-- ===========================================================================
-- V37.1 -- Periodo academico: validaciones
-- ===========================================================================
-- QUE HACE: una fn_periodo_validar_<regla> / fn_descanso_validar_<regla> por
-- regla (RETURNS VOID, lanza o nada) y fn_periodo_validar, que compone las de
-- fechas y horario que comparten crear y actualizar.
-- POR QUE AQUI: capa 1 del modulo (V37.1 validaciones / V37.2 nucleos /
-- V37.3 wrappers); los endpoints siguen en V75 porque necesitan eval-col (V47).
-- DEPENDE DE: V22 (TPERIODO_ACADEMICO, TDESCANSOS, TSEDE, cascada academica).
-- ===========================================================================

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_validar_existe(p_pk BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM academico_test.TPERIODO_ACADEMICO WHERE PK_TPERIODO_ACADEMICO = p_pk) THEN
        RAISE EXCEPTION 'No existe el periodo academico' USING ERRCODE = 'P0002';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_validar_activo(p_pk BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_nombre VARCHAR(200);
BEGIN
    SELECT NOMBRE INTO v_nombre
      FROM academico_test.TPERIODO_ACADEMICO
     WHERE PK_TPERIODO_ACADEMICO = p_pk AND ACTIVE = FALSE;
    IF FOUND THEN
        RAISE EXCEPTION 'El periodo academico "%" esta inactivo; no se puede actualizar', v_nombre
            USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_validar_campos(
    p_fk_sede BIGINT, p_fk_estado BIGINT, p_fecha_inicio DATE, p_fecha_fin DATE,
    p_fecha_limite_matricula DATE, p_fk_jornada BIGINT, p_hora_inicio TIME, p_hora_fin TIME
)
RETURNS VOID LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_fk_sede IS NULL OR p_fk_estado IS NULL OR p_fecha_inicio IS NULL
       OR p_fecha_fin IS NULL OR p_fecha_limite_matricula IS NULL
       OR p_fk_jornada IS NULL OR p_hora_inicio IS NULL OR p_hora_fin IS NULL THEN
        RAISE EXCEPTION 'Faltan campos obligatorios del periodo academico' USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_validar_fechas(p_fecha_inicio DATE, p_fecha_fin DATE)
RETURNS VOID LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_fecha_fin <= p_fecha_inicio THEN
        RAISE EXCEPTION 'La fecha fin (%) debe ser posterior a la fecha inicio (%)',
            p_fecha_fin, p_fecha_inicio USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_validar_limite_matricula(
    p_fecha_limite DATE, p_fecha_inicio DATE, p_fecha_fin DATE
)
RETURNS VOID LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_fecha_limite < p_fecha_inicio OR p_fecha_limite > p_fecha_fin THEN
        RAISE EXCEPTION 'La fecha limite de matricula (%) debe estar entre inicio (%) y fin (%)',
            p_fecha_limite, p_fecha_inicio, p_fecha_fin USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_validar_horario(p_hora_inicio TIME, p_hora_fin TIME)
RETURNS VOID LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_hora_fin < p_hora_inicio THEN
        RAISE EXCEPTION 'La hora fin (%) no puede ser anterior a la hora inicio (%)',
            p_hora_fin, p_hora_inicio USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_validar_sede(p_fk_sede BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_nombre VARCHAR(130); v_active BOOLEAN;
BEGIN
    SELECT NOMBRE, ACTIVE INTO v_nombre, v_active FROM academico_test.TSEDE WHERE PK_TSEDE = p_fk_sede;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La sede seleccionada no existe' USING ERRCODE = '23503';
    ELSIF NOT v_active THEN
        RAISE EXCEPTION 'La sede "%" existe pero esta inactiva', v_nombre USING ERRCODE = '23503';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_validar_sede_mismo_establecimiento(
    p_fk_sede_actual BIGINT, p_fk_sede_nueva BIGINT
)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF (SELECT FK_TESTABLECIMIENTO FROM academico_test.TSEDE WHERE PK_TSEDE = p_fk_sede_nueva)
       <> (SELECT FK_TESTABLECIMIENTO FROM academico_test.TSEDE WHERE PK_TSEDE = p_fk_sede_actual) THEN
        RAISE EXCEPTION 'No se puede mover el periodo a una sede de otro establecimiento'
            USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_validar_anterior_distinto(
    p_pk BIGINT, p_fk_periodo_anterior BIGINT
)
RETURNS VOID LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_fk_periodo_anterior = p_pk THEN
        RAISE EXCEPTION 'Un periodo academico no puede ser su propio periodo anterior'
            USING ERRCODE = '22023';
    END IF;
END;
$$;

-- El anterior debe estar activo y ser del mismo establecimiento. NULL = sin anterior.
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_validar_anterior(
    p_fk_periodo_anterior BIGINT, p_fk_establecimiento BIGINT
)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_nombre TEXT;
BEGIN
    IF p_fk_periodo_anterior IS NULL THEN RETURN; END IF;
    PERFORM 1
      FROM academico_test.TPERIODO_ACADEMICO pa
      JOIN academico_test.TSEDE se ON se.PK_TSEDE = pa.FK_TSEDE
     WHERE pa.PK_TPERIODO_ACADEMICO = p_fk_periodo_anterior
       AND pa.ACTIVE = TRUE
       AND se.FK_TESTABLECIMIENTO = p_fk_establecimiento;
    IF NOT FOUND THEN
        SELECT NOMBRE INTO v_nombre FROM academico_test.TPERIODO_ACADEMICO
         WHERE PK_TPERIODO_ACADEMICO = p_fk_periodo_anterior;
        IF v_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'El periodo academico anterior "%" existe pero esta inactivo o pertenece a otro establecimiento',
                v_nombre USING ERRCODE = '22023';
        ELSE
            RAISE EXCEPTION 'El periodo academico anterior seleccionado no existe' USING ERRCODE = '22023';
        END IF;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_validar_estado(p_fk_estado BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_valor TEXT; v_categoria VARCHAR(30);
BEGIN
    SELECT VALOR, CATEGORIA INTO v_valor, v_categoria
      FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_fk_estado;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El estado seleccionado no existe' USING ERRCODE = '23503';
    END IF;
    IF v_categoria <> 'ESTADOPERIODO' THEN
        RAISE EXCEPTION 'El estado "%" no pertenece a la categoria ESTADOPERIODO (es %)',
            v_valor, v_categoria USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_validar_jornada(p_fk_jornada BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_valor TEXT; v_categoria VARCHAR(30);
BEGIN
    SELECT VALOR, CATEGORIA INTO v_valor, v_categoria
      FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_fk_jornada;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La jornada seleccionada no existe' USING ERRCODE = '23503';
    END IF;
    IF v_categoria <> 'JORNADA' THEN
        RAISE EXCEPTION 'La jornada "%" no pertenece a la categoria JORNADA (es %)',
            v_valor, v_categoria USING ERRCODE = '22023';
    END IF;
END;
$$;

-- Un solo periodo activo por (año, sede, jornada): mañana y tarde pueden coexistir.
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_validar_unico_jornada(
    p_fk_ano_lectivo BIGINT, p_fk_sede BIGINT, p_fk_jornada BIGINT, p_pk_excluir BIGINT DEFAULT NULL
)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM academico_test.TPERIODO_ACADEMICO
         WHERE FK_TANO_LECTIVO = p_fk_ano_lectivo AND FK_TSEDE = p_fk_sede
           AND FK_TLV_JORNADA = p_fk_jornada AND ACTIVE = TRUE
           AND PK_TPERIODO_ACADEMICO <> COALESCE(p_pk_excluir, -1)
    ) THEN
        RAISE EXCEPTION 'La sede "%" ya tiene un periodo academico activo en la jornada "%" para el año lectivo %',
            (SELECT NOMBRE FROM academico_test.TSEDE WHERE PK_TSEDE = p_fk_sede),
            (SELECT VALOR FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_fk_jornada),
            (SELECT NOMBRE FROM academico_test.TANO_LECTIVO WHERE PK_ANO_LECTIVO = p_fk_ano_lectivo)
            USING ERRCODE = '23505';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_validar_descansos_pares(
    p_descanso_inicio TIME[], p_descanso_fin TIME[]
)
RETURNS VOID LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_descanso_fin IS NULL
       OR COALESCE(array_length(p_descanso_inicio, 1), 0) <> COALESCE(array_length(p_descanso_fin, 1), 0) THEN
        RAISE EXCEPTION 'Los arreglos de inicio/fin de descansos deben tener la misma longitud'
            USING ERRCODE = '22023';
    END IF;
END;
$$;

-- Set de descansos del formulario: pares, cada uno con fin >= inicio, dentro
-- del horario y sin traslaparse entre si. Los mensajes citan la posicion.
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_validar_descansos(
    p_descanso_inicio TIME[], p_descanso_fin TIME[], p_hora_inicio TIME, p_hora_fin TIME
)
RETURNS VOID LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE i INT; j INT;
BEGIN
    PERFORM academico_test.fn_periodo_validar_descansos_pares(p_descanso_inicio, p_descanso_fin);
    IF array_length(p_descanso_inicio, 1) IS NULL THEN RETURN; END IF;
    FOR i IN 1 .. array_length(p_descanso_inicio, 1) LOOP
        IF p_descanso_fin[i] < p_descanso_inicio[i] THEN
            RAISE EXCEPTION 'Descanso %: hora fin anterior a inicio', i USING ERRCODE = '22023';
        END IF;
        IF p_descanso_inicio[i] < p_hora_inicio OR p_descanso_fin[i] > p_hora_fin THEN
            RAISE EXCEPTION 'Descanso % (% a %) fuera del horario del periodo (% a %)',
                i, p_descanso_inicio[i], p_descanso_fin[i], p_hora_inicio, p_hora_fin
                USING ERRCODE = '22023';
        END IF;
        FOR j IN 1 .. i - 1 LOOP
            IF p_descanso_inicio[i] < p_descanso_fin[j] AND p_descanso_fin[i] > p_descanso_inicio[j] THEN
                RAISE EXCEPTION 'Los descansos % y % se traslapan', j, i USING ERRCODE = '22023';
            END IF;
        END LOOP;
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_validar_descansos_en_horario(
    p_pk BIGINT, p_hora_inicio TIME, p_hora_fin TIME
)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM academico_test.TDESCANSOS
         WHERE FK_TPERIODO_ACADEMICO = p_pk AND ACTIVE = TRUE
           AND (HORA_INICIO < p_hora_inicio OR HORA_FIN > p_hora_fin)
    ) THEN
        RAISE EXCEPTION 'El nuevo horario (% a %) deja descansos existentes fuera de rango; ajustelos primero',
            p_hora_inicio, p_hora_fin USING ERRCODE = '22023';
    END IF;
END;
$$;

-- Lo que bloquea la baja; criterios, promocion y descansos se arrastran en el nucleo.
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_validar_sin_dependientes(p_pk BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_nombre VARCHAR(200); v_que TEXT;
BEGIN
    v_que := CASE
        WHEN EXISTS (SELECT 1 FROM academico_test.THORARIO h
                       JOIN academico_test.TGRUPO g ON g.PK_TGRUPO = h.FK_TGRUPO AND g.ACTIVE = TRUE
                       JOIN academico_test.TGRADO gr ON gr.PK_TGRADO = g.FK_TGRADO AND gr.ACTIVE = TRUE
                      WHERE gr.FK_TPERIODO_ACADEMICO = p_pk AND h.ACTIVE = TRUE)
            THEN 'existen horarios/asistencias configurados'
        WHEN EXISTS (SELECT 1 FROM academico_test.TPLAN pl
                       JOIN academico_test.TGRADO gr ON gr.PK_TGRADO = pl.FK_TGRADO AND gr.ACTIVE = TRUE
                      WHERE gr.FK_TPERIODO_ACADEMICO = p_pk AND pl.ACTIVE = TRUE)
            THEN 'existen planes de estudio asociados'
        WHEN EXISTS (SELECT 1 FROM academico_test.TPERIODO_EVALUACION pe
                      WHERE pe.FK_TPERIODO_ACADEMICO = p_pk AND pe.ACTIVE = TRUE)
            THEN 'existen periodos de evaluacion asociados'
        WHEN EXISTS (SELECT 1 FROM academico_test.TNIVEL_ESCALA ne
                      WHERE ne.FK_PERIODO_ACADEMICO = p_pk AND ne.ACTIVE = TRUE)
            THEN 'existen escalas de valoracion asociadas'
        WHEN EXISTS (SELECT 1 FROM academico_test.TDOCENTE_ASIGNATURA da
                      WHERE da.FK_TPERIODO_ACADEMICO = p_pk AND da.ACTIVE = TRUE)
            THEN 'existen asignaciones academicas asociadas'
        WHEN EXISTS (SELECT 1 FROM academico_test.TAREA t
                      WHERE t.FK_TPERIODO_ACADEMICO = p_pk AND t.ACTIVE = TRUE)
            THEN 'existen areas academicas configuradas'
        WHEN EXISTS (SELECT 1 FROM academico_test.TGRADO gr
                      WHERE gr.FK_TPERIODO_ACADEMICO = p_pk AND gr.ACTIVE = TRUE)
            THEN 'existen grados/grupos configurados'
    END;
    IF v_que IS NULL THEN RETURN; END IF;
    SELECT s.NOMBRE || ' - ' || al.NOMBRE || ' - ' || jor.NOMBRE INTO v_nombre
      FROM academico_test.TPERIODO_ACADEMICO pa
      JOIN academico_test.TSEDE s          ON s.PK_TSEDE = pa.FK_TSEDE
      JOIN academico_test.TANO_LECTIVO al  ON al.PK_ANO_LECTIVO = pa.FK_TANO_LECTIVO
      JOIN academico_test.TLISTA_VALOR jor ON jor.PK_LISTA_VALOR = pa.FK_TLV_JORNADA
     WHERE pa.PK_TPERIODO_ACADEMICO = p_pk;
    RAISE EXCEPTION 'No se puede eliminar el periodo academico "%": %', v_nombre, v_que
        USING ERRCODE = '23503';
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_descanso_validar_existe(p_pk BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM academico_test.TDESCANSOS WHERE PK_TDESCANSOS = p_pk) THEN
        RAISE EXCEPTION 'El descanso seleccionado no existe' USING ERRCODE = 'P0002';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_descanso_validar_activo(p_pk BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_hi TIME; v_hf TIME;
BEGIN
    SELECT HORA_INICIO, HORA_FIN INTO v_hi, v_hf
      FROM academico_test.TDESCANSOS WHERE PK_TDESCANSOS = p_pk AND ACTIVE = FALSE;
    IF FOUND THEN
        RAISE EXCEPTION 'El descanso de % a % existe pero ya esta inactivo', v_hi, v_hf
            USING ERRCODE = 'P0002';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_descanso_validar_rango(p_hora_inicio TIME, p_hora_fin TIME)
RETURNS VOID LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_hora_fin < p_hora_inicio THEN
        RAISE EXCEPTION 'La hora fin del descanso no puede ser anterior a la inicio' USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_descanso_validar_dentro_periodo(
    p_fk_periodo BIGINT, p_hora_inicio TIME, p_hora_fin TIME
)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_pi TIME; v_pf TIME;
BEGIN
    SELECT HORA_INICIO, HORA_FIN INTO v_pi, v_pf
      FROM academico_test.TPERIODO_ACADEMICO WHERE PK_TPERIODO_ACADEMICO = p_fk_periodo;
    IF p_hora_inicio < v_pi OR p_hora_fin > v_pf THEN
        RAISE EXCEPTION 'El descanso (% a %) debe estar dentro del horario del periodo (% a %)',
            p_hora_inicio, p_hora_fin, v_pi, v_pf USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_descanso_validar_sin_traslape(
    p_fk_periodo BIGINT, p_hora_inicio TIME, p_hora_fin TIME
)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM academico_test.TDESCANSOS
         WHERE FK_TPERIODO_ACADEMICO = p_fk_periodo AND ACTIVE = TRUE
           AND p_hora_inicio < HORA_FIN AND p_hora_fin > HORA_INICIO
    ) THEN
        RAISE EXCEPTION 'El descanso (% a %) se traslapa con otro descanso existente',
            p_hora_inicio, p_hora_fin USING ERRCODE = '22023';
    END IF;
END;
$$;

-- Fechas y horario del periodo; el orden es contrato: fechas, limite, horas.
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_validar(
    p_fecha_inicio DATE, p_fecha_fin DATE, p_fecha_limite_matricula DATE,
    p_hora_inicio TIME, p_hora_fin TIME
)
RETURNS VOID LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    PERFORM academico_test.fn_periodo_validar_fechas(p_fecha_inicio, p_fecha_fin);
    PERFORM academico_test.fn_periodo_validar_limite_matricula(p_fecha_limite_matricula, p_fecha_inicio, p_fecha_fin);
    PERFORM academico_test.fn_periodo_validar_horario(p_hora_inicio, p_hora_fin);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_validar(DATE, DATE, DATE, TIME, TIME)
    IS 'Compone fn_periodo_validar_fechas, _limite_matricula y _horario; la usan fn_periodo_crear_interno y fn_periodo_actualizar_interno.';
