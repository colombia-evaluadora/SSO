-- ===========================================================================
-- V136 -- Validaciones de escritura de asistencia, una funcion por regla
-- (RETURNS VOID), para que los wrappers de V138 no las lleven en linea.
-- Por que aqui: Regla 74 -- un docente sin rol que administre solo escribe
-- la asignatura que el mismo dicta; el gate actual solo valida capability +
-- alcance territorial, no eso. Incluye fn_asistencia_periodo_estado, que
-- vivia en V220 (eliminada: su contenido quedo consolidado en V136-V141).
-- Depende de: TGRUPO/TGRADO/TPERIODO_ACADEMICO/TLISTA_VALOR/TASIGNATURA/
-- TACTIVIDAD/TDOCENTE_ASIGNATURA/TFUNCIONARIO (V22), V29 (fn_usuario_es_docente_puro).
-- ===========================================================================

SET search_path TO academico_test, public;

-- Definicion sin cambios respecto a la V220 original (eliminada).
CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_periodo_estado(
    p_fk_tgrupo BIGINT
)
RETURNS TABLE (
    fk_tperiodo_academico BIGINT,
    estado_valor          VARCHAR,
    estado_nombre         VARCHAR
)
LANGUAGE sql STABLE AS $$
    SELECT pa.PK_TPERIODO_ACADEMICO,
           lv.VALOR::VARCHAR,
           lv.NOMBRE::VARCHAR
      FROM academico_test.TGRUPO gr
      JOIN academico_test.TGRADO g              ON g.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
 LEFT JOIN academico_test.TLISTA_VALOR lv       ON lv.PK_LISTA_VALOR = pa.FK_TLV_ESTADO
                                              AND lv.CATEGORIA = 'ESTADOPERIODO'
     WHERE gr.PK_TGRUPO = p_fk_tgrupo AND gr.ACTIVE = TRUE;
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_periodo_estado(BIGINT)
    IS 'Periodo academico del grupo y su estado ESTADOPERIODO (VALOR/NOMBRE). estado_valor = ''C'' -> Cerrado. NULL en estado_* si el periodo no tiene estado clasificado. Copia identica de V220, redefinida aqui (V136) para trazabilidad -- la usa fn_asistencia_validar_periodo_abierto.';

CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_validar_contexto(
    p_fk_tgrupo      BIGINT,
    p_fk_tasignatura BIGINT,
    p_fk_tactividad  BIGINT DEFAULT NULL
)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF p_fk_tgrupo IS NULL THEN
        RAISE EXCEPTION 'grupo es obligatorio' USING ERRCODE = '23502';
    END IF;
    IF p_fk_tasignatura IS NULL AND p_fk_tactividad IS NULL THEN
        RAISE EXCEPTION 'debe enviar la asignatura (sesion por horario) o la actividad (sesion formativa)'
            USING ERRCODE = '23502';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM academico_test.TGRUPO
                    WHERE PK_TGRUPO = p_fk_tgrupo AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'grupo (%) no existe o no esta activo', p_fk_tgrupo USING ERRCODE = '23503';
    END IF;
    IF p_fk_tasignatura IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM academico_test.TASIGNATURA
                        WHERE PK_TASIGNATURA = p_fk_tasignatura AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'asignatura (%) no existe o no esta activa', p_fk_tasignatura USING ERRCODE = '23503';
    END IF;
    -- La actividad debe ser DE ESTE GRUPO: el gate autoriza sobre el grupo,
    -- no sobre la actividad.
    IF p_fk_tactividad IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM academico_test.TACTIVIDAD
                        WHERE PK_TACTIVIDAD = p_fk_tactividad AND ACTIVE = TRUE
                          AND FK_TGRUPO = p_fk_tgrupo) THEN
        RAISE EXCEPTION 'la actividad (%) no existe, no esta activa o no pertenece al grupo %',
            p_fk_tactividad, p_fk_tgrupo USING ERRCODE = '23503';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_validar_contexto(BIGINT, BIGINT, BIGINT)
    IS 'Grupo activo + (asignatura o actividad activa del mismo grupo). La usa fn_asistencia_registrar_bulk (V138).';

CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_validar_periodo_abierto(
    p_fk_tgrupo BIGINT,
    p_accion    VARCHAR DEFAULT 'registrar'
)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_estado RECORD;
BEGIN
    SELECT * INTO v_estado FROM academico_test.fn_asistencia_periodo_estado(p_fk_tgrupo);
    IF v_estado.estado_valor = 'C' THEN
        RAISE EXCEPTION 'el periodo academico del grupo % esta %; no se puede % la asistencia',
            p_fk_tgrupo, COALESCE(v_estado.estado_nombre, 'Cerrado'), p_accion
            USING ERRCODE = '22023',
                  HINT = 'Reabrir el periodo academico para permitir cambios de asistencia.';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_validar_periodo_abierto(BIGINT, VARCHAR)
    IS 'Lanza 22023 si el periodo academico del grupo esta Cerrado. La usan fn_asistencia_registrar_bulk y fn_asistencia_editar (V138).';

CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_validar_fecha_no_futura(
    p_fecha DATE
)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF p_fecha > CURRENT_DATE THEN
        RAISE EXCEPTION 'no se puede registrar asistencia en una fecha futura (%); la fecha maxima es hoy (%)',
            p_fecha, CURRENT_DATE
            USING ERRCODE = '22023',
                  HINT = 'Registre la asistencia el dia de la clase o despues.';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_validar_fecha_no_futura(DATE)
    IS 'Regla de V464 extraida a funcion propia: no se toma asistencia de una clase que no ha ocurrido. La usa fn_asistencia_registrar_bulk (V138).';

CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_validar_docente_asignado(
    p_pk_usuario     BIGINT,
    p_fk_tgrupo      BIGINT,
    p_fk_tasignatura BIGINT,
    p_fk_tactividad  BIGINT DEFAULT NULL
)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_funcionario BIGINT;
    v_asignatura  BIGINT;
BEGIN
    IF COALESCE(academico_test.fn_usuario_categoria_rol_nivel(p_pk_usuario), 4) <= 2 THEN
        RETURN;
    END IF;

    v_asignatura := COALESCE(p_fk_tasignatura,
        (SELECT FK_TASIGNATURA FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_fk_tactividad));

    SELECT PK_TFUNCIONARIO INTO v_funcionario
      FROM academico_test.TFUNCIONARIO WHERE FK_TUSUARIO = p_pk_usuario AND ACTIVE = TRUE;

    IF v_funcionario IS NULL OR v_asignatura IS NULL OR NOT EXISTS (
        SELECT 1 FROM academico_test.TDOCENTE_ASIGNATURA
         WHERE FK_TFUNCIONARIO = v_funcionario AND FK_TGRUPO = p_fk_tgrupo
           AND FK_TASIGNATURA = v_asignatura AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'no tiene asignada la asignatura % en el grupo % para registrar/editar asistencia',
            v_asignatura, p_fk_tgrupo USING ERRCODE = '42501';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_validar_docente_asignado(BIGINT, BIGINT, BIGINT, BIGINT)
    IS 'Regla 74: salvo nivel administrativo real (categoria <= 2), exige TDOCENTE_ASIGNATURA activa para (funcionario, grupo, asignatura) -- aplica igual a un docente que ademas es director de grupo/coordinador/jefe de area. La usan fn_asistencia_registrar_bulk y fn_asistencia_editar (V138); fn_asistencia_editar_bulk (V438) la hereda porque llama a fn_asistencia_editar por cada pk.';
