# Mapa del dominio

**Generado** por `python scripts/generar-mapa.py` — no editar a mano.
Estado: 331 migraciones (V1–V406), 505 funciones vivas, 103 endpoints vivos. Ultima generacion: 2026-09-15.

Para una **funcion**, la migracion dueña es la que hay que editar: es su ultima escritura viva, no la que la creo.

Para un **endpoint** se listan todas las migraciones que lo tocan, sin elegir dueño: una migracion que clona una fila hermana tambien la menciona, y desde el SQL no se distingue. La columna de funciones es aproximada por el mismo motivo — son las funciones que invocan esas migraciones, no solo esa ruta.

El detalle exacto (historial, firmas, dependencias) sale de `python .claude/skills/next-migration-number/deps.py <nombre|ruta>` y `deps.py --version <n>`.

## Indice

- [(transversal)](#transversal) — 14 funcion(es), 0 endpoint(s)
- [academico](#academico) — 1 funcion(es), 0 endpoint(s)
- [actividad](#actividad) — 62 funcion(es), 0 endpoint(s)
- [app](#app) — 1 funcion(es), 0 endpoint(s)
- [area](#area) — 7 funcion(es), 0 endpoint(s)
- [asignacion](#asignacion) — 5 funcion(es), 0 endpoint(s)
- [asignatura](#asignatura) — 6 funcion(es), 0 endpoint(s)
- [asistencia](#asistencia) — 19 funcion(es), 1 endpoint(s)
- [audit](#audit) — 0 funcion(es), 5 endpoint(s)
- [audit-table](#audit-table) — 0 funcion(es), 7 endpoint(s)
- [available](#available) — 1 funcion(es), 0 endpoint(s)
- [cat](#cat) — 5 funcion(es), 0 endpoint(s)
- [catalogo](#catalogo) — 0 funcion(es), 4 endpoint(s)
- [criterio](#criterio) — 7 funcion(es), 0 endpoint(s)
- [cumplimiento](#cumplimiento) — 3 funcion(es), 1 endpoint(s)
- [descanso](#descanso) — 2 funcion(es), 0 endpoint(s)
- [docente](#docente) — 6 funcion(es), 0 endpoint(s)
- [documento](#documento) — 5 funcion(es), 1 endpoint(s)
- [enfasi](#enfasi) — 4 funcion(es), 0 endpoint(s)
- [ente](#ente) — 8 funcion(es), 0 endpoint(s)
- [es](#es) — 2 funcion(es), 0 endpoint(s)
- [escala](#escala) — 8 funcion(es), 0 endpoint(s)
- [especialidad](#especialidad) — 1 funcion(es), 0 endpoint(s)
- [est](#est) — 17 funcion(es), 0 endpoint(s)
- [establecimiento](#establecimiento) — 0 funcion(es), 2 endpoint(s)
- [estudiante](#estudiante) — 5 funcion(es), 0 endpoint(s)
- [fun](#fun) — 19 funcion(es), 0 endpoint(s)
- [funcionario](#funcionario) — 2 funcion(es), 2 endpoint(s)
- [grade](#grade) — 2 funcion(es), 0 endpoint(s)
- [grado](#grado) — 9 funcion(es), 0 endpoint(s)
- [grupo](#grupo) — 9 funcion(es), 0 endpoint(s)
- [horario](#horario) — 4 funcion(es), 0 endpoint(s)
- [instrumento](#instrumento) — 2 funcion(es), 0 endpoint(s)
- [jornada](#jornada) — 1 funcion(es), 0 endpoint(s)
- [matricula](#matricula) — 47 funcion(es), 0 endpoint(s)
- [menu](#menu) — 2 funcion(es), 5 endpoint(s)
- [mi](#mi) — 3 funcion(es), 0 endpoint(s)
- [microservice](#microservice) — 1 funcion(es), 0 endpoint(s)
- [nivel](#nivel) — 1 funcion(es), 0 endpoint(s)
- [nodo](#nodo) — 1 funcion(es), 0 endpoint(s)
- [nota](#nota) — 1 funcion(es), 0 endpoint(s)
- [padre](#padre) — 4 funcion(es), 0 endpoint(s)
- [parent](#parent) — 1 funcion(es), 0 endpoint(s)
- [periodo](#periodo) — 29 funcion(es), 0 endpoint(s)
- [personalizar](#personalizar) — 4 funcion(es), 0 endpoint(s)
- [pigse](#pigse) — 15 funcion(es), 0 endpoint(s)
- [plan](#plan) — 13 funcion(es), 1 endpoint(s)
- [planeador](#planeador) — 5 funcion(es), 66 endpoint(s)
- [planilla](#planilla) — 5 funcion(es), 0 endpoint(s)
- [prematricula](#prematricula) — 2 funcion(es), 0 endpoint(s)
- [puede](#puede) — 2 funcion(es), 0 endpoint(s)
- [rango](#rango) — 4 funcion(es), 0 endpoint(s)
- [refcurr](#refcurr) — 11 funcion(es), 0 endpoint(s)
- [refenunc](#refenunc) — 5 funcion(es), 0 endpoint(s)
- [referente](#referente) — 2 funcion(es), 0 endpoint(s)
- [reorder](#reorder) — 1 funcion(es), 0 endpoint(s)
- [resolver](#resolver) — 3 funcion(es), 0 endpoint(s)
- [rol](#rol) — 2 funcion(es), 0 endpoint(s)
- [role](#role) — 1 funcion(es), 4 endpoint(s)
- [sed](#sed) — 17 funcion(es), 0 endpoint(s)
- [sede](#sede) — 6 funcion(es), 0 endpoint(s)
- [select](#select) — 0 funcion(es), 2 endpoint(s)
- [sincronizar](#sincronizar) — 1 funcion(es), 0 endpoint(s)
- [subject](#subject) — 6 funcion(es), 0 endpoint(s)
- [superadmin](#superadmin) — 1 funcion(es), 0 endpoint(s)
- [tactividad](#tactividad) — 3 funcion(es), 0 endpoint(s)
- [trg](#trg) — 1 funcion(es), 0 endpoint(s)
- [trol](#trol) — 3 funcion(es), 0 endpoint(s)
- [tsede](#tsede) — 1 funcion(es), 0 endpoint(s)
- [tunidad](#tunidad) — 1 funcion(es), 0 endpoint(s)
- [tusuario](#tusuario) — 1 funcion(es), 0 endpoint(s)
- [unidad](#unidad) — 33 funcion(es), 0 endpoint(s)
- [user](#user) — 2 funcion(es), 0 endpoint(s)
- [usu](#usu) — 9 funcion(es), 0 endpoint(s)
- [usuario](#usuario) — 17 funcion(es), 2 endpoint(s)
- [validar](#validar) — 1 funcion(es), 0 endpoint(s)

## (transversal)

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_assert_permiso_funcionario` | 3 | V29 | V51, V72, V199, V300 |
| `academico_test.fn_assert_permiso_seccion` | 6 | V29 | V37, V39, V40, V51, V52, V53… |
| `academico_test.fn_audit_ctx` | 0 | V184 | V88, V256, V261, V276, V283, V378 |
| `academico_test.fn_audit_declarar` | 5 | V66 | V37, V38, V39, V40, V41, V42… |
| `academico_test.fn_cdc_asegurar_auditoria` | 2 | V283 | — |
| `academico_test.fn_cdc_evento_tabla_nueva` | 0 | V283 | — |
| `academico_test.fn_delete_menu` | 2 | V115 | V126 |
| `academico_test.fn_list_menu_possibilities_for_rol` | 2 | V113 | — |
| `academico_test.fn_menu_codigo_canonico` | 1 | V396 | — |
| `academico_test.fn_menu_grupo_de` | 1 | V396 | — |
| `academico_test.fn_upsert_menu` | 11 | V113 | V126 |
| `pigse.fn_assert_permiso_funcionario` | 3 | V370 | V386, V390, V393 |
| `pigse.fn_assert_permiso_seccion` | 6 | V370 | V371, V386 |
| `pigse.fn_audit_declarar` | 4 | V362 | V394 |

## academico

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `public.fn_get_academico_usuario_id` | 1 | V299 | V64, V67, V69, V75, V76, V77… |

## actividad

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_actividad_actualizar` | 35 | V224 | V246 |
| `academico_test.fn_actividad_adaptacion_reemplazar` | 3 | V224 | V246 |
| `academico_test.fn_actividad_buscar_por_pk` | 3 | V224 | V246, V272, V353 |
| `academico_test.fn_actividad_calendario` | 8 | V251 | V251 |
| `academico_test.fn_actividad_calendario_docente` | 7 | V251 | — |
| `academico_test.fn_actividad_campos_disponibles` | 2 | V214.2 | V224, V246 |
| `academico_test.fn_actividad_cotejo_definir` | 3 | V226 | V240, V274, V340 |
| `academico_test.fn_actividad_crear` | 35 | V224 | V246, V274, V340 |
| `academico_test.fn_actividad_criterio_quitar` | 2 | V214.1 | V246 |
| `academico_test.fn_actividad_criterio_relacionar` | 3 | V214.1 | V224, V246 |
| `academico_test.fn_actividad_disponibles_listar` | 5 | V223 | V246 |
| `academico_test.fn_actividad_eliminar` | 2 | V224 | V246 |
| `academico_test.fn_actividad_es_formativa` | 1 | V243 | — |
| `academico_test.fn_actividad_escala_definir` | 3 | V226 | V240, V274, V340 |
| `academico_test.fn_actividad_estado` | 5 | V224 | V251 |
| `academico_test.fn_actividad_estudiante_actividad` | 1 | V227 | V241, V243 |
| `academico_test.fn_actividad_estudiantes_asignar` | 4 | V224 | — |
| `academico_test.fn_actividad_estudiantes_calificaciones_listar` | 4 | V227 | V247 |
| `academico_test.fn_actividad_evaluacion_requerida` | 1 | V214.2 | — |
| `academico_test.fn_actividad_evidencia_quitar` | 2 | V214.1 | V246 |
| `academico_test.fn_actividad_evidencia_relacionar` | 3 | V214.1 | V224, V246 |
| `academico_test.fn_actividad_exportar` | 5 | V272 | V129, V273 |
| `academico_test.fn_actividad_finalizacion_refrescar` | 1 | V224 | — |
| `academico_test.fn_actividad_grado_resolver` | 1 | V227 | V272 |
| `academico_test.fn_actividad_huerfanas_listar` | 8 | V244 | V246 |
| `academico_test.fn_actividad_importar` | 9 | V340 | V129, V275 |
| `academico_test.fn_actividad_instrumento_assert` | 2 | V240 | V227, V240 |
| `academico_test.fn_actividad_instrumento_definir` | 3 | V240 | V247 |
| `academico_test.fn_actividad_instrumento_obtener` | 2 | V240 | V247, V272, V353 |
| `academico_test.fn_actividad_instrumento_reset` | 3 | V226 | — |
| `academico_test.fn_actividad_instrumentos_permitidos` | 2 | V214.2 | — |
| `academico_test.fn_actividad_listar` | 18 | V224 | V246, V404 |
| `academico_test.fn_actividad_listar_docente` | 12 | V224 | V250 |
| `academico_test.fn_actividad_lv_assert` | 3 | V224 | V226, V240 |
| `academico_test.fn_actividad_material_reemplazar` | 3 | V224 | V246 |
| `academico_test.fn_actividad_materiales_reutilizables_listar` | 7 | V224 | V246 |
| `academico_test.fn_actividad_nota_ajustar_por_criterio` | 2 | V227 | — |
| `academico_test.fn_actividad_nota_asistencia_assert` | 2 | V227 | — |
| `academico_test.fn_actividad_nota_asistencia_assert_preescolar` | 2 | V243 | — |
| `academico_test.fn_actividad_nota_calificar` | 4 | V243 | V247 |
| `academico_test.fn_actividad_nota_calificar_cotejo` | 4 | V227 | V241, V243 |
| `academico_test.fn_actividad_nota_calificar_cotejo_bulk` | 6 | V227 | V247 |
| `academico_test.fn_actividad_nota_calificar_escala` | 5 | V227 | V241, V243 |
| `academico_test.fn_actividad_nota_calificar_escala_bulk` | 6 | V227 | V247 |
| `academico_test.fn_actividad_nota_calificar_otro` | 4 | V227 | V241, V243 |
| `academico_test.fn_actividad_nota_calificar_rubrica` | 4 | V227 | V241, V243 |
| `academico_test.fn_actividad_nota_calificar_rubrica_bulk` | 6 | V227 | V247 |
| `academico_test.fn_actividad_nota_cotejo_recalcular` | 1 | V227 | — |
| `academico_test.fn_actividad_nota_get_or_create` | 2 | V227 | V243 |
| `academico_test.fn_actividad_nota_obtener` | 2 | V241 | V247 |
| `academico_test.fn_actividad_nota_rubrica_recalcular` | 1 | V227 | — |
| `academico_test.fn_actividad_observar_estudiante` | 4 | V243 | V246 |
| `academico_test.fn_actividad_observar_grupal` | 4 | V243 | V246 |
| `academico_test.fn_actividad_otro_definir` | 3 | V240 | V274, V340 |
| `academico_test.fn_actividad_otro_metodo_valoracion` | 1 | V241 | V243 |
| `academico_test.fn_actividad_pantalla_edicion` | 3 | V353 | — |
| `academico_test.fn_actividad_recuperacion_configurar` | 3 | V224 | — |
| `academico_test.fn_actividad_referente_tipo_evaluacion` | 1 | V214.2 | V226 |
| `academico_test.fn_actividad_resumen_estados` | 8 | V224 | — |
| `academico_test.fn_actividad_resumen_estados_docente` | 7 | V224 | V250, V252 |
| `academico_test.fn_actividad_rubrica_definir` | 3 | V226 | V240, V274, V340 |
| `academico_test.fn_actividad_unidad_configuracion` | 2 | V214.2 | V224, V246 |

## app

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `public.fn_sync_app_users` | 1 | V151 | V302 |

## area

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_area_actualizar` | 6 | V40 | V77 |
| `academico_test.fn_area_asignatura_listar` | 1 | V40 | V77, V214 |
| `academico_test.fn_area_bulk_delete` | 2 | V40 | — |
| `academico_test.fn_area_crear` | 6 | V40 | V77 |
| `academico_test.fn_area_listar` | 7 | V40 | V77 |
| `academico_test.fn_area_soft_delete` | 2 | V40 | V77 |
| `academico_test.fn_area_subject_reporte_listar` | 8 | V188 | V135 |

## asignacion

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_asignacion_docente` | 3 | V46 | V92 |
| `academico_test.fn_asignacion_docente_listar` | 8 | V46 | V92 |
| `academico_test.fn_asignacion_guardar` | 4 | V46 | V92 |
| `academico_test.fn_asignacion_pool` | 4 | V287 | V92 |
| `academico_test.fn_asignacion_reporte_listar` | 9 | V190 | V135 |

## asignatura

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_asignatura_criterio_evaluacion_vigente` | 2 | V239 | V227 |
| `academico_test.fn_asignatura_grado_ponderacion_disponible` | 3 | V239 | V248 |
| `academico_test.fn_asignatura_plan_calculo_definitiva_modo` | 1 | V239 | V216 |
| `academico_test.fn_asignatura_plan_elemento_calculo` | 1 | V239 | V216 |
| `academico_test.fn_asignatura_plan_vigente` | 2 | V239 | — |
| `academico_test.fn_asignatura_plan_vigente_por_grado` | 2 | V239 | V216 |

## asistencia

| Endpoint | Verbo | Migraciones que la tocan | Funciones que invocan (aprox.) |
|---|---|---|---|
| `/asistencias/export-all` | POST | V228 | `fn_asistencia_listar_seguimiento` (V220), `fn_get_academico_usuario_id` (V299) |

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_asistencia_actividades_dia` | 4 | V220 | V221 |
| `academico_test.fn_asistencia_actividades_programadas` | 6 | V220 | — |
| `academico_test.fn_asistencia_asignaturas_sesion` | 4 | V220 | V221 |
| `academico_test.fn_asistencia_calendario` | 8 | V220 | V221 |
| `academico_test.fn_asistencia_editar` | 7 | V220 | V221 |
| `academico_test.fn_asistencia_estudiantes_sesion` | 6 | V220 | V221 |
| `academico_test.fn_asistencia_franja_bloque` | 5 | V220 | — |
| `academico_test.fn_asistencia_gate_escritura` | 3 | V220 | — |
| `academico_test.fn_asistencia_grupo_es_formativo` | 1 | V220 | — |
| `academico_test.fn_asistencia_horas_actividad` | 3 | V220 | — |
| `academico_test.fn_asistencia_horas_bloque` | 5 | V220 | — |
| `academico_test.fn_asistencia_listar_seguimiento` | 12 | V220 | V221, V228, V290 |
| `academico_test.fn_asistencia_periodo_estado` | 1 | V220 | — |
| `academico_test.fn_asistencia_periodo_eval` | 2 | V220 | — |
| `academico_test.fn_asistencia_puede_ver` | 2 | V220 | — |
| `academico_test.fn_asistencia_registrar_bulk` | 8 | V220 | V221 |
| `academico_test.fn_asistencia_resumen_horas` | 6 | V220 | V221 |
| `academico_test.fn_asistencia_sesiones_programadas` | 7 | V220 | — |
| `academico_test.fn_asistencia_tipo_pk` | 1 | V220 | V227, V243 |

## audit

| Endpoint | Verbo | Migraciones que la tocan | Funciones que invocan (aprox.) |
|---|---|---|---|
| `/audits/query` | POST | V133, V356, V377, V400 | — |
| `/audits/sessions/:SESSIONID` | GET | V86, V133, V183, V356 | — |
| `/audits/sessions/:SESSIONID/operations` | DELETE | V183, V376, V380 | — |
| `/audits/sessions/:SESSIONID/operations` | POST | V356, V362, V376, V380 | `fn_matricula_config_ee_solicitante` (V180), `fn_usuario_tiene_rol` (V257), `fn_get_academico_usuario_id` (V299)… |
| `/audits/stats` | POST | V133, V356, V384, V400 | — |

## audit-table

| Endpoint | Verbo | Migraciones que la tocan | Funciones que invocan (aprox.) |
|---|---|---|---|
| `/audit-tables/:SLUG` | GET | V85, V356 | — |
| `/audit-tables/:SLUG/operations/:OPERATIONID/changes` | DELETE | V134, V183 | — |
| `/audit-tables/:SLUG/operations/:OPERATIONID/changes` | GET | V85, V356 | — |
| `/audit-tables/:SLUG/operations/query` | DELETE | V381 | — |
| `/audit-tables/:SLUG/operations/query` | POST | V132, V356, V362, V376 | `fn_matricula_config_ee_solicitante` (V180), `fn_usuario_tiene_rol` (V257), `fn_get_academico_usuario_id` (V299)… |
| `/audit-tables/:SLUG/operations/stats` | POST | V85, V356, V384, V402 | — |
| `/audit-tables/query` | POST | V85, V356, V381, V403 | — |

## available

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_list_available_menus` | 1 | V115 | V119 |

## cat

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_cat_discapacidades_listar` | 1 | V58 | V119 |
| `academico_test.fn_cat_etnia_resguardo_listar` | 0 | V170 | — |
| `academico_test.fn_cat_municipios_listar` | 1 | V58 | V119 |
| `academico_test.fn_cat_propiedad_juridica_listar` | 1 | V58 | V119 |
| `academico_test.fn_cat_roles_listar` | 1 | V304 | V119 |

## catalogo

| Endpoint | Verbo | Migraciones que la tocan | Funciones que invocan (aprox.) |
|---|---|---|---|
| `/catalogos/discapacidades` | GET | V366 | `fn_usuario_tiene_rol` (V257), `fn_get_pigse_usuario_id` (V261) |
| `/catalogos/municipios` | GET | V366, V385 | `fn_usuario_tiene_rol` (V257), `fn_get_pigse_usuario_id` (V261) |
| `/catalogos/propiedad-juridica` | GET | V366 | `fn_usuario_tiene_rol` (V257), `fn_get_pigse_usuario_id` (V261) |
| `/catalogos/roles` | GET | V366 | `fn_usuario_tiene_rol` (V257), `fn_get_pigse_usuario_id` (V261) |

## criterio

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_criterio_eval_actualizar` | 12 | V41 | V76 |
| `academico_test.fn_criterio_eval_obtener` | 2 | V41 | V76 |
| `academico_test.fn_criterio_evaluacion_formato` | 1 | V227 | — |
| `academico_test.fn_criterio_evaluacion_porcentaje_inicial` | 1 | V239 | V227 |
| `academico_test.fn_criterio_evaluacion_porcentaje_maximo_recuperacion` | 1 | V239 | V227 |
| `academico_test.fn_criterio_prom_guardar` | 13 | V38 | V43, V76 |
| `academico_test.fn_criterio_prom_obtener` | 3 | V38 | V43, V76 |

## cumplimiento

| Endpoint | Verbo | Migraciones que la tocan | Funciones que invocan (aprox.) |
|---|---|---|---|
| `/cumplimiento/query` | POST | V197 | `fn_pigse_cumplimiento_listar_paginado` (V196) |

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `pigse.fn_cumplimiento_listar` | 0 | V261 | V262 |
| `pigse.fn_cumplimiento_listar_paginado` | 8 | V261 | V262 |
| `pigse.fn_cumplimiento_metricas` | 0 | V261 | V262 |

## descanso

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_descanso_agregar` | 4 | V37 | V75 |
| `academico_test.fn_descanso_eliminar` | 2 | V37 | V75 |

## docente

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_docente_director_grupo_sync` | 4 | V285 | — |
| `academico_test.fn_docente_grado_asignatura_listar` | 3 | V250 | V248 |
| `academico_test.fn_docente_grado_directores_sync` | 3 | V285 | — |
| `academico_test.fn_docente_grupos_listar` | 3 | V250 | V248 |
| `academico_test.fn_docente_periodo_vigente` | 1 | V250 | V254 |
| `academico_test.fn_docente_unidad_tabs_listar` | 1 | V281 | — |

## documento

| Endpoint | Verbo | Migraciones que la tocan | Funciones que invocan (aprox.) |
|---|---|---|---|
| `/documentos/todos/query` | POST | V368, V374 | `fn_documentos_listar_todos` (V368), `fn_documentos_listar_todos_paginado` (V374) |

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `pigse.fn_documento_eliminar` | 3 | V261 | V262 |
| `pigse.fn_documento_guardar` | 4 | V261 | V262 |
| `pigse.fn_documentos_listar` | 1 | V261 | V262 |
| `pigse.fn_documentos_listar_todos` | 0 | V368 | V374 |
| `pigse.fn_documentos_listar_todos_paginado` | 7 | V374 | V374 |

## enfasi

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_enfasis_actualizar` | 3 | V40 | V77 |
| `academico_test.fn_enfasis_desde_seleccion` | 3 | V40 | — |
| `academico_test.fn_enfasis_resolver` | 4 | V40 | V77 |
| `academico_test.fn_enfasis_soft_delete` | 2 | V40 | V77 |

## ente

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_ente_usuario_crear` | 6 | V150 | V263 |
| `academico_test.fn_ente_usuario_soft_delete` | 4 | V150 | — |
| `pigse.fn_ente_actualizar` | 6 | V257 | V258 |
| `pigse.fn_ente_buscar_por_pk` | 2 | V257 | V258 |
| `pigse.fn_ente_crear` | 5 | V257 | V258 |
| `pigse.fn_ente_listar` | 6 | V257 | V258 |
| `pigse.fn_ente_soft_delete` | 2 | V257 | V258 |
| `pigse.fn_ente_usuario_crear` | 4 | V257 | V263 |

## es

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_es_super_admin` | 1 | V37 | — |
| `academico_test.fn_es_super_admin_sso` | 1 | V302 | V303, V304 |

## escala

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_escala_bulk_delete` | 2 | V42 | — |
| `academico_test.fn_escala_eliminar` | 2 | V42 | V78 |
| `academico_test.fn_escala_guardar_bulk` | 4 | V42 | V78 |
| `academico_test.fn_escala_listar` | 7 | V42 | V78, V135 |
| `academico_test.fn_escala_nivel_bulk_soft_delete` | 3 | V128 | — |
| `academico_test.fn_escala_nivel_soft_delete` | 3 | V42 | V78, V128 |
| `academico_test.fn_escala_propagar` | 3 | V42 | V41 |
| `academico_test.fn_escala_valoracion_bulk_delete` | 2 | V42 | V78 |

## especialidad

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_especialidad_enfasis_listar` | 2 | V40 | V77 |

## est

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_est_actualizar` | 34 | V399 | V64, V98 |
| `academico_test.fn_est_buscar_por_nit` | 2 | V53 | V52, V111, V296, V354, V399, V401 |
| `academico_test.fn_est_buscar_por_pk` | 2 | V53 | V98 |
| `academico_test.fn_est_contar` | 5 | V116 | V116, V130 |
| `academico_test.fn_est_crear` | 32 | V399 | V64, V98 |
| `academico_test.fn_est_listar` | 9 | V130 | V67, V69, V98, V116, V130 |
| `academico_test.fn_est_listar_paginado` | 9 | V130 | V98 |
| `academico_test.fn_est_listar_todos` | 1 | V53 | V98 |
| `academico_test.fn_est_soft_delete` | 2 | V354 | V98, V354 |
| `academico_test.fn_est_soft_delete_bulk` | 2 | V354 | V98 |
| `pigse.fn_est_actualizar` | 14 | V362 | V258, V360 |
| `pigse.fn_est_buscar_por_pk` | 2 | V397 | V258 |
| `pigse.fn_est_crear` | 14 | V394 | V258, V360 |
| `pigse.fn_est_listar` | 8 | V387 | V258, V387 |
| `pigse.fn_est_soft_delete` | 2 | V257 | V258 |
| `pigse.fn_est_soft_delete_bulk` | 2 | V392 | V98 |
| `pigse.fn_est_usuario_crear` | 4 | V257 | V360, V369 |

## establecimiento

| Endpoint | Verbo | Migraciones que la tocan | Funciones que invocan (aprox.) |
|---|---|---|---|
| `/establecimientos/bulk-delete` | POST | V366 | `fn_usuario_tiene_rol` (V257), `fn_get_pigse_usuario_id` (V261) |
| `/establecimientos/funcionarios/eliminar-multiple` | PUT | V366 | `fn_usuario_tiene_rol` (V257), `fn_get_pigse_usuario_id` (V261) |

## estudiante

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_estudiante_actualizar` | 15 | V177 | — |
| `academico_test.fn_estudiante_crear` | 12 | V160 | V166 |
| `academico_test.fn_estudiante_dependencias_bloqueantes` | 2 | V162 | V160 |
| `academico_test.fn_estudiante_obtener_por_id` | 2 | V160 | V166, V204 |
| `academico_test.fn_estudiante_soft_delete` | 4 | V160 | V166 |

## fun

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_fun_activo_por_usuario` | 1 | V51 | V93 |
| `academico_test.fn_fun_actualizar` | 42 | V72 | V93 |
| `academico_test.fn_fun_baja_establecimiento` | 2 | V300 | V93 |
| `academico_test.fn_fun_baja_establecimiento_bulk` | 2 | V51 | V93 |
| `academico_test.fn_fun_cancelar_pendiente` | 2 | V51 | V93 |
| `academico_test.fn_fun_crear` | 15 | V51 | V258, V390 |
| `academico_test.fn_fun_enlazar_establecimiento` | 3 | V51 | V93 |
| `academico_test.fn_fun_filtros_permiso_actualizar` | 3 | V199 | — |
| `academico_test.fn_fun_filtros_permiso_listar` | 2 | V199 | — |
| `academico_test.fn_fun_permisos_actualizar` | 3 | V297 | V52, V53, V93, V111, V399 |
| `pigse.fn_fun_actualizar` | 20 | V390 | V258, V369, V390 |
| `pigse.fn_fun_asignar_rol` | 3 | V369 | — |
| `pigse.fn_fun_baja_bulk` | 2 | V366 | — |
| `pigse.fn_fun_buscar_por_pk` | 2 | V390 | V258 |
| `pigse.fn_fun_cancelar_pendiente` | 2 | V360 | V93 |
| `pigse.fn_fun_crear` | 11 | V393 | V258, V390 |
| `pigse.fn_fun_listar` | 10 | V386 | V258, V386 |
| `pigse.fn_fun_permisos_actualizar` | 3 | V390 | V52, V53, V93, V111, V399 |
| `pigse.fn_fun_soft_delete` | 2 | V370 | V258 |

## funcionario

| Endpoint | Verbo | Migraciones que la tocan | Funciones que invocan (aprox.) |
|---|---|---|---|
| `/funcionario/:ID/filtros-permiso` | GET | V199 | `fn_assert_permiso_funcionario` (V370), `fn_get_academico_usuario_id` (V299) |
| `/funcionario/:ID/filtros-permiso` | PUT | V199 | `fn_assert_permiso_funcionario` (V370), `fn_get_academico_usuario_id` (V299) |

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_funcionario_actual` | 1 | V224 | V216, V250, V251, V254, V281 |
| `academico_test.fn_funcionario_sede_listar` | 3 | V43 | V79 |

## grade

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_grade_config_guardar` | 4 | V43 | V79 |
| `academico_test.fn_grade_config_obtener` | 2 | V43 | V79 |

## grado

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_grado_actualizar` | 6 | V43 | V79 |
| `academico_test.fn_grado_bulk_delete` | 2 | V43 | V79 |
| `academico_test.fn_grado_crear` | 5 | V43 | V79 |
| `academico_test.fn_grado_es_preescolar` | 1 | V285 | V286, V287 |
| `academico_test.fn_grado_grupo_etiqueta` | 3 | V224 | V251 |
| `academico_test.fn_grado_grupo_reporte_listar` | 5 | V187 | V135 |
| `academico_test.fn_grado_listar` | 7 | V43 | V79 |
| `academico_test.fn_grado_obtener` | 2 | V43 | V79 |
| `academico_test.fn_grado_soft_delete` | 2 | V43 | V79 |

## grupo

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_grupo_actualizar` | 6 | V285 | V79 |
| `academico_test.fn_grupo_bulk_delete` | 2 | V43 | V79 |
| `academico_test.fn_grupo_crear` | 6 | V285 | V79 |
| `academico_test.fn_grupo_establecimiento` | 1 | V40 | V220 |
| `academico_test.fn_grupo_jornada` | 1 | V40 | V220 |
| `academico_test.fn_grupo_listar` | 7 | V43 | V79 |
| `academico_test.fn_grupo_obtener` | 2 | V43 | V79 |
| `academico_test.fn_grupo_periodo` | 1 | V40 | V220 |
| `academico_test.fn_grupo_soft_delete` | 2 | V43 | V79 |

## horario

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_horario_asignaturas` | 2 | V45 | V80 |
| `academico_test.fn_horario_calcular_bloques` | 1 | V45 | — |
| `academico_test.fn_horario_guardar` | 3 | V45 | V43, V80 |
| `academico_test.fn_horario_listar` | 3 | V45 | V43, V80 |

## instrumento

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_instrumento_nombre` | 1 | V214.2 | V224 |
| `academico_test.fn_instrumento_permitido_por_tipo_evaluacion` | 2 | V214.2 | V226, V282 |

## jornada

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_jornadas_activas_por_sede` | 2 | V162 | V127 |

## matricula

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_matricula_actualizar` | 9 | V177 | — |
| `academico_test.fn_matricula_archivo_actualizar` | 5 | V177 | — |
| `academico_test.fn_matricula_archivo_actualizar_lote` | 11 | V177 | — |
| `academico_test.fn_matricula_archivo_crear` | 4 | V165 | V177, V201 |
| `academico_test.fn_matricula_archivo_crear_lote` | 7 | V165 | V166 |
| `academico_test.fn_matricula_archivo_listar_por_matricula` | 2 | V165 | V166, V204 |
| `academico_test.fn_matricula_archivo_soft_delete` | 2 | V165 | V166 |
| `academico_test.fn_matricula_campo_sync_no_editable` | 0 | V159 | — |
| `academico_test.fn_matricula_config_actualizar` | 3 | V159 | — |
| `academico_test.fn_matricula_config_crear` | 2 | V159 | — |
| `academico_test.fn_matricula_config_crear_interno` | 2 | V159 | V180, V181, V182 |
| `academico_test.fn_matricula_config_editar_campo` | 4 | V180 | V127 |
| `academico_test.fn_matricula_config_ee_solicitante` | 1 | V180 | V181, V182, V362 |
| `academico_test.fn_matricula_config_obtener` | 1 | V182 | V127 |
| `academico_test.fn_matricula_config_trg_establecimiento` | 0 | V159 | — |
| `academico_test.fn_matricula_corregir_lote` | 3 | V178 | V129, V179 |
| `academico_test.fn_matricula_crear` | 7 | V163 | V166 |
| `academico_test.fn_matricula_cupo_ocupado` | 2 | V145 | V178, V205, V350, V351 |
| `academico_test.fn_matricula_dependencias_bloqueantes` | 1 | V162 | V163, V166 |
| `academico_test.fn_matricula_directa_actualizar` | 71 | V177 | V179 |
| `academico_test.fn_matricula_directa_crear` | 57 | V166 | V167 |
| `academico_test.fn_matricula_directa_eliminar` | 2 | V166 | V127, V169 |
| `academico_test.fn_matricula_directa_eliminar_bulk` | 2 | V166 | V127, V169 |
| `academico_test.fn_matricula_documento_otro_agregar` | 3 | V201 | — |
| `academico_test.fn_matricula_gate_escritura` | 3 | V40 | V163, V164, V165, V166 |
| `academico_test.fn_matricula_grupo` | 1 | V40 | V163, V164, V165 |
| `academico_test.fn_matricula_listar` | 11 | V270 | V127, V206 |
| `academico_test.fn_matricula_mover_lote` | 8 | V178 | V178 |
| `academico_test.fn_matricula_obtener_completa` | 2 | V204 | V168 |
| `academico_test.fn_matricula_obtener_por_id` | 2 | V163 | V166, V204 |
| `academico_test.fn_matricula_promover_lote` | 5 | V178 | V129, V176, V179 |
| `academico_test.fn_matricula_puede_cambiar_estado` | 3 | V233 | V166, V177, V178 |
| `academico_test.fn_matricula_puede_ver` | 2 | V40 | V200 |
| `academico_test.fn_matricula_reactivar` | 2 | V166 | V127, V173 |
| `academico_test.fn_matricula_reingresar` | 2 | V166 | V127, V172 |
| `academico_test.fn_matricula_replicar` | 3 | V175 | V178 |
| `academico_test.fn_matricula_retirar` | 2 | V166 | V127, V171 |
| `academico_test.fn_matricula_reubicar_lote` | 5 | V178 | V129, V176, V179 |
| `academico_test.fn_matricula_socioeconomico_actualizar` | 18 | V177 | — |
| `academico_test.fn_matricula_socioeconomico_crear` | 18 | V164 | V166, V177 |
| `academico_test.fn_matricula_socioeconomico_obtener_por_matricula` | 2 | V164 | V166, V204 |
| `academico_test.fn_matricula_socioeconomico_soft_delete` | 2 | V164 | V166 |
| `academico_test.fn_matricula_soft_delete` | 2 | V163 | V166 |
| `academico_test.fn_matricula_validar_cupo` | 1 | V205 | V166 |
| `academico_test.fn_matricula_validar_estudiante_disponible` | 1 | V162 | V166 |
| `academico_test.fn_matricula_validar_periodo_vigente` | 2 | V162 | V166, V175, V177, V178 |
| `academico_test.fn_matricula_valor_forzar_no_editable` | 0 | V159 | — |

## menu

| Endpoint | Verbo | Migraciones que la tocan | Funciones que invocan (aprox.) |
|---|---|---|---|
| `/menus` | GET | V364 | — |
| `/menus` | POST | V364 | — |
| `/menus/:ID` | PATCH | V364 | — |
| `/menus/:ID/eliminar` | PUT | V364 | — |
| `/menus/order` | PUT | V364 | — |

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_associate_menus_to_rol` | 5 | V123 | V129, V198 |
| `academico_test.fn_dissociate_menus_from_rol` | 3 | V113 | — |

## mi

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_mi_establecimiento_para_auditoria` | 1 | V362 | — |
| `pigse.fn_mi_establecimiento` | 1 | V261 | V262 |
| `pigse.fn_mi_establecimiento_para_auditoria` | 1 | V362 | — |

## microservice

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `public.fn_microservice_validar_file_storage` | 0 | V147 | — |

## nivel

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_nivel_ensenanza_listar` | 1 | V43 | V79, V214 |

## nodo

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_nodo_curricular_listar` | 1 | V38 | V76 |

## nota

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_nota_homologar` | 3 | V227 | — |

## padre

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_padre_actualizar` | 23 | V177 | — |
| `academico_test.fn_padre_crear` | 22 | V161 | V166, V177 |
| `academico_test.fn_padre_obtener_por_id` | 2 | V161 | V166, V204 |
| `academico_test.fn_padre_soft_delete` | 3 | V161 | V166 |

## parent

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_create_parent_menu_with_submenus` | 8 | V59 | — |

## periodo

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_periodo_actualizar` | 15 | V37 | V75 |
| `academico_test.fn_periodo_anos_lectivos_listar` | 1 | V191 | V75 |
| `academico_test.fn_periodo_anteriores_por_sede` | 3 | V37 | V75 |
| `academico_test.fn_periodo_areas_asignaturas_listar` | 2 | V40 | V77 |
| `academico_test.fn_periodo_bulk_delete` | 2 | V37 | V75 |
| `academico_test.fn_periodo_crear` | 14 | V37 | V75 |
| `academico_test.fn_periodo_detalle` | 2 | V37 | V75 |
| `academico_test.fn_periodo_establecimiento` | 1 | V29 | V39, V40, V41, V42, V43, V44… |
| `academico_test.fn_periodo_eval_actualizar` | 9 | V39 | V76 |
| `academico_test.fn_periodo_eval_bulk_delete` | 2 | V39 | V76 |
| `academico_test.fn_periodo_eval_crear` | 9 | V39 | V76 |
| `academico_test.fn_periodo_eval_detalle` | 2 | V39 | V76 |
| `academico_test.fn_periodo_eval_listar` | 7 | V39 | V76, V124 |
| `academico_test.fn_periodo_eval_soft_delete` | 2 | V39 | V76 |
| `academico_test.fn_periodo_eval_validar` | 8 | V39 | — |
| `academico_test.fn_periodo_evaluacion_listar` | 4 | V254 | — |
| `academico_test.fn_periodo_gate_escritura` | 5 | V29 | V37, V38, V39, V40, V41, V42… |
| `academico_test.fn_periodo_jornada` | 1 | V29 | V37, V38, V39, V40, V41, V42… |
| `academico_test.fn_periodo_jornadas_listar` | 2 | V191 | — |
| `academico_test.fn_periodo_listar` | 11 | V37 | V75, V124 |
| `academico_test.fn_periodo_puede_ver` | 2 | V29 | V37, V38, V39, V40, V41, V42… |
| `academico_test.fn_periodo_resolver_matricula` | 4 | V352 | V127, V166 |
| `academico_test.fn_periodo_sede` | 1 | V29 | V37, V38, V39, V40, V41, V42… |
| `academico_test.fn_periodo_sedes_listar` | 1 | V191 | — |
| `academico_test.fn_periodo_soft_delete` | 2 | V37 | V75 |
| `academico_test.fn_periodo_usuario_establecimientos` | 1 | V37 | V191 |
| `academico_test.fn_periodo_usuario_global` | 1 | V37 | V191 |
| `academico_test.fn_periodo_usuario_puede_ver` | 2 | V37 | V162, V242, V250, V254, V270, V350… |
| `academico_test.fn_periodo_usuario_sedes` | 1 | V37 | V191 |

## personalizar

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_personalizar_asignatura_crear` | 2 | V214.3 | — |
| `academico_test.fn_personalizar_asignatura_eliminar` | 2 | V214.3 | — |
| `academico_test.fn_personalizar_asignatura_listar` | 3 | V214.3 | — |
| `academico_test.fn_personalizar_asignatura_pk` | 1 | V214.3 | — |

## pigse

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_pigse_cumplimiento_listar` | 0 | V156 | V196 |
| `academico_test.fn_pigse_cumplimiento_listar_paginado` | 8 | V196 | V197 |
| `academico_test.fn_pigse_cumplimiento_metricas` | 0 | V149 | — |
| `academico_test.fn_pigse_documento_eliminar` | 3 | V156 | — |
| `academico_test.fn_pigse_documento_guardar` | 4 | V156 | — |
| `academico_test.fn_pigse_documentos_listar` | 1 | V156 | V152, V156 |
| `academico_test.fn_pigse_mi_establecimiento` | 1 | V149 | V152, V156 |
| `public.fn_get_pigse_usuario_id` | 1 | V261 | V258, V262, V263, V360, V362, V366… |
| `public.fn_pigse_es_administrador` | 1 | V364 | — |
| `public.fn_pigse_rol_crear` | 2 | V364 | — |
| `public.fn_pigse_rol_rutas_actualizar` | 3 | V364 | — |
| `public.fn_pigse_ruta_actualizar` | 7 | V364 | — |
| `public.fn_pigse_ruta_crear` | 5 | V364 | — |
| `public.fn_pigse_ruta_eliminar` | 2 | V364 | — |
| `public.fn_pigse_rutas_reordenar` | 2 | V364 | — |

## plan

| Endpoint | Verbo | Migraciones que la tocan | Funciones que invocan (aprox.) |
|---|---|---|---|
| `/plans` | GET | V364 | — |

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_create_plan_from_value` | 2 | V113 | V119 |
| `academico_test.fn_delete_plan_from_value` | 2 | V113 | — |
| `academico_test.fn_list_plans_from_value` | 1 | V113 | V119 |
| `academico_test.fn_plan_actualizar` | 11 | V285 | V80 |
| `academico_test.fn_plan_agregar` | 11 | V285 | V80 |
| `academico_test.fn_plan_asignatura_bulk_delete` | 2 | V44 | V80 |
| `academico_test.fn_plan_asignaturas_disponibles_listar` | 3 | V44 | V80 |
| `academico_test.fn_plan_eliminar` | 2 | V285 | V80 |
| `academico_test.fn_plan_eliminar_restricciones` | 2 | V286 | — |
| `academico_test.fn_plan_listar` | 7 | V44 | V80 |
| `academico_test.fn_plan_obtener` | 2 | V44 | V80 |
| `academico_test.fn_plan_reporte_listar` | 7 | V186 | V135 |
| `academico_test.fn_plan_soft_delete` | 2 | V44 | V80 |

## planeador

| Endpoint | Verbo | Migraciones que la tocan | Funciones que invocan (aprox.) |
|---|---|---|---|
| `/planeador/actividades` | GET | V275, V404 | `fn_actividad_importar` (V340), `fn_actividad_listar` (V224), `fn_get_academico_usuario_id` (V299) |
| `/planeador/actividades` | POST | V275, V404 | `fn_actividad_importar` (V340), `fn_actividad_listar` (V224), `fn_get_academico_usuario_id` (V299) |
| `/planeador/actividades/:ID` | GET | V246 | `fn_actividad_actualizar` (V224), `fn_actividad_adaptacion_reemplazar` (V224), `fn_actividad_buscar_por_pk` (V224)… |
| `/planeador/actividades/:ID` | PATCH | V246 | `fn_actividad_actualizar` (V224), `fn_actividad_adaptacion_reemplazar` (V224), `fn_actividad_buscar_por_pk` (V224)… |
| `/planeador/actividades/:ID` | PUT | V246 | `fn_actividad_actualizar` (V224), `fn_actividad_adaptacion_reemplazar` (V224), `fn_actividad_buscar_por_pk` (V224)… |
| `/planeador/actividades/:ID/adaptaciones` | PUT | V246 | `fn_actividad_actualizar` (V224), `fn_actividad_adaptacion_reemplazar` (V224), `fn_actividad_buscar_por_pk` (V224)… |
| `/planeador/actividades/:ID/calificaciones` | GET | V247 | `fn_actividad_estudiantes_calificaciones_listar` (V227), `fn_actividad_instrumento_definir` (V240), `fn_actividad_instrumento_obtener` (V240)… |
| `/planeador/actividades/:ID/calificar-bulk/cotejo` | PUT | V247 | `fn_actividad_estudiantes_calificaciones_listar` (V227), `fn_actividad_instrumento_definir` (V240), `fn_actividad_instrumento_obtener` (V240)… |
| `/planeador/actividades/:ID/calificar-bulk/escala` | PUT | V247 | `fn_actividad_estudiantes_calificaciones_listar` (V227), `fn_actividad_instrumento_definir` (V240), `fn_actividad_instrumento_obtener` (V240)… |
| `/planeador/actividades/:ID/calificar-bulk/rubrica` | PUT | V247 | `fn_actividad_estudiantes_calificaciones_listar` (V227), `fn_actividad_instrumento_definir` (V240), `fn_actividad_instrumento_obtener` (V240)… |
| `/planeador/actividades/:ID/configuracion` | GET | V246 | `fn_actividad_actualizar` (V224), `fn_actividad_adaptacion_reemplazar` (V224), `fn_actividad_buscar_por_pk` (V224)… |
| `/planeador/actividades/:ID/criterios` | POST | V246 | `fn_actividad_actualizar` (V224), `fn_actividad_adaptacion_reemplazar` (V224), `fn_actividad_buscar_por_pk` (V224)… |
| `/planeador/actividades/:ID/evidencias` | POST | V246 | `fn_actividad_actualizar` (V224), `fn_actividad_adaptacion_reemplazar` (V224), `fn_actividad_buscar_por_pk` (V224)… |
| `/planeador/actividades/:ID/instrumento` | GET | V247 | `fn_actividad_estudiantes_calificaciones_listar` (V227), `fn_actividad_instrumento_definir` (V240), `fn_actividad_instrumento_obtener` (V240)… |
| `/planeador/actividades/:ID/instrumento` | PUT | V247 | `fn_actividad_estudiantes_calificaciones_listar` (V227), `fn_actividad_instrumento_definir` (V240), `fn_actividad_instrumento_obtener` (V240)… |
| `/planeador/actividades/:ID/materiales` | PUT | V246 | `fn_actividad_actualizar` (V224), `fn_actividad_adaptacion_reemplazar` (V224), `fn_actividad_buscar_por_pk` (V224)… |
| `/planeador/actividades/:ID/materiales-reutilizables` | GET | V246 | `fn_actividad_actualizar` (V224), `fn_actividad_adaptacion_reemplazar` (V224), `fn_actividad_buscar_por_pk` (V224)… |
| `/planeador/actividades/:ID/observar-grupal` | POST | V246 | `fn_actividad_actualizar` (V224), `fn_actividad_adaptacion_reemplazar` (V224), `fn_actividad_buscar_por_pk` (V224)… |
| `/planeador/actividades/calendario` | GET | V251 | `fn_actividad_calendario` (V251), `fn_actividad_estado` (V224), `fn_funcionario_actual` (V224)… |
| `/planeador/actividades/criterios/:ID` | PATCH | V246 | `fn_actividad_actualizar` (V224), `fn_actividad_adaptacion_reemplazar` (V224), `fn_actividad_buscar_por_pk` (V224)… |
| `/planeador/actividades/estudiantes/:ID/calificar` | PUT | V247 | `fn_actividad_estudiantes_calificaciones_listar` (V227), `fn_actividad_instrumento_definir` (V240), `fn_actividad_instrumento_obtener` (V240)… |
| `/planeador/actividades/estudiantes/:ID/nota` | GET | V247 | `fn_actividad_estudiantes_calificaciones_listar` (V227), `fn_actividad_instrumento_definir` (V240), `fn_actividad_instrumento_obtener` (V240)… |
| `/planeador/actividades/estudiantes/:ID/observar` | PUT | V246 | `fn_actividad_actualizar` (V224), `fn_actividad_adaptacion_reemplazar` (V224), `fn_actividad_buscar_por_pk` (V224)… |
| `/planeador/actividades/evidencias/:ID` | PATCH | V246 | `fn_actividad_actualizar` (V224), `fn_actividad_adaptacion_reemplazar` (V224), `fn_actividad_buscar_por_pk` (V224)… |
| `/planeador/actividades/export-all` | GET | V404 | `fn_actividad_listar` (V224), `fn_get_academico_usuario_id` (V299) |
| `/planeador/actividades/export-all` | POST | V404 | `fn_actividad_listar` (V224), `fn_get_academico_usuario_id` (V299) |
| `/planeador/actividades/exportar` | GET | V273 | `fn_actividad_exportar` (V272), `fn_get_academico_usuario_id` (V299) |
| `/planeador/actividades/exportar` | POST | V273 | `fn_actividad_exportar` (V272), `fn_get_academico_usuario_id` (V299) |
| `/planeador/actividades/huerfanas` | GET | V246 | `fn_actividad_actualizar` (V224), `fn_actividad_adaptacion_reemplazar` (V224), `fn_actividad_buscar_por_pk` (V224)… |
| `/planeador/actividades/importar` | GET | V275 | `fn_actividad_importar` (V340), `fn_get_academico_usuario_id` (V299) |
| `/planeador/actividades/importar` | POST | V275 | `fn_actividad_importar` (V340), `fn_get_academico_usuario_id` (V299) |
| `/planeador/actividades/mias` | GET | V250, V253, V279 | `fn_actividad_listar_docente` (V224), `fn_actividad_resumen_estados_docente` (V224), `fn_funcionario_actual` (V224)… |
| `/planeador/actividades/stats` | GET | V252 | `fn_actividad_resumen_estados_docente` (V224), `fn_get_academico_usuario_id` (V299) |
| `/planeador/actividades/tablero` | GET | V250 | `fn_actividad_listar_docente` (V224), `fn_actividad_resumen_estados_docente` (V224), `fn_funcionario_actual` (V224)… |
| `/planeador/asignaturas/:ID/ponderacion-disponible` | GET | V248 | `fn_asignatura_grado_ponderacion_disponible` (V239), `fn_docente_grado_asignatura_listar` (V250), `fn_docente_grupos_listar` (V250)… |
| `/planeador/docentes/grado-asignatura` | GET | V248 | `fn_asignatura_grado_ponderacion_disponible` (V239), `fn_docente_grado_asignatura_listar` (V250), `fn_docente_grupos_listar` (V250)… |
| `/planeador/docentes/grupos` | GET | V248 | `fn_asignatura_grado_ponderacion_disponible` (V239), `fn_docente_grado_asignatura_listar` (V250), `fn_docente_grupos_listar` (V250)… |
| `/planeador/periodos-evaluacion` | GET | V254 | `fn_docente_periodo_vigente` (V250), `fn_funcionario_actual` (V224), `fn_periodo_usuario_puede_ver` (V37)… |
| `/planeador/planilla/calificaciones` | GET | V248 | `fn_asignatura_grado_ponderacion_disponible` (V239), `fn_docente_grado_asignatura_listar` (V250), `fn_docente_grupos_listar` (V250)… |
| `/planeador/planilla/columnas` | GET | V248 | `fn_asignatura_grado_ponderacion_disponible` (V239), `fn_docente_grado_asignatura_listar` (V250), `fn_docente_grupos_listar` (V250)… |
| `/planeador/referente-curricular` | GET | V278 | `fn_planeador_assert_alcance` (V277), `fn_assert_permiso_seccion` (V370), `fn_get_academico_usuario_id` (V299) |
| `/planeador/unidades` | GET | V406 | `fn_unidad_listar` (V216), `fn_get_academico_usuario_id` (V299) |
| `/planeador/unidades` | POST | V406 | `fn_unidad_listar` (V216), `fn_get_academico_usuario_id` (V299) |
| `/planeador/unidades/:ID` | GET | V245 | `fn_unidad_actividad_desvincular` (V223), `fn_unidad_actividad_ponderacion_set` (V223), `fn_unidad_actividad_vincular` (V244)… |
| `/planeador/unidades/:ID` | PATCH | V245 | `fn_unidad_actividad_desvincular` (V223), `fn_unidad_actividad_ponderacion_set` (V223), `fn_unidad_actividad_vincular` (V244)… |
| `/planeador/unidades/:ID` | PUT | V245 | `fn_unidad_actividad_desvincular` (V223), `fn_unidad_actividad_ponderacion_set` (V223), `fn_unidad_actividad_vincular` (V244)… |
| `/planeador/unidades/:ID/actividades` | GET | V245 | `fn_unidad_actividad_desvincular` (V223), `fn_unidad_actividad_ponderacion_set` (V223), `fn_unidad_actividad_vincular` (V244)… |
| `/planeador/unidades/:ID/actividades-disponibles` | GET | V246 | `fn_actividad_actualizar` (V224), `fn_actividad_adaptacion_reemplazar` (V224), `fn_actividad_buscar_por_pk` (V224)… |
| `/planeador/unidades/:ID/actividades/:ACTIVIDADID` | PUT | V245 | `fn_unidad_actividad_desvincular` (V223), `fn_unidad_actividad_ponderacion_set` (V223), `fn_unidad_actividad_vincular` (V244)… |
| `/planeador/unidades/:ID/configuracion-actividad` | GET | V282 | `fn_instrumento_permitido_por_tipo_evaluacion` (V214.2), `fn_planeador_assert_alcance` (V277), `fn_unidad_calculo_definitiva_modo` (V223)… |
| `/planeador/unidades/:ID/contenidos` | GET | V245 | `fn_unidad_actividad_desvincular` (V223), `fn_unidad_actividad_ponderacion_set` (V223), `fn_unidad_actividad_vincular` (V244)… |
| `/planeador/unidades/:ID/criterios` | GET | V245 | `fn_unidad_actividad_desvincular` (V223), `fn_unidad_actividad_ponderacion_set` (V223), `fn_unidad_actividad_vincular` (V244)… |
| `/planeador/unidades/:ID/criterios` | POST | V245 | `fn_unidad_actividad_desvincular` (V223), `fn_unidad_actividad_ponderacion_set` (V223), `fn_unidad_actividad_vincular` (V244)… |
| `/planeador/unidades/:ID/enunciados` | POST | V245 | `fn_unidad_actividad_desvincular` (V223), `fn_unidad_actividad_ponderacion_set` (V223), `fn_unidad_actividad_vincular` (V244)… |
| `/planeador/unidades/:ID/objetivos` | GET | V245 | `fn_unidad_actividad_desvincular` (V223), `fn_unidad_actividad_ponderacion_set` (V223), `fn_unidad_actividad_vincular` (V244)… |
| `/planeador/unidades/:ID/ponderacion-disponible` | GET | V245 | `fn_unidad_actividad_desvincular` (V223), `fn_unidad_actividad_ponderacion_set` (V223), `fn_unidad_actividad_vincular` (V244)… |
| `/planeador/unidades/:ID/referente` | GET | V255 | `fn_planeador_assert_alcance` (V277), `fn_get_academico_usuario_id` (V299) |
| `/planeador/unidades/:ID/valoraciones` | GET | V227 | `fn_actividad_instrumento_assert` (V240), `fn_asignatura_criterio_evaluacion_vigente` (V239), `fn_asistencia_tipo_pk` (V220)… |
| `/planeador/unidades/actividades/:ACTIVIDADID` | PATCH | V245 | `fn_unidad_actividad_desvincular` (V223), `fn_unidad_actividad_ponderacion_set` (V223), `fn_unidad_actividad_vincular` (V244)… |
| `/planeador/unidades/actividades/:ACTIVIDADID/ponderacion` | PUT | V245 | `fn_unidad_actividad_desvincular` (V223), `fn_unidad_actividad_ponderacion_set` (V223), `fn_unidad_actividad_vincular` (V244)… |
| `/planeador/unidades/criterios/:ID` | PATCH | V245 | `fn_unidad_actividad_desvincular` (V223), `fn_unidad_actividad_ponderacion_set` (V223), `fn_unidad_actividad_vincular` (V244)… |
| `/planeador/unidades/criterios/:ID` | PUT | V245 | `fn_unidad_actividad_desvincular` (V223), `fn_unidad_actividad_ponderacion_set` (V223), `fn_unidad_actividad_vincular` (V244)… |
| `/planeador/unidades/enunciados/:ID` | PATCH | V245 | `fn_unidad_actividad_desvincular` (V223), `fn_unidad_actividad_ponderacion_set` (V223), `fn_unidad_actividad_vincular` (V244)… |
| `/planeador/unidades/export-all` | GET | V406 | `fn_unidad_listar` (V216), `fn_get_academico_usuario_id` (V299) |
| `/planeador/unidades/export-all` | POST | V406 | `fn_unidad_listar` (V216), `fn_get_academico_usuario_id` (V299) |
| `/planeador/unidades/tabs` | GET | V281 | `fn_funcionario_actual` (V224), `fn_unidad_referente_aplicable` (V216), `fn_assert_permiso_seccion` (V370)… |

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_planeador_alcanza` | 6 | V277 | V272, V274, V340 |
| `academico_test.fn_planeador_assert_alcance` | 7 | V277 | V214.1, V214.2, V216, V222, V223, V224… |
| `academico_test.fn_planeador_etiqueta_a_lv` | 2 | V274 | V340 |
| `academico_test.fn_planeador_periodo_vigente` | 3 | V203 | V272, V274, V340 |
| `academico_test.fn_planeador_sn` | 2 | V274 | V340 |

## planilla

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_planilla_actividades_universo` | 5 | V239 | — |
| `academico_test.fn_planilla_calificaciones_listar` | 10 | V239 | V248 |
| `academico_test.fn_planilla_columnas_listar` | 7 | V239 | V248 |
| `academico_test.fn_planilla_definitiva_proyectada` | 2 | V239 | — |
| `academico_test.fn_planilla_grupo_asignatura_assert` | 3 | V239 | — |

## prematricula

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_prematricula_buscar_por_pk` | 2 | V351 | — |
| `academico_test.fn_prematricula_listar` | 19 | V350 | — |

## puede

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_puede_afectar_establecimiento` | 1 | V302 | V51, V52, V53, V111, V112, V114… |
| `academico_test.fn_puede_afectar_usuarios` | 1 | V50 | V30, V51, V150 |

## rango

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_assert_rango_rol` | 2 | V298 | V51, V297 |
| `academico_test.fn_assert_rango_rol_otorgable` | 2 | V298 | V51, V111, V297 |
| `pigse.fn_assert_rango_rol` | 2 | V370 | V51, V297 |
| `pigse.fn_assert_rango_rol_otorgable` | 2 | V370 | V390 |

## refcurr

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_refcurr_actualizar` | 17 | V214.3 | V214, V214.3 |
| `academico_test.fn_refcurr_areas_listar` | 2 | V213 | V214 |
| `academico_test.fn_refcurr_buscar_por_pk` | 2 | V214.3 | V214 |
| `academico_test.fn_refcurr_crear` | 16 | V214.3 | V214, V214.3 |
| `academico_test.fn_refcurr_eliminar` | 3 | V213 | V214 |
| `academico_test.fn_refcurr_enfoque_guard` | 0 | V214.2 | — |
| `academico_test.fn_refcurr_listar` | 11 | V214.3 | V214 |
| `academico_test.fn_refcurr_niveles_listar` | 2 | V213 | V214 |
| `academico_test.fn_refcurr_nombre_asignatura` | 2 | V214.3 | — |
| `academico_test.fn_refcurr_nombre_asignatura_default` | 1 | V214.3 | — |
| `academico_test.fn_refcurr_por_grado_asignatura` | 4 | V278 | — |

## refenunc

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_refenunc_actualizar` | 6 | V213 | V214 |
| `academico_test.fn_refenunc_crear` | 6 | V213 | V214 |
| `academico_test.fn_refenunc_eliminar` | 2 | V213 | V214 |
| `academico_test.fn_refenunc_evidencias_listar` | 3 | V213 | V214 |
| `academico_test.fn_refenunc_listar` | 4 | V213 | V214 |

## referente

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_referente_actividades_instrumentadas` | 1 | V214.2 | — |
| `academico_test.fn_referente_es_evaluativo_vigente` | 1 | V214.2 | V216 |

## reorder

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_reorder_menus` | 2 | V113 | V126 |

## resolver

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_resolver_actor` | 1 | V66 | — |
| `academico_test.fn_resolver_establecimiento_unico` | 1 | V112 | V51, V112, V114 |
| `pigse.fn_resolver_actor` | 1 | V362 | — |

## rol

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_rol_categoria_nivel` | 1 | V29 | V51, V294, V295, V297, V298, V300… |
| `pigse.fn_rol_categoria_nivel` | 1 | V370 | V390 |

## role

| Endpoint | Verbo | Migraciones que la tocan | Funciones que invocan (aprox.) |
|---|---|---|---|
| `/roles` | GET | V364 | — |
| `/roles` | POST | V364 | — |
| `/roles/:ROLEID/menus` | GET | V364 | — |
| `/roles/:ROLEID/menus` | PUT | V364 | — |

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_list_roles` | 1 | V113 | V126 |

## sed

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_sed_actualizar` | 11 | V401 | V95 |
| `academico_test.fn_sed_buscar_por_pk` | 2 | V52 | V95 |
| `academico_test.fn_sed_contar` | 3 | V116 | V116, V130 |
| `academico_test.fn_sed_crear` | 11 | V401 | V53, V95, V111, V399 |
| `academico_test.fn_sed_listar` | 7 | V130 | V67, V69, V95, V116, V130 |
| `academico_test.fn_sed_listar_paginado` | 7 | V130 | V95 |
| `academico_test.fn_sed_listar_todos` | 1 | V52 | V95 |
| `academico_test.fn_sed_listar_todos_planeador` | 1 | V396 | — |
| `academico_test.fn_sed_por_establecimiento` | 2 | V52 | V95 |
| `academico_test.fn_sed_soft_delete` | 2 | V354 | V53, V95, V354 |
| `academico_test.fn_sed_soft_delete_bulk` | 2 | V354 | V95 |
| `pigse.fn_sed_actualizar` | 11 | V370 | V95 |
| `pigse.fn_sed_buscar_por_pk` | 2 | V370 | V95 |
| `pigse.fn_sed_crear` | 11 | V370 | V394 |
| `pigse.fn_sed_listar` | 8 | V386 | V386 |
| `pigse.fn_sed_soft_delete` | 2 | V370 | V53, V95, V354 |
| `pigse.fn_sed_soft_delete_bulk` | 2 | V370 | V95 |

## sede

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_sede_tiene_periodos` | 1 | V162 | V127 |
| `academico_test.fn_sede_usuario_actualizar` | 6 | V51 | — |
| `academico_test.fn_sede_usuario_crear` | 8 | V111 | V297 |
| `academico_test.fn_sede_usuario_soft_delete` | 2 | V111 | V53, V111, V297, V399 |
| `pigse.fn_sede_usuario_crear` | 8 | V370 | V390 |
| `pigse.fn_sede_usuario_soft_delete` | 2 | V370 | V390 |

## select

| Endpoint | Verbo | Migraciones que la tocan | Funciones que invocan (aprox.) |
|---|---|---|---|
| `/select` | GET | V366 | `fn_usuario_tiene_rol` (V257), `fn_get_pigse_usuario_id` (V261) |
| `/select/:CATEGORIA` | GET | V366 | `fn_usuario_tiene_rol` (V257), `fn_get_pigse_usuario_id` (V261) |

## sincronizar

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_sincronizar_rol_publico` | 1 | V302 | V51, V53, V150, V296, V300, V301… |

## subject

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_subject_actualizar` | 8 | V40 | V77 |
| `academico_test.fn_subject_crear` | 8 | V40 | V77 |
| `academico_test.fn_subject_guardar_bulk` | 3 | V40 | V77 |
| `academico_test.fn_subject_listar` | 2 | V40 | V77 |
| `academico_test.fn_subject_periodo_listar` | 7 | V40 | V77 |
| `academico_test.fn_subject_soft_delete` | 2 | V40 | V77 |

## superadmin

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_assert_superadmin` | 1 | V113 | V113, V115, V119, V123 |

## tactividad

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_tactividad_estudiante_finalizacion` | 0 | V224 | — |
| `academico_test.fn_tactividad_nota_finalizacion` | 0 | V224 | — |
| `academico_test.fn_tactividad_ponderacion_unidad_check` | 0 | V223 | — |

## trg

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_trg_tsede_usuario_sync_rol_publico` | 0 | V301 | — |

## trol

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_add_trol` | 4 | V113 | V119 |
| `academico_test.fn_list_trol_names_for_superadmin` | 1 | V59 | — |
| `academico_test.fn_sync_trol_to_public_role` | 0 | V113 | V113 |

## tsede

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_sync_tsede_usuario_to_role_users` | 0 | V57 | — |

## tunidad

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_tunidad_ponderacion_asignatura_check` | 0 | V239 | — |

## tusuario

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_sync_tusuario_to_users` | 0 | V215 | — |

## unidad

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_unidad_actividad_desvincular` | 2 | V223 | V224, V245 |
| `academico_test.fn_unidad_actividad_ponderacion_set` | 3 | V223 | V224, V245 |
| `academico_test.fn_unidad_actividad_vincular` | 5 | V244 | V224, V245 |
| `academico_test.fn_unidad_actividades_instrumentadas` | 1 | V214.2 | V216 |
| `academico_test.fn_unidad_actividades_listar` | 9 | V216 | V245 |
| `academico_test.fn_unidad_actualizar` | 14 | V216 | V245 |
| `academico_test.fn_unidad_buscar_por_pk` | 2 | V216 | V245 |
| `academico_test.fn_unidad_calculo_definitiva_modo` | 1 | V223 | V214.2, V224, V239, V244, V282 |
| `academico_test.fn_unidad_campos_disponibles` | 2 | V214.2 | V216 |
| `academico_test.fn_unidad_configuracion_actividad` | 3 | V282 | — |
| `academico_test.fn_unidad_contenidos_listar` | 2 | V216 | V245 |
| `academico_test.fn_unidad_crear` | 12 | V216 | V245, V274, V340 |
| `academico_test.fn_unidad_criterio_actualizar` | 8 | V222 | V245 |
| `academico_test.fn_unidad_criterio_agregar` | 7 | V216 | V245 |
| `academico_test.fn_unidad_criterio_eliminar` | 2 | V222 | V245 |
| `academico_test.fn_unidad_criterio_listar` | 3 | V222 | V245 |
| `academico_test.fn_unidad_eliminar` | 2 | V216 | V245 |
| `academico_test.fn_unidad_enunciado_quitar` | 2 | V214.1 | V245 |
| `academico_test.fn_unidad_enunciado_relacionar` | 3 | V214.1 | V216, V245 |
| `academico_test.fn_unidad_estado` | 3 | V224 | V216 |
| `academico_test.fn_unidad_etiqueta_por_grado` | 3 | V216 | — |
| `academico_test.fn_unidad_listar` | 12 | V216 | V245, V406 |
| `academico_test.fn_unidad_objetivos_listar` | 2 | V216 | V245 |
| `academico_test.fn_unidad_ponderacion_asignada` | 3 | V223 | V244, V245 |
| `academico_test.fn_unidad_ponderacion_disponible` | 3 | V223 | V245 |
| `academico_test.fn_unidad_ponderacion_intra_asignatura_asignada` | 3 | V239 | V216, V248 |
| `academico_test.fn_unidad_ponderacion_recalcular_sumatoria` | 2 | V223 | V224, V244 |
| `academico_test.fn_unidad_referente_aplicable` | 3 | V216 | V280, V281 |
| `academico_test.fn_unidad_referente_detalle` | 2 | V255 | — |
| `academico_test.fn_unidad_referente_evaluativo` | 1 | V214.2 | V216, V224, V226, V243, V282 |
| `academico_test.fn_unidad_referente_tipo_evaluacion` | 1 | V214.2 | V282 |
| `academico_test.fn_unidad_rubrica_asegurar` | 2 | V222 | V216 |
| `academico_test.fn_unidad_valoraciones_listar` | 2 | V227 | — |

## user

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_sync_users_password_to_tusuario` | 0 | V54 | — |
| `academico_test.fn_sync_users_to_tusuario` | 0 | V215 | — |

## usu

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_usu_actualizar` | 19 | V179 | — |
| `academico_test.fn_usu_autocompletar_por_documento` | 2 | V51 | V93 |
| `academico_test.fn_usu_buscar_por_documento` | 3 | V51 | V93 |
| `academico_test.fn_usu_crear` | 15 | V51 | — |
| `academico_test.fn_usu_empleado_buscar_por_pk` | 2 | V51 | V93 |
| `academico_test.fn_usu_empleados_contar` | 6 | V116 | V116, V130 |
| `academico_test.fn_usu_empleados_listar` | 10 | V130 | V67, V69, V93, V116, V130 |
| `academico_test.fn_usu_empleados_listar_paginado` | 10 | V130 | V93 |
| `academico_test.fn_usu_tiene_otros_vinculos` | 1 | V51 | V300 |

## usuario

| Endpoint | Verbo | Migraciones que la tocan | Funciones que invocan (aprox.) |
|---|---|---|---|
| `/usuarios/:PK_TUSUARIO/permisos-menu` | GET | V185 | — |
| `/usuarios/autocompletar-por-documento` | GET | V366 | `fn_usuario_tiene_rol` (V257), `fn_get_pigse_usuario_id` (V261) |

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_usuario_administrado_crear` | 10 | V30 | V219 |
| `academico_test.fn_usuario_categoria_rol_nivel` | 1 | V302 | V40, V51, V52, V53, V116, V130… |
| `academico_test.fn_usuario_ee_accesibles` | 1 | V29 | V40, V51, V116, V179, V220, V233… |
| `academico_test.fn_usuario_ee_lectura` | 1 | V29 | V40, V52, V53, V116, V130 |
| `academico_test.fn_usuario_otros_usos` | 3 | V162 | V160, V161 |
| `academico_test.fn_usuario_permisos_menu` | 1 | V303 | V29, V127 |
| `academico_test.fn_usuario_peso_categoria` | 1 | V298 | — |
| `academico_test.fn_usuario_puede_en_menu` | 3 | V29 | V40, V51, V52, V53, V116, V130… |
| `academico_test.fn_usuario_sedes_jornadas_accesibles` | 1 | V29 | V40, V51, V116, V220, V297, V300 |
| `academico_test.fn_usuario_sedes_lectura` | 1 | V29 | V52, V116, V130, V216, V224, V244… |
| `pigse.fn_usuario_categoria_rol_nivel` | 1 | V370 | V390 |
| `pigse.fn_usuario_ee_accesibles` | 1 | V370 | V390 |
| `pigse.fn_usuario_ente_crear` | 11 | V263 | — |
| `pigse.fn_usuario_provisionar` | 1 | V263 | — |
| `pigse.fn_usuario_puede_en_menu` | 3 | V370 | V373 |
| `pigse.fn_usuario_sedes_jornadas_accesibles` | 1 | V370 | V390 |
| `pigse.fn_usuario_tiene_rol` | 2 | V257 | V263, V360, V362, V366, V369, V387… |

## validar

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `public.fn_validar_tabla_archivo` | 2 | V147 | — |

