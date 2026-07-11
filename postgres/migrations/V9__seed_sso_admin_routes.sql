-- =============================================================================
-- V9 — sso-admin sidebar menu seed. Inserts the twelve ROUTE rows the
-- legacy hardcoded Sidebar.tsx rendered before the dynamic sidebar was
-- wired to GET /sso-admin/myMenu, and binds all of them to ADMIN via
-- ROLE_ROUTE directly (independent of App membership — see V10 for the
-- App-path binding). Idempotent: WHERE NOT EXISTS on PATH for the
-- ROUTE insert, ON CONFLICT DO NOTHING on the composite PK for
-- ROLE_ROUTE, so re-running against an already-seeded DB is a no-op.
-- Ported from postgres/init/08-seed-sso-admin-routes.sh.
-- =============================================================================

INSERT INTO ROUTE (NAME, ICON, PATH, MENUORDER, TYPE, IDPARENT)
SELECT v.name, v.icon, v.path, v.menu_order, NULL, NULL
FROM (VALUES
    ('Usuarios',         'users',       '/admin/users',          1),
    ('Roles',            'shieldcheck', '/admin/roles',          2),
    ('Grupos',           'users',       '/admin/groups',         3),
    ('Microservicios',   'box',         '/admin/microservices',  4),
    ('Query Services',   'database',    '/admin/query-services', 5),
    ('Queries Catalog',  'layers',      '/admin/queries',        6),
    ('Queries (admin)',  'settings',    '/admin/query-catalog',  7),
    ('Dynamic CRUD',     'foldertree',  '/admin/dynamic-crud',   8),
    ('Endpoints',        'network',     '/admin/endpoints',      9),
    ('Rutas',            'network',     '/admin/routes',        10),
    ('Apps',             'layers',      '/admin/apps',          11),
    ('Writes',           'filetext',    '/admin/writes',        12)
) AS v(name, icon, path, menu_order)
WHERE NOT EXISTS (
    SELECT 1 FROM ROUTE WHERE ROUTE.PATH = v.path
);

INSERT INTO ROLE_ROUTE (ROLE_ID, ROUTE_ID)
SELECT r.id_role, ro.ID_ROUTE
FROM role r
CROSS JOIN ROUTE ro
WHERE r.name = 'ADMIN'
  AND ro.PATH LIKE '/admin/%'
ON CONFLICT (ROLE_ID, ROUTE_ID) DO NOTHING;
