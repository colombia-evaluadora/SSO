-- Bug: fn_subject_soft_delete bloqueaba el borrado de una asignatura si
-- tenía asignaciones docente, horarios o calificaciones asociadas, pero NO
-- si estaba en un plan de estudio (TASIGNATURA_PLAN.FK_TASIGNATURA) — se
-- podía borrar una asignatura que un grado ya tenía en su plan de estudio,
-- dejando el renglón del plan apuntando a una asignatura inactiva.
--
-- Fix: agrega el mismo tipo de bloqueo por dependencia que ya usan las demás
-- (mensaje con el nombre de la asignatura, ERRCODE 23503), consultando solo
-- filas activas de TASIGNATURA_PLAN.
CREATE OR REPLACE FUNCTION academico_test.fn_subject_soft_delete(p_pk bigint, p_pk_usuario_solicitante bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $$
DECLARE
    v_n INT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_nombre VARCHAR(130);
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, (
        SELECT academico_test.fn_periodo_establecimiento(a.FK_TPERIODO_ACADEMICO)
          FROM academico_test.TASIGNATURA s JOIN academico_test.TAREA a ON a.PK_TAREA = s.FK_TAREA
         WHERE s.PK_TASIGNATURA = p_pk));
    SELECT NOMBRE INTO v_nombre FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_pk;
    -- Bloqueo por dependencias (solo filas activas).
    IF EXISTS (
        SELECT 1 FROM academico_test.TDOCENTE_ASIGNATURA da
         WHERE da.FK_TASIGNATURA = p_pk AND da.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar la asignatura %: existen asignaciones docente asociadas', COALESCE(v_nombre, p_pk::text)
            USING ERRCODE = '23503';
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.THORARIO h
         WHERE h.FK_TASIGNATURA = p_pk AND h.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar la asignatura %: existen horarios asociados', COALESCE(v_nombre, p_pk::text)
            USING ERRCODE = '23503';
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.TASIGNATURA_PLAN ap
         WHERE ap.FK_TASIGNATURA = p_pk AND ap.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar la asignatura %: esta asociada a un plan de estudio', COALESCE(v_nombre, p_pk::text)
            USING ERRCODE = '23503';
    END IF;
    -- Procesos academicos activos: ya hay calificaciones registradas para la asignatura.
    IF EXISTS (
        SELECT 1 FROM academico_test.TASIGNATURA_NOTA an
         WHERE an.FK_TASIGNATURA = p_pk AND an.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar la asignatura %: existen calificaciones registradas', COALESCE(v_nombre, p_pk::text)
            USING ERRCODE = '23503';
    END IF;
    UPDATE academico_test.TASIGNATURA SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TASIGNATURA = p_pk AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN
        IF v_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'La asignatura % existe pero esta inactiva', v_nombre USING ERRCODE = 'P0002';
        ELSE
            RAISE EXCEPTION 'No existe una asignatura activa con el PK indicado' USING ERRCODE = 'P0002';
        END IF;
    END IF;
    RETURN p_pk;
END;
$$;
