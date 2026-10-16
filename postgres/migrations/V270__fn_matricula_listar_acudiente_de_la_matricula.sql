-- =============================================================================
-- V270 -- fn_matricula_listar y fn_matricula_acudiente
--
-- Que hace:
--   * El acudiente sale de TMATRICULA.FK_TPADRE; TNUCLEO_FAMILIAR solo es
--     respaldo cuando viene NULL (fn_matricula_acudiente).
--   * Nombres completos (primer + segundo); la busqueda libre los cubre.
--   * Alcance una vez por periodo; pagina sobre ids y une textos, acudiente
--     y has_grades solo para la pagina.
--   * Establecimiento (nivel 2): solo Cursando de periodos activos, sin historico.
-- Depende de: V22, V29 (nivel de rol), V37 (fn_periodo_usuario_periodos).
-- =============================================================================

-- Acudiente de una matricula: el que senala TMATRICULA.FK_TPADRE, y de esa
-- misma fila sale el parentesco. Si viene NULL se cae al vinculo familiar
-- marcado como acudiente (o al mas antiguo). Siempre una fila.
CREATE OR REPLACE FUNCTION academico_test.fn_matricula_acudiente(
    p_fk_testudiante BIGINT, p_fk_tpadre BIGINT
)
RETURNS TABLE(nombre TEXT, guardian_name TEXT)
LANGUAGE sql
STABLE
ROWS 1
AS $function$
    SELECT concat_ws(' ', pu.PRIMER_NOMBRE, pu.SEGUNDO_NOMBRE,
                          pu.PRIMER_APELLIDO, pu.SEGUNDO_APELLIDO),
           NULLIF(TRIM(concat_ws(' ', pu.PRIMER_NOMBRE, pu.SEGUNDO_NOMBRE,
                                      pu.PRIMER_APELLIDO, pu.SEGUNDO_APELLIDO)), '')
               || COALESCE(' (' || (SELECT par.NOMBRE FROM academico_test.TLISTA_VALOR par
                                     WHERE par.PK_LISTA_VALOR = nf.FK_TLV_PARENTESCO) || ')', '')
      FROM (SELECT 1) x
      LEFT JOIN LATERAL (
             SELECT nf0.FK_TPADRE, nf0.FK_TLV_PARENTESCO
               FROM academico_test.TNUCLEO_FAMILIAR nf0
              WHERE nf0.FK_TESTUDIANTE = p_fk_testudiante
                AND nf0.ACTIVE = TRUE
                AND (p_fk_tpadre IS NULL OR nf0.FK_TPADRE = p_fk_tpadre)
              ORDER BY (p_fk_tpadre IS NULL AND nf0.ACUDIENTE = 'S') DESC NULLS LAST,
                       nf0.PK_TNUCLEO_FAMILIAR
              LIMIT 1
      ) nf ON TRUE
      LEFT JOIN academico_test.TPADRE p         ON p.PK_TPADRE = COALESCE(p_fk_tpadre, nf.FK_TPADRE)
      LEFT JOIN academico_test.TUSUARIO pu      ON pu.PK_TUSUARIO = p.FK_TUSUARIO;
$function$;

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_listar(
    p_search text DEFAULT NULL::text,
    p_statuses text[] DEFAULT NULL::text[],
    p_campus text DEFAULT NULL::text,
    p_shift text DEFAULT NULL::text,
    p_grade integer DEFAULT NULL::integer,
    p_group text DEFAULT NULL::text,
    p_page_index integer DEFAULT 0,
    p_page_size integer DEFAULT 10,
    p_pk_usuario bigint DEFAULT NULL::bigint,
    p_sort_by text DEFAULT NULL::text,
    p_sort_dir text DEFAULT NULL::text
)
RETURNS TABLE(id bigint, document_number character varying, first_name character varying, last_name character varying, institution character varying, campus character varying, shift character varying, education_level text, grade integer, grupo character varying, enrollment_date date, guardian text, status text, has_grades boolean, total_count bigint)
-- jit off: con un millon de matriculas compilar costaba casi un segundo.
LANGUAGE plpgsql
STABLE
SET jit = off
AS $function$
DECLARE
    v_col  TEXT;
    v_dir  TEXT;
    v_expr TEXT;   -- la misma columna, sobre b y lo que haga falta unirle
    v_join TEXT;
    v_per  BIGINT[];
    v_vig  BOOLEAN;
    v_cur  BIGINT;   -- pk de Cursando; NULL = sin filtro de estado
BEGIN
    -- Periodos visibles como arreglo: el plan ve cuantos son y elige indice
    -- para una sede o recorrido completo para un global.
    -- Establecimiento no ve historico: periodo activo y no Cerrado ('C').
    v_vig := COALESCE(academico_test.fn_usuario_categoria_rol_nivel(p_pk_usuario) = 2, FALSE);
    v_per := ARRAY(
        SELECT up.periodo_id
          FROM academico_test.fn_periodo_usuario_periodos(p_pk_usuario) up
         WHERE NOT v_vig
            OR EXISTS (SELECT 1
                         FROM academico_test.TPERIODO_ACADEMICO pa
                         LEFT JOIN academico_test.TLISTA_VALOR lv
                                ON lv.PK_LISTA_VALOR = pa.FK_TLV_ESTADO
                               AND lv.CATEGORIA = 'ESTADOPERIODO'
                        WHERE pa.PK_TPERIODO_ACADEMICO = up.periodo_id
                          AND pa.ACTIVE = TRUE
                          AND lv.VALOR IS DISTINCT FROM 'C'));
    IF v_vig THEN
        SELECT PK_LISTA_VALOR INTO v_cur
          FROM academico_test.TLISTA_VALOR
         WHERE CATEGORIA = 'ESTADO_MATRICULA' AND VALOR = '1' AND ACTIVE = TRUE;
        v_cur := COALESCE(v_cur, -1);  -- sin catalogo: nada, no todo
    END IF;
    -- Los valores son alias del SELECT final, no nombres de RETURNS TABLE.
    v_col := CASE lower(coalesce(p_sort_by, ''))
        WHEN 'documentnumber' THEN 'document_number'
        WHEN 'firstname'      THEN 'first_name'
        WHEN 'lastname'       THEN 'last_name'
        WHEN 'institution'    THEN 'institution'
        WHEN 'campus'         THEN 'campus'
        WHEN 'shift'          THEN 'shift'
        WHEN 'educationlevel' THEN 'educationlevel'
        WHEN 'grade'          THEN 'grade_num'
        WHEN 'group'          THEN 'grupo'
        WHEN 'enrollmentdate' THEN 'enrollment_date'
        WHEN 'guardian'       THEN 'guardian_name'
        WHEN 'status'         THEN 'status'
        ELSE 'last_name'
    END;
    v_dir := CASE WHEN lower(coalesce(p_sort_dir, '')) = 'desc' THEN 'DESC' ELSE 'ASC' END;
    -- Se pagina antes de poner los textos: solo se une lo que pide el orden.
    v_expr := CASE v_col
        WHEN 'document_number' THEN 'u.IDENTIFICACION'
        WHEN 'first_name'      THEN 'TRIM(concat_ws('' '', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE))::VARCHAR'
        WHEN 'last_name'       THEN 'TRIM(concat_ws('' '', u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO))::VARCHAR'
        WHEN 'guardian_name'   THEN 'ac.guardian_name'
        WHEN 'enrollment_date' THEN 'b.enrollment_date'
        WHEN 'status'          THEN 'b.status'
        ELSE 'gr.' || v_col
    END;
    v_join := CASE
        WHEN v_col IN ('document_number', 'first_name', 'last_name')
            THEN 'JOIN academico_test.TUSUARIO u ON u.PK_TUSUARIO = b.fk_tusuario'
        WHEN v_col = 'guardian_name'
            THEN 'CROSS JOIN LATERAL academico_test.fn_matricula_acudiente(b.fk_testudiante, b.fk_tpadre) ac'
        WHEN v_col IN ('enrollment_date', 'status')
            THEN ''
        ELSE 'JOIN gr ON gr.pk_tgrupo = b.fk_tgrupo'
    END;

    RETURN QUERY EXECUTE format($q$
      -- Grupos visibles con sus textos: miles de filas, no millones.
      WITH gr AS MATERIALIZED (
        SELECT gr.PK_TGRUPO AS pk_tgrupo,
               est.NOMBRE AS institution,
               sd.NOMBRE AS campus,
               jor.NOMBRE AS shift,
               -- Fuente real: TNIVEL_ENSENANZA.CODIGO 1..4, no el numero de grado.
               CASE ne.CODIGO
                   WHEN '1' THEN 'PREESCOLAR'
                   WHEN '2' THEN 'BASICA_PRIMARIA'
                   WHEN '3' THEN 'BASICA_SECUNDARIA'
                   WHEN '4' THEN 'MEDIA'
               END AS educationlevel,
               NULLIF(g.CODIGO,'')::INT AS grade_num,
               gr.NOMBRE AS grupo
          FROM academico_test.TPERIODO_ACADEMICO pa
          JOIN academico_test.TSEDE sd       ON sd.PK_TSEDE = pa.FK_TSEDE
          JOIN academico_test.TESTABLECIMIENTO est ON est.PK_ESTABLECIMIENTO = sd.FK_TESTABLECIMIENTO
          JOIN academico_test.TGRADO g       ON g.FK_TPERIODO_ACADEMICO = pa.PK_TPERIODO_ACADEMICO AND g.ACTIVE = TRUE
          JOIN academico_test.TNIVEL_ENSENANZA ne ON ne.PK_NIVEL_ENSENANZA = g.FK_TNIVEL_ENSENANZA
          JOIN academico_test.TGRUPO gr      ON gr.FK_TGRADO = g.PK_TGRADO AND gr.ACTIVE = TRUE
          JOIN academico_test.TLISTA_VALOR jor ON jor.PK_LISTA_VALOR = gr.FK_TLV_JORNADA
         WHERE pa.PK_TPERIODO_ACADEMICO = ANY($10)
           AND ($3 IS NULL OR sd.NOMBRE = $3)
           AND ($4 IS NULL OR jor.NOMBRE = $4)
           AND ($5 IS NULL OR NULLIF(g.CODIGO,'')::INT = $5)
           AND ($6 IS NULL OR gr.NOMBRE = $6)
      ),
      -- Con busqueda: acudientes cuyo nombre coincide, una pasada por TPADRE.
      pad AS MATERIALIZED (
        SELECT p.PK_TPADRE AS pk
          FROM academico_test.TPADRE p
          JOIN academico_test.TUSUARIO pu ON pu.PK_TUSUARIO = p.FK_TUSUARIO
         WHERE $1 IS NOT NULL
           AND concat_ws(' ', pu.PRIMER_NOMBRE, pu.SEGUNDO_NOMBRE,
                              pu.PRIMER_APELLIDO, pu.SEGUNDO_APELLIDO) ILIKE '%%' || $1 || '%%'
      ),
      -- Solo ids hasta paginar.
      b AS MATERIALIZED (
        SELECT m.PK_TMATRICULA AS id, m.FK_TGRUPO AS fk_tgrupo,
               m.FK_TESTUDIANTE AS fk_testudiante, m.FK_TPADRE AS fk_tpadre,
               es.FK_TUSUARIO AS fk_tusuario,
               m.CREATED_AT::DATE AS enrollment_date,
               -- Cast obligatorio: en SQL dinamico no hay coercion VARCHAR->TEXT.
               est_m.NOMBRE::TEXT AS status
          FROM gr
          JOIN academico_test.TMATRICULA m   ON m.FK_TGRUPO = gr.pk_tgrupo AND m.ACTIVE = TRUE
          JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE AND es.ACTIVE = TRUE
                                            AND es.FK_TUSUARIO IS NOT NULL
          -- Solo la usa la busqueda: sin ella el planificador quita el join.
          LEFT JOIN academico_test.TUSUARIO u ON u.PK_TUSUARIO = es.FK_TUSUARIO
          JOIN academico_test.TLISTA_VALOR est_m ON est_m.PK_LISTA_VALOR = m.FK_TLV_ESTADO_MATRICULA
         WHERE ($2 IS NULL OR CARDINALITY($2) = 0 OR est_m.NOMBRE = ANY($2))
           -- Establecimiento: solo Cursando, por pk ya resuelto.
           AND ($11::BIGINT IS NULL OR m.FK_TLV_ESTADO_MATRICULA = $11)
           AND ($1 IS NULL OR
                u.IDENTIFICACION ILIKE '%%' || $1 || '%%' OR
                gr.institution   ILIKE '%%' || $1 || '%%' OR
                concat_ws(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
                               u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO)
                    ILIKE '%%' || $1 || '%%' OR
                -- El acudiente sale de FK_TPADRE o de un vinculo del estudiante:
                -- si ninguno esta en pad no hace falta resolverlo.
                ((m.FK_TPADRE IN (SELECT pk FROM pad) OR
                  m.FK_TESTUDIANTE IN (SELECT nf.FK_TESTUDIANTE
                                         FROM academico_test.TNUCLEO_FAMILIAR nf
                                        WHERE nf.ACTIVE = TRUE
                                          AND nf.FK_TPADRE IN (SELECT pk FROM pad)))
                 AND EXISTS (SELECT 1
                               FROM academico_test.fn_matricula_acudiente(m.FK_TESTUDIANTE, m.FK_TPADRE) ac
                              WHERE ac.nombre ILIKE '%%' || $1 || '%%')))
      ),
      sel AS (
        SELECT b.* FROM b %3$s
         ORDER BY %4$s %2$s, b.id
         LIMIT NULLIF($8, 0)
        OFFSET COALESCE($7, 0) * COALESCE(NULLIF($8, 0), 0)
      ),
      pg AS (
        SELECT p.id,
               u.IDENTIFICACION AS document_number,
               TRIM(concat_ws(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE))::VARCHAR     AS first_name,
               TRIM(concat_ws(' ', u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO))::VARCHAR AS last_name,
               gr.institution, gr.campus, gr.shift, gr.educationlevel, gr.grade_num, gr.grupo,
               p.enrollment_date,
               ac.guardian_name,
               p.status
          FROM sel p
          JOIN gr                        ON gr.pk_tgrupo = p.fk_tgrupo
          JOIN academico_test.TUSUARIO u ON u.PK_TUSUARIO = p.fk_tusuario
          CROSS JOIN LATERAL academico_test.fn_matricula_acudiente(p.fk_testudiante, p.fk_tpadre) ac
      )
      SELECT pg.id, pg.document_number, pg.first_name, pg.last_name,
             pg.institution, pg.campus, pg.shift,
             pg.educationlevel AS education_level,
             pg.grade_num      AS grade,
             pg.grupo, pg.enrollment_date,
             pg.guardian_name  AS guardian,
             pg.status,
             (EXISTS (
                 SELECT 1 FROM academico_test.TASIGNATURA_NOTA an
                  WHERE an.FK_TMATRICULA = pg.id AND an.ACTIVE = TRUE
                    AND an.CALIFICACION IS NOT NULL
             ) OR EXISTS (
                 SELECT 1 FROM academico_test.TASIGNATURA_DEFINITIVA ad
                  WHERE ad.FK_TMATRICULA = pg.id AND ad.ACTIVE = TRUE
                    AND ad.DEFINITIVA IS NOT NULL
             )) AS has_grades,
             (SELECT count(*) FROM b)::BIGINT AS total_count
        FROM pg
       ORDER BY %1$s %2$s, pg.id
    $q$, v_col, v_dir, v_join, v_expr)
    USING NULLIF(TRIM(p_search), ''), p_statuses, NULLIF(TRIM(p_campus), ''), NULLIF(TRIM(p_shift), ''),
          p_grade, NULLIF(TRIM(p_group), ''), p_page_index, p_page_size, p_pk_usuario, v_per, v_cur;
END;
$function$;
