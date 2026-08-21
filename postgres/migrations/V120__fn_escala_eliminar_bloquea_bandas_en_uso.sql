-- Bug: fn_escala_eliminar (borrado individual de una banda/valoracion) no
-- corria ningun chequeo de dependencia antes de desactivar — a diferencia de
-- sus hermanas fn_escala_bulk_delete/fn_escala_nivel_soft_delete, que sí
-- bloquean si la banda esta en uso por TNIVEL_CRITERIO_UNIDAD. Esto quedo mas
-- expuesto con V110 (fn_escala_valoracion_bulk_delete), que llama a esta
-- funcion por cada fila del lote.
CREATE OR REPLACE FUNCTION academico_test.fn_escala_eliminar(p_pk bigint, p_pk_usuario_solicitante bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $$
DECLARE
    v_n       INT;
    v_audit   VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_nombre  VARCHAR(130);
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, (
        SELECT academico_test.fn_periodo_establecimiento(ne.FK_PERIODO_ACADEMICO)
          FROM academico_test.TESCALA_VALORACION ev
          JOIN academico_test.TNIVEL_ESCALA ne ON ne.FK_TESCALA = ev.FK_TESCALA AND ne.ACTIVE = TRUE
         WHERE ev.PK_TESCALA_VALORACION = p_pk));
    SELECT tv.NOMBRE INTO v_nombre
      FROM academico_test.TESCALA_VALORACION ev
      JOIN academico_test.TVALORACION tv ON tv.PK_TVALORACION = ev.FK_TVALORACION
     WHERE ev.PK_TESCALA_VALORACION = p_pk;
    -- Bloqueo: la banda esta en uso por criterios de unidad (mismo chequeo que
    -- ya tienen fn_escala_bulk_delete / fn_escala_nivel_soft_delete).
    IF EXISTS (
        SELECT 1 FROM academico_test.TNIVEL_CRITERIO_UNIDAD ncu
         WHERE ncu.FK_TESCALA_VALORACION = p_pk AND ncu.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar la banda "%": esta en uso por criterios de unidad',
            COALESCE(v_nombre, p_pk::TEXT) USING ERRCODE = '23503';
    END IF;
    UPDATE academico_test.TESCALA_VALORACION SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TESCALA_VALORACION = p_pk AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN
        IF v_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'La banda "%" existe pero esta inactiva', v_nombre USING ERRCODE = 'P0002';
        ELSE
            RAISE EXCEPTION 'No existe una banda con el identificador indicado' USING ERRCODE = 'P0002';
        END IF;
    END IF;
    RETURN p_pk;
END;
$$;
