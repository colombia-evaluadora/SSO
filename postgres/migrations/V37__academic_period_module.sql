-- ===========================================================================
-- V37 — Modulo de Periodo Academico (academico_test).
--
-- Funciones:
--   fn_periodo_crear(...)       — crea el periodo + su criterio de evaluacion
--                                 (1:1, PK compartida) + N descansos, en una
--                                 sola operacion atomica. Resuelve/crea el
--                                 año lectivo desde FECHA_INICIO y arma el
--                                 NOMBRE = "<año> - <jornada>". Retorna PK.
--   fn_periodo_actualizar(...)  — PATCH; re-deriva año/nombre; no permite
--                                 mover a otro establecimiento.
--   fn_periodo_soft_delete(...) — baja logica en cascada (periodo + criterio
--                                 + descansos).
--   fn_periodo_listar(...)      — lista con filtros opcionales.
--   fn_periodo_detalle(...)     — un periodo por PK.
--   fn_descanso_agregar / fn_descanso_eliminar — edicion de descansos suelta.
--
-- SQLSTATE: 42501 no autorizado, 22023 obligatorio/invalido, 23505 duplicado,
--           23503 FK inexistente, P0002 no existe.
-- ===========================================================================

SET search_path TO academico_test, public;

-- ---------------------------------------------------------------------------
-- fn_es_super_admin — helper reusable (definido tambien por el modulo de
-- Establecimiento; se incluye aca con CREATE OR REPLACE para que este archivo
-- corra de forma independiente. Cuerpo identico: no diverge).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_es_super_admin(p_pk_usuario BIGINT)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM academico_test.TSEDE_USUARIO
         WHERE FK_TUSUARIO = p_pk_usuario AND FK_TROL = 1 AND ACTIVE = TRUE
    );
$$;

-- ---------------------------------------------------------------------------
-- fn_periodo_crear
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_crear(
    p_fk_sede                 BIGINT,
    p_fk_estado               BIGINT,
    p_fecha_inicio            DATE,
    p_fecha_fin               DATE,
    p_fecha_limite_matricula  DATE,
    p_fk_jornada              BIGINT,
    p_hora_inicio             TIME,
    p_hora_fin                TIME,
    p_reserva                 bool_sn      DEFAULT 'S',
    p_bloques_por_defecto     BIGINT       DEFAULT 0,
    p_fk_periodo_anterior     BIGINT       DEFAULT NULL,
    -- Descansos como arreglos paralelos (misma longitud). NULL = sin descansos.
    p_descanso_inicio         TIME[]       DEFAULT NULL,
    p_descanso_fin            TIME[]       DEFAULT NULL,
    p_pk_usuario_solicitante  BIGINT       DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql AS $$
DECLARE
    v_establecimiento BIGINT;
    v_nombre_ano      VARCHAR(50);
    v_nombre_jornada  TEXT;
    v_ano_id          BIGINT;
    v_id              BIGINT;
    v_audit           VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    i                 INT;
    j                 INT;
BEGIN
    -- 0. Autorizacion.
    IF NOT academico_test.fn_es_super_admin(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    -- 1. Obligatorios.
    IF p_fk_sede IS NULL OR p_fk_estado IS NULL OR p_fecha_inicio IS NULL
       OR p_fecha_fin IS NULL OR p_fecha_limite_matricula IS NULL
       OR p_fk_jornada IS NULL OR p_hora_inicio IS NULL OR p_hora_fin IS NULL THEN
        RAISE EXCEPTION 'Faltan campos obligatorios del periodo academico'
            USING ERRCODE = '22023';
    END IF;

    -- 2. Reglas de fecha/hora.
    IF p_fecha_fin <= p_fecha_inicio THEN
        RAISE EXCEPTION 'La fecha fin (%) debe ser posterior a la fecha inicio (%)',
            p_fecha_fin, p_fecha_inicio USING ERRCODE = '22023';
    END IF;
    IF p_fecha_limite_matricula < p_fecha_inicio OR p_fecha_limite_matricula > p_fecha_fin THEN
        RAISE EXCEPTION 'La fecha limite de matricula (%) debe estar entre inicio (%) y fin (%)',
            p_fecha_limite_matricula, p_fecha_inicio, p_fecha_fin USING ERRCODE = '22023';
    END IF;
    IF p_hora_fin < p_hora_inicio THEN
        RAISE EXCEPTION 'La hora fin (%) no puede ser anterior a la hora inicio (%)',
            p_hora_fin, p_hora_inicio USING ERRCODE = '22023';
    END IF;

    -- 3. Establecimiento de la sede (debe estar activa).
    SELECT FK_TESTABLECIMIENTO INTO v_establecimiento
      FROM academico_test.TSEDE WHERE PK_TSEDE = p_fk_sede AND ACTIVE = TRUE;
    IF v_establecimiento IS NULL THEN
        RAISE EXCEPTION 'La sede % no existe o esta inactiva', p_fk_sede USING ERRCODE = '23503';
    END IF;

    -- 3b. Periodo anterior (opcional): debe existir, estar activo y pertenecer al
    -- mismo establecimiento que la sede del nuevo periodo.
    IF p_fk_periodo_anterior IS NOT NULL THEN
        PERFORM 1
          FROM academico_test.TPERIODO_ACADEMICO pa
          JOIN academico_test.TSEDE se ON se.PK_TSEDE = pa.FK_TSEDE
         WHERE pa.PK_TPERIODO_ACADEMICO = p_fk_periodo_anterior
           AND pa.ACTIVE = TRUE
           AND se.FK_TESTABLECIMIENTO = v_establecimiento;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'El periodo academico anterior % no existe, esta inactivo o pertenece a otro establecimiento',
                p_fk_periodo_anterior USING ERRCODE = '22023';
        END IF;
    END IF;

    -- 4. Resolver/crear el año lectivo (nombre = año de FECHA_INICIO).
    v_nombre_ano := to_char(p_fecha_inicio, 'YYYY');
    INSERT INTO academico_test.TANO_LECTIVO (NOMBRE, FK_TESTABLECIMIENTO, CREATED_BY)
    VALUES (v_nombre_ano, v_establecimiento, v_audit)
    ON CONFLICT (FK_TESTABLECIMIENTO, NOMBRE) DO NOTHING
    RETURNING PK_ANO_LECTIVO INTO v_ano_id;
    IF v_ano_id IS NULL THEN
        SELECT PK_ANO_LECTIVO INTO v_ano_id FROM academico_test.TANO_LECTIVO
         WHERE FK_TESTABLECIMIENTO = v_establecimiento AND NOMBRE = v_nombre_ano;
    END IF;

    -- 5. Un solo periodo activo por (año lectivo, sede).
    IF EXISTS (
        SELECT 1 FROM academico_test.TPERIODO_ACADEMICO
         WHERE FK_TANO_LECTIVO = v_ano_id AND FK_TSEDE = p_fk_sede AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'La sede % ya tiene un periodo academico activo para el año lectivo %',
            p_fk_sede, v_nombre_ano USING ERRCODE = '23505';
    END IF;

    -- 6. Nombre derivado.
    SELECT VALOR INTO v_nombre_jornada
      FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_fk_jornada;
    IF v_nombre_jornada IS NULL THEN
        RAISE EXCEPTION 'La jornada % no existe', p_fk_jornada USING ERRCODE = '23503';
    END IF;

    -- 7. Insert del periodo.
    INSERT INTO academico_test.TPERIODO_ACADEMICO (
        FK_TPERIODO_ACADEMICO, FK_TANO_LECTIVO, FK_TLV_ESTADO, FK_TSEDE,
        FECHA_INICIO, FECHA_FIN, FECHA_LIMITE_MATRICULA, FK_TLV_JORNADA,
        RESERVA, BLOQUES_POR_DEFECTO, NOMBRE, HORA_INICIO, HORA_FIN, CREATED_BY
    ) VALUES (
        p_fk_periodo_anterior, v_ano_id, p_fk_estado, p_fk_sede,
        p_fecha_inicio, p_fecha_fin, p_fecha_limite_matricula, p_fk_jornada,
        COALESCE(p_reserva, 'S'), COALESCE(p_bloques_por_defecto, 0),
        v_nombre_ano || ' - ' || v_nombre_jornada, p_hora_inicio, p_hora_fin, v_audit
    )
    RETURNING PK_TPERIODO_ACADEMICO INTO v_id;

    -- 8. Criterio de evaluacion por defecto (1:1, PK compartida).
    INSERT INTO academico_test.TCRITERIO_EVALUACION (
        PK_TCRITERIO_EVALUACION, FK_TLV_FORMATO_CALIFICACION, FK_TLV_ELEMENTO_DEF,
        FK_TLV_CRITERIO_FINAL, FK_TLV_CRITERIO_AREA, FK_TLV_DESEMPENO_SIN_CALIF,
        FK_TLV_MODIF_FINAL_PERACA, NUMERO_DECIMALES, PORCENTAJE_INICIAL_CALIF, CREATED_BY
    ) VALUES (v_id, 5286, 494, 501, 508, 522, 511, 0, 0, v_audit)
    ON CONFLICT (PK_TCRITERIO_EVALUACION) DO NOTHING;

    -- 9. Descansos anidados (opcional). Validan contra el horario del periodo.
    IF p_descanso_inicio IS NOT NULL THEN
        IF p_descanso_fin IS NULL OR array_length(p_descanso_inicio,1) <> array_length(p_descanso_fin,1) THEN
            RAISE EXCEPTION 'Los arreglos de inicio/fin de descansos deben tener la misma longitud'
                USING ERRCODE = '22023';
        END IF;
        FOR i IN 1 .. array_length(p_descanso_inicio, 1) LOOP
            IF p_descanso_fin[i] < p_descanso_inicio[i] THEN
                RAISE EXCEPTION 'Descanso %: hora fin anterior a inicio', i USING ERRCODE = '22023';
            END IF;
            IF p_descanso_inicio[i] < p_hora_inicio OR p_descanso_fin[i] > p_hora_fin THEN
                RAISE EXCEPTION 'Descanso % (% a %) fuera del horario del periodo (% a %)',
                    i, p_descanso_inicio[i], p_descanso_fin[i], p_hora_inicio, p_hora_fin
                    USING ERRCODE = '22023';
            END IF;
            -- Sin traslape con los descansos previos del mismo arreglo.
            FOR j IN 1 .. i - 1 LOOP
                IF p_descanso_inicio[i] < p_descanso_fin[j] AND p_descanso_fin[i] > p_descanso_inicio[j] THEN
                    RAISE EXCEPTION 'Los descansos % y % se traslapan', j, i USING ERRCODE = '22023';
                END IF;
            END LOOP;
            INSERT INTO academico_test.TDESCANSOS (FK_TPERIODO_ACADEMICO, HORA_INICIO, HORA_FIN, CREATED_BY)
            VALUES (v_id, p_descanso_inicio[i], p_descanso_fin[i], v_audit);
        END LOOP;
    END IF;

    RETURN v_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- fn_periodo_actualizar (PATCH: NULL = no cambia). Re-deriva año/nombre y no
-- permite mover el periodo a otro establecimiento.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_actualizar(
    p_pk_periodo              BIGINT,
    p_fk_estado               BIGINT   DEFAULT NULL,
    p_fk_sede                 BIGINT   DEFAULT NULL,
    p_fecha_inicio            DATE     DEFAULT NULL,
    p_fecha_fin               DATE     DEFAULT NULL,
    p_fecha_limite_matricula  DATE     DEFAULT NULL,
    p_fk_jornada              BIGINT   DEFAULT NULL,
    p_reserva                 bool_sn  DEFAULT NULL,
    p_bloques_por_defecto     BIGINT   DEFAULT NULL,
    p_fk_periodo_anterior     BIGINT   DEFAULT NULL,
    p_hora_inicio             TIME     DEFAULT NULL,
    p_hora_fin                TIME     DEFAULT NULL,
    p_pk_usuario_solicitante  BIGINT   DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql AS $$
DECLARE
    r                 academico_test.TPERIODO_ACADEMICO;
    v_sede            BIGINT;
    v_inicio          DATE;
    v_fin             DATE;
    v_limite          DATE;
    v_jornada         BIGINT;
    v_est_old         BIGINT;
    v_est_new         BIGINT;
    v_hi              TIME;
    v_hf              TIME;
    v_nombre_ano      VARCHAR(50);
    v_nombre_jornada  TEXT;
    v_ano_id          BIGINT;
    v_audit           VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    IF NOT academico_test.fn_es_super_admin(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    SELECT * INTO r FROM academico_test.TPERIODO_ACADEMICO WHERE PK_TPERIODO_ACADEMICO = p_pk_periodo;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe el periodo academico %', p_pk_periodo USING ERRCODE = 'P0002';
    END IF;
    IF r.ACTIVE = FALSE THEN
        RAISE EXCEPTION 'El periodo academico % esta inactivo; no se puede actualizar', p_pk_periodo
            USING ERRCODE = '22023';
    END IF;

    -- Valores efectivos (COALESCE param o actual).
    v_sede    := COALESCE(p_fk_sede, r.FK_TSEDE);
    v_inicio  := COALESCE(p_fecha_inicio, r.FECHA_INICIO);
    v_fin     := COALESCE(p_fecha_fin, r.FECHA_FIN);
    v_limite  := COALESCE(p_fecha_limite_matricula, r.FECHA_LIMITE_MATRICULA);
    v_jornada := COALESCE(p_fk_jornada, r.FK_TLV_JORNADA);
    v_hi      := COALESCE(p_hora_inicio, r.HORA_INICIO);
    v_hf      := COALESCE(p_hora_fin, r.HORA_FIN);

    -- No cambiar de establecimiento (rompe el año lectivo).
    IF v_sede <> r.FK_TSEDE THEN
        SELECT FK_TESTABLECIMIENTO INTO v_est_old FROM academico_test.TSEDE WHERE PK_TSEDE = r.FK_TSEDE;
        SELECT FK_TESTABLECIMIENTO INTO v_est_new FROM academico_test.TSEDE WHERE PK_TSEDE = v_sede AND ACTIVE = TRUE;
        IF v_est_new IS NULL THEN
            RAISE EXCEPTION 'La sede % no existe o esta inactiva', v_sede USING ERRCODE = '23503';
        END IF;
        IF v_est_new <> v_est_old THEN
            RAISE EXCEPTION 'No se puede mover el periodo a una sede de otro establecimiento'
                USING ERRCODE = '22023';
        END IF;
    END IF;

    -- Reglas de fecha/hora.
    IF v_fin <= v_inicio THEN
        RAISE EXCEPTION 'La fecha fin (%) debe ser posterior a la fecha inicio (%)', v_fin, v_inicio
            USING ERRCODE = '22023';
    END IF;
    IF v_limite < v_inicio OR v_limite > v_fin THEN
        RAISE EXCEPTION 'La fecha limite de matricula (%) debe estar entre inicio (%) y fin (%)',
            v_limite, v_inicio, v_fin USING ERRCODE = '22023';
    END IF;
    IF v_hf < v_hi THEN
        RAISE EXCEPTION 'La hora fin (%) no puede ser anterior a la hora inicio (%)', v_hf, v_hi
            USING ERRCODE = '22023';
    END IF;
    -- Los descansos existentes deben seguir dentro del nuevo horario.
    IF EXISTS (
        SELECT 1 FROM academico_test.TDESCANSOS
         WHERE FK_TPERIODO_ACADEMICO = p_pk_periodo AND ACTIVE = TRUE
           AND (HORA_INICIO < v_hi OR HORA_FIN > v_hf)
    ) THEN
        RAISE EXCEPTION 'El nuevo horario (% a %) deja descansos existentes fuera de rango; ajustelos primero',
            v_hi, v_hf USING ERRCODE = '22023';
    END IF;

    -- Re-resolver año lectivo (por si cambio la fecha de inicio).
    SELECT FK_TESTABLECIMIENTO INTO v_est_new FROM academico_test.TSEDE WHERE PK_TSEDE = v_sede;

    -- Periodo anterior (opcional): existe, activo, mismo establecimiento y no a si mismo.
    IF p_fk_periodo_anterior IS NOT NULL THEN
        IF p_fk_periodo_anterior = p_pk_periodo THEN
            RAISE EXCEPTION 'Un periodo academico no puede ser su propio periodo anterior'
                USING ERRCODE = '22023';
        END IF;
        PERFORM 1
          FROM academico_test.TPERIODO_ACADEMICO pa
          JOIN academico_test.TSEDE se ON se.PK_TSEDE = pa.FK_TSEDE
         WHERE pa.PK_TPERIODO_ACADEMICO = p_fk_periodo_anterior
           AND pa.ACTIVE = TRUE
           AND se.FK_TESTABLECIMIENTO = v_est_new;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'El periodo academico anterior % no existe, esta inactivo o pertenece a otro establecimiento',
                p_fk_periodo_anterior USING ERRCODE = '22023';
        END IF;
    END IF;

    v_nombre_ano := to_char(v_inicio, 'YYYY');
    INSERT INTO academico_test.TANO_LECTIVO (NOMBRE, FK_TESTABLECIMIENTO, CREATED_BY)
    VALUES (v_nombre_ano, v_est_new, v_audit)
    ON CONFLICT (FK_TESTABLECIMIENTO, NOMBRE) DO NOTHING
    RETURNING PK_ANO_LECTIVO INTO v_ano_id;
    IF v_ano_id IS NULL THEN
        SELECT PK_ANO_LECTIVO INTO v_ano_id FROM academico_test.TANO_LECTIVO
         WHERE FK_TESTABLECIMIENTO = v_est_new AND NOMBRE = v_nombre_ano;
    END IF;

    -- Un solo periodo activo por (año, sede) — excluyendose a si mismo.
    IF EXISTS (
        SELECT 1 FROM academico_test.TPERIODO_ACADEMICO
         WHERE FK_TANO_LECTIVO = v_ano_id AND FK_TSEDE = v_sede AND ACTIVE = TRUE
           AND PK_TPERIODO_ACADEMICO <> p_pk_periodo
    ) THEN
        RAISE EXCEPTION 'La sede % ya tiene un periodo academico activo para el año lectivo %',
            v_sede, v_nombre_ano USING ERRCODE = '23505';
    END IF;

    -- Nombre derivado.
    SELECT VALOR INTO v_nombre_jornada FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = v_jornada;
    IF v_nombre_jornada IS NULL THEN
        RAISE EXCEPTION 'La jornada % no existe', v_jornada USING ERRCODE = '23503';
    END IF;

    UPDATE academico_test.TPERIODO_ACADEMICO SET
        FK_TLV_ESTADO          = COALESCE(p_fk_estado, FK_TLV_ESTADO),
        FK_TSEDE               = v_sede,
        FECHA_INICIO           = v_inicio,
        FECHA_FIN              = v_fin,
        FECHA_LIMITE_MATRICULA = v_limite,
        FK_TLV_JORNADA         = v_jornada,
        FK_TANO_LECTIVO        = v_ano_id,
        RESERVA                = COALESCE(p_reserva, RESERVA),
        BLOQUES_POR_DEFECTO    = COALESCE(p_bloques_por_defecto, BLOQUES_POR_DEFECTO),
        FK_TPERIODO_ACADEMICO  = COALESCE(p_fk_periodo_anterior, FK_TPERIODO_ACADEMICO),
        HORA_INICIO            = COALESCE(p_hora_inicio, HORA_INICIO),
        HORA_FIN               = COALESCE(p_hora_fin, HORA_FIN),
        NOMBRE                 = v_nombre_ano || ' - ' || v_nombre_jornada,
        MODIFIED_BY            = v_audit,
        MODIFIED_AT            = CURRENT_TIMESTAMP
     WHERE PK_TPERIODO_ACADEMICO = p_pk_periodo;

    RETURN p_pk_periodo;
END;
$$;

-- ---------------------------------------------------------------------------
-- fn_periodo_soft_delete (cascada: periodo + criterio + descansos).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_soft_delete(
    p_pk_periodo              BIGINT,
    p_pk_usuario_solicitante  BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql AS $$
DECLARE
    v_activo BOOLEAN;
    v_audit  VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    IF NOT academico_test.fn_es_super_admin(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    SELECT ACTIVE INTO v_activo FROM academico_test.TPERIODO_ACADEMICO WHERE PK_TPERIODO_ACADEMICO = p_pk_periodo;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe el periodo academico %', p_pk_periodo USING ERRCODE = 'P0002';
    END IF;
    IF v_activo = FALSE THEN
        RAISE EXCEPTION 'El periodo academico % ya esta inactivo', p_pk_periodo USING ERRCODE = '22023';
    END IF;

    IF EXISTS (
        SELECT 1 FROM academico_test.THORARIO h
          JOIN academico_test.TGRUPO g ON g.PK_TGRUPO = h.FK_TGRUPO AND g.ACTIVE = TRUE
          JOIN academico_test.TGRADO gr ON gr.PK_TGRADO = g.FK_TGRADO AND gr.ACTIVE = TRUE
         WHERE gr.FK_TPERIODO_ACADEMICO = p_pk_periodo AND h.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el periodo academico %: existen horarios/asistencias configurados', p_pk_periodo
            USING ERRCODE = '23503';
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.TPLAN pl
          JOIN academico_test.TGRADO gr ON gr.PK_TGRADO = pl.FK_TGRADO AND gr.ACTIVE = TRUE
         WHERE gr.FK_TPERIODO_ACADEMICO = p_pk_periodo AND pl.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el periodo academico %: existen planes de estudio asociados', p_pk_periodo
            USING ERRCODE = '23503';
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.TPERIODO_EVALUACION pe
         WHERE pe.FK_TPERIODO_ACADEMICO = p_pk_periodo AND pe.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el periodo academico %: existen periodos de evaluacion asociados', p_pk_periodo
            USING ERRCODE = '23503';
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.TNIVEL_ESCALA ne
         WHERE ne.FK_PERIODO_ACADEMICO = p_pk_periodo AND ne.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el periodo academico %: existen escalas de valoracion asociadas', p_pk_periodo
            USING ERRCODE = '23503';
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.TDOCENTE_ASIGNATURA da
         WHERE da.FK_TPERIODO_ACADEMICO = p_pk_periodo AND da.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el periodo academico %: existen asignaciones academicas asociadas', p_pk_periodo
            USING ERRCODE = '23503';
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.TAREA t
         WHERE t.FK_TPERIODO_ACADEMICO = p_pk_periodo AND t.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el periodo academico %: existen areas academicas configuradas', p_pk_periodo
            USING ERRCODE = '23503';
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.TGRADO gr
         WHERE gr.FK_TPERIODO_ACADEMICO = p_pk_periodo AND gr.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el periodo academico %: existen grados/grupos configurados', p_pk_periodo
            USING ERRCODE = '23503';
    END IF;

    UPDATE academico_test.TPERIODO_ACADEMICO
       SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TPERIODO_ACADEMICO = p_pk_periodo;

    UPDATE academico_test.TCRITERIO_EVALUACION
       SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TCRITERIO_EVALUACION = p_pk_periodo AND ACTIVE = TRUE;

    UPDATE academico_test.TDESCANSOS
       SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TPERIODO_ACADEMICO = p_pk_periodo AND ACTIVE = TRUE;

    RETURN p_pk_periodo;
END;
$$;

-- ---------------------------------------------------------------------------
-- fn_periodo_listar — lista con filtros opcionales (NULL = ignora). Sin gate
-- (lectura). Devuelve nombres resueltos (sede, año, estado).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_listar(
    p_fk_sede      BIGINT   DEFAULT NULL,
    p_nombre_sede  TEXT     DEFAULT NULL,
    p_ano          TEXT     DEFAULT NULL,
    p_fk_estado    BIGINT   DEFAULT NULL,
    p_fecha_desde  DATE     DEFAULT NULL,
    p_fecha_hasta  DATE     DEFAULT NULL
)
RETURNS TABLE (
    id BIGINT, sede_id BIGINT, sede_name VARCHAR, school_year_id BIGINT,
    school_year_name VARCHAR, status_id BIGINT, status VARCHAR,
    start_date DATE, end_date DATE, enrollment_deadline DATE, name VARCHAR,
    jornada_id BIGINT, reserva bool_sn, default_blocks_count BIGINT,
    schedule_start_time TIME, schedule_end_time TIME
)
LANGUAGE sql STABLE AS $$
    SELECT pa.PK_TPERIODO_ACADEMICO, pa.FK_TSEDE, s.NOMBRE, pa.FK_TANO_LECTIVO,
           al.NOMBRE, pa.FK_TLV_ESTADO, est.VALOR,
           pa.FECHA_INICIO, pa.FECHA_FIN, pa.FECHA_LIMITE_MATRICULA, pa.NOMBRE,
           pa.FK_TLV_JORNADA, pa.RESERVA, pa.BLOQUES_POR_DEFECTO,
           pa.HORA_INICIO, pa.HORA_FIN
      FROM academico_test.TPERIODO_ACADEMICO pa
      JOIN academico_test.TSEDE s          ON s.PK_TSEDE = pa.FK_TSEDE
      JOIN academico_test.TANO_LECTIVO al  ON al.PK_ANO_LECTIVO = pa.FK_TANO_LECTIVO
      JOIN academico_test.TLISTA_VALOR est ON est.PK_LISTA_VALOR = pa.FK_TLV_ESTADO
     WHERE pa.ACTIVE = TRUE
       AND (p_fk_sede     IS NULL OR pa.FK_TSEDE = p_fk_sede)
       AND (p_nombre_sede IS NULL OR s.NOMBRE ILIKE '%' || p_nombre_sede || '%')
       AND (p_ano         IS NULL OR al.NOMBRE = p_ano)
       AND (p_fk_estado   IS NULL OR pa.FK_TLV_ESTADO = p_fk_estado)
       AND (p_fecha_desde IS NULL OR pa.FECHA_INICIO >= p_fecha_desde)
       AND (p_fecha_hasta IS NULL OR pa.FECHA_INICIO <= p_fecha_hasta)
     ORDER BY pa.FECHA_INICIO DESC;
$$;

-- ---------------------------------------------------------------------------
-- fn_periodo_detalle — un periodo por PK (mismos campos que el listado).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_detalle(p_pk_periodo BIGINT)
RETURNS TABLE (
    id BIGINT, sede_id BIGINT, sede_name VARCHAR, school_year_id BIGINT,
    school_year_name VARCHAR, status_id BIGINT, status VARCHAR,
    start_date DATE, end_date DATE, enrollment_deadline DATE, name VARCHAR,
    jornada_id BIGINT, reserva bool_sn, default_blocks_count BIGINT,
    schedule_start_time TIME, schedule_end_time TIME
)
LANGUAGE sql STABLE AS $$
    SELECT pa.PK_TPERIODO_ACADEMICO, pa.FK_TSEDE, s.NOMBRE, pa.FK_TANO_LECTIVO,
           al.NOMBRE, pa.FK_TLV_ESTADO, est.VALOR,
           pa.FECHA_INICIO, pa.FECHA_FIN, pa.FECHA_LIMITE_MATRICULA, pa.NOMBRE,
           pa.FK_TLV_JORNADA, pa.RESERVA, pa.BLOQUES_POR_DEFECTO,
           pa.HORA_INICIO, pa.HORA_FIN
      FROM academico_test.TPERIODO_ACADEMICO pa
      JOIN academico_test.TSEDE s          ON s.PK_TSEDE = pa.FK_TSEDE
      JOIN academico_test.TANO_LECTIVO al  ON al.PK_ANO_LECTIVO = pa.FK_TANO_LECTIVO
      JOIN academico_test.TLISTA_VALOR est ON est.PK_LISTA_VALOR = pa.FK_TLV_ESTADO
     WHERE pa.PK_TPERIODO_ACADEMICO = p_pk_periodo AND pa.ACTIVE = TRUE;
$$;

-- ---------------------------------------------------------------------------
-- fn_descanso_agregar / fn_descanso_eliminar — edicion suelta de descansos.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_descanso_agregar(
    p_fk_periodo              BIGINT,
    p_hora_inicio             TIME,
    p_hora_fin                TIME,
    p_pk_usuario_solicitante  BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql AS $$
DECLARE
    v_pi TIME; v_pf TIME; v_id BIGINT;
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    IF NOT academico_test.fn_es_super_admin(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    SELECT HORA_INICIO, HORA_FIN INTO v_pi, v_pf
      FROM academico_test.TPERIODO_ACADEMICO WHERE PK_TPERIODO_ACADEMICO = p_fk_periodo;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe el periodo academico %', p_fk_periodo USING ERRCODE = 'P0002';
    END IF;
    IF p_hora_fin < p_hora_inicio THEN
        RAISE EXCEPTION 'La hora fin del descanso no puede ser anterior a la inicio' USING ERRCODE = '22023';
    END IF;
    IF p_hora_inicio < v_pi OR p_hora_fin > v_pf THEN
        RAISE EXCEPTION 'El descanso (% a %) debe estar dentro del horario del periodo (% a %)',
            p_hora_inicio, p_hora_fin, v_pi, v_pf USING ERRCODE = '22023';
    END IF;
    -- Sin traslape con otros descansos activos del mismo periodo.
    IF EXISTS (
        SELECT 1 FROM academico_test.TDESCANSOS
         WHERE FK_TPERIODO_ACADEMICO = p_fk_periodo AND ACTIVE = TRUE
           AND p_hora_inicio < HORA_FIN AND p_hora_fin > HORA_INICIO
    ) THEN
        RAISE EXCEPTION 'El descanso (% a %) se traslapa con otro descanso existente',
            p_hora_inicio, p_hora_fin USING ERRCODE = '22023';
    END IF;

    INSERT INTO academico_test.TDESCANSOS (FK_TPERIODO_ACADEMICO, HORA_INICIO, HORA_FIN, CREATED_BY)
    VALUES (p_fk_periodo, p_hora_inicio, p_hora_fin, v_audit)
    RETURNING PK_TDESCANSOS INTO v_id;
    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_descanso_eliminar(
    p_pk_descanso             BIGINT,
    p_pk_usuario_solicitante  BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql AS $$
DECLARE v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR; v_n INT;
BEGIN
    IF NOT academico_test.fn_es_super_admin(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;
    UPDATE academico_test.TDESCANSOS
       SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TDESCANSOS = p_pk_descanso AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN
        RAISE EXCEPTION 'No existe un descanso activo con PK %', p_pk_descanso USING ERRCODE = 'P0002';
    END IF;
    RETURN p_pk_descanso;
END;
$$;
