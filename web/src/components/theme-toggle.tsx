import { useState, useEffect } from "react";
import { Button } from "@/components/ui/button";
import { Paintbrush } from "lucide-react";

const THEMES = [
  { id: "industrial", label: "Neo Industrial", colors: ["#1a1a18", "#f0ece4", "#e8562a"] },
  { id: "classic", label: "Classic", colors: ["#0f172a", "#e2e8f0", "#3b82f6"] },
] as const;

type ThemeId = (typeof THEMES)[number]["id"];

function getStoredTheme(): ThemeId {
  return (localStorage.getItem("sympozium-theme") as ThemeId) || "industrial";
}

function applyTheme(id: ThemeId) {
  if (id === "industrial") {
    document.documentElement.removeAttribute("data-theme");
  } else {
    document.documentElement.setAttribute("data-theme", id);
  }
  localStorage.setItem("sympozium-theme", id);
}

export function ThemeToggle() {
  const [active, setActive] = useState<ThemeId>(getStoredTheme);
  const [open, setOpen] = useState(false);

  useEffect(() => {
    applyTheme(active);
  }, [active]);

  const toggle = (id: ThemeId) => {
    setActive(id);
    setOpen(false);
  };

  return (
    <div className="relative">
      <Button
        variant="ghost"
        size="icon"
        onClick={() => setOpen((v) => !v)}
        title="Switch theme"
      >
        <Paintbrush className="h-4 w-4" />
      </Button>

      {open && (
        <>
          <div className="fixed inset-0 z-40" onClick={() => setOpen(false)} />
          <div className="absolute right-0 top-full mt-1 z-50 w-48 border bg-popover text-popover-foreground shadow-lg p-1">
            {THEMES.map((t) => (
              <button
                key={t.id}
                onClick={() => toggle(t.id)}
                className={`flex w-full items-center gap-3 px-3 py-2 text-sm transition-colors ${
                  active === t.id
                    ? "bg-accent text-accent-foreground"
                    : "hover:bg-accent/50"
                }`}
              >
                <div className="flex gap-1">
                  {t.colors.map((c, i) => (
                    <span
                      key={i}
                      className="h-3 w-3 border border-border/50"
                      style={{ backgroundColor: c }}
                    />
                  ))}
                </div>
                <span>{t.label}</span>
              </button>
            ))}
          </div>
        </>
      )}
    </div>
  );
}
