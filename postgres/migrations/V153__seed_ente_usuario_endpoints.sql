-- Registra en el catálogo los 4 endpoints de EnteUsuarioController
-- (sso-admin) -- sin esta fila, SsoAdminAccessManager responde 403 a
-- TODO el mundo (autorización per-endpoint vía endpoint+role_endpoint,
-- sin bypass para ningún rol -- mismo patrón que V125 sembró para
-- /audit/revert).
--
-- Gateado a ADMIN (genérico), no a CEVAL-SUPER_ADMINISTRADOR como el
-- audit-revert -- se pidió explícitamente "nivel admin sso", y dar de
-- alta un usuario de Ente Territorial es una operación administrativa
-- normal, no destructiva sobre datos existentes.

INSERT INTO endpoint (method, path, description, numberparams) VALUES
    ('GET',  '/ente/listar',        'Listar entes territoriales activos', 0),
    ('GET',  '/ente/roles',         'Listar roles TROL disponibles para bind de ente territorial', 0),
    ('POST', '/ente/usuario/bind',  'Dar de alta un usuario de Ente Territorial (TENTE_USUARIO)', 1),
    ('DELETE', '/ente/usuario/unbind', 'Dar de baja un usuario de Ente Territorial (TENTE_USUARIO)', 3)
ON CONFLICT (path, method, description) DO NOTHING;

INSERT INTO role_app (id_app, id_role)
SELECT a.id_app, r.id_role
  FROM app a CROSS JOIN role r
 WHERE a.name = 'SSO-ADMIN' AND r.name = 'ADMIN'
ON CONFLICT DO NOTHING;

INSERT INTO role_endpoint (endpoint_id, role_id)
SELECT e.id_endpoint, r.id_role
  FROM endpoint e
 CROSS JOIN role r
 WHERE r.name = 'ADMIN'
   AND (e.method, e.path) IN (
       ('GET', '/ente/listar'), ('GET', '/ente/roles'),
       ('POST', '/ente/usuario/bind'), ('DELETE', '/ente/usuario/unbind'))
ON CONFLICT (endpoint_id, role_id) DO NOTHING;
