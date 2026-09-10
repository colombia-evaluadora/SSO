-- ===========================================================================
-- V80 - registro en public.query (+ role_query) de los endpoints de
--        query-service de plan de estudio por grado y horarios (V44, V45).
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
--   El texto volcado ya refleja los UPDATE de las migraciones < V80, que
--   sobre base limpia corren antes y no encuentran fila: el estado final es
--   el mismo por ambos caminos.
--
-- NUMERACION
--   Hueco libre V80, verificado contra TODAS las ramas de origin. Se eligio
--   por encima de las migraciones que definen las funciones invocadas (V44, V45)
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
-- 1. POST /grados/:ID/plan-asignaturas  ->  fn_plan_agregar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msp513gr-wm68mep6',
    'SELECT academico_test.fn_plan_agregar(
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.FK_ASIGNATURA AS BIGINT),
    CAST(:BODY.NUMERO_HORA AS NUMERIC),
    CAST(:BODY.INFLUENCIA_AREA AS NUMERIC),
    CAST(:BODY.NUMERO_CREDITO AS BIGINT),
    CAST(:BODY.INFLUYE_DESEMPENO AS BOOLEAN),
    CAST(:BODY.MATRICULA_OBLIGATORIA AS BOOLEAN),
    CAST(:BODY.APROBACION_OBLIGATORIA AS BOOLEAN),
    CAST(:BODY.FK_FORMATO_CALIF AS BIGINT),
    CAST(:BODY.FK_CRITERIO_NOTA AS BIGINT),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
) AS id;',
    'postgres', false, false,
    m.id_microservice,
    '/grados/:ID/plan-asignaturas', 'SELECT', 'POST',
    '{"PARAM.ID": "BIGINT", "BODY.NUMERO_HORA": "NUMERIC", "BODY.FK_ASIGNATURA": "BIGINT", "BODY.NUMERO_CREDITO": "BIGINT", "BODY.INFLUENCIA_AREA": "NUMERIC", "BODY.FK_CRITERIO_NOTA": "BIGINT", "BODY.FK_FORMATO_CALIF": "BIGINT", "BODY.INFLUYE_DESEMPENO": "BOOLEAN", "BODY.MATRICULA_OBLIGATORIA": "BOOLEAN", "BODY.APROBACION_OBLIGATORIA": "BOOLEAN"}'::jsonb,
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
   AND q.path_template = '/grados/:ID/plan-asignaturas'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. POST /grados/:ID/plan-asignaturas/query  ->  fn_plan_listar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msp562r9-gvdsa24o',
    'SELECT *
FROM academico_test.fn_plan_listar(
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.FILTRO AS TEXT),
    CAST(:BODY.PAGE_INDEX AS INT),
    CAST(:BODY.PAGE_SIZE AS INT),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.SORTING_ID AS TEXT),
    CAST(:BODY.SORTING_DESC AS TEXT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/grados/:ID/plan-asignaturas/query', 'SELECT', 'POST',
    '{"PARAM.ID": "BIGINT", "BODY.FILTRO": "TEXT", "BODY.PAGE_SIZE": "INTEGER", "BODY.PAGE_INDEX": "INTEGER", "BODY.SORTING_ID": "TEXT", "BODY.SORTING_DESC": "TEXT"}'::jsonb,
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
  JOIN public.role r ON r.name IN ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-COORDINADOR', 'CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'CEVAL-JEFE_AREA_PLANEACION', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-RECTOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/grados/:ID/plan-asignaturas/query'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3. GET /grados/:ID/plan-disponibles  ->  fn_plan_asignaturas_disponibles_listar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msp57p9y-gy528cm6',
    'SELECT *
FROM academico_test.fn_plan_asignaturas_disponibles_listar(
    CAST(:PARAM.ID AS BIGINT),
    CAST(:QUERY.FILTRO AS TEXT),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/grados/:ID/plan-disponibles', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT", "QUERY.FILTRO": "TEXT"}'::jsonb,
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
   AND q.path_template = '/grados/:ID/plan-disponibles'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 4. PUT /grados/:ID/plan/eliminar  ->  fn_plan_soft_delete
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msp54qe1-lav6he1e',
    'SELECT academico_test.fn_plan_soft_delete(
    CAST(:PARAM.ID AS BIGINT),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
) AS id;',
    'postgres', false, false,
    m.id_microservice,
    '/grados/:ID/plan/eliminar', 'SELECT', 'PUT',
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
   AND q.path_template = '/grados/:ID/plan/eliminar'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 5. POST /horarios  ->  fn_horario_guardar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msp58y62-bulxdgy5',
    'SELECT academico_test.fn_horario_guardar(
    CAST(:BODY.FK_GRADO AS BIGINT),
    CAST(:BODY_RAW.ENTRIES AS JSONB),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
) AS cantidad;',
    'postgres', false, false,
    m.id_microservice,
    '/horarios', 'SELECT', 'POST',
    '{"BODY.ENTRIES": "JSONB", "BODY.FK_GRADO": "BIGINT", "BODY_RAW.ENTRIES": "JSONB"}'::jsonb,
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
   AND q.path_template = '/horarios'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 6. GET /horarios/:FK_GRADO  ->  fn_horario_listar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msp5atu7-vrfs051h',
    'SELECT * FROM academico_test.fn_horario_listar(
    CAST(:PARAM.FK_GRADO AS BIGINT),
    CAST(:QUERY.FK_GRUPO AS BIGINT),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
)',
    'postgres', false, false,
    m.id_microservice,
    '/horarios/:FK_GRADO', 'SELECT', 'GET',
    '{"PARAM.FK_GRADO": "BIGINT!", "QUERY.FK_GRUPO": "BIGINT"}'::jsonb,
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
   AND q.path_template = '/horarios/:FK_GRADO'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 7. GET /horarios/asignaturas  ->  fn_horario_asignaturas
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msp5bceo-klt3xam6',
    'SELECT *
FROM academico_test.fn_horario_asignaturas(
    CAST(:QUERY.FK_GRADO AS BIGINT),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/horarios/asignaturas', 'SELECT', 'GET',
    '{"QUERY.FK_GRADO": "BIGINT"}'::jsonb,
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
   AND q.path_template = '/horarios/asignaturas'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 8. GET /plan-asignaturas/:ID  ->  fn_plan_obtener
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msp571hs-2oonor2r',
    'SELECT *
FROM academico_test.fn_plan_obtener(
    CAST(:PARAM.ID AS BIGINT),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/plan-asignaturas/:ID', 'SELECT', 'GET',
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
   AND q.path_template = '/plan-asignaturas/:ID'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 9. PUT /plan-asignaturas/:ID  ->  fn_plan_actualizar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msp52qj5-vg0pzk4n',
    'SELECT academico_test.fn_plan_actualizar(
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.FK_ASIGNATURA AS BIGINT),
    CAST(:BODY.NUMERO_HORA AS NUMERIC),
    CAST(:BODY.INFLUENCIA_AREA AS NUMERIC),
    CAST(:BODY.NUMERO_CREDITO AS BIGINT),
    CAST(:BODY.INFLUYE_DESEMPENO AS BOOLEAN),
    CAST(:BODY.MATRICULA_OBLIGATORIA AS BOOLEAN),
    CAST(:BODY.APROBACION_OBLIGATORIA AS BOOLEAN),
    CAST(:BODY.FK_FORMATO_CALIF AS BIGINT),
    CAST(:BODY.FK_CRITERIO_NOTA AS BIGINT),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
) AS id;',
    'postgres', false, false,
    m.id_microservice,
    '/plan-asignaturas/:ID', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT", "BODY.NUMERO_HORA": "NUMERIC", "BODY.FK_ASIGNATURA": "BIGINT", "BODY.NUMERO_CREDITO": "BIGINT", "BODY.INFLUENCIA_AREA": "NUMERIC", "BODY.FK_CRITERIO_NOTA": "BIGINT", "BODY.FK_FORMATO_CALIF": "BIGINT", "BODY.INFLUYE_DESEMPENO": "BOOLEAN", "BODY.MATRICULA_OBLIGATORIA": "BOOLEAN", "BODY.APROBACION_OBLIGATORIA": "BOOLEAN"}'::jsonb,
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
   AND q.path_template = '/plan-asignaturas/:ID'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 10. PUT /plan-asignaturas/:ID/eliminar  ->  fn_plan_eliminar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msp541e8-vm32e2tl',
    'SELECT academico_test.fn_plan_eliminar(
    CAST(:PARAM.ID AS BIGINT),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
) AS id;',
    'postgres', false, false,
    m.id_microservice,
    '/plan-asignaturas/:ID/eliminar', 'SELECT', 'PUT',
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
   AND q.path_template = '/plan-asignaturas/:ID/eliminar'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 11. POST /plan-asignaturas/bulk-delete  ->  fn_plan_asignatura_bulk_delete
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-mt1peoav-wxhpau2o',
    'SELECT * FROM academico_test.fn_plan_asignatura_bulk_delete(CAST(:BODY.IDS AS BIGINT[]), public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT));',
    'postgres', false, false,
    m.id_microservice,
    '/plan-asignaturas/bulk-delete', 'SELECT', 'POST',
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
  JOIN public.role r ON r.name IN ('CEVAL-COORDINADOR', 'CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/plan-asignaturas/bulk-delete'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;
