-- ============================================================================
-- V356 — split del microservicio de auditoría por esquema.
--
-- POR QUE NO UN FILTRO EN EL FRONT
--   V355 intentó resolver el discriminador PIGSE/CEVAL agregando el
--   parámetro :BODY.FILTERS.SCHEMA al catálogo y haciendo que el front
--   eligiera esquema en un dropdown. Esa es la forma equivocada:
--   el front no debería saber qué esquema le corresponde — el back
--   ya lo sabe por la ruta que el gateway le enrutó (/api/audit-ch/**
--   vs /api/audit-pigse/**), y meterle al front un selector de esquema
--   cuando esa elección ya está implícita en el microservicio es:
--     1. una variable de UI que solo se configura una vez y nunca
--        cambia — un dropdown donde todos los usuarios ven "academico_test"
--        y nadie cambia;
--     2. una superficie de error: un bug en el front podría enviar
--        :BODY.FILTERS.SCHEMA='pigse' a un endpoint que debe ser CEVAL
--        y nadie se enteraría;
--     3. código que hay que duplicar en los 4 hooks de filtros y en
--        los 4 componentes de UI cuando la separación real vive en
--        el catálogo de microservicios, que es donde SÍ debe vivir.
--
-- QUE HACE ESTA MIGRACION
--   1. Revierte los cambios de V355 sobre las filas existentes del
--      microservicio `audit-clickhouse`: vuelve a la forma V85/V86/V90
--      (slug = t<Nombre>, sin prefijo de schema; sin columna calculada
--      schema; sin filtro BODY.FILTERS.SCHEMA).
--   2. Corrige el WHERE de V85 que V355 no alcanzó a tocar: V85 tenía
--      `WHERE tabla LIKE 't%'` que solo matchea si `tabla` no tiene
--      prefijo de schema -- pero fn_audit_ctx emite `tabla` como
--      concat(TG_TABLE_SCHEMA, '.', TG_TABLE_NAME), así que el WHERE
--      de V85 jamás devolvió filas en producción. La corrección es
--      acá: `WHERE tabla LIKE 'academico_test.%'` (CEVAL) o
--      `WHERE tabla LIKE 'pigse.%'` (PIGSE).
--   3. Da de alta el microservicio `audit-clickhouse-pigse` con su
--      request_uri propio (/api/audit-pigse/**). El provisioner sidecar
--      levantará un contenedor `query-service-audit-clickhouse-pigse`
--      automáticamente al ver la fila nueva (ver ProvisionerController).
--   4. Duplica las 8 queries del catálogo (1.1, 1.2, 1.3, 1.4, 1.6
--      + 2.2, 2.3, 2.4, 2.5) contra `audit-clickhouse-pigse`, con
--      `WHERE tabla LIKE 'pigse.%'` en las 5 que leen audit_log (las
--      otras 3 leen tsesion_web que es global y van idénticas).
--
-- QUE NO HACE
--   - No renombra `audit-clickhouse` -> `audit-clickhouse-ceval`. La
--     fila de V84 mantiene su identidad: cambiar serviceid obligaría
--     al provisioner a re-provisionar el contenedor en todos los
--     ambientes y agrega churn sin beneficio. La fila de V84 ES hoy
--     CEVAL-only (lo era desde antes: academico_test.* era el único
--     esquema que escribía a ClickHouse) -- esta migración lo explicita
--     agregando el WHERE y deja la nueva fila como contraparte PIGSE.
--   - No duplica 1.4 (cambios de una operación). El endpoint recibe
--     operationId = "{lsn}-{seq}", busca por lsn/seq (PK de auditoría,
--     única por evento CDC), no por tabla: el resultado es independiente
--     del esquema. Lo duplico de todos modos para que cada gateway de
--     app tenga su propio juego completo de paths registrados.
--
-- CONVENCION DE QUERY TEXT PARA HARDCODEAR EL SCHEMA
--   - Lista/Detalle de tablas (1.1, 1.2): el CTE catalogo extrae
--     `tabla` con `LIKE 'academico_test.%'` (CEVAL) o `LIKE 'pigse.%'`
--     (PIGSE), y el slug algorítmico (V85) deriva del nombre SIN el
--     prefijo de schema (se usa length('<schema>.') en lugar de un 2
--     fijo para recortar tanto el schema como la `t` inicial).
--   - Operaciones de una tabla (1.3) y stats (1.6): el slug entrante
--     sigue siendo `t<Nombre>`; la fórmula inversa ahora reconstruye
--     `concat('academico_test.t', ...)` (CEVAL) o `concat('pigse.t', ...)`
--     (PIGSE).
--   - Cambios de una operación (1.4): la subconsulta usa lsn/seq (PK
--     única), no tabla, así que la query es idéntica entre esquemas.
--   - Sesiones (2.2, 2.3, 2.5): leen tsesion_web que es global; la
--     query es idéntica. Se duplica por simetría de routing.
--   - Operaciones de una sesión (2.4): filtra por sesion_id pero como
--     la sesión puede contener operaciones en ambos esquemas, agrega
--     `tabla LIKE 'academico_test.%'` (CEVAL) o `tabla LIKE 'pigse.%'`
--     (PIGSE).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Microservicio PIGSE
-- ---------------------------------------------------------------------------
INSERT INTO public.microservice
    (serviceid, description, requesturi, kind, dialect, jdbcurl, dbusername, dbpassword, instancename)
VALUES (
    'audit-clickhouse-pigse',
    'Auditoría PIGSE de solo lectura (ClickHouse) — gemelo de audit-clickhouse con esquema pigse.* hardcodeado en cada WHERE. Provisioner sidecar levanta query-service-audit-clickhouse-pigse enrutado bajo /api/audit-pigse/**',
    '/api/audit-pigse/**',
    'QUERY',
    'clickhouse',
    'jdbc:ch://cdc-clickhouse:8123/auditoria',
    'default',
    '',
    'audit-clickhouse-pigse'
)
ON CONFLICT (serviceid) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. Revertir V355 y agregar el WHERE hardcodeado de academico_test en las
--    queries existentes (microservicio audit-clickhouse = CEVAL).
-- ---------------------------------------------------------------------------

-- 2.1 — 1.1 /audit-tables/query
UPDATE public.query
SET query = 'WITH catalogo AS (
    SELECT
        tabla_real,
        -- Slug algorítmico V85 aplicado a la tabla SIN el prefijo
        -- ''academico_test.'' y SIN la ''t'' inicial. length(''academico_test.'')
        -- es 16, así que substring(tabla_real, 18) quita el schema + la t.
        -- Esto mismo que hacía V85 cuando tabla NO tenía schema -- pero
        -- ahora V355 no existe y la columna tabla SÍ tiene schema,
        -- así que la fórmula debe cortar 16+1=17 chars. Resultado:
        -- ''academico_test.tperiodo_academico'' -> ''periodo_academico''
        -- -> ''PeriodoAcademico'' -> ''tPeriodoAcademico''.
        concat(''t'', arrayStringConcat(arrayMap(w -> concat(upper(substring(w,1,1)), lower(substring(w,2))), splitByChar(''_'', substring(tabla_real, length(''academico_test.'') + 2))), '''')) AS slug,
        arrayStringConcat(arrayMap(w -> concat(upper(substring(w,1,1)), lower(substring(w,2))), splitByChar(''_'', substring(tabla_real, length(''academico_test.'') + 2))), '' '') AS name,
        ''Table-Icon'' AS icon
    FROM (SELECT DISTINCT tabla AS tabla_real FROM auditoria.audit_log WHERE tabla LIKE ''academico_test.%'')
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
    param_types = '{"BODY.FILTERS.NAME":"VARCHAR","BODY.SORTING":"VARCHAR","BODY.PAGEINDEX":"VARCHAR","BODY.PAGESIZE":"VARCHAR"}',
    detail = 'V356 — audit-tables/query: esquema academico_test.* hardcodeado en WHERE del CTE y fórmula de slug ajustada para recortar el prefijo del schema (V85 presuponía un tabla sin schema; V356 lo hace explícito). Reemplaza la versión V355 que usaba :BODY.FILTERS.SCHEMA como discriminador.'
WHERE path_template = '/audit-tables/query'
  AND http_method = 'POST'
  AND microservice_id = (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse');

-- 2.2 — 1.2 /audit-tables/{slug}
UPDATE public.query
SET query = 'WITH catalogo AS (
    SELECT
        tabla_real,
        concat(''t'', arrayStringConcat(arrayMap(w -> concat(upper(substring(w,1,1)), lower(substring(w,2))), splitByChar(''_'', substring(tabla_real, length(''academico_test.'') + 2))), '''')) AS slug,
        arrayStringConcat(arrayMap(w -> concat(upper(substring(w,1,1)), lower(substring(w,2))), splitByChar(''_'', substring(tabla_real, length(''academico_test.'') + 2))), '' '') AS name,
        ''Table-Icon'' AS icon
    FROM (SELECT DISTINCT tabla AS tabla_real FROM auditoria.audit_log WHERE tabla LIKE ''academico_test.%'')
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
    param_types = '{"PARAM.SLUG":"VARCHAR"}',
    detail = 'V356 — audit-tables/{slug}: detalle de tabla CEVAL con WHERE academico_test.* hardcodeado.'
WHERE path_template = '/audit-tables/:SLUG'
  AND http_method = 'GET'
  AND microservice_id = (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse');

-- 2.3 — 1.3 /audit-tables/{slug}/operations/query
UPDATE public.query
SET query = 'SELECT
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
-- Fórmula inversa slug -> tabla CEVAL: el slug entrante es t<Nombre>
-- (V85, sin schema); el WHERE reconstruye ''academico_test.t<nombre>''
-- hardcodeando el schema que le corresponde a este microservicio.
WHERE tabla = concat(''academico_test.t'', substring(lower(replaceRegexpAll(substring(:PARAM.SLUG, 2), ''([A-Z])'', ''_\1'')), 2))
  AND operacion != ''r''
  AND (coalesce(:BODY.FILTERS.AUTHOR, '''') = '''' OR positionCaseInsensitive(app_user, :BODY.FILTERS.AUTHOR) > 0
                                   OR positionCaseInsensitive(toString(client_ip), :BODY.FILTERS.AUTHOR) > 0)
  AND (coalesce(:BODY.FILTERS.OPERATIONCH, '''') = '''' OR operacion = :BODY.FILTERS.OPERATIONCH)
  AND ts >= parseDateTimeBestEffort(if(:BODY.FILTERS.OCCURREDFROM = '''', ''1970-01-01'', :BODY.FILTERS.OCCURREDFROM))
  AND ts <= parseDateTimeBestEffort(if(:BODY.FILTERS.OCCURREDTO = '''', ''2999-12-31'', :BODY.FILTERS.OCCURREDTO))
ORDER BY ts DESC
LIMIT 100;',
    detail = 'V356 — audit-tables/{slug}/operations/query: fórmula inversa slug->tabla hardcodea ''academico_test.t'' porque el microservicio ES la fuente del discriminador.'
WHERE path_template = '/audit-tables/:SLUG/operations/query'
  AND http_method = 'POST'
  AND microservice_id = (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse');

-- 2.4 — 1.4 /audit-tables/{slug}/operations/{operationId}/changes
-- Sin WHERE de schema: la operación se identifica por lsn+seq (PK de
-- auditoría), no por tabla. La query es independiente del esquema.
-- No necesita cambios para V356 -- pero actualizamos el detail para
-- reflejar que es la versión CEVAL del microservicio.
UPDATE public.query
SET detail = 'V356 — audit-tables/{slug}/operations/{operationId}/changes: la operación se identifica por lsn+seq (PK de auditoría CDC), no por tabla; el resultado es independiente del esquema. Query idéntica entre microservicios CEVAL y PIGSE.'
WHERE path_template = '/audit-tables/:SLUG/operations/:OPERATIONID/changes'
  AND http_method = 'GET'
  AND microservice_id = (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse');

-- 2.5 — 1.6 /audit-tables/{slug}/operations/stats
UPDATE public.query
SET query = 'SELECT
    countIf(operacion = ''c'') AS inserts,
    countIf(operacion = ''u'') AS updates,
    countIf(operacion = ''d'') AS deletes
FROM auditoria.audit_log
WHERE tabla = concat(''academico_test.t'', substring(lower(replaceRegexpAll(substring(:PARAM.SLUG, 2), ''([A-Z])'', ''_\1'')), 2))
  AND operacion != ''r''
  AND ts >= parseDateTimeBestEffort(if(:BODY.FILTERS.OCCURREDFROM = '''', ''1970-01-01'', :BODY.FILTERS.OCCURREDFROM))
  AND ts <= parseDateTimeBestEffort(if(:BODY.FILTERS.OCCURREDTO = '''', ''2999-12-31'', :BODY.FILTERS.OCCURREDTO));',
    detail = 'V356 — audit-tables/{slug}/operations/stats: hardcoded ''academico_test.t'' en la fórmula inversa slug->tabla.'
WHERE path_template = '/audit-tables/:SLUG/operations/stats'
  AND http_method = 'POST'
  AND microservice_id = (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse');

-- 2.6 — 2.4 /audits/sessions/{sessionId}/operations
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
  AND tabla LIKE ''academico_test.%''
  AND (coalesce(:BODY.FILTERS.TABLESLUG, '''') = '''' OR tabla = :BODY.FILTERS.TABLESLUG)
  AND (coalesce(:BODY.FILTERS.OPERATIONCH, '''') = '''' OR operacion = :BODY.FILTERS.OPERATIONCH)
  AND ts >= parseDateTimeBestEffort(if(:BODY.FILTERS.OCCURREDFROM = '''', ''1970-01-01'', :BODY.FILTERS.OCCURREDFROM))
  AND ts <= parseDateTimeBestEffort(if(:BODY.FILTERS.OCCURREDTO = '''', ''2999-12-31'', :BODY.FILTERS.OCCURREDTO))
ORDER BY ts DESC
LIMIT 100;',
    param_types = '{"PARAM.SESSIONID":"VARCHAR","BODY.FILTERS.TABLESLUG":"VARCHAR","BODY.FILTERS.OPERATIONCH":"VARCHAR","BODY.FILTERS.OCCURREDFROM":"VARCHAR","BODY.FILTERS.OCCURREDTO":"VARCHAR","BODY.SESSIONID":"VARCHAR","BODY.SORTING":"VARCHAR","BODY.PAGEINDEX":"VARCHAR","BODY.PAGESIZE":"VARCHAR"}',
    detail = 'V356 — audits/sessions/{sessionId}/operations: WHERE academico_test.* hardcodeado; shape idéntico al de V90 (sesion_id = family_id real). Reemplaza la versión V355 que tenía :BODY.FILTERS.SCHEMA.'
WHERE path_template = '/audits/sessions/:SESSIONID/operations'
  AND http_method = 'POST'
  AND microservice_id = (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse');

-- ---------------------------------------------------------------------------
-- 3. Duplicar las 8 queries contra audit-clickhouse-pigse
-- ---------------------------------------------------------------------------
-- Las cinco queries que leen audit_log.tabla llevan WHERE
-- ''pigse.%'' en vez de ''academico_test.%''. Las tres que leen
-- tsesion_web son idénticas (sesiones son globales).
-- ---------------------------------------------------------------------------

-- 3.1 — 1.1 /audit-tables/query (pigse)
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, detail, path_template, execution_mode, http_method, microservice_id, param_types)
VALUES (
    gen_random_uuid()::text,
    'WITH catalogo AS (
    SELECT
        tabla_real,
        concat(''t'', arrayStringConcat(arrayMap(w -> concat(upper(substring(w,1,1)), lower(substring(w,2))), splitByChar(''_'', substring(tabla_real, length(''pigse.'') + 2))), '''')) AS slug,
        arrayStringConcat(arrayMap(w -> concat(upper(substring(w,1,1)), lower(substring(w,2))), splitByChar(''_'', substring(tabla_real, length(''pigse.'') + 2))), '' '') AS name,
        ''Table-Icon'' AS icon
    FROM (SELECT DISTINCT tabla AS tabla_real FROM auditoria.audit_log WHERE tabla LIKE ''pigse.%'')
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
    'V356 — audit-tables/query (pigse): gemelo CEVAL con WHERE pigse.* y length(''pigse.'') en la fórmula de slug',
    '/audit-tables/query',
    'SELECT',
    'POST',
    (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse-pigse'),
    '{"BODY.FILTERS.NAME":"VARCHAR","BODY.SORTING":"VARCHAR","BODY.PAGEINDEX":"VARCHAR","BODY.PAGESIZE":"VARCHAR"}'
)
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

-- 3.2 — 1.2 /audit-tables/{slug} (pigse)
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, detail, path_template, execution_mode, http_method, microservice_id, param_types)
VALUES (
    gen_random_uuid()::text,
    'WITH catalogo AS (
    SELECT
        tabla_real,
        concat(''t'', arrayStringConcat(arrayMap(w -> concat(upper(substring(w,1,1)), lower(substring(w,2))), splitByChar(''_'', substring(tabla_real, length(''pigse.'') + 2))), '''')) AS slug,
        arrayStringConcat(arrayMap(w -> concat(upper(substring(w,1,1)), lower(substring(w,2))), splitByChar(''_'', substring(tabla_real, length(''pigse.'') + 2))), '' '') AS name,
        ''Table-Icon'' AS icon
    FROM (SELECT DISTINCT tabla AS tabla_real FROM auditoria.audit_log WHERE tabla LIKE ''pigse.%'')
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
    'V356 — audit-tables/{slug} (pigse): detalle con WHERE pigse.* hardcodeado',
    '/audit-tables/:SLUG',
    'SELECT',
    'GET',
    (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse-pigse'),
    '{"PARAM.SLUG":"VARCHAR"}'
)
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

-- 3.3 — 1.3 /audit-tables/{slug}/operations/query (pigse)
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
WHERE tabla = concat(''pigse.t'', substring(lower(replaceRegexpAll(substring(:PARAM.SLUG, 2), ''([A-Z])'', ''_\1'')), 2))
  AND operacion != ''r''
  AND (coalesce(:BODY.FILTERS.AUTHOR, '''') = '''' OR positionCaseInsensitive(app_user, :BODY.FILTERS.AUTHOR) > 0
                                   OR positionCaseInsensitive(toString(client_ip), :BODY.FILTERS.AUTHOR) > 0)
  AND (coalesce(:BODY.FILTERS.OPERATIONCH, '''') = '''' OR operacion = :BODY.FILTERS.OPERATIONCH)
  AND ts >= parseDateTimeBestEffort(if(:BODY.FILTERS.OCCURREDFROM = '''', ''1970-01-01'', :BODY.FILTERS.OCCURREDFROM))
  AND ts <= parseDateTimeBestEffort(if(:BODY.FILTERS.OCCURREDTO = '''', ''2999-12-31'', :BODY.FILTERS.OCCURREDTO))
ORDER BY ts DESC
LIMIT 100;',
    'clickhouse',
    false,
    false,
    'V356 — audit-tables/{slug}/operations/query (pigse): fórmula inversa reconstruye ''pigse.t<...>''',
    '/audit-tables/:SLUG/operations/query',
    'SELECT',
    'POST',
    (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse-pigse'),
    '{"PARAM.SLUG":"VARCHAR","BODY.FILTERS.AUTHOR":"VARCHAR","BODY.FILTERS.OPERATIONCH":"VARCHAR","BODY.FILTERS.OCCURREDFROM":"VARCHAR","BODY.FILTERS.OCCURREDTO":"VARCHAR","BODY.TABLESLUG":"VARCHAR","BODY.SORTING":"VARCHAR","BODY.PAGEINDEX":"VARCHAR","BODY.PAGESIZE":"VARCHAR"}'
)
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

-- 3.4 — 1.4 /audit-tables/{slug}/operations/{operationId}/changes (pigse)
-- Idéntica a CEVAL: la PK es lsn+seq, no tabla.
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, detail, path_template, execution_mode, http_method, microservice_id, param_types)
VALUES (
    gen_random_uuid()::text,
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
    (SELECT argMax(fila_new_raw, ts) FROM auditoria.audit_log
      WHERE tabla = (SELECT tabla FROM op) AND pk = (SELECT pk FROM op) AND operacion != ''r'') AS currentRaw;',
    'clickhouse',
    false,
    false,
    'V356 — audit-tables/{slug}/operations/{operationId}/changes (pigse): idéntica a CEVAL porque la PK de auditoría es lsn+seq, no tabla',
    '/audit-tables/:SLUG/operations/:OPERATIONID/changes',
    'SELECT',
    'GET',
    (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse-pigse'),
    '{"PARAM.SLUG":"VARCHAR","PARAM.OPERATIONID":"VARCHAR"}'
)
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

-- 3.5 — 1.6 /audit-tables/{slug}/operations/stats (pigse)
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, detail, path_template, execution_mode, http_method, microservice_id, param_types)
VALUES (
    gen_random_uuid()::text,
    'SELECT
    countIf(operacion = ''c'') AS inserts,
    countIf(operacion = ''u'') AS updates,
    countIf(operacion = ''d'') AS deletes
FROM auditoria.audit_log
WHERE tabla = concat(''pigse.t'', substring(lower(replaceRegexpAll(substring(:PARAM.SLUG, 2), ''([A-Z])'', ''_\1'')), 2))
  AND operacion != ''r''
  AND ts >= parseDateTimeBestEffort(if(:BODY.FILTERS.OCCURREDFROM = '''', ''1970-01-01'', :BODY.FILTERS.OCCURREDFROM))
  AND ts <= parseDateTimeBestEffort(if(:BODY.FILTERS.OCCURREDTO = '''', ''2999-12-31'', :BODY.FILTERS.OCCURREDTO));',
    'clickhouse',
    false,
    false,
    'V356 — audit-tables/{slug}/operations/stats (pigse): hardcoded ''pigse.t'' en la fórmula inversa',
    '/audit-tables/:SLUG/operations/stats',
    'SELECT',
    'POST',
    (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse-pigse'),
    '{"PARAM.SLUG":"VARCHAR","BODY.FILTERS.OCCURREDFROM":"VARCHAR","BODY.FILTERS.OCCURREDTO":"VARCHAR"}'
)
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

-- 3.6 — 2.2 /audits/query (pigse)
-- Idéntica a la versión CEVAL/V90: tsesion_web es global, el JOIN con
-- audit_log no filtra por tabla porque una sesión puede contener ops
-- de cualquier esquema. Se duplica por simetría de routing del gateway.
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, detail, path_template, execution_mode, http_method, microservice_id, param_types)
VALUES (
    gen_random_uuid()::text,
    'WITH latest AS (
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
    'clickhouse',
    false,
    false,
    'V356 — audits/query (pigse): idéntica a V90/CEVAL porque tsesion_web es global',
    '/audits/query',
    'SELECT',
    'POST',
    (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse-pigse'),
    '{"BODY.FILTERS.AUTHOR":"VARCHAR","BODY.FILTERS.STARTEDFROM":"VARCHAR","BODY.FILTERS.STARTEDTO":"VARCHAR","BODY.FILTERS.STATUS":"VARCHAR","BODY.SORTING":"VARCHAR","BODY.PAGEINDEX":"VARCHAR","BODY.PAGESIZE":"VARCHAR"}'
)
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

-- 3.7 — 2.3 /audits/sessions/{sessionId} (pigse)
-- Idéntica a V90: detalle de UNA sesión real.
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, detail, path_template, execution_mode, http_method, microservice_id, param_types)
VALUES (
    gen_random_uuid()::text,
    'WITH latest AS (
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
    'clickhouse',
    false,
    false,
    'V356 — audits/sessions/{sessionId} (pigse): idéntica a V90, sesiones son globales',
    '/audits/sessions/:SESSIONID',
    'SELECT',
    'GET',
    (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse-pigse'),
    '{"PARAM.SESSIONID":"VARCHAR"}'
)
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

-- 3.8 — 2.4 /audits/sessions/{sessionId}/operations (pigse)
-- A diferencia de 2.2/2.3, esta SÍ filtra por tabla porque las
-- operaciones pueden ser de cualquier esquema -- aquí el filtro es
-- pigse.% porque el microservicio ES PIGSE.
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
WHERE sesion_id = :PARAM.SESSIONID
  AND operacion != ''r''
  AND tabla LIKE ''pigse.%''
  AND (coalesce(:BODY.FILTERS.TABLESLUG, '''') = '''' OR tabla = :BODY.FILTERS.TABLESLUG)
  AND (coalesce(:BODY.FILTERS.OPERATIONCH, '''') = '''' OR operacion = :BODY.FILTERS.OPERATIONCH)
  AND ts >= parseDateTimeBestEffort(if(:BODY.FILTERS.OCCURREDFROM = '''', ''1970-01-01'', :BODY.FILTERS.OCCURREDFROM))
  AND ts <= parseDateTimeBestEffort(if(:BODY.FILTERS.OCCURREDTO = '''', ''2999-12-31'', :BODY.FILTERS.OCCURREDTO))
ORDER BY ts DESC
LIMIT 100;',
    'clickhouse',
    false,
    false,
    'V356 — audits/sessions/{sessionId}/operations (pigse): WHERE pigse.* hardcodeado, mismo shape V90',
    '/audits/sessions/:SESSIONID/operations',
    'SELECT',
    'POST',
    (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse-pigse'),
    '{"PARAM.SESSIONID":"VARCHAR","BODY.FILTERS.TABLESLUG":"VARCHAR","BODY.FILTERS.OPERATIONCH":"VARCHAR","BODY.FILTERS.OCCURREDFROM":"VARCHAR","BODY.FILTERS.OCCURREDTO":"VARCHAR","BODY.SESSIONID":"VARCHAR","BODY.SORTING":"VARCHAR","BODY.PAGEINDEX":"VARCHAR","BODY.PAGESIZE":"VARCHAR"}'
)
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

-- 3.9 — 2.5 /audits/stats (pigse)
-- Idéntica a V90: agregados sobre tsesion_web que es global.
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, detail, path_template, execution_mode, http_method, microservice_id, param_types)
VALUES (
    gen_random_uuid()::text,
    'WITH latest AS (
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
    'clickhouse',
    false,
    false,
    'V356 — audits/stats (pigse): idéntica a V90, agregados sobre tsesion_web global',
    '/audits/stats',
    'SELECT',
    'POST',
    (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse-pigse'),
    '{}'
)
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

-- ---------------------------------------------------------------------------
-- 4. Verificación
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_ceval    BIGINT;
    v_pigse    BIGINT;
    v_ceval_op BIGINT;
    v_pigse_op BIGINT;
    v_leak     TEXT;
BEGIN
    SELECT count(*) FILTER (WHERE q.query LIKE '%academico_test.%'),
           count(*) FILTER (WHERE q.query LIKE '%pigse.%')
      INTO v_ceval, v_pigse
      FROM public.query q
      JOIN public.microservice m ON m.id_microservice = q.microservice_id
     WHERE m.serviceid = 'audit-clickhouse';

    SELECT count(*) FILTER (WHERE q.query LIKE '%pigse.%')
      INTO v_pigse_op
      FROM public.query q
      JOIN public.microservice m ON m.id_microservice = q.microservice_id
     WHERE m.serviceid = 'audit-clickhouse-pigse';

    SELECT count(*) FILTER (WHERE q.query LIKE '%academico_test.%')
      INTO v_ceval_op
      FROM public.query q
      JOIN public.microservice m ON m.id_microservice = q.microservice_id
     WHERE m.serviceid = 'audit-clickhouse-pigse';

    RAISE NOTICE 'V356 audit-clickhouse (CEVAL): queries con academico_test.*=% con pigse.*=% (esperado % y 0)',
        v_ceval, v_pigse, v_ceval_op;
    RAISE NOTICE 'V356 audit-clickhouse-pigse (PIGSE): queries con pigse.*=% (esperado >=5), con academico_test.*=% (esperado 0)',
        v_pigse_op, v_ceval_op;

    IF v_pigse != 0 THEN
        RAISE NOTICE 'V356 ATENCION: el microservicio CEVAL tiene %% filas con pigse.* que no deberia', v_pigse;
    END IF;
    IF v_ceval_op != 0 THEN
        RAISE NOTICE 'V356 ATENCION: el microservicio PIGSE tiene %% filas con academico_test.* que no deberia', v_ceval_op;
    END IF;
END $$;
