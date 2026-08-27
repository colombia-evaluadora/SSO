-- V90 -- /audits/* sobre sesiones REALES, no heurísticas de 30 min.
--
-- Reemplaza las cuatro queries de V86
-- (V86__seed_audits_sessions_catalog_queries.sql) que agrupaban filas
-- de audit_log por app_user con corte de inactividad de 30 min
-- (lagInFrame + suma acumulada). Ese heurístico era admisible como
-- placeholder mientras tsesion_web no tenía datos -- pero ahora
-- (V88) sí los tiene y V89 le agregó last_seen_at, así que las
-- sesiones reales son la fuente primaria.
--
-- Cambios respecto a V86:
--   * Fuente: JOIN auditoria.tsesion_web (mirror ClickHouse vía CDC,
--     ver init.sql) con auditoria.audit_log, NO heurístico.
--   * sessionId deja de ser '{app_user}-{sesion_seq}' sintético y
--     pasa a ser el family_id real (UUID string, mismo que
--     RefreshTokenStore.mint()).
--   * ended_at se COMPUTA en lectura (ended_at_computed), nunca se
--     persiste como cierre silencioso. logout/reuse_detected sí
--     tienen ended_at real en close_reason='logout'/'reuse_detected'.
--   * status: 'active' cuando ended_at_computed IS NULL (sigue
--     activa), 'closed' en otro caso. Mismo vocabulario que V86.
--
-- INTERVAL ''30 min'' (sintaxis Postgres) NO es válido en ClickHouse
-- -- exige INTERVAL <número> <unidad> sin comillas (p.ej. INTERVAL 30
-- MINUTE), no un literal de texto. Falla con "Syntax error... Expected
-- ... THEN" porque el parser espera la palabra clave THEN justo
-- después del operando de la comparación y encuentra el string en su
-- lugar. Se usa dateDiff(''minute'', last_seen_at, now()) > 30 en su
-- lugar -- mismo patrón que ya se usó para el heurístico sintético de
-- V86 (now() - max(ts) tampoco funciona directo entre DateTime y
-- DateTime64, otro motivo más para dateDiff sobre aritmética directa
-- de intervalos). Encontrado ejecutando contra ClickHouse real.
--
-- 2.2 -- POST /audits/query: listar sesiones reales con filtros.
-- Reemplaza la fila de V86 con path_template='/audits/query'.
-- El UPSERT no se usa porque V86 ya insertó esa fila; ON CONFLICT
-- (microservice_id, path_template, http_method) WHERE path_template
-- IS NOT NULL DO UPDATE reemplaza el query en vez de fallar por
-- duplicado. Misma estrategia para 2.3/2.4/2.5.
--
-- argMax por lsn: la tabla usa ReplacingMergeTree(lsn) con ORDER BY
-- (family_id), pero hasta la compactación coexisten varias versiones
-- de la misma fila. argMax(ended_at, lsn) garantiza que cada
-- familia aparece UNA vez con su estado más reciente -- sin
-- necesitar FINAL (que haría full scan y rompería el bloom filter
-- index sobre family_id).
UPDATE public.query
   SET query = 'WITH latest AS (
    SELECT family_id,
           argMax(started_at, lsn) AS started_at,
           argMax(ended_at, lsn) AS ended_at,
           argMax(close_reason, lsn) AS close_reason,
           argMax(last_seen_at, lsn) AS last_seen_at
      FROM auditoria.tsesion_web
     GROUP BY family_id
),
abiertas AS (
    SELECT family_id,
           started_at,
           ended_at,
           close_reason,
           last_seen_at,
           CASE
               WHEN close_reason != '''' THEN ended_at
               WHEN dateDiff(''minute'', last_seen_at, now()) > 30 THEN last_seen_at
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
           CASE WHEN ended_at_computed IS NULL THEN ''active'' ELSE ''closed'' END AS status
      FROM abiertas
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
HAVING (coalesce(:BODY.FILTERS.AUTHOR, '''') = ''''
        OR positionCaseInsensitive(any(audit.app_user), :BODY.FILTERS.AUTHOR) > 0)
   AND (coalesce(:BODY.FILTERS.STATUS, '''') = ''''
        OR status = :BODY.FILTERS.STATUS)
   AND started_at >= parseDateTimeBestEffort(if(:BODY.FILTERS.STARTEDFROM = '''', ''1970-01-01'', :BODY.FILTERS.STARTEDFROM))
   AND started_at <= parseDateTimeBestEffort(if(:BODY.FILTERS.STARTEDTO = '''', ''2999-12-31'', :BODY.FILTERS.STARTEDTO))
ORDER BY started_at DESC
LIMIT 100;',
    detail = 'V90 — audits/query: sesiones REALES desde tsesion_web mirror. '
             'ended_at es COMPUTADO (close_reason conocido vs last_seen_at > 30min). '
             'sessionId = family_id real. argMax sobre lsn para deduplicar '
             'versiones de ReplacingMergeTree.'
  WHERE path_template = '/audits/query'
    AND microservice_id = (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse');

-- 2.3 -- GET /audits/sessions/{sessionId}: detalle de UNA sesión real.
-- argMax(ended_at, lsn) etc.: misma dedupe que 2.2 (ver comentario
-- arriba).
UPDATE public.query
   SET query = 'WITH latest AS (
    SELECT family_id AS id,
           argMax(started_at, lsn) AS started_at,
           argMax(ended_at, lsn) AS ended_at,
           argMax(close_reason, lsn) AS close_reason,
           argMax(last_seen_at, lsn) AS last_seen_at
      FROM auditoria.tsesion_web
     WHERE family_id = :PARAM.SESSIONID
     GROUP BY family_id
)
SELECT
    l.id AS id,
    any(audit.app_user) AS authorName,
    NULL AS authorAvatarUrl,
    false AS authorVerified,
    any(audit.client_ip) AS ip,
    l.started_at AS startedAt,
    CASE
        WHEN l.close_reason != '''' THEN l.ended_at
        WHEN dateDiff(''minute'', l.last_seen_at, now()) > 30 THEN l.last_seen_at
        ELSE NULL
    END AS endedAt,
    CASE
        WHEN l.close_reason != '''' THEN ''closed''
        WHEN dateDiff(''minute'', l.last_seen_at, now()) > 30 THEN ''closed''
        ELSE ''active''
    END AS status,
    count(audit.lsn) AS operationsCount
FROM latest l
LEFT JOIN auditoria.audit_log audit
  ON audit.sesion_id = l.id
GROUP BY l.id, l.started_at, l.ended_at, l.close_reason, l.last_seen_at;',
    detail = 'V90 — audits/sessions/{sessionId}: detalle de una sesión REAL '
             '(family_id). ended_at y status computados en lectura. '
             'argMax sobre lsn para deduplicar.'
  WHERE path_template = '/audits/sessions/:SESSIONID'
    AND microservice_id = (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse');

-- 2.4 -- POST /audits/sessions/{sessionId}/operations: ops de UNA sesión.
UPDATE public.query
   SET query = 'SELECT
    concat(toString(lsn), ''-'', toString(seq)) AS id,
    tabla AS tableSlug,
    CASE operacion WHEN ''c'' THEN ''INSERT'' WHEN ''u'' THEN ''UPDATE'' WHEN ''d'' THEN ''DELETE'' ELSE ''SNAPSHOT'' END AS operation,
    etiqueta AS entityName,
    pk AS entityId,
    ts AS occurredAt,
    count() OVER() AS totalCount
FROM auditoria.audit_log
WHERE sesion_id = :PARAM.SESSIONID
  AND operacion != ''r''
  AND (coalesce(:BODY.FILTERS.TABLESLUG, '''') = '''' OR tabla = :BODY.FILTERS.TABLESLUG)
  AND (coalesce(:BODY.FILTERS.OPERATIONCH, '''') = '''' OR operacion = :BODY.FILTERS.OPERATIONCH)
  AND ts >= parseDateTimeBestEffort(if(:BODY.FILTERS.OCCURREDFROM = '''', ''1970-01-01'', :BODY.FILTERS.OCCURREDFROM))
  AND ts <= parseDateTimeBestEffort(if(:BODY.FILTERS.OCCURREDTO = '''', ''2999-12-31'', :BODY.FILTERS.OCCURREDTO))
ORDER BY ts DESC
LIMIT 100;',
    detail = 'V90 — audits/sessions/{sessionId}/operations: operaciones de una '
             'sesión REAL, filtradas por sesion_id = family_id.'
  WHERE path_template = '/audits/sessions/:SESSIONID/operations'
    AND microservice_id = (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse');

-- 2.5 -- POST /audits/stats: agregados sobre sesiones reales.
-- Misma dedupe argMax(..., lsn) que 2.2/2.3.
UPDATE public.query
   SET query = 'WITH latest AS (
    SELECT family_id,
           argMax(started_at, lsn) AS started_at,
           argMax(ended_at, lsn) AS ended_at,
           argMax(close_reason, lsn) AS close_reason,
           argMax(last_seen_at, lsn) AS last_seen_at
      FROM auditoria.tsesion_web
     GROUP BY family_id
)
SELECT
    countIf(toDate(started_at) = today()) AS sessionsToday,
    countIf(CASE
        WHEN close_reason != '''' THEN ended_at
        WHEN dateDiff(''minute'', last_seen_at, now()) > 30 THEN last_seen_at
        ELSE NULL
    END IS NULL) AS activeSessions,
    countIf(toDate(started_at) = today()) AS operationsToday
FROM latest;',
    detail = 'V90 — audits/stats: agregados sobre sesiones REALES '
             '(tsesion_web mirror). activeSessions = ended_at_computed IS NULL. '
             'argMax sobre lsn para deduplicar.'
  WHERE path_template = '/audits/stats'
    AND microservice_id = (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse');
