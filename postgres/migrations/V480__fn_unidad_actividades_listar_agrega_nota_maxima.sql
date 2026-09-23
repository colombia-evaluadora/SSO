-- ===========================================================================
-- V480 — fn_unidad_actividades_listar agrega NOTA_MAXIMA.
--
-- CONTEXTO: la pestana "Actividades" de una unidad (GET .../unidades/:id/
-- actividades) solo devolvia PONDERACION (%, TACTIVIDAD.PONDERACION), pero
-- en modo Sumatoria el docente NO captura un %, captura un PUNTAJE
-- (TACTIVIDAD.NOTA_MAXIMA, V22) y el % lo autocalcula el sistema
-- (fn_unidad_ponderacion_recalcular_sumatoria, V223) -- ver el comentario
-- extenso de V223, punto 7. Sin NOTA_MAXIMA en esta fila, el front no tiene
-- forma de mostrar (ni de precargar para editar) el puntaje real de cada
-- actividad cuando la unidad calcula por Sumatoria: la columna quedaba
-- forzada a mostrar siempre PONDERACION, que en ese modo es un DERIVADO, no
-- lo que el docente edita a mano.
--
-- FIX: se agrega NOTA_MAXIMA al RETURNS TABLE de fn_unidad_actividades_listar
-- (TACTIVIDAD.NOTA_MAXIMA, columna ya existente desde V22, sin migracion de
-- datos). Cambiar el RETURNS TABLE de una funcion existente no lo permite
-- CREATE OR REPLACE -- se necesita DROP FUNCTION IF EXISTS primero, mismo
-- patron ya usado en este archivo para fn_unidad_buscar_por_pk (V216).
--
-- Depende de: V216 (fn_unidad_actividades_listar), V223 (TACTIVIDAD.
-- PONDERACION / modo Sumatoria).
-- ===========================================================================

SET search_path TO academico_test, public;

DROP FUNCTION IF EXISTS academico_test.fn_unidad_actividades_listar(BIGINT, BIGINT, VARCHAR, BIGINT, BOOLEAN, VARCHAR, BOOLEAN, INT, INT);

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_actividades_listar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tunidad               BIGINT,
    p_search                   VARCHAR   DEFAULT NULL,
    p_fk_tgrupo                BIGINT    DEFAULT NULL,
    p_incluir_inactivas        BOOLEAN   DEFAULT FALSE,
    p_orden_por                VARCHAR   DEFAULT 'actividad',
    p_orden_asc                BOOLEAN   DEFAULT TRUE,
    p_limite                   INT       DEFAULT 50,
    p_offset                   INT       DEFAULT 0
)
RETURNS TABLE (
    pk_tactividad                   BIGINT,
    titulo                          VARCHAR,
    fk_tasignatura                  BIGINT,
    asignatura                      VARCHAR,
    fk_tlv_tipo_actividad           BIGINT,
    tipo_actividad                  VARCHAR,
    fk_tlv_instrumento_evaluacion   BIGINT,
    instrumento_evaluacion          VARCHAR,
    fk_tgrupo                       BIGINT,
    grupo                           VARCHAR,
    fk_tlv_jerarquia                BIGINT,
    jerarquia                       VARCHAR,
    ponderacion                     NUMERIC,
    -- V480: puntaje que el docente captura en unidades "Sumatoria de
    -- Actividades" (TACTIVIDAD.NOTA_MAXIMA, V22) -- de donde
    -- fn_unidad_ponderacion_recalcular_sumatoria deriva PONDERACION.
    nota_maxima                     NUMERIC,
    influencia                      NUMERIC,
    es_evaluativa                   VARCHAR,
    fecha_inicio                    DATE,
    fecha_cierre                    DATE,
    active                          BOOLEAN,
    total_count                     BIGINT
)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', NULL, NULL, p_pk_tunidad
    );

    IF NOT EXISTS (SELECT 1 FROM academico_test.TUNIDAD WHERE PK_TUNIDAD = p_pk_tunidad) THEN
        RAISE EXCEPTION 'No se encontro la unidad tematica solicitada' USING ERRCODE = 'P0002';
    END IF;

    RETURN QUERY
    SELECT a.PK_TACTIVIDAD,
           a.TITULO,
           a.FK_TASIGNATURA,
           asig.NOMBRE,
           a.FK_TLV_TIPO_ACTIVIDAD,
           lvt.NOMBRE,
           a.FK_TLV_INSTRUMENTO_EVALUACION,
           lvi.NOMBRE,
           a.FK_TGRUPO,
           g.NOMBRE,
           a.FK_TLV_JERARQUIA,
           lvj.NOMBRE,
           a.PONDERACION,
           a.NOTA_MAXIMA,
           a.INFLUENCIA,
           a.ES_EVALUATIVA::VARCHAR,
           a.FECHA_INICIO,
           a.FECHA_CIERRE,
           a.ACTIVE,
           COUNT(*) OVER()
      FROM academico_test.TACTIVIDAD a
      LEFT JOIN academico_test.TASIGNATURA asig ON asig.PK_TASIGNATURA = a.FK_TASIGNATURA
      LEFT JOIN academico_test.TLISTA_VALOR lvt ON lvt.PK_LISTA_VALOR = a.FK_TLV_TIPO_ACTIVIDAD
      LEFT JOIN academico_test.TLISTA_VALOR lvi ON lvi.PK_LISTA_VALOR = a.FK_TLV_INSTRUMENTO_EVALUACION
      LEFT JOIN academico_test.TLISTA_VALOR lvj ON lvj.PK_LISTA_VALOR = a.FK_TLV_JERARQUIA
      LEFT JOIN academico_test.TGRUPO g         ON g.PK_TGRUPO = a.FK_TGRUPO
     WHERE a.FK_TUNIDAD = p_pk_tunidad
       AND (p_incluir_inactivas OR a.ACTIVE = TRUE)
       AND (p_search IS NULL OR a.TITULO ILIKE '%' || p_search || '%')
       AND (p_fk_tgrupo IS NULL OR a.FK_TGRUPO = p_fk_tgrupo)
     ORDER BY
       CASE WHEN p_orden_asc THEN
           CASE LOWER(TRIM(COALESCE(p_orden_por, 'actividad')))
               WHEN 'actividad'   THEN a.TITULO
               WHEN 'tipo'         THEN lvt.NOMBRE
               WHEN 'instrumento'  THEN lvi.NOMBRE
               WHEN 'grupo'        THEN g.NOMBRE
               ELSE a.TITULO
           END
       END ASC,
       CASE WHEN p_orden_asc AND LOWER(TRIM(COALESCE(p_orden_por, 'actividad'))) = 'porcentaje'
            THEN a.PONDERACION END ASC,
       CASE WHEN NOT p_orden_asc THEN
           CASE LOWER(TRIM(COALESCE(p_orden_por, 'actividad')))
               WHEN 'actividad'   THEN a.TITULO
               WHEN 'tipo'         THEN lvt.NOMBRE
               WHEN 'instrumento'  THEN lvi.NOMBRE
               WHEN 'grupo'        THEN g.NOMBRE
               ELSE a.TITULO
           END
       END DESC,
       CASE WHEN NOT p_orden_asc AND LOWER(TRIM(COALESCE(p_orden_por, 'actividad'))) = 'porcentaje'
            THEN a.PONDERACION END DESC
     LIMIT GREATEST(p_limite, 1)
    OFFSET GREATEST(p_offset, 0);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_actividades_listar(BIGINT, BIGINT, VARCHAR, BIGINT, BOOLEAN, VARCHAR, BOOLEAN, INT, INT)
    IS 'Lista las actividades (TACTIVIDAD) vinculadas a una unidad (FK_TUNIDAD, opcional desde V218) y su peso dentro de ella -- pestaña "Actividades" del detalle de unidad. La columna "(%)" de la pantalla es PONDERACION (TACTIVIDAD.PONDERACION, V223: lo que edita el docente con fn_unidad_actividad_ponderacion_set y lo que valida la regla del 100% por unidad+grupo) -- SOLO en modo "Ponderar" (TUNIDAD.FK_TLV_CALCULO_DEFINITIVA); en modo "Sumatoria de Actividades" es un DERIVADO que calcula fn_unidad_ponderacion_recalcular_sumatoria (V223) a partir de NOTA_MAXIMA, y es NOTA_MAXIMA (V480, TACTIVIDAD.NOTA_MAXIMA, V22) lo que el docente edita a mano en ese modo -- por eso se agrega a este listado, antes solo la traia fn_actividad_listar/fn_actividad_buscar_por_pk. INFLUENCIA (V22, peso para el promedio ponderado de TUNIDAD_NOTA) se sigue devolviendo por compatibilidad pero NO es ninguna de las dos columnas anteriores. El criterio de orden ''porcentaje'' ordena por PONDERACION. Devuelve tambien titulo, asignatura (TACTIVIDAD.FK_TASIGNATURA, propia de la actividad desde V218), tipo de actividad, instrumento de evaluacion, grupo y jerarquia resueltos, fechas y ES_EVALUATIVA. Filtros: search sobre TITULO, grupo, incluir_inactivas. Orden: actividad|tipo|instrumento|grupo|porcentaje. total_count via COUNT(*) OVER(). Gate VER sobre PLANEADOR. V216, editada en V480.';
