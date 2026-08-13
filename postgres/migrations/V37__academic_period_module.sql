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
--                                 mover a otro establecimiento; reconcilia los
--                                 descansos (reemplazo total del set).
--   fn_periodo_soft_delete(...) — baja logica en cascada (periodo + criterio
--                                 + descansos).
--   fn_periodo_listar(...)      — lista con filtros opcionales.
--   fn_periodo_detalle(...)     — un periodo por PK.
--   fn_periodo_anteriores_por_sede(...) — candidatos a "periodo anterior" de
--                                 una sede (picker del formulario).
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
-- Alcance de lectura del PERIODO ACADEMICO.
--   Globales (ven todo):  1 Super Admin, 2 Director (Ente Territorial),
--                         3 Jefe de Sistema (Ente Territorial).
--   Por establecimiento:  7 Rector, 8 Jefe de Sistema (Establecimiento),
--                         9 Auxiliar administrativo.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_usuario_global(p_pk_usuario BIGINT)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM academico_test.TSEDE_USUARIO
         WHERE FK_TUSUARIO = p_pk_usuario AND ACTIVE = TRUE AND FK_TROL IN (1, 2, 3)
    );
$$;

-- Establecimientos que el usuario puede ver (por sus roles de establecimiento).
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_usuario_establecimientos(p_pk_usuario BIGINT)
RETURNS TABLE (establecimiento_id BIGINT) LANGUAGE sql STABLE AS $$
    SELECT DISTINCT s.FK_TESTABLECIMIENTO
      FROM academico_test.TSEDE_USUARIO su
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
     WHERE su.FK_TUSUARIO = p_pk_usuario AND su.ACTIVE = TRUE
       AND su.FK_TROL IN (7, 8, 9);
$$;

-- Sedes que el usuario puede ver por roles con alcance SEDE (no todo el
-- establecimiento). Rol 11 = Coordinador: SOLO su(s) sede(s), solo lectura.
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_usuario_sedes(p_pk_usuario BIGINT)
RETURNS TABLE (sede_id BIGINT) LANGUAGE sql STABLE AS $$
    SELECT DISTINCT su.FK_TSEDE
      FROM academico_test.TSEDE_USUARIO su
     WHERE su.FK_TUSUARIO = p_pk_usuario AND su.ACTIVE = TRUE
       AND su.FK_TROL IN (11);
$$;

-- TRUE si el usuario puede ver el periodo: global (1/2/3), o el establecimiento
-- de su sede (7/8/9), o —alcance SEDE— la sede exacta del periodo (11).
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_usuario_puede_ver(
    p_pk_usuario BIGINT, p_fk_periodo BIGINT
)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT academico_test.fn_periodo_usuario_global(p_pk_usuario)
        OR EXISTS (
            SELECT 1
              FROM academico_test.TPERIODO_ACADEMICO pa
              JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
             WHERE pa.PK_TPERIODO_ACADEMICO = p_fk_periodo
               AND ( s.FK_TESTABLECIMIENTO IN (
                         SELECT establecimiento_id
                           FROM academico_test.fn_periodo_usuario_establecimientos(p_pk_usuario))
                     OR pa.FK_TSEDE IN (
                         SELECT sede_id
                           FROM academico_test.fn_periodo_usuario_sedes(p_pk_usuario)) )
        );
$$;

-- ESCRITURA: los mismos roles (1,2,3 globales; 7,8,9 por establecimiento).
-- Gate grueso: ¿tiene algun rol de gestion?
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_usuario_puede_gestionar(p_pk_usuario BIGINT)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM academico_test.TSEDE_USUARIO
         WHERE FK_TUSUARIO = p_pk_usuario AND ACTIVE = TRUE
           AND FK_TROL IN (1, 2, 3, 7, 8, 9)
    );
$$;

-- Gate fino: ¿puede escribir sobre este establecimiento? Global si; los de
-- establecimiento solo si es el suyo.
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_usuario_puede_escribir(
    p_pk_usuario BIGINT, p_fk_establecimiento BIGINT
)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT academico_test.fn_periodo_usuario_global(p_pk_usuario)
        OR p_fk_establecimiento IN (
            SELECT establecimiento_id
              FROM academico_test.fn_periodo_usuario_establecimientos(p_pk_usuario)
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
    v_establecimiento    BIGINT;
    v_nombre_ano         VARCHAR(50);
    v_nombre_jornada     TEXT;
    v_nombre_estado      TEXT;
    v_categoria_jornada  VARCHAR(30);
    v_categoria_estado   VARCHAR(30);
    v_ano_id             BIGINT;
    v_id                 BIGINT;
    v_audit              VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    i                    INT;
    j                    INT;
    -- Valores por defecto del criterio de evaluacion (catalogo TLISTA_VALOR).
    c_formato_calif        CONSTANT BIGINT := 51889;
    c_elemento_def         CONSTANT BIGINT := 494;
    c_criterio_final       CONSTANT BIGINT := 501;
    c_criterio_area        CONSTANT BIGINT := 508;
    c_desempeno_sin_calif  CONSTANT BIGINT := 522;
    c_modif_final_peraca   CONSTANT BIGINT := 511;
BEGIN
    -- 0. Autorizacion (gate grueso: algun rol de gestion).
    IF NOT academico_test.fn_periodo_usuario_puede_gestionar(p_pk_usuario_solicitante) THEN
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
    -- 3a. Autorizacion (gate fino: el establecimiento debe estar en su alcance).
    IF NOT academico_test.fn_periodo_usuario_puede_escribir(p_pk_usuario_solicitante, v_establecimiento) THEN
        RAISE EXCEPTION 'El usuario no puede gestionar periodos de este establecimiento'
            USING ERRCODE = '42501';
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

    -- 6a. Validar FK_TLV_ESTADO — debe existir y pertenecer a la categoria
    --     ESTADOPERIODO en TLISTA_VALOR.
    SELECT VALOR, CATEGORIA INTO v_nombre_estado, v_categoria_estado
      FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_fk_estado;
    IF v_nombre_estado IS NULL THEN
        RAISE EXCEPTION 'El estado % no existe', p_fk_estado USING ERRCODE = '23503';
    END IF;
    IF v_categoria_estado <> 'ESTADOPERIODO' THEN
        RAISE EXCEPTION 'El estado % no pertenece a la categoria ESTADOPERIODO (es %)',
            p_fk_estado, v_categoria_estado USING ERRCODE = '22023';
    END IF;

    -- 6b. Nombre derivado de la jornada — debe existir y pertenecer a la
    --     categoria JORNADA en TLISTA_VALOR.
    SELECT VALOR, CATEGORIA INTO v_nombre_jornada, v_categoria_jornada
      FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_fk_jornada;
    IF v_nombre_jornada IS NULL THEN
        RAISE EXCEPTION 'La jornada % no existe', p_fk_jornada USING ERRCODE = '23503';
    END IF;
    IF v_categoria_jornada <> 'JORNADA' THEN
        RAISE EXCEPTION 'La jornada % no pertenece a la categoria JORNADA (es %)',
            p_fk_jornada, v_categoria_jornada USING ERRCODE = '22023';
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
        FK_TLV_MODIF_FINAL_PERACA, CREATED_BY
    ) VALUES (v_id, c_formato_calif, c_elemento_def, c_criterio_final, c_criterio_area,
              c_desempeno_sin_calif, c_modif_final_peraca, v_audit)
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
-- permite mover el periodo a otro establecimiento. Reconcilia descansos:
--   p_descanso_inicio IS NULL → no los toca (los existentes deben caber en el
--                               nuevo horario); un arreglo (incluso vacio) →
--                               reemplazo total (soft-delete de los activos +
--                               insert del set provisto).
-- ---------------------------------------------------------------------------
-- Firma anterior (13 args, sin descansos): se elimina para no dejar el overload
-- viejo conviviendo con el nuevo y evitar llamadas ambiguas.
DROP FUNCTION IF EXISTS academico_test.fn_periodo_actualizar(
    BIGINT, BIGINT, BIGINT, DATE, DATE, DATE, BIGINT, bool_sn, BIGINT, BIGINT, TIME, TIME, BIGINT);
    DROP FUNCTION IF EXISTS academico_test.fn_periodo_actualizar(
    BIGINT,
    BIGINT,
    BIGINT,
    DATE,
    DATE,
    DATE,
    BIGINT,
    bool_sn,
    BIGINT,
    BIGINT,
    TIME,
    TIME,
    TIME[],
    TIME[],
    BIGINT
);
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
    -- Descansos como arreglos paralelos (misma longitud). NULL = no tocarlos.
    p_descanso_inicio         TIME[]   DEFAULT NULL,
    p_descanso_fin            TIME[]   DEFAULT NULL,
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
    v_estado          BIGINT;
    v_est_old         BIGINT;
    v_est_new         BIGINT;
    v_hi              TIME;
    v_hf              TIME;
    v_nombre_ano      VARCHAR(50);
    v_nombre_jornada  TEXT;
    v_categoria_jornada VARCHAR(30);
    v_categoria_estado  VARCHAR(30);
    v_ano_id          BIGINT;
    v_audit           VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    i                 INT;
    j                 INT;
BEGIN
    IF NOT academico_test.fn_periodo_usuario_puede_gestionar(p_pk_usuario_solicitante) THEN
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
    -- Autorizacion fina: el establecimiento del periodo debe estar en su alcance.
    IF NOT academico_test.fn_periodo_usuario_puede_escribir(
             p_pk_usuario_solicitante,
             (SELECT FK_TESTABLECIMIENTO FROM academico_test.TSEDE WHERE PK_TSEDE = r.FK_TSEDE)) THEN
        RAISE EXCEPTION 'El usuario no puede gestionar periodos de este establecimiento'
            USING ERRCODE = '42501';
    END IF;

    -- Valores efectivos (COALESCE param o actual).
    v_sede    := COALESCE(p_fk_sede, r.FK_TSEDE);
    v_inicio  := COALESCE(p_fecha_inicio, r.FECHA_INICIO);
    v_fin     := COALESCE(p_fecha_fin, r.FECHA_FIN);
    v_limite  := COALESCE(p_fecha_limite_matricula, r.FECHA_LIMITE_MATRICULA);
    v_jornada := COALESCE(p_fk_jornada, r.FK_TLV_JORNADA);
    v_estado  := COALESCE(p_fk_estado, r.FK_TLV_ESTADO);
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
    -- Reconciliacion de descansos.
    --   p_descanso_inicio IS NULL → no se tocan; se conserva el guard: los
    --     descansos existentes deben seguir dentro del nuevo horario.
    --   arreglo provisto (incluso vacio) → reemplazo total: se validan contra el
    --     nuevo horario/entre si, se da de baja el set activo y se inserta el nuevo.
    IF p_descanso_inicio IS NULL THEN
        IF EXISTS (
            SELECT 1 FROM academico_test.TDESCANSOS
             WHERE FK_TPERIODO_ACADEMICO = p_pk_periodo AND ACTIVE = TRUE
               AND (HORA_INICIO < v_hi OR HORA_FIN > v_hf)
        ) THEN
            RAISE EXCEPTION 'El nuevo horario (% a %) deja descansos existentes fuera de rango; ajustelos primero',
                v_hi, v_hf USING ERRCODE = '22023';
        END IF;
    ELSE
        IF p_descanso_fin IS NULL
           OR COALESCE(array_length(p_descanso_inicio, 1), 0) <> COALESCE(array_length(p_descanso_fin, 1), 0) THEN
            RAISE EXCEPTION 'Los arreglos de inicio/fin de descansos deben tener la misma longitud'
                USING ERRCODE = '22023';
        END IF;
        -- Validacion (misma que fn_periodo_crear, pero contra el horario efectivo).
        IF array_length(p_descanso_inicio, 1) IS NOT NULL THEN
            FOR i IN 1 .. array_length(p_descanso_inicio, 1) LOOP
                IF p_descanso_fin[i] < p_descanso_inicio[i] THEN
                    RAISE EXCEPTION 'Descanso %: hora fin anterior a inicio', i USING ERRCODE = '22023';
                END IF;
                IF p_descanso_inicio[i] < v_hi OR p_descanso_fin[i] > v_hf THEN
                    RAISE EXCEPTION 'Descanso % (% a %) fuera del horario del periodo (% a %)',
                        i, p_descanso_inicio[i], p_descanso_fin[i], v_hi, v_hf USING ERRCODE = '22023';
                END IF;
                FOR j IN 1 .. i - 1 LOOP
                    IF p_descanso_inicio[i] < p_descanso_fin[j] AND p_descanso_fin[i] > p_descanso_inicio[j] THEN
                        RAISE EXCEPTION 'Los descansos % y % se traslapan', j, i USING ERRCODE = '22023';
                    END IF;
                END LOOP;
            END LOOP;
        END IF;
        -- Reconciliacion por diff (evita churn de PKs): se comparan los activos
        -- contra el set provisto por (HORA_INICIO, HORA_FIN).
        --   1) baja los activos que ya NO estan en el set provisto,
        --   2) inserta los provistos que aun NO existen activos,
        --   3) los que coinciden quedan intactos (conservan su PK).
        -- Set vacio ('{}') → el paso 1 los baja a todos y el 2 no inserta nada.
        UPDATE academico_test.TDESCANSOS d
           SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE d.FK_TPERIODO_ACADEMICO = p_pk_periodo AND d.ACTIVE = TRUE
           AND NOT EXISTS (
               SELECT 1
                 FROM unnest(p_descanso_inicio, p_descanso_fin) AS nuevo(hi, hf)
                WHERE nuevo.hi = d.HORA_INICIO AND nuevo.hf = d.HORA_FIN
           );

        INSERT INTO academico_test.TDESCANSOS (FK_TPERIODO_ACADEMICO, HORA_INICIO, HORA_FIN, CREATED_BY)
        SELECT p_pk_periodo, nuevo.hi, nuevo.hf, v_audit
          FROM unnest(p_descanso_inicio, p_descanso_fin) AS nuevo(hi, hf)
         WHERE NOT EXISTS (
               SELECT 1 FROM academico_test.TDESCANSOS d
                WHERE d.FK_TPERIODO_ACADEMICO = p_pk_periodo AND d.ACTIVE = TRUE
                  AND d.HORA_INICIO = nuevo.hi AND d.HORA_FIN = nuevo.hf
           );
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

    -- Validar FK_TLV_ESTADO efectivo — debe existir y pertenecer a la categoria
    -- ESTADOPERIODO en TLISTA_VALOR.
    SELECT CATEGORIA INTO v_categoria_estado
      FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = v_estado;
    IF v_categoria_estado IS NULL THEN
        RAISE EXCEPTION 'El estado % no existe', v_estado USING ERRCODE = '23503';
    END IF;
    IF v_categoria_estado <> 'ESTADOPERIODO' THEN
        RAISE EXCEPTION 'El estado % no pertenece a la categoria ESTADOPERIODO (es %)',
            v_estado, v_categoria_estado USING ERRCODE = '22023';
    END IF;

    -- Nombre derivado de la jornada — debe existir y pertenecer a la categoria
    -- JORNADA en TLISTA_VALOR.
    SELECT VALOR, CATEGORIA INTO v_nombre_jornada, v_categoria_jornada
      FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = v_jornada;
    IF v_nombre_jornada IS NULL THEN
        RAISE EXCEPTION 'La jornada % no existe', v_jornada USING ERRCODE = '23503';
    END IF;
    IF v_categoria_jornada <> 'JORNADA' THEN
        RAISE EXCEPTION 'La jornada % no pertenece a la categoria JORNADA (es %)',
            v_jornada, v_categoria_jornada USING ERRCODE = '22023';
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
    IF NOT academico_test.fn_periodo_usuario_puede_gestionar(p_pk_usuario_solicitante) THEN
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
    -- Autorizacion fina: el establecimiento del periodo debe estar en su alcance.
    IF NOT academico_test.fn_periodo_usuario_puede_escribir(p_pk_usuario_solicitante, (
             SELECT s.FK_TESTABLECIMIENTO
               FROM academico_test.TPERIODO_ACADEMICO pa
               JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
              WHERE pa.PK_TPERIODO_ACADEMICO = p_pk_periodo)) THEN
        RAISE EXCEPTION 'El usuario no puede gestionar periodos de este establecimiento'
            USING ERRCODE = '42501';
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

    -- Cascade: criterios de promocion del periodo (default POR_DEFECTO='S' y
    -- cualquier override que quede ligado al periodo) y sus obligatorias. Son
    -- propiedad del periodo, se dan de baja con el (igual que el criterio de
    -- evaluacion). Los overrides por grado ya bajaron via fn_grado_soft_delete.
    UPDATE academico_test.TCRITERIO_PROMOCION_ASIGNATURA_OBLIGATORIA
       SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE ACTIVE = TRUE AND FK_TCRITERIO_PROMOCION IN (
         SELECT PK_TCRITERIO_PROMOCION FROM academico_test.TCRITERIO_PROMOCION
          WHERE FK_TPERIODO_ACADEMICO = p_pk_periodo AND ACTIVE = TRUE
     );
    UPDATE academico_test.TCRITERIO_PROMOCION
       SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TPERIODO_ACADEMICO = p_pk_periodo AND ACTIVE = TRUE;

    UPDATE academico_test.TDESCANSOS
       SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TPERIODO_ACADEMICO = p_pk_periodo AND ACTIVE = TRUE;

    RETURN p_pk_periodo;
END;
$$;

-- ---------------------------------------------------------------------------
-- fn_periodo_listar — lista con filtros opcionales (NULL = ignora). Sin gate
-- (lectura). Devuelve nombres resueltos (sede, año, estado). Ordena por la
-- columna pedida (p_sort_by/p_sort_dir); si no viene, por fecha de inicio desc.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_periodo_listar(BIGINT, TEXT, TEXT, BIGINT, DATE, DATE, BIGINT, INT, INT);
DROP FUNCTION IF EXISTS academico_test.fn_periodo_listar(BIGINT, TEXT, TEXT, BIGINT, DATE, DATE, BIGINT, INT, INT, TEXT, TEXT);
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_listar(
    p_fk_sede      BIGINT   DEFAULT NULL,
    p_nombre_sede  TEXT     DEFAULT NULL,
    p_ano          TEXT     DEFAULT NULL,
    p_fk_estado    BIGINT   DEFAULT NULL,
    p_fecha_desde  DATE     DEFAULT NULL,
    p_fecha_hasta  DATE     DEFAULT NULL,
    p_pk_usuario   BIGINT   DEFAULT NULL,   -- alcance (global / establecimiento)
    p_page_index   INT      DEFAULT 0,
    p_page_size    INT      DEFAULT 10,
    -- Orden: id de columna del front + direccion ('asc'/'desc').
    p_sort_by      TEXT     DEFAULT NULL,
    p_sort_dir     TEXT     DEFAULT NULL
)
RETURNS TABLE (
    id BIGINT, sede_id BIGINT, sede_name VARCHAR, school_year_id BIGINT,
    school_year_name VARCHAR, status_id BIGINT, status VARCHAR, status_name VARCHAR,
    start_date DATE, end_date DATE, enrollment_deadline DATE, name VARCHAR,
    jornada_id BIGINT, jornada VARCHAR, jornada_name VARCHAR,
    reserva bool_sn, default_blocks_count BIGINT,
    schedule_start_time TIME, schedule_end_time TIME, total_count BIGINT
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_col TEXT;
    v_dir TEXT;
BEGIN
    -- Whitelist: mapea el id de columna del front → columna real. Cualquier
    -- valor no listado cae al default (fecha de inicio). Nunca se interpola
    -- input del usuario crudo → sin riesgo de inyeccion.
    v_col := CASE lower(coalesce(p_sort_by, ''))
        WHEN 'sedename'           THEN 's.NOMBRE'
        WHEN 'schoolyearid'       THEN 'al.NOMBRE'
        WHEN 'status'             THEN 'est.VALOR'
        WHEN 'startdate'          THEN 'pa.FECHA_INICIO'
        WHEN 'enddate'            THEN 'pa.FECHA_FIN'
        WHEN 'enrollmentdeadline' THEN 'pa.FECHA_LIMITE_MATRICULA'
        WHEN 'name'               THEN 'pa.NOMBRE'
        ELSE 'pa.FECHA_INICIO'
    END;
    v_dir := CASE WHEN lower(coalesce(p_sort_dir, '')) = 'asc' THEN 'ASC' ELSE 'DESC' END;

    RETURN QUERY EXECUTE format($q$
        SELECT pa.PK_TPERIODO_ACADEMICO, pa.FK_TSEDE, s.NOMBRE, pa.FK_TANO_LECTIVO,
               al.NOMBRE, pa.FK_TLV_ESTADO, est.VALOR, est.NOMBRE,
               pa.FECHA_INICIO, pa.FECHA_FIN, pa.FECHA_LIMITE_MATRICULA, pa.NOMBRE,
               pa.FK_TLV_JORNADA, jor.VALOR, jor.NOMBRE, pa.RESERVA, pa.BLOQUES_POR_DEFECTO,
               pa.HORA_INICIO, pa.HORA_FIN, count(*) OVER()::BIGINT
          FROM academico_test.TPERIODO_ACADEMICO pa
          JOIN academico_test.TSEDE s          ON s.PK_TSEDE = pa.FK_TSEDE
          JOIN academico_test.TANO_LECTIVO al  ON al.PK_ANO_LECTIVO = pa.FK_TANO_LECTIVO
          JOIN academico_test.TLISTA_VALOR est ON est.PK_LISTA_VALOR = pa.FK_TLV_ESTADO
          JOIN academico_test.TLISTA_VALOR jor ON jor.PK_LISTA_VALOR = pa.FK_TLV_JORNADA
         WHERE pa.ACTIVE = TRUE
           AND ($1 IS NULL OR pa.FK_TSEDE = $1)
           AND ($2 IS NULL OR s.NOMBRE ILIKE '%%' || $2 || '%%')
           AND ($3 IS NULL OR al.NOMBRE = $3)
           AND ($4 IS NULL OR pa.FK_TLV_ESTADO = $4)
           AND ($5 IS NULL OR pa.FECHA_INICIO >= $5)
           AND ($6 IS NULL OR pa.FECHA_INICIO <= $6)
           -- Alcance por rol: global (1/2/3) ve todo; establecimiento (7/8/9)
           -- el suyo; SEDE (11 coordinador) solo la sede exacta del periodo.
           AND (academico_test.fn_periodo_usuario_global($7)
                OR s.FK_TESTABLECIMIENTO IN (
                    SELECT establecimiento_id
                      FROM academico_test.fn_periodo_usuario_establecimientos($7))
                OR pa.FK_TSEDE IN (
                    SELECT sede_id FROM academico_test.fn_periodo_usuario_sedes($7)))
         ORDER BY %s %s, pa.PK_TPERIODO_ACADEMICO DESC
         LIMIT NULLIF($9, 0)
        OFFSET COALESCE($8, 0) * COALESCE(NULLIF($9, 0), 0)
    $q$, v_col, v_dir)
    USING p_fk_sede, p_nombre_sede, p_ano, p_fk_estado, p_fecha_desde,
          p_fecha_hasta, p_pk_usuario, p_page_index, p_page_size;
END;
$$;

-- ---------------------------------------------------------------------------
-- fn_periodo_detalle — un periodo por PK (mismos campos que el listado).
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_periodo_detalle(BIGINT, BIGINT);
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_detalle(
    p_pk_periodo BIGINT, p_pk_usuario BIGINT DEFAULT NULL
)
RETURNS TABLE (
    id BIGINT, sede_id BIGINT, sede_name VARCHAR, school_year_id BIGINT,
    school_year_name VARCHAR, status_id BIGINT, status VARCHAR, status_name VARCHAR,
    start_date DATE, end_date DATE, enrollment_deadline DATE, name VARCHAR,
    jornada_id BIGINT, jornada VARCHAR, jornada_name VARCHAR,
    reserva bool_sn, default_blocks_count BIGINT,
    schedule_start_time TIME, schedule_end_time TIME, descansos jsonb
)
LANGUAGE sql STABLE AS $$
    SELECT pa.PK_TPERIODO_ACADEMICO, pa.FK_TSEDE, s.NOMBRE, pa.FK_TANO_LECTIVO,
           al.NOMBRE, pa.FK_TLV_ESTADO, est.VALOR, est.NOMBRE,
           pa.FECHA_INICIO, pa.FECHA_FIN, pa.FECHA_LIMITE_MATRICULA, pa.NOMBRE,
           pa.FK_TLV_JORNADA, jor.VALOR, jor.NOMBRE, pa.RESERVA, pa.BLOQUES_POR_DEFECTO,
           pa.HORA_INICIO, pa.HORA_FIN,
           -- Descansos activos del periodo como [{startTime, endTime}] en HH:MI,
           -- ordenados por hora de inicio. '[]' si no hay.
           COALESCE((
               SELECT jsonb_agg(
                          jsonb_build_object(
                              'startTime', to_char(d.HORA_INICIO, 'HH24:MI'),
                              'endTime',   to_char(d.HORA_FIN,    'HH24:MI'))
                          ORDER BY d.HORA_INICIO)
                 FROM academico_test.TDESCANSOS d
                WHERE d.FK_TPERIODO_ACADEMICO = pa.PK_TPERIODO_ACADEMICO
                  AND d.ACTIVE = TRUE
           ), '[]'::jsonb)
      FROM academico_test.TPERIODO_ACADEMICO pa
      JOIN academico_test.TSEDE s          ON s.PK_TSEDE = pa.FK_TSEDE
      JOIN academico_test.TANO_LECTIVO al  ON al.PK_ANO_LECTIVO = pa.FK_TANO_LECTIVO
      JOIN academico_test.TLISTA_VALOR est ON est.PK_LISTA_VALOR = pa.FK_TLV_ESTADO
      JOIN academico_test.TLISTA_VALOR jor ON jor.PK_LISTA_VALOR = pa.FK_TLV_JORNADA
     WHERE pa.PK_TPERIODO_ACADEMICO = p_pk_periodo AND pa.ACTIVE = TRUE
       AND academico_test.fn_periodo_usuario_puede_ver(p_pk_usuario, p_pk_periodo);
$$;

-- ---------------------------------------------------------------------------
-- fn_periodo_anteriores_por_sede — candidatos a "periodo anterior" para el
-- formulario: periodos activos de la sede dada, dentro del alcance del usuario,
-- excluyendo (opcional) el periodo que se esta editando. Ordenados por fecha
-- de inicio desc. Sin gate de escritura (es un picker de lectura).
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_periodo_anteriores_por_sede(BIGINT, BIGINT, BIGINT);
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_anteriores_por_sede(
    p_fk_sede          BIGINT,
    p_excluir_periodo  BIGINT DEFAULT NULL,
    p_pk_usuario       BIGINT DEFAULT NULL
)
RETURNS TABLE (id BIGINT, name VARCHAR, start_date DATE)
LANGUAGE sql STABLE AS $$
    SELECT pa.PK_TPERIODO_ACADEMICO, pa.NOMBRE, pa.FECHA_INICIO
      FROM academico_test.TPERIODO_ACADEMICO pa
     WHERE pa.FK_TSEDE = p_fk_sede
       AND pa.ACTIVE = TRUE
       AND (p_excluir_periodo IS NULL OR pa.PK_TPERIODO_ACADEMICO <> p_excluir_periodo)
       AND academico_test.fn_periodo_usuario_puede_ver(p_pk_usuario, pa.PK_TPERIODO_ACADEMICO)
     ORDER BY pa.FECHA_INICIO DESC;
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
    IF NOT academico_test.fn_periodo_usuario_puede_gestionar(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    SELECT HORA_INICIO, HORA_FIN INTO v_pi, v_pf
      FROM academico_test.TPERIODO_ACADEMICO WHERE PK_TPERIODO_ACADEMICO = p_fk_periodo;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe el periodo academico %', p_fk_periodo USING ERRCODE = 'P0002';
    END IF;
    IF NOT academico_test.fn_periodo_usuario_puede_escribir(p_pk_usuario_solicitante, (
             SELECT s.FK_TESTABLECIMIENTO
               FROM academico_test.TPERIODO_ACADEMICO pa
               JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
              WHERE pa.PK_TPERIODO_ACADEMICO = p_fk_periodo)) THEN
        RAISE EXCEPTION 'El usuario no puede gestionar periodos de este establecimiento'
            USING ERRCODE = '42501';
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
    IF NOT academico_test.fn_periodo_usuario_puede_gestionar(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;
    -- Alcance fino: el establecimiento del periodo del descanso debe estar en su alcance.
    IF NOT academico_test.fn_periodo_usuario_puede_escribir(p_pk_usuario_solicitante, (
             SELECT s.FK_TESTABLECIMIENTO
               FROM academico_test.TDESCANSOS d
               JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.PK_TPERIODO_ACADEMICO = d.FK_TPERIODO_ACADEMICO
               JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
              WHERE d.PK_TDESCANSOS = p_pk_descanso)) THEN
        RAISE EXCEPTION 'El usuario no puede gestionar periodos de este establecimiento'
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

-- Borrado multiple: intenta cada id; salta los bloqueados (dependencias/no existe).
-- Devuelve una fila por cada id recibido: eliminado=TRUE si el soft delete
-- corrio, o FALSE con error_code (SQLSTATE) y error_mensaje del motivo. Cada
-- id corre en su propia subtransaccion (BEGIN...EXCEPTION), asi que un fallo
-- no revierte a los que si se pudieron eliminar.
DROP FUNCTION IF EXISTS academico_test.fn_periodo_bulk_delete(BIGINT[], BIGINT);
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_bulk_delete(
    p_ids BIGINT[], p_pk_usuario_solicitante BIGINT
)
RETURNS TABLE (id BIGINT, eliminado BOOLEAN, error_code TEXT, error_mensaje TEXT)
LANGUAGE plpgsql AS $$
DECLARE v_id BIGINT; v_state TEXT; v_msg TEXT;
BEGIN
    IF NOT academico_test.fn_periodo_usuario_puede_gestionar(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;
    IF p_ids IS NULL THEN RETURN; END IF;
    FOREACH v_id IN ARRAY p_ids LOOP
        BEGIN
            PERFORM academico_test.fn_periodo_soft_delete(v_id, p_pk_usuario_solicitante);
            id := v_id; eliminado := TRUE; error_code := NULL; error_mensaje := NULL;
            RETURN NEXT;
        EXCEPTION WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
            id := v_id; eliminado := FALSE; error_code := v_state; error_mensaje := v_msg;
            RETURN NEXT;
        END;
    END LOOP;
    RETURN;
END;
$$;
