-- ===========================================================================
-- V484 - Calificacion BULK de escala con varios criterios generales.
--
--   fn_actividad_nota_calificar_escala_bulk (V227; aridad 6 -> 7)
--   PUT /planeador/actividades/:ID/calificar-bulk/escala (V247)
--
-- Por que: V472 guarda una nota POR criterio general, pero el bulk seguia
-- delegando en la individual de un solo valor y nunca escribia
-- TACTIVIDAD_ESCALA_CRITERIO_EVALUACION. Ahora acepta BODY.CRITERIOS y,
-- con un valor suelto, lo replica a todos los criterios.
-- Depende de: V227, V247, V469, V472.
-- ===========================================================================

DROP FUNCTION IF EXISTS academico_test.fn_actividad_nota_calificar_escala_bulk(BIGINT, BIGINT, BIGINT, NUMERIC, BIGINT[], DATE);

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_calificar_escala_bulk(
    p_pk_usuario_solicitante    BIGINT,
    p_pk_tactividad             BIGINT,
    p_pk_nivel                  BIGINT,
    p_valor_numerico            NUMERIC,
    p_criterios                 JSONB,
    p_pk_tactividad_estudiante  BIGINT[],
    p_fecha                     DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
    pk_tactividad_estudiante  BIGINT,
    calificacion              NUMERIC
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_tipo_val            VARCHAR;
    v_criterios_generales VARCHAR;
    v_criterios_esperados INTEGER;
    v_criterios           JSONB;
    v_pk_est              BIGINT;
    v_pct                 NUMERIC(5,2);
BEGIN
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'EDITAR', NULL, NULL, NULL, p_pk_tactividad
    );

    IF p_pk_tactividad_estudiante IS NULL
       OR COALESCE(array_length(p_pk_tactividad_estudiante, 1), 0) = 0 THEN
        RAISE EXCEPTION 'p_pk_tactividad_estudiante debe traer al menos un estudiante' USING ERRCODE = '22023';
    END IF;

    IF p_criterios IS NOT NULL AND jsonb_typeof(p_criterios) = 'null' THEN
        v_criterios := NULL;
    ELSE
        v_criterios := p_criterios;
    END IF;

    IF v_criterios IS NOT NULL THEN
        IF p_pk_nivel IS NOT NULL OR p_valor_numerico IS NOT NULL THEN
            RAISE EXCEPTION 'Con criterios no se envian pkNivel ni valorNumerico sueltos' USING ERRCODE = '22023';
        END IF;
    ELSIF (p_pk_nivel IS NOT NULL) = (p_valor_numerico IS NOT NULL) THEN
        RAISE EXCEPTION 'Debe indicarse criterios, o exactamente uno de pkNivel (escala CUALITATIVA) o valorNumerico (escala NUMERICA)'
            USING ERRCODE = '22023';
    END IF;

    PERFORM academico_test.fn_actividad_instrumento_assert(p_pk_tactividad, 'ESCALA_VALORACION');

    SELECT lv.VALOR, e.CRITERIOS_GENERALES INTO v_tipo_val, v_criterios_generales
      FROM academico_test.TACTIVIDAD_ESCALA e
      JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = e.FK_TLV_TIPO_ESCALA
     WHERE e.FK_TACTIVIDAD = p_pk_tactividad AND e.ACTIVE = TRUE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La actividad no tiene una escala de valoracion definida (use fn_actividad_escala_definir primero)'
            USING ERRCODE = '22023';
    END IF;

    -- Mismo conteo que fn_actividad_nota_calificar_escala_criterios (V472).
    v_criterios_esperados := GREATEST(
        COALESCE(array_length(string_to_array(NULLIF(TRIM(v_criterios_generales), ''), ','), 1), 1), 1);

    IF v_criterios IS NULL THEN
        IF v_tipo_val = 'CUALITATIVA' AND p_pk_nivel IS NULL THEN
            RAISE EXCEPTION 'La escala de esta actividad es CUALITATIVA: la calificacion bulk requiere pkNivel, no valorNumerico'
                USING ERRCODE = '22023';
        END IF;
        IF v_tipo_val <> 'CUALITATIVA' AND p_valor_numerico IS NULL THEN
            RAISE EXCEPTION 'La escala de esta actividad es NUMERICA: la calificacion bulk requiere valorNumerico, no pkNivel'
                USING ERRCODE = '22023';
        END IF;

        -- Con varios criterios, el valor suelto se aplica a cada uno.
        IF v_criterios_esperados > 1 THEN
            SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                       'criterioIndex', i, 'pkNivel', p_pk_nivel, 'valorNumerico', p_valor_numerico)) ORDER BY i)
              INTO v_criterios
              FROM generate_series(0, v_criterios_esperados - 1) AS i;
        END IF;
    END IF;

    FOREACH v_pk_est IN ARRAY p_pk_tactividad_estudiante LOOP
        IF academico_test.fn_actividad_estudiante_actividad(v_pk_est) <> p_pk_tactividad THEN
            RAISE EXCEPTION 'La asignacion actividad-estudiante % no pertenece a la actividad %', v_pk_est, p_pk_tactividad
                USING ERRCODE = '22023';
        END IF;

        IF v_criterios IS NOT NULL THEN
            v_pct := academico_test.fn_actividad_nota_calificar_escala_criterios(
                         p_pk_usuario_solicitante, v_pk_est, v_criterios, p_fecha);
        ELSE
            v_pct := academico_test.fn_actividad_nota_calificar_escala(
                         p_pk_usuario_solicitante, v_pk_est, p_pk_nivel, p_valor_numerico, p_fecha);
        END IF;

        pk_tactividad_estudiante := v_pk_est;
        calificacion             := v_pct;
        RETURN NEXT;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_nota_calificar_escala_bulk(BIGINT, BIGINT, BIGINT, NUMERIC, JSONB, BIGINT[], DATE)
    IS 'Calificacion BULK por escala de valoracion para N estudiantes de la misma actividad. Tres formas: p_criterios = [{criterioIndex, pkNivel|valorNumerico}, ...] (set completo, mismo valor por criterio para todos, delega en fn_actividad_nota_calificar_escala_criterios); o un p_pk_nivel / p_valor_numerico suelto, que con varios criterios generales se replica a cada criterio y con 0-1 criterio va a fn_actividad_nota_calificar_escala. Gate EDITAR sobre PLANEADOR; cada TACTIVIDAD_ESTUDIANTE debe pertenecer a la actividad. Devuelve {pk_tactividad_estudiante, calificacion}. V227; criterios en V484.';


-- El endpoint ya existe (V247): ON CONFLICT DO NOTHING no lo tocaria.
UPDATE public.query q
   SET query = 'SELECT * FROM academico_test.fn_actividad_nota_calificar_escala_bulk(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.PK_NIVEL AS BIGINT),
    CAST(:BODY.VALOR_NUMERICO AS NUMERIC),
    CAST(:BODY.CRITERIOS AS JSONB),
    CAST(:BODY.ESTUDIANTES AS BIGINT[]),
    COALESCE(CAST(:BODY.FECHA AS DATE), CURRENT_DATE)
);',
       param_types = '{"PARAM.ID": "BIGINT", "BODY.PK_NIVEL": "BIGINT", "BODY.VALOR_NUMERICO": "NUMERIC", "BODY.CRITERIOS": "JSONB", "BODY.ESTUDIANTES": "BIGINT[]", "BODY.FECHA": "DATE"}'::jsonb,
       detail = 'V484 -- calificacion BULK por escala de valoracion (fn_actividad_nota_calificar_escala_bulk). :ID = PK_TACTIVIDAD. BODY.ESTUDIANTES (obligatorio) = PKs de TACTIVIDAD_ESTUDIANTE con asistencia valida en BODY.FECHA (default hoy). Valor: BODY.CRITERIOS = [{"criterioIndex":0,"pkNivel":n}|{"criterioIndex":0,"valorNumerico":n}, ...] uno por criterio general (set completo), o BODY.PK_NIVEL (CUALITATIVA) / BODY.VALOR_NUMERICO (NUMERICA) suelto, que con varios criterios se aplica a todos. Devuelve {pk_tactividad_estudiante, calificacion} (0-100). Gate EDITAR sobre PLANEADOR. 22023 si se mezclan CRITERIOS con valor suelto, faltan criterios, el valor no corresponde al tipo de escala o un estudiante no pertenece a la actividad o no tiene asistencia.'
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/actividades/:ID/calificar-bulk/escala'
   AND q.http_method     = 'PUT';
