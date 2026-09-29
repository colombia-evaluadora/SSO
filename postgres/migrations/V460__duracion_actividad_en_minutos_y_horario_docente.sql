-- ===========================================================================
-- V460 - Programacion de actividad: la duracion se cuenta en MINUTOS de clase
-- (antes bloques), a partir de las horas del horario del docente con el grupo
-- (THORARIO, o el bloque del periodo si faltan); inicio y entrega solo en dias
-- con clase; sin negativos en duracion ni semana (assert + CHECK).
-- fn_actividad_programacion_limites cambia sus columnas (DROP + CREATE).
-- Los valores ya guardados en bloques NO se convierten.
-- fn_actividad_configuracion_contexto vive hoy en V496.
-- Depende de: V422 (assert/limites), V45 (fn_horario_calcular_bloques),
-- V459 (detail de la fila de configuracion, que aqui se reconcilia).
-- ===========================================================================


SET search_path TO academico_test, public;

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
