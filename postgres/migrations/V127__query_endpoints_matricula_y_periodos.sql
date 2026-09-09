-- ===========================================================================
-- V127 - registro en public.query (+ role_query) de los endpoints de
--        query-service de matricula directa, su configuracion y utilidades de periodo (V162, V166, V180, V185, V200).
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
--   El texto volcado ya refleja los UPDATE de las migraciones < V127, que
--   sobre base limpia corren antes y no encuentran fila: el estado final es
--   el mismo por ambos caminos.
--
-- NUMERACION
--   Hueco libre V127, verificado contra TODAS las ramas de origin. Se eligio
--   por encima de las migraciones que definen las funciones invocadas (V162, V166, V180, V185, V200)
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
-- 1. PUT /cobertura-academica/matricula/:ID  ->  fn_matricula_directa_eliminar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-mtb2d9k4-cobmatdel1',
    'SELECT academico_test.fn_matricula_directa_eliminar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
) AS resultado;',
    'postgres', false, false,
    m.id_microservice,
    '/cobertura-academica/matricula/:ID', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    NULL,
    'V169 -- baja logica de una matricula: valida dependencias bloqueantes, arrastra socioeconomico y archivos, y resuelve estudiante/acudiente/usuario segun sus otros usos',
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
  JOIN public.role r ON r.name IN ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/cobertura-academica/matricula/:ID'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. PUT /cobertura-academica/matricula/:ID/reactivar  ->  fn_matricula_reactivar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-mtb2d9k4-cobmatrea1',
    'SELECT academico_test.fn_matricula_reactivar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
) AS resultado;',
    'postgres', false, false,
    m.id_microservice,
    '/cobertura-academica/matricula/:ID/reactivar', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    NULL,
    'V173 -- reactivacion de matricula: devuelve a Cursando una matricula cerrada academicamente (Aprobado, Reprobado, Promovido, Reubicado) para corregir o completar informacion. Solo rector/secretaria/jefe de sistema del establecimiento; el super-admin NO puede ejecutarlo',
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
  JOIN public.role r ON r.name IN ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-RECTOR')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/cobertura-academica/matricula/:ID/reactivar'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3. PUT /cobertura-academica/matricula/:ID/reingresar  ->  fn_matricula_reingresar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-mtb2d9k4-cobmatrei1',
    'SELECT academico_test.fn_matricula_reingresar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
) AS resultado;',
    'postgres', false, false,
    m.id_microservice,
    '/cobertura-academica/matricula/:ID/reingresar', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    NULL,
    'V172 -- reingreso de matricula: cambia el estado de Retirado a Cursando y cierra el registro de retiro llenando su FECHA_REINTEGRO. Solo rector/secretaria/jefe de sistema del establecimiento; el super-admin NO puede ejecutarlo',
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
  JOIN public.role r ON r.name IN ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-RECTOR')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/cobertura-academica/matricula/:ID/reingresar'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 4. PUT /cobertura-academica/matricula/:ID/retirar  ->  fn_matricula_retirar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-mtb2d9k4-cobmatret1',
    'SELECT academico_test.fn_matricula_retirar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
) AS resultado;',
    'postgres', false, false,
    m.id_microservice,
    '/cobertura-academica/matricula/:ID/retirar', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    NULL,
    'V171 -- retiro de matricula: cambia el estado de Cursando a Retirado conservando toda la informacion. Solo rector/secretaria/jefe de sistema del establecimiento; el super-admin NO puede ejecutarlo',
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
  JOIN public.role r ON r.name IN ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-RECTOR')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/cobertura-academica/matricula/:ID/retirar'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 5. POST /cobertura-academica/matricula/bulk-delete  ->  fn_matricula_directa_eliminar_bulk
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-mtb2d9k4-cobmatdel2',
    'SELECT * FROM academico_test.fn_matricula_directa_eliminar_bulk(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.IDS AS BIGINT[])
);',
    'postgres', false, false,
    m.id_microservice,
    '/cobertura-academica/matricula/bulk-delete', 'SELECT', 'POST',
    '{"BODY.IDS": "BIGINT[]"}'::jsonb,
    NULL,
    'V169 -- baja logica masiva de matriculas: procesa cada PK por separado y devuelve status y detalle por cada una; una que falle no detiene las demas',
    NULL, NULL,
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

-- Sin filas en role_query en el catalogo vivo: el endpoint no esta
-- expuesto a ningun rol todavia.

-- ---------------------------------------------------------------------------
-- 6. GET /matricula/configuracion  ->  fn_matricula_config_obtener
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-matcfg-obtener-v1',
    'SELECT academico_test.fn_matricula_config_obtener(
        public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
    ) AS config;',
    'postgres', false, false,
    m.id_microservice,
    '/matricula/configuracion', 'SELECT', 'GET',
    '{}'::jsonb,
    NULL,
    'Cobertura Matricula (CU-86e2z8aff): configuracion de matricula del establecimiento del solicitante (rector / secretaria / jefe de sistema, resuelto por fn_matricula_config_ee_solicitante). Devuelve JSONB { fk_establecimiento, establecimiento, pk_matricula_config, campos:[{fk_campo,nombre,editable,requerido,visible}] }. 42501 si no tiene rol; 22023 si administra 2+ establecimientos.',
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
  JOIN public.role r ON r.name IN ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/matricula/configuracion'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 7. PUT /matricula/configuracion/campo/:ID  ->  fn_matricula_config_editar_campo
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-matcfg-editcampo-v1',
    'SELECT academico_test.fn_matricula_config_editar_campo(
        public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
        CAST(:PARAM.ID AS BIGINT),
        CASE
            WHEN CAST(:BODY.REQUERIDO AS BOOLEAN) IS NULL THEN NULL
            WHEN CAST(:BODY.REQUERIDO AS BOOLEAN) THEN ''S''
            ELSE ''N''
        END::academico_test.bool_sn,
        CASE
            WHEN CAST(:BODY.VISIBLE AS BOOLEAN) IS NULL THEN NULL
            WHEN CAST(:BODY.VISIBLE AS BOOLEAN) THEN ''S''
            ELSE ''N''
        END::academico_test.bool_sn
    ) AS config;',
    'postgres', false, false,
    m.id_microservice,
    '/matricula/configuracion/campo/:ID', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT", "BODY.VISIBLE": "BOOLEAN", "BODY.REQUERIDO": "BOOLEAN"}'::jsonb,
    NULL,
    'Cobertura Matricula (CU-86e2z8aff): edita requerido/visible de UN campo (PARAM.ID = fk_campo) en la config de matricula del establecimiento del solicitante (rector / secretaria / jefe de sistema). Body { requerido?: bool, visible?: bool } -- al menos uno; el ausente no se toca. Errores: 42501 sin rol o campo no editable (EDITABLE=N); 23503 campo inexistente/inactivo; 22023 parametros invalidos. Devuelve la config completa ya actualizada (mismo shape que GET /matricula/configuracion).',
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
  JOIN public.role r ON r.name IN ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-RECTOR')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/matricula/configuracion/campo/:ID'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 8. POST /matricula/query  ->  fn_matricula_listar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-mtc0mvvz-mlz97d71',
    'SELECT * FROM academico_test.fn_matricula_listar(
              p_search     => CAST(:BODY.SEARCH AS TEXT),
              p_statuses   => CAST(:BODY.STATUSES AS TEXT[]),
              p_campus     => CAST(:BODY.CAMPUS AS TEXT),
              p_shift      => CAST(:BODY.SHIFT AS TEXT),
              p_grade      => CAST(:BODY.GRADE AS INT),
              p_group      => CAST(:BODY.GROUP AS TEXT),
              p_page_index => CAST(:BODY.PAGEINDEX AS INT),
              p_page_size  => CAST(:BODY.PAGESIZE AS INT),
              p_pk_usuario => public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
              p_sort_by    => CAST(:BODY.SORTBY AS TEXT),
              p_sort_dir   => CAST(:BODY.SORTDIR AS TEXT)
          )',
    'postgres', false, false,
    m.id_microservice,
    '/matricula/query', 'SELECT', 'POST',
    '{"BODY.GRADE": "INTEGER", "BODY.GROUP": "TEXT", "BODY.SHIFT": "TEXT", "BODY.CAMPUS": "TEXT", "BODY.SEARCH": "TEXT", "BODY.SORTBY": "TEXT", "BODY.SORTDIR": "TEXT", "BODY.PAGESIZE": "INTEGER", "BODY.STATUSES": "TEXT[]", "BODY.PAGEINDEX": "INTEGER"}'::jsonb,
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
  JOIN public.role r ON r.name IN ('CEVAL-COORDINADOR', 'CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/matricula/query'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 9. POST /periodos/resolver-matricula  ->  fn_periodo_resolver_matricula
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-mth98azq-k12jz84t',
    'SELECT * FROM academico_test.fn_periodo_resolver_matricula(
    CAST(:BODY.FK_SEDE AS BIGINT),
    CAST(:BODY.FK_TLV_JORNADA AS BIGINT),
      public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
) AS periodo_id;',
    'postgres', false, false,
    m.id_microservice,
    '/periodos/resolver-matricula', 'SELECT', 'POST',
    '{"BODY.FK_SEDE": "BIGINT", "BODY.FK_TLV_JORNADA": "BIGINT"}'::jsonb,
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
   AND q.path_template = '/periodos/resolver-matricula'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 10. POST /sedes/jornadas-activas  ->  fn_jornadas_activas_por_sede
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-mt7h6rv2-chr2nujw',
    'SELECT * FROM academico_test.fn_jornadas_activas_por_sede(
      CAST(:BODY.FK_SEDE AS BIGINT),
      public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
  );',
    'postgres', false, false,
    m.id_microservice,
    '/sedes/jornadas-activas', 'SELECT', 'POST',
    '{"BODY.FK_SEDE": "BIGINT!"}'::jsonb,
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
   AND q.path_template = '/sedes/jornadas-activas'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 11. POST /sedes/tiene-periodos  ->  fn_sede_tiene_periodos
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-mt7h7geu-774e2yd0',
    'SELECT academico_test.fn_sede_tiene_periodos(CAST(:BODY.FK_SEDE AS BIGINT)) AS tiene_periodos;',
    'postgres', false, false,
    m.id_microservice,
    '/sedes/tiene-periodos', 'SELECT', 'POST',
    '{"BODY.FK_SEDE": "BIGINT"}'::jsonb,
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
   AND q.path_template = '/sedes/tiene-periodos'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 12. GET /usuarios/permisos-menu  ->  fn_usuario_permisos_menu
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'c12abb21-526e-453d-917b-6d3e994cf61e',
    'SELECT * FROM academico_test.fn_usuario_permisos_menu(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/usuarios/permisos-menu', 'SELECT', 'GET',
    '{}'::jsonb,
    NULL,
    'V131 -- permisos de menu (crear/editar/eliminar/ver) del usuario, para que el front decida que botones mostrar segun su rol',
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
  JOIN public.role r ON r.name IN ('CEVAL-ACUDIENTE', 'CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-COORDINADOR', 'CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'CEVAL-DIRECTOR_GRUPO', 'CEVAL-DOCENTE', 'CEVAL-ESTUDIANTE', 'CEVAL-JEFE_AREA', 'CEVAL-JEFE_AREA_CALIDAD', 'CEVAL-JEFE_AREA_COBERTURA', 'CEVAL-JEFE_AREA_PLANEACION', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-PSICO_ORIENTADOR', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN', 'SSO-USER')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/usuarios/permisos-menu'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;
