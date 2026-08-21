-- V85 — filas de catálogo (public.query, type='clickhouse') para los
-- endpoints de /audit-tables/* descritos en
-- docs/auditoria-queries-por-endpoint-clickhouse.md §1. Corren contra
-- la instancia registrada en V84.
--
-- Simplificaciones deliberadas frente a la spec completa (documentadas
-- también en el .md hermano — no son un compromiso silencioso):
--   - El catálogo de tablas auditables (slug/nombre/ícono) es un CTE
--     literal con 4 tablas de ejemplo, no una tabla real. Extender
--     agregando más filas al UNION ALL de cada query, o migrar a una
--     tabla real (public.audit_table_catalog) cuando la lista crezca.
--   - `entityFields`/el diff antes-después se devuelven como JSON crudo
--     (fila_new_raw/fila_old_raw) en vez de un mapa por nombre de campo
--     legible — construir ese mapeo por campo requeriría una fila de
--     catálogo distinta POR TABLA (cada una con sus propios
--     JSONExtractString), lo cual no escala vía SQL estático. La capa
--     de aplicación parsea el JSON y aplica las etiquetas legibles del
--     mismo catálogo de tablas.
--   - `filters.operations` acepta un solo valor (INSERT/UPDATE/DELETE),
--     no un array — bind de arrays contra ClickHouse vía este binder
--     no está validado todavía.
--   - LIMIT es literal fijo (100) — ClickHouse exige que LIMIT/OFFSET
--     sean constantes en el texto SQL, :QUERY.SIZE/:QUERY.OFFSET
--     bindeados fallan con "LIMIT expression must be constant with
--     numeric type" (encontrado y documentado en la sesión anterior).
--     Pendiente: paginación real necesita resolver esto antes de
--     mergear a un catálogo de producción.

-- 1.1 — POST /audit-tables/query (listar tablas auditadas)
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, detail, path_template, execution_mode, http_method, microservice_id, param_types)
VALUES (
    gen_random_uuid()::text,
    'WITH catalogo AS (
    SELECT * FROM (
        SELECT ''tarea'' AS tabla_real, ''tArea'' AS slug, ''Área'' AS name, ''BookOpen-Icon'' AS icon
        UNION ALL SELECT ''tgrado'', ''tGrado'', ''Grado'', ''GraduationCap-Icon''
        UNION ALL SELECT ''testablecimiento'', ''tEstablecimiento'', ''Establecimiento'', ''Bank-Icon''
        UNION ALL SELECT ''tperiodo_academico'', ''tPeriodoAcademico'', ''Periodo académico'', ''Calendar-Icon''
    )
)
SELECT
    c.slug,
    c.name,
    c.icon,
    countIf(a.tabla = c.tabla_real AND toDate(a.ts) = today() AND a.operacion != ''r'') AS operationsToday,
    count() OVER() AS totalCount
FROM catalogo c
LEFT JOIN auditoria.audit_log a ON a.tabla = c.tabla_real
WHERE coalesce(:BODY.FILTERS.NAME, '''') = '''' OR positionCaseInsensitive(c.name, :BODY.FILTERS.NAME) > 0
GROUP BY c.slug, c.name, c.icon
ORDER BY c.name
LIMIT 100;',
    'clickhouse',
    false,
    false,
    'V85 — audit-tables/query: catálogo (literal, ver comentario de cabecera) + operationsToday calculado en vivo',
    '/audit-tables/query',
    'SELECT',
    'POST',
    (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse'),
    '{"BODY.FILTERS.NAME":"VARCHAR","BODY.SORTING":"VARCHAR","BODY.PAGEINDEX":"VARCHAR","BODY.PAGESIZE":"VARCHAR"}'
)
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

-- 1.2 — GET /audit-tables/{slug} (detalle de una tabla)
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, detail, path_template, execution_mode, http_method, microservice_id, param_types)
VALUES (
    gen_random_uuid()::text,
    'WITH catalogo AS (
    SELECT * FROM (
        SELECT ''tarea'' AS tabla_real, ''tArea'' AS slug, ''Área'' AS name, ''BookOpen-Icon'' AS icon
        UNION ALL SELECT ''tgrado'', ''tGrado'', ''Grado'', ''GraduationCap-Icon''
        UNION ALL SELECT ''testablecimiento'', ''tEstablecimiento'', ''Establecimiento'', ''Bank-Icon''
        UNION ALL SELECT ''tperiodo_academico'', ''tPeriodoAcademico'', ''Periodo académico'', ''Calendar-Icon''
    )
)
SELECT
    c.slug,
    c.name,
    c.icon,
    countIf(a.tabla = c.tabla_real AND toDate(a.ts) = today() AND a.operacion != ''r'') AS operationsToday
FROM catalogo c
LEFT JOIN auditoria.audit_log a ON a.tabla = c.tabla_real
WHERE c.slug = :PARAM.SLUG
GROUP BY c.slug, c.name, c.icon;',
    'clickhouse',
    false,
    false,
    'V85 — audit-tables/{slug}: detalle + operationsToday del día',
    '/audit-tables/:SLUG',
    'SELECT',
    'GET',
    (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse'),
    '{"PARAM.SLUG":"VARCHAR"}'
)
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

-- 1.3 — POST /audit-tables/{slug}/operations/query (listar operaciones de una tabla)
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, detail, path_template, execution_mode, http_method, microservice_id, param_types)
VALUES (
    gen_random_uuid()::text,
    'SELECT
    concat(toString(lsn), ''-'', toString(seq)) AS id,
    CASE operacion WHEN ''c'' THEN ''INSERT'' WHEN ''u'' THEN ''UPDATE'' WHEN ''d'' THEN ''DELETE'' ELSE ''SNAPSHOT'' END AS operation,
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
WHERE tabla = CASE :PARAM.SLUG
        WHEN ''tArea'' THEN ''tarea''
        WHEN ''tGrado'' THEN ''tgrado''
        WHEN ''tEstablecimiento'' THEN ''testablecimiento''
        WHEN ''tPeriodoAcademico'' THEN ''tperiodo_academico''
        ELSE ''''
      END
  AND operacion != ''r''
  AND (coalesce(:BODY.FILTERS.AUTHOR, '''') = '''' OR positionCaseInsensitive(app_user, :BODY.FILTERS.AUTHOR) > 0
                                   OR positionCaseInsensitive(toString(client_ip), :BODY.FILTERS.AUTHOR) > 0)
  AND (coalesce(:BODY.FILTERS.OPERATIONCH, '''') = '''' OR operacion = :BODY.FILTERS.OPERATIONCH)
  -- ClickHouse NO hace short-circuit de OR (a diferencia de Postgres) --
  -- evalúa ambos lados siempre, así que "x = '''' OR parseDateTimeBestEffort(x)"
  -- revienta en CANNOT_PARSE_DATETIME cuando x es '''' aunque el primer
  -- lado sea true. Se evita pasándole SIEMPRE un string parseable
  -- (el filtro real, o un sentinela que hace el rango un no-op).
  AND ts >= parseDateTimeBestEffort(if(:BODY.FILTERS.OCCURREDFROM = '''', ''1970-01-01'', :BODY.FILTERS.OCCURREDFROM))
  AND ts <= parseDateTimeBestEffort(if(:BODY.FILTERS.OCCURREDTO = '''', ''2999-12-31'', :BODY.FILTERS.OCCURREDTO))
ORDER BY ts DESC
LIMIT 100;',
    'clickhouse',
    false,
    false,
    'V85 — audit-tables/{slug}/operations/query: listado paginado y filtrable. operation ya mapeado c/u/d->INSERT/UPDATE/DELETE. entityFieldsRaw es JSON crudo (ver simplificaciones de cabecera)',
    '/audit-tables/:SLUG/operations/query',
    'SELECT',
    'POST',
    (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse'),
    '{"PARAM.SLUG":"VARCHAR","BODY.FILTERS.AUTHOR":"VARCHAR","BODY.FILTERS.OPERATIONCH":"VARCHAR","BODY.FILTERS.OCCURREDFROM":"VARCHAR","BODY.FILTERS.OCCURREDTO":"VARCHAR","BODY.TABLESLUG":"VARCHAR","BODY.SORTING":"VARCHAR","BODY.PAGEINDEX":"VARCHAR","BODY.PAGESIZE":"VARCHAR"}'
)
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

-- 1.4 — GET /audit-tables/{slug}/operations/{operationId}/changes
-- operationId = "{lsn}-{seq}" (misma identidad que ya usa POST /audit/revert, sso-admin, fase 1)
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, detail, path_template, execution_mode, http_method, microservice_id, param_types)
VALUES (
    gen_random_uuid()::text,
    -- ClickHouse no soporta subconsultas correlacionadas fila-a-fila
    -- ("Resolve identifier ''a1.tabla'' from parent scope only
    -- supported for constants and CTE") — a diferencia de Postgres.
    -- Se evita con un CTE `op` de UNA sola fila (ya filtrada por
    -- lsn/seq) y referenciándolo como subconsulta escalar
    -- `(SELECT tabla FROM op)`, que SÍ está permitido.
    'WITH op AS (
    SELECT tabla, pk, operacion, etiqueta, fila_old_raw, fila_new_raw
    FROM auditoria.audit_log
    WHERE lsn = toUInt64(splitByChar(''-'', :PARAM.OPERATIONID)[1])
      AND seq = toUInt32(splitByChar(''-'', :PARAM.OPERATIONID)[2])
    ORDER BY ts DESC
    LIMIT 1
)
SELECT
    :PARAM.OPERATIONID AS operationId,
    CASE (SELECT operacion FROM op) WHEN ''c'' THEN ''INSERT'' WHEN ''u'' THEN ''UPDATE'' WHEN ''d'' THEN ''DELETE'' ELSE ''SNAPSHOT'' END AS operation,
    (SELECT etiqueta FROM op) AS entityName,
    (SELECT pk FROM op) AS entityId,
    (SELECT fila_old_raw FROM op) AS beforeRaw,
    (SELECT fila_new_raw FROM op) AS afterRaw,
    -- "current": la operación MÁS RECIENTE conocida sobre la misma fila
    -- (misma tabla+pk) — puede diferir de afterRaw si hubo cambios
    -- posteriores a esta operación, exactamente el caso que la spec
    -- dice que puede pasar. No requiere tocar Postgres.
    (SELECT argMax(fila_new_raw, ts) FROM auditoria.audit_log
      WHERE tabla = (SELECT tabla FROM op) AND pk = (SELECT pk FROM op) AND operacion != ''r'') AS currentRaw;',
    'clickhouse',
    false,
    false,
    'V85 — audit-tables/{slug}/operations/{operationId}/changes: before/after/current como JSON crudo (ver simplificaciones de cabecera); el diff campo-por-campo lo arma la capa de aplicación',
    '/audit-tables/:SLUG/operations/:OPERATIONID/changes',
    'SELECT',
    'GET',
    (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse'),
    '{"PARAM.SLUG":"VARCHAR","PARAM.OPERATIONID":"VARCHAR"}'
)
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

-- 1.6 — POST /audit-tables/{slug}/operations/stats
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, detail, path_template, execution_mode, http_method, microservice_id, param_types)
VALUES (
    gen_random_uuid()::text,
    'SELECT
    countIf(operacion = ''c'') AS inserts,
    countIf(operacion = ''u'') AS updates,
    countIf(operacion = ''d'') AS deletes
FROM auditoria.audit_log
WHERE tabla = CASE :PARAM.SLUG
        WHEN ''tArea'' THEN ''tarea''
        WHEN ''tGrado'' THEN ''tgrado''
        WHEN ''tEstablecimiento'' THEN ''testablecimiento''
        WHEN ''tPeriodoAcademico'' THEN ''tperiodo_academico''
        ELSE ''''
      END
  AND operacion != ''r''
  AND ts >= parseDateTimeBestEffort(if(:BODY.FILTERS.OCCURREDFROM = '''', ''1970-01-01'', :BODY.FILTERS.OCCURREDFROM))
  AND ts <= parseDateTimeBestEffort(if(:BODY.FILTERS.OCCURREDTO = '''', ''2999-12-31'', :BODY.FILTERS.OCCURREDTO));',
    'clickhouse',
    false,
    false,
    'V85 — audit-tables/{slug}/operations/stats: conteo inserts/updates/deletes',
    '/audit-tables/:SLUG/operations/stats',
    'SELECT',
    'POST',
    (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse'),
    '{"PARAM.SLUG":"VARCHAR","BODY.FILTERS.OCCURREDFROM":"VARCHAR","BODY.FILTERS.OCCURREDTO":"VARCHAR"}'
)
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;
