-- ===========================================================================
-- V456 — Asistencias: "mis clases" (QUERY.MIAS=true) deja de vaciar el
-- calendario para quien no dicta ninguna asignatura.
--
-- Que hace: (1) fn_asistencia_mis_clases_funcionario, punto unico que
-- traduce el usuario del token al funcionario por el que se filtra; devuelve
-- NULL (= sin filtro, todo el alcance del rol) cuando el funcionario no tiene
-- TDOCENTE_ASIGNATURA activa. (2) re-apunta a ese helper las 4 filas de
-- public.query con MIAS (V221): antes resolvian el funcionario "a pelo", y un
-- rector -- funcionario sin asignacion docente -- obtenia 200 con 0 filas.
-- Depende de: V220 (p_fk_tfuncionario), V221 (asis-calendario,
-- asis-resumen-horas, asis-sesion-asignaturas, asis-sesion-actividades).
-- ===========================================================================

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_mis_clases_funcionario(
    p_pk_usuario BIGINT
)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT f.PK_TFUNCIONARIO
      FROM academico_test.TFUNCIONARIO f
     WHERE f.FK_TUSUARIO = p_pk_usuario
       AND f.ACTIVE = TRUE
       AND EXISTS (SELECT 1
                     FROM academico_test.TDOCENTE_ASIGNATURA da
                    WHERE da.FK_TFUNCIONARIO = f.PK_TFUNCIONARIO
                      AND da.ACTIVE = TRUE)
     ORDER BY f.PK_TFUNCIONARIO
     LIMIT 1;
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_mis_clases_funcionario(BIGINT)
    IS 'Funcionario por el que se acota la vista "mis clases" de Asistencias (QUERY.MIAS=true): el del usuario SOLO si tiene alguna TDOCENTE_ASIGNATURA activa. NULL para quien no dicta nada (rector, coordinador, super admin, usuario sin funcionario): p_fk_tfuncionario NULL en V220 significa "sin filtro por docente", y el alcance real lo sigue poniendo fn_asistencia_puede_ver. Un QUERY.FUNCIONARIO explicito no pasa por aqui: filtrar por un docente concreto sin asignaciones debe dar vacio.';

-- Solo las filas que aun llevan el subquery inline; idempotente.
UPDATE public.query
   SET query = regexp_replace(
                   query,
                   'THEN COALESCE\(\(SELECT f\.PK_TFUNCIONARIO FROM academico_test\.TFUNCIONARIO f.*?AND f\.ACTIVE = TRUE\), -1\)',
                   'THEN academico_test.fn_asistencia_mis_clases_funcionario(public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT))'
               )
 WHERE uuid IN ('asis-calendario', 'asis-resumen-horas',
                'asis-sesion-asignaturas', 'asis-sesion-actividades')
   AND query LIKE '%QUERY.MIAS%'
   AND query LIKE '%THEN COALESCE((SELECT f.PK_TFUNCIONARIO%';

DO $$
DECLARE
    v_pendientes INT;
BEGIN
    SELECT count(*) INTO v_pendientes
      FROM public.query
     WHERE uuid IN ('asis-calendario', 'asis-resumen-horas',
                    'asis-sesion-asignaturas', 'asis-sesion-actividades')
       AND query LIKE '%QUERY.MIAS%'
       AND query NOT LIKE '%fn_asistencia_mis_clases_funcionario%';
    IF v_pendientes > 0 THEN
        RAISE EXCEPTION 'V456: % fila(s) de public.query con MIAS siguen sin fn_asistencia_mis_clases_funcionario', v_pendientes;
    END IF;
END $$;
