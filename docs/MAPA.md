# Mapa del dominio

**Generado** por `python scripts/generar-mapa.py` — no editar a mano.
Estado: 461 migraciones (V1–V533), 990 funciones vivas, 63 endpoints vivos. Ultima generacion: 2026-10-02.

Para una **funcion**, la migracion dueña es la que hay que editar: es su ultima escritura viva, no la que la creo.

Para un **endpoint** se listan todas las migraciones que lo tocan, sin elegir dueño: una migracion que clona una fila hermana tambien la menciona, y desde el SQL no se distingue. La columna de funciones es aproximada por el mismo motivo — son las funciones que invocan esas migraciones, no solo esa ruta.

El detalle exacto (historial, firmas, dependencias) sale de `python .claude/skills/next-migration-number/deps.py <nombre|ruta>` y `deps.py --version <n>`.

## Indice

- [(transversal)](#transversal) — 21 funcion(es), 0 endpoint(s)
- [academico](#academico) — 1 funcion(es), 0 endpoint(s)
- [actividad](#actividad) — 248 funcion(es), 0 endpoint(s)
- [anio](#anio) — 1 funcion(es), 0 endpoint(s)
- [app](#app) — 1 funcion(es), 0 endpoint(s)
- [area](#area) — 7 funcion(es), 0 endpoint(s)
- [asignacion](#asignacion) — 5 funcion(es), 0 endpoint(s)
- [asignatura](#asignatura) — 13 funcion(es), 0 endpoint(s)
- [asistencia](#asistencia) — 41 funcion(es), 1 endpoint(s)
- [audit](#audit) — 0 funcion(es), 5 endpoint(s)
- [audit-table](#audit-table) — 0 funcion(es), 7 endpoint(s)
- [available](#available) — 1 funcion(es), 0 endpoint(s)
- [cat](#cat) — 5 funcion(es), 0 endpoint(s)
- [catalogo](#catalogo) — 0 funcion(es), 4 endpoint(s)
- [criterio](#criterio) — 10 funcion(es), 0 endpoint(s)
- [cumplimiento](#cumplimiento) — 3 funcion(es), 0 endpoint(s)
- [descanso](#descanso) — 2 funcion(es), 0 endpoint(s)
- [docente](#docente) — 7 funcion(es), 0 endpoint(s)
- [documento](#documento) — 6 funcion(es), 1 endpoint(s)
- [enfasi](#enfasi) — 4 funcion(es), 0 endpoint(s)
- [ente](#ente) — 8 funcion(es), 0 endpoint(s)
- [es](#es) — 2 funcion(es), 0 endpoint(s)
- [escala](#escala) — 9 funcion(es), 0 endpoint(s)
- [especialidad](#especialidad) — 1 funcion(es), 0 endpoint(s)
- [est](#est) — 21 funcion(es), 0 endpoint(s)
- [establecimiento](#establecimiento) — 2 funcion(es), 2 endpoint(s)
- [estudiante](#estudiante) — 15 funcion(es), 0 endpoint(s)
- [fun](#fun) — 19 funcion(es), 0 endpoint(s)
- [funcionario](#funcionario) — 5 funcion(es), 2 endpoint(s)
- [gestion](#gestion) — 4 funcion(es), 0 endpoint(s)
- [grade](#grade) — 2 funcion(es), 0 endpoint(s)
- [grado](#grado) — 10 funcion(es), 0 endpoint(s)
- [grupo](#grupo) — 10 funcion(es), 0 endpoint(s)
- [horario](#horario) — 5 funcion(es), 0 endpoint(s)
- [informe](#informe) — 31 funcion(es), 0 endpoint(s)
- [instrumento](#instrumento) — 2 funcion(es), 0 endpoint(s)
- [jornada](#jornada) — 1 funcion(es), 0 endpoint(s)
- [matricula](#matricula) — 49 funcion(es), 0 endpoint(s)
- [menu](#menu) — 5 funcion(es), 5 endpoint(s)
- [mi](#mi) — 3 funcion(es), 0 endpoint(s)
- [microservice](#microservice) — 1 funcion(es), 0 endpoint(s)
- [my](#my) — 1 funcion(es), 0 endpoint(s)
- [nivel](#nivel) — 1 funcion(es), 0 endpoint(s)
- [nodo](#nodo) — 1 funcion(es), 0 endpoint(s)
- [nota](#nota) — 2 funcion(es), 0 endpoint(s)
- [numero](#numero) — 1 funcion(es), 0 endpoint(s)
- [padre](#padre) — 4 funcion(es), 0 endpoint(s)
- [periodo](#periodo) — 32 funcion(es), 0 endpoint(s)
- [personalizar](#personalizar) — 4 funcion(es), 0 endpoint(s)
- [pigse](#pigse) — 15 funcion(es), 0 endpoint(s)
- [plan](#plan) — 13 funcion(es), 1 endpoint(s)
- [planeador](#planeador) — 12 funcion(es), 26 endpoint(s)
- [planilla](#planilla) — 9 funcion(es), 0 endpoint(s)
- [prematricula](#prematricula) — 16 funcion(es), 0 endpoint(s)
- [promedio](#promedio) — 1 funcion(es), 0 endpoint(s)
- [puede](#puede) — 2 funcion(es), 0 endpoint(s)
- [rango](#rango) — 4 funcion(es), 0 endpoint(s)
- [recuperacion](#recuperacion) — 4 funcion(es), 0 endpoint(s)
- [refcurr](#refcurr) — 35 funcion(es), 0 endpoint(s)
- [refenunc](#refenunc) — 14 funcion(es), 0 endpoint(s)
- [referente](#referente) — 2 funcion(es), 0 endpoint(s)
- [reorder](#reorder) — 1 funcion(es), 0 endpoint(s)
- [resolver](#resolver) — 3 funcion(es), 0 endpoint(s)
- [resultado](#resultado) — 1 funcion(es), 0 endpoint(s)
- [rol](#rol) — 7 funcion(es), 0 endpoint(s)
- [role](#role) — 1 funcion(es), 4 endpoint(s)
- [sed](#sed) — 17 funcion(es), 0 endpoint(s)
- [sede](#sede) — 6 funcion(es), 0 endpoint(s)
- [select](#select) — 0 funcion(es), 2 endpoint(s)
- [sesion](#sesion) — 1 funcion(es), 0 endpoint(s)
- [sincronizar](#sincronizar) — 1 funcion(es), 0 endpoint(s)
- [solicitud](#solicitud) — 17 funcion(es), 0 endpoint(s)
- [subject](#subject) — 6 funcion(es), 0 endpoint(s)
- [superadmin](#superadmin) — 1 funcion(es), 0 endpoint(s)
- [tactividad](#tactividad) — 4 funcion(es), 0 endpoint(s)
- [tg](#tg) — 5 funcion(es), 0 endpoint(s)
- [tinforme](#tinforme) — 1 funcion(es), 0 endpoint(s)
- [tlv](#tlv) — 4 funcion(es), 0 endpoint(s)
- [tr](#tr) — 1 funcion(es), 0 endpoint(s)
- [trg](#trg) — 1 funcion(es), 0 endpoint(s)
- [trol](#trol) — 3 funcion(es), 0 endpoint(s)
- [tsede](#tsede) — 1 funcion(es), 0 endpoint(s)
- [tunidad](#tunidad) — 1 funcion(es), 0 endpoint(s)
- [tusuario](#tusuario) — 1 funcion(es), 0 endpoint(s)
- [unidad](#unidad) — 116 funcion(es), 0 endpoint(s)
- [user](#user) — 2 funcion(es), 0 endpoint(s)
- [usu](#usu) — 9 funcion(es), 0 endpoint(s)
- [usuario](#usuario) — 24 funcion(es), 3 endpoint(s)
- [validar](#validar) — 1 funcion(es), 0 endpoint(s)

## (transversal)

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_assert_permiso_funcionario` | 3 | V29 | V51, V72, V199, V300 |
| `academico_test.fn_assert_permiso_seccion` | 6 | V29 | V37, V39, V40, V51, V111, V138… |
| `academico_test.fn_audit_ctx` | 0 | V184 | V88, V256, V261, V276, V283, V378 |
| `academico_test.fn_audit_declarar` | 5 | V66 | V37, V38, V39, V40, V41, V42… |
| `academico_test.fn_cdc_asegurar_auditoria` | 2 | V283 | V496.1, V496.18 |
| `academico_test.fn_cdc_evento_tabla_nueva` | 0 | V283 | — |
| `academico_test.fn_delete_menu` | 2 | V115 | V126 |
| `academico_test.fn_list_menu_possibilities_for_rol` | 2 | V113 | — |
| `academico_test.fn_menu_catalogo_listar_interno` | 0 | V498 | — |
| `academico_test.fn_menu_codigo_canonico` | 1 | V29 | V113, V303, V396 |
| `academico_test.fn_menu_codigo_desde_nombre` | 1 | V113 | — |
| `academico_test.fn_menu_eliminar_interno` | 1 | V115 | — |
| `academico_test.fn_menu_grupo_de` | 1 | V396 | — |
| `academico_test.fn_menu_validar_codigo_unico` | 1 | V113 | — |
| `academico_test.fn_menu_validar_rama_no_visible` | 1 | V115 | — |
| `academico_test.fn_menu_validar_rama_sin_roles` | 1 | V115 | — |
| `academico_test.fn_upsert_menu` | 11 | V113 | V126 |
| `academico_test.fn_upsert_menu_interno` | 10 | V113 | — |
| `pigse.fn_assert_permiso_funcionario` | 3 | V370 | V386, V390, V393 |
| `pigse.fn_assert_permiso_seccion` | 6 | V370 | V386 |
| `pigse.fn_audit_declarar` | 4 | V362 | V394 |

## academico

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `public.fn_get_academico_usuario_id` | 1 | V299 | V64, V67, V69, V75, V76, V77… |

## actividad

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_actividad_actualizar` | 37 | V496.3 | V246, V496.4 |
| `academico_test.fn_actividad_actualizar_interno` | 37 | V496.2 | V496.3 |
| `academico_test.fn_actividad_adaptacion_archivo_registrar` | 3 | V496.3 | V496.4 |
| `academico_test.fn_actividad_adaptacion_archivos` | 1 | V496.1 | V496.2 |
| `academico_test.fn_actividad_adaptacion_reemplazar` | 3 | V496.3 | V246, V496.4 |
| `academico_test.fn_actividad_adaptacion_reemplazar_interno` | 3 | V496.2 | V496.3 |
| `academico_test.fn_actividad_adaptaciones_reutilizables_listar` | 9 | V471 | — |
| `academico_test.fn_actividad_adaptaciones_reutilizables_listar_interno` | 8 | V496.2 | V471 |
| `academico_test.fn_actividad_archivo_recibido` | 4 | V496.3 | — |
| `academico_test.fn_actividad_asistencia_congelar_interno` | 1 | V496.6 | — |
| `academico_test.fn_actividad_asistencia_dia` | 2 | V450 | V496.5, V496.6 |
| `academico_test.fn_actividad_asistencia_estudiante` | 1 | V496.5 | V496.6 |
| `academico_test.fn_actividad_asistencia_fecha_resolver` | 2 | V496.5 | V469.3 |
| `academico_test.fn_actividad_asistencia_planeador_set` | 3 | V496.7 | V496.8 |
| `academico_test.fn_actividad_asistencia_planeador_set_interno` | 3 | V496.6 | V496.7 |
| `academico_test.fn_actividad_assert_carga_docente` | 4 | V496.1 | V496.3 |
| `academico_test.fn_actividad_assert_escritura` | 4 | V496.3 | — |
| `academico_test.fn_actividad_assert_minimo_evidencia` | 1 | V483 | V496.2 |
| `academico_test.fn_actividad_assert_propietario` | 2 | V496.1 | V492.3, V496.3 |
| `academico_test.fn_actividad_assert_propietario_resultados` | 2 | V496.5 | V496.7 |
| `academico_test.fn_actividad_assert_resultados` | 3 | V496.7 | V461, V463 |
| `academico_test.fn_actividad_auditar` | 3 | V496.3 | V461, V463, V496.7 |
| `academico_test.fn_actividad_buscar_por_pk` | 3 | V452 | V246, V272, V450 |
| `academico_test.fn_actividad_calendario` | 9 | V528 | V528 |
| `academico_test.fn_actividad_calendario_docente` | 8 | V528 | V529 |
| `academico_test.fn_actividad_campos_disponibles` | 2 | V479 | V246, V452 |
| `academico_test.fn_actividad_configuracion_contexto` | 7 | V496 | V496.4 |
| `academico_test.fn_actividad_configuracion_contexto_interno` | 7 | V496 | — |
| `academico_test.fn_actividad_contexto_evaluativo` | 3 | V475 | V475, V479, V496.2, V496.25 |
| `academico_test.fn_actividad_contexto_tipo_evaluacion` | 3 | V479 | — |
| `academico_test.fn_actividad_cotejo_captura_guardar` | 4 | V496.6 | — |
| `academico_test.fn_actividad_cotejo_definir_interno` | 3 | V496.6 | — |
| `academico_test.fn_actividad_crear` | 36 | V496.3 | V246, V340, V496.4 |
| `academico_test.fn_actividad_crear_interno` | 36 | V496.2 | V496.3 |
| `academico_test.fn_actividad_criterio_campos_disponibles` | 2 | V440 | V479, V496 |
| `academico_test.fn_actividad_criterio_evaluacion` | 1 | V496.5 | — |
| `academico_test.fn_actividad_criterio_quitar` | 2 | V496.3 | V246, V496.4 |
| `academico_test.fn_actividad_criterio_quitar_interno` | 2 | V496.2 | V496.3 |
| `academico_test.fn_actividad_criterio_relacionar` | 3 | V496.3 | V246, V496.4 |
| `academico_test.fn_actividad_criterio_relacionar_interno` | 3 | V496.2 | V496.3 |
| `academico_test.fn_actividad_criterios_set_interno` | 3 | V496.2 | — |
| `academico_test.fn_actividad_desempeno_tipo` | 3 | V496.1 | V496.2 |
| `academico_test.fn_actividad_disponibles_listar` | 5 | V223 | V492.4 |
| `academico_test.fn_actividad_eliminar` | 2 | V496.3 | V246, V496.4 |
| `academico_test.fn_actividad_eliminar_interno` | 2 | V482 | V496.3 |
| `academico_test.fn_actividad_en_periodo_eval` | 2 | V332 | V333, V335, V428, V433, V439, V468… |
| `academico_test.fn_actividad_es_formativa` | 1 | V475 | V450, V469.3, V479, V481, V496.4, V496.5… |
| `academico_test.fn_actividad_escala_aplicable` | 2 | V496.1 | V496.2 |
| `academico_test.fn_actividad_escala_criterios_cantidad` | 1 | V496.5 | V496.6 |
| `academico_test.fn_actividad_escala_definir_interno` | 3 | V496.6 | — |
| `academico_test.fn_actividad_escala_porcentaje` | 3 | V496.6 | — |
| `academico_test.fn_actividad_escala_precarga` | 5 | V496.3 | V496.4 |
| `academico_test.fn_actividad_escala_precarga_interno` | 2 | V496.2 | V496.3 |
| `academico_test.fn_actividad_estado` | 5 | V462 | V251, V452, V481, V526, V528, V530 |
| `academico_test.fn_actividad_estado_por_asistencia` | 2 | V496.5 | V496.6 |
| `academico_test.fn_actividad_estado_resultado` | 1 | V496.5 | V496.6 |
| `academico_test.fn_actividad_estudiante_actividad` | 1 | V227 | V461, V463, V496.5, V496.6, V496.7 |
| `academico_test.fn_actividad_estudiante_etiqueta` | 1 | V496.5 | V463, V496.6, V496.7 |
| `academico_test.fn_actividad_estudiante_nombre` | 1 | V496.1 | V136, V496.2, V496.5, V496.6, V496.19 |
| `academico_test.fn_actividad_estudiantes_asignar_detalle_interno` | 4 | V496.2 | V496.3 |
| `academico_test.fn_actividad_estudiantes_asignar_interno` | 4 | V496.2 | — |
| `academico_test.fn_actividad_estudiantes_calificaciones_listar` | 4 | V496.7 | V247, V496.8 |
| `academico_test.fn_actividad_estudiantes_calificaciones_listar_interno` | 3 | V496.6 | V496.7 |
| `academico_test.fn_actividad_estudiantes_con_resultado` | 1 | V496.1 | V496.2 |
| `academico_test.fn_actividad_estudiantes_piar_excluidos` | 1 | V496.2 | — |
| `academico_test.fn_actividad_estudiantes_set` | 4 | V496.3 | — |
| `academico_test.fn_actividad_estudiantes_set_detalle` | 4 | V496.3 | V496.4 |
| `academico_test.fn_actividad_etiqueta` | 1 | V496.1 | V461, V463, V496.2, V496.3, V496.5, V496.6… |
| `academico_test.fn_actividad_etiqueta_de` | 4 | V496.1 | V496.2, V496.3 |
| `academico_test.fn_actividad_evaluacion_requerida` | 1 | V479 | V214.2 |
| `academico_test.fn_actividad_evidencia_quitar` | 2 | V496.3 | V246, V496.4 |
| `academico_test.fn_actividad_evidencia_quitar_interno` | 2 | V496.2 | V496.3 |
| `academico_test.fn_actividad_evidencia_relacionar` | 3 | V496.3 | V246, V496.4 |
| `academico_test.fn_actividad_evidencia_relacionar_interno` | 3 | V496.2 | V496.3 |
| `academico_test.fn_actividad_evidencias_set_interno` | 3 | V496.2 | — |
| `academico_test.fn_actividad_exportar` | 5 | V272 | V129, V273 |
| `academico_test.fn_actividad_fecha_asistencia` | 1 | V450 | V496.5, V496.6 |
| `academico_test.fn_actividad_fecha_inicio_asistencia` | 1 | V450 | V496.6 |
| `academico_test.fn_actividad_finalizacion_refrescar` | 1 | V224 | — |
| `academico_test.fn_actividad_grado` | 2 | V479 | V496.1 |
| `academico_test.fn_actividad_grado_resolver` | 1 | V227 | V272, V408, V496.5, V496.6, V496.18, V496.19 |
| `academico_test.fn_actividad_grupo_etiqueta` | 1 | V496.1 | — |
| `academico_test.fn_actividad_huerfanas_listar` | 8 | V244 | V246 |
| `academico_test.fn_actividad_importar` | 9 | V340 | V129, V275 |
| `academico_test.fn_actividad_instrumento_contexto_assert` | 5 | V479 | V496.1 |
| `academico_test.fn_actividad_instrumento_definir` | 3 | V496.3 | V247, V496.4 |
| `academico_test.fn_actividad_instrumento_definir_interno` | 3 | V496.6 | V340, V496.3 |
| `academico_test.fn_actividad_instrumento_efectivo` | 1 | V496.5 | V496.6, V496.9 |
| `academico_test.fn_actividad_instrumento_nombre_de` | 1 | V496.5 | — |
| `academico_test.fn_actividad_instrumento_obtener` | 2 | V469 | V247, V272, V452 |
| `academico_test.fn_actividad_instrumento_reset` | 3 | V226 | V496.6 |
| `academico_test.fn_actividad_instrumentos_campos_disponibles` | 1 | V458 | V479, V496 |
| `academico_test.fn_actividad_instrumentos_permitidos` | 2 | V214.2 | — |
| `academico_test.fn_actividad_listar` | 19 | V526 | V246, V404 |
| `academico_test.fn_actividad_listar_docente` | 13 | V526 | V250, V527 |
| `academico_test.fn_actividad_listar_interno` | 23 | V526 | V526 |
| `academico_test.fn_actividad_lv_assert` | 3 | V496.1 | — |
| `academico_test.fn_actividad_material_archivo_registrar` | 3 | V496.3 | V496.4 |
| `academico_test.fn_actividad_material_archivos_listar` | 2 | V427 | — |
| `academico_test.fn_actividad_material_reemplazar` | 3 | V496.3 | V246, V496.4 |
| `academico_test.fn_actividad_material_reemplazar_interno` | 3 | V496.2 | V496.3 |
| `academico_test.fn_actividad_materiales_reutilizables_listar` | 8 | V429 | V246 |
| `academico_test.fn_actividad_matriculas_grupo_listar` | 2 | V421 | — |
| `academico_test.fn_actividad_nota_ajustar_por_criterio` | 2 | V496.18 | V408, V469, V496.6, V496.19 |
| `academico_test.fn_actividad_nota_aplicar_interno` | 3 | V496.6 | V496.19 |
| `academico_test.fn_actividad_nota_calificar` | 4 | V496.7 | V247, V496.8 |
| `academico_test.fn_actividad_nota_calificar_cotejo_bulk` | 6 | V496.7 | V247, V496.8 |
| `academico_test.fn_actividad_nota_calificar_cotejo_bulk_interno` | 6 | V496.6 | V496.7 |
| `academico_test.fn_actividad_nota_calificar_cotejo_interno` | 3 | V496.6 | — |
| `academico_test.fn_actividad_nota_calificar_escala_bulk` | 7 | V496.7 | V247, V496.8 |
| `academico_test.fn_actividad_nota_calificar_escala_bulk_interno` | 7 | V496.6 | V496.7 |
| `academico_test.fn_actividad_nota_calificar_escala_criterios_interno` | 3 | V496.6 | — |
| `academico_test.fn_actividad_nota_calificar_escala_interno` | 4 | V496.6 | — |
| `academico_test.fn_actividad_nota_calificar_interno` | 4 | V496.6 | V496.7 |
| `academico_test.fn_actividad_nota_calificar_otro_interno` | 3 | V496.6 | — |
| `academico_test.fn_actividad_nota_calificar_rubrica_bulk` | 6 | V496.7 | V247, V496.8 |
| `academico_test.fn_actividad_nota_calificar_rubrica_bulk_interno` | 6 | V496.6 | V496.7 |
| `academico_test.fn_actividad_nota_calificar_rubrica_interno` | 3 | V496.6 | — |
| `academico_test.fn_actividad_nota_cotejo_recalcular` | 1 | V496.6 | — |
| `academico_test.fn_actividad_nota_get_or_create` | 2 | V227 | V408, V496.6, V496.19 |
| `academico_test.fn_actividad_nota_guardar_interno` | 3 | V496.6 | V496.9 |
| `academico_test.fn_actividad_nota_obtener` | 2 | V496.7 | V247, V496.8 |
| `academico_test.fn_actividad_nota_obtener_interno` | 1 | V496.6 | V496.7 |
| `academico_test.fn_actividad_nota_redondear` | 2 | V496.5 | V496.6 |
| `academico_test.fn_actividad_nota_resultado_instrumento` | 1 | V496.6 | V469.3, V490 |
| `academico_test.fn_actividad_nota_rubrica_recalcular` | 1 | V496.6 | V496.9 |
| `academico_test.fn_actividad_observacion_evidencias_set` | 4 | V463 | V496.6 |
| `academico_test.fn_actividad_observacion_soporte_agregar` | 4 | V461 | — |
| `academico_test.fn_actividad_observacion_soporte_agregar_interno` | 4 | V496.6 | V461 |
| `academico_test.fn_actividad_observacion_soporte_favorito` | 3 | V461 | — |
| `academico_test.fn_actividad_observacion_soporte_favorito_interno` | 3 | V496.6 | V461 |
| `academico_test.fn_actividad_observacion_soporte_quitar` | 3 | V461 | — |
| `academico_test.fn_actividad_observacion_soporte_quitar_interno` | 2 | V496.6 | V461 |
| `academico_test.fn_actividad_observacion_soporte_resolver` | 1 | V496.5 | V461, V496.6 |
| `academico_test.fn_actividad_observacion_soportes_listar` | 2 | V461 | — |
| `academico_test.fn_actividad_observacion_soportes_listar_interno` | 1 | V496.6 | V461 |
| `academico_test.fn_actividad_observar_estudiante` | 7 | V463 | V246, V496.8 |
| `academico_test.fn_actividad_observar_estudiante_interno` | 7 | V496.6 | V463 |
| `academico_test.fn_actividad_observar_grupal` | 7 | V463 | V246, V496.8 |
| `academico_test.fn_actividad_observar_grupal_interno` | 7 | V496.6 | V463 |
| `academico_test.fn_actividad_otro_campos_disponibles` | 1 | V458 | — |
| `academico_test.fn_actividad_otro_definir_interno` | 3 | V496.6 | — |
| `academico_test.fn_actividad_otro_metodo_valoracion` | 1 | V226 | V469.3, V496.5 |
| `academico_test.fn_actividad_otro_sn` | 1 | V469 | V496.6 |
| `academico_test.fn_actividad_pantalla_edicion` | 3 | V452 | V496.4 |
| `academico_test.fn_actividad_periodo_evaluacion` | 2 | V408 | V496.18, V496.19 |
| `academico_test.fn_actividad_ponderacion_campos_disponibles` | 3 | V458 | V479, V496 |
| `academico_test.fn_actividad_programacion_assert` | 6 | V460 | V496.1 |
| `academico_test.fn_actividad_programacion_limites` | 2 | V460 | V496 |
| `academico_test.fn_actividad_progreso_evaluacion` | 1 | V481 | V526 |
| `academico_test.fn_actividad_recuperacion_aplicar` | 2 | V408 | V496.6 |
| `academico_test.fn_actividad_recuperacion_campos_disponibles` | 9 | V496.2 | V479, V496 |
| `academico_test.fn_actividad_recuperacion_configurar_interno` | 3 | V496.2 | — |
| `academico_test.fn_actividad_recuperacion_consolidar` | 3 | V496.19 | V496.19 |
| `academico_test.fn_actividad_recuperacion_consolidar_interno` | 3 | V496.19 | — |
| `academico_test.fn_actividad_recuperacion_revertir` | 2 | V408 | V482, V496.2 |
| `academico_test.fn_actividad_referente_tipo_evaluacion` | 1 | V479 | V214.2, V496.5 |
| `academico_test.fn_actividad_refuerzo_vigente` | 3 | V408 | V496.19 |
| `academico_test.fn_actividad_resultado_correccion_solicitar_interno` | 3 | V496.19 | V496.6 |
| `academico_test.fn_actividad_resultado_desde_asistencia_interno` | 5 | V496.6 | V137, V496.19 |
| `academico_test.fn_actividad_resultado_estado_set` | 3 | V496.7 | V496.8 |
| `academico_test.fn_actividad_resultado_estado_set_bulk` | 4 | V496.7 | V496.8 |
| `academico_test.fn_actividad_resultado_estado_set_bulk_interno` | 4 | V496.6 | V496.7 |
| `academico_test.fn_actividad_resultado_estado_set_interno` | 3 | V496.6 | V496.7 |
| `academico_test.fn_actividad_resultado_registrado` | 1 | V496.5 | V496.6 |
| `academico_test.fn_actividad_resultados_completos` | 1 | V496.5 | V496.6 |
| `academico_test.fn_actividad_resumen_estados` | 9 | V530 | V530 |
| `academico_test.fn_actividad_resumen_estados_docente` | 8 | V530 | V250, V252, V531 |
| `academico_test.fn_actividad_rotulo` | 3 | V496.1 | — |
| `academico_test.fn_actividad_rubrica_captura_guardar` | 4 | V496.6 | — |
| `academico_test.fn_actividad_rubrica_definir_interno` | 3 | V496.6 | — |
| `academico_test.fn_actividad_sede` | 2 | V479 | V496.3 |
| `academico_test.fn_actividad_unidad_configuracion` | 2 | V214.2 | V246, V452 |
| `academico_test.fn_actividad_url_host` | 1 | V496.1 | — |
| `academico_test.fn_actividad_validar_activa` | 1 | V496.1 | V496.2, V496.3, V496.5, V496.6, V496.7 |
| `academico_test.fn_actividad_validar_adaptacion_estudiantes` | 2 | V496.1 | V496.2 |
| `academico_test.fn_actividad_validar_adaptaciones` | 1 | V496.1 | V496.2 |
| `academico_test.fn_actividad_validar_archivo_adaptacion` | 2 | V496.1 | — |
| `academico_test.fn_actividad_validar_archivo_existente` | 2 | V496.1 | V496.3, V496.5 |
| `academico_test.fn_actividad_validar_archivo_formato` | 4 | V496.1 | V496.5 |
| `academico_test.fn_actividad_validar_archivo_material` | 2 | V496.1 | — |
| `academico_test.fn_actividad_validar_asignatura` | 1 | V496.1 | — |
| `academico_test.fn_actividad_validar_asistencia_editable` | 1 | V496.5 | V496.6 |
| `academico_test.fn_actividad_validar_calificable` | 1 | V496.5 | V496.6 |
| `academico_test.fn_actividad_validar_calificacion` | 2 | V496.5 | V496.6 |
| `academico_test.fn_actividad_validar_campos` | 17 | V496.1 | V496.2 |
| `academico_test.fn_actividad_validar_catalogo` | 3 | V496.1 | V496.5 |
| `academico_test.fn_actividad_validar_coherencia` | 17 | V496.1 | V496.2 |
| `academico_test.fn_actividad_validar_cotejo_captura` | 2 | V496.5 | V496.6 |
| `academico_test.fn_actividad_validar_cotejo_definicion` | 2 | V496.5 | — |
| `academico_test.fn_actividad_validar_cotejo_item` | 2 | V496.5 | V496.6 |
| `academico_test.fn_actividad_validar_criterio` | 3 | V496.1 | V496.2 |
| `academico_test.fn_actividad_validar_cumplido` | 1 | V496.5 | V496.6 |
| `academico_test.fn_actividad_validar_editable` | 1 | V496.1 | V496.3 |
| `academico_test.fn_actividad_validar_eliminable` | 1 | V482 | V496.3 |
| `academico_test.fn_actividad_validar_escala_criterios` | 2 | V496.5 | V496.6 |
| `academico_test.fn_actividad_validar_escala_definicion` | 3 | V496.5 | — |
| `academico_test.fn_actividad_validar_escala_valor` | 4 | V496.5 | V496.6 |
| `academico_test.fn_actividad_validar_estado_coherente` | 1 | V496.5 | V496.6 |
| `academico_test.fn_actividad_validar_estado_resultado_asignable` | 1 | V496.5 | V496.6 |
| `academico_test.fn_actividad_validar_estado_transicion` | 2 | V496.5 | V496.6 |
| `academico_test.fn_actividad_validar_estudiante_de` | 2 | V496.5 | — |
| `academico_test.fn_actividad_validar_estudiantes_lote` | 2 | V496.5 | V496.6 |
| `academico_test.fn_actividad_validar_estudiantes_minimo` | 1 | V496.1 | V496.2, V496.3 |
| `academico_test.fn_actividad_validar_evaluativa_contexto` | 4 | V496.1 | — |
| `academico_test.fn_actividad_validar_evidencia` | 3 | V496.1 | V496.2 |
| `academico_test.fn_actividad_validar_evidencias_cantidad` | 1 | V496.5 | V496.6 |
| `academico_test.fn_actividad_validar_evidencias_minimo` | 3 | V496.1 | — |
| `academico_test.fn_actividad_validar_evidencias_narrativas` | 4 | V496.5 | V496.6 |
| `academico_test.fn_actividad_validar_existente` | 1 | V496.1 | V496.2, V496.3, V496.5, V496.7 |
| `academico_test.fn_actividad_validar_fechas_orden` | 2 | V496.1 | — |
| `academico_test.fn_actividad_validar_formativa` | 1 | V496.5 | V496.6 |
| `academico_test.fn_actividad_validar_grupo` | 1 | V496.1 | — |
| `academico_test.fn_actividad_validar_instrumento` | 2 | V496.5 | V496.6 |
| `academico_test.fn_actividad_validar_instrumento_definicion` | 2 | V496.5 | V496.6 |
| `academico_test.fn_actividad_validar_instrumento_permitido` | 2 | V496.5 | — |
| `academico_test.fn_actividad_validar_materiales` | 1 | V496.1 | V496.2 |
| `academico_test.fn_actividad_validar_matriculas` | 4 | V496.1 | V496.2 |
| `academico_test.fn_actividad_validar_momento` | 1 | V496.5 | V496.6 |
| `academico_test.fn_actividad_validar_nota_maxima` | 1 | V496.1 | — |
| `academico_test.fn_actividad_validar_observacion_texto` | 1 | V496.5 | V496.6 |
| `academico_test.fn_actividad_validar_otro_definicion` | 2 | V496.5 | — |
| `academico_test.fn_actividad_validar_periodo_evaluacion_unico` | 4 | V496.1 | — |
| `academico_test.fn_actividad_validar_permite_calificar` | 1 | V496.5 | V496.6 |
| `academico_test.fn_actividad_validar_peso_requerido` | 5 | V496.1 | — |
| `academico_test.fn_actividad_validar_ponderacion` | 4 | V496.1 | — |
| `academico_test.fn_actividad_validar_porcentaje` | 2 | V496.5 | V496.6 |
| `academico_test.fn_actividad_validar_recuperable` | 3 | V496.1 | V496.2 |
| `academico_test.fn_actividad_validar_recuperacion_config` | 1 | V496.1 | V496.2 |
| `academico_test.fn_actividad_validar_recuperacion_herencia` | 1 | V496.1 | — |
| `academico_test.fn_actividad_validar_recuperacion_sumativa` | 3 | V496.1 | — |
| `academico_test.fn_actividad_validar_referente_calificable` | 1 | V496.5 | V496.6 |
| `academico_test.fn_actividad_validar_requerido` | 2 | V496.1 | — |
| `academico_test.fn_actividad_validar_rubrica_captura` | 2 | V496.5 | V496.6 |
| `academico_test.fn_actividad_validar_rubrica_definicion` | 2 | V496.5 | — |
| `academico_test.fn_actividad_validar_rubrica_nivel` | 3 | V496.5 | V496.6 |
| `academico_test.fn_actividad_validar_sin_asistencias` | 1 | V482 | — |
| `academico_test.fn_actividad_validar_sin_notas` | 1 | V496.1 | V482 |
| `academico_test.fn_actividad_validar_sin_recuperaciones` | 1 | V482 | — |
| `academico_test.fn_actividad_validar_texto` | 3 | V496.1 | V496.5 |
| `academico_test.fn_actividad_validar_tiene_unidad` | 3 | V496.1 | — |
| `academico_test.fn_actividad_validar_titulo` | 2 | V496.1 | — |
| `academico_test.fn_actividad_validar_titulo_unico` | 5 | V496.1 | V496.2 |
| `academico_test.fn_actividad_validar_unidad` | 1 | V496.1 | — |
| `academico_test.fn_actividad_validar_unidad_compatible` | 4 | V496.1 | — |
| `academico_test.fn_actividad_validar_unidad_referente_vigente` | 2 | V496.1 | — |
| `academico_test.fn_actividad_validar_url` | 2 | V496.1 | V496.5 |
| `academico_test.fn_actividad_validar_url_dominio` | 4 | V496.1 | — |

## anio

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_anio_lectivo_numero` | 1 | V417 | V418, V468 |

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
| `academico_test.fn_asignacion_docente_listar` | 8 | V264 | V92 |
| `academico_test.fn_asignacion_guardar` | 4 | V46 | V92 |
| `academico_test.fn_asignacion_pool` | 4 | V287 | V92 |
| `academico_test.fn_asignacion_reporte_listar` | 9 | V190 | V135 |

## asignatura

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_asignatura_criterio_evaluacion_vigente` | 2 | V239 | V227, V408, V410, V428, V455, V496.1… |
| `academico_test.fn_asignatura_definitiva_anual_calcular_interno` | 2 | V496.24 | — |
| `academico_test.fn_asignatura_definitiva_anual_interno` | 2 | V496.24 | — |
| `academico_test.fn_asignatura_definitiva_proyectada_periodo` | 3 | V496.23 | V346, V408, V410, V428, V469.3, V490… |
| `academico_test.fn_asignatura_grado_ponderacion_disponible` | 3 | V239 | V248 |
| `academico_test.fn_asignatura_nota_requerida_periodo` | 3 | V496.24 | V428 |
| `academico_test.fn_asignatura_notas_periodo_interno` | 3 | V496.23 | — |
| `academico_test.fn_asignatura_periodos_ponderar` | 2 | V496.24 | — |
| `academico_test.fn_asignatura_plan_calculo_definitiva_modo` | 1 | V239 | V333, V492.1, V496.23 |
| `academico_test.fn_asignatura_plan_elemento_calculo` | 1 | V239 | V333, V492.1, V496.23 |
| `academico_test.fn_asignatura_plan_vigente` | 2 | V239 | V333, V496.23 |
| `academico_test.fn_asignatura_plan_vigente_por_grado` | 2 | V239 | V492.1 |
| `academico_test.fn_asignatura_tipo_evaluacion` | 2 | V428 | V432 |

## asistencia

| Endpoint | Verbo | Migraciones que la tocan | Funciones que invocan (aprox.) |
|---|---|---|---|
| `/asistencias/export-all` | POST | V228 | `fn_asistencia_listar_seguimiento` (V438), `fn_get_academico_usuario_id` (V299) |

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_asistencia_actividades_dia` | 4 | V141 | V221 |
| `academico_test.fn_asistencia_actividades_programadas` | 6 | V457 | V140 |
| `academico_test.fn_asistencia_alta_aplicar_interno` | 3 | V496.19 | — |
| `academico_test.fn_asistencia_alta_solicitar_interno` | 11 | V496.19 | — |
| `academico_test.fn_asistencia_asignaturas_sesion` | 4 | V141 | V221 |
| `academico_test.fn_asistencia_assert_puede_ver` | 3 | V136 | V141 |
| `academico_test.fn_asistencia_bloques_programados` | 4 | V485 | V496.6 |
| `academico_test.fn_asistencia_calendario` | 8 | V140 | V221 |
| `academico_test.fn_asistencia_correccion_requiere_aprobacion` | 1 | V496.18 | V138 |
| `academico_test.fn_asistencia_correccion_solicitar_interno` | 7 | V496.19 | V138 |
| `academico_test.fn_asistencia_editar` | 7 | V138 | V221, V438 |
| `academico_test.fn_asistencia_editar_bulk` | 7 | V438 | — |
| `academico_test.fn_asistencia_editar_interno` | 8 | V137 | V138, V496.19 |
| `academico_test.fn_asistencia_estudiantes_sesion` | 6 | V141 | V221 |
| `academico_test.fn_asistencia_fecha_requiere_aprobacion` | 2 | V496.18 | V137, V138, V141 |
| `academico_test.fn_asistencia_franja_bloque` | 5 | V140 | V141, V457 |
| `academico_test.fn_asistencia_gate_escritura` | 3 | V138 | — |
| `academico_test.fn_asistencia_grupo_es_formativo` | 1 | V436 | V140, V457 |
| `academico_test.fn_asistencia_horas_actividad` | 3 | V140 | V457 |
| `academico_test.fn_asistencia_horas_bloque` | 5 | V140 | V457 |
| `academico_test.fn_asistencia_listar_seguimiento` | 15 | V438 | V221, V228, V290 |
| `academico_test.fn_asistencia_periodo_estado` | 1 | V136 | — |
| `academico_test.fn_asistencia_periodo_eval` | 2 | V137 | V141, V408, V496.6, V496.18, V496.19 |
| `academico_test.fn_asistencia_puede_ver` | 2 | V140 | V136, V457 |
| `academico_test.fn_asistencia_puede_ver_asignatura` | 3 | V136 | V140, V141, V438, V457 |
| `academico_test.fn_asistencia_registrar_bulk` | 8 | V138 | V221 |
| `academico_test.fn_asistencia_registrar_bulk_interno` | 8 | V137 | V138 |
| `academico_test.fn_asistencia_registrar_solicitar_interno` | 9 | V496.19 | V137 |
| `academico_test.fn_asistencia_resumen_horas` | 6 | V140 | V221 |
| `academico_test.fn_asistencia_sesiones_programadas` | 7 | V457 | V136, V140, V485 |
| `academico_test.fn_asistencia_solicitud_pendiente` | 1 | V496.18 | V141, V438, V496.19 |
| `academico_test.fn_asistencia_tipo_pk` | 1 | V137 | V136, V450, V496.6, V496.19 |
| `academico_test.fn_asistencia_tipo_prioridad` | 1 | V438 | — |
| `academico_test.fn_asistencia_validar_contexto` | 3 | V136 | V138 |
| `academico_test.fn_asistencia_validar_docente_asignado` | 4 | V136 | V138 |
| `academico_test.fn_asistencia_validar_excusa_registros` | 2 | V136 | V138 |
| `academico_test.fn_asistencia_validar_excusa_tipo` | 3 | V136 | V138 |
| `academico_test.fn_asistencia_validar_fecha_no_futura` | 1 | V136 | V138, V496.6 |
| `academico_test.fn_asistencia_validar_fecha_programada` | 4 | V136 | V138 |
| `academico_test.fn_asistencia_validar_periodo_abierto` | 2 | V136 | V138 |
| `academico_test.fn_asistencia_validar_tipo` | 1 | V136 | V137, V496.6, V496.19 |

## audit

| Endpoint | Verbo | Migraciones que la tocan | Funciones que invocan (aprox.) |
|---|---|---|---|
| `/audits/query` | POST | V208, V356, V377, V400 | — |
| `/audits/sessions/:SESSIONID` | GET | V90, V133, V183, V356 | — |
| `/audits/sessions/:SESSIONID/operations` | DELETE | V90, V183, V376, V380 | — |
| `/audits/sessions/:SESSIONID/operations` | POST | V356, V362, V376, V380 | `fn_matricula_config_ee_solicitante` (V180), `fn_usuario_tiene_rol` (V257), `fn_get_academico_usuario_id` (V299)… |
| `/audits/stats` | POST | V133, V356, V384, V400 | — |

## audit-table

| Endpoint | Verbo | Migraciones que la tocan | Funciones que invocan (aprox.) |
|---|---|---|---|
| `/audit-tables/:SLUG` | GET | V85, V356 | — |
| `/audit-tables/:SLUG/operations/:OPERATIONID/changes` | DELETE | V134, V183 | — |
| `/audit-tables/:SLUG/operations/:OPERATIONID/changes` | GET | V85, V356 | — |
| `/audit-tables/:SLUG/operations/query` | DELETE | V381 | — |
| `/audit-tables/:SLUG/operations/query` | POST | V355, V356, V362, V376 | `fn_matricula_config_ee_solicitante` (V180), `fn_usuario_tiene_rol` (V257), `fn_get_academico_usuario_id` (V299)… |
| `/audit-tables/:SLUG/operations/stats` | POST | V355, V356, V384, V402 | — |
| `/audit-tables/query` | POST | V85, V356, V381, V403 | — |

## available

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_list_available_menus` | 1 | V498 | V119 |

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
| `academico_test.fn_criterio_eval_actualizar` | 14 | V41 | V76 |
| `academico_test.fn_criterio_eval_obtener` | 2 | V41 | V76 |
| `academico_test.fn_criterio_evaluacion_desempeno_sin_calificar` | 1 | V408 | V496.19, V496.23 |
| `academico_test.fn_criterio_evaluacion_formato` | 1 | V227 | V428, V455, V474, V496.1, V496.2, V496.5 |
| `academico_test.fn_criterio_evaluacion_nota_final_editable` | 1 | V408 | V496.19 |
| `academico_test.fn_criterio_evaluacion_nota_redondear` | 2 | V496.5 | V496.19 |
| `academico_test.fn_criterio_evaluacion_porcentaje_inicial` | 1 | V239 | V227, V408, V496.18, V496.19, V496.23 |
| `academico_test.fn_criterio_evaluacion_porcentaje_maximo_recuperacion` | 1 | V239 | V227, V496.18, V496.19 |
| `academico_test.fn_criterio_prom_guardar` | 13 | V38 | V43, V76 |
| `academico_test.fn_criterio_prom_obtener` | 3 | V38 | V43, V76 |

## cumplimiento

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `pigse.fn_cumplimiento_listar` | 0 | V523 | V262, V524 |
| `pigse.fn_cumplimiento_listar_paginado` | 9 | V524 | V262, V524 |
| `pigse.fn_cumplimiento_metricas` | 0 | V521 | V262 |

## descanso

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_descanso_agregar` | 4 | V37 | V75 |
| `academico_test.fn_descanso_eliminar` | 2 | V37 | V75 |

## docente

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_docente_director_grupo_sync` | 4 | V285 | — |
| `academico_test.fn_docente_grado_asignatura_listar` | 4 | V497 | V248, V497 |
| `academico_test.fn_docente_grado_asignatura_listar_interno` | 3 | V497 | — |
| `academico_test.fn_docente_grado_directores_sync` | 3 | V285 | — |
| `academico_test.fn_docente_grupos_listar` | 3 | V250 | V248 |
| `academico_test.fn_docente_periodo_vigente` | 1 | V250 | V469.4, V497 |
| `academico_test.fn_docente_unidad_tabs_listar` | 1 | V407 | V492.4 |

## documento

| Endpoint | Verbo | Migraciones que la tocan | Funciones que invocan (aprox.) |
|---|---|---|---|
| `/documentos/todos/query` | POST | V495 | — |

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `pigse.fn_documento_categorias_listar` | 2 | V521 | V512, V521, V522 |
| `pigse.fn_documento_eliminar` | 5 | V522 | V262, V512, V515 |
| `pigse.fn_documento_guardar` | 5 | V522 | V262, V512 |
| `pigse.fn_documentos_listar` | 1 | V521 | V262, V512, V515, V521, V523 |
| `pigse.fn_documentos_listar_todos` | 0 | V521 | V374 |
| `pigse.fn_documentos_listar_todos_paginado` | 7 | V374 | V368 |

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
| `academico_test.fn_escala_variantes_permitidas` | 1 | V458 | — |

## especialidad

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_especialidad_enfasis_listar` | 2 | V40 | V77 |

## est

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_est_actualizar` | 34 | V399 | V64, V98 |
| `academico_test.fn_est_buscar_por_nit` | 2 | V53 | V111, V354, V399, V414 |
| `academico_test.fn_est_buscar_por_pk` | 2 | V53 | V98 |
| `academico_test.fn_est_contar` | 5 | V116 | — |
| `academico_test.fn_est_crear` | 32 | V414 | V64, V98 |
| `academico_test.fn_est_listar` | 9 | V116 | V67, V69, V98 |
| `academico_test.fn_est_listar_paginado` | 9 | V116 | V98 |
| `academico_test.fn_est_listar_todos` | 1 | V53 | V98 |
| `academico_test.fn_est_soft_delete` | 2 | V354 | V98 |
| `academico_test.fn_est_soft_delete_bulk` | 2 | V354 | V98 |
| `academico_test.fn_est_zona_sede_defecto` | 1 | V414 | — |
| `academico_test.fn_est_zona_sede_permitida` | 2 | V414 | — |
| `academico_test.fn_est_zonas_sede_permitidas` | 1 | V414 | V442 |
| `academico_test.fn_est_zonas_sede_texto` | 1 | V414 | — |
| `pigse.fn_est_actualizar` | 14 | V362 | V258, V360 |
| `pigse.fn_est_buscar_por_pk` | 2 | V397 | V258 |
| `pigse.fn_est_crear` | 14 | V394 | V258, V360 |
| `pigse.fn_est_listar` | 8 | V387 | V258 |
| `pigse.fn_est_soft_delete` | 2 | V257 | V258 |
| `pigse.fn_est_soft_delete_bulk` | 2 | V392 | V98 |
| `pigse.fn_est_usuario_crear` | 4 | V257 | V369 |

## establecimiento

| Endpoint | Verbo | Migraciones que la tocan | Funciones que invocan (aprox.) |
|---|---|---|---|
| `/establecimientos/bulk-delete` | POST | V366 | `fn_usuario_tiene_rol` (V257), `fn_get_pigse_usuario_id` (V261) |
| `/establecimientos/funcionarios/eliminar-multiple` | PUT | V366 | `fn_usuario_tiene_rol` (V257), `fn_get_pigse_usuario_id` (V261) |

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_establecimiento_fondo_boletin_defecto` | 0 | V467 | — |
| `academico_test.fn_establecimiento_fondo_boletin_trg` | 0 | V467 | — |

## estudiante

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_estudiante_actualizar` | 15 | V177 | — |
| `academico_test.fn_estudiante_anio_observacion_eliminar` | 2 | V490 | V435 |
| `academico_test.fn_estudiante_anio_observacion_fuentes` | 2 | V486 | — |
| `academico_test.fn_estudiante_anio_observacion_fuentes_interno` | 1 | V486 | — |
| `academico_test.fn_estudiante_anio_observacion_guardar` | 5 | V490 | V435 |
| `academico_test.fn_estudiante_crear` | 12 | V160 | V415 |
| `academico_test.fn_estudiante_dependencias_bloqueantes` | 2 | V162 | V160 |
| `academico_test.fn_estudiante_final_observacion` | 2 | V490 | V434 |
| `academico_test.fn_estudiante_obtener_por_id` | 2 | V160 | V204 |
| `academico_test.fn_estudiante_periodo_observacion_eliminar` | 3 | V490 | V413 |
| `academico_test.fn_estudiante_periodo_observacion_fuentes` | 3 | V486 | — |
| `academico_test.fn_estudiante_periodo_observacion_fuentes_interno` | 2 | V486 | — |
| `academico_test.fn_estudiante_periodo_observacion_generar` | 3 | V490 | V343 |
| `academico_test.fn_estudiante_periodo_observacion_guardar` | 6 | V490 | V343 |
| `academico_test.fn_estudiante_soft_delete` | 4 | V160 | V166 |

## fun

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_fun_activo_por_usuario` | 1 | V51 | V93 |
| `academico_test.fn_fun_actualizar` | 42 | V72 | V93 |
| `academico_test.fn_fun_baja_establecimiento` | 2 | V300 | V51, V93 |
| `academico_test.fn_fun_baja_establecimiento_bulk` | 2 | V51 | V93 |
| `academico_test.fn_fun_cancelar_pendiente` | 2 | V51 | V93 |
| `academico_test.fn_fun_crear` | 15 | V51 | V258 |
| `academico_test.fn_fun_enlazar_establecimiento` | 3 | V51 | V93 |
| `academico_test.fn_fun_filtros_permiso_actualizar` | 3 | V199 | — |
| `academico_test.fn_fun_filtros_permiso_listar` | 2 | V199 | — |
| `academico_test.fn_fun_permisos_actualizar` | 3 | V297 | V93, V111, V399 |
| `pigse.fn_fun_actualizar` | 20 | V390 | V258, V369 |
| `pigse.fn_fun_asignar_rol` | 3 | V369 | — |
| `pigse.fn_fun_baja_bulk` | 2 | V366 | — |
| `pigse.fn_fun_buscar_por_pk` | 2 | V390 | V258 |
| `pigse.fn_fun_cancelar_pendiente` | 2 | V360 | V93 |
| `pigse.fn_fun_crear` | 11 | V393 | V258 |
| `pigse.fn_fun_listar` | 10 | V386 | V258 |
| `pigse.fn_fun_permisos_actualizar` | 3 | V390 | V370 |
| `pigse.fn_fun_soft_delete` | 2 | V370 | V258 |

## funcionario

| Endpoint | Verbo | Migraciones que la tocan | Funciones que invocan (aprox.) |
|---|---|---|---|
| `/funcionario/:ID/filtros-permiso` | GET | V199 | `fn_assert_permiso_funcionario` (V370), `fn_get_academico_usuario_id` (V299) |
| `/funcionario/:ID/filtros-permiso` | PUT | V199 | `fn_assert_permiso_funcionario` (V370), `fn_get_academico_usuario_id` (V299) |

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_funcionario_actual` | 1 | V224 | V250, V251, V407, V469.4, V481, V492.3… |
| `academico_test.fn_funcionario_archivo_crear` | 5 | V443 | V445 |
| `academico_test.fn_funcionario_archivo_eliminar` | 2 | V443 | V445 |
| `academico_test.fn_funcionario_archivo_listar` | 2 | V443 | — |
| `academico_test.fn_funcionario_sede_listar` | 3 | V43 | V79 |

## gestion

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `pigse.fn_gestion_documental_excepcion_eliminar` | 3 | V522 | — |
| `pigse.fn_gestion_documental_excepcion_guardar` | 4 | V522 | — |
| `pigse.fn_gestion_documental_fecha_limite_guardar` | 3 | V522 | — |
| `pigse.fn_gestion_documental_fecha_limite_obtener` | 0 | V522 | — |

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
| `academico_test.fn_grado_desempeno_minimo` | 1 | V334 | V346, V410, V428, V439, V490, V496.2… |
| `academico_test.fn_grado_es_preescolar` | 1 | V285 | V286, V287, V437 |
| `academico_test.fn_grado_grupo_etiqueta` | 3 | V224 | V251, V452, V468, V481, V490, V526… |
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
| `academico_test.fn_grupo_director_rol_sync_interno` | 5 | V285 | — |
| `academico_test.fn_grupo_establecimiento` | 1 | V40 | V138, V140, V429, V496.20, V507 |
| `academico_test.fn_grupo_jornada` | 1 | V40 | V138, V140, V496.20, V507 |
| `academico_test.fn_grupo_listar` | 7 | V43 | V79 |
| `academico_test.fn_grupo_obtener` | 2 | V43 | V79 |
| `academico_test.fn_grupo_periodo` | 1 | V40 | V136, V137, V138, V140, V469.2, V469.3… |
| `academico_test.fn_grupo_soft_delete` | 2 | V43 | V79 |

## horario

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_horario_asignaturas` | 2 | V45 | V80 |
| `academico_test.fn_horario_calcular_bloques` | 1 | V45 | V437, V460 |
| `academico_test.fn_horario_guardar` | 3 | V45 | V43, V80 |
| `academico_test.fn_horario_listar` | 3 | V45 | V43, V80 |
| `academico_test.fn_horario_preescolar_autogenerar` | 2 | V437 | — |

## informe

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_informe_alcanza_sede_jornada` | 3 | V417 | — |
| `academico_test.fn_informe_anos_listar` | 2 | V417 | — |
| `academico_test.fn_informe_assert_grupo_propio` | 2 | V489 | V490, V496.20, V496.24, V496.25 |
| `academico_test.fn_informe_assert_puede_escribir` | 1 | V496.26 | V490, V496.24 |
| `academico_test.fn_informe_boletin_preescolar` | 4 | V468 | V466 |
| `academico_test.fn_informe_cambios_pendientes` | 3 | V491 | V342 |
| `academico_test.fn_informe_desactualizado` | 3 | V496.20 | V496.21 |
| `academico_test.fn_informe_desactualizado_interno` | 2 | V496.19 | V496.20 |
| `academico_test.fn_informe_desactualizado_marcar_interno` | 2 | V496.19 | — |
| `academico_test.fn_informe_estudiante_asignaturas` | 4 | V428 | V335, V346, V439, V490, V491, V496.24 |
| `academico_test.fn_informe_final_guardar` | 3 | V496.24 | — |
| `academico_test.fn_informe_final_guardar_interno` | 3 | V496.24 | — |
| `academico_test.fn_informe_formativo_listar` | 4 | V496.25 | — |
| `academico_test.fn_informe_formativo_listar_interno` | 3 | V496.25 | — |
| `academico_test.fn_informe_grupo_listar` | 4 | V496.24 | V342, V439, V468, V496.25 |
| `academico_test.fn_informe_grupo_reporte` | 5 | V439 | V420 |
| `academico_test.fn_informe_grupo_tabla` | 4 | V496.25 | V434 |
| `academico_test.fn_informe_grupos_listar` | 5 | V490 | V419 |
| `academico_test.fn_informe_historial_listar` | 5 | V491 | V349 |
| `academico_test.fn_informe_historial_registrar` | 6 | V348 | V490 |
| `academico_test.fn_informe_jornadas_listar` | 3 | V417 | — |
| `academico_test.fn_informe_metricas_recalcular` | 3 | V346 | V490 |
| `academico_test.fn_informe_periodo_academico_resolver` | 4 | V418 | V490 |
| `academico_test.fn_informe_periodo_evidencias_listar` | 3 | V490 | V434 |
| `academico_test.fn_informe_periodo_guardar` | 4 | V490 | V342 |
| `academico_test.fn_informe_periodo_requerido` | 3 | V428 | V439, V490, V496.24 |
| `academico_test.fn_informe_periodos_evaluacion_listar` | 4 | V418 | — |
| `academico_test.fn_informe_planilla_guardar` | 5 | V490 | V347 |
| `academico_test.fn_informe_planilla_listar` | 5 | V490 | V345 |
| `academico_test.fn_informe_planillas_pendientes` | 3 | V491 | V342 |
| `academico_test.fn_informe_sedes_listar` | 1 | V417 | — |

## instrumento

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_instrumento_nombre` | 1 | V214.2 | V479, V496.3 |
| `academico_test.fn_instrumento_permitido_por_tipo_evaluacion` | 2 | V458 | V214.2, V496.5 |

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
| `academico_test.fn_matricula_archivo_crear` | 4 | V165 | V177, V201, V416 |
| `academico_test.fn_matricula_archivo_crear_lote` | 7 | V416 | V415 |
| `academico_test.fn_matricula_archivo_listar_por_matricula` | 2 | V165 | V204 |
| `academico_test.fn_matricula_archivo_soft_delete` | 2 | V165 | V166 |
| `academico_test.fn_matricula_campo_sync_no_editable` | 0 | V159 | — |
| `academico_test.fn_matricula_config_actualizar` | 3 | V159 | — |
| `academico_test.fn_matricula_config_crear` | 2 | V159 | — |
| `academico_test.fn_matricula_config_crear_interno` | 2 | V159 | V180, V181, V182 |
| `academico_test.fn_matricula_config_editar_campo` | 4 | V180 | V127 |
| `academico_test.fn_matricula_config_ee_solicitante` | 1 | V180 | V181, V182, V362, V496.22 |
| `academico_test.fn_matricula_config_obtener` | 1 | V182 | V127 |
| `academico_test.fn_matricula_config_trg_establecimiento` | 0 | V159 | — |
| `academico_test.fn_matricula_corregir_lote` | 3 | V178 | V129, V179 |
| `academico_test.fn_matricula_crear` | 7 | V163 | V415 |
| `academico_test.fn_matricula_cupo_ocupado` | 2 | V145 | V178, V205, V350, V351 |
| `academico_test.fn_matricula_dependencias_bloqueantes` | 1 | V162 | V163, V166 |
| `academico_test.fn_matricula_directa_actualizar` | 71 | V177 | V179 |
| `academico_test.fn_matricula_directa_crear` | 57 | V415 | V167 |
| `academico_test.fn_matricula_directa_eliminar` | 2 | V166 | V127, V169 |
| `academico_test.fn_matricula_directa_eliminar_bulk` | 2 | V166 | V127, V169 |
| `academico_test.fn_matricula_documento_otro_agregar` | 3 | V201 | — |
| `academico_test.fn_matricula_es_cursando` | 1 | V421 | V422, V496.1, V496.2 |
| `academico_test.fn_matricula_gate_escritura` | 3 | V40 | V163, V164, V165, V415 |
| `academico_test.fn_matricula_grupo` | 1 | V40 | V163, V164, V165, V490 |
| `academico_test.fn_matricula_listar` | 11 | V270 | V127, V206 |
| `academico_test.fn_matricula_mover_lote` | 8 | V178 | — |
| `academico_test.fn_matricula_obtener_completa` | 2 | V204 | V168 |
| `academico_test.fn_matricula_obtener_por_id` | 2 | V163 | V204 |
| `academico_test.fn_matricula_promover_lote` | 5 | V178 | V129, V179 |
| `academico_test.fn_matricula_puede_cambiar_estado` | 3 | V233 | V166, V177, V178 |
| `academico_test.fn_matricula_puede_ver` | 2 | V40 | — |
| `academico_test.fn_matricula_reactivar` | 2 | V166 | V127, V173 |
| `academico_test.fn_matricula_reingresar` | 2 | V166 | V127, V172 |
| `academico_test.fn_matricula_replicar` | 3 | V175 | V178 |
| `academico_test.fn_matricula_retirar` | 2 | V166 | V127, V171 |
| `academico_test.fn_matricula_reubicar_lote` | 5 | V178 | V129, V179 |
| `academico_test.fn_matricula_socioeconomico_actualizar` | 18 | V177 | — |
| `academico_test.fn_matricula_socioeconomico_crear` | 18 | V164 | V177, V415 |
| `academico_test.fn_matricula_socioeconomico_obtener_por_matricula` | 2 | V164 | V204 |
| `academico_test.fn_matricula_socioeconomico_soft_delete` | 2 | V164 | V166 |
| `academico_test.fn_matricula_soft_delete` | 2 | V163 | V166 |
| `academico_test.fn_matricula_validar_cupo` | 1 | V205 | V415 |
| `academico_test.fn_matricula_validar_estudiante_disponible` | 1 | V162 | V415 |
| `academico_test.fn_matricula_validar_periodo_vigente` | 2 | V162 | V166, V177, V178 |
| `academico_test.fn_matricula_validar_plazo_matricula` | 1 | V415 | — |
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
| `academico_test.fn_associate_menus_to_rol` | 5 | V498 | V129, V198 |
| `academico_test.fn_dissociate_menus_from_rol` | 3 | V113 | — |
| `academico_test.fn_menus_reordenar_interno` | 2 | V498 | — |
| `academico_test.fn_menus_validar_hermanos` | 1 | V498 | — |
| `academico_test.fn_menus_validar_lista` | 2 | V498 | — |

## mi

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_mi_establecimiento_para_auditoria` | 1 | V496.22 | — |
| `pigse.fn_mi_establecimiento` | 1 | V261 | V262, V512, V515, V521, V522 |
| `pigse.fn_mi_establecimiento_para_auditoria` | 1 | V362 | — |

## microservice

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `public.fn_microservice_validar_file_storage` | 0 | V147 | — |

## my

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_list_my_menus` | 1 | V193 | V194 |

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
| `academico_test.fn_nota_homologar` | 3 | V428 | V432, V439, V469.3, V490, V496.6, V496.24 |
| `academico_test.fn_nota_redondear` | 3 | V496.5 | — |

## numero

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_numero_corto` | 1 | V496.6 | V496.5 |

## padre

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_padre_actualizar` | 23 | V177 | — |
| `academico_test.fn_padre_crear` | 22 | V161 | V177, V415 |
| `academico_test.fn_padre_obtener_por_id` | 2 | V161 | V204 |
| `academico_test.fn_padre_soft_delete` | 3 | V161 | V166 |

## periodo

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_periodo_actualizar` | 15 | V37 | V75 |
| `academico_test.fn_periodo_anos_lectivos_listar` | 1 | V191 | V75 |
| `academico_test.fn_periodo_anteriores_por_sede` | 3 | V37 | V75 |
| `academico_test.fn_periodo_areas_asignaturas_listar` | 2 | V40 | V77 |
| `academico_test.fn_periodo_bulk_delete` | 2 | V37 | V75 |
| `academico_test.fn_periodo_crear` | 14 | V81 | V75 |
| `academico_test.fn_periodo_detalle` | 2 | V37 | V75 |
| `academico_test.fn_periodo_establecimiento` | 1 | V29 | V39, V40, V41, V42, V43, V44… |
| `academico_test.fn_periodo_eval_actualizar` | 9 | V39 | V76 |
| `academico_test.fn_periodo_eval_bulk_delete` | 2 | V39 | V76 |
| `academico_test.fn_periodo_eval_crear` | 9 | V39 | V76 |
| `academico_test.fn_periodo_eval_detalle` | 2 | V39 | V76 |
| `academico_test.fn_periodo_eval_listar` | 7 | V39 | V76, V124 |
| `academico_test.fn_periodo_eval_soft_delete` | 2 | V39 | V76 |
| `academico_test.fn_periodo_eval_validar` | 8 | V39 | — |
| `academico_test.fn_periodo_evaluacion_admite_refuerzo` | 1 | V496.18 | — |
| `academico_test.fn_periodo_evaluacion_calificable` | 1 | V496.18 | — |
| `academico_test.fn_periodo_evaluacion_listar` | 5 | V469.4 | V469.5 |
| `academico_test.fn_periodo_evaluacion_listar_interno` | 2 | V469.3 | V469.4 |
| `academico_test.fn_periodo_gate_escritura` | 5 | V29 | V37, V38, V39, V40, V41, V42… |
| `academico_test.fn_periodo_jornada` | 1 | V29 | V37, V38, V39, V40, V41, V42… |
| `academico_test.fn_periodo_jornadas_listar` | 2 | V191 | — |
| `academico_test.fn_periodo_listar` | 11 | V37 | V75, V124 |
| `academico_test.fn_periodo_puede_ver` | 2 | V29 | V37, V38, V39, V40, V41, V42… |
| `academico_test.fn_periodo_resolver_matricula` | 4 | V415 | V127 |
| `academico_test.fn_periodo_sede` | 1 | V29 | V37, V38, V39, V40, V41, V42… |
| `academico_test.fn_periodo_sedes_listar` | 1 | V191 | — |
| `academico_test.fn_periodo_soft_delete` | 2 | V37 | V75 |
| `academico_test.fn_periodo_usuario_establecimientos` | 1 | V37 | V191 |
| `academico_test.fn_periodo_usuario_global` | 1 | V37 | V191 |
| `academico_test.fn_periodo_usuario_puede_ver` | 2 | V37 | V250, V270, V350, V351, V415, V469.4… |
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
| `academico_test.fn_pigse_documentos_listar` | 1 | V156 | V156 |
| `academico_test.fn_pigse_mi_establecimiento` | 1 | V149 | V156 |
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
| `academico_test.fn_plan_eliminar` | 2 | V285 | V44, V80 |
| `academico_test.fn_plan_eliminar_restricciones` | 2 | V286 | — |
| `academico_test.fn_plan_listar` | 7 | V44 | V80 |
| `academico_test.fn_plan_obtener` | 2 | V44 | V80 |
| `academico_test.fn_plan_reporte_listar` | 7 | V186 | V135 |
| `academico_test.fn_plan_soft_delete` | 2 | V44 | V80 |

## planeador

| Endpoint | Verbo | Migraciones que la tocan | Funciones que invocan (aprox.) |
|---|---|---|---|
| `/planeador/actividades` | GET | V275, V404 | `fn_actividad_importar` (V340), `fn_actividad_listar` (V526), `fn_get_academico_usuario_id` (V299) |
| `/planeador/actividades` | POST | V275 | `fn_actividad_importar` (V340), `fn_get_academico_usuario_id` (V299) |
| `/planeador/actividades/:ID` | GET | V246, V450, V452, V475 | `fn_actividad_actualizar` (V496.3), `fn_actividad_adaptacion_reemplazar` (V496.3), `fn_actividad_buscar_por_pk` (V452)… |
| `/planeador/actividades/:ID/configuracion` | GET | V246, V475, V479 | `fn_actividad_actualizar` (V496.3), `fn_actividad_adaptacion_reemplazar` (V496.3), `fn_actividad_buscar_por_pk` (V452)… |
| `/planeador/actividades/:ID/instrumento` | GET | V247 | `fn_actividad_estudiantes_calificaciones_listar` (V496.7), `fn_actividad_instrumento_definir` (V496.3), `fn_actividad_instrumento_obtener` (V469)… |
| `/planeador/actividades/:ID/materiales-reutilizables` | GET | V246 | `fn_actividad_actualizar` (V496.3), `fn_actividad_adaptacion_reemplazar` (V496.3), `fn_actividad_buscar_por_pk` (V452)… |
| `/planeador/actividades/:ID/observar-grupal` | POST | V246, V496.8 | `fn_actividad_actualizar` (V496.3), `fn_actividad_adaptacion_reemplazar` (V496.3), `fn_actividad_asistencia_planeador_set` (V496.7)… |
| `/planeador/actividades/:ID/observar-grupal` | PUT | V246, V463 | `fn_actividad_actualizar` (V496.3), `fn_actividad_adaptacion_reemplazar` (V496.3), `fn_actividad_assert_resultados` (V496.7)… |
| `/planeador/actividades/calendario` | GET | V251, V529 | `fn_actividad_calendario_docente` (V528), `fn_actividad_estado` (V462), `fn_funcionario_actual` (V224)… |
| `/planeador/actividades/estudiantes-grupo` | GET | V421 | `fn_planeador_assert_alcance` (V277), `fn_get_academico_usuario_id` (V299) |
| `/planeador/actividades/estudiantes/:ID/observar` | POST | V246, V463 | `fn_actividad_actualizar` (V496.3), `fn_actividad_adaptacion_reemplazar` (V496.3), `fn_actividad_assert_resultados` (V496.7)… |
| `/planeador/actividades/estudiantes/:ID/observar` | PUT | V246, V496.8 | `fn_actividad_actualizar` (V496.3), `fn_actividad_adaptacion_reemplazar` (V496.3), `fn_actividad_asistencia_planeador_set` (V496.7)… |
| `/planeador/actividades/export-all` | GET | V404 | `fn_actividad_listar` (V526), `fn_get_academico_usuario_id` (V299) |
| `/planeador/actividades/export-all` | POST | V404 | `fn_actividad_listar` (V526), `fn_get_academico_usuario_id` (V299) |
| `/planeador/actividades/exportar` | GET | V273 | `fn_actividad_exportar` (V272), `fn_get_academico_usuario_id` (V299) |
| `/planeador/actividades/exportar` | POST | V273 | `fn_actividad_exportar` (V272), `fn_get_academico_usuario_id` (V299) |
| `/planeador/actividades/huerfanas` | GET | V246 | `fn_actividad_actualizar` (V496.3), `fn_actividad_adaptacion_reemplazar` (V496.3), `fn_actividad_buscar_por_pk` (V452)… |
| `/planeador/actividades/importar` | GET | V275 | `fn_actividad_importar` (V340), `fn_get_academico_usuario_id` (V299) |
| `/planeador/actividades/importar` | POST | V275 | `fn_actividad_importar` (V340), `fn_get_academico_usuario_id` (V299) |
| `/planeador/actividades/mias` | GET | V250, V253, V279, V527 | `fn_actividad_listar_docente` (V526), `fn_actividad_resumen_estados_docente` (V530), `fn_funcionario_actual` (V224)… |
| `/planeador/actividades/stats` | GET | V252, V531 | `fn_actividad_resumen_estados_docente` (V530), `fn_get_academico_usuario_id` (V299) |
| `/planeador/actividades/tablero` | GET | V250, V531 | `fn_actividad_listar_docente` (V526), `fn_actividad_resumen_estados_docente` (V530), `fn_funcionario_actual` (V224)… |
| `/planeador/asignaturas/:ID/ponderacion-disponible` | GET | V248 | `fn_asignatura_grado_ponderacion_disponible` (V239), `fn_docente_grado_asignatura_listar` (V497), `fn_docente_grupos_listar` (V250)… |
| `/planeador/docentes/grado-asignatura` | GET | V248, V497 | `fn_asignatura_grado_ponderacion_disponible` (V239), `fn_docente_grado_asignatura_listar` (V497), `fn_docente_grupos_listar` (V250)… |
| `/planeador/docentes/grupos` | GET | V248 | `fn_asignatura_grado_ponderacion_disponible` (V239), `fn_docente_grado_asignatura_listar` (V497), `fn_docente_grupos_listar` (V250)… |
| `/planeador/referente-curricular` | GET | V278, V422 | `fn_matricula_es_cursando` (V421), `fn_planeador_assert_alcance` (V277), `fn_assert_permiso_seccion` (V370)… |

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_planeador_actividad_tabs_listar` | 1 | V525 | — |
| `academico_test.fn_planeador_actividad_tabs_listar_interno` | 4 | V525 | — |
| `academico_test.fn_planeador_alcanza` | 6 | V277 | V272, V340 |
| `academico_test.fn_planeador_assert_alcance` | 7 | V277 | V214.2, V223, V239, V278, V421, V422… |
| `academico_test.fn_planeador_estudiantes_candidatos_listar` | 7 | V422 | — |
| `academico_test.fn_planeador_etiqueta_a_lv` | 2 | V274 | V340 |
| `academico_test.fn_planeador_listado_alcance` | 1 | V481 | V488, V525, V526 |
| `academico_test.fn_planeador_periodo_vigente` | 3 | V203 | V272, V340 |
| `academico_test.fn_planeador_rotulo_actividad` | 4 | V511 | — |
| `academico_test.fn_planeador_rotulo_actividad_interno` | 3 | V511 | — |
| `academico_test.fn_planeador_rotulo_pluralizar` | 1 | V525 | — |
| `academico_test.fn_planeador_sn` | 2 | V274 | V340 |

## planilla

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_planilla_actividades_universo` | 6 | V469.3 | — |
| `academico_test.fn_planilla_calificaciones_listar` | 11 | V469.4 | V469.5 |
| `academico_test.fn_planilla_calificaciones_listar_interno` | 9 | V469.3 | V469.4 |
| `academico_test.fn_planilla_columnas_listar` | 8 | V469.4 | V469.5 |
| `academico_test.fn_planilla_columnas_listar_interno` | 6 | V469.3 | V469.4 |
| `academico_test.fn_planilla_definitiva_proyectada` | 2 | V239 | V408 |
| `academico_test.fn_planilla_grupo_asignatura_assert` | 3 | V469.2 | V346, V469.4, V490 |
| `academico_test.fn_planilla_periodo_eval_resolver` | 2 | V469.3 | V469.4 |
| `academico_test.fn_planilla_validar_periodo_del_grupo` | 2 | V469.2 | V469.3 |

## prematricula

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_prematricula_assert_grupo_no_procesado` | 1 | V505 | V508 |
| `academico_test.fn_prematricula_assert_periodo_siguiente` | 2 | V504 | V507 |
| `academico_test.fn_prematricula_buscar_por_pk` | 2 | V351 | — |
| `academico_test.fn_prematricula_crear` | 8 | V506 | V508 |
| `academico_test.fn_prematricula_estado` | 1 | V502 | V508 |
| `academico_test.fn_prematricula_gate_ee` | 4 | V507 | — |
| `academico_test.fn_prematricula_gate_grupo` | 3 | V507 | V508 |
| `academico_test.fn_prematricula_grupo_elegir` | 2 | V503 | — |
| `academico_test.fn_prematricula_grupo_procesado` | 1 | V505 | — |
| `academico_test.fn_prematricula_grupo_procesar` | 3 | V508 | V510 |
| `academico_test.fn_prematricula_grupos_destino` | 1 | V503 | V507, V508 |
| `academico_test.fn_prematricula_listar` | 19 | V350 | — |
| `academico_test.fn_prematricula_matricula_procesable` | 1 | V505 | V508 |
| `academico_test.fn_prematricula_periodo_siguiente` | 1 | V503 | V504, V505 |
| `academico_test.fn_prematricula_periodos_actuales` | 2 | V504 | V507 |
| `academico_test.fn_prematricula_plan_listar` | 3 | V507 | V509 |

## promedio

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_promedio_homologar` | 2 | V474 | V490, V493, V496.24 |

## puede

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_puede_afectar_establecimiento` | 1 | V302 | V111 |
| `academico_test.fn_puede_afectar_usuarios` | 1 | V50 | V30, V150 |

## rango

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_assert_rango_rol` | 2 | V298 | V29, V51, V297 |
| `academico_test.fn_assert_rango_rol_otorgable` | 2 | V298 | V111, V297 |
| `pigse.fn_assert_rango_rol` | 2 | V370 | V29, V51, V297 |
| `pigse.fn_assert_rango_rol_otorgable` | 2 | V370 | V390 |

## recuperacion

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_recuperacion_aprobada_vigente` | 3 | V496.18 | V496.19 |
| `academico_test.fn_recuperacion_combinar` | 7 | V496.19 | V496.19 |
| `academico_test.fn_recuperacion_definitiva_periodo` | 3 | V408 | V496.19 |
| `academico_test.fn_recuperacion_tipo_aprobacion` | 1 | V496.18 | V496.19 |

## refcurr

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_refcurr_actualizar` | 18 | V214.3 | V214 |
| `academico_test.fn_refcurr_actualizar_interno` | 18 | V214.3 | — |
| `academico_test.fn_refcurr_areas_listar` | 2 | V213 | V214 |
| `academico_test.fn_refcurr_buscar_por_pk` | 2 | V214.3 | V214 |
| `academico_test.fn_refcurr_buscar_por_pk_interno` | 1 | V214.3 | — |
| `academico_test.fn_refcurr_crear` | 17 | V214.3 | V214 |
| `academico_test.fn_refcurr_crear_interno` | 17 | V214.3 | — |
| `academico_test.fn_refcurr_eliminar` | 3 | V213 | V214 |
| `academico_test.fn_refcurr_eliminar_interno` | 3 | V213 | — |
| `academico_test.fn_refcurr_enfoque_guard` | 0 | V214.2 | — |
| `academico_test.fn_refcurr_grados_disponibles_interno` | 1 | V213 | V214.3 |
| `academico_test.fn_refcurr_grados_listar` | 2 | V214.3 | — |
| `academico_test.fn_refcurr_grados_vinculados_interno` | 1 | V214.3 | V492.1 |
| `academico_test.fn_refcurr_impacto` | 2 | V214.3 | — |
| `academico_test.fn_refcurr_impacto_interno` | 1 | V214.3 | — |
| `academico_test.fn_refcurr_listar` | 11 | V214.3 | V214 |
| `academico_test.fn_refcurr_listar_interno` | 10 | V214.3 | — |
| `academico_test.fn_refcurr_niveles_listar` | 2 | V213 | V214 |
| `academico_test.fn_refcurr_nombre_asignatura` | 2 | V214.3 | — |
| `academico_test.fn_refcurr_nombre_asignatura_default` | 1 | V214.3 | — |
| `academico_test.fn_refcurr_por_grado_asignatura` | 4 | V422 | — |
| `academico_test.fn_refcurr_uso_assert` | 2 | V213 | — |
| `academico_test.fn_refcurr_validar_areas` | 1 | V214.3 | — |
| `academico_test.fn_refcurr_validar_areas_sin_enunciados` | 2 | V214.3 | — |
| `academico_test.fn_refcurr_validar_campos` | 13 | V214.3 | — |
| `academico_test.fn_refcurr_validar_enfoque_tipo` | 2 | V214.3 | — |
| `academico_test.fn_refcurr_validar_estado` | 1 | V213 | V214.3 |
| `academico_test.fn_refcurr_validar_existe` | 1 | V213 | V214.3 |
| `academico_test.fn_refcurr_validar_lista_valor` | 3 | V214.3 | — |
| `academico_test.fn_refcurr_validar_nivel_unico_activo` | 2 | V214.3 | — |
| `academico_test.fn_refcurr_validar_niveles` | 1 | V214.3 | — |
| `academico_test.fn_refcurr_validar_niveles_con_grados` | 2 | V214.3 | — |
| `academico_test.fn_refcurr_validar_nombre_unico` | 3 | V214.3 | — |
| `academico_test.fn_refcurr_validar_texto` | 4 | V213 | V214.3 |
| `academico_test.fn_refcurr_validar_vigencia` | 2 | V214.3 | — |

## refenunc

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_refenunc_actualizar` | 4 | V213 | V214 |
| `academico_test.fn_refenunc_actualizar_interno` | 4 | V213 | — |
| `academico_test.fn_refenunc_crear` | 7 | V213 | V214 |
| `academico_test.fn_refenunc_crear_interno` | 7 | V213 | — |
| `academico_test.fn_refenunc_eliminar` | 2 | V213 | V214 |
| `academico_test.fn_refenunc_eliminar_interno` | 2 | V213 | — |
| `academico_test.fn_refenunc_evidencias_listar` | 3 | V213 | V214 |
| `academico_test.fn_refenunc_listar` | 5 | V213 | V214 |
| `academico_test.fn_refenunc_listar_interno` | 4 | V213 | — |
| `academico_test.fn_refenunc_referenciado_alguna_vez` | 1 | V492.1 | V213 |
| `academico_test.fn_refenunc_validar_area` | 2 | V213 | — |
| `academico_test.fn_refenunc_validar_existe` | 1 | V213 | — |
| `academico_test.fn_refenunc_validar_grado` | 2 | V213 | — |
| `academico_test.fn_refenunc_validar_padre` | 2 | V213 | — |

## referente

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_referente_actividades_instrumentadas` | 1 | V214.2 | — |
| `academico_test.fn_referente_es_evaluativo_vigente` | 1 | V214.2 | V492.1 |

## reorder

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_reorder_menus` | 3 | V498 | V126 |

## resolver

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_resolver_actor` | 1 | V66 | V214.3, V492.1, V496.1, V496.5 |
| `academico_test.fn_resolver_establecimiento_unico` | 1 | V112 | V51 |
| `pigse.fn_resolver_actor` | 1 | V362 | V214.3, V492.1, V496.1, V496.5 |

## resultado

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_resultado_correccion_requiere_aprobacion` | 2 | V496.18 | V496.6 |

## rol

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_rol_alcance_sede` | 1 | V489 | — |
| `academico_test.fn_rol_categoria_nivel` | 1 | V29 | V297, V298, V300, V302, V489 |
| `academico_test.fn_rol_menus_asignar_interno` | 4 | V498 | — |
| `academico_test.fn_rol_menus_listar` | 2 | V498 | — |
| `academico_test.fn_rol_menus_listar_interno` | 1 | V498 | — |
| `academico_test.fn_rol_menus_validar_jerarquia` | 1 | V498 | — |
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
| `academico_test.fn_sed_actualizar` | 11 | V414 | V95 |
| `academico_test.fn_sed_buscar_por_pk` | 2 | V52 | V95 |
| `academico_test.fn_sed_contar` | 3 | V116 | — |
| `academico_test.fn_sed_crear` | 11 | V414 | V95, V111 |
| `academico_test.fn_sed_listar` | 7 | V116 | V67, V69, V95 |
| `academico_test.fn_sed_listar_paginado` | 7 | V116 | V95 |
| `academico_test.fn_sed_listar_todos` | 1 | V52 | V95 |
| `academico_test.fn_sed_listar_todos_planeador` | 1 | V396 | — |
| `academico_test.fn_sed_por_establecimiento` | 2 | V52 | V95 |
| `academico_test.fn_sed_soft_delete` | 2 | V354 | V95 |
| `academico_test.fn_sed_soft_delete_bulk` | 2 | V354 | V95 |
| `pigse.fn_sed_actualizar` | 11 | V370 | V95 |
| `pigse.fn_sed_buscar_por_pk` | 2 | V370 | V95 |
| `pigse.fn_sed_crear` | 11 | V370 | V394 |
| `pigse.fn_sed_listar` | 8 | V386 | V370 |
| `pigse.fn_sed_soft_delete` | 2 | V370 | V95 |
| `pigse.fn_sed_soft_delete_bulk` | 2 | V370 | V95 |

## sede

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_sede_tiene_periodos` | 1 | V162 | V127 |
| `academico_test.fn_sede_usuario_actualizar` | 6 | V51 | — |
| `academico_test.fn_sede_usuario_crear` | 8 | V111 | V297 |
| `academico_test.fn_sede_usuario_soft_delete` | 2 | V111 | V297, V399 |
| `pigse.fn_sede_usuario_crear` | 8 | V370 | V390 |
| `pigse.fn_sede_usuario_soft_delete` | 2 | V370 | V390 |

## select

| Endpoint | Verbo | Migraciones que la tocan | Funciones que invocan (aprox.) |
|---|---|---|---|
| `/select` | GET | V366 | `fn_usuario_tiene_rol` (V257), `fn_get_pigse_usuario_id` (V261) |
| `/select/:CATEGORIA` | GET | V366 | `fn_usuario_tiene_rol` (V257), `fn_get_pigse_usuario_id` (V261) |

## sesion

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `pigse.fn_sesion_usuario` | 2 | V500 | — |

## sincronizar

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_sincronizar_rol_publico` | 1 | V302 | V150, V300, V301, V399, V414 |

## solicitud

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_solicitud_aprobacion_aprobar` | 3 | V496.20 | V496.21 |
| `academico_test.fn_solicitud_aprobacion_aprobar_interno` | 3 | V496.19 | V496.20 |
| `academico_test.fn_solicitud_aprobacion_assert_aprobador` | 2 | V496.20 | — |
| `academico_test.fn_solicitud_aprobacion_assert_coordinador` | 2 | V496.20 | — |
| `academico_test.fn_solicitud_aprobacion_creadas` | 0 | V496.19 | V496.8, V496.21 |
| `academico_test.fn_solicitud_aprobacion_crear_interno` | 11 | V496.19 | — |
| `academico_test.fn_solicitud_aprobacion_estado` | 1 | V496.18 | — |
| `academico_test.fn_solicitud_aprobacion_listar` | 4 | V496.20 | V496.21 |
| `academico_test.fn_solicitud_aprobacion_listar_interno` | 3 | V496.19 | V496.20 |
| `academico_test.fn_solicitud_aprobacion_puede_aprobar` | 2 | V496.20 | — |
| `academico_test.fn_solicitud_aprobacion_rechazar` | 3 | V496.20 | V496.21 |
| `academico_test.fn_solicitud_aprobacion_rechazar_interno` | 3 | V496.19 | V496.20 |
| `academico_test.fn_solicitud_aprobacion_tipo` | 1 | V496.18 | V496.19, V496.20 |
| `academico_test.fn_solicitud_aprobacion_validar_existe` | 1 | V496.18 | V496.20 |
| `academico_test.fn_solicitud_aprobacion_validar_motivo` | 2 | V496.18 | V496.20 |
| `academico_test.fn_solicitud_aprobacion_validar_pendiente` | 1 | V496.18 | V496.20 |
| `academico_test.fn_solicitud_valor_vigente_recuperacion` | 2 | V496.18 | V496.19 |

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
| `academico_test.fn_assert_superadmin` | 1 | V113 | V115, V119, V498 |

## tactividad

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_tactividad_estudiante_finalizacion` | 0 | V224 | — |
| `academico_test.fn_tactividad_nota_estado_default` | 0 | V496.5 | — |
| `academico_test.fn_tactividad_nota_finalizacion` | 0 | V224 | — |
| `academico_test.fn_tactividad_ponderacion_unidad_check` | 0 | V223 | — |

## tg

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_tg_horario_preescolar_autogenerar` | 0 | V437 | — |
| `academico_test.tg_actividad_recuperacion_herencia` | 0 | V496.1 | — |
| `academico_test.tg_actividad_unidad_referente_vigente` | 0 | V496.1 | — |
| `academico_test.tg_planeador_minimo_enunciado_evidencia` | 0 | V496.2 | — |
| `academico_test.tg_tactividad_depurar_por_unidad` | 0 | V496.2 | — |

## tinforme

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_tinforme_guardado_limpiar_desactualizado` | 0 | V496.19 | — |

## tlv

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_tlv_estado_resultado_pk` | 1 | V496.5 | V496.6 |
| `academico_test.fn_tlv_momento_registro_pk` | 1 | V496.5 | V496.6 |
| `academico_test.fn_tlv_solicitud_estado_pk` | 1 | V496.18 | V496.19 |
| `academico_test.fn_tlv_solicitud_tipo_pk` | 1 | V496.18 | V496.19 |

## tr

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_tr_refcurr_reparar_unidades` | 0 | V455 | — |

## trg

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_trg_tsede_usuario_sync_rol_publico` | 0 | V301 | — |

## trol

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_add_trol` | 4 | V113 | V119 |
| `academico_test.fn_sync_trol_to_public_role` | 0 | V113 | — |
| `academico_test.fn_trol_validar_activo` | 1 | V498 | — |

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
| `academico_test.fn_unidad_actividad_desvincular` | 2 | V492.3 | V492.4 |
| `academico_test.fn_unidad_actividad_desvincular_interno` | 2 | V492.2 | V492.3, V496.2 |
| `academico_test.fn_unidad_actividad_ponderacion_set` | 3 | V492.3 | V492.4 |
| `academico_test.fn_unidad_actividad_ponderacion_set_interno` | 3 | V492.2 | V492.3, V496.2 |
| `academico_test.fn_unidad_actividad_vincular` | 5 | V492.3 | V492.4 |
| `academico_test.fn_unidad_actividad_vincular_interno` | 5 | V492.2 | V492.3, V496.2 |
| `academico_test.fn_unidad_actividades_instrumentadas` | 1 | V214.2 | V455, V492.1 |
| `academico_test.fn_unidad_actividades_listar` | 9 | V480 | V492.4 |
| `academico_test.fn_unidad_actividades_listar_interno` | 9 | V492.2 | V480 |
| `academico_test.fn_unidad_actividades_resumen_interno` | 1 | V492.2 | V492.3 |
| `academico_test.fn_unidad_actualizar` | 16 | V492.3 | V492.4 |
| `academico_test.fn_unidad_actualizar_interno` | 16 | V492.2 | V492.3 |
| `academico_test.fn_unidad_assert_autor` | 2 | V492.1 | V492.3 |
| `academico_test.fn_unidad_assert_criterio_propietario` | 2 | V492.1 | V492.3 |
| `academico_test.fn_unidad_assert_minimo_enunciado` | 1 | V483 | V496.2 |
| `academico_test.fn_unidad_assert_propietario` | 2 | V492.1 | V492.3 |
| `academico_test.fn_unidad_aviso_peso_liberado` | 4 | V492.2 | V492.3, V496.3 |
| `academico_test.fn_unidad_buscar_por_pk` | 2 | V488 | V492.4 |
| `academico_test.fn_unidad_buscar_por_pk_interno` | 1 | V488 | — |
| `academico_test.fn_unidad_calculo_definitiva_modo` | 1 | V223 | V239, V333, V479, V492.1, V492.2, V492.3… |
| `academico_test.fn_unidad_campos_disponibles` | 2 | V214.2 | V488 |
| `academico_test.fn_unidad_configuracion_actividad` | 6 | V496 | V492.4 |
| `academico_test.fn_unidad_contenidos_listar` | 2 | V492.3 | V492.4 |
| `academico_test.fn_unidad_contenidos_listar_interno` | 1 | V492.2 | V492.3 |
| `academico_test.fn_unidad_contenidos_reemplazar_interno` | 4 | V492.2 | — |
| `academico_test.fn_unidad_crear` | 13 | V492.3 | V340, V492.4 |
| `academico_test.fn_unidad_crear_interno` | 13 | V492.2 | V492.3 |
| `academico_test.fn_unidad_criterio_actualizar` | 8 | V492.3 | V492.4 |
| `academico_test.fn_unidad_criterio_actualizar_interno` | 8 | V492.2 | V492.3 |
| `academico_test.fn_unidad_criterio_agregar` | 7 | V492.3 | V492.4 |
| `academico_test.fn_unidad_criterio_agregar_interno` | 7 | V492.2 | V492.3 |
| `academico_test.fn_unidad_criterio_eliminar` | 2 | V492.3 | V492.4 |
| `academico_test.fn_unidad_criterio_eliminar_interno` | 2 | V492.2 | V492.3 |
| `academico_test.fn_unidad_criterio_listar` | 3 | V492.3 | V492.4 |
| `academico_test.fn_unidad_criterio_listar_interno` | 2 | V492.2 | V492.3 |
| `academico_test.fn_unidad_eliminar` | 2 | V492.3 | V492.4 |
| `academico_test.fn_unidad_eliminar_interno` | 2 | V492.2 | V492.3 |
| `academico_test.fn_unidad_enunciado_etiqueta` | 1 | V492.1 | V492.2, V492.3, V496.1, V496.3 |
| `academico_test.fn_unidad_enunciado_quitar` | 2 | V492.3 | V492.4 |
| `academico_test.fn_unidad_enunciado_quitar_interno` | 2 | V492.2 | V492.3 |
| `academico_test.fn_unidad_enunciado_relacionar` | 3 | V492.3 | V492.4 |
| `academico_test.fn_unidad_enunciado_relacionar_interno` | 3 | V492.2 | V492.3 |
| `academico_test.fn_unidad_enunciados_depurar_interno` | 2 | V492.2 | — |
| `academico_test.fn_unidad_enunciados_desactivar_interno` | 3 | V492.2 | — |
| `academico_test.fn_unidad_enunciados_reemplazar_interno` | 3 | V492.2 | — |
| `academico_test.fn_unidad_escala_aplicable` | 1 | V455 | V492.1 |
| `academico_test.fn_unidad_estado` | 3 | V224 | V488 |
| `academico_test.fn_unidad_etiqueta` | 1 | V492.1 | V492.2, V496.1 |
| `academico_test.fn_unidad_instrumento_derivado` | 1 | V488 | — |
| `academico_test.fn_unidad_listar` | 12 | V488 | V492.4 |
| `academico_test.fn_unidad_listar_interno` | 15 | V488 | — |
| `academico_test.fn_unidad_objetivos_listar` | 2 | V492.3 | V492.4 |
| `academico_test.fn_unidad_objetivos_listar_interno` | 1 | V492.2 | V492.3 |
| `academico_test.fn_unidad_objetivos_reemplazar_interno` | 3 | V492.2 | — |
| `academico_test.fn_unidad_ponderacion_asignada` | 3 | V223 | V492.1, V492.2, V492.4 |
| `academico_test.fn_unidad_ponderacion_desde_sumatoria_interno` | 2 | V492.2 | — |
| `academico_test.fn_unidad_ponderacion_disponible` | 3 | V492.3 | V223, V492.4 |
| `academico_test.fn_unidad_ponderacion_disponible_interno` | 2 | V492.2 | V492.3 |
| `academico_test.fn_unidad_ponderacion_intra_asignatura_asignada` | 3 | V239 | V248, V492.1 |
| `academico_test.fn_unidad_ponderacion_recalcular_sumatoria` | 2 | V223 | V482, V492.2, V496.2 |
| `academico_test.fn_unidad_referente_aplicable` | 3 | V451 | V243, V280, V407, V452, V455, V475… |
| `academico_test.fn_unidad_referente_detalle` | 2 | V492.3 | V492.4 |
| `academico_test.fn_unidad_referente_detalle_interno` | 1 | V492.2 | V492.3 |
| `academico_test.fn_unidad_referente_efectivo_interno` | 5 | V492.2 | — |
| `academico_test.fn_unidad_referente_evaluativo` | 1 | V214.2 | V243, V475, V492.1, V496 |
| `academico_test.fn_unidad_referente_reparar` | 1 | V455 | — |
| `academico_test.fn_unidad_referente_tipo_evaluacion` | 1 | V214.2 | V479, V496 |
| `academico_test.fn_unidad_rotulo` | 1 | V492.1 | — |
| `academico_test.fn_unidad_rubrica_asegurar_interno` | 2 | V492.2 | — |
| `academico_test.fn_unidad_sede` | 2 | V492.3 | — |
| `academico_test.fn_unidad_sumatoria_desde_ponderacion_interno` | 2 | V492.2 | — |
| `academico_test.fn_unidad_sumatoria_puntaje_maximo` | 2 | V492.2 | — |
| `academico_test.fn_unidad_validar_activa` | 1 | V492.1 | V492.2, V492.3 |
| `academico_test.fn_unidad_validar_actividad_activa` | 1 | V492.1 | V492.2, V492.3 |
| `academico_test.fn_unidad_validar_actividad_compatible` | 2 | V492.1 | V492.2 |
| `academico_test.fn_unidad_validar_actividad_existente` | 1 | V492.1 | V492.2, V492.3 |
| `academico_test.fn_unidad_validar_actividad_mover` | 3 | V492.1 | V492.2 |
| `academico_test.fn_unidad_validar_actividad_vinculada` | 1 | V492.1 | V492.2 |
| `academico_test.fn_unidad_validar_admite_rubrica` | 1 | V492.1 | V492.2 |
| `academico_test.fn_unidad_validar_asignatura` | 1 | V492.1 | — |
| `academico_test.fn_unidad_validar_bandera_sn` | 2 | V492.1 | V492.2 |
| `academico_test.fn_unidad_validar_calculo_definitiva` | 1 | V492.1 | — |
| `academico_test.fn_unidad_validar_calculo_requerido` | 2 | V492.1 | V492.2 |
| `academico_test.fn_unidad_validar_campos` | 10 | V492.1 | V492.2 |
| `academico_test.fn_unidad_validar_cesion` | 4 | V492.1 | V492.2 |
| `academico_test.fn_unidad_validar_coherencia` | 7 | V492.1 | V492.2 |
| `academico_test.fn_unidad_validar_contenidos_titulos` | 2 | V492.1 | V492.2 |
| `academico_test.fn_unidad_validar_criterio_activo` | 1 | V492.1 | V492.2, V492.3 |
| `academico_test.fn_unidad_validar_criterio_existente` | 1 | V492.1 | V492.2, V492.3 |
| `academico_test.fn_unidad_validar_criterio_niveles_edicion` | 2 | V492.1 | V492.2 |
| `academico_test.fn_unidad_validar_criterio_niveles_nuevos` | 2 | V492.1 | V492.2 |
| `academico_test.fn_unidad_validar_criterio_texto` | 2 | V492.1 | V492.2 |
| `academico_test.fn_unidad_validar_descripcion` | 1 | V492.1 | — |
| `academico_test.fn_unidad_validar_docente` | 1 | V492.1 | — |
| `academico_test.fn_unidad_validar_eliminable` | 1 | V492.1 | V492.2 |
| `academico_test.fn_unidad_validar_enfoque_actividades` | 2 | V492.1 | — |
| `academico_test.fn_unidad_validar_enunciado` | 2 | V492.1 | V492.2 |
| `academico_test.fn_unidad_validar_enunciado_area` | 2 | V492.1 | — |
| `academico_test.fn_unidad_validar_enunciado_existente` | 1 | V492.1 | — |
| `academico_test.fn_unidad_validar_enunciado_grado` | 2 | V492.1 | V496.1 |
| `academico_test.fn_unidad_validar_enunciado_nivel1` | 1 | V492.1 | — |
| `academico_test.fn_unidad_validar_enunciado_referente` | 2 | V492.1 | V496.1 |
| `academico_test.fn_unidad_validar_existente` | 1 | V492.1 | V480, V492.2, V492.3 |
| `academico_test.fn_unidad_validar_grado` | 1 | V492.1 | — |
| `academico_test.fn_unidad_validar_nombre` | 2 | V492.1 | — |
| `academico_test.fn_unidad_validar_nombre_unico` | 4 | V492.1 | — |
| `academico_test.fn_unidad_validar_ponderacion_actividad` | 4 | V492.1 | V492.2 |
| `academico_test.fn_unidad_validar_ponderacion_actividad_manual` | 1 | V492.1 | V492.2, V496.1 |
| `academico_test.fn_unidad_validar_ponderacion_aplica` | 2 | V492.1 | — |
| `academico_test.fn_unidad_validar_ponderacion_rango` | 1 | V492.1 | — |
| `academico_test.fn_unidad_validar_ponderacion_total` | 4 | V492.1 | — |
| `academico_test.fn_unidad_validar_referente_aplica_grado` | 2 | V492.1 | — |
| `academico_test.fn_unidad_validar_referente_cubre_grado` | 2 | V492.1 | — |
| `academico_test.fn_unidad_validar_referente_vigente` | 1 | V492.1 | — |
| `academico_test.fn_unidad_validar_textos` | 3 | V492.1 | — |
| `academico_test.fn_unidad_valoraciones_listar` | 2 | V455 | V227, V492.4 |

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
| `academico_test.fn_usu_empleado_buscar_por_pk` | 2 | V444 | V93 |
| `academico_test.fn_usu_empleados_contar` | 6 | V116 | — |
| `academico_test.fn_usu_empleados_listar` | 10 | V116 | V67, V69, V93 |
| `academico_test.fn_usu_empleados_listar_paginado` | 10 | V116 | V93 |
| `academico_test.fn_usu_tiene_otros_vinculos` | 1 | V51 | V300 |

## usuario

| Endpoint | Verbo | Migraciones que la tocan | Funciones que invocan (aprox.) |
|---|---|---|---|
| `/usuarios/:PK_TUSUARIO/permisos-menu` | GET | V185 | — |
| `/usuarios/actividad/query` | POST | V495 | — |
| `/usuarios/autocompletar-por-documento` | GET | V366 | `fn_usuario_tiene_rol` (V257), `fn_get_pigse_usuario_id` (V261) |

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `academico_test.fn_usuario_administrado_crear` | 10 | V30 | V219 |
| `academico_test.fn_usuario_categoria_rol_nivel` | 1 | V302 | V40, V51, V52, V53, V116, V136… |
| `academico_test.fn_usuario_ee_accesibles` | 1 | V29 | V40, V51, V116, V140, V179, V233… |
| `academico_test.fn_usuario_ee_lectura` | 1 | V29 | V40, V52, V53, V116 |
| `academico_test.fn_usuario_es_coordinador_sede` | 2 | V496.20 | — |
| `academico_test.fn_usuario_es_docente_puro` | 1 | V29 | V224, V407, V480, V481, V492.1, V496.1… |
| `academico_test.fn_usuario_grupos_dirigidos` | 1 | V489 | V136, V140, V490, V491 |
| `academico_test.fn_usuario_otros_usos` | 3 | V162 | V160, V161 |
| `academico_test.fn_usuario_permisos_menu` | 1 | V303 | V29, V127 |
| `academico_test.fn_usuario_peso_categoria` | 1 | V298 | — |
| `academico_test.fn_usuario_puede_en_menu` | 3 | V29 | V40, V51, V52, V53, V116, V140… |
| `academico_test.fn_usuario_sedes_coordinador` | 1 | V496.18 | V496.20, V496.22 |
| `academico_test.fn_usuario_sedes_jornadas_accesibles` | 1 | V29 | V40, V51, V116, V140, V297, V300… |
| `academico_test.fn_usuario_sedes_lectura` | 1 | V29 | V52, V116, V224, V244, V251, V396… |
| `academico_test.fn_usuario_solo_sus_grupos` | 1 | V489 | V136, V140, V490, V491, V496.26 |
| `pigse.fn_usuario_categoria_rol_nivel` | 1 | V370 | V390 |
| `pigse.fn_usuario_ee_accesibles` | 1 | V370 | V390 |
| `pigse.fn_usuario_ente_crear` | 11 | V263 | — |
| `pigse.fn_usuario_provisionar` | 1 | V263 | — |
| `pigse.fn_usuario_puede_en_menu` | 3 | V370 | V373 |
| `pigse.fn_usuario_sedes_jornadas_accesibles` | 1 | V370 | V390 |
| `pigse.fn_usuario_tiene_rol` | 2 | V257 | V263, V360, V362, V366, V369, V387… |
| `pigse.fn_usuarios_actividad_listar` | 8 | V495 | — |
| `pigse.fn_usuarios_actividad_listar_interno` | 7 | V500 | — |

## validar

| Funcion | Params | Migracion dueña | La usan |
|---|---|---|---|
| `public.fn_validar_tabla_archivo` | 2 | V147 | — |

