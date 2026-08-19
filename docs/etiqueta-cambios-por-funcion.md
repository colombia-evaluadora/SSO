# Cambios por función — adopción de `fn_audit_declarar`

> Referencia función por función de lo que cambió cada migración `V67` a `V77` en cada una de las 49 funciones `academico_test.fn_*` de escritura. Complementa [`etiqueta-auditoria-cdc-analisis.md`](etiqueta-auditoria-cdc-analisis.md) (el porqué del diseño) y [`etiqueta-catalogo-funciones-fn.md`](etiqueta-catalogo-funciones-fn.md) (el catálogo original de candidatas). Este documento solo cubre, por función: **en qué posición del cuerpo se insertó la llamada** a `fn_audit_declarar`, y **si se le mandó información extra** (más allá de actor+etiqueta) y de dónde salió.

## El cambio, en una línea

En todas las funciones el cambio es el mismo gesto: agregar

```sql
PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante, format('<texto>', ...) [, <establecimiento_id>]);
```

**una sola vez, justo antes del primer `INSERT`/`UPDATE` que hace la función**, después de que ya pasaron todas las validaciones (`RAISE EXCEPTION`) — así una llamada que termina en error nunca deja una fila de auditoría a medias. `fn_audit_declarar(p_usuario_id, p_etiqueta, p_establecimiento_id, p_sede_id, p_etiquetas)` (`V66`) hace tres cosas con eso: resuelve el actor legible (`app.user_id`), fija el texto de la etiqueta (`app.etiqueta`), y si le pasaron `establecimiento_id`/`sede_id` funde su nombre legible dentro de `app.contexto` (JSON, *merge* no *overwrite* — no pisa lo que ya hubiera ahí). Ninguna de las 49 funciones pasa `p_sede_id` ni `p_etiquetas` (los dos parámetros extra que existen en el helper pero nadie usa todavía) — la única "información extra" real que se manda hoy es `p_establecimiento_id`.

## Cómo leer las tablas

- **Posición**: qué validación es la última que corre antes de la llamada, y qué `INSERT`/`UPDATE` es el primero que corre después.
- **Etiqueta**: el string de `format()` tal cual quedó en la función (sin los valores, solo la plantilla).
- **Info extra**: si se pasó un tercer argumento (`establecimiento_id`) o no, y de dónde sale esa variable — la inmensa mayoría reutiliza una expresión que la función **ya necesitaba** para el chequeo de permisos (`fn_periodo_gate_escritura`/`fn_periodo_usuario_puede_escribir`), no se agregó una consulta nueva solo para esto.

---

## V67 — `fn_grado_*` (prueba de concepto)

| Función | Posición | Etiqueta | Info extra |
|---|---|---|---|
| `fn_grado_crear` | Justo antes del `INSERT INTO TGRADO`, después de validar que no exista ya un grado con ese código en el periodo. | `Creación del grado %s` | Sí — `v_establecimiento_id`, ya resuelto antes vía `fn_periodo_establecimiento(p_fk_periodo)` para el gate de permisos. |
| `fn_grado_actualizar` | Justo antes del `UPDATE TGRADO`, después de validar duplicado de nombre. | `Actualización del grado %s` | Sí — mismo `v_establecimiento_id` reutilizado. |

## V68 — área / asignatura(*subject*) / grupo

| Función | Posición | Etiqueta | Info extra |
|---|---|---|---|
| `fn_area_crear` | Antes del `INSERT INTO TAREA`, tras validar duplicado por código. | `Creación del área %s` | Sí — `v_establecimiento_id` (de `fn_periodo_establecimiento`). |
| `fn_area_actualizar` | Antes del `UPDATE TAREA`, tras validar duplicado por código. | `Actualización del área %s` | Sí — mismo patrón. |
| `fn_area_soft_delete` | Antes del `UPDATE ... SET ACTIVE=FALSE`, tras validar que no tenga asignaturas activas asociadas. | `Eliminación del área %s` (usa `COALESCE(v_nombre, pk::TEXT)` por si el nombre no se pudo resolver). | Sí. |
| `fn_grado_soft_delete` | Antes del `UPDATE` en cascada (grado + criterio de promoción), tras validar que no tenga grupos activos. | `Eliminación del grado %s` | Sí. |
| `fn_grupo_crear` | Antes del `INSERT INTO TGRUPO`, tras validar duplicado de nombre en grado+jornada. | `Creación del grupo %s` | Sí. |
| `fn_grupo_actualizar` | Antes del `UPDATE TGRUPO`, tras la misma validación de duplicado. | `Actualización del grupo %s` | Sí. |
| `fn_grupo_soft_delete` | Antes del `UPDATE ... SET ACTIVE=FALSE`, tras validar que no tenga horarios configurados. | `Eliminación del grupo %s` | Sí. |
| `fn_subject_crear` | Antes del `INSERT INTO TASIGNATURA`, tras validar duplicado de abreviación en el área. | `Creación de la asignatura %s` | Sí — variable `v_est`. |
| `fn_subject_actualizar` | Antes del `UPDATE TASIGNATURA`, misma validación previa. | `Actualización de la asignatura %s` | Sí — `v_establecimiento_id`. |
| `fn_subject_soft_delete` | Antes del `UPDATE ... SET ACTIVE=FALSE`, tras validar que no tenga horarios asociados. | `Eliminación de la asignatura %s` | Sí. |
| `fn_subject_guardar_bulk` | Antes del primer `UPDATE` (baja lógica de las asignaturas que no vienen en el set nuevo), tras el chequeo de permisos sobre el área. | `Configuración masiva de asignaturas del área %s` | Sí — `v_est`. |

## V69 — escalas de valoración

| Función | Posición | Etiqueta | Info extra |
|---|---|---|---|
| `fn_escala_eliminar` | Antes del `UPDATE TESCALA_VALORACION`, justo después de resolver el establecimiento y llamar `fn_periodo_gate_escritura`. | `Eliminación de la banda de valoración %s` | Sí. |
| `fn_escala_guardar_bulk` | Al inicio de la función, inmediatamente después del gate de permisos (antes de cualquier validación de negocio del lote). Es un texto fijo, no un `format()`. | `'Configuración masiva de escalas de valoración'` (literal, sin interpolación) | Sí — `v_establecimiento_id`. |
| `fn_escala_nivel_soft_delete` | Antes del primer `UPDATE` (valoraciones de las bandas), tras validar que no haya bandas en uso por criterios de unidad. | `Eliminación de la escala de valoración del nivel %s` | Sí. |

## V70 — periodo académico / descansos / periodo de evaluación

| Función | Posición | Etiqueta | Info extra |
|---|---|---|---|
| `fn_periodo_crear` | Antes del `INSERT INTO TPERIODO_ACADEMICO`, tras validar que la jornada exista. | `Creación del periodo académico %s - %s` (año lectivo + jornada) | Sí — `v_establecimiento`. |
| `fn_periodo_actualizar` | Antes del `UPDATE TPERIODO_ACADEMICO`, misma validación de jornada. | `Actualización del periodo académico %s - %s` | Sí — `v_establecimiento_id`. |
| `fn_periodo_soft_delete` | Antes del `UPDATE ... SET ACTIVE=FALSE`, tras validar que no existan grados/grupos configurados. | `Eliminación del periodo académico %s` | Sí. |
| `fn_descanso_agregar` | Antes del `INSERT INTO TDESCANSOS`, tras validar que no se traslape con otro descanso existente. | `Agregado de descanso %s-%s al periodo académico` | Sí. |
| `fn_descanso_eliminar` | Antes del `UPDATE TDESCANSOS`, justo después del chequeo de permisos (`fn_periodo_usuario_puede_escribir`). | `Eliminación del descanso %s-%s` | Sí. |
| `fn_periodo_eval_crear` | Antes del `INSERT INTO TPERIODO_EVALUACION`, tras `fn_periodo_eval_validar` (fechas/solapamiento). | `Creación del periodo de evaluación %s` | Sí — `v_establecimiento_id`. |
| `fn_periodo_eval_actualizar` | Antes del `UPDATE TPERIODO_EVALUACION`, misma validación de solapamiento. | `Actualización del periodo de evaluación %s` (usa `COALESCE(p_nombre, r.NOMBRE)` para mostrar el nombre vigente aunque no se edite). | Sí. |
| `fn_periodo_eval_soft_delete` | Antes del `UPDATE ... SET ACTIVE=FALSE`, tras el chequeo de permisos sobre el establecimiento. | `Eliminación del periodo de evaluación %s` | Sí — variable `v_est`. |

## V71 — criterios de evaluación/promoción, plan de estudio, horario, asignación docente

| Función | Posición | Etiqueta | Info extra |
|---|---|---|---|
| `fn_criterio_eval_actualizar` | Antes del `UPDATE TCRITERIO_EVALUACION`, tras leer la escala/formato actuales. | `Actualización del criterio de evaluación del periodo %s` | Sí — `v_establecimiento_id`. |
| `fn_criterio_prom_guardar` | Antes de buscar/crear la fila (criterio general del periodo o override de un grado), tras resolver el nombre del grado si aplica. | `Configuración del criterio de promoción` + (` general del periodo` **o** ` del grado %s`, según si `p_fk_grado` viene o no). | Sí. |
| `fn_plan_agregar` | **Reubicada en `V77`** — originalmente (V71) quedó *después* del `INSERT INTO TPLAN` (el contenedor del plan, creado la primera vez que un grado recibe una asignatura); `V77` la movió a *antes*, junto con el resto (ver abajo). | `Asignación de %s al plan de estudio del grado %s` | Sí. |
| `fn_plan_actualizar` | Antes del `UPDATE TASIGNATURA_PLAN`, tras validar que la nueva asignatura (si cambia) no esté ya en el plan. | `Actualización del plan de estudio: %s en %s` (asignatura + grado) | Sí. |
| `fn_plan_eliminar` | Antes del `UPDATE ... SET ACTIVE=FALSE` (renglón individual del plan), tras validar que no tenga asignaciones docentes activas. | `Eliminación de %s del plan de estudio de %s` | Sí. |
| `fn_plan_soft_delete` | Antes del primer `UPDATE` en cascada (todo el plan del grado), tras validar que ninguna asignatura tenga asignaciones docentes activas. | `Eliminación del plan de estudio completo del grado %s` | Sí. |
| `fn_horario_guardar` | Antes del `UPDATE THORARIO` (desactivación del horario previo del grado), tras tomar el advisory lock y validar que el grado exista. | `Configuración del horario del grado %s` | Sí. |
| `fn_asignacion_guardar` | Antes del `UPDATE TDOCENTE_ASIGNATURA` (desactivación de asignaciones previas), tras validar que el funcionario exista y tomar el advisory lock. | `Asignación académica del docente %s para el periodo %s` | Sí. |

## V72 — establecimiento (soft-delete), catálogo PLAN, funcionario↔establecimiento, sede_usuario (parte 1)

| Función | Posición | Etiqueta | Info extra |
|---|---|---|---|
| `fn_est_soft_delete` | Antes del `UPDATE TESTABLECIMIENTO`, tras validar que no esté ya inactivo. | `Eliminación del establecimiento %s` | **No** — el establecimiento que se está eliminando es la propia entidad de la etiqueta; no aplica pasar su propio id como "contexto adicional". |
| `fn_est_soft_delete_bulk` | Al inicio, tras el chequeo de permisos (`fn_puede_afectar_establecimiento`) y antes del `FOREACH` que llama a `fn_est_soft_delete` por cada uno. Etiqueta agregada del lote — cada llamada individual dentro del loop declara la suya propia (última gana), esta es solo el contexto general previo al loop. | `Eliminación masiva de %s establecimientos` | No. |
| `fn_fun_enlazar_establecimiento` | Antes del `UPDATE TFUNCIONARIO` (fija `FK_ESTABLECIMIENTO`), tras validar que el funcionario esté pendiente de enlazar. | `Vinculación del funcionario %s al establecimiento %s` | Sí — `v_fk_establecimiento` (el establecimiento al que se está vinculando). |
| `fn_sede_usuario_actualizar` | Antes del `UPDATE TSEDE_USUARIO`, tras validar que la jornada exista. | `Actualización de la asignación de sede/rol %s` | No — resolver el establecimiento de un `TSEDE_USUARIO` pediría un `JOIN` extra (sede→establecimiento) que la función no necesitaba antes; se dejó fuera para no agregar una consulta nueva solo para esto. |
| `fn_sede_usuario_soft_delete` | Antes del `UPDATE ... SET ACTIVE=FALSE`, tras el chequeo de idempotencia (si ya estaba inactivo, retorna sin error). | `Eliminación de la asignación de sede/rol %s` | No — mismo motivo. |
| `fn_sed_soft_delete_bulk` | Al inicio, antes del `FOREACH` que llama a `fn_sed_soft_delete` por cada sede. Mismo patrón que `fn_est_soft_delete_bulk`: etiqueta del lote, cada llamada individual pisa la suya. | `Eliminación masiva de %s sedes` | No. |
| `fn_create_plan_from_value` | Antes del `INSERT INTO tlista_valor`, tras validar que no exista ya un valor activo con ese nombre en la categoría `PLAN`. | `Creación del valor de catálogo "%s" (plan de estudio)` | No — es un valor de catálogo global (`TLISTA_VALOR`), no pertenece a un establecimiento. |
| `fn_delete_plan_from_value` | Antes del `UPDATE tlista_valor ... SET active=FALSE`, dentro del `IF v_pk IS NOT NULL`. | `Eliminación del valor de catálogo "%s" (plan de estudio)` | No — mismo motivo. |
| `fn_fun_crear` | Antes del `INSERT INTO TFUNCIONARIO`, tras validar que el usuario no sea ya funcionario activo. | `Creación del funcionario %s` | No — un funcionario recién creado todavía no tiene establecimiento asignado (eso lo hace `fn_fun_enlazar_establecimiento` después, en otra llamada). |

## V73 — sede (soft-delete), sede_usuario (parte 2), usuario

| Función | Posición | Etiqueta | Info extra |
|---|---|---|---|
| `fn_sed_soft_delete` | Antes del `UPDATE TSEDE`, tras el chequeo de permisos. | `Eliminación de la sede %s` | Sí — `v_fk_ee` (el establecimiento dueño de la sede). |
| `fn_sede_usuario_crear` | Antes del `INSERT INTO TSEDE_USUARIO`, tras validar que no exista ya una asignación activa idéntica (sede+rol+usuario+orden). | `Asignación del rol %s al usuario %s en la sede %s` | No — mismo motivo que `fn_sede_usuario_actualizar`/`soft_delete` en V72 (requeriría un `JOIN` sede→establecimiento extra). |
| `fn_usu_crear` | Antes del `INSERT INTO TUSUARIO`, tras validar que el archivo de foto (si viene) exista. | `Creación del usuario %s (cuenta %s)` | No — un usuario nuevo aún no tiene ninguna asignación de sede/establecimiento. |

## V74 — sede (crear/actualizar), establecimiento (crear)

| Función | Posición | Etiqueta | Info extra |
|---|---|---|---|
| `fn_sed_crear` | Antes del `INSERT INTO TSEDE`, tras calcular el consecutivo de sedes del establecimiento. | `Creación de la sede %s (código %s)` | Sí — `p_fk_establecimiento` directamente (el parámetro de entrada, no hizo falta resolver nada). |
| `fn_sed_actualizar` | Antes del `UPDATE TSEDE` (el patrón CTE que detecta columnas cambiadas), justo después del comentario que explica que `MODIFIED_BY`/`MODIFIED_AT` solo se tocan si algo cambió. | `Actualización de la sede %s` | Sí — `v_fk_ee`. |
| `fn_est_crear` | Antes del `INSERT INTO TESTABLECIMIENTO`, tras validar que el archivo del logo (si viene) exista. | `Creación del establecimiento %s` | No — el establecimiento se está creando en esta misma llamada, todavía no tiene PK que pasar como "establecimiento donde ocurrió el cambio" (el cambio *es* la creación de ese establecimiento). |

## V75 — establecimiento (actualizar)

| Función | Posición | Etiqueta | Info extra |
|---|---|---|---|
| `fn_est_actualizar` | Antes del `UPDATE TESTABLECIMIENTO` (patrón CTE de columnas cambiadas), en el mismo punto que `fn_sed_actualizar`. | `Actualización del establecimiento %s` (usa `COALESCE(p_nombre, v_nombre_actual)` para mostrar el nombre vigente aunque no se edite). | Sí — `p_pk_establecimiento` directamente (es la función que edita ese establecimiento, su propia PK ya es el establecimiento_id). |

## V76 — funcionario (actualizar)

| Función | Posición | Etiqueta | Info extra |
|---|---|---|---|
| `fn_fun_actualizar` | Antes de las validaciones de valor (sección 2 de la función), justo después de leer nombre/apellidos actuales del funcionario — necesarios para armar la etiqueta aunque el `PATCH` no traiga esos campos. | `Actualización de datos del funcionario %s` (nombre completo, usando `COALESCE` entre lo nuevo y lo actual campo por campo). | No — esta función no resuelve el establecimiento del funcionario (viene de una tabla distinta, `FK_ESTABLECIMIENTO`, y no se necesitaba antes para el resto de la función); queda como candidato para una iteración futura si Mesa de Ayuda lo pide. Nota: esta es la función que en la prueba end-to-end (§13.2 del análisis) demostró que una sola llamada puede declarar la etiqueta para **dos tablas** (`TUSUARIO` y `TFUNCIONARIO`) en la misma transacción. |

## V77 — corrección de orden en `fn_plan_agregar`

| Función | Qué cambió | Por qué |
|---|---|---|
| `fn_plan_agregar` | Se movió la llamada a `fn_audit_declarar` de **después** del `INSERT INTO TPLAN` a **antes** de él — ahora es lo primero que corre tras la última validación (`RAISE EXCEPTION` de asignatura inexistente/inactiva), antes incluso del `pg_advisory_xact_lock`. | La primera vez que un grado recibe una asignatura, la función crea primero la fila contenedora `TPLAN` (el "plan de estudio" del grado) y luego la fila `TASIGNATURA_PLAN` (el renglón). Como `trg_audit_ctx` es `BEFORE STATEMENT`, el `INSERT INTO TPLAN` original (antes de `V77`) disparaba el trigger **antes** de que `fn_audit_declarar` hubiera fijado `app.etiqueta`/`app.contexto` — esa fila puntual llegaba a ClickHouse vacía, aunque el `INSERT INTO TASIGNATURA_PLAN` que venía después sí quedaba bien etiquetado. Encontrado con la prueba end-to-end real (api-gateway → ClickHouse), no por inspección de código — ver §13.1 de `etiqueta-auditoria-cdc-analisis.md`. |

---

## Funciones excluidas a propósito (no llevan `fn_audit_declarar` propio)

Documentadas también en `etiqueta-auditoria-cdc-analisis.md` §12.2, se repiten aquí por completitud ya que forman parte del mismo universo de 51 funciones candidatas:

| Función | Por qué no |
|---|---|
| `fn_enfasis_desde_seleccion`, `fn_enfasis_resolver`, `fn_escala_propagar` | *Helpers* internos invocados desde dentro de otra función que ya declaró su propia etiqueta. `set_config(..., true)` es "última llamada gana" por transacción — si estos también declararan la suya, pisarían la etiqueta correcta del caller. |
| `fn_fun_soft_delete` | No hace ningún `INSERT`/`UPDATE` propio — delega enteramente en `fn_sede_usuario_soft_delete`, que sí declara. |
| `fn_create_parent_menu_with_submenus` y el resto del grupo legacy/drift de menús y roles | Funciones con drift conocido respecto a producción (§17 de `etiqueta-catalogo-funciones-fn.md`), fuera de alcance de esta iniciativa. |
