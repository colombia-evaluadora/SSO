-- ===========================================================================
-- V200 — Cobertura: listado de matricula (POST /coverage/matricula/query).
--
-- Contrato completo: docs/matricula-listado-endpoint-contract.md (front
-- repo). Resumen: filtros {search, statuses[], campus, shift, grade, group},
-- 1 criterio de orden, paginacion pageIndex/pageSize -> {rows, pageCount,
-- totalCount}.
--
-- Cadena de entidades reales (NO es TLISTA_VALOR salvo donde se indica):
--   TMATRICULA -> TESTUDIANTE -> TUSUARIO           (documentNumber/nombre)
--   TMATRICULA -> TGRUPO -> TGRADO -> TPERIODO_ACADEMICO -> TSEDE -> TESTABLECIMIENTO
--   TGRUPO.FK_TLV_JORNADA -> TLISTA_VALOR            (shift, string libre)
--   TMATRICULA.FK_TLV_ESTADO_MATRICULA -> TLISTA_VALOR (status)
--   TESTUDIANTE -> TNUCLEO_FAMILIAR -> TPADRE -> TUSUARIO (guardian, nombre)
--   TNUCLEO_FAMILIAR.FK_TLV_PARENTESCO -> TLISTA_VALOR (guardian, parentesco)
--
-- Alcance/seguridad: se reusa academico_test.fn_periodo_usuario_puede_ver
-- (V37) sobre el periodo academico del grado de cada matricula — mismo
-- criterio de visibilidad (global 1/2/3, establecimiento 7/8/9, sede 11) que
-- ya usa el modulo de Periodos Academicos. Ver memoria "role-scoping-academic".
--
-- --------------------------------------------------------------------------
-- Verificado contra la BD real (tunel SSH a 172.233.184.248, sso_db,
-- 2026-08-27) antes de escribir esta version — reemplaza las suposiciones
-- de la version anterior de este archivo:
--
--  1. educationLevel: NO se deriva del numero de grado (evitado a proposito
--     mas abajo) — TGRADO.FK_TNIVEL_ENSENANZA -> TNIVEL_ENSENANZA ya trae
--     exactamente los 4 niveles del front (CODIGO 1..4 = Preescolar/Basica
--     Primaria/Basica Secundaria/Media), confirmado con datos reales. Se usa
--     ese join + CASE sobre ne.CODIGO.
--
--  2. grade: TGRADO.CODIGO SI es siempre castable a INT (confirmado, ningun
--     grado real tiene CODIGO no numerico), pero el dominio real excede el
--     0..11 que asumia el front hoy — hay grados activos con codigo -2, -1
--     (preescolar previo a transicion: Pre-Jardin, Jardin) y con codigo
--     21..26 y 99 (cientos de filas, no basura — ciclos/aceleracion/
--     validacion de adultos). DECIDIDO: el front se adapta al dominio real,
--     asi que esta funcion devuelve el codigo tal cual (casteado a INT) sin
--     recortar rango — filas con grade fuera de 0..11 SI aparecen.
--
--  3. status: el catalogo real ESTADO_MATRICULA (TLISTA_VALOR, 11 valores
--     activos) no coincide con el enum viejo de 6 valores del front
--     (`MatriculaStatus`: cursando/aprobado/reprobado/promovido/reubicado/
--     retirado) — catalogo real: Cursando, Aprobado, Reprobado, Retirado,
--     Graduado, "Promovido Anticipadamente", Trasladado, "Sin definir",
--     Desertor, "Esperando Aprobación", Rechazado. DECIDIDO: el front se
--     adapta a los valores reales, asi que no hay mapeo — `status` es un
--     slug derivado directo de TLISTA_VALOR.NOMBRE (minusculas, espacios a
--     "_", tildes fuera): cursando, aprobado, reprobado, retirado, graduado,
--     promovido_anticipadamente, trasladado, sin_definir, desertor,
--     esperando_aprobacion, rechazado. Si se agregan valores nuevos al
--     catalogo, aparecen solos (mismo slug) sin tocar esta funcion.
--
--  4. enrollmentDate: TMATRICULA no tiene una columna de fecha de matricula
--     propia (no es TINSCRIPCION/TPREMATRICULA, que son trazabilidad
--     opcional). Se usa TMATRICULA.CREATED_AT como fecha de matricula.
--
--  5. hasGrades: EXISTS sobre TASIGNATURA_NOTA (nota parcial) o
--     TASIGNATURA_DEFINITIVA (nota final) para la matricula — cualquiera de
--     las dos con valor no nulo cuenta como "tiene calificaciones". No se
--     pudo probar contra datos reales: TMATRICULA/TASIGNATURA_NOTA/
--     TASIGNATURA_DEFINITIVA estan en 0 filas en el ambiente consultado.
--
--  6. guardian (corregido tras probar contra datos reales, 2026-08-31):
--     TMATRICULA.FK_TPADRE / TMATRICULA.FK_TLV_ACUDIENTE_PARENTESCO estan
--     SIEMPRE null en los datos migrados -- el vinculo real esta en
--     TNUCLEO_FAMILIAR (tabla muchos-a-muchos ESTUDIANTE<->PADRE, con
--     FK_TLV_PARENTESCO propia), confirmado con el equipo de back. Un mismo
--     TESTUDIANTE puede tener varias filas en TNUCLEO_FAMILIAR (padre, madre,
--     etc.); se prioriza la marcada ACUDIENTE = 'S', y si ninguna lo esta
--     (visto en datos reales: existe al menos una fila con ACUDIENTE NULL
--     que el detalle igual muestra como acudiente) se toma cualquiera como
--     fallback en vez de dejar el campo vacio. Solo 33.040 de 76.821
--     matriculas activas tienen alguna fila en TNUCLEO_FAMILIAR -- el resto
--     legitimamente no tiene acudiente registrado, `guardian` sale NULL.
--     Nombre del acudiente: solo primer nombre + primer apellido (no los 4
--     campos), por consistencia con como ya se muestra el nombre del
--     estudiante en este mismo listado.
-- ===========================================================================

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_listar(
    p_search      TEXT    DEFAULT NULL,  -- ILIKE sobre documento/nombres/institucion/acudiente
    p_statuses    TEXT[]  DEFAULT NULL,  -- slugs reales del catalogo (ver nota 3)
    p_campus      TEXT    DEFAULT NULL,  -- TSEDE.NOMBRE, match exacto
    p_shift       TEXT    DEFAULT NULL,  -- TLISTA_VALOR(JORNADA).NOMBRE, match exacto
    p_grade       INT     DEFAULT NULL,  -- TGRADO.CODIGO::INT, match exacto (ver nota 2)
    p_group       TEXT    DEFAULT NULL,  -- TGRUPO.NOMBRE, match exacto
    p_page_index  INT     DEFAULT 0,     -- 0-based
    p_page_size   INT     DEFAULT 10,    -- 0/NULL = sin paginar
    p_pk_usuario  BIGINT  DEFAULT NULL,  -- alcance (ver fn_periodo_usuario_puede_ver)
    p_sort_by     TEXT    DEFAULT NULL,  -- id de columna del front (documentNumber, firstName, ...)
    p_sort_dir    TEXT    DEFAULT NULL   -- 'asc' | 'desc'
)
RETURNS TABLE (
    id               BIGINT,
    document_number  VARCHAR,
    first_name       VARCHAR,
    last_name        VARCHAR,
    institution      VARCHAR,
    campus           VARCHAR,
    shift            VARCHAR,
    education_level  TEXT,
    grade            INT,
    grupo            VARCHAR,
    enrollment_date  DATE,
    guardian         TEXT,
    status           TEXT,
    has_grades       BOOLEAN,
    total_count      BIGINT
)
LANGUAGE plpgsql STABLE AS $$
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
                -- Slug directo del catalogo real -- ver nota 3 del header
                -- (el front se adapta a estos valores, sin mapeo a un enum
                -- fijo). Tildes fuera con translate(), espacios a "_".
                lower(regexp_replace(
                    translate(trim(est_m.NOMBRE), 'ÁÉÍÓÚÑáéíóúñ', 'AEIOUNaeioun'),
                    '\s+', '_', 'g'
                )) AS status,
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
         -- Acudiente real via TNUCLEO_FAMILIAR (muchos-a-muchos ESTUDIANTE<->
         -- PADRE) -- ver nota 6 del header, NO via TMATRICULA.FK_TPADRE (esa
         -- columna esta siempre null en los datos reales). Prioriza
         -- ACUDIENTE='S'; si ninguna fila lo tiene marcado, cae a cualquiera
         -- (fila mas antigua) en vez de dejar el campo vacio.
         LEFT JOIN LATERAL (
                SELECT nf.FK_TPADRE, nf.FK_TLV_PARENTESCO
                  FROM academico_test.TNUCLEO_FAMILIAR nf
                 WHERE nf.FK_TESTUDIANTE = m.FK_TESTUDIANTE AND nf.ACTIVE = TRUE
                 ORDER BY (nf.ACUDIENTE = 'S') DESC NULLS LAST, nf.PK_TNUCLEO_FAMILIAR
                 LIMIT 1
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
        -- el catalogo crudo -- ver nota 3 del header sobre el mapeo. Va en un
        -- nivel aparte (y total_count se calcula DESPUES, en el siguiente)
        -- porque una alias de SELECT no es visible en el WHERE del mismo
        -- nivel, y count(*) OVER() debe reflejar este filtro tambien.
        WHERE ($2 IS NULL OR CARDINALITY($2) = 0 OR q.status = ANY($2))
        ) qs
        ORDER BY %s %s, id
        LIMIT NULLIF($8, 0)
       OFFSET COALESCE($7, 0) * COALESCE(NULLIF($8, 0), 0)
    $q$, v_col, v_dir)
    USING NULLIF(TRIM(p_search), ''), p_statuses, NULLIF(TRIM(p_campus), ''), NULLIF(TRIM(p_shift), ''),
          p_grade, NULLIF(TRIM(p_group), ''), p_page_index, p_page_size, p_pk_usuario;
END;
$$;
