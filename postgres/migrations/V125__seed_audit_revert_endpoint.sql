-- V125 — registra en el catálogo el endpoint `POST /audit/revert`
-- (AuditRevertController, sso-admin). Se agregó en la rama de fase 1
-- de V-audit-revert pero nunca se sembró en `endpoint`/`role_endpoint`
-- — sin esta fila, SsoAdminAccessManager responde 403 a TODO el
-- mundo, ADMIN incluido — la autorización en sso-admin es
-- per-endpoint vía `endpoint` + `role_endpoint`, sin bypass alguno
-- para ningún rol (ver su javadoc). Mismo patrón que V82 sembró para
-- /microservice/{id}/container/recreate.
--
-- El rol otorgado es CEVAL-SUPER_ADMINISTRADOR, NO ADMIN genérico —
-- deliberado, tal como ya advertía el javadoc de
-- AuditRevertController desde fase 1 ("esa asignación de rol
-- debería quedar MUY restringida"): revertir un cambio de auditoría
-- es una operación destructiva que reescribe datos de producción, y
-- el mismo nivel de privilegio "supervisión/superadmin" que V87 le
-- dio a la lectura del historial completo de auditoría
-- (bind_audit_clickhouse_queries_to_super_admin) es el que le
-- corresponde a poder revertirlo.
--
-- SsoAdminAccessManager exige DOS gates, no solo role_endpoint:
-- role_app (CEVAL-SUPER_ADMINISTRADOR -> SSO-ADMIN) Y role_endpoint
-- (CEVAL-SUPER_ADMINISTRADOR -> POST /audit/revert). CEVAL-* se
-- namespacea a COLOMBIA-EVALUADORA por convención (V36) y nunca tuvo
-- binding a SSO-ADMIN — se agrega aquí, pero como
-- SsoAdminAccessManager exige AMBOS gates, ese role_app por sí solo
-- no abre nada más: el rol solo gana acceso a los endpoints de
-- SSO-ADMIN que además tengan su propia fila role_endpoint (hoy,
-- únicamente este).

INSERT INTO endpoint (method, path, description, numberparams)
VALUES ('POST', '/audit/revert',
        'Revertir un cambio de auditoría visto en ClickHouse (INSERT/UPDATE)', 1)
ON CONFLICT (path, method, description) DO NOTHING;

INSERT INTO role_app (id_app, id_role)
SELECT a.id_app, r.id_role
FROM app a
CROSS JOIN role r
WHERE a.name = 'SSO-ADMIN'
  AND r.name = 'CEVAL-SUPER_ADMINISTRADOR'
ON CONFLICT DO NOTHING;

INSERT INTO role_endpoint (endpoint_id, role_id)
SELECT e.id_endpoint, r.id_role
FROM endpoint e
CROSS JOIN role r
WHERE r.name = 'CEVAL-SUPER_ADMINISTRADOR'
  AND (e.method, e.path) = ('POST', '/audit/revert')
ON CONFLICT (endpoint_id, role_id) DO NOTHING;
