-- ===========================================================================
-- V79 - registro en public.query (+ role_query) de los endpoints de
--        query-service de grados, grupos y niveles de ensenanza (V43).
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
--   El texto volcado ya refleja los UPDATE de las migraciones < V79, que
--   sobre base limpia corren antes y no encuentran fila: el estado final es
--   el mismo por ambos caminos.
--
-- NUMERACION
--   Hueco libre V79, verificado contra TODAS las ramas de origin. Se eligio
--   por encima de las migraciones que definen las funciones invocadas (V43)
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
-- 1. GET /catalogos/niveles-ensenanza  ->  fn_nivel_ensenanza_listar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'cat-niveles-ensenanza',
    'SELECT * FROM academico_test.fn_nivel_ensenanza_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/catalogos/niveles-ensenanza', 'SELECT', 'GET',
    '{}'::jsonb,
    NULL,
    'V214 -- TNIVEL_ENSENANZA activos (id, codigo, nombre) para el select "Nivel educativo"',
    NULL, NULL,
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
   AND q.path_template = '/catalogos/niveles-ensenanza'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. POST /grados  ->  fn_grado_crear
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-msp38x3p-a9ldttl5',
    'SELECT *
FROM academico_test.fn_grado_crear(
    CAST(:BODY.FK_PERIODO AS BIGINT),
    CAST(:BODY.FK_NIVEL AS BIGINT),
    CAST(:BODY.NOMBRE AS VARCHAR),
    CAST(:BODY.FK_GRADO_SIGUIENTE AS BIGINT),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/grados', 'SELECT', 'POST',
    '{"BODY.NOMBRE": "VARCHAR", "BODY.FK_NIVEL": "BIGINT", "BODY.FK_PERIODO": "BIGINT", "BODY.FK_GRADO_SIGUIENTE": "BIGINT"}'::jsonb,
    NULL,
    NULL,
    NULL, NULL,
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-COORDINADOR', 'CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/grados'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3. POST /grados/:FK_GRADO/grupos/query  ->  fn_grupo_listar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-msp4t0ow-kewwn1lc',
    'SELECT *
FROM academico_test.fn_grupo_listar(
    CAST(:PARAM.FK_GRADO AS BIGINT),
    CAST(:BODY.FILTRO AS TEXT),
    CAST(:BODY.PAGE_INDEX AS INT),
    CAST(:BODY.PAGE_SIZE AS INT),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.SORTING_ID AS TEXT),
    CAST(:BODY.SORTING_DESC AS TEXT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/grados/:FK_GRADO/grupos/query', 'SELECT', 'POST',
    '{"BODY.FILTRO": "TEXT", "BODY.PAGE_SIZE": "INTEGER", "PARAM.FK_GRADO": "BIGINT!", "BODY.PAGE_INDEX": "INTEGER", "BODY.SORTING_ID": "TEXT", "BODY.SORTING_DESC": "TEXT"}'::jsonb,
    NULL,
    NULL,
    NULL, NULL,
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-COORDINADOR', 'CEVAL-DIRECTOR_GRUPO', 'CEVAL-DOCENTE', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-PSICO_ORIENTADOR', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/grados/:FK_GRADO/grupos/query'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 4. GET /grados/:ID  ->  fn_grado_obtener
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-msp4ol3f-4qdanvz4',
    'SELECT *
FROM academico_test.fn_grado_obtener(
    CAST(:PARAM.ID AS BIGINT),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/grados/:ID', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    NULL,
    NULL,
    NULL, NULL,
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-COORDINADOR', 'CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/grados/:ID'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 5. PUT /grados/:ID  ->  fn_grado_actualizar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-msp3bkgm-tv5450yn',
    'SELECT *
FROM academico_test.fn_grado_actualizar(
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.FK_NIVEL AS BIGINT),
    CAST(:BODY.NOMBRE AS VARCHAR),
    CAST(:BODY.FK_GRADO_SIGUIENTE AS BIGINT),
    CAST(:BODY.TIENE_GRADO_SIGUIENTE AS BOOLEAN),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/grados/:ID', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT", "BODY.NOMBRE": "VARCHAR", "BODY.FK_NIVEL": "BIGINT", "BODY.FK_GRADO_SIGUIENTE": "BIGINT", "BODY.TIENE_GRADO_SIGUIENTE": "BOOLEAN"}'::jsonb,
    NULL,
    NULL,
    NULL, NULL,
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-COORDINADOR', 'CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/grados/:ID'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 6. GET /grados/:ID/configuracion  ->  fn_grade_config_obtener
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-msp4yr30-a5n334d5',
    'SELECT academico_test.fn_grade_config_obtener(
    CAST(:PARAM.ID AS BIGINT),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/grados/:ID/configuracion', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    NULL,
    NULL,
    NULL, NULL,
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-COORDINADOR', 'CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/grados/:ID/configuracion'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 7. PUT /grados/:ID/configuracion  ->  fn_grade_config_guardar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-msp4zjhu-orlnkdpp',
    'SELECT *
FROM academico_test.fn_grade_config_guardar(
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY_RAW.SCHEDULE AS JSONB),
    CAST(:BODY_RAW.PROMOTION AS JSONB),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/grados/:ID/configuracion', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT", "BODY_RAW.SCHEDULE": "JSONB", "BODY_RAW.PROMOTION": "JSONB"}'::jsonb,
    NULL,
    NULL,
    NULL, NULL,
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-COORDINADOR', 'CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/grados/:ID/configuracion'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 8. PUT /grados/:ID/eliminar  ->  fn_grado_soft_delete
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-msp3ddjg-h1f2xn1h',
    'SELECT *
FROM academico_test.fn_grado_soft_delete(
    CAST(:PARAM.ID AS BIGINT),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/grados/:ID/eliminar', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    NULL,
    NULL,
    NULL, NULL,
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-COORDINADOR', 'CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/grados/:ID/eliminar'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 9. POST /grados/:ID/grupos  ->  fn_grupo_crear
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-msp4pf6w-vv2ute96',
    'SELECT *
FROM academico_test.fn_grupo_crear(
    CAST(:BODY.FK_GRADO AS BIGINT),
    CAST(:BODY.NOMBRE AS VARCHAR),
    CAST(:BODY.FK_MODELO_PEDAGOGICO AS BIGINT),
    CAST(:BODY.CAPACIDAD AS NUMERIC),
    CAST(:BODY.FK_FUNCIONARIO AS BIGINT),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/grados/:ID/grupos', 'SELECT', 'POST',
    '{"PARAM.ID": "BIGINT", "BODY.NOMBRE": "VARCHAR", "BODY.FK_GRADO": "BIGINT", "BODY.CAPACIDAD": "NUMERIC", "BODY.FK_FUNCIONARIO": "BIGINT", "BODY.FK_MODELO_PEDAGOGICO": "BIGINT"}'::jsonb,
    NULL,
    NULL,
    NULL, NULL,
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-COORDINADOR', 'CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/grados/:ID/grupos'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 10. PUT /grados/eliminacion-masiva  ->  fn_grado_bulk_delete
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-msp4x4ev-noqjga0b',
    'SELECT *
FROM academico_test.fn_grado_bulk_delete(
    CAST(:BODY.IDS AS BIGINT[]),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/grados/eliminacion-masiva', 'SELECT', 'PUT',
    '{"BODY.IDS": "BIGINT[]"}'::jsonb,
    NULL,
    NULL,
    NULL, NULL,
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-COORDINADOR', 'CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/grados/eliminacion-masiva'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 11. POST /grados/query/:FK_PERIODO  ->  fn_grado_listar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-msp3ep7p-r3da43h1',
    'SELECT *
FROM academico_test.fn_grado_listar(
    CAST(:PARAM.FK_PERIODO AS BIGINT),
    CAST(:BODY.FILTRO AS TEXT),
    CAST(:BODY.PAGE_INDEX AS INT),
    CAST(:BODY.PAGE_SIZE AS INT),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.SORTING_ID AS TEXT),
    CAST(:BODY.SORTING_DESC AS TEXT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/grados/query/:FK_PERIODO', 'SELECT', 'POST',
    '{"BODY.FILTRO": "TEXT", "BODY.PAGE_SIZE": "INTEGER", "BODY.PAGE_INDEX": "INTEGER", "BODY.SORTING_ID": "TEXT", "PARAM.FK_PERIODO": "BIGINT!", "BODY.SORTING_DESC": "TEXT"}'::jsonb,
    NULL,
    NULL,
    NULL, NULL,
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-COORDINADOR', 'CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/grados/query/:FK_PERIODO'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 12. GET /grupos/:ID  ->  fn_grupo_obtener
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-msp4umr6-a1v1mxix',
    'SELECT *
FROM academico_test.fn_grupo_obtener(
    CAST(:PARAM.ID AS BIGINT),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/grupos/:ID', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    NULL,
    NULL,
    NULL, NULL,
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-COORDINADOR', 'CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/grupos/:ID'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 13. PUT /grupos/:ID  ->  fn_grupo_actualizar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-msp4rbjg-aokwfv42',
    'SELECT *
FROM academico_test.fn_grupo_actualizar(
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.NOMBRE AS VARCHAR),
    CAST(:BODY.FK_MODELO_PEDAGOGICO AS BIGINT),
    CAST(:BODY.CAPACIDAD AS NUMERIC),
    CAST(:BODY.FK_FUNCIONARIO AS BIGINT),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/grupos/:ID', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT", "BODY.NOMBRE": "VARCHAR", "BODY.CAPACIDAD": "NUMERIC", "BODY.FK_FUNCIONARIO": "BIGINT", "BODY.FK_MODELO_PEDAGOGICO": "BIGINT"}'::jsonb,
    NULL,
    NULL,
    NULL, NULL,
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-COORDINADOR', 'CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/grupos/:ID'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 14. PUT /grupos/:ID/eliminar  ->  fn_grupo_soft_delete
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-msp4sgpc-toh5izs5',
    'SELECT *
FROM academico_test.fn_grupo_soft_delete(
    CAST(:PARAM.ID AS BIGINT),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/grupos/:ID/eliminar', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    NULL,
    NULL,
    NULL, NULL,
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-COORDINADOR', 'CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/grupos/:ID/eliminar'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 15. POST /grupos/bulk-delete  ->  fn_grupo_bulk_delete
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-mt1pe3xn-ylspmf15',
    'SELECT * FROM academico_test.fn_grupo_bulk_delete(CAST(:BODY.IDS AS BIGINT[]), public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT));',
    'postgres', false, false,
    m.id_microservice,
    '/grupos/bulk-delete', 'SELECT', 'POST',
    '{"BODY.IDS": "BIGINT[]"}'::jsonb,
    NULL,
    NULL,
    NULL, NULL,
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-COORDINADOR', 'CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/grupos/bulk-delete'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 16. GET /niveles-ensenanza  ->  fn_nivel_ensenanza_listar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-msp4v3q1-l8cop89v',
    'SELECT *
FROM academico_test.fn_nivel_ensenanza_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/niveles-ensenanza', 'SELECT', 'GET',
    '{}'::jsonb,
    NULL,
    NULL,
    NULL, NULL,
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-COORDINADOR', 'CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'CEVAL-DIRECTOR_GRUPO', 'CEVAL-DOCENTE', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-PSICO_ORIENTADOR', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/niveles-ensenanza'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 17. GET /sedes/:ID/funcionarios  ->  fn_funcionario_sede_listar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-msp4vmzq-ccjqezg4',
    'SELECT *
FROM academico_test.fn_funcionario_sede_listar(
    CAST(:PARAM.ID AS BIGINT),
    CAST(:QUERY.FILTRO AS TEXT),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/sedes/:ID/funcionarios', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT", "QUERY.FILTRO": "TEXT"}'::jsonb,
    NULL,
    NULL,
    NULL, NULL,
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-COORDINADOR', 'CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/sedes/:ID/funcionarios'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;
