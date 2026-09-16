-- ===========================================================================
-- V333 - fn_asignatura_definitiva_proyectada_periodo: la nota proyectada de
--        una asignatura ACOTADA A UN PERIODO DE EVALUACION.
--
-- POR QUE NO ALCANZA LA QUE YA EXISTE
--   fn_planilla_definitiva_proyectada(matricula, asignatura) calcula la nota
--   al vuelo desde TACTIVIDAD_NOTA y es exactamente el "gris" que la vista de
--   informes necesita -- pero NO filtra por periodo. Barre todas las
--   actividades evaluativas de la asignatura, sin mirar fechas.
--
--   Para la planilla eso esta bien: ahi la pregunta es "como va el estudiante
--   en la asignatura". En informes la pregunta es otra -- "que saco en el
--   primer periodo" -- y son numeros distintos. Por eso esta funcion y no un
--   parametro opcional en aquella: la que existe la usa el modulo de planilla
--   y no se toca.
--
-- QUE COMPARTE Y QUE CAMBIA
--   El ALGORITMO es el mismo, copiado de la version viva, no reescrito:
--
--     (a) Se resuelve el motor de calculo de (grupo, asignatura) con
--         fn_asignatura_plan_vigente -> elemento (ACTIVIDADES | UNIDADES) y
--         modo (PONDERAR | PROMEDIAR | SUMATORIA).
--     (b) ACTIVIDADES: todas compiten planas en un mismo calculo.
--     (c) UNIDADES y (e) fallback sin configuracion: cada unidad resuelve su
--         nota con su propio modo y despues se combinan entre si; si a alguna
--         unidad le falta PONDERACION -- o hay actividades sueltas sin unidad,
--         que forman un bucket sin peso posible -- se cae a promedio simple,
--         porque ponderar con huecos daria un resultado sesgado y silencioso.
--
--   Lo UNICO que cambia es un filtro mas en las dos ramas:
--     fn_actividad_en_periodo_eval(a.PK_TACTIVIDAD, p_fk_tperiodo_evaluacion)
--
--   Mantener el algoritmo identico es deliberado: si las dos divergen, el
--   consolidado del ano y la suma de sus periodos dejarian de explicarse
--   entre si. Si aquella cambia, esta tiene que cambiar igual.
--
-- LO QUE DEVUELVE, Y LO QUE NO
--   Devuelve el PORCENTAJE (0..100), igual que la original -- no la nota en
--   la escala del colegio. Homologar es trabajo de fn_nota_homologar, que
--   necesita el grado ademas de la asignatura y decide si ese colegio
--   califica con numero o con valoracion cualitativa.
--
--   Devuelve NULL cuando no hay ninguna actividad calificada en el periodo.
--   NULL no es cero: significa "todavia no hay con que proyectar", y quien
--   lo muestre debe distinguirlo de un cero real.
--
--   En preescolar devolvera NULL casi siempre, y esta bien: alli las
--   observaciones se guardan con CALIFICABLE='N' y el filtro las excluye a
--   proposito -- un comentario no promedia. Ese caso se resuelve con
--   TASIGNATURA_NOTA_OBSERVACION (V330/V332), no aca.
--
-- Idempotente: CREATE OR REPLACE. Funcion nueva, sin sobrecarga previa.
-- ===========================================================================


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
    v_elemento           VARCHAR;   -- 'ACTIVIDADES' | 'UNIDADES' | NULL
    v_modo               VARCHAR;   -- 'PONDERAR' | 'PROMEDIAR' | 'SUMATORIA' | NULL
    v_resultado          NUMERIC;
BEGIN
    -- Configuracion del motor de calculo para (grupo de la matricula,
    -- asignatura). Puede no resolverse: en ese caso v_elemento queda NULL y
    -- se aplica el fallback.
    SELECT academico_test.fn_asignatura_plan_vigente(m.FK_TGRUPO, p_fk_tasignatura)
      INTO v_pk_asignatura_plan
      FROM academico_test.TMATRICULA m
     WHERE m.PK_TMATRICULA = p_fk_tmatricula;

    IF v_pk_asignatura_plan IS NOT NULL THEN
        v_elemento := academico_test.fn_asignatura_plan_elemento_calculo(v_pk_asignatura_plan);
        v_modo     := academico_test.fn_asignatura_plan_calculo_definitiva_modo(v_pk_asignatura_plan);
    END IF;

    IF v_elemento = 'ACTIVIDADES' THEN
        -- (b) PLANO: todas las actividades evaluativas calificadas DEL
        -- PERIODO compiten en un mismo calculo, sin pasar por unidad.
        WITH notas AS (
            SELECT COALESCE(a.PONDERACION, 0)             AS peso,
                   COALESCE(n.DEFINITIVA, n.CALIFICACION) AS nota
              FROM academico_test.TACTIVIDAD a
              JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
                ON ae.FK_TACTIVIDAD = a.PK_TACTIVIDAD
               AND ae.FK_TMATRICULA = p_fk_tmatricula
               AND ae.ACTIVE = TRUE
              JOIN academico_test.TACTIVIDAD_NOTA n
                ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
               AND n.ACTIVE = TRUE
             WHERE a.ACTIVE = TRUE
               AND a.FK_TASIGNATURA = p_fk_tasignatura
               AND COALESCE(a.ES_EVALUATIVA::VARCHAR, 'S') = 'S'
               AND COALESCE(n.CALIFICABLE, 'S') <> 'N'
               AND COALESCE(n.DEFINITIVA, n.CALIFICACION) IS NOT NULL
               -- *** lo unico que esta funcion agrega ***
               AND academico_test.fn_actividad_en_periodo_eval(
                       a.PK_TACTIVIDAD, p_fk_tperiodo_evaluacion) = TRUE
        )
        SELECT ROUND(
                   CASE
                       WHEN v_modo IN ('PONDERAR', 'SUMATORIA') AND SUM(nt.peso) > 0
                       THEN SUM(nt.nota * nt.peso) / SUM(nt.peso)
                       ELSE AVG(nt.nota)
                   END, 2)
          INTO v_resultado
          FROM notas nt;

        RETURN v_resultado;
    END IF;

    -- (c) POR UNIDAD (v_elemento = 'UNIDADES') y (e) fallback sin
    -- configuracion comparten camino, igual que en la version del ano.
    WITH notas AS (
        SELECT a.FK_TUNIDAD,
               COALESCE(a.PONDERACION, 0)             AS peso,
               COALESCE(n.DEFINITIVA, n.CALIFICACION) AS nota
          FROM academico_test.TACTIVIDAD a
          JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
            ON ae.FK_TACTIVIDAD = a.PK_TACTIVIDAD
           AND ae.FK_TMATRICULA = p_fk_tmatricula
           AND ae.ACTIVE = TRUE
          JOIN academico_test.TACTIVIDAD_NOTA n
            ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
           AND n.ACTIVE = TRUE
         WHERE a.ACTIVE = TRUE
           AND a.FK_TASIGNATURA = p_fk_tasignatura
           AND COALESCE(a.ES_EVALUATIVA::VARCHAR, 'S') = 'S'
           AND COALESCE(n.CALIFICABLE, 'S') <> 'N'
           AND COALESCE(n.DEFINITIVA, n.CALIFICACION) IS NOT NULL
           -- *** lo unico que esta funcion agrega ***
           AND academico_test.fn_actividad_en_periodo_eval(
                   a.PK_TACTIVIDAD, p_fk_tperiodo_evaluacion) = TRUE
    ),
    por_unidad AS (
        SELECT nt.FK_TUNIDAD,
               CASE
                   WHEN academico_test.fn_unidad_calculo_definitiva_modo(nt.FK_TUNIDAD)
                            IN ('PONDERAR', 'SUMATORIA')
                        AND SUM(nt.peso) > 0
                   THEN SUM(nt.nota * nt.peso) / SUM(nt.peso)
                   ELSE AVG(nt.nota)
               END AS nota_unidad
          FROM notas nt
         GROUP BY nt.FK_TUNIDAD
    ),
    con_peso AS (
        -- El bucket de actividades sin unidad (FK_TUNIDAD NULL) no tiene peso
        -- posible: el LEFT JOIN lo deja en NULL y, por la regla de abajo,
        -- fuerza el promedio simple.
        SELECT pu.nota_unidad,
               tu.PONDERACION AS peso_unidad
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
    IS 'Nota proyectada (el "gris" de la vista de informes) de una asignatura para UN periodo de evaluacion. Existe porque fn_planilla_definitiva_proyectada, que hace este mismo calculo, NO filtra por periodo: barre todas las actividades evaluativas de la asignatura sin mirar fechas, que es lo correcto para la planilla ("como va en la asignatura") pero no para el informe ("que saco en el primer periodo"). El algoritmo es copia literal de aquella -- motor de calculo por fn_asignatura_plan_vigente, rama plana por ACTIVIDADES o rama por UNIDADES con fallback a promedio simple cuando falta alguna ponderacion -- y lo UNICO que agrega es el filtro fn_actividad_en_periodo_eval en las dos ramas. Mantenerlas identicas es deliberado: si divergen, el consolidado del ano y la suma de sus periodos dejan de explicarse entre si; si aquella cambia, esta debe cambiar igual. Devuelve PORCENTAJE (0..100), no la nota en la escala del colegio: homologar es trabajo de fn_nota_homologar, que necesita tambien el grado. Devuelve NULL cuando no hay ninguna actividad calificada en el periodo -- NULL no es cero, es "no hay con que proyectar". En preescolar devolvera NULL casi siempre y es correcto: alli las observaciones se guardan con CALIFICABLE=N y el filtro las excluye a proposito, porque un comentario no promedia; ese caso lo cubre TASIGNATURA_NOTA_OBSERVACION.';
