-- =============================================================================
-- V10 — sso-admin App grouping seed. Complements V9: that migration
-- bound every /admin/** route to ADMIN via the direct ROLE_ROUTE join
-- table; this one populates the App-path branch of
-- RouteRepository.findVisibleForRoles (role_app + app_route) for the
-- SSO-ADMIN app. app_route is the sole route<->app membership relation
-- (ROUTE has no id_app FK of its own — see V8). Assumes the SSO-ADMIN
-- app row already exists (created via the running application, not
-- seeded here). Idempotent: both inserts use ON CONFLICT DO NOTHING
-- on their composite PKs.
-- Ported from postgres/init/09-seed-sso-admin-app.sh.
-- =============================================================================

INSERT INTO role_app (id_app, id_role)
SELECT a.id_app, r.id_role
FROM app a
CROSS JOIN role r
WHERE a.name = 'SSO-ADMIN'
  AND r.name = 'ADMIN'
ON CONFLICT (id_app, id_role) DO NOTHING;

INSERT INTO app_route (id_app, id_route)
SELECT a.id_app, ro.ID_ROUTE
FROM app a
CROSS JOIN ROUTE ro
WHERE a.name = 'SSO-ADMIN'
  AND ro.PATH LIKE '/admin/%'
ON CONFLICT (id_app, id_route) DO NOTHING;
