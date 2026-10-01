-- V479 - El instrumento de evaluación lo admite el referente, no la unidad:
-- helpers de contexto (tipo de evaluación, evaluación requerida, grado y sede
-- de la actividad), fn_actividad_instrumento_contexto_assert y
-- fn_actividad_campos_disponibles. Crear/actualizar y sus reglas viven hoy en
-- V496.1-V496.3.


SET search_path TO academico_test, public;

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
    v_que VARCHAR := COALESCE(p_titulo, 'La actividad');
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

UPDATE public.query q
   SET detail = q.detail || ' V479 -- La evaluacion (instrumento) ya no se apaga por no tener unidad: sale del referente curricular que le aplica a la actividad, que sin unidad se deriva de su grado y asignatura. En nivel Preescolar sigue apagada.'
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/actividades/:ID/configuracion'
   AND q.http_method     = 'GET'
   AND q.detail NOT LIKE '%V479 --%';
