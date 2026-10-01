-- ===========================================================================
-- V496.23 - La nota proyectada de una asignatura por periodo (V333) aplica:
--   Regla 77: el estado del resultado (V496.5) decide que nota computa.
--   Regla 33: SUMATORIA suma puntos (NOTA_MAXIMA) y un peso que falta en
--             PONDERAR/SUMATORIA es un error 22023, no un promedio silencioso.
--   3.4:      solo actividades sumativas (ES_EVALUATIVA) y no de recuperacion.
-- El universo de notas sale a fn_asignatura_notas_periodo_interno para que
-- las dos ramas (actividades / unidades) no repitan los filtros.
-- Depende de: V333, V408 (politica sin calificar), V239, V496.5 (ESTADO_RESULTADO).
-- ===========================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_asignatura_notas_periodo_interno(
    p_fk_tmatricula          BIGINT,
    p_fk_tasignatura         BIGINT,
    p_fk_tperiodo_evaluacion BIGINT
)
RETURNS TABLE(
    pk_tactividad BIGINT,
    titulo        VARCHAR,
    fk_tunidad    BIGINT,
    ponderacion   NUMERIC,
    puntaje       NUMERIC,
    nota          NUMERIC
)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_fk_grado    BIGINT;
    v_pk_criterio BIGINT;
    v_politica    VARCHAR;
    v_piso        NUMERIC;
BEGIN
    SELECT gr.FK_TGRADO INTO v_fk_grado
      FROM academico_test.TMATRICULA m
      JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = m.FK_TGRUPO
     WHERE m.PK_TMATRICULA = p_fk_tmatricula;

    v_pk_criterio := academico_test.fn_asignatura_criterio_evaluacion_vigente(
                         p_fk_tasignatura, v_fk_grado);
    IF v_pk_criterio IS NOT NULL THEN
        v_politica := academico_test.fn_criterio_evaluacion_desempeno_sin_calificar(v_pk_criterio);
        v_piso     := COALESCE(academico_test.fn_criterio_evaluacion_porcentaje_inicial(v_pk_criterio), 0);
    END IF;

    -- Regla 77. PENDIENTE no tiene valor; la inasistencia justificada sale
    -- siempre del denominador; NO_PRESENTO / no justificada valen el piso de
    -- la escala con "Menor calificacion posible" y se excluyen con "Ninguna"
    -- (o si el colegio no lo configuro: no se inventa la politica).
    RETURN QUERY
    SELECT x.pk, x.titulo, x.unidad, x.ponderacion, x.puntaje, x.nota
      FROM (
            SELECT a.PK_TACTIVIDAD                      AS pk,
                   a.TITULO::VARCHAR                    AS titulo,
                   a.FK_TUNIDAD                         AS unidad,
                   a.PONDERACION::NUMERIC               AS ponderacion,
                   a.NOTA_MAXIMA::NUMERIC               AS puntaje,
                   CASE
                       WHEN UPPER(TRIM(er.VALOR)) IN ('PENDIENTE', 'NO_ASISTIO_JUSTIFICADA')
                       THEN NULL
                       WHEN UPPER(TRIM(er.VALOR)) IN ('NO_PRESENTO', 'NO_ASISTIO_NO_JUSTIFICADA')
                       THEN CASE WHEN v_politica = 'MENOR' THEN v_piso END
                       ELSE COALESCE(n.DEFINITIVA, n.CALIFICACION)
                   END                                  AS nota
              FROM academico_test.TACTIVIDAD a
              JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
                ON ae.FK_TACTIVIDAD = a.PK_TACTIVIDAD
               AND ae.FK_TMATRICULA = p_fk_tmatricula
               AND ae.ACTIVE = TRUE
              JOIN academico_test.TACTIVIDAD_NOTA n
                ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
               AND n.ACTIVE = TRUE
              LEFT JOIN academico_test.TLISTA_VALOR er
                ON er.PK_LISTA_VALOR = n.FK_TLV_ESTADO_RESULTADO
             WHERE a.ACTIVE = TRUE
               AND a.FK_TASIGNATURA = p_fk_tasignatura
               AND COALESCE(a.ES_EVALUATIVA::VARCHAR, 'S') = 'S'
               AND COALESCE(a.ES_RECUPERACION::VARCHAR, 'N') <> 'S'
               AND COALESCE(n.CALIFICABLE, 'S') <> 'N'
               AND academico_test.fn_actividad_en_periodo_eval(
                       a.PK_TACTIVIDAD, p_fk_tperiodo_evaluacion) = TRUE
           ) x
     WHERE x.nota IS NOT NULL;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_asignatura_notas_periodo_interno(BIGINT, BIGINT, BIGINT)
    IS 'INTERNO: universo de notas que computan para (matricula, asignatura, periodo de evaluacion), una fila por actividad con su peso (PONDERACION), su puntaje (NOTA_MAXIMA) y la nota en porcentaje ya resuelta por la Regla 77 segun TACTIVIDAD_NOTA.FK_TLV_ESTADO_RESULTADO y la politica "Sin calificaciones" del criterio (fn_criterio_evaluacion_desempeno_sin_calificar): PENDIENTE y NO_ASISTIO_JUSTIFICADA nunca computan; NO_PRESENTO y NO_ASISTIO_NO_JUSTIFICADA valen PORCENTAJE_INICIAL_CALIF (0 si no hay) con MENOR y se excluyen con NINGUNA o sin politica. Solo actividades sumativas (ES_EVALUATIVA = S), no de recuperacion (su efecto ya esta en DEFINITIVA) y CALIFICABLE <> N. Sin gate. La usa fn_asignatura_definitiva_proyectada_periodo.';


CREATE OR REPLACE FUNCTION academico_test.fn_asignatura_definitiva_proyectada_periodo(
    p_fk_tmatricula          BIGINT,
    p_fk_tasignatura         BIGINT,
    p_fk_tperiodo_evaluacion BIGINT
)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_pk_asignatura_plan BIGINT;
    v_elemento           VARCHAR;
    v_modo               VARCHAR;
    v_resultado          NUMERIC;
    v_falta              VARCHAR;
BEGIN
    SELECT academico_test.fn_asignatura_plan_vigente(m.FK_TGRUPO, p_fk_tasignatura)
      INTO v_pk_asignatura_plan
      FROM academico_test.TMATRICULA m
     WHERE m.PK_TMATRICULA = p_fk_tmatricula;

    IF v_pk_asignatura_plan IS NOT NULL THEN
        v_elemento := academico_test.fn_asignatura_plan_elemento_calculo(v_pk_asignatura_plan);
        v_modo     := academico_test.fn_asignatura_plan_calculo_definitiva_modo(v_pk_asignatura_plan);
    END IF;

    IF v_elemento = 'ACTIVIDADES' THEN
        IF v_modo IN ('PONDERAR', 'SUMATORIA') THEN
            SELECT t.titulo INTO v_falta
              FROM academico_test.fn_asignatura_notas_periodo_interno(
                   p_fk_tmatricula, p_fk_tasignatura, p_fk_tperiodo_evaluacion) t
             WHERE (CASE WHEN v_modo = 'SUMATORIA' THEN t.puntaje ELSE t.ponderacion END) IS NULL
             LIMIT 1;
            IF FOUND THEN
                RAISE EXCEPTION 'La actividad "%" no tiene % y la asignatura calcula por %',
                    v_falta,
                    CASE WHEN v_modo = 'SUMATORIA' THEN 'puntaje' ELSE 'ponderacion' END,
                    v_modo
                    USING ERRCODE = '22023';
            END IF;
        END IF;

        -- SUMATORIA: puntos obtenidos (nota% x puntaje) sobre puntos posibles
        -- de lo ya calificado, llevado a porcentaje.
        SELECT ROUND(
                   CASE
                       WHEN v_modo = 'SUMATORIA'
                       THEN SUM(t.nota * t.puntaje / 100) / NULLIF(SUM(t.puntaje), 0) * 100
                       WHEN v_modo = 'PONDERAR'
                       THEN SUM(t.nota * t.ponderacion) / NULLIF(SUM(t.ponderacion), 0)
                       ELSE AVG(t.nota)
                   END, 2)
          INTO v_resultado
          FROM academico_test.fn_asignatura_notas_periodo_interno(
                   p_fk_tmatricula, p_fk_tasignatura, p_fk_tperiodo_evaluacion) t;

        RETURN v_resultado;
    END IF;

    -- UNIDADES y fallback sin configuracion. Con UNIDADES configurado, una
    -- unidad sin peso o actividades sin unidad son error; en el fallback se
    -- conserva el promedio simple.
    IF v_elemento = 'UNIDADES' THEN
        SELECT format('la actividad "%s" de la unidad "%s" no tiene %s',
                      t.titulo, tu.NOMBRE,
                      CASE WHEN m.modo = 'SUMATORIA' THEN 'puntaje' ELSE 'ponderacion' END)
          INTO v_falta
          FROM academico_test.fn_asignatura_notas_periodo_interno(
                   p_fk_tmatricula, p_fk_tasignatura, p_fk_tperiodo_evaluacion) t
          JOIN academico_test.TUNIDAD tu ON tu.PK_TUNIDAD = t.fk_tunidad
          CROSS JOIN LATERAL (SELECT academico_test.fn_unidad_calculo_definitiva_modo(t.fk_tunidad) AS modo) m
         WHERE (m.modo = 'PONDERAR'  AND t.ponderacion IS NULL)
            OR (m.modo = 'SUMATORIA' AND t.puntaje IS NULL)
         LIMIT 1;
        IF v_falta IS NULL AND v_modo IN ('PONDERAR', 'SUMATORIA') THEN
            SELECT CASE WHEN t.fk_tunidad IS NULL
                        THEN format('la actividad "%s" no tiene unidad', t.titulo)
                        ELSE format('la unidad "%s" no tiene ponderacion', tu.NOMBRE)
                   END
              INTO v_falta
              FROM academico_test.fn_asignatura_notas_periodo_interno(
                   p_fk_tmatricula, p_fk_tasignatura, p_fk_tperiodo_evaluacion) t
              LEFT JOIN academico_test.TUNIDAD tu ON tu.PK_TUNIDAD = t.fk_tunidad
             WHERE tu.PONDERACION IS NULL
             LIMIT 1;
        END IF;
        IF v_falta IS NOT NULL THEN
            RAISE EXCEPTION 'No se puede calcular la nota de la asignatura por unidades: %', v_falta
                USING ERRCODE = '22023';
        END IF;
    END IF;

    WITH por_unidad AS (
        SELECT t.fk_tunidad,
               CASE academico_test.fn_unidad_calculo_definitiva_modo(t.fk_tunidad)
                   WHEN 'SUMATORIA'
                   THEN SUM(t.nota * t.puntaje / 100) / NULLIF(SUM(t.puntaje), 0) * 100
                   WHEN 'PONDERAR'
                   THEN SUM(t.nota * t.ponderacion) / NULLIF(SUM(t.ponderacion), 0)
               END AS nota_calc,
               AVG(t.nota) AS nota_prom
          FROM academico_test.fn_asignatura_notas_periodo_interno(
                   p_fk_tmatricula, p_fk_tasignatura, p_fk_tperiodo_evaluacion) t
         GROUP BY t.fk_tunidad
    ),
    con_peso AS (
        SELECT COALESCE(pu.nota_calc, pu.nota_prom) AS nota_unidad,
               tu.PONDERACION                       AS peso_unidad
          FROM por_unidad pu
          LEFT JOIN academico_test.TUNIDAD tu ON tu.PK_TUNIDAD = pu.FK_TUNIDAD
    )
    SELECT ROUND(
               CASE
                   WHEN v_modo IN ('PONDERAR', 'SUMATORIA')
                        AND COUNT(*) FILTER (WHERE cp.peso_unidad IS NULL) = 0
                        AND SUM(cp.peso_unidad) > 0
                   THEN SUM(cp.nota_unidad * cp.peso_unidad) / SUM(cp.peso_unidad)
                   ELSE AVG(cp.nota_unidad)
               END, 2)
      INTO v_resultado
      FROM con_peso cp;

    RETURN v_resultado;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_asignatura_definitiva_proyectada_periodo(BIGINT, BIGINT, BIGINT)
    IS 'INTERNO: nota proyectada (porcentaje 0-100, sin homologar) de una asignatura en UN periodo de evaluacion; el "gris" de informes. La usan fn_informe_estudiante_asignaturas, fn_asignatura_nota_requerida_periodo, fn_asignatura_definitiva_anual_calcular_interno, fn_informe_periodo_guardar y la recuperacion. Universo: fn_asignatura_notas_periodo_interno (Regla 77, solo sumativas, sin recuperaciones). Motor por fn_asignatura_plan_vigente: ACTIVIDADES -> calculo plano; UNIDADES -> cada unidad con su modo y luego entre unidades con TUNIDAD.PONDERACION; sin configuracion -> mismo camino por unidad con promedio simple como fallback. SUMATORIA suma puntos (nota x NOTA_MAXIMA / sum NOTA_MAXIMA de lo calificado); PONDERAR pondera por PONDERACION (Regla 33). Con el motor configurado, un peso o puntaje que falta, una unidad sin PONDERACION o actividades sin unidad lanzan 22023 nombrando la actividad o la unidad, en vez de caer a promedio. NULL si nada computa en el periodo.';
