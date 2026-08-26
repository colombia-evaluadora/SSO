-- Reporte "Areas, asignaturas y especialidades": `fn_area_listar` (todas
-- las areas de un periodo) y `fn_subject_listar` (las asignaturas de UNA
-- area a la vez, `p_fk_area` obligatorio) son dos funciones separadas por el
-- mismo motivo que grado/grupo y plan de estudio -- se editan por separado.
-- El reporte pedido es un solo archivo, area + sus asignaturas, para TODAS
-- las areas del periodo, con filtros opcionales de area/asignatura/
-- especialidad/estado.
--
-- Mapeo de columnas: replica exactamente lo que ya devuelven fn_area_listar
-- ("abreviacion" = TAREA.CODIGO, no TAREA.ABREVIACION) y fn_subject_listar
-- ("abreviacion" = TASIGNATURA.CODIGO, no TASIGNATURA.ABREVIACION) -- son las
-- mismas columnas que ya ve el usuario en pantalla (RN: "la informacion
-- exportada debe coincidir con la informacion visualizada").
--
-- Un area sin asignaturas todavia sigue apareciendo (LEFT JOIN a
-- TASIGNATURA), igual que un grado sin grupos en el reporte de grados.
CREATE OR REPLACE FUNCTION academico_test.fn_area_subject_reporte_listar(
    p_fk_periodo         BIGINT,
    p_fk_area            BIGINT[] DEFAULT NULL,
    p_fk_asignatura      BIGINT[] DEFAULT NULL,
    p_fk_especialidad    BIGINT[] DEFAULT NULL,
    p_incluir_inactivos  BOOLEAN  DEFAULT FALSE,
    p_pk_usuario         BIGINT   DEFAULT NULL,
    p_page_index         INT      DEFAULT 0,
    p_page_size          INT      DEFAULT 10
)
RETURNS TABLE (
    area_id BIGINT, area_general_name VARCHAR, area_nombre_interno VARCHAR, area_abreviacion VARCHAR,
    asignatura_id BIGINT, asignatura VARCHAR, asignatura_abreviacion VARCHAR,
    especialidad_id BIGINT, especialidad_name VARCHAR,
    orden_reportes NUMERIC, color VARCHAR, total_count BIGINT
)
LANGUAGE sql STABLE AS $$
    SELECT a.PK_TAREA, ta.NOMBRE, a.NOMBRE, a.CODIGO,
           s.PK_TASIGNATURA, s.NOMBRE, s.CODIGO,
           en.PK_TENFASIS, en.NOMBRE,
           s.ORDEN_REPORTE, s.COLOR,
           count(*) OVER()::BIGINT
      FROM academico_test.TAREA a
      JOIN academico_test.TAREA_ASIGNATURA ta ON ta.PK_TAREA_ASIGNATURA = a.FK_TAREA_ASIGNATURA
 LEFT JOIN academico_test.TASIGNATURA s        ON s.FK_TAREA = a.PK_TAREA
                                               AND (p_incluir_inactivos OR s.ACTIVE = TRUE)
 LEFT JOIN academico_test.TENFASIS en          ON en.PK_TENFASIS = s.FK_TENFASIS
     WHERE a.FK_TPERIODO_ACADEMICO = p_fk_periodo
       AND (p_incluir_inactivos OR a.ACTIVE = TRUE)
       AND academico_test.fn_periodo_usuario_puede_ver(p_pk_usuario, p_fk_periodo)
       AND (p_fk_area         IS NULL OR CARDINALITY(p_fk_area)         = 0 OR a.PK_TAREA        = ANY(p_fk_area))
       AND (p_fk_asignatura   IS NULL OR CARDINALITY(p_fk_asignatura)   = 0 OR s.PK_TASIGNATURA   = ANY(p_fk_asignatura))
       AND (p_fk_especialidad IS NULL OR CARDINALITY(p_fk_especialidad) = 0 OR en.PK_TENFASIS     = ANY(p_fk_especialidad))
     ORDER BY a.ORDEN_REPORTE, a.NOMBRE, s.ORDEN_REPORTE, s.NOMBRE
     LIMIT NULLIF(p_page_size, 0)
    OFFSET COALESCE(p_page_index, 0) * COALESCE(NULLIF(p_page_size, 0), 0);
$$;
