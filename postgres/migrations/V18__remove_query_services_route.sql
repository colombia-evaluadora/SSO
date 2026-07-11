-- =============================================================================
-- V18 — drop the standalone "Query Services" sidebar route. The QUERY-kind
-- microservice CRUD/ops that lived at /admin/query-services now renders
-- inline at the bottom of the Microservicios page (/admin/microservices),
-- so the separate menu entry (seeded by V9 as menuorder 5) is gone.
--
-- ROLE_ROUTE.route_id and APP_ROUTE.id_route are both ON DELETE CASCADE
-- (V3, V6), so deleting the ROUTE row clears its bindings automatically;
-- we still delete them explicitly first, matching V17's style, so the
-- intent is obvious and the migration is safe regardless of FK config.
-- Idempotent: no-ops once the /admin/query-services row is gone.
-- =============================================================================

DELETE FROM ROLE_ROUTE
WHERE ROUTE_ID IN (SELECT ID_ROUTE FROM ROUTE WHERE PATH = '/admin/query-services');

DELETE FROM APP_ROUTE
WHERE ID_ROUTE IN (SELECT ID_ROUTE FROM ROUTE WHERE PATH = '/admin/query-services');

DELETE FROM ROUTE WHERE PATH = '/admin/query-services';
