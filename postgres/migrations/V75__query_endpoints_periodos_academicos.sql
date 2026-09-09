-- ===========================================================================
-- V75 - registro en public.query (+ role_query) de los endpoints de
--        query-service de periodos academicos y sus descansos (V37).
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
--   El texto volcado ya refleja los UPDATE de las migraciones < V75, que
--   sobre base limpia corren antes y no encuentran fila: el estado final es
--   el mismo por ambos caminos.
--
-- NUMERACION
--   Hueco libre V75, verificado contra TODAS las ramas de origin. Se eligio
--   por encima de las migraciones que definen las funciones invocadas (V37)
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
-- 1. POST /periodos-academicos  ->  fn_periodo_crear
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-msnssnib-7o09r0ms',
    'SELECT *
FROM academico_test.fn_periodo_crear(
    CAST(:BODY.FK_SEDE AS BIGINT),
    CAST(:BODY.FK_ESTADO AS BIGINT),
    CAST(:BODY.FECHA_INICIO AS DATE),
    CAST(:BODY.FECHA_FIN AS DATE),
    CAST(:BODY.FECHA_LIMITE_MATRICULA AS DATE),
    CAST(:BODY.FK_JORNADA AS BIGINT),
    CAST(:BODY.HORA_INICIO AS TIME),
    CAST(:BODY.HORA_FIN AS TIME),
    CAST(:BODY.RESERVA AS academico_test.bool_sn),
    CAST(:BODY.BLOQUES_POR_DEFECTO AS BIGINT),
    CAST(:BODY.FK_PERIODO_ANTERIOR AS BIGINT),
    CAST(:BODY.DESCANSO_INICIO AS TIME[]),
    CAST(:BODY.DESCANSO_FIN AS TIME[]),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/periodos-academicos', 'SELECT', 'POST',
    '{"BODY.FK_SEDE": "BIGINT!", "BODY.RESERVA": "BOOL_SN!", "BODY.HORA_FIN": "TIME!", "BODY.FECHA_FIN": "DATE!", "BODY.FK_ESTADO": "BIGINT!", "BODY.FK_JORNADA": "BIGINT!", "BODY.HORA_INICIO": "TIME!", "BODY.DESCANSO_FIN": "TIME[]", "BODY.FECHA_INICIO": "DATE!", "BODY.DESCANSO_INICIO": "TIME[]", "BODY.BLOQUES_POR_DEFECTO": "BIGINT!", "BODY.FK_PERIODO_ANTERIOR": "BIGINT", "BODY.FECHA_LIMITE_MATRICULA": "DATE!"}'::jsonb,
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
   AND q.path_template = '/periodos-academicos'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. PUT /periodos-academicos  ->  fn_periodo_bulk_delete
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-msnt84nj-84rnp1lx',
    'SELECT *
FROM academico_test.fn_periodo_bulk_delete(
    CAST(:BODY.IDS AS BIGINT[]),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/periodos-academicos', 'SELECT', 'PUT',
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
   AND q.path_template = '/periodos-academicos'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3. GET /periodos-academicos/:ID  ->  fn_periodo_detalle
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-msnsotal-irkg95bz',
    'SELECT *
FROM academico_test.fn_periodo_detalle(
    CAST(:PARAM.ID AS BIGINT),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/periodos-academicos/:ID', 'SELECT', 'GET',
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
   AND q.path_template = '/periodos-academicos/:ID'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 4. PUT /periodos-academicos/:ID  ->  fn_periodo_soft_delete
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-msnt221w-khyaentf',
    'SELECT *
FROM academico_test.fn_periodo_soft_delete(
    CAST(:PARAM.ID AS BIGINT),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/periodos-academicos/:ID', 'SELECT', 'PUT',
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
   AND q.path_template = '/periodos-academicos/:ID'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 5. POST /periodos-academicos/:ID/descansos  ->  fn_descanso_agregar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-msnt3onj-nelkjobq',
    'SELECT *
FROM academico_test.fn_descanso_agregar(
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.HORA_INICIO AS TIME),
    CAST(:BODY.HORA_FIN AS TIME),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/periodos-academicos/:ID/descansos', 'SELECT', 'POST',
    '{"PARAM.ID": "BIGINT", "BODY.HORA_FIN": "TIME", "BODY.HORA_INICIO": "TIME"}'::jsonb,
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
   AND q.path_template = '/periodos-academicos/:ID/descansos'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 6. GET /periodos-academicos/anos-lectivos  ->  fn_periodo_anos_lectivos_listar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-mt7qtxfs-0y42mu3t',
    'SELECT * FROM academico_test.fn_periodo_anos_lectivos_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/periodos-academicos/anos-lectivos', 'SELECT', 'GET',
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
  JOIN public.role r ON r.name IN ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-COORDINADOR', 'CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/periodos-academicos/anos-lectivos'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 7. POST /periodos-academicos/anterior  ->  fn_periodo_anteriores_por_sede
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-msrlbvy7-nvh85nyg',
    'SELECT *
FROM academico_test.fn_periodo_anteriores_por_sede(
    CAST(:BODY.FK_SEDE AS BIGINT),
    CAST(:BODY.FK_PERIODO AS BIGINT),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/periodos-academicos/anterior', 'SELECT', 'POST',
    '{"BODY.FK_SEDE": "BIGINT", "BODY.FK_PERIODO": "BIGINT"}'::jsonb,
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
   AND q.path_template = '/periodos-academicos/anterior'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 8. PUT /periodos-academicos/descansos/:ID  ->  fn_descanso_eliminar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-msnt6jdx-4vkyaele',
    'SELECT *
FROM academico_test.fn_descanso_eliminar(
    CAST(:PARAM.ID AS BIGINT),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/periodos-academicos/descansos/:ID', 'SELECT', 'PUT',
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
   AND q.path_template = '/periodos-academicos/descansos/:ID'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 9. PUT /periodos-academicos/editar/:ID  ->  fn_periodo_actualizar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-ea55865d-cbd834e3',
    'SELECT *
FROM academico_test.fn_periodo_actualizar(
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.FK_ESTADO AS BIGINT),
    CAST(:BODY.FK_SEDE AS BIGINT),
    CAST(:BODY.FECHA_INICIO AS DATE),
    CAST(:BODY.FECHA_FIN AS DATE),
    CAST(:BODY.FECHA_LIMITE_MATRICULA AS DATE),
    CAST(:BODY.FK_JORNADA AS BIGINT),
    CAST(:BODY.RESERVA AS academico_test.bool_sn),
    CAST(:BODY.BLOQUES_POR_DEFECTO AS BIGINT),
    CAST(:BODY.FK_PERIODO_ANTERIOR AS BIGINT),
    CAST(:BODY.HORA_INICIO AS TIME),
    CAST(:BODY.HORA_FIN AS TIME),
    CAST(:BODY.DESCANSO_INICIO AS TIME[]),
    CAST(:BODY.DESCANSO_FIN AS TIME[]),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/periodos-academicos/editar/:ID', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT", "BODY.FK_SEDE": "BIGINT", "BODY.RESERVA": "VARCHAR", "BODY.HORA_FIN": "TIME", "BODY.FECHA_FIN": "DATE", "BODY.FK_ESTADO": "BIGINT", "BODY.FK_JORNADA": "BIGINT", "BODY.HORA_INICIO": "TIME", "BODY.DESCANSO_FIN": "TIME[]", "BODY.FECHA_INICIO": "DATE", "BODY.DESCANSO_INICIO": "TIME[]", "BODY.BLOQUES_POR_DEFECTO": "BIGINT", "BODY.FK_PERIODO_ANTERIOR": "BIGINT", "BODY.FECHA_LIMITE_MATRICULA": "DATE"}'::jsonb,
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
   AND q.path_template = '/periodos-academicos/editar/:ID'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 10. POST /periodos-academicos/query  ->  fn_periodo_listar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-msns7wiu-ragcxbp8',
    'SELECT *
FROM academico_test.fn_periodo_listar(
    CAST(:BODY.FK_SEDE AS BIGINT),
    CAST(:BODY.NOMBRE_SEDE AS TEXT),
    CAST(:BODY.ANO AS TEXT),
    CAST(:BODY.FK_ESTADO AS BIGINT),
    CAST(:BODY.FECHA_DESDE AS DATE),
    CAST(:BODY.FECHA_HASTA AS DATE),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.PAGEINDEX AS INT),
    CAST(:BODY.PAGESIZE AS INT),
    CAST(:BODY.SORT_BY AS TEXT),
    CAST(:BODY.SORT_DIR AS TEXT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/periodos-academicos/query', 'SELECT', 'POST',
    '{"BODY.ANO": "TEXT", "BODY.FK_SEDE": "BIGINT", "BODY.SORT_BY": "TEXT", "BODY.PAGESIZE": "INTEGER", "BODY.SORT_DIR": "TEXT", "BODY.FK_ESTADO": "BIGINT", "BODY.PAGEINDEX": "INTEGER", "BODY.FECHA_DESDE": "DATE", "BODY.FECHA_HASTA": "DATE", "BODY.NOMBRE_SEDE": "TEXT"}'::jsonb,
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
  JOIN public.role r ON r.name IN ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-COORDINADOR', 'CEVAL-DIRECTOR_GRUPO', 'CEVAL-DOCENTE', 'CEVAL-JEFE_AREA', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-PSICO_ORIENTADOR', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/periodos-academicos/query'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 11. POST /periodos-academicos/reporte  ->  fn_periodo_listar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'eval-col-periodos-academicos-reporte-001',
    'SELECT * FROM academico_test.fn_periodo_listar(
    CAST(:BODY.FILTERS.FK_SEDE AS BIGINT),
    CAST(:BODY.FILTERS.NOMBRE_SEDE AS TEXT),
    CAST(:BODY.FILTERS.ANO AS TEXT),
    CAST(:BODY.FILTERS.FK_ESTADO AS BIGINT),
    CAST(:BODY.FILTERS.FECHA_DESDE AS DATE),
    CAST(:BODY.FILTERS.FECHA_HASTA AS DATE),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    NULL::INTEGER, NULL::INTEGER,
    CAST(:BODY.SORTING.ID AS TEXT),
    CAST(:BODY.SORTING.DESC AS TEXT)
) t
WHERE CAST(:BODY.FILTERS.IDS AS BIGINT[]) IS NULL
   OR t.id = ANY(CAST(:BODY.FILTERS.IDS AS BIGINT[]));',
    'postgres', false, false,
    m.id_microservice,
    '/periodos-academicos/reporte', 'SELECT', 'POST',
    '{"BODY.SORTING.ID": "TEXT", "BODY.FILTERS.ANO": "TEXT", "BODY.FILTERS.IDS": "BIGINT[]", "BODY.SORTING.DESC": "TEXT", "BODY.FILTERS.FK_SEDE": "BIGINT", "BODY.FILTERS.FK_ESTADO": "BIGINT", "BODY.FILTERS.FECHA_DESDE": "DATE", "BODY.FILTERS.FECHA_HASTA": "DATE", "BODY.FILTERS.NOMBRE_SEDE": "TEXT"}'::jsonb,
    NULL,
    'Periodos academicos sin paginar para reporte. Mismos filtros y mismo gate que el listado.',
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
   AND q.path_template = '/periodos-academicos/reporte'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 12. POST /periodos-evaluacion/anterior  ->  fn_periodo_anteriores_por_sede
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-msr32knc-ca2eh33f',
    'SELECT *
FROM academico_test.fn_periodo_anteriores_por_sede(
    CAST(:BODY.FK_SEDE AS BIGINT),
    CAST(:BODY.EXCLUIR_PERIODO AS BIGINT),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/periodos-evaluacion/anterior', 'SELECT', 'POST',
    '{"BODY.FK_SEDE": "BIGINT", "BODY.EXCLUIR_PERIODO": "BIGINT"}'::jsonb,
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
   AND q.path_template = '/periodos-evaluacion/anterior'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;
