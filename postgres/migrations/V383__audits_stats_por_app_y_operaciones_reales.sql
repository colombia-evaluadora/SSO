-- ============================================================================
-- V383 — dos bugs reales en las tarjetas de la pantalla de Sesiones
-- ("X Sesiones, Y Sesiones activas, Z Operaciones"), fuente:
-- /audits/stats (fila de catálogo, una por app):
--
-- 1. Sin scoping por app_name -- igual que /audits/query antes de V377,
--    esta fila lee `auditoria.tsesion_web` COMPLETA, mezclando sesiones
--    de PIGSE y CEVAL en el mismo conteo. "Sesiones"/"Sesiones activas"
--    de PIGSE incluían sesiones de CEVAL y viceversa.
--
-- 2. `operationsToday` estaba copiado y pegado de `sessionsToday`
--    (`countIf(toDate(started_at) = today())`, exactamente la misma
--    expresión) -- la tarjeta "Operaciones" en realidad mostraba el
--    número de SESIONES iniciadas hoy, no de operaciones. Coincidencia
--    que nadie notó antes porque en un ambiente de test con poco tráfico
--    ambos números casualmente calzaban.
--
-- Fix: igual que V377/V381, se resuelve la app vía `app_name` (mirror de
-- sesiones) y `operationsToday` ahora es un conteo real contra
-- `auditoria.audit_log` (incluye tsesion_web -- se cuenta TODO lo que
-- pasó hoy en esa app, login/logout incluido, igual que ya se decidió
-- mostrar "Inicio de sesión" en el detalle de una sesión, V380).
-- ============================================================================

UPDATE public.query q
   SET query = $Q$WITH latest AS (
    SELECT family_id,
           argMax(started_at, lsn) AS started_at,
           argMax(ended_at, lsn) AS ended_at,
           argMax(close_reason, lsn) AS close_reason,
           argMax(last_seen_at, lsn) AS last_seen_at,
           argMax(app_name, lsn) AS app_name
      FROM auditoria.tsesion_web
     GROUP BY family_id
),
mias AS (
    SELECT * FROM latest WHERE app_name = 'PIGSE'
)
SELECT
    countIf(toDate(started_at) = today()) AS sessionsToday,
    countIf(CASE
        WHEN close_reason != '' THEN ended_at
        WHEN dateDiff('minute', last_seen_at, now()) > 30 THEN last_seen_at
        ELSE NULL
    END IS NULL) AS activeSessions,
    (SELECT count() FROM auditoria.audit_log
      WHERE toDate(ts) = today()
        AND sesion_id IN (SELECT family_id FROM mias)) AS operationsToday
FROM mias;
$Q$
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid = 'audit-clickhouse-pigse'
   AND q.path_template = '/audits/stats';

UPDATE public.query q
   SET query = $Q$WITH latest AS (
    SELECT family_id,
           argMax(started_at, lsn) AS started_at,
           argMax(ended_at, lsn) AS ended_at,
           argMax(close_reason, lsn) AS close_reason,
           argMax(last_seen_at, lsn) AS last_seen_at,
           argMax(app_name, lsn) AS app_name
      FROM auditoria.tsesion_web
     GROUP BY family_id
),
mias AS (
    SELECT * FROM latest WHERE app_name = 'COLOMBIA-EVALUADORA'
)
SELECT
    countIf(toDate(started_at) = today()) AS sessionsToday,
    countIf(CASE
        WHEN close_reason != '' THEN ended_at
        WHEN dateDiff('minute', last_seen_at, now()) > 30 THEN last_seen_at
        ELSE NULL
    END IS NULL) AS activeSessions,
    (SELECT count() FROM auditoria.audit_log
      WHERE toDate(ts) = today()
        AND sesion_id IN (SELECT family_id FROM mias)) AS operationsToday
FROM mias;
$Q$
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid = 'audit-clickhouse-cval'
   AND q.path_template = '/audits/stats';

DO $$
DECLARE
    v_ok BOOLEAN;
BEGIN
    SELECT bool_and(q.query ILIKE '%app_name%' AND q.query ILIKE '%audit_log%') INTO v_ok
      FROM public.query q
      JOIN public.microservice m ON m.id_microservice = q.microservice_id
     WHERE m.serviceid IN ('audit-clickhouse-pigse', 'audit-clickhouse-cval')
       AND q.path_template = '/audits/stats';

    IF NOT coalesce(v_ok, false) THEN
        RAISE EXCEPTION 'V383: alguna de las dos filas de /audits/stats no se actualizo';
    END IF;

    RAISE NOTICE 'V383 OK: /audits/stats (pigse+cval) escopa por app_name y operationsToday cuenta operaciones reales.';
END $$;
