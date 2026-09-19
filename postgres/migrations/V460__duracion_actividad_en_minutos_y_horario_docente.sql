-- ===========================================================================
-- V460 — Programacion de actividad: la duracion se cuenta en MINUTOS de clase
-- (antes bloques), a partir de las horas del horario del docente con el grupo
-- (THORARIO, o el bloque del periodo si faltan); inicio y entrega solo en dias
-- con clase; sin negativos en duracion ni semana (assert + CHECK).
-- fn_actividad_programacion_limites cambia sus columnas (DROP + CREATE) y la
-- configuracion expone horario (dias y horas) y duracionEstimada en MINUTOS.
-- Los valores ya guardados en bloques NO se convierten: no se pueden
-- distinguir de minutos sin un marcador, y convertir dos veces los duplicaria.
-- Depende de: V422 (assert/limites), V45 (fn_horario_calcular_bloques),
-- V459 (fn_actividad_configuracion_contexto).
-- ===========================================================================
SET search_path TO academico_test, public;

-- ---------------------------------------------------------------------------
-- 1) Limites de programacion: la duracion se cuenta en MINUTOS de clase.
--    Cambia RETURNS TABLE -> DROP + CREATE (misma aridad).
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_actividad_programacion_limites(BIGINT, BIGINT);
CREATE FUNCTION academico_test.fn_actividad_programacion_limites(
    p_fk_tgrupo      BIGINT,
    p_fk_tasignatura BIGINT
)
RETURNS TABLE (
    fk_tperiodo_academico BIGINT,
    periodo_academico     VARCHAR,
    periodo_desde         DATE,
    periodo_hasta         DATE,
    semanas               INT,
    bloques_por_semana    INT,
    minutos_por_bloque    NUMERIC,
    minutos_por_semana    NUMERIC,
    dias_habiles          INT[],
    dias_habiles_nombre   JSONB,
    horario               JSONB,
    fecha_min             DATE,
    fecha_max             DATE,
    duracion_max          NUMERIC
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_desde DATE; v_hasta DATE; v_sem INT; v_blo INT;
    v_dias INT[]; v_nom JSONB; v_fmin DATE; v_fmax DATE;
    v_pk BIGINT; v_nombre VARCHAR;
    v_min_bloque NUMERIC; v_min_semana NUMERIC; v_sin_horas INT; v_horario JSONB;
BEGIN
    SELECT pa.PK_TPERIODO_ACADEMICO, pa.NOMBRE, pa.FECHA_INICIO, pa.FECHA_FIN
      INTO v_pk, v_nombre, v_desde, v_hasta
      FROM academico_test.TGRUPO gr
      JOIN academico_test.TGRADO g ON g.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa
            ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
           AND pa.ACTIVE = TRUE
     WHERE gr.PK_TGRUPO = p_fk_tgrupo;

    IF v_desde IS NOT NULL AND v_hasta IS NOT NULL THEN
        v_sem := CEIL(((v_hasta - v_desde) + 1) / 7.0)::INT;
    END IF;

    -- Bloques del (grupo, asignatura) con sus horas: las de THORARIO y, si
    -- faltan, las del bloque del periodo (fn_horario_calcular_bloques, V45).
    WITH b AS (
        SELECT lv.VALOR::INT AS dia, lv.NOMBRE AS dia_nombre, h.NUMERO_BLOQUE::INT AS numero_bloque,
               COALESCE(h.HORA_INICIO::TIME, cb.hora_inicio) AS hora_inicio,
               COALESCE(h.HORA_FIN::TIME,    cb.hora_fin)    AS hora_fin
          FROM academico_test.THORARIO h
          JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = h.FK_TLV_DIA_SEMANA
          LEFT JOIN LATERAL (SELECT * FROM academico_test.fn_horario_calcular_bloques(v_pk) x
                              WHERE x.numero_bloque = h.NUMERO_BLOQUE::INT) cb ON v_pk IS NOT NULL
         WHERE h.FK_TGRUPO = p_fk_tgrupo
           AND h.FK_TASIGNATURA = p_fk_tasignatura
           AND h.ACTIVE = TRUE
    ), bm AS (
        SELECT b.*, CASE WHEN hora_inicio IS NOT NULL AND hora_fin IS NOT NULL
                         THEN ROUND(EXTRACT(EPOCH FROM (hora_fin - hora_inicio)) / 60, 2) END AS minutos
          FROM b
    )
    SELECT COUNT(*)::INT,
           COALESCE(ARRAY_AGG(DISTINCT dia ORDER BY dia), ARRAY[]::INT[]),
           COALESCE(jsonb_agg(DISTINCT jsonb_build_object('valor', dia, 'nombre', dia_nombre)), '[]'::jsonb),
           ROUND(AVG(minutos), 2),
           SUM(minutos),
           COUNT(*) FILTER (WHERE minutos IS NULL OR minutos <= 0),
           COALESCE((SELECT jsonb_agg(jsonb_build_object(
                          'valor', d.dia, 'nombre', d.dia_nombre,
                          'bloques', (SELECT jsonb_agg(jsonb_build_object(
                                          'numero', x.numero_bloque, 'horaInicio', x.hora_inicio,
                                          'horaFin', x.hora_fin, 'minutos', x.minutos)
                                          ORDER BY x.numero_bloque)
                                        FROM bm x WHERE x.dia = d.dia))
                          ORDER BY d.dia)
                       FROM (SELECT DISTINCT dia, dia_nombre FROM bm) d), '[]'::jsonb)
      INTO v_blo, v_dias, v_nom, v_min_bloque, v_min_semana, v_sin_horas, v_horario
      FROM bm;

    IF COALESCE(v_sin_horas, 0) > 0 THEN
        v_min_semana := NULL;          -- no se inventan minutos para un bloque sin horas
    END IF;

    -- DIA_SEMANA.VALOR es EXTRACT(DOW)+1 (Domingo = 1).
    IF v_desde IS NOT NULL AND COALESCE(array_length(v_dias, 1), 0) > 0 THEN
        SELECT MIN(d)::DATE, MAX(d)::DATE INTO v_fmin, v_fmax
          FROM generate_series(v_desde, v_hasta, INTERVAL '1 day') d
         WHERE (EXTRACT(DOW FROM d)::INT + 1) = ANY(v_dias);
    ELSE
        v_fmin := v_desde; v_fmax := v_hasta;
    END IF;

    RETURN QUERY SELECT v_pk, v_nombre, v_desde, v_hasta, v_sem, v_blo,
                        v_min_bloque, v_min_semana, v_dias, v_nom, v_horario,
                        v_fmin, v_fmax,
                        CASE WHEN v_min_semana IS NOT NULL AND v_sem IS NOT NULL
                             THEN v_sem * v_min_semana END;
END;
$$;
COMMENT ON FUNCTION academico_test.fn_actividad_programacion_limites(BIGINT, BIGINT)
    IS 'Fuente UNICA de los limites de la seccion Programacion de una actividad, compartida por la pantalla (fn_actividad_configuracion_contexto) y la escritura (fn_actividad_programacion_assert). La ventana la fija el PERIODO ACADEMICO del grado del grupo; semanas = CEIL(dias / 7). El horario del docente con ese grupo sale de THORARIO ACTIVO del (grupo, asignatura): bloques_por_semana, dias_habiles (DIA_SEMANA.VALOR = EXTRACT(DOW)+1, Domingo = 1) y horario = [{valor, nombre, bloques:[{numero, horaInicio, horaFin, minutos}]}], con las horas de THORARIO o, si faltan, las del bloque del periodo (fn_horario_calcular_bloques). LA DURACION SE CUENTA EN MINUTOS: minutos_por_bloque (promedio), minutos_por_semana (suma) y duracion_max = semanas x minutos_por_semana. Si algun bloque no tiene horas, minutos_por_semana y duracion_max vienen NULL en vez de inventar un tope. fecha_min / fecha_max = primer y ultimo dia con clase dentro del periodo.';

-- ---------------------------------------------------------------------------
-- 2) Validacion de escritura: minutos, dias con clase para inicio Y cierre,
--    y sin negativos. Misma firma que V422: CREATE OR REPLACE.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_programacion_assert(
    p_fk_tgrupo         BIGINT,
    p_fk_tasignatura    BIGINT,
    p_fecha_inicio      DATE,
    p_fecha_cierre      DATE,
    p_duracion          NUMERIC,
    p_semana_cronograma VARCHAR
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    l      RECORD;
    v_sem  INT;
BEGIN
    -- Valores imposibles: no dependen del contexto.
    IF p_duracion IS NOT NULL AND p_duracion < 0 THEN
        RAISE EXCEPTION 'La duracion estimada (%) no puede ser negativa', p_duracion USING ERRCODE = '22023';
    END IF;
    IF p_semana_cronograma ~ '-\s*\d' THEN
        RAISE EXCEPTION 'La semana del cronograma (%) no admite numeros negativos', p_semana_cronograma
            USING ERRCODE = '22023';
    END IF;
    IF p_duracion IS NOT NULL AND p_duracion < 1 THEN
        RAISE EXCEPTION 'La duracion estimada (%) debe ser al menos 1 minuto', p_duracion USING ERRCODE = '22023';
    END IF;

    IF p_fk_tgrupo IS NULL OR p_fk_tasignatura IS NULL THEN
        RETURN;                       -- sin contexto no hay limites que aplicar
    END IF;

    SELECT * INTO l
      FROM academico_test.fn_actividad_programacion_limites(p_fk_tgrupo, p_fk_tasignatura);

    IF l.periodo_desde IS NOT NULL THEN
        IF p_fecha_inicio IS NOT NULL
           AND (p_fecha_inicio < l.periodo_desde OR p_fecha_inicio > l.periodo_hasta) THEN
            RAISE EXCEPTION 'La fecha de inicio (%) esta fuera del periodo academico % (% a %)',
                p_fecha_inicio, COALESCE(l.periodo_academico, ''), l.periodo_desde, l.periodo_hasta
                USING ERRCODE = '22023';
        END IF;
        IF p_fecha_cierre IS NOT NULL
           AND (p_fecha_cierre < l.periodo_desde OR p_fecha_cierre > l.periodo_hasta) THEN
            RAISE EXCEPTION 'La fecha de cierre (%) esta fuera del periodo academico % (% a %)',
                p_fecha_cierre, COALESCE(l.periodo_academico, ''), l.periodo_desde, l.periodo_hasta
                USING ERRCODE = '22023';
        END IF;
    END IF;

    -- Inicio y entrega solo en dias en que el docente tiene clase con el grupo.
    IF COALESCE(array_length(l.dias_habiles, 1), 0) > 0 THEN
        IF p_fecha_inicio IS NOT NULL
           AND NOT ((EXTRACT(DOW FROM p_fecha_inicio)::INT + 1) = ANY(l.dias_habiles)) THEN
            RAISE EXCEPTION 'La fecha de inicio (%) cae en un dia en que no se dicta la asignatura segun el horario del grupo',
                p_fecha_inicio USING ERRCODE = '22023';
        END IF;
        IF p_fecha_cierre IS NOT NULL
           AND NOT ((EXTRACT(DOW FROM p_fecha_cierre)::INT + 1) = ANY(l.dias_habiles)) THEN
            RAISE EXCEPTION 'La fecha de cierre (%) cae en un dia en que no se dicta la asignatura segun el horario del grupo',
                p_fecha_cierre USING ERRCODE = '22023';
        END IF;
    END IF;

    IF p_duracion IS NOT NULL AND l.duracion_max IS NOT NULL AND p_duracion > l.duracion_max THEN
        RAISE EXCEPTION 'La duracion estimada (% minutos) supera el maximo de % minutos: % semanas del periodo academico por % minutos semanales de clase de la asignatura',
            p_duracion, l.duracion_max, l.semanas, l.minutos_por_semana
            USING ERRCODE = '22023';
    END IF;

    -- SEMANA_CRONOGRAMA es texto y admite rangos ("10-12"): se valida CADA
    -- numero que aparezca, no el campo entero como un entero.
    IF l.semanas IS NOT NULL AND NULLIF(TRIM(COALESCE(p_semana_cronograma, '')), '') IS NOT NULL THEN
        FOR v_sem IN
            SELECT t[1]::INT
              FROM regexp_matches(p_semana_cronograma, '\d+', 'g') t
        LOOP
            IF v_sem < 1 OR v_sem > l.semanas THEN
                RAISE EXCEPTION 'La semana del cronograma (%) esta fuera de rango: el periodo academico tiene % semanas',
                    v_sem, l.semanas USING ERRCODE = '22023';
            END IF;
        END LOOP;
    END IF;
END;
$$;
COMMENT ON FUNCTION academico_test.fn_actividad_programacion_assert(BIGINT, BIGINT, DATE, DATE, NUMERIC, VARCHAR)
    IS 'Validacion de la seccion Programacion al crear/actualizar una actividad (llamada por fn_actividad_crear/_actualizar), con los mismos limites que ve la pantalla (fn_actividad_programacion_limites). Sin contexto (grupo o asignatura NULL) solo rechaza valores imposibles: duracion negativa o menor que 1 minuto y semana del cronograma con numeros negativos. Con contexto: fechas de inicio y cierre dentro del periodo academico y AMBAS en un dia en que el docente dicta la asignatura al grupo segun THORARIO (sin horario no se exige); DURACION_ESTIMADA en MINUTOS, como maximo semanas x minutos semanales de clase (sin horas en el horario no hay tope); semanas del cronograma entre 1 y las semanas del periodo. 22023 en todos los casos.';

-- ---------------------------------------------------------------------------
-- 3) La columna misma no admite negativos, venga de donde venga.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_tactividad_duracion_no_negativa'
                      AND conrelid = 'academico_test.tactividad'::regclass) THEN
        ALTER TABLE academico_test.TACTIVIDAD
            ADD CONSTRAINT ck_tactividad_duracion_no_negativa
            CHECK (DURACION_ESTIMADA IS NULL OR DURACION_ESTIMADA >= 0) NOT VALID;
    END IF;
END $$;
COMMENT ON COLUMN academico_test.TACTIVIDAD.DURACION_ESTIMADA
    IS 'Duracion estimada de la actividad en MINUTOS de clase (programacion). Tope: semanas del periodo academico x minutos semanales de la asignatura en el horario del grupo. No admite negativos.';

-- ---------------------------------------------------------------------------
-- 4) La configuracion expone minutos y el horario. Misma firma que V459.
-- ---------------------------------------------------------------------------
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
                WHEN COALESCE(v_bloques, 0) = 0
                    THEN 'El grupo no tiene horario configurado para esta asignatura'
                WHEN v_min_semana IS NULL
                    THEN 'El horario no tiene horas definidas en todos sus bloques; no se pueden contar minutos'
                ELSE 'Dias y horas en que el docente dicta esta asignatura a este grupo, segun THORARIO' END),
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
            'motivo', CASE
                WHEN COALESCE(array_length(v_dias, 1), 0) = 0
                    THEN 'No puede ser anterior a la fecha de inicio ni exceder el periodo academico'
                ELSE 'No puede ser anterior a la fecha de inicio, debe caer en un dia en que se dicta la asignatura y no exceder el periodo academico' END),
        'semanaCronograma', jsonb_build_object(
            'min', 1,
            'max', v_semanas,
            'motivo', CASE WHEN v_semanas IS NULL
                THEN 'El grado no tiene periodo academico asociado; no se puede acotar'
                ELSE 'Semanas que dura el periodo academico' END),
        'duracionEstimada', jsonb_build_object(
            'min', 1,
            'max', v_duracion_max,
            'unidad', 'MINUTOS',
            'paso', v_min_bloque,
            'motivo', CASE WHEN v_duracion_max IS NULL
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
                                p_fk_tactividad_recuperar, NULL, p_pk_usuario_solicitante))
    );
END;
$$;


-- El detail de la fila public.query sigue diciendo BLOQUES: se reconcilia.
UPDATE public.query q
   SET detail = REPLACE(REPLACE(q.detail,
        'duracionEstimada {min: 1, max} donde max = semanas del periodo x bloques semanales de la asignatura (la intensidad horaria, contada sobre THORARIO activo), e intensidadHoraria {bloquesPorSemana, diasHabiles:[{valor,nombre}]}',
        'duracionEstimada {min: 1, max, unidad: MINUTOS, paso} donde max = semanas del periodo x minutos semanales de clase de la asignatura (horas de THORARIO o del bloque del periodo), e intensidadHoraria {bloquesPorSemana, minutosPorBloque, minutosPorSemana, diasHabiles:[{valor,nombre}], horario:[{valor, nombre, bloques:[{numero, horaInicio, horaFin, minutos}]}]}: las fechas de inicio y cierre solo se aceptan en dias con clase'),
        'sin horario, las fechas solo se acotan por el periodo y duracionEstimada.max viene NULL',
        'sin horario, las fechas solo se acotan por el periodo; sin horas en el horario duracionEstimada.max viene NULL')
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/actividades/configuracion'
   AND q.http_method     = 'GET';
