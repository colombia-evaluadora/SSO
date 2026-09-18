-- ===========================================================================
-- V350 - fn_prematricula_listar: listado paginado de PRE-MATRICULAS.
--
-- QUE ES LA PRE-MATRICULA
--   TPREMATRICULA (V22) es el paso intermedio de los estudiantes ANTIGUOS:
--   el que ya esta en la institucion y va a cambiar de grado. Su FK_TGRUPO
--   es, textualmente segun el comentario de la DDL, el "grupo tentativo del
--   nuevo grado" -- o sea el DESTINO, no donde esta hoy.
--
--   Los estudiantes NUEVOS van por la otra rama del modelo
--   (TRESERVA_CUPO -> TINSCRIPCION -> TMATRICULA) y no se listan aqui.
--
-- ALCANCE DE ESTA FUNCION
--   Devuelve SOLO lo que pinta la tabla del listado. El detalle de una fila
--   es un endpoint aparte -- fn_prematricula_buscar_por_pk (V351) -- igual
--   que en los demas modulos: el listado no arrastra los datos de la ficha.
--
--   Las columnas de la tabla son ID / Nombres / Apellidos / Sede / Grado /
--   Grado al que aspira / Estado. A eso se suman:
--
--     * failed -- lo necesita la celda "Grado al que aspira": si el
--       estudiante reprobo, el front pinta que repite el mismo grado en vez
--       de avanzar. La resolucion la hace el front; aqui target_grade es
--       siempre el grado crudo del grupo destino.
--     * institution / shift / education_level / grupo -- no son columnas,
--       pero si son las dimensiones de "Agrupar por" (junto con campus y
--       grade, que ya estan). Sin su valor el front no puede rotular los
--       grupos que el propio p_group_by arma.
--
-- DE DONDE SALE CADA COLUMNA
--   La fila mezcla DOS ubicaciones, y conviene tenerlo presente porque no
--   son la misma:
--
--     * ORIGEN  -- institution / campus / shift / education_level / grade /
--       grupo: la matricula ACTIVA mas reciente del estudiante, que es donde
--       esta hoy. El tipo del front lo dice asi: el bloque se titula "Datos
--       de la institucion educativa de origen" y group es "Grupo actual del
--       estudiante".
--     * DESTINO -- target_grade y status: el FK_TGRUPO de la prematricula.
--
--   No hay ninguna FK entre prematricula y matricula: TPREMATRICULA solo
--   conoce al estudiante, asi que el origen se resuelve por LATERAL a su
--   matricula activa mas reciente. En los datos de hoy los 47 registros
--   tienen matricula activa y ninguno esta ya en el grupo destino, que es
--   justo lo que se espera de un cambio de grado.
--
-- EL CUPO (status)
--   Compara TGRUPO.CAPACIDAD del grupo DESTINO contra
--   fn_matricula_cupo_ocupado (V145), que cuenta solo las matriculas en
--   Cursando / Aprobado / Reprobado -- las reubicadas y promovidas no gastan
--   cupo. status es su lectura textual: 'con_cupo' / 'sin_cupo'.
--
--   OJO -- el tipo del front admite un tercer valor, 'pendiente', y aqui NO
--   se emite nunca. No es un olvido: no hay regla de negocio conocida que lo
--   defina, el mock tampoco lo produce (status = hasSlot ? con_cupo :
--   sin_cupo) y los 5.335 grupos activos tienen CAPACIDAD, asi que tampoco
--   cabe como "no se puede saber". Se deja el hueco a proposito en vez de
--   inventarle un significado; cuando se defina, entra aqui.
--
-- PERMISOS
--   Capability por el menu PRE_MATRICULA (ya existe en TMENU, pk 868) y, por
--   fila, el alcance sobre el periodo academico del grupo DESTINO
--   (fn_periodo_usuario_puede_ver, el mismo criterio que fn_matricula_listar).
--   Sin capability se levanta 42501 en vez de devolver una lista vacia, que
--   son cosas distintas para el que llama.
--
-- FORMA
--   Calcada de fn_matricula_listar: SQL dinamico con lista blanca de
--   ordenamiento, count(*) OVER() como total_count en el nivel exterior, y
--   LIMIT/OFFSET por pageIndex/pageSize. Los filtros sobre columnas ya
--   derivadas (origen y status) se aplican en un nivel intermedio, porque un
--   alias del SELECT no es visible en el WHERE de su mismo nivel y
--   total_count tiene que reflejarlos.
--
--   p_group_by no cambia el conjunto de filas, solo antepone esa dimension
--   al ORDER BY -- es lo que el front documenta para "Agrupar por".
--
--   p_created_from / p_created_to filtran por CREATED_AT de la prematricula.
--   En el front ese control se llama reservedFrom/reservedTo porque la vista
--   reusa el formulario de reservas; aqui no hay reserva, la fecha propia es
--   la de creacion.
--
--   Las jornadas se comparan sin tildes y en mayuscula (TRANSLATE) para que
--   el 'MANANA' del front case con el 'Mañana' del catalogo, y tambien
--   contra el NOMBRE crudo por si llega ya resuelto.
--
-- El DROP de arriba existe porque cambia el RETURNS TABLE: CREATE OR REPLACE
-- no puede alterar el tipo de retorno de una funcion existente.
--
-- Idempotente: DROP IF EXISTS + CREATE OR REPLACE.
-- ===========================================================================


DROP FUNCTION IF EXISTS academico_test.fn_prematricula_listar(
    BIGINT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER, TEXT,
    TEXT[], TEXT[], TEXT[], DATE, DATE, TEXT, TEXT, TEXT, INTEGER, INTEGER);


CREATE OR REPLACE FUNCTION academico_test.fn_prematricula_listar(
    p_pk_usuario       BIGINT,
    p_search           TEXT    DEFAULT NULL,
    p_first_name       TEXT    DEFAULT NULL,
    p_last_name        TEXT    DEFAULT NULL,
    p_document_number  TEXT    DEFAULT NULL,
    p_institution      TEXT    DEFAULT NULL,
    p_campus           TEXT    DEFAULT NULL,
    p_grade            INTEGER DEFAULT NULL,
    p_group            TEXT    DEFAULT NULL,
    p_shifts           TEXT[]  DEFAULT NULL,
    p_levels           TEXT[]  DEFAULT NULL,
    p_statuses         TEXT[]  DEFAULT NULL,
    p_created_from     DATE    DEFAULT NULL,
    p_created_to       DATE    DEFAULT NULL,
    p_group_by         TEXT    DEFAULT NULL,
    p_sort_by          TEXT    DEFAULT NULL,
    p_sort_dir         TEXT    DEFAULT NULL,
    p_page_index       INTEGER DEFAULT 0,
    p_page_size        INTEGER DEFAULT 10
)
RETURNS TABLE(
    id               BIGINT,
    document_number  VARCHAR,
    first_name       VARCHAR,
    last_name        VARCHAR,
    -- origen: donde esta hoy
    institution      VARCHAR,
    campus           VARCHAR,
    shift            VARCHAR,
    education_level  TEXT,
    grade            INTEGER,
    grupo            VARCHAR,
    -- destino: a donde aspira
    target_grade     INTEGER,
    failed           BOOLEAN,
    status           TEXT,
    total_count      BIGINT
)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_col   TEXT;
    v_dir   TEXT;
    v_grp   TEXT;
    v_order TEXT;
BEGIN
    -- Capability del modulo. Va antes de resolver nada: quien no tiene el
    -- permiso recibe 42501, no una lista vacia.
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario, 'PRE_MATRICULA', 'VER');

    -- Lista blanca de ordenamiento. A la izquierda, el nombre que manda el
    -- front (la columna de la tabla); a la derecha, el alias real.
    v_col := CASE lower(coalesce(p_sort_by, ''))
        WHEN 'documentnumber' THEN 'document_number'
        WHEN 'firstname'      THEN 'first_name'
        WHEN 'lastname'       THEN 'last_name'
        WHEN 'institution'    THEN 'institution'
        WHEN 'campus'         THEN 'campus'
        WHEN 'shift'          THEN 'shift'
        WHEN 'educationlevel' THEN 'education_level'
        WHEN 'grade'          THEN 'grade'
        WHEN 'group'          THEN 'grupo'
        WHEN 'targetgrade'    THEN 'target_grade'
        WHEN 'status'         THEN 'status'
        ELSE 'last_name'
    END;
    v_dir := CASE WHEN lower(coalesce(p_sort_dir, '')) = 'desc' THEN 'DESC' ELSE 'ASC' END;

    -- "Agrupar por": no filtra, solo antepone esa dimension al orden para
    -- que las filas que la comparten queden juntas antes de paginar.
    v_grp := CASE lower(coalesce(p_group_by, ''))
        WHEN 'institution'    THEN 'institution'
        WHEN 'campus'         THEN 'campus'
        WHEN 'grade'          THEN 'grade'
        WHEN 'group'          THEN 'grupo'
        WHEN 'shift'          THEN 'shift'
        WHEN 'educationlevel' THEN 'education_level'
        ELSE NULL
    END;

    v_order := CASE WHEN v_grp IS NULL
                    THEN format('%I %s, id', v_col, v_dir)
                    ELSE format('%I ASC NULLS LAST, %I %s, id', v_grp, v_col, v_dir)
               END;

    RETURN QUERY EXECUTE format($q$
        SELECT *, count(*) OVER()::BIGINT AS total_count FROM (
        SELECT * FROM (
            SELECT
                pm.PK_TPREMATRICULA AS id,
                u.IDENTIFICACION    AS document_number,
                u.PRIMER_NOMBRE     AS first_name,
                u.PRIMER_APELLIDO   AS last_name,

                -- ORIGEN: la matricula activa mas reciente del estudiante.
                o.institution,
                o.campus,
                o.shift,
                o.education_level,
                o.grade,
                o.grupo,

                -- DESTINO: el grupo tentativo de la prematricula.
                NULLIF(gd.CODIGO, '')::INT AS target_grade,

                -- Reprobado en la matricula de origen: el front lo usa para
                -- decidir que repite grado en vez de avanzar.
                COALESCE(o.estado_valor = '3', FALSE) AS failed,

                CASE WHEN grd.CAPACIDAD IS NOT NULL
                       AND academico_test.fn_matricula_cupo_ocupado(grd.PK_TGRUPO) < grd.CAPACIDAD
                     THEN 'con_cupo' ELSE 'sin_cupo' END::TEXT AS status

              FROM academico_test.TPREMATRICULA pm

              JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = pm.FK_TESTUDIANTE AND es.ACTIVE = TRUE
              JOIN academico_test.TUSUARIO u     ON u.PK_TUSUARIO = es.FK_TUSUARIO

              -- grupo DESTINO y su cadena hasta el periodo academico
              JOIN academico_test.TGRUPO grd     ON grd.PK_TGRUPO = pm.FK_TGRUPO AND grd.ACTIVE = TRUE
              JOIN academico_test.TGRADO gd      ON gd.PK_TGRADO = grd.FK_TGRADO AND gd.ACTIVE = TRUE
              JOIN academico_test.TPERIODO_ACADEMICO pad ON pad.PK_TPERIODO_ACADEMICO = gd.FK_TPERIODO_ACADEMICO

              -- ORIGEN: no hay FK entre prematricula y matricula, asi que se
              -- toma la activa mas reciente del estudiante.
              LEFT JOIN LATERAL (
                    SELECT est.NOMBRE  AS institution,
                           sd.NOMBRE   AS campus,
                           jor.NOMBRE  AS shift,
                           CASE ne.CODIGO
                               WHEN '1' THEN 'PREESCOLAR'
                               WHEN '2' THEN 'BASICA_PRIMARIA'
                               WHEN '3' THEN 'BASICA_SECUNDARIA'
                               WHEN '4' THEN 'MEDIA'
                           END         AS education_level,
                           NULLIF(g.CODIGO, '')::INT AS grade,
                           gr.NOMBRE   AS grupo,
                           em.VALOR    AS estado_valor
                      FROM academico_test.TMATRICULA m
                      JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = m.FK_TGRUPO
                      JOIN academico_test.TGRADO g  ON g.PK_TGRADO = gr.FK_TGRADO
                      JOIN academico_test.TNIVEL_ENSENANZA ne ON ne.PK_NIVEL_ENSENANZA = g.FK_TNIVEL_ENSENANZA
                      JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
                      JOIN academico_test.TSEDE sd  ON sd.PK_TSEDE = pa.FK_TSEDE
                      JOIN academico_test.TESTABLECIMIENTO est ON est.PK_ESTABLECIMIENTO = sd.FK_TESTABLECIMIENTO
                      JOIN academico_test.TLISTA_VALOR jor ON jor.PK_LISTA_VALOR = gr.FK_TLV_JORNADA
                      JOIN academico_test.TLISTA_VALOR em  ON em.PK_LISTA_VALOR = m.FK_TLV_ESTADO_MATRICULA
                     WHERE m.FK_TESTUDIANTE = pm.FK_TESTUDIANTE
                       AND m.ACTIVE = TRUE
                     ORDER BY m.PK_TMATRICULA DESC
                     LIMIT 1
              ) o ON TRUE

             WHERE pm.ACTIVE = TRUE
               -- Alcance: el periodo academico del grupo DESTINO.
               AND academico_test.fn_periodo_usuario_puede_ver($16, pad.PK_TPERIODO_ACADEMICO)

               AND ($1 IS NULL OR (
                       u.IDENTIFICACION   ILIKE '%%' || $1 || '%%' OR
                       u.PRIMER_NOMBRE    ILIKE '%%' || $1 || '%%' OR
                       u.SEGUNDO_NOMBRE   ILIKE '%%' || $1 || '%%' OR
                       u.PRIMER_APELLIDO  ILIKE '%%' || $1 || '%%' OR
                       u.SEGUNDO_APELLIDO ILIKE '%%' || $1 || '%%'
                   ))
               AND ($2 IS NULL OR u.PRIMER_NOMBRE   ILIKE '%%' || $2 || '%%')
               AND ($3 IS NULL OR u.PRIMER_APELLIDO ILIKE '%%' || $3 || '%%')
               AND ($4 IS NULL OR u.IDENTIFICACION  ILIKE '%%' || $4 || '%%')
               AND ($12 IS NULL OR pm.CREATED_AT::DATE >= $12)
               AND ($13 IS NULL OR pm.CREATED_AT::DATE <= $13)
        ) q
        -- Filtros sobre columnas ya derivadas (origen y status). Van en un
        -- nivel aparte porque un alias del SELECT no es visible en el WHERE
        -- de su mismo nivel, y total_count debe contarlos tambien.
        WHERE ($5  IS NULL OR q.institution = $5)
          AND ($6  IS NULL OR q.campus = $6)
          AND ($7  IS NULL OR q.grade = $7)
          AND ($8  IS NULL OR q.grupo = $8)
          AND ($9  IS NULL OR CARDINALITY($9)  = 0 OR
               q.shift = ANY($9) OR
               TRANSLATE(UPPER(q.shift), 'ÁÉÍÓÚÑ', 'AEIOUN') = ANY(
                   SELECT TRANSLATE(UPPER(s), 'ÁÉÍÓÚÑ', 'AEIOUN') FROM UNNEST($9) s))
          AND ($10 IS NULL OR CARDINALITY($10) = 0 OR q.education_level = ANY($10))
          AND ($11 IS NULL OR CARDINALITY($11) = 0 OR q.status = ANY($11))
        ) qs
        ORDER BY %s
        LIMIT NULLIF($15, 0)
       OFFSET COALESCE($14, 0) * COALESCE(NULLIF($15, 0), 0)
    $q$, v_order)
    USING NULLIF(TRIM(p_search), ''),
          NULLIF(TRIM(p_first_name), ''),
          NULLIF(TRIM(p_last_name), ''),
          NULLIF(TRIM(p_document_number), ''),
          NULLIF(TRIM(p_institution), ''),
          NULLIF(TRIM(p_campus), ''),
          p_grade,
          NULLIF(TRIM(p_group), ''),
          p_shifts,
          p_levels,
          p_statuses,
          p_created_from,
          p_created_to,
          p_page_index,
          p_page_size,
          p_pk_usuario;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_prematricula_listar(BIGINT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER, TEXT, TEXT[], TEXT[], TEXT[], DATE, DATE, TEXT, TEXT, TEXT, INTEGER, INTEGER)
    IS 'Listado paginado de TPREMATRICULA (estudiantes ANTIGUOS que cambian de grado; los NUEVOS van por TRESERVA_CUPO -> TINSCRIPCION y no se listan aqui). Devuelve SOLO lo que pinta la tabla: las columnas ID / Nombres / Apellidos / Sede / Grado / Grado al que aspira / Estado, mas failed (la celda del grado al que aspira lo necesita para saber si repite) y las dimensiones de "Agrupar por" que no son columnas (institution, shift, education_level, grupo), sin las cuales el front no puede rotular los grupos que p_group_by arma. El detalle de una fila es fn_prematricula_buscar_por_pk (V351), como en los demas modulos. Cada fila mezcla dos ubicaciones: el ORIGEN (institution/campus/shift/education_level/grade/grupo) sale de la matricula ACTIVA mas reciente del estudiante, porque no hay FK entre prematricula y matricula; el DESTINO (target_grade, status) sale del FK_TGRUPO de la prematricula, el "grupo tentativo del nuevo grado" segun la DDL de V22. failed = la matricula de origen esta en Reprobado (VALOR 3); el front lo usa para pintar que repite grado, esta funcion devuelve siempre el grado crudo del destino. status compara TGRUPO.CAPACIDAD del destino contra fn_matricula_cupo_ocupado (V145, solo Cursando/Aprobado/Reprobado): con_cupo / sin_cupo. El tercer valor que admite el tipo del front, pendiente, NO se emite: no hay regla de negocio que lo defina, el mock tampoco lo produce y todos los grupos activos tienen capacidad. Permisos: capability por el menu PRE_MATRICULA y, por fila, alcance sobre el periodo academico del grupo destino (fn_periodo_usuario_puede_ver), igual que fn_matricula_listar. Paginacion y ordenamiento con la misma forma que fn_matricula_listar: SQL dinamico con lista blanca de columnas, total_count por count(*) OVER() y LIMIT/OFFSET por pageIndex/pageSize; p_group_by no filtra, solo antepone esa dimension al ORDER BY. p_created_from/p_created_to filtran por CREATED_AT de la prematricula (en el front ese control se llama reservedFrom/reservedTo porque la vista reusa el formulario de reservas). Las jornadas se comparan sin tildes y en mayuscula para que el MANANA del front case con el Mañana del catalogo.';
