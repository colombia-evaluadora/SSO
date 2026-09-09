-- ===========================================================================
-- V98 - registro en public.query (+ role_query) de los endpoints de
--        query-service de establecimientos (V53).
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
--   El texto volcado ya refleja los UPDATE de las migraciones < V98, que
--   sobre base limpia corren antes y no encuentran fila: el estado final es
--   el mismo por ambos caminos.
--
-- NUMERACION
--   Hueco libre V98, verificado contra TODAS las ramas de origin. Se eligio
--   por encima de las migraciones que definen las funciones invocadas (V53)
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
-- 1. POST /establecimientos  ->  fn_est_crear
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msnu438k-mbe0cg26',
    'SELECT academico_test.fn_est_crear(
    p_pk_usuario_solicitante => public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    p_nombre => CAST(:BODY.BASICINFO.NAME AS VARCHAR),
    p_nit => CAST(:BODY.BASICINFO.NIT AS VARCHAR),
    p_fk_municipio => CAST(:BODY.ADDRESS.MUNICIPALITY AS BIGINT),
    p_fk_propiedad_juridica => CAST(:BODY.BASICINFO.OWNERSHIPTYPE AS BIGINT),
    p_codigo => CAST(:BODY.BASICINFO.DANE AS VARCHAR),
    p_localidad => CAST(:BODY.ADDRESS.LOCALITY AS VARCHAR),
    p_comuna => CAST(:BODY.ADDRESS.COMMUNE AS VARCHAR),
    p_barrio => CAST(:BODY.ADDRESS.DISTRICT AS VARCHAR),
    p_direccion => CAST(:BODY.ADDRESS.ADDRESS AS VARCHAR),
    p_correo_electronico => CAST(:BODY.CONTACT.EMAIL AS VARCHAR),
    p_telefono => CAST(:BODY.CONTACT.PHONE AS VARCHAR),
    p_fax => CAST(:BODY.CONTACT.FAX AS VARCHAR),
    p_pagina_web => CAST(:BODY.CONTACT.WEBSITE AS VARCHAR),
    p_fk_lista_valor_zona => CAST(:BODY.ADDRESS.ZONE AS BIGINT),
    p_resolucion_aprobacion => CAST(:BODY.ADDITIONALINFO.APPROVALRESOLUTION AS VARCHAR),
    p_licencia_funcionamiento => CAST(:BODY.ADDITIONALINFO.LICENSESTATUS AS VARCHAR),
    p_fecha_licencia => CAST(:BODY.ADDITIONALINFO.LICENSEDATE AS DATE),
    p_fk_lv_calendario => CAST(:BODY.ADDITIONALINFO.CALENDAR AS BIGINT),
    p_fk_lv_idioma => CAST(:BODY.ADDITIONALINFO.TEACHINGLANGUAGE AS BIGINT),
    p_fk_lv_genero_est => CAST(:BODY.ADDITIONALINFO.POPULATIONGENDER AS BIGINT),
    p_fk_discapacidad => CAST(:BODY.ADDITIONALINFO.DISABILITYTYPE AS BIGINT),
    p_talento => CAST(CASE WHEN CAST(:BODY.ADDITIONALINFO.GIFTEDATTENTION AS BOOLEAN) THEN ''S'' ELSE ''N'' END AS academico_test.bool_sn),
    p_etnias => CAST(CASE WHEN CAST(:BODY.ADDITIONALINFO.ETHNICATTENTION AS BOOLEAN) THEN ''S'' ELSE ''N'' END AS academico_test.bool_sn),
    p_fk_tfuncionario_rector => CAST(:BODY.PRINCIPAL AS BIGINT),
    p_fk_tfuncionario_secretaria => CAST(:BODY.SECRETARY AS BIGINT),
    p_subsidio => CAST(CASE WHEN CAST(:BODY.ADDITIONALINFO.SUBSIDY AS BOOLEAN) THEN ''S'' ELSE ''N'' END AS academico_test.bool_sn),
    p_fk_lv_regimen_catcosto => CAST(:BODY.ADDITIONALINFO.COSTREGIME AS BIGINT),
    p_fk_lv_rango_tarifa => CAST(:BODY.ADDITIONALINFO.TUITIONRANGE AS BIGINT),
    p_fk_archivo => CAST(:BODY.LOGO AS BIGINT)
) AS pk_establecimiento_creado',
    'postgres', false, false,
    m.id_microservice,
    '/establecimientos', 'SELECT', 'POST',
    '{"BODY.LOGO": "FILE:escudo", "BODY.PRINCIPAL": "BIGINT", "BODY.SECRETARY": "BIGINT", "BODY.CONTACT.FAX": "VARCHAR", "BODY.ADDRESS.ZONE": "BIGINT", "BODY.BASICINFO.NIT": "VARCHAR", "BODY.CONTACT.EMAIL": "VARCHAR", "BODY.CONTACT.PHONE": "VARCHAR", "BODY.BASICINFO.DANE": "VARCHAR", "BODY.BASICINFO.NAME": "VARCHAR", "BODY.ADDRESS.ADDRESS": "VARCHAR", "BODY.ADDRESS.COMMUNE": "VARCHAR", "BODY.CONTACT.WEBSITE": "VARCHAR", "BODY.ADDRESS.DISTRICT": "VARCHAR", "BODY.ADDRESS.LOCALITY": "VARCHAR", "BODY.ADDRESS.MUNICIPALITY": "BIGINT", "BODY.ADDITIONALINFO.SUBSIDY": "BOOLEAN", "BODY.ADDITIONALINFO.CALENDAR": "BIGINT", "BODY.BASICINFO.OWNERSHIPTYPE": "BIGINT", "BODY.ADDITIONALINFO.COSTREGIME": "BIGINT", "BODY.ADDITIONALINFO.LICENSEDATE": "DATE", "BODY.ADDITIONALINFO.TUITIONRANGE": "BIGINT", "BODY.ADDITIONALINFO.LICENSESTATUS": "VARCHAR", "BODY.ADDITIONALINFO.DISABILITYTYPE": "BIGINT", "BODY.ADDITIONALINFO.ETHNICATTENTION": "BOOLEAN", "BODY.ADDITIONALINFO.GIFTEDATTENTION": "BOOLEAN", "BODY.ADDITIONALINFO.POPULATIONGENDER": "BIGINT", "BODY.ADDITIONALINFO.TEACHINGLANGUAGE": "BIGINT", "BODY.ADDITIONALINFO.APPROVALRESOLUTION": "VARCHAR"}'::jsonb,
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
  JOIN public.role r ON r.name IN ('CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/establecimientos'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. GET /establecimientos/:ID  ->  fn_est_buscar_por_pk
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msrirgk4-f8yfa587',
    'SELECT
    t.PK_ESTABLECIMIENTO,
    t.CODIGO,
    t.NOMBRE,
    t.NIT,
    t.IDECOL,
    t.FK_TMUNICIPIO,
    t.FK_TLISTA_VALOR_ZONA,
    t.LOCALIDAD,
    t.COMUNA,
    t.BARRIO,
    t.DIRECCION,
    t.CORREO_ELECTRONICO,
    t.TELEFONO,
    t.FAX,
    t.PAGINA_WEB,
    t.FK_TPROPIEDAD_JURIDICA,
    t.RESOLUCION_APROBACION,
    t.LICENCIA_FUNCIONAMIENTO,
    t.FECHA_LICENCIA,
    t.FK_TLV_CALENDARIO,
    t.FK_TLV_IDIOMA,
    t.FK_TLV_GENERO_EST,
    t.FK_TDISCAPACIDAD,
    t.TALENTO,
    t.ETNIAS,
    t.FK_TFUNCIONARIO_RECTOR,
    t.FK_TFUNCIONARIO_SECRETARIA,
    t.SUBSIDIO,
    t.FK_TLV_REGIMEN_CATCOSTO,
    t.FK_TLV_RANGO_TARIFA,
    t.FK_TLV_ASOCIACION_NACIONAL,
    t.FK_TLV_ESTADO_ESTABLECIMIENTO,
    t.FK_TARCHIVO,
    t.CREATED_BY,
    t.CREATED_AT,
    t.MODIFIED_BY,
    t.MODIFIED_AT,
    t.ACTIVE
FROM academico_test.fn_est_buscar_por_pk(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
) AS t;',
    'postgres', false, false,
    m.id_microservice,
    '/establecimientos/:ID', 'SELECT', 'GET',
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
   AND q.path_template = '/establecimientos/:ID'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3. PATCH /establecimientos/:ID  ->  fn_est_actualizar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msq4nazf-j5jti48l',
    'SELECT academico_test.fn_est_actualizar(
    p_pk_establecimiento => CAST(:PARAM.ID AS BIGINT),
    p_nombre => CAST(:BODY.BASICINFO.NAME AS VARCHAR),
    p_nit => CAST(:BODY.BASICINFO.NIT AS VARCHAR),
    p_fk_municipio => CAST(:BODY.ADDRESS.MUNICIPALITY AS BIGINT),
    p_fk_propiedad_juridica => CAST(:BODY.BASICINFO.OWNERSHIPTYPE AS BIGINT),
    p_codigo => CAST(:BODY.BASICINFO.DANE AS VARCHAR),
    p_localidad => CAST(:BODY.ADDRESS.LOCALITY AS VARCHAR),
    p_comuna => CAST(:BODY.ADDRESS.COMMUNE AS VARCHAR),
    p_barrio => CAST(:BODY.ADDRESS.DISTRICT AS VARCHAR),
    p_direccion => CAST(:BODY.ADDRESS.ADDRESS AS VARCHAR),
    p_correo_electronico => CAST(:BODY.CONTACT.EMAIL AS VARCHAR),
    p_telefono => CAST(:BODY.CONTACT.PHONE AS VARCHAR),
    p_fax => CAST(:BODY.CONTACT.FAX AS VARCHAR),
    p_pagina_web => CAST(:BODY.CONTACT.WEBSITE AS VARCHAR),
    p_fk_lista_valor_zona => CAST(:BODY.ADDRESS.ZONE AS BIGINT),
    p_resolucion_aprobacion => CAST(:BODY.ADDITIONALINFO.APPROVALRESOLUTION AS VARCHAR),
    p_licencia_funcionamiento => CAST(:BODY.ADDITIONALINFO.LICENSESTATUS AS VARCHAR),
    p_fecha_licencia => CAST(:BODY.ADDITIONALINFO.LICENSEDATE AS DATE),
    p_fk_lv_calendario => CAST(:BODY.ADDITIONALINFO.CALENDAR AS BIGINT),
    p_fk_lv_idioma => CAST(:BODY.ADDITIONALINFO.TEACHINGLANGUAGE AS BIGINT),
    p_fk_lv_genero_est => CAST(:BODY.ADDITIONALINFO.POPULATIONGENDER AS BIGINT),
    p_fk_discapacidad => CAST(:BODY.ADDITIONALINFO.DISABILITYTYPE AS BIGINT),
    p_talento => CAST(CASE WHEN CAST(:BODY.ADDITIONALINFO.GIFTEDATTENTION AS BOOLEAN) THEN ''S'' ELSE ''N'' END AS academico_test.bool_sn),
    p_etnias => CAST(CASE WHEN CAST(:BODY.ADDITIONALINFO.ETHNICATTENTION AS BOOLEAN) THEN ''S'' ELSE ''N'' END AS academico_test.bool_sn),
    p_fk_tfuncionario_rector => CAST(:BODY.PRINCIPAL AS BIGINT),
    p_fk_tfuncionario_secretaria => CAST(:BODY.SECRETARY AS BIGINT),
    p_subsidio => CAST(CASE WHEN CAST(:BODY.ADDITIONALINFO.SUBSIDY AS BOOLEAN) THEN ''S'' ELSE ''N'' END AS academico_test.bool_sn),
    p_fk_lv_regimen_catcosto => CAST(:BODY.ADDITIONALINFO.COSTREGIME AS BIGINT),
    p_fk_lv_rango_tarifa => CAST(:BODY.ADDITIONALINFO.TUITIONRANGE AS BIGINT),
    p_fk_archivo => CAST(:BODY.LOGO AS BIGINT),
    p_pk_usuario_solicitante => public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
) AS pk_establecimiento_actualizado',
    'postgres', false, false,
    m.id_microservice,
    '/establecimientos/:ID', 'SELECT', 'PATCH',
    '{"PARAM.ID": "BIGINT", "BODY.LOGO": "FILE:escudo", "BODY.PRINCIPAL": "BIGINT", "BODY.SECRETARY": "BIGINT", "BODY.CONTACT.FAX": "VARCHAR", "BODY.ADDRESS.ZONE": "BIGINT", "BODY.BASICINFO.NIT": "VARCHAR", "BODY.CONTACT.EMAIL": "VARCHAR", "BODY.CONTACT.PHONE": "VARCHAR", "BODY.BASICINFO.DANE": "VARCHAR", "BODY.BASICINFO.NAME": "VARCHAR", "BODY.ADDRESS.ADDRESS": "VARCHAR", "BODY.ADDRESS.COMMUNE": "VARCHAR", "BODY.CONTACT.WEBSITE": "VARCHAR", "BODY.ADDRESS.DISTRICT": "VARCHAR", "BODY.ADDRESS.LOCALITY": "VARCHAR", "BODY.ADDRESS.MUNICIPALITY": "BIGINT", "BODY.ADDITIONALINFO.SUBSIDY": "BOOLEAN", "BODY.ADDITIONALINFO.CALENDAR": "BIGINT", "BODY.BASICINFO.OWNERSHIPTYPE": "BIGINT", "BODY.ADDITIONALINFO.COSTREGIME": "BIGINT", "BODY.ADDITIONALINFO.LICENSEDATE": "DATE", "BODY.ADDITIONALINFO.TUITIONRANGE": "BIGINT", "BODY.ADDITIONALINFO.LICENSESTATUS": "VARCHAR", "BODY.ADDITIONALINFO.DISABILITYTYPE": "BIGINT", "BODY.ADDITIONALINFO.ETHNICATTENTION": "BOOLEAN", "BODY.ADDITIONALINFO.GIFTEDATTENTION": "BOOLEAN", "BODY.ADDITIONALINFO.POPULATIONGENDER": "BIGINT", "BODY.ADDITIONALINFO.TEACHINGLANGUAGE": "BIGINT", "BODY.ADDITIONALINFO.APPROVALRESOLUTION": "VARCHAR"}'::jsonb,
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
  JOIN public.role r ON r.name IN ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-JEFE_AREA', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/establecimientos/:ID'
   AND q.http_method   = 'PATCH'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 4. PUT /establecimientos/:ID  ->  fn_est_soft_delete
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msq59zzv-0of3qxey',
    'SELECT academico_test.fn_est_soft_delete(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
) AS pk_establecimiento_borrado',
    'postgres', false, false,
    m.id_microservice,
    '/establecimientos/:ID', 'SELECT', 'PUT',
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
  JOIN public.role r ON r.name IN ('CEVAL-JEFE_AREA', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/establecimientos/:ID'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 5. POST /establecimientos/bulk-delete  ->  fn_est_soft_delete_bulk
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-msrk3piq-yvvykrij',
    'SELECT * FROM academico_test.fn_est_soft_delete_bulk(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    :BODY.PKS
);',
    'postgres', false, false,
    m.id_microservice,
    '/establecimientos/bulk-delete', 'SELECT', 'POST',
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
  JOIN public.role r ON r.name IN ('CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/establecimientos/bulk-delete'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 6. GET /establecimientos/opciones  ->  fn_est_listar_todos
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'eval-col-establecimientos-opciones-001',
    'SELECT pk_establecimiento AS id, nombre AS name
FROM academico_test.fn_est_listar_todos(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/establecimientos/opciones', 'SELECT', 'GET',
    '{}'::jsonb,
    NULL,
    'Lista liviana (id+nombre) de todos los establecimientos que el usuario puede ver, sin paginar. Para selects (alta de sedes, alta de funcionarios).',
    'establecimientos-opciones', 'DEFAULT'
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
   AND q.path_template = '/establecimientos/opciones'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 7. POST /establecimientos/query  ->  fn_est_listar_paginado
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'q-mspam6ud-e0dpwwnm',
    'SELECT * FROM academico_test.fn_est_listar_paginado(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FILTERS.SEARCH AS VARCHAR),
    CAST(:BODY.FILTERS.DEPARTMENT AS VARCHAR[]),
    CAST(:BODY.FILTERS.MUNICIPALITY AS VARCHAR[]),
    CAST(:BODY.FILTERS.STATUS AS VARCHAR[]),
    CAST(:BODY.SORTING.ID AS VARCHAR),
    CAST(:BODY.SORTING.DESC AS BOOLEAN),
    CAST(:BODY.PAGEINDEX AS INTEGER),
    CAST(:BODY.PAGESIZE AS INTEGER)
);',
    'postgres', false, false,
    m.id_microservice,
    '/establecimientos/query', 'SELECT', 'POST',
    '{"BODY.PAGESIZE": "INTEGER", "BODY.PAGEINDEX": "INTEGER", "BODY.SORTING.ID": "VARCHAR", "BODY.SORTING.DESC": "BOOLEAN", "BODY.FILTERS.SEARCH": "VARCHAR", "BODY.FILTERS.STATUS": "TEXT[]", "BODY.FILTERS.DEPARTMENT": "TEXT[]", "BODY.FILTERS.MUNICIPALITY": "TEXT[]"}'::jsonb,
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
  JOIN public.role r ON r.name IN ('CEVAL-JEFE_AREA', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/establecimientos/query'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 8. POST /establecimientos/reporte  ->  fn_est_listar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style)
SELECT
    'eval-col-establecimientos-reporte-001',
    'SELECT * FROM academico_test.fn_est_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FILTERS.SEARCH AS VARCHAR),
    CAST(:BODY.FILTERS.DEPARTMENT AS VARCHAR[]),
    CAST(:BODY.FILTERS.MUNICIPALITY AS VARCHAR[]),
    CAST(:BODY.FILTERS.STATUS AS VARCHAR[]),
    CAST(:BODY.SORTING.ID AS VARCHAR),
    CAST(:BODY.SORTING.DESC AS BOOLEAN),
    NULL::INTEGER, NULL::INTEGER
) t
WHERE CAST(:BODY.FILTERS.IDS AS BIGINT[]) IS NULL
   OR t.pk_establecimiento = ANY(CAST(:BODY.FILTERS.IDS AS BIGINT[]));',
    'postgres', false, false,
    m.id_microservice,
    '/establecimientos/reporte', 'SELECT', 'POST',
    '{"BODY.SORTING.ID": "VARCHAR", "BODY.FILTERS.IDS": "BIGINT[]", "BODY.SORTING.DESC": "BOOLEAN", "BODY.FILTERS.SEARCH": "VARCHAR", "BODY.FILTERS.STATUS": "TEXT[]", "BODY.FILTERS.DEPARTMENT": "TEXT[]", "BODY.FILTERS.MUNICIPALITY": "TEXT[]"}'::jsonb,
    NULL,
    'Establecimientos sin paginar para reporte. Mismos filtros y mismo gate que el listado.',
    NULL, NULL
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-JEFE_AREA', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/establecimientos/reporte'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;
