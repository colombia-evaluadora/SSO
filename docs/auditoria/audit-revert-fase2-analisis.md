# Análisis: revertir un cambio visto en ClickHouse (fase 2 de `POST /audit/revert`)

> Rama: `feature/CU-86e2xvf90-Back-Revertir-cambios` (base `origin/dev`)
> Alcance: `SSO/sso-admin` — `AuditRevertService`/`AuditRevertController`.
> Pregunta que responde: *dado un cambio que `query-service` escribió en Postgres y que ya llegó a `auditoria.audit_log` en ClickHouse vía el pipeline CDC (Debezium → RabbitMQ → cdc-worker), ¿cómo se revierte ese cambio en Postgres a su operación contraria?*

## 1. Punto de partida — lo que ya existía (fase 1)

`AuditRevertService`/`AuditRevertController` (`POST /audit/revert`, `{lsn, seq, dryRun}`) ya resolvían **un solo caso**: un `UPDATE` que tocó la bandera `active` (el patrón soft-delete/soft-restore). Cualquier otra cosa —`INSERT`, `DELETE` físico, `UPDATE` de cualquier otra columna— se rechazaba explícitamente. Ver la cabecera de `AuditRevertService.java` en `dev` para el detalle de esa fase 1.

Esta fase 2 amplía el alcance a los tres casos que pidió el usuario:

| Operación original (ClickHouse `operacion`) | Reversión |
|---|---|
| `c` (INSERT) | "eliminar" = desactivar la fila (`active = true → false`) |
| `u` con `active` cambiando | `active = false → true` (o viceversa) — ya cubierto en fase 1, ahora es un caso particular del punto siguiente |
| `u` genérico (cualquier columna) | Revertir cada columna que cambió a su valor anterior |
| `d` (DELETE físico) | **Rechazado explícitamente** — ver §3 |

## 2. Por qué "crear → eliminar" es un soft-delete, no un `DELETE FROM`

Se verificó contra `postgres/migrations/` que **ninguna función `academico_test.fn_*` de escritura hace hoy un `DELETE FROM` de negocio**:

```
grep -ri "DELETE FROM academico_test" postgres/migrations/   → 0 resultados
grep -ri "DELETE FROM" postgres/migrations/                  → solo migraciones one-off de catálogo (ROLE_ROUTE, ROUTE, role_app), no tablas de negocio
```

Todo el sistema borra por convención con `active = false` (`fn_*_soft_delete`, `fn_*_bulk_delete`). Esto significa que "deshacer una creación" **es, en la práctica, el mismo mecanismo** que ya usa el resto del sistema para eliminar: no hace falta (ni sería seguro) un `DELETE FROM` real, que además rompería la propia auditoría (la fila desaparecería de Postgres pero seguiría "viva" en el historial de ClickHouse) y arriesgaría violar FKs de tablas que ya referencian esa fila.

**Regla implementada**: revertir un INSERT (`operacion = 'c'`) solo se soporta si la tabla tiene columna `active` (se verifica contra `fila_new_raw`, que trae la fila completa tal como quedó insertada). Si no la tiene, se rechaza con `UnsupportedRevertException` — no hay una forma segura de "deshacer la creación" sin ese mecanismo.

## 3. Por qué `DELETE` físico (`operacion = 'd'`) se rechaza en vez de reinsertar

Revertir un `DELETE` físico exigiría reconstruir la fila completa desde `fila_old_raw` con un `INSERT`. Se decidió **no implementarlo en esta fase** porque:

1. **No ocurre hoy** — confirmado en §2, ninguna función de escritura genera esta operación para tablas de negocio de `academico_test`. Implementarlo sería código muerto sin poder probarlo contra un caso real.
2. Si llegara a aparecer (una tabla fuera del patrón, o un cambio futuro), reinsertar a ciegas tiene riesgos que fase 1/2 no cubren: llaves foráneas que la cascada del `DELETE` original pudo borrar también (¿se reinsertan en cascada, o el revert deja huérfanos?), columnas generadas/`DEFAULT` que no calzan con el valor crudo, y triggers `BEFORE INSERT` que pudieron cambiar de comportamiento desde que la fila original se creó.

El endpoint devuelve un mensaje explícito (`UNSUPPORTED_REVERT`, 422) en vez de fallar silenciosamente o intentar algo no validado.

## 4. Diseño del `UPDATE` genérico

Antes (fase 1) solo se comparaba la columna `active`. Ahora:

1. Se leen `fila_new_raw` (estado que dejó el cambio original) y `fila_old_raw` (estado anterior, al que se revierte) — mismo motivo que fase 1 para usar los `_raw` y no `fila_new`/`fila_old` (ver comentario en `AuditRevertService`: `JsonTypedRowBuilder` puede colapsar dos columnas reales bajo el mismo slot genérico).
2. Se calcula la diferencia clave por clave entre ambos mapas (excluyendo la PK, que nunca se revierte). Cada columna cuyo valor cambió se agrega a la lista de cambios a revertir.
3. **Antes de escribir nada**, se relee cada columna afectada desde Postgres y se compara contra lo que el evento original dejó (`fila_new_raw`). Si algo no calza, es porque alguien tocó esa columna después del evento que se quiere revertir — se rechaza con `RevertConflictException` (409) en vez de pisarlo a ciegas. Esto es el mismo principio de conflicto de fase 1, generalizado a N columnas en vez de solo `active`.
4. Se genera un único `UPDATE tabla SET col1 = ?, col2 = ?, ... WHERE pk = ?` con todas las columnas revertidas en la misma sentencia (mismo patrón transaccional que ya usaba fase 1: GUCs de auditoría y el `UPDATE` van en la misma transacción Spring real).

### Limitación conocida: comparación de valores JSON vs. JDBC

Los valores de ClickHouse llegan como JSON (Jackson: `Boolean`/`Integer`/`Long`/`Double`/`String`/`null`) y los de Postgres como objetos JDBC (`Boolean`/`Number`/`BigDecimal`/`String`/`Timestamp`/`null`). La comparación (`jsonValuesEqual`) normaliza ambos lados a texto — suficiente para los tipos simples que cubren la mayoría de columnas de negocio (booleanos, enteros, texto), **pero no está garantizada** para columnas `timestamp`/`jsonb`/`array` con formato ambiguo entre ambos mundos. Se decidió **fallar cerrado**: si la comparación no calza exactamente, se trata como conflicto (rechaza el revert) — nunca se aplica un cambio dudoso. Si en el futuro se necesita revertir columnas de esos tipos de forma confiable, hace falta un comparador dedicado por tipo (fuera de alcance de esta fase).

## 5. Qué NO cambia respecto a fase 1

- La identificación del cambio sigue siendo `(lsn, seq)` — un evento de cambio de fila puntual, no una transacción completa (revertir varias filas de una misma transacción sigue fuera de alcance).
- `dryRun=true` sigue siendo el default — el endpoint muta datos de producción y nunca debe ejecutar por accidente.
- Solo se soportan tablas con una única columna `pk_*` (PK compuesta sigue rechazada).
- El mecanismo de atribución (GUCs `app.user_id`/`app.etiqueta`/`app.contexto`, resolución `uid` → `PK_TUSUARIO` vía `fn_get_academico_usuario_id`) es el mismo que fase 1 — solo se agregó `revert_of_operacion` al contexto para que quede trazable en ClickHouse si el revert fue de un `c` o un `u`.

## 6. Cambios de contrato del DTO de respuesta

`AuditRevertResponse` reemplazó los campos específicos de fase 1 (`activeBefore`/`activeAfter`) por una lista genérica `cambios: [{columna, antes, despues}]`, con un nuevo campo `operacionOriginal` (`c`/`u`) para que el caller sepa qué tipo de reversión se aplicó. No hay consumidores hoy en `admin-ui` (verificado — el endpoint no se usa desde el frontend todavía), así que el cambio de forma no rompe nada existente.
