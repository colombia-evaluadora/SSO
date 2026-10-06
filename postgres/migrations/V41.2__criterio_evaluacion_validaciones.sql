-- ===========================================================================
-- V41.2 -- Criterios de evaluacion: validaciones
-- ===========================================================================
-- QUE HACE: una fn_criterio_eval_validar_<regla> por regla (RETURNS VOID, lanza
-- o nada) y fn_criterio_eval_validar, que las compone para actualizar.
-- POR QUE AQUI: capa 1 del modulo (V41.2 validaciones / V41.3 nucleos /
-- V41.4 wrappers). Los endpoints siguen en V76 porque necesitan eval-col (V47).
-- DEPENDE DE: V22 (TCRITERIO_EVALUACION, TESCALA*, TNIVEL_ESCALA), V41.
-- ===========================================================================

SET search_path TO academico_test, public;

-- TCRITERIO_EVALUACION comparte pk con TPERIODO_ACADEMICO.
CREATE OR REPLACE FUNCTION academico_test.fn_criterio_eval_validar_existe(p_pk_periodo BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_nombre VARCHAR(130);
BEGIN
    IF NOT EXISTS (SELECT 1 FROM academico_test.TCRITERIO_EVALUACION
                    WHERE PK_TCRITERIO_EVALUACION = p_pk_periodo AND ACTIVE = TRUE) THEN
        SELECT NOMBRE INTO v_nombre FROM academico_test.TPERIODO_ACADEMICO
         WHERE PK_TPERIODO_ACADEMICO = p_pk_periodo;
        IF v_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'No existe criterio de evaluacion activo para el periodo "%"', v_nombre
                USING ERRCODE = 'P0002';
        ELSE
            RAISE EXCEPTION 'El periodo academico seleccionado no existe' USING ERRCODE = 'P0002';
        END IF;
    END IF;
END;
$$;

-- p_grading_scale es un PK_TESCALA_VALORACION; su TESCALA debe estar activa.
CREATE OR REPLACE FUNCTION academico_test.fn_criterio_eval_validar_valoracion_activa(p_grading_scale BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_nombre VARCHAR;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TESCALA_VALORACION tv
          JOIN academico_test.TESCALA t ON t.PK_TESCALA = tv.FK_TESCALA AND t.ACTIVE = TRUE
         WHERE tv.PK_TESCALA_VALORACION = p_grading_scale AND tv.ACTIVE = TRUE
    ) THEN
        SELECT v.NOMBRE INTO v_nombre
          FROM academico_test.TESCALA_VALORACION tv
          JOIN academico_test.TVALORACION v ON v.PK_TVALORACION = tv.FK_TVALORACION
         WHERE tv.PK_TESCALA_VALORACION = p_grading_scale;
        IF v_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'La valoracion "%" existe pero esta inactiva', v_nombre USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'La valoracion seleccionada no existe' USING ERRCODE = '23503';
        END IF;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_criterio_eval_validar_escala_del_periodo(
    p_pk_periodo BIGINT, p_fk_tescala BIGINT
)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_escala VARCHAR; v_periodo VARCHAR;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TNIVEL_ESCALA
         WHERE FK_TESCALA = p_fk_tescala AND FK_PERIODO_ACADEMICO = p_pk_periodo AND ACTIVE = TRUE
    ) THEN
        SELECT NOMBRE INTO v_escala FROM academico_test.TESCALA WHERE PK_TESCALA = p_fk_tescala;
        SELECT NOMBRE INTO v_periodo FROM academico_test.TPERIODO_ACADEMICO WHERE PK_TPERIODO_ACADEMICO = p_pk_periodo;
        RAISE EXCEPTION 'La escala "%" no pertenece al periodo academico "%"', v_escala, v_periodo
            USING ERRCODE = '22023';
    END IF;
END;
$$;

-- Valor activo de TLISTA_VALOR de la categoria indicada. p_etiqueta nombra el campo en el mensaje.
CREATE OR REPLACE FUNCTION academico_test.fn_criterio_eval_validar_catalogo(
    p_pk BIGINT, p_categoria VARCHAR, p_etiqueta TEXT
)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_nombre VARCHAR;
BEGIN
    IF p_pk IS NULL THEN RETURN; END IF;
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_pk AND ACTIVE = TRUE AND CATEGORIA = p_categoria
    ) THEN
        SELECT NOMBRE INTO v_nombre FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_pk;
        IF v_nombre IS NOT NULL THEN
            RAISE EXCEPTION '% "%" no es valido para este campo', p_etiqueta, v_nombre USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION '% seleccionado no existe', p_etiqueta USING ERRCODE = '23503';
        END IF;
    END IF;
END;
$$;

-- FK_TLV_MODIF_FINAL_PERACA no se ata a una categoria: basta con que el valor este activo.
CREATE OR REPLACE FUNCTION academico_test.fn_criterio_eval_validar_valor_activo(p_pk BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_nombre VARCHAR;
BEGIN
    IF p_pk IS NULL THEN RETURN; END IF;
    IF NOT EXISTS (SELECT 1 FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_pk AND ACTIVE = TRUE) THEN
        SELECT NOMBRE INTO v_nombre FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_pk;
        IF v_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'El valor "%" existe pero esta inactivo en el catalogo', v_nombre USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'El valor seleccionado no existe en el catalogo' USING ERRCODE = '23503';
        END IF;
    END IF;
END;
$$;

-- El orden es contrato: escala, formato, elementos, nota final editable, criterios, desempeno, redondeo.
CREATE OR REPLACE FUNCTION academico_test.fn_criterio_eval_validar(
    p_pk_periodo BIGINT,
    p_grading_format BIGINT,
    p_grading_scale BIGINT,
    p_set_grading_scale BOOLEAN,
    p_period_calc_elements BIGINT,
    p_modif_final_peraca BIGINT,
    p_subject_grade_criteria BIGINT,
    p_final_grade_criteria BIGINT,
    p_area_grade_criteria BIGINT,
    p_student_wo_grades BIGINT,
    p_rounding_mode BIGINT
)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE v_fk_tescala BIGINT;
BEGIN
    IF p_set_grading_scale AND p_grading_scale IS NOT NULL THEN
        PERFORM academico_test.fn_criterio_eval_validar_valoracion_activa(p_grading_scale);
        SELECT FK_TESCALA INTO v_fk_tescala FROM academico_test.TESCALA_VALORACION
         WHERE PK_TESCALA_VALORACION = p_grading_scale;
        PERFORM academico_test.fn_criterio_eval_validar_escala_del_periodo(p_pk_periodo, v_fk_tescala);
    END IF;
    PERFORM academico_test.fn_criterio_eval_validar_catalogo(p_grading_format, 'FORMATO_CALIFICACION', 'El formato de calificacion');
    PERFORM academico_test.fn_criterio_eval_validar_catalogo(p_period_calc_elements, 'ELEMENTO_CALCULO_DEF', 'El elemento de calculo del periodo');
    PERFORM academico_test.fn_criterio_eval_validar_valor_activo(p_modif_final_peraca);
    PERFORM academico_test.fn_criterio_eval_validar_catalogo(p_subject_grade_criteria, 'TIPO_CALCULO', 'El criterio de calculo de la asignatura');
    PERFORM academico_test.fn_criterio_eval_validar_catalogo(p_final_grade_criteria, 'CRITERIO_FINAL_PERACA', 'El criterio de nota final');
    PERFORM academico_test.fn_criterio_eval_validar_catalogo(p_area_grade_criteria, 'CRITERIO_AREA', 'El criterio de nota de area');
    PERFORM academico_test.fn_criterio_eval_validar_catalogo(p_student_wo_grades, 'DESEMPENIOSUGERIR', 'El desempeno sugerido sin calificacion');
    PERFORM academico_test.fn_criterio_eval_validar_catalogo(p_rounding_mode, 'MODO_REDONDEAR', 'El modo de redondeo');
END;
$$;

COMMENT ON FUNCTION academico_test.fn_criterio_eval_validar(BIGINT, BIGINT, BIGINT, BOOLEAN, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT)
    IS 'Compone las fn_criterio_eval_validar_* de la edicion de criterios de evaluacion de un periodo academico.';
