-- ===========================================================================
-- V77 - registro en public.query (+ role_query) de los endpoints de
--        query-service de areas, asignaturas, enfasis y especialidades (V40).
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
--   El texto volcado ya refleja los UPDATE de las migraciones < V77, que
--   sobre base limpia corren antes y no encuentran fila: el estado final es
--   el mismo por ambos caminos.
--
-- NUMERACION
--   Hueco libre V77, verificado contra TODAS las ramas de origin. Se eligio
--   por encima de las migraciones que definen las funciones invocadas (V40)
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
-- 1. POST /areas  ->  fn_area_crear
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msntptca-wsoxs67h',
    'SELECT academico_test.fn_area_crear(
    CAST(:BODY.FK_PERIODO AS BIGINT),
    CAST(:BODY.FK_AREA_ASIGNATURA AS BIGINT),
    CAST(:BODY.NOMBRE_INTERNO AS VARCHAR),
    CAST(:BODY.ABREVIACION AS VARCHAR),
    CAST(:BODY.ORDEN_REPORTES AS NUMERIC),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/areas', 'SELECT', 'POST',
    '{"BODY.FK_PERIODO": "BIGINT", "BODY.ABREVIACION": "VARCHAR", "BODY.NOMBRE_INTERNO": "VARCHAR", "BODY.ORDEN_REPORTES": "NUMERIC", "BODY.FK_AREA_ASIGNATURA": "BIGINT"}'::jsonb,
    NULL,
    NULL,
    NULL, NULL
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
   AND q.path_template = '/areas'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. POST /areas/:FK_AREA/asignaturas  ->  fn_subject_crear
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msnu32nb-3a7d5kad',
    'SELECT academico_test.fn_subject_crear(
    CAST(:PARAM.FK_AREA AS BIGINT),
    CAST(:BODY.FK_AREA_ASIGNATURA AS BIGINT),
    CAST(:BODY.NOMBRE_INTERNO AS VARCHAR),
    CAST(:BODY.ABREVIACION AS VARCHAR),
    CAST(:BODY.FK_ENFASIS AS BIGINT),
    CAST(:BODY.COLOR AS VARCHAR),
    CAST(:BODY.ORDEN_REPORTES AS NUMERIC),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/areas/:FK_AREA/asignaturas', 'SELECT', 'POST',
    '{"BODY.COLOR": "VARCHAR", "PARAM.FK_AREA": "BIGINT", "BODY.FK_ENFASIS": "BIGINT", "BODY.ABREVIACION": "VARCHAR", "BODY.NOMBRE_INTERNO": "VARCHAR", "BODY.ORDEN_REPORTES": "NUMERIC", "BODY.FK_AREA_ASIGNATURA": "BIGINT"}'::jsonb,
    NULL,
    NULL,
    NULL, NULL
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
   AND q.path_template = '/areas/:FK_AREA/asignaturas'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3. PUT /areas/:ID  ->  fn_area_actualizar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msntsemp-8ef6799d',
    'SELECT academico_test.fn_area_actualizar(
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.FK_AREA_ASIGNATURA AS BIGINT),
    CAST(:BODY.NOMBRE_INTERNO AS VARCHAR),
    CAST(:BODY.ABREVIACION AS VARCHAR),
    CAST(:BODY.ORDEN_REPORTES AS NUMERIC),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/areas/:ID', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT", "BODY.ABREVIACION": "VARCHAR", "BODY.NOMBRE_INTERNO": "VARCHAR", "BODY.ORDEN_REPORTES": "NUMERIC", "BODY.FK_AREA_ASIGNATURA": "BIGINT"}'::jsonb,
    NULL,
    NULL,
    NULL, NULL
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
   AND q.path_template = '/areas/:ID'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 4. GET /areas/:ID/asignaturas  ->  fn_subject_listar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msrqzc3g-mg4gudyz',
    'SELECT *
FROM academico_test.fn_subject_listar(
    CAST(:PARAM.ID AS BIGINT),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/areas/:ID/asignaturas', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    NULL,
    NULL,
    NULL, NULL
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
   AND q.path_template = '/areas/:ID/asignaturas'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 5. PUT /areas/:ID/asignaturas  ->  fn_subject_guardar_bulk
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msp22xiz-4644j11q',
    'SELECT academico_test.fn_subject_guardar_bulk(
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY_RAW.ASIGNATURAS AS JSONB),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
) AS cantidad;',
    'postgres', false, false,
    m.id_microservice,
    '/areas/:ID/asignaturas', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT", "BODY.ASIGNATURAS": "JSONB", "BODY_RAW.ASIGNATURAS": "JSONB"}'::jsonb,
    NULL,
    NULL,
    NULL, NULL
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
   AND q.path_template = '/areas/:ID/asignaturas'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 6. GET /areas/:ID/especialidades  ->  fn_especialidad_enfasis_listar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msp1s793-3oz3q24d',
    'SELECT *
FROM academico_test.fn_especialidad_enfasis_listar(
    (SELECT s.FK_TESTABLECIMIENTO
       FROM academico_test.TPERIODO_ACADEMICO pa
       JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
      WHERE pa.PK_TPERIODO_ACADEMICO = CAST(:PARAM.ID AS BIGINT)),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/areas/:ID/especialidades', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    NULL,
    NULL,
    NULL, NULL
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
   AND q.path_template = '/areas/:ID/especialidades'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 7. POST /areas/asignaturas  ->  fn_subject_periodo_listar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msrx3cek-ra0oi7l3',
    'SELECT *
FROM academico_test.fn_subject_periodo_listar(
    CAST(:BODY.FK_PERIODO AS BIGINT),
    CAST(:BODY.FILTRO AS TEXT),
    CAST(:BODY.PAGE_INDEX AS INT),
    CAST(:BODY.PAGE_SIZE AS INT),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.SORT_BY AS TEXT),
    CAST(:BODY.SORT_DIR AS TEXT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/areas/asignaturas', 'SELECT', 'POST',
    '{"BODY.FILTRO": "TEXT", "BODY.SORT_BY": "TEXT", "BODY.SORT_DIR": "TEXT", "BODY.PAGE_SIZE": "INTEGER", "BODY.FK_PERIODO": "BIGINT", "BODY.PAGE_INDEX": "INTEGER"}'::jsonb,
    NULL,
    NULL,
    NULL, NULL
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
   AND q.path_template = '/areas/asignaturas'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 8. PUT /areas/asignaturas/:SUBJECT_ID  ->  fn_subject_actualizar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msp1xosj-8sy2l041',
    'SELECT academico_test.fn_subject_actualizar(
    CAST(:PARAM.SUBJECT_ID AS BIGINT),
    CAST(:BODY.FK_AREA_ASIGNATURA AS BIGINT),
    CAST(:BODY.NOMBRE_INTERNO AS VARCHAR),
    CAST(:BODY.ABREVIACION AS VARCHAR),
    CAST(:BODY.FK_ENFASIS AS BIGINT),
    CAST(:BODY.COLOR AS VARCHAR),
    CAST(:BODY.ORDEN_REPORTES AS NUMERIC),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
) AS id;',
    'postgres', false, false,
    m.id_microservice,
    '/areas/asignaturas/:SUBJECT_ID', 'SELECT', 'PUT',
    '{"BODY.COLOR": "VARCHAR", "BODY.FK_ENFASIS": "BIGINT", "BODY.ABREVIACION": "VARCHAR", "PARAM.SUBJECT_ID": "BIGINT", "BODY.NOMBRE_INTERNO": "VARCHAR", "BODY.ORDEN_REPORTES": "NUMERIC", "BODY.FK_AREA_ASIGNATURA": "BIGINT"}'::jsonb,
    NULL,
    NULL,
    NULL, NULL
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
   AND q.path_template = '/areas/asignaturas/:SUBJECT_ID'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 9. PUT /areas/asignaturas/eliminar/:SUBJECT_ID  ->  fn_subject_soft_delete
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msp21f2k-xxosurvz',
    'SELECT academico_test.fn_subject_soft_delete(
    CAST(:PARAM.SUBJECT_ID AS BIGINT),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
) AS id;',
    'postgres', false, false,
    m.id_microservice,
    '/areas/asignaturas/eliminar/:SUBJECT_ID', 'SELECT', 'PUT',
    '{"PARAM.SUBJECT_ID": "BIGINT"}'::jsonb,
    NULL,
    NULL,
    NULL, NULL
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
   AND q.path_template = '/areas/asignaturas/eliminar/:SUBJECT_ID'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 10. PUT /areas/eliminar/:ID  ->  fn_area_soft_delete
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msntv6zh-152gn4lg',
    'SELECT academico_test.fn_area_soft_delete(
    CAST(:PARAM.ID AS BIGINT),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/areas/eliminar/:ID', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    NULL,
    NULL,
    NULL, NULL
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
   AND q.path_template = '/areas/eliminar/:ID'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 11. GET /areas/general  ->  fn_area_asignatura_listar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msp241c2-742o3puw',
    'SELECT *
FROM academico_test.fn_area_asignatura_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/areas/general', 'SELECT', 'GET',
    '{}'::jsonb,
    NULL,
    NULL,
    NULL, NULL
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
   AND q.path_template = '/areas/general'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 12. POST /areas/query  ->  fn_area_listar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msnu08pu-z2hxug56',
    'SELECT *
FROM academico_test.fn_area_listar(
    CAST(:BODY.FK_PERIODO AS BIGINT),
    CAST(:BODY.NOMBRE_INTERNO AS TEXT),
    CAST(:BODY.PAGE_INDEX AS INT),
    CAST(:BODY.PAGE_SIZE AS INT),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.SORT_BY AS TEXT),
    CAST(:BODY.SORT_DIR AS TEXT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/areas/query', 'SELECT', 'POST',
    '{"BODY.SORT_BY": "TEXT", "BODY.SORT_DIR": "TEXT", "BODY.PAGE_SIZE": "BIGINT", "BODY.FK_PERIODO": "BIGINT", "BODY.PAGE_INDEX": "BIGINT", "BODY.NOMBRE_INTERNO": "TEXT"}'::jsonb,
    NULL,
    NULL,
    NULL, NULL
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
   AND q.path_template = '/areas/query'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 13. GET /catalogos/areas-asignaturas  ->  fn_area_asignatura_listar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'cat-areas-asignaturas',
    'SELECT * FROM academico_test.fn_area_asignatura_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/catalogos/areas-asignaturas', 'SELECT', 'GET',
    '{}'::jsonb,
    NULL,
    'V214 -- TAREA_ASIGNATURA activas (id, nombre, especialidad_id) para el select "Areas o dimensiones"',
    NULL, NULL
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
   AND q.path_template = '/catalogos/areas-asignaturas'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 14. POST /enfasis  ->  fn_enfasis_resolver
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-9790ce68-ec01cfb6',
    'SELECT academico_test.fn_enfasis_resolver(
    (SELECT s.FK_TESTABLECIMIENTO
       FROM academico_test.TPERIODO_ACADEMICO pa
       JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
      WHERE pa.PK_TPERIODO_ACADEMICO = CAST(:BODY.FK_PERIODO AS BIGINT)
        AND pa.ACTIVE = TRUE),
    CAST(:BODY.NOMBRE AS VARCHAR),
    NULL,
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
) AS id;',
    'postgres', false, false,
    m.id_microservice,
    '/enfasis', 'SELECT', 'POST',
    '{"BODY.NOMBRE": "VARCHAR", "BODY.FK_PERIODO": "BIGINT"}'::jsonb,
    NULL,
    NULL,
    NULL, NULL
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
   AND q.path_template = '/enfasis'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 15. PUT /enfasis/:ID  ->  fn_enfasis_actualizar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-mss1502y-battsoxh',
    'SELECT academico_test.fn_enfasis_actualizar(
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.NOMBRE AS TEXT),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
) AS id;',
    'postgres', false, false,
    m.id_microservice,
    '/enfasis/:ID', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT", "BODY.NOMBRE": "TEXT"}'::jsonb,
    NULL,
    NULL,
    NULL, NULL
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
   AND q.path_template = '/enfasis/:ID'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 16. PUT /enfasis/eliminar/:ID  ->  fn_enfasis_soft_delete
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-mss16gw3-2rqec2b2',
    'SELECT academico_test.fn_enfasis_soft_delete(
    CAST(:PARAM.ID AS BIGINT),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
) AS id;',
    'postgres', false, false,
    m.id_microservice,
    '/enfasis/eliminar/:ID', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    NULL,
    NULL,
    NULL, NULL
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
   AND q.path_template = '/enfasis/eliminar/:ID'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 17. GET /periodos/:ID/areas/asignaturas  ->  fn_periodo_areas_asignaturas_listar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msp24ppx-hivguj4s',
    'SELECT *
FROM academico_test.fn_periodo_areas_asignaturas_listar(
    CAST(:PARAM.ID AS BIGINT),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/periodos/:ID/areas/asignaturas', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    NULL,
    NULL,
    NULL, NULL
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
   AND q.path_template = '/periodos/:ID/areas/asignaturas'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;
