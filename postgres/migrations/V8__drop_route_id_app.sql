-- =============================================================================
-- V8 — drop ROUTE.id_app. V6 added it as a direct "primary app" FK
-- alongside app_route (M:N), but a singular FK can't represent a route
-- belonging to more than one app, and it drifted out of sync with
-- app_route whenever an admin bound/unbound routes only through the
-- App edit page's route picker. app_route is the sole route<->app
-- membership relation going forward. MICROSERVICE.id_app is untouched
-- — only ROUTE loses its FK.
-- Ported from postgres/init/06-create-app-tables.sh (commit b8e55bd).
-- =============================================================================

DROP INDEX IF EXISTS idx_route_app;

ALTER TABLE ROUTE DROP COLUMN IF EXISTS id_app;
