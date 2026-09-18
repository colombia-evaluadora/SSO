-- ============================================================================
-- V402 — /audit-tables/:SLUG/operations/stats (CEVAL) nunca recibio el
-- filtro por establecimiento que V362 SI le puso a su vecina
-- /audit-tables/:SLUG/operations/query (la lista paginada de la misma
-- pantalla "Por tablas" -> <tabla> -> Detalle). Resultado: el card de
-- stats (Insert/Update/Delete) contaba operaciones de TODAS las
-- instituciones para cualquier rector, mientras la lista de abajo (que
-- si tenia el filtro) solo mostraba las suyas -- reportado por el
-- usuario como "en operaciones y en la tabla me aparecen 7 pero en los
-- stats me aparecen 13".
--
-- Es una fuga real entre instituciones (un rector podia inferir volumen
-- de actividad de EEs ajenos via el conteo), no solo un numero
-- inconsistente. FIX: mismo condicional que ya tienen /operations/query,
-- /audits/query y /audits/stats (V362/V398).
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
  )
  AND (
      position(concat(',', :CONTEXT.ROLES, ','), ',CEVAL-SUPER_ADMINISTRADOR,') > 0
      OR (:CONTEXT.ESTABLISHMENT != '' AND JSONExtractString(contexto, 'establecimiento') = :CONTEXT.ESTABLISHMENT)
  );
$Q$
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid = 'audit-clickhouse-cval'
   AND q.path_template = '/audit-tables/:SLUG/operations/stats';

DO $$
DECLARE
    v_ok BOOLEAN;
BEGIN
    SELECT (q.query ILIKE '%JSONExtractString(contexto, ''establecimiento'')%') INTO v_ok
      FROM public.query q JOIN public.microservice m ON m.id_microservice = q.microservice_id
     WHERE m.serviceid = 'audit-clickhouse-cval' AND q.path_template = '/audit-tables/:SLUG/operations/stats';

    IF NOT coalesce(v_ok, false) THEN
        RAISE EXCEPTION 'V402: /audit-tables/:SLUG/operations/stats no quedo filtrando por establecimiento';
    END IF;

    RAISE NOTICE 'V402 OK: /audit-tables/:SLUG/operations/stats ahora filtra por establecimiento igual que /operations/query.';
END $$;
