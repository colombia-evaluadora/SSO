-- =============================================================================
-- V239 -- fn_matricula_listar: el acudiente de la fila sale de
-- TMATRICULA.FK_TPADRE, no de un desempate arbitrario del nucleo familiar.
--
-- -----------------------------------------------------------------------------
-- Por que va en una migracion nueva y no editando V200
-- -----------------------------------------------------------------------------
-- La funcion que corre en el servidor NO es la de V200: alguien aplico a mano
-- una revision posterior que no quedo escrita en el repo (V200 une por
-- m.FK_TPADRE; la viva usa un LEFT JOIN LATERAL sobre TNUCLEO_FAMILIAR).
-- Editar V200 con lo que dice el archivo revertiria esa revision, y escribir
-- ahi la version viva seria subir al repo trabajo de otra persona sin que lo
-- haya revisado.
--
-- Asi que esta migracion parte de la version VIVA y solo cambia como se elige
-- el acudiente. Cuando el dueño de V200 escriba su revision al archivo, esto
-- sigue siendo la ultima palabra por numero de version. El detalle del cambio
-- esta comentado dentro de la propia funcion.
--
-- Idempotente: CREATE OR REPLACE.
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
    -- Los alias de la derivada de abajo son los nombres de columna de salida
    -- (RETURNS TABLE) salvo educationlevel/grade_num/grupo/guardian_name, que
    -- son los alias reales usados en el SELECT interno.
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
        SELECT *, count(*) OVER()::BIGINT AS total_count FROM (
        SELECT * FROM (
            SELECT
                m.PK_TMATRICULA AS id,
                u.IDENTIFICACION AS document_number,
                u.PRIMER_NOMBRE AS first_name,
                u.PRIMER_APELLIDO AS last_name,
                est.NOMBRE AS institution,
                sd.NOMBRE AS campus,
                jor.NOMBRE AS shift,
                -- Fuente real confirmada en BD (ver nota 1): TNIVEL_ENSENANZA.CODIGO
                -- 1..4, NO se deriva del numero de grado.
                CASE ne.CODIGO
                    WHEN '1' THEN 'PREESCOLAR'
                    WHEN '2' THEN 'BASICA_PRIMARIA'
                    WHEN '3' THEN 'BASICA_SECUNDARIA'
                    WHEN '4' THEN 'MEDIA'
                END AS educationlevel,
                NULLIF(g.CODIGO,'')::INT AS grade_num,
                gr.NOMBRE AS grupo,
                m.CREATED_AT::DATE AS enrollment_date,
                -- Solo primer nombre + primer apellido -- ver nota 6 del header.
                NULLIF(TRIM(concat_ws(' ', pu.PRIMER_NOMBRE, pu.PRIMER_APELLIDO)), '')
                    || COALESCE(' (' || par.NOMBRE || ')', '') AS guardian_name,
                -- NOMBRE crudo de TLISTA_VALOR, tal cual -- el front ya no
                -- arma un slug propio, usa el mismo valor que detalle y
                -- catálogo (ver nota 3 del header). Cast explícito a TEXT:
                -- TLISTA_VALOR.NOMBRE es VARCHAR, pero RETURNS TABLE declara
                -- `status TEXT` -- en un RETURN QUERY EXECUTE con SQL
                -- dinámico, Postgres exige que el tipo calce exacto (no hay
                -- coerción implícita VARCHAR->TEXT acá), así que sin el cast
                -- la función falla en runtime con "structure of query does
                -- not match function result type" (el 500 que se vio).
                est_m.NOMBRE::TEXT AS status,
                EXISTS (
                    SELECT 1 FROM academico_test.TASIGNATURA_NOTA an
                     WHERE an.FK_TMATRICULA = m.PK_TMATRICULA AND an.ACTIVE = TRUE
                       AND an.CALIFICACION IS NOT NULL
                    UNION ALL
                    SELECT 1 FROM academico_test.TASIGNATURA_DEFINITIVA ad
                     WHERE ad.FK_TMATRICULA = m.PK_TMATRICULA AND ad.ACTIVE = TRUE
                       AND ad.DEFINITIVA IS NOT NULL
                ) AS has_grades
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
         -- REV -- El acudiente de la matricula es el que señala
         -- TMATRICULA.FK_TPADRE. La revision anterior lo descartaba con el
         -- argumento de que "esa columna esta siempre null en los datos
         -- reales", y eso no se sostiene: de las matriculas activas, 32.070
         -- la tienen rellena y 31.293 de ellas coinciden con una fila ACTIVA
         -- de TNUCLEO_FAMILIAR para el mismo par (padre, estudiante).
         --
         -- El desempate que habia --ACUDIENTE='S' y, si no, la fila mas
         -- antigua-- no desempata nada: ACUDIENTE vale 'S' en 18.262 de las
         -- 18.268 filas activas, y en los estudiantes con varios vinculos
         -- estan TODOS marcados (499 con 2 de 2, 117 con 3 de 3, uno con 26
         -- de 26). Resultado: a un estudiante con dos o tres acudientes se le
         -- mostraba uno esencialmente arbitrario, ignorando el que la
         -- matricula si indica.
         --
         -- Se conserva el criterio viejo como RESPALDO, solo para cuando
         -- FK_TPADRE viene NULL (las altas hechas por la app no lo llenaban
         -- hasta ahora, y hay 382 matriculas sin ningun vinculo).
         LEFT JOIN LATERAL (
                SELECT elegido.fk_tpadre AS FK_TPADRE,
                       (SELECT nf2.FK_TLV_PARENTESCO
                          FROM academico_test.TNUCLEO_FAMILIAR nf2
                         WHERE nf2.FK_TESTUDIANTE = m.FK_TESTUDIANTE
                           AND nf2.FK_TPADRE      = elegido.fk_tpadre
                           AND nf2.ACTIVE         = TRUE
                         ORDER BY nf2.PK_TNUCLEO_FAMILIAR
                         LIMIT 1) AS FK_TLV_PARENTESCO
                  FROM (
                        SELECT COALESCE(
                                   m.FK_TPADRE,
                                   (SELECT nf3.FK_TPADRE
                                      FROM academico_test.TNUCLEO_FAMILIAR nf3
                                     WHERE nf3.FK_TESTUDIANTE = m.FK_TESTUDIANTE
                                       AND nf3.ACTIVE         = TRUE
                                     ORDER BY (nf3.ACUDIENTE = 'S') DESC NULLS LAST,
                                              nf3.PK_TNUCLEO_FAMILIAR
                                     LIMIT 1)
                               ) AS fk_tpadre
                       ) elegido
         ) nf ON TRUE
         LEFT JOIN academico_test.TPADRE p        ON p.PK_TPADRE = nf.FK_TPADRE
         LEFT JOIN academico_test.TUSUARIO pu     ON pu.PK_TUSUARIO = p.FK_TUSUARIO
         LEFT JOIN academico_test.TLISTA_VALOR par ON par.PK_LISTA_VALOR = nf.FK_TLV_PARENTESCO
             WHERE m.ACTIVE = TRUE
               AND academico_test.fn_periodo_usuario_puede_ver($9, pa.PK_TPERIODO_ACADEMICO)
               AND ($1 IS NULL OR (
                       u.IDENTIFICACION ILIKE '%%' || $1 || '%%' OR
                       u.PRIMER_NOMBRE  ILIKE '%%' || $1 || '%%' OR
                       u.PRIMER_APELLIDO ILIKE '%%' || $1 || '%%' OR
                       est.NOMBRE ILIKE '%%' || $1 || '%%' OR
                       concat_ws(' ', pu.PRIMER_NOMBRE, pu.PRIMER_APELLIDO) ILIKE '%%' || $1 || '%%'
                   ))
               AND ($3 IS NULL OR sd.NOMBRE = $3)
               AND ($4 IS NULL OR jor.NOMBRE = $4)
               AND ($5 IS NULL OR NULLIF(g.CODIGO,'')::INT = $5)
               AND ($6 IS NULL OR gr.NOMBRE = $6)
        ) q
        -- Filtro de statuses sobre el alias ya mapeado (q.status), no sobre
        -- el catalogo crudo. Va en un nivel aparte (y total_count se calcula
        -- DESPUES, en el siguiente) porque una alias de SELECT no es visible
        -- en el WHERE del mismo nivel, y count(*) OVER() debe reflejar este
        -- filtro tambien. $2 ahora contiene el NOMBRE crudo ("Cursando"), no
        -- un slug -- ver nota 3 del header.
        WHERE ($2 IS NULL OR CARDINALITY($2) = 0 OR q.status = ANY($2))
        ) qs
        ORDER BY %s %s, id
        LIMIT NULLIF($8, 0)
       OFFSET COALESCE($7, 0) * COALESCE(NULLIF($8, 0), 0)
    $q$, v_col, v_dir)
    USING NULLIF(TRIM(p_search), ''), p_statuses, NULLIF(TRIM(p_campus), ''), NULLIF(TRIM(p_shift), ''),
          p_grade, NULLIF(TRIM(p_group), ''), p_page_index, p_page_size, p_pk_usuario;
END;
$function$;
