-- V86 — filas de catálogo (public.query, type='clickhouse') para los
-- endpoints de /audits/* (sesiones) descritos en
-- docs/auditoria-queries-por-endpoint-clickhouse.md §2.
--
-- ADVERTENCIA que aplica a TODA esta migración: no existe una entidad
-- de sesión de autenticación real en ningún esquema del sistema (ni
-- Postgres ni ClickHouse — ver §6 del gap-analysis). Las queries de
-- abajo APROXIMAN una sesión agrupando filas de audit_log por
-- app_user con un corte de inactividad de 30 minutos (heurística de
-- "sessionization" vía lagInFrame + suma acumulada). El "id" de
-- sesión es sintético (`{app_user}-{índice}`) y no corresponde a
-- nada que auth-center conozca. Sirven para tener el endpoint
-- funcionando y probar el contrato de la spec — no para auditoría
-- legal de sesiones reales hasta que exista una entidad de sesión de
-- verdad.
--
-- Simplificación adicional: el filtro `author` en 2.2 solo busca por
-- app_user, no por IP (evita repetir el `any(client_ip)` agregado
-- dentro de un HAVING). 2.4 filtra solo por app_user, no por el
-- rango exacto [startedAt, endedAt] de la sesión — una operación de
-- OTRA sesión del mismo usuario podría colarse si hay más de una
-- sesión con la misma app_user en el histórico completo.

-- 2.2 — POST /audits/query (listar sesiones aproximadas)
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, detail, path_template, execution_mode, http_method, microservice_id, param_types)
VALUES (
    gen_random_uuid()::text,
    'WITH ordenado AS (
    SELECT app_user, client_ip, ts,
           if(dateDiff(''minute'', lagInFrame(ts) OVER (PARTITION BY app_user ORDER BY ts), ts) > 30, 1, 0) AS es_sesion_nueva
    FROM auditoria.audit_log
    WHERE app_user != '''' AND operacion != ''r''
),
sesionado AS (
    SELECT app_user, client_ip, ts,
           sum(es_sesion_nueva) OVER (PARTITION BY app_user ORDER BY ts ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS sesion_seq
    FROM ordenado
)
SELECT
    concat(app_user, ''-'', toString(sesion_seq)) AS id,
    app_user AS authorName,
    NULL AS authorAvatarUrl,
    false AS authorVerified,
    toString(any(client_ip)) AS ip,
    min(ts) AS startedAt,
    max(ts) AS endedAt,
    if(dateDiff(''minute'', max(ts), now()) < 30, ''active'', ''closed'') AS status,
    count() AS operationsCount,
    count() OVER() AS totalCount
FROM sesionado
GROUP BY app_user, sesion_seq
HAVING (coalesce(:BODY.FILTERS.AUTHOR, '''') = '''' OR positionCaseInsensitive(app_user, :BODY.FILTERS.AUTHOR) > 0)
   -- ClickHouse no hace short-circuit de OR — parseDateTimeBestEffort
   -- se evalúa siempre, así que se le pasa un sentinela parseable en
   -- vez de depender de que el OR "salve" el caso vacío.
   AND min(ts) >= parseDateTimeBestEffort(if(:BODY.FILTERS.STARTEDFROM = '''', ''1970-01-01'', :BODY.FILTERS.STARTEDFROM))
   AND min(ts) <= parseDateTimeBestEffort(if(:BODY.FILTERS.STARTEDTO = '''', ''2999-12-31'', :BODY.FILTERS.STARTEDTO))
ORDER BY startedAt DESC
LIMIT 100;',
    'clickhouse',
    false,
    false,
    'V86 — audits/query: sesiones APROXIMADAS (ver advertencia de cabecera) por inactividad de 30min sobre app_user',
    '/audits/query',
    'SELECT',
    'POST',
    (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse'),
    '{"BODY.FILTERS.AUTHOR":"VARCHAR","BODY.FILTERS.STARTEDFROM":"VARCHAR","BODY.FILTERS.STARTEDTO":"VARCHAR","BODY.FILTERS.STATUS":"VARCHAR","BODY.SORTING":"VARCHAR","BODY.PAGEINDEX":"VARCHAR","BODY.PAGESIZE":"VARCHAR"}'
)
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

-- 2.3 — GET /audits/sessions/{sessionId} (detalle de una sesión aproximada)
-- sessionId = "{app_user}-{sesion_seq}"; se separa con una regex sobre
-- el último '-' para tolerar app_user con guiones en el nombre.
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, detail, path_template, execution_mode, http_method, microservice_id, param_types)
VALUES (
    gen_random_uuid()::text,
    'WITH ordenado AS (
    SELECT ts, client_ip,
           if(dateDiff(''minute'', lagInFrame(ts) OVER (ORDER BY ts), ts) > 30, 1, 0) AS es_sesion_nueva
    FROM auditoria.audit_log
    WHERE app_user = extract(:PARAM.SESSIONID, ''^(.*)-\\d+$'') AND operacion != ''r''
),
sesionado AS (
    SELECT ts, client_ip,
           sum(es_sesion_nueva) OVER (ORDER BY ts ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS sesion_seq
    FROM ordenado
)
SELECT
    :PARAM.SESSIONID AS id,
    extract(:PARAM.SESSIONID, ''^(.*)-\\d+$'') AS authorName,
    NULL AS authorAvatarUrl,
    false AS authorVerified,
    toString(any(client_ip)) AS ip,
    min(ts) AS startedAt,
    max(ts) AS endedAt,
    if(dateDiff(''minute'', max(ts), now()) < 30, ''active'', ''closed'') AS status,
    count() AS operationsCount
FROM sesionado
WHERE sesion_seq = toUInt32(extract(:PARAM.SESSIONID, ''-(\\d+)$''))
GROUP BY sesion_seq;',
    'clickhouse',
    false,
    false,
    'V86 — audits/sessions/{sessionId}: detalle de una sesión aproximada',
    '/audits/sessions/:SESSIONID',
    'SELECT',
    'GET',
    (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse'),
    '{"PARAM.SESSIONID":"VARCHAR"}'
)
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

-- 2.4 — POST /audits/sessions/{sessionId}/operations (operaciones de una sesión aproximada)
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, detail, path_template, execution_mode, http_method, microservice_id, param_types)
VALUES (
    gen_random_uuid()::text,
    'SELECT
    concat(toString(lsn), ''-'', toString(seq)) AS id,
    tabla AS tableSlug,
    CASE operacion WHEN ''c'' THEN ''INSERT'' WHEN ''u'' THEN ''UPDATE'' WHEN ''d'' THEN ''DELETE'' ELSE ''SNAPSHOT'' END AS operation,
    etiqueta AS entityName,
    pk AS entityId,
    ts AS occurredAt,
    count() OVER() AS totalCount
FROM auditoria.audit_log
WHERE app_user = extract(:PARAM.SESSIONID, ''^(.*)-\\d+$'')
  AND operacion != ''r''
  AND (coalesce(:BODY.FILTERS.TABLESLUG, '''') = '''' OR tabla = :BODY.FILTERS.TABLESLUG)
  AND (coalesce(:BODY.FILTERS.OPERATIONCH, '''') = '''' OR operacion = :BODY.FILTERS.OPERATIONCH)
  AND ts >= parseDateTimeBestEffort(if(:BODY.FILTERS.OCCURREDFROM = '''', ''1970-01-01'', :BODY.FILTERS.OCCURREDFROM))
  AND ts <= parseDateTimeBestEffort(if(:BODY.FILTERS.OCCURREDTO = '''', ''2999-12-31'', :BODY.FILTERS.OCCURREDTO))
ORDER BY ts DESC
LIMIT 100;',
    'clickhouse',
    false,
    false,
    'V86 — audits/sessions/{sessionId}/operations: filtra por app_user completo, no por el rango exacto de la sesión (ver simplificación de cabecera)',
    '/audits/sessions/:SESSIONID/operations',
    'SELECT',
    'POST',
    (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse'),
    '{"PARAM.SESSIONID":"VARCHAR","BODY.FILTERS.TABLESLUG":"VARCHAR","BODY.FILTERS.OPERATIONCH":"VARCHAR","BODY.FILTERS.OCCURREDFROM":"VARCHAR","BODY.FILTERS.OCCURREDTO":"VARCHAR","BODY.SESSIONID":"VARCHAR","BODY.SORTING":"VARCHAR","BODY.PAGEINDEX":"VARCHAR","BODY.PAGESIZE":"VARCHAR"}'
)
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

-- 2.5 — POST /audits/stats
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, detail, path_template, execution_mode, http_method, microservice_id, param_types)
VALUES (
    gen_random_uuid()::text,
    'WITH ordenado AS (
    SELECT app_user, ts,
           if(dateDiff(''minute'', lagInFrame(ts) OVER (PARTITION BY app_user ORDER BY ts), ts) > 30, 1, 0) AS es_sesion_nueva
    FROM auditoria.audit_log
    WHERE app_user != '''' AND operacion != ''r''
),
sesionado AS (
    SELECT app_user, ts,
           sum(es_sesion_nueva) OVER (PARTITION BY app_user ORDER BY ts ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS sesion_seq
    FROM ordenado
),
sesiones AS (
    SELECT app_user, sesion_seq, min(ts) AS startedAt, max(ts) AS endedAt, count() AS ops
    FROM sesionado GROUP BY app_user, sesion_seq
)
SELECT
    countIf(toDate(startedAt) = today()) AS sessionsToday,
    countIf(dateDiff(''minute'', endedAt, now()) < 30) AS activeSessions,
    sumIf(ops, toDate(startedAt) = today()) AS operationsToday
FROM sesiones;',
    'clickhouse',
    false,
    false,
    'V86 — audits/stats: sessionsToday/activeSessions/operationsToday sobre sesiones aproximadas, sin filtros (v1)',
    '/audits/stats',
    'SELECT',
    'POST',
    (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse'),
    '{}'
)
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;
