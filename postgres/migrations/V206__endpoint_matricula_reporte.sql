-- ===========================================================================
-- V206 - Reporte de Matricula (PDF/Excel): la misma fn_matricula_listar del
-- listado, sin paginar, en una ruta que llama reporting-service. Las columnas
-- del archivo las filtra reporting-service con el `columns` del body; esta
-- fila solo trae las filas. Roles: los mismos de /matricula/query (V127).
--
-- Depende de: V270 (fn_matricula_listar), V127 (/matricula/query y sus
-- role_query), V68 (reporting-service).
-- ===========================================================================

SET search_path TO public;

-- 1. Endpoint del reporte -- misma fn_matricula_listar, sin paginar.
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-matricula-reporte',
    'SELECT * FROM academico_test.fn_matricula_listar(
              p_search     => CAST(:BODY.FILTERS.SEARCH AS TEXT),
              p_statuses   => CAST(:BODY.FILTERS.STATUSES AS TEXT[]),
              p_campus     => CAST(:BODY.FILTERS.CAMPUS AS TEXT),
              p_shift      => CAST(:BODY.FILTERS.SHIFT AS TEXT),
              p_grade      => CAST(:BODY.FILTERS.GRADE AS INT),
              p_group      => CAST(:BODY.FILTERS.GROUP AS TEXT),
              p_page_index => NULL::INT,
              p_page_size  => NULL::INT,
              p_pk_usuario => public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
              p_sort_by    => CAST(:BODY.SORTING.SORTBY AS TEXT),
              p_sort_dir   => CAST(:BODY.SORTING.SORTDIR AS TEXT)
          )',
    'postgres', false, false,
    m.id_microservice,
    '/matricula/reporte', 'SELECT', 'POST',
    -- reporting-service empaqueta los filtros bajo "filters" y el orden bajo
    -- "sorting" (no los binds planos de /matricula/query); sin PAGEINDEX/PAGESIZE.
    '{"BODY.FILTERS.GRADE": "INTEGER", "BODY.FILTERS.GROUP": "TEXT", "BODY.FILTERS.SHIFT": "TEXT", "BODY.FILTERS.CAMPUS": "TEXT", "BODY.FILTERS.SEARCH": "TEXT", "BODY.SORTING.SORTBY": "TEXT", "BODY.SORTING.SORTDIR": "TEXT", "BODY.FILTERS.STATUSES": "TEXT[]"}'::jsonb,
    NULL,
    'V206 -- Reporte de Matricula: igual que /matricula/query (fn_matricula_listar) pero SIN paginar -- el insumo que reporting-service usa para armar el PDF/Excel. Las columnas del archivo las decide reporting-service (config + el `columns` que mande el front con las que tenga visibles en la tabla), no esta fila. Mismo gate que el listado: fn_matricula_puede_ver por fila dentro de la funcion reusada.',
    NULL,
    NULL,
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

-- 2. role_query -- copia 1:1 de /matricula/query (POST).
INSERT INTO public.role_query (role_id, query_id)
SELECT rq.role_id, q_new.id_query
  FROM public.role_query rq
  JOIN public.query q_old ON q_old.id_query = rq.query_id
                          AND q_old.path_template = '/matricula/query'
                          AND q_old.http_method = 'POST'
  JOIN public.query q_new ON q_new.uuid = 'q-matricula-reporte'
 WHERE NOT EXISTS (
     SELECT 1 FROM public.role_query rq2
      WHERE rq2.query_id = q_new.id_query AND rq2.role_id = rq.role_id
 );
