-- ===========================================================================
-- V306 - role_endpoint: se mapea el estado del servidor de pruebas que
--        ninguna migracion garantizaba.
--
-- POR QUE ESTA MIGRACION EXISTE
--   role_endpoint decide dos cosas distintas segun el servicio que lo lea:
--   que endpoints de sso-admin / auth-center puede llamar un rol, y -- en
--   file-service -- quien tiene el privilegio de ver CUALQUIER archivo sin
--   pasar por el chequeo de propiedad (ver FileAccessService y la cabecera
--   de V63). En los dos casos es configuracion de seguridad, y hasta ahora
--   vivia casi entera fuera de Flyway.
--
--   Medicion: se aplicaron las 254 migraciones del repo sobre una base
--   limpia -- lo mismo que hace el job flyway-migrations -- y se comparo el
--   resultado con el servidor de pruebas, que es el entorno funcional:
--
--       role_endpoint que el repo garantiza .....  26
--       role_endpoint en el servidor de pruebas .. 209
--       -------------------------------------------------
--       sin respaldo en ninguna migracion ........ 175
--
--   Es decir, el 84% de la configuracion de role_endpoint solo existia
--   porque alguien la inserto a mano en cada entorno. Una base reconstruida
--   desde cero nacia con 26 filas y sin forma de saber que le faltaba.
--
--   Reparto de las 175 que se reponen aqui:
--
--     CEVAL-ACUDIENTE                          1
--     CEVAL-AUXILIAR_ADMINISTRATIVO            3
--     CEVAL-COORDINADOR                        1
--     CEVAL-DIRECTOR_ENTE_TERRITORIAL          8
--     CEVAL-DOCENTE                            2
--     CEVAL-ESTUDIANTE                         1
--     CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL      8
--     CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO       7
--     CEVAL-RECTOR                             7
--     CEVAL-SUPER_ADMINISTRADOR                3
--     PIGSE-ADMINISTRADOR                      1
--     PIGSE-AUXILIAR_ADMINISTRATIVO            1
--     PIGSE-DIRECTOR_ENTE_TERRITORIAL          1
--     PIGSE-JEFE_AREA_CALIDAD                  1
--     PIGSE-JEFE_AREA_COBERTURA                1
--     PIGSE-JEFE_AREA_PLANEACION               1
--     PIGSE-JEFE_SISTEMA_ENTE_TERRITORIAL      1
--     PIGSE-JEFE_SISTEMA_ESTABLECIMIENTO       1
--     PIGSE-RECTOR                             2
--     PIGSE-SECRETARIA_TERRITORIAL             1
--     PIGSE-SECRETARIO                         1
--     SSO-ADMIN                              122
--
--   SSO-ADMIN se lleva 122 de las 175, y no es casualidad: es el rol que las
--   migraciones nombran como 'SSO-ADMIN' literal, que en produccion se llama
--   'ADMIN' -- el mismo no-op silencioso que dejo a los funcionarios sin
--   permisos y que V305 documenta.
--
-- QUE NO ENTRA AQUI, A PROPOSITO
--   El servidor de PRODUCCION tiene ademas 20 pares que el de pruebas NO
--   tiene, y NO se incluyen. No son ruido: conceden a CEVAL-DOCENTE,
--   CEVAL-COORDINADOR, CEVAL-PSICO_ORIENTADOR y CEVAL-AUXILIAR_ADMINISTRATIVO
--   el binding de lectura privilegiada de archivos, que segun V63 significa
--   "ve CUALQUIER archivo, sin importar de quien sea". V63 excluyo
--   explicitamente a CEVAL-AUXILIAR_ADMINISTRATIVO por ser "un rol operativo
--   / de captura, no de supervision", y alguien se lo concedio igualmente a
--   mano en produccion.
--
--   Replicar eso seria propagar una ampliacion de privilegios que ninguna
--   migracion respalda. Queda documentado para decidirse aparte; esta
--   migracion solo fija el estado del entorno que funciona.
--
-- EMPAREJAMIENTO
--   Por (method, path) del endpoint y por nombre de rol, nunca por id: los
--   id_endpoint / id_role no son estables entre entornos. La CTE de alias
--   hace que 'SSO-ADMIN' encuentre tambien al rol 'ADMIN' (y SSO-USER a
--   USER), que es lo que evita repetir el no-op de siempre.
--
-- IDEMPOTENTE
--   ON CONFLICT DO NOTHING. En un entorno ya completo no inserta nada.
-- ===========================================================================

CREATE TEMP VIEW v306_roles AS
    SELECT id_role, name FROM public.role
    UNION ALL SELECT id_role, 'SSO-ADMIN' FROM public.role WHERE name = 'ADMIN'
    UNION ALL SELECT id_role, 'SSO-USER'  FROM public.role WHERE name = 'USER'
    UNION ALL SELECT id_role, 'ADMIN'     FROM public.role WHERE name = 'SSO-ADMIN'
    UNION ALL SELECT id_role, 'USER'      FROM public.role WHERE name = 'SSO-USER';

INSERT INTO public.role_endpoint (role_id, endpoint_id)
SELECT DISTINCT r.id_role, e.id_endpoint
  FROM (VALUES
            ('CEVAL-ACUDIENTE', 'PUT', '/files/**'),
            ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'PATCH', '/files/**'),
            ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'POST', '/files/**'),
            ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'POST', '/register/usuario'),
            ('CEVAL-COORDINADOR', 'POST', '/files/**'),
            ('CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'GET', '/files/download/{archivoId}'),
            ('CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'GET', '/files/view/{archivoId}'),
            ('CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'PATCH', '/files/**'),
            ('CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'POST', '/files/**'),
            ('CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'POST', '/files/view-token/{archivoId}'),
            ('CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'POST', '/register/funcionario'),
            ('CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'POST', '/register/usuario'),
            ('CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'PUT', '/files/**'),
            ('CEVAL-DOCENTE', 'POST', '/files/**'),
            ('CEVAL-DOCENTE', 'PUT', '/files/**'),
            ('CEVAL-ESTUDIANTE', 'POST', '/files/**'),
            ('CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'GET', '/files/download/{archivoId}'),
            ('CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'GET', '/files/view/{archivoId}'),
            ('CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'PATCH', '/files/**'),
            ('CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'POST', '/files/**'),
            ('CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'POST', '/files/view-token/{archivoId}'),
            ('CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'POST', '/register/funcionario'),
            ('CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'POST', '/register/usuario'),
            ('CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'PUT', '/files/**'),
            ('CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'GET', '/files/download/{archivoId}'),
            ('CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'GET', '/files/view/{archivoId}'),
            ('CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'PATCH', '/files/**'),
            ('CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'POST', '/files/**'),
            ('CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'POST', '/files/view-token/{archivoId}'),
            ('CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'POST', '/register/funcionario'),
            ('CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'POST', '/register/usuario'),
            ('CEVAL-RECTOR', 'GET', '/files/download/{archivoId}'),
            ('CEVAL-RECTOR', 'PATCH', '/files/**'),
            ('CEVAL-RECTOR', 'POST', '/files/**'),
            ('CEVAL-RECTOR', 'POST', '/files/view-token/{archivoId}'),
            ('CEVAL-RECTOR', 'POST', '/register/funcionario'),
            ('CEVAL-RECTOR', 'POST', '/register/usuario'),
            ('CEVAL-RECTOR', 'PUT', '/files/**'),
            ('CEVAL-SUPER_ADMINISTRADOR', 'POST', '/register/funcionario'),
            ('CEVAL-SUPER_ADMINISTRADOR', 'POST', '/register/usuario'),
            ('CEVAL-SUPER_ADMINISTRADOR', 'PUT', '/files/**'),
            ('PIGSE-ADMINISTRADOR', 'POST', '/files/view-token/{archivoId}'),
            ('PIGSE-AUXILIAR_ADMINISTRATIVO', 'POST', '/files/view-token/{archivoId}'),
            ('PIGSE-DIRECTOR_ENTE_TERRITORIAL', 'POST', '/files/view-token/{archivoId}'),
            ('PIGSE-JEFE_AREA_CALIDAD', 'POST', '/files/view-token/{archivoId}'),
            ('PIGSE-JEFE_AREA_COBERTURA', 'POST', '/files/view-token/{archivoId}'),
            ('PIGSE-JEFE_AREA_PLANEACION', 'POST', '/files/view-token/{archivoId}'),
            ('PIGSE-JEFE_SISTEMA_ENTE_TERRITORIAL', 'POST', '/files/view-token/{archivoId}'),
            ('PIGSE-JEFE_SISTEMA_ESTABLECIMIENTO', 'POST', '/files/view-token/{archivoId}'),
            ('PIGSE-RECTOR', 'POST', '/files/view-token/{archivoId}'),
            ('PIGSE-RECTOR', 'PUT', '/files/**'),
            ('PIGSE-SECRETARIA_TERRITORIAL', 'POST', '/files/view-token/{archivoId}'),
            ('PIGSE-SECRETARIO', 'POST', '/files/view-token/{archivoId}'),
            ('SSO-ADMIN', 'DELETE', '/app/{id}'),
            ('SSO-ADMIN', 'DELETE', '/app/{id}/microservice/{microserviceId}'),
            ('SSO-ADMIN', 'DELETE', '/app/{id}/role/{roleId}'),
            ('SSO-ADMIN', 'DELETE', '/app/{id}/route/{routeId}'),
            ('SSO-ADMIN', 'DELETE', '/app/{id}/user/{userId}'),
            ('SSO-ADMIN', 'DELETE', '/endpoint/{id}'),
            ('SSO-ADMIN', 'DELETE', '/endpoint/{id}/microservice/{microserviceId}'),
            ('SSO-ADMIN', 'DELETE', '/endpoint/{id}/role/{roleId}'),
            ('SSO-ADMIN', 'DELETE', '/ente/usuario/unbind'),
            ('SSO-ADMIN', 'DELETE', '/group/{id}/role/{roleId}'),
            ('SSO-ADMIN', 'DELETE', '/microservice/{id}'),
            ('SSO-ADMIN', 'DELETE', '/query/{id}'),
            ('SSO-ADMIN', 'DELETE', '/query/{id}/role/{roleId}'),
            ('SSO-ADMIN', 'DELETE', '/route/{id}'),
            ('SSO-ADMIN', 'DELETE', '/route/{id}/role/{roleId}'),
            ('SSO-ADMIN', 'DELETE', '/unbindUserRole'),
            ('SSO-ADMIN', 'DELETE', '/write/{id}'),
            ('SSO-ADMIN', 'DELETE', '/write/{id}/role/{roleId}'),
            ('SSO-ADMIN', 'GET', '/'),
            ('SSO-ADMIN', 'GET', '/app/getApps'),
            ('SSO-ADMIN', 'GET', '/app/{id}'),
            ('SSO-ADMIN', 'GET', '/app/{id}/microservices/checked'),
            ('SSO-ADMIN', 'GET', '/app/{id}/roles/checked'),
            ('SSO-ADMIN', 'GET', '/app/{id}/routes/checked'),
            ('SSO-ADMIN', 'GET', '/app/{id}/users/checked'),
            ('SSO-ADMIN', 'GET', '/endpoint/bySignature'),
            ('SSO-ADMIN', 'GET', '/endpoint/getEndpoints'),
            ('SSO-ADMIN', 'GET', '/endpoint/{id}'),
            ('SSO-ADMIN', 'GET', '/endpoint/{id}/microservices/checked'),
            ('SSO-ADMIN', 'GET', '/endpoint/{id}/roles/checked'),
            ('SSO-ADMIN', 'GET', '/ente/listar'),
            ('SSO-ADMIN', 'GET', '/ente/roles'),
            ('SSO-ADMIN', 'GET', '/file-references/{pkTarchivo}'),
            ('SSO-ADMIN', 'GET', '/files/download/{archivoId}'),
            ('SSO-ADMIN', 'GET', '/files/view/{archivoId}'),
            ('SSO-ADMIN', 'GET', '/forgotPassword'),
            ('SSO-ADMIN', 'GET', '/getApiToken'),
            ('SSO-ADMIN', 'GET', '/getInfoUser'),
            ('SSO-ADMIN', 'GET', '/getQuery'),
            ('SSO-ADMIN', 'GET', '/getRolesByEmail'),
            ('SSO-ADMIN', 'GET', '/getUsers'),
            ('SSO-ADMIN', 'GET', '/getUsersSSO'),
            ('SSO-ADMIN', 'GET', '/getWrite'),
            ('SSO-ADMIN', 'GET', '/group'),
            ('SSO-ADMIN', 'GET', '/group/{id}/roles/checked'),
            ('SSO-ADMIN', 'GET', '/microservice/getMicroservice'),
            ('SSO-ADMIN', 'GET', '/microservice/getMicroservices'),
            ('SSO-ADMIN', 'GET', '/microservice/{id}'),
            ('SSO-ADMIN', 'GET', '/microservice/{id}/container/logs'),
            ('SSO-ADMIN', 'GET', '/microservice/{id}/container/status'),
            ('SSO-ADMIN', 'GET', '/myApps'),
            ('SSO-ADMIN', 'GET', '/myMenu'),
            ('SSO-ADMIN', 'GET', '/myQueries'),
            ('SSO-ADMIN', 'GET', '/query/byUuid'),
            ('SSO-ADMIN', 'GET', '/query/getQueries'),
            ('SSO-ADMIN', 'GET', '/query/param-types'),
            ('SSO-ADMIN', 'GET', '/query/{id}'),
            ('SSO-ADMIN', 'GET', '/query/{id}/roles/checked'),
            ('SSO-ADMIN', 'GET', '/role/getRoles'),
            ('SSO-ADMIN', 'GET', '/role/getRolesOwn'),
            ('SSO-ADMIN', 'GET', '/role/users'),
            ('SSO-ADMIN', 'GET', '/role/users/checked'),
            ('SSO-ADMIN', 'GET', '/route/getRoutes'),
            ('SSO-ADMIN', 'GET', '/route/getRoutesByParent'),
            ('SSO-ADMIN', 'GET', '/route/{id}'),
            ('SSO-ADMIN', 'GET', '/route/{id}/roles/checked'),
            ('SSO-ADMIN', 'GET', '/user/roles'),
            ('SSO-ADMIN', 'GET', '/write/byUuid'),
            ('SSO-ADMIN', 'GET', '/write/getWrites'),
            ('SSO-ADMIN', 'GET', '/write/{id}'),
            ('SSO-ADMIN', 'GET', '/write/{id}/roles/checked'),
            ('SSO-ADMIN', 'PATCH', '/files/**'),
            ('SSO-ADMIN', 'POST', '/activateAccount'),
            ('SSO-ADMIN', 'POST', '/app/save'),
            ('SSO-ADMIN', 'POST', '/app/{id}/microservice/{microserviceId}'),
            ('SSO-ADMIN', 'POST', '/app/{id}/role/{roleId}'),
            ('SSO-ADMIN', 'POST', '/app/{id}/route/{routeId}'),
            ('SSO-ADMIN', 'POST', '/app/{id}/user/{userId}'),
            ('SSO-ADMIN', 'POST', '/audit/revert'),
            ('SSO-ADMIN', 'POST', '/auth/logout'),
            ('SSO-ADMIN', 'POST', '/auth/refresh'),
            ('SSO-ADMIN', 'POST', '/bindUserRole'),
            ('SSO-ADMIN', 'POST', '/createAccount'),
            ('SSO-ADMIN', 'POST', '/deactivateAccount/{id}'),
            ('SSO-ADMIN', 'POST', '/endpoint/save'),
            ('SSO-ADMIN', 'POST', '/endpoint/{id}/microservice/{microserviceId}'),
            ('SSO-ADMIN', 'POST', '/endpoint/{id}/role/{roleId}'),
            ('SSO-ADMIN', 'POST', '/ente/usuario/bind'),
            ('SSO-ADMIN', 'POST', '/files/**'),
            ('SSO-ADMIN', 'POST', '/files/view-token/{archivoId}'),
            ('SSO-ADMIN', 'POST', '/googleLogin'),
            ('SSO-ADMIN', 'POST', '/group'),
            ('SSO-ADMIN', 'POST', '/group/bindUserGroup'),
            ('SSO-ADMIN', 'POST', '/group/{id}/role/{roleId}'),
            ('SSO-ADMIN', 'POST', '/login'),
            ('SSO-ADMIN', 'POST', '/microservice/save'),
            ('SSO-ADMIN', 'POST', '/microservice/testConnection'),
            ('SSO-ADMIN', 'POST', '/microservice/{id}/container/recreate'),
            ('SSO-ADMIN', 'POST', '/microservice/{id}/container/restart'),
            ('SSO-ADMIN', 'POST', '/query/save'),
            ('SSO-ADMIN', 'POST', '/query/{id}/role/{roleId}'),
            ('SSO-ADMIN', 'POST', '/reactivateAccount/{id}'),
            ('SSO-ADMIN', 'POST', '/register/funcionario'),
            ('SSO-ADMIN', 'POST', '/register/usuario'),
            ('SSO-ADMIN', 'POST', '/resendActivation/{id}'),
            ('SSO-ADMIN', 'POST', '/restorePassword'),
            ('SSO-ADMIN', 'POST', '/role/createRole'),
            ('SSO-ADMIN', 'POST', '/route/save'),
            ('SSO-ADMIN', 'POST', '/route/{id}/role/{roleId}'),
            ('SSO-ADMIN', 'POST', '/write/save'),
            ('SSO-ADMIN', 'POST', '/write/{id}/role/{roleId}'),
            ('SSO-ADMIN', 'PUT', '/app/update'),
            ('SSO-ADMIN', 'PUT', '/endpoint/update'),
            ('SSO-ADMIN', 'PUT', '/file-references/{pkTarchivo}'),
            ('SSO-ADMIN', 'PUT', '/files/**'),
            ('SSO-ADMIN', 'PUT', '/group/update'),
            ('SSO-ADMIN', 'PUT', '/microservice/update'),
            ('SSO-ADMIN', 'PUT', '/query/update'),
            ('SSO-ADMIN', 'PUT', '/role/updateRole'),
            ('SSO-ADMIN', 'PUT', '/route/update'),
            ('SSO-ADMIN', 'PUT', '/updateAccount'),
            ('SSO-ADMIN', 'PUT', '/write/update')
       ) AS d(rol, metodo, ruta)
  JOIN v306_roles r      ON r.name = d.rol
  JOIN public.endpoint e ON e.path = d.ruta
                        AND coalesce(e.method, '-') = d.metodo
ON CONFLICT DO NOTHING;

DO $$
DECLARE
    v_total BIGINT;
    v_admin BIGINT;
BEGIN
    SELECT count(*) INTO v_total FROM public.role_endpoint;
    SELECT count(*) INTO v_admin
      FROM public.role_endpoint re
      JOIN public.role r ON r.id_role = re.role_id
     WHERE r.name IN ('SSO-ADMIN', 'ADMIN');

    RAISE NOTICE 'V306: role_endpoint total=% (rol administrador=%)', v_total, v_admin;

    IF v_admin < 100 THEN
        RAISE WARNING 'V306: el rol administrador quedo con % endpoints, se esperaban ~122. Revisa como se llama en public.role.', v_admin;
    END IF;
END $$;

DROP VIEW v306_roles;
