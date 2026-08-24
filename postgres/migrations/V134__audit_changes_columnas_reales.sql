-- =============================================================================
-- V134 — /audit-tables/{slug}/operations/{operationId}/changes deja de pedir
--        columnas que no existen.
--
-- Mismo defecto que arreglo V132 para el listado de operaciones, en el ultimo
-- endpoint de la coleccion de Postman que quedaba sin verificar: la fila
-- selecciona `fila_old_raw` y `fila_new_raw`, y auditoria.audit_log tiene
-- `fila_old` y `fila_new`, ambas de tipo JSON. El nombre con sufijo `_raw`
-- corresponde a una forma anterior del sink.
--
-- El contrato de salida no cambia: beforeRaw/afterRaw/currentRaw siguen siendo
-- JSON crudo —ahora via toJSONString(...)— que es lo que el front parsea en
-- `real-mapping.ts`.
--
-- Nota sobre currentRaw: filtra `operacion != 'r'`, o sea que ignora las filas
-- de snapshot a proposito (busca el ultimo cambio real sobre esa fila). Con el
-- backlog actual —todo snapshot— devuelve NULL, que es correcto: todavia no ha
-- habido ningun cambio posterior que mostrar.
-- =============================================================================

UPDATE public.query
   SET query = $sql$WITH op AS (
    SELECT tabla, pk, operacion, etiqueta, fila_old, fila_new
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
    (SELECT toJSONString(fila_old) FROM op) AS beforeRaw,
    (SELECT toJSONString(fila_new) FROM op) AS afterRaw,
    -- "current": la operación MÁS RECIENTE conocida sobre la misma fila
    -- (misma tabla+pk) — puede diferir de afterRaw si hubo cambios
    -- posteriores a esta operación, exactamente el caso que la spec
    -- dice que puede pasar. No requiere tocar Postgres.
    (SELECT argMax(toJSONString(fila_new), ts) FROM auditoria.audit_log
      WHERE tabla = (SELECT tabla FROM op) AND pk = (SELECT pk FROM op) AND operacion != 'r') AS currentRaw;$sql$
 WHERE path_template = '/audit-tables/:SLUG/operations/:OPERATIONID/changes';
