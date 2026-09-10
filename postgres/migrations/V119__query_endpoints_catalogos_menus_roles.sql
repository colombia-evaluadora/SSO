-- ===========================================================================
-- V119 - registro en public.query (+ role_query) de los endpoints de
--        query-service de catalogos especificos, menus, roles y planes (V58, V59).
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
--   El texto volcado ya refleja los UPDATE de las migraciones < V119, que
--   sobre base limpia corren antes y no encuentran fila: el estado final es
--   el mismo por ambos caminos.
--
-- NUMERACION
--   Hueco libre V119, verificado contra TODAS las ramas de origin. Se eligio
--   por encima de las migraciones que definen las funciones invocadas (V58, V59)
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
-- 1. GET /catalogos/discapacidades  ->  fn_cat_discapacidades_listar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'eval-col-catalogos-discapacidades-001',
    'SELECT * FROM academico_test.fn_cat_discapacidades_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/catalogos/discapacidades', 'SELECT', 'GET',
    '{}'::jsonb,
    NULL,
    'Catalogo de tipos de discapacidad activos, para el select correspondiente del formulario de establecimiento.',
    'catalogos-discapacidades', 'DEFAULT',
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/catalogos/discapacidades'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. GET /catalogos/municipios  ->  fn_cat_municipios_listar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'eval-col-catalogos-municipios-001',
    'SELECT * FROM academico_test.fn_cat_municipios_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/catalogos/municipios', 'SELECT', 'GET',
    '{}'::jsonb,
    NULL,
    'Catalogo de municipios activos con su departamento resuelto, para el select de municipio del formulario de establecimiento.',
    'catalogos-municipios', 'DEFAULT',
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN', 'SSO-USER')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/catalogos/municipios'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3. GET /catalogos/propiedad-juridica  ->  fn_cat_propiedad_juridica_listar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'eval-col-catalogos-propiedad-juridica-001',
    'SELECT * FROM academico_test.fn_cat_propiedad_juridica_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/catalogos/propiedad-juridica', 'SELECT', 'GET',
    '{}'::jsonb,
    NULL,
    'Catalogo de tipos de propiedad juridica activos, para el select correspondiente del formulario de establecimiento.',
    'catalogos-propiedad-juridica', 'DEFAULT',
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN', 'SSO-USER')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/catalogos/propiedad-juridica'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 4. GET /catalogos/roles  ->  fn_cat_roles_listar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'eval-col-catalogos-roles-001',
    'SELECT * FROM academico_test.fn_cat_roles_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/catalogos/roles', 'SELECT', 'GET',
    '{}'::jsonb,
    NULL,
    'Catalogo de roles asignables a un funcionario (TROL, PK_TROL >= 9), para el select de rol del dialog de permisos de funcionario.',
    'catalogos-roles', 'DEFAULT',
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/catalogos/roles'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 5. GET /menus  ->  fn_list_available_menus
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'eval-col-menus-list-001',
    'SELECT pk_tmenu       AS id,
            pk_padre       AS "idParent",
            nombre         AS name,
            url            AS path,
            icono          AS icon,
            visible,
            orden          AS "menuOrder",
            plan_id        AS "planId",
            type
       FROM academico_test.fn_list_available_menus(:CONTEXT.USER_ID::BIGINT);',
    'postgres', false, false,
    m.id_microservice,
    '/menus', 'SELECT', 'GET',
    '{}'::jsonb,
    NULL,
    'roles-permisos: catalogo COMPLETO de menus (MenuDto[]), sin filtrar por rol.',
    'menus-list', NULL,
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/menus'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 6. GET /plans  ->  fn_list_plans_from_value
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'eval-col-plans-list-001',
    'SELECT id, name
       FROM academico_test.fn_list_plans_from_value(:CONTEXT.USER_ID::BIGINT);',
    'postgres', false, false,
    m.id_microservice,
    '/plans', 'SELECT', 'GET',
    '{}'::jsonb,
    NULL,
    'roles-permisos: planes academicos activos (PlanDto[]).',
    'plans-list', NULL,
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/plans'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 7. POST /plans  ->  fn_create_plan_from_value
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'eval-col-plans-create-001',
    'SELECT id, name
       FROM academico_test.fn_create_plan_from_value(
           :CONTEXT.USER_ID::BIGINT,
           CAST(:BODY.NAME AS VARCHAR)
       );',
    'postgres', false, false,
    m.id_microservice,
    '/plans', 'SELECT', 'POST',
    '{"BODY.NAME": "VARCHAR"}'::jsonb,
    NULL,
    'roles-permisos: alta rapida de plan academico (PlanDto 201).',
    'plans-create', NULL,
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/plans'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 8. POST /roles  ->  fn_add_trol
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'eval-col-roles-create-001',
    'SELECT id, name
       FROM academico_test.fn_add_trol(
           :CONTEXT.USER_ID::BIGINT,
           CAST(:BODY.NAME AS VARCHAR),
           :CONTEXT.EMAIL
       );',
    'postgres', false, false,
    m.id_microservice,
    '/roles', 'SELECT', 'POST',
    '{"BODY.NAME": "VARCHAR"}'::jsonb,
    NULL,
    'roles-permisos: alta rapida de rol (RoleDto 201). p_estado usa el DEFAULT de la funcion (ACTIVO).',
    'roles-create', NULL,
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
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 9. GET /roles/:ROLEID/menus  ->  fn_assert_superadmin
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'eval-col-roles-menus-list-001',
    'WITH _auth AS (SELECT academico_test.fn_assert_superadmin(:CONTEXT.USER_ID::BIGINT))
     SELECT tm.fk_tmenu AS id
       FROM academico_test.trol_menu tm, _auth
      WHERE tm.fk_trol = CAST(:PARAM.ROLEID AS BIGINT)
        AND tm.active = TRUE
      ORDER BY tm.orden_rol NULLS LAST;',
    'postgres', false, false,
    m.id_microservice,
    '/roles/:ROLEID/menus', 'SELECT', 'GET',
    '{"PARAM.ROLEID": "BIGINT"}'::jsonb,
    NULL,
    'roles-permisos: ids de menu asignados a un rol, EN EL ORDEN guardado.',
    'roles-menus-list', NULL,
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
   AND q.path_template = '/roles/:ROLEID/menus'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;
