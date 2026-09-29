-- ===========================================================================
-- V504 - Prematricula (3/9): las validaciones del PRIMER endpoint (el plan).
--
--   fn_prematricula_periodos_actuales(ee, sede)   -> periodos del ano en curso
--   fn_prematricula_assert_periodo_siguiente(...) -> 22023 si no hay a donde
--
--   Solo validan. No leen matriculas, no crean nada, no miran permisos (de
--   eso se encarga la funcion general en la V507).
--
--
-- QUE ES "EL PERIODO ACADEMICO ACTUAL"
--   El del ano lectivo en curso, por nombre del ano. NO por fechas: un
--   periodo puede haber terminado en noviembre y la prematricula del ano
--   siguiente se hace justamente despues, con el periodo ya cerrado. Usar
--   BETWEEN fecha_inicio AND fecha_fin dejaria el proceso sin insumo en el
--   unico momento del ano en que se usa.
--
--   Un establecimiento tiene un TPERIODO_ACADEMICO por (sede, jornada), asi
--   que "el actual" son varios y por eso esto devuelve un conjunto.
--
--
-- POR QUE VALIDAR EL PERIODO SIGUIENTE ANTES DE TODO
--   Sin el, cada grupo resolveria destino NULL y el proceso entero seria una
--   lista de errores. Es mas util una sola excepcion al principio, con un
--   mensaje que diga que falta crear el periodo del ano que viene, que 40
--   grupos fallando uno por uno.
--
--   Basta con que UNA sede tenga periodo siguiente para dejar seguir: el plan
--   reporta por grupo y los grupos sin destino se ven ahi. Lo que se corta es
--   el caso en que no hay nada que hacer en ningun lado.
--
-- Idempotente: CREATE OR REPLACE.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1) Los periodos academicos del ano en curso de un establecimiento.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_prematricula_periodos_actuales(
    p_fk_testablecimiento  BIGINT,
    p_fk_tsede             BIGINT DEFAULT NULL
)
RETURNS TABLE (
    fk_tperiodo_academico  BIGINT,
    fk_tsede               BIGINT,
    fk_tlv_jornada         BIGINT,
    anio                   INT
)
LANGUAGE sql
STABLE
AS $$
    SELECT pa.PK_TPERIODO_ACADEMICO,
           pa.FK_TSEDE,
           pa.FK_TLV_JORNADA,
           al.NOMBRE::INT
      FROM academico_test.TPERIODO_ACADEMICO pa
      JOIN academico_test.TSEDE s
        ON s.PK_TSEDE = pa.FK_TSEDE
       AND s.ACTIVE   = TRUE
      JOIN academico_test.TANO_LECTIVO al
        ON al.PK_ANO_LECTIVO = pa.FK_TANO_LECTIVO
     WHERE pa.ACTIVE = TRUE
       AND s.FK_TESTABLECIMIENTO = p_fk_testablecimiento
       AND (p_fk_tsede IS NULL OR pa.FK_TSEDE = p_fk_tsede)
       AND al.NOMBRE ~ '^[0-9]{4}$'
       AND al.NOMBRE::INT = EXTRACT(YEAR FROM CURRENT_DATE)::INT
     ORDER BY pa.FK_TSEDE, pa.FK_TLV_JORNADA;
$$;

COMMENT ON FUNCTION academico_test.fn_prematricula_periodos_actuales(BIGINT, BIGINT)
    IS 'Periodos academicos ACTIVE del ano lectivo EN CURSO de un establecimiento, opcionalmente acotados a una sede. Son varios porque hay uno por (sede, jornada). "Actual" se decide por el nombre del ano lectivo y NO por el rango de fechas: la prematricula se hace al final del ano, con el periodo ya vencido, y filtrar por fechas dejaria el proceso sin insumo justo cuando se usa. TANO_LECTIVO.NOMBRE es VARCHAR y se valida con ~ antes de castear.';

-- ---------------------------------------------------------------------------
-- 2) Que exista a donde prematricular.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_prematricula_assert_periodo_siguiente(
    p_fk_testablecimiento  BIGINT,
    p_fk_tsede             BIGINT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_actuales   INT;
    v_con_sig    INT;
    v_ee_nombre  VARCHAR;
    v_sede_txt   VARCHAR := '';
BEGIN
    -- Los nombres para el mensaje. Estos dos SI se pueden resolver -- el
    -- establecimiento y la sede existen --, y un id suelto no le dice nada a
    -- quien lee el error. El COALESCE cubre el id que no existe: ahi el
    -- numero es lo unico que hay, y es mejor que un hueco.
    SELECT e.NOMBRE INTO v_ee_nombre
      FROM academico_test.TESTABLECIMIENTO e
     WHERE e.PK_ESTABLECIMIENTO = p_fk_testablecimiento;
    v_ee_nombre := COALESCE(v_ee_nombre,
                            'con identificador ' || p_fk_testablecimiento);

    IF p_fk_tsede IS NOT NULL THEN
        SELECT ' en la sede ' || s.NOMBRE INTO v_sede_txt
          FROM academico_test.TSEDE s
         WHERE s.PK_TSEDE = p_fk_tsede;
        v_sede_txt := COALESCE(v_sede_txt,
                               ' en la sede con identificador ' || p_fk_tsede);
    END IF;

    SELECT COUNT(*),
           COUNT(*) FILTER (
               WHERE academico_test.fn_prematricula_periodo_siguiente(
                         pa.fk_tperiodo_academico) IS NOT NULL)
      INTO v_actuales, v_con_sig
      FROM academico_test.fn_prematricula_periodos_actuales(
               p_fk_testablecimiento, p_fk_tsede) pa;

    IF v_actuales = 0 THEN
        RAISE EXCEPTION
            'El establecimiento % no tiene periodo academico del ano en curso (%)%',
            v_ee_nombre,
            EXTRACT(YEAR FROM CURRENT_DATE)::INT,
            v_sede_txt
            USING ERRCODE = '22023';
    END IF;

    IF v_con_sig = 0 THEN
        RAISE EXCEPTION
            'No se puede prematricular: falta crear el periodo academico del ano % para el establecimiento %. Creelo primero, con sus grados y grupos.',
            EXTRACT(YEAR FROM CURRENT_DATE)::INT + 1,
            v_ee_nombre
            USING ERRCODE = '22023';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_prematricula_assert_periodo_siguiente(BIGINT, BIGINT)
    IS 'Falla con 22023 si el establecimiento no tiene periodo academico del ano en curso, o si NINGUNO de esos periodos tiene su equivalente del ano siguiente. Se corta aca y no grupo por grupo porque sin periodo destino el proceso entero seria una lista de errores identicos; una sola excepcion al principio dice que hay que crear el periodo del ano que viene. Basta con que UNA sede lo tenga: los grupos sin destino se reportan despues, en el plan.';
