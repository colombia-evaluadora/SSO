-- ===========================================================================
-- V136 -- Validaciones de escritura de asistencia, una funcion por regla
-- (RETURNS VOID), para que los wrappers de V138 no las lleven en linea.
-- Por que aqui: Regla 74 -- un docente sin rol que administre solo escribe
-- (y lee) la asignatura que el mismo dicta; Regla 72 -- dia de clase segun
-- horario y excusa solo en inasistencia o tardanza. Incluye
-- fn_asistencia_periodo_estado (antes V220, consolidada en V136-V141).
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

-- Regla 72c: solo días con clase de la asignatura en el horario del grupo. Un
-- grupo sin horario cargado para la asignatura no tiene contra qué validar y pasa.
CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_validar_fecha_programada(
    p_fk_tgrupo      BIGINT,
    p_fk_tasignatura BIGINT,
    p_fecha          DATE,
    p_bloque         NUMERIC
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_fk_tasignatura IS NULL OR NOT EXISTS (
        SELECT 1 FROM academico_test.THORARIO
         WHERE FK_TGRUPO = p_fk_tgrupo AND FK_TASIGNATURA = p_fk_tasignatura AND ACTIVE = TRUE) THEN
        RETURN;
    END IF;
    IF EXISTS (SELECT 1
                 FROM academico_test.fn_asistencia_sesiones_programadas(
                          NULL, academico_test.fn_periodo_sede(academico_test.fn_grupo_periodo(p_fk_tgrupo)),
                          p_fecha, p_fecha, p_fk_tgrupo, p_fk_tasignatura, NULL) sp
                WHERE p_bloque IS NULL OR sp.bloque = p_bloque) THEN
        RETURN;
    END IF;
    RAISE EXCEPTION '% no tiene clase programada en el grupo % el %',
        COALESCE((SELECT NOMBRE FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_fk_tasignatura), 'La asignatura'),
        COALESCE((SELECT NOMBRE FROM academico_test.TGRUPO WHERE PK_TGRUPO = p_fk_tgrupo), ''),
        to_char(p_fecha, 'DD/MM/YYYY') || CASE WHEN p_bloque IS NULL THEN '' ELSE ' en el bloque ' || p_bloque END
        USING ERRCODE = '22023', HINT = 'Elija un día de clase según el horario del grupo';
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_validar_fecha_programada(BIGINT, BIGINT, DATE, NUMERIC)
    IS 'Regla 72c: 22023 si la asignatura no tiene clase programada (fn_asistencia_sesiones_programadas) en el grupo esa fecha, o en ese bloque. Sin asignatura o sin horario cargado para ella no valida. La usa fn_asistencia_registrar_bulk (V138).';

-- Regla 72b: la excusa acompaña una inasistencia o una llegada tarde, nunca un Asistió.
CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_validar_excusa_tipo(
    p_tipo_asistencia_valor NUMERIC,
    p_fk_soporte_archivo    BIGINT,
    p_fk_tmatricula         BIGINT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_fk_soporte_archivo IS NOT NULL AND p_tipo_asistencia_valor = 1 THEN
        RAISE EXCEPTION 'La excusa solo se adjunta a una inasistencia o a una llegada tarde: % está marcado como %',
            COALESCE(academico_test.fn_actividad_estudiante_nombre(p_fk_tmatricula), 'el estudiante'),
            COALESCE((SELECT NOMBRE FROM academico_test.TLISTA_VALOR
                       WHERE PK_LISTA_VALOR = academico_test.fn_asistencia_tipo_pk(1)), 'Asistió')
            USING ERRCODE = '22023';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_validar_excusa_tipo(NUMERIC, BIGINT, BIGINT)
    IS 'Regla 72b: 22023 si se adjunta excusa a un registro de tipo Asistió (TIPO_ASISTENCIA VALOR 1). La usan fn_asistencia_validar_excusa_registros y fn_asistencia_editar (V138).';

CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_validar_excusa_registros(
    p_registros          JSONB,
    p_marcar_todos_valor NUMERIC
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_r JSONB;
BEGIN
    IF p_registros IS NULL OR jsonb_typeof(p_registros) <> 'array' THEN
        RETURN;
    END IF;
    FOR v_r IN SELECT * FROM jsonb_array_elements(p_registros) LOOP
        PERFORM academico_test.fn_asistencia_validar_excusa_tipo(
            COALESCE((v_r->>'tipoAsistencia')::NUMERIC, p_marcar_todos_valor),
            NULLIF(v_r->>'fkArchivo', '')::BIGINT,
            (v_r->>'fkMatricula')::BIGINT);
    END LOOP;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_validar_excusa_registros(JSONB, NUMERIC)
    IS 'Regla 72b sobre cada registro de p_registros (fn_asistencia_validar_excusa_tipo). La usa fn_asistencia_registrar_bulk (V138).';

-- ---------------------------------------------------------------------------
-- Lectura (Regla 74): el docente solo ve las asignaturas que dicta en el grupo
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_puede_ver_asignatura(
    p_pk_usuario     BIGINT,
    p_fk_tgrupo      BIGINT,
    p_fk_tasignatura BIGINT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    -- Solo se angosta el nivel 3 "solo sus grupos" que no dirige el grupo: el
    -- docente. Director de grupo y coordinación conservan el alcance de V140.
    RETURN academico_test.fn_asistencia_puede_ver(p_pk_usuario, p_fk_tgrupo)
       AND (p_pk_usuario IS NULL OR p_fk_tasignatura IS NULL
            OR COALESCE(academico_test.fn_usuario_categoria_rol_nivel(p_pk_usuario), 99) <> 3
            OR NOT academico_test.fn_usuario_solo_sus_grupos(p_pk_usuario)
            OR p_fk_tgrupo IN (SELECT grupo_id FROM academico_test.fn_usuario_grupos_dirigidos(p_pk_usuario))
            OR EXISTS (SELECT 1
                         FROM academico_test.TDOCENTE_ASIGNATURA da
                         JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = da.FK_TFUNCIONARIO
                        WHERE f.FK_TUSUARIO = p_pk_usuario AND f.ACTIVE = TRUE
                          AND da.FK_TGRUPO = p_fk_tgrupo AND da.FK_TASIGNATURA = p_fk_tasignatura
                          AND da.ACTIVE = TRUE));
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_puede_ver_asignatura(BIGINT, BIGINT, BIGINT)
    IS 'Regla 74, BOOLEAN para el WHERE de las lecturas de asistencia: fn_asistencia_puede_ver (V140) y, para el docente (nivel 3 solo-sus-grupos que no dirige el grupo), además que dicte esa asignatura en el grupo (TDOCENTE_ASIGNATURA). Asignatura NULL (toma por actividad) = alcance del grupo. plpgsql: depende de funciones posteriores (V140, V489).';

CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_assert_puede_ver(
    p_pk_usuario     BIGINT,
    p_fk_tgrupo      BIGINT,
    p_fk_tasignatura BIGINT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF NOT academico_test.fn_asistencia_puede_ver_asignatura(p_pk_usuario, p_fk_tgrupo, p_fk_tasignatura) THEN
        RAISE EXCEPTION 'No tiene permiso para ver la asistencia del grupo %',
            COALESCE((SELECT NOMBRE FROM academico_test.TGRUPO WHERE PK_TGRUPO = p_fk_tgrupo), p_fk_tgrupo::TEXT)
            USING ERRCODE = '42501';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_assert_puede_ver(BIGINT, BIGINT, BIGINT)
    IS 'Gate de lectura de asistencia (Regla 74): 42501 si fn_asistencia_puede_ver_asignatura es falso; sin asignatura, alcance del grupo. La usan fn_asistencia_estudiantes_sesion, fn_asistencia_asignaturas_sesion y fn_asistencia_actividades_dia (V141).';
