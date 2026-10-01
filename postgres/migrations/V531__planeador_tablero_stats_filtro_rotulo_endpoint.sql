-- ===========================================================================
-- V531 — GET /planeador/actividades/tablero y GET /planeador/actividades/
-- stats (alias con la nomenclatura del front, V252): agregan
-- ?grado_asignatura_pares= (V530), mismo contrato CSV que V527/V529 ya le
-- dieron a /mias y /calendario. Sin esto las 4 tarjetas de resumen sumaban
-- TODOS los rotulos del docente y no cambiaban al moverse entre pestañas.
-- Dollar-quoting para reescribir el texto completo, igual que V527/V529.
-- Depende de: V250 (tablero), V252 (stats), V530.
-- ===========================================================================

SET search_path TO academico_test, public;

UPDATE public.query q
   SET query = $q$SELECT * FROM academico_test.fn_actividad_resumen_estados_docente(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.ASIGNATURA AS BIGINT),
    CAST(:QUERY.GRUPO AS BIGINT),
    CAST(:QUERY.UNIDAD AS BIGINT),
    CAST(:QUERY.FECHA_DESDE AS DATE),
    CAST(:QUERY.FECHA_HASTA AS DATE),
    COALESCE(CAST(:QUERY.DIAS_GRACIA AS INT), 2),
    string_to_array(NULLIF(TRIM(CAST(:QUERY.GRADO_ASIGNATURA_PARES AS VARCHAR)), ''), ',')
);$q$,
       param_types = (COALESCE(q.param_types, '{}'::jsonb) - 'QUERY.GRADO_ASIGNATURA_PARES')
                     || '{
                          "QUERY.ASIGNATURA": "BIGINT", "QUERY.GRUPO": "BIGINT",
                          "QUERY.UNIDAD": "BIGINT", "QUERY.FECHA_DESDE": "DATE",
                          "QUERY.FECHA_HASTA": "DATE", "QUERY.DIAS_GRACIA": "INT",
                          "QUERY.GRADO_ASIGNATURA_PARES": "VARCHAR"
                        }'::jsonb
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/actividades/tablero'
   AND q.http_method     = 'GET'
   AND q.query LIKE '%fn_actividad_resumen_estados_docente%';

UPDATE public.query q
   SET query = $q$SELECT t.pendientes_por_evaluar AS pending,
       t.en_evaluacion          AS in_progress,
       t.finalizadas            AS completed,
       t.vencidas               AS cancelled,
       t.pendientes_por_evaluar,
       t.en_evaluacion,
       t.finalizadas,
       t.vencidas,
       t.total
  FROM academico_test.fn_actividad_resumen_estados_docente(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.ASIGNATURA AS BIGINT),
    CAST(:QUERY.GRUPO AS BIGINT),
    CAST(:QUERY.UNIDAD AS BIGINT),
    CAST(:QUERY.FECHA_DESDE AS DATE),
    CAST(:QUERY.FECHA_HASTA AS DATE),
    COALESCE(CAST(:QUERY.DIAS_GRACIA AS INT), 2),
    string_to_array(NULLIF(TRIM(CAST(:QUERY.GRADO_ASIGNATURA_PARES AS VARCHAR)), ''), ',')
) t;$q$,
       param_types = (COALESCE(q.param_types, '{}'::jsonb) - 'QUERY.GRADO_ASIGNATURA_PARES')
                     || '{
                          "QUERY.ASIGNATURA": "BIGINT", "QUERY.GRUPO": "BIGINT",
                          "QUERY.UNIDAD": "BIGINT", "QUERY.FECHA_DESDE": "DATE",
                          "QUERY.FECHA_HASTA": "DATE", "QUERY.DIAS_GRACIA": "INT",
                          "QUERY.GRADO_ASIGNATURA_PARES": "VARCHAR"
                        }'::jsonb
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/actividades/stats'
   AND q.http_method     = 'GET'
   AND q.query LIKE '%fn_actividad_resumen_estados_docente%';

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.query
         WHERE path_template = '/planeador/actividades/tablero' AND http_method = 'GET'
           AND query LIKE '%GRADO_ASIGNATURA_PARES AS VARCHAR%'
    ) THEN
        RAISE EXCEPTION 'No se actualizo GET /planeador/actividades/tablero';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.query
         WHERE path_template = '/planeador/actividades/stats' AND http_method = 'GET'
           AND query LIKE '%GRADO_ASIGNATURA_PARES AS VARCHAR%'
    ) THEN
        RAISE EXCEPTION 'No se actualizo GET /planeador/actividades/stats';
    END IF;
END $$;
