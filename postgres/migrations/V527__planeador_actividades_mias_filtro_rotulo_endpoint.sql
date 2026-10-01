-- ===========================================================================
-- V527 — GET /planeador/actividades/mias: agrega ?grado_asignatura_pares=
-- (V526, fn_actividad_listar_docente). Mismo estilo incremental que V279
-- (reemplazo textual del final de la llamada posicional) y mismo guard
-- (NOT LIKE) para que la migracion sea reaplicable sin duplicar el bind.
-- Depende de: V279 (ultimo que toco el texto de esta fila), V526.
-- ===========================================================================

SET search_path TO academico_test, public;

UPDATE public.query q
   SET query = replace(
                 q.query,
                 E'CAST(:QUERY.DIA AS DATE)\n);',
                 E'CAST(:QUERY.DIA AS DATE),\n    CAST(:QUERY.GRADO_ASIGNATURA_PARES AS JSONB)\n);'
               ),
       param_types = COALESCE(q.param_types, '{}'::jsonb)
                     || '{"QUERY.GRADO_ASIGNATURA_PARES": "JSONB"}'::jsonb
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/actividades/mias'
   AND q.http_method     = 'GET'
   AND q.query LIKE '%fn_actividad_listar_docente%'
   AND q.query NOT LIKE '%QUERY.GRADO_ASIGNATURA_PARES%';
