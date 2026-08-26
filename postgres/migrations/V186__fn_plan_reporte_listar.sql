-- Reporte "Plan de estudio" (RN de exportacion): la pantalla de edicion
-- (`fn_plan_listar`, V44) esta scopeada a UN grado a la vez (`p_fk_grado`
-- obligatorio) porque es donde se EDITA el plan de un grado puntual. El
-- reporte pedido es distinto: exportar el plan de estudio de TODO un periodo
-- academico (todos los grados), con filtros opcionales por grado, asignatura
-- y especialidad -- no existia una funcion que cruzara grados.
--
-- Tambien expone dos columnas que `fn_plan_listar` nunca devolvio porque no
-- las necesitaba la pantalla de edicion (ya esta en el contexto de un grado
-- y una asignatura elegida de un selector): abreviacion (TASIGNATURA.
-- ABREVIACION) y especialidad asociada (TASIGNATURA.FK_TENFASIS -> TENFASIS,
-- NULL si la asignatura no tiene enfasis -- "si aplica").
--
-- Sin paginar: mismo patron que fn_periodo_listar/fn_grado_listar
-- (LIMIT NULLIF($n, 0)), para que el reporte reuse esta misma funcion con
-- page_size=NULL, igual que V124 hizo con periodo academico/evaluacion.
CREATE OR REPLACE FUNCTION academico_test.fn_plan_reporte_listar(
    p_fk_periodo      BIGINT,
    p_fk_grado        BIGINT[] DEFAULT NULL,
    p_fk_asignatura   BIGINT[] DEFAULT NULL,
    p_fk_especialidad BIGINT[] DEFAULT NULL,
    p_pk_usuario      BIGINT   DEFAULT NULL,
    p_page_index      INT      DEFAULT 0,
    p_page_size       INT      DEFAULT 10
)
RETURNS TABLE (
    id BIGINT, grado_id BIGINT, grado_name VARCHAR,
    asignatura_id BIGINT, asignatura VARCHAR, abreviacion VARCHAR,
    especialidad_id BIGINT, especialidad_name VARCHAR,
    intensidad_horaria NUMERIC, influencia_area NUMERIC,
    matricula_obligatoria BOOLEAN, aprobacion_obligatoria BOOLEAN,
    influye_desempeno BOOLEAN, total_count BIGINT
)
LANGUAGE sql STABLE AS $$
    SELECT ap.PK_TASIGNATURA_PLAN, g.PK_TGRADO, g.NOMBRE,
           s.PK_TASIGNATURA, s.NOMBRE, s.ABREVIACION,
           en.PK_TENFASIS, en.NOMBRE,
           ap.NUMERO_HORA, ap.INFLUENCIA_AREA,
           (ap.MATRICULA_OBLIGATORIA = 'S'), (ap.APROBACION_OBLIGATORIA = 'S'),
           (ap.INFLUYE_DESEMPLENO_ACADEMICO = 'S'),
           count(*) OVER()::BIGINT
      FROM academico_test.TASIGNATURA_PLAN ap
      JOIN academico_test.TPLAN p        ON p.PK_TPLAN = ap.FK_TPLAN AND p.ACTIVE = TRUE
      JOIN academico_test.TGRADO g       ON g.PK_TGRADO = p.FK_TGRADO
      JOIN academico_test.TASIGNATURA s  ON s.PK_TASIGNATURA = ap.FK_TASIGNATURA
 LEFT JOIN academico_test.TENFASIS en    ON en.PK_TENFASIS = s.FK_TENFASIS
     WHERE ap.ACTIVE = TRUE
       AND g.FK_TPERIODO_ACADEMICO = p_fk_periodo
       AND academico_test.fn_periodo_usuario_puede_ver(p_pk_usuario, p_fk_periodo)
       AND (p_fk_grado        IS NULL OR CARDINALITY(p_fk_grado)        = 0 OR g.PK_TGRADO      = ANY(p_fk_grado))
       AND (p_fk_asignatura   IS NULL OR CARDINALITY(p_fk_asignatura)   = 0 OR s.PK_TASIGNATURA  = ANY(p_fk_asignatura))
       AND (p_fk_especialidad IS NULL OR CARDINALITY(p_fk_especialidad) = 0 OR en.PK_TENFASIS    = ANY(p_fk_especialidad))
     ORDER BY g.NOMBRE, s.NOMBRE
     LIMIT NULLIF(p_page_size, 0)
    OFFSET COALESCE(p_page_index, 0) * COALESCE(NULLIF(p_page_size, 0), 0);
$$;