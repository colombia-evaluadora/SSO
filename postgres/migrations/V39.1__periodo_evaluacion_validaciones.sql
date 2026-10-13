-- ===========================================================================
-- V39.1 -- Periodo de evaluacion: validaciones
-- ===========================================================================
-- QUE HACE: una fn_periodo_eval_validar_<regla> por regla (RETURNS VOID, lanza
-- o nada) y fn_periodo_eval_validar, que las compone para crear/actualizar.
-- POR QUE AQUI: capa 1 del modulo (V39.1 validaciones / V39.2 nucleos /
-- V39.3 wrappers); los endpoints siguen en V76 porque necesitan eval-col (V47).
-- DEPENDE DE: V22 (TPERIODO_ACADEMICO, TPERIODO_EVALUACION, notas).
-- ===========================================================================

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_eval_validar_existe(p_pk BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM academico_test.TPERIODO_EVALUACION WHERE PK_TPERIODO_EVALUACION = p_pk) THEN
        RAISE EXCEPTION 'No existe el periodo de evaluacion indicado' USING ERRCODE = 'P0002';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_eval_validar_activo(p_pk BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_nombre VARCHAR(130);
BEGIN
    SELECT NOMBRE INTO v_nombre
      FROM academico_test.TPERIODO_EVALUACION
     WHERE PK_TPERIODO_EVALUACION = p_pk AND ACTIVE = FALSE;
    IF FOUND THEN
        RAISE EXCEPTION 'El periodo de evaluacion "%" esta inactivo; no se puede actualizar', v_nombre
            USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_eval_validar_campos(
    p_fk_periodo BIGINT, p_codigo VARCHAR, p_nombre VARCHAR, p_abreviacion VARCHAR,
    p_fecha_inicio DATE, p_fecha_fin DATE, p_fk_estado BIGINT
)
RETURNS VOID LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_fk_periodo IS NULL OR NULLIF(TRIM(p_codigo),'') IS NULL OR NULLIF(TRIM(p_nombre),'') IS NULL
       OR NULLIF(TRIM(p_abreviacion),'') IS NULL OR p_fecha_inicio IS NULL OR p_fecha_fin IS NULL
       OR p_fk_estado IS NULL THEN
        RAISE EXCEPTION 'Faltan campos obligatorios del periodo de evaluacion' USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_eval_validar_fechas(p_fecha_inicio DATE, p_fecha_fin DATE)
RETURNS VOID LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_fecha_fin <= p_fecha_inicio THEN
        RAISE EXCEPTION 'La fecha fin debe ser posterior a la fecha inicio' USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_eval_validar_periodo_academico(p_fk_periodo BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_nombre VARCHAR(130); v_active BOOLEAN;
BEGIN
    SELECT NOMBRE, ACTIVE INTO v_nombre, v_active
      FROM academico_test.TPERIODO_ACADEMICO WHERE PK_TPERIODO_ACADEMICO = p_fk_periodo;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El periodo academico indicado no existe' USING ERRCODE = '23503';
    ELSIF NOT v_active THEN
        RAISE EXCEPTION 'El periodo academico "%" esta inactivo', v_nombre USING ERRCODE = '23503';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_eval_validar_dentro_periodo(
    p_fk_periodo BIGINT, p_fecha_inicio DATE, p_fecha_fin DATE
)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_pi DATE; v_pf DATE;
BEGIN
    SELECT FECHA_INICIO, FECHA_FIN INTO v_pi, v_pf
      FROM academico_test.TPERIODO_ACADEMICO WHERE PK_TPERIODO_ACADEMICO = p_fk_periodo;
    IF p_fecha_inicio < v_pi OR p_fecha_fin > v_pf THEN
        RAISE EXCEPTION 'El periodo de evaluacion (% a %) debe estar dentro del periodo academico (% a %)',
            p_fecha_inicio, p_fecha_fin, v_pi, v_pf USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_eval_validar_porcentaje(p_porcentaje NUMERIC)
RETURNS VOID LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_porcentaje < 0 THEN
        RAISE EXCEPTION 'El porcentaje (%) no puede ser negativo', p_porcentaje USING ERRCODE = '22023';
    END IF;
END;
$$;

-- p_campo: CODIGO | NOMBRE | ABREVIACION. Unico entre los activos del periodo academico.
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_eval_validar_unico(
    p_fk_periodo BIGINT, p_campo TEXT, p_valor VARCHAR, p_pk_excluir BIGINT DEFAULT NULL
)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF NULLIF(TRIM(p_valor),'') IS NULL THEN RETURN; END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.TPERIODO_EVALUACION pe
         WHERE pe.FK_TPERIODO_ACADEMICO = p_fk_periodo AND pe.ACTIVE = TRUE
           AND pe.PK_TPERIODO_EVALUACION <> COALESCE(p_pk_excluir, -1)
           AND UPPER(TRIM(CASE p_campo WHEN 'CODIGO' THEN pe.CODIGO
                                       WHEN 'NOMBRE' THEN pe.NOMBRE
                                       ELSE pe.ABREVIACION END)) = UPPER(TRIM(p_valor))
    ) THEN
        RAISE EXCEPTION 'Ya existe un periodo de evaluacion con % % en este periodo academico',
            CASE p_campo WHEN 'CODIGO' THEN 'el codigo' WHEN 'NOMBRE' THEN 'el nombre' ELSE 'la abreviacion' END,
            p_valor USING ERRCODE = '23505';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_eval_validar_sin_solape(
    p_fk_periodo BIGINT, p_fecha_inicio DATE, p_fecha_fin DATE, p_pk_excluir BIGINT DEFAULT NULL
)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM academico_test.TPERIODO_EVALUACION pe
         WHERE pe.FK_TPERIODO_ACADEMICO = p_fk_periodo AND pe.ACTIVE = TRUE
           AND pe.PK_TPERIODO_EVALUACION <> COALESCE(p_pk_excluir, -1)
           AND p_fecha_inicio <= pe.FECHA_FIN AND p_fecha_fin >= pe.FECHA_INICIO
    ) THEN
        RAISE EXCEPTION 'El periodo de evaluacion se solapa con otro existente' USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_eval_validar_suma_pesos(
    p_fk_periodo BIGINT, p_porcentaje NUMERIC, p_pk_excluir BIGINT DEFAULT NULL
)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_suma NUMERIC;
BEGIN
    SELECT COALESCE(SUM(pe.PORCENTAJE), 0) INTO v_suma
      FROM academico_test.TPERIODO_EVALUACION pe
     WHERE pe.FK_TPERIODO_ACADEMICO = p_fk_periodo AND pe.ACTIVE = TRUE
       AND pe.PK_TPERIODO_EVALUACION <> COALESCE(p_pk_excluir, -1);
    IF v_suma + COALESCE(p_porcentaje, 0) > 100 THEN
        RAISE EXCEPTION 'La suma de pesos (% + %) supera el 100%%', v_suma, COALESCE(p_porcentaje, 0)
            USING ERRCODE = '22023';
    END IF;
END;
$$;

-- Las notas no dependen de que la matricula siga activa: son historial.
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_eval_validar_sin_calificaciones(p_pk BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_nombre VARCHAR(130);
BEGIN
    IF EXISTS (SELECT 1 FROM academico_test.TASIGNATURA_NOTA an
                WHERE an.FK_TPERIODO_EVALUACION = p_pk AND an.ACTIVE = TRUE)
       OR EXISTS (SELECT 1 FROM academico_test.TAREA_NOTA tn
                   WHERE tn.FK_TPERIODO_EVALUACION = p_pk AND tn.ACTIVE = TRUE) THEN
        SELECT NOMBRE INTO v_nombre
          FROM academico_test.TPERIODO_EVALUACION WHERE PK_TPERIODO_EVALUACION = p_pk;
        RAISE EXCEPTION 'No se puede eliminar el periodo de evaluacion "%": existen calificaciones registradas',
            COALESCE(v_nombre, p_pk::TEXT) USING ERRCODE = '23503';
    END IF;
END;
$$;

-- El orden es contrato: periodo academico, porcentaje, unicos, rango, solape, suma.
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_eval_validar(
    p_fk_periodo bigint,
    p_fecha_inicio date,
    p_fecha_fin date,
    p_porcentaje numeric,
    p_codigo character varying DEFAULT NULL::character varying,
    p_nombre character varying DEFAULT NULL::character varying,
    p_abreviacion character varying DEFAULT NULL::character varying,
    p_pk_excluir bigint DEFAULT NULL::bigint
)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    PERFORM academico_test.fn_periodo_eval_validar_periodo_academico(p_fk_periodo);
    PERFORM academico_test.fn_periodo_eval_validar_porcentaje(p_porcentaje);
    PERFORM academico_test.fn_periodo_eval_validar_unico(p_fk_periodo, 'CODIGO', p_codigo, p_pk_excluir);
    PERFORM academico_test.fn_periodo_eval_validar_unico(p_fk_periodo, 'NOMBRE', p_nombre, p_pk_excluir);
    PERFORM academico_test.fn_periodo_eval_validar_unico(p_fk_periodo, 'ABREVIACION', p_abreviacion, p_pk_excluir);
    PERFORM academico_test.fn_periodo_eval_validar_dentro_periodo(p_fk_periodo, p_fecha_inicio, p_fecha_fin);
    PERFORM academico_test.fn_periodo_eval_validar_sin_solape(p_fk_periodo, p_fecha_inicio, p_fecha_fin, p_pk_excluir);
    PERFORM academico_test.fn_periodo_eval_validar_suma_pesos(p_fk_periodo, p_porcentaje, p_pk_excluir);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_eval_validar(BIGINT, DATE, DATE, NUMERIC, VARCHAR, VARCHAR, VARCHAR, BIGINT)
    IS 'Compone las fn_periodo_eval_validar_* de crear/actualizar. p_pk_excluir = el periodo que se edita.';
