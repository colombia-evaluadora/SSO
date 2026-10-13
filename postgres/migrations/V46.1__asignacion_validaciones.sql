-- ===========================================================================
-- V46.1 -- Asignacion academica: validaciones
-- ===========================================================================
-- QUE HACE: una fn_asignacion_validar_<regla> por regla (RETURNS VOID, lanza
-- o nada) y fn_asignacion_validar_par, que las compone para cada par
-- "grupoId:asignaturaId" que llega a fn_asignacion_guardar.
-- POR QUE AQUI: capa 1 del modulo (V46.1 validaciones / V46.2 nucleos /
-- V46.3 wrappers); los endpoints siguen en V92 porque necesitan eval-col (V47).
-- DEPENDE DE: V22 (TPERIODO_ACADEMICO, TFUNCIONARIO, TDOCENTE_ASIGNATURA, plan).
-- ===========================================================================

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_asignacion_validar_periodo_existe(p_fk_periodo BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM academico_test.TPERIODO_ACADEMICO WHERE PK_TPERIODO_ACADEMICO = p_fk_periodo) THEN
        RAISE EXCEPTION 'El periodo academico no existe' USING ERRCODE = 'P0002';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_asignacion_validar_periodo_activo(p_fk_periodo BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_nombre TEXT;
BEGIN
    SELECT NOMBRE INTO v_nombre
      FROM academico_test.TPERIODO_ACADEMICO WHERE PK_TPERIODO_ACADEMICO = p_fk_periodo AND ACTIVE = FALSE;
    IF FOUND THEN
        RAISE EXCEPTION 'El periodo academico "%" existe pero esta inactivo', v_nombre USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_asignacion_validar_funcionario(p_fk_funcionario BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_nombre TEXT;
BEGIN
    IF EXISTS (SELECT 1 FROM academico_test.TFUNCIONARIO
                WHERE PK_TFUNCIONARIO = p_fk_funcionario AND ACTIVE = TRUE) THEN
        RETURN;
    END IF;
    SELECT TRIM(concat_ws(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE, u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO))
      INTO v_nombre
      FROM academico_test.TFUNCIONARIO f
      JOIN academico_test.TUSUARIO u ON u.PK_TUSUARIO = f.FK_TUSUARIO
     WHERE f.PK_TFUNCIONARIO = p_fk_funcionario;
    IF v_nombre IS NOT NULL THEN
        RAISE EXCEPTION 'El funcionario "%" existe pero esta inactivo', v_nombre USING ERRCODE = '23503';
    END IF;
    RAISE EXCEPTION 'No existe un funcionario con el id proporcionado' USING ERRCODE = '23503';
END;
$$;

-- Formato "grupoId:asignaturaId" (ambos numericos).
CREATE OR REPLACE FUNCTION academico_test.fn_asignacion_validar_formato(p_pair TEXT)
RETURNS VOID LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_pair !~ '^[0-9]+:[0-9]+$' THEN
        RAISE EXCEPTION 'Identificador de asignacion invalido: %', p_pair USING ERRCODE = '22023';
    END IF;
END;
$$;

-- La asignatura tiene que estar en un plan activo del grado del grupo, dentro del periodo.
CREATE OR REPLACE FUNCTION academico_test.fn_asignacion_validar_asignatura_del_grupo(
    p_fk_periodo BIGINT, p_fk_grupo BIGINT, p_fk_asignatura BIGINT
)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
          FROM academico_test.TGRUPO gr
          JOIN academico_test.TGRADO g ON g.PK_TGRADO = gr.FK_TGRADO AND g.ACTIVE = TRUE
               AND g.FK_TPERIODO_ACADEMICO = p_fk_periodo
          JOIN academico_test.TPLAN pl ON pl.FK_TGRADO = g.PK_TGRADO AND pl.ACTIVE = TRUE
          JOIN academico_test.TASIGNATURA_PLAN ap ON ap.FK_TPLAN = pl.PK_TPLAN
               AND ap.FK_TASIGNATURA = p_fk_asignatura AND ap.ACTIVE = TRUE
          JOIN academico_test.TASIGNATURA s ON s.PK_TASIGNATURA = p_fk_asignatura AND s.ACTIVE = TRUE
         WHERE gr.PK_TGRUPO = p_fk_grupo AND gr.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'La asignatura % no corresponde al grupo % en el plan de estudio del periodo.',
            (SELECT a.NOMBRE FROM academico_test.TASIGNATURA a WHERE a.PK_TASIGNATURA = p_fk_asignatura),
            (SELECT format('%s del grado %s', gr.NOMBRE, g.NOMBRE)
                   FROM academico_test.TGRUPO gr
                   JOIN academico_test.TGRADO g ON g.PK_TGRADO = gr.FK_TGRADO
                  WHERE gr.PK_TGRUPO = p_fk_grupo)
            USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_asignacion_validar_sin_otro_docente(
    p_fk_periodo BIGINT, p_fk_grupo BIGINT, p_fk_asignatura BIGINT, p_fk_funcionario BIGINT
)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_asig TEXT; v_grupo TEXT;
BEGIN
    IF EXISTS (
        SELECT 1 FROM academico_test.TDOCENTE_ASIGNATURA
         WHERE FK_TGRUPO = p_fk_grupo AND FK_TASIGNATURA = p_fk_asignatura
           AND FK_TPERIODO_ACADEMICO = p_fk_periodo AND ACTIVE = TRUE
           AND FK_TFUNCIONARIO <> p_fk_funcionario
    ) THEN
        SELECT s.NOMBRE, g.NOMBRE || ' ' || gr.NOMBRE INTO v_asig, v_grupo
          FROM academico_test.TASIGNATURA s
          JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = p_fk_grupo
          JOIN academico_test.TGRADO g ON g.PK_TGRADO = gr.FK_TGRADO
         WHERE s.PK_TASIGNATURA = p_fk_asignatura;
        RAISE EXCEPTION 'La asignatura "%" en el grupo "%" ya esta asignada a otro docente en el periodo',
            v_asig, v_grupo USING ERRCODE = '23505';
    END IF;
END;
$$;

-- El nucleo desactiva antes la asignacion del docente: lo que encuentre aqui vino en este mismo lote.
CREATE OR REPLACE FUNCTION academico_test.fn_asignacion_validar_no_duplicada(
    p_fk_periodo BIGINT, p_fk_grupo BIGINT, p_fk_asignatura BIGINT, p_fk_funcionario BIGINT
)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_asig TEXT; v_grupo TEXT;
BEGIN
    IF EXISTS (
        SELECT 1 FROM academico_test.TDOCENTE_ASIGNATURA
         WHERE FK_TGRUPO = p_fk_grupo AND FK_TASIGNATURA = p_fk_asignatura
           AND FK_TPERIODO_ACADEMICO = p_fk_periodo AND ACTIVE = TRUE
           AND FK_TFUNCIONARIO = p_fk_funcionario
    ) THEN
        SELECT s.NOMBRE, g.NOMBRE || ' ' || gr.NOMBRE INTO v_asig, v_grupo
          FROM academico_test.TASIGNATURA s
          JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = p_fk_grupo
          JOIN academico_test.TGRADO g ON g.PK_TGRADO = gr.FK_TGRADO
         WHERE s.PK_TASIGNATURA = p_fk_asignatura;
        RAISE EXCEPTION 'La asignatura "%" en el grupo "%" esta duplicada en la asignacion',
            v_asig, v_grupo USING ERRCODE = '23505';
    END IF;
END;
$$;

-- El orden es contrato: pertenencia al plan, ocupada por otro docente, duplicada.
CREATE OR REPLACE FUNCTION academico_test.fn_asignacion_validar_par(
    p_fk_periodo BIGINT, p_fk_funcionario BIGINT, p_fk_grupo BIGINT, p_fk_asignatura BIGINT
)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    PERFORM academico_test.fn_asignacion_validar_asignatura_del_grupo(p_fk_periodo, p_fk_grupo, p_fk_asignatura);
    PERFORM academico_test.fn_asignacion_validar_sin_otro_docente(p_fk_periodo, p_fk_grupo, p_fk_asignatura, p_fk_funcionario);
    PERFORM academico_test.fn_asignacion_validar_no_duplicada(p_fk_periodo, p_fk_grupo, p_fk_asignatura, p_fk_funcionario);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asignacion_validar_par(BIGINT, BIGINT, BIGINT, BIGINT)
    IS 'Compone las fn_asignacion_validar_* de un par grupo:asignatura. La usa fn_asignacion_guardar_interno.';
