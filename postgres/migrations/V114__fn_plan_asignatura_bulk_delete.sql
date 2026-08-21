-- Nueva capacidad: eliminar varios renglones del plan de estudio
-- (TASIGNATURA_PLAN) en un solo lote desde el front. Hasta ahora solo existía
-- borrado individual (fn_plan_eliminar, PUT /plan-asignaturas/:ID) — mismo
-- hueco que tenían escala de valoración (V110) y grupos (V113).
--
-- Mismo patrón: recorre el arreglo de PKs, delega en fn_plan_eliminar (ya
-- trae la validación de permisos, existencia y bloqueo por asignaciones
-- académicas activas) y captura la excepción por fila.
CREATE OR REPLACE FUNCTION academico_test.fn_plan_asignatura_bulk_delete(
    p_ids bigint[],
    p_pk_usuario_solicitante bigint
)
RETURNS TABLE(id bigint, eliminado boolean, error_code text, error_mensaje text)
LANGUAGE plpgsql AS $$
DECLARE v_id BIGINT; v_state TEXT; v_msg TEXT;
BEGIN
    IF p_ids IS NULL THEN RETURN; END IF;
    FOREACH v_id IN ARRAY p_ids LOOP
        BEGIN
            PERFORM academico_test.fn_plan_eliminar(v_id, p_pk_usuario_solicitante);
            id := v_id; eliminado := TRUE; error_code := NULL; error_mensaje := NULL;
            RETURN NEXT;
        EXCEPTION WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
            id := v_id; eliminado := FALSE; error_code := v_state; error_mensaje := v_msg;
            RETURN NEXT;
        END;
    END LOOP;
    RETURN;
END;
$$;
