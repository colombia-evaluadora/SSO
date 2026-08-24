-- =============================================================================
-- V135 — reactiva las definiciones ORIGINALES de V85/V90 (client_ip,
-- fila_new_raw/fila_old_raw, tsesion_web mirror) que V131-V134 habían
-- reemplazado por versiones degradadas, ahora que la causa real ya está
-- resuelta: el ClickHouse del servidor tenía el esquema desincronizado con
-- docker/clickhouse/clickhouse-init.sql (columnas de contexto HTTP y la
-- tabla auditoria.tsesion_web nunca se crearon porque el volumen del
-- contenedor nunca se reinicializó desde PR #75). Ya se aplicaron los
-- ALTER TABLE/CREATE TABLE necesarios contra el servidor -- ver sesión de
-- hoy -- así que las queries originales vuelven a ser válidas.
--
-- Qué revierte cada bloque, y por qué SÍ (no todo V131-V134 se revierte):
--
--   * V131 (param_types VARCHAR -> Nullable(String)) NO SE TOCA. Es un
--     fix real y ortogonal: evita que el rewriter de Postgres le inyecte
--     CAST(:X AS varchar) a binds de ClickHouse (CANNOT_CONVERT_TYPE al
--     castear NULL a un tipo no-nullable). No tiene relación con las
--     columnas de contexto ni con tsesion_web -- sigue vigente.
--
--   * V132 (id_query con path_template='/audit-tables/:SLUG/operations/query',
--     microservicio audit-clickhouse) quitó `client_ip`/`fila_new_raw`
--     porque esas columnas no existían. Se restaura el SELECT original de
--     V85 §1.3 (toString(client_ip) AS ip, fila_new_raw AS entityFieldsRaw,
--     y el OR de autor sobre client_ip).
--
--   * V133 (path_template IN ('/audits/query', '/audits/sessions/:SESSIONID',
--     '/audits/stats')) reemplazó el JOIN contra auditoria.tsesion_web por
--     una lectura heurística de audit_log.fila_new.* porque la tabla no
--     existía. Se restaura el SELECT original de V90 §2.2/2.3/2.5 (JOIN
--     directo a auditoria.tsesion_web, con client_ip real en vez de NULL).
--
--   * V134 (path_template='/audit-tables/:SLUG/operations/:OPERATIONID/changes')
--     quitó `fila_old_raw`/`fila_new_raw`. Se restaura el SELECT original
--     de V85 §1.4.
--
-- Fix adicional, agregado en el mismo movimiento (no estaba en V85/V90
-- originales, y sin él estas mismas filas siguen dando 500 apenas se
-- reactivan): el guard `if(:FILTRO = '', default, :FILTRO)` que V85/V90 ya
-- documentaban contra el no-short-circuit de ClickHouse solo cubre el caso
-- filtro=''. Cuando el cliente OMITE la clave del filtro en el body,
-- query-service bindea NULL, y `NULL = ''` en ClickHouse es NULL (no
-- TRUE) -- el if() cae al ELSE, que es el mismo NULL, y
-- parseDateTimeBestEffort(NULL) revienta con CANNOT_PARSE_DATETIME
-- (reproducido hoy contra el servidor de pruebas en los 4 endpoints que
-- tienen filtro de fecha: operations/query, operations/stats, audits/query,
-- audits/sessions/{id}/operations). Se envuelve cada comparación en
-- `coalesce(:FILTRO, '') = ''` -- NULL-safe y produce el mismo resultado
-- que antes para el caso filtro=''.
--
-- Nota operativa: auditoria.tsesion_web está vacía hasta que
-- ClickHouseSessionMirrorStage (cdc-worker) reciba el primer cambio real
-- sobre academico_test.tsesion_web -- el componente ya existe en el código
-- vendorizado (SSO/cdc-sync), no requiere ningún cambio de aplicación.
--
-- Idempotente: UPDATE ... SET query = <texto fijo>, mismo patrón que
-- V132/V133/V134.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- /audit-tables/{slug}/operations/query — V85 §1.3 original + coalesce fix
-- ---------------------------------------------------------------------------
UPDATE public.query
   SET query = $sql$SELECT
    concat(toString(lsn), '-', toString(seq)) AS id,
    CASE operacion WHEN 'c' THEN 'INSERT' WHEN 'u' THEN 'UPDATE' WHEN 'd' THEN 'DELETE' ELSE 'SNAPSHOT' END AS operation,
    app_user AS authorName,
    NULL AS authorAvatarUrl,
    false AS authorVerified,
    toString(client_ip) AS ip,
    etiqueta AS entityName,
    pk AS entityId,
    ts AS occurredAt,
    fila_new_raw AS entityFieldsRaw,
    count() OVER() AS totalCount
FROM auditoria.audit_log
-- Fórmula inversa slug -> tabla (ver V85 §1.3): inserta '_' antes de cada
-- mayúscula del slug (sin contar la primera), minúscula, y antepone 't'.
WHERE tabla = concat('t', substring(lower(replaceRegexpAll(substring(:PARAM.SLUG, 2), '([A-Z])', '_\1')), 2))
  AND operacion != 'r'
  AND (coalesce(:BODY.FILTERS.AUTHOR, '') = '' OR positionCaseInsensitive(app_user, :BODY.FILTERS.AUTHOR) > 0
                                   OR positionCaseInsensitive(toString(client_ip), :BODY.FILTERS.AUTHOR) > 0)
  AND (coalesce(:BODY.FILTERS.OPERATIONCH, '') = '' OR operacion = :BODY.FILTERS.OPERATIONCH)
  -- V125/V135: coalesce(:X, '') en vez de :X -- NULL-safe cuando el
  -- cliente omite la clave del filtro (bind NULL, no '').
  AND ts >= parseDateTimeBestEffort(if(coalesce(:BODY.FILTERS.OCCURREDFROM, '') = '', '1970-01-01', :BODY.FILTERS.OCCURREDFROM))
  AND ts <= parseDateTimeBestEffort(if(coalesce(:BODY.FILTERS.OCCURREDTO, '') = '', '2999-12-31', :BODY.FILTERS.OCCURREDTO))
ORDER BY ts DESC
LIMIT 100;$sql$
  WHERE path_template = '/audit-tables/:SLUG/operations/query'
    AND microservice_id = (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse');

-- ---------------------------------------------------------------------------
-- /audit-tables/{slug}/operations/stats — V85 §1.6 original + coalesce fix
-- (V131-V134 nunca tocaron esta fila; el bug de NULL seguía sin arreglar)
-- ---------------------------------------------------------------------------
UPDATE public.query
   SET query = $sql$SELECT
    countIf(operacion = 'c') AS inserts,
    countIf(operacion = 'u') AS updates,
    countIf(operacion = 'd') AS deletes
FROM auditoria.audit_log
-- Fórmula inversa slug -> tabla — ver V85 §1.3/§1.6.
WHERE tabla = concat('t', substring(lower(replaceRegexpAll(substring(:PARAM.SLUG, 2), '([A-Z])', '_\1')), 2))
  AND operacion != 'r'
  AND ts >= parseDateTimeBestEffort(if(coalesce(:BODY.FILTERS.OCCURREDFROM, '') = '', '1970-01-01', :BODY.FILTERS.OCCURREDFROM))
  AND ts <= parseDateTimeBestEffort(if(coalesce(:BODY.FILTERS.OCCURREDTO, '') = '', '2999-12-31', :BODY.FILTERS.OCCURREDTO));$sql$
  WHERE path_template = '/audit-tables/:SLUG/operations/stats'
    AND microservice_id = (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse');

-- ---------------------------------------------------------------------------
-- /audit-tables/{slug}/operations/{operationId}/changes — V85 §1.4 original
-- (sin filtro de fecha, no necesita el fix de coalesce)
-- ---------------------------------------------------------------------------
UPDATE public.query
   SET query = $sql$WITH op AS (
    SELECT tabla, pk, operacion, etiqueta, fila_old_raw, fila_new_raw
    FROM auditoria.audit_log
    WHERE lsn = toUInt64(splitByChar('-', :PARAM.OPERATIONID)[1])
      AND seq = toUInt32(splitByChar('-', :PARAM.OPERATIONID)[2])
    ORDER BY ts DESC
    LIMIT 1
)
SELECT
    :PARAM.OPERATIONID AS operationId,
    CASE (SELECT operacion FROM op) WHEN 'c' THEN 'INSERT' WHEN 'u' THEN 'UPDATE' WHEN 'd' THEN 'DELETE' ELSE 'SNAPSHOT' END AS operation,
    (SELECT etiqueta FROM op) AS entityName,
    (SELECT pk FROM op) AS entityId,
    (SELECT fila_old_raw FROM op) AS beforeRaw,
    (SELECT fila_new_raw FROM op) AS afterRaw,
    (SELECT argMax(fila_new_raw, ts) FROM auditoria.audit_log
      WHERE tabla = (SELECT tabla FROM op) AND pk = (SELECT pk FROM op) AND operacion != 'r') AS currentRaw;$sql$
  WHERE path_template = '/audit-tables/:SLUG/operations/:OPERATIONID/changes'
    AND microservice_id = (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse');

-- ---------------------------------------------------------------------------
-- /audits/query — V90 §2.2 original (JOIN tsesion_web) + coalesce fix
-- ---------------------------------------------------------------------------
UPDATE public.query
   SET query = $sql$WITH latest AS (
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
ORDER BY started_at DESC
LIMIT 100;$sql$
  WHERE path_template = '/audits/query'
    AND microservice_id = (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse');

-- ---------------------------------------------------------------------------
-- /audits/sessions/{sessionId} — V90 §2.3 original (JOIN tsesion_web)
-- (sin filtro de fecha, no necesita el fix de coalesce)
-- ---------------------------------------------------------------------------
UPDATE public.query
   SET query = $sql$WITH latest AS (
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
        WHEN l.close_reason != '' THEN l.ended_at
        WHEN dateDiff('minute', l.last_seen_at, now()) > 30 THEN l.last_seen_at
        ELSE NULL
    END AS endedAt,
    CASE
        WHEN l.close_reason != '' THEN 'closed'
        WHEN dateDiff('minute', l.last_seen_at, now()) > 30 THEN 'closed'
        ELSE 'active'
    END AS status,
    count(audit.lsn) AS operationsCount
FROM latest l
LEFT JOIN auditoria.audit_log audit
  ON audit.sesion_id = l.id
GROUP BY l.id, l.started_at, l.ended_at, l.close_reason, l.last_seen_at;$sql$
  WHERE path_template = '/audits/sessions/:SESSIONID'
    AND microservice_id = (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse');

-- ---------------------------------------------------------------------------
-- /audits/sessions/{sessionId}/operations — V90 §2.4 original + coalesce fix
-- (V131-V134 nunca tocaron esta fila -- no lee tsesion_web, pero seguía con
-- el bug de NULL sin arreglar)
-- ---------------------------------------------------------------------------
UPDATE public.query
   SET query = $sql$SELECT
    concat(toString(lsn), '-', toString(seq)) AS id,
    tabla AS tableSlug,
    CASE operacion WHEN 'c' THEN 'INSERT' WHEN 'u' THEN 'UPDATE' WHEN 'd' THEN 'DELETE' ELSE 'SNAPSHOT' END AS operation,
    etiqueta AS entityName,
    pk AS entityId,
    ts AS occurredAt,
    count() OVER() AS totalCount
FROM auditoria.audit_log
WHERE sesion_id = :PARAM.SESSIONID
  AND operacion != 'r'
  AND (coalesce(:BODY.FILTERS.TABLESLUG, '') = '' OR tabla = :BODY.FILTERS.TABLESLUG)
  AND (coalesce(:BODY.FILTERS.OPERATIONCH, '') = '' OR operacion = :BODY.FILTERS.OPERATIONCH)
  AND ts >= parseDateTimeBestEffort(if(coalesce(:BODY.FILTERS.OCCURREDFROM, '') = '', '1970-01-01', :BODY.FILTERS.OCCURREDFROM))
  AND ts <= parseDateTimeBestEffort(if(coalesce(:BODY.FILTERS.OCCURREDTO, '') = '', '2999-12-31', :BODY.FILTERS.OCCURREDTO))
ORDER BY ts DESC
LIMIT 100;$sql$
  WHERE path_template = '/audits/sessions/:SESSIONID/operations'
    AND microservice_id = (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse');

-- ---------------------------------------------------------------------------
-- /audits/stats — V90 §2.5 original (JOIN tsesion_web)
-- (sin filtro de fecha del cliente, no necesita el fix de coalesce)
-- ---------------------------------------------------------------------------
UPDATE public.query
   SET query = $sql$WITH latest AS (
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
        WHEN close_reason != '' THEN ended_at
        WHEN dateDiff('minute', last_seen_at, now()) > 30 THEN last_seen_at
        ELSE NULL
    END IS NULL) AS activeSessions,
    countIf(toDate(started_at) = today()) AS operationsToday
FROM latest;$sql$
  WHERE path_template = '/audits/stats'
    AND microservice_id = (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse');
