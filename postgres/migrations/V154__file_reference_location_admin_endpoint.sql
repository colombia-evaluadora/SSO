-- V-file-reference-admin — registra en el catálogo los 2 endpoints
-- de FileReferenceLocationController (sso-admin) -- sin esta fila,
-- SsoAdminAccessManager responde 403 a TODO el mundo (autorización
-- per-endpoint vía endpoint+role_endpoint, sin bypass para ningún
-- rol -- mismo patrón que V125/V153 sembraron antes).
--
-- Gateado al rol "admin de sso-admin" genérico, igual que V153: dar
-- de alta o corregir una fila de public.file_reference_location es
-- una operación administrativa de catálogo, no destructiva.
--
-- ('ADMIN', 'SSO-ADMIN'): el nombre de ese rol difiere entre entornos
-- -- el catálogo local de bootstrap usa 'ADMIN', el servidor real usa
-- 'SSO-ADMIN' (mismo hallazgo que V153, confirmado contra
-- 172.233.184.248).
--
-- También agrega la entrada de sidebar '/admin/file-references'
-- (ROUTE + ROLE_ROUTE), siguiendo el mismo patrón que V9 sembró para
-- el resto de pantallas de sso-admin -- el sidebar es 100% dirigido
-- por datos (GET /sso-admin/myMenu), así que sin esta fila la
-- pantalla nueva del admin-ui es alcanzable sólo tecleando la URL.

INSERT INTO endpoint (method, path, description, numberparams) VALUES
    ('GET', '/file-references/{pkTarchivo}', 'Ver la ubicación registrada de un pk_tarchivo', 1),
    ('PUT', '/file-references/{pkTarchivo}', 'Crear o corregir la ubicación de un pk_tarchivo', 3)
ON CONFLICT (path, method, description) DO NOTHING;

INSERT INTO role_app (id_app, id_role)
SELECT a.id_app, r.id_role
  FROM app a CROSS JOIN role r
 WHERE a.name = 'SSO-ADMIN' AND r.name IN ('ADMIN', 'SSO-ADMIN')
ON CONFLICT DO NOTHING;

INSERT INTO role_endpoint (endpoint_id, role_id)
SELECT e.id_endpoint, r.id_role
  FROM endpoint e
 CROSS JOIN role r
 WHERE r.name IN ('ADMIN', 'SSO-ADMIN')
   AND (e.method, e.path) IN (
       ('GET', '/file-references/{pkTarchivo}'),
       ('PUT', '/file-references/{pkTarchivo}'))
ON CONFLICT (endpoint_id, role_id) DO NOTHING;

INSERT INTO route (name, icon, path, menuorder, type, idparent)
SELECT 'Referencias de archivo', 'database', '/admin/file-references', 13, NULL, NULL
 WHERE NOT EXISTS (SELECT 1 FROM route WHERE path = '/admin/file-references');

INSERT INTO role_route (role_id, route_id)
SELECT r.id_role, ro.id_route
  FROM role r CROSS JOIN route ro
 WHERE r.name IN ('ADMIN', 'SSO-ADMIN')
   AND ro.path = '/admin/file-references'
ON CONFLICT (role_id, route_id) DO NOTHING;
