-- =============================================================================
-- V65 — todas las UNIQUE constraints de academico_test pasan a indice unico
-- parcial (WHERE active = true).
--
-- Motivacion: el esquema entero sigue el patron de soft-delete (columna
-- ACTIVE en cada tabla). Con una UNIQUE constraint plana, un registro
-- "eliminado" (ACTIVE = false) sigue bloqueando el valor para uno nuevo:
-- no se puede reactivar un codigo/nombre porque el registro inactivo lo
-- sigue reservando en el indice. Todas las funciones fn_*_crear del
-- esquema ya validan duplicados con un `WHERE ... AND ACTIVE = TRUE`
-- explicito antes de insertar (ver p.ej. fn_area_crear, fn_grado_crear,
-- fn_periodo_crear) — la intencion de negocio siempre fue "unico entre
-- los activos", el indice simplemente no lo reflejaba.
--
-- 84 constraints en 50 tablas. Se generaron automaticamente introspectando
-- pg_constraint (tabla, nombre, columnas) para evitar errores de
-- transcripcion — cada UNIQUE (cols) se reemplaza por CREATE UNIQUE INDEX
-- (mismo nombre, mismas columnas) WHERE active = true.
--
-- Decision explicita: los 26 constraints DEFERRABLE INITIALLY DEFERRED del
-- esquema (tactividad, tasignatura, tgrupo, tunidad, etc.) tambien se
-- convierten aqui, con perdida intencional de la semantica deferrable —
-- Postgres no permite que un indice parcial respalde un constraint
-- deferrable (ALTER TABLE ... ADD CONSTRAINT ... UNIQUE USING INDEX exige
-- un indice no parcial). Si algun flujo dependia de swaps de valores unicos
-- dentro de una misma transaccion, revisar despues de aplicar esta migracion.
--
-- IF EXISTS / IF NOT EXISTS en cada paso: si esta migracion se re-ejecuta
-- sobre una base que ya tiene el indice parcial (p.ej. porque se aplico a
-- mano contra un servidor antes de existir esta migracion — ver
-- docs/analisis-mensajes-error-plpgsql.md y la memoria del proyecto sobre
-- drift de V59), no falla.
-- =============================================================================

ALTER TABLE academico_test.tacta_grado DROP CONSTRAINT IF EXISTS u_tacta_grado_1;
CREATE UNIQUE INDEX IF NOT EXISTS u_tacta_grado_1 ON academico_test.tacta_grado (numero_acta, fk_tperiodo_academico) WHERE active = true;
ALTER TABLE academico_test.tactividad DROP CONSTRAINT IF EXISTS u_tactividad_1;
CREATE UNIQUE INDEX IF NOT EXISTS u_tactividad_1 ON academico_test.tactividad (titulo, fk_tunidad, fk_tgrupo, fk_tlv_jerarquia) WHERE active = true;
ALTER TABLE academico_test.tactividad_cotejo_evaluacion DROP CONSTRAINT IF EXISTS un_tac_cotejo_eval_1;
CREATE UNIQUE INDEX IF NOT EXISTS un_tac_cotejo_eval_1 ON academico_test.tactividad_cotejo_evaluacion (fk_tactividad_cotejo_item, fk_tactividad_estudiante) WHERE active = true;
ALTER TABLE academico_test.tactividad_escala DROP CONSTRAINT IF EXISTS un_tac_escala_1;
CREATE UNIQUE INDEX IF NOT EXISTS un_tac_escala_1 ON academico_test.tactividad_escala (fk_tactividad) WHERE active = true;
ALTER TABLE academico_test.tactividad_escala_evaluacion DROP CONSTRAINT IF EXISTS un_tac_escala_eval_1;
CREATE UNIQUE INDEX IF NOT EXISTS un_tac_escala_eval_1 ON academico_test.tactividad_escala_evaluacion (fk_tactividad_escala, fk_tactividad_estudiante) WHERE active = true;
ALTER TABLE academico_test.tactividad_escala_nivel DROP CONSTRAINT IF EXISTS un_tac_escala_nivel_1;
CREATE UNIQUE INDEX IF NOT EXISTS un_tac_escala_nivel_1 ON academico_test.tactividad_escala_nivel (fk_tactividad_escala, ponderacion) WHERE active = true;
ALTER TABLE academico_test.tactividad_estudiante DROP CONSTRAINT IF EXISTS un_tactividad_estudiante_1;
CREATE UNIQUE INDEX IF NOT EXISTS un_tactividad_estudiante_1 ON academico_test.tactividad_estudiante (fk_tactividad, fk_tmatricula) WHERE active = true;
ALTER TABLE academico_test.tactividad_nota DROP CONSTRAINT IF EXISTS uk_tactividad_nota_1;
CREATE UNIQUE INDEX IF NOT EXISTS uk_tactividad_nota_1 ON academico_test.tactividad_nota (fk_tactividad_estudiante) WHERE active = true;
ALTER TABLE academico_test.tactividad_recuperacion DROP CONSTRAINT IF EXISTS un_tac_recuperacion_1;
CREATE UNIQUE INDEX IF NOT EXISTS un_tac_recuperacion_1 ON academico_test.tactividad_recuperacion (fk_tactividad) WHERE active = true;
ALTER TABLE academico_test.tactividad_rubrica_evaluacion DROP CONSTRAINT IF EXISTS un_tac_rubrica_eval_1;
CREATE UNIQUE INDEX IF NOT EXISTS un_tac_rubrica_eval_1 ON academico_test.tactividad_rubrica_evaluacion (fk_tactividad_rubrica_criterio, fk_tactividad_estudiante) WHERE active = true;
ALTER TABLE academico_test.tactividad_rubrica_nivel DROP CONSTRAINT IF EXISTS un_tac_rubrica_nivel_1;
CREATE UNIQUE INDEX IF NOT EXISTS un_tac_rubrica_nivel_1 ON academico_test.tactividad_rubrica_nivel (fk_tactividad_rubrica_criterio, ponderacion) WHERE active = true;
ALTER TABLE academico_test.tano_lectivo DROP CONSTRAINT IF EXISTS u_tano_lectivo_1;
CREATE UNIQUE INDEX IF NOT EXISTS u_tano_lectivo_1 ON academico_test.tano_lectivo (fk_testablecimiento, nombre) WHERE active = true;
ALTER TABLE academico_test.taplico_encuesta DROP CONSTRAINT IF EXISTS un_taplico_encuesta_1;
CREATE UNIQUE INDEX IF NOT EXISTS un_taplico_encuesta_1 ON academico_test.taplico_encuesta (fk_tusuario, fk_tencuesta) WHERE active = true;
ALTER TABLE academico_test.tarea DROP CONSTRAINT IF EXISTS u_tarea_1;
CREATE UNIQUE INDEX IF NOT EXISTS u_tarea_1 ON academico_test.tarea (fk_tperiodo_academico, codigo) WHERE active = true;
ALTER TABLE academico_test.tarea DROP CONSTRAINT IF EXISTS u_tarea_2;
CREATE UNIQUE INDEX IF NOT EXISTS u_tarea_2 ON academico_test.tarea (fk_tperiodo_academico, nombre) WHERE active = true;
ALTER TABLE academico_test.tarea_definitiva DROP CONSTRAINT IF EXISTS u_tarea_definitiva_1;
CREATE UNIQUE INDEX IF NOT EXISTS u_tarea_definitiva_1 ON academico_test.tarea_definitiva (fk_tmatricula, fk_tarea) WHERE active = true;
ALTER TABLE academico_test.tarea_gestion DROP CONSTRAINT IF EXISTS un_tarea_gestion_1;
CREATE UNIQUE INDEX IF NOT EXISTS un_tarea_gestion_1 ON academico_test.tarea_gestion (nombre) WHERE active = true;
ALTER TABLE academico_test.tarea_nota DROP CONSTRAINT IF EXISTS uk_tarea_nota_1;
CREATE UNIQUE INDEX IF NOT EXISTS uk_tarea_nota_1 ON academico_test.tarea_nota (fk_tarea, fk_tperiodo_evaluacion, fk_tmatricula) WHERE active = true;
ALTER TABLE academico_test.tasignatura DROP CONSTRAINT IF EXISTS u_tasignatura_1;
CREATE UNIQUE INDEX IF NOT EXISTS u_tasignatura_1 ON academico_test.tasignatura (nombre, fk_tenfasis, fk_tarea) WHERE active = true;
ALTER TABLE academico_test.tasignatura_definitiva DROP CONSTRAINT IF EXISTS uk_tasignatura_definitiva_1;
CREATE UNIQUE INDEX IF NOT EXISTS uk_tasignatura_definitiva_1 ON academico_test.tasignatura_definitiva (fk_tmatricula, fk_tasignatura) WHERE active = true;
ALTER TABLE academico_test.tasignatura_nota DROP CONSTRAINT IF EXISTS u_tasignatura_nota_1;
CREATE UNIQUE INDEX IF NOT EXISTS u_tasignatura_nota_1 ON academico_test.tasignatura_nota (fk_tmatricula, fk_tperiodo_evaluacion, fk_tasignatura) WHERE active = true;
ALTER TABLE academico_test.tasignatura_plan DROP CONSTRAINT IF EXISTS un_tasignatura_plan_1;
CREATE UNIQUE INDEX IF NOT EXISTS un_tasignatura_plan_1 ON academico_test.tasignatura_plan (fk_tasignatura, fk_tplan) WHERE active = true;
ALTER TABLE academico_test.tcalendario_detalle DROP CONSTRAINT IF EXISTS uk_tcalendario_detalle_1;
CREATE UNIQUE INDEX IF NOT EXISTS uk_tcalendario_detalle_1 ON academico_test.tcalendario_detalle (fecha, nombre, fk_tcalendario) WHERE active = true;
ALTER TABLE academico_test.tcomportamiento DROP CONSTRAINT IF EXISTS u_tcomportamiento_1;
CREATE UNIQUE INDEX IF NOT EXISTS u_tcomportamiento_1 ON academico_test.tcomportamiento (fk_testablecimiento, codigo) WHERE active = true;
ALTER TABLE academico_test.tcriterio_evaluacion_asignatura_plan DROP CONSTRAINT IF EXISTS un_tce_asig_plan_1;
CREATE UNIQUE INDEX IF NOT EXISTS un_tce_asig_plan_1 ON academico_test.tcriterio_evaluacion_asignatura_plan (fk_tcriterio_evaluacion, fk_tasignatura_plan) WHERE active = true;
ALTER TABLE academico_test.tcriterio_promocion DROP CONSTRAINT IF EXISTS tcriterio_promocion_uk1;
CREATE UNIQUE INDEX IF NOT EXISTS tcriterio_promocion_uk1 ON academico_test.tcriterio_promocion (fk_tgrado) WHERE active = true;
ALTER TABLE academico_test.tcriterio_unidad DROP CONSTRAINT IF EXISTS un_tcriterio_unidad_1;
CREATE UNIQUE INDEX IF NOT EXISTS un_tcriterio_unidad_1 ON academico_test.tcriterio_unidad (fk_trubrica_unidad, orden) WHERE active = true;
ALTER TABLE academico_test.tdenominacion DROP CONSTRAINT IF EXISTS u_tdenominacion_1;
CREATE UNIQUE INDEX IF NOT EXISTS u_tdenominacion_1 ON academico_test.tdenominacion (codigo, nombre) WHERE active = true;
ALTER TABLE academico_test.tdepartamento DROP CONSTRAINT IF EXISTS u_tdepartamento_1;
CREATE UNIQUE INDEX IF NOT EXISTS u_tdepartamento_1 ON academico_test.tdepartamento (codigo, fk_tlv_tpais) WHERE active = true;
ALTER TABLE academico_test.tdepartamento DROP CONSTRAINT IF EXISTS u_tdepartamento_2;
CREATE UNIQUE INDEX IF NOT EXISTS u_tdepartamento_2 ON academico_test.tdepartamento (nombre, fk_tlv_tpais) WHERE active = true;
ALTER TABLE academico_test.tdiploma DROP CONSTRAINT IF EXISTS uk_tdiploma_1;
CREATE UNIQUE INDEX IF NOT EXISTS uk_tdiploma_1 ON academico_test.tdiploma (libro, folio) WHERE active = true;
ALTER TABLE academico_test.tdiscapacidad DROP CONSTRAINT IF EXISTS u_tdiscapacidad_1;
CREATE UNIQUE INDEX IF NOT EXISTS u_tdiscapacidad_1 ON academico_test.tdiscapacidad (codigo) WHERE active = true;
ALTER TABLE academico_test.tdiscapacidad DROP CONSTRAINT IF EXISTS u_tdiscapacidad_2;
CREATE UNIQUE INDEX IF NOT EXISTS u_tdiscapacidad_2 ON academico_test.tdiscapacidad (nombre) WHERE active = true;
ALTER TABLE academico_test.tencuesta DROP CONSTRAINT IF EXISTS u_tencuesta_1;
CREATE UNIQUE INDEX IF NOT EXISTS u_tencuesta_1 ON academico_test.tencuesta (fk_establecimiento, titulo) WHERE active = true;
ALTER TABLE academico_test.tenfasis DROP CONSTRAINT IF EXISTS u_tenfasis_1;
CREATE UNIQUE INDEX IF NOT EXISTS u_tenfasis_1 ON academico_test.tenfasis (fk_testablecimiento, codigo) WHERE active = true;
ALTER TABLE academico_test.tenfasis DROP CONSTRAINT IF EXISTS u_tenfasis_2;
CREATE UNIQUE INDEX IF NOT EXISTS u_tenfasis_2 ON academico_test.tenfasis (fk_testablecimiento, nombre) WHERE active = true;
ALTER TABLE academico_test.tente DROP CONSTRAINT IF EXISTS u_tente_1;
CREATE UNIQUE INDEX IF NOT EXISTS u_tente_1 ON academico_test.tente (nit) WHERE active = true;
ALTER TABLE academico_test.tente DROP CONSTRAINT IF EXISTS u_tente_2;
CREATE UNIQUE INDEX IF NOT EXISTS u_tente_2 ON academico_test.tente (nombre) WHERE active = true;
ALTER TABLE academico_test.tescala_valoracion DROP CONSTRAINT IF EXISTS u_tescala_valoracion_1;
CREATE UNIQUE INDEX IF NOT EXISTS u_tescala_valoracion_1 ON academico_test.tescala_valoracion (fk_tescala, fk_tvaloracion) WHERE active = true;
ALTER TABLE academico_test.tescala_valoracion DROP CONSTRAINT IF EXISTS u_tescala_valoracion_2;
CREATE UNIQUE INDEX IF NOT EXISTS u_tescala_valoracion_2 ON academico_test.tescala_valoracion (fk_tescala, fk_tvl_tipo_valoracion, orden) WHERE active = true;
ALTER TABLE academico_test.tespecialidad DROP CONSTRAINT IF EXISTS u_tespecialidad_1;
CREATE UNIQUE INDEX IF NOT EXISTS u_tespecialidad_1 ON academico_test.tespecialidad (codigo) WHERE active = true;
ALTER TABLE academico_test.tespecialidad DROP CONSTRAINT IF EXISTS u_tespecialidad_2;
CREATE UNIQUE INDEX IF NOT EXISTS u_tespecialidad_2 ON academico_test.tespecialidad (nombre) WHERE active = true;
ALTER TABLE academico_test.testablecimiento DROP CONSTRAINT IF EXISTS u_testablecimiento_1;
CREATE UNIQUE INDEX IF NOT EXISTS u_testablecimiento_1 ON academico_test.testablecimiento (codigo) WHERE active = true;
ALTER TABLE academico_test.testudiante DROP CONSTRAINT IF EXISTS u_testudiante_2;
CREATE UNIQUE INDEX IF NOT EXISTS u_testudiante_2 ON academico_test.testudiante (fk_tusuario) WHERE active = true;
ALTER TABLE academico_test.tetnia DROP CONSTRAINT IF EXISTS u_tetnia_1;
CREATE UNIQUE INDEX IF NOT EXISTS u_tetnia_1 ON academico_test.tetnia (codigo) WHERE active = true;
ALTER TABLE academico_test.tetnia DROP CONSTRAINT IF EXISTS u_tetnia_2;
CREATE UNIQUE INDEX IF NOT EXISTS u_tetnia_2 ON academico_test.tetnia (nombre) WHERE active = true;
ALTER TABLE academico_test.tfuncionario DROP CONSTRAINT IF EXISTS u_tfuncionario_2;
CREATE UNIQUE INDEX IF NOT EXISTS u_tfuncionario_2 ON academico_test.tfuncionario (fk_tusuario, fk_establecimiento) WHERE active = true;
ALTER TABLE academico_test.tgrado DROP CONSTRAINT IF EXISTS u_tgrado_1;
CREATE UNIQUE INDEX IF NOT EXISTS u_tgrado_1 ON academico_test.tgrado (fk_tperiodo_academico, codigo) WHERE active = true;
ALTER TABLE academico_test.tgrado DROP CONSTRAINT IF EXISTS u_tgrado_2;
CREATE UNIQUE INDEX IF NOT EXISTS u_tgrado_2 ON academico_test.tgrado (fk_tperiodo_academico, nombre) WHERE active = true;
ALTER TABLE academico_test.tgrupo DROP CONSTRAINT IF EXISTS u_tgrupo_1;
CREATE UNIQUE INDEX IF NOT EXISTS u_tgrupo_1 ON academico_test.tgrupo (fk_tgrado, fk_tlv_jornada, nombre) WHERE active = true;
ALTER TABLE academico_test.tlista_valor DROP CONSTRAINT IF EXISTS tlista_valor_categoria_valor_key;
CREATE UNIQUE INDEX IF NOT EXISTS tlista_valor_categoria_valor_key ON academico_test.tlista_valor (categoria, valor) WHERE active = true;
ALTER TABLE academico_test.tmatricula_asignatura DROP CONSTRAINT IF EXISTS u_tmatricula_asignatura_1;
CREATE UNIQUE INDEX IF NOT EXISTS u_tmatricula_asignatura_1 ON academico_test.tmatricula_asignatura (fk_tmatricula, fk_tasignatura) WHERE active = true;
ALTER TABLE academico_test.tmatricula_promocion DROP CONSTRAINT IF EXISTS u_tmatricula_promocion_1;
CREATE UNIQUE INDEX IF NOT EXISTS u_tmatricula_promocion_1 ON academico_test.tmatricula_promocion (fk_tmatricula) WHERE active = true;
ALTER TABLE academico_test.tmatricula_socioeconomico DROP CONSTRAINT IF EXISTS u_tmatricula_socioeconomico_1;
CREATE UNIQUE INDEX IF NOT EXISTS u_tmatricula_socioeconomico_1 ON academico_test.tmatricula_socioeconomico (fk_tmatricula) WHERE active = true;
ALTER TABLE academico_test.tmunicipio DROP CONSTRAINT IF EXISTS u_tmunicipio_1;
CREATE UNIQUE INDEX IF NOT EXISTS u_tmunicipio_1 ON academico_test.tmunicipio (codigo, pk_tdepartamento) WHERE active = true;
ALTER TABLE academico_test.tmunicipio DROP CONSTRAINT IF EXISTS u_tmunicipio_2;
CREATE UNIQUE INDEX IF NOT EXISTS u_tmunicipio_2 ON academico_test.tmunicipio (nombre, pk_tdepartamento) WHERE active = true;
ALTER TABLE academico_test.tnivel_criterio_unidad DROP CONSTRAINT IF EXISTS un_tnivel_criterio_unidad_1;
CREATE UNIQUE INDEX IF NOT EXISTS un_tnivel_criterio_unidad_1 ON academico_test.tnivel_criterio_unidad (fk_tcriterio_unidad, fk_tescala_valoracion) WHERE active = true;
ALTER TABLE academico_test.tnivel_ensenanza DROP CONSTRAINT IF EXISTS u_tnivel_ensenanza_1;
CREATE UNIQUE INDEX IF NOT EXISTS u_tnivel_ensenanza_1 ON academico_test.tnivel_ensenanza (codigo) WHERE active = true;
ALTER TABLE academico_test.tnivel_ensenanza DROP CONSTRAINT IF EXISTS u_tnivel_ensenanza_2;
CREATE UNIQUE INDEX IF NOT EXISTS u_tnivel_ensenanza_2 ON academico_test.tnivel_ensenanza (nombre) WHERE active = true;
ALTER TABLE academico_test.tobs_servicio_vivienda DROP CONSTRAINT IF EXISTS u_tobs_servicio_vivienda_1;
CREATE UNIQUE INDEX IF NOT EXISTS u_tobs_servicio_vivienda_1 ON academico_test.tobs_servicio_vivienda (fk_tobservador, fk_tlv_servicio_vivienda) WHERE active = true;
ALTER TABLE academico_test.tobservador DROP CONSTRAINT IF EXISTS u_tobservador_1;
CREATE UNIQUE INDEX IF NOT EXISTS u_tobservador_1 ON academico_test.tobservador (fk_testudiante, fk_establecimiento) WHERE active = true;
ALTER TABLE academico_test.tpadre DROP CONSTRAINT IF EXISTS u_tpadre_2;
CREATE UNIQUE INDEX IF NOT EXISTS u_tpadre_2 ON academico_test.tpadre (fk_tusuario) WHERE active = true;
ALTER TABLE academico_test.tperiodo_academico DROP CONSTRAINT IF EXISTS u_tperiodo_academico_1;
CREATE UNIQUE INDEX IF NOT EXISTS u_tperiodo_academico_1 ON academico_test.tperiodo_academico (fk_tano_lectivo, fk_tsede, nombre) WHERE active = true;
ALTER TABLE academico_test.tperiodo_evaluacion DROP CONSTRAINT IF EXISTS u_tperiodo_evaluacion_1;
CREATE UNIQUE INDEX IF NOT EXISTS u_tperiodo_evaluacion_1 ON academico_test.tperiodo_evaluacion (fk_tperiodo_academico, nombre) WHERE active = true;
ALTER TABLE academico_test.tplan DROP CONSTRAINT IF EXISTS u_tplan_1;
CREATE UNIQUE INDEX IF NOT EXISTS u_tplan_1 ON academico_test.tplan (fk_tgrado, codigo) WHERE active = true;
ALTER TABLE academico_test.tplan DROP CONSTRAINT IF EXISTS u_tplan_2;
CREATE UNIQUE INDEX IF NOT EXISTS u_tplan_2 ON academico_test.tplan (fk_tgrado, nombre) WHERE active = true;
ALTER TABLE academico_test.tpregunta DROP CONSTRAINT IF EXISTS u_tpregunta_1;
CREATE UNIQUE INDEX IF NOT EXISTS u_tpregunta_1 ON academico_test.tpregunta (fk_tencuesta, pregunta) WHERE active = true;
ALTER TABLE academico_test.tpropiedad_juridica DROP CONSTRAINT IF EXISTS u_tpropiedad_juridica_1;
CREATE UNIQUE INDEX IF NOT EXISTS u_tpropiedad_juridica_1 ON academico_test.tpropiedad_juridica (codigo) WHERE active = true;
ALTER TABLE academico_test.tpropiedad_juridica DROP CONSTRAINT IF EXISTS u_tpropiedad_juridica_2;
CREATE UNIQUE INDEX IF NOT EXISTS u_tpropiedad_juridica_2 ON academico_test.tpropiedad_juridica (nombre) WHERE active = true;
ALTER TABLE academico_test.tresguardo DROP CONSTRAINT IF EXISTS u_tresguardo_1;
CREATE UNIQUE INDEX IF NOT EXISTS u_tresguardo_1 ON academico_test.tresguardo (codigo) WHERE active = true;
ALTER TABLE academico_test.tresguardo DROP CONSTRAINT IF EXISTS u_tresguardo_2;
CREATE UNIQUE INDEX IF NOT EXISTS u_tresguardo_2 ON academico_test.tresguardo (nombre) WHERE active = true;
ALTER TABLE academico_test.trespuesta DROP CONSTRAINT IF EXISTS u_trespuesta_1;
CREATE UNIQUE INDEX IF NOT EXISTS u_trespuesta_1 ON academico_test.trespuesta (fk_tpregunta, respuesta) WHERE active = true;
ALTER TABLE academico_test.trol DROP CONSTRAINT IF EXISTS u_trol_1;
CREATE UNIQUE INDEX IF NOT EXISTS u_trol_1 ON academico_test.trol (nombre) WHERE active = true;
ALTER TABLE academico_test.trol_menu DROP CONSTRAINT IF EXISTS u_trol_menu_1;
CREATE UNIQUE INDEX IF NOT EXISTS u_trol_menu_1 ON academico_test.trol_menu (fk_trol, fk_tmenu) WHERE active = true;
ALTER TABLE academico_test.trubrica_unidad DROP CONSTRAINT IF EXISTS un_trubrica_unidad_1;
CREATE UNIQUE INDEX IF NOT EXISTS un_trubrica_unidad_1 ON academico_test.trubrica_unidad (fk_tunidad) WHERE active = true;
ALTER TABLE academico_test.tsede DROP CONSTRAINT IF EXISTS u_tsede_1;
CREATE UNIQUE INDEX IF NOT EXISTS u_tsede_1 ON academico_test.tsede (fk_testablecimiento, nombre) WHERE active = true;
ALTER TABLE academico_test.tsede DROP CONSTRAINT IF EXISTS u_tsede_2;
CREATE UNIQUE INDEX IF NOT EXISTS u_tsede_2 ON academico_test.tsede (fk_testablecimiento, consecutivo) WHERE active = true;
ALTER TABLE academico_test.tsede DROP CONSTRAINT IF EXISTS u_tsede_3;
CREATE UNIQUE INDEX IF NOT EXISTS u_tsede_3 ON academico_test.tsede (codigo) WHERE active = true;
ALTER TABLE academico_test.tsede_usuario DROP CONSTRAINT IF EXISTS uk_tsede_usuario_1;
CREATE UNIQUE INDEX IF NOT EXISTS uk_tsede_usuario_1 ON academico_test.tsede_usuario (fk_tsede, fk_trol, fk_tusuario, fk_tlv_jornada) WHERE active = true;
ALTER TABLE academico_test.tsede_usuario DROP CONSTRAINT IF EXISTS uk_tsede_usuario_2;
CREATE UNIQUE INDEX IF NOT EXISTS uk_tsede_usuario_2 ON academico_test.tsede_usuario (fk_tsede, fk_trol, fk_tusuario, orden) WHERE active = true;
ALTER TABLE academico_test.tunidad DROP CONSTRAINT IF EXISTS un_tunidad_1;
CREATE UNIQUE INDEX IF NOT EXISTS un_tunidad_1 ON academico_test.tunidad (nombre, fk_tasignatura, fk_tgrado, fk_tperiodo_evaluacion) WHERE active = true;
ALTER TABLE academico_test.tunidad_nota DROP CONSTRAINT IF EXISTS un_tunidad_nota_1;
CREATE UNIQUE INDEX IF NOT EXISTS un_tunidad_nota_1 ON academico_test.tunidad_nota (fk_tunidad, fk_tmatricula) WHERE active = true;
ALTER TABLE academico_test.tusuario DROP CONSTRAINT IF EXISTS u_tusuario_1;
CREATE UNIQUE INDEX IF NOT EXISTS u_tusuario_1 ON academico_test.tusuario (cuenta) WHERE active = true;
ALTER TABLE academico_test.tusuario DROP CONSTRAINT IF EXISTS u_tusuario_2;
CREATE UNIQUE INDEX IF NOT EXISTS u_tusuario_2 ON academico_test.tusuario (fk_tlv_tipo_documento, identificacion) WHERE active = true;
