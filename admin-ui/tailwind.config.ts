import type { Config } from "tailwindcss";

/**
 * Tailwind config — content scan picks up any TSX file under src/.
 * The preflight reset is the only base style applied. We do NOT
 * add custom utilities beyond what Tailwind ships; doing so would
 * add CSS that bypasses the strict CSP we set in index.html
 * (no 'unsafe-inline', no inline styles).
 */
export default {
  content: ["./index.html", "./src/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        // Neutral grays for the chrome.
        surface: {
          50: "#f8fafc",
          100: "#f1f5f9",
          200: "#e2e8f0",
          300: "#cbd5e1",
          700: "#334155",
          800: "#1e293b",
          900: "#0f172a",
        },
        // Action colors.
        brand: {
          50: "#eff6ff",
          100: "#dbeafe",
          500: "#3b82f6",
          600: "#2563eb",
          700: "#1d4ed8",
        },
      },
    },
  },
  plugins: [],
} satisfies Config;
