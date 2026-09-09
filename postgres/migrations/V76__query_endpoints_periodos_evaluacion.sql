-- ===========================================================================
-- V76 - registro en public.query (+ role_query) de los endpoints de
--        query-service de periodos de evaluacion y criterio de evaluacion (V38, V41).
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
--   El texto volcado ya refleja los UPDATE de las migraciones < V76, que
--   sobre base limpia corren antes y no encuentran fila: el estado final es
--   el mismo por ambos caminos.
--
-- NUMERACION
--   Hueco libre V76, verificado contra TODAS las ramas de origin. Se eligio
--   por encima de las migraciones que definen las funciones invocadas (V38, V41)
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
-- 1. GET /catalogos/nodos-curriculares  ->  fn_nodo_curricular_listar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msp2cnu2-p34rijlb',
    'SELECT *
FROM academico_test.fn_nodo_curricular_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/catalogos/nodos-curriculares', 'SELECT', 'GET',
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
   AND q.path_template = '/catalogos/nodos-curriculares'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. POST /periodo-evaluacion  ->  fn_periodo_eval_crear
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msntdig0-ue2q6veu',
    'SELECT academico_test.fn_periodo_eval_crear(
    CAST(:BODY.FK_PERIODO AS BIGINT),
    CAST(:BODY.CODIGO AS VARCHAR),
    CAST(:BODY.NOMBRE AS VARCHAR),
    CAST(:BODY.ABREVIACION AS VARCHAR),
    CAST(:BODY.FECHA_INICIO AS DATE),
    CAST(:BODY.FECHA_FIN AS DATE),
    CAST(:BODY.FK_ESTADO AS BIGINT),
    CAST(:BODY.PORCENTAJE AS NUMERIC),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/periodo-evaluacion', 'SELECT', 'POST',
    '{"BODY.CODIGO": "VARCHAR", "BODY.NOMBRE": "VARCHAR", "BODY.FECHA_FIN": "DATE", "BODY.FK_ESTADO": "BIGINT", "BODY.FK_PERIODO": "BIGINT", "BODY.PORCENTAJE": "NUMERIC", "BODY.ABREVIACION": "VARCHAR", "BODY.FECHA_INICIO": "DATE"}'::jsonb,
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
   AND q.path_template = '/periodo-evaluacion'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3. PUT /periodo-evaluacion/:ID  ->  fn_periodo_eval_soft_delete
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msntjhis-92y5w3na',
    'SELECT academico_test.fn_periodo_eval_soft_delete(
    CAST(:PARAM.ID AS BIGINT),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/periodo-evaluacion/:ID', 'SELECT', 'PUT',
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
   AND q.path_template = '/periodo-evaluacion/:ID'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 4. POST /periodo-evaluacion/bulk-delete  ->  fn_periodo_eval_bulk_delete
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msntnybu-wdhdby32',
    'SELECT *
FROM academico_test.fn_periodo_eval_bulk_delete(
    CAST(:BODY.IDS AS BIGINT[]),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/periodo-evaluacion/bulk-delete', 'SELECT', 'POST',
    '{"BODY.IDS": "BIGINT[]"}'::jsonb,
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
   AND q.path_template = '/periodo-evaluacion/bulk-delete'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 5. GET /periodo-evaluacion/detalle/:ID  ->  fn_periodo_eval_detalle
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msntn6hp-4s2i793j',
    'SELECT *
FROM academico_test.fn_periodo_eval_detalle(
    CAST(:PARAM.ID AS BIGINT),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/periodo-evaluacion/detalle/:ID', 'SELECT', 'GET',
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
   AND q.path_template = '/periodo-evaluacion/detalle/:ID'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 6. PUT /periodo-evaluacion/editar/:ID  ->  fn_periodo_eval_actualizar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msnth8kn-n6ba8ke1',
    'SELECT academico_test.fn_periodo_eval_actualizar(
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.CODIGO AS VARCHAR),
    CAST(:BODY.NOMBRE AS VARCHAR),
    CAST(:BODY.ABREVIACION AS VARCHAR),
    CAST(:BODY.FECHA_INICIO AS DATE),
    CAST(:BODY.FECHA_FIN AS DATE),
    CAST(:BODY.FK_ESTADO AS BIGINT),
    CAST(:BODY.PORCENTAJE AS NUMERIC),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/periodo-evaluacion/editar/:ID', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT", "BODY.CODIGO": "VARCHAR", "BODY.NOMBRE": "VARCHAR", "BODY.FECHA_FIN": "DATE", "BODY.FK_ESTADO": "BIGINT", "BODY.PORCENTAJE": "NUMERIC", "BODY.ABREVIACION": "VARCHAR", "BODY.FECHA_INICIO": "DATE"}'::jsonb,
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
   AND q.path_template = '/periodo-evaluacion/editar/:ID'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 7. POST /periodo-evaluacion/query  ->  fn_periodo_eval_listar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msntkyka-1kijq0mp',
    'SELECT *
FROM academico_test.fn_periodo_eval_listar(
    CAST(:BODY.FK_PERIODO AS BIGINT),
    CAST(:BODY.FILTRO AS TEXT),
    CAST(:BODY.PAGEINDEX AS INT),
    CAST(:BODY.PAGESIZE AS INT),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.SORT_BY AS TEXT),
    CAST(:BODY.SORT_DIR AS TEXT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/periodo-evaluacion/query', 'SELECT', 'POST',
    '{"BODY.FILTRO": "TEXT", "BODY.SORT_BY": "TEXT", "BODY.PAGESIZE": "INTEGER", "BODY.SORT_DIR": "TEXT", "BODY.PAGEINDEX": "INTEGER", "BODY.FK_PERIODO": "BIGINT"}'::jsonb,
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
   AND q.path_template = '/periodo-evaluacion/query'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 8. POST /periodo-evaluacion/reporte  ->  fn_periodo_eval_listar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'eval-col-periodos-evaluacion-reporte-001',
    'SELECT * FROM academico_test.fn_periodo_eval_listar(
    CAST(:BODY.FILTERS.FK_PERIODO AS BIGINT),
    CAST(:BODY.FILTERS.FILTRO AS TEXT),
    NULL::INTEGER, NULL::INTEGER,
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.SORTING.ID AS TEXT),
    CAST(:BODY.SORTING.DESC AS TEXT)
) t
WHERE CAST(:BODY.FILTERS.IDS AS BIGINT[]) IS NULL
   OR t.id = ANY(CAST(:BODY.FILTERS.IDS AS BIGINT[]));',
    'postgres', false, false,
    m.id_microservice,
    '/periodo-evaluacion/reporte', 'SELECT', 'POST',
    '{"BODY.SORTING.ID": "TEXT", "BODY.FILTERS.IDS": "BIGINT[]", "BODY.SORTING.DESC": "TEXT", "BODY.FILTERS.FILTRO": "TEXT", "BODY.FILTERS.FK_PERIODO": "BIGINT"}'::jsonb,
    NULL,
    'Periodos de evaluacion sin paginar para reporte. Mismos filtros y mismo gate que el listado.',
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
   AND q.path_template = '/periodo-evaluacion/reporte'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 9. GET /periodos/:ID/criterio-evaluacion  ->  fn_criterio_eval_obtener
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msp2dtzb-v168yf13',
    'SELECT *
FROM academico_test.fn_criterio_eval_obtener(
    CAST(:PARAM.ID AS BIGINT),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/periodos/:ID/criterio-evaluacion', 'SELECT', 'GET',
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
   AND q.path_template = '/periodos/:ID/criterio-evaluacion'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 10. PUT /periodos/:ID/criterio-evaluacion  ->  fn_criterio_eval_actualizar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msp2emmg-jxl0l988',
    'SELECT academico_test.fn_criterio_eval_actualizar(
    CAST(:PARAM.ID AS BIGINT),

    CAST(:BODY.GRADING_FORMAT AS BIGINT),
    CAST(:BODY.GRADING_SCALE AS BIGINT),
    CAST(:BODY.SET_GRADING_SCALE AS BOOLEAN),

    CAST(:BODY.PERIOD_CALC_ELEMENTS AS BIGINT),

    CAST(:BODY.MODIF_FINAL_PERACA AS BIGINT),
    CAST(:BODY.SUBJECT_GRADE_CRITERIA AS BIGINT),
    CAST(:BODY.FINAL_GRADE_CRITERIA AS BIGINT),
    CAST(:BODY.AREA_GRADE_CRITERIA AS BIGINT),

    CAST(:BODY.STUDENT_WO_GRADES AS BIGINT),

    CAST(:BODY.ROUNDING_MODE AS BIGINT),

    CAST(:BODY.INITIAL_GRADE AS NUMERIC),
    CAST(:BODY.MAX_RECOVERY_GRADE AS NUMERIC),

    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
) AS id;',
    'postgres', false, false,
    m.id_microservice,
    '/periodos/:ID/criterio-evaluacion', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT", "BODY.GRADING_SCALE": "BIGINT", "BODY.INITIAL_GRADE": "NUMERIC", "BODY.ROUNDING_MODE": "NUMERIC", "BODY.GRADING_FORMAT": "BIGINT", "BODY.SET_GRADING_SCALE": "BOOLEAN", "BODY.STUDENT_WO_GRADES": "BIGINT", "BODY.MAX_RECOVERY_GRADE": "NUMERIC", "BODY.MODIF_FINAL_PERACA": "BIGINT", "BODY.AREA_GRADE_CRITERIA": "BIGINT", "BODY.FINAL_GRADE_CRITERIA": "BIGINT", "BODY.PERIOD_CALC_ELEMENTS": "BIGINT", "BODY.SUBJECT_GRADE_CRITERIA": "BIGINT"}'::jsonb,
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
   AND q.path_template = '/periodos/:ID/criterio-evaluacion'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 11. GET /periodos/:ID/criterio-promocion  ->  fn_criterio_prom_obtener
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msp2c5uj-lcdywzqj',
    'SELECT *
FROM academico_test.fn_criterio_prom_obtener(
    CAST(:PARAM.ID AS BIGINT),
    CAST(:QUERY.FK_GRADO AS BIGINT),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/periodos/:ID/criterio-promocion', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT", "QUERY.FK_GRADO": "BIGINT", "PARAM.FK_PERIODO": "BIGINT"}'::jsonb,
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
   AND q.path_template = '/periodos/:ID/criterio-promocion'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 12. PUT /periodos/:ID/criterio-promocion  ->  fn_criterio_prom_guardar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msp28jp6-sy5f15co',
    'SELECT academico_test.fn_criterio_prom_guardar(
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.FK_GRADO AS BIGINT),
    CAST(:BODY.NODO_CURRICULAR AS academico_test.nodo_curricular),
    CAST(:BODY.CANTIDAD_NIVELAR AS NUMERIC),
    CAST(:BODY.ASIGNATURA_OBLIGATORIA AS academico_test.bool_sn),
    CAST(:BODY.APROBACION_PROMEDIO AS academico_test.bool_sn),
    CAST(:BODY.DESEMPENHO_MIN_GENERAL AS NUMERIC),
    CAST(:BODY.DESEMPENHO_MINIMO AS NUMERIC),
    CAST(:BODY.MAX_ASIG_PROMEDIO AS NUMERIC),
    CAST(:BODY.MINIMO_INASISTENCIAS AS NUMERIC),
    CAST(:BODY.MAX_ASIG_NIVELAR_PROM AS NUMERIC),
    CAST(:BODY.OBLIGATORIAS AS BIGINT[]),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
) AS id;',
    'postgres', false, false,
    m.id_microservice,
    '/periodos/:ID/criterio-promocion', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT", "BODY.FK_GRADO": "BIGINT", "BODY.OBLIGATORIAS": "BIGINT[]", "BODY.NODO_CURRICULAR": "NODO_CURRICULAR", "BODY.CANTIDAD_NIVELAR": "NUMERIC", "BODY.DESEMPENHO_MINIMO": "NUMERIC", "BODY.MAX_ASIG_PROMEDIO": "NUMERIC", "BODY.APROBACION_PROMEDIO": "BOOL_SN", "BODY.MINIMO_INASISTENCIAS": "NUMERIC", "BODY.MAX_ASIG_NIVELAR_PROM": "NUMERIC", "BODY.ASIGNATURA_OBLIGATORIA": "BOOL_SN", "BODY.DESEMPENHO_MIN_GENERAL": "NUMERIC"}'::jsonb,
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
   AND q.path_template = '/periodos/:ID/criterio-promocion'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;
