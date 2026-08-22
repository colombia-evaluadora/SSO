-- V82 — registra en el catálogo el endpoint nuevo
-- `POST /microservice/{id}/container/recreate` (borra + vuelve a
-- crear el contenedor con la imagen query-service actual, a
-- diferencia de /container/restart que reutiliza el filesystem
-- viejo — ver MicroserviceService.recreateContainer).
--
-- Sin esta fila, SsoAdminAccessManager responde 403 a TODO el mundo,
-- ADMIN incluido — la autorización en sso-admin es per-endpoint vía
-- `endpoint` + `role_endpoint`, sin bypass alguno para ningún rol
-- (ver su javadoc). Mismo patrón que V15 sembró para los otros tres
-- endpoints de /container/**.

INSERT INTO endpoint (method, path, description, numberparams)
VALUES ('POST', '/microservice/{id}/container/recreate',
        'Recrear contenedor (borrar + crear con la imagen actual)', 1)
ON CONFLICT (path, method, description) DO NOTHING;

INSERT INTO role_endpoint (endpoint_id, role_id)
SELECT e.id_endpoint, r.id_role
FROM endpoint e
CROSS JOIN role r
WHERE r.name = 'ADMIN'
  AND (e.method, e.path) = ('POST', '/microservice/{id}/container/recreate')
ON CONFLICT (endpoint_id, role_id) DO NOTHING;
