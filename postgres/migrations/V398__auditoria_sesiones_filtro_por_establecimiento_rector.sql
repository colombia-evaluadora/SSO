-- ============================================================================
-- V398 — cierra el hueco que V362 dejó explícitamente fuera de alcance:
-- CEVAL-RECTOR ya veía SOLO su establecimiento en "por tabla"
-- (/audit-tables/:SLUG/operations/query) y en el detalle de una sesión
-- puntual (/audits/sessions/:SESSIONID/operations) -- pero la LISTA de
-- sesiones y sus tarjetas de stats (/audits/query, /audits/stats,
-- "Sesiones de auditoría") seguían mostrando TODA la actividad de
-- Colombia Evaluadora a cualquier rector, porque leen
-- auditoria.tsesion_web, que no tiene noción de establecimiento (V362
-- lo documentó como fuera de alcance en su punto 6).
--
-- FIX: mismo patrón que V362 (comparar contra
-- JSONExtractString(contexto, 'establecimiento'), el dato que
-- academico_test.fn_audit_declarar ya venía grabando desde V66) pero
-- vía un JOIN a auditoria.audit_log por sesion_id -- una sesión es "del
-- establecimiento del rector" si AL MENOS UNA de sus operaciones (de
-- cualquier actor: docente, secretaría, el propio rector) quedó
-- etiquetada con ese establecimiento. Mismo límite ya aceptado por
-- V362: sesiones sin ninguna operación con contexto.establecimiento
-- (código legado, o rutas que aún no llaman fn_audit_declarar) no le
-- aparecen a ningún rector -- solo al super-admin.
--
-- El filtro se aplica como un AND de nivel superior sobre TODO el
-- HAVING existente (no solo la rama sin :BODY.IDS): un rector no debe
-- poder ver una sesión ajena aunque la pida por id explícito vía
-- :BODY.IDS (la tarjeta de "operaciones" del detalle de sesión también
-- pasa por acá).
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
abiertas AS (
    SELECT family_id,
           started_at,
           ended_at,
           close_reason,
           last_seen_at,
           app_name,
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
GROUP BY s.family_id, s.started_at, s.ended_at, s.close_reason, s.last_seen_at, s.status
HAVING (coalesce(:BODY.FILTERS.AUTHOR, '') = ''
        OR positionCaseInsensitive(any(audit.app_user), :BODY.FILTERS.AUTHOR) > 0)
   AND (coalesce(:BODY.FILTERS.STATUS, '') = ''
        OR status = :BODY.FILTERS.STATUS)
   AND started_at >= parseDateTimeBestEffort(if(coalesce(:BODY.FILTERS.STARTEDFROM, '') = '', '1970-01-01', :BODY.FILTERS.STARTEDFROM))
   AND started_at <= parseDateTimeBestEffort(if(coalesce(:BODY.FILTERS.STARTEDTO, '') = '', '2999-12-31', :BODY.FILTERS.STARTEDTO))
   AND (
       position(concat(',', :CONTEXT.ROLES, ','), ',CEVAL-SUPER_ADMINISTRADOR,') > 0
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
    v_query_ok BOOLEAN;
    v_stats_ok BOOLEAN;
BEGIN
    SELECT (q.query ILIKE '%CONTEXT.ESTABLISHMENT%' AND q.query ILIKE '%CEVAL-SUPER_ADMINISTRADOR%') INTO v_query_ok
      FROM public.query q JOIN public.microservice m ON m.id_microservice = q.microservice_id
     WHERE m.serviceid = 'audit-clickhouse-cval' AND q.path_template = '/audits/query';

    SELECT (q.query ILIKE '%CONTEXT.ESTABLISHMENT%' AND q.query ILIKE '%CEVAL-SUPER_ADMINISTRADOR%') INTO v_stats_ok
      FROM public.query q JOIN public.microservice m ON m.id_microservice = q.microservice_id
     WHERE m.serviceid = 'audit-clickhouse-cval' AND q.path_template = '/audits/stats';

    IF NOT coalesce(v_query_ok, false) THEN
        RAISE EXCEPTION 'V398: /audits/query no quedo con el filtro de establecimiento';
    END IF;
    IF NOT coalesce(v_stats_ok, false) THEN
        RAISE EXCEPTION 'V398: /audits/stats no quedo con el filtro de establecimiento';
    END IF;

    RAISE NOTICE 'V398 OK: /audits/query y /audits/stats (CEVAL) escopan por establecimiento para CEVAL-RECTOR, igual que las 4 queries de V362.';
END $$;
