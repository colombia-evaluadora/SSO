-- Registra en public.query los 15 endpoints CRUD de pigse.tente /
-- pigse.testablecimiento / pigse.tfuncionario (funciones de V257) y sus
-- permisos en public.role_query. Aditivo e idempotente.

-- CONTEXT.USER_ID es system-bound (JWT), primer parametro de toda funcion.

-- 1. /entes
INSERT INTO public.query (uuid, query, type, microservice_id, path_template, execution_mode, http_method, param_types)
SELECT 'pigse-entes-query',
       $q$SELECT * FROM pigse.fn_ente_listar(
              CAST(:CONTEXT.USER_ID AS BIGINT),
              CAST(:BODY.FILTERS.SEARCH AS VARCHAR),
              CAST(:BODY.SORTING.ID AS VARCHAR),
              CAST(:BODY.SORTING.DESC AS BOOLEAN),
              CAST(:BODY.PAGEINDEX AS INTEGER),
              CAST(:BODY.PAGESIZE AS INTEGER)
          )$q$,
       'postgres', m.id_microservice, '/entes/query', 'SELECT', 'POST',
       '{"BODY.FILTERS.SEARCH": "VARCHAR", "BODY.SORTING.ID": "VARCHAR",
         "BODY.SORTING.DESC": "BOOLEAN", "BODY.PAGEINDEX": "INTEGER", "BODY.PAGESIZE": "INTEGER"}'::jsonb
  FROM public.microservice m WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE uuid = 'pigse-entes-query');

INSERT INTO public.query (uuid, query, type, microservice_id, path_template, execution_mode, http_method, param_types)
SELECT 'pigse-entes-buscar-pk',
       $q$SELECT * FROM pigse.fn_ente_buscar_por_pk(
              CAST(:CONTEXT.USER_ID AS BIGINT), CAST(:PARAM.ID AS BIGINT))$q$,
       'postgres', m.id_microservice, '/entes/:ID', 'SELECT', 'GET',
       '{"PARAM.ID": "BIGINT!"}'::jsonb
  FROM public.microservice m WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE uuid = 'pigse-entes-buscar-pk');

INSERT INTO public.query (uuid, query, type, microservice_id, path_template, execution_mode, http_method, param_types)
SELECT 'pigse-entes-crear',
       $q$SELECT pigse.fn_ente_crear(
              CAST(:CONTEXT.USER_ID AS BIGINT),
              CAST(:BODY.NIT AS VARCHAR),
              CAST(:BODY.NOMBRE AS VARCHAR),
              CAST(:BODY.FK_TMUNICIPIO AS BIGINT),
              CAST(:BODY.FK_TENTE_PADRE AS BIGINT)
          ) AS pk_ente$q$,
       'postgres', m.id_microservice, '/entes', 'SELECT', 'POST',
       '{"BODY.NIT": "VARCHAR!", "BODY.NOMBRE": "VARCHAR!",
         "BODY.FK_TMUNICIPIO": "BIGINT!", "BODY.FK_TENTE_PADRE": "BIGINT"}'::jsonb
  FROM public.microservice m WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE uuid = 'pigse-entes-crear');

INSERT INTO public.query (uuid, query, type, microservice_id, path_template, execution_mode, http_method, param_types)
SELECT 'pigse-entes-actualizar',
       $q$SELECT pigse.fn_ente_actualizar(
              CAST(:CONTEXT.USER_ID AS BIGINT),
              CAST(:PARAM.ID AS BIGINT),
              CAST(:BODY.NIT AS VARCHAR),
              CAST(:BODY.NOMBRE AS VARCHAR),
              CAST(:BODY.FK_TMUNICIPIO AS BIGINT),
              CAST(:BODY.FK_TENTE_PADRE AS BIGINT)
          ) AS actualizado$q$,
       'postgres', m.id_microservice, '/entes/:ID', 'SELECT', 'PUT',
       '{"PARAM.ID": "BIGINT!", "BODY.NIT": "VARCHAR", "BODY.NOMBRE": "VARCHAR",
         "BODY.FK_TMUNICIPIO": "BIGINT", "BODY.FK_TENTE_PADRE": "BIGINT"}'::jsonb
  FROM public.microservice m WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE uuid = 'pigse-entes-actualizar');

-- DELETE -> PATCH: ck_query_http_method no admite DELETE, ver V149.
INSERT INTO public.query (uuid, query, type, microservice_id, path_template, execution_mode, http_method, param_types)
SELECT 'pigse-entes-eliminar',
       $q$SELECT pigse.fn_ente_soft_delete(
              CAST(:CONTEXT.USER_ID AS BIGINT), CAST(:PARAM.ID AS BIGINT)) AS eliminado$q$,
       'postgres', m.id_microservice, '/entes/:ID', 'SELECT', 'PATCH',
       '{"PARAM.ID": "BIGINT!"}'::jsonb
  FROM public.microservice m WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE uuid = 'pigse-entes-eliminar');

-- 2. /establecimientos
INSERT INTO public.query (uuid, query, type, microservice_id, path_template, execution_mode, http_method, param_types)
SELECT 'pigse-establecimientos-query',
       $q$SELECT * FROM pigse.fn_est_listar(
              CAST(:CONTEXT.USER_ID AS BIGINT),
              CAST(:BODY.FILTERS.SEARCH AS VARCHAR),
              CAST(:BODY.FILTERS.ENTES AS BIGINT[]),
              CAST(:BODY.FILTERS.MUNICIPIOS AS VARCHAR[]),
              CAST(:BODY.SORTING.ID AS VARCHAR),
              CAST(:BODY.SORTING.DESC AS BOOLEAN),
              CAST(:BODY.PAGEINDEX AS INTEGER),
              CAST(:BODY.PAGESIZE AS INTEGER)
          )$q$,
       'postgres', m.id_microservice, '/establecimientos/query', 'SELECT', 'POST',
       '{"BODY.FILTERS.SEARCH": "VARCHAR", "BODY.FILTERS.ENTES": "BIGINT[]",
         "BODY.FILTERS.MUNICIPIOS": "VARCHAR[]", "BODY.SORTING.ID": "VARCHAR",
         "BODY.SORTING.DESC": "BOOLEAN", "BODY.PAGEINDEX": "INTEGER", "BODY.PAGESIZE": "INTEGER"}'::jsonb
  FROM public.microservice m WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE uuid = 'pigse-establecimientos-query');

INSERT INTO public.query (uuid, query, type, microservice_id, path_template, execution_mode, http_method, param_types)
SELECT 'pigse-establecimientos-buscar-pk',
       $q$SELECT * FROM pigse.fn_est_buscar_por_pk(
              CAST(:CONTEXT.USER_ID AS BIGINT), CAST(:PARAM.ID AS BIGINT))$q$,
       'postgres', m.id_microservice, '/establecimientos/:ID', 'SELECT', 'GET',
       '{"PARAM.ID": "BIGINT!"}'::jsonb
  FROM public.microservice m WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE uuid = 'pigse-establecimientos-buscar-pk');

INSERT INTO public.query (uuid, query, type, microservice_id, path_template, execution_mode, http_method, param_types)
SELECT 'pigse-establecimientos-crear',
       $q$SELECT pigse.fn_est_crear(
              CAST(:CONTEXT.USER_ID AS BIGINT),
              CAST(:BODY.FK_ENTE AS BIGINT),
              CAST(:BODY.NOMBRE AS VARCHAR),
              CAST(:BODY.NIT AS VARCHAR),
              CAST(:BODY.FK_TMUNICIPIO AS BIGINT),
              CAST(:BODY.CODIGO AS VARCHAR)
          ) AS pk_establecimiento$q$,
       'postgres', m.id_microservice, '/establecimientos', 'SELECT', 'POST',
       '{"BODY.FK_ENTE": "BIGINT!", "BODY.NOMBRE": "VARCHAR!", "BODY.NIT": "VARCHAR!",
         "BODY.FK_TMUNICIPIO": "BIGINT!", "BODY.CODIGO": "VARCHAR!"}'::jsonb
  FROM public.microservice m WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE uuid = 'pigse-establecimientos-crear');

INSERT INTO public.query (uuid, query, type, microservice_id, path_template, execution_mode, http_method, param_types)
SELECT 'pigse-establecimientos-actualizar',
       $q$SELECT pigse.fn_est_actualizar(
              CAST(:CONTEXT.USER_ID AS BIGINT),
              CAST(:PARAM.ID AS BIGINT),
              CAST(:BODY.NOMBRE AS VARCHAR),
              CAST(:BODY.NIT AS VARCHAR),
              CAST(:BODY.CODIGO AS VARCHAR),
              CAST(:BODY.FK_TMUNICIPIO AS BIGINT)
          ) AS actualizado$q$,
       'postgres', m.id_microservice, '/establecimientos/:ID', 'SELECT', 'PUT',
       '{"PARAM.ID": "BIGINT!", "BODY.NOMBRE": "VARCHAR", "BODY.NIT": "VARCHAR",
         "BODY.FK_TMUNICIPIO": "BIGINT", "BODY.CODIGO": "VARCHAR"}'::jsonb
  FROM public.microservice m WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE uuid = 'pigse-establecimientos-actualizar');

INSERT INTO public.query (uuid, query, type, microservice_id, path_template, execution_mode, http_method, param_types)
SELECT 'pigse-establecimientos-eliminar',
       $q$SELECT pigse.fn_est_soft_delete(
              CAST(:CONTEXT.USER_ID AS BIGINT), CAST(:PARAM.ID AS BIGINT)) AS eliminado$q$,
       'postgres', m.id_microservice, '/establecimientos/:ID', 'SELECT', 'PATCH',
       '{"PARAM.ID": "BIGINT!"}'::jsonb
  FROM public.microservice m WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE uuid = 'pigse-establecimientos-eliminar');

-- 3. /funcionarios
INSERT INTO public.query (uuid, query, type, microservice_id, path_template, execution_mode, http_method, param_types)
SELECT 'pigse-funcionarios-query',
       $q$SELECT * FROM pigse.fn_fun_listar(
              CAST(:CONTEXT.USER_ID AS BIGINT),
              CAST(:BODY.FILTERS.SEARCH AS VARCHAR),
              CAST(:BODY.FILTERS.ESTABLECIMIENTOS AS BIGINT[]),
              CAST(:BODY.SORTING.ID AS VARCHAR),
              CAST(:BODY.SORTING.DESC AS BOOLEAN),
              CAST(:BODY.PAGEINDEX AS INTEGER),
              CAST(:BODY.PAGESIZE AS INTEGER)
          )$q$,
       'postgres', m.id_microservice, '/funcionarios/query', 'SELECT', 'POST',
       '{"BODY.FILTERS.SEARCH": "VARCHAR", "BODY.FILTERS.ESTABLECIMIENTOS": "BIGINT[]",
         "BODY.SORTING.ID": "VARCHAR", "BODY.SORTING.DESC": "BOOLEAN",
         "BODY.PAGEINDEX": "INTEGER", "BODY.PAGESIZE": "INTEGER"}'::jsonb
  FROM public.microservice m WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE uuid = 'pigse-funcionarios-query');

INSERT INTO public.query (uuid, query, type, microservice_id, path_template, execution_mode, http_method, param_types)
SELECT 'pigse-funcionarios-buscar-pk',
       $q$SELECT * FROM pigse.fn_fun_buscar_por_pk(
              CAST(:CONTEXT.USER_ID AS BIGINT), CAST(:PARAM.ID AS BIGINT))$q$,
       'postgres', m.id_microservice, '/funcionarios/:ID', 'SELECT', 'GET',
       '{"PARAM.ID": "BIGINT!"}'::jsonb
  FROM public.microservice m WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE uuid = 'pigse-funcionarios-buscar-pk');

INSERT INTO public.query (uuid, query, type, microservice_id, path_template, execution_mode, http_method, param_types)
SELECT 'pigse-funcionarios-crear',
       $q$SELECT pigse.fn_fun_crear(
              CAST(:CONTEXT.USER_ID AS BIGINT),
              CAST(:BODY.FK_ESTABLECIMIENTO AS BIGINT),
              CAST(:BODY.CORREO_ELECTRONICO AS VARCHAR),
              CAST(:BODY.IDENTIFICACION AS VARCHAR),
              CAST(:BODY.PRIMER_NOMBRE AS VARCHAR),
              CAST(:BODY.PRIMER_APELLIDO AS VARCHAR)
          ) AS pk_funcionario$q$,
       'postgres', m.id_microservice, '/funcionarios', 'SELECT', 'POST',
       '{"BODY.FK_ESTABLECIMIENTO": "BIGINT!", "BODY.CORREO_ELECTRONICO": "VARCHAR!",
         "BODY.IDENTIFICACION": "VARCHAR!", "BODY.PRIMER_NOMBRE": "VARCHAR!",
         "BODY.PRIMER_APELLIDO": "VARCHAR!"}'::jsonb
  FROM public.microservice m WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE uuid = 'pigse-funcionarios-crear');

INSERT INTO public.query (uuid, query, type, microservice_id, path_template, execution_mode, http_method, param_types)
SELECT 'pigse-funcionarios-actualizar',
       $q$SELECT pigse.fn_fun_actualizar(
              CAST(:CONTEXT.USER_ID AS BIGINT),
              CAST(:PARAM.ID AS BIGINT),
              CAST(:BODY.CORREO_ELECTRONICO AS VARCHAR),
              CAST(:BODY.IDENTIFICACION AS VARCHAR),
              CAST(:BODY.PRIMER_NOMBRE AS VARCHAR),
              CAST(:BODY.PRIMER_APELLIDO AS VARCHAR)
          ) AS actualizado$q$,
       'postgres', m.id_microservice, '/funcionarios/:ID', 'SELECT', 'PUT',
       '{"PARAM.ID": "BIGINT!", "BODY.CORREO_ELECTRONICO": "VARCHAR", "BODY.IDENTIFICACION": "VARCHAR",
         "BODY.PRIMER_NOMBRE": "VARCHAR", "BODY.PRIMER_APELLIDO": "VARCHAR"}'::jsonb
  FROM public.microservice m WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE uuid = 'pigse-funcionarios-actualizar');

INSERT INTO public.query (uuid, query, type, microservice_id, path_template, execution_mode, http_method, param_types)
SELECT 'pigse-funcionarios-eliminar',
       $q$SELECT pigse.fn_fun_soft_delete(
              CAST(:CONTEXT.USER_ID AS BIGINT), CAST(:PARAM.ID AS BIGINT)) AS eliminado$q$,
       'postgres', m.id_microservice, '/funcionarios/:ID', 'SELECT', 'PATCH',
       '{"PARAM.ID": "BIGINT!"}'::jsonb
  FROM public.microservice m WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE uuid = 'pigse-funcionarios-eliminar');

-- 4. role_query -- el reparto ESPEJA el gate de V257: un rol con role_query
-- pero sin permiso en la funcion recibe un 42501 de la base, y al contrario
-- un 403 del gateway. Las dos listas se mueven juntas.

-- Administracion territorial: escritura completa. Son los dos roles que
-- fn_est_crear / fn_fun_crear / fn_ente_crear autorizan. La lista de uuid va
-- explicita, NO por LIKE 'pigse-%': las filas originales de PIGSE
-- (documentos, my-menus, cumplimiento -- V149/V196/V197) comparten ese
-- prefijo y un LIKE les ampliaria los permisos de rebote.
INSERT INTO public.role_query (query_id, role_id)
SELECT q.id_query, ro.id_role
  FROM public.query q
 CROSS JOIN public.role ro
  JOIN public.microservice m
    ON m.id_microservice = q.microservice_id AND m.serviceid = 'pigse'
 WHERE q.uuid IN (
       'pigse-entes-query', 'pigse-entes-buscar-pk', 'pigse-entes-crear',
       'pigse-entes-actualizar', 'pigse-entes-eliminar',
       'pigse-establecimientos-query', 'pigse-establecimientos-buscar-pk',
       'pigse-establecimientos-crear', 'pigse-establecimientos-actualizar',
       'pigse-establecimientos-eliminar',
       'pigse-funcionarios-query', 'pigse-funcionarios-buscar-pk',
       'pigse-funcionarios-crear', 'pigse-funcionarios-actualizar',
       'pigse-funcionarios-eliminar')
   AND ro.name IN ('PIGSE-ADMINISTRADOR', 'PIGSE-SECRETARIA_TERRITORIAL')
   AND NOT EXISTS (SELECT 1 FROM public.role_query rq WHERE rq.query_id = q.id_query AND rq.role_id = ro.id_role);

-- Ente territorial (5 roles): escritura sobre /entes y /establecimientos.
INSERT INTO public.role_query (query_id, role_id)
SELECT q.id_query, ro.id_role
  FROM public.query q
 CROSS JOIN public.role ro
 WHERE q.uuid IN (
       'pigse-entes-query', 'pigse-entes-buscar-pk', 'pigse-entes-crear',
       'pigse-entes-actualizar', 'pigse-entes-eliminar',
       'pigse-establecimientos-query', 'pigse-establecimientos-buscar-pk',
       'pigse-establecimientos-crear', 'pigse-establecimientos-actualizar',
       'pigse-establecimientos-eliminar',
       'pigse-funcionarios-query', 'pigse-funcionarios-buscar-pk')
   AND ro.name IN ('PIGSE-DIRECTOR_ENTE_TERRITORIAL', 'PIGSE-JEFE_SISTEMA_ENTE_TERRITORIAL',
                   'PIGSE-JEFE_AREA_PLANEACION', 'PIGSE-JEFE_AREA_COBERTURA', 'PIGSE-JEFE_AREA_CALIDAD')
   AND NOT EXISTS (SELECT 1 FROM public.role_query rq WHERE rq.query_id = q.id_query AND rq.role_id = ro.id_role);

-- Establecimiento (2 roles): escritura sobre /funcionarios, lectura del resto.
INSERT INTO public.role_query (query_id, role_id)
SELECT q.id_query, ro.id_role
  FROM public.query q
 CROSS JOIN public.role ro
 WHERE q.uuid IN (
       'pigse-entes-query', 'pigse-entes-buscar-pk',
       'pigse-establecimientos-query', 'pigse-establecimientos-buscar-pk',
       'pigse-funcionarios-query', 'pigse-funcionarios-buscar-pk',
       'pigse-funcionarios-crear', 'pigse-funcionarios-actualizar', 'pigse-funcionarios-eliminar')
   AND ro.name IN ('PIGSE-RECTOR', 'PIGSE-JEFE_SISTEMA_ESTABLECIMIENTO')
   AND NOT EXISTS (SELECT 1 FROM public.role_query rq WHERE rq.query_id = q.id_query AND rq.role_id = ro.id_role);

-- Auxiliar administrativo: solo lectura (los /query y los GET por pk).
INSERT INTO public.role_query (query_id, role_id)
SELECT q.id_query, ro.id_role
  FROM public.query q
 CROSS JOIN public.role ro
 WHERE q.uuid IN (
       'pigse-entes-query', 'pigse-entes-buscar-pk',
       'pigse-establecimientos-query', 'pigse-establecimientos-buscar-pk',
       'pigse-funcionarios-query', 'pigse-funcionarios-buscar-pk')
   AND ro.name = 'PIGSE-AUXILIAR_ADMINISTRATIVO'
   AND NOT EXISTS (SELECT 1 FROM public.role_query rq WHERE rq.query_id = q.id_query AND rq.role_id = ro.id_role);
