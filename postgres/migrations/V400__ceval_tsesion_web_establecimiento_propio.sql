-- ============================================================================
-- V400 — cierra el ultimo hueco real del filtro de auditoria por
-- establecimiento (V362/V398/V399): un CEVAL-RECTOR recien logueado NO
-- veia ni su PROPIA sesion en "Sesiones de auditoria" hasta que esa
-- sesion tuviera al menos una operacion de ESCRITURA ya etiquetada con
-- su establecimiento (v_398/399 solo miraban auditoria.audit_log via
-- JOIN por sesion_id). Un login puro, sin ninguna accion todavia, no
-- generaba ninguna fila en audit_log -- asi que ni el propio rector se
-- veia a si mismo, y mucho menos a sus docentes/secretaria si tampoco
-- habian hecho nada aun.
--
-- CAUSA RAIZ: academico_test.tsesion_web (la fuente de "sesiones", no
-- de "operaciones") nunca guardaba el establecimiento del actor -- solo
-- app_name (V377). El establecimiento SI se resuelve en cada login
-- (EstablishmentResolver, para el claim `est` del JWT) pero ese valor
-- nunca se persistia en la fila de sesion.
--
-- FIX: se agrega la columna `establecimiento` a tsesion_web (mismo
-- patron que V377 con app_name), poblada por
-- SessionTrackingService.openSession con el MISMO valor ya resuelto
-- para el JWT (auth-center, contraparte de esta migracion, mismo
-- commit). El mirror de ClickHouse (cdc-worker
-- ClickHouseSessionMirrorStage) y la tabla destino
-- (docker/clickhouse/migrations/) se actualizan igual, tambien en el
-- mismo commit.
--
-- /audits/query y /audits/stats (CEVAL) pasan a filtrar por
-- `s.establecimiento = :CONTEXT.ESTABLISHMENT` (la sesion misma sabe de
-- quien es) ADEMAS del chequeo por audit_log que V398 ya tenia (se
-- conserva por compatibilidad con sesiones de docentes/secretaria de
-- otros logins, o de antes de este fix, que si tienen actividad
-- etiquetada pero no este campo nuevo en su propia fila de sesion).
-- ============================================================================

ALTER TABLE academico_test.tsesion_web
    ADD COLUMN IF NOT EXISTS establecimiento VARCHAR(200);

COMMENT ON COLUMN academico_test.tsesion_web.establecimiento IS
    'V400: nombre del unico establecimiento que el actor de esta sesion administra como rector/secretaria (EstablishmentResolver, mismo valor que el claim est del JWT), resuelto en el momento del login. NULL para quien no aplica (super-admin, docente, etc.) o para sesiones anteriores a este fix.';

UPDATE public.query q
   SET query = $Q$WITH latest AS (
    SELECT family_id,
           argMax(started_at, lsn) AS started_at,
           argMax(ended_at, lsn) AS ended_at,
           argMax(close_reason, lsn) AS close_reason,
           argMax(last_seen_at, lsn) AS last_seen_at,
           argMax(app_name, lsn) AS app_name,
           argMax(establecimiento, lsn) AS establecimiento
      FROM auditoria.tsesion_web
     GROUP BY family_id
),
abiertas AS (
    SELECT family_id,
           started_at,
           ended_at,
           close_reason,
           last_seen_at,
           app_name,
           establecimiento,
           CASE
               WHEN close_reason != '' THEN ended_at
               WHEN dateDiff('minute', last_seen_at, now()) > 30 THEN last_seen_at
               ELSE NULL
           END AS ended_at_computed
      FROM latest
),
sesiones AS (
    SELECT family_id,
           started_at,
           ended_at_computed AS ended_at,
           close_reason,
           last_seen_at,
           establecimiento,
           CASE WHEN ended_at_computed IS NULL THEN 'active' ELSE 'closed' END AS status
      FROM abiertas
     WHERE app_name = 'COLOMBIA-EVALUADORA'
)
SELECT
    family_id AS id,
    any(audit.app_user) AS authorName,
    NULL AS authorAvatarUrl,
    false AS authorVerified,
    any(audit.client_ip) AS ip,
    started_at AS startedAt,
    ended_at AS endedAt,
    status,
    count(audit.lsn) AS operationsCount,
    count() OVER() AS totalCount
FROM sesiones s
LEFT JOIN auditoria.audit_log audit
  ON audit.sesion_id = s.family_id
GROUP BY s.family_id, s.started_at, s.ended_at, s.close_reason, s.last_seen_at, s.status, s.establecimiento
HAVING (coalesce(:BODY.FILTERS.AUTHOR, '') = ''
        OR positionCaseInsensitive(any(audit.app_user), :BODY.FILTERS.AUTHOR) > 0)
   AND (coalesce(:BODY.FILTERS.STATUS, '') = ''
        OR status = :BODY.FILTERS.STATUS)
   AND started_at >= parseDateTimeBestEffort(if(coalesce(:BODY.FILTERS.STARTEDFROM, '') = '', '1970-01-01', :BODY.FILTERS.STARTEDFROM))
   AND started_at <= parseDateTimeBestEffort(if(coalesce(:BODY.FILTERS.STARTEDTO, '') = '', '2999-12-31', :BODY.FILTERS.STARTEDTO))
   AND (
       position(concat(',', :CONTEXT.ROLES, ','), ',CEVAL-SUPER_ADMINISTRADOR,') > 0
       OR (:CONTEXT.ESTABLISHMENT != '' AND s.establecimiento = :CONTEXT.ESTABLISHMENT)
       OR (:CONTEXT.ESTABLISHMENT != '' AND countIf(JSONExtractString(audit.contexto, 'establecimiento') = :CONTEXT.ESTABLISHMENT) > 0)
   )
ORDER BY started_at DESC
LIMIT :BODY.PAGESIZE OFFSET :BODY.PAGEOFFSET;
$Q$
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid = 'audit-clickhouse-cval'
   AND q.path_template = '/audits/query';

UPDATE public.query q
   SET query = $Q$WITH latest AS (
    SELECT family_id,
           argMax(started_at, lsn) AS started_at,
           argMax(ended_at, lsn) AS ended_at,
           argMax(close_reason, lsn) AS close_reason,
           argMax(last_seen_at, lsn) AS last_seen_at,
           argMax(app_name, lsn) AS app_name,
           argMax(establecimiento, lsn) AS establecimiento
      FROM auditoria.tsesion_web
     GROUP BY family_id
),
abiertas AS (
    SELECT family_id, started_at, establecimiento,
           CASE
               WHEN close_reason != '' THEN ended_at
               WHEN dateDiff('minute', last_seen_at, now()) > 30 THEN last_seen_at
               ELSE NULL
           END AS ended_at_computed
      FROM latest
     WHERE app_name = 'COLOMBIA-EVALUADORA'
),
sesiones AS (
    SELECT family_id, started_at, establecimiento,
           CASE WHEN ended_at_computed IS NULL THEN 'active' ELSE 'closed' END AS status
      FROM abiertas
),
filtradas AS (
    SELECT s.family_id, s.started_at, s.status
      FROM sesiones s
      LEFT JOIN auditoria.audit_log audit ON audit.sesion_id = s.family_id
     GROUP BY s.family_id, s.started_at, s.status, s.establecimiento
    HAVING (
        (coalesce(:BODY.IDS, '') != '' AND has(splitByChar(',', :BODY.IDS), s.family_id))
        OR
        (coalesce(:BODY.IDS, '') = ''
         AND (coalesce(:BODY.FILTERS.AUTHOR, '') = '' OR positionCaseInsensitive(any(audit.app_user), :BODY.FILTERS.AUTHOR) > 0)
         AND (coalesce(:BODY.FILTERS.STATUS, '') = '' OR s.status = :BODY.FILTERS.STATUS)
         AND s.started_at >= parseDateTimeBestEffort(if(coalesce(:BODY.FILTERS.STARTEDFROM, '') = '', '1970-01-01', :BODY.FILTERS.STARTEDFROM))
         AND s.started_at <= parseDateTimeBestEffort(if(coalesce(:BODY.FILTERS.STARTEDTO, '') = '', '2999-12-31', :BODY.FILTERS.STARTEDTO))
        )
    ) AND (
        position(concat(',', :CONTEXT.ROLES, ','), ',CEVAL-SUPER_ADMINISTRADOR,') > 0
        OR (:CONTEXT.ESTABLISHMENT != '' AND s.establecimiento = :CONTEXT.ESTABLISHMENT)
        OR (:CONTEXT.ESTABLISHMENT != '' AND countIf(JSONExtractString(audit.contexto, 'establecimiento') = :CONTEXT.ESTABLISHMENT) > 0)
    )
)
SELECT
    count() AS sessionsToday,
    countIf(status = 'active') AS activeSessions,
    (SELECT count() FROM auditoria.audit_log WHERE sesion_id IN (SELECT family_id FROM filtradas)) AS operationsToday
FROM filtradas;
$Q$
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid = 'audit-clickhouse-cval'
   AND q.path_template = '/audits/stats';

DO $$
DECLARE
    v_col_ok BOOLEAN;
    v_query_ok BOOLEAN;
    v_stats_ok BOOLEAN;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema = 'academico_test' AND table_name = 'tsesion_web' AND column_name = 'establecimiento'
    ) INTO v_col_ok;

    SELECT (q.query ILIKE '%s.establecimiento = :CONTEXT.ESTABLISHMENT%') INTO v_query_ok
      FROM public.query q JOIN public.microservice m ON m.id_microservice = q.microservice_id
     WHERE m.serviceid = 'audit-clickhouse-cval' AND q.path_template = '/audits/query';

    SELECT (q.query ILIKE '%s.establecimiento = :CONTEXT.ESTABLISHMENT%') INTO v_stats_ok
      FROM public.query q JOIN public.microservice m ON m.id_microservice = q.microservice_id
     WHERE m.serviceid = 'audit-clickhouse-cval' AND q.path_template = '/audits/stats';

    IF NOT coalesce(v_col_ok, false) THEN
        RAISE EXCEPTION 'V400: academico_test.tsesion_web.establecimiento no se creo';
    END IF;
    IF NOT coalesce(v_query_ok, false) THEN
        RAISE EXCEPTION 'V400: /audits/query no quedo filtrando por establecimiento propio de la sesion';
    END IF;
    IF NOT coalesce(v_stats_ok, false) THEN
        RAISE EXCEPTION 'V400: /audits/stats no quedo filtrando por establecimiento propio de la sesion';
    END IF;

    RAISE NOTICE 'V400 OK: tsesion_web.establecimiento agregada, /audits/query y /audits/stats la usan. Requiere el deploy de auth-center (SessionTrackingService/JsonLoginFilter) y cdc-worker (ClickHouseSessionMirrorStage) del mismo commit -- sin eso la columna llega vacia y el filtro se degrada al chequeo por audit_log de V398.';
END $$;
