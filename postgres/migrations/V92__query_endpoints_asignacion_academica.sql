-- ===========================================================================
-- V92 - registro en public.query (+ role_query) de los endpoints de
--        query-service de asignacion academica de docentes (V46).
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
--   El texto volcado ya refleja los UPDATE de las migraciones < V92, que
--   sobre base limpia corren antes y no encuentran fila: el estado final es
--   el mismo por ambos caminos.
--
-- NUMERACION
--   Hueco libre V92, verificado contra TODAS las ramas de origin. Se eligio
--   por encima de las migraciones que definen las funciones invocadas (V46)
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
-- 1. POST /asignaciones  ->  fn_asignacion_guardar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msp5c6ax-v7v3bgi0',
    'SELECT academico_test.fn_asignacion_guardar(
    CAST(:BODY.ACADEMIC_PERIOD_ID AS BIGINT),
    CAST(:BODY.FK_FUNCIONARIO AS BIGINT),
    CAST(:BODY.SUBJECT_IDS AS TEXT[]),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
) AS cantidad;',
    'postgres', false, false,
    m.id_microservice,
    '/asignaciones', 'SELECT', 'POST',
    '{"BODY.SUBJECT_IDS": "TEXT[]", "BODY.FK_FUNCIONARIO": "BIGINT", "BODY.ACADEMIC_PERIOD_ID": "BIGINT"}'::jsonb,
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
   AND q.path_template = '/asignaciones'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. GET /asignaciones/:ACADEMIC_PERIOD_ID/docente/:ID  ->  fn_asignacion_docente
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msp5gjov-exllt95c',
    'SELECT *
FROM academico_test.fn_asignacion_docente(
    CAST(:PARAM.ACADEMIC_PERIOD_ID AS BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/asignaciones/:ACADEMIC_PERIOD_ID/docente/:ID', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT", "PARAM.ACADEMIC_PERIOD_ID": "BIGINT"}'::jsonb,
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
   AND q.path_template = '/asignaciones/:ACADEMIC_PERIOD_ID/docente/:ID'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3. GET /asignaciones/docentes/:ID  ->  fn_asignacion_docente_listar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msp5j0bc-g1ip85b3',
    'SELECT *
FROM academico_test.fn_asignacion_docente_listar(
    CAST(:PARAM.ID AS BIGINT),
    CAST(:QUERY.ESTADO AS TEXT),
    CAST(:QUERY.FILTRO AS TEXT),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/asignaciones/docentes/:ID', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT", "QUERY.ESTADO": "TEXT", "QUERY.FILTRO": "TEXT"}'::jsonb,
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
   AND q.path_template = '/asignaciones/docentes/:ID'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 4. POST /asignaciones/docentes/:PERIODO_ACADEMICO_ID  ->  fn_asignacion_docente_listar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-1425f10b-9775ae39',
    'SELECT * FROM academico_test.fn_asignacion_docente_listar(
    CAST(:PARAM.PERIODO_ACADEMICO_ID AS BIGINT),
    CAST(:BODY.ESTADO AS TEXT),
    CAST(:BODY.FILTRO AS TEXT),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.PAGE_INDEX AS INT),
    CAST(:BODY.PAGE_SIZE AS INT),
    CAST(:BODY.SORT_BY AS TEXT),
    CAST(:BODY.SORT_DIR AS TEXT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/asignaciones/docentes/:PERIODO_ACADEMICO_ID', 'SELECT', 'POST',
    '{"BODY.ESTADO": "TEXT", "BODY.FILTRO": "TEXT", "BODY.SORT_BY": "TEXT", "BODY.SORT_DIR": "TEXT", "BODY.PAGE_SIZE": "INTEGER", "BODY.PAGE_INDEX": "INTEGER", "PARAM.PERIODO_ACADEMICO_ID": "BIGINT!"}'::jsonb,
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
   AND q.path_template = '/asignaciones/docentes/:PERIODO_ACADEMICO_ID'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 5. GET /asignaciones/pool/:ACADEMIC_PERIOD_ID  ->  fn_asignacion_pool
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msp5fbuq-7z6c8km2',
    'SELECT *
FROM academico_test.fn_asignacion_pool(
    CAST(:PARAM.ACADEMIC_PERIOD_ID AS BIGINT),
    CAST(:QUERY.FILTRO AS TEXT),
    CAST(:QUERY.SOLO_SIN_DOCENTE AS BOOLEAN),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/asignaciones/pool/:ACADEMIC_PERIOD_ID', 'SELECT', 'GET',
    '{"QUERY.FILTRO": "TEXT", "QUERY.SOLO_SIN_DOCENTE": "BOOLEAN", "PARAM.ACADEMIC_PERIOD_ID": "BIGINT!"}'::jsonb,
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
   AND q.path_template = '/asignaciones/pool/:ACADEMIC_PERIOD_ID'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;
