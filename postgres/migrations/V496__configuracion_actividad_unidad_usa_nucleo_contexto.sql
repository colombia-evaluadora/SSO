-- V496 -- configuracion de actividad desde la unidad con el mismo nucleo que por contexto
-- Que hace: parte fn_actividad_configuracion_contexto en wrapper + _interno y
--   reescribe fn_unidad_configuracion_actividad para delegar en ese nucleo, asi
--   GET /planeador/unidades/:ID/configuracion-actividad responde lo mismo que
--   GET /planeador/actividades/configuracion: programacion (periodo, fechas,
--   semanas, duracion, horario), contexto resuelto y recuperacion dinamica.
-- Por que aqui: eran dos copias y la de unidad se quedo sin programacion.
--   La unidad es de un GRADO y el horario es de un GRUPO: el grupo llega por
--   ?grupo= o, si el grado tiene uno solo activo, se toma ese.
-- Depende de: V476 (ambas funciones), V460 (fn_actividad_programacion_limites),
--   V459 (fn_actividad_recuperacion_campos_disponibles), V277 (alcance).

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_configuracion_contexto_interno(
    p_fk_tgrupo               BIGINT,
    p_fk_tasignatura          BIGINT,
    p_fk_tunidad              BIGINT  DEFAULT NULL,
    p_es_sumativo             VARCHAR DEFAULT 'S',
    p_recuperar               VARCHAR DEFAULT 'N',
    p_fk_tactividad_recuperar BIGINT  DEFAULT NULL,
    p_pk_usuario_alcance      BIGINT  DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_es_sumativo   VARCHAR := UPPER(TRIM(COALESCE(p_es_sumativo, 'S')));
    v_fk_tgrado     BIGINT;
    v_grado         VARCHAR;
    v_grupo         VARCHAR;
    v_nivel         VARCHAR;
    v_asignatura    VARCHAR;
    v_es_preescolar BOOLEAN;
    v_pk_referente  BIGINT;
    v_ref_nombre    VARCHAR;
    v_evaluativo    BOOLEAN := FALSE;
    v_tipo          VARCHAR;
    v_modo          VARCHAR;
    v_instrumentos  JSONB;
    v_pk_periodo    BIGINT;
    v_periodo       VARCHAR;
    v_pa_desde      DATE;
    v_pa_hasta      DATE;
    v_semanas       INT;
    v_bloques       INT;
    v_dias          INT[];
    v_dias_nombre   JSONB;
    v_fecha_min     DATE;
    v_fecha_max     DATE;
    v_duracion_max  NUMERIC;
    v_min_bloque    NUMERIC;
    v_min_semana    NUMERIC;
    v_horario       JSONB;
    v_programacion  JSONB;
    v_es_formativo  BOOLEAN;
    v_sin_grupo     CONSTANT VARCHAR := 'Falta el grupo: el periodo academico y el horario se calculan sobre el grupo de la actividad';
BEGIN
    -- El grupo solo es opcional cuando hay unidad (de ella sale el grado).
    IF p_fk_tgrupo IS NOT NULL OR p_fk_tunidad IS NULL THEN
        SELECT gr.NOMBRE, gr.FK_TGRADO
          INTO v_grupo, v_fk_tgrado
          FROM academico_test.TGRUPO gr
         WHERE gr.PK_TGRUPO = p_fk_tgrupo
           AND gr.ACTIVE = TRUE;

        IF v_grupo IS NULL THEN
            RAISE EXCEPTION 'No se encontro el grupo solicitado' USING ERRCODE = 'P0002';
        END IF;
    END IF;

    SELECT a.NOMBRE INTO v_asignatura
      FROM academico_test.TASIGNATURA a
     WHERE a.PK_TASIGNATURA = p_fk_tasignatura
       AND a.ACTIVE = TRUE;

    IF v_asignatura IS NULL THEN
        RAISE EXCEPTION 'No se encontro la asignatura solicitada' USING ERRCODE = 'P0002';
    END IF;

    IF p_fk_tunidad IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM academico_test.TUNIDAD
                        WHERE PK_TUNIDAD = p_fk_tunidad AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'No se encontro la unidad solicitada' USING ERRCODE = 'P0002';
    END IF;

    IF p_fk_tgrupo IS NULL THEN
        SELECT u.FK_TGRADO INTO v_fk_tgrado
          FROM academico_test.TUNIDAD u WHERE u.PK_TUNIDAD = p_fk_tunidad;
    END IF;

    SELECT gd.NOMBRE, ne.NOMBRE
      INTO v_grado, v_nivel
      FROM academico_test.TGRADO gd
      LEFT JOIN academico_test.TNIVEL_ENSENANZA ne
             ON ne.PK_NIVEL_ENSENANZA = gd.FK_TNIVEL_ENSENANZA
     WHERE gd.PK_TGRADO = v_fk_tgrado;

    v_es_preescolar := COALESCE(v_nivel ILIKE 'preescolar%', FALSE);

    -- Con unidad manda la unidad (ya eligio referente y metodo de calculo);
    -- sin unidad, el referente se deriva del grado + asignatura.
    IF p_fk_tunidad IS NOT NULL THEN
        v_evaluativo := academico_test.fn_unidad_referente_evaluativo(p_fk_tunidad);
        v_tipo       := academico_test.fn_unidad_referente_tipo_evaluacion(p_fk_tunidad);
        v_modo       := academico_test.fn_unidad_calculo_definitiva_modo(p_fk_tunidad);

        SELECT u.FK_REFERENTE_CURRICULAR INTO v_pk_referente
          FROM academico_test.TUNIDAD u WHERE u.PK_TUNIDAD = p_fk_tunidad;
    ELSE
        v_pk_referente := academico_test.fn_unidad_referente_aplicable(
                              v_fk_tgrado, p_fk_tasignatura, NULL);

        SELECT (enf.VALOR = 'EVALUATIVO'), tev.VALOR
          INTO v_evaluativo, v_tipo
          FROM academico_test.TREFERENTE_CURRICULAR rc
          LEFT JOIN academico_test.TLISTA_VALOR enf ON enf.PK_LISTA_VALOR = rc.FK_TLV_ENFOQUE_PEDAGOGICO
          LEFT JOIN academico_test.TLISTA_VALOR tev ON tev.PK_LISTA_VALOR = rc.FK_TLV_TIPO_EVALUACION
         WHERE rc.PK_REFERENTE_CURRICULAR = v_pk_referente;
    END IF;

    SELECT rc.NOMBRE INTO v_ref_nombre
      FROM academico_test.TREFERENTE_CURRICULAR rc
     WHERE rc.PK_REFERENTE_CURRICULAR = v_pk_referente;

    -- esFormativo sale del REFERENTE, antes del apagon de Preescolar: es el
    -- valor que la escritura acepta y guarda (fn_actividad_contexto_evaluativo).
    -- El apagon gobierna evaluacion.visible, que es otra pregunta.
    v_es_formativo := NOT COALESCE(v_evaluativo, FALSE);

    -- Preescolar es formativo por definicion: sin evaluacion con nota.
    v_evaluativo := COALESCE(v_evaluativo, FALSE) AND NOT v_es_preescolar;

    v_instrumentos := CASE
        WHEN NOT v_evaluativo THEN '[]'::jsonb
        ELSE academico_test.fn_actividad_instrumentos_campos_disponibles(v_tipo)
    END;

    -- Limites de la seccion "Programacion": un solo calculo, compartido con la
    -- validacion de escritura (fn_actividad_programacion_assert).
    SELECT l.fk_tperiodo_academico, l.periodo_academico, l.periodo_desde, l.periodo_hasta,
           l.semanas, l.bloques_por_semana, l.dias_habiles, l.dias_habiles_nombre,
           l.fecha_min, l.fecha_max, l.duracion_max,
           l.minutos_por_bloque, l.minutos_por_semana, l.horario
      INTO v_pk_periodo, v_periodo, v_pa_desde, v_pa_hasta,
           v_semanas, v_bloques, v_dias, v_dias_nombre,
           v_fecha_min, v_fecha_max, v_duracion_max,
           v_min_bloque, v_min_semana, v_horario
      FROM academico_test.fn_actividad_programacion_limites(p_fk_tgrupo, p_fk_tasignatura) l;

    v_programacion := jsonb_build_object(
        'periodoAcademico', CASE WHEN v_pk_periodo IS NULL THEN NULL
            ELSE jsonb_build_object('pk', v_pk_periodo, 'nombre', v_periodo,
                                    'fechaInicio', v_pa_desde, 'fechaFin', v_pa_hasta,
                                    'semanas', v_semanas) END,
        'intensidadHoraria', jsonb_build_object(
            'bloquesPorSemana',  v_bloques,
            'minutosPorBloque',  v_min_bloque,
            'minutosPorSemana',  v_min_semana,
            'diasHabiles',       v_dias_nombre,
            'horario',           v_horario,
            'motivo', CASE
                WHEN p_fk_tgrupo IS NULL THEN v_sin_grupo
                WHEN COALESCE(v_bloques, 0) = 0
                    THEN 'El grupo no tiene horario configurado para esta asignatura'
                WHEN v_min_semana IS NULL
                    THEN 'El horario no tiene horas definidas en todos sus bloques; no se pueden contar minutos'
                ELSE 'Dias y horas en que el docente dicta esta asignatura a este grupo, segun THORARIO' END),
        'fechaInicio', jsonb_build_object(
            'min', v_fecha_min, 'max', v_fecha_max,
            'diasHabiles', v_dias,
            'motivo', CASE
                WHEN p_fk_tgrupo IS NULL THEN v_sin_grupo
                WHEN v_pa_desde IS NULL THEN 'El grado no tiene periodo academico asociado; no hay ventana que aplicar'
                WHEN COALESCE(array_length(v_dias, 1), 0) = 0 THEN 'Sin horario configurado: solo aplica la ventana del periodo academico'
                ELSE 'Dentro del periodo academico y en un dia en que se dicta la asignatura' END),
        'fechaCierre', jsonb_build_object(
            'min', v_fecha_min, 'max', v_fecha_max,
            'diasHabiles', v_dias,
            'motivo', CASE
                WHEN p_fk_tgrupo IS NULL THEN v_sin_grupo
                WHEN COALESCE(array_length(v_dias, 1), 0) = 0
                    THEN 'No puede ser anterior a la fecha de inicio ni exceder el periodo academico'
                ELSE 'No puede ser anterior a la fecha de inicio, debe caer en un dia en que se dicta la asignatura y no exceder el periodo academico' END),
        'semanaCronograma', jsonb_build_object(
            'min', 1,
            'max', v_semanas,
            'motivo', CASE
                WHEN p_fk_tgrupo IS NULL THEN v_sin_grupo
                WHEN v_semanas IS NULL THEN 'El grado no tiene periodo academico asociado; no se puede acotar'
                ELSE 'Semanas que dura el periodo academico' END),
        'duracionEstimada', jsonb_build_object(
            'min', 1,
            'max', v_duracion_max,
            'unidad', 'MINUTOS',
            'paso', v_min_bloque,
            'motivo', CASE
                WHEN p_fk_tgrupo IS NULL THEN v_sin_grupo
                WHEN v_duracion_max IS NULL
                    THEN 'Falta el periodo academico o las horas del horario de la asignatura; no hay tope que calcular'
                ELSE 'Minutos: semanas del periodo academico por los minutos semanales de clase de la asignatura' END));

    RETURN jsonb_build_object(
        'programacion',   v_programacion,
        'fkTgrupo',       p_fk_tgrupo,
        'grupo',          v_grupo,
        'fkTgrado',       v_fk_tgrado,
        'grado',          v_grado,
        'nivelEnsenanza', v_nivel,
        'fkTasignatura',  p_fk_tasignatura,
        'asignatura',     v_asignatura,
        'pkTunidad',      p_fk_tunidad,
        'origenConfiguracion', CASE WHEN p_fk_tunidad IS NULL THEN 'CONTEXTO' ELSE 'UNIDAD' END,
        'referente', CASE WHEN v_pk_referente IS NULL THEN NULL
                          ELSE jsonb_build_object('pk', v_pk_referente, 'nombre', v_ref_nombre) END,
        'esSumativoConsultado', v_es_sumativo,
        -- Lo que el formulario debe traer marcado: con referente formativo la
        -- actividad no lleva nota, asi que nace NO sumativa.
        'esFormativo',        v_es_formativo,
        'esSumativoSugerido', CASE WHEN v_es_formativo THEN 'N' ELSE 'S' END,
        'campos_disponibles', jsonb_build_object(
            'criterio', academico_test.fn_actividad_criterio_campos_disponibles(
                            v_es_preescolar, p_fk_tunidad IS NOT NULL),
            'evaluacion', jsonb_build_object(
                'visible',   COALESCE(v_evaluativo, FALSE),
                'requerido', COALESCE(v_evaluativo, FALSE),
                'motivo',    CASE
                    WHEN v_es_preescolar THEN 'El nivel Preescolar se rige por un referente formativo: no hay evaluacion con nota ni recuperacion'
                    WHEN NOT COALESCE(v_evaluativo, FALSE) AND p_fk_tunidad IS NOT NULL
                        THEN 'El referente curricular de la unidad no es EVALUATIVO (o la unidad no tiene referente)'
                    WHEN NOT COALESCE(v_evaluativo, FALSE)
                        THEN 'El referente curricular que aplica no es EVALUATIVO (o no hay referente para ese grado y asignatura)'
                    WHEN p_fk_tunidad IS NOT NULL
                        THEN 'El referente curricular de la unidad es EVALUATIVO: la actividad requiere instrumento de evaluacion'
                    ELSE 'El referente curricular que aplica es EVALUATIVO: la actividad requiere instrumento de evaluacion'
                END,
                'tipoEvaluacion', v_tipo,
                'instrumentosPermitidos', v_instrumentos),
            'ponderacion', academico_test.fn_actividad_ponderacion_campos_disponibles(
                               v_es_sumativo, p_fk_tunidad IS NOT NULL, v_modo),
            'recuperacion', academico_test.fn_actividad_recuperacion_campos_disponibles(
                                v_evaluativo, v_es_sumativo, v_es_preescolar,
                                p_recuperar, p_fk_tgrupo, p_fk_tasignatura,
                                p_fk_tactividad_recuperar, NULL, p_pk_usuario_alcance))
    );
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_configuracion_contexto_interno(BIGINT, BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT)
    IS 'INTERNO: la configuracion del formulario de actividad sin gate, reutilizada por fn_actividad_configuracion_contexto (GET /planeador/actividades/configuracion) y fn_unidad_configuracion_actividad (GET /planeador/unidades/:ID/configuracion-actividad) para que las dos respondan lo mismo. Devuelve programacion (periodoAcademico, intensidadHoraria con horario, fechaInicio, fechaCierre, semanaCronograma, duracionEstimada en MINUTOS; limites de fn_actividad_programacion_limites), el contexto resuelto (grupo, grado, nivelEnsenanza, asignatura, unidad, referente), esFormativo / esSumativoSugerido y campos_disponibles {criterio, evaluacion, ponderacion, recuperacion}. p_fk_tgrupo es obligatorio salvo con unidad: sin grupo el grado sale de la unidad y programacion viene con sus limites NULL y el motivo "Falta el grupo". p_pk_usuario_alcance solo se reenvia a fn_actividad_recuperacion_campos_disponibles para comprobar alcance sobre la actividad a recuperar despues de validar que existe; NULL = el llamador ya lo comprobo. P0002 si el grupo, la asignatura o la unidad no existen o estan inactivos.';


-- Mismo contrato y firma que V476: solo pasa a gate + delegacion.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_configuracion_contexto(
    p_pk_usuario_solicitante  BIGINT,
    p_fk_tgrupo               BIGINT,
    p_fk_tasignatura          BIGINT,
    p_fk_tunidad              BIGINT  DEFAULT NULL,
    p_es_sumativo             VARCHAR DEFAULT 'S',
    p_recuperar               VARCHAR DEFAULT 'N',
    p_fk_tactividad_recuperar BIGINT  DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql STABLE AS $$
BEGIN
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', p_fk_tgrupo, NULL, p_fk_tunidad
    );

    RETURN academico_test.fn_actividad_configuracion_contexto_interno(
        p_fk_tgrupo, p_fk_tasignatura, p_fk_tunidad, p_es_sumativo,
        p_recuperar, p_fk_tactividad_recuperar, p_pk_usuario_solicitante);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_configuracion_contexto(BIGINT, BIGINT, BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT)
    IS 'GET /planeador/actividades/configuracion?grupo=&asignatura=&unidad=: que pintar en el formulario de actividad a partir de grupo + asignatura, con unidad OPCIONAL (con unidad manda la unidad; sin ella el referente se deriva con fn_unidad_referente_aplicable). Gate VER sobre PLANEADOR + alcance por el grupo y la unidad; la respuesta la arma fn_actividad_configuracion_contexto_interno, el mismo nucleo de GET /planeador/unidades/:ID/configuracion-actividad. p_es_sumativo (S|N, default S): con N solo se apagan recuperacion y ponderacion. p_recuperar = S lista las actividades recuperables del (grupo, asignatura) y p_fk_tactividad_recuperar devuelve el origen elegido con sus estudiantes. En Preescolar la evaluacion y la recuperacion vienen apagadas. P0002 si el grupo, la asignatura o la unidad no existen.';


DROP FUNCTION IF EXISTS academico_test.fn_unidad_configuracion_actividad(BIGINT, BIGINT, VARCHAR);
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_configuracion_actividad(
    p_pk_usuario_solicitante  BIGINT,
    p_pk_tunidad              BIGINT,
    p_es_sumativo             VARCHAR DEFAULT 'S',
    p_fk_tgrupo               BIGINT  DEFAULT NULL,
    p_recuperar               VARCHAR DEFAULT 'N',
    p_fk_tactividad_recuperar BIGINT  DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_nombre_unidad  VARCHAR;
    v_fk_tgrado      BIGINT;
    v_fk_tasignatura BIGINT;
    v_grupo_nombre   VARCHAR;
    v_grupo_grado    BIGINT;
    v_fk_tgrupo      BIGINT := p_fk_tgrupo;
BEGIN
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', p_fk_tgrupo, NULL, p_pk_tunidad
    );

    SELECT u.NOMBRE, u.FK_TGRADO, u.FK_TASIGNATURA
      INTO v_nombre_unidad, v_fk_tgrado, v_fk_tasignatura
      FROM academico_test.TUNIDAD u
     WHERE u.PK_TUNIDAD = p_pk_tunidad
       AND u.ACTIVE = TRUE;

    IF v_nombre_unidad IS NULL THEN
        RAISE EXCEPTION 'No se encontro la unidad solicitada' USING ERRCODE = 'P0002';
    END IF;

    IF p_fk_tgrupo IS NOT NULL THEN
        SELECT gr.NOMBRE, gr.FK_TGRADO
          INTO v_grupo_nombre, v_grupo_grado
          FROM academico_test.TGRUPO gr
         WHERE gr.PK_TGRUPO = p_fk_tgrupo
           AND gr.ACTIVE = TRUE;

        IF v_grupo_nombre IS NULL THEN
            RAISE EXCEPTION 'No se encontro el grupo solicitado' USING ERRCODE = 'P0002';
        END IF;
        IF v_grupo_grado IS DISTINCT FROM v_fk_tgrado THEN
            RAISE EXCEPTION 'El grupo "%" no pertenece al grado de la unidad "%"',
                v_grupo_nombre, v_nombre_unidad USING ERRCODE = '22023';
        END IF;
    ELSE
        -- Con un solo grupo activo en el grado no hay nada que elegir. Con
        -- varios (o ninguno) no se adivina: programacion sale sin limites.
        SELECT MIN(gr.PK_TGRUPO) INTO v_fk_tgrupo
          FROM academico_test.TGRUPO gr
         WHERE gr.FK_TGRADO = v_fk_tgrado
           AND gr.ACTIVE = TRUE
        HAVING COUNT(*) = 1;
    END IF;

    RETURN academico_test.fn_actividad_configuracion_contexto_interno(
               v_fk_tgrupo, v_fk_tasignatura, p_pk_tunidad, p_es_sumativo,
               p_recuperar, p_fk_tactividad_recuperar, p_pk_usuario_solicitante)
        || jsonb_build_object(
               'unidad',      v_nombre_unidad,
               'origenGrupo', CASE
                   WHEN p_fk_tgrupo IS NOT NULL THEN 'PARAMETRO'
                   WHEN v_fk_tgrupo IS NOT NULL THEN 'UNICO_DEL_GRADO'
               END);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_configuracion_actividad(BIGINT, BIGINT, VARCHAR, BIGINT, VARCHAR, BIGINT)
    IS 'GET /planeador/unidades/:ID/configuracion-actividad: que pintar en el formulario de NUEVA ACTIVIDAD para la unidad escogida, antes de crearla. Gate VER sobre PLANEADOR + alcance por la unidad (y el grupo si llega); la respuesta la arma fn_actividad_configuracion_contexto_interno con la asignatura de la unidad, asi que trae exactamente lo mismo que GET /planeador/actividades/configuracion con ?unidad=: programacion (periodo, fechas, semanas, duracion en minutos, horario), contexto, referente, esFormativo / esSumativoSugerido y campos_disponibles. Ademas: unidad (nombre) y origenGrupo. La unidad es de un grado y el horario de un grupo: p_fk_tgrupo (?grupo=) tiene que ser del grado de la unidad (22023 si no); sin el, se usa el unico grupo activo del grado (origenGrupo = UNICO_DEL_GRADO) y, si hay varios o ninguno, origenGrupo = NULL y programacion sale sin limites con el motivo "Falta el grupo". p_recuperar / p_fk_tactividad_recuperar igual que en la configuracion por contexto. P0002 si la unidad o el grupo no existen o estan inactivos.';


UPDATE public.query q
   SET query = 'SELECT academico_test.fn_unidad_configuracion_actividad(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    COALESCE(CAST(:QUERY.ES_SUMATIVO AS VARCHAR), ''S''),
    CAST(:QUERY.GRUPO AS BIGINT),
    COALESCE(CAST(:QUERY.RECUPERAR AS VARCHAR), ''N''),
    CAST(:QUERY.ACTIVIDAD_RECUPERAR AS BIGINT)
) AS configuracion;',
       param_types = '{"PARAM.ID": "BIGINT", "QUERY.ES_SUMATIVO": "VARCHAR", "QUERY.GRUPO": "BIGINT", "QUERY.RECUPERAR": "VARCHAR", "QUERY.ACTIVIDAD_RECUPERAR": "BIGINT"}'::jsonb,
       detail = 'Que pintar en el formulario de NUEVA ACTIVIDAD para la unidad escogida, antes de crearla. :ID = PK_TUNIDAD. Responde lo MISMO que GET /planeador/actividades/configuracion?grupo=&asignatura=&unidad= (mismo nucleo, la asignatura sale de la unidad): programacion {periodoAcademico, intensidadHoraria {bloquesPorSemana, minutosPorBloque, minutosPorSemana, diasHabiles, horario:[{valor, nombre, bloques:[{numero, horaInicio, horaFin, minutos}]}]}, fechaInicio/fechaCierre {min, max, diasHabiles}, semanaCronograma {min, max}, duracionEstimada {min, max, unidad: MINUTOS, paso}}, contexto (fkTgrupo, grupo, fkTgrado, grado, nivelEnsenanza, fkTasignatura, asignatura, pkTunidad, referente {pk, nombre}), esSumativoConsultado, esFormativo, esSumativoSugerido y campos_disponibles {criterio, evaluacion, ponderacion, recuperacion}; ademas unidad (nombre) y origenGrupo. La unidad es de un GRADO y el horario de un GRUPO: ?grupo= (opcional) tiene que ser del grado de la unidad (422 si no); sin el se usa el unico grupo activo del grado (origenGrupo = UNICO_DEL_GRADO) y si hay varios origenGrupo = NULL y programacion viene con sus limites NULL y el motivo "Falta el grupo": el front debe pedir el grupo y volver a consultar. ?ES_SUMATIVO=S|N (default S): con N solo se apagan recuperacion y ponderacion. ?RECUPERAR=S lista en recuperacion.actividadesRecuperables las sumativas del (grupo, asignatura); ?ACTIVIDAD_RECUPERAR= devuelve recuperacion.origen con sus estudiantes. El front decide por VALOR: los pk no son estables entre entornos. Gate VER sobre PLANEADOR + alcance por la unidad; 404 (P0002) si la unidad o el grupo no existen o estan inactivos.'
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/unidades/:ID/configuracion-actividad'
   AND q.http_method     = 'GET';

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.query q
          JOIN public.microservice m ON m.id_microservice = q.microservice_id
         WHERE m.serviceid = 'eval-col'
           AND q.path_template = '/planeador/unidades/:ID/configuracion-actividad'
           AND q.http_method = 'GET'
           AND q.query LIKE '%:QUERY.GRUPO%') THEN
        RAISE EXCEPTION 'Falta la fila de GET /planeador/unidades/:ID/configuracion-actividad (V282)';
    END IF;
END;
$$;
