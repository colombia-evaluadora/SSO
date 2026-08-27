-- =============================================================================
-- V133 — la pantalla de sesiones deja de leer una tabla que no existe.
--
-- SINTOMA
--   POST /api/audit-ch/audits/query  -> 500
--   POST /api/audit-ch/audits/stats  -> 500
--   GET  /api/audit-ch/audits/sessions/{id} -> 500
--
--     Code: 60. DB::Exception: Unknown table expression identifier
--     'auditoria.tsesion_web' in scope ...
--
-- CAUSA
--   Las tres filas leen `auditoria.tsesion_web` como si el sink de CDC crease
--   una tabla por tabla replicada. No lo hace: la base `auditoria` en
--   ClickHouse tiene exactamente DOS tablas —`app_log` y `audit_log`— y cada
--   cambio de cualquier tabla origen aterriza como una FILA de `audit_log`,
--   con el nombre de la tabla en la columna `tabla` y el snapshot de la fila
--   en `fila_new` (tipo JSON). `academico_test.tsesion_web` si esta en la
--   publicacion `cdc_pub`, pero eso la manda a `audit_log`, no a una tabla
--   propia.
--
--   Por eso el arreglo NO es replicar nada: es leer la sesion de donde el
--   sink la deja. Los nombres de columna coinciden con lo que el SQL ya
--   esperaba (family_id, started_at, ended_at, close_reason, last_seen_at),
--   asi que solo cambia el origen y el acceso pasa por `fila_new.<columna>`.
--
-- DECODIFICACION DE TIMESTAMPS
--   `fila_new` declara hints de tipo para un puñado de rutas (fecha, fecha_ts,
--   ...); las demas quedan como rutas dinamicas con la codificacion cruda de
--   Debezium, que difiere segun el tipo origen: `timestamptz` viaja como
--   cadena ISO-8601 y `timestamp` como microsegundos desde epoch. Las columnas
--   de tsesion_web son timestamptz, pero para no depender de esa suposicion el
--   decodificador acepta las dos formas:
--
--     multiIf(vacio -> NULL,
--             13..19 digitos -> toDateTime64(micros / 1000000, 3, 'UTC'),
--             parseDateTime64BestEffortOrNull(texto, 3, 'UTC'))
--
--   Verificado en el servidor contra las tres codificaciones mas el vacio; se
--   usa parseDateTime64* (y no parseDateTimeBestEffort*) porque la variante sin
--   64 colapsa el resultado a segundos y perdia los milisegundos.
--
-- IP DEL CLIENTE
--   `audit_log` no tiene columna de IP (mismo motivo que V132): `ip` sale NULL
--   y el front ya pinta "" cuando llega null.
--
-- LO QUE ESTA MIGRACION NO ARREGLA
--   Que hoy no haya sesiones que mostrar. El conector va por el snapshot
--   inicial —las 6.9M de filas replicadas son TODAS operacion='r', repartidas
--   en solo 3 tablas (tactividad_estudiante, tactividad_nota, tactividad)— y
--   todavia no ha llegado a tsesion_web. Con esta migracion los endpoints
--   responden 200 con lista vacia en vez de 500, y se pueblan solos cuando el
--   CDC alcance esa tabla. Si la pantalla tiene que mostrar datos YA, lo que
--   hay que revisar es el avance del snapshot del conector, no este SQL.
-- =============================================================================

-- --------------------------------------------------------------------------
-- /audits/query — listado de sesiones
-- --------------------------------------------------------------------------
UPDATE public.query
   SET query = $sql$WITH sesiones AS (
    SELECT
        toString(fila_new.family_id) AS family_id,
        argMax(multiIf(toString(fila_new.started_at) = '', NULL,
                       match(toString(fila_new.started_at), '^[0-9]{13,19}$'),
                           toDateTime64(toUInt64OrZero(toString(fila_new.started_at)) / 1000000, 3, 'UTC'),
                       parseDateTime64BestEffortOrNull(toString(fila_new.started_at), 3, 'UTC')), lsn) AS started_at,
        argMax(multiIf(toString(fila_new.ended_at) = '', NULL,
                       match(toString(fila_new.ended_at), '^[0-9]{13,19}$'),
                           toDateTime64(toUInt64OrZero(toString(fila_new.ended_at)) / 1000000, 3, 'UTC'),
                       parseDateTime64BestEffortOrNull(toString(fila_new.ended_at), 3, 'UTC')), lsn) AS ended_at,
        argMax(toString(fila_new.close_reason), lsn) AS close_reason,
        argMax(multiIf(toString(fila_new.last_seen_at) = '', NULL,
                       match(toString(fila_new.last_seen_at), '^[0-9]{13,19}$'),
                           toDateTime64(toUInt64OrZero(toString(fila_new.last_seen_at)) / 1000000, 3, 'UTC'),
                       parseDateTime64BestEffortOrNull(toString(fila_new.last_seen_at), 3, 'UTC')), lsn) AS last_seen_at
      FROM auditoria.audit_log
     WHERE tabla = 'tsesion_web'
     GROUP BY family_id
),
calculadas AS (
    -- Una sesion esta cerrada si el origen la cerro (close_reason) o si lleva
    -- mas de 30 minutos sin latido. Mismo criterio que tenia la fila anterior.
    SELECT
        family_id,
        started_at,
        close_reason,
        last_seen_at,
        CASE
            WHEN close_reason != '' THEN ended_at
            WHEN dateDiff('minute', last_seen_at, now()) > 30 THEN last_seen_at
            ELSE NULL
        END AS ended_at_computed
      FROM sesiones
)
SELECT
    s.family_id AS id,
    any(audit.app_user) AS authorName,
    NULL AS authorAvatarUrl,
    false AS authorVerified,
    NULL AS ip,
    s.started_at AS startedAt,
    s.ended_at_computed AS endedAt,
    if(s.ended_at_computed IS NULL, 'active', 'closed') AS status,
    count(audit.lsn) AS operationsCount,
    count() OVER() AS totalCount
FROM calculadas s
LEFT JOIN auditoria.audit_log audit
  ON audit.sesion_id = s.family_id
GROUP BY s.family_id, s.started_at, s.ended_at_computed
HAVING (coalesce(:BODY.FILTERS.AUTHOR, '') = ''
        OR positionCaseInsensitive(any(audit.app_user), :BODY.FILTERS.AUTHOR) > 0)
   AND (coalesce(:BODY.FILTERS.STATUS, '') = ''
        OR if(s.ended_at_computed IS NULL, 'active', 'closed') = :BODY.FILTERS.STATUS)
   -- ClickHouse no hace short-circuit del OR: al filtro de fecha se le pasa
   -- siempre un literal parseable, y el sentinela hace el rango un no-op.
   AND s.started_at >= parseDateTimeBestEffort(if(:BODY.FILTERS.STARTEDFROM = '', '1970-01-01', :BODY.FILTERS.STARTEDFROM))
   AND s.started_at <= parseDateTimeBestEffort(if(:BODY.FILTERS.STARTEDTO = '', '2999-12-31', :BODY.FILTERS.STARTEDTO))
ORDER BY s.started_at DESC
LIMIT 100;$sql$
 WHERE path_template = '/audits/query'
   AND http_method = 'POST';

-- --------------------------------------------------------------------------
-- /audits/sessions/{id} — detalle de una sesion
-- --------------------------------------------------------------------------
UPDATE public.query
   SET query = $sql$WITH sesiones AS (
    SELECT
        toString(fila_new.family_id) AS family_id,
        argMax(multiIf(toString(fila_new.started_at) = '', NULL,
                       match(toString(fila_new.started_at), '^[0-9]{13,19}$'),
                           toDateTime64(toUInt64OrZero(toString(fila_new.started_at)) / 1000000, 3, 'UTC'),
                       parseDateTime64BestEffortOrNull(toString(fila_new.started_at), 3, 'UTC')), lsn) AS started_at,
        argMax(multiIf(toString(fila_new.ended_at) = '', NULL,
                       match(toString(fila_new.ended_at), '^[0-9]{13,19}$'),
                           toDateTime64(toUInt64OrZero(toString(fila_new.ended_at)) / 1000000, 3, 'UTC'),
                       parseDateTime64BestEffortOrNull(toString(fila_new.ended_at), 3, 'UTC')), lsn) AS ended_at,
        argMax(toString(fila_new.close_reason), lsn) AS close_reason,
        argMax(multiIf(toString(fila_new.last_seen_at) = '', NULL,
                       match(toString(fila_new.last_seen_at), '^[0-9]{13,19}$'),
                           toDateTime64(toUInt64OrZero(toString(fila_new.last_seen_at)) / 1000000, 3, 'UTC'),
                       parseDateTime64BestEffortOrNull(toString(fila_new.last_seen_at), 3, 'UTC')), lsn) AS last_seen_at
      FROM auditoria.audit_log
     WHERE tabla = 'tsesion_web'
       AND toString(fila_new.family_id) = :PARAM.SESSIONID
     GROUP BY family_id
),
calculadas AS (
    SELECT
        family_id,
        started_at,
        close_reason,
        last_seen_at,
        CASE
            WHEN close_reason != '' THEN ended_at
            WHEN dateDiff('minute', last_seen_at, now()) > 30 THEN last_seen_at
            ELSE NULL
        END AS ended_at_computed
      FROM sesiones
)
SELECT
    s.family_id AS id,
    any(audit.app_user) AS authorName,
    NULL AS authorAvatarUrl,
    false AS authorVerified,
    NULL AS ip,
    s.started_at AS startedAt,
    s.ended_at_computed AS endedAt,
    if(s.ended_at_computed IS NULL, 'active', 'closed') AS status,
    count(audit.lsn) AS operationsCount
FROM calculadas s
LEFT JOIN auditoria.audit_log audit
  ON audit.sesion_id = s.family_id
GROUP BY s.family_id, s.started_at, s.ended_at_computed;$sql$
 WHERE path_template = '/audits/sessions/:SESSIONID'
   AND http_method = 'GET';

-- --------------------------------------------------------------------------
-- /audits/stats — tarjetas de la cabecera
-- --------------------------------------------------------------------------
UPDATE public.query
   SET query = $sql$WITH sesiones AS (
    SELECT
        toString(fila_new.family_id) AS family_id,
        argMax(multiIf(toString(fila_new.started_at) = '', NULL,
                       match(toString(fila_new.started_at), '^[0-9]{13,19}$'),
                           toDateTime64(toUInt64OrZero(toString(fila_new.started_at)) / 1000000, 3, 'UTC'),
                       parseDateTime64BestEffortOrNull(toString(fila_new.started_at), 3, 'UTC')), lsn) AS started_at,
        argMax(multiIf(toString(fila_new.ended_at) = '', NULL,
                       match(toString(fila_new.ended_at), '^[0-9]{13,19}$'),
                           toDateTime64(toUInt64OrZero(toString(fila_new.ended_at)) / 1000000, 3, 'UTC'),
                       parseDateTime64BestEffortOrNull(toString(fila_new.ended_at), 3, 'UTC')), lsn) AS ended_at,
        argMax(toString(fila_new.close_reason), lsn) AS close_reason,
        argMax(multiIf(toString(fila_new.last_seen_at) = '', NULL,
                       match(toString(fila_new.last_seen_at), '^[0-9]{13,19}$'),
                           toDateTime64(toUInt64OrZero(toString(fila_new.last_seen_at)) / 1000000, 3, 'UTC'),
                       parseDateTime64BestEffortOrNull(toString(fila_new.last_seen_at), 3, 'UTC')), lsn) AS last_seen_at
      FROM auditoria.audit_log
     WHERE tabla = 'tsesion_web'
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
FROM sesiones;$sql$
 WHERE path_template = '/audits/stats';
