-- V469.1 — Planilla de calificación: DDL (1 de 5).
--
-- Qué hace: índices que sostienen el LATERAL por celda de la planilla (fecha
-- de asistencia por asignatura o por actividad de cada matrícula).
-- Antes en V441. Sigue: V469.2 validaciones, V469.3 núcleos, V469.4
-- funciones de endpoint, V469.5 endpoints.
-- Depende de: V22 (TASISTENCIA).

SET search_path TO academico_test, public;

CREATE INDEX IF NOT EXISTS idx_tasistencia_mat_asig_fecha
    ON academico_test.TASISTENCIA (FK_TMATRICULA, FK_TASIGNATURA, FECHA)
 WHERE ACTIVE = TRUE AND FK_TASIGNATURA IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_tasistencia_mat_act_fecha
    ON academico_test.TASISTENCIA (FK_TMATRICULA, FK_TACTIVIDAD, FECHA)
 WHERE ACTIVE = TRUE AND FK_TACTIVIDAD IS NOT NULL;
