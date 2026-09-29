-- ===========================================================================
-- V474 - fn_promedio_homologar: el promedio del informe en el formato de
-- calificacion del periodo, y las cinco columnas promedio_* que agrega
-- fn_informe_grupo_listar. La vigente del listado es la de V490 (CREATE OR
-- REPLACE sin DROP), asi que aqui queda el DROP de la firma de V439.
-- ===========================================================================


CREATE OR REPLACE FUNCTION academico_test.fn_promedio_homologar(
    p_porcentaje            NUMERIC,
    p_fk_tperiodo_academico BIGINT
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
ROWS 1  -- el de V493: re-aplicar este fichero no lo devuelve a 1000
AS $function$
DECLARE
    v_fmt RECORD;
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

    RETURN QUERY
    SELECT CASE WHEN v_fmt.es_numerico
                THEN ROUND(p_porcentaje / 100 * v_fmt.nota_maxima, v_fmt.decimales)
           END,
           v_fmt.formato_valor,
           v_fmt.es_numerico,
           val.NOMBRE,
           val.GRAFICA_SIMBOLO
      -- LEFT JOIN LATERAL: las escalas reales tienen huecos entre bandas y un
      -- promedio que caiga en uno sale igual, con la valoracion en NULL.
      FROM (SELECT 1) _base
      LEFT JOIN LATERAL (
            SELECT sv.FK_TVALORACION
              FROM academico_test.TESCALA_VALORACION sv
             WHERE sv.FK_TESCALA = v_fmt.fk_tescala
               AND sv.ACTIVE = TRUE
               AND p_porcentaje BETWEEN sv.LIMITE_INFERIOR AND sv.LIMITE_SUPERIOR
             ORDER BY sv.ORDEN
             LIMIT 1
      ) ev ON TRUE
      LEFT JOIN academico_test.TVALORACION val
             ON val.PK_TVALORACION = ev.FK_TVALORACION;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_promedio_homologar(NUMERIC, BIGINT)
    IS 'Convierte un PROMEDIO en porcentaje 0-100 al FORMATO DE CALIFICACION configurado en el criterio de evaluacion GENERAL de un periodo academico, y devuelve ademas la banda de la escala en la que cae. Hermana de fn_nota_homologar (V227/V428) para el grano en el que no hay una asignatura de la que sacar el formato: un promedio agrega varias, y cada una podria resolver por la cadena de V428 a un formato distinto. El criterio general se lee con fn_criterio_evaluacion_formato del PK del periodo academico, porque TCRITERIO_EVALUACION comparte PK con TPERIODO_ACADEMICO (V22). En los formatos numericos (CINCO/DIEZ/CIEN) devuelve el numero redondeado a los decimales configurados; en LITERAL/SIMBOLO/CARITA devuelve promedio NULL y lo que vale es la valoracion, igual que hace fn_nota_homologar con las notas. Sin criterio o sin formato configurado devuelve el porcentaje CRUDO -- no hay formato al que convertir y anularlo borraria el dato. Nunca devuelve cero filas: con porcentaje NULL devuelve la fila en NULL, para que un LEFT JOIN LATERAL no pierda al estudiante sin calificar. Punto unico de esta conversion; la consume fn_informe_grupo_listar. V474.';

DROP FUNCTION IF EXISTS academico_test.fn_informe_grupo_listar(BIGINT, BIGINT, BIGINT[], VARCHAR, BOOLEAN);

-- Solo si aun tiene el retorno de V439: re-aplicar no tumba la de V490.
DO $$
DECLARE
    v_fn regprocedure := to_regprocedure('academico_test.fn_informe_grupo_listar(bigint,bigint,bigint[],varchar)');
BEGIN
    IF v_fn IS NOT NULL AND pg_get_function_result(v_fn) NOT LIKE '%promedio_formato%' THEN
        DROP FUNCTION academico_test.fn_informe_grupo_listar(BIGINT, BIGINT, BIGINT[], VARCHAR);
    END IF;
END $$;

UPDATE public.query q
   SET detail = 'Listado principal de informes: una fila por (estudiante, periodo) del grupo, con promedio, puesto, aprobadas/reprobadas, la cuenta de EVIDENCIAS y las asignaturas embebidas en JSONB. FORMATO dice si la fila se lee como numerica o cualitativa (preescolar); en el caso cualitativo lo que vale es OBSERVACION. EL FINAL SE PIDE METIENDO -1 EN PERIODOS (V439; antes era el bind INCLUIR_FINAL, que ya no existe): PERIODOS nulo o vacio = todos los periodos reales sin Final, [622,-1] = ese periodo y el Final, [-1] = SOLO el Final. Esa ultima combinacion es la que motiva el cambio: con la bandera era imposible, porque un arreglo vacio significa TODOS. La fila Final llega con FK_TPERIODO_EVALUACION = -1 -- un centinela, no un PK --, MODO_PERIODO "final", CONSOLIDADO false y cada asignatura con ESTADO "final"; se calcula al vuelo sobre todos los periodos del año y un periodo sin nota guardada vale cero. Sin paginacion: paginar romperia el puesto. SEARCH filtra por nombre y documento DESPUES de calcular el puesto. V474: PROMEDIO_GUARDADO y PROMEDIO_PROYECTADO llegan en el FORMATO DE CALIFICACION del criterio de evaluacion general del periodo academico (3,3 sobre cinco), no en el porcentaje guardado. Si ese formato no es numerico llegan NULL y lo que se pinta son PROMEDIO_VALORACION / PROMEDIO_SIMBOLO y PROMEDIO_PROYECTADO_VALORACION / PROMEDIO_PROYECTADO_SIMBOLO; sin criterio configurado se recibe el porcentaje crudo. PROMEDIO_FORMATO (CINCO/DIEZ/CIEN/LITERAL/SIMBOLO/CARITA) dice con cual se homologo. El PUESTO se sigue calculando sobre el porcentaje.'
  FROM public.microservice m
 WHERE q.microservice_id = m.id_microservice
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/informes/grupo'
   AND q.http_method     = 'POST';
