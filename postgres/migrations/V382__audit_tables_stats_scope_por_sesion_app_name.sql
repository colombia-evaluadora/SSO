-- ============================================================================
-- V382 — mismo bug que V381, encontrado en un tercer endpoint que se
-- había quedado sin tocar: /audit-tables/:SLUG/operations/stats (las
-- tarjetas Insert/Update/Delete de la pantalla de detalle de una tabla).
-- Reportado en vivo: esas tarjetas mostraban 0/0/0 mientras la lista de
-- abajo (ya corregida en V381) sí mostraba una fila UPDATE real.
--
-- Mismo fix que V381: en vez de exigir `tabla = 'esquema.tXxx'` exacto,
-- se acepta también la forma sin prefijo, y en vez de confiar en el
-- prefijo de esquema para saber a qué app pertenece la fila, se
-- resuelve vía `sesion_id -> auditoria.tsesion_web.app_name` (V377).
-- Ver V380/V381 para el análisis completo de la causa raíz (cdc-worker,
-- AuditRecord.fromEvent no combina schema+table).
-- ============================================================================

UPDATE public.query q
   SET query = $Q$WITH slug_calc AS (
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
  AND ts >= parseDateTimeBestEffort(if(:BODY.FILTERS.OCCURREDFROM = '', '1970-01-01', :BODY.FILTERS.OCCURREDFROM))
  AND ts <= parseDateTimeBestEffort(if(:BODY.FILTERS.OCCURREDTO = '', '2999-12-31', :BODY.FILTERS.OCCURREDTO));
$Q$
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid = 'audit-clickhouse-pigse'
   AND q.path_template = '/audit-tables/:SLUG/operations/stats';

UPDATE public.query q
   SET query = $Q$WITH slug_calc AS (
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
  AND ts >= parseDateTimeBestEffort(if(:BODY.FILTERS.OCCURREDFROM = '', '1970-01-01', :BODY.FILTERS.OCCURREDFROM))
  AND ts <= parseDateTimeBestEffort(if(:BODY.FILTERS.OCCURREDTO = '', '2999-12-31', :BODY.FILTERS.OCCURREDTO));
$Q$
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid = 'audit-clickhouse-cval'
   AND q.path_template = '/audit-tables/:SLUG/operations/stats';

DO $$
DECLARE
    v_ok BOOLEAN;
BEGIN
    SELECT bool_and(q.query ILIKE '%tabla_bare%' AND q.query ILIKE '%app_name%') INTO v_ok
      FROM public.query q
      JOIN public.microservice m ON m.id_microservice = q.microservice_id
     WHERE m.serviceid IN ('audit-clickhouse-pigse', 'audit-clickhouse-cval')
       AND q.path_template = '/audit-tables/:SLUG/operations/stats';

    IF NOT coalesce(v_ok, false) THEN
        RAISE EXCEPTION 'V382: alguna de las dos filas de operations/stats no se actualizo';
    END IF;

    RAISE NOTICE 'V382 OK: /audit-tables/:SLUG/operations/stats (pigse+cval) escopa por sesion_id -> app_name igual que V381.';
END $$;
