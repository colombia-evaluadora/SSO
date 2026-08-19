# Análisis: dónde generar la `etiqueta` de auditoría (query-service ↔ cdc-sync ↔ ClickHouse)

> Fecha: 2026-08-19 (actualizado el mismo día con introspección directa contra la base real)
> Alcance: `SSO/query-service`, `db-migrations/cdc-sync`, `SSO/postgres/migrations` (funciones `academico_test.fn_*`).
> Pregunta que responde: *¿dónde se debe generar el valor de la columna `auditoria.audit_log.etiqueta` para que el equipo de soporte identifique de inmediato "qué pasó y a quién" sin cruzar IDs a mano?*
>
> **Ver también**: [`etiqueta-catalogo-funciones-fn.md`](etiqueta-catalogo-funciones-fn.md) — catálogo función-por-función (las 67 funciones de escritura realmente desplegadas en `172.233.184.248`, no solo las que aparecen en los archivos de migración) con la etiqueta propuesta para cada una. Corrige un supuesto de este documento: **no existe hoy un módulo de notas/calificaciones** en el catálogo de funciones desplegado — los ejemplos de "calificación de Luis Rafael Puello" de aquí son ilustrativos del patrón, no una función real; la función real más cercana en espíritu es `fn_asignacion_guardar` (asignación docente–materia–grupo).
>
> **Alcance de la implementación**: todo el trabajo de código vive **exclusivamente en `SSO`** (rama `feat/etiqueta-auditoria-cdc`, base `origin/dev`) — `db-migrations`/`cdc-sync` (el pipeline Debezium → RabbitMQ → cdc-worker → ClickHouse) **no se toca**. Eso es posible porque `app.user_id`, `app.etiqueta` y `app.contexto` son columnas/GUCs que ya existen de punta a punta (§1); establecimiento/sede/etiquetas de categorización se anidan dentro de `app.contexto` (que ya viaja sin filtrar) en vez de pedir columnas ClickHouse nuevas — ver §6.2. Toda validación de SQL en este documento se hizo contra el **Postgres local de Docker** (`sso-postgres`, esquema sincronizado vía Flyway con el mismo `postgres/migrations/`), nunca contra la base de 172.233.184.248.
>
> **⚠️ Hallazgo de la prueba end-to-end (§11)**: adoptar `fn_audit_declarar` en una función real (`fn_grado_actualizar`, V67) y ejecutarla contra el stack local completo de `cdc-sync` confirma que el lado Postgres funciona exactamente como se diseñó — pero descubrió un bloqueador **preexistente y no causado por este trabajo** en `cdc-capture` (`db-migrations`) que impide que `etiqueta`/`app_user`/`contexto` lleguen a ClickHouse en absoluto, para cualquier fila, no solo las de este cambio. Ver §11 para la evidencia — es un hallazgo nuevo que había quedado oculto porque, hasta ahora, nadie había llegado a setear las GUCs para poder notar que ni siquiera así se propagan.

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
2. **Priorizar por impacto de soporte**, no por orden alfabético — empezar por los módulos que Mesa de Ayuda más consulta hoy (según el pedido original: notas/calificaciones, matrícula, usuarios/funcionarios, permisos). Revisar si existe ya un módulo de notas (`fn_nota_*` / `fn_calificacion_*`); si no, dejarlo como convención obligatoria para cuando se cree.
3. **Tocar las 52 funciones de escritura** en tandas por módulo (cada `V*__*_module.sql` ya agrupa por dominio — `V43` = grado/grupo, `V51` = funcionario, etc.), agregando la llamada a `fn_audit_declarar` con el texto apropiado a cada `crear`/`actualizar`/`soft_delete`/`bulk_delete`.
4. **Test de atribución end-to-end** por módulo tocado — el mismo patrón que documenta §6 de `CONTRATO_SP_CLICKHOUSE.md` (`CdcContextAspectOrderingTest`), adaptado: llamar la función vía `query-service` (o directo por psql) y verificar en ClickHouse que `app_user` y `etiqueta` llegan poblados en <N segundos.
5. **Congelar la convención para funciones nuevas** — agregar el checklist del §10 de `CONTRATO_SP_CLICKHOUSE.md` un ítem: *"Si el SP muta datos, ¿declara `app.user_id` y `app.etiqueta` con `fn_audit_declarar` antes del DML?"*.

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

**No se investigó más profundo ni se intentó arreglar** — es código de `db-migrations` (`cdc-capture/src/main/java/com/example/cdc/capture/AmqpPublisher.java`, método `parseAuditContext`), fuera del alcance de esta rama por instrucción explícita. Queda documentado aquí para que quien tenga permiso de tocar ese repo lo diagnostique (candidatos a revisar: versión/config de Debezium respecto a cómo serializa `pg_logical_emit_message` como JSON — la forma `{"message": {"prefix": ..., "data": ...}}` que el código espera puede no coincidir con lo que esta versión del conector realmente emite).

**No se verificó si este mismo bug afecta la base de producción** (172.233.184.248) — por instrucción explícita de no probar contra el entorno real; sería el primer chequeo a hacer antes de invertir en adoptar `fn_audit_declarar` en las 65 funciones restantes, porque si el bug también está en producción, ninguna cantidad de trabajo del lado de Postgres hará que la etiqueta llegue a ClickHouse hasta que se arregle `cdc-capture`.
