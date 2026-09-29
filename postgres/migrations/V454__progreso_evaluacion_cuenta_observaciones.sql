-- ===========================================================================
-- V454 - fn_planilla_columnas_listar cuenta como calificado al estudiante con
-- nota o con OBSERVACION (CALIFICABLE = N), la regla de V243.
-- fn_actividad_listar vive hoy en V481. Depende de: V441, V243.
-- ===========================================================================


SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_planilla_columnas_listar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tgrupo              BIGINT,
    p_fk_tasignatura         BIGINT,
    p_fk_tgrado              BIGINT  DEFAULT NULL,
    p_fecha_desde            DATE    DEFAULT NULL,
    p_fecha_hasta            DATE    DEFAULT NULL,
    p_search_actividad       VARCHAR DEFAULT NULL
)
RETURNS TABLE (
    orden_columna                  INTEGER,
    pk_tactividad                  BIGINT,
    titulo                         VARCHAR,
    fk_tunidad                     BIGINT,
    unidad                         VARCHAR,
    fk_tlv_instrumento_evaluacion  BIGINT,
    instrumento                    VARCHAR,
    instrumento_nombre             VARCHAR,
    metodo_valoracion              VARCHAR,
    ponderacion                    NUMERIC,
    nota_maxima                    NUMERIC,
    es_evaluativa                  VARCHAR,
    es_formativa                   BOOLEAN,
    fecha_inicio                   DATE,
    fecha_cierre                   DATE,
    estudiantes_asignados          BIGINT,
    estudiantes_calificados        BIGINT
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', p_fk_tgrupo
    );
    PERFORM academico_test.fn_planilla_grupo_asignatura_assert(
        p_fk_tgrupo, p_fk_tasignatura, p_fk_tgrado
    );

    RETURN QUERY
    SELECT uni.orden_columna,
           a.PK_TACTIVIDAD,
           a.TITULO,
           a.FK_TUNIDAD,
           u.NOMBRE,
           a.FK_TLV_INSTRUMENTO_EVALUACION,
           lvi.VALOR::VARCHAR,
           lvi.NOMBRE::VARCHAR,
           CASE WHEN lvi.VALOR = 'OTRO'
                THEN academico_test.fn_actividad_otro_metodo_valoracion(a.PK_TACTIVIDAD)
           END::VARCHAR,
           a.PONDERACION,
           a.NOTA_MAXIMA,
           a.ES_EVALUATIVA::VARCHAR,
           academico_test.fn_actividad_es_formativa(a.PK_TACTIVIDAD),
           a.FECHA_INICIO,
           a.FECHA_CIERRE,
           prog.asignados,
           prog.calificados
      FROM academico_test.fn_planilla_actividades_universo(
               p_fk_tgrupo, p_fk_tasignatura, p_fecha_desde, p_fecha_hasta, p_search_actividad
           ) uni
      JOIN academico_test.TACTIVIDAD a ON a.PK_TACTIVIDAD = uni.pk_tactividad
      LEFT JOIN academico_test.TUNIDAD u        ON u.PK_TUNIDAD = a.FK_TUNIDAD
      LEFT JOIN academico_test.TLISTA_VALOR lvi ON lvi.PK_LISTA_VALOR = a.FK_TLV_INSTRUMENTO_EVALUACION
      LEFT JOIN LATERAL (
          SELECT COUNT(*)::BIGINT AS asignados,
                 COUNT(*) FILTER (
                     WHERE n.PK_TACTIVIDAD_NOTA IS NOT NULL
                       AND ( COALESCE(n.DEFINITIVA, n.CALIFICACION) IS NOT NULL
                        OR (n.CALIFICABLE = 'N' AND NULLIF(TRIM(n.OBSERVACION), '') IS NOT NULL) )
                 )::BIGINT AS calificados
            FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
            JOIN academico_test.TMATRICULA m ON m.PK_TMATRICULA = ae.FK_TMATRICULA
            LEFT JOIN academico_test.TACTIVIDAD_NOTA n
                   ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                  AND n.ACTIVE = TRUE
           WHERE ae.FK_TACTIVIDAD = a.PK_TACTIVIDAD
             AND ae.ACTIVE = TRUE
             AND m.FK_TGRUPO = p_fk_tgrupo
      ) prog ON TRUE
     ORDER BY uni.orden_columna;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_planilla_columnas_listar(BIGINT, BIGINT, BIGINT, BIGINT, DATE, DATE, VARCHAR)
    IS 'estudiantes_calificados cuenta tambien al estudiante con OBSERVACION y CALIFICABLE = N (formativa/preescolar), misma regla que el listado y que fn_actividad_finalizacion_refrescar. Trae ademas es_formativa y metodo_valoracion (V441). HEADER de la pantalla "Planilla de calificacion": una fila por actividad-columna del (grupo, asignatura), en el MISMO orden_columna que devuelven las celdas de fn_planilla_calificaciones_listar (ambas salen de fn_planilla_actividades_universo, por eso no pueden desalinearse). Trae la unidad resuelta -- con eso el cliente arma el sub-header del toggle "Ver por: Unidad" con un group-by, sin otra consulta ni otro contrato: las actividades de una misma unidad vienen contiguas --, el instrumento (VALOR canonico + NOMBRE, para saber que popover de calificacion abrir y llamar despues a fn_actividad_instrumento_obtener de V226), PONDERACION/NOTA_MAXIMA, ES_EVALUATIVA, fechas y el progreso de calificacion acotado a ESE grupo (asignados / calificados; la actividad puede tener estudiantes de otros grupos). Filtros: ventana de fechas y buscador de actividad. Sin paginacion (son las columnas visibles de una tabla). Gate VER sobre PLANEADOR + fn_planilla_grupo_asignatura_assert. V239.';
