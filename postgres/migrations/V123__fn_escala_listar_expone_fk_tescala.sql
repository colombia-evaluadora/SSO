-- Bug de contrato: "Escala de valoración" en criterio de evaluación mezclaba
-- TRES espacios de id distintos como si fueran el mismo campo:
--   - GET  (fn_criterio_eval_obtener) devuelve grading_scale = FK_TESCALA
--     (el PK de la escala contenedora, TESCALA).
--   - PUT  (fn_criterio_eval_actualizar, ver V95) espera p_grading_scale =
--     PK_TESCALA_VALORACION (el PK de UNA banda individual).
--   - El front arma el selector de "Escala de valoración" agrupando por
--     NIVEL DE ENSEÑANZA (lvl.id) — un tercer espacio de id, sin relación
--     con los otros dos — porque fn_escala_listar nunca exponía el
--     FK_TESCALA de cada banda, así que el front no tenía forma de resolver
--     "en qué nivel está esta escala" ni "qué escala corresponde a este
--     nivel" sin ese dato.
--
-- Este fix es el primer paso (backend): agrega FK_TESCALA a lo que devuelve
-- fn_escala_listar, para que el front pueda armar el mapeo
-- nivel<->escala<->banda-representativa que hace falta para no seguir
-- mandando un nivel donde el back espera un PK_TESCALA_VALORACION.
DROP FUNCTION IF EXISTS academico_test.fn_escala_listar(bigint, text, bigint, bigint, text, text);

CREATE OR REPLACE FUNCTION academico_test.fn_escala_listar(p_academic_period_id bigint, p_filtro text DEFAULT NULL::text, p_pk_usuario bigint DEFAULT NULL::bigint, p_teaching_level_id bigint DEFAULT NULL::bigint, p_sort_by text DEFAULT NULL::text, p_sort_dir text DEFAULT NULL::text)
 RETURNS TABLE(id bigint, nombre character varying, abreviacion character varying, tipo character varying, tipo_name character varying, iconografia character varying, teaching_level_id bigint, teaching_level_name character varying, nota_minima numeric, nota_maxima numeric, nota_equivalente numeric, escala_id bigint)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_col TEXT;
    v_dir TEXT;
BEGIN
    v_col := CASE lower(coalesce(p_sort_by, ''))
        WHEN 'nombre'            THEN 'v.NOMBRE'
        WHEN 'abreviacion'       THEN 'v.CODIGO'
        WHEN 'tipo'              THEN 'tv.VALOR'
        WHEN 'teachinglevelname' THEN 'nen.NOMBRE'
        WHEN 'notaminima'        THEN 'nota_minima'
        WHEN 'notamaxima'        THEN 'nota_maxima'
        WHEN 'notaequivalente'   THEN 'nota_equivalente'
        ELSE 'ne.FK_TNIVEL_ENSENANZA'
    END;
    v_dir := CASE WHEN lower(coalesce(p_sort_dir, '')) = 'desc' THEN 'DESC' ELSE 'ASC' END;

    RETURN QUERY EXECUTE format($q$
        WITH fmt AS (
            SELECT 0::numeric AS mn,
                   CASE UPPER(TRIM(lv.VALOR))
                     WHEN 'CINCO' THEN 5
                     WHEN 'DIEZ'  THEN 10
                     ELSE 100
                   END::numeric AS mx
              FROM academico_test.TCRITERIO_EVALUACION ce
              JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = ce.FK_TLV_FORMATO_CALIFICACION
             WHERE ce.PK_TCRITERIO_EVALUACION = $1
        )
        SELECT ev.PK_TESCALA_VALORACION, v.NOMBRE, v.CODIGO, tv.VALOR, tv.NOMBRE,
               COALESCE(v.GRAFICA_CARITAS, v.GRAFICA_SIMBOLO),
               ne.FK_TNIVEL_ENSENANZA, nen.NOMBRE,
               round(ev.LIMITE_INFERIOR / 100 * (fmt.mx - fmt.mn) + fmt.mn, 2) AS nota_minima,
               round(ev.LIMITE_SUPERIOR / 100 * (fmt.mx - fmt.mn) + fmt.mn, 2) AS nota_maxima,
               round(ev.LIMITE_PROMEDIO / 100 * (fmt.mx - fmt.mn) + fmt.mn, 2) AS nota_equivalente,
               ev.FK_TESCALA
          FROM academico_test.TESCALA_VALORACION ev
          JOIN academico_test.TVALORACION v    ON v.PK_TVALORACION = ev.FK_TVALORACION
          JOIN academico_test.TLISTA_VALOR tv  ON tv.PK_LISTA_VALOR = ev.FK_TVL_TIPO_VALORACION
          JOIN academico_test.TNIVEL_ESCALA ne ON ne.FK_TESCALA = ev.FK_TESCALA
          JOIN academico_test.TNIVEL_ENSENANZA nen ON nen.PK_NIVEL_ENSENANZA = ne.FK_TNIVEL_ENSENANZA
          CROSS JOIN fmt
         WHERE ne.FK_PERIODO_ACADEMICO = $1 AND ev.ACTIVE = TRUE
           AND ($4 IS NULL OR ne.FK_TNIVEL_ENSENANZA = $4)
           AND academico_test.fn_periodo_usuario_puede_ver($3, $1)
           AND ($2 IS NULL OR v.NOMBRE ILIKE '%%' || $2 || '%%' OR v.CODIGO ILIKE '%%' || $2 || '%%')
         ORDER BY %s %s, ev.ORDEN
    $q$, v_col, v_dir)
    USING p_academic_period_id, NULLIF(TRIM(p_filtro),''), p_pk_usuario, p_teaching_level_id;
END;
$function$;
