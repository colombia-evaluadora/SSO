-- ============================================================================
-- V384 — las tarjetas de stats (Sesiones/Sesiones activas/Operaciones y
-- Insert/Update/Delete) eran completamente estáticas: /audits/stats no
-- declaraba NINGÚN parámetro (agregados globales fijos) y
-- /audit-tables/:SLUG/operations/stats solo aceptaba un rango de fechas,
-- nunca la selección (`ids`) que el resto de la pantalla sí soporta
-- (exportar seleccionados, por ejemplo). Reportado en vivo: las tarjetas
-- no reflejaban ni el filtro activo (p.ej. "estado:(Cerrada)") ni las
-- filas marcadas con check.
--
-- Fix: ambos endpoints (pigse + cval) ganan soporte real de filtros/ids:
--   - /audits/stats: BODY.IDS (family_id separados por coma) tiene
--     prioridad; si viene vacío, aplica los mismos filtros que
--     /audits/query (author/status/startedFrom/startedTo). Sin ids NI
--     filtros, el resultado es el total de todas las sesiones de la app
--     (ya no ceñido a "hoy" -- la tarjeta dice "Sesiones", no "Sesiones
--     de hoy", así que mostrar el total real cuando no hay ningún filtro
--     activo es más coherente que el gate arbitrario por fecha que tenía
--     antes).
--   - /audit-tables/:SLUG/operations/stats: agrega BODY.IDS
--     (lsn-seq separados por coma) con la misma prioridad sobre el rango
--     de fechas existente.
-- ============================================================================

UPDATE public.query q
   SET query = $Q$
WITH latest AS (
    SELECT family_id,
           argMax(started_at, lsn) AS started_at,
           argMax(ended_at, lsn) AS ended_at,
           argMax(close_reason, lsn) AS close_reason,
           argMax(last_seen_at, lsn) AS last_seen_at,
           argMax(app_name, lsn) AS app_name
      FROM auditoria.tsesion_web
     GROUP BY family_id
),
abiertas AS (
    SELECT family_id, started_at,
           CASE
               WHEN close_reason != '' THEN ended_at
               WHEN dateDiff('minute', last_seen_at, now()) > 30 THEN last_seen_at
               ELSE NULL
           END AS ended_at_computed
      FROM latest
     WHERE app_name = 'PIGSE'
),
sesiones AS (
    SELECT family_id, started_at,
           CASE WHEN ended_at_computed IS NULL THEN 'active' ELSE 'closed' END AS status
      FROM abiertas
),
filtradas AS (
    SELECT s.family_id, s.started_at, s.status
      FROM sesiones s
      LEFT JOIN auditoria.audit_log audit ON audit.sesion_id = s.family_id
     GROUP BY s.family_id, s.started_at, s.status
    HAVING
        (:BODY.IDS != '' AND has(splitByChar(',', :BODY.IDS), s.family_id))
        OR
        (:BODY.IDS = ''
         AND (coalesce(:BODY.FILTERS.AUTHOR, '') = '' OR positionCaseInsensitive(any(audit.app_user), :BODY.FILTERS.AUTHOR) > 0)
         AND (coalesce(:BODY.FILTERS.STATUS, '') = '' OR s.status = :BODY.FILTERS.STATUS)
         AND s.started_at >= parseDateTimeBestEffort(if(:BODY.FILTERS.STARTEDFROM = '', '1970-01-01', :BODY.FILTERS.STARTEDFROM))
         AND s.started_at <= parseDateTimeBestEffort(if(:BODY.FILTERS.STARTEDTO = '', '2999-12-31', :BODY.FILTERS.STARTEDTO))
        )
)
SELECT
    count() AS sessionsToday,
    countIf(status = 'active') AS activeSessions,
    (SELECT count() FROM auditoria.audit_log WHERE sesion_id IN (SELECT family_id FROM filtradas)) AS operationsToday
FROM filtradas;
$Q$,
       param_types = '{"BODY.IDS": "VARCHAR", "BODY.FILTERS.AUTHOR": "VARCHAR", "BODY.FILTERS.STATUS": "VARCHAR", "BODY.FILTERS.STARTEDTO": "VARCHAR", "BODY.FILTERS.STARTEDFROM": "VARCHAR"}'::jsonb
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid = 'audit-clickhouse-pigse'
   AND q.path_template = '/audits/stats';

UPDATE public.query q
   SET query = $Q$
WITH latest AS (
    SELECT family_id,
           argMax(started_at, lsn) AS started_at,
           argMax(ended_at, lsn) AS ended_at,
           argMax(close_reason, lsn) AS close_reason,
           argMax(last_seen_at, lsn) AS last_seen_at,
           argMax(app_name, lsn) AS app_name
      FROM auditoria.tsesion_web
     GROUP BY family_id
),
abiertas AS (
    SELECT family_id, started_at,
           CASE
               WHEN close_reason != '' THEN ended_at
               WHEN dateDiff('minute', last_seen_at, now()) > 30 THEN last_seen_at
               ELSE NULL
           END AS ended_at_computed
      FROM latest
     WHERE app_name = 'COLOMBIA-EVALUADORA'
),
sesiones AS (
    SELECT family_id, started_at,
           CASE WHEN ended_at_computed IS NULL THEN 'active' ELSE 'closed' END AS status
      FROM abiertas
),
filtradas AS (
    SELECT s.family_id, s.started_at, s.status
      FROM sesiones s
      LEFT JOIN auditoria.audit_log audit ON audit.sesion_id = s.family_id
     GROUP BY s.family_id, s.started_at, s.status
    HAVING
        (coalesce(:BODY.IDS, '') != '' AND has(splitByChar(',', :BODY.IDS), s.family_id))
        OR
        (coalesce(:BODY.IDS, '') = ''
         AND (coalesce(:BODY.FILTERS.AUTHOR, '') = '' OR positionCaseInsensitive(any(audit.app_user), :BODY.FILTERS.AUTHOR) > 0)
         AND (coalesce(:BODY.FILTERS.STATUS, '') = '' OR s.status = :BODY.FILTERS.STATUS)
         AND s.started_at >= parseDateTimeBestEffort(if(coalesce(:BODY.FILTERS.STARTEDFROM, '') = '', '1970-01-01', :BODY.FILTERS.STARTEDFROM))
         AND s.started_at <= parseDateTimeBestEffort(if(coalesce(:BODY.FILTERS.STARTEDTO, '') = '', '2999-12-31', :BODY.FILTERS.STARTEDTO))
        )
)
SELECT
    count() AS sessionsToday,
    countIf(status = 'active') AS activeSessions,
    (SELECT count() FROM auditoria.audit_log WHERE sesion_id IN (SELECT family_id FROM filtradas)) AS operationsToday
FROM filtradas;
$Q$,
       param_types = '{"BODY.IDS": "Nullable(String)", "BODY.FILTERS.AUTHOR": "Nullable(String)", "BODY.FILTERS.STATUS": "Nullable(String)", "BODY.FILTERS.STARTEDTO": "Nullable(String)", "BODY.FILTERS.STARTEDFROM": "Nullable(String)"}'::jsonb
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid = 'audit-clickhouse-cval'
   AND q.path_template = '/audits/stats';

UPDATE public.query q
   SET query = $Q$
WITH slug_calc AS (
    SELECT concat('t', substring(lower(replaceRegexpAll(substring(:PARAM.SLUG, 2), '([A-Z])', '_\1')), 2)) AS tabla_bare
)
SELECT
    countIf(operacion = 'c') AS inserts,
    countIf(operacion = 'u') AS updates,
    countIf(operacion = 'd') AS deletes
FROM auditoria.audit_log, slug_calc
WHERE (tabla = concat('pigse.', tabla_bare) OR tabla = tabla_bare)
  AND operacion != 'r'
  AND sesion_id IN (SELECT family_id FROM auditoria.tsesion_web WHERE app_name = 'PIGSE')
  AND (
      (coalesce(:BODY.IDS, '') != '' AND has(splitByChar(',', :BODY.IDS), concat(toString(lsn), '-', toString(seq))))
      OR
      (coalesce(:BODY.IDS, '') = ''
       AND ts >= parseDateTimeBestEffort(if(coalesce(:BODY.FILTERS.OCCURREDFROM, '') = '', '1970-01-01', :BODY.FILTERS.OCCURREDFROM))
       AND ts <= parseDateTimeBestEffort(if(coalesce(:BODY.FILTERS.OCCURREDTO, '') = '', '2999-12-31', :BODY.FILTERS.OCCURREDTO))
      )
  );
$Q$,
       param_types = param_types || '{"BODY.IDS": "VARCHAR"}'::jsonb
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid = 'audit-clickhouse-pigse'
   AND q.path_template = '/audit-tables/:SLUG/operations/stats';

UPDATE public.query q
   SET query = $Q$
WITH slug_calc AS (
    SELECT concat('t', substring(lower(replaceRegexpAll(substring(:PARAM.SLUG, 2), '([A-Z])', '_\1')), 2)) AS tabla_bare
)
SELECT
    countIf(operacion = 'c') AS inserts,
    countIf(operacion = 'u') AS updates,
    countIf(operacion = 'd') AS deletes
FROM auditoria.audit_log, slug_calc
WHERE (tabla = concat('academico_test.', tabla_bare) OR tabla = tabla_bare)
  AND operacion != 'r'
  AND sesion_id IN (SELECT family_id FROM auditoria.tsesion_web WHERE app_name = 'COLOMBIA-EVALUADORA')
  AND (
      (coalesce(:BODY.IDS, '') != '' AND has(splitByChar(',', :BODY.IDS), concat(toString(lsn), '-', toString(seq))))
      OR
      (coalesce(:BODY.IDS, '') = ''
       AND ts >= parseDateTimeBestEffort(if(coalesce(:BODY.FILTERS.OCCURREDFROM, '') = '', '1970-01-01', :BODY.FILTERS.OCCURREDFROM))
       AND ts <= parseDateTimeBestEffort(if(coalesce(:BODY.FILTERS.OCCURREDTO, '') = '', '2999-12-31', :BODY.FILTERS.OCCURREDTO))
      )
  );
$Q$,
       param_types = param_types || '{"BODY.IDS": "VARCHAR"}'::jsonb
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid = 'audit-clickhouse-cval'
   AND q.path_template = '/audit-tables/:SLUG/operations/stats';

DO $$
DECLARE
    v_ok BOOLEAN;
BEGIN
    SELECT bool_and(q.param_types ? 'BODY.IDS') INTO v_ok
      FROM public.query q
      JOIN public.microservice m ON m.id_microservice = q.microservice_id
     WHERE m.serviceid IN ('audit-clickhouse-pigse', 'audit-clickhouse-cval')
       AND q.path_template IN ('/audits/stats', '/audit-tables/:SLUG/operations/stats');

    IF NOT coalesce(v_ok, false) THEN
        RAISE EXCEPTION 'V384: alguna de las 4 filas no gano el parametro BODY.IDS';
    END IF;

    RAISE NOTICE 'V384 OK: /audits/stats y /audit-tables/:SLUG/operations/stats (pigse+cval) ahora aceptan filtros/ids reales.';
END $$;
