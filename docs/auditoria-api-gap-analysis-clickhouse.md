# Gap analysis: ¿ClickHouse soporta los endpoints de `/sections/api-reference` (audits, audit-tables)?

> Fecha: 2026-08-19
> Fuente de la spec: [`colombia-evaluadora/docs`](https://github.com/colombia-evaluadora/docs), `sections/api-reference/{models,audits/*,audit-tables/*}.mdx` (la URL pública `solinces.mintlify.io/...` está detrás de login; se leyó vía `gh api` sobre el repo).
> Fuente del estado actual: esquema real de `auditoria.audit_log` (`db-migrations/cdc-sync/docker/clickhouse/clickhouse-init.sql`), pipeline `cdc-sync` (lectura, sin tocar el repo), y Postgres local (`sso-postgres`, sincronizado con producción vía Flyway — no se consultó la base real).
>
> La spec documenta un **mock**: `audits/operations-query.mdx` lo dice explícito — *"Las operaciones se generan determinísticamente on-the-fly en el mock; en backend real salen de la tabla de auditoría."* Este documento evalúa qué tan lejos está esa "tabla de auditoría" real (ClickHouse) de poder respaldar ese mock.

---

## 1. Resumen ejecutivo

La spec describe **dos features distintas** bajo `/api-reference`:

- **`/audit-tables/*`** — navegar el log de cambios *por tabla de negocio* (qué pasó en `TGRADO`, en `TESTABLECIMIENTO`, etc.), con filtros ad-hoc por campo y **reversión de cambios**.
- **`/audits/*`** — navegar por *sesión de usuario* (qué hizo Ana Pérez desde tal IP entre las 9:15 y las 9:40), con las mismas capacidades de listado/export.

**Veredicto corto**: ClickHouse (`auditoria.audit_log`) puede respaldar el núcleo de `/audit-tables/*` (listar/filtrar/exportar operaciones por tabla) **una vez que la etiqueta/atribución ya en curso** (`fn_audit_declarar`, ver `etiqueta-auditoria-cdc-analisis.md`) se adopte en las funciones de escritura — pero le faltan tres piezas que **no son de ClickHouse, son de catálogo/aplicación**: (1) un mapeo tabla→slug/nombre/ícono/campos-legibles, que no existe en ningún lado hoy; (2) el revert de campos, que requiere una vía de escritura de vuelta a Postgres que hoy no existe; (3) la columna `ip`, que no existe en ningún esquema del sistema (ni Postgres ni ClickHouse). **`/audits/*` (sesiones) no tiene fuente de datos real hoy** — no existe una entidad "sesión de login" con IP/estado/duración en ningún esquema del sistema; lo más cercano (`academico_test.tsesion`) es otra cosa.

---

## 2. Lo que SÍ está resuelto o casi resuelto

| Capacidad de la spec | Columna/mecanismo real | Estado |
|---|---|---|
| `operation` = INSERT/UPDATE/DELETE | `audit_log.operacion` | ⚠️ **existe pero con valores distintos** — ver §4.1 |
| `entityId` | `audit_log.pk` | ✅ ya poblado (primera columna `pk_*` de `fila_new`) |
| `occurredAt` / `occurredFrom` / `occurredTo` | `audit_log.ts`, con índice `minmax` | ✅ eficiente — el filtro de rango es exactamente el caso de uso del índice existente |
| Paginación / conteo total (`pageIndex`, `pageSize`, `totalCount`) | `LIMIT`/`OFFSET` + `count() OVER()` en ClickHouse | ✅ mecánico, sin gap |
| `before` / `after` por campo (`OperationChange`) | `fila_old` / `fila_new` (JSON tipado) | ✅ los datos están; falta lógica de diff (no construida, pero sin gap de capacidad) |
| `entityName` (nombre legible del registro) | `audit_log.etiqueta` (una vez adoptada `fn_audit_declarar` — ver documento hermano) | ⚠️ **la tubería existe, pero hoy llega vacía para el 100% de las filas** — mismo root cause ya diagnosticado: `query-service` nunca setea `app.etiqueta`. Se resuelve adoptando `fn_audit_declarar` en las funciones `fn_*`, no requiere cambios nuevos de esquema. |
| `authorName` | `audit_log.app_user` | ⚠️ misma historia — la resolución de actor legible ya está en `fn_audit_declarar` (V66), falta adoptarla por función. |
| `inserts`/`updates`/`deletes` counts (`TableOperationsStats`) | `count() ... GROUP BY operacion` | ✅ trivial una vez resuelto el mapeo de valores (§4.1) |
| Filtro por rango de tabla + fecha (`WHERE tabla = ? AND ts BETWEEN ? AND ?`) | `ORDER BY (tabla, pk, lsn, seq)` + índice bloom en `tabla` | ✅ el diseño de partición/orden de la tabla ya está pensado para este acceso |

---

## 3. Gaps de catálogo (no son de ClickHouse — falta metadata que no existe en ningún lado)

### 3.1 `AuditTable.slug` / `.name` / `.icon` / `.fields`

La spec asume un catálogo curado de "tablas auditables": `tResultado` → *"Resultado final"*, con un ícono y una lista de **campos legibles** (`["Código", "Nombre", "Descripción"]`). **No existe ese catálogo en ningún lado del sistema** — ni en Postgres, ni en ClickHouse. `audit_log.tabla` guarda el nombre crudo `schema.tabla` de Postgres (p. ej. `academico_test.tgrado`), no un slug curado; y las columnas de `fila_new`/`fila_old` usan los nombres de columna crudos de Postgres (`NOMBRE`, `FK_TNIVEL_ENSENANZA`, mayúsculas, snake_case técnico), no las etiquetas de UI (`"Nombre del grado"`).

**Qué hace falta**: una tabla de catálogo nueva (análoga a `query`/`endpoint` de `sso-admin`) que mapee `tabla_postgres → {slug, nombre_legible, icono, campos: [{columna_cruda, etiqueta_legible}]}`. Es trabajo de aplicación/backend, no de ClickHouse — pero es un prerrequisito real para que `/audit-tables/query`, `/audit-tables/{slug}`, y los `fieldFilters` ad-hoc funcionen tal como los describe la spec.

### 3.2 `entityFields` con nombres de columna legibles

Consecuencia directa de 3.1: `TableOperation.entityFields` y el `showAll=true` de `/operations/{id}/changes` esperan un mapa `{"Código": "PRI-001", "Nombre": "Primaria", ...}`. ClickHouse puede dar los *valores* (vía `fila_new`), pero no las *llaves legibles* — esas salen del catálogo que no existe.

---

## 4. Gaps de datos (la columna no existe o no tiene el valor que la spec espera)

### 4.1 `operation`: los valores no coinciden — **verificado contra el código**

`Operation.java` (cdc-common) define los códigos que Debezium realmente escribe en `audit_log.operacion`:

```java
INSERT("c"), UPDATE("u"), DELETE("d"), SNAPSHOT("r")
```

Es decir, **`audit_log.operacion` guarda literalmente `"c"` / `"u"` / `"d"` / `"r"`**, no `"INSERT"` / `"UPDATE"` / `"DELETE"` como pide el `OperationType` enum de la spec. (El `LEFT(TG_OP,1)` → `'I'/'U'/'D'` que sí usa el trigger es para el mensaje `audit_ctx` de contexto, un campo distinto — no llega a la columna `operacion`.)

**Qué hace falta**: una capa de traducción (`CASE operacion WHEN 'c' THEN 'INSERT' WHEN 'u' THEN 'UPDATE' WHEN 'd' THEN 'DELETE' END`) en la capa que sirva estos endpoints, más una decisión explícita sobre qué hacer con `'r'` (filas de snapshot inicial — probablemente deben excluirse de la vista de auditoría, no son "cambios" hechos por nadie). Trivial de implementar, pero **no está hecho** y hay que decidirlo antes de exponer el endpoint.

### 4.2 `ip` / `authorIp` — no existe en ningún esquema

Se buscó en **todo** el esquema (Postgres local + `audit_log`): ninguna tabla de `academico_test` ni de `public` tiene una columna de IP de origen del request, y `audit_log` tampoco la tiene como columna propia. La única vía teórica sería anidarla dentro de `contexto` (mismo mecanismo usado para `establecimiento`/`sede`, ver `etiqueta-auditoria-cdc-analisis.md` §6.2) — pero eso requiere que **algo la capture primero**, y hoy nada lo hace: `query-service` no construye `app.contexto` (root cause ya diagnosticado), y no hay ningún filtro/aspecto que lea `HttpServletRequest.getRemoteAddr()` en el camino de escritura real. Es un gap de **dos niveles**: falta la captura en origen, y falta el espacio en el esquema para que viaje.

**Qué hace falta**: (a) capturar la IP del request en `query-service` (o en el API Gateway, que ya la ve) y pasarla hasta el punto donde se llama `fn_audit_declarar`; (b) agregar `ip` a lo que se anida en `app.contexto`. Ninguna de las dos cosas existe hoy.

### 4.3 `authorAvatarUrl` / `authorVerified` — sin equivalente conceptual

No hay "avatar" ni "verificado" en el dominio de este sistema (usuarios de un backend académico, no una red social). Lo más cercano a un avatar sería `TUSUARIO.FK_TARCHIVO` (foto de perfil, si está seteada) — pero ese campo no viaja por el pipeline de auditoría en absoluto, y "verificado" no tiene análogo en el dominio (¿verificado por quién, contra qué?). Estos dos campos leen como boilerplate genérico de un template de Mintlify no adaptado todavía a este producto, más que como un requisito real del negocio — vale la pena confirmarlo con quien mantiene esa spec antes de invertir en resolverlos; la recomendación es dejarlos `null`/`false` en una primera implementación real.

---

## 5. Gap estructural: `revert` — no es un gap de ClickHouse, es una feature que no existe

`POST /audit-tables/{slug}/operations/{operationId}/changes/revert` pide **escribir de vuelta** el valor anterior de un campo hacia la tabla origen de Postgres. Esto está completamente fuera de lo que ClickHouse puede o debe hacer — `auditoria.audit_log` es un sumidero analítico de solo-inserción (`ReplacingMergeTree`, alimentado unidireccionalmente por CDC); no tiene, ni debería tener, ningún camino de escritura hacia `academico_test.*`.

Implementarlo de verdad requiere una feature nueva y no trivial:

1. Resolver `operationId` → `{tabla, pk, columna, valor_antes}` (la lectura desde ClickHouse sí es fácil, ver §2).
2. Un endpoint de escritura nuevo — en `query-service` (una fila de catálogo `DML`/`PROCEDURE` por tabla) o una familia de funciones `fn_*_revertir_campo` — que aplique ese `UPDATE` puntual contra Postgres.
3. **Autorización específica**: "revertir cualquier campo de cualquier tabla a un valor histórico" es una capacidad de administrador muy sensible — necesita su propio chequeo de rol, independiente de los permisos de escritura normales de cada módulo (un usuario con permiso para *crear* grados no necesariamente debería poder *revertir* cambios ajenos en `TESTABLECIMIENTO`).
4. El revert en sí mismo **debe auditarse** — entra por el mismo mecanismo (`fn_audit_declarar`) con una etiqueta propia (p. ej. *"Reversión del campo Nombre en el grado Octavo"*), lo que crea una fila nueva en `audit_log`, no modifica la histórica — hay que documentar ese comportamiento (revert = nueva operación, no un borrado del historial) para que el frontend lo represente bien.
5. Validación de que el `before` que se está restaurando sigue teniendo sentido (¿y si otro cambio posterior ya movió una FK a algo que hace inválido el valor a revertir? — la spec ya contempla el concepto de `current` distinto de `after` precisamente por esto, pero no dice qué hace `revert` si `current` no es igual a lo que un usuario vio en pantalla antes de confirmar).

**Nada de esto existe hoy.** Es, en la práctica, un proyecto aparte — no una extensión del trabajo de `fn_audit_declarar`.

---

## 6. `/audits/*` (sesiones): no hay fuente de datos, en ningún lado

Se verificó explícitamente contra el Postgres local:

```sql
-- academico_test.tsesion (única tabla con "sesion" en el nombre en todo el esquema)
pk_tsesion, fk_tusuario, fecha_ingreso, fecha_salida,
hora_ingreso, hora_salida, created_by, created_at, modified_by, modified_at, active
```

No hay columna `ip`. `fecha_ingreso`/`fecha_salida` son `date` (no timestamp) y `hora_ingreso`/`hora_salida` son `varchar` libre — esto tiene forma de **registro de asistencia/jornada** (check-in/check-out), no de sesión de autenticación HTTP con estado `active`/`closed` y `operationsCount`. Tampoco existe ninguna tabla `session`/`token`/`login`/`refresh` en `public` ni en ningún otro schema — el ciclo de vida real de un JWT en `auth-center` no está persistido en una tabla consultable (es plausible que sea JWT sin estado, autocontenido, sin sesión server-side).

Del lado de ClickHouse, `sesion_id` es solo una etiqueta de correlación por fila (`LowCardinality(String)`, sin índice temporal propio de "inicio/fin de sesión") — **y hoy está vacía para el 100% del tráfico**, mismo root cause que `app_user`/`etiqueta`.

**Veredicto**: `/audits/*` completo (sesiones, no operaciones-por-tabla) necesita una entidad de sesión nueva de punta a punta — no es un gap de ClickHouse, es una feature de `auth-center`/`query-service` que no existe. Si el objetivo de negocio es "ver qué hizo Ana Pérez en su sesión de las 9:15", eso hoy solo es reconstruible parcialmente agrupando `audit_log` por `app_user` + rango de tiempo — sin límites claros de "dónde empezó/terminó la sesión", sin IP, y solo una vez que `app_user` esté poblado.

---

## 7. Tabla resumen

| Endpoint | Bloqueadores | ¿Es de ClickHouse? |
|---|---|---|
| `POST /audit-tables/query`, `GET /audit-tables/{slug}` | Catálogo slug/nombre/ícono/campos inexistente (§3.1) | No — falta catálogo de aplicación |
| `POST /audit-tables/{slug}/operations/query` | `entityName`/`authorName` vacíos hoy (se resuelve adoptando `fn_audit_declarar`); `operation` con valores `c/u/d/r` no `INSERT/UPDATE/DELETE` (§4.1); `ip` no existe (§4.2); `fieldFilters`/`entityFields` necesitan el catálogo de campos (§3.2) | Parcial — atribución sí es de ClickHouse (ya en curso); catálogo e IP no |
| `GET /audit-tables/{slug}/operations/{id}/changes` | Diff `before/after/current` no construido (dato disponible, falta lógica); catálogo de campos para labels | Parcial |
| `POST /audit-tables/{slug}/operations/{id}/changes/revert` | **Feature de escritura completa, inexistente** (§5) | No — es un proyecto aparte |
| `POST /audit-tables/{slug}/operations/stats` | Mapeo de `operation` (§4.1) | Sí, trivial una vez resuelto |
| `POST/GET .../export*` | Generación de PDF/Excel es capa de aplicación, no de ClickHouse; depende de que el resto de datos ya estén resueltos | No — capa de aplicación |
| `/audits/*` (todo el árbol: query, get-session, stats, operations, export) | **No existe la entidad "sesión"** en ningún esquema (§6); `sesion_id`/`ip` vacíos | No — falta la fuente de datos completa |

---

## 8. Qué SÍ recomendaría priorizar (si esta spec es la hoja de ruta real)

1. **Adoptar `fn_audit_declarar`** en las 67 funciones `fn_*` (ya diseñado, no implementado) — desbloquea `entityName`/`authorName` para `/audit-tables/*`, la parte más cercana a estar lista.
2. **Mapear `operacion` c/u/d/r → INSERT/UPDATE/DELETE** en la capa de servicio que exponga estos endpoints (trivial, no hecho).
3. **Diseñar el catálogo de tablas auditables** (slug/nombre/ícono/campos-legibles) — es el bloqueador que toca más endpoints (`/audit-tables/query`, `/audit-tables/{slug}`, `fieldFilters`, `entityFields`).
4. **Decidir qué hacer con `/audits/*` (sesiones)** antes de construirlo — o se define una entidad de sesión real (auth-center empieza a persistir login/logout + IP), o se reformula esa parte de la spec para trabajar sobre agrupaciones de `audit_log` por `app_user`/rango de fecha en vez de una sesión con ciclo de vida propio.
5. **`revert` queda para el final** — es la pieza de mayor riesgo (escritura arbitraria a producción) y la que menos reutiliza lo que ya existe.
