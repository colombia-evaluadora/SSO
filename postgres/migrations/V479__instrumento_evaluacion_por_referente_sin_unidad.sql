-- ===========================================================================
-- V479 - El instrumento de evaluacion lo admite el REFERENTE, no la unidad.
-- V476 generalizo el gate de ES_EVALUATIVA al caso "sin unidad" (el referente
-- se deriva del grado del grupo y la asignatura), pero dejo la sub-rama del
-- instrumento con el "IF unidad IS NULL THEN RAISE" heredado de V224: una
-- actividad podia quedar evaluativa y a la vez sin poder decir con que se
-- evalua, y desvincularle la unidad fallaba sin salida. Aqui se cierra en los
-- helpers (contexto_tipo_evaluacion, referente_tipo_evaluacion,
-- evaluacion_requerida), en el nuevo nucleo fn_actividad_instrumento_contexto_assert
-- que comparten el alta y el PATCH, y en campos_disponibles (que ademas
-- deriva el nivel del grupo para no abrirle el instrumento a Preescolar).
-- Depende de: V214.2, V224, V451, V476 (cuyas copias de crear/actualizar/
-- campos_disponibles se reemplazan aqui).
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
-- 3) Escritura y lectura: copias de V476 con la sub-rama del instrumento
--    delegada en el assert, y el nivel de Preescolar derivado del grupo
--    cuando la actividad no tiene unidad. Misma firma: CREATE OR REPLACE.
-- ---------------------------------------------------------------------------

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
    -- DEFAULT NULL (antes 'S'): quien no manda el dato quiere el valor que
    -- le corresponde a su referente, y ese lo resuelve v_evaluativa abajo.
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
    -- NULL = actividad normal. Objeto = actividad de recuperacion:
    -- {destino, fkActividadRecuperar?, tipoAplicacion, tipoCalculo, valorPonderacion?}
    p_recuperacion                      JSONB         DEFAULT NULL,
    -- PK_REFERENTE_ENUNCIADO (nivel 2 / evidencia) que esta actividad
    -- sustenta. Solo tiene sentido si la actividad tiene unidad (p_fk_tunidad)
    -- y cada evidencia cuelga de un enunciado ya relacionado con esa unidad
    -- (TUNIDAD_ENUNCIADO) -- fn_actividad_evidencia_relacionar (V214.1) valida
    -- todo eso, aborta el CREATE si alguna no cumple.
    p_evidencias                        BIGINT[]      DEFAULT NULL,
    -- PK_TCRITERIO_UNIDAD de la rubrica de la unidad que esta actividad
    -- evalua. Solo tiene sentido si la actividad tiene unidad; cada criterio
    -- debe pertenecer a la rubrica de ESA unidad --
    -- fn_actividad_criterio_relacionar (V214.1) lo valida, aborta el CREATE
    -- si alguno no cumple.
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
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'CREAR', p_fk_tgrupo, NULL, p_fk_tunidad,
        NULL,
        -- Sin grupo NI unidad la actividad nace huerfana: no tiene sede contra
        -- la que comprobar alcance, y vincularla despues si lo comprueba.
        p_permitir_sin_ancla => TRUE
    );

    -- 1. Obligatorios.
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

    -- 2. Coherencia de fechas y banderas S/N.
    IF p_fecha_inicio IS NOT NULL AND p_fecha_cierre IS NOT NULL
       AND p_fecha_cierre < p_fecha_inicio THEN
        RAISE EXCEPTION 'La fecha de cierre (%) no puede ser anterior a la de inicio (%)',
            p_fecha_cierre, p_fecha_inicio USING ERRCODE = '22023';
    END IF;

    -- Limites de la seccion Programacion (V422): ventana del periodo academico,
    -- dia habil segun horario, duracion y semana del cronograma. Mismo calculo
    -- que pinta la pantalla, para que el tope no sea solo decorativo.
    PERFORM academico_test.fn_actividad_programacion_assert(
        p_fk_tgrupo, p_fk_tasignatura, p_fecha_inicio, p_fecha_cierre,
        p_duracion_estimada, p_semana_cronograma);
    -- Las banderas S/N ya son academico_test.bool_sn: el dominio (CHECK IN
    -- ('S','N')) las valida al vuelo, no hace falta un chequeo manual aqui.

    -- 3. FKs propias.
    IF NOT EXISTS (SELECT 1 FROM academico_test.TASIGNATURA
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
    IF p_ponderacion IS NOT NULL AND (p_ponderacion < 0 OR p_ponderacion > 100) THEN
        RAISE EXCEPTION 'La ponderacion (%) debe estar entre 0 y 100', p_ponderacion USING ERRCODE = '22023';
    END IF;
    IF p_ponderacion IS NOT NULL AND p_fk_tunidad IS NULL THEN
        RAISE EXCEPTION 'La ponderacion solo aplica cuando la actividad se vincula a una unidad'
            USING ERRCODE = '22023';
    END IF;
    -- ES_EVALUATIVA resultante. Con referente FORMATIVO el valor por
    -- defecto es 'N' (no 'S'): el enfoque valora con observaciones, y un
    -- 'S' silencioso dejaba la actividad calificable contra su referente.
    -- Todos los gates de abajo miran ya v_evaluativa, no el parametro.
    v_ctx_evaluativo := academico_test.fn_actividad_contexto_evaluativo(
                            p_fk_tgrupo, p_fk_tasignatura, p_fk_tunidad);
    v_evaluativa     := COALESCE(p_es_evaluativa,
                            CASE WHEN v_ctx_evaluativo THEN 'S' ELSE 'N' END);

    -- Condicion dinamica "actividad -> ponderacion" (V214.2, bloque
    -- 'ponderacion'), gate (a): sin evaluacion no hay peso que repartir.
    IF p_ponderacion IS NOT NULL AND v_evaluativa = 'N' THEN
        RAISE EXCEPTION 'La ponderacion no aplica: la actividad no es evaluativa (p_es_evaluativa = ''N'')'
            USING ERRCODE = '22023';
    END IF;
    -- Gate (b): el metodo de calculo de la unidad (V73) decide si el % se
    -- captura a mano (Ponderar), no aplica (Promediar) o lo autocalcula el
    -- sistema a partir de NOTA_MAXIMA (Sumatoria). fn_unidad_calculo_definitiva_modo
    -- y el recalculo viven en V223, punto unico de la regla.
    IF p_ponderacion IS NOT NULL AND p_fk_tunidad IS NOT NULL THEN
        IF academico_test.fn_unidad_calculo_definitiva_modo(p_fk_tunidad) = 'PROMEDIAR' THEN
            RAISE EXCEPTION 'La ponderacion no aplica: la unidad (%) promedia sus actividades', p_fk_tunidad
                USING ERRCODE = '22023';
        ELSIF academico_test.fn_unidad_calculo_definitiva_modo(p_fk_tunidad) = 'SUMATORIA' THEN
            RAISE EXCEPTION 'La ponderacion de la unidad (%) se autocalcula: es una unidad de Sumatoria, envie el puntaje de la actividad (p_nota_maxima) en vez del porcentaje', p_fk_tunidad
                USING ERRCODE = '22023';
        END IF;
    END IF;
    -- Una actividad de recuperacion recupera una NOTA: tiene que ser evaluativa.
    IF p_recuperacion IS NOT NULL AND v_evaluativa = 'N' THEN
        RAISE EXCEPTION 'Una actividad de recuperacion debe ser evaluativa (p_es_evaluativa = ''S'')'
            USING ERRCODE = '22023';
    END IF;

    -- 4. Catalogos (helper unico). Nombres de categoria verificados contra
    --    el servidor de test: la jerarquia es TIPO_JERARQUIA_ACTIVIDAD.
    PERFORM academico_test.fn_actividad_lv_assert(p_fk_tlv_tipo_actividad,          'TIPO_ACTIVIDAD',           'FK_TLV_TIPO_ACTIVIDAD');
    PERFORM academico_test.fn_actividad_lv_assert(p_fk_tlv_jerarquia,               'TIPO_JERARQUIA_ACTIVIDAD', 'FK_TLV_JERARQUIA');
    PERFORM academico_test.fn_actividad_lv_assert(p_fk_tlv_modalidad,               'MODALIDAD',                'FK_TLV_MODALIDAD');
    PERFORM academico_test.fn_actividad_lv_assert(p_fk_tlv_instrumento_evaluacion,  'INSTRUMENTO_EVALUACION',   'FK_TLV_INSTRUMENTO_EVALUACION');
    PERFORM academico_test.fn_actividad_lv_assert(p_fk_tlv_tipo_evidencia,          'TIPO_EVIDENCIA',           'FK_TLV_TIPO_EVIDENCIA');
    PERFORM academico_test.fn_actividad_lv_assert(p_fk_tlv_metodo_valoracion,       'METODO_VALORACION',        'FK_TLV_METODO_VALORACION'); -- sin seed: solo valida existencia+ACTIVE
    PERFORM academico_test.fn_actividad_lv_assert(p_fk_tlv_tipo_calculo,            'TIPO_CALCULO',             'FK_TLV_TIPO_CALCULO');

    -- 4.a Una actividad no puede quedar evaluativa (ES_EVALUATIVA = 'S') si
    --     se vincula a una unidad cuyo referente curricular es FORMATIVO:
    --     ese enfoque valora con observaciones, no con nota. Mismo helper
    --     que usa la sub-rama de instrumento (4.b) de abajo, aplicado ahora
    --     al flag ES_EVALUATIVA en si, no solo al instrumento.
    IF v_evaluativa = 'S' AND NOT v_ctx_evaluativo THEN
        IF p_fk_tunidad IS NOT NULL THEN
            RAISE EXCEPTION 'La actividad no puede ser evaluativa: la unidad "%" se rige por un referente curricular Formativo, que valora el aprendizaje con observaciones y no con nota',
                (SELECT NOMBRE FROM academico_test.TUNIDAD WHERE PK_TUNIDAD = p_fk_tunidad)
                USING ERRCODE = '22023';
        ELSE
            RAISE EXCEPTION 'La actividad no puede ser evaluativa: el referente curricular que le corresponde a este grado y asignatura es Formativo, y valora el aprendizaje con observaciones y no con nota'
                USING ERRCODE = '22023';
        END IF;
    END IF;

    -- 4.b Sub-rama "evaluacion" (instrumento de evaluacion): el instrumento lo
    --     admite el REFERENTE, no la unidad. La regla entera vive en
    --     fn_actividad_instrumento_contexto_assert (V479), compartida con el PATCH.
    PERFORM academico_test.fn_actividad_instrumento_contexto_assert(
                p_fk_tlv_instrumento_evaluacion, p_fk_tgrupo, p_fk_tasignatura,
                p_fk_tunidad, p_titulo);

    -- 5. Unicidad (TITULO, unidad, grupo, jerarquia) entre activas —
    --    backstop de U_TACTIVIDAD_1 (V22), que con FK_TUNIDAD/FK_TGRUPO
    --    NULL no garantiza nada (NULL nunca colisiona en un UNIQUE).
    IF EXISTS (
        SELECT 1 FROM academico_test.TACTIVIDAD
         WHERE UPPER(TRIM(TITULO)) = UPPER(TRIM(p_titulo))
           AND FK_TUNIDAD       IS NOT DISTINCT FROM p_fk_tunidad
           AND FK_TGRUPO        IS NOT DISTINCT FROM p_fk_tgrupo
           AND FK_TLV_JERARQUIA = p_fk_tlv_jerarquia
           AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'Ya existe una actividad activa "%" para esa unidad, grupo y jerarquia', p_titulo
            USING ERRCODE = '23505';
    END IF;

    -- 6. INSERT. FK_TUNIDAD/PONDERACION van directo: la regla del 100% por
    --    (unidad, grupo) la impone el trigger tr_tactividad_ponderacion_unidad
    --    (V223) — no se re-implementa la suma aqui.
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

    -- 6.b Unidad de SUMATORIA: el % de TODAS las actividades del bucket
    --     (unidad, grupo) se reparte proporcionalmente segun NOTA_MAXIMA, asi
    --     que entrar una actividad nueva obliga a recalcular el bucket
    --     completo. No-op si la unidad no es de sumatoria (o no hay unidad).
    PERFORM academico_test.fn_unidad_ponderacion_recalcular_sumatoria(p_fk_tunidad, p_fk_tgrupo);

    -- 7. Satelites (helpers reutilizables). ORDEN IMPORTA: los estudiantes
    --    van primero porque las adaptaciones con
    --    aplicaA = ESTUDIANTES_SELECCIONADOS apuntan a filas de
    --    TACTIVIDAD_ESTUDIANTE que deben existir ya.
    PERFORM academico_test.fn_actividad_estudiantes_asignar(
                p_pk_usuario_solicitante, v_id_creado, p_fk_tmatriculas, p_asignar_todo_el_grupo);
    PERFORM academico_test.fn_actividad_material_reemplazar(
                p_pk_usuario_solicitante, v_id_creado, p_materiales);
    PERFORM academico_test.fn_actividad_adaptacion_reemplazar(
                p_pk_usuario_solicitante, v_id_creado, p_adaptaciones);
    -- Config 1:1 de recuperacion (crea TACTIVIDAD_RECUPERACION si p_recuperacion no es NULL).
    PERFORM academico_test.fn_actividad_recuperacion_configurar(
                p_pk_usuario_solicitante, v_id_creado, p_recuperacion);

    -- 8. Evidencias de enunciado (opcional; TACTIVIDAD_EVIDENCIA, V214.1).
    --    fn_actividad_evidencia_relacionar exige FK_TUNIDAD y que el
    --    enunciado padre de cada evidencia ya este en TUNIDAD_ENUNCIADO
    --    para esa misma unidad -- revienta y aborta el CREATE si no.
    IF p_evidencias IS NOT NULL THEN
        PERFORM academico_test.fn_actividad_evidencia_relacionar(
                    p_pk_usuario_solicitante, v_id_creado, ev)
          FROM unnest(p_evidencias) AS ev
         WHERE ev IS NOT NULL;
    END IF;

    -- 9. Criterios de la rubrica de la unidad (opcional;
    --    TACTIVIDAD_CRITERIO_UNIDAD, V214.1). fn_actividad_criterio_relacionar
    --    exige FK_TUNIDAD y que cada criterio pertenezca a la rubrica de
    --    esa misma unidad -- revienta y aborta el CREATE si no.
    IF p_criterios IS NOT NULL THEN
        PERFORM academico_test.fn_actividad_criterio_relacionar(
                    p_pk_usuario_solicitante, v_id_creado, cr)
          FROM unnest(p_criterios) AS cr
         WHERE cr IS NOT NULL;
    END IF;

    RETURN v_id_creado;
END;
$$;

-- 2.b PATCH parcial: mismo criterio sobre los valores RESULTANTES.
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
    -- NULL = no tocar; array (incl. vacio) = reemplazo completo
    p_materiales                        JSONB         DEFAULT NULL,
    p_adaptaciones                      JSONB         DEFAULT NULL,
    p_fk_tmatriculas                    BIGINT[]      DEFAULT NULL,
    p_asignar_todo_el_grupo             BOOLEAN       DEFAULT FALSE,
    -- NULL = no tocar la recuperacion. Objeto = configurarla. Para QUITARLA
    -- (volver la actividad a normal) usar p_quitar_recuperacion = TRUE.
    p_recuperacion                      JSONB         DEFAULT NULL,
    p_quitar_recuperacion               BOOLEAN       DEFAULT FALSE,
    -- Mismo contrato que p_materiales / p_adaptaciones: NULL = no tocar,
    -- array (incl. vacio) = el set queda EXACTAMENTE ese.
    p_evidencias                        BIGINT[]      DEFAULT NULL,
    p_criterios                         BIGINT[]      DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_actual      academico_test.TACTIVIDAD%ROWTYPE;
    v_titulo      VARCHAR(250);
    v_grupo       BIGINT;
    v_inicio      DATE;
    v_cierre      DATE;
    v_fk_tunidad  BIGINT;
    v_instrumento BIGINT;
    v_evaluativa  academico_test.bool_sn;
    v_ctx_evaluativo BOOLEAN;
    v_modo_calc   VARCHAR;
BEGIN
    SELECT * INTO v_actual
      FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_pk_tactividad;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la actividad solicitada' USING ERRCODE = 'P0002';
    END IF;

    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'EDITAR', p_fk_tgrupo, NULL, p_fk_tunidad, p_pk_tactividad
    );

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
    IF p_recuperacion IS NOT NULL
       AND COALESCE(p_es_evaluativa, v_actual.ES_EVALUATIVA) = 'N' THEN
        RAISE EXCEPTION 'Una actividad de recuperacion debe ser evaluativa' USING ERRCODE = '22023';
    END IF;

    -- Valores resultantes para coherencia/unicidad.
    v_titulo := COALESCE(NULLIF(TRIM(p_titulo), ''), v_actual.TITULO);
    v_grupo  := COALESCE(p_fk_tgrupo, v_actual.FK_TGRUPO);
    v_inicio := COALESCE(p_fecha_inicio, v_actual.FECHA_INICIO);
    v_cierre := COALESCE(p_fecha_cierre, v_actual.FECHA_CIERRE);
    -- Unidad resultante tras aplicar p_desvincular_unidad / p_fk_tunidad,
    -- necesaria para validar la sub-rama de evaluacion mas abajo.
    v_fk_tunidad  := CASE WHEN p_desvincular_unidad THEN NULL
                          ELSE COALESCE(p_fk_tunidad, v_actual.FK_TUNIDAD) END;
    v_instrumento := COALESCE(p_fk_tlv_instrumento_evaluacion, v_actual.FK_TLV_INSTRUMENTO_EVALUACION);
    -- ES_EVALUATIVA resultante (nueva o heredada), mismo criterio de "valor
    -- resultante" que v_fk_tunidad / v_instrumento. El ultimo COALESCE ya no
    -- es 'S' fijo: una actividad sin valor guardado cae en el que le
    -- corresponde a su referente (con unidad, el de la unidad; sin ella, el
    -- derivado del grado y la asignatura resultantes).
    v_ctx_evaluativo := academico_test.fn_actividad_contexto_evaluativo(
                            v_grupo,
                            COALESCE(p_fk_tasignatura, v_actual.FK_TASIGNATURA),
                            v_fk_tunidad);
    v_evaluativa  := COALESCE(p_es_evaluativa, v_actual.ES_EVALUATIVA,
                        CASE WHEN v_ctx_evaluativo THEN 'S' ELSE 'N' END);

    -- Condicion dinamica "actividad -> ponderacion" (V214.2). Gate (a): sin
    -- evaluacion no hay peso. Gate (b): el metodo de calculo de la unidad
    -- resultante decide si el % se captura a mano (Ponderar), no aplica
    -- (Promediar) o lo autocalcula el sistema desde NOTA_MAXIMA (Sumatoria).
    IF p_ponderacion IS NOT NULL AND v_evaluativa = 'N' THEN
        RAISE EXCEPTION 'La ponderacion no aplica: la actividad "%" no es evaluativa', v_titulo
            USING ERRCODE = '22023';
    END IF;
    v_modo_calc := CASE WHEN v_fk_tunidad IS NULL THEN NULL
                        ELSE academico_test.fn_unidad_calculo_definitiva_modo(v_fk_tunidad) END;
    IF p_ponderacion IS NOT NULL AND v_modo_calc = 'PROMEDIAR' THEN
        RAISE EXCEPTION 'La unidad "%" promedia sus actividades, asi que la actividad no lleva peso (%%)', (SELECT NOMBRE FROM academico_test.TUNIDAD WHERE PK_TUNIDAD = v_fk_tunidad)
            USING ERRCODE = '22023';
    END IF;
    IF p_ponderacion IS NOT NULL AND v_modo_calc = 'SUMATORIA' THEN
        RAISE EXCEPTION 'La unidad "%" suma los puntajes de sus actividades: indica el puntaje maximo de la actividad en vez del peso (%%), que se calcula solo', (SELECT NOMBRE FROM academico_test.TUNIDAD WHERE PK_TUNIDAD = v_fk_tunidad)
            USING ERRCODE = '22023';
    END IF;

    IF v_inicio IS NOT NULL AND v_cierre IS NOT NULL AND v_cierre < v_inicio THEN
        RAISE EXCEPTION 'La fecha de cierre (%) no puede ser anterior a la de inicio (%)',
            v_cierre, v_inicio USING ERRCODE = '22023';
    END IF;

    -- Mismos limites que en el alta, pero sobre los valores RESULTANTES: un
    -- PATCH que solo mueve el grupo puede dejar fuera de rango unas fechas que
    -- no venian en el body.
    PERFORM academico_test.fn_actividad_programacion_assert(
        v_grupo,
        COALESCE(p_fk_tasignatura, v_actual.FK_TASIGNATURA),
        v_inicio, v_cierre,
        COALESCE(p_duracion_estimada, v_actual.DURACION_ESTIMADA),
        COALESCE(NULLIF(TRIM(p_semana_cronograma), ''), v_actual.SEMANA_CRONOGRAMA));

    IF p_fk_tasignatura IS NOT NULL AND NOT EXISTS (SELECT 1 FROM academico_test.TASIGNATURA
                    WHERE PK_TASIGNATURA = p_fk_tasignatura AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'La asignatura seleccionada no esta disponible' USING ERRCODE = '23503';
    END IF;
    IF p_fk_tgrupo IS NOT NULL AND NOT EXISTS (SELECT 1 FROM academico_test.TGRUPO
                    WHERE PK_TGRUPO = p_fk_tgrupo AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'El grupo seleccionado no esta disponible' USING ERRCODE = '23503';
    END IF;

    PERFORM academico_test.fn_actividad_lv_assert(p_fk_tlv_tipo_actividad,          'TIPO_ACTIVIDAD',         'FK_TLV_TIPO_ACTIVIDAD');
    PERFORM academico_test.fn_actividad_lv_assert(p_fk_tlv_modalidad,               'MODALIDAD',              'FK_TLV_MODALIDAD');
    PERFORM academico_test.fn_actividad_lv_assert(p_fk_tlv_instrumento_evaluacion,  'INSTRUMENTO_EVALUACION', 'FK_TLV_INSTRUMENTO_EVALUACION');
    PERFORM academico_test.fn_actividad_lv_assert(p_fk_tlv_tipo_evidencia,          'TIPO_EVIDENCIA',         'FK_TLV_TIPO_EVIDENCIA');
    PERFORM academico_test.fn_actividad_lv_assert(p_fk_tlv_metodo_valoracion,       'METODO_VALORACION',      'FK_TLV_METODO_VALORACION'); -- sin seed: solo valida existencia+ACTIVE
    PERFORM academico_test.fn_actividad_lv_assert(p_fk_tlv_tipo_calculo,            'TIPO_CALCULO',           'FK_TLV_TIPO_CALCULO');

    -- La actividad no puede quedar evaluativa (v_evaluativa = 'S') si, tras
    -- el PATCH, termina vinculada a una unidad Formativa: mismo criterio de
    -- "valor resultante" (v_fk_tunidad / v_evaluativa) que las sub-ramas de
    -- ponderacion y evaluacion, para cubrir tanto "marcarla evaluativa
    -- ahora" como "moverla a una unidad Formativa dejandola evaluativa".
    IF v_evaluativa = 'S' AND NOT v_ctx_evaluativo THEN
        IF v_fk_tunidad IS NOT NULL THEN
            RAISE EXCEPTION 'La actividad "%" no puede ser evaluativa: la unidad "%" se rige por un referente curricular Formativo, que valora el aprendizaje con observaciones y no con nota', v_titulo,
                (SELECT NOMBRE FROM academico_test.TUNIDAD WHERE PK_TUNIDAD = v_fk_tunidad)
                USING ERRCODE = '22023';
        ELSE
            RAISE EXCEPTION 'La actividad "%" no puede ser evaluativa: el referente curricular que le corresponde a su grado y asignatura es Formativo, y valora el aprendizaje con observaciones y no con nota', v_titulo
                USING ERRCODE = '22023';
        END IF;
    END IF;

    -- Sub-rama "evaluacion" (instrumento de evaluacion): se valida contra los
    -- valores RESULTANTES (instrumento / unidad / grupo / asignatura), no solo
    -- contra los parametros entrantes, para cubrir tanto "fijar instrumento
    -- ahora" como "mover la actividad a un contexto Formativo dejando el
    -- instrumento heredado". Desvincular la unidad ya NO es motivo de rechazo:
    -- sin unidad manda el referente del grado y la asignatura.
    PERFORM academico_test.fn_actividad_instrumento_contexto_assert(
                v_instrumento, v_grupo,
                COALESCE(p_fk_tasignatura, v_actual.FK_TASIGNATURA),
                v_fk_tunidad, v_titulo);

    -- Unicidad contra la unidad RESULTANTE (v_fk_tunidad, ya calculada
    -- arriba y usada tambien para la sub-rama de evaluacion), NO contra
    -- v_actual.FK_TUNIDAD: con la unidad vieja, mover una actividad de
    -- unidad comparaba contra el bucket equivocado y podia lanzar un 23505
    -- falso (o dejar pasar un duplicado real en la unidad destino).
    IF EXISTS (
        SELECT 1 FROM academico_test.TACTIVIDAD
         WHERE UPPER(TRIM(TITULO)) = UPPER(TRIM(v_titulo))
           AND FK_TUNIDAD       IS NOT DISTINCT FROM v_fk_tunidad
           AND FK_TGRUPO        IS NOT DISTINCT FROM v_grupo
           AND FK_TLV_JERARQUIA = v_actual.FK_TLV_JERARQUIA
           AND ACTIVE = TRUE
           AND PK_TACTIVIDAD <> p_pk_tactividad
    ) THEN
        RAISE EXCEPTION 'Ya existe otra actividad activa "%" para esa unidad, grupo y jerarquia', v_titulo
            USING ERRCODE = '23505';
    END IF;

    UPDATE academico_test.TACTIVIDAD
       SET TITULO                          = v_titulo,
           DESCRIPCION                     = CASE WHEN p_descripcion IS NULL THEN DESCRIPCION
                                                  ELSE NULLIF(TRIM(p_descripcion), '') END,
           FK_TASIGNATURA                  = COALESCE(p_fk_tasignatura, FK_TASIGNATURA),
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
           FK_TLV_INSTRUMENTO_EVALUACION   = COALESCE(p_fk_tlv_instrumento_evaluacion, FK_TLV_INSTRUMENTO_EVALUACION),
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

    -- Unidad / ponderacion: se delega en las funciones de V223 (mismo gate
    -- EDITAR) para no duplicar la regla del 100%.
    IF p_desvincular_unidad THEN
        PERFORM academico_test.fn_unidad_actividad_desvincular(p_pk_usuario_solicitante, p_pk_tactividad);
    ELSIF p_fk_tunidad IS NOT NULL THEN
        PERFORM academico_test.fn_unidad_actividad_vincular(
                    p_pk_usuario_solicitante, p_pk_tactividad, p_fk_tunidad, p_ponderacion);
    ELSIF p_ponderacion IS NOT NULL THEN
        PERFORM academico_test.fn_unidad_actividad_ponderacion_set(
                    p_pk_usuario_solicitante, p_pk_tactividad, p_ponderacion);
    END IF;

    -- Sumatoria: el reparto proporcional depende de NOTA_MAXIMA y del
    -- conjunto de actividades del bucket, asi que se recalcula SIEMPRE (no
    -- solo cuando se toco la unidad): editar el puntaje de una actividad
    -- cambia el % de TODAS las de su (unidad, grupo). Se recalcula tambien el
    -- bucket de origen si la unidad o el grupo cambiaron. No-op fuera de
    -- Sumatoria.
    PERFORM academico_test.fn_unidad_ponderacion_recalcular_sumatoria(v_fk_tunidad, v_grupo);
    IF v_actual.FK_TUNIDAD IS NOT NULL
       AND (v_actual.FK_TUNIDAD IS DISTINCT FROM v_fk_tunidad
            OR v_actual.FK_TGRUPO IS DISTINCT FROM v_grupo) THEN
        PERFORM academico_test.fn_unidad_ponderacion_recalcular_sumatoria(
                    v_actual.FK_TUNIDAD, v_actual.FK_TGRUPO);
    END IF;

    -- ORDEN IMPORTA: estudiantes antes que adaptaciones (ver fn_actividad_crear).
    PERFORM academico_test.fn_actividad_estudiantes_asignar(
                p_pk_usuario_solicitante, p_pk_tactividad, p_fk_tmatriculas, p_asignar_todo_el_grupo);
    PERFORM academico_test.fn_actividad_material_reemplazar(
                p_pk_usuario_solicitante, p_pk_tactividad, p_materiales);
    PERFORM academico_test.fn_actividad_adaptacion_reemplazar(
                p_pk_usuario_solicitante, p_pk_tactividad, p_adaptaciones);

    -- Recuperacion: solo si el caller la toco (objeto = configurar; flag = quitar).
    IF p_quitar_recuperacion THEN
        PERFORM academico_test.fn_actividad_recuperacion_configurar(
                    p_pk_usuario_solicitante, p_pk_tactividad, NULL);
    ELSIF p_recuperacion IS NOT NULL THEN
        PERFORM academico_test.fn_actividad_recuperacion_configurar(
                    p_pk_usuario_solicitante, p_pk_tactividad, p_recuperacion);
    END IF;

    -- Evidencias / criterios: reemplazo del set. Primero se desactiva lo que
    -- ya no viene y despues se relaciona el resto con los helpers de V214.1,
    -- que son los duenos de la regla de negocio (evidencia de nivel 2 cuyo
    -- enunciado padre este en la unidad; criterio de la rubrica de esa unidad)
    -- y reactivan la fila existente en vez de duplicarla. Quitar se permite
    -- siempre; agregar exige unidad, igual que en fn_actividad_crear.
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

COMMENT ON FUNCTION academico_test.fn_actividad_crear(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, VARCHAR, BIGINT, BIGINT, NUMERIC, DATE, DATE, NUMERIC, VARCHAR, BIGINT, VARCHAR, academico_test.bool_sn, BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, NUMERIC, NUMERIC, academico_test.bool_sn, academico_test.bool_sn, academico_test.bool_sn, academico_test.bool_sn, VARCHAR, JSONB, JSONB, BIGINT[], BOOLEAN, JSONB, BIGINT[], BIGINT[])
    IS 'Crea una actividad del Planeador (gate CREAR sobre PLANEADOR): inserta TACTIVIDAD (identificacion, programacion, evaluacion y seguimiento) y opcionalmente la vincula a una unidad con su PONDERACION (%) — la regla "la suma por (unidad, grupo) no pasa de 100" la impone el trigger de V223. NO asigna estudiantes por defecto: p_asignar_todo_el_grupo=TRUE los toma del FK_TGRUPO, o p_fk_tmatriculas fija estudiantes especificos (1 o mas). p_recuperacion (objeto) marca la actividad como de recuperacion y crea su fila TACTIVIDAD_RECUPERACION via fn_actividad_recuperacion_configurar. p_evidencias (PKs de TREFERENTE_ENUNCIADO nivel 2) y p_criterios (PKs de TCRITERIO_UNIDAD) relacionan la actividad, via fn_actividad_evidencia_relacionar / fn_actividad_criterio_relacionar (V214.1), con evidencias de enunciados ya vinculados a la unidad y con criterios de la rubrica de esa misma unidad — ambos exigen FK_TUNIDAD y abortan el CREATE si la actividad no tiene unidad o alguna PK no cumple la regla de negocio. Delega materiales / adaptaciones / estudiantes en sus helpers. Valida catalogos con fn_actividad_lv_assert y unicidad (titulo, unidad, grupo, jerarquia) entre activas con IS NOT DISTINCT FROM. p_fk_tlv_instrumento_evaluacion solo se acepta si el referente curricular que le aplica al contexto es EVALUATIVO (fn_actividad_instrumento_contexto_assert, condicion dinamica "actividad -> evaluacion" de V214.2); en otro caso lanza 22023. PONDERACION (condicion dinamica "actividad -> ponderacion" de V214.2): se rechaza (22023) si la actividad no es evaluativa (p_es_evaluativa=''N''), si no se vincula a una unidad, si la unidad PROMEDIA (no aplica) o si la unidad calcula por SUMATORIA -- ahi el docente envia p_nota_maxima (puntaje) y el % lo autocalcula fn_unidad_ponderacion_recalcular_sumatoria (V223), invocada tras el INSERT para repartir el bucket (unidad, grupo) completo. Retorna PK_TACTIVIDAD. V224. V476 -- El gate del referente Formativo ya no exige unidad: si la actividad nace sin ella, el referente se deriva del (grado del grupo, asignatura) con fn_actividad_contexto_evaluativo, y un ES_EVALUATIVA=''S'' explicito contra un referente Formativo se rechaza con 22023 igual que si la unidad lo fuera. Ademas el parametro p_es_evaluativa pasa a DEFAULT NULL: omitirlo ya no significa ''S'' fijo, significa "el valor que le corresponde a mi referente" -- ''N'' con referente Formativo, ''S'' con Evaluativo o cuando no hay referente del que decidir. Una actividad de Preescolar creada sin unidad dejaba de ser formativa solo por el default. V479 -- El instrumento de evaluacion tampoco exige unidad: se acepta si el referente que le aplica al contexto (unidad, o grado del grupo + asignatura) es EVALUATIVO, y se rechaza con 22023 solo si es Formativo. La regla vive en fn_actividad_instrumento_contexto_assert, compartida con el PATCH.';

COMMENT ON FUNCTION academico_test.fn_actividad_actualizar(BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT, NUMERIC, BOOLEAN, BIGINT, DATE, DATE, NUMERIC, VARCHAR, BIGINT, VARCHAR, academico_test.bool_sn, BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, NUMERIC, NUMERIC, academico_test.bool_sn, academico_test.bool_sn, academico_test.bool_sn, academico_test.bool_sn, VARCHAR, JSONB, JSONB, BIGINT[], BOOLEAN, JSONB, BOOLEAN, BIGINT[], BIGINT[])
    IS 'PATCH parcial de una actividad (gate EDITAR sobre PLANEADOR): cada parametro NULL preserva el valor actual. Unidad/ponderacion se delegan en fn_unidad_actividad_vincular / _ponderacion_set / _desvincular (V223) para que la regla del 100% viva en un solo sitio; p_desvincular_unidad=TRUE es excluyente con p_fk_tunidad/p_ponderacion. Recuperacion: p_recuperacion (objeto) la configura via fn_actividad_recuperacion_configurar, p_quitar_recuperacion=TRUE la elimina (vuelve la actividad a normal); son excluyentes y NULL/FALSE no la tocan. p_materiales / p_adaptaciones / p_fk_tmatriculas NULL = no tocar, array = reemplazo completo. p_evidencias (PKs de TREFERENTE_ENUNCIADO nivel 2) y p_criterios (PKs de TCRITERIO_UNIDAD) siguen el MISMO contrato: NULL = no tocar, array (incl. vacio) = el set queda exactamente ese -- se desactivan (ACTIVE=FALSE) las relaciones que ya no vienen y el resto se relaciona/reactiva con fn_actividad_evidencia_relacionar / fn_actividad_criterio_relacionar (V214.1), duenos unicos de la regla de negocio (la evidencia debe ser nivel 2 y su enunciado padre estar ya relacionado con la unidad de la actividad; el criterio debe pertenecer a la rubrica de esa misma unidad). QUITAR siempre se puede; AGREGAR exige que la actividad tenga unidad, igual que en fn_actividad_crear. Revalida fechas, catalogos y unicidad (titulo, unidad, grupo, jerarquia). El FK_TLV_INSTRUMENTO_EVALUACION resultante (nuevo o heredado) solo se admite si el referente curricular que le aplica al contexto resultante es EVALUATIVO (fn_actividad_instrumento_contexto_assert, condicion dinamica "actividad -> evaluacion" de V214.2); en otro caso lanza 22023. PONDERACION (condicion dinamica "actividad -> ponderacion" de V214.2, evaluada contra los valores RESULTANTES): se rechaza p_ponderacion (22023) si la actividad queda NO evaluativa (ES_EVALUATIVA resultante = ''N''), si la unidad resultante PROMEDIA, o si calcula por SUMATORIA -- ahi el docente envia p_nota_maxima y el % lo autocalcula fn_unidad_ponderacion_recalcular_sumatoria (V223), que se invoca SIEMPRE al final sobre el bucket resultante (y sobre el de origen si cambio la unidad o el grupo), porque editar el puntaje de una actividad cambia el % de todas las de su (unidad, grupo). Retorna PK_TACTIVIDAD. V224. V476 -- El gate del referente Formativo ya no exige unidad: si la actividad nace sin ella, el referente se deriva del (grado del grupo, asignatura) con fn_actividad_contexto_evaluativo, y un ES_EVALUATIVA=''S'' explicito contra un referente Formativo se rechaza con 22023 igual que si la unidad lo fuera. Ademas el parametro p_es_evaluativa pasa a DEFAULT NULL: omitirlo ya no significa ''S'' fijo, significa "el valor que le corresponde a mi referente" -- ''N'' con referente Formativo, ''S'' con Evaluativo o cuando no hay referente del que decidir. Una actividad de Preescolar creada sin unidad dejaba de ser formativa solo por el default. V479 -- El instrumento de evaluacion tampoco exige unidad: el valor RESULTANTE se acepta si el referente que le aplica al contexto resultante (unidad, o grado del grupo + asignatura) es EVALUATIVO. Desvincular la unidad de una actividad con instrumento heredado ya no falla: antes se rechazaba con 22023 sin mas salida que retirar el instrumento. La regla vive en fn_actividad_instrumento_contexto_assert, compartida con el alta.';

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
