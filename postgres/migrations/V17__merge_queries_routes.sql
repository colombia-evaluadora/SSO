-- =============================================================================
-- V14 — merge the two queries sidebar routes into one. V9 seeded two entries
-- for what was really one feature: 'Queries Catalog' -> /admin/queries (the
-- consumer-only execution page) and 'Queries (admin)' -> /admin/query-catalog
-- (the CRUD page). The admin page now also executes, so the consumer page was
-- removed and /admin/queries redirects to /admin/query-catalog. Drop the
-- now-defunct /admin/queries route and rename the surviving one to the plain
-- 'Queries Catalog' label. Idempotent: no-ops once the /admin/queries row is
-- gone. Delete ROLE_ROUTE bindings first to satisfy the FK.
-- =============================================================================

DELETE FROM ROLE_ROUTE
WHERE ROUTE_ID IN (SELECT ID_ROUTE FROM ROUTE WHERE PATH = '/admin/queries');

DELETE FROM ROUTE WHERE PATH = '/admin/queries';

UPDATE ROUTE
SET NAME = 'Queries Catalog', ICON = 'layers'
WHERE PATH = '/admin/query-catalog';
