-- =============================================================================
-- V132 — /audit-tables/{slug}/operations/query deja de pedirle a ClickHouse dos
--        columnas que su tabla no tiene.
--
-- SINTOMA
--   POST /api/audit-ch/audit-tables/tActividadNota/operations/query -> 500:
--
--     Code: 47. DB::Exception: Unknown expression or function identifier
--     'client_ip' in scope SELECT concat(toString(lsn), '-', ...
--
-- CAUSA
--   La fila selecciona `client_ip` y `fila_new_raw`. El DESCRIBE real de
--   auditoria.audit_log no tiene ninguna de las dos:
--
--     lsn, seq, xid, tabla, operacion, pk, fila_new, fila_old, tabla_origen,
--     estado, latencia_ms, snapshot, app_user, db_user, sesion_id, familia,
--     request_id, etiqueta, contexto, ts
--
--   * No hay columna de IP. El unico candidato seria `contexto`, pero hoy
--     viene vacio en las 6.8M de filas replicadas, asi que no hay dato que
--     mapear: la fila devuelve NULL y el front ya lo tolera
--     (`use-table-operations-query.ts` hace `row.ip ?? ""`).
--   * El snapshot de la fila esta en `fila_new`, de tipo JSON. El nombre
--     `fila_new_raw` corresponde a una forma anterior del sink; hoy el
--     equivalente es `toJSONString(fila_new)`, que es exactamente lo que
--     `entityFieldsRaw` espera (JSON crudo, parseado en el cliente por
--     `real-mapping.ts`).
--
--   El filtro por autor tambien buscaba dentro de la IP; sin columna, esa
--   rama se cae y queda el match por `app_user`, que es el unico dato de
--   autor que existe.
--
-- Se reescribe la fila entera en vez de parchear con replace() para que quede
-- legible que este es el SQL vigente. Idempotente por definicion.
-- =============================================================================

UPDATE public.query
   SET query = $sql$SELECT
    concat(toString(lsn), '-', toString(seq)) AS id,
    CASE operacion WHEN 'c' THEN 'INSERT' WHEN 'u' THEN 'UPDATE' WHEN 'd' THEN 'DELETE' ELSE 'SNAPSHOT' END AS operation,
    app_user AS authorName,
    NULL AS authorAvatarUrl,
    false AS authorVerified,
    -- audit_log no replica la IP del cliente (V132). El front pinta "" cuando
    -- llega NULL, asi que la columna se conserva en el contrato de salida.
    NULL AS ip,
    etiqueta AS entityName,
    pk AS entityId,
    ts AS occurredAt,
    toJSONString(fila_new) AS entityFieldsRaw,
    count() OVER() AS totalCount
FROM auditoria.audit_log
-- Fórmula inversa slug -> tabla (ver comentario de cabecera): inserta
-- '_' antes de cada mayúscula del slug (sin contar la primera),
-- minúscula, y antepone 't'.
WHERE tabla = concat('t', substring(lower(replaceRegexpAll(substring(:PARAM.SLUG, 2), '([A-Z])', '_\1')), 2))
  AND operacion != 'r'
  AND (coalesce(:BODY.FILTERS.AUTHOR, '') = ''
       OR positionCaseInsensitive(app_user, :BODY.FILTERS.AUTHOR) > 0)
  AND (coalesce(:BODY.FILTERS.OPERATIONCH, '') = '' OR operacion = :BODY.FILTERS.OPERATIONCH)
  -- ClickHouse NO hace short-circuit de OR (a diferencia de Postgres) --
  -- evalúa ambos lados siempre, así que "x = '' OR parseDateTimeBestEffort(x)"
  -- revienta en CANNOT_PARSE_DATETIME cuando x es '' aunque el primer
  -- lado sea true. Se evita pasándole SIEMPRE un string parseable
  -- (el filtro real, o un sentinela que hace el rango un no-op).
  AND ts >= parseDateTimeBestEffort(if(:BODY.FILTERS.OCCURREDFROM = '', '1970-01-01', :BODY.FILTERS.OCCURREDFROM))
  AND ts <= parseDateTimeBestEffort(if(:BODY.FILTERS.OCCURREDTO = '', '2999-12-31', :BODY.FILTERS.OCCURREDTO))
ORDER BY ts DESC
LIMIT 100;$sql$
 WHERE path_template = '/audit-tables/:SLUG/operations/query'
   AND http_method = 'POST';
