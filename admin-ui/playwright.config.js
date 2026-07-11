var __assign = (this && this.__assign) || function () {
    __assign = Object.assign || function(t) {
        for (var s, i = 1, n = arguments.length; i < n; i++) {
            s = arguments[i];
            for (var p in s) if (Object.prototype.hasOwnProperty.call(s, p))
                t[p] = s[p];
        }
        return t;
    };
    return __assign.apply(this, arguments);
};
var _a;
import { defineConfig, devices } from "@playwright/test";
/**
 * Playwright config. Single browser (chromium) for the happy-path
 * E2E. We use the Vite dev server (port 5173) as the base URL —
 * Vite proxies /api to the gateway, so the SPA sees a single
 * origin, matching production behavior.
 *
 * `webServer` boots Vite automatically before the tests and
 * reuses it across runs. The proxy requires the gateway to be
 * running on :8080 — start it via `mvn -pl api-gateway spring-boot:run`
 * (or `docker compose up api-gateway`) before `npm run e2e`.
 *
 * In CI we run against the built image: set `BASE_URL=http://localhost:8080/admin/`
 * and Playwright will skip the local webServer.
 */
export default defineConfig({
    testDir: "./e2e",
    fullyParallel: false,
    forbidOnly: !!process.env.CI,
    retries: process.env.CI ? 2 : 0,
    workers: 1,
    reporter: process.env.CI ? "github" : "list",
    use: {
        baseURL: (_a = process.env.BASE_URL) !== null && _a !== void 0 ? _a : "http://localhost:5173/admin/",
        trace: "on-first-retry",
        screenshot: "only-on-failure",
    },
    projects: [
        {
            name: "chromium",
            use: __assign({}, devices["Desktop Chrome"]),
        },
    ],
    webServer: process.env.BASE_URL
        ? undefined
        : {
            command: "npm run dev",
            url: "http://localhost:5173",
            reuseExistingServer: !process.env.CI,
            timeout: 60000,
        },
});
