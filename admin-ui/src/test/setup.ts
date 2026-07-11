/**
 * Vitest setup. Loaded by vite.config.ts's `test.setupFiles`.
 *
 * We use happy-dom (not jsdom) because happy-dom is significantly
 * smaller and faster for the small amount of DOM this app needs in
 * tests. The trade-off is missing a few APIs (CSSStyleSheet etc.)
 * which we don't use.
 */
import "@testing-library/jest-dom/vitest";
import { afterEach, vi } from "vitest";
import { cleanup } from "@testing-library/react";

// happy-dom + cleanup: every test gets a fresh DOM. Without this,
// state leaks between tests via the global document.
afterEach(() => {
  cleanup();
});

// Stable URL for any fetch the test triggers. Real network is mocked
// by individual tests via vi.spyOn(global, "fetch").
process.env.VITE_API_BASE = "/api";
vi.stubGlobal("matchMedia", (query: string) => ({
  matches: false,
  media: query,
  onchange: null,
  addListener: vi.fn(),
  removeListener: vi.fn(),
  addEventListener: vi.fn(),
  removeEventListener: vi.fn(),
  dispatchEvent: vi.fn(),
}));
