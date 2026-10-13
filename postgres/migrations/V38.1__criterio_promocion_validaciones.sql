-- ===========================================================================
-- V38.1 -- Criterios de promocion: validaciones
-- ===========================================================================
-- QUE HACE: una fn_criterio_prom_validar_<regla> por regla (RETURNS VOID, lanza
-- o nada) y fn_criterio_prom_validar_obligatoria, que compone las de cada
-- asignatura/area obligatoria.
-- POR QUE AQUI: capa 1 del modulo (V38.1 validaciones / V38.2 nucleos /
-- V38.3 wrappers); los endpoints siguen en V76 porque necesitan eval-col (V47).
-- DEPENDE DE: V22 (TPERIODO_ACADEMICO, TCRITERIO_PROMOCION, TASIGNATURA, TAREA).
-- ===========================================================================

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_criterio_prom_validar_periodo_informado(p_fk_periodo BIGINT)
RETURNS VOID LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_fk_periodo IS NULL THEN
        RAISE EXCEPTION 'El periodo academico es obligatorio' USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_criterio_prom_validar_periodo_existe(p_fk_periodo BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM academico_test.TPERIODO_ACADEMICO
                    WHERE PK_TPERIODO_ACADEMICO = p_fk_periodo) THEN
        RAISE EXCEPTION 'El periodo academico indicado no existe' USING ERRCODE = 'P0002';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_criterio_prom_validar_no_negativos(
    p_cantidad_nivelar NUMERIC, p_desempenho_min_general NUMERIC, p_desempenho_minimo NUMERIC,
    p_max_asig_promedio NUMERIC, p_minimo_inasistencias NUMERIC, p_max_asig_nivelar_prom NUMERIC
)
RETURNS VOID LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_cantidad_nivelar < 0 OR p_desempenho_min_general < 0 OR p_desempenho_minimo < 0
       OR p_max_asig_promedio < 0 OR p_minimo_inasistencias < 0 OR p_max_asig_nivelar_prom < 0 THEN
        RAISE EXCEPTION 'Los valores numericos del criterio de promocion no pueden ser negativos'
            USING ERRCODE = '22023';
    END IF;
END;
$$;

-- Los ids obligatorios son de TASIGNATURA ('AS') o de TAREA ('AR'), nunca mixtos.
CREATE OR REPLACE FUNCTION academico_test.fn_criterio_prom_validar_nodo_obligatorias(
    p_nodo_curricular academico_test.nodo_curricular
)
RETURNS VOID LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_nodo_curricular IS DISTINCT FROM 'AS' AND p_nodo_curricular IS DISTINCT FROM 'AR' THEN
        RAISE EXCEPTION 'nodo_curricular debe ser AS o AR para guardar obligatorias'
            USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_criterio_prom_validar_asignatura_del_periodo(
    p_fk_periodo BIGINT, p_fk_asignatura BIGINT
)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_nombre VARCHAR(130);
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TASIGNATURA s
          JOIN academico_test.TAREA a ON a.PK_TAREA = s.FK_TAREA
         WHERE s.PK_TASIGNATURA = p_fk_asignatura AND s.ACTIVE = TRUE
           AND a.FK_TPERIODO_ACADEMICO = p_fk_periodo
    ) THEN
        SELECT s.NOMBRE INTO v_nombre FROM academico_test.TASIGNATURA s WHERE s.PK_TASIGNATURA = p_fk_asignatura;
        IF v_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'La asignatura "%" no esta activa o no pertenece al periodo', v_nombre
                USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'La asignatura no existe' USING ERRCODE = '23503';
        END IF;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_criterio_prom_validar_area_del_periodo(
    p_fk_periodo BIGINT, p_fk_area BIGINT
)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_nombre VARCHAR(130);
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TAREA
         WHERE PK_TAREA = p_fk_area AND ACTIVE = TRUE
           AND FK_TPERIODO_ACADEMICO = p_fk_periodo
    ) THEN
        SELECT NOMBRE INTO v_nombre FROM academico_test.TAREA WHERE PK_TAREA = p_fk_area;
        IF v_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'El area "%" no esta activa o no pertenece al periodo', v_nombre
                USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'El area no existe' USING ERRCODE = '23503';
        END IF;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_criterio_prom_validar_obligatoria_no_repetida(
    p_pk_criterio BIGINT, p_fk_asignatura BIGINT, p_fk_area BIGINT
)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_nombre VARCHAR(130);
BEGIN
    IF EXISTS (
        SELECT 1 FROM academico_test.TCRITERIO_PROMOCION_ASIGNATURA_OBLIGATORIA
         WHERE FK_TCRITERIO_PROMOCION = p_pk_criterio AND ACTIVE = TRUE
           AND FK_TASIGNATURA IS NOT DISTINCT FROM p_fk_asignatura
           AND FK_TAREA IS NOT DISTINCT FROM p_fk_area
    ) THEN
        IF p_fk_asignatura IS NOT NULL THEN
            SELECT NOMBRE INTO v_nombre FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_fk_asignatura;
            RAISE EXCEPTION 'La asignatura "%" ya esta en la lista de obligatorias', v_nombre
                USING ERRCODE = '23505';
        ELSE
            SELECT NOMBRE INTO v_nombre FROM academico_test.TAREA WHERE PK_TAREA = p_fk_area;
            RAISE EXCEPTION 'El area "%" ya esta en la lista de obligatorias', v_nombre
                USING ERRCODE = '23505';
        END IF;
    END IF;
END;
$$;

-- El orden es contrato: nodo, pertenencia al periodo, repetida.
CREATE OR REPLACE FUNCTION academico_test.fn_criterio_prom_validar_obligatoria(
    p_fk_periodo BIGINT, p_pk_criterio BIGINT,
    p_nodo_curricular academico_test.nodo_curricular, p_pk BIGINT
)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    PERFORM academico_test.fn_criterio_prom_validar_nodo_obligatorias(p_nodo_curricular);
    IF p_nodo_curricular = 'AS' THEN
        PERFORM academico_test.fn_criterio_prom_validar_asignatura_del_periodo(p_fk_periodo, p_pk);
        PERFORM academico_test.fn_criterio_prom_validar_obligatoria_no_repetida(p_pk_criterio, p_pk, NULL);
    ELSE
        PERFORM academico_test.fn_criterio_prom_validar_area_del_periodo(p_fk_periodo, p_pk);
        PERFORM academico_test.fn_criterio_prom_validar_obligatoria_no_repetida(p_pk_criterio, NULL, p_pk);
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_criterio_prom_validar_obligatoria(BIGINT, BIGINT, academico_test.nodo_curricular, BIGINT)
    IS 'Compone las fn_criterio_prom_validar_* de una asignatura (AS) o area (AR) obligatoria del criterio p_pk_criterio.';
