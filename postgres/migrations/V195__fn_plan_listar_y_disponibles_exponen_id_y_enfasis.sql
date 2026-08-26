-- Plan de estudio: el selector de "asignatura" (dialog-create-study-plan.tsx)
-- trabajaba por NOMBRE de punta a punta en el front (ver
-- resolve-plan-asignatura-id.ts, ahora eliminado), aunque
-- fn_plan_agregar/fn_plan_actualizar siempre pidieron el id
-- (`p_fk_asignatura BIGINT`). Con nombres de asignatura repetidos ahora
-- validos entre distinto enfasis (V143), el `.find(row => row.nombre ===
-- nombre)` de esa resolucion por nombre podia matchear la asignatura
-- equivocada, y el combobox de "disponibles" no podia distinguir ni
-- seleccionar la segunda opcion con nombre repetido.
--
-- Dos cambios, sin tocar logica de negocio ni filtros:
--   1. fn_plan_asignaturas_disponibles_listar: agrega `enfasis_nombre` para
--      que el front arme una etiqueta "Nombre (Enfasis)" cuando haga falta
--      distinguir.
--   2. fn_plan_listar: agrega `asignatura_id` (ya lo tenia fn_plan_obtener,
--      pero el listado de la tabla no) y `enfasis_nombre`, para que el front
--      pueda editar un renglon sin tener que resolver el id por nombre.
--
-- Ambos cambian el shape de retorno -> requieren DROP FUNCTION explicito.

DROP FUNCTION IF EXISTS academico_test.fn_plan_asignaturas_disponibles_listar(BIGINT, TEXT, BIGINT);
CREATE OR REPLACE FUNCTION academico_test.fn_plan_asignaturas_disponibles_listar(
    p_fk_grado BIGINT, p_filtro TEXT DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS TABLE (id BIGINT, nombre VARCHAR, area_id BIGINT, area_nombre VARCHAR, enfasis_nombre VARCHAR)
LANGUAGE sql STABLE AS $$
    SELECT s.PK_TASIGNATURA, s.NOMBRE, a.PK_TAREA, a.NOMBRE, e.NOMBRE
      FROM academico_test.TGRADO g
      JOIN academico_test.TAREA a       ON a.FK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO AND a.ACTIVE = TRUE
      JOIN academico_test.TASIGNATURA s ON s.FK_TAREA = a.PK_TAREA AND s.ACTIVE = TRUE
      LEFT JOIN academico_test.TENFASIS e ON e.PK_TENFASIS = s.FK_TENFASIS AND e.ACTIVE = TRUE
     WHERE g.PK_TGRADO = p_fk_grado
       AND (NULLIF(TRIM(p_filtro),'') IS NULL OR s.NOMBRE ILIKE '%' || p_filtro || '%')
       AND NOT EXISTS (
             SELECT 1 FROM academico_test.TASIGNATURA_PLAN ap
               JOIN academico_test.TPLAN p ON p.PK_TPLAN = ap.FK_TPLAN
              WHERE p.FK_TGRADO = p_fk_grado AND ap.FK_TASIGNATURA = s.PK_TASIGNATURA AND ap.ACTIVE = TRUE)
     ORDER BY a.NOMBRE, s.NOMBRE;
$$;

DROP FUNCTION IF EXISTS academico_test.fn_plan_listar(BIGINT, TEXT, INT, INT, BIGINT, TEXT, TEXT);
CREATE OR REPLACE FUNCTION academico_test.fn_plan_listar(
    p_fk_grado BIGINT, p_filtro TEXT DEFAULT NULL,
    p_page_index INT DEFAULT 0, p_page_size INT DEFAULT 10,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL,
    -- Orden: id de columna del front + direccion ('asc'/'desc'), igual que fn_periodo_listar (V37).
    p_sort_by TEXT DEFAULT NULL,
    p_sort_dir TEXT DEFAULT NULL
)
RETURNS TABLE (codigo BIGINT, asignatura_id BIGINT, asignatura VARCHAR, enfasis_nombre VARCHAR,
               intensidad_horaria NUMERIC, influencia_area NUMERIC,
               numero_creditos BIGINT, influye_desempeno BOOLEAN, matricula_obligatoria BOOLEAN,
               aprobacion_obligatoria BOOLEAN, formato_calificacion BIGINT, criterio_nota BIGINT,
               personalizado BOOLEAN, total_count BIGINT)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_col TEXT;
    v_dir TEXT;
BEGIN
    v_col := CASE lower(coalesce(p_sort_by, ''))
        WHEN 'asignatura'        THEN 's.NOMBRE'
        WHEN 'intensidadhoraria' THEN 'ap.NUMERO_HORA'
        WHEN 'influenciaarea'    THEN 'ap.INFLUENCIA_AREA'
        WHEN 'numerocreditos'    THEN 'ap.NUMERO_CREDITO'
        ELSE 's.NOMBRE'
    END;
    v_dir := CASE WHEN lower(coalesce(p_sort_dir, '')) = 'desc' THEN 'DESC' ELSE 'ASC' END;

    RETURN QUERY EXECUTE format($q$
        SELECT ap.PK_TASIGNATURA_PLAN, s.PK_TASIGNATURA, s.NOMBRE, e.NOMBRE,
               ap.NUMERO_HORA, ap.INFLUENCIA_AREA, ap.NUMERO_CREDITO,
               (ap.INFLUYE_DESEMPLENO_ACADEMICO = 'S'), (ap.MATRICULA_OBLIGATORIA = 'S'),
               (ap.APROBACION_OBLIGATORIA = 'S'),
               COALESCE(ap.FK_TLV_FORMATO_CALIFICACION_DEF, ce.FK_TLV_FORMATO_CALIFICACION),
               COALESCE(ap.FK_TLV_CALCULO_DEFINITIVA,      ce.FK_TLV_MODIF_FINAL_PERACA),
               (ap.FK_TLV_FORMATO_CALIFICACION_DEF IS NOT NULL OR ap.FK_TLV_CALCULO_DEFINITIVA IS NOT NULL),
               count(*) OVER()::BIGINT
          FROM academico_test.TASIGNATURA_PLAN ap
          JOIN academico_test.TPLAN p        ON p.PK_TPLAN = ap.FK_TPLAN
          JOIN academico_test.TASIGNATURA s  ON s.PK_TASIGNATURA = ap.FK_TASIGNATURA
          LEFT JOIN academico_test.TENFASIS e ON e.PK_TENFASIS = s.FK_TENFASIS AND e.ACTIVE = TRUE
          LEFT JOIN academico_test.TCRITERIO_EVALUACION_ASIGNATURA_PLAN cap
                 ON cap.FK_TASIGNATURA_PLAN = ap.PK_TASIGNATURA_PLAN AND cap.ACTIVE = TRUE
          LEFT JOIN academico_test.TCRITERIO_EVALUACION ce
                 ON ce.PK_TCRITERIO_EVALUACION = cap.FK_TCRITERIO_EVALUACION AND ce.ACTIVE = TRUE
         WHERE p.FK_TGRADO = $1 AND ap.ACTIVE = TRUE
           AND ($2 IS NULL OR s.NOMBRE ILIKE '%%' || $2 || '%%')
         ORDER BY %s %s, ap.PK_TASIGNATURA_PLAN
         LIMIT NULLIF($4, 0)
        OFFSET COALESCE($3, 0) * COALESCE(NULLIF($4, 0), 0)
    $q$, v_col, v_dir)
    USING p_fk_grado, NULLIF(TRIM(p_filtro),''), p_page_index, p_page_size;
END;
$$;
