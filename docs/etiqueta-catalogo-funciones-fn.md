# Catálogo de funciones `academico_test.fn_*` de escritura y sus etiquetas propuestas

> Fecha: 2026-08-19
> Fuente: introspección directa contra `sso-postgres` en `172.233.184.248` (`\df` + `pg_proc.prosrc` vía `ssh root@172.233.184.248 "docker exec -i sso-postgres psql -U neondb_owner -d sso_db"`), NO el código de `postgres/migrations/` — esto captura el estado **real desplegado**, que puede tener drift respecto a los archivos de migración versionados (ver §4).
> Complementa: [`etiqueta-auditoria-cdc-analisis.md`](etiqueta-auditoria-cdc-analisis.md) — ese documento explica *por qué* la función es el lugar correcto para generar la etiqueta; este documento aplica esa recomendación función por función.

## 1. Método

Se clasificaron las 127 funciones `academico_test.fn_*` desplegadas según si su cuerpo (`pg_proc.prosrc`) contiene `INSERT`, `UPDATE` o `DELETE`. Resultado: **67 funciones de escritura**. Para cada una se extrajeron la firma (`pg_get_function_arguments`) y las líneas relevantes del cuerpo (sentencias DML, `SELECT ... INTO` de nombres legibles, uso de `v_audit`/`p_pk_usuario_solicitante`) para identificar qué variable ya contiene el dato "humano" que debe ir en la etiqueta.

Todas siguen el patrón documentado en el análisis previo: reciben `p_pk_usuario_solicitante` (o, en el módulo de establecimiento/sede/funcionario/usuario, como primer parámetro posicional) y ya resuelven el nombre legible de la entidad afectada antes del DML — por validaciones de negocio que de todas formas necesitan ejecutar.

**Convención de etiqueta propuesta**: `PERFORM set_config('app.etiqueta', <texto>, true);` justo antes del `INSERT`/`UPDATE`/`DELETE` principal, usando `format()` y la(s) variable(s) ya pobladas señaladas en la columna "Dato disponible". Ninguna requiere una consulta adicional.

> **✅ Estado de implementación (actualizado 2026-08-19)**: la adopción real se hizo con el helper `fn_audit_declarar` (no `set_config` directo — ver §6.2 de `etiqueta-auditoria-cdc-analisis.md`) sobre las funciones tal como existen en el Postgres local (rama `origin/dev`), que difieren algo de este catálogo original sacado de prod (§4 abajo ya lo advertía). Resultado: **49 funciones** con `fn_audit_declarar` en su cuerpo — `fn_grado_crear`/`fn_grado_actualizar` (`V67`) más 47 funciones más en `V68`-`V76`. Excluidas a propósito: `fn_enfasis_desde_seleccion`, `fn_enfasis_resolver`, `fn_escala_propagar` (helpers internos, ver estrategia 1 del §20 abajo — es la que se aplicó), `fn_fun_soft_delete` (delega en `fn_sede_usuario_soft_delete`, que sí declara), y el grupo legacy/drift de §17. Detalle completo, migraciones y verificación: §12 de `etiqueta-auditoria-cdc-analisis.md`. Commit `d5b9f9c`, rama `feat/etiqueta-auditoria-cdc` (pusheada a origin).

---

## 2. Establecimiento educativo (`TESTABLECIMIENTO`)

| Función | Operación | Dato disponible | Etiqueta propuesta |
|---|---|---|---|
| `fn_est_crear` | INSERT | `p_nombre` (parámetro, obligatorio) | `format('Creación del establecimiento %s', p_nombre)` |
| `fn_est_actualizar` | UPDATE | `v_nombre_actual` (SELECT previo), `p_nombre` si cambia | `format('Actualización del establecimiento %s', COALESCE(p_nombre, v_nombre_actual))` |
| `fn_est_soft_delete` | UPDATE (ACTIVE=FALSE) + cascada a sedes | nombre no se lee hoy — agregar `SELECT NOMBRE INTO v_nombre FROM TESTABLECIMIENTO WHERE PK_ESTABLECIMIENTO=p_pk_establecimiento` (una línea) | `format('Eliminación del establecimiento %s', v_nombre)` |
| `fn_est_soft_delete_bulk` | llama a `fn_est_soft_delete` en loop sobre `p_pks` | — | `format('Eliminación masiva de %s establecimientos', array_length(p_pks,1))` (agregado antes del loop; cada llamada individual ya deja su propia etiqueta si se declara dentro de `fn_est_soft_delete`, pero como es `PERFORM` sin nueva transacción, la última sobrescribe — ver nota §5) |

## 3. Sede (`TSEDE`)

| Función | Operación | Dato disponible | Etiqueta propuesta |
|---|---|---|---|
| `fn_sed_crear` | INSERT | `p_nombre`, `p_codigo` (parámetros) | `format('Creación de la sede %s (código %s)', p_nombre, p_codigo)` |
| `fn_sed_actualizar` | UPDATE | `current.NOMBRE` (fila previa ya seleccionada), `p_nombre` si cambia | `format('Actualización de la sede %s', COALESCE(p_nombre, current.NOMBRE))` |
| `fn_sed_soft_delete` | UPDATE (ACTIVE=FALSE), cascada usuarios/niveles | agregar `SELECT NOMBRE INTO v_nombre FROM TSEDE WHERE PK_TSEDE=p_pk_sede` | `format('Eliminación de la sede %s', v_nombre)` |
| `fn_sed_soft_delete_bulk` | loop sobre `fn_sed_soft_delete` | — | `format('Eliminación masiva de %s sedes', array_length(p_pks,1))` |

## 4. Vínculo sede–usuario–rol (`TSEDE_USUARIO`)

| Función | Operación | Dato disponible | Etiqueta propuesta |
|---|---|---|---|
| `fn_sede_usuario_crear` | INSERT | ids crudos (`p_fk_sede`, `p_fk_rol`, `p_fk_usuario`) — **no hay nombre resuelto hoy**; agregar 2 `SELECT NOMBRE`/nombre de usuario si se quiere calidad completa | mínimo viable: `format('Asignación del rol %s al usuario %s en la sede %s', p_fk_rol, p_fk_usuario, p_fk_sede)` (con IDs); ideal: resolver nombres de rol/sede y nombre+apellido del usuario primero |
| `fn_sede_usuario_actualizar` | UPDATE | igual — sin nombre resuelto hoy | `format('Actualización de la asignación de sede/rol %s', p_pk_sede_usuario)` (mejorable con `SELECT` a `TROL`/`TUSUARIO`) |
| `fn_sede_usuario_soft_delete` | UPDATE (ACTIVE=FALSE) | igual | `format('Eliminación de la asignación de sede/rol %s', p_pk_sede_usuario)` |

> Este módulo es el más débil hoy en términos de "dato legible ya disponible" — es justamente el caso de uso que más valor tiene para soporte ("¿quién le quitó el rol admin a X en la sede Y?"), así que vale la pena invertir en 1-2 `SELECT` extra aquí aunque no sean gratis.

## 5. Funcionario / docente (`TFUNCIONARIO`)

| Función | Operación | Dato disponible | Etiqueta propuesta |
|---|---|---|---|
| `fn_fun_crear` | INSERT | `p_primer_nombre`, `p_primer_apellido` (+ segundo nombre/apellido, todos parámetros) | `format('Creación del funcionario %s', trim(concat_ws(' ', p_primer_nombre, p_segundo_nombre, p_primer_apellido, p_segundo_apellido)))` |
| `fn_fun_actualizar` | UPDATE (función de 43 parámetros — la más grande del catálogo) | nombre actual no está en una variable visible en el extracto — agregar `SELECT` de `TFUNCIONARIO`/`TUSUARIO` antes del UPDATE, o construir con `COALESCE(p_primer_nombre, ...)` contra la fila actual (mismo patrón que `fn_est_actualizar`) | `format('Actualización de datos del funcionario %s', v_nombre_completo)` |
| `fn_fun_soft_delete` | UPDATE (ACTIVE=FALSE) | igual — agregar `SELECT` de nombre antes de dar de baja | `format('Eliminación del funcionario %s', v_nombre_completo)` |
| `fn_fun_baja_establecimiento` | UPDATE (2x ACTIVE=FALSE, desvincula de sede/establecimiento) | igual | `format('Desvinculación del funcionario %s del establecimiento', v_nombre_completo)` |
| `fn_fun_enlazar_establecimiento` | UPDATE | igual | `format('Vinculación del funcionario %s al establecimiento', v_nombre_completo)` |

> `fn_fun_actualizar` y `fn_fun_crear` son las funciones de escritura más grandes del sistema (30 KB / 7 KB de cuerpo, 43 y 15 parámetros respectivamente — datos de RRHH docente completos: identificación, escalafón, vinculación, amenaza, etc.). Es el ejemplo más claro del pedido original del usuario ("Eliminación del permiso de acceso para el docente X") — soporte hoy tendría que cruzar `FK_TUSUARIO`/`FK_TLV_*` a mano para saber de quién se habla.

## 6. Usuario (`TUSUARIO`)

| Función | Operación | Dato disponible | Etiqueta propuesta |
|---|---|---|---|
| `fn_usu_crear` | INSERT | `p_primer_nombre`, `p_primer_apellido`, `p_cuenta` (parámetros) | `format('Creación del usuario %s (cuenta %s)', trim(concat_ws(' ', p_primer_nombre, p_segundo_nombre, p_primer_apellido, p_segundo_apellido)), p_cuenta)` — calca literalmente el ejemplo "Creación del usuario Jorge Sánchez" del pedido original |

> No existe hoy `fn_usu_actualizar` ni `fn_usu_soft_delete` en el catálogo de escritura detectado — si existen como parte de otro flujo (p. ej. `fn_fun_actualizar` actualiza también campos de `TUSUARIO` internamente), revisar si conviene declarar la etiqueta ahí también.

## 7. Periodo académico (`TPERIODO_ACADEMICO`, `TANO_LECTIVO`, `TDESCANSOS`)

| Función | Operación | Dato disponible | Etiqueta propuesta |
|---|---|---|---|
| `fn_periodo_crear` | INSERT (+ `TCRITERIO_EVALUACION`, `TDESCANSOS`) | `v_nombre_sede`, `v_nombre_ano`, `v_nombre_jornada` (ya resueltos) | `format('Creación del periodo académico %s - %s en la sede %s', v_nombre_ano, v_nombre_jornada, v_nombre_sede)` |
| `fn_periodo_actualizar` | UPDATE | `v_nombre_sede`, `v_nombre_ano`, `v_nombre_jornada` (ya resueltos) | `format('Actualización del periodo académico %s - %s (sede %s)', v_nombre_ano, v_nombre_jornada, v_nombre_sede)` |
| `fn_periodo_soft_delete` | UPDATE (ACTIVE=FALSE), cascada extensa (horarios, planes, criterios, escalas, grados) | `v_nombre_periodo` (ya resuelto) | `format('Eliminación del periodo académico %s', v_nombre_periodo)` |
| `fn_descanso_agregar` | INSERT | `p_hora_inicio`/`p_hora_fin` (parámetros); nombre del periodo no resuelto aún | `format('Agregado de descanso %s-%s al periodo académico', p_hora_inicio, p_hora_fin)` |
| `fn_descanso_eliminar` | UPDATE (ACTIVE=FALSE) | `v_tmp_hi`/`v_tmp_hf` (horas ya seleccionadas) | `format('Eliminación del descanso %s-%s', v_tmp_hi, v_tmp_hf)` |

## 8. Periodo de evaluación (`TPERIODO_EVALUACION`)

| Función | Operación | Dato disponible | Etiqueta propuesta |
|---|---|---|---|
| `fn_periodo_eval_crear` | INSERT | `p_nombre` (parámetro) | `format('Creación del periodo de evaluación %s', p_nombre)` |
| `fn_periodo_eval_actualizar` | UPDATE | `r.NOMBRE` (fila previa), `p_nombre` si cambia | `format('Actualización del periodo de evaluación %s', COALESCE(p_nombre, r.NOMBRE))` |
| `fn_periodo_eval_soft_delete` | UPDATE (ACTIVE=FALSE) | `v_nombre_periodo_eval` (ya resuelto) | `format('Eliminación del periodo de evaluación %s', v_nombre_periodo_eval)` |

## 9. Criterios de evaluación y promoción (`TCRITERIO_EVALUACION`, `TCRITERIO_PROMOCION`)

`fn_criterio_eval_actualizar` tiene **3 sobrecargas activas simultáneamente** (drift entre versiones — mismo nombre, distintos parámetros: `p_grading_scale` vs `p_pk_tescala_valoracion`, con/sin `p_modif_final_peraca`, `p_max_recovery_grade`). Ver §4 — antes de tocar esta función conviene resolver cuál sobrecarga es la vigente.

| Función | Operación | Dato disponible | Etiqueta propuesta |
|---|---|---|---|
| `fn_criterio_eval_actualizar` (todas las sobrecargas) | UPDATE `TCRITERIO_EVALUACION` | `v_tmp_nombre2` = nombre del `TPERIODO_ACADEMICO` (ya resuelto en validaciones) | `format('Actualización del criterio de evaluación del periodo %s', v_tmp_nombre2)` |
| `fn_criterio_prom_guardar` | INSERT/UPDATE `TCRITERIO_PROMOCION` + `TCRITERIO_PROMOCION_ASIGNATURA_OBLIGATORIA` | grado (`p_fk_grado`) opcionalmente NULL = "criterio general del periodo"; agregar `SELECT NOMBRE` de `TGRADO` si no NULL | `format('Configuración del criterio de promoción%s', CASE WHEN p_fk_grado IS NULL THEN ' general del periodo' ELSE format(' del grado %s', v_nombre_grado) END)` |

## 10. Escalas de valoración (`TESCALA`, `TESCALA_VALORACION`, `TVALORACION`, `TNIVEL_ESCALA`)

| Función | Operación | Dato disponible | Etiqueta propuesta |
|---|---|---|---|
| `fn_escala_guardar_bulk` | INSERT masivo (`TESCALA`, `TNIVEL_ESCALA`, `TVALORACION`, `TESCALA_VALORACION`) | `v_nivel_nom` (nombre del nivel de enseñanza, ya resuelto) | `format('Configuración de la escala de valoración del nivel %s', v_nivel_nom)` |
| `fn_escala_eliminar` | UPDATE (ACTIVE=FALSE) sobre `TESCALA_VALORACION` | `v_nombre` (nombre de la banda, ya resuelto) | `format('Eliminación de la banda de valoración %s', v_nombre)` |
| `fn_escala_nivel_soft_delete` | UPDATE en cascada (`TVALORACION`→`TESCALA_VALORACION`→`TNIVEL_ESCALA`→`TESCALA`) | `v_nivel_nombre` (ya resuelto) | `format('Eliminación de la escala de valoración del nivel %s', v_nivel_nombre)` |
| `fn_escala_bulk_delete` | UPDATE masivo (4 tablas en cascada) | `v_nombre_escala` (ya resuelto) | `format('Eliminación masiva de escalas — incluye %s', v_nombre_escala)` |
| `fn_escala_propagar` | INSERT (`TVALORACION`, `TESCALA_VALORACION`) — función interna, llamada desde `fn_criterio_eval_actualizar` | recibe `p_audit` ya armado por el caller | heredar la etiqueta del caller (no declarar una propia — ver nota §5 sobre "quién manda al final gana") |

## 11. Grado y grupo (`TGRADO`, `TGRUPO`)

| Función | Operación | Dato disponible | Etiqueta propuesta |
|---|---|---|---|
| `fn_grado_crear` | INSERT | `v_nombre` (parámetro validado) | `format('Creación del grado %s', v_nombre)` |
| `fn_grado_actualizar` | UPDATE | `v_nombre` = `COALESCE(p_nombre, r.NOMBRE)` | `format('Actualización del grado %s', v_nombre)` |
| `fn_grado_soft_delete` | UPDATE en cascada (criterio promoción + grado) | `v_nombre_grado` (ya resuelto) | `format('Eliminación del grado %s', v_nombre_grado)` |
| `fn_grupo_crear` | INSERT | `p_nombre`, `v_nombre_director` (nombre del director ya resuelto) | `format('Creación del grupo %s%s', p_nombre, CASE WHEN v_nombre_director IS NOT NULL THEN format(' (director: %s)', v_nombre_director) ELSE '' END)` |
| `fn_grupo_actualizar` | UPDATE | `v_nombre` = `COALESCE(p_nombre, r.NOMBRE)` | `format('Actualización del grupo %s', v_nombre)` |
| `fn_grupo_soft_delete` | UPDATE (ACTIVE=FALSE) | `v_nombre_grupo` (ya resuelto) | `format('Eliminación del grupo %s', v_nombre_grupo)` |

## 12. Área y asignatura (`TAREA`, `TASIGNATURA`, `TAREA_ASIGNATURA`)

| Función | Operación | Dato disponible | Etiqueta propuesta |
|---|---|---|---|
| `fn_area_crear` | INSERT | `p_nombre_interno` | `format('Creación del área %s', p_nombre_interno)` |
| `fn_area_actualizar` | UPDATE | `v_nombre` = `COALESCE(p_nombre_interno, r.NOMBRE)` | `format('Actualización del área %s', v_nombre)` |
| `fn_area_soft_delete` | UPDATE (ACTIVE=FALSE) | `v_nombre` (ya resuelto) | `format('Eliminación del área %s', v_nombre)` |
| `fn_subject_crear` | INSERT | `p_nombre_interno` | `format('Creación de la asignatura %s', p_nombre_interno)` |
| `fn_subject_actualizar` | UPDATE | `v_nombre` = `COALESCE(p_nombre_interno, r.NOMBRE)` | `format('Actualización de la asignatura %s', v_nombre)` |
| `fn_subject_soft_delete` | UPDATE (ACTIVE=FALSE) | `v_nombre` (ya resuelto) — **el mensaje de error de esta función ya menciona "existen calificaciones registradas"**, la primera referencia real a notas en el catálogo | `format('Eliminación de la asignatura %s', v_nombre)` |
| `fn_subject_guardar_bulk` | INSERT/UPDATE masivo dentro de un `jsonb` | `v_nombre` por cada elemento del loop | `format('Configuración masiva de asignaturas del área %s', v_nombre_area)` (a nivel de llamada completa, no por fila — ver nota §5) |

## 13. Énfasis y especialidad (`TENFASIS`, `TESPECIALIDAD`)

| Función | Operación | Dato disponible | Etiqueta propuesta |
|---|---|---|---|
| `fn_enfasis_actualizar` (2 sobrecargas) | UPDATE | `v_nombre` = `COALESCE(p_nombre, r.NOMBRE)` | `format('Actualización del énfasis %s', v_nombre)` |
| `fn_enfasis_soft_delete` | UPDATE (ACTIVE=FALSE) | `v_nombre` (ya resuelto) | `format('Eliminación del énfasis %s', v_nombre)` |
| `fn_enfasis_desde_seleccion` | INSERT (crea énfasis on-the-fly desde una especialidad) — función interna, llamada desde `fn_subject_*` | `v_nombre` (nombre de la especialidad) | `format('Creación automática del énfasis %s', v_nombre)` — considerar si vale la pena o si debe heredar del caller |
| `fn_enfasis_resolver` | INSERT (upsert de énfasis por nombre) — función interna | `p_nombre` (parámetro) | igual — probable candidata a "heredar del caller" en vez de declarar la suya |

## 14. Plan de estudio (`TPLAN`, `TASIGNATURA_PLAN`)

| Función | Operación | Dato disponible | Etiqueta propuesta |
|---|---|---|---|
| `fn_plan_agregar` | INSERT | `v_grado_nom`, `v_asignatura_nom` (ambos ya resueltos) | `format('Asignación de %s al plan de estudio del grado %s', v_asignatura_nom, v_grado_nom)` |
| `fn_plan_actualizar` | UPDATE | `v_asignatura_nom`, `v_grado_nom` (ambos ya resueltos) | `format('Actualización del plan de estudio: %s en %s', v_asignatura_nom, v_grado_nom)` |
| `fn_plan_eliminar` | UPDATE (ACTIVE=FALSE) | `v_asignatura_nom`, `v_grado_nom` (ambos ya resueltos) | `format('Eliminación de %s del plan de estudio de %s', v_asignatura_nom, v_grado_nom)` |
| `fn_plan_soft_delete` | UPDATE en cascada (plan completo de un grado) | `v_grado_nom` (ya resuelto) | `format('Eliminación del plan de estudio completo del grado %s', v_grado_nom)` |

## 15. Horario (`THORARIO`)

| Función | Operación | Dato disponible | Etiqueta propuesta |
|---|---|---|---|
| `fn_horario_guardar` | INSERT masivo (vía tabla temporal `tmp_horario_entries`) | `v_nombre_grado` (ya resuelto) | `format('Configuración del horario del grado %s', v_nombre_grado)` |

## 16. Asignación docente (`TDOCENTE_ASIGNATURA`)

| Función | Operación | Dato disponible | Etiqueta propuesta |
|---|---|---|---|
| `fn_asignacion_guardar` | INSERT (+ UPDATE ACTIVE=FALSE de asignaciones previas) | `v_nombre_funcionario` (nombre completo ya resuelto vía `concat_ws`), `v_nombre_periodo` | `format('Asignación académica del docente %s para el periodo %s', v_nombre_funcionario, v_nombre_periodo)` — este es el ejemplo más cercano al "Eliminación del permiso de acceso para el docente X" del pedido original |

## 17. Menús y roles — **drift conocido, no priorizar** (`TMENU`, `TROL`, `TROL_MENU`, `public.role*`)

Estas funciones corresponden al experimento de menús/roles revertido que ya está documentado como pendiente de limpieza (`v59_cleanup_drift.sql`, memoria `V59 server drift cleanup pending`). **No se recomienda invertir en etiquetas aquí hasta decidir si se limpian o se quedan**, porque construir la convención sobre código que puede desaparecer es trabajo desechable.

| Función | Operación | Nota |
|---|---|---|
| `fn_add_trol` | INSERT `academico_test.trol` | firma vieja (`p_user_pk, p_nombre, p_created_by, p_estado`) — de las que la limpieza de drift debería reemplazar |
| `fn_upsert_menu` | INSERT/UPDATE `academico_test.tmenu` | cuerpo de 14 KB, 3 variantes de validación concatenadas (indicio de parches sucesivos sin limpiar código muerto) |
| `fn_delete_menu` | UPDATE (ACTIVE=FALSE) `tmenu` | — |
| `fn_reorder_menus` | UPDATE `orden` en `tmenu` | reordenamiento, bajo valor de etiqueta (no hay "qué cambió" legible, es una lista de posiciones) |
| `fn_associate_menus_to_rol` / `fn_dissociate_menus_from_rol` | INSERT/UPDATE `trol_menu` | firma vieja según memoria de drift |
| `fn_sincronizar_rol_publico` | INSERT/DELETE `public.role_users` | sync interno, no invocado directo por usuario final probablemente |
| `fn_sync_trol_to_public_role`, `fn_sync_tsede_usuario_to_role_users` | INSERT `public.role*` | funciones "sync" sin parámetros — llamadas por trigger o batch, no por request de usuario; **no hay actor que atribuir** (no reciben `p_pk_usuario_solicitante`) |
| `fn_sync_users_password_to_tusuario` | UPDATE contraseña en `TUSUARIO` | igual — sync interno, sin actor de request |

## 18. Catálogo de listas de valor (`TLISTA_VALOR`)

| Función | Operación | Dato disponible | Etiqueta propuesta |
|---|---|---|---|
| `fn_create_plan_from_value` | INSERT (categoría `PLAN`) | `v_nombre` (parámetro) | `format('Creación del valor de catálogo "%s" (plan de estudio)', v_nombre)` |
| `fn_delete_plan_from_value` | UPDATE (ACTIVE=FALSE) | `p_nombre` (parámetro) | `format('Eliminación del valor de catálogo "%s" (plan de estudio)', p_nombre)` |

---

## 19. Nota sobre las 3 funciones de escritura más grandes

`fn_est_actualizar` (32 KB), `fn_fun_actualizar` (31 KB) y `fn_upsert_menu`/`fn_periodo_actualizar`/`fn_sed_crear`/`fn_est_crear` (9-17 KB) concentran la mayoría de parámetros opcionales del sistema — son los "formularios grandes" de establecimiento, funcionario y menú. Para estas, la etiqueta genérica ("Actualización de X") es menos útil que en las funciones pequeñas, porque un `UPDATE` con 30 columnas `COALESCE` puede estar cambiando 1 campo trivial o 20 campos críticos. Vale la pena, solo para estas 2-3 funciones, evaluar una etiqueta que liste **qué cambió** (no solo quién), aprovechando que `fn_est_actualizar` ya calcula flags `chg_codigo`, `chg_nombre`, etc. (línea 359 del extracto) — ese patrón ya existe para otro propósito (probablemente para decidir si dispara alguna otra rutina) y se puede reusar:

```sql
-- fn_est_actualizar ya tiene estos booleanos calculados (línea ~359):
--   chg_codigo, chg_nombre, ...
-- Reusarlos para una etiqueta más rica que solo "actualización":
PERFORM set_config('app.etiqueta', format(
    'Actualización del establecimiento %s (%s)',
    COALESCE(p_nombre, v_nombre_actual),
    array_to_string(ARRAY[
        CASE WHEN chg_codigo THEN 'código' END,
        CASE WHEN chg_nombre THEN 'nombre' END
        -- ... resto de flags chg_*
    ] FILTER (WHERE ... IS NOT NULL), ', ')
), true);
```

## 20. Nota sobre funciones anidadas (§5 referida arriba)

Varias funciones se llaman entre sí dentro de la misma transacción (`fn_subject_crear` → `fn_enfasis_desde_seleccion`, `fn_criterio_eval_actualizar` → `fn_escala_propagar`, `fn_est_soft_delete` → `fn_sed_soft_delete`, `fn_sed/est_soft_delete_bulk` → `fn_sed/est_soft_delete` en loop). Como `set_config(..., true)` es *local a la transacción*, no a la sentencia, **la última llamada gana** — si una función interna declara su propia etiqueta después de que la externa ya declaró la suya, la sobrescribe. Dos estrategias razonables:

1. **Solo la función "de entrada" (la que expone `query-service`) declara la etiqueta** — las funciones internas (`fn_escala_propagar`, `fn_enfasis_desde_seleccion`, `fn_enfasis_resolver`) no deberían llamar `set_config('app.etiqueta', ...)` nunca, para no pisar la etiqueta más específica que ya puso el caller. Es la opción más simple y la recomendada por defecto.
2. Para los `*_bulk`/`*_soft_delete_bulk` que hacen loop sobre la función singular (`fn_est_soft_delete_bulk` → N × `fn_est_soft_delete`), declarar la etiqueta agregada ("Eliminación masiva de N establecimientos") **antes** del loop y no dentro de la función singular cuando se invoca en modo bulk — o aceptar que solo quede registrada la del último elemento procesado (aceptable si el nombre de tabla + el conteo de filas del batch ya da contexto suficiente en `auditoria.audit_log`, dado que todas comparten `xid`).

---

## 21. Resumen cuantitativo

| Categoría | Cantidad |
|---|---|
| Funciones `fn_*` totales desplegadas en `academico_test` | 127 |
| Funciones de escritura (INSERT/UPDATE/DELETE) | 67 |
| Con dato legible ya resuelto en variable antes del DML (etiqueta ~gratis) | ~55 |
| Requieren agregar 1 `SELECT` extra para tener nombre legible (`fn_sede_usuario_*`, `fn_est_soft_delete`, `fn_sed_soft_delete`, `fn_fun_actualizar`/`fn_fun_soft_delete`) | ~10 |
| Legacy/drift — no priorizar (menús, roles, syncs internos) | 10 |
| Sobrecargas duplicadas a resolver antes de tocar (`fn_criterio_eval_actualizar` ×3, `fn_enfasis_actualizar` ×2) | 2 nombres, 5 firmas |

**Prioridad sugerida de implementación** (mayor valor de soporte / menor costo primero): §5 Funcionario, §16 Asignación docente, §11 Grado/Grupo, §6 Usuario, §12 Área/Asignatura, §14 Plan de estudio — todas ya tienen el nombre legible resuelto, cero `SELECT` adicional, y son las entidades que más se prestan a reclamos de "¿quién cambió esto de fulano?". Dejar §4 (sede-usuario, requiere 1-2 SELECT nuevos) y §17 (drift) para una segunda pasada.
