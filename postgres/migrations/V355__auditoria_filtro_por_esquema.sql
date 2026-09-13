-- ============================================================================
-- V355 — discriminador PIGSE/CEVAL en la UI de "Registro de actividad" sin
--        agregar columna nueva en ClickHouse.
--
-- POR QUE NO UNA COLUMNA
--   Las dos apps NO comparten tablas a nivel lógico: PIGSE escribe
--   exclusivamente contra `pigse.*` y Colombia Evaluadora exclusivamente
--   contra `academico_test.*`. La columna `tabla` en `auditoria.audit_log`
--   ya viene como `<schema>.<tabla>` (ver fn_audit_ctx: concatena
--   TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME), así que el prefijo del
--   esquema ES el discriminador que ya está grabado. Agregar una columna
--   `app` redundante introduce un segundo punto de verdad que puede
--   desincronizarse del schema y, peor, abre la puerta a que en el
--   futuro una mutación cross-schema se reporte con la app equivocada.
--
-- QUE AGREGA ESTA MIGRACION
--   1. CTE `catalogo` en /audit-tables/query (1.1 de V85) expone el
--      schema de cada tabla como columna propia. El front compone el
--      `slug` como `<schema>-t<NombreAlgoritmico>` para disambiguar
--      tablas con el mismo nombre en esquemas distintos (hoy solo
--      `pigse.tfuncionario` vs `academico_test.tfuncionario`; mañana
--      puede haber más).
--   2. Fórmula inversa slug -> tabla en 1.3/1.6 (V85) actualizada para
--      parsear el prefijo de schema y devolver `<schema>.<tabla>`.
--   3. Filtro `:BODY.FILTERS.SCHEMA` opcional agregado a las queries
--      que pueden mostrar tablas mezcladas entre esquemas:
--        - /audit-tables/query (1.1)            — listar tablas
--        - /audit-tables/{slug}/operations/query (1.3) — ops de una tabla
--        - /audit-tables/{slug}/operations/stats (1.6) — agregados de tabla
--        - /audits/sessions/{id}/operations (2.4)      — drill-down sesión
--      Se traduce a `WHERE tabla LIKE :BODY.FILTERS.SCHEMA || '.%'`
--      cuando viene no vacío; vacío = sin filtro (comportamiento actual).
--   4. La sesión 2.2 ya agrupaba por app_user (no por tabla), así que
--      el schema NO se filtra a nivel de sesión sino de operación:
--      una sesión puede contener mutaciones en ambos esquemas. El
--      drill-down 2.4 sí filtra operaciones por schema. 2.2 queda
--      intacta.
--
-- RETROCOMPATIBILIDAD
--   - Slugs V85 (sin prefijo de schema, ej. `tfuncionario`) se siguen
--     aceptando: si no contienen '-', se asumen academico_test (legacy).
--     El front debe migrar a la nueva forma, pero los bookmarks
--     guardados durante el rollout no rompen.
--   - Filtro schema vacío = comportamiento idéntico a V85/V86.
--   - Filas existentes en `public.query` se actualizan con `UPDATE`
--     idempotente (busca por path_template + http_method + microservice).
--     No se duplican gracias a la unicidad que V85/V86 ya enforzaron
--     (UNIQUE sobre (microservice_id, path_template, http_method)
--     WHERE path_template IS NOT NULL).
--
-- POR QUE EN V355 Y NO V85.1 O V85_FOLLOWUP
--   La convención del repo es seguir numerando (V85 -> V86 -> ... ->
--   V354 -> V355+). Renombrar V85 introduce riesgo de checksum mismatch
--   en Flyway (todos los servidores ya tienen V85 marcada como aplicada).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1.1 — /audit-tables/query con columna schema y filtro opcional
-- ---------------------------------------------------------------------------
UPDATE public.query
SET query = 'WITH catalogo AS (
    SELECT
        schema,
        tabla_real,
        concat(schema, ''-'', ''t'', arrayStringConcat(arrayMap(w -> concat(upper(substring(w,1,1)), lower(substring(w,2))), splitByChar(''_'', substring(tabla_real, 2))), '''')) AS slug,
        arrayStringConcat(arrayMap(w -> concat(upper(substring(w,1,1)), lower(substring(w,2))), splitByChar(''_'', substring(tabla_real, 2))), '' '') AS name,
        ''Table-Icon'' AS icon
    FROM (SELECT DISTINCT schema, tabla AS tabla_real
          FROM (
              -- Extrae schema y tabla del campo `tabla` (formato
              -- `schema.tabla`) emitido por fn_audit_ctx. ClickHouse no
              -- tiene splitPart nativo equivalente, pero extract con
              -- regex sirve y es consistente con 2.3.
              SELECT
                  extract(tabla, ''^([^.]+)\.(.+)$'') AS schema,
                  extract(tabla, ''^([^.]+)\.(.+)$'', 2) AS tabla
              FROM auditoria.audit_log
              WHERE tabla LIKE ''%\.%''
          ) parsed
          WHERE schema != '''' AND tabla_real != '''')
)
SELECT
    c.slug,
    c.schema AS schema,
    c.name,
    c.icon,
    countIf(a.tabla = (c.schema || ''.'' || c.tabla_real) AND toDate(a.ts) = today() AND a.operacion != ''r'') AS operationsToday,
    count() OVER() AS totalCount
FROM catalogo c
LEFT JOIN auditoria.audit_log a ON a.tabla = (c.schema || ''.'' || c.tabla_real)
WHERE (coalesce(:BODY.FILTERS.SCHEMA, '''') = '''' OR c.schema = :BODY.FILTERS.SCHEMA)
  AND (coalesce(:BODY.FILTERS.NAME, '''') = '''' OR positionCaseInsensitive(c.name, :BODY.FILTERS.NAME) > 0)
GROUP BY c.slug, c.schema, c.name, c.icon
ORDER BY c.name
LIMIT 100;',
    param_types = '{"BODY.FILTERS.SCHEMA":"VARCHAR","BODY.FILTERS.NAME":"VARCHAR","BODY.SORTING":"VARCHAR","BODY.PAGEINDEX":"VARCHAR","BODY.PAGESIZE":"VARCHAR"}'
WHERE path_template = '/audit-tables/query'
  AND http_method = 'POST'
  AND microservice_id = (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse');

-- ---------------------------------------------------------------------------
-- 1.2 — /audit-tables/{slug} con schema derivado del slug
-- ---------------------------------------------------------------------------
UPDATE public.query
SET query = 'WITH catalogo AS (
    SELECT
        schema,
        tabla_real,
        concat(schema, ''-'', ''t'', arrayStringConcat(arrayMap(w -> concat(upper(substring(w,1,1)), lower(substring(w,2))), splitByChar(''_'', substring(tabla_real, 2))), '''')) AS slug,
        arrayStringConcat(arrayMap(w -> concat(upper(substring(w,1,1)), lower(substring(w,2))), splitByChar(''_'', substring(tabla_real, 2))), '' '') AS name,
        ''Table-Icon'' AS icon
    FROM (SELECT DISTINCT schema, tabla AS tabla_real
          FROM (SELECT extract(tabla, ''^([^.]+)\.(.+)$'') AS schema,
                       extract(tabla, ''^([^.]+)\.(.+)$'', 2) AS tabla
                FROM auditoria.audit_log WHERE tabla LIKE ''%\.%'') parsed
          WHERE schema != '''' AND tabla_real != '''')
)
SELECT
    c.slug,
    c.schema AS schema,
    c.name,
    c.icon,
    countIf(a.tabla = (c.schema || ''.'' || c.tabla_real) AND toDate(a.ts) = today() AND a.operacion != ''r'') AS operationsToday
FROM catalogo c
LEFT JOIN auditoria.audit_log a ON a.tabla = (c.schema || ''.'' || c.tabla_real)
WHERE c.slug = :PARAM.SLUG
GROUP BY c.slug, c.schema, c.name, c.icon;',
    param_types = '{"PARAM.SLUG":"VARCHAR"}'
WHERE path_template = '/audit-tables/:SLUG'
  AND http_method = 'GET'
  AND microservice_id = (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse');

-- ---------------------------------------------------------------------------
-- 1.3 — /audit-tables/{slug}/operations/query
-- Fórmula slug -> tabla: separar el primer segmento como schema, el resto
-- es el nombre de tabla algorítmico. Si el slug no contiene '-' se asume
-- academico_test (legacy, retrocompatible con V85).
-- ---------------------------------------------------------------------------
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
-- Fórmula slug -> tabla con prefijo de schema (V355):
--   * contiene ''-'' -> primera mitad = schema, resto = nombre de tabla
--     algorítmico (igual que V85 pero con t<...> delante).
--   * NO contiene ''-'' -> retrocompat con V85: schema = academico_test.
--     El replaceRegexpAll pasa el slug (''tFuncionario'' -> ''t_funcionario'')
--     y concat(''t'', substring(lower(...), 2)) reconstruye ''tfuncionario''.
WHERE tabla = if(position(:PARAM.SLUG, ''-'') > 0,
    concat(extract(:PARAM.SLUG, ''^([^-]+)-(.*)$''),
           ''.'',
           concat(''t'', substring(lower(replaceRegexpAll(extract(:PARAM.SLUG, ''^([^-]+)-(.*)$'', 2), ''([A-Z])'', ''_\1'')), 2))),
    concat(''academico_test.'',
           concat(''t'', substring(lower(replaceRegexpAll(substring(:PARAM.SLUG, 2), ''([A-Z])'', ''_\1'')), 2)))
)
  AND operacion != ''r''
  AND (coalesce(:BODY.FILTERS.AUTHOR, '''') = '''' OR positionCaseInsensitive(app_user, :BODY.FILTERS.AUTHOR) > 0
                                   OR positionCaseInsensitive(toString(client_ip), :BODY.FILTERS.AUTHOR) > 0)
  AND (coalesce(:BODY.FILTERS.OPERATIONCH, '''') = '''' OR operacion = :BODY.FILTERS.OPERATIONCH)
  AND ts >= parseDateTimeBestEffort(if(:BODY.FILTERS.OCCURREDFROM = '''', ''1970-01-01'', :BODY.FILTERS.OCCURREDFROM))
  AND ts <= parseDateTimeBestEffort(if(:BODY.FILTERS.OCCURREDTO = '''', ''2999-12-31'', :BODY.FILTERS.OCCURREDTO))
ORDER BY ts DESC
LIMIT 100;',
    param_types = '{"PARAM.SLUG":"VARCHAR","BODY.FILTERS.AUTHOR":"VARCHAR","BODY.FILTERS.OPERATIONCH":"VARCHAR","BODY.FILTERS.OCCURREDFROM":"VARCHAR","BODY.FILTERS.OCCURREDTO":"VARCHAR","BODY.TABLESLUG":"VARCHAR","BODY.SORTING":"VARCHAR","BODY.PAGEINDEX":"VARCHAR","BODY.PAGESIZE":"VARCHAR"}'
WHERE path_template = '/audit-tables/:SLUG/operations/query'
  AND http_method = 'POST'
  AND microservice_id = (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse');

-- ---------------------------------------------------------------------------
-- 1.6 — /audit-tables/{slug}/operations/stats (misma fórmula que 1.3)
-- ---------------------------------------------------------------------------
UPDATE public.query
SET query = 'SELECT
    countIf(operacion = ''c'') AS inserts,
    countIf(operacion = ''u'') AS updates,
    countIf(operacion = ''d'') AS deletes
FROM auditoria.audit_log
WHERE tabla = if(position(:PARAM.SLUG, ''-'') > 0,
    concat(extract(:PARAM.SLUG, ''^([^-]+)-(.*)$''),
           ''.'',
           concat(''t'', substring(lower(replaceRegexpAll(extract(:PARAM.SLUG, ''^([^-]+)-(.*)$'', 2), ''([A-Z])'', ''_\1'')), 2))),
    concat(''academico_test.'',
           concat(''t'', substring(lower(replaceRegexpAll(substring(:PARAM.SLUG, 2), ''([A-Z])'', ''_\1'')), 2)))
)
  AND operacion != ''r''
  AND ts >= parseDateTimeBestEffort(if(:BODY.FILTERS.OCCURREDFROM = '''', ''1970-01-01'', :BODY.FILTERS.OCCURREDFROM))
  AND ts <= parseDateTimeBestEffort(if(:BODY.FILTERS.OCCURREDTO = '''', ''2999-12-31'', :BODY.FILTERS.OCCURREDTO));',
    param_types = '{"PARAM.SLUG":"VARCHAR","BODY.FILTERS.OCCURREDFROM":"VARCHAR","BODY.FILTERS.OCCURREDTO":"VARCHAR"}'
WHERE path_template = '/audit-tables/:SLUG/operations/stats'
  AND http_method = 'POST'
  AND microservice_id = (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse');

-- ---------------------------------------------------------------------------
-- 2.2 — /audits/query (sesiones): filtro schema a nivel de app_user no
-- tiene sentido (un usuario opera en ambos esquemas durante la misma
-- sesión). El drill-down 2.4 sí filtra operaciones por schema.
-- Mantenemos 2.2 sin cambios de shape; solo anotamos el caveat.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 2.4 — /audits/sessions/{sessionId}/operations: agrega filtro schema
-- SINTO la heurística V86 de app_user/extract. Esa forma quedó
-- obsoleta cuando V90 introdujo sesiones REALES con sesion_id =
-- family_id (UUID). V355 parte del shape de V90 y solo agrega la
-- columna `schema` (columna calculada de tabla) y el filtro
-- :BODY.FILTERS.SCHEMA. No tocar el WHERE sobre sesion_id.
-- ---------------------------------------------------------------------------
UPDATE public.query
SET query = 'SELECT
    concat(toString(lsn), ''-'', toString(seq)) AS id,
    tabla AS tableSlug,
    extract(tabla, ''^([^.]+)\.(.+)$'') AS schema,
    CASE operacion WHEN ''c'' THEN ''INSERT'' WHEN ''u'' THEN ''UPDATE'' WHEN ''d'' THEN ''DELETE'' ELSE ''SNAPSHOT'' END AS operation,
    etiqueta AS entityName,
    pk AS entityId,
    ts AS occurredAt,
    count() OVER() AS totalCount
FROM auditoria.audit_log
WHERE sesion_id = :PARAM.SESSIONID
  AND operacion != ''r''
  AND (coalesce(:BODY.FILTERS.SCHEMA, '''') = '''' OR tabla LIKE concat(:BODY.FILTERS.SCHEMA, ''.%''))
  AND (coalesce(:BODY.FILTERS.TABLESLUG, '''') = '''' OR tabla = :BODY.FILTERS.TABLESLUG)
  AND (coalesce(:BODY.FILTERS.OPERATIONCH, '''') = '''' OR operacion = :BODY.FILTERS.OPERATIONCH)
  AND ts >= parseDateTimeBestEffort(if(:BODY.FILTERS.OCCURREDFROM = '''', ''1970-01-01'', :BODY.FILTERS.OCCURREDFROM))
  AND ts <= parseDateTimeBestEffort(if(:BODY.FILTERS.OCCURREDTO = '''', ''2999-12-31'', :BODY.FILTERS.OCCURREDTO))
ORDER BY ts DESC
LIMIT 100;',
    param_types = '{"PARAM.SESSIONID":"VARCHAR","BODY.FILTERS.SCHEMA":"VARCHAR","BODY.FILTERS.TABLESLUG":"VARCHAR","BODY.FILTERS.OPERATIONCH":"VARCHAR","BODY.FILTERS.OCCURREDFROM":"VARCHAR","BODY.FILTERS.OCCURREDTO":"VARCHAR","BODY.SESSIONID":"VARCHAR","BODY.SORTING":"VARCHAR","BODY.PAGEINDEX":"VARCHAR","BODY.PAGESIZE":"VARCHAR"}'
WHERE path_template = '/audits/sessions/:SESSIONID/operations'
  AND http_method = 'POST'
  AND microservice_id = (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse');
