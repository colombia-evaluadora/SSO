-- ===========================================================================
-- V410 - La nota que el estudiante NECESITA en un periodo sin calificaciones.
-- Queda fn_asignatura_nota_requerida_periodo (el despeje, por asignatura).
-- fn_informe_estudiante_asignaturas y fn_informe_periodo_requerido viven en
-- V428; el COMMENT de la segunda, en V516.
-- ===========================================================================


CREATE OR REPLACE FUNCTION academico_test.fn_asignatura_nota_requerida_periodo(
    p_fk_tmatricula          BIGINT,
    p_fk_tasignatura         BIGINT,
    p_fk_tperiodo_evaluacion BIGINT
)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_fk_grado  BIGINT;
    v_fk_peraca BIGINT;
    v_minimo    NUMERIC;
    v_modo      VARCHAR;
    v_suma_pct  NUMERIC;
    v_ponderar  BOOLEAN;
    r           RECORD;
    v_peso      NUMERIC;
    v_nota      NUMERIC;
    v_S         NUMERIC := 0;
    v_W         NUMERIC := 0;
    v_E         NUMERIC := 0;
    v_pedido_con_nota BOOLEAN := FALSE;
BEGIN
    SELECT gd.PK_TGRADO, gd.FK_TPERIODO_ACADEMICO
      INTO v_fk_grado, v_fk_peraca
      FROM academico_test.TMATRICULA m
      JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = m.FK_TGRUPO
      JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
     WHERE m.PK_TMATRICULA = p_fk_tmatricula
       AND m.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    -- Sin umbral no hay contra que despejar. Ver el punto (5).
    v_minimo := academico_test.fn_grado_desempeno_minimo(v_fk_grado);
    IF v_minimo IS NULL THEN
        RETURN NULL;
    END IF;

    -- Como se combinan los periodos para la nota del ano.
    SELECT lv.VALOR
      INTO v_modo
      FROM academico_test.TCRITERIO_EVALUACION ce
      JOIN academico_test.TLISTA_VALOR lv
        ON lv.PK_LISTA_VALOR = ce.FK_TLV_CRITERIO_FINAL
     WHERE ce.PK_TCRITERIO_EVALUACION =
           academico_test.fn_asignatura_criterio_evaluacion_vigente(
               p_fk_tasignatura, v_fk_grado);

    SELECT SUM(pe.PORCENTAJE)
      INTO v_suma_pct
      FROM academico_test.TPERIODO_EVALUACION pe
     WHERE pe.ACTIVE = TRUE
       AND pe.FK_TPERIODO_ACADEMICO = v_fk_peraca;

    -- Dos fallbacks a equitativo: criterio sin configurar, o pesos que no
    -- suman 100. Ver el punto (3).
    v_ponderar := (v_modo = '2' AND v_suma_pct = 100);

    FOR r IN
        SELECT pe.PK_TPERIODO_EVALUACION AS pk,
               COALESCE(pe.PORCENTAJE, 0) AS pct
          FROM academico_test.TPERIODO_EVALUACION pe
         WHERE pe.ACTIVE = TRUE
           AND pe.FK_TPERIODO_ACADEMICO = v_fk_peraca
    LOOP
        v_peso := CASE WHEN v_ponderar THEN r.pct ELSE 1 END;

        SELECT sn.DEFINITIVA
          INTO v_nota
          FROM academico_test.TASIGNATURA_NOTA sn
         WHERE sn.FK_TMATRICULA          = p_fk_tmatricula
           AND sn.FK_TASIGNATURA         = p_fk_tasignatura
           AND sn.FK_TPERIODO_EVALUACION = r.pk
           AND sn.ACTIVE = TRUE;

        IF v_nota IS NULL THEN
            v_nota := academico_test.fn_asignatura_definitiva_proyectada_periodo(
                          p_fk_tmatricula, p_fk_tasignatura, r.pk);
        END IF;

        v_W := v_W + v_peso;

        IF v_nota IS NOT NULL THEN
            v_S := v_S + (v_nota * v_peso);
            IF r.pk = p_fk_tperiodo_evaluacion THEN
                v_pedido_con_nota := TRUE;
            END IF;
        ELSE
            v_E := v_E + v_peso;
        END IF;

        v_nota := NULL;
    END LOOP;

    -- El periodo pedido ya tiene nota: no hay nada que requerir en el. Se
    -- devuelve NULL en vez de un numero que no le aplica.
    IF v_pedido_con_nota THEN
        RETURN NULL;
    END IF;

    -- Sin incognitas -- o con peso cero en todas ellas -- el despeje no tiene
    -- solucion.
    IF v_E IS NULL OR v_E = 0 THEN
        RETURN NULL;
    END IF;

    RETURN ROUND(((v_minimo * v_W) - v_S) / v_E, 2);
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_asignatura_nota_requerida_periodo(BIGINT, BIGINT, BIGINT)
    IS 'Cuanto necesita sacar un estudiante en un periodo SIN CALIFICACIONES para no perder la asignatura en el AÑO. No es una proyeccion -- esa sale de notas que existen -- sino un DESPEJE: dadas las notas de los periodos que si tienen, cuanto hay que sacar en los que faltan para llegar al minimo. Formula sobre TODOS los periodos del ano, no solo los seleccionados, porque la pregunta es por la asignatura en el ano: con S = suma(nota*peso) de los periodos con nota, W = suma(peso) de todos y E = suma(peso) de los vacios, requerido = (minimo*W - S)/E. Un solo valor para todos los vacios: si faltan el tercero y el cuarto, responde cuanto sacar en CADA uno asumiendo lo mismo en ambos, que es la lectura natural de la pregunta; cualquier otro reparto seria una decision arbitraria disfrazada de calculo. La nota ya lograda de cada periodo es COALESCE(guardada, proyectada). El minimo sale de TCRITERIO_PROMOCION.DESEMPENHO_MINIMO ("porcentaje minimo por area o asignatura") y NO de DESEMPENHO_MINIMO_GENERAL, que es el umbral del promedio general; la forma de combinar periodos sale de TCRITERIO_EVALUACION.FK_TLV_CRITERIO_FINAL -> CRITERIO_FINAL_PERACA (1 equitativo, 2 por porcentaje de cada PE) y este es el PRIMER uso de ese criterio para calcular algo: hasta ahora solo lo tocaban los CRUD de configuracion. Cae a EQUITATIVO en dos casos: criterio sin configurar (solo 24 de 163 criterios activos lo tienen) y pesos que no suman 100 (medido: con 4 periodos los 77 peracas suman 100, pero con 1 periodo solo 2 de 12, y con 2 periodos 34 de 41) -- ponderar con pesos rotos da un numero que parece preciso y no lo es, y aqui ese numero le dice a un estudiante cuanto tiene que sacar. Devuelve NULL si el periodo pedido YA tiene nota (no aplica), si no hay incognitas, o si el grado no tiene DESEMPENHO_MINIMO configurado -- 425 de 742 filas activas --: no se inventa un 60, porque decirle a alguien que necesita 4,2 por una configuracion que el colegio nunca hizo es peor que no decirle nada. El resultado puede superar el maximo o ser negativo y se devuelve igual: necesitar 130 sobre 100 ES la informacion (ya perdio), y recortarlo la esconderia.';
