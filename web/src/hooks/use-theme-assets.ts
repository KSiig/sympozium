import { useState, useEffect } from "react";

const ASSETS: Record<string, { icon: string; logo: string }> = {
  industrial: { icon: "/icon-industrial.svg", logo: "/logo-industrial.svg" },
  classic: { icon: "/icon.png", logo: "/logo.png" },
};

export function useThemeAssets() {
  const [theme, setTheme] = useState(
    () => document.documentElement.getAttribute("data-theme") || "industrial",
  );

  useEffect(() => {
    const observer = new MutationObserver(() => {
      setTheme(
        document.documentElement.getAttribute("data-theme") || "industrial",
      );
    });
    observer.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["data-theme"],
    });
    return () => observer.disconnect();
  }, []);

  return ASSETS[theme] || ASSETS.industrial;
}
