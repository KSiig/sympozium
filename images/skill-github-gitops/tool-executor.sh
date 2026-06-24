#!/bin/bash
# tool-executor.sh — Watches /ipc/tools/ for exec-request-*.json files,
# executes the requested commands, and writes exec-result-*.json responses.
# This script runs as the main process in the github-gitops skill sidecar.
#
# Differences from the generic sidecar:
#   - Loads GH_TOKEN from the mounted Secret at startup so `gh` is authenticated.
#   - Exports sympozium_fingerprint() helper for deterministic deduplication hashes.

set -euo pipefail

export TOOLS_DIR="/ipc/tools"
POLL_INTERVAL=0.2  # seconds
export RESULTS_DIR="/workspace/.ipc-results"

SECRET_FILE="/secrets/github-token/GH_TOKEN"

mkdir -p "$TOOLS_DIR"

# ---------------------------------------------------------------------------
# Auth — load the GitHub token from the mounted Secret (if present).
# The Secret is managed by the Sympozium API server's auth flow.
# ---------------------------------------------------------------------------
if [[ -f "$SECRET_FILE" ]]; then
    GH_TOKEN="$(cat "$SECRET_FILE")"
    export GH_TOKEN
    echo "[tool-executor] GitHub token loaded from $SECRET_FILE"
else
    echo "[tool-executor] WARNING: $SECRET_FILE not found — gh commands will run unauthenticated"
fi

# ---------------------------------------------------------------------------
# sympozium_fingerprint <string>
#
# Produces a stable 12-character base-36 lowercase identifier for <string>.
# Used to tag GitHub issues/PRs so the agent can detect duplicates.
#
# Usage (inside execute_command calls):
#   FP=$(sympozium_fingerprint "Deployment/my-app/crashloop")
#   gh issue list --label "sympozium-fp:$FP" ...
# ---------------------------------------------------------------------------
sympozium_fingerprint() {
    local input="$1"
    # sha256sum outputs hex; take first 16 hex chars → convert to decimal → format
    # as 12-char base-36.  Pure bash + standard coreutils, no Python needed.
    local hex
    hex=$(printf '%s' "$input" | sha256sum | awk '{print $1}' | head -c 16)
    local dec
    dec=$(printf '%d' "0x${hex}" 2>/dev/null || python3 -c "print(int('${hex}',16))")
    # Convert decimal to base-36 (0-9, a-z).
    local result="" n=$dec
    local charset="0123456789abcdefghijklmnopqrstuvwxyz"
    if [[ $n -eq 0 ]]; then
        result="0"
    else
        while [[ $n -gt 0 ]]; do
            result="${charset:$((n % 36)):1}${result}"
            n=$((n / 36))
        done
    fi
    # Pad / truncate to exactly 12 characters.
    result="${result:0:12}"
    while [[ ${#result} -lt 12 ]]; do result="0${result}"; done
    printf '%s' "$result"
}
export -f sympozium_fingerprint

echo "[tool-executor] started, watching $TOOLS_DIR for exec requests"

# ---------------------------------------------------------------------------
# sidecar_exec <target> <command> [timeout_sec]
#
# Send an exec request to another sidecar and wait for its result.
# Returns stdout (or file contents via resultPath) on success; exits non-zero
# on failure or timeout. Intended for sidecar-to-sidecar calls that bypass
# the LLM context entirely.
# ---------------------------------------------------------------------------
sidecar_exec() {
    local target="$1"
    local command="$2"
    local timeout_sec="${3:-30}"

    local id="sidecar-$(date +%s%N)-$$"
    local req_file="$TOOLS_DIR/exec-request-${id}.json"
    local res_file="$TOOLS_DIR/exec-result-${id}.json"

    jq -n \
        --arg id "$id" \
        --arg command "$command" \
        --arg target "$target" \
        --arg caller "${SYMPOZIUM_SKILL_PACK:-unknown}" \
        --argjson timeout "$timeout_sec" \
        '{id: $id, command: $command, target: $target, caller: $caller, timeout: $timeout}' \
        > "${req_file}.tmp"
    mv "${req_file}.tmp" "$req_file"

    local deadline=$((SECONDS + timeout_sec + 5))
    while [ $SECONDS -lt $deadline ]; do
        if [ -f "$res_file" ]; then
            local exit_code result_path
            exit_code=$(jq -r '.exitCode // 1' "$res_file")
            if [ "$exit_code" -ne 0 ]; then
                jq -r '.stderr // ""' "$res_file" >&2
                rm -f "$req_file" "$res_file" 2>/dev/null
                rm -rf "$TOOLS_DIR/.claim-${id}" 2>/dev/null
                return "$exit_code"
            fi
            result_path=$(jq -r '.resultPath // ""' "$res_file")
            if [ -n "$result_path" ] && [ -f "$result_path" ]; then
                cat "$result_path"
                rm -f "$result_path"
            else
                jq -r '.stdout // ""' "$res_file"
            fi
            rm -f "$req_file" "$res_file" 2>/dev/null
            rm -rf "$TOOLS_DIR/.claim-${id}" 2>/dev/null
            return 0
        fi
        sleep 0.15
    done

    rm -f "$req_file" 2>/dev/null
    echo "sidecar_exec: timed out waiting for $target" >&2
    return 124
}
export -f sidecar_exec

# ---------------------------------------------------------------------------
# process_request <req_file>
# ---------------------------------------------------------------------------
process_request() {
    local req_file="$1"
    local basename
    basename=$(basename "$req_file")

    local id
    id="${basename#exec-request-}"
    id="${id%.json}"

    local result_file="$TOOLS_DIR/exec-result-${id}.json"

    local command args workdir timeout_sec
    command=$(jq -r '.command // ""' "$req_file" 2>/dev/null) || return
    args=$(jq -r '(.args // []) | join(" ")' "$req_file" 2>/dev/null) || return
    workdir=$(jq -r '.workDir // "/workspace"' "$req_file" 2>/dev/null) || return
    timeout_sec=$(jq -r '.timeout // 60' "$req_file" 2>/dev/null) || return

    if [[ "$timeout_sec" -lt 1 ]]; then timeout_sec=60; fi
    if [[ "$timeout_sec" -gt 300 ]]; then timeout_sec=300; fi

    local full_cmd="$command"
    if [[ -n "$args" ]]; then
        full_cmd="$command $args"
    fi

    echo "[tool-executor] exec [$id]: $full_cmd (timeout=${timeout_sec}s, workdir=${workdir})"

    local stdout="" stderr="" exit_code=0 timed_out="false"
    local tmp_stdout tmp_stderr
    tmp_stdout=$(mktemp)
    tmp_stderr=$(mktemp)

    cd "$workdir" 2>/dev/null || cd /

    if timeout "$timeout_sec" bash -c "$full_cmd" >"$tmp_stdout" 2>"$tmp_stderr"; then
        exit_code=0
    else
        exit_code=$?
        if [[ $exit_code -eq 124 ]]; then
            timed_out="true"
        fi
    fi

    stdout=$(cat "$tmp_stdout")
    stderr=$(cat "$tmp_stderr")
    rm -f "$tmp_stdout" "$tmp_stderr"

    local result_path=""
    if [[ ${#stdout} -gt 51200 ]]; then
        mkdir -p "$RESULTS_DIR"
        result_path="$RESULTS_DIR/${id}.out"
        printf '%s' "$stdout" > "$result_path"
        stdout="(large output: ${#stdout} bytes written to $result_path)"
    fi
    if [[ ${#stderr} -gt 51200 ]]; then
        stderr="${stderr:0:51200}...(truncated)"
    fi

    local tmp_result="${result_file}.tmp"
    if [[ -n "$result_path" ]]; then
        jq -n \
            --arg id "$id" \
            --argjson exitCode "$exit_code" \
            --arg stdout "$stdout" \
            --arg stderr "$stderr" \
            --argjson timedOut "$timed_out" \
            --arg resultPath "$result_path" \
            '{id: $id, exitCode: $exitCode, stdout: $stdout, stderr: $stderr, timedOut: $timedOut, resultPath: $resultPath}' \
            > "$tmp_result"
    else
        jq -n \
            --arg id "$id" \
            --argjson exitCode "$exit_code" \
            --arg stdout "$stdout" \
            --arg stderr "$stderr" \
            --argjson timedOut "$timed_out" \
            '{id: $id, exitCode: $exitCode, stdout: $stdout, stderr: $stderr, timedOut: $timedOut}' \
            > "$tmp_result"
    fi
    mv "$tmp_result" "$result_file"

    echo "[tool-executor] done [$id]: exit=$exit_code timed_out=$timed_out"
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
while true; do
    if [[ -f /ipc/done ]]; then
        echo "[tool-executor] agent done, exiting"
        exit 0
    fi

    for req_file in "$TOOLS_DIR"/exec-request-*.json; do
        [[ -e "$req_file" ]] || continue

        local_basename=$(basename "$req_file")
        local_id="${local_basename#exec-request-}"
        local_id="${local_id%.json}"
        result_file="$TOOLS_DIR/exec-result-${local_id}.json"

        if [[ -e "$result_file" ]]; then
            continue
        fi

        # Target-based routing: if the request specifies a target, only the
        # sidecar whose SYMPOZIUM_SKILL_PACK env matches may claim it. An
        # empty target preserves legacy behavior (any sidecar may claim).
        # Comparison is case-insensitive and whitespace-trimmed for safety.
        if [[ -n "${SYMPOZIUM_SKILL_PACK:-}" ]]; then
            req_target=$(jq -r '.target // ""' "$req_file" 2>/dev/null || echo "")
            req_target_norm=$(printf '%s' "$req_target" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
            self_norm=$(printf '%s' "$SYMPOZIUM_SKILL_PACK" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
            if [[ -n "$req_target_norm" && "$req_target_norm" != "$self_norm" ]]; then
                continue
            fi
        fi

        claim_dir="$TOOLS_DIR/.claim-${local_id}"
        if ! mkdir "$claim_dir" 2>/dev/null; then
            continue
        fi

        process_request "$req_file" &
    done

    sleep "$POLL_INTERVAL"
done
