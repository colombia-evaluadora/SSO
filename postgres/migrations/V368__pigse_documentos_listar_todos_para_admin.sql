-- ============================================================================
-- V368 — "Gestion Documental" para PIGSE-ADMINISTRADOR/PIGSE-SECRETARIA_TERRITORIAL:
-- fila POST /documentos/todos/query (todas las instituciones, paginado en
-- servidor) y sus grants. Las funciones vigentes estan en V374
-- (fn_documentos_listar_todos_paginado) y V512 (fn_documentos_listar_todos);
-- V374 reescribe query/param_types de la fila y V495 la usa de plantilla.
-- ============================================================================

INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT gen_random_uuid()::text,
       $q$SELECT * FROM pigse.fn_documentos_listar_todos_paginado(
           CAST(:BODY.FILTERS.SEARCH AS VARCHAR),
           CAST(:BODY.SORTING.ID AS VARCHAR),
           CAST(:BODY.SORTING.DESC AS BOOLEAN),
           CAST(:BODY.PAGEINDEX AS INTEGER),
           CAST(:BODY.PAGESIZE AS INTEGER)
       )$q$,
       'postgres', false, false, m.id_microservice, '/documentos/todos/query', 'SELECT', 'POST',
       '{"BODY.PAGESIZE":"INTEGER","BODY.PAGEINDEX":"INTEGER","BODY.SORTING.ID":"VARCHAR","BODY.SORTING.DESC":"BOOLEAN","BODY.FILTERS.SEARCH":"VARCHAR"}'::jsonb,
       'Gestion documental PIGSE: documentos de TODAS las instituciones, paginado real en servidor, para roles de fiscalizacion (admin/secretaria territorial).'
  FROM public.microservice m
 WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE microservice_id = m.id_microservice AND path_template = '/documentos/todos/query' AND http_method = 'POST');

INSERT INTO public.role_query (role_id, query_id)
SELECT ro.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  CROSS JOIN public.role ro
 WHERE m.serviceid = 'pigse'
   AND q.path_template IN ('/documentos/todos', '/documentos/todos/query')
   AND ro.name IN ('PIGSE-ADMINISTRADOR', 'PIGSE-SECRETARIA_TERRITORIAL')
ON CONFLICT DO NOTHING;
