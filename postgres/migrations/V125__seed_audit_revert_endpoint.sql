-- V125 — registra en el catálogo el endpoint `POST /audit/revert`
-- (AuditRevertController, sso-admin). Se agregó en la rama de fase 1
-- de V-audit-revert pero nunca se sembró en `endpoint`/`role_endpoint`
-- — sin esta fila, SsoAdminAccessManager responde 403 a TODO el
-- mundo, ADMIN incluido — la autorización en sso-admin es
-- per-endpoint vía `endpoint` + `role_endpoint`, sin bypass alguno
-- para ningún rol (ver su javadoc). Mismo patrón que V82 sembró para
-- /microservice/{id}/container/recreate.

INSERT INTO endpoint (method, path, description, numberparams)
VALUES ('POST', '/audit/revert',
        'Revertir un cambio de auditoría visto en ClickHouse (INSERT/UPDATE)', 1)
ON CONFLICT (path, method, description) DO NOTHING;

INSERT INTO role_endpoint (endpoint_id, role_id)
SELECT e.id_endpoint, r.id_role
FROM endpoint e
CROSS JOIN role r
WHERE r.name = 'ADMIN'
  AND (e.method, e.path) = ('POST', '/audit/revert')
ON CONFLICT (endpoint_id, role_id) DO NOTHING;
