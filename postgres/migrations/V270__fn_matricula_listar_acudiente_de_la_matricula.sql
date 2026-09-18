-- =============================================================================
-- V270 -- fn_matricula_listar
--
-- Que hace:
--   * El acudiente de la fila sale de TMATRICULA.FK_TPADRE; TNUCLEO_FAMILIAR
--     solo actua de respaldo cuando esa columna viene NULL.
--   * first_name / last_name / guardian devuelven nombre y apellido COMPLETOS
--     (primer + segundo), y la busqueda libre los cubre.
--   * has_grades se evalua despues de paginar, no sobre todo el resultado.
--
-- Depende de: TMATRICULA, TNUCLEO_FAMILIAR, TPADRE, TUSUARIO, TGRUPO, TGRADO,
--   TNIVEL_ENSENANZA, TPERIODO_ACADEMICO, TSEDE, TESTABLECIMIENTO,
--   TLISTA_VALOR, fn_periodo_usuario_puede_ver. Idempotente: CREATE OR REPLACE.
-- =============================================================================

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
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_col TEXT;
    v_dir TEXT;
BEGIN
    -- Los valores son alias del SELECT interno, no nombres de RETURNS TABLE.
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

    RETURN QUERY EXECUTE format($q$
        SELECT
            pg.id,
            pg.document_number,
            pg.first_name,
            pg.last_name,
            pg.institution,
            pg.campus,
            pg.shift,
            pg.educationlevel AS education_level,
            pg.grade_num      AS grade,
            pg.grupo,
            pg.enrollment_date,
            pg.guardian_name  AS guardian,
            pg.status,
            -- Dentro del nivel paginado esto se evaluaria para cada fila que
            -- pasa los filtros; aca solo para las de la pagina pedida.
            (EXISTS (
                SELECT 1 FROM academico_test.TASIGNATURA_NOTA an
                 WHERE an.FK_TMATRICULA = pg.id AND an.ACTIVE = TRUE
                   AND an.CALIFICACION IS NOT NULL
            ) OR EXISTS (
                SELECT 1 FROM academico_test.TASIGNATURA_DEFINITIVA ad
                 WHERE ad.FK_TMATRICULA = pg.id AND ad.ACTIVE = TRUE
                   AND ad.DEFINITIVA IS NOT NULL
            )) AS has_grades,
            pg.total_count
        FROM (
            SELECT q.*, count(*) OVER()::BIGINT AS total_count
            FROM (
                SELECT
                    m.PK_TMATRICULA AS id,
                    u.IDENTIFICACION AS document_number,
                    TRIM(concat_ws(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE))::VARCHAR     AS first_name,
                    TRIM(concat_ws(' ', u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO))::VARCHAR AS last_name,
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
                    gr.NOMBRE AS grupo,
                    m.CREATED_AT::DATE AS enrollment_date,
                    NULLIF(TRIM(concat_ws(' ', pu.PRIMER_NOMBRE, pu.SEGUNDO_NOMBRE,
                                               pu.PRIMER_APELLIDO, pu.SEGUNDO_APELLIDO)), '')
                        || COALESCE(' (' || par.NOMBRE || ')', '') AS guardian_name,
                    -- Cast obligatorio: en SQL dinamico no hay coercion
                    -- VARCHAR->TEXT y la funcion reventaria con "structure of
                    -- query does not match function result type".
                    est_m.NOMBRE::TEXT AS status
                  FROM academico_test.TMATRICULA m
                  JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE AND es.ACTIVE = TRUE
                  JOIN academico_test.TUSUARIO u     ON u.PK_TUSUARIO = es.FK_TUSUARIO
                  JOIN academico_test.TGRUPO gr      ON gr.PK_TGRUPO = m.FK_TGRUPO AND gr.ACTIVE = TRUE
                  JOIN academico_test.TGRADO g       ON g.PK_TGRADO = gr.FK_TGRADO AND g.ACTIVE = TRUE
                  JOIN academico_test.TNIVEL_ENSENANZA ne ON ne.PK_NIVEL_ENSENANZA = g.FK_TNIVEL_ENSENANZA
                  JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
                  JOIN academico_test.TSEDE sd       ON sd.PK_TSEDE = pa.FK_TSEDE
                  JOIN academico_test.TESTABLECIMIENTO est ON est.PK_ESTABLECIMIENTO = sd.FK_TESTABLECIMIENTO
                  JOIN academico_test.TLISTA_VALOR jor ON jor.PK_LISTA_VALOR = gr.FK_TLV_JORNADA
                  JOIN academico_test.TLISTA_VALOR est_m ON est_m.PK_LISTA_VALOR = m.FK_TLV_ESTADO_MATRICULA
             -- El acudiente es el que senala TMATRICULA.FK_TPADRE, y de esa
             -- misma fila sale el parentesco. Si viene NULL se cae al vinculo
             -- familiar marcado como acudiente (o al mas antiguo).
             LEFT JOIN LATERAL (
                    SELECT nf0.FK_TPADRE, nf0.FK_TLV_PARENTESCO
                      FROM academico_test.TNUCLEO_FAMILIAR nf0
                     WHERE nf0.FK_TESTUDIANTE = m.FK_TESTUDIANTE
                       AND nf0.ACTIVE = TRUE
                       AND (m.FK_TPADRE IS NULL OR nf0.FK_TPADRE = m.FK_TPADRE)
                     ORDER BY (m.FK_TPADRE IS NULL AND nf0.ACUDIENTE = 'S') DESC NULLS LAST,
                              nf0.PK_TNUCLEO_FAMILIAR
                     LIMIT 1
             ) nf ON TRUE
             LEFT JOIN academico_test.TPADRE p        ON p.PK_TPADRE = COALESCE(m.FK_TPADRE, nf.FK_TPADRE)
             LEFT JOIN academico_test.TUSUARIO pu     ON pu.PK_TUSUARIO = p.FK_TUSUARIO
             LEFT JOIN academico_test.TLISTA_VALOR par ON par.PK_LISTA_VALOR = nf.FK_TLV_PARENTESCO
                 WHERE m.ACTIVE = TRUE
                   AND academico_test.fn_periodo_usuario_puede_ver($9, pa.PK_TPERIODO_ACADEMICO)
                   AND ($3 IS NULL OR sd.NOMBRE = $3)
                   AND ($4 IS NULL OR jor.NOMBRE = $4)
                   AND ($5 IS NULL OR NULLIF(g.CODIGO,'')::INT = $5)
                   AND ($6 IS NULL OR gr.NOMBRE = $6)
                   -- Estado sobre el NOMBRE crudo del catalogo ("Cursando"),
                   -- aqui mismo para que count(*) OVER() ya lo refleje.
                   AND ($2 IS NULL OR CARDINALITY($2) = 0 OR est_m.NOMBRE = ANY($2))
                   AND ($1 IS NULL OR (
                           u.IDENTIFICACION ILIKE '%%' || $1 || '%%' OR
                           est.NOMBRE ILIKE '%%' || $1 || '%%' OR
                           concat_ws(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
                                          u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO)
                               ILIKE '%%' || $1 || '%%' OR
                           concat_ws(' ', pu.PRIMER_NOMBRE, pu.SEGUNDO_NOMBRE,
                                          pu.PRIMER_APELLIDO, pu.SEGUNDO_APELLIDO)
                               ILIKE '%%' || $1 || '%%'
                       ))
            ) q
            ORDER BY %1$s %2$s, id
            LIMIT NULLIF($8, 0)
           OFFSET COALESCE($7, 0) * COALESCE(NULLIF($8, 0), 0)
        ) pg
        ORDER BY %1$s %2$s, pg.id
    $q$, v_col, v_dir)
    USING NULLIF(TRIM(p_search), ''), p_statuses, NULLIF(TRIM(p_campus), ''), NULLIF(TRIM(p_shift), ''),
          p_grade, NULLIF(TRIM(p_group), ''), p_page_index, p_page_size, p_pk_usuario;
END;
$function$;
