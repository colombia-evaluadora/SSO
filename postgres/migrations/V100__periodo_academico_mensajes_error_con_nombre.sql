CREATE OR REPLACE FUNCTION academico_test.fn_periodo_crear(
    p_fk_sede BIGINT,
    p_fk_estado BIGINT,
    p_fecha_inicio DATE,
    p_fecha_fin DATE,
    p_fecha_limite_matricula DATE,
    p_fk_jornada BIGINT,
    p_hora_inicio TIME,
    p_hora_fin TIME,
    p_reserva academico_test.bool_sn DEFAULT 'S',
    p_bloques_por_defecto BIGINT DEFAULT 0,
    p_fk_periodo_anterior BIGINT DEFAULT NULL,
    p_descanso_inicio TIME[] DEFAULT NULL,
    p_descanso_fin TIME[] DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_establecimiento    BIGINT;
    v_nombre_sede        VARCHAR(130);
    v_nombre_ano         VARCHAR(50);
    v_nombre_jornada     TEXT;
    v_nombre_estado      TEXT;
    v_categoria_jornada  VARCHAR(30);
    v_categoria_estado   VARCHAR(30);
    v_ano_id             BIGINT;
    v_id                 BIGINT;
    v_tmp_nombre         TEXT;
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
    c_modo_redondear       CONSTANT BIGINT := 515;
    c_criterio_asignatura  CONSTANT BIGINT := 264;
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

    -- 3. Establecimiento y nombre de la sede (debe estar activa).
    SELECT FK_TESTABLECIMIENTO, NOMBRE INTO v_establecimiento, v_nombre_sede
      FROM academico_test.TSEDE WHERE PK_TSEDE = p_fk_sede AND ACTIVE = TRUE;
    IF v_establecimiento IS NULL THEN
        SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TSEDE WHERE PK_TSEDE = p_fk_sede;
        IF v_tmp_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'La sede "%" existe pero esta inactiva', v_tmp_nombre USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'La sede seleccionada no existe' USING ERRCODE = '23503';
        END IF;
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
            SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TPERIODO_ACADEMICO
             WHERE PK_TPERIODO_ACADEMICO = p_fk_periodo_anterior;
            IF v_tmp_nombre IS NOT NULL THEN
                RAISE EXCEPTION 'El periodo academico anterior "%" existe pero esta inactivo o pertenece a otro establecimiento',
                    v_tmp_nombre USING ERRCODE = '22023';
            ELSE
                RAISE EXCEPTION 'El periodo academico anterior seleccionado no existe' USING ERRCODE = '22023';
            END IF;
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
        RAISE EXCEPTION 'La sede "%" ya tiene un periodo academico activo para el año lectivo %',
            v_nombre_sede, v_nombre_ano USING ERRCODE = '23505';
    END IF;

    -- 6a. Validar FK_TLV_ESTADO — debe existir y pertenecer a la categoria
    --     ESTADOPERIODO en TLISTA_VALOR.
    SELECT VALOR, CATEGORIA INTO v_nombre_estado, v_categoria_estado
      FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_fk_estado;
    IF v_nombre_estado IS NULL THEN
        RAISE EXCEPTION 'El estado seleccionado no existe' USING ERRCODE = '23503';
    END IF;
    IF v_categoria_estado <> 'ESTADOPERIODO' THEN
        RAISE EXCEPTION 'El estado "%" no pertenece a la categoria ESTADOPERIODO (es %)',
            v_nombre_estado, v_categoria_estado USING ERRCODE = '22023';
    END IF;

    -- 6b. Nombre derivado de la jornada — debe existir y pertenecer a la
    --     categoria JORNADA en TLISTA_VALOR.
    SELECT VALOR, CATEGORIA INTO v_nombre_jornada, v_categoria_jornada
      FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_fk_jornada;
    IF v_nombre_jornada IS NULL THEN
        RAISE EXCEPTION 'La jornada seleccionada no existe' USING ERRCODE = '23503';
    END IF;
    IF v_categoria_jornada <> 'JORNADA' THEN
        RAISE EXCEPTION 'La jornada "%" no pertenece a la categoria JORNADA (es %)',
            v_nombre_jornada, v_categoria_jornada USING ERRCODE = '22023';
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

    -- 8. Criterio de evaluacion por defecto (1:1, PK compartida). Restauradas
    -- FK_TLV_CRITERIO_ASIGNATURA, FK_TLV_MODO_REDONDEAR y
    -- PORCENTAJE_MAXIMO_RECUPERACION, que V100 había perdido.
    INSERT INTO academico_test.TCRITERIO_EVALUACION (
        PK_TCRITERIO_EVALUACION, FK_TLV_FORMATO_CALIFICACION, FK_TLV_ELEMENTO_DEF,
        FK_TLV_MODIF_FINAL_PERACA, FK_TLV_CRITERIO_ASIGNATURA, FK_TLV_CRITERIO_FINAL,
        FK_TLV_CRITERIO_AREA, FK_TLV_DESEMPENO_SIN_CALIF, FK_TLV_MODO_REDONDEAR,
        PORCENTAJE_MAXIMO_RECUPERACION, CREATED_BY
    ) VALUES (
        v_id, c_formato_calif, c_elemento_def, c_modif_final_peraca, c_criterio_asignatura,
        c_criterio_final, c_criterio_area, c_desempeno_sin_calif, c_modo_redondear, 1, v_audit
    )
    ON CONFLICT (PK_TCRITERIO_EVALUACION) DO NOTHING;

    -- 9. Descansos anidados (opcional). Validan contra el horario del periodo.
    IF p_descanso_inicio IS NOT NULL THEN
        IF p_descanso_fin IS NULL
           OR COALESCE(array_length(p_descanso_inicio, 1), 0) <> COALESCE(array_length(p_descanso_fin, 1), 0) THEN
            RAISE EXCEPTION 'Los arreglos de inicio/fin de descansos deben tener la misma longitud'
                USING ERRCODE = '22023';
        END IF;
        IF array_length(p_descanso_inicio, 1) IS NOT NULL THEN
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
    END IF;

    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_actualizar(
    p_pk_periodo              BIGINT,
    p_fk_estado               BIGINT   DEFAULT NULL,
    p_fk_sede                 BIGINT   DEFAULT NULL,
    p_fecha_inicio            DATE     DEFAULT NULL,
    p_fecha_fin               DATE     DEFAULT NULL,
    p_fecha_limite_matricula  DATE     DEFAULT NULL,
    p_fk_jornada              BIGINT   DEFAULT NULL,
    p_reserva                 academico_test.bool_sn DEFAULT NULL,
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
    v_nombre_sede     VARCHAR(130);
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
    v_nombre_estado   TEXT;
    v_categoria_jornada VARCHAR(30);
    v_categoria_estado  VARCHAR(30);
    v_ano_id          BIGINT;
    v_tmp_nombre      TEXT;
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
        RAISE EXCEPTION 'No existe el periodo academico' USING ERRCODE = 'P0002';
    END IF;
    IF r.ACTIVE = FALSE THEN
        RAISE EXCEPTION 'El periodo academico "%" esta inactivo; no se puede actualizar', r.NOMBRE
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
        SELECT FK_TESTABLECIMIENTO, NOMBRE INTO v_est_new, v_nombre_sede
          FROM academico_test.TSEDE WHERE PK_TSEDE = v_sede AND ACTIVE = TRUE;
        IF v_est_new IS NULL THEN
            SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TSEDE WHERE PK_TSEDE = v_sede;
            IF v_tmp_nombre IS NOT NULL THEN
                RAISE EXCEPTION 'La sede "%" existe pero esta inactiva', v_tmp_nombre USING ERRCODE = '23503';
            ELSE
                RAISE EXCEPTION 'La sede seleccionada no existe' USING ERRCODE = '23503';
            END IF;
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

    -- Re-resolver año lectivo (por si cambio la fecha de inicio) y el nombre
    -- de la sede efectiva (para el mensaje de conflicto de abajo, si aplica).
    SELECT FK_TESTABLECIMIENTO, NOMBRE INTO v_est_new, v_nombre_sede
      FROM academico_test.TSEDE WHERE PK_TSEDE = v_sede;

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
            SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TPERIODO_ACADEMICO
             WHERE PK_TPERIODO_ACADEMICO = p_fk_periodo_anterior;
            IF v_tmp_nombre IS NOT NULL THEN
                RAISE EXCEPTION 'El periodo academico anterior "%" existe pero esta inactivo o pertenece a otro establecimiento',
                    v_tmp_nombre USING ERRCODE = '22023';
            ELSE
                RAISE EXCEPTION 'El periodo academico anterior seleccionado no existe' USING ERRCODE = '22023';
            END IF;
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
        RAISE EXCEPTION 'La sede "%" ya tiene un periodo academico activo para el año lectivo %',
            v_nombre_sede, v_nombre_ano USING ERRCODE = '23505';
    END IF;

    -- Validar FK_TLV_ESTADO efectivo — debe existir y pertenecer a la categoria
    -- ESTADOPERIODO en TLISTA_VALOR.
    SELECT VALOR, CATEGORIA INTO v_nombre_estado, v_categoria_estado
      FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = v_estado;
    IF v_categoria_estado IS NULL THEN
        RAISE EXCEPTION 'El estado seleccionado no existe' USING ERRCODE = '23503';
    END IF;
    IF v_categoria_estado <> 'ESTADOPERIODO' THEN
        RAISE EXCEPTION 'El estado "%" no pertenece a la categoria ESTADOPERIODO (es %)',
            v_nombre_estado, v_categoria_estado USING ERRCODE = '22023';
    END IF;

    -- Nombre derivado de la jornada — debe existir y pertenecer a la categoria
    -- JORNADA en TLISTA_VALOR.
    SELECT VALOR, CATEGORIA INTO v_nombre_jornada, v_categoria_jornada
      FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = v_jornada;
    IF v_nombre_jornada IS NULL THEN
        RAISE EXCEPTION 'La jornada seleccionada no existe' USING ERRCODE = '23503';
    END IF;
    IF v_categoria_jornada <> 'JORNADA' THEN
        RAISE EXCEPTION 'La jornada "%" no pertenece a la categoria JORNADA (es %)',
            v_nombre_jornada, v_categoria_jornada USING ERRCODE = '22023';
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

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_soft_delete(p_pk_periodo bigint, p_pk_usuario_solicitante bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_activo BOOLEAN;
    v_nombre_periodo VARCHAR(200);
    v_audit  VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    IF NOT academico_test.fn_periodo_usuario_puede_gestionar(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    SELECT ACTIVE, NOMBRE INTO v_activo, v_nombre_periodo
      FROM academico_test.TPERIODO_ACADEMICO WHERE PK_TPERIODO_ACADEMICO = p_pk_periodo;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe el periodo academico' USING ERRCODE = 'P0002';
    END IF;
    IF v_activo = FALSE THEN
        RAISE EXCEPTION 'El periodo academico "%" ya esta inactivo', v_nombre_periodo USING ERRCODE = '22023';
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
        RAISE EXCEPTION 'No se puede eliminar el periodo academico "%": existen horarios/asistencias configurados', v_nombre_periodo
            USING ERRCODE = '23503';
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.TPLAN pl
          JOIN academico_test.TGRADO gr ON gr.PK_TGRADO = pl.FK_TGRADO AND gr.ACTIVE = TRUE
         WHERE gr.FK_TPERIODO_ACADEMICO = p_pk_periodo AND pl.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el periodo academico "%": existen planes de estudio asociados', v_nombre_periodo
            USING ERRCODE = '23503';
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.TPERIODO_EVALUACION pe
         WHERE pe.FK_TPERIODO_ACADEMICO = p_pk_periodo AND pe.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el periodo academico "%": existen periodos de evaluacion asociados', v_nombre_periodo
            USING ERRCODE = '23503';
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.TNIVEL_ESCALA ne
         WHERE ne.FK_PERIODO_ACADEMICO = p_pk_periodo AND ne.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el periodo academico "%": existen escalas de valoracion asociadas', v_nombre_periodo
            USING ERRCODE = '23503';
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.TDOCENTE_ASIGNATURA da
         WHERE da.FK_TPERIODO_ACADEMICO = p_pk_periodo AND da.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el periodo academico "%": existen asignaciones academicas asociadas', v_nombre_periodo
            USING ERRCODE = '23503';
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.TAREA t
         WHERE t.FK_TPERIODO_ACADEMICO = p_pk_periodo AND t.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el periodo academico "%": existen areas academicas configuradas', v_nombre_periodo
            USING ERRCODE = '23503';
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.TGRADO gr
         WHERE gr.FK_TPERIODO_ACADEMICO = p_pk_periodo AND gr.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el periodo academico "%": existen grados/grupos configurados', v_nombre_periodo
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
$function$;

CREATE OR REPLACE FUNCTION academico_test.fn_descanso_agregar(p_fk_periodo bigint, p_hora_inicio time without time zone, p_hora_fin time without time zone, p_pk_usuario_solicitante bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
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
        RAISE EXCEPTION 'No existe el periodo academico' USING ERRCODE = 'P0002';
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
$function$;

CREATE OR REPLACE FUNCTION academico_test.fn_descanso_eliminar(p_pk_descanso bigint, p_pk_usuario_solicitante bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_n INT;
    v_tmp_hi TIME;
    v_tmp_hf TIME;
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
        SELECT HORA_INICIO, HORA_FIN INTO v_tmp_hi, v_tmp_hf
          FROM academico_test.TDESCANSOS WHERE PK_TDESCANSOS = p_pk_descanso;
        IF v_tmp_hi IS NOT NULL THEN
            RAISE EXCEPTION 'El descanso de % a % existe pero ya esta inactivo', v_tmp_hi, v_tmp_hf
                USING ERRCODE = 'P0002';
        ELSE
            RAISE EXCEPTION 'El descanso seleccionado no existe' USING ERRCODE = 'P0002';
        END IF;
    END IF;
    RETURN p_pk_descanso;
END;
$function$;
