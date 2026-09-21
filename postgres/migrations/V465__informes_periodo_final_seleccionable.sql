-- ===========================================================================
-- V465 - El periodo "Final" tambien se puede marcar: sale en la lista.
--   fn_informe_periodos_evaluacion_listar   +ES_FINAL, +la fila centinela
--   POST /informes/periodos                 no cambia lo que recibe
--
-- Devuelve una fila mas, "Final", que no existe en la tabla: la que V431
-- calcula al vuelo. Va en el back porque sin periodos no hay nada que
-- acumular. El contrato de la fila, en el COMMENT de la funcion.
--
-- Depende de: V418 (esta funcion), V431 (p_incluir_final y el centinela -1).
-- Idempotente: DROP + CREATE (cambia el RETURNS TABLE) y UPDATE del detail.
-- ===========================================================================

DROP FUNCTION IF EXISTS academico_test.fn_informe_periodos_evaluacion_listar(BIGINT, BIGINT, INTEGER, BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_informe_periodos_evaluacion_listar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tsede               BIGINT,
    p_anio                   INTEGER,
    p_fk_tlv_jornada         BIGINT
)
RETURNS TABLE(
    fk_tperiodo_evaluacion  BIGINT,
    codigo                  VARCHAR,
    nombre                  VARCHAR,
    abreviacion             VARCHAR,
    fecha_inicio            DATE,
    fecha_fin               DATE,
    porcentaje              NUMERIC,
    estado                  VARCHAR,
    calificable             BOOLEAN,
    termino                 BOOLEAN,
    en_curso                BOOLEAN,
    es_final                BOOLEAN,
    fk_tperiodo_academico   BIGINT,
    periodo_academico       VARCHAR,
    fk_tsede                BIGINT,
    sede_nombre             VARCHAR,
    fk_tlv_jornada          BIGINT,
    jornada                 VARCHAR,
    fk_testablecimiento     BIGINT,
    anio                    INTEGER
)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_periodo BIGINT;
BEGIN
    -- El resolvedor ya valida el alcance y levanta P0002 si no existe.
    v_periodo := academico_test.fn_informe_periodo_academico_resolver(
        p_pk_usuario_solicitante, p_fk_tsede, p_anio, p_fk_tlv_jornada);

    RETURN QUERY
    WITH reales AS (
        SELECT pe.PK_TPERIODO_EVALUACION AS o_pk,
               pe.CODIGO                 AS o_codigo,
               pe.NOMBRE                 AS o_nombre,
               pe.ABREVIACION            AS o_abreviacion,
               pe.FECHA_INICIO           AS o_inicio,
               pe.FECHA_FIN              AS o_fin,
               pe.PORCENTAJE             AS o_porcentaje,
               est.NOMBRE                AS o_estado,
               -- El catalogo ESTADOPERIODOEVALUACION usa VALOR '1' para
               -- "Calificable". Se devuelve resuelto para que el front no
               -- tenga que conocer el codigo.
               (est.VALOR = '1')         AS o_calificable,
               (pe.FECHA_FIN < CURRENT_DATE) AS o_termino,
               (CURRENT_DATE BETWEEN pe.FECHA_INICIO AND pe.FECHA_FIN)
                                         AS o_en_curso,
               pa.PK_TPERIODO_ACADEMICO  AS o_pa,
               pa.NOMBRE                 AS o_pa_nombre,
               s.PK_TSEDE                AS o_sede,
               s.NOMBRE                  AS o_sede_nombre,
               pa.FK_TLV_JORNADA         AS o_jornada,
               jor.NOMBRE                AS o_jornada_nombre,
               s.FK_TESTABLECIMIENTO     AS o_establecimiento,
               academico_test.fn_anio_lectivo_numero(al.NOMBRE) AS o_anio
          FROM academico_test.TPERIODO_EVALUACION pe
          JOIN academico_test.TPERIODO_ACADEMICO pa
            ON pa.PK_TPERIODO_ACADEMICO = pe.FK_TPERIODO_ACADEMICO
          JOIN academico_test.TANO_LECTIVO al
            ON al.PK_ANO_LECTIVO = pa.FK_TANO_LECTIVO
          JOIN academico_test.TSEDE s
            ON s.PK_TSEDE = pa.FK_TSEDE
          LEFT JOIN academico_test.TLISTA_VALOR est
                 ON est.PK_LISTA_VALOR = pe.FK_TLV_ESTADO
          LEFT JOIN academico_test.TLISTA_VALOR jor
                 ON jor.PK_LISTA_VALOR = pa.FK_TLV_JORNADA
         WHERE pe.ACTIVE = TRUE
           AND pe.FK_TPERIODO_ACADEMICO = v_periodo
    ),
    -- El LIMIT 1 va aqui y no sobre el UNION, donde recortaria la lista.
    fila_final AS (
        SELECT r.o_pa, r.o_pa_nombre, r.o_sede, r.o_sede_nombre,
               r.o_jornada, r.o_jornada_nombre, r.o_establecimiento, r.o_anio
          FROM reales r
         LIMIT 1
    ),
    todo AS (
        SELECT 0 AS orden,
               r.o_pk, r.o_codigo, r.o_nombre, r.o_abreviacion,
               r.o_inicio, r.o_fin, r.o_porcentaje, r.o_estado,
               r.o_calificable, r.o_termino, r.o_en_curso,
               FALSE AS o_es_final,
               r.o_pa, r.o_pa_nombre, r.o_sede, r.o_sede_nombre,
               r.o_jornada, r.o_jornada_nombre, r.o_establecimiento, r.o_anio
          FROM reales r

        UNION ALL

        SELECT 1 AS orden,
               -- Centinela, no un PK: el mismo que devuelve V431.
               (-1)::BIGINT,
               'FINAL'::VARCHAR, 'Final'::VARCHAR, 'FIN'::VARCHAR,
               NULL::DATE, NULL::DATE, NULL::NUMERIC, NULL::VARCHAR,
               FALSE, FALSE, FALSE,
               TRUE,
               f.o_pa, f.o_pa_nombre, f.o_sede, f.o_sede_nombre,
               f.o_jornada, f.o_jornada_nombre, f.o_establecimiento, f.o_anio
          FROM fila_final f
    )
    SELECT t.o_pk, t.o_codigo, t.o_nombre, t.o_abreviacion,
           t.o_inicio, t.o_fin, t.o_porcentaje, t.o_estado,
           t.o_calificable, t.o_termino, t.o_en_curso, t.o_es_final,
           t.o_pa, t.o_pa_nombre, t.o_sede, t.o_sede_nombre,
           t.o_jornada, t.o_jornada_nombre, t.o_establecimiento, t.o_anio
      FROM todo t
     -- El Final al fondo: es el acumulado, no un periodo del calendario.
     ORDER BY t.orden, t.o_inicio, t.o_nombre;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_periodos_evaluacion_listar(BIGINT, BIGINT, INTEGER, BIGINT)
    IS 'Los periodos de evaluacion del periodo academico que resuelven (sede, año, jornada) -- los checkboxes de la pantalla de informes -- MAS la opcion "Final", que no existe en TPERIODO_EVALUACION y que fn_informe_grupo_listar calcula al vuelo (V431). La fila Final viaja con FK_TPERIODO_EVALUACION = -1, el mismo centinela que devuelve el listado, y con ES_FINAL = TRUE, que es el unico discriminador que el front debe mirar: su destino NO es el arreglo PERIODOS de POST /informes/grupo -- ahi -1 no casaria con ningun PK y la fila no apareceria -- sino BODY.INCLUIR_FINAL. Sale siempre al fondo del orden, y solo si hay al menos un periodo de evaluacion configurado: el Final es el acumulado del año y sin periodos no hay nada que acumular, con lo que ofrecerlo produciria una columna vacia indistinguible de un error de permisos. No se exige que los periodos esten consolidados, porque eso es una regla de guardado y no de visualizacion. Sus fechas, porcentaje y estado van en NULL a proposito: el orden lo pone la funcion, y una fecha inventada solo serviria para que alguien la imprima. Sustituye a fn_periodo_evaluacion_listar_ano (V339), que devolvia los de TODO el año dentro del alcance del usuario. El alcance y la existencia del periodo los valida fn_informe_periodo_academico_resolver, que responde 42501 o P0002 antes de leer. Devuelve TERMINO y EN_CURSO calculados contra CURRENT_DATE: TERMINO es exactamente la condicion que usa la alerta roja (V338) para decidir si una planilla puede considerarse pendiente. V418, V465.';


-- El endpoint no cambia de ruta, metodo ni parametros: solo el detail.
UPDATE public.query q
   SET detail = 'Los periodos de evaluacion del periodo academico que resuelven la sede, el año y la jornada elegidos en los tres selects de la pantalla (POST /informes/sedes, /informes/anos, /informes/jornadas), MAS la opcion "Final". FK_TSEDE y FK_TLV_JORNADA son obligatorios; sin ANIO se toma el año en curso. Responde 42501 si el usuario no alcanza esa sede y jornada, y P0002 si no hay periodo academico para esa combinacion -- un error explicito en vez de una lista vacia que se confunde con "no hay nada configurado". Cada fila trae CALIFICABLE, TERMINO y EN_CURSO ya resueltos; TERMINO es la misma condicion con la que la alerta roja decide si una planilla esta pendiente. *** LA FILA CON ES_FINAL = TRUE NO ES UN PERIODO ***: llega con FK_TPERIODO_EVALUACION = -1 (centinela, no un PK) y va siempre al final de la lista. Marcarla NO se manda en el arreglo PERIODOS de POST /informes/grupo, donde -1 no casaria con nada, sino en BODY.INCLUIR_FINAL; el listado la devuelve como una fila mas con la nota definitiva del año, calculada al vuelo sobre TODOS los periodos (V431). Solo aparece si hay al menos un periodo de evaluacion configurado.'
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/informes/periodos'
   AND q.http_method     = 'POST';
