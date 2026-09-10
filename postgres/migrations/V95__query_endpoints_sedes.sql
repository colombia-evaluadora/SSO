-- ===========================================================================
-- V95 - registro en public.query (+ role_query) de los endpoints de
--        query-service de sedes (V52).
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
--   El texto volcado ya refleja los UPDATE de las migraciones < V95, que
--   sobre base limpia corren antes y no encuentran fila: el estado final es
--   el mismo por ambos caminos.
--
-- NUMERACION
--   Hueco libre V95, verificado contra TODAS las ramas de origin. Se eligio
--   por encima de las migraciones que definen las funciones invocadas (V52)
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
-- 1. POST /establecimientos/sedes  ->  fn_sed_crear
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msq6pxjf-me894c3k',
    'SELECT academico_test.fn_sed_crear(
    p_codigo => CAST(:BODY.DANE AS VARCHAR),
    p_nombre => CAST(:BODY.NAME AS VARCHAR),
    p_fk_lista_valor_zona => CAST(:BODY.ZONE AS BIGINT),
    p_fk_establecimiento => CAST(:BODY.ESTABLISHMENTID AS BIGINT),
    p_comuna => CAST(:BODY.COMUNE AS VARCHAR),
    p_barrio => CAST(:BODY.NEIGHBORHOOD AS VARCHAR),
    p_direccion => CAST(:BODY.ADDRESS AS VARCHAR),
    p_telefono => CAST(:BODY.PHONE AS VARCHAR),
    p_pk_usuario_solicitante => public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
) AS pk_sede_creada',
    'postgres', false, false,
    m.id_microservice,
    '/establecimientos/sedes', 'SELECT', 'POST',
    '{"BODY.DANE": "VARCHAR", "BODY.NAME": "VARCHAR", "BODY.ZONE": "BIGINT", "BODY.PHONE": "VARCHAR", "BODY.COMUNE": "VARCHAR", "BODY.ADDRESS": "VARCHAR", "BODY.NEIGHBORHOOD": "VARCHAR", "BODY.ESTABLISHMENTID": "BIGINT"}'::jsonb,
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
  JOIN public.role r ON r.name IN ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/establecimientos/sedes'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. GET /establecimientos/sedes/:ID  ->  fn_sed_buscar_por_pk
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msridyb1-23ev0r9f',
    'SELECT
    t.PK_TSEDE,
    t.CODIGO,
    t.NOMBRE,
    t.CONSECUTIVO,
    t.FK_TLV_ZONA,
    t.FK_TESTABLECIMIENTO,
    t.LOCALIDAD,
    t.COMUNA,
    t.BARRIO,
    t.DIRECCION,
    t.TELEFONO,
    t.CREATED_BY,
    t.CREATED_AT,
    t.MODIFIED_BY,
    t.MODIFIED_AT,
    t.ACTIVE
FROM academico_test.fn_sed_buscar_por_pk(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
) AS t;',
    'postgres', false, false,
    m.id_microservice,
    '/establecimientos/sedes/:ID', 'SELECT', 'GET',
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
  JOIN public.role r ON r.name IN ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/establecimientos/sedes/:ID'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3. PATCH /establecimientos/sedes/:ID  ->  fn_sed_actualizar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msq7nc22-itbsybhx',
    'SELECT academico_test.fn_sed_actualizar(
    p_pk_sede => CAST(:PARAM.ID AS BIGINT),
    p_codigo => CAST(:BODY.DANE AS VARCHAR),
    p_nombre => CAST(:BODY.NAME AS VARCHAR),
    p_fk_lista_valor_zona => CAST(:BODY.ZONE AS BIGINT),
    p_comuna => CAST(:BODY.COMUNE AS VARCHAR),
    p_barrio => CAST(:BODY.NEIGHBORHOOD AS VARCHAR),
    p_direccion => CAST(:BODY.ADDRESS AS VARCHAR),
    p_telefono => CAST(:BODY.PHONE AS VARCHAR),
    p_pk_usuario_solicitante => public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
) AS pk_sede_actualizada',
    'postgres', false, false,
    m.id_microservice,
    '/establecimientos/sedes/:ID', 'SELECT', 'PATCH',
    '{"PARAM.ID": "BIGINT", "BODY.DANE": "VARCHAR", "BODY.NAME": "VARCHAR", "BODY.ZONE": "BIGINT", "BODY.PHONE": "VARCHAR", "BODY.COMUNE": "VARCHAR", "BODY.ADDRESS": "VARCHAR", "BODY.NEIGHBORHOOD": "VARCHAR"}'::jsonb,
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
  JOIN public.role r ON r.name IN ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/establecimientos/sedes/:ID'
   AND q.http_method   = 'PATCH'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 4. PUT /establecimientos/sedes/:ID  ->  fn_sed_soft_delete
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msq9hr0h-tkmw4wmn',
    'SELECT academico_test.fn_sed_soft_delete(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
) AS pk_sede_borrada',
    'postgres', false, false,
    m.id_microservice,
    '/establecimientos/sedes/:ID', 'SELECT', 'PUT',
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
  JOIN public.role r ON r.name IN ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/establecimientos/sedes/:ID'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 5. PUT /establecimientos/sedes/bulk-delete  ->  fn_sed_soft_delete_bulk
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msrjz7fg-6g1vzdjm',
    'SELECT * FROM academico_test.fn_sed_soft_delete_bulk(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    :BODY.PKS
);',
    'postgres', false, false,
    m.id_microservice,
    '/establecimientos/sedes/bulk-delete', 'SELECT', 'PUT',
    '{"BODY.PKS": "BIGINT[]"}'::jsonb,
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
  JOIN public.role r ON r.name IN ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/establecimientos/sedes/bulk-delete'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 6. GET /establecimientos/sedes/opciones  ->  fn_sed_listar_todos
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'eval-col-establecimientos-sedes-opciones-001',
    'SELECT * FROM academico_test.fn_sed_listar_todos(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/establecimientos/sedes/opciones', 'SELECT', 'GET',
    '{}'::jsonb,
    NULL,
    'Lista liviana (id+nombre+establecimiento) de todas las sedes que el usuario puede ver, sin paginar. Para selects (dialog de permisos de funcionario, periodo academico).',
    'establecimientos-sedes-opciones', 'DEFAULT'
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
   AND q.path_template = '/establecimientos/sedes/opciones'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 7. POST /establecimientos/sedes/query  ->  fn_sed_listar_paginado
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msq9aw73-qjaksdbn',
    'SELECT * FROM academico_test.fn_sed_listar_paginado(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FILTERS.SEARCH AS VARCHAR),
    CAST(:BODY.FILTERS.ZONES AS VARCHAR[]),
    CAST(:BODY.SORTING.ID AS VARCHAR),
    CAST(:BODY.SORTING.DESC AS BOOLEAN),
    CAST(:BODY.PAGEINDEX AS INTEGER),
    CAST(:BODY.PAGESIZE AS INTEGER)
);',
    'postgres', false, false,
    m.id_microservice,
    '/establecimientos/sedes/query', 'SELECT', 'POST',
    '{"BODY.PAGESIZE": "INTEGER", "BODY.PAGEINDEX": "INTEGER", "BODY.SORTING.ID": "VARCHAR", "BODY.SORTING.DESC": "BOOLEAN", "BODY.FILTERS.ZONES": "TEXT[]", "BODY.FILTERS.SEARCH": "VARCHAR"}'::jsonb,
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
  JOIN public.role r ON r.name IN ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/establecimientos/sedes/query'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 8. POST /establecimientos/sedes/reporte  ->  fn_sed_listar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'eval-col-sedes-reporte-001',
    'SELECT * FROM academico_test.fn_sed_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FILTERS.SEARCH AS VARCHAR),
    CAST(:BODY.FILTERS.ZONES AS VARCHAR[]),
    CAST(:BODY.SORTING.ID AS VARCHAR),
    CAST(:BODY.SORTING.DESC AS BOOLEAN),
    NULL::INTEGER, NULL::INTEGER
) t
WHERE CAST(:BODY.FILTERS.IDS AS BIGINT[]) IS NULL
   OR t.pk_sede = ANY(CAST(:BODY.FILTERS.IDS AS BIGINT[]));',
    'postgres', false, false,
    m.id_microservice,
    '/establecimientos/sedes/reporte', 'SELECT', 'POST',
    '{"BODY.SORTING.ID": "VARCHAR", "BODY.FILTERS.IDS": "BIGINT[]", "BODY.SORTING.DESC": "BOOLEAN", "BODY.FILTERS.ZONES": "TEXT[]", "BODY.FILTERS.SEARCH": "VARCHAR"}'::jsonb,
    NULL,
    'Sedes sin paginar para reporte. Mismos filtros y mismo gate que el listado.',
    NULL, NULL
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
   AND q.path_template = '/establecimientos/sedes/reporte'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ===========================================================================
-- Endpoint que V52 dejo escrito pero COMENTADO.
--
--   Es la causa raiz de este hueco, documentada en el propio archivo: el
--   bloque INSERT esta ahi, entre guiones, con un microservice_id quemado
--   ('8') y un uuid sin generar, anotado como id_query=137 del ambiente de
--   prueba. Nunca corrio. Se registra aqui con el contenido REAL desplegado
--   (uuid del servidor, microservice_id resuelto por serviceid) en vez de
--   descomentarlo: descomentar V52 cambiaria su checksum en todos los
--   entornos ya migrados sin necesidad.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 9. GET /establecimientos/:ID/sedes
--    Sedes de un establecimiento.
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-rbelf97t-zw24zdv8',
    'SELECT * FROM academico_test.fn_sed_por_establecimiento(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/establecimientos/:ID/sedes', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    NULL,
    NULL,
    NULL, NULL
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

-- Sin filas en role_query en el catalogo vivo: el endpoint no esta expuesto
-- a ningun rol. Se reproduce tal cual (no se inventa un permiso).
