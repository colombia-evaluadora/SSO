-- V459 - Retira la firma vieja de fn_actividad_configuracion_contexto. La
-- sección de recuperación y su configuración viven hoy en V496.1-V496.2, y la
-- fila GET /planeador/actividades/configuracion en V496.4.


SET search_path TO academico_test, public;

DROP FUNCTION IF EXISTS academico_test.fn_actividad_configuracion_contexto(BIGINT, BIGINT, BIGINT, BIGINT, VARCHAR);
