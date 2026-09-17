-- ===========================================================================
-- V440 — Planeador: un solo constructor de `campos_disponibles`.
--
-- Las tres funciones de configuracion del formulario de actividad (por
-- actividad, por unidad y por grupo+asignatura) armaban los bloques a mano y
-- divergian: `instrumentosPermitidos` salia con clave `etiqueta` y ORDER BY
-- NOMBRE por un camino, y con clave `nombre` y ORDER BY PK por los otros dos.
-- Aqui se extraen tres helpers por VALORES resueltos y las tres funciones
-- pasan a componerlos. Los helpers emiten `etiqueta` Y `nombre` (aditivo).
--
-- Depende de: V214.2, V282, V420, V223, V277, V73.
-- ===========================================================================
SET search_path TO academico_test, public;

-- ---------------------------------------------------------------------------
-- 1) Helpers compartidos
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_actividad_instrumentos_campos_disponibles(VARCHAR);
CREATE FUNCTION academico_test.fn_actividad_instrumentos_campos_disponibles(
    p_tipo_evaluacion VARCHAR
) RETURNS JSONB
LANGUAGE sql STABLE AS $$
    SELECT COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
                   'pk',       lv.PK_LISTA_VALOR,
                   'valor',    lv.VALOR,
                   'etiqueta', lv.NOMBRE,
                   'nombre',   lv.NOMBRE)
                   ORDER BY lv.NOMBRE)
          FROM academico_test.TLISTA_VALOR lv
         WHERE lv.CATEGORIA = 'INSTRUMENTO_EVALUACION'
           AND lv.ACTIVE = TRUE
           AND academico_test.fn_instrumento_permitido_por_tipo_evaluacion(lv.VALOR, p_tipo_evaluacion)
    ), '[]'::jsonb);
$$;

DROP FUNCTION IF EXISTS academico_test.fn_actividad_criterio_campos_disponibles(BOOLEAN, BOOLEAN);
CREATE FUNCTION academico_test.fn_actividad_criterio_campos_disponibles(
    p_es_preescolar BOOLEAN,
    p_tiene_unidad  BOOLEAN
) RETURNS JSONB
LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object(
        'visible',   NOT COALESCE(p_es_preescolar, FALSE) AND COALESCE(p_tiene_unidad, FALSE),
        'requerido', FALSE,
        'motivo', CASE
            WHEN COALESCE(p_es_preescolar, FALSE) AND COALESCE(p_tiene_unidad, FALSE)
                THEN 'El grado de la unidad pertenece al nivel Preescolar: la relacion con criterios de rubrica no aplica'
            WHEN COALESCE(p_es_preescolar, FALSE)
                THEN 'El grado pertenece al nivel Preescolar: la relacion con criterios de rubrica no aplica'
            WHEN NOT COALESCE(p_tiene_unidad, FALSE)
                THEN 'Los criterios pertenecen a la rubrica de una unidad; la actividad aun no tiene unidad'
            ELSE 'Opcional: la actividad puede relacionarse con criterios de la rubrica de la unidad'
        END);
$$;

DROP FUNCTION IF EXISTS academico_test.fn_actividad_ponderacion_campos_disponibles(VARCHAR, BOOLEAN, VARCHAR);
CREATE FUNCTION academico_test.fn_actividad_ponderacion_campos_disponibles(
    p_es_evaluativa VARCHAR,
    p_tiene_unidad  BOOLEAN,
    p_modo_calculo  VARCHAR
) RETURNS JSONB
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN UPPER(TRIM(COALESCE(p_es_evaluativa, 'S'))) = 'N' THEN jsonb_build_object(
            'visible', FALSE, 'requerido', FALSE, 'modo', NULL,
            'motivo', 'La actividad no es evaluativa; la ponderacion no aplica')
        WHEN NOT COALESCE(p_tiene_unidad, FALSE) THEN jsonb_build_object(
            'visible', FALSE, 'requerido', FALSE, 'modo', NULL,
            'motivo', 'La actividad aun no pertenece a una unidad; la ponderacion la define el metodo de calculo de la unidad')
        WHEN p_modo_calculo = 'PONDERAR' THEN jsonb_build_object(
            'visible', TRUE, 'requerido', TRUE, 'modo', 'PORCENTAJE',
            'campo', 'PONDERACION', 'autocalculado', FALSE,
            'motivo', 'la unidad pondera sus actividades')
        WHEN p_modo_calculo = 'SUMATORIA' THEN jsonb_build_object(
            'visible', TRUE, 'requerido', TRUE, 'modo', 'PUNTAJE',
            'campo', 'NOTA_MAXIMA', 'autocalculado', TRUE,
            'motivo', 'la unidad suma puntajes; el % lo calcula el sistema')
        WHEN p_modo_calculo = 'PROMEDIAR' THEN jsonb_build_object(
            'visible', FALSE, 'requerido', FALSE, 'modo', NULL,
            'motivo', 'la unidad promedia, la ponderacion no aplica')
        ELSE jsonb_build_object(
            'visible', FALSE, 'requerido', FALSE, 'modo', NULL,
            'motivo', 'la unidad aun no tiene metodo de calculo elegido')
    END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_instrumentos_campos_disponibles(VARCHAR) IS
    'Bloque instrumentosPermitidos del formulario de actividad, por TIPO_EVALUACION resuelto.';
COMMENT ON FUNCTION academico_test.fn_actividad_criterio_campos_disponibles(BOOLEAN, BOOLEAN) IS
    'Bloque criterio del formulario de actividad.';
COMMENT ON FUNCTION academico_test.fn_actividad_ponderacion_campos_disponibles(VARCHAR, BOOLEAN, VARCHAR) IS
    'Bloque ponderacion del formulario de actividad, por metodo de calculo de la unidad.';

-- ---------------------------------------------------------------------------
-- 2) Las tres funciones de configuracion pasan a componer los helpers
-- ---------------------------------------------------------------------------
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
    v_es_evaluativa     VARCHAR(1);
    v_modo_calculo      VARCHAR;
    v_tipo              VARCHAR;
BEGIN
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', NULL, NULL, NULL, p_pk_tactividad
    );

    SELECT a.TITULO, a.FK_TUNIDAD, UPPER(TRIM(COALESCE(a.ES_EVALUATIVA::VARCHAR, 'S')))
      INTO v_titulo, v_fk_tunidad, v_es_evaluativa
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
    END IF;

    -- "Preescolar" se resuelve por NOMBRE: el CODIGO de TNIVEL_ENSENANZA no es
    -- estable entre entornos (catalogo del dump base, no seedeado por Flyway).
    v_es_preescolar := COALESCE(v_nombre_nivel ILIKE 'preescolar%', FALSE);

    v_evaluacion_req := academico_test.fn_actividad_evaluacion_requerida(p_pk_tactividad);

    v_tipo := academico_test.fn_actividad_referente_tipo_evaluacion(p_pk_tactividad);

    v_instrumentos := CASE
        WHEN NOT COALESCE(v_evaluacion_req, FALSE) OR v_es_evaluativa = 'N' THEN '[]'::jsonb
        ELSE academico_test.fn_actividad_instrumentos_campos_disponibles(v_tipo)
    END;

    RETURN jsonb_build_object(
        'criterio', academico_test.fn_actividad_criterio_campos_disponibles(
                        v_es_preescolar, v_fk_tunidad IS NOT NULL),
        'evaluacion', jsonb_build_object(
            'visible',  v_evaluacion_req,
            'requerido', v_evaluacion_req,
            'motivo', CASE
                WHEN v_fk_tunidad IS NULL THEN 'La actividad no tiene unidad relacionada'
                WHEN v_evaluacion_req THEN 'El referente curricular de la unidad de la actividad es EVALUATIVO'
                ELSE 'El referente curricular de la unidad no es EVALUATIVO (o la unidad no tiene referente)'
            END,
            'tipoEvaluacion', v_tipo,
            'instrumentosPermitidos', v_instrumentos
        ),
        'ponderacion', academico_test.fn_actividad_ponderacion_campos_disponibles(
                           v_es_evaluativa, v_fk_tunidad IS NOT NULL, v_modo_calculo),
        'recuperacion', academico_test.fn_actividad_recuperacion_campos_disponibles(
                            v_evaluacion_req, v_es_evaluativa)
    );
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_configuracion_actividad(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tunidad             BIGINT,
    p_es_evaluativa          VARCHAR DEFAULT 'S'
) RETURNS JSONB
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_nombre_unidad   VARCHAR;
    v_nivel_nombre    VARCHAR;
    v_es_evaluativa   VARCHAR := UPPER(TRIM(COALESCE(p_es_evaluativa, 'S')));
    v_evaluativo      BOOLEAN;
    v_tipo            VARCHAR;
    v_modo            VARCHAR;
    v_es_preescolar   BOOLEAN;
    v_instrumentos    JSONB;
BEGIN
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', NULL, NULL, p_pk_tunidad
    );

    SELECT u.NOMBRE, ne.NOMBRE
      INTO v_nombre_unidad, v_nivel_nombre
      FROM academico_test.TUNIDAD u
      JOIN academico_test.TGRADO g            ON g.PK_TGRADO = u.FK_TGRADO
      LEFT JOIN academico_test.TNIVEL_ENSENANZA ne
             ON ne.PK_NIVEL_ENSENANZA = g.FK_TNIVEL_ENSENANZA
     WHERE u.PK_TUNIDAD = p_pk_tunidad
       AND u.ACTIVE = TRUE;

    IF v_nombre_unidad IS NULL THEN
        RAISE EXCEPTION 'No se encontro la unidad solicitada' USING ERRCODE = 'P0002';
    END IF;

    v_es_preescolar := COALESCE(v_nivel_nombre ILIKE 'preescolar%', FALSE);

    v_evaluativo := academico_test.fn_unidad_referente_evaluativo(p_pk_tunidad);
    v_tipo       := academico_test.fn_unidad_referente_tipo_evaluacion(p_pk_tunidad);
    v_modo       := academico_test.fn_unidad_calculo_definitiva_modo(p_pk_tunidad);

    v_instrumentos := CASE
        WHEN NOT COALESCE(v_evaluativo, FALSE) OR v_es_evaluativa = 'N' THEN '[]'::jsonb
        ELSE academico_test.fn_actividad_instrumentos_campos_disponibles(v_tipo)
    END;

    RETURN jsonb_build_object(
        'pkTunidad', p_pk_tunidad,
        'unidad',    v_nombre_unidad,
        'nivelEnsenanza', v_nivel_nombre,
        'esEvaluativaConsultada', v_es_evaluativa,
        'campos_disponibles', jsonb_build_object(
            'criterio', academico_test.fn_actividad_criterio_campos_disponibles(
                            v_es_preescolar, TRUE),
            'evaluacion', jsonb_build_object(
                'visible',   COALESCE(v_evaluativo, FALSE) AND v_es_evaluativa <> 'N',
                'requerido', COALESCE(v_evaluativo, FALSE) AND v_es_evaluativa <> 'N',
                'motivo',    CASE
                    WHEN v_es_evaluativa = 'N'
                        THEN 'La actividad se creara como NO evaluativa; no hay seccion de evaluacion'
                    WHEN NOT COALESCE(v_evaluativo, FALSE)
                        THEN 'El referente curricular de la unidad no es EVALUATIVO (o la unidad no tiene referente)'
                    ELSE 'El referente curricular de la unidad es EVALUATIVO: la actividad requiere instrumento de evaluacion'
                END,
                'tipoEvaluacion', v_tipo,
                'instrumentosPermitidos', v_instrumentos),
            'ponderacion', academico_test.fn_actividad_ponderacion_campos_disponibles(
                               v_es_evaluativa, TRUE, v_modo),
            'recuperacion', academico_test.fn_actividad_recuperacion_campos_disponibles(
                                COALESCE(v_evaluativo, FALSE), v_es_evaluativa))
    );
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_configuracion_contexto(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tgrupo              BIGINT,
    p_fk_tasignatura         BIGINT,
    p_fk_tunidad             BIGINT DEFAULT NULL,
    p_es_evaluativa          VARCHAR DEFAULT 'S'
) RETURNS JSONB
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_es_evaluativa VARCHAR := UPPER(TRIM(COALESCE(p_es_evaluativa, 'S')));
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
    v_programacion  JSONB;
BEGIN
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', p_fk_tgrupo, NULL, p_fk_tunidad
    );

    SELECT gr.NOMBRE, gr.FK_TGRADO, gd.NOMBRE, ne.NOMBRE
      INTO v_grupo, v_fk_tgrado, v_grado, v_nivel
      FROM academico_test.TGRUPO gr
      LEFT JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
      LEFT JOIN academico_test.TNIVEL_ENSENANZA ne
             ON ne.PK_NIVEL_ENSENANZA = gd.FK_TNIVEL_ENSENANZA
     WHERE gr.PK_TGRUPO = p_fk_tgrupo
       AND gr.ACTIVE = TRUE;

    IF v_grupo IS NULL THEN
        RAISE EXCEPTION 'No se encontro el grupo solicitado' USING ERRCODE = 'P0002';
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

    v_instrumentos := CASE
        WHEN NOT COALESCE(v_evaluativo, FALSE) OR v_es_evaluativa = 'N' THEN '[]'::jsonb
        ELSE academico_test.fn_actividad_instrumentos_campos_disponibles(v_tipo)
    END;

    -- Limites de la seccion "Programacion": un solo calculo, compartido con la
    -- validacion de escritura (fn_actividad_programacion_assert).
    SELECT l.fk_tperiodo_academico, l.periodo_academico, l.periodo_desde, l.periodo_hasta,
           l.semanas, l.bloques_por_semana, l.dias_habiles, l.dias_habiles_nombre,
           l.fecha_min, l.fecha_max, l.duracion_max
      INTO v_pk_periodo, v_periodo, v_pa_desde, v_pa_hasta,
           v_semanas, v_bloques, v_dias, v_dias_nombre,
           v_fecha_min, v_fecha_max, v_duracion_max
      FROM academico_test.fn_actividad_programacion_limites(p_fk_tgrupo, p_fk_tasignatura) l;

    v_programacion := jsonb_build_object(
        'periodoAcademico', CASE WHEN v_pk_periodo IS NULL THEN NULL
            ELSE jsonb_build_object('pk', v_pk_periodo, 'nombre', v_periodo,
                                    'fechaInicio', v_pa_desde, 'fechaFin', v_pa_hasta,
                                    'semanas', v_semanas) END,
        'intensidadHoraria', jsonb_build_object(
            'bloquesPorSemana', v_bloques,
            'diasHabiles',      v_dias_nombre,
            'motivo', CASE WHEN COALESCE(v_bloques, 0) = 0
                THEN 'El grupo no tiene horario configurado para esta asignatura'
                ELSE 'Bloques activos de THORARIO para este grupo y asignatura' END),
        'fechaInicio', jsonb_build_object(
            'min', v_fecha_min, 'max', v_fecha_max,
            'diasHabiles', v_dias,
            'motivo', CASE
                WHEN v_pa_desde IS NULL THEN 'El grado no tiene periodo academico asociado; no hay ventana que aplicar'
                WHEN COALESCE(array_length(v_dias, 1), 0) = 0 THEN 'Sin horario configurado: solo aplica la ventana del periodo academico'
                ELSE 'Dentro del periodo academico y en un dia en que se dicta la asignatura' END),
        'fechaCierre', jsonb_build_object(
            'min', v_fecha_min, 'max', v_fecha_max,
            'diasHabiles', v_dias,
            'motivo', 'No puede ser anterior a la fecha de inicio ni exceder el periodo academico'),
        'semanaCronograma', jsonb_build_object(
            'min', CASE WHEN v_semanas IS NULL THEN NULL ELSE 1 END,
            'max', v_semanas,
            'motivo', CASE WHEN v_semanas IS NULL
                THEN 'El grado no tiene periodo academico asociado; no se puede acotar'
                ELSE 'Semanas que dura el periodo academico' END),
        'duracionEstimada', jsonb_build_object(
            'min', CASE WHEN v_duracion_max IS NULL THEN NULL ELSE 1 END,
            'max', v_duracion_max,
            'unidad', 'BLOQUES',
            'motivo', CASE WHEN v_duracion_max IS NULL
                THEN 'Falta el periodo academico o el horario de la asignatura; no hay tope que calcular'
                ELSE 'Semanas del periodo academico por los bloques semanales de la asignatura' END));

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
        'esEvaluativaConsultada', v_es_evaluativa,
        'campos_disponibles', jsonb_build_object(
            'criterio', academico_test.fn_actividad_criterio_campos_disponibles(
                            v_es_preescolar, p_fk_tunidad IS NOT NULL),
            'evaluacion', jsonb_build_object(
                'visible',   COALESCE(v_evaluativo, FALSE) AND v_es_evaluativa <> 'N',
                'requerido', COALESCE(v_evaluativo, FALSE) AND v_es_evaluativa <> 'N',
                'motivo',    CASE
                    WHEN v_es_evaluativa = 'N'
                        THEN 'La actividad se creara como NO evaluativa; no hay seccion de evaluacion'
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
                               v_es_evaluativa, p_fk_tunidad IS NOT NULL, v_modo),
            'recuperacion', academico_test.fn_actividad_recuperacion_campos_disponibles(
                                COALESCE(v_evaluativo, FALSE), v_es_evaluativa))
    );
END;
$$;
