-- ===========================================================================
-- V474 - informe promedio en formato de calificacion
-- Recortada: las funciones de informes que V535-V541 reescriben en capas
-- se quitaron de aqui y viven alli. Queda lo que sigue vivo y lo que una
-- base limpia necesita al migrar (CREATE solo si la funcion no existe).
-- ===========================================================================


-- Suma el grado (para la escala por nivel): la firma de dos parametros sobra.
DROP FUNCTION IF EXISTS academico_test.fn_promedio_homologar(NUMERIC, BIGINT);
CREATE OR REPLACE FUNCTION academico_test.fn_promedio_homologar(
    p_porcentaje            NUMERIC,
    p_fk_tperiodo_academico BIGINT,
    p_fk_tgrado             BIGINT DEFAULT NULL
)
RETURNS TABLE (
    promedio           NUMERIC,
    formato_valor      VARCHAR,
    es_numerico        BOOLEAN,
    valoracion_nombre  VARCHAR,
    valoracion_simbolo VARCHAR
)
LANGUAGE plpgsql
STABLE
ROWS 1  
AS $function$
DECLARE
    v_fmt    RECORD;
    v_escala BIGINT;
BEGIN
    -- Sin porcentaje no hay nada que homologar. Se devuelve la fila con todo
    -- en NULL y no cero filas, para que un LEFT JOIN LATERAL no pierda al
    -- estudiante sin calificar.
    IF p_porcentaje IS NULL OR p_fk_tperiodo_academico IS NULL THEN
        RETURN QUERY SELECT NULL::NUMERIC, NULL::VARCHAR, NULL::BOOLEAN,
                            NULL::VARCHAR, NULL::VARCHAR;
        RETURN;
    END IF;

    SELECT f.* INTO v_fmt
      FROM academico_test.fn_criterio_evaluacion_formato(p_fk_tperiodo_academico) f;

    -- Sin criterio, o con criterio sin formato: se devuelve el crudo. Es el
    -- comportamiento anterior a V474, y es lo unico honesto -- no hay formato
    -- al que convertir y poner NULL borraria el dato.
    IF v_fmt.formato_valor IS NULL THEN
        RETURN QUERY SELECT p_porcentaje, NULL::VARCHAR, NULL::BOOLEAN,
                            NULL::VARCHAR, NULL::VARCHAR;
        RETURN;
    END IF;

    -- Las bandas: las del criterio del periodo y, si no tiene escala, la del
    -- nivel del grado (el colegio que configura una escala por nivel).
    v_escala := COALESCE(v_fmt.fk_tescala,
                         academico_test.fn_grado_escala_aplicable(p_fk_tgrado));

    RETURN QUERY
    SELECT CASE WHEN v_fmt.es_numerico
                THEN ROUND(p_porcentaje / 100 * v_fmt.nota_maxima, v_fmt.decimales)
           END,
           v_fmt.formato_valor,
           v_fmt.es_numerico,
           b.valoracion_nombre,
           b.valoracion_simbolo
      -- LEFT JOIN LATERAL: un promedio que caiga en un hueco entre bandas
      -- sale igual, con la valoracion en NULL.
      FROM (SELECT 1) _base
      LEFT JOIN LATERAL academico_test.fn_escala_valoracion_banda(v_escala, p_porcentaje) b ON TRUE;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_promedio_homologar(NUMERIC, BIGINT, BIGINT)
    IS 'Convierte un PROMEDIO en porcentaje 0-100 al FORMATO DE CALIFICACION configurado en el criterio de evaluacion GENERAL de un periodo academico, y devuelve ademas la banda de la escala en la que cae. Hermana de fn_nota_homologar (V227/V428) para el grano en el que no hay una asignatura de la que sacar el formato: un promedio agrega varias, y cada una podria resolver por la cadena de V428 a un formato distinto. El criterio general se lee con fn_criterio_evaluacion_formato del PK del periodo academico, porque TCRITERIO_EVALUACION comparte PK con TPERIODO_ACADEMICO (V22). En los formatos numericos (CINCO/DIEZ/CIEN) devuelve el numero redondeado a los decimales configurados; en LITERAL/SIMBOLO/CARITA devuelve promedio NULL y lo que vale es la valoracion, igual que hace fn_nota_homologar con las notas. Sin criterio o sin formato configurado devuelve el porcentaje CRUDO -- no hay formato al que convertir y anularlo borraria el dato. Nunca devuelve cero filas: con porcentaje NULL devuelve la fila en NULL, para que un LEFT JOIN LATERAL no pierda al estudiante sin calificar. Con P_FK_TGRADO, si el criterio del periodo no tiene escala las bandas salen de la del nivel del grado (fn_grado_escala_aplicable); la banda se busca con fn_escala_valoracion_banda. Punto unico de esta conversion; la consumen fn_informe_grupo_listar_interno (promedios) y el boletin de notas (areas).';

DO $$
DECLARE
    v_fn regprocedure := to_regprocedure('academico_test.fn_informe_grupo_listar(bigint,bigint,bigint[],varchar)');
BEGIN
    IF v_fn IS NOT NULL AND pg_get_function_result(v_fn) NOT LIKE '%promedio_formato%' THEN
        DROP FUNCTION academico_test.fn_informe_grupo_listar(BIGINT, BIGINT, BIGINT[], VARCHAR);
    END IF;
END $$;

