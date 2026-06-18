package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type sidecarToolManifest struct {
	Tools []sidecarToolEntry `json:"tools"`
}

type sidecarToolEntry struct {
	Name           string         `json:"name"`
	Description    string         `json:"description"`
	Target         string         `json:"target"`
	Subcommand     string         `json:"subcommand"`
	InputMode      string         `json:"inputMode"`      // "stdin" or "args"
	PositionalArgs []string       `json:"positionalArgs"` // parameter names to pass as positional CLI args (in order)
	Parameters     map[string]any `json:"parameters"`
}

var (
	sidecarToolRegistry   = map[string]sidecarToolEntry{}
	sidecarToolRegistryMu sync.RWMutex
)

// loadSidecarTools reads all sidecar-tools-*.json manifests from ipcToolsDir
// and returns ToolDef entries for the LLM tool list. It also populates
// sidecarToolRegistry for dispatch. Waits up to 5 seconds for at least one
// manifest to appear (sidecars may still be starting).
func loadSidecarTools(ipcToolsDir string) []ToolDef {
	pattern := filepath.Join(ipcToolsDir, "sidecar-tools-*.json")

	var files []string
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		var err error
		files, err = filepath.Glob(pattern)
		if err == nil && len(files) > 0 {
			break
		}
		files = nil
		time.Sleep(500 * time.Millisecond)
	}

	if len(files) == 0 {
		return nil
	}

	var allTools []ToolDef
	sidecarToolRegistryMu.Lock()
	defer sidecarToolRegistryMu.Unlock()

	for _, f := range files {
		data, err := os.ReadFile(f)
		if err != nil {
			log.Printf("sidecar_tools: failed to read %s: %v", f, err)
			continue
		}

		var manifest sidecarToolManifest
		if err := json.Unmarshal(data, &manifest); err != nil {
			log.Printf("sidecar_tools: failed to parse %s: %v", f, err)
			continue
		}

		for _, entry := range manifest.Tools {
			sidecarToolRegistry[entry.Name] = entry
			allTools = append(allTools, ToolDef{
				Name:        entry.Name,
				Description: entry.Description,
				Parameters:  entry.Parameters,
			})
			log.Printf("sidecar_tools: registered %s (target=%s, subcommand=%s)",
				entry.Name, entry.Target, entry.Subcommand)
		}
	}

	return allTools
}

func lookupSidecarTool(name string) (sidecarToolEntry, bool) {
	sidecarToolRegistryMu.RLock()
	defer sidecarToolRegistryMu.RUnlock()
	entry, ok := sidecarToolRegistry[name]
	return entry, ok
}

func isSidecarTool(name string) bool {
	sidecarToolRegistryMu.RLock()
	defer sidecarToolRegistryMu.RUnlock()
	_, ok := sidecarToolRegistry[name]
	return ok
}

// executeSidecarTool constructs the shell command for a sidecar native tool
// and dispatches it via the existing IPC executeCommand mechanism.
func executeSidecarTool(ctx context.Context, tool sidecarToolEntry, argsJSON string) string {
	subcommand := tool.Subcommand

	var args map[string]any
	if err := json.Unmarshal([]byte(argsJSON), &args); err != nil {
		return fmt.Sprintf("Error parsing sidecar tool arguments: %v", err)
	}

	// Extract positional args (in declared order) and build the suffix.
	var posSuffix string
	if len(tool.PositionalArgs) > 0 {
		var parts []string
		for _, key := range tool.PositionalArgs {
			if val, ok := args[key]; ok {
				parts = append(parts, fmt.Sprintf("%v", val))
				delete(args, key) // remove from the map so it's not piped on stdin
			}
		}
		if len(parts) > 0 {
			posSuffix = " " + strings.Join(parts, " ")
		}
	}

	var command string
	if tool.InputMode == "stdin" {
		// Re-marshal the remaining args (positional fields stripped) as stdin JSON.
		stdinJSON, err := json.Marshal(args)
		if err != nil {
			return fmt.Sprintf("Error marshalling sidecar tool stdin: %v", err)
		}
		escaped := strings.ReplaceAll(string(stdinJSON), "'", "'\\''")
		command = fmt.Sprintf("echo '%s' | node /app/dist/cli.js %s%s",
			escaped, subcommand, posSuffix)
	} else {
		// Args-mode: positional args appended to the subcommand.
		command = fmt.Sprintf("node /app/dist/cli.js %s%s", subcommand, posSuffix)
	}

	return executeCommand(ctx, map[string]any{
		"command": command,
		"target":  tool.Target,
	})
}
