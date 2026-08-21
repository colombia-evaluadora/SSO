-- Nueva capacidad: eliminar varios grupos (TGRUPO) de un grado en un solo
-- lote desde el front. Hasta ahora solo existía borrado individual
-- (fn_grupo_soft_delete, PUT /grupos/:ID) — no había forma de seleccionar
-- varias filas de la subtabla de grupos y borrarlas juntas (mismo hueco que
-- tenía escala de valoración con sus bandas, ver V110).
--
-- Mismo patrón que fn_periodo_bulk_delete / fn_escala_valoracion_bulk_delete:
-- recorre el arreglo de PKs, delega en fn_grupo_soft_delete (que ya trae toda
-- la validación de permisos, existencia y bloqueo por matrículas/horarios/
-- asignaciones/calificaciones asociadas) y captura la excepción por fila para
-- devolver un resultado parcial en vez de abortar todo el lote.
CREATE OR REPLACE FUNCTION academico_test.fn_grupo_bulk_delete(
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
            PERFORM academico_test.fn_grupo_soft_delete(v_id, p_pk_usuario_solicitante);
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
