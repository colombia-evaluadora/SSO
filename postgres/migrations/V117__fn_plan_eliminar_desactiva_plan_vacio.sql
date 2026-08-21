-- Bug: no había forma de borrar un plan de estudio completo. El front solo
-- borra renglones individuales (asignaturas) del plan vía fn_plan_eliminar;
-- si se borran TODOS los renglones, el TPLAN en sí queda activo y vacío para
-- siempre, y fn_grado_soft_delete bloquea el borrado del grado mientras
-- exista un TPLAN activo asociado ("existe un plan de estudio asociado") —
-- aunque ese plan ya no tenga ninguna asignatura.
--
-- fn_plan_agregar ya crea el TPLAN automáticamente cuando hace falta
-- (primera asignatura que se agrega a un grado); este fix agrega la cascada
-- inversa: al borrar el último renglón activo de un plan, el TPLAN también
-- se da de baja.
CREATE OR REPLACE FUNCTION academico_test.fn_plan_eliminar(p_pk bigint, p_pk_usuario_solicitante bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $$
DECLARE
    v_n INT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_asignatura_nom TEXT; v_grado_nom TEXT;
    v_plan_id BIGINT;
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, (
        SELECT academico_test.fn_periodo_establecimiento(g.FK_TPERIODO_ACADEMICO)
          FROM academico_test.TASIGNATURA_PLAN ap
          JOIN academico_test.TPLAN pl ON pl.PK_TPLAN = ap.FK_TPLAN
          JOIN academico_test.TGRADO g ON g.PK_TGRADO = pl.FK_TGRADO
         WHERE ap.PK_TASIGNATURA_PLAN = p_pk));
    -- Bloqueo: la asignatura del renglon tiene asignaciones docente activas en
    -- algun grupo del grado del plan.
    IF EXISTS (
        SELECT 1
          FROM academico_test.TASIGNATURA_PLAN ap
          JOIN academico_test.TPLAN pl ON pl.PK_TPLAN = ap.FK_TPLAN
          JOIN academico_test.TGRUPO g ON g.FK_TGRADO = pl.FK_TGRADO AND g.ACTIVE = TRUE
          JOIN academico_test.TDOCENTE_ASIGNATURA da ON da.FK_TGRUPO = g.PK_TGRUPO
               AND da.FK_TASIGNATURA = ap.FK_TASIGNATURA AND da.ACTIVE = TRUE
         WHERE ap.PK_TASIGNATURA_PLAN = p_pk AND ap.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar: la asignatura tiene asignaciones academicas (docentes) en grupos del grado'
            USING ERRCODE = '23503';
    END IF;
    -- FK_TPLAN del renglon (para la cascada de abajo) antes de darlo de baja.
    SELECT FK_TPLAN INTO v_plan_id FROM academico_test.TASIGNATURA_PLAN WHERE PK_TASIGNATURA_PLAN = p_pk;
    UPDATE academico_test.TASIGNATURA_PLAN SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TASIGNATURA_PLAN = p_pk AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN
        SELECT ta.NOMBRE, tg.NOMBRE INTO v_asignatura_nom, v_grado_nom
          FROM academico_test.TASIGNATURA_PLAN ap
          JOIN academico_test.TASIGNATURA ta ON ta.PK_TASIGNATURA = ap.FK_TASIGNATURA
          JOIN academico_test.TPLAN pl ON pl.PK_TPLAN = ap.FK_TPLAN
          JOIN academico_test.TGRADO tg ON tg.PK_TGRADO = pl.FK_TGRADO
         WHERE ap.PK_TASIGNATURA_PLAN = p_pk;
        IF v_asignatura_nom IS NOT NULL THEN
            RAISE EXCEPTION 'El renglon de plan para la asignatura "%" del grado "%" existe pero esta inactivo', v_asignatura_nom, v_grado_nom
                USING ERRCODE = 'P0002';
        ELSE
            RAISE EXCEPTION 'No existe un renglon de plan activo con el identificador indicado' USING ERRCODE = 'P0002';
        END IF;
    END IF;
    -- Da de baja el enlace con el criterio de evaluacion.
    UPDATE academico_test.TCRITERIO_EVALUACION_ASIGNATURA_PLAN
       SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TASIGNATURA_PLAN = p_pk AND ACTIVE = TRUE;
    -- Cascada: si el plan se quedo sin ningun renglon activo, se da de baja
    -- tambien (evita que un TPLAN vacio bloquee para siempre el borrado del
    -- grado en fn_grado_soft_delete).
    IF v_plan_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TASIGNATURA_PLAN
         WHERE FK_TPLAN = v_plan_id AND ACTIVE = TRUE
    ) THEN
        UPDATE academico_test.TPLAN
           SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TPLAN = v_plan_id AND ACTIVE = TRUE;
    END IF;
    RETURN p_pk;
END;
$$;
