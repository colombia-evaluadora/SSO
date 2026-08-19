# Análisis: dónde generar la `etiqueta` de auditoría (query-service ↔ cdc-sync ↔ ClickHouse)

> Fecha: 2026-08-19 (actualizado el mismo día con introspección directa contra la base real)
> Alcance: `SSO/query-service`, `db-migrations/cdc-sync`, `SSO/postgres/migrations` (funciones `academico_test.fn_*`).
> Pregunta que responde: *¿dónde se debe generar el valor de la columna `auditoria.audit_log.etiqueta` para que el equipo de soporte identifique de inmediato "qué pasó y a quién" sin cruzar IDs a mano?*
>
> **Ver también**: [`etiqueta-catalogo-funciones-fn.md`](etiqueta-catalogo-funciones-fn.md) — catálogo función-por-función (las 67 funciones de escritura realmente desplegadas en `172.233.184.248`, no solo las que aparecen en los archivos de migración) con la etiqueta propuesta para cada una. Corrige un supuesto de este documento: **no existe hoy un módulo de notas/calificaciones** en el catálogo de funciones desplegado — los ejemplos de "calificación de Luis Rafael Puello" de aquí son ilustrativos del patrón, no una función real; la función real más cercana en espíritu es `fn_asignacion_guardar` (asignación docente–materia–grupo).
>
> **Alcance de la implementación**: el trabajo de código de Postgres (helper `fn_audit_declarar`, adopción en `fn_grado_*`) vive en `SSO` (rama `feat/etiqueta-auditoria-cdc`, base `origin/dev`). El pipeline `cdc-sync` (Debezium → RabbitMQ → cdc-worker → ClickHouse) inicialmente **no se tocó** por instrucción explícita — hasta que la prueba end-to-end (§11) encontró un bug preexistente en `cdc-capture` que bloqueaba toda la iniciativa, momento en el que se autorizó explícitamente corregirlo (§11.5). `app.user_id`, `app.etiqueta` y `app.contexto` son columnas/GUCs que ya existían de punta a punta (§1); establecimiento/sede/etiquetas de categorización se anidan dentro de `app.contexto` (que ya viaja sin filtrar) en vez de pedir columnas ClickHouse nuevas — ver §6.2. Toda validación de SQL en este documento se hizo contra el **Postgres local de Docker** (`sso-postgres`, esquema sincronizado vía Flyway con el mismo `postgres/migrations/`), nunca contra la base de 172.233.184.248.
>
> **✅ Resuelto (§11.5)**: la prueba end-to-end encontró que `cdc-capture` ignoraba el 100% de los mensajes `audit_ctx` desde siempre (bug de nombre de clave — `"data"` vs el `"content"` real de Debezium — verificado descompilando el JAR real de `debezium-connector-postgres`, no por prueba y error). Corregido y **validado end-to-end con la imagen reconstruida**: la comparación antes/después en `auditoria.audit_log` confirma `app_user`/`etiqueta`/`contexto` llegando poblados. Hallazgo adicional: `db-migrations/cdc-sync` no es lo que se despliega — SSO tiene su propia copia vendorizada en `cdc-sync/` que es la que `deploy-test.yml` realmente construye y publica; el fix se aplicó ahí.

---

## 1. Resumen ejecutivo

El campo `etiqueta` **ya existe de punta a punta** — en el esquema de ClickHouse, en el envelope CDC, en el trigger de Postgres y en el pipeline del `cdc-worker`. No hay que diseñar tubería nueva. El problema no es de esquema, es que **nadie lo llena**:

- `query-service` — el único camino de escritura real de este sistema hoy — nunca setea las GUCs `app.user_id` / `app.contexto` / `app.request_id` / `app.etiqueta` que el trigger `trg_audit_ctx` lee. Resultado: **el 100% de las filas de auditoría que se originan en `query-service` llegan a ClickHouse con `app_user=''`, `sesion_id=''`, `etiqueta=''`**, no solo la etiqueta.
- El patrón de referencia que sí llena esas GUCs (`AuditContextAspect` en `db-migrations/api/`) pertenece a una app-demo distinta (`com.demo.api`, dominio "clientes/pedidos"), no a `query-service`.
- Las 52 funciones de escritura `academico_test.fn_*_crear/actualizar/soft_delete` que sí ejecuta `query-service` en producción **ya reciben la identidad del actor como parámetro normal** (`p_pk_usuario_solicitante`) y **ya tienen en variables locales los datos legibles del negocio** (nombre del grado, del estudiante, de la materia, etc.) en el momento exacto en que hacen el `INSERT`/`UPDATE`. Ese es el lugar más barato y más correcto para construir la etiqueta — no `query-service` (genérico, no conoce semántica de negocio) ni el `cdc-worker` (solo ve columnas crudas y FKs, que es justo lo que se quiere evitar).

**Recomendación**: generar la etiqueta **dentro de cada función `fn_*` de escritura**, con `PERFORM set_config('app.etiqueta', ..., true)` justo antes del DML, usando los datos que la función ya validó/joineó. En paralelo, arreglar la atribución de actor (`app.user_id`) con el mismo mecanismo — reutiliza `p_pk_usuario_solicitante`, que ya está en la firma de todas estas funciones — porque hoy esa columna también llega vacía y es un problema más grave que la etiqueta misma.

---

## 2. Mapa arquitectónico verificado

```
Cliente (front / admin-ui)
   │  POST /query, /service, /serviceFit, /write, o ruta por QueryPathRegistry
   ▼
query-service (SSO/query-service)
   │  QueryController / WriteController
   │  → QueryService.execute() / WriteService.execute()
   │  → catalog.fetchQuery()/fetchWrite() resuelve uuid → SQL/CALL desde sso-admin
   │  → NamedParameterJdbcTemplate.execute()/update() UNA sola sentencia
   │    (SELECT fn_x(...), CALL sp_x(...), o INSERT/UPDATE crudo en modo DML)
   │  → :CONTEXT.USER_ID / :CONTEXT.EMAIL / :CONTEXT.ROLES se bindean como
   │    PARÁMETROS SQL normales (NO como GUCs de sesión — ver §3)
   ▼
PostgreSQL — academico_test.*
   │  la función fn_* hace su INSERT/UPDATE/DELETE
   │  dispara trg_audit_ctx (BEFORE STATEMENT, una vez por sentencia)
   │  trg_audit_ctx lee current_setting('app.user_id'|'app.contexto'|
   │    'app.request_id'|'app.etiqueta', true) y hace
   │    pg_logical_emit_message('audit_ctx', json)  -- transaccional
   ▼
WAL (slot cdc_slot, plugin pgoutput, REPLICA IDENTITY FULL)
   ▼
cdc-capture (Debezium embebido)
   │  AmqpPublisher: op='m' (audit_ctx) → AuditContextCache.put(xid, ctx)
   │  op='c'/'u'/'d' → ctxCache.take(xid) → adjunta {payload, routing_key, context}
   ▼
RabbitMQ
   ▼
cdc-worker
   │  AmqpConsumer → PipelineExecutor
   │  ├─ ClickHouseAuditStage → INSERT auditoria.audit_log (incluye etiqueta)
   │  └─ OracleReverseStage   → MERGE academico.X (espejo Oracle, opcional)
   ▼
ClickHouse auditoria.audit_log
   columnas: app_user, db_user, sesion_id, familia, request_id, etiqueta, contexto, ...
```

Archivos que sustentan cada salto (ya existen, sin cambios pendientes de infraestructura):

| Salto | Archivo |
|---|---|
| Trigger emisor | [`postgres/migrations/V26__context-emitter.sql`](../postgres/migrations/V26__context-emitter.sql) (= `cdc-sync/docker/postgres/04-context-emitter.sql`) |
| Cache de correlación por `xid` | `cdc-sync/cdc-capture/.../AuditContextCache.java` |
| Publicación a Rabbit | `cdc-sync/cdc-capture/.../AmqpPublisher.java` |
| Envelope tipado | `cdc-sync/cdc-common/.../CdcEvent.java` (`Context.etiqueta` ya existe) |
| Mapeo a fila CH | `cdc-sync/cdc-worker/.../pipeline/AuditRecord.java` + `ClickHouseAuditStage.java` |
| DDL ClickHouse | `cdc-sync/docker/clickhouse/clickhouse-init.sql` — columna `etiqueta String` ya declarada |
| Contrato documentado | `cdc-sync/docs/CONTRATO_SP_CLICKHOUSE.md` |

## 3. La causa raíz: `query-service` no participa del contrato de contexto

`CONTRATO_SP_CLICKHOUSE.md` describe dos formas válidas de inyectar contexto (`SET LOCAL` explícito, o un aspect tipo `AuditContextAspect`). **Ninguna de las dos está implementada en `query-service`.**

Evidencia:

- `WriteService.execute()` ([`WriteService.java:78`](../../SSO/query-service/src/main/java/com/co/eurekatic/query/write/WriteService.java)) construye `INSERT`/`UPDATE` y llama `jdbc.update(sql, params)` directo. Cero `set_config`, cero `SET LOCAL`, cero `@Transactional`.
- `QueryService.doExecute()` ([`QueryService.java:142`](../../SSO/query-service/src/main/java/com/co/eurekatic/query/read/QueryService.java)) inyecta identidad vía `injectContextParams()` — pero como **parámetros de bind SQL** (`:CONTEXT.USER_ID`, `:CONTEXT.EMAIL`, `:CONTEXT.ROLES`), no como GUCs de sesión. El trigger `fn_audit_ctx()` no lee parámetros de bind — lee `current_setting('app.*')`. Son dos mecanismos distintos y no se tocan.
- No hay ningún `@Transactional`, `PlatformTransactionManager` ni `TransactionTemplate` en `query-service/src/main/java` (grep vacío). Cada `jdbc.execute()`/`jdbc.update()` es una sola sentencia top-level — importante para el diseño de la solución (§5).
- El único código del monorepo que sí llama `set_config('app.user_id'|'app.contexto'|'app.etiqueta'|'app.request_id', ...)` es `AuditContextAspect.java` en `db-migrations/api/api/...` — que es una app de referencia con dominio de juguete (`clientes`/`pedidos`, paquete `com.demo.api`), **no** `query-service`.

**Consecuencia medible**: hoy, para cualquier fila que `auditoria.audit_log` reciba con `tabla` empezando en `academico_test.*`, se puede asumir `app_user=''`, `sesion_id=''`, `familia=''`, `request_id=''`, `etiqueta=''` — el 100%, no una fracción. La query de diagnóstico §9.2.A del contrato (`WHERE app_user=''`) lo confirmaría en caliente contra la base real si se quiere verificar antes de tocar código.

## 4. Dónde SÍ hay datos de negocio disponibles: las funciones `fn_*`

`query-service` no ejecuta SQL ad-hoc contra tablas — ejecuta funciones catalogadas en `sso-admin` con `executionMode = PROCEDURE | FUNCTION | DML`. El patrón dominante (127 funciones `academico_test.fn_*` en `postgres/migrations`, 52 con forma de escritura — `crear`/`actualizar`/`soft_delete`/`bulk_delete`/`guardar`) ya sigue una convención consistente. Ejemplo real, [`V43__grade_module.sql:81-137`](../postgres/migrations/V43__grade_module.sql) (`fn_grado_actualizar`):

```sql
CREATE OR REPLACE FUNCTION academico_test.fn_grado_actualizar(
    p_pk BIGINT, p_fk_nivel BIGINT DEFAULT NULL, p_nombre VARCHAR(130) DEFAULT NULL,
    ..., p_pk_usuario_solicitante BIGINT DEFAULT NULL
) RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    r academico_test.TGRADO;
    v_nombre VARCHAR(130);
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    ...
    SELECT * INTO r FROM academico_test.TGRADO WHERE PK_TGRADO = p_pk AND ACTIVE = TRUE;
    ...
    v_nombre := COALESCE(p_nombre, r.NOMBRE);   -- ← el nombre "humano" YA está en una variable
    ...
    UPDATE academico_test.TGRADO SET NOMBRE = v_nombre, ..., MODIFIED_BY = v_audit ...
     WHERE PK_TGRADO = p_pk;
    RETURN p_pk;
END; $$;
```

Dos hechos clave de este patrón, verificados en 15 funciones que ya usan `p_pk_usuario_solicitante` y 10 con el `v_audit` local:

1. **El actor ya llega como parámetro normal** — no como GUC. `query-service` ya lo bindea (típicamente desde `:CONTEXT.USER_ID` o un id resuelto). No hace falta tocar `query-service` para tener el actor disponible dentro de la función.
2. **Los datos legibles del negocio ya están en variables locales antes del DML** — `r.NOMBRE`, `v_nombre`, y en otras funciones (`fn_est_actualizar`, `fn_fun_actualizar`, etc.) el nombre del estudiante/funcionario/materia sale de un `SELECT ... INTO` que la función igual necesita para validar. Construir la etiqueta ahí es **gratis** en términos de I/O — no hay un JOIN adicional que pagar.

Comparar con las otras dos opciones:

| Capa candidata | ¿Conoce "quién actuó"? | ¿Conoce el "qué" en términos de negocio? | Costo de obtenerlo |
|---|---|---|---|
| `query-service` (§3) | Sí (JWT) | **No** — es un proxy catálogo-genérico; el SQL es texto opaco para él | Tendría que parsear el SQL o mantener metadata paralela por `uuid` — fragil y duplica lo que el SP ya sabe |
| Función `fn_*` (recomendado) | Sí (`p_pk_usuario_solicitante`, ya en la firma) | **Sí** — ya hizo el `SELECT`/`JOIN` para validar | Cero — reutiliza variables ya pobladas |
| `cdc-worker` (post-hoc) | Parcial (`app_user` si llegara poblado) | **No** — solo ve `before`/`after` con columnas y FKs crudos | Alto: tendría que reabrir conexión a Postgres/Oracle por cada evento para resolver cada FK a nombre — exactamente el anti-patrón que la etiqueta busca eliminar, y además la fila padre pudo cambiar entre el evento y la resolución |

La tabla confirma la intuición del punto 4 del pedido del usuario ("el desarrollador, al programar el método de guardado, define qué capturar") — el "método de guardado" de este sistema **es la función `fn_*`**, no un service Java.

## 5. Por qué el mecanismo funciona sin tocar `query-service`

`pg_logical_emit_message(true, ...)` es transaccional y el trigger es `BEFORE STATEMENT`. Cuando `query-service` ejecuta `SELECT academico_test.fn_grado_actualizar(...)` como una única sentencia top-level (confirmado en §3 — no hay `@Transactional` envolvente, cada llamada JDBC es su propia transacción implícita), **esa única sentencia es también la transacción completa de la función**: todo lo que la función hace adentro —`PERFORM set_config(..., true)`, el `UPDATE`, el trigger, el logical message— vive en el mismo commit implícito. No hay problema de "otra conexión" ni de "orden del aspecto" (la trampa que sí aplica al patrón `AuditContextAspect`, porque ahí el `SET LOCAL` y el DML corren en llamadas JDBC separadas dentro de un `@Transactional` de Spring). Aquí todo es una sola llamada a función — el caso más simple del contrato.

Esto significa: **la solución no requiere ningún cambio en `query-service`, `cdc-capture`, `cdc-worker` ni en el esquema de ClickHouse.** Es enteramente un cambio en las 52 funciones `fn_*` de escritura (más las que se agreguen a futuro).

## 6. Diseño recomendado

### 6.1 Convención de dos líneas al inicio de cada función de escritura

```sql
CREATE OR REPLACE FUNCTION academico_test.fn_grado_actualizar(...)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    r academico_test.TGRADO;
    v_nombre VARCHAR(130);
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    ...
    SELECT * INTO r FROM academico_test.TGRADO WHERE PK_TGRADO = p_pk AND ACTIVE = TRUE;
    IF NOT FOUND THEN RAISE EXCEPTION ...; END IF;
    v_nombre := COALESCE(p_nombre, r.NOMBRE);
    ...

    -- ↓ NUEVO — atribución + etiqueta, justo antes del DML, misma transacción.
    PERFORM set_config('app.user_id', p_pk_usuario_solicitante::TEXT, true);
    PERFORM set_config('app.etiqueta',
        format('Actualización del grado: %s', v_nombre), true);

    UPDATE academico_test.TGRADO SET NOMBRE = v_nombre, ..., MODIFIED_BY = v_audit ...
     WHERE PK_TGRADO = p_pk;
    RETURN p_pk;
END; $$;
```

Ejemplos calcados de los que pidió el usuario, con datos que las funciones análogas ya tienen en variables:

```sql
-- fn_est_crear (estudiante) — v_nombre_completo ya se construye para el INSERT
PERFORM set_config('app.etiqueta',
    format('Creación del estudiante %s', v_nombre_completo), true);

-- fn_fun_soft_delete (funcionario) — r.NOMBRE viene del SELECT de validación
PERFORM set_config('app.etiqueta',
    format('Eliminación del funcionario %s', r.NOMBRE), true);

-- una función de notas/calificaciones (si existe hoy o a futuro) — patrón:
PERFORM set_config('app.etiqueta',
    format('Modificación de la calificación de %s en %s', v_nombre_estudiante, v_nombre_materia),
    true);
```

### 6.2 Helper `fn_audit_declarar` — implementado (V66, rama `feat/etiqueta-auditoria-cdc`)

El trigger ya trunca a 200 caracteres (`LEFT(NULLIF(current_setting('app.etiqueta', true), ''), 200)`), así que no hace falta truncar en cada SP. La versión implementada resuelve tres cosas en una sola llamada — no solo la etiqueta:

1. **Actor legible** (`app.user_id`) — `p_usuario_id` es el PK numérico de `TUSUARIO`, no un nombre; el helper lo resuelve a nombre completo (o correo, o cuenta, en ese orden) con un único `JOIN`, centralizado aquí en vez de repetido en cada una de las ~67 funciones. Sin esto, `app_user` en ClickHouse quedaría como un ID crudo — el mismo problema que la etiqueta busca eliminar, trasladado del "qué" al "quién".
2. **Etiqueta principal** (`app.etiqueta`) — el texto de negocio, sin cambios respecto al diseño original.
3. **Establecimiento / sede / etiquetas de categorización** — *no* son columnas dedicadas en ClickHouse hoy (eso requeriría tocar el esquema y el pipeline Java de `db-migrations/cdc-sync`, fuera de alcance de este cambio — ver nota debajo). Se anidan dentro de `app.contexto`, que **ya viaja completa y sin filtrar por todo el pipeline existente** sin tocar una sola línea de `db-migrations` (el trigger la embebe tal cual con `'contexto': v_ctx`, y del lado Java `CdcEvent.Context.contexto` es un `Map<String,Object>` genérico en cada etapa, no una lista fija de claves). Quedan disponibles hoy mismo vía `JSONExtractString(contexto, 'establecimiento')` en ClickHouse, sin índice dedicado — la promoción a columnas propias (`LowCardinality` + bloom filter, igual que `familia`/`sesion_id`) queda como trabajo de seguimiento explícito sobre `db-migrations/cdc-sync`, no parte de esta pasada.

```sql
CREATE OR REPLACE FUNCTION academico_test.fn_audit_declarar(
    p_usuario_id         BIGINT,
    p_etiqueta           TEXT,
    p_establecimiento_id BIGINT DEFAULT NULL,
    p_sede_id            BIGINT DEFAULT NULL,
    p_etiquetas          TEXT[] DEFAULT NULL
) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_actor TEXT; v_establecimiento TEXT; v_sede TEXT;
    v_ctx_existente JSONB; v_ctx_nuevo JSONB;
BEGIN
    IF p_usuario_id IS NOT NULL THEN
        SELECT COALESCE(
                   NULLIF(TRIM(concat_ws(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
                                          u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO)), ''),
                   u.CORREO_ELECTRONICO, u.CUENTA)
          INTO v_actor FROM academico_test.TUSUARIO u WHERE u.PK_TUSUARIO = p_usuario_id;
        PERFORM set_config('app.user_id', COALESCE(v_actor, p_usuario_id::TEXT), true);
    END IF;

    IF p_sede_id IS NOT NULL THEN
        SELECT s.NOMBRE, e.NOMBRE INTO v_sede, v_establecimiento
          FROM academico_test.TSEDE s
          JOIN academico_test.TESTABLECIMIENTO e ON e.PK_ESTABLECIMIENTO = s.FK_TESTABLECIMIENTO
         WHERE s.PK_TSEDE = p_sede_id;
    ELSIF p_establecimiento_id IS NOT NULL THEN
        SELECT e.NOMBRE INTO v_establecimiento
          FROM academico_test.TESTABLECIMIENTO e WHERE e.PK_ESTABLECIMIENTO = p_establecimiento_id;
    END IF;

    IF v_establecimiento IS NOT NULL OR v_sede IS NOT NULL OR p_etiquetas IS NOT NULL THEN
        -- MERGE, no overwrite: si en el futuro query-service (Fase 2, §6.3)
        -- ya dejó sesion_id/familia en app.contexto, no se pisan.
        v_ctx_existente := NULLIF(current_setting('app.contexto', true), '')::JSONB;
        v_ctx_nuevo := jsonb_strip_nulls(jsonb_build_object(
            'establecimiento', v_establecimiento, 'sede', v_sede,
            'etiquetas', CASE WHEN p_etiquetas IS NULL THEN NULL ELSE to_jsonb(p_etiquetas) END));
        PERFORM set_config('app.contexto',
            (COALESCE(v_ctx_existente, '{}'::JSONB) || v_ctx_nuevo)::TEXT, true);
    END IF;

    IF p_etiqueta IS NOT NULL THEN
        PERFORM set_config('app.etiqueta', p_etiqueta, true);
    END IF;
END; $$;
```

Uso mínimo (una función que solo quiere actor + etiqueta, sin sede/establecimiento): `PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante, format('Creación del grado: %s', p_nombre));`. Uso completo, reutilizando el mismo establecimiento/sede ya resuelto para el gate de permisos (§ ver `etiqueta-catalogo-funciones-fn.md`): `PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante, format('Actualización del grado %s', v_nombre), NULL, v_sede_id);`.

**Implementado y validado** en `postgres/migrations/V66__fn_audit_declarar.sql`, rama `feat/etiqueta-auditoria-cdc` (base `origin/dev`). Validado con `psql` contra el Postgres **local** de Docker (`sso-postgres`, mismo esquema que producción vía Flyway) — no contra la base de 172.233.184.248 ni contra `db-migrations`, que quedan fuera de alcance de este cambio. Tres casos cubiertos: (1) solo actor+etiqueta, (2) actor+etiqueta+sede+etiquetas (resuelve sede y establecimiento con un solo `JOIN`), (3) todo `NULL` (una función que aún no adoptó el helper no debe romperse) — y un cuarto caso de *merge-safety*: si `app.contexto` ya trae `sesion_id`/`familia` (simulando la Fase 2 de `query-service`), el helper los preserva en vez de sobrescribirlos.

### 6.3 Qué NO intentar arreglar en esta misma pasada

`sesion_id`, `familia`, `request_id` viven en el request HTTP, no en el dominio SQL — `query-service` los tendría que inyectar como GUCs para que las funciones los hereden, y eso sí requeriría envolver la llamada en una transacción explícita (el mismo problema de "misma conexión" que documenta el §6 de `CONTRATO_SP_CLICKHOUSE.md`). Es un cambio real pero **independiente** del de la etiqueta: no bloquea la etiqueta (que solo necesita `p_pk_usuario_solicitante`, ya disponible) y tiene su propio análisis de riesgo (tocar el pool de conexiones de un servicio que hoy es *stateless por request*). Se recomienda tratarlo como una fase 2 separada si se quiere `sesion_id`/`familia` poblados — no es necesario para que la etiqueta funcione.

## 7. Plan de implementación sugerido

1. ✅ **Agregar `fn_audit_declarar`** (§6.2) — hecho en `postgres/migrations/V66__fn_audit_declarar.sql`, rama `feat/etiqueta-auditoria-cdc`.
2. ✅ **Validar el mecanismo end-to-end** contra el stack local completo antes de escalar — hecho en §11, encontró y corrigió además el bug preexistente de `cdc-capture` que bloqueaba toda entrega de contexto.
3. ✅ **Tocar las 51 funciones de escritura restantes** (más `fn_grado_*`, ya cubiertas en `V67`) — hecho en `V68`-`V76`, 49 funciones en total con `fn_audit_declarar`; detalle completo en §12.
4. **Test de atribución end-to-end** por módulo tocado, contra el stack local con `cdc-capture`/`cdc-worker`/ClickHouse reales — hecho solo para `fn_grado_*` (§11); pendiente repetir para una muestra de `V68`-`V76` (§12.4). La verificación actual de esas 49 funciones es transaccional dentro de Postgres (`BEGIN...ROLLBACK`), no end-to-end contra ClickHouse.
5. **Congelar la convención para funciones nuevas** — agregar al checklist del §10 de `CONTRATO_SP_CLICKHOUSE.md` un ítem: *"Si el SP muta datos, ¿declara `app.user_id` y `app.etiqueta` con `fn_audit_declarar` antes del DML?"*. Pendiente.

## 8. Riesgos a vigilar (heredados del contrato ya documentado)

Todos están cubiertos por `CONTRATO_SP_CLICKHOUSE.md` §4.1/§4.3 y aplican igual aquí porque el mecanismo es el mismo `set_config(..., true)`:

- **No hacer `COMMIT`/`ROLLBACK` dentro de la función** — ya es una regla que estas funciones respetan (son `LANGUAGE plpgsql` sin control transaccional propio).
- **No capturar excepciones sin re-lanzar** después de setear `app.etiqueta` — si un `EXCEPTION WHEN OTHERS` traga el error, el `ROLLBACK` implícito borra tanto el DML como el `pg_logical_emit_message`, así que no hay fuga de datos, pero conviene no depender de eso.
- **Truncamiento a 200 chars** — usar `format()` con datos acotados (nombres, no descripciones libres largas) para que el mensaje no se corte a mitad de palabra.
- **PII en la etiqueta** — la etiqueta va a ClickHouse en texto plano sin cifrar (columna `String`, no anonimizada). Si `auditoria` tiene lectores con menos privilegio que la tabla origen, esto amplía la superficie de exposición de nombres de estudiantes/funcionarios. Vale la pena una decisión explícita de a quién se le da acceso a `auditoria.audit_log` antes de poblarla masivamente con nombres reales.

## 9. Cómo verificar el estado actual antes de tocar código

Contra la ClickHouse real (si está accesible desde este entorno), confirmar la causa raíz con la query que ya trae el contrato:

```sql
SELECT app_user, count() AS n, round(count()*100.0/sum(count()) OVER (),2) AS pct
FROM auditoria.audit_log
WHERE ts > now() - INTERVAL 7 DAY AND tabla LIKE 'academico_test.%'
GROUP BY app_user ORDER BY n DESC;
```

Se espera `app_user=''` en (casi) el 100% de las filas — eso es lo que este análisis predice y lo que justifica el orden de prioridad (arreglar atribución + etiqueta juntas, en la función, en la misma pasada).

---

## 10. Conclusión

| Pregunta | Respuesta |
|---|---|
| ¿El esquema/pipeline de `etiqueta` ya existe? | Sí, completo, sin cambios pendientes de infraestructura. |
| ¿Por qué está vacía hoy? | `query-service` nunca setea las GUCs `app.*` que el trigger lee — ni la etiqueta ni el resto del contexto. |
| ¿Dónde generarla? | **Dentro de cada función `academico_test.fn_*` de escritura**, justo antes del DML, con `set_config('app.etiqueta', ..., true)` — reutilizando datos que la función ya tiene en variables locales. |
| ¿Por qué no en `query-service`? | Es un proxy catálogo-genérico: no conoce la semántica de negocio del SQL que ejecuta, así que no puede redactar "modificación de la calificación de Luis Rafael Puello" sin duplicar lógica que el SP ya tiene. |
| ¿Por qué no en `cdc-worker`? | Solo ve columnas crudas y FKs — resolver nombres ahí es exactamente el problema que la etiqueta busca eliminar, y reintroduce el costo/latencia de cruzar IDs post-hoc. |
| ¿Requiere tocar `cdc-sync` o el esquema de ClickHouse? | No, para lo diseñado aquí — pero §11 encontró un bug preexistente en `cdc-capture` que sí requeriría tocar `db-migrations` para que la etiqueta llegue a producción. |
| ¿Alcance del cambio? | ~52 funciones de escritura en `postgres/migrations`, más un helper nuevo (`fn_audit_declarar`) y la convención documentada para funciones futuras. |

---

## 11. Prueba end-to-end contra el stack local — resultado y hallazgo bloqueante

Se adoptó `fn_audit_declarar` en una función real (`fn_grado_crear`/`fn_grado_actualizar`, migración `V67__fn_grado_adopta_audit_declarar.sql`) y se ejecutó contra el stack **local** completo de Docker: `sso-postgres` → `cdc-capture` → RabbitMQ → `cdc-worker` → `cdc-clickhouse` (perfil `cdc-sync`, activado con `CDC_SYNC_ENABLED=true ./scripts/sso-stack.sh up -d`; imágenes ya publicadas de `db-migrations`, no se construyó ni editó ese repo).

### 11.1 Lo que SÍ funcionó — la infraestructura CDC funciona de punta a punta

```sql
-- Ejecutado contra sso-postgres (real, sin ROLLBACK):
SELECT academico_test.fn_grado_actualizar(1, NULL, 'Octavo', NULL, NULL, 1);
```

La fila llegó a `auditoria.audit_log` en el ClickHouse local en segundos, con `lsn`/`xid`/`tabla`/`operacion`/`pk` correctos:

```
lsn:       45226272
xid:       1182
tabla:     tgrado
operacion: u
pk:        1
```

(Nota al margen, verificado en el camino: `tabla` guarda el nombre **crudo sin schema** — `tgrado`, no `academico_test.tgrado` como decía `CONTRATO_SP_CLICKHOUSE.md` §8 — el código real (`CdcEvent.tableName()` → `source.table()`) no incluye el schema. Vale la pena corregir esa documentación por separado.)

Esto confirma: WAL lógico, publicación `cdc_pub`, replica identity, slot `cdc_slot`, ruteo por RabbitMQ, y el INSERT a ClickHouse — **todo el esqueleto mecánico del pipeline funciona correctamente**, incluyendo con la función ya modificada por `fn_audit_declarar` (cero errores de sintaxis/ejecución en Postgres).

### 11.2 Lo que NO funcionó — `etiqueta`/`app_user`/`contexto` llegaron vacíos

```
app_user:  (vacío)
db_user:   (vacío)
etiqueta:  (vacío)
contexto:  (vacío)
```

En el log de `cdc-capture`, en el mismo instante:

```
DEBUG AmqpPublisher — Ignoring audit_ctx logical message xid=1182
```

### 11.3 Por qué esto NO es un problema de `fn_audit_declarar`

Se verificó con un smoke test directo (`BEGIN; ...; ROLLBACK;`) que la función sí deja las GUCs correctamente seteadas en la sesión, ANTES de que corra el `UPDATE`:

```
app.user_id=[Admin Sistema] app.etiqueta=[Actualización del grado Octavo] app.contexto=[{"establecimiento": "Establecimiento Seed Local"}]
```

El trigger `trg_audit_ctx` (V26, sin cambios) lee esas mismas GUCs con `current_setting(..., true)` — el diseño de esa parte está correcto y validado.

### 11.4 El bloqueador es preexistente, no causado por este trabajo

Se revisó el historial completo de `cdc-capture` y de `auditoria.audit_log` en el stack local:

- **836 filas históricas en `audit_log` local, 0 con `app_user`/`etiqueta`/`contexto` no vacíos** — el 100%, no una fracción.
- El log de `cdc-capture` muestra la MISMA línea `"Ignoring audit_ctx logical message xid=<N>"` para **cinco transacciones de una sesión de pruebas del 2026-08-06** (`xid=1437, 1438, 1439, 1441, 1442`) — **13 días antes** de que existiera `fn_audit_declarar` o cualquier cambio de esta rama. En ese momento nadie seteaba ninguna GUC `app.*`, así que el mensaje lógico igual se emitía (con todos los campos `null` dentro del JSON) pero el trigger lo arma siempre con `prefix='audit_ctx'` y un `data` no vacío — la función `AmqpPublisher.parseAuditContext()` solo devuelve `null` (→ "Ignoring") si la forma **estructural** del evento Debezium no calza con lo esperado (`message` no es un mapa, o `prefix`/`data` no están donde se buscan), no por contenido vacío.

**Conclusión**: el mecanismo de correlación de `audit_ctx` (`cdc-capture` → `AmqpPublisher.parseAuditContext` → `AuditContextCache`) parece estar roto de forma sistemática en la imagen actualmente desplegada — independientemente de si el llamador setea las GUCs o no. Esto es un hallazgo **nuevo**, no visible hasta ahora porque nadie había llegado a setear `app.etiqueta`/`app.user_id` para poder notar que, aun haciéndolo bien, el dato se pierde un paso más adelante en la tubería.

**No se verificó si este mismo bug afecta la base de producción** (172.233.184.248) — por instrucción explícita de no probar contra el entorno real. Sí se resolvió del lado del código (§11.5) — el chequeo pendiente en producción es ahora "¿ya corre la imagen con el fix?", no "¿existe el bug?".

### 11.5 Causa raíz encontrada y corregida — verificado contra el bytecode real de Debezium, no por prueba y error

Se descompiló el JAR real `debezium-connector-postgres-3.1.0.Final` (el mismo que usa `cdc-capture`, cacheado en `~/.m2`) para ver qué shape de JSON produce Debezium para un mensaje lógico, en vez de asumirlo. `LogicalDecodingMessageMonitor.class` define estas constantes:

```java
DEBEZIUM_LOGICAL_DECODING_MESSAGE_KEY        = "message"   // coincide con el código
DEBEZIUM_LOGICAL_DECODING_MESSAGE_PREFIX_KEY = "prefix"    // coincide con el código
DEBEZIUM_LOGICAL_DECODING_MESSAGE_CONTENT_KEY = "content"  // el código buscaba "data" — NUNCA existió esa clave
```

`AmqpPublisher.parseAuditContext()` leía `msg.get("data")`, que siempre devolvía `null` porque la clave real es `content`. Con eso, la función retornaba `null` el 100% de las veces → `"Ignoring audit_ctx logical message"` para cada transacción, sin excepción, desde siempre. Un segundo problema, oculto detrás del primero: el bytecode de `convertContent(byte[])` muestra que, con el `binary.handling.mode` por defecto (`bytes`, nunca configurado explícitamente), el contenido llega como bytes crudos que el `JsonConverter` sin schema de Kafka Connect serializa como **string Base64** — no como texto plano. Ambos problemas estaban además ocultos por los propios tests: `AmqpPublisherContextTest` fabricaba a mano un JSON con `{"prefix": "audit_ctx", "data": ...}` en texto plano — la misma suposición equivocada del código de producción — y el único test que corre un Debezium real (`CapturePublishIT`) nunca ejercita el camino de `audit_ctx`; el otro (`CaptureE2EIT`) es un stub sin terminar. Nunca hubo una prueba que validara esta forma contra Debezium real.

**Fix aplicado** en `AmqpPublisher.parseAuditContext()`: leer `msg.get("content")` en vez de `"data"`, y Base64-decodificar el valor antes de parsearlo como JSON. Además, se fijó `binary.handling.mode=base64` explícito en `DebeziumEngineConfig` (documenta la suposición en vez de depender de un default implícito de otra librería) y se corrigieron las fixtures de `AmqpPublisherContextTest` para usar `content`/Base64 real.

**Hallazgo adicional durante el fix**: `db-migrations/cdc-sync` **no es el código que realmente se despliega**. SSO tiene su propia copia vendorizada completa en `cdc-sync/` (no es submódulo — son archivos normales del repo SSO), y `deploy-test.yml`/`ci.yml` construyen y publican `cdc-capture`/`cdc-worker` **desde esa copia** hacia `ghcr.io/colombia-evaluadora/sso/cdc-capture`. Es exactamente la imagen que corre en local (`ghcr.io/colombia-evaluadora/sso/cdc-capture:test-latest`) y, casi seguro, en producción. El fix se aplicó en **ambos** lugares (rama `fix/audit-ctx-message-content-key` en `db-migrations`, y directamente en `cdc-sync/` dentro de esta rama de SSO) — pero la copia de SSO es la que de verdad importa para producción.

**Validado end-to-end, con la imagen reconstruida localmente y corriendo de verdad**: se reconstruyó `cdc-capture` (`docker compose build cdc-capture`) desde el `cdc-sync/` corregido, se reinició el contenedor, y se volvió a ejecutar `fn_grado_actualizar` contra `sso-postgres`. Comparación directa de las dos filas en `auditoria.audit_log` (misma tabla, antes/después del fix, sin tocar nada del lado de Postgres entre una y otra):

| Campo | `xid=1182` (antes del fix) | `xid=1183` (después del fix) |
|---|---|---|
| `app_user` | *(vacío)* | `Admin Sistema` |
| `etiqueta` | *(vacío)* | `Actualización del grado Octavo` |
| `contexto` | *(vacío)* | `{"establecimiento":"Establecimiento Seed Local"}` |

Pipeline completo funcionando de punta a punta: Postgres → `trg_audit_ctx` → `cdc-capture` (corregido) → RabbitMQ → `cdc-worker` → ClickHouse.

## 12. Adopción completa de `fn_audit_declarar` — 49 funciones, `V68`-`V76`

Con el pipeline validado end-to-end (§11) y el helper probado en `fn_grado_*` (§6.2, `V67`), se extendió `fn_audit_declarar` a **todas** las funciones `fn_*` de escritura restantes de `academico_test` en el Postgres local (rama basada en `origin/dev`), cerrando el ítem 3 del plan del §7.

### 12.1 Migraciones agregadas

| Migración | Módulo |
|---|---|
| `V68__fn_area_subject_grupo_adoptan_audit_declarar.sql` | área / subject / grupo |
| `V69__fn_escala_adoptan_audit_declarar.sql` | escala |
| `V70__fn_periodo_adoptan_audit_declarar.sql` | periodo / descanso / periodo_eval |
| `V71__fn_criterio_plan_horario_asignacion_adoptan_audit_declarar.sql` | criterio / plan / horario / asignación |
| `V72__fn_est_fun_sede_usuario_pequenas_adoptan_audit_declarar.sql` | est / fun / sede_usuario (funciones pequeñas) |
| `V73__fn_sed_sedeusuario_usu_adoptan_audit_declarar.sql` | sed / sede_usuario / usu |
| `V74__fn_sed_crear_actualizar_est_crear_adoptan_audit_declarar.sql` | sed_crear / sed_actualizar / est_crear |
| `V75__fn_est_actualizar_adopta_audit_declarar.sql` | `fn_est_actualizar` (función grande) |
| `V76__fn_fun_actualizar_adopta_audit_declarar.sql` | `fn_fun_actualizar` (función grande) |

Todas siguen el mismo patrón que `V67`: capturar (o reutilizar) el `v_establecimiento_id` ya disponible en la función, y llamar `fn_audit_declarar(p_pk_usuario_solicitante, format('<texto natural>', ...), v_establecimiento_id)` justo antes del `INSERT`/`UPDATE`/soft-delete.

### 12.2 Exclusiones deliberadas

No todas las funciones de la lista original reciben su propia llamada:

- **`fn_enfasis_desde_seleccion`, `fn_enfasis_resolver`, `fn_escala_propagar`** — son *helpers* internos invocados desde dentro de otra función que ya declara su propia etiqueta. `set_config(..., true)` es "última llamada gana" dentro de la transacción: si estos helpers declararan la suya, pisarían la etiqueta correcta del caller.
- **`fn_fun_soft_delete`** — no hace DML directo; solo delega en `fn_sede_usuario_soft_delete`, que sí la declara.
- **`fn_create_parent_menu_with_submenus`** y el resto del grupo legacy/drift de menús/roles — mismo criterio del catálogo original (§17 de `etiqueta-catalogo-funciones-fn.md`): funciones con drift respecto a prod, fuera de alcance de esta pasada.

### 12.3 Verificación

- Las 9 migraciones se aplicaron sin error contra `sso-postgres` local (`CREATE OR REPLACE FUNCTION` para cada una).
- `SELECT count(*) FROM pg_proc ... WHERE prosrc ILIKE '%fn_audit_declarar%'` sobre `academico_test.fn_*` → **49**, que reconcilia exacto: 51 funciones del alcance original menos las 4 exclusiones de §12.2 = 47 nuevas + las 2 de `fn_grado_*` (`V67`) = 49.
- Smoke test transaccional (`BEGIN ... ROLLBACK`, sin persistir nada) ejecutando funciones representativas de cada migración — incluida `fn_fun_actualizar`, la más grande del lote — confirmando que cada llamada deja la `etiqueta` esperada en `current_setting('app.etiqueta', true)` sin errores:

| Función probada | Migración | `etiqueta` resultante |
|---|---|---|
| `fn_area_crear` / `fn_area_actualizar` / `fn_area_soft_delete` | V68 | `Creación`/`Actualización`/`Eliminación del área ...` |
| `fn_periodo_eval_crear` / `fn_periodo_eval_soft_delete` | V70 | `Creación`/`Eliminación del periodo de evaluación ...` |
| `fn_sed_actualizar` | V73/V74 | `Actualización de la sede ...` |
| `fn_est_actualizar` | V75 | `Actualización del establecimiento ...` |
| `fn_sede_usuario_actualizar` | V72 | `Actualización de la asignación de sede/rol ...` |
| `fn_plan_actualizar` | V71 | `Actualización del plan de estudio: ...` |
| `fn_fun_actualizar` | V76 | `Actualización de datos del funcionario ...` |

### 12.4 Estado

Commiteado (`d5b9f9c`) y pusheado a `origin/feat/etiqueta-auditoria-cdc`. §13 completa la validación end-to-end pendiente aquí (contra el pipeline CDC real, no solo `BEGIN...ROLLBACK` en Postgres). Pendiente: PR contra `dev`/`main`.

## 13. Prueba end-to-end real por endpoint — api-gateway → query-service → Postgres → cdc-capture → RabbitMQ → cdc-worker → ClickHouse

A diferencia de §11 (una sola función, llamada directo por `psql`), esta ronda ejercita el pipeline **completo incluyendo el api-gateway y el query-service** (`sso-query-service-eval-col`, que resuelve cada ruta contra la tabla `public.query` de `sso-admin` y ejecuta la función `fn_*` correspondiente), con JWT real emitido por `auth-center` y verificación directa en ClickHouse después de cada llamada.

### 13.1 Cobertura secuencial (usuario único, ~30 endpoints)

Se armó un arnés (`e2e_test.py`, en el scratchpad de la sesión) que hace login como `admin@example.com`, y por cada endpoint de escritura registrado en el catálogo local: llama al endpoint real vía `POST http://localhost:8080/api/eval-col/...`, espera la propagación del pipeline y consulta `auditoria.audit_log` para confirmar `etiqueta`/`app_user` poblados.

**29 llamadas, 27 HTTP OK, 24/24 con atribución confirmada en ClickHouse** (3 de las "sin fila" reportadas inicialmente eran un error del arnés de prueba — comprobaban la tabla `tplan` cuando la fila real cae en `tasignatura_plan`; corregido y reverificado). `fn_horario_guardar`/`fn_asignacion_guardar` no dejan fila cuando el `UPDATE` de desactivación afecta 0 registros (grado/funcionario recién creado, sin agenda/asignaciones previas) — comportamiento esperado, no un defecto: sin cambio de fila no hay evento CDC con el que correlacionar el mensaje de contexto (mismo fenómeno que ya documenta §11.3).

Módulos cubiertos con confirmación end-to-end real (HTTP + ClickHouse): área, asignatura/subject, grado, grupo, plan de estudio (agregar/actualizar/eliminar/soft-delete-por-grado), horario, establecimiento→funcionario (vincular), periodo académico (crear/soft-delete), descanso (agregar/eliminar), periodo de evaluación (crear/actualizar/soft-delete).

**Bug real encontrado y corregido en esta ronda — `V77`**: `fn_plan_agregar` insertaba el contenedor `TPLAN` (la fila padre del plan de estudio, creada solo la primera vez que un grado recibe una asignatura) **antes** de llamar a `fn_audit_declarar`. Como `trg_audit_ctx` es `BEFORE STATEMENT`, esa fila puntual llegaba a ClickHouse con `etiqueta`/`app_user` vacíos (el resto de inserts de la misma función sí iban después y no se veían afectados). Corregido en `postgres/migrations/V77__fn_plan_agregar_fix_orden_audit_declarar.sql` moviendo la declaración de la etiqueta al inicio de la función, antes del primer `INSERT`. Reverificado end-to-end: la fila de `tplan` ahora sí trae la etiqueta.

**Hallazgos NO relacionados con este trabajo** (bugs preexistentes de drift entre el catálogo `public.query` de `sso-admin` y las funciones `fn_*` reales, detectados como efecto colateral de probar por HTTP en vez de por `psql` directo — se reportan aquí para que quede constancia, pero están fuera de alcance de esta iniciativa):

| Endpoint | Síntoma | Causa |
|---|---|---|
| `PATCH /establecimientos/funcionarios/:ID` (`fn_fun_actualizar`) | 500 `function ... does not exist` | La llamada SQL del catálogo tiene ~20 parámetros menos que la firma real de la función (drift de cuando se le agregaron campos nuevos). |
| `PUT /periodos-academicos/editar/:ID` (`fn_periodo_actualizar`) | 500 `function ... does not exist` | El catálogo pasa `DESCANSO_INICIO`/`DESCANSO_FIN` como argumentos posicionales que la función ya no acepta (los descansos se separaron a `fn_descanso_agregar`/`fn_descanso_eliminar`). |
| `POST /plans` (`fn_create_plan_from_value`) | 500 `column "id" does not exist` | El catálogo hace `SELECT id, name FROM fn_create_plan_from_value(...)`; la función devuelve `TABLE(pk_lista_valor, nombre, valor, status)`. |
| `POST /periodos-academicos` (`fn_periodo_crear`) | 400 `upper bound of FOR loop cannot be null` | Con `DESCANSO_INICIO`/`DESCANSO_FIN` como arreglo vacío `[]` (en vez de `NULL`), `array_length([],1)` es `NULL` en Postgres (no `0`), y el `FOR i IN 1..NULL` revienta. Workaround usado en la prueba: mandar `NULL` en vez de `[]`. |
| `POST /establecimientos` (`fn_est_crear`) | 500 genérico `Database error`, sin traza SQL en los logs | `BODY.LOGO` está declarado en el catálogo como tipo especial `FILE:escudo`; el query-service no tiene manejo real para ese tipo (no hay código para `"FILE:"` en el binder), así que la petición JSON plana falla antes de llegar a Postgres. Bloquea probar `fn_est_crear` **por HTTP**; la función en sí se probó por `psql` directo (ver §13.2) y funciona correctamente. |

### 13.2 Prueba de cadena — establecimiento con rector/secretaría, sede, vinculación de funcionarios

Pedido explícito: verificar que una creación de establecimiento con rector y secretaría genera una **cadena coherente de etiquetas** a través de varias tablas, no solo una fila aislada. Como `fn_est_crear` está bloqueado por HTTP (tabla de arriba), esta única llamada se hizo por `psql` directo (mismo efecto que tendría el endpoint si el catálogo no tuviera el bug de `LOGO`); el resto de la cadena — sede, vinculación de funcionarios, actualización — se ejecutó **100% por HTTP real** contra `api-gateway`:

1. `fn_est_crear` (directo, `p_pk_usuario_solicitante=1`) — establecimiento nuevo con `p_fk_tfuncionario_rector=4` (Maria Gomez) y `p_fk_tfuncionario_secretaria=5` (Jorge Ramirez).
2. `POST /establecimientos/sedes` — sede nueva en ese establecimiento.
3. `POST /funcionario/enlazar-establecimiento` ×2 — vincula a Maria Gomez y a Jorge Ramirez.
4. `fn_fun_actualizar` (directo, mismo bug de catálogo de la tabla de arriba) — actualiza el teléfono de Maria Gomez.
5. `PATCH /establecimientos/sedes/:ID`, `PUT .../sedes/:ID` (soft-delete), `PUT /establecimientos/:ID` (soft-delete) — cierre del ciclo.

Cadena resultante en `auditoria.audit_log`, en orden, todas atribuidas correctamente a `Admin Sistema` y con `contexto.establecimiento` propagado donde aplica:

| xid | tabla | etiqueta |
|---|---|---|
| 1333 | `testablecimiento` | Creación del establecimiento Establecimiento Cadena Test |
| 1334 | `tsede` | Creación de la sede Sede Cadena Test (código CHAIN-SEDE-1) |
| 1335 | `tfuncionario` | Vinculación del funcionario Maria Gomez al establecimiento Establecimiento Cadena Test |
| 1336 | `tfuncionario` | Vinculación del funcionario Jorge Ramirez al establecimiento Establecimiento Cadena Test |
| 1337 | `tusuario` **y** `tfuncionario` (mismo xid) | Actualización de datos del funcionario Maria Gomez |
| 1338 | `tsede` | Actualización de la sede Sede Cadena Test v2 |
| 1339 | `tsede` | Eliminación de la sede Sede Cadena Test v2 |
| 1340 | `testablecimiento` | Eliminación del establecimiento Establecimiento Cadena Test |

Hallazgo interesante (no un bug): `xid=1337` toca **dos tablas** (`tusuario` y `tfuncionario`) en la misma transacción porque `fn_fun_actualizar` actualiza ambas filas — y ambas llegan con la **misma etiqueta correcta**, confirmando que `fn_audit_declarar` cubre correctamente el caso de una función que muta más de una tabla por llamada. Se verificó además contra Postgres que el establecimiento quedó con `FK_TFUNCIONARIO_RECTOR=4`/`FK_TFUNCIONARIO_SECRETARIA=5` tal como se pidió — los datos y la auditoría concuerdan.

Nota: la etiqueta de "Creación del establecimiento" no nombra al rector/secretaría en el texto (solo guarda sus FKs); son las llamadas separadas de "Vinculación del funcionario..." las que sí los nombran explícitamente. No es un defecto — es simplemente que `fn_est_crear` no resuelve esos nombres hoy; se podría enriquecer el texto de la etiqueta de creación en una iteración futura si Mesa de Ayuda lo pide.

### 13.3 Prueba de concurrencia — múltiples usuarios, múltiples roles, operaciones simultáneas

Pedido explícito: confirmar que la atribución es correcta incluso con varias transacciones concurrentes de distintos actores sobre la **misma tabla**, que es exactamente el escenario que puede cruzar contextos si `AuditContextCache` (clave `xid`) tuviera un bug de concurrencia.

Se crearon 3 usuarios de prueba reales (vía `POST /createAccount` + activación por token de MailHog + alta del `TUSUARIO`/`TSEDE_USUARIO` correspondiente en `academico_test`, igual que un alta real): `e2e.rector@example.com` (rol `CEVAL-RECTOR`), `e2e.coordinador@example.com` (rol `CEVAL-COORDINADOR`) y `e2e.docente@example.com` (rol `CEVAL-DOCENTE`, de solo lectura — 2 endpoints `GET /select*` nada más). Los 4 actores (los 3 nuevos + `admin`) dispararon **simultáneamente** (con una barrera de hilos) `POST /areas` → `PUT actualizar` → `PUT eliminar`, cada uno con su propio nombre de área.

Resultado:

- `e2e.docente` recibió **403 Forbidden** en el primer intento, como se esperaba (su rol no tiene `POST /areas` en `role_query`) — confirma que el control de autorización a nivel de catálogo funciona antes de llegar siquiera a Postgres.
- Los otros 3 (`admin`, `rector`, `coordinador`) ejecutaron sus 3 llamadas cada uno **entrelazadas en el tiempo** contra la misma tabla `tarea` (xids consecutivos 1268–1276, algunas actualizaciones de distintos usuarios llegaron fuera de orden de xid pero eso es exactamente el punto: concurrencia real).
- **9/9 filas en ClickHouse atribuidas al actor correcto, 0 cruces**: cada `etiqueta`/`app_user` correspondió exactamente a quien hizo esa llamada, sin ninguna mezcla entre transacciones concurrentes.

Esto es la validación más fuerte posible del diseño `fn_audit_declarar` + `set_config(..., true)` + `AuditContextCache` por `xid`: sobrevive concurrencia real de múltiples conexiones/usuarios sin cruzar contextos.

### 13.4 Estado

Ambas pruebas (secuencial + concurrente + cadena) corrieron contra el stack local completo con `CDC_SYNC_ENABLED=true`. El único fix de código que salió de esta ronda es `V77` (aplicado localmente, pendiente de commit/push junto con este documento). El resto de hallazgos (tabla del §13.1) son bugs preexistentes de drift entre `sso-admin`/`public.query` y las funciones `fn_*`, no introducidos ni corregidos por esta iniciativa — quedan documentados aquí para que el equipo decida si los prioriza aparte.

## 14. `request_id` y `path` — Fase 2 implementada (parcial)

Pregunta del usuario: ¿por qué `sesion_id`/`familia`/`request_id` siguen vacíos en ClickHouse, y desde dónde en el flujo `api-gateway → query-service → Postgres` se pueden inyectar? Ver §6.3 y el trigger `fn_audit_ctx()` (`V26__context-emitter.sql`) para el porqué exacto: son datos del **request HTTP**, no del dominio SQL — ninguna función `fn_*` puede inventarlos, y `query-service` nunca los seteaba.

### 14.1 Semántica de referencia (`db-migrations/api/api` — `AuditContextAspect.java`)

La única implementación real de este contrato en el monorepo (una app-demo, dominio `clientes`/`pedidos`) define:

- **`sesion_id`** = claim `jti` del JWT, validado contra una tabla `sesiones` propia (revocación de sesión).
- **`familia`** = claim custom `familia` (UUID) — un concepto de agrupación multi-tenant ("familia de cliente").
- **`request_id`** = header `X-Request-Id`, reenviado tal cual sin validar.
- Además mete `ip`, `user_agent` y `endpoint` (`MÉTODO URI`) dentro de `contexto`.

**El JWT real de `auth-center` (SSO) no tiene ni `jti` ni `familia`** — solo `sub/iss/roles/typ/iat/exp/uid`. `sesion_id` necesitaría un cambio en `auth-center` (agregar un claim `jti` al emitir el token) que está fuera del alcance de `query-service`; `familia` no tiene ningún concepto equivalente en SSO (tenencia única — lo más parecido, el establecimiento/sede, ya lo cubre `fn_audit_declarar` en `contexto`, sería redundante). **Decisión**: implementar solo `request_id` (autocontenido en `query-service`) y agregar `path` (equivalente al `endpoint` de la referencia) en `contexto`; `sesion_id`/`familia` quedan documentados como pendientes de una decisión de producto que no corresponde inventar aquí.

### 14.2 Dónde se inyecta, y por qué así

`query-service` no tiene ningún `@Transactional`/`TransactionTemplate` (confirmado por grep, §3 de este documento) — cada `jdbc.query()` es su propio statement top-level. Para que un `set_config()` sobreviva hasta que el `fn_*` real lo necesite, tiene que correr **en la misma sentencia SQL**, no en una separada. Dos piezas:

1. **`QueryService.injectRequestParams()`** (nuevo, junto a `injectContextParams()` que ya inyectaba `:CONTEXT.USER_ID`/`EMAIL`/`ROLES` desde el JWT) — agrega `:CONTEXT.REQUEST_ID` (header `X-Request-Id` si vino, si no un `UUID.randomUUID()`) y `:CONTEXT.PATH` (`MÉTODO URI`) al mapa de parámetros de **toda** petición, autenticada o no, vía `RequestContextHolder` (mismo patrón que `AuditContextAspect`, sin necesitar inyectar `HttpServletRequest` en cada firma intermedia).
2. **El SQL de cada query de escritura del catálogo** (`public.query.query`, en `sso-admin`) se envuelve en un CTE `MATERIALIZED` que fija `app.request_id` y funde `path` en `app.contexto` — **antes** de la subconsulta que llama al `fn_*` real, garantizado por `MATERIALIZED` (fuerza a Postgres a computar el CTE como paso independiente antes de evaluar el resto):

   ```sql
   WITH _ctx AS MATERIALIZED (
     SELECT set_config('app.request_id', :CONTEXT.REQUEST_ID, true) AS _rid,
            set_config('app.contexto', jsonb_build_object('path', :CONTEXT.PATH)::text, true) AS _c
   )
   SELECT _orig.* FROM _ctx, (
     SELECT academico_test.fn_area_crear(...)
   ) AS _orig;
   ```

   `fn_audit_declarar` ya hace *merge*, no *overwrite*, sobre `app.contexto` (diseño original, §6.2) — así que `path` sobrevive intacto cuando la función además mete `establecimiento`/`sede`. Verificado con un test dirigido antes de aplicarlo a las 43 queries: `contexto` termina como `{"path":"POST /areas","establecimiento":"..."}`, ambos presentes.

   La tabla `public.query` es dato administrado por `sso-admin`, no tiene migraciones Flyway propias en este repo (se pobló ad-hoc en este ambiente local) — el wrap se aplicó con `scripts/wrap-write-queries-audit-context.sql` (idempotente, documentado, reproducible en cualquier ambiente).

### 14.3 Validación end-to-end

Reconstruida la imagen de `query-service` (`ghcr.io/colombia-evaluadora/sso/query-service:test-latest`, contenedor `sso-query-service-eval-col` recreado) y aplicado el wrap a las 43 queries de escritura. Repetido el arnés completo de §13.1 sin regresiones (mismos 3 fallos preexistentes de la tabla del §13.1, nada nuevo roto), y confirmado en una muestra de ~20 filas across todos los módulos: `request_id` único por request (o el valor exacto del header `X-Request-Id` cuando se manda) y `contexto.path` con el endpoint real (`POST /areas`, `PUT /grados/7`, etc.) en el 100% de las filas.

**Hallazgo adicional (a favor, no un bug)**: cuando un solo request modifica varias tablas en la misma transacción (p. ej. `POST /grados/:ID/plan-asignaturas` → `tplan` + `tasignatura_plan` + `tcriterio_evaluacion_asignatura_plan`), las tres filas de auditoría comparten el **mismo `request_id`** — exactamente el caso de uso para el que existe esa columna: agrupar en ClickHouse todos los cambios de una sola acción del usuario aunque toquen varias tablas, sin depender de que el `xid` de Postgres sea fácil de correlacionar desde afuera.

### 14.4 Pendiente

- `sesion_id`/`familia`: requieren decisión de producto (¿qué representa "familia" en SSO, si algo?) y, para `sesion_id`, un cambio en `auth-center` (emitir un claim `jti`/id de sesión) — no implementado aquí.
- El script del catálogo (`scripts/wrap-write-queries-audit-context.sql`) solo tocó las 43 queries de escritura de las 49 funciones adoptadas — no las de lectura (no aplica, no mutan nada) ni las 6 funciones sin endpoint registrado localmente (§12.1).
- Falta decidir si este wrap del catálogo se aplica también en el ambiente real (producción) — ahí `public.query` es la misma clase de dato administrado, así que el mismo script aplicaría, pero requiere coordinación con quien gestiona ese catálogo en producción.
