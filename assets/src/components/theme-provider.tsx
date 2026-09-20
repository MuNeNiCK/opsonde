import * as React from "react";

type Theme = "light" | "dark";

export type ThemeSetting = Theme | "system";

export type ThemeProviderProps = {
  attribute?: string;
  children: React.ReactNode;
  defaultTheme?: ThemeSetting;
  disableTransitionOnChange?: boolean;
  enableSystem?: boolean;
  storageKey?: string;
  value?: Partial<Record<Theme, string>>;
};

type ThemeContextValue = {
  theme: ThemeSetting;
  resolvedTheme: Theme;
  systemTheme: Theme;
  setTheme: (theme: ThemeSetting) => void;
};

const COLOR_SCHEME_QUERY = "(prefers-color-scheme: dark)";
const DEFAULT_STORAGE_KEY = "console-ui-theme";
const DEFAULT_ATTRIBUTE_VALUE: Record<Theme, string> = {
  light: "light",
  dark: "dark",
};

const ThemeContext = React.createContext<ThemeContextValue | undefined>(undefined);

const fallbackContext: ThemeContextValue = {
  theme: "system",
  resolvedTheme: "light",
  systemTheme: "light",
  setTheme: () => {},
};

function getSystemTheme(): Theme {
  if (typeof window === "undefined") {
    return "light";
  }

  return window.matchMedia(COLOR_SCHEME_QUERY).matches ? "dark" : "light";
}

function disableTransitionsTemporarily() {
  if (typeof document === "undefined") {
    return () => {};
  }

  const style = document.createElement("style");
  style.setAttribute("data-console-ui-theme-transition", "false");
  style.appendChild(
    document.createTextNode("*{transition-duration:0s!important;animation-duration:0s!important;}"),
  );
  document.head.appendChild(style);

  return () => {
    requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        style.remove();
      });
    });
  };
}

function applyTheme(options: {
  attribute: string;
  disableTransitionOnChange: boolean;
  theme: Theme;
  value?: ThemeProviderProps["value"];
}) {
  if (typeof document === "undefined") {
    return;
  }

  const { attribute, disableTransitionOnChange, theme, value } = options;
  const cleanup = disableTransitionOnChange ? disableTransitionsTemporarily() : undefined;
  const nextValue = value?.[theme] ?? DEFAULT_ATTRIBUTE_VALUE[theme];

  if (attribute === "class") {
    const values = Object.values({
      ...DEFAULT_ATTRIBUTE_VALUE,
      ...value,
    }).filter(Boolean);

    document.documentElement.classList.remove(...values);
    document.documentElement.classList.add(nextValue);
  } else {
    document.documentElement.setAttribute(attribute, nextValue);
  }

  cleanup?.();
}

function readStoredTheme(storageKey: string): ThemeSetting | null {
  try {
    const value = localStorage.getItem(storageKey);

    if (value === "light" || value === "dark" || value === "system") {
      return value;
    }
  } catch {
    return null;
  }

  return null;
}

export function ThemeProvider({
  attribute = "class",
  children,
  defaultTheme = "system",
  disableTransitionOnChange = false,
  enableSystem = true,
  storageKey = DEFAULT_STORAGE_KEY,
  value,
}: ThemeProviderProps) {
  const [theme, setThemeState] = React.useState<ThemeSetting>(defaultTheme);
  const [systemTheme, setSystemTheme] = React.useState<Theme>(getSystemTheme);
  const resolvedTheme = theme === "system" ? (enableSystem ? systemTheme : "light") : theme;

  React.useEffect(() => {
    setThemeState(readStoredTheme(storageKey) ?? defaultTheme);
  }, [defaultTheme, storageKey]);

  React.useEffect(() => {
    if (!enableSystem || typeof window === "undefined") {
      return;
    }

    const media = window.matchMedia(COLOR_SCHEME_QUERY);
    const handleChange = (event: MediaQueryListEvent) => {
      setSystemTheme(event.matches ? "dark" : "light");
    };

    setSystemTheme(media.matches ? "dark" : "light");
    media.addEventListener("change", handleChange);

    return () => media.removeEventListener("change", handleChange);
  }, [enableSystem]);

  React.useEffect(() => {
    applyTheme({
      attribute,
      disableTransitionOnChange,
      theme: resolvedTheme,
      value,
    });
  }, [attribute, disableTransitionOnChange, resolvedTheme, value]);

  const setTheme = React.useCallback(
    (nextTheme: ThemeSetting) => {
      setThemeState(nextTheme);

      try {
        localStorage.setItem(storageKey, nextTheme);
      } catch {
        // localStorage can be unavailable in restricted browser contexts.
      }
    },
    [storageKey],
  );

  const contextValue = React.useMemo<ThemeContextValue>(
    () => ({
      theme,
      resolvedTheme,
      setTheme,
      systemTheme,
    }),
    [theme, resolvedTheme, setTheme, systemTheme],
  );

  return <ThemeContext.Provider value={contextValue}>{children}</ThemeContext.Provider>;
}

export function useTheme() {
  return React.useContext(ThemeContext) ?? fallbackContext;
}
