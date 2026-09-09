-- ===========================================================================
-- V78 - registro en public.query (+ role_query) de los endpoints de
--        query-service de escalas de valoracion (V42).
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
--   El texto volcado ya refleja los UPDATE de las migraciones < V78, que
--   sobre base limpia corren antes y no encuentran fila: el estado final es
--   el mismo por ambos caminos.
--
-- NUMERACION
--   Hueco libre V78, verificado contra TODAS las ramas de origin. Se eligio
--   por encima de las migraciones que definen las funciones invocadas (V42)
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
-- 1. POST /escalas  ->  fn_escala_guardar_bulk
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msp2oiwj-fdnka7e1',
    'SELECT academico_test.fn_escala_guardar_bulk(
    CAST(:BODY.ACADEMIC_PERIOD_ID AS BIGINT),
    CAST(:BODY.TEACHING_LEVEL_IDS AS BIGINT[]),
    CAST(:BODY_RAW.SCALES AS JSONB),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
) AS cantidad;',
    'postgres', false, false,
    m.id_microservice,
    '/escalas', 'SELECT', 'POST',
    '{"BODY.SCALES": "JSONB", "BODY_RAW.SCALES": "JSONB", "BODY.ACADEMIC_PERIOD_ID": "BIGINT", "BODY.TEACHING_LEVEL_IDS": "BIGINT[]"}'::jsonb,
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
   AND q.path_template = '/escalas'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. PUT /escalas/:ID  ->  fn_escala_eliminar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msp2ph9x-6cnry9b2',
    'SELECT academico_test.fn_escala_eliminar(
    CAST(:PARAM.ID AS BIGINT),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
) AS id_eliminado;',
    'postgres', false, false,
    m.id_microservice,
    '/escalas/:ID', 'SELECT', 'PUT',
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
   AND q.path_template = '/escalas/:ID'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3. POST /escalas/:PERIODO_ACADEMICO_ID  ->  fn_escala_listar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msp2nnaz-t2lc7h4n',
    'SELECT *
FROM academico_test.fn_escala_listar(
    CAST(:PARAM.PERIODO_ACADEMICO_ID AS BIGINT),
    CAST(:BODY.FILTRO AS TEXT),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.TEACHING_LEVEL_ID AS BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/escalas/:PERIODO_ACADEMICO_ID', 'SELECT', 'POST',
    '{"BODY.FILTRO": "TEXT", "BODY.TEACHING_LEVEL_ID": "BIGINT", "PARAM.PERIODO_ACADEMICO_ID": "BIGINT!"}'::jsonb,
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
  JOIN public.role r ON r.name IN ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-COORDINADOR', 'CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'CEVAL-DOCENTE', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/escalas/:PERIODO_ACADEMICO_ID'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 4. POST /escalas/valoraciones/bulk-delete  ->  fn_escala_valoracion_bulk_delete
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-mt1o1hwv-7xw0ph8p',
    'SELECT * FROM academico_test.fn_escala_valoracion_bulk_delete(
    CAST(:BODY.IDS AS BIGINT[]), public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/escalas/valoraciones/bulk-delete', 'SELECT', 'POST',
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
   AND q.path_template = '/escalas/valoraciones/bulk-delete'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 5. PUT /periodos/:PERIODO_ID/niveles/:NIVEL_ID/escala  ->  fn_escala_nivel_soft_delete
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-mssnnhno-amudol6b',
    'SELECT *
FROM academico_test.fn_escala_nivel_soft_delete(
    CAST(:PARAM.PERIODO_ID AS BIGINT),
    CAST(:PARAM.NIVEL_ID AS BIGINT),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);
',
    'postgres', false, false,
    m.id_microservice,
    '/periodos/:PERIODO_ID/niveles/:NIVEL_ID/escala', 'SELECT', 'PUT',
    '{"PARAM.NIVEL_ID": "BIGINT", "PARAM.PERIODO_ID": "BIGINT"}'::jsonb,
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
   AND q.path_template = '/periodos/:PERIODO_ID/niveles/:NIVEL_ID/escala'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;
