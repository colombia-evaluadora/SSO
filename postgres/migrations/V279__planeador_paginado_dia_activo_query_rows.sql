-- ===========================================================================
-- V279 - Planeador: ?dia= (paginado por dia activo) alcanzable por HTTP en
-- GET /planeador/actividades y /planeador/actividades/mias.
--
-- Las filas ya registradas no se actualizan con ON CONFLICT DO NOTHING, asi que
-- se reconcilian con UPDATE: reemplazo textual del final de la llamada.
-- El guard es ':QUERY.DIA AS DATE' completo porque QUERY.DIAS_GRACIA tambien
-- contiene 'QUERY.DIA'. La fila de GET /planeador/unidades vive en V492.4.
-- Depende de: V224 (fn_actividad_listar*, con p_dia), V246/V250, V253.
-- ===========================================================================

SET search_path TO academico_test, public;

-- GET /planeador/actividades: la fila omite p_fk_tfuncionario (posicion 17);
-- se rellena con NULL para llegar a p_dia (18).
UPDATE public.query q
   SET query = replace(
                 q.query,
                 E'COALESCE(CAST(:QUERY.OFFSET AS INT), 0)\n);',
                 E'COALESCE(CAST(:QUERY.OFFSET AS INT), 0),\n    NULL,\n    CAST(:QUERY.DIA AS DATE)\n);'
               ),
       param_types = COALESCE(q.param_types, '{}'::jsonb)
                     || '{"QUERY.DIA": "DATE"}'::jsonb
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/actividades'
   AND q.http_method     = 'GET'
   AND q.query LIKE '%fn_actividad_listar(%'
   AND q.query NOT LIKE '%:QUERY.DIA AS DATE%';

-- GET /planeador/actividades/mias: p_dia es el ultimo argumento.
UPDATE public.query q
   SET query = replace(
                 q.query,
                 E'COALESCE(CAST(:QUERY.OFFSET AS INT), 0)\n);',
                 E'COALESCE(CAST(:QUERY.OFFSET AS INT), 0),\n    CAST(:QUERY.DIA AS DATE)\n);'
               ),
       param_types = COALESCE(q.param_types, '{}'::jsonb)
                     || '{"QUERY.DIA": "DATE"}'::jsonb
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/actividades/mias'
   AND q.http_method     = 'GET'
   AND q.query LIKE '%fn_actividad_listar_docente%'
   AND q.query NOT LIKE '%:QUERY.DIA AS DATE%';
