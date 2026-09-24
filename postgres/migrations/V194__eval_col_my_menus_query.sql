-- ===========================================================================
-- V194 - registra en public.query la ruta GET /my-menus del microservicio
--        eval-col (sidebar de Colombia Evaluadora) y la vincula a los
--        roles CEVAL-* + ADMIN/USER.
--
-- POR QUE ESTA MIGRACION EXISTE
--   V193 trajo academico_test.fn_list_my_menus (la funcion PL/pgSQL) y
--   sembro academico_test.trol_menu, pero el catalogo dinamico de
--   query-service (public.query) NUNCA tuvo la fila para GET /my-menus
--   en el microservicio eval-col -- solo pigse la tenia. Sin esta fila,
--   GET /api/eval-col/my-menus responde 404 "No query registered for
--   path: /my-menus" para cualquier usuario, sin importar rol ni
--   permisos: el catalogo mismo no conoce la ruta.
--
--   Copiada de testv2 (el servidor de test), query uuid 'eval-col-my-menus-001'
--   (id_query=135 alla), verificada campo a campo.
--
-- ROLES
--   testv2 la vincula a los 16 roles CEVAL-* + 'SSO-ADMIN' + 'SSO-USER'.
--   Este servidor no tiene roles con esos dos nombres -- sus equivalentes
--   son 'ADMIN' y 'USER' (mismo proposito, nombre distinto). Se vincula
--   a esos dos en su lugar, mas los 16 CEVAL-* (idénticos en ambos
--   entornos).
--
-- NUMERACION
--   Hueco libre V194, verificado contra TODAS las ramas de origin. Va
--   despues de V193 (que crea la funcion que esta query invoca).
-- ===========================================================================

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, detail, microservice_id,
     path_template, execution_mode, http_method, param_types, cacheable,
     cache_ttl_seconds, createddate)
SELECT
    'eval-col-my-menus-001',
    'SELECT pk_tmenu       AS id,
            pk_padre       AS "idParent",
            nombre         AS name,
            url            AS path,
            icono          AS icon,
            visible,
            orden          AS "menuOrder",
            plan_id        AS "planId",
            type
       FROM academico_test.fn_list_my_menus(:CONTEXT.USER_ID::BIGINT);',
    'postgres', FALSE, FALSE,
    'Menus del usuario autenticado (cruza trol_menu con los roles del JWT). Alimenta el sidebar del front.',
    m.id_microservice, '/my-menus', 'SELECT', 'GET', '{}'::jsonb, FALSE, 60, CURRENT_TIMESTAMP
FROM public.microservice m
WHERE m.serviceid = 'eval-col'
  AND NOT EXISTS (
      SELECT 1 FROM public.query q2
       WHERE q2.microservice_id = m.id_microservice AND q2.path_template = '/my-menus'
  );

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
FROM public.query q
JOIN public.microservice m ON m.id_microservice = q.microservice_id
JOIN public.role r ON r.name IN (
    'ADMIN', 'USER',
    'CEVAL-SUPER_ADMINISTRADOR', 'CEVAL-DIRECTOR_ENTE_TERRITORIAL',
    'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-JEFE_AREA_PLANEACION',
    'CEVAL-JEFE_AREA_COBERTURA', 'CEVAL-JEFE_AREA_CALIDAD', 'CEVAL-RECTOR',
    'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-AUXILIAR_ADMINISTRATIVO',
    'CEVAL-PSICO_ORIENTADOR', 'CEVAL-COORDINADOR', 'CEVAL-JEFE_AREA',
    'CEVAL-DIRECTOR_GRUPO', 'CEVAL-DOCENTE', 'CEVAL-ESTUDIANTE', 'CEVAL-ACUDIENTE'
)
WHERE m.serviceid = 'eval-col'
  AND q.path_template = '/my-menus'
  AND NOT EXISTS (
      SELECT 1 FROM public.role_query rq
       WHERE rq.role_id = r.id_role AND rq.query_id = q.id_query
  );
