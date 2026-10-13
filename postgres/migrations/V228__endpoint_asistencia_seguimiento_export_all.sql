-- =============================================================================
-- V228 -- POST /asistencias/export-all: reporte PDF/Excel de Seguimiento
-- (reporting-service, clave `asistencias`). Es fn_asistencia_listar_seguimiento
-- sin paginar, con los mismos filtros, gate y alcance que /asistencias/query.
-- La fila nace completa (SEDE/JORNADA/GRADO, sin JOIN): los parches de V436 y
-- V438 sobre ella son no-op, asi re-aplicar este archivo solo no le quita filtros.
-- FILTERS.IDS recorta por fuera de la funcion, despues del gate. SORTING.DESC
-- vale TRUE por defecto, igual que el listado.
-- Tras aplicar, reiniciar query-service-eval-col (cachea el catalogo).
-- Depende de: V438 (fn_asistencia_listar_seguimiento), V221 ('asis-seguimiento'),
-- V48 (fn_get_academico_usuario_id), V68 (reporting-service).
-- =============================================================================

DELETE FROM public.query WHERE uuid = 'eval-col-asistencias-seguimiento-export-all-001';

INSERT INTO public.query (
    uuid, query, type, public_end, captcha, detail, action, style,
    createddate, microservice_id, path_template, execution_mode,
    out_param_names, http_method, param_types, cacheable, cache_ttl_seconds
)
SELECT
    'eval-col-asistencias-seguimiento-export-all-001',
    $q$SELECT t.*
  FROM academico_test.fn_asistencia_listar_seguimiento(
    p_pk_usuario      => public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    p_fecha_desde     => CAST(:BODY.FILTERS.FECHA_DESDE AS DATE),
    p_fecha_hasta     => CAST(:BODY.FILTERS.FECHA_HASTA AS DATE),
    p_fk_tgrupo       => CAST(:BODY.FILTERS.GRUPO AS BIGINT),
    p_fk_tasignatura  => CAST(:BODY.FILTERS.ASIGNATURA AS BIGINT),
    p_fk_tactividad   => CAST(:BODY.FILTERS.ACTIVIDAD AS BIGINT),
    p_tipo_asistencia => CAST(:BODY.FILTERS.TIPO_ASISTENCIA AS NUMERIC),
    p_search          => CAST(:BODY.FILTERS.SEARCH AS TEXT),
    p_fk_tsede        => CAST(:BODY.FILTERS.SEDE AS BIGINT),
    p_jornada         => CAST(:BODY.FILTERS.JORNADA AS TEXT),
    p_grado           => CAST(:BODY.FILTERS.GRADO AS TEXT),
    p_page_index      => NULL::INTEGER,
    p_page_size       => NULL::INTEGER,
    p_sort_by         => CAST(:BODY.SORTING.ID AS TEXT),
    p_sort_dir        => CASE WHEN COALESCE(CAST(:BODY.SORTING.DESC AS BOOLEAN), TRUE)
                              THEN 'desc' ELSE 'asc' END
) t
 WHERE CAST(:BODY.FILTERS.IDS AS BIGINT[]) IS NULL
    OR t.pk_tasistencia = ANY(CAST(:BODY.FILTERS.IDS AS BIGINT[]));$q$,
    listado.type, FALSE, FALSE,
    'V228 -- registros de asistencia SIN PAGINAR para el reporte PDF/Excel de la pantalla Seguimiento (reporting-service, clave asistencias). Misma funcion, mismos filtros y mismo gate/alcance que POST /asistencias/query (fn_asistencia_listar_seguimiento, V438/V221), con los binds bajo BODY.FILTERS.* (FECHA_DESDE, FECHA_HASTA, SEDE, JORNADA, GRADO, GRUPO, ASIGNATURA, ACTIVIDAD, TIPO_ASISTENCIA, SEARCH) + FILTERS.IDS para exportar seleccionados y SORTING.ID/DESC para el orden. TODOS los filtros son opcionales (exporta lo que el usuario este viendo). grado/grado_valor/jornada los devuelve la propia funcion. No es /asistencias/reporte (V290), que es el reporte por grupo con GRUPO y rango de fechas obligatorios.',
    listado.action, listado.style,
    CURRENT_TIMESTAMP, listado.microservice_id,
    '/asistencias/export-all',
    listado.execution_mode, NULL, 'POST',
    '{"BODY.FILTERS.FECHA_DESDE":     "VARCHAR",
      "BODY.FILTERS.FECHA_HASTA":     "VARCHAR",
      "BODY.FILTERS.GRUPO":           "BIGINT",
      "BODY.FILTERS.ASIGNATURA":      "BIGINT",
      "BODY.FILTERS.ACTIVIDAD":       "BIGINT",
      "BODY.FILTERS.TIPO_ASISTENCIA": "NUMERIC",
      "BODY.FILTERS.SEARCH":          "VARCHAR",
      "BODY.FILTERS.SEDE":            "BIGINT",
      "BODY.FILTERS.JORNADA":         "VARCHAR",
      "BODY.FILTERS.GRADO":           "VARCHAR",
      "BODY.FILTERS.IDS":             "BIGINT[]",
      "BODY.SORTING.ID":              "VARCHAR",
      "BODY.SORTING.DESC":            "BOOLEAN"}'::JSONB,
    FALSE, COALESCE(listado.cache_ttl_seconds, 0)
  FROM public.query listado
  JOIN public.microservice m ON m.id_microservice = listado.microservice_id
 WHERE m.serviceid = 'eval-col'
   AND listado.uuid = 'asis-seguimiento'
 LIMIT 1;

-- Quien ve el listado puede exportarlo: roles copiados, nunca por nombre.
INSERT INTO public.role_query (query_id, role_id)
SELECT reporte.id_query, rq.role_id
  FROM public.query reporte
  JOIN public.query listado  ON listado.uuid = 'asis-seguimiento'
  JOIN public.role_query rq  ON rq.query_id = listado.id_query
 WHERE reporte.uuid = 'eval-col-asistencias-seguimiento-export-all-001'
ON CONFLICT (query_id, role_id) DO NOTHING;

-- Mismas reglas que 'asis-seguimiento'; las fechas no se acotan: las rechaza el cast.
INSERT INTO public.query_param_constraint
       (query_id, param_key, only_positive, allow_decimals, max_digits,
        numeric_text, min_length, max_length, min_value, max_value)
SELECT q.id_query, c.param_key, c.only_positive, c.allow_decimals, c.max_digits,
       c.numeric_text, c.min_length, c.max_length, c.min_value, c.max_value
  FROM (VALUES
    ('BODY.FILTERS.GRUPO',           TRUE,  FALSE, NULL::integer, NULL::boolean, NULL::integer, NULL::integer, NULL::numeric, NULL::numeric),
    ('BODY.FILTERS.ASIGNATURA',      TRUE,  FALSE, NULL,   NULL,   NULL,   NULL,   NULL,   NULL),
    ('BODY.FILTERS.ACTIVIDAD',       TRUE,  FALSE, NULL,   NULL,   NULL,   NULL,   NULL,   NULL),
    ('BODY.FILTERS.TIPO_ASISTENCIA', TRUE,  FALSE, 1,      NULL,   NULL,   NULL,   1::numeric, 6::numeric),
    ('BODY.FILTERS.SEARCH',          NULL,  NULL,  NULL,   FALSE,  NULL,   100,    NULL,   NULL),
    ('BODY.FILTERS.SEDE',            TRUE,  FALSE, NULL,   NULL,   NULL,   NULL,   NULL,   NULL),
    ('BODY.FILTERS.JORNADA',         NULL,  NULL,  NULL,   FALSE,  NULL,   60,     NULL,   NULL),
    ('BODY.FILTERS.GRADO',           NULL,  NULL,  NULL,   FALSE,  NULL,   60,     NULL,   NULL)
  ) AS c(param_key, only_positive, allow_decimals, max_digits,
         numeric_text, min_length, max_length, min_value, max_value)
 CROSS JOIN (SELECT id_query FROM public.query
              WHERE uuid = 'eval-col-asistencias-seguimiento-export-all-001') q
ON CONFLICT (query_id, param_key) DO UPDATE
   SET only_positive  = EXCLUDED.only_positive,
       allow_decimals = EXCLUDED.allow_decimals,
       max_digits     = EXCLUDED.max_digits,
       numeric_text   = EXCLUDED.numeric_text,
       min_length     = EXCLUDED.min_length,
       max_length     = EXCLUDED.max_length,
       min_value      = EXCLUDED.min_value,
       max_value      = EXCLUDED.max_value;

-- Sin 'asis-seguimiento' el INSERT no crea nada: mejor que reviente a un 404 mudo.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.query
                    WHERE uuid = 'eval-col-asistencias-seguimiento-export-all-001') THEN
        RAISE EXCEPTION 'V228: no se creo la fila de /asistencias/export-all (falta la fila asis-seguimiento de POST /asistencias/query, V221)';
    END IF;
END $$;
