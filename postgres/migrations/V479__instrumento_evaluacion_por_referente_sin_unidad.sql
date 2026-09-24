-- ===========================================================================
-- V479 - El instrumento de evaluacion lo admite el REFERENTE, no la unidad.
-- V476 generalizo el gate de ES_EVALUATIVA al caso "sin unidad" (el referente
-- se deriva del grado del grupo y la asignatura), pero dejo la sub-rama del
-- instrumento con el "IF unidad IS NULL THEN RAISE" heredado de V224: una
-- actividad podia quedar evaluativa y a la vez sin poder decir con que se
-- evalua. Se cierra en los helpers, en fn_actividad_instrumento_contexto_assert
-- y en campos_disponibles (que deriva el nivel para apagar Preescolar).
-- Crear/editar se parten en wrapper (gate + auditoria) y nucleo _interno con
-- reglas fn_actividad_validar_*; una actividad vive en UN periodo de evaluacion.
-- Depende de: V66, V214.2, V224, V277, V451, V460, V476.
-- ===========================================================================
SET search_path TO academico_test, public;

-- ---------------------------------------------------------------------------
-- 1) El TIPO_EVALUACION del referente aplicable, con o sin unidad.
--    Mismo reparto que fn_actividad_contexto_evaluativo (V476): con unidad
--    manda la unidad; sin ella el referente se deriva del (grado del grupo,
--    asignatura). Sin esto el filtrado de instrumentos se quedaba sin tipo en
--    cuanto la actividad no tenia unidad y ofrecia los cuatro.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_contexto_tipo_evaluacion(
    p_fk_tgrupo      BIGINT,
    p_fk_tasignatura BIGINT,
    p_fk_tunidad     BIGINT
)
RETURNS VARCHAR
LANGUAGE sql
STABLE
AS $$
    SELECT CASE
        WHEN p_fk_tunidad IS NOT NULL
            THEN academico_test.fn_unidad_referente_tipo_evaluacion(p_fk_tunidad)
        ELSE (
            SELECT lv.VALOR
              FROM academico_test.TGRUPO g
              JOIN academico_test.TREFERENTE_CURRICULAR rc
                ON rc.PK_REFERENTE_CURRICULAR =
                   academico_test.fn_unidad_referente_aplicable(
                       g.FK_TGRADO, p_fk_tasignatura, NULL)
              JOIN academico_test.TLISTA_VALOR lv
                ON lv.PK_LISTA_VALOR = rc.FK_TLV_TIPO_EVALUACION
             WHERE g.PK_TGRUPO = p_fk_tgrupo
               AND rc.ACTIVE = TRUE)
    END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_contexto_tipo_evaluacion(BIGINT, BIGINT, BIGINT)
    IS 'VALOR de TLISTA_VALOR CATEGORIA=TIPO_EVALUACION (CUALITATIVA / CUANTITATIVA / CUANTITATIVA_CUALITATIVA, V212) del referente curricular que le aplica a una actividad, o NULL si no hay de donde decidir. Con p_fk_tunidad manda la unidad (fn_unidad_referente_tipo_evaluacion, V214.2); sin ella el referente se DERIVA del (grado del grupo, asignatura) con fn_unidad_referente_aplicable (V451), el mismo reparto que fn_actividad_contexto_evaluativo (V476) hace para el enfoque. Es la contraparte "que tipo" de aquella: una decide si hay nota, esta con que instrumentos se puede evaluar (fn_instrumento_permitido_por_tipo_evaluacion). NULL se interpreta corriente abajo como "sin restriccion": se ofrecen los cuatro instrumentos. Sin gate: helper de lectura invocado desde funciones que ya gatearon. V479.';

-- fn_actividad_referente_tipo_evaluacion deja de exigir unidad: delega.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_referente_tipo_evaluacion(
    p_pk_tactividad   BIGINT
)
RETURNS VARCHAR
LANGUAGE sql
STABLE
AS $$
    SELECT academico_test.fn_actividad_contexto_tipo_evaluacion(
               a.FK_TGRUPO, a.FK_TASIGNATURA, a.FK_TUNIDAD)
      FROM academico_test.TACTIVIDAD a
     WHERE a.PK_TACTIVIDAD = p_pk_tactividad
       AND a.ACTIVE = TRUE;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_referente_tipo_evaluacion(BIGINT)
    IS 'TIPO_EVALUACION (VALOR) del referente curricular que le aplica a una actividad. NULL si la actividad no existe/esta inactiva, o si el referente no se puede resolver o no tiene tipo. V214.2. V479 -- deja de entrar exclusivamente por TACTIVIDAD.FK_TUNIDAD y delega en fn_actividad_contexto_tipo_evaluacion, que sin unidad deriva el referente del (grado del grupo, asignatura): una actividad sin unidad tenia tipo NULL y por tanto ningun filtro de instrumentos.';

-- fn_actividad_evaluacion_requerida: una sola regla, la de V476.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_evaluacion_requerida(
    p_pk_tactividad   BIGINT
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    -- FALSE (no NULL) si la actividad no existe o esta inactiva. Que hacer
    -- cuando SI existe lo decide fn_actividad_contexto_evaluativo, duena
    -- unica de "este contexto admite nota".
    SELECT COALESCE(
        (SELECT academico_test.fn_actividad_contexto_evaluativo(
                    a.FK_TGRUPO, a.FK_TASIGNATURA, a.FK_TUNIDAD)
           FROM academico_test.TACTIVIDAD a
          WHERE a.PK_TACTIVIDAD = p_pk_tactividad
            AND a.ACTIVE = TRUE),
        FALSE
    );
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_evaluacion_requerida(BIGINT)
    IS 'TRUE si la actividad admite EVALUACION CON NOTA segun el referente curricular que le aplica (condicion dinamica "actividad -> evaluacion"); FALSE si la actividad no existe o esta inactiva (nunca NULL). No gatea VER: helper booleano puro. V214.2. V479 -- delega en fn_actividad_contexto_evaluativo (V476) en vez de repetir "unidad con referente EVALUATIVO": antes devolvia FALSE por el solo hecho de no tener unidad, aunque el referente de su grado y asignatura fuera EVALUATIVO, y era lo que dejaba a una actividad suelta sin instrumentos. Contrapartida deliberada: cuando no hay de donde decidir (sin grupo, o sin referente activo) devuelve TRUE, el mismo default permisivo que ya aplica la escritura, en vez del FALSE de antes.';

-- ---------------------------------------------------------------------------
-- 2) La regla del instrumento, en un solo sitio. Nucleo sin gate: lo invocan
--    fn_actividad_crear y fn_actividad_actualizar, que ya gatearon.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_instrumento_contexto_assert(
    p_fk_tlv_instrumento  BIGINT,
    p_fk_tgrupo           BIGINT,
    p_fk_tasignatura      BIGINT,
    p_fk_tunidad          BIGINT,
    p_titulo              VARCHAR DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_que VARCHAR := COALESCE('La actividad "' || p_titulo || '"', 'La actividad');
BEGIN
    IF p_fk_tlv_instrumento IS NULL THEN
        RETURN;
    END IF;

    IF academico_test.fn_actividad_contexto_evaluativo(
           p_fk_tgrupo, p_fk_tasignatura, p_fk_tunidad) THEN
        RETURN;
    END IF;

    IF p_fk_tunidad IS NOT NULL THEN
        RAISE EXCEPTION '% tiene configurado el instrumento de evaluacion %, pero la unidad "%" se rige por un referente curricular en el que el aprendizaje se valora con observaciones y no con instrumentos. Retirale el instrumento a la actividad o llevala a una unidad que si los admita.',
            v_que, academico_test.fn_instrumento_nombre(p_fk_tlv_instrumento),
            (SELECT NOMBRE FROM academico_test.TUNIDAD WHERE PK_TUNIDAD = p_fk_tunidad)
            USING ERRCODE = '22023';
    ELSE
        RAISE EXCEPTION '% tiene configurado el instrumento de evaluacion %, pero el referente curricular que le corresponde a su grado y asignatura valora el aprendizaje con observaciones y no con instrumentos. Retirale el instrumento a la actividad.',
            v_que, academico_test.fn_instrumento_nombre(p_fk_tlv_instrumento)
            USING ERRCODE = '22023';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_instrumento_contexto_assert(BIGINT, BIGINT, BIGINT, BIGINT, VARCHAR)
    IS 'Nucleo (sin gate de permisos) de la condicion dinamica "actividad -> evaluacion": aborta con 22023 si se configura un instrumento de evaluacion en un contexto cuyo referente curricular es Formativo. No-op si no hay instrumento. El contexto lo decide fn_actividad_contexto_evaluativo (V476): con unidad manda la unidad, sin ella el referente se deriva del (grado del grupo, asignatura) -- por eso NO tener unidad ya no es motivo de rechazo, que era el bug: V476 dejaba crear una actividad evaluativa sin unidad pero esta rama seguia exigiendola, y un PATCH que desvinculaba la unidad de una actividad con instrumento heredado fallaba sin salida. p_titulo solo adorna el mensaje. Lo invocan fn_actividad_crear y fn_actividad_actualizar, que ya gatearon CREAR/EDITAR sobre PLANEADOR. V479.';

-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- 1) Ancla territorial de la actividad: mismo reparto que el alcance, el
--    grado sale del grupo y, sin grupo, de la unidad.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_grado(
    p_fk_tgrupo  BIGINT,
    p_fk_tunidad BIGINT
)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(
        (SELECT gr.FK_TGRADO FROM academico_test.TGRUPO gr
          WHERE gr.PK_TGRUPO = p_fk_tgrupo AND gr.ACTIVE),
        (SELECT u.FK_TGRADO FROM academico_test.TUNIDAD u
          WHERE u.PK_TUNIDAD = p_fk_tunidad AND u.ACTIVE));
$$;
COMMENT ON FUNCTION academico_test.fn_actividad_grado(BIGINT, BIGINT)
    IS 'INTERNO: grado de una actividad (del grupo o, sin grupo, de la unidad). Lo usan fn_actividad_sede y fn_actividad_validar_periodo_evaluacion_unico. NULL para la actividad huerfana.';

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_sede(
    p_fk_tgrupo  BIGINT,
    p_fk_tunidad BIGINT
)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT pa.FK_TSEDE
      FROM academico_test.TGRADO g
      JOIN academico_test.TPERIODO_ACADEMICO pa
        ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
     WHERE g.PK_TGRADO = academico_test.fn_actividad_grado(p_fk_tgrupo, p_fk_tunidad);
$$;
COMMENT ON FUNCTION academico_test.fn_actividad_sede(BIGINT, BIGINT)
    IS 'INTERNO: sede de una actividad, para la etiqueta de auditoria de fn_actividad_crear/_actualizar. NULL si no tiene ancla.';

-- ---------------------------------------------------------------------------
-- 2) Reglas. Cada una lanza o no hace nada; las comparten alta y PATCH, que
--    se las pasan con los valores RESULTANTES.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_fechas_orden(
    p_fecha_inicio DATE,
    p_fecha_cierre DATE
)
RETURNS VOID
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_fecha_inicio IS NOT NULL AND p_fecha_cierre IS NOT NULL
       AND p_fecha_cierre < p_fecha_inicio THEN
        RAISE EXCEPTION 'La fecha de cierre (%) no puede ser anterior a la de inicio (%)',
            p_fecha_cierre, p_fecha_inicio USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_periodo_evaluacion_unico(
    p_fk_tgrupo    BIGINT,
    p_fk_tunidad   BIGINT,
    p_fecha_inicio DATE,
    p_fecha_cierre DATE
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_total    INT;
    v_periodos TEXT;
    v_primero  RECORD;
BEGIN
    IF p_fecha_inicio IS NULL OR p_fecha_cierre IS NULL THEN
        RETURN;
    END IF;

    -- Se cuentan los periodos que SOLAPAN el rango, no solo los que contienen
    -- sus extremos: un cierre que cae en el hueco entre dos cortes tambien
    -- sale del periodo en que empezo.
    SELECT count(*),
           string_agg(format('%s (%s a %s)', pe.NOMBRE, pe.FECHA_INICIO, pe.FECHA_FIN),
                      ', ' ORDER BY pe.FECHA_INICIO)
      INTO v_total, v_periodos
      FROM academico_test.TGRADO g
      JOIN academico_test.TPERIODO_EVALUACION pe
        ON pe.FK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
       AND pe.ACTIVE = TRUE
     WHERE g.PK_TGRADO = academico_test.fn_actividad_grado(p_fk_tgrupo, p_fk_tunidad)
       AND pe.FECHA_INICIO <= p_fecha_cierre
       AND pe.FECHA_FIN    >= p_fecha_inicio;

    IF v_total > 1 THEN
        SELECT pe.NOMBRE, pe.FECHA_FIN INTO v_primero
          FROM academico_test.TGRADO g
          JOIN academico_test.TPERIODO_EVALUACION pe
            ON pe.FK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
           AND pe.ACTIVE = TRUE
         WHERE g.PK_TGRADO = academico_test.fn_actividad_grado(p_fk_tgrupo, p_fk_tunidad)
           AND pe.FECHA_INICIO <= p_fecha_cierre
           AND pe.FECHA_FIN    >= p_fecha_inicio
         ORDER BY pe.FECHA_INICIO
         LIMIT 1;

        RAISE EXCEPTION 'La actividad no puede abarcar varios periodos de evaluacion: del % al % pasa por %',
            p_fecha_inicio, p_fecha_cierre, v_periodos
            USING ERRCODE = '22023',
                  HINT    = format('Si empieza en %s, la fecha de cierre debe ser a mas tardar el %s',
                                   v_primero.NOMBRE, v_primero.FECHA_FIN);
    END IF;
END;
$$;
COMMENT ON FUNCTION academico_test.fn_actividad_validar_periodo_evaluacion_unico(BIGINT, BIGINT, DATE, DATE)
    IS 'INTERNO: 22023 si [fecha_inicio, fecha_cierre] solapa mas de un periodo de evaluacion activo del periodo academico del grado de la actividad. La nota de una actividad se imputa a un solo periodo (fn_actividad_periodo_evaluacion), asi que no puede repartirse entre dos. Sin alguna de las fechas o sin ancla no aplica. Lo usan fn_actividad_crear_interno y fn_actividad_actualizar_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_referencias_activas(
    p_fk_tasignatura BIGINT,
    p_fk_tgrupo      BIGINT,
    p_fk_tunidad     BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_fk_tasignatura IS NOT NULL AND NOT EXISTS (SELECT 1 FROM academico_test.TASIGNATURA
                    WHERE PK_TASIGNATURA = p_fk_tasignatura AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'La asignatura seleccionada no esta disponible' USING ERRCODE = '23503';
    END IF;
    IF p_fk_tgrupo IS NOT NULL AND NOT EXISTS (SELECT 1 FROM academico_test.TGRUPO
                    WHERE PK_TGRUPO = p_fk_tgrupo AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'El grupo seleccionado no esta disponible' USING ERRCODE = '23503';
    END IF;
    IF p_fk_tunidad IS NOT NULL AND NOT EXISTS (SELECT 1 FROM academico_test.TUNIDAD
                    WHERE PK_TUNIDAD = p_fk_tunidad AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'La unidad seleccionada no esta disponible' USING ERRCODE = '23503';
    END IF;
END;
$$;

-- Evaluativa en contexto Formativo: el enfoque valora con observaciones, y un
-- 'S' dejaba la actividad calificable contra su referente.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_evaluativa_contexto(
    p_es_evaluativa  academico_test.bool_sn,
    p_ctx_evaluativo BOOLEAN,
    p_fk_tunidad     BIGINT,
    p_titulo         VARCHAR
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_es_evaluativa = 'S' AND NOT p_ctx_evaluativo THEN
        IF p_fk_tunidad IS NOT NULL THEN
            RAISE EXCEPTION 'La actividad "%" no puede ser evaluativa: la unidad "%" se rige por un referente curricular Formativo, que valora el aprendizaje con observaciones y no con nota', p_titulo,
                (SELECT NOMBRE FROM academico_test.TUNIDAD WHERE PK_TUNIDAD = p_fk_tunidad)
                USING ERRCODE = '22023';
        END IF;
        RAISE EXCEPTION 'La actividad "%" no puede ser evaluativa: el referente curricular que le corresponde a su grado y asignatura es Formativo, y valora el aprendizaje con observaciones y no con nota', p_titulo
            USING ERRCODE = '22023';
    END IF;
END;
$$;

-- El metodo de calculo de la unidad decide si el % se captura a mano
-- (Ponderar), no aplica (Promediar) o sale de NOTA_MAXIMA (Sumatoria).
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_ponderacion(
    p_ponderacion   NUMERIC,
    p_fk_tunidad    BIGINT,
    p_es_evaluativa academico_test.bool_sn,
    p_titulo        VARCHAR
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_modo VARCHAR;
BEGIN
    IF p_ponderacion IS NULL THEN
        RETURN;
    END IF;
    IF p_ponderacion < 0 OR p_ponderacion > 100 THEN
        RAISE EXCEPTION 'La ponderacion (%) debe estar entre 0 y 100', p_ponderacion USING ERRCODE = '22023';
    END IF;
    IF p_fk_tunidad IS NULL THEN
        RAISE EXCEPTION 'La ponderacion solo aplica cuando la actividad se vincula a una unidad'
            USING ERRCODE = '22023';
    END IF;
    IF p_es_evaluativa = 'N' THEN
        RAISE EXCEPTION 'La ponderacion no aplica: la actividad "%" no es evaluativa', p_titulo
            USING ERRCODE = '22023';
    END IF;

    v_modo := academico_test.fn_unidad_calculo_definitiva_modo(p_fk_tunidad);
    IF v_modo = 'PROMEDIAR' THEN
        RAISE EXCEPTION 'La unidad "%" promedia sus actividades, asi que la actividad no lleva peso (%%)',
            (SELECT NOMBRE FROM academico_test.TUNIDAD WHERE PK_TUNIDAD = p_fk_tunidad)
            USING ERRCODE = '22023';
    ELSIF v_modo = 'SUMATORIA' THEN
        RAISE EXCEPTION 'La unidad "%" suma los puntajes de sus actividades: indica el puntaje maximo de la actividad en vez del peso (%%), que se calcula solo',
            (SELECT NOMBRE FROM academico_test.TUNIDAD WHERE PK_TUNIDAD = p_fk_tunidad)
            USING ERRCODE = '22023';
    END IF;
END;
$$;

-- Backstop de U_TACTIVIDAD_1: con FK_TUNIDAD/FK_TGRUPO NULL el UNIQUE no
-- garantiza nada (NULL nunca colisiona).
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_titulo_unico(
    p_titulo           VARCHAR,
    p_fk_tunidad       BIGINT,
    p_fk_tgrupo        BIGINT,
    p_fk_tlv_jerarquia BIGINT,
    p_excluir_pk       BIGINT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM academico_test.TACTIVIDAD
         WHERE UPPER(TRIM(TITULO)) = UPPER(TRIM(p_titulo))
           AND FK_TUNIDAD       IS NOT DISTINCT FROM p_fk_tunidad
           AND FK_TGRUPO        IS NOT DISTINCT FROM p_fk_tgrupo
           AND FK_TLV_JERARQUIA = p_fk_tlv_jerarquia
           AND ACTIVE = TRUE
           AND PK_TACTIVIDAD IS DISTINCT FROM p_excluir_pk
    ) THEN
        RAISE EXCEPTION 'Ya existe una actividad activa "%" para esa unidad, grupo y jerarquia', p_titulo
            USING ERRCODE = '23505';
    END IF;
END;
$$;

-- Todas las reglas de coherencia, en el orden en que responden al cliente.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_coherencia(
    p_titulo            VARCHAR,
    p_fk_tasignatura    BIGINT,
    p_fk_tgrupo         BIGINT,
    p_fk_tunidad        BIGINT,
    p_ponderacion       NUMERIC,
    p_es_evaluativa     academico_test.bool_sn,
    p_ctx_evaluativo    BOOLEAN,
    p_es_recuperacion   BOOLEAN,
    p_fecha_inicio      DATE,
    p_fecha_cierre      DATE,
    p_duracion_estimada NUMERIC,
    p_semana_cronograma VARCHAR
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_actividad_validar_fechas_orden(p_fecha_inicio, p_fecha_cierre);
    PERFORM academico_test.fn_actividad_programacion_assert(
        p_fk_tgrupo, p_fk_tasignatura, p_fecha_inicio, p_fecha_cierre,
        p_duracion_estimada, p_semana_cronograma);
    PERFORM academico_test.fn_actividad_validar_periodo_evaluacion_unico(
        p_fk_tgrupo, p_fk_tunidad, p_fecha_inicio, p_fecha_cierre);
    PERFORM academico_test.fn_actividad_validar_ponderacion(
        p_ponderacion, p_fk_tunidad, p_es_evaluativa, p_titulo);
    IF p_es_recuperacion AND p_es_evaluativa = 'N' THEN
        RAISE EXCEPTION 'Una actividad de recuperacion debe ser evaluativa' USING ERRCODE = '22023';
    END IF;
END;
$$;
COMMENT ON FUNCTION academico_test.fn_actividad_validar_coherencia(VARCHAR, BIGINT, BIGINT, BIGINT, NUMERIC, academico_test.bool_sn, BOOLEAN, BOOLEAN, DATE, DATE, NUMERIC, VARCHAR)
    IS 'INTERNO: reglas de coherencia de una actividad sobre sus valores RESULTANTES (orden de fechas, programacion, un solo periodo de evaluacion, ponderacion, recuperacion evaluativa). Compartida por fn_actividad_crear_interno y fn_actividad_actualizar_interno; una regla nueva se agrega aqui y aplica a las dos.';

-- ---------------------------------------------------------------------------
-- 3) Alta: nucleo sin gate + wrapper con gate y etiqueta de auditoria.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_crear_interno(
    p_pk_usuario_solicitante            BIGINT,
    p_titulo                            VARCHAR(250),
    p_fk_tasignatura                    BIGINT,
    p_fk_tlv_tipo_actividad             BIGINT,
    p_fk_tlv_jerarquia                  BIGINT,
    p_descripcion                       VARCHAR(4000) DEFAULT NULL,
    p_fk_tgrupo                         BIGINT        DEFAULT NULL,
    p_fk_tunidad                        BIGINT        DEFAULT NULL,
    p_ponderacion                       NUMERIC       DEFAULT NULL,
    p_fecha_inicio                      DATE          DEFAULT NULL,
    p_fecha_cierre                      DATE          DEFAULT NULL,
    p_duracion_estimada                 NUMERIC       DEFAULT NULL,
    p_semana_cronograma                 VARCHAR(50)   DEFAULT NULL,
    p_fk_tlv_modalidad                  BIGINT        DEFAULT NULL,
    p_material_requerido                VARCHAR(4000) DEFAULT NULL,
    p_es_evaluativa                     academico_test.bool_sn DEFAULT NULL,
    p_fk_tlv_instrumento_evaluacion     BIGINT        DEFAULT NULL,
    p_descripcion_instrumento           VARCHAR(4000) DEFAULT NULL,
    p_fk_tlv_tipo_evidencia             BIGINT        DEFAULT NULL,
    p_fk_tlv_metodo_valoracion          BIGINT        DEFAULT NULL,
    p_fk_tlv_tipo_calculo               BIGINT        DEFAULT NULL,
    p_influencia                        NUMERIC       DEFAULT NULL,
    p_nota_maxima                       NUMERIC       DEFAULT NULL,
    p_requiere_archivo                  academico_test.bool_sn DEFAULT 'N',
    p_requiere_texto                    academico_test.bool_sn DEFAULT 'N',
    p_genera_evidencias                 academico_test.bool_sn DEFAULT 'N',
    p_requiere_validacion_coordinador   academico_test.bool_sn DEFAULT 'N',
    p_observaciones_docente             VARCHAR(4000) DEFAULT NULL,
    p_materiales                        JSONB         DEFAULT NULL,
    p_adaptaciones                      JSONB         DEFAULT NULL,
    p_fk_tmatriculas                    BIGINT[]      DEFAULT NULL,
    p_asignar_todo_el_grupo             BOOLEAN       DEFAULT FALSE,
    p_recuperacion                      JSONB         DEFAULT NULL,
    p_evidencias                        BIGINT[]      DEFAULT NULL,
    p_criterios                         BIGINT[]      DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_id_creado      BIGINT;
    v_ctx_evaluativo BOOLEAN;
    v_evaluativa     academico_test.bool_sn;
BEGIN
    IF NULLIF(TRIM(p_titulo), '') IS NULL THEN
        RAISE EXCEPTION 'El nombre de la actividad es obligatorio'
            USING ERRCODE = '22023', HINT = 'p_titulo no puede ser NULL ni vacio';
    END IF;
    IF p_fk_tasignatura IS NULL THEN
        RAISE EXCEPTION 'La asignatura (FK_TASIGNATURA) es obligatoria' USING ERRCODE = '22023';
    END IF;
    IF p_fk_tlv_tipo_actividad IS NULL THEN
        RAISE EXCEPTION 'El tipo de actividad (FK_TLV_TIPO_ACTIVIDAD) es obligatorio' USING ERRCODE = '22023';
    END IF;
    IF p_fk_tlv_jerarquia IS NULL THEN
        RAISE EXCEPTION 'La jerarquia (FK_TLV_JERARQUIA) es obligatoria' USING ERRCODE = '22023';
    END IF;

    PERFORM academico_test.fn_actividad_validar_referencias_activas(
        p_fk_tasignatura, p_fk_tgrupo, p_fk_tunidad);

    -- Sin valor enviado, ES_EVALUATIVA es la que le corresponde al referente.
    v_ctx_evaluativo := academico_test.fn_actividad_contexto_evaluativo(
                            p_fk_tgrupo, p_fk_tasignatura, p_fk_tunidad);
    v_evaluativa     := COALESCE(p_es_evaluativa,
                            CASE WHEN v_ctx_evaluativo THEN 'S' ELSE 'N' END);

    PERFORM academico_test.fn_actividad_validar_coherencia(
        p_titulo, p_fk_tasignatura, p_fk_tgrupo, p_fk_tunidad, p_ponderacion,
        v_evaluativa, v_ctx_evaluativo, p_recuperacion IS NOT NULL,
        p_fecha_inicio, p_fecha_cierre, p_duracion_estimada, p_semana_cronograma);

    PERFORM academico_test.fn_actividad_lv_assert(p_fk_tlv_tipo_actividad,          'TIPO_ACTIVIDAD',           'FK_TLV_TIPO_ACTIVIDAD');
    PERFORM academico_test.fn_actividad_lv_assert(p_fk_tlv_jerarquia,               'TIPO_JERARQUIA_ACTIVIDAD', 'FK_TLV_JERARQUIA');
    PERFORM academico_test.fn_actividad_lv_assert(p_fk_tlv_modalidad,               'MODALIDAD',                'FK_TLV_MODALIDAD');
    PERFORM academico_test.fn_actividad_lv_assert(p_fk_tlv_instrumento_evaluacion,  'INSTRUMENTO_EVALUACION',   'FK_TLV_INSTRUMENTO_EVALUACION');
    PERFORM academico_test.fn_actividad_lv_assert(p_fk_tlv_tipo_evidencia,          'TIPO_EVIDENCIA',           'FK_TLV_TIPO_EVIDENCIA');
    PERFORM academico_test.fn_actividad_lv_assert(p_fk_tlv_metodo_valoracion,       'METODO_VALORACION',        'FK_TLV_METODO_VALORACION');
    PERFORM academico_test.fn_actividad_lv_assert(p_fk_tlv_tipo_calculo,            'TIPO_CALCULO',             'FK_TLV_TIPO_CALCULO');

    PERFORM academico_test.fn_actividad_validar_evaluativa_contexto(
        v_evaluativa, v_ctx_evaluativo, p_fk_tunidad, TRIM(p_titulo));
    PERFORM academico_test.fn_actividad_instrumento_contexto_assert(
        p_fk_tlv_instrumento_evaluacion, p_fk_tgrupo, p_fk_tasignatura,
        p_fk_tunidad, p_titulo);
    PERFORM academico_test.fn_actividad_validar_titulo_unico(
        p_titulo, p_fk_tunidad, p_fk_tgrupo, p_fk_tlv_jerarquia);

    -- La regla del 100% por (unidad, grupo) la impone el trigger
    -- tr_tactividad_ponderacion_unidad: no se re-implementa la suma aqui.
    INSERT INTO academico_test.TACTIVIDAD (
        TITULO, DESCRIPCION, FECHA_CREACION,
        FK_TASIGNATURA, FK_TGRUPO, FK_TUNIDAD, PONDERACION,
        FK_TLV_TIPO_ACTIVIDAD, FK_TLV_JERARQUIA, FK_TLV_TIPO_CALCULO,
        INFLUENCIA, NOTA_MAXIMA,
        FECHA_INICIO, FECHA_CIERRE, DURACION_ESTIMADA, SEMANA_CRONOGRAMA,
        FK_TLV_MODALIDAD, MATERIAL_REQUERIDO,
        ES_EVALUATIVA, ES_RECUPERACION, FK_TLV_INSTRUMENTO_EVALUACION, DESCRIPCION_INSTRUMENTO,
        FK_TLV_TIPO_EVIDENCIA, FK_TLV_METODO_VALORACION,
        REQUIERE_ARCHIVO, REQUIERE_TEXTO,
        GENERA_EVIDENCIAS, REQUIERE_VALIDACION_COORDINADOR, OBSERVACIONES_DOCENTE,
        CREATED_BY, CREATED_AT, ACTIVE
    ) VALUES (
        TRIM(p_titulo), NULLIF(TRIM(p_descripcion), ''), CURRENT_DATE,
        p_fk_tasignatura, p_fk_tgrupo, p_fk_tunidad, p_ponderacion,
        p_fk_tlv_tipo_actividad, p_fk_tlv_jerarquia, p_fk_tlv_tipo_calculo,
        p_influencia, p_nota_maxima,
        p_fecha_inicio, p_fecha_cierre, p_duracion_estimada, NULLIF(TRIM(p_semana_cronograma), ''),
        p_fk_tlv_modalidad, NULLIF(TRIM(p_material_requerido), ''),
        v_evaluativa,
        CASE WHEN p_recuperacion IS NOT NULL THEN 'S' ELSE 'N' END,
        p_fk_tlv_instrumento_evaluacion,
        NULLIF(TRIM(p_descripcion_instrumento), ''),
        p_fk_tlv_tipo_evidencia, p_fk_tlv_metodo_valoracion,
        COALESCE(p_requiere_archivo, 'N'), COALESCE(p_requiere_texto, 'N'),
        COALESCE(p_genera_evidencias, 'N'),
        COALESCE(p_requiere_validacion_coordinador, 'N'),
        NULLIF(TRIM(p_observaciones_docente), ''),
        p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
    )
    RETURNING PK_TACTIVIDAD INTO v_id_creado;

    -- Sumatoria: una actividad nueva cambia el % de todo su bucket.
    PERFORM academico_test.fn_unidad_ponderacion_recalcular_sumatoria(p_fk_tunidad, p_fk_tgrupo);

    -- ORDEN IMPORTA: las adaptaciones a ESTUDIANTES_SELECCIONADOS apuntan a
    -- filas de TACTIVIDAD_ESTUDIANTE que deben existir ya.
    PERFORM academico_test.fn_actividad_estudiantes_asignar(
                p_pk_usuario_solicitante, v_id_creado, p_fk_tmatriculas, p_asignar_todo_el_grupo);
    PERFORM academico_test.fn_actividad_material_reemplazar(
                p_pk_usuario_solicitante, v_id_creado, p_materiales);
    PERFORM academico_test.fn_actividad_adaptacion_reemplazar(
                p_pk_usuario_solicitante, v_id_creado, p_adaptaciones);
    PERFORM academico_test.fn_actividad_recuperacion_configurar(
                p_pk_usuario_solicitante, v_id_creado, p_recuperacion);

    IF p_evidencias IS NOT NULL THEN
        PERFORM academico_test.fn_actividad_evidencia_relacionar(
                    p_pk_usuario_solicitante, v_id_creado, ev)
          FROM unnest(p_evidencias) AS ev
         WHERE ev IS NOT NULL;
    END IF;
    IF p_criterios IS NOT NULL THEN
        PERFORM academico_test.fn_actividad_criterio_relacionar(
                    p_pk_usuario_solicitante, v_id_creado, cr)
          FROM unnest(p_criterios) AS cr
         WHERE cr IS NOT NULL;
    END IF;

    RETURN v_id_creado;
END;
$$;
COMMENT ON FUNCTION academico_test.fn_actividad_crear_interno(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, VARCHAR, BIGINT, BIGINT, NUMERIC, DATE, DATE, NUMERIC, VARCHAR, BIGINT, VARCHAR, academico_test.bool_sn, BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, NUMERIC, NUMERIC, academico_test.bool_sn, academico_test.bool_sn, academico_test.bool_sn, academico_test.bool_sn, VARCHAR, JSONB, JSONB, BIGINT[], BOOLEAN, JSONB, BIGINT[], BIGINT[])
    IS 'INTERNO: alta de actividad sin gate ni etiqueta de auditoria (validaciones + INSERT + satelites). La invoca fn_actividad_crear; un import o un duplicado de actividades puede reutilizarla tras su propio gate. p_pk_usuario_solicitante solo se usa para CREATED_BY y los satelites.';

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_crear(
    p_pk_usuario_solicitante            BIGINT,
    p_titulo                            VARCHAR(250),
    p_fk_tasignatura                    BIGINT,
    p_fk_tlv_tipo_actividad             BIGINT,
    p_fk_tlv_jerarquia                  BIGINT,
    p_descripcion                       VARCHAR(4000) DEFAULT NULL,
    p_fk_tgrupo                         BIGINT        DEFAULT NULL,
    p_fk_tunidad                        BIGINT        DEFAULT NULL,
    p_ponderacion                       NUMERIC       DEFAULT NULL,
    p_fecha_inicio                      DATE          DEFAULT NULL,
    p_fecha_cierre                      DATE          DEFAULT NULL,
    p_duracion_estimada                 NUMERIC       DEFAULT NULL,
    p_semana_cronograma                 VARCHAR(50)   DEFAULT NULL,
    p_fk_tlv_modalidad                  BIGINT        DEFAULT NULL,
    p_material_requerido                VARCHAR(4000) DEFAULT NULL,
    p_es_evaluativa                     academico_test.bool_sn DEFAULT NULL,
    p_fk_tlv_instrumento_evaluacion     BIGINT        DEFAULT NULL,
    p_descripcion_instrumento           VARCHAR(4000) DEFAULT NULL,
    p_fk_tlv_tipo_evidencia             BIGINT        DEFAULT NULL,
    p_fk_tlv_metodo_valoracion          BIGINT        DEFAULT NULL,
    p_fk_tlv_tipo_calculo               BIGINT        DEFAULT NULL,
    p_influencia                        NUMERIC       DEFAULT NULL,
    p_nota_maxima                       NUMERIC       DEFAULT NULL,
    p_requiere_archivo                  academico_test.bool_sn DEFAULT 'N',
    p_requiere_texto                    academico_test.bool_sn DEFAULT 'N',
    p_genera_evidencias                 academico_test.bool_sn DEFAULT 'N',
    p_requiere_validacion_coordinador   academico_test.bool_sn DEFAULT 'N',
    p_observaciones_docente             VARCHAR(4000) DEFAULT NULL,
    p_materiales                        JSONB         DEFAULT NULL,
    p_adaptaciones                      JSONB         DEFAULT NULL,
    p_fk_tmatriculas                    BIGINT[]      DEFAULT NULL,
    p_asignar_todo_el_grupo             BOOLEAN       DEFAULT FALSE,
    p_recuperacion                      JSONB         DEFAULT NULL,
    p_evidencias                        BIGINT[]      DEFAULT NULL,
    p_criterios                         BIGINT[]      DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
BEGIN
    -- La actividad huerfana (sin grupo ni unidad) no tiene sede contra la que
    -- comprobar alcance; vincularla despues si lo comprueba.
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'CREAR', p_fk_tgrupo, NULL, p_fk_tunidad,
        NULL, p_permitir_sin_ancla => TRUE);

    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Creacion de la actividad %s', TRIM(p_titulo)), NULL,
        academico_test.fn_actividad_sede(p_fk_tgrupo, p_fk_tunidad));

    RETURN academico_test.fn_actividad_crear_interno(
        p_pk_usuario_solicitante, p_titulo, p_fk_tasignatura, p_fk_tlv_tipo_actividad,
        p_fk_tlv_jerarquia, p_descripcion, p_fk_tgrupo, p_fk_tunidad, p_ponderacion,
        p_fecha_inicio, p_fecha_cierre, p_duracion_estimada, p_semana_cronograma,
        p_fk_tlv_modalidad, p_material_requerido, p_es_evaluativa,
        p_fk_tlv_instrumento_evaluacion, p_descripcion_instrumento,
        p_fk_tlv_tipo_evidencia, p_fk_tlv_metodo_valoracion, p_fk_tlv_tipo_calculo,
        p_influencia, p_nota_maxima, p_requiere_archivo, p_requiere_texto,
        p_genera_evidencias, p_requiere_validacion_coordinador, p_observaciones_docente,
        p_materiales, p_adaptaciones, p_fk_tmatriculas, p_asignar_todo_el_grupo,
        p_recuperacion, p_evidencias, p_criterios);
END;
$$;
COMMENT ON FUNCTION academico_test.fn_actividad_crear(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, VARCHAR, BIGINT, BIGINT, NUMERIC, DATE, DATE, NUMERIC, VARCHAR, BIGINT, VARCHAR, academico_test.bool_sn, BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, NUMERIC, NUMERIC, academico_test.bool_sn, academico_test.bool_sn, academico_test.bool_sn, academico_test.bool_sn, VARCHAR, JSONB, JSONB, BIGINT[], BOOLEAN, JSONB, BIGINT[], BIGINT[])
    IS 'POST /planeador/actividades. Wrapper: gate CREAR de PLANEADOR con alcance (la actividad huerfana pasa con solo capability), etiqueta de auditoria con la sede de la actividad, y delega en fn_actividad_crear_interno. Rechaza 22023 si las fechas abarcan mas de un periodo de evaluacion.';

-- ---------------------------------------------------------------------------
-- 4) PATCH: mismo reparto, reglas sobre los valores RESULTANTES.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_actualizar_interno(
    p_pk_usuario_solicitante            BIGINT,
    p_pk_tactividad                     BIGINT,
    p_titulo                            VARCHAR(250)  DEFAULT NULL,
    p_descripcion                       VARCHAR(4000) DEFAULT NULL,
    p_fk_tasignatura                    BIGINT        DEFAULT NULL,
    p_fk_tgrupo                         BIGINT        DEFAULT NULL,
    p_fk_tunidad                        BIGINT        DEFAULT NULL,
    p_ponderacion                       NUMERIC       DEFAULT NULL,
    p_desvincular_unidad                BOOLEAN       DEFAULT FALSE,
    p_fk_tlv_tipo_actividad             BIGINT        DEFAULT NULL,
    p_fecha_inicio                      DATE          DEFAULT NULL,
    p_fecha_cierre                      DATE          DEFAULT NULL,
    p_duracion_estimada                 NUMERIC       DEFAULT NULL,
    p_semana_cronograma                 VARCHAR(50)   DEFAULT NULL,
    p_fk_tlv_modalidad                  BIGINT        DEFAULT NULL,
    p_material_requerido                VARCHAR(4000) DEFAULT NULL,
    p_es_evaluativa                     academico_test.bool_sn DEFAULT NULL,
    p_fk_tlv_instrumento_evaluacion     BIGINT        DEFAULT NULL,
    p_descripcion_instrumento           VARCHAR(4000) DEFAULT NULL,
    p_fk_tlv_tipo_evidencia             BIGINT        DEFAULT NULL,
    p_fk_tlv_metodo_valoracion          BIGINT        DEFAULT NULL,
    p_fk_tlv_tipo_calculo               BIGINT        DEFAULT NULL,
    p_influencia                        NUMERIC       DEFAULT NULL,
    p_nota_maxima                       NUMERIC       DEFAULT NULL,
    p_requiere_archivo                  academico_test.bool_sn DEFAULT NULL,
    p_requiere_texto                    academico_test.bool_sn DEFAULT NULL,
    p_genera_evidencias                 academico_test.bool_sn DEFAULT NULL,
    p_requiere_validacion_coordinador   academico_test.bool_sn DEFAULT NULL,
    p_observaciones_docente             VARCHAR(4000) DEFAULT NULL,
    p_materiales                        JSONB         DEFAULT NULL,
    p_adaptaciones                      JSONB         DEFAULT NULL,
    p_fk_tmatriculas                    BIGINT[]      DEFAULT NULL,
    p_asignar_todo_el_grupo             BOOLEAN       DEFAULT FALSE,
    p_recuperacion                      JSONB         DEFAULT NULL,
    p_quitar_recuperacion               BOOLEAN       DEFAULT FALSE,
    p_evidencias                        BIGINT[]      DEFAULT NULL,
    p_criterios                         BIGINT[]      DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_actual         academico_test.TACTIVIDAD%ROWTYPE;
    v_titulo         VARCHAR(250);
    v_asignatura     BIGINT;
    v_grupo          BIGINT;
    v_inicio         DATE;
    v_cierre         DATE;
    v_fk_tunidad     BIGINT;
    v_instrumento    BIGINT;
    v_evaluativa     academico_test.bool_sn;
    v_ctx_evaluativo BOOLEAN;
BEGIN
    SELECT * INTO v_actual
      FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_pk_tactividad;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la actividad solicitada' USING ERRCODE = 'P0002';
    END IF;
    IF v_actual.ACTIVE = FALSE THEN
        RAISE EXCEPTION 'La actividad "%" ya no esta disponible; no se puede editar', v_actual.TITULO
            USING ERRCODE = '22023';
    END IF;
    IF p_titulo IS NOT NULL AND NULLIF(TRIM(p_titulo), '') IS NULL THEN
        RAISE EXCEPTION 'El nombre de la actividad no puede quedar vacio' USING ERRCODE = '22023';
    END IF;
    IF p_desvincular_unidad AND (p_fk_tunidad IS NOT NULL OR p_ponderacion IS NOT NULL) THEN
        RAISE EXCEPTION 'No se puede quitar la actividad de su unidad y a la vez asignarle una unidad o un peso: elige una de las dos cosas'
            USING ERRCODE = '22023';
    END IF;
    IF p_quitar_recuperacion AND p_recuperacion IS NOT NULL THEN
        RAISE EXCEPTION 'No se puede quitar y configurar la recuperacion de la actividad en la misma operacion: elige una de las dos cosas' USING ERRCODE = '22023';
    END IF;

    -- Un PATCH que solo mueve el grupo puede dejar fuera de regla unas fechas
    -- que no venian en el body: todo se valida sobre lo que QUEDA.
    v_titulo      := COALESCE(NULLIF(TRIM(p_titulo), ''), v_actual.TITULO);
    v_asignatura  := COALESCE(p_fk_tasignatura, v_actual.FK_TASIGNATURA);
    v_grupo       := COALESCE(p_fk_tgrupo, v_actual.FK_TGRUPO);
    v_inicio      := COALESCE(p_fecha_inicio, v_actual.FECHA_INICIO);
    v_cierre      := COALESCE(p_fecha_cierre, v_actual.FECHA_CIERRE);
    v_fk_tunidad  := CASE WHEN p_desvincular_unidad THEN NULL
                          ELSE COALESCE(p_fk_tunidad, v_actual.FK_TUNIDAD) END;
    v_instrumento := COALESCE(p_fk_tlv_instrumento_evaluacion, v_actual.FK_TLV_INSTRUMENTO_EVALUACION);
    v_ctx_evaluativo := academico_test.fn_actividad_contexto_evaluativo(
                            v_grupo, v_asignatura, v_fk_tunidad);
    v_evaluativa  := COALESCE(p_es_evaluativa, v_actual.ES_EVALUATIVA,
                        CASE WHEN v_ctx_evaluativo THEN 'S' ELSE 'N' END);

    PERFORM academico_test.fn_actividad_validar_referencias_activas(
        p_fk_tasignatura, p_fk_tgrupo, NULL);
    -- La ponderacion solo se valida si viene: la guardada ya paso la regla.
    PERFORM academico_test.fn_actividad_validar_coherencia(
        v_titulo, v_asignatura, v_grupo, v_fk_tunidad, p_ponderacion,
        v_evaluativa, v_ctx_evaluativo, p_recuperacion IS NOT NULL,
        v_inicio, v_cierre,
        COALESCE(p_duracion_estimada, v_actual.DURACION_ESTIMADA),
        COALESCE(NULLIF(TRIM(p_semana_cronograma), ''), v_actual.SEMANA_CRONOGRAMA));

    PERFORM academico_test.fn_actividad_lv_assert(p_fk_tlv_tipo_actividad,          'TIPO_ACTIVIDAD',         'FK_TLV_TIPO_ACTIVIDAD');
    PERFORM academico_test.fn_actividad_lv_assert(p_fk_tlv_modalidad,               'MODALIDAD',              'FK_TLV_MODALIDAD');
    PERFORM academico_test.fn_actividad_lv_assert(p_fk_tlv_instrumento_evaluacion,  'INSTRUMENTO_EVALUACION', 'FK_TLV_INSTRUMENTO_EVALUACION');
    PERFORM academico_test.fn_actividad_lv_assert(p_fk_tlv_tipo_evidencia,          'TIPO_EVIDENCIA',         'FK_TLV_TIPO_EVIDENCIA');
    PERFORM academico_test.fn_actividad_lv_assert(p_fk_tlv_metodo_valoracion,       'METODO_VALORACION',      'FK_TLV_METODO_VALORACION');
    PERFORM academico_test.fn_actividad_lv_assert(p_fk_tlv_tipo_calculo,            'TIPO_CALCULO',           'FK_TLV_TIPO_CALCULO');

    PERFORM academico_test.fn_actividad_validar_evaluativa_contexto(
        v_evaluativa, v_ctx_evaluativo, v_fk_tunidad, v_titulo);
    PERFORM academico_test.fn_actividad_instrumento_contexto_assert(
        v_instrumento, v_grupo, v_asignatura, v_fk_tunidad, v_titulo);
    -- Contra la unidad RESULTANTE: con la vieja, mover de unidad comparaba
    -- contra el bucket equivocado.
    PERFORM academico_test.fn_actividad_validar_titulo_unico(
        v_titulo, v_fk_tunidad, v_grupo, v_actual.FK_TLV_JERARQUIA, p_pk_tactividad);

    UPDATE academico_test.TACTIVIDAD
       SET TITULO                          = v_titulo,
           DESCRIPCION                     = CASE WHEN p_descripcion IS NULL THEN DESCRIPCION
                                                  ELSE NULLIF(TRIM(p_descripcion), '') END,
           FK_TASIGNATURA                  = v_asignatura,
           FK_TGRUPO                       = v_grupo,
           FK_TLV_TIPO_ACTIVIDAD           = COALESCE(p_fk_tlv_tipo_actividad, FK_TLV_TIPO_ACTIVIDAD),
           FECHA_INICIO                    = v_inicio,
           FECHA_CIERRE                    = v_cierre,
           DURACION_ESTIMADA               = COALESCE(p_duracion_estimada, DURACION_ESTIMADA),
           SEMANA_CRONOGRAMA               = COALESCE(NULLIF(TRIM(p_semana_cronograma), ''), SEMANA_CRONOGRAMA),
           FK_TLV_MODALIDAD                = COALESCE(p_fk_tlv_modalidad, FK_TLV_MODALIDAD),
           MATERIAL_REQUERIDO              = CASE WHEN p_material_requerido IS NULL THEN MATERIAL_REQUERIDO
                                                  ELSE NULLIF(TRIM(p_material_requerido), '') END,
           ES_EVALUATIVA                   = v_evaluativa,
           FK_TLV_INSTRUMENTO_EVALUACION   = v_instrumento,
           DESCRIPCION_INSTRUMENTO         = CASE WHEN p_descripcion_instrumento IS NULL THEN DESCRIPCION_INSTRUMENTO
                                                  ELSE NULLIF(TRIM(p_descripcion_instrumento), '') END,
           FK_TLV_TIPO_EVIDENCIA           = COALESCE(p_fk_tlv_tipo_evidencia, FK_TLV_TIPO_EVIDENCIA),
           FK_TLV_METODO_VALORACION        = COALESCE(p_fk_tlv_metodo_valoracion, FK_TLV_METODO_VALORACION),
           FK_TLV_TIPO_CALCULO             = COALESCE(p_fk_tlv_tipo_calculo, FK_TLV_TIPO_CALCULO),
           INFLUENCIA                      = COALESCE(p_influencia, INFLUENCIA),
           NOTA_MAXIMA                     = COALESCE(p_nota_maxima, NOTA_MAXIMA),
           REQUIERE_ARCHIVO                = COALESCE(p_requiere_archivo, REQUIERE_ARCHIVO),
           REQUIERE_TEXTO                  = COALESCE(p_requiere_texto, REQUIERE_TEXTO),
           GENERA_EVIDENCIAS               = COALESCE(p_genera_evidencias, GENERA_EVIDENCIAS),
           REQUIERE_VALIDACION_COORDINADOR = COALESCE(p_requiere_validacion_coordinador, REQUIERE_VALIDACION_COORDINADOR),
           OBSERVACIONES_DOCENTE           = CASE WHEN p_observaciones_docente IS NULL THEN OBSERVACIONES_DOCENTE
                                                  ELSE NULLIF(TRIM(p_observaciones_docente), '') END,
           MODIFIED_BY                     = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT                     = CURRENT_TIMESTAMP
     WHERE PK_TACTIVIDAD = p_pk_tactividad;

    -- Unidad / ponderacion: la regla del 100% es de las funciones de unidad.
    IF p_desvincular_unidad THEN
        PERFORM academico_test.fn_unidad_actividad_desvincular(p_pk_usuario_solicitante, p_pk_tactividad);
    ELSIF p_fk_tunidad IS NOT NULL THEN
        PERFORM academico_test.fn_unidad_actividad_vincular(
                    p_pk_usuario_solicitante, p_pk_tactividad, p_fk_tunidad, p_ponderacion);
    ELSIF p_ponderacion IS NOT NULL THEN
        PERFORM academico_test.fn_unidad_actividad_ponderacion_set(
                    p_pk_usuario_solicitante, p_pk_tactividad, p_ponderacion);
    END IF;

    -- Sumatoria: se recalcula siempre el bucket destino, y tambien el de
    -- origen si la actividad cambio de unidad o de grupo.
    PERFORM academico_test.fn_unidad_ponderacion_recalcular_sumatoria(v_fk_tunidad, v_grupo);
    IF v_actual.FK_TUNIDAD IS NOT NULL
       AND (v_actual.FK_TUNIDAD IS DISTINCT FROM v_fk_tunidad
            OR v_actual.FK_TGRUPO IS DISTINCT FROM v_grupo) THEN
        PERFORM academico_test.fn_unidad_ponderacion_recalcular_sumatoria(
                    v_actual.FK_TUNIDAD, v_actual.FK_TGRUPO);
    END IF;

    -- ORDEN IMPORTA: estudiantes antes que adaptaciones.
    PERFORM academico_test.fn_actividad_estudiantes_asignar(
                p_pk_usuario_solicitante, p_pk_tactividad, p_fk_tmatriculas, p_asignar_todo_el_grupo);
    PERFORM academico_test.fn_actividad_material_reemplazar(
                p_pk_usuario_solicitante, p_pk_tactividad, p_materiales);
    PERFORM academico_test.fn_actividad_adaptacion_reemplazar(
                p_pk_usuario_solicitante, p_pk_tactividad, p_adaptaciones);

    IF p_quitar_recuperacion THEN
        PERFORM academico_test.fn_actividad_recuperacion_configurar(
                    p_pk_usuario_solicitante, p_pk_tactividad, NULL);
    ELSIF p_recuperacion IS NOT NULL THEN
        PERFORM academico_test.fn_actividad_recuperacion_configurar(
                    p_pk_usuario_solicitante, p_pk_tactividad, p_recuperacion);
    END IF;

    -- Reemplazo del set: se desactiva lo que ya no viene y los helpers de
    -- relacion reactivan la fila existente en vez de duplicarla.
    IF p_evidencias IS NOT NULL THEN
        UPDATE academico_test.TACTIVIDAD_EVIDENCIA
           SET ACTIVE = FALSE,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TACTIVIDAD = p_pk_tactividad
           AND ACTIVE = TRUE
           AND FK_REFERENTE_ENUNCIADO <> ALL(
                   ARRAY(SELECT x FROM unnest(p_evidencias) x WHERE x IS NOT NULL));

        PERFORM academico_test.fn_actividad_evidencia_relacionar(
                    p_pk_usuario_solicitante, p_pk_tactividad, ev)
           FROM unnest(p_evidencias) AS ev
          WHERE ev IS NOT NULL;
    END IF;

    IF p_criterios IS NOT NULL THEN
        UPDATE academico_test.TACTIVIDAD_CRITERIO_UNIDAD
           SET ACTIVE = FALSE,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TACTIVIDAD = p_pk_tactividad
           AND ACTIVE = TRUE
           AND FK_TCRITERIO_UNIDAD <> ALL(
                   ARRAY(SELECT x FROM unnest(p_criterios) x WHERE x IS NOT NULL));

        PERFORM academico_test.fn_actividad_criterio_relacionar(
                    p_pk_usuario_solicitante, p_pk_tactividad, cr)
           FROM unnest(p_criterios) AS cr
          WHERE cr IS NOT NULL;
    END IF;

    RETURN p_pk_tactividad;
END;
$$;
COMMENT ON FUNCTION academico_test.fn_actividad_actualizar_interno(BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT, NUMERIC, BOOLEAN, BIGINT, DATE, DATE, NUMERIC, VARCHAR, BIGINT, VARCHAR, academico_test.bool_sn, BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, NUMERIC, NUMERIC, academico_test.bool_sn, academico_test.bool_sn, academico_test.bool_sn, academico_test.bool_sn, VARCHAR, JSONB, JSONB, BIGINT[], BOOLEAN, JSONB, BOOLEAN, BIGINT[], BIGINT[])
    IS 'INTERNO: PATCH de actividad sin gate ni etiqueta de auditoria; valida sobre los valores resultantes y aplica UPDATE + satelites. La invoca fn_actividad_actualizar.';

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_actualizar(
    p_pk_usuario_solicitante            BIGINT,
    p_pk_tactividad                     BIGINT,
    p_titulo                            VARCHAR(250)  DEFAULT NULL,
    p_descripcion                       VARCHAR(4000) DEFAULT NULL,
    p_fk_tasignatura                    BIGINT        DEFAULT NULL,
    p_fk_tgrupo                         BIGINT        DEFAULT NULL,
    p_fk_tunidad                        BIGINT        DEFAULT NULL,
    p_ponderacion                       NUMERIC       DEFAULT NULL,
    p_desvincular_unidad                BOOLEAN       DEFAULT FALSE,
    p_fk_tlv_tipo_actividad             BIGINT        DEFAULT NULL,
    p_fecha_inicio                      DATE          DEFAULT NULL,
    p_fecha_cierre                      DATE          DEFAULT NULL,
    p_duracion_estimada                 NUMERIC       DEFAULT NULL,
    p_semana_cronograma                 VARCHAR(50)   DEFAULT NULL,
    p_fk_tlv_modalidad                  BIGINT        DEFAULT NULL,
    p_material_requerido                VARCHAR(4000) DEFAULT NULL,
    p_es_evaluativa                     academico_test.bool_sn DEFAULT NULL,
    p_fk_tlv_instrumento_evaluacion     BIGINT        DEFAULT NULL,
    p_descripcion_instrumento           VARCHAR(4000) DEFAULT NULL,
    p_fk_tlv_tipo_evidencia             BIGINT        DEFAULT NULL,
    p_fk_tlv_metodo_valoracion          BIGINT        DEFAULT NULL,
    p_fk_tlv_tipo_calculo               BIGINT        DEFAULT NULL,
    p_influencia                        NUMERIC       DEFAULT NULL,
    p_nota_maxima                       NUMERIC       DEFAULT NULL,
    p_requiere_archivo                  academico_test.bool_sn DEFAULT NULL,
    p_requiere_texto                    academico_test.bool_sn DEFAULT NULL,
    p_genera_evidencias                 academico_test.bool_sn DEFAULT NULL,
    p_requiere_validacion_coordinador   academico_test.bool_sn DEFAULT NULL,
    p_observaciones_docente             VARCHAR(4000) DEFAULT NULL,
    p_materiales                        JSONB         DEFAULT NULL,
    p_adaptaciones                      JSONB         DEFAULT NULL,
    p_fk_tmatriculas                    BIGINT[]      DEFAULT NULL,
    p_asignar_todo_el_grupo             BOOLEAN       DEFAULT FALSE,
    p_recuperacion                      JSONB         DEFAULT NULL,
    p_quitar_recuperacion               BOOLEAN       DEFAULT FALSE,
    p_evidencias                        BIGINT[]      DEFAULT NULL,
    p_criterios                         BIGINT[]      DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_titulo VARCHAR;
    v_grupo  BIGINT;
    v_unidad BIGINT;
BEGIN
    -- Existencia (P0002) antes que el gate: el alcance se resuelve desde la fila.
    SELECT TITULO, FK_TGRUPO, FK_TUNIDAD INTO v_titulo, v_grupo, v_unidad
      FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_pk_tactividad;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la actividad solicitada' USING ERRCODE = 'P0002';
    END IF;

    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'EDITAR', p_fk_tgrupo, NULL, p_fk_tunidad, p_pk_tactividad);

    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Actualizacion de la actividad %s', COALESCE(NULLIF(TRIM(p_titulo), ''), v_titulo)),
        NULL,
        academico_test.fn_actividad_sede(COALESCE(p_fk_tgrupo, v_grupo),
                                         COALESCE(p_fk_tunidad, v_unidad)));

    RETURN academico_test.fn_actividad_actualizar_interno(
        p_pk_usuario_solicitante, p_pk_tactividad, p_titulo, p_descripcion,
        p_fk_tasignatura, p_fk_tgrupo, p_fk_tunidad, p_ponderacion, p_desvincular_unidad,
        p_fk_tlv_tipo_actividad, p_fecha_inicio, p_fecha_cierre, p_duracion_estimada,
        p_semana_cronograma, p_fk_tlv_modalidad, p_material_requerido, p_es_evaluativa,
        p_fk_tlv_instrumento_evaluacion, p_descripcion_instrumento, p_fk_tlv_tipo_evidencia,
        p_fk_tlv_metodo_valoracion, p_fk_tlv_tipo_calculo, p_influencia, p_nota_maxima,
        p_requiere_archivo, p_requiere_texto, p_genera_evidencias,
        p_requiere_validacion_coordinador, p_observaciones_docente, p_materiales,
        p_adaptaciones, p_fk_tmatriculas, p_asignar_todo_el_grupo, p_recuperacion,
        p_quitar_recuperacion, p_evidencias, p_criterios);
END;
$$;
COMMENT ON FUNCTION academico_test.fn_actividad_actualizar(BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT, NUMERIC, BOOLEAN, BIGINT, DATE, DATE, NUMERIC, VARCHAR, BIGINT, VARCHAR, academico_test.bool_sn, BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, NUMERIC, NUMERIC, academico_test.bool_sn, academico_test.bool_sn, academico_test.bool_sn, academico_test.bool_sn, VARCHAR, JSONB, JSONB, BIGINT[], BOOLEAN, JSONB, BOOLEAN, BIGINT[], BIGINT[])
    IS 'PATCH /planeador/actividades/:id. Wrapper: existencia (P0002), gate EDITAR de PLANEADOR con alcance, etiqueta de auditoria con la sede resultante, y delega en fn_actividad_actualizar_interno. Rechaza 22023 si las fechas resultantes abarcan mas de un periodo de evaluacion.';


CREATE OR REPLACE FUNCTION academico_test.fn_actividad_campos_disponibles(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT
) RETURNS JSONB
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_titulo            VARCHAR;
    v_fk_tunidad        BIGINT;
    v_nombre_nivel      VARCHAR;
    v_es_preescolar     BOOLEAN;
    v_evaluacion_req    BOOLEAN;
    v_instrumentos      JSONB;
    v_es_sumativo       VARCHAR(1);
    v_es_recuperacion   VARCHAR(1);
    v_fk_tgrupo         BIGINT;
    v_fk_tasignatura    BIGINT;
    v_fk_recuperar      BIGINT;
    v_modo_calculo      VARCHAR;
    v_tipo              VARCHAR;
    v_es_formativo      BOOLEAN;
BEGIN
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', NULL, NULL, NULL, p_pk_tactividad
    );

    -- TACTIVIDAD.ES_EVALUATIVA es la columna que persiste "sumativa" (S/N).
    SELECT a.TITULO, a.FK_TUNIDAD, UPPER(TRIM(COALESCE(a.ES_EVALUATIVA::VARCHAR, 'S'))),
           UPPER(TRIM(COALESCE(a.ES_RECUPERACION::VARCHAR, 'N'))), a.FK_TGRUPO, a.FK_TASIGNATURA,
           (SELECT r.FK_TACTIVIDAD_RECUPERAR FROM academico_test.TACTIVIDAD_RECUPERACION r
             WHERE r.FK_TACTIVIDAD = a.PK_TACTIVIDAD AND r.ACTIVE = TRUE)
      INTO v_titulo, v_fk_tunidad, v_es_sumativo,
           v_es_recuperacion, v_fk_tgrupo, v_fk_tasignatura, v_fk_recuperar
      FROM academico_test.TACTIVIDAD a
     WHERE a.PK_TACTIVIDAD = p_pk_tactividad;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la actividad solicitada' USING ERRCODE = 'P0002';
    END IF;

    IF v_fk_tunidad IS NOT NULL THEN
        SELECT ne.NOMBRE
          INTO v_nombre_nivel
          FROM academico_test.TUNIDAD u
          JOIN academico_test.TGRADO g ON g.PK_TGRADO = u.FK_TGRADO
          JOIN academico_test.TNIVEL_ENSENANZA ne ON ne.PK_NIVEL_ENSENANZA = g.FK_TNIVEL_ENSENANZA
         WHERE u.PK_TUNIDAD = v_fk_tunidad;

        v_modo_calculo := academico_test.fn_unidad_calculo_definitiva_modo(v_fk_tunidad);
    ELSE
        -- Sin unidad el nivel sale del grado del GRUPO, igual que ya lo
        -- resuelve fn_actividad_configuracion_contexto. Sin esta rama el
        -- apagon de Preescolar no se aplicaba a una actividad suelta y, ahora
        -- que la evaluacion ya no exige unidad, le habria abierto el
        -- instrumento. Sin grupo no hay nivel: queda NULL (no Preescolar).
        SELECT ne.NOMBRE
          INTO v_nombre_nivel
          FROM academico_test.TGRUPO gr
          JOIN academico_test.TGRADO g ON g.PK_TGRADO = gr.FK_TGRADO
          JOIN academico_test.TNIVEL_ENSENANZA ne ON ne.PK_NIVEL_ENSENANZA = g.FK_TNIVEL_ENSENANZA
         WHERE gr.PK_TGRUPO = v_fk_tgrupo;
    END IF;

    v_es_preescolar := COALESCE(v_nombre_nivel ILIKE 'preescolar%', FALSE);

    v_evaluacion_req := academico_test.fn_actividad_evaluacion_requerida(p_pk_tactividad);

    v_tipo := academico_test.fn_actividad_referente_tipo_evaluacion(p_pk_tactividad);

    -- Preescolar es formativo por definicion: sin evaluacion con nota.
    v_evaluacion_req := COALESCE(v_evaluacion_req, FALSE) AND NOT v_es_preescolar;

    v_instrumentos := CASE
        WHEN NOT v_evaluacion_req THEN '[]'::jsonb
        ELSE academico_test.fn_actividad_instrumentos_campos_disponibles(v_tipo)
    END;

    -- Valor canonico, el mismo que devuelve GET /planeador/actividades/:ID.
    v_es_formativo := academico_test.fn_actividad_es_formativa(p_pk_tactividad);

    RETURN jsonb_build_object(
        -- Lo que el formulario debe traer marcado: con referente formativo
        -- la actividad no lleva nota, asi que nace NO sumativa. El front ya
        -- no tiene que deducirlo de evaluacion.visible.
        'esFormativo',        v_es_formativo,
        'esSumativoSugerido', CASE WHEN v_es_formativo THEN 'N' ELSE 'S' END,
        'criterio', academico_test.fn_actividad_criterio_campos_disponibles(
                        v_es_preescolar, v_fk_tunidad IS NOT NULL),
        'evaluacion', jsonb_build_object(
            'visible',  v_evaluacion_req,
            'requerido', v_evaluacion_req,
            'motivo', CASE
                WHEN v_es_preescolar THEN 'El nivel Preescolar se rige por un referente formativo: no hay evaluacion con nota ni recuperacion'
                WHEN v_evaluacion_req AND v_fk_tunidad IS NOT NULL THEN 'El referente curricular de la unidad de la actividad es EVALUATIVO'
                WHEN v_evaluacion_req THEN 'La actividad no tiene unidad: manda el referente curricular de su grado y asignatura, que es EVALUATIVO'
                WHEN v_fk_tunidad IS NOT NULL THEN 'El referente curricular de la unidad no es EVALUATIVO (o la unidad no tiene referente)'
                ELSE 'El referente curricular que le corresponde al grado y la asignatura de la actividad no es EVALUATIVO'
            END,
            'tipoEvaluacion', v_tipo,
            'instrumentosPermitidos', v_instrumentos
        ),
        'ponderacion', academico_test.fn_actividad_ponderacion_campos_disponibles(
                           v_es_sumativo, v_fk_tunidad IS NOT NULL, v_modo_calculo),
        'recuperacion', academico_test.fn_actividad_recuperacion_campos_disponibles(
                            v_evaluacion_req, v_es_sumativo, v_es_preescolar,
                            v_es_recuperacion, v_fk_tgrupo, v_fk_tasignatura,
                            v_fk_recuperar, p_pk_tactividad, NULL)
    );
END;
$$;



COMMENT ON FUNCTION academico_test.fn_actividad_campos_disponibles(BIGINT, BIGINT)
    IS 'Que pintar en el formulario de una actividad YA creada: {esFormativo, esSumativoSugerido, criterio, evaluacion, ponderacion, recuperacion}. Gate VER sobre PLANEADOR + alcance por la actividad; P0002 si no existe. V214.2. V479 -- evaluacion.visible/requerido e instrumentosPermitidos ya no se apagan por no tener unidad: salen del referente que le aplica a la actividad (fn_actividad_evaluacion_requerida + fn_actividad_referente_tipo_evaluacion, ambas generalizadas aqui). El apagon de Preescolar se mantiene, y ahora tambien SIN unidad: el nivel de ensenanza se deriva del grado del grupo cuando no hay unidad de la que leerlo -- sin eso, generalizar la evaluacion le habria abierto el instrumento a una actividad suelta de Preescolar.';

-- ---------------------------------------------------------------------------
-- 4) public.query: el catalogo anunciaba "hay que tener unidad".
--    ON CONFLICT DO NOTHING no actualiza filas ya sembradas: UPDATE aparte.
-- ---------------------------------------------------------------------------
UPDATE public.query q
   SET detail = q.detail || ' V479 -- La evaluacion (instrumento) ya no se apaga por no tener unidad: sale del referente curricular que le aplica a la actividad, que sin unidad se deriva de su grado y asignatura. En nivel Preescolar sigue apagada.'
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/actividades/:ID/configuracion'
   AND q.http_method     = 'GET'
   AND q.detail NOT LIKE '%V479 --%';

UPDATE public.query q
   SET detail = q.detail || ' V479 -- El instrumento de evaluacion ya no exige unidad: se acepta cuando el referente que le aplica al contexto (unidad, o grado del grupo + asignatura) es EVALUATIVO, y se rechaza con 422 (22023) solo si es Formativo. Desvincular la unidad de una actividad que ya tenia instrumento tampoco falla.'
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   IN ('/planeador/actividades', '/planeador/actividades/:ID')
   AND q.http_method     IN ('POST', 'PATCH')
   AND q.detail NOT LIKE '%V479 --%';
