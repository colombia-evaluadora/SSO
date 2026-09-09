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
--   TMATRICULA.FK_TPADRE -> TPADRE -> TUSUARIO        (guardian, nombre)
--   TMATRICULA.FK_TLV_ACUDIENTE_PARENTESCO -> TLISTA_VALOR (guardian, parentesco)
--
-- Alcance/seguridad (CU-86e2w4xdt): modelo capability + scope unificado
-- (docs/gate-permisos-por-menu-analysis.md), igual que el resto de la
-- seccion Matricula. Reemplaza a fn_periodo_usuario_puede_ver (listas fijas
-- de FK_TROL):
--   * CAPABILITY: se exige 'VER' sobre el menu MATRICULA
--     (fn_usuario_puede_en_menu) -- TROL_MENU concede / TUSUARIO_ROL_PERMISO
--     recorta, lo administra el super admin. Sin capability -> 42501.
--     El SUPER_ADMIN (categoria nivel 0) no pasa por esta comprobacion.
--   * SCOPE por categoria de rol (fn_usuario_categoria_rol_nivel):
--       nivel 0/1 (super / territorial) -> ve TODAS las matriculas;
--       nivel 2 (establecimiento)       -> EE en fn_usuario_ee_accesibles;
--       nivel 3 (sede+jornada)          -> par (TSEDE, TGRUPO.FK_TLV_JORNADA)
--                                          en fn_usuario_sedes_jornadas_accesibles;
--       sin categoria / nivel 4         -> no ve ninguna (fail-closed).
--   * p_pk_usuario NULL (llamada interna sin scoping) -> se trata como
--     nivel 0: devuelve todo, sin exigir capability.
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
    p_pk_usuario  BIGINT  DEFAULT NULL,  -- alcance: capability 'VER' MATRICULA + scope por categoria de rol (NULL = interno, sin scoping)
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
    -- Autorizacion (CU-86e2w4xdt): fail-fast de capability. Si el usuario no
    -- es SUPER_ADMIN y no tiene 'VER' sobre el menu MATRICULA -> 42501 (mismo
    -- trato que el resto de la seccion). El filtro FINO por scope (que EE /
    -- sede+jornada ve) va por fila, con fn_matricula_puede_ver (V40), que
    -- reemplaza a fn_periodo_usuario_puede_ver.
    IF p_pk_usuario IS NOT NULL
       AND COALESCE(academico_test.fn_usuario_categoria_rol_nivel(p_pk_usuario), 99) <> 0
       AND NOT academico_test.fn_usuario_puede_en_menu(p_pk_usuario, 'MATRICULA', 'VER') THEN
        RAISE EXCEPTION 'El usuario no tiene permiso para ver en el modulo MATRICULA'
            USING ERRCODE = '42501';
    END IF;
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
                NULLIF(TRIM(regexp_replace(
                    concat_ws(' ', pu.PRIMER_NOMBRE, pu.SEGUNDO_NOMBRE, pu.PRIMER_APELLIDO, pu.SEGUNDO_APELLIDO),
                    '\s+', ' ', 'g')), '')
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
         LEFT JOIN academico_test.TPADRE p        ON p.PK_TPADRE = m.FK_TPADRE
         LEFT JOIN academico_test.TUSUARIO pu     ON pu.PK_TUSUARIO = p.FK_TUSUARIO
         LEFT JOIN academico_test.TLISTA_VALOR par ON par.PK_LISTA_VALOR = m.FK_TLV_ACUDIENTE_PARENTESCO
             WHERE m.ACTIVE = TRUE
               -- Scope fino por fila (CU-86e2w4xdt): capability + EE / sede+
               -- jornada segun categoria de rol. Reemplaza fn_periodo_usuario_puede_ver.
               AND academico_test.fn_matricula_puede_ver($9, gr.PK_TGRUPO)
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
