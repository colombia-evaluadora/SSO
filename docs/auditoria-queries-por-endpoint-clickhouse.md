# Queries SELECT por endpoint — `/audit-tables/*` y `/audits/*` contra ClickHouse

> Fecha: 2026-08-21. Complementa `auditoria-api-gap-analysis-clickhouse.md` (léelo primero — este
> documento asume su veredicto y su actualización del 21-ago) y `auditoria-endpoints-cheatsheet.md`
> si existe una versión más nueva. Fuente de la spec: `colombia-evaluadora/docs`,
> `sections/api-reference/{audit-tables,audits}/*.mdx` (leído vía `gh api` el mismo día).
>
> Objetivo: para cada endpoint de la spec, la query ClickHouse real que produce (o aproxima, cuando
> no hay forma exacta) el shape de respuesta documentado — usando el esquema **actual** de
> `auditoria.audit_log` (incluye `client_ip`, `headers`, `request_body`, `fila_new_raw`,
> `fila_old_raw` — todas agregadas en esta misma rama). Pensadas para vivir como filas de catálogo
> `public.query` (`type='clickhouse'`) de una instancia `query-service` dedicada — ver
> "§9.1 — instancia ClickHouse-only" del gap-analysis para cómo se prueba esto en la práctica.
>
> Convención de placeholders: `:PARAM.X` (path), `:BODY.X` (body JSON), `:QUERY.X` (query string) —
> la misma que usa el resto del catálogo de este sistema, no la sintaxis nativa `{x:Type}` de
> ClickHouse.
>
> **Recordatorio del hallazgo de la sesión anterior**: ClickHouse exige que `LIMIT`/`OFFSET` sean
> literales constantes en el texto SQL — `LIMIT :QUERY.SIZE` falla con `Code: 440`. Todas las
> queries de este documento que paginan usan un `LIMIT` fijo como placeholder de lo que
> **debería** ser `:QUERY.SIZE`/`:QUERY.OFFSET`; resolver esto de verdad (interpolar un entero
> validado como literal, no bindearlo) es trabajo pendiente, marcado con 🔶 donde aplica.

**Leyenda de estado:**
- ✅ **Directo** — el SELECT de abajo produce el shape exacto de la spec con los datos actuales.
- ⚠️ **Requiere catálogo o aproximación** — el SELECT funciona pero depende de algo que no existe
  en ClickHouse (el catálogo de tablas auditables) o aproxima un concepto que no está modelado
   (sesión de usuario).
- ❌ **No resoluble con SELECT** — escritura, generación de archivos, u otro tipo de operación.

---

## Parte 1 — `/audit-tables/*`

### 1.1 `POST /audit-tables/query` — listar tablas auditadas ⚠️

**El bloqueador real**: `slug`/`name`/`icon`/`fields` no existen en ningún esquema (ver §3.1 del
gap-analysis). La query de abajo asume un catálogo — la forma más simple de tenerlo sin construir
una tabla nueva es un `CTE` con los valores como literales, mantenido a mano. Es sostenible mientras
la lista de tablas auditables no cambie seguido; si empieza a crecer, migrar esto a una tabla real
(`public.audit_table_catalog` en Postgres, gestionada como cualquier otro catálogo de `sso-admin`) y
unir contra ella en vez de hardcodearla.

```sql
WITH catalogo AS (
    SELECT * FROM (
        SELECT 'academico_test.tarea' AS tabla_real, 'tArea' AS slug,
               'Área' AS name, 'BookOpen-Icon' AS icon,
               ['Nombre', 'Código', 'Orden de reportes'] AS fields
        UNION ALL
        SELECT 'academico_test.tgrado', 'tGrado', 'Grado', 'GraduationCap-Icon',
               ['Nombre', 'Nivel', 'Jornada']
        UNION ALL
        SELECT 'academico_test.testablecimiento', 'tEstablecimiento', 'Establecimiento', 'Bank-Icon',
               ['Nombre', 'Código DANE', 'Dirección']
        -- ... una fila por cada tabla auditable real; ver
        -- docs/etiqueta-catalogo-funciones-fn.md para la lista completa de
        -- tablas que hoy tienen fn_audit_declarar adoptado.
    )
)
SELECT
    c.slug,
    c.name,
    c.icon,
    countIf(a.tabla = c.tabla_real AND toDate(a.ts) = today() AND a.operacion != 'r') AS operationsToday,
    c.fields
FROM catalogo c
LEFT JOIN auditoria.audit_log a ON a.tabla = c.tabla_real
WHERE positionCaseInsensitive(c.name, :BODY.FILTERS.NAME) > 0  -- omitir el WHERE si filters.name viene vacío
GROUP BY c.slug, c.name, c.icon, c.fields
ORDER BY c.name  -- o operationsToday, según :BODY.SORTING[0].id/.desc
LIMIT 10;  -- 🔶 debería ser :QUERY.SIZE — ver nota de LIMIT/OFFSET arriba
```

`pageCount`/`totalCount` requieren una segunda pasada (o `count() OVER()` sobre el `SELECT` sin el
`LIMIT`, igual que en 1.3) contando filas del `catalogo` filtrado — trivial una vez resuelto el
`LIMIT`.

### 1.2 `GET /audit-tables/{slug}` — detalle de una tabla ⚠️

Mismo catálogo, una sola fila:

```sql
WITH catalogo AS ( /* igual que 1.1 */ )
SELECT
    c.slug,
    c.name,
    c.icon,
    countIf(a.tabla = c.tabla_real AND toDate(a.ts) = today() AND a.operacion != 'r') AS operationsToday,
    c.fields
FROM catalogo c
LEFT JOIN auditoria.audit_log a ON a.tabla = c.tabla_real
WHERE c.slug = :PARAM.SLUG
GROUP BY c.slug, c.name, c.icon, c.fields;
```

Si la fila viene vacía → `404 "Tabla no encontrada."` (lo resuelve la capa de servicio, no la query).

### 1.3 `POST /audit-tables/{slug}/operations/query` — listar operaciones de una tabla ✅ (con matices)

Directo para todos los campos salvo `entityFields` (necesita saber qué columnas raw le corresponden
a cada label del catálogo) y `authorAvatarUrl`/`authorVerified` (sin equivalente — `null`/`false`
siempre, per §4.3 del gap-analysis).

```sql
SELECT
    concat(toString(lsn), '-', toString(seq)) AS id,      -- identidad de operación: ver §1.4
    CASE operacion
        WHEN 'c' THEN 'INSERT'
        WHEN 'u' THEN 'UPDATE'
        WHEN 'd' THEN 'DELETE'
    END AS operation,
    app_user AS authorName,
    NULL AS authorAvatarUrl,                                -- sin equivalente en el dominio (§4.3)
    false AS authorVerified,                                 -- sin equivalente en el dominio (§4.3)
    toString(client_ip) AS ip,
    etiqueta AS entityName,
    pk AS entityId,
    ts AS occurredAt,
    -- entityFields: snapshot ACTUAL (no el de esta operación) de los
    -- campos del catálogo, tomado de la última operación conocida sobre
    -- esta misma fila (ver §1.4 para el mismo truco con argMax).
    map(
        'Nombre', (SELECT argMax(JSONExtractString(fila_new_raw, 'nombre'), ts)
                    FROM auditoria.audit_log WHERE tabla = :PARAM.TABLA_REAL AND pk = a.pk),
        'Código', (SELECT argMax(JSONExtractString(fila_new_raw, 'codigo'), ts)
                    FROM auditoria.audit_log WHERE tabla = :PARAM.TABLA_REAL AND pk = a.pk)
        -- una entrada por cada campo declarado en AuditTable.fields
    ) AS entityFields
FROM auditoria.audit_log AS a
WHERE tabla = :PARAM.TABLA_REAL
  AND operacion != 'r'
  -- filters.author (nombre O ip, "contains")
  AND (:BODY.FILTERS.AUTHOR = '' OR positionCaseInsensitive(app_user, :BODY.FILTERS.AUTHOR) > 0
                                  OR positionCaseInsensitive(toString(client_ip), :BODY.FILTERS.AUTHOR) > 0)
  -- filters.operations (mapear INSERT/UPDATE/DELETE -> c/u/d ANTES de bindear, en la capa Java)
  AND (:BODY.FILTERS.OPERATIONS_CH = '' OR operacion IN (:BODY.FILTERS.OPERATIONS_CH))
  -- filters.occurredFrom / occurredTo
  AND (:BODY.FILTERS.OCCURRED_FROM = '' OR ts >= parseDateTimeBestEffort(:BODY.FILTERS.OCCURRED_FROM))
  AND (:BODY.FILTERS.OCCURRED_TO = ''   OR ts <= parseDateTimeBestEffort(:BODY.FILTERS.OCCURRED_TO))
  -- filters.fieldFilters[] (AND entre todos) — un JSONExtractString por campo, condición aplicada
  -- en la capa que arma el SQL (contains -> positionCaseInsensitive, equals -> =, startsWith -> startsWith)
  AND positionCaseInsensitive(JSONExtractString(fila_new_raw, 'nombre'), :BODY.FIELDFILTER_NOMBRE) > 0
ORDER BY
    -- sorting[0].id: occurredAt->ts, operation->operacion, authorIp->authorName (así lo pide la
    -- spec — "orden por authorName" aunque el id se llame authorIp), detail->etiqueta
    ts DESC
LIMIT 25;  -- 🔶 debería ser :QUERY.SIZE OFFSET :QUERY.OFFSET
```

`pageCount`/`totalCount`: agregar `count() OVER() AS totalCount` al `SELECT` (funciona bien en
ClickHouse, confirmado en la sesión anterior) y calcular `pageCount = ceil(totalCount / pageSize)`
en la capa de servicio.

### 1.4 `GET /audit-tables/{slug}/operations/{operationId}/changes` ✅

**Decisión de diseño**: `operationId` se define como `"{lsn}-{seq}"` — la misma identidad que ya usa
`POST /audit/revert` (fase 1, `sso-admin`). Consistente con el resto del sistema, no requiere una
tabla de mapeo nueva.

```sql
WITH op AS (
    SELECT tabla, pk, operacion, etiqueta, fila_new_raw, fila_old_raw, ts
    FROM auditoria.audit_log
    WHERE lsn = :PARAM.LSN AND seq = :PARAM.SEQ
    ORDER BY ts DESC LIMIT 1
),
-- "current": ClickHouse SÍ puede aproximarlo sin tocar Postgres — es el
-- valor del campo en la operación MÁS RECIENTE sobre la misma fila,
-- que puede ser distinta de la operación que se está inspeccionando si
-- hubo cambios posteriores (justo el caso que la spec dice que puede
-- pasar). argMax(valor, ts) = "el valor de la fila con el ts más alto".
current_vals AS (
    SELECT
        argMax(JSONExtractString(fila_new_raw, 'nombre'), ts) AS nombre_actual,
        argMax(JSONExtractString(fila_new_raw, 'codigo'), ts) AS codigo_actual
        -- una columna por cada campo del catálogo de esta tabla
    FROM auditoria.audit_log
    WHERE tabla = (SELECT tabla FROM op) AND pk = (SELECT pk FROM op) AND operacion != 'r'
)
SELECT
    concat(:PARAM.LSN, '-', :PARAM.SEQ) AS operationId,
    CASE op.operacion WHEN 'c' THEN 'INSERT' WHEN 'u' THEN 'UPDATE' WHEN 'd' THEN 'DELETE' END AS operation,
    op.etiqueta AS entityName,
    op.pk AS entityId,
    2 AS totalFields,  -- cantidad de campos declarados en el catálogo para esta tabla
    -- changedFields: contar cuántos de los pares before/after difieren
    (JSONExtractString(op.fila_old_raw, 'nombre') != JSONExtractString(op.fila_new_raw, 'nombre'))
  + (JSONExtractString(op.fila_old_raw, 'codigo') != JSONExtractString(op.fila_new_raw, 'codigo'))
    AS changedFields,
    [
        (0, 'Nombre',
            nullIf(JSONExtractString(op.fila_old_raw, 'nombre'), ''),
            nullIf(JSONExtractString(op.fila_new_raw, 'nombre'), ''),
            nullIf(current_vals.nombre_actual, '')),
        (1, 'Código',
            nullIf(JSONExtractString(op.fila_old_raw, 'codigo'), ''),
            nullIf(JSONExtractString(op.fila_new_raw, 'codigo'), ''),
            nullIf(current_vals.codigo_actual, ''))
        -- una tupla (fieldIndex, field, before, after, current) por campo del catálogo
    ] AS changes
FROM op, current_vals;
```

Con `?showAll=false` (el default), filtrar `changes` en la capa de servicio a solo las tuplas donde
`before != after`. `fieldIndex` es simplemente la posición del campo en la lista del catálogo — el
cliente lo devuelve tal cual al llamar `/revert`, así que **debe ser estable entre requests**
(depende de que el orden del catálogo de campos no cambie, no de nada calculado por fila).

### 1.5 `POST /audit-tables/{slug}/operations/{operationId}/changes/revert` ❌

No es un `SELECT` — es la única operación de escritura de todo el árbol `/audit-tables/*`. Fuera de
alcance de este documento por definición. El sistema ya tiene una fase 1 real y funcionando
(`AuditRevertService`, `sso-admin`), pero **limitada al patrón soft-delete/soft-restore** (toggle de
`active`) — revertir un campo arbitrario como pide este endpoint (`changes[].fieldIndex` → cualquier
columna) es la extensión natural pero no está construida: necesitaría, por cada `fieldIndex`,
resolver `field → columna_real` (vía el mismo catálogo de 1.1) y generar un
`UPDATE tabla SET columna_real = :valor_viejo WHERE pk = :pk` dentro de la misma transacción que ya
usa `AuditRevertService` para el `set_config` de contexto — mecánicamente parecido a lo que ya
existe, solo generalizado a "cualquier columna" en vez de "solo `active`".

### 1.6 `POST /audit-tables/{slug}/operations/stats` ✅

Mismos filtros que 1.3 (o, si viene `ids`, filtrar por la lista de `lsn-seq` en vez de por fecha/autor):

```sql
SELECT
    countIf(operacion = 'c') AS inserts,
    countIf(operacion = 'u') AS updates,
    countIf(operacion = 'd') AS deletes
FROM auditoria.audit_log
WHERE tabla = :PARAM.TABLA_REAL
  AND operacion != 'r'
  -- mismos filtros de autor/rango/fieldFilters que 1.3, si no viene `ids`
  -- si viene `ids` (lista de "lsn-seq"): AND (lsn, seq) IN (:BODY.IDS_PARSED)
;
```

### 1.7 `POST /audit-tables/{slug}/operations/export` y `/export-all` ❌ (parcialmente ✅)

La generación de PDF/Excel es capa de aplicación (no de ClickHouse) — pero la query que **alimenta**
el export es exactamente la de 1.3 (con `ids` en vez de filtros, para la variante no-`-all`):

```sql
-- export: filtra por la lista explícita de operaciones elegidas
SELECT /* mismas columnas que 1.3 */
FROM auditoria.audit_log
WHERE tabla = :PARAM.TABLA_REAL AND (lsn, seq) IN (:BODY.IDS_PARSED);

-- export-all: exactamente la query de 1.3, sin el LIMIT/OFFSET (todas las filas filtradas)
```

---

## Parte 2 — `/audits/*` (sesiones)

**Advertencia que aplica a TODO este bloque**: no existe una entidad "sesión de autenticación HTTP"
en ningún esquema (§6 del gap-analysis, sigue sin resolver). Las queries de abajo
**aproximan** una sesión agrupando filas de `audit_log` por `app_user` con un corte quieto ("gap") de
inactividad — es una heurística de sessionization, no datos reales de login/logout. Etiquetadas ⚠️
en cada caso; `id` de sesión es sintético (`app_user + índice de sesión`), no corresponde a nada que
`auth-center` conozca.

### 2.1 CTE base de sessionization (reutilizado por todos los endpoints de esta sección)

```sql
WITH ordenado AS (
    SELECT
        app_user,
        client_ip,
        ts,
        -- 30 minutos de inactividad = nueva "sesión". Umbral arbitrario,
        -- ajustar según lo que el negocio considere razonable.
        if(dateDiff('minute',
                     lagInFrame(ts) OVER (PARTITION BY app_user ORDER BY ts),
                     ts) > 30, 1, 0) AS es_sesion_nueva
    FROM auditoria.audit_log
    WHERE app_user != '' AND operacion != 'r'
),
sesionado AS (
    SELECT
        app_user,
        client_ip,
        ts,
        sum(es_sesion_nueva) OVER (PARTITION BY app_user ORDER BY ts
                                    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS sesion_seq
    FROM ordenado
)
SELECT
    concat(app_user, '-', toString(sesion_seq)) AS id,
    app_user AS authorName,
    NULL AS authorAvatarUrl,          -- sin equivalente (§4.3)
    false AS authorVerified,          -- sin equivalente (§4.3)
    toString(any(client_ip)) AS ip,   -- IP del primer evento de la sesión aproximada
    min(ts) AS startedAt,
    max(ts) AS endedAt,
    if(now() - max(ts) < INTERVAL 30 MINUTE, 'active', 'closed') AS status,
    count() AS operationsCount
FROM sesionado
GROUP BY app_user, sesion_seq
```

### 2.2 `POST /audits/query` — listar sesiones ⚠️

La CTE de 2.1 + filtros:

```sql
WITH ordenado AS ( /* igual que 2.1 */ ), sesionado AS ( /* igual que 2.1 */ )
SELECT
    concat(app_user, '-', toString(sesion_seq)) AS id,
    app_user AS authorName,
    NULL AS authorAvatarUrl,
    false AS authorVerified,
    toString(any(client_ip)) AS ip,
    min(ts) AS startedAt,
    max(ts) AS endedAt,
    if(now() - max(ts) < INTERVAL 30 MINUTE, 'active', 'closed') AS status,
    count() AS operationsCount
FROM sesionado
GROUP BY app_user, sesion_seq
HAVING
  (:BODY.FILTERS.AUTHOR = '' OR positionCaseInsensitive(authorName, :BODY.FILTERS.AUTHOR) > 0
                              OR positionCaseInsensitive(ip, :BODY.FILTERS.AUTHOR) > 0)
  AND (:BODY.FILTERS.STATUS = '' OR status IN (:BODY.FILTERS.STATUS))
  AND (:BODY.FILTERS.STARTED_FROM = '' OR startedAt >= parseDateTimeBestEffort(:BODY.FILTERS.STARTED_FROM))
  AND (:BODY.FILTERS.STARTED_TO   = '' OR startedAt <= parseDateTimeBestEffort(:BODY.FILTERS.STARTED_TO))
ORDER BY startedAt DESC   -- o duration = endedAt - startedAt, o operationsCount, según sorting[0]
LIMIT 25;  -- 🔶 debería ser :QUERY.SIZE OFFSET :QUERY.OFFSET
```

### 2.3 `GET /audits/sessions/{sessionId}` ⚠️

`sessionId` = `"{app_user}-{sesion_seq}"` (el `id` sintético de 2.1). Se parsea en la capa de
servicio y se filtra directo, sin necesidad de recorrer todo `audit_log` de todos los usuarios:

```sql
WITH ordenado AS (
    SELECT ts, client_ip,
           if(dateDiff('minute', lagInFrame(ts) OVER (ORDER BY ts), ts) > 30, 1, 0) AS es_sesion_nueva
    FROM auditoria.audit_log
    WHERE app_user = :PARAM.APP_USER AND operacion != 'r'   -- parseado de sessionId
),
sesionado AS (
    SELECT ts, client_ip,
           sum(es_sesion_nueva) OVER (ORDER BY ts ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS sesion_seq
    FROM ordenado
)
SELECT
    :PARAM.SESSION_ID AS id,
    :PARAM.APP_USER AS authorName,
    NULL AS authorAvatarUrl,
    false AS authorVerified,
    toString(any(client_ip)) AS ip,
    min(ts) AS startedAt,
    max(ts) AS endedAt,
    if(now() - max(ts) < INTERVAL 30 MINUTE, 'active', 'closed') AS status,
    count() AS operationsCount
FROM sesionado
WHERE sesion_seq = :PARAM.SESION_SEQ   -- parseado de sessionId
GROUP BY sesion_seq;
```

Si no hay filas → `404 "Sesión no encontrada."`.

### 2.4 `POST /audits/sessions/{sessionId}/operations` ⚠️

Una vez resuelto el rango `[startedAt, endedAt]` de la sesión (2.3), es una consulta directa sobre
`audit_log` — esta parte SÍ es sólida, es exactamente 1.3 sin agrupar por tabla:

```sql
SELECT
    concat(toString(lsn), '-', toString(seq)) AS id,
    tabla AS tableSlug,   -- crudo (academico_test.tarea); mapear a slug legible vía el catálogo de 1.1
    CASE operacion WHEN 'c' THEN 'INSERT' WHEN 'u' THEN 'UPDATE' WHEN 'd' THEN 'DELETE' END AS operation,
    etiqueta AS entityName,
    pk AS entityId,
    ts AS occurredAt
FROM auditoria.audit_log
WHERE app_user = :PARAM.APP_USER
  AND ts BETWEEN :PARAM.SESSION_STARTED_AT AND :PARAM.SESSION_ENDED_AT  -- del lookup de 2.3
  AND operacion != 'r'
  AND (:BODY.FILTERS.TABLE_SLUG = '' OR tabla = :BODY.FILTERS.TABLE_SLUG_REAL)
  AND (:BODY.FILTERS.OPERATIONS_CH = '' OR operacion IN (:BODY.FILTERS.OPERATIONS_CH))
ORDER BY ts DESC
LIMIT 25;  -- 🔶 debería ser :QUERY.SIZE OFFSET :QUERY.OFFSET
```

### 2.5 `POST /audits/stats` ⚠️

```sql
WITH ordenado AS ( /* igual que 2.1 */ ), sesionado AS ( /* igual que 2.1 */ ),
sesiones AS (
    SELECT app_user, sesion_seq, min(ts) AS startedAt, max(ts) AS endedAt, count() AS ops
    FROM sesionado GROUP BY app_user, sesion_seq
)
SELECT
    countIf(toDate(startedAt) = today()) AS sessionsToday,
    countIf(now() - endedAt < INTERVAL 30 MINUTE) AS activeSessions,
    sumIf(ops, toDate(startedAt) = today()) AS operationsToday
FROM sesiones;
```

### 2.6 `POST /audits/export` y `/export-all`, `POST /audits/sessions/{id}/operations/export` ❌ (parcialmente ✅)

Igual que 1.7 — la generación de archivo es capa de aplicación; la query que alimenta el export es
2.2 (sesiones) o 2.4 (operaciones de una sesión) sin `LIMIT`.

---

## Resumen — qué tan lejos llega ClickHouse solo, hoy

| Bloque | Estado real |
|---|---|
| `/audit-tables/*/operations/*` (query, stats, changes) | ✅ **Sólido** — todos los campos disponibles, incluida una aproximación razonable de `current` vía `argMax` |
| `/audit-tables/query`, `GET /audit-tables/{slug}` | ⚠️ Funciona, pero depende de un catálogo tabla→slug/nombre/ícono/campos que no existe — la CTE literal de 1.1 es un parche, no una solución definitiva |
| `/audit-tables/.../revert` | ❌ Escritura — fuera de alcance de "queries SELECT" por definición |
| `/audits/*` (todo el árbol) | ⚠️ Todas las queries **corren** y devuelven el shape correcto, pero sobre una sesión **sintética** (heurística de inactividad de 30 min sobre `app_user`) — no hay forma de que sean "correctas" hasta que exista una entidad de sesión real en `auth-center` |
| Pendiente transversal | 🔶 `LIMIT`/`OFFSET` deben ser literales en ClickHouse — toda paginación de arriba necesita esto resuelto antes de ser un catálogo real |

---

## Actualización (2026-08-21, más tarde) — implementado y probado como migraciones reales

Las 9 queries "✅ sólido"/"⚠️ funciona" de arriba (1.1, 1.2, 1.3, 1.4, 1.6, 2.2, 2.3, 2.4, 2.5 — todo
excepto `revert` y los `export*`, que no son SELECT) se implementaron como migraciones Flyway reales
(`postgres/migrations/V84`-`V87`) y se probaron end-to-end contra una instancia real de
`query-service` en modo ClickHouse — no solo en papel. Validado con un ciclo completo de
borrar-todo → reaplicar V84→V87 → confirmar los 9 endpoints en `200`, simulando lo que un ambiente
nuevo vería.

**Bugs reales encontrados escribiendo el SQL de verdad** (ninguno visible solo leyendo la spec o
razonando en abstracto — todos salieron de ejecutar contra ClickHouse real, versión 24.8.14.39):

1. **`audit_log.tabla` NO lleva prefijo de schema.** Es `tarea`, no `academico_test.tarea` — un
   drift entre lo que dice `CONTRATO_SP_CLICKHOUSE.md` y lo que el pipeline realmente escribe, ya
   detectado en una sesión anterior pero que igual se me volvió a colar al escribir el catálogo
   literal de tablas (§1.1/§1.2 del cuerpo de este documento usan el nombre correcto ya
   corregido). Costó `operationsToday: 0` en todas las tablas hasta que se corrigió.

2. **ClickHouse NO hace short-circuit de `OR`.** `(x = '' OR parseDateTimeBestEffort(x) >= ts)`
   revienta con `CANNOT_PARSE_DATETIME`/`CANNOT_CONVERT_TYPE` cuando `x` es `''` o `NULL`, porque
   ClickHouse evalúa **ambos** lados del `OR` siempre — a diferencia de Postgres, donde ese patrón
   es idiomático y seguro. Fix real: envolver el argumento con `if(x = '', '<sentinela>', x)` para
   que la función que puede fallar NUNCA reciba un valor inválido, en vez de confiar en que el
   `OR` "salve" el caso vacío. Aplicado a todos los filtros de rango de fecha.

3. **`CAST(NULL, 'tipo')` es ilegal contra un tipo no-nullable — y es lo que genera
   `SqlRewriter` cuando un placeholder con `paramType` declarado se bindea `NULL`.** Pasa cuando el
   caller **omite por completo** una key opcional del body en vez de mandarla como string vacío —
   `ParamBinder` bindea `NULL` para el placeholder declarado-pero-ausente, y `CAST(NULL, 'varchar')`
   truena con `Cannot convert NULL to a non-nullable type` sin importar qué lo envuelva (ni
   siquiera `coalesce()` lo salva, porque el `CAST` en sí mismo es lo que falla, antes de que
   `coalesce` reciba nada). **Contrato resultante**: el caller de estos endpoints debe mandar
   **todas** las keys declaradas de `filters`, aunque sea con string vacío — omitirlas hace que el
   catálogo actual falle. Alternativa no explorada: no declarar `paramType` para esas keys (cae al
   auto-derive de Spring) — pero eso reabre el guard V49 de "placeholder sin tipo declarado" para
   cualquier key que el caller SÍ mande.

4. **Cualquier key presente en el body de la petición necesita `paramType` declarado, la use o no
   el SQL de esa fila.** El guard V49 de query-service itera **todo** `allParams` (no solo lo que
   aparece en el texto SQL) — un body 100%-spec-compliant que manda `sorting`/`pageIndex`/
   `pageSize`/`tableSlug` (campos que estas queries simplificadas no usan) los rechaza con 400 si
   no están en `param_types`, aunque la query nunca los referencie. Se declaran igual, con
   `VARCHAR` como tipo — como no se bindean en ningún placeholder del SQL, el tipo declarado no
   importa funcionalmente, solo necesita **existir**.

5. **ClickHouse no soporta subconsultas correlacionadas fila-a-fila** (`"Resolve identifier 'a1.x'
   from parent scope only supported for constants and CTE"`) — el patrón Postgres de
   `(SELECT ... FROM t2 WHERE t2.col = t1.col)` dentro de un `SELECT ... FROM t1` no funciona igual.
   Fix (1.4): materializar la fila de interés en un CTE de una sola fila, y referenciarlo con
   subconsultas escalares `(SELECT campo FROM cte)` en vez de un alias correlacionado — eso SÍ está
   permitido ("constants and CTE").

6. **`now()` (`DateTime`, precisión de segundo) y una columna `DateTime64(3, 'UTC')` no se pueden
   restar directamente** — `now() - max(ts)` truena con `Illegal types DateTime and DateTime64(3,
   'UTC') of arguments of function minus`. Fix: `dateDiff('minute', max(ts), now()) < 30` en vez de
   `now() - max(ts) < INTERVAL 30 MINUTE` — mismo resultado, sin el choque de tipos.

7. **La autorización del catálogo (`role_query`) tarda hasta ~60s en propagarse** después de
   insertar una fila nueva — hay una capa de caché en `sso-admin` (`QueryCatalogService`, TTL corto
   pero no instantáneo) que sigue sirviendo "no autorizado" un rato después de que la fila ya existe
   en la base. No es un bug, pero cuesta tiempo real de iteración si no se sabe — cada ciclo de
   prueba de este documento necesitó ese margen.

**Migración nueva, `V87`**: sin una fila `role_query` explícita, TODAS estas queries responden 403 a
cualquier caller — el catálogo no tiene bypass implícito ni para ADMIN. `V87` las vincula a
`CEVAL-SUPER_ADMINISTRADOR` como punto de partida deliberadamente angosto (el histórico completo de
auditoría es información sensible); a quién más darle acceso es una decisión de producto, no técnica.
