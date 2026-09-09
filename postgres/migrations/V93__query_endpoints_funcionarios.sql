-- ===========================================================================
-- V93 - registro en public.query (+ role_query) de los endpoints de
--        query-service de funcionarios y usuarios (V51).
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
--   El texto volcado ya refleja los UPDATE de las migraciones < V93, que
--   sobre base limpia corren antes y no encuentran fila: el estado final es
--   el mismo por ambos caminos.
--
-- NUMERACION
--   Hueco libre V93, verificado contra TODAS las ramas de origin. Se eligio
--   por encima de las migraciones que definen las funciones invocadas (V51)
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
-- 1. GET /establecimientos/funcionarios/:ID  ->  fn_usu_empleado_buscar_por_pk
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'eval-col-funcionarios-buscar-por-pk-001',
    'SELECT * FROM academico_test.fn_usu_empleado_buscar_por_pk(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/establecimientos/funcionarios/:ID', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    NULL,
    'Detalle completo de un funcionario (TUSUARIO + TFUNCIONARIO + permisos). Mismo gate que el listado, aplicado contra el EE concreto del funcionario.',
    'funcionarios-buscar-por-pk', 'DEFAULT',
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
   AND q.path_template = '/establecimientos/funcionarios/:ID'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. PATCH /establecimientos/funcionarios/:ID  ->  fn_fun_actualizar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'eval-col-funcionarios-actualizar-001',
    'SELECT academico_test.fn_fun_actualizar(
    p_pk_funcionario => CAST(:PARAM.ID AS BIGINT),
    p_pk_usuario_solicitante => public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    p_correo_electronico => CAST(:BODY.PERSON.EMAIL AS VARCHAR),
    p_identificacion => CAST(:BODY.PERSON.IDENTIFICATION AS VARCHAR),
    p_fk_tlv_tipo_documento => CAST(:BODY.PERSON.DOCUMENTTYPE.ID AS BIGINT),
    p_primer_nombre => CAST(:BODY.PERSON.FIRSTNAME AS VARCHAR),
    p_segundo_nombre => CAST(:BODY.PERSON.MIDDLENAME AS VARCHAR),
    p_primer_apellido => CAST(:BODY.PERSON.LASTNAME AS VARCHAR),
    p_segundo_apellido => CAST(:BODY.PERSON.SECONDLASTNAME AS VARCHAR),
    p_fecha_nacimiento => CAST(:BODY.PERSON.BIRTHDATE AS DATE),
    p_fk_tlv_genero => CAST(:BODY.PERSON.GENDER.ID AS BIGINT),
    p_telefono => CAST(:BODY.PERSON.PHONE AS VARCHAR),
    p_estado => CAST(CASE WHEN CAST(:BODY.STATUS AS VARCHAR) = ''ACTIVE'' THEN ''A''
                          WHEN CAST(:BODY.STATUS AS VARCHAR) = ''SUSPENDED'' THEN ''I''
                          ELSE NULL END AS VARCHAR),
    p_fk_tlv_clase_funcionario => CAST(:BODY.EMPLOYEECLASS.ID AS BIGINT),
    p_fk_tlv_nivel_esenanza => CAST(:BODY.EDUCATIONLEVEL.ID AS BIGINT),
    p_fk_tlv_grado_escalafon => CAST(:BODY.GRADE.ID AS BIGINT),
    p_fk_tlv_nivel_educativo => CAST(:BODY.HIGHESTEDUCATIONLEVEL.ID AS BIGINT),
    p_fk_tlv_fuente_recurso => CAST(:BODY.FUNDINGSOURCE.ID AS BIGINT),
    p_fk_tlv_cargo => CAST(:BODY.FUNCTIONALPOSITION.ID AS BIGINT),
    p_fk_tlv_tipo_vinculacion => CAST(:BODY.EMPLOYMENTTYPE.ID AS BIGINT),
    p_direccion => CAST(:BODY.ADDRESS AS VARCHAR),
    p_fk_tarchivo_foto => CAST(:BODY.FKTARCHIVOFOTO AS BIGINT)
) AS pk_funcionario_actualizado;',
    'postgres', false, false,
    m.id_microservice,
    '/establecimientos/funcionarios/:ID', 'SELECT', 'PATCH',
    '{"PARAM.ID": "BIGINT", "BODY.STATUS": "VARCHAR", "BODY.ADDRESS": "VARCHAR", "BODY.GRADE.ID": "BIGINT", "BODY.PERSON.EMAIL": "VARCHAR", "BODY.PERSON.PHONE": "VARCHAR", "BODY.FKTARCHIVOFOTO": "FILE:perfilUsuario", "BODY.PERSON.LASTNAME": "VARCHAR", "BODY.EMPLOYEECLASS.ID": "BIGINT", "BODY.FUNDINGSOURCE.ID": "BIGINT", "BODY.PERSON.BIRTHDATE": "DATE", "BODY.PERSON.FIRSTNAME": "VARCHAR", "BODY.PERSON.GENDER.ID": "BIGINT", "BODY.EDUCATIONLEVEL.ID": "BIGINT", "BODY.EMPLOYMENTTYPE.ID": "BIGINT", "BODY.PERSON.MIDDLENAME": "VARCHAR", "BODY.FUNCTIONALPOSITION.ID": "BIGINT", "BODY.PERSON.IDENTIFICATION": "VARCHAR", "BODY.PERSON.SECONDLASTNAME": "VARCHAR", "BODY.PERSON.DOCUMENTTYPE.ID": "BIGINT", "BODY.HIGHESTEDUCATIONLEVEL.ID": "BIGINT"}'::jsonb,
    NULL,
    'PATCH integral del subconjunto de TUSUARIO/TFUNCIONARIO que hoy expone el formulario de funcionario del front (no toca la lista de permisos, ver /funcionario/:ID/permisos aparte, ni la contraseña).',
    'funcionarios-actualizar', 'DEFAULT',
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
   AND q.path_template = '/establecimientos/funcionarios/:ID'
   AND q.http_method   = 'PATCH'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3. PUT /establecimientos/funcionarios/:ID  ->  fn_fun_baja_establecimiento
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'eval-col-funcionarios-baja-001',
    'SELECT academico_test.fn_fun_baja_establecimiento(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
) AS pk_funcionario_eliminado;',
    'postgres', false, false,
    m.id_microservice,
    '/establecimientos/funcionarios/:ID', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    NULL,
    'Baja logica integral del funcionario en el EE al que esta enlazado (TFUNCIONARIO + cascada de TSEDE_USUARIO de ese EE + limpieza de FK_TFUNCIONARIO_SECRETARIA si aplica). Bloqueado si el funcionario es el rector del EE.',
    'funcionarios-baja', 'DEFAULT',
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
   AND q.path_template = '/establecimientos/funcionarios/:ID'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 4. PUT /establecimientos/funcionarios/eliminar-multiple  ->  fn_fun_baja_establecimiento_bulk
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'eval-col-funcionarios-baja-bulk-001',
    'SELECT * FROM academico_test.fn_fun_baja_establecimiento_bulk(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.PKS AS BIGINT[])
);',
    'postgres', false, false,
    m.id_microservice,
    '/establecimientos/funcionarios/eliminar-multiple', 'SELECT', 'PUT',
    '{"BODY.PKS": "BIGINT[]"}'::jsonb,
    NULL,
    'Baja logica en lote de funcionarios (mismas reglas que la baja individual por cada PK, en savepoints independientes). Si el rector de un EE viene en el lote, se omite pero el resto se procesa igual. Devuelve (pk_funcionario, status) por cada PK.',
    'funcionarios-baja-bulk', 'DEFAULT',
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
   AND q.path_template = '/establecimientos/funcionarios/eliminar-multiple'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 5. POST /establecimientos/funcionarios/query  ->  fn_usu_empleados_listar_paginado
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'eval-col-funcionarios-listar-paginado-001',
    'SELECT * FROM academico_test.fn_usu_empleados_listar_paginado(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FILTERS.SEARCH AS VARCHAR),
    CAST(:BODY.FILTERS.ROLES AS VARCHAR[]),
    CAST(:BODY.FILTERS.WORKSCHEDULES AS VARCHAR[]),
    CAST(:BODY.FILTERS.STATUSES AS VARCHAR[]),
    CAST(:BODY.FILTERS.CAMPUSID AS BIGINT),
    CAST(:BODY.SORTING.ID AS VARCHAR),
    CAST(:BODY.SORTING.DESC AS BOOLEAN),
    CAST(:BODY.PAGEINDEX AS INTEGER),
    CAST(:BODY.PAGESIZE AS INTEGER)
);',
    'postgres', false, false,
    m.id_microservice,
    '/establecimientos/funcionarios/query', 'SELECT', 'POST',
    '{"BODY.PAGESIZE": "INTEGER", "BODY.PAGEINDEX": "INTEGER", "BODY.SORTING.ID": "VARCHAR", "BODY.SORTING.DESC": "BOOLEAN", "BODY.FILTERS.ROLES": "TEXT[]", "BODY.FILTERS.SEARCH": "VARCHAR", "BODY.FILTERS.CAMPUSID": "BIGINT", "BODY.FILTERS.STATUSES": "TEXT[]", "BODY.FILTERS.WORKSCHEDULES": "TEXT[]"}'::jsonb,
    NULL,
    'Listado paginado de funcionarios enlazados a un EE. Gate: super-admin ve todos, rector/secretaria de un EE solo ve los de ese EE.',
    'funcionarios-listar-paginado', 'DEFAULT',
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
   AND q.path_template = '/establecimientos/funcionarios/query'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 6. POST /establecimientos/funcionarios/reporte  ->  fn_usu_empleados_listar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'eval-col-funcionarios-reporte-001',
    'SELECT * FROM academico_test.fn_usu_empleados_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FILTERS.SEARCH AS VARCHAR),
    CAST(:BODY.FILTERS.ROLES AS VARCHAR[]),
    CAST(:BODY.FILTERS.WORKSCHEDULES AS VARCHAR[]),
    CAST(:BODY.FILTERS.STATUSES AS VARCHAR[]),
    CAST(:BODY.FILTERS.CAMPUSID AS BIGINT),
    CAST(:BODY.SORTING.ID AS VARCHAR),
    CAST(:BODY.SORTING.DESC AS BOOLEAN),
    NULL::INTEGER, NULL::INTEGER
) t
WHERE CAST(:BODY.FILTERS.IDS AS BIGINT[]) IS NULL
   OR t.pk_empleado = ANY(CAST(:BODY.FILTERS.IDS AS BIGINT[]));',
    'postgres', false, false,
    m.id_microservice,
    '/establecimientos/funcionarios/reporte', 'SELECT', 'POST',
    '{"BODY.SORTING.ID": "VARCHAR", "BODY.FILTERS.IDS": "BIGINT[]", "BODY.SORTING.DESC": "BOOLEAN", "BODY.FILTERS.ROLES": "TEXT[]", "BODY.FILTERS.SEARCH": "VARCHAR", "BODY.FILTERS.CAMPUSID": "BIGINT", "BODY.FILTERS.STATUSES": "TEXT[]", "BODY.FILTERS.WORKSCHEDULES": "TEXT[]"}'::jsonb,
    NULL,
    'Funcionarios sin paginar para reporte. Mismos filtros y mismo gate que el listado (super-admin ve todos; rector/secretaria solo los de su EE).',
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
   AND q.path_template = '/establecimientos/funcionarios/reporte'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 7. PUT /funcionario/:ID/permisos  ->  fn_fun_permisos_actualizar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'eval-col-funcionario-permisos-actualizar-001',
    'SELECT * FROM academico_test.fn_fun_permisos_actualizar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.PERMISOS AS JSONB)
);',
    'postgres', false, false,
    m.id_microservice,
    '/funcionario/:ID/permisos', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT", "BODY.PERMISOS": "JSONB"}'::jsonb,
    NULL,
    'Procesa la lista de permisos (TSEDE_USUARIO) del funcionario segun accion=crear|eliminar por elemento. Reemplaza el JSONB que antes viajaba dentro de fn_fun_actualizar.',
    'funcionario-permisos-actualizar', 'DEFAULT',
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
   AND q.path_template = '/funcionario/:ID/permisos'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 8. POST /funcionario/enlazar-establecimiento  ->  fn_fun_enlazar_establecimiento
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'eval-col-funcionario-enlazar-establecimiento-001',
    'SELECT academico_test.fn_fun_enlazar_establecimiento(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.PKFUNCIONARIO AS BIGINT),
    CAST(:BODY.FKESTABLECIMIENTO AS BIGINT)
) AS pk_funcionario_enlazado;',
    'postgres', false, false,
    m.id_microservice,
    '/funcionario/enlazar-establecimiento', 'SELECT', 'POST',
    '{"BODY.PKFUNCIONARIO": "BIGINT", "BODY.FKESTABLECIMIENTO": "BIGINT"}'::jsonb,
    NULL,
    'Liga el TFUNCIONARIO pendiente (creado por /register/funcionario, sin establecimiento) al EE elegido. Segundo paso del alta de funcionario.',
    'funcionario-enlazar-establecimiento', 'DEFAULT',
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
   AND q.path_template = '/funcionario/enlazar-establecimiento'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 9. GET /usuarios/buscar-por-documento  ->  fn_usu_buscar_por_documento
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'eval-col-usuarios-buscar-por-documento-001',
    'SELECT * FROM academico_test.fn_usu_buscar_por_documento(
    CAST(:QUERY.FKTLVTIPODOCUMENTO AS BIGINT),
    CAST(:QUERY.IDENTIFICACION AS VARCHAR),
    FALSE
);',
    'postgres', false, false,
    m.id_microservice,
    '/usuarios/buscar-por-documento', 'SELECT', 'GET',
    '{"QUERY.IDENTIFICACION": "VARCHAR", "QUERY.FKTLVTIPODOCUMENTO": "BIGINT"}'::jsonb,
    NULL,
    'Busca TUSUARIO activos por (tipo de documento, identificacion). Devuelve 0..N filas (puede haber mas de un tipo de documento con el mismo numero).',
    'usuarios-buscar-por-documento', 'DEFAULT',
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
   AND q.path_template = '/usuarios/buscar-por-documento'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

-- ===========================================================================
-- Endpoints que V51 dejo escritos pero COMENTADOS.
--
--   Son la causa raiz de este hueco, documentada en el propio archivo: el
--   bloque INSERT esta ahi, entre guiones, con un microservice_id quemado
--   ('8') y un uuid sin generar. Nunca corrieron. Se registran aqui con el
--   contenido REAL desplegado (uuid del servidor, microservice_id resuelto
--   por serviceid) en vez de descomentarlos: descomentar V51 cambiaria su
--   checksum en todos los entornos ya migrados sin necesidad.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 10. POST /funcionario/cancelar-pendiente  ->  fn_fun_cancelar_pendiente
--    Soft delete de un TFUNCIONARIO que aun no se uso en ningun lado, para
--    que el front deshaga un alta que quedo huerfana.
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-ws5p9ubs-h7xi1p33',
    'SELECT academico_test.fn_fun_cancelar_pendiente(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.PKFUNCIONARIO AS BIGINT)
) AS pk_funcionario_cancelado;',
    'postgres', false, false,
    m.id_microservice,
    '/funcionario/cancelar-pendiente', 'SELECT', 'POST',
    '{"BODY.PKFUNCIONARIO": "BIGINT"}'::jsonb,
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
  JOIN public.role r ON r.name IN ('CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/funcionario/cancelar-pendiente'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 11. GET /funcionarios/activo-por-usuario  ->  fn_fun_activo_por_usuario
--    Dado un PK_TUSUARIO devuelve su PK_TFUNCIONARIO activo, o NULL.
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-lb86j8in-s3k43969',
    'SELECT academico_test.fn_fun_activo_por_usuario(
    CAST(:QUERY.FKUSUARIO AS BIGINT)
) AS pk_tfuncionario_activo;',
    'postgres', false, false,
    m.id_microservice,
    '/funcionarios/activo-por-usuario', 'SELECT', 'GET',
    '{"QUERY.FKUSUARIO": "BIGINT"}'::jsonb,
    NULL,
    NULL,
    NULL, NULL,
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

-- Sin filas en role_query en el catalogo vivo: el endpoint no esta expuesto
-- a ningun rol. Se reproduce tal cual (no se inventa un permiso).

-- ---------------------------------------------------------------------------
-- 12. GET /usuarios/autocompletar-por-documento  ->  fn_usu_autocompletar_por_documento
--    Autocompletado por documento del front: resuelve TUSUARIO y el
--    PK_TFUNCIONARIO activo en una sola consulta.
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-51kccog8-mkef0m8m',
    'SELECT * FROM academico_test.fn_usu_autocompletar_por_documento(
    CAST(:QUERY.FKTLVTIPODOCUMENTO AS BIGINT),
    CAST(:QUERY.IDENTIFICACION AS VARCHAR)
);',
    'postgres', false, false,
    m.id_microservice,
    '/usuarios/autocompletar-por-documento', 'SELECT', 'GET',
    '{"QUERY.IDENTIFICACION": "VARCHAR", "QUERY.FKTLVTIPODOCUMENTO": "BIGINT"}'::jsonb,
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
  JOIN public.role r ON r.name IN ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/usuarios/autocompletar-por-documento'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;
