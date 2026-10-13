-- ===========================================================================
-- V44.1 -- Plan de estudio: validaciones
-- ===========================================================================
-- QUE HACE: una fn_plan_validar_<regla> por regla (RETURNS VOID, lanza o nada)
-- sobre TPLAN / TASIGNATURA_PLAN, y las que componen los valores de un renglon
-- y lo que impide quitarlo del plan.
-- POR QUE AQUI: capa 1 del modulo (V44.1 validaciones / V44.2 nucleos /
-- V44.3 wrappers); los endpoints siguen en V80 porque necesitan eval-col.
-- DEPENDE DE: V22 (TPLAN, TASIGNATURA_PLAN, TGRADO, TASIGNATURA, TLISTA_VALOR).
-- ===========================================================================

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_plan_validar_renglon_existe(p_pk BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM academico_test.TASIGNATURA_PLAN WHERE PK_TASIGNATURA_PLAN = p_pk) THEN
        RAISE EXCEPTION 'No existe un renglon de plan activo con el identificador indicado' USING ERRCODE = 'P0002';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_plan_validar_renglon_activo(p_pk BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_asignatura TEXT; v_grado TEXT;
BEGIN
    SELECT ta.NOMBRE, tg.NOMBRE INTO v_asignatura, v_grado
      FROM academico_test.TASIGNATURA_PLAN ap
      JOIN academico_test.TASIGNATURA ta ON ta.PK_TASIGNATURA = ap.FK_TASIGNATURA
      JOIN academico_test.TPLAN pl ON pl.PK_TPLAN = ap.FK_TPLAN
      JOIN academico_test.TGRADO tg ON tg.PK_TGRADO = pl.FK_TGRADO
     WHERE ap.PK_TASIGNATURA_PLAN = p_pk AND ap.ACTIVE = FALSE;
    IF FOUND THEN
        RAISE EXCEPTION 'El renglon de plan para la asignatura "%" del grado "%" existe pero esta inactivo',
            v_asignatura, v_grado USING ERRCODE = 'P0002';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_plan_validar_existe_para_grado(p_fk_grado BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_grado TEXT;
BEGIN
    IF EXISTS (SELECT 1 FROM academico_test.TPLAN WHERE FK_TGRADO = p_fk_grado AND ACTIVE = TRUE) THEN
        RETURN;
    END IF;
    SELECT NOMBRE INTO v_grado FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_grado;
    IF v_grado IS NOT NULL THEN
        RAISE EXCEPTION 'No existe un plan de estudio activo para el grado "%"', v_grado USING ERRCODE = 'P0002';
    END IF;
    RAISE EXCEPTION 'No existe un plan de estudio activo para el grado indicado' USING ERRCODE = 'P0002';
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_plan_validar_campos(p_fk_grado BIGINT, p_fk_asignatura BIGINT)
RETURNS VOID LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_fk_grado IS NULL OR p_fk_asignatura IS NULL THEN
        RAISE EXCEPTION 'Grado y asignatura son obligatorios' USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_plan_validar_intensidad_horaria(p_numero_hora NUMERIC)
RETURNS VOID LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_numero_hora IS NOT NULL AND p_numero_hora <= 0 THEN
        RAISE EXCEPTION 'La intensidad horaria debe ser mayor a 0' USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_plan_validar_influencia_area(p_influencia_area NUMERIC)
RETURNS VOID LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_influencia_area IS NOT NULL AND (p_influencia_area < 0 OR p_influencia_area > 100) THEN
        RAISE EXCEPTION 'La influencia en el area (%%) debe estar entre 0 y 100' USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_plan_validar_creditos(p_numero_credito BIGINT)
RETURNS VOID LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_numero_credito IS NOT NULL AND p_numero_credito < 0 THEN
        RAISE EXCEPTION 'El numero de creditos no puede ser negativo' USING ERRCODE = '22023';
    END IF;
END;
$$;

-- NULL = el valor no viene y no se valida.
CREATE OR REPLACE FUNCTION academico_test.fn_plan_validar_valores(
    p_numero_hora NUMERIC, p_influencia_area NUMERIC, p_numero_credito BIGINT
)
RETURNS VOID LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    PERFORM academico_test.fn_plan_validar_intensidad_horaria(p_numero_hora);
    PERFORM academico_test.fn_plan_validar_influencia_area(p_influencia_area);
    PERFORM academico_test.fn_plan_validar_creditos(p_numero_credito);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_plan_validar_valores(NUMERIC, NUMERIC, BIGINT)
    IS 'Compone intensidad horaria, influencia en el area y creditos de un renglon del plan.';

CREATE OR REPLACE FUNCTION academico_test.fn_plan_validar_grado(p_fk_grado BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_nombre TEXT; v_active BOOLEAN;
BEGIN
    SELECT NOMBRE, ACTIVE INTO v_nombre, v_active FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_grado;
    IF v_active IS TRUE AND v_nombre IS NOT NULL THEN RETURN; END IF;
    IF v_nombre IS NOT NULL THEN
        RAISE EXCEPTION 'El grado "%" existe pero esta inactivo', v_nombre USING ERRCODE = '23503';
    END IF;
    RAISE EXCEPTION 'El grado indicado no existe' USING ERRCODE = '23503';
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_plan_validar_asignatura(p_fk_asignatura BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_nombre TEXT; v_active BOOLEAN;
BEGIN
    IF p_fk_asignatura IS NULL THEN RETURN; END IF;
    SELECT NOMBRE, ACTIVE INTO v_nombre, v_active FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_fk_asignatura;
    IF v_active IS TRUE AND v_nombre IS NOT NULL THEN RETURN; END IF;
    IF v_nombre IS NOT NULL THEN
        RAISE EXCEPTION 'La asignatura "%" existe pero esta inactiva', v_nombre USING ERRCODE = '23503';
    END IF;
    RAISE EXCEPTION 'La asignatura indicada no existe' USING ERRCODE = '23503';
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_plan_validar_formato_calificacion(p_fk_formato_calif BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_valor TEXT;
BEGIN
    IF p_fk_formato_calif IS NULL OR EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_fk_formato_calif AND ACTIVE = TRUE AND CATEGORIA = 'FORMATO_CALIFICACION'
           AND VALOR IS NOT NULL
    ) THEN
        RETURN;
    END IF;
    SELECT VALOR INTO v_valor FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_fk_formato_calif;
    IF v_valor IS NOT NULL THEN
        RAISE EXCEPTION 'El formato de calificacion "%" existe pero esta inactivo o no pertenece a la categoria correspondiente', v_valor
            USING ERRCODE = '23503';
    END IF;
    RAISE EXCEPTION 'El formato de calificacion indicado no existe' USING ERRCODE = '23503';
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_plan_validar_criterio_nota(p_fk_criterio_nota BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_valor TEXT;
BEGIN
    IF p_fk_criterio_nota IS NULL OR EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_fk_criterio_nota AND ACTIVE = TRUE AND CATEGORIA = 'TIPO_CALCULO'
           AND VALOR IS NOT NULL
    ) THEN
        RETURN;
    END IF;
    SELECT VALOR INTO v_valor FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_fk_criterio_nota;
    IF v_valor IS NOT NULL THEN
        RAISE EXCEPTION 'El criterio de calculo de nota "%" existe pero esta inactivo o no pertenece a la categoria correspondiente', v_valor
            USING ERRCODE = '23503';
    END IF;
    RAISE EXCEPTION 'El criterio de calculo de nota indicado no existe' USING ERRCODE = '23503';
END;
$$;

-- Una asignatura aparece una sola vez entre los renglones activos de un plan.
CREATE OR REPLACE FUNCTION academico_test.fn_plan_validar_asignatura_unica(
    p_fk_plan BIGINT, p_fk_asignatura BIGINT, p_pk_excluir BIGINT DEFAULT NULL
)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM academico_test.TASIGNATURA_PLAN
         WHERE FK_TPLAN = p_fk_plan AND FK_TASIGNATURA = p_fk_asignatura AND ACTIVE = TRUE
           AND PK_TASIGNATURA_PLAN <> COALESCE(p_pk_excluir, -1)
    ) THEN
        RAISE EXCEPTION 'La asignatura "%" ya esta en el plan de estudio de este grado',
            (SELECT NOMBRE FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_fk_asignatura)
            USING ERRCODE = '23505';
    END IF;
END;
$$;

-- Solo cuentan los grupos de este grado: en otros grados la asignatura sigue en su plan.
CREATE OR REPLACE FUNCTION academico_test.fn_plan_validar_renglon_sin_asignaciones(p_pk BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
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
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_plan_validar_renglon_sin_horarios(p_pk BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF EXISTS (
        SELECT 1
          FROM academico_test.TASIGNATURA_PLAN ap
          JOIN academico_test.TPLAN pl ON pl.PK_TPLAN = ap.FK_TPLAN
          JOIN academico_test.TGRUPO g ON g.FK_TGRADO = pl.FK_TGRADO AND g.ACTIVE = TRUE
          JOIN academico_test.THORARIO h ON h.FK_TGRUPO = g.PK_TGRUPO
               AND h.FK_TASIGNATURA = ap.FK_TASIGNATURA AND h.ACTIVE = TRUE
         WHERE ap.PK_TASIGNATURA_PLAN = p_pk AND ap.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar: la asignatura tiene bloques de horario configurados en grupos del grado'
            USING ERRCODE = '23503';
    END IF;
END;
$$;

-- El orden es contrato: asignaciones docentes, horario.
CREATE OR REPLACE FUNCTION academico_test.fn_plan_validar_renglon_removible(p_pk BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    PERFORM academico_test.fn_plan_validar_renglon_sin_asignaciones(p_pk);
    PERFORM academico_test.fn_plan_validar_renglon_sin_horarios(p_pk);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_plan_validar_renglon_removible(BIGINT)
    IS 'Compone lo que impide quitar un renglon del plan (23503): docente u horario en grupos del grado.';

CREATE OR REPLACE FUNCTION academico_test.fn_plan_validar_sin_asignaciones(p_fk_plan BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF EXISTS (
        SELECT 1
          FROM academico_test.TASIGNATURA_PLAN ap
          JOIN academico_test.TPLAN pl ON pl.PK_TPLAN = ap.FK_TPLAN
          JOIN academico_test.TGRUPO g ON g.FK_TGRADO = pl.FK_TGRADO AND g.ACTIVE = TRUE
          JOIN academico_test.TDOCENTE_ASIGNATURA da ON da.FK_TGRUPO = g.PK_TGRUPO
               AND da.FK_TASIGNATURA = ap.FK_TASIGNATURA AND da.ACTIVE = TRUE
         WHERE ap.FK_TPLAN = p_fk_plan AND ap.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el plan del grado "%": hay asignaturas con asignaciones academicas (docentes) activas',
            (SELECT g.NOMBRE FROM academico_test.TPLAN pl JOIN academico_test.TGRADO g ON g.PK_TGRADO = pl.FK_TGRADO
              WHERE pl.PK_TPLAN = p_fk_plan)
            USING ERRCODE = '23503';
    END IF;
END;
$$;
