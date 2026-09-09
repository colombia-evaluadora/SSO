-- ===========================================================================
-- V126 - registro en public.query (+ role_query) de los endpoints de
--        query-service de CRUD de menus y listado de roles sobre TROL (V113).
--
-- POR QUE ESTA MIGRACION EXISTE
--   Estas filas NUNCA estuvieron en Flyway: llegaron al servidor de test por
--   el dump base o por INSERT aplicados a mano (en V51/V52 quedaron incluso
--   escritos pero COMENTADOS). Consecuencias reales del hueco:
--     a) sobre una base limpia el modulo no expone NINGUN endpoint;
--     b) las migraciones posteriores que solo hacen UPDATE sobre estas filas
--        (V64/V67/V68/V69/V116/V117/V124/V130/V131/V135/...) se vuelven
--        no-ops silenciosos porque la fila que buscan no existe.
--   Esta migracion documenta el catalogo real y cierra ese hueco.
--
-- CONTENIDO
--   Volcado literal del catalogo vivo en el servidor de test (public.query),
--   uuid INCLUIDO: varias migraciones posteriores localizan estas filas por
--   uuid (p.ej. V135), asi que conservarlo es obligatorio, no cosmetico.
--   El texto volcado ya refleja los UPDATE de las migraciones < V126, que
--   sobre base limpia corren antes y no encuentran fila: el estado final es
--   el mismo por ambos caminos.
--
-- NUMERACION
--   Hueco libre V126, verificado contra TODAS las ramas de origin. Se eligio
--   por encima de las migraciones que definen las funciones invocadas (V113)
--   y por debajo de las que actualizan estas mismas filas. Flyway corre con
--   -outOfOrder=true (docker-compose.yml), asi que los entornos ya migrados la
--   aplican sin conflicto; ahi los INSERT son no-ops por el ON CONFLICT.
--
-- REQUISITO PREVIO
--   V47 registra el microservicio 'eval-col'. Sin esa fila estos INSERT no
--   insertan nada (el SELECT origen no devuelve filas).
--
-- ROLES
--   role_query decide que roles de public.role pueden llamar al endpoint por
--   el gateway; NO sustituye el gate de capability/scope que hace cada funcion
--   por dentro, y NO tiene bypass de admin. Los roles se resuelven por nombre:
--   si un entorno todavia no tiene sincronizado alguno (V111), ese rol no se
--   inserta y el resto si.
--
-- CAVEAT DE RECARGA
--   Una fila nueva en public.query da 404 por el gateway hasta que el
--   contenedor query-service-eval-col se reinicia.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. POST /menus  ->  fn_upsert_menu
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'eval-col-menus-create-001',
    'SELECT pk_tmenu       AS id,
       pk_padre       AS "idParent",
       nombre         AS name,
       path,
       icono          AS icon,
       visible,
       orden          AS "menuOrder",
       plan_id        AS "planId",
       type
  FROM academico_test.fn_upsert_menu(
       :CONTEXT.USER_ID::BIGINT,
       CAST(:BODY.NAME AS VARCHAR),
       :CONTEXT.EMAIL,
       CAST(:BODY.PATH AS VARCHAR),
       CAST(:BODY.ICON AS VARCHAR),
       CASE WHEN CAST(:BODY.VISIBLE AS BOOLEAN) IS NOT FALSE THEN ''S'' ELSE ''N'' END,
       NULL,
       CAST(:BODY.PLANID AS BIGINT),
       CAST(:BODY.IDPARENT AS BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/menus', 'SELECT', 'POST',
    '{"BODY.ICON": "VARCHAR", "BODY.NAME": "VARCHAR", "BODY.PATH": "VARCHAR", "BODY.PLANID": "BIGINT", "BODY.VISIBLE": "BOOLEAN", "BODY.IDPARENT": "BIGINT"}'::jsonb,
    NULL,
    'roles-permisos: crea un menu (raiz si idParent=null, submenu si idParent=<pk existente>).',
    'menus-create', NULL,
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/menus'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. PATCH /menus/:ID  ->  fn_upsert_menu
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'eval-col-menus-update-001',
    'SELECT pk_tmenu       AS id,
       pk_padre       AS "idParent",
       nombre         AS name,
       path,
       icono          AS icon,
       visible,
       orden          AS "menuOrder",
       plan_id        AS "planId",
       type
  FROM academico_test.fn_upsert_menu(
       :CONTEXT.USER_ID::BIGINT,
       CAST(:BODY.NAME AS VARCHAR),
       :CONTEXT.EMAIL,
       CAST(:BODY.PATH AS VARCHAR),
       CAST(:BODY.ICON AS VARCHAR),
       CASE WHEN CAST(:BODY.VISIBLE AS BOOLEAN) IS NOT FALSE THEN ''S'' ELSE ''N'' END,
       NULL,
       CAST(:BODY.PLANID AS BIGINT),
       CAST(:BODY.IDPARENT AS BIGINT),
       CAST(:PARAM.ID AS BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/menus/:ID', 'SELECT', 'PATCH',
    '{"PARAM.ID": "BIGINT", "BODY.ICON": "VARCHAR", "BODY.NAME": "VARCHAR", "BODY.PATH": "VARCHAR", "BODY.PLANID": "BIGINT", "BODY.VISIBLE": "BOOLEAN", "BODY.IDPARENT": "BIGINT"}'::jsonb,
    NULL,
    'roles-permisos: edita un menu existente. idParent distinto al actual reparenta.',
    'menus-update', NULL,
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/menus/:ID'
   AND q.http_method   = 'PATCH'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3. PUT /menus/:ID/eliminar  ->  fn_delete_menu
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'eval-col-menus-delete-001',
    'SELECT CASE WHEN was_deleted THEN ''success'' ELSE ''error'' END AS status,
            CASE WHEN was_deleted THEN ''Menu eliminado'' ELSE ''El menu no existia o ya estaba eliminado'' END AS message
       FROM academico_test.fn_delete_menu(
           :CONTEXT.USER_ID::BIGINT,
           CAST(:PARAM.ID AS BIGINT)
       );',
    'postgres', false, false,
    m.id_microservice,
    '/menus/:ID/eliminar', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    NULL,
    'roles-permisos: soft-delete en cascada de un menu. Via PUT porque el catalogo QUERY no admite DELETE.',
    'menus-delete', NULL,
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/menus/:ID/eliminar'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 4. PUT /menus/order  ->  fn_reorder_menus
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'eval-col-menus-order-001',
    'SELECT pk_tmenu, orden
       FROM academico_test.fn_reorder_menus(
           :CONTEXT.USER_ID::BIGINT,
           CAST(:BODY_RAW.ITEMS AS JSONB)
       );',
    'postgres', false, false,
    m.id_microservice,
    '/menus/order', 'SELECT', 'PUT',
    '{"BODY.ITEMS": "JSONB", "BODY_RAW.ITEMS": "JSONB"}'::jsonb,
    NULL,
    'roles-permisos: reordena menus entre hermanos. Atomico.',
    'menus-order', NULL,
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/menus/order'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 5. GET /roles  ->  fn_list_roles
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'eval-col-roles-list-001',
    'SELECT id, name
       FROM academico_test.fn_list_roles(:CONTEXT.USER_ID::BIGINT);',
    'postgres', false, false,
    m.id_microservice,
    '/roles', 'SELECT', 'GET',
    '{}'::jsonb,
    NULL,
    'roles-permisos: lista de roles academicos (RoleDto[]) para el select "Rol" de Configuracion de roles y menus.',
    'roles-list', NULL,
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/roles'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;
