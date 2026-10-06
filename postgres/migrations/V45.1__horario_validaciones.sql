-- ===========================================================================
-- V45.1 -- Horario: validaciones
-- ===========================================================================
-- QUE HACE: una fn_horario_validar_<regla> por regla (RETURNS VOID, lanza o
-- nada) y fn_horario_validar_celda, que las compone para cada celda que llega
-- a fn_horario_guardar.
-- POR QUE AQUI: capa 1 del modulo (V45.1 validaciones / V45.2 nucleos /
-- V45.3 wrappers); los endpoints siguen en V80 porque necesitan eval-col (V47).
-- DEPENDE DE: V22 (TGRADO, TGRUPO, TPLAN, TASIGNATURA_PLAN, TLISTA_VALOR).
-- ===========================================================================

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_horario_validar_grado_existe(p_fk_grado BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_grado) THEN
        RAISE EXCEPTION 'El grado seleccionado no existe' USING ERRCODE = 'P0002';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_horario_validar_grado_activo(p_fk_grado BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_nombre VARCHAR;
BEGIN
    SELECT NOMBRE INTO v_nombre
      FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_grado AND ACTIVE = FALSE;
    IF FOUND THEN
        RAISE EXCEPTION 'El grado "%" existe pero esta inactivo', v_nombre USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_horario_validar_celda_campos(
    p_bloque INT, p_fk_grupo BIGINT, p_fk_dia BIGINT, p_fk_plan_item BIGINT
)
RETURNS VOID LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_bloque IS NULL OR p_fk_grupo IS NULL OR p_fk_dia IS NULL OR p_fk_plan_item IS NULL THEN
        RAISE EXCEPTION 'Cada celda requiere grupoId, planItemId, diaId y bloque' USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_horario_validar_bloque_rango(p_bloque INT, p_max_bloques BIGINT)
RETURNS VOID LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_bloque < 0 OR p_bloque >= p_max_bloques THEN
        RAISE EXCEPTION 'Bloque % fuera de rango (0 a %)', p_bloque, p_max_bloques - 1
            USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_horario_validar_grupo_del_grado(p_fk_grupo BIGINT, p_fk_grado BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_grupo VARCHAR; v_grado VARCHAR;
BEGIN
    IF EXISTS (SELECT 1 FROM academico_test.TGRUPO
                WHERE PK_TGRUPO = p_fk_grupo AND FK_TGRADO = p_fk_grado AND ACTIVE = TRUE) THEN
        RETURN;
    END IF;
    SELECT NOMBRE INTO v_grupo FROM academico_test.TGRUPO WHERE PK_TGRUPO = p_fk_grupo;
    IF v_grupo IS NULL THEN
        RAISE EXCEPTION 'El grupo seleccionado no existe' USING ERRCODE = '22023';
    END IF;
    SELECT NOMBRE INTO v_grado FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_grado;
    RAISE EXCEPTION 'El grupo "%" no pertenece al grado "%" o esta inactivo', v_grupo, v_grado
        USING ERRCODE = '22023';
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_horario_validar_dia(p_fk_dia BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_nombre VARCHAR;
BEGIN
    IF EXISTS (SELECT 1 FROM academico_test.TLISTA_VALOR
                WHERE PK_LISTA_VALOR = p_fk_dia AND ACTIVE = TRUE AND CATEGORIA = 'DIA_SEMANA') THEN
        RETURN;
    END IF;
    SELECT NOMBRE INTO v_nombre FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_fk_dia;
    IF v_nombre IS NOT NULL THEN
        RAISE EXCEPTION 'El dia "%" no es valido (debe ser de la categoria DIA_SEMANA)', v_nombre
            USING ERRCODE = '23503';
    END IF;
    RAISE EXCEPTION 'El dia seleccionado no existe' USING ERRCODE = '23503';
END;
$$;

-- El renglon tiene que estar activo y en un plan activo del mismo grado.
CREATE OR REPLACE FUNCTION academico_test.fn_horario_validar_plan_item(p_fk_plan_item BIGINT, p_fk_grado BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_asig VARCHAR; v_grado VARCHAR;
BEGIN
    IF EXISTS (SELECT 1
                 FROM academico_test.TASIGNATURA_PLAN ap
                 JOIN academico_test.TPLAN pl ON pl.PK_TPLAN = ap.FK_TPLAN AND pl.ACTIVE = TRUE
                WHERE ap.PK_TASIGNATURA_PLAN = p_fk_plan_item AND ap.ACTIVE = TRUE
                  AND pl.FK_TGRADO = p_fk_grado) THEN
        RETURN;
    END IF;
    SELECT a.NOMBRE INTO v_asig
      FROM academico_test.TASIGNATURA_PLAN ap
      JOIN academico_test.TASIGNATURA a ON a.PK_TASIGNATURA = ap.FK_TASIGNATURA
     WHERE ap.PK_TASIGNATURA_PLAN = p_fk_plan_item;
    IF v_asig IS NULL THEN
        RAISE EXCEPTION 'El renglon de plan seleccionado no existe' USING ERRCODE = '23503';
    END IF;
    SELECT NOMBRE INTO v_grado FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_grado;
    RAISE EXCEPTION 'El renglon de plan de la asignatura "%" no esta activo o no pertenece al grado "%"',
        v_asig, v_grado USING ERRCODE = '23503';
END;
$$;

-- El orden es contrato: campos, rango del bloque, grupo, dia, renglon de plan.
CREATE OR REPLACE FUNCTION academico_test.fn_horario_validar_celda(
    p_fk_grado BIGINT, p_max_bloques BIGINT,
    p_bloque INT, p_fk_grupo BIGINT, p_fk_dia BIGINT, p_fk_plan_item BIGINT
)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    PERFORM academico_test.fn_horario_validar_celda_campos(p_bloque, p_fk_grupo, p_fk_dia, p_fk_plan_item);
    PERFORM academico_test.fn_horario_validar_bloque_rango(p_bloque, p_max_bloques);
    PERFORM academico_test.fn_horario_validar_grupo_del_grado(p_fk_grupo, p_fk_grado);
    PERFORM academico_test.fn_horario_validar_dia(p_fk_dia);
    PERFORM academico_test.fn_horario_validar_plan_item(p_fk_plan_item, p_fk_grado);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_horario_validar_celda(BIGINT, BIGINT, INT, BIGINT, BIGINT, BIGINT)
    IS 'Compone las fn_horario_validar_* de una celda del horario. La usa fn_horario_guardar_interno.';
