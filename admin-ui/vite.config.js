/// <reference types="vitest" />
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import path from "node:path";
/**
 * Vite config for the admin SPA. In dev, the Vite server runs on
 * :5173 and proxies any /api/* request to the api-gateway on :8080.
 * This is what makes the cookie-based auth flow work without
 * involving CORS: the browser sees a single origin (the Vite dev
 * server), and the proxy makes the request to the gateway on the
 * server side, carrying cookies through HttpClient's normal
 * forwarding.
 *
 * In production, VITE_API_BASE is /api and the gateway serves the
 * SPA at /admin/** AND proxies /api/** to the backend. Single origin
 * end-to-end, no CORS at all.
 */
export default defineConfig({
    // The api-gateway serves this SPA under /admin/** (see
    // AdminUiGlobalFilter). Without this base, Vite emits asset
    // URLs at the site root (/assets/...) which the gateway does not
    // serve and its deny-by-default security 401s — the page renders
    // blank. base: "/admin/" makes the built index.html reference
    // /admin/assets/... which the gateway serves and permits. The
    // router already hardcodes the /admin prefix in its route paths,
    // so no React Router basename is needed.
    base: "/admin/",
    plugins: [react()],
    resolve: {
        alias: {
            "@": path.resolve(__dirname, "src"),
        },
    },
    server: {
        port: 5173,
        proxy: {
            // Anything under /api (auth, sso-admin, anything else) is
            // forwarded to the gateway. The Vite dev server does NOT
            // change the request — Origin/Host/cookies are preserved.
            "/api": {
                target: "http://localhost:8080",
                changeOrigin: false,
                secure: false,
            },
            // The Queries Catalog calls query-service containers
            // directly (NOT under /api): the gateway's discovery
            // locator auto-creates /query-service-<instance>/** routes
            // from Eureka service ids lowercased. Forward those too,
            // otherwise the SPA's fetch hits Vite itself and 404s
            // (it forwards the path verbatim, no StripPrefix — the
            // gateway's locator expects /query-service-<x>/...).
            "/query-service": {
                target: "http://localhost:8080",
                changeOrigin: false,
                secure: false,
            },
        },
    },
    preview: {
        // `npm run preview` serves the production build (dist/) on
        // :4173. Without this proxy the SPA's /api/* calls would hit
        // :4173/api/* and 404 (Vite preview has no built-in proxy
        // outside of `server`). Adding the same forward as dev keeps
        // the prod-bundle testable locally without rebuilding the
        // gateway image each time you tweak the SPA.
        port: 4173,
        proxy: {
            "/api": {
                target: "http://localhost:8080",
                changeOrigin: false,
                secure: false,
            },
            // Same gateway auto-locator routes as in `server` above.
            // Without this, /query-service-postfix-.../query from the
            // SPA hits :4173 and the dev server 404s the static asset.
            "/query-service": {
                target: "http://localhost:8080",
                changeOrigin: false,
                secure: false,
            },
        },
    },
    build: {
        outDir: "dist",
        // Sourcemaps are dev artifacts. Keeping them OFF in the
        // production build saves ~1.3 MB in the api-gateway jar
        // (the SPA's `dist/` is copied into the jar's resources
        // before `mvn package`; sourcemaps would otherwise ship
        // inside the fat jar with no consumer). For debugging
        // production minified bundles, run a local dev server
        // (`npm run dev`) and use the browser devtools there.
        sourcemap: false,
        target: "es2022",
    },
    test: {
        environment: "happy-dom",
        globals: true,
        setupFiles: ["./src/test/setup.ts"],
        // e2e/ is Playwright's territory; vitest only owns src/.
        include: ["src/**/*.{test,spec}.{ts,tsx}"],
        exclude: ["node_modules", "dist", "e2e"],
    },
});
