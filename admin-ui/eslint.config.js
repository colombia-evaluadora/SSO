// Flat config (ESLint 9). Keep the surface area small — we don't
// need stylistic rules here, that's Prettier's job.
import tseslint from "@typescript-eslint/eslint-plugin";
import tsParser from "@typescript-eslint/parser";
import react from "eslint-plugin-react";
import reactHooks from "eslint-plugin-react-hooks";
import jsxA11y from "eslint-plugin-jsx-a11y";

export default [
  {
    ignores: ["dist/**", "node_modules/**", "coverage/**", "playwright-report/**", "test-results/**"],
  },
  {
    files: ["**/*.{ts,tsx}"],
    languageOptions: {
      parser: tsParser,
      parserOptions: {
        ecmaVersion: "latest",
        sourceType: "module",
        ecmaFeatures: { jsx: true },
      },
    },
    plugins: {
      "@typescript-eslint": tseslint,
      react,
      "react-hooks": reactHooks,
      "jsx-a11y": jsxA11y,
    },
    settings: {
      react: { version: "detect" },
    },
    rules: {
      // No "any" by default. Zod + the typed API client give us
      // real shapes; falling back to "any" hides bugs.
      "@typescript-eslint/no-explicit-any": "error",
      // Hooks rules — for the price of a one-time setup, the
      // exhaustive-deps rule catches a class of subtle bugs.
      "react-hooks/rules-of-hooks": "error",
      "react-hooks/exhaustive-deps": "warn",
      // React 19 + the new JSX transform.
      "react/react-in-jsx-scope": "off",
      "react/prop-types": "off",
      // Accessibility — we ship a11y-tagged primitives below.
      "jsx-a11y/label-has-associated-control": "warn",
      "jsx-a11y/no-autofocus": "warn",
    },
  },
];
