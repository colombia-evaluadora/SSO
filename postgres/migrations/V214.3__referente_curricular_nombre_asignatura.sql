-- ===========================================================================
-- V214.3 -- TREFERENTE_CURRICULAR.NOMBRE_ASIGNATURA
-- ===========================================================================
-- Numeracion: out-of-order deliberado. La familia de referentes curriculares
-- vive en V212 (schema) / V213 (CRUD) / V214 (filas de public.query), y
-- V214.1 / V214.2 ya estaban ocupadas; V214.3 es el primer hueco libre que
-- deja el cambio pegado a lo que modifica en vez de a 190 versiones de
-- distancia. deploy.yml ya migra con `-outOfOrder=true` (ver deploy.yml:479).
--
-- QUE HACE
--   1. Agrega NOMBRE_ASIGNATURA VARCHAR(150) NOT NULL a TREFERENTE_CURRICULAR.
--      Es el rotulo con el que se llamara la asignatura en las pantallas que
--      consumen el referente (planeador, asistencias, periodos).
--   2. Rehace fn_refcurr_crear / fn_refcurr_actualizar (nuevo parametro) y
--      fn_refcurr_listar / fn_refcurr_buscar_por_pk (nueva columna en el
--      RETURNS TABLE). Las cuatro cambian de FIRMA o de tipo de retorno, asi
--      que van con DROP + CREATE (no basta CREATE OR REPLACE) -- mismo patron
--      que V213 uso con fn_refcurr_buscar_por_pk.
--   3. Agrega fn_refcurr_nombre_asignatura: resuelve el nombre de UNA
--      asignatura para el usuario que pregunta, gateada por capability de
--      menu (PLANEADOR / ASISTENCIAS / PERIODOS_ACADEMICOS).
--   4. Reconcilia las filas de public.query de crear/actualizar (el
--      ON CONFLICT DO UPDATE de V214 no se reejecuta) y agrega la fila del
--      endpoint nuevo.
--
-- BACKFILL
--   La columna es NOT NULL sobre una tabla que ya puede tener filas: se
--   agrega NULLable, se rellena con NOMBRE (el unico valor sensato que
--   tenemos) y recien ahi se pone NOT NULL. Idempotente.
--
-- AUDITORIA
--   No hace falta tocar el trigger de CDC: TREFERENTE_CURRICULAR ya existia
--   cuando se le colgo el trigger, y una columna nueva viaja sola.
-- ===========================================================================

SET search_path TO academico_test, public;

-- ---------------------------------------------------------------------------
-- 1) DDL
-- ---------------------------------------------------------------------------
ALTER TABLE academico_test.TREFERENTE_CURRICULAR
  ADD COLUMN IF NOT EXISTS NOMBRE_ASIGNATURA VARCHAR(150);

UPDATE academico_test.TREFERENTE_CURRICULAR
   SET NOMBRE_ASIGNATURA = NOMBRE
 WHERE NOMBRE_ASIGNATURA IS NULL;

ALTER TABLE academico_test.TREFERENTE_CURRICULAR
  ALTER COLUMN NOMBRE_ASIGNATURA SET NOT NULL;

COMMENT ON COLUMN academico_test.TREFERENTE_CURRICULAR.NOMBRE_ASIGNATURA
    IS 'V214.3 -- Nombre con el que se rotula la asignatura de este referente en las pantallas que lo consumen (planeador, asistencias, periodos academicos). Obligatorio. Backfill inicial = NOMBRE del referente.';

-- ---------------------------------------------------------------------------
-- 2) fn_refcurr_crear -- nuevo parametro obligatorio p_nombre_asignatura.
--    Cambia la firma: hay que borrar la vieja (si no, las dos conviven y
--    una llamada con argumentos nombrados queda ambigua -> 42725).
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_refcurr_crear(
    BIGINT, VARCHAR, VARCHAR, BIGINT[], BIGINT, BIGINT, VARCHAR, VARCHAR,
    INTEGER, VARCHAR, VARCHAR, VARCHAR, INTEGER, VARCHAR, BIGINT[]);
DROP FUNCTION IF EXISTS academico_test.fn_refcurr_crear(
    BIGINT, VARCHAR, VARCHAR, BIGINT[], BIGINT, BIGINT, VARCHAR, VARCHAR,
    INTEGER, VARCHAR, VARCHAR, VARCHAR, INTEGER, VARCHAR, BIGINT[], VARCHAR);

CREATE OR REPLACE FUNCTION academico_test.fn_refcurr_crear(
    p_pk_usuario_solicitante        BIGINT,
    p_nombre                        VARCHAR(150),
    p_descripcion                   VARCHAR(400),
    p_fk_tnivel_ensenanza_ids       BIGINT[],
    p_fk_tlv_enfoque_pedagogico     BIGINT,
    p_fk_tlv_tipo_evaluacion        BIGINT,
    p_instrumento                   VARCHAR(400),
    p_normatividad                  VARCHAR(400),
    p_anio_vigencia_desde           INTEGER,
    p_nivel_1_etiqueta              VARCHAR(60)  DEFAULT 'Enunciado',
    p_nivel_2_etiqueta              VARCHAR(60)  DEFAULT 'Evidencia',
    p_instrumento_info_adicional    VARCHAR(400) DEFAULT NULL,
    p_anio_vigencia_hasta           INTEGER     DEFAULT NULL,
    p_estado                        VARCHAR(1)   DEFAULT 'A',
    p_fk_tarea_asignatura_ids       BIGINT[]     DEFAULT NULL,
    -- V214.3 -- obligatorio de negocio; va al final con DEFAULT NULL para no
    -- reordenar la firma, y se valida como obligatorio en el cuerpo.
    p_nombre_asignatura             VARCHAR(150) DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_id_creado  BIGINT;
BEGIN
    -- 0. Gate: capability CREAR sobre REFERENTES_CURRICULARES (sin scope,
    --    catalogo global).
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'REFERENTES_CURRICULARES', 'CREAR'
    );

    -- 1. Obligatorios reales.
    IF NULLIF(TRIM(p_nombre), '') IS NULL THEN
        RAISE EXCEPTION 'Nombre del referente es obligatorio'
            USING ERRCODE = '22023', HINT = 'p_nombre no puede ser NULL ni vacio';
    END IF;
    IF NULLIF(TRIM(p_descripcion), '') IS NULL THEN
        RAISE EXCEPTION 'Descripcion/finalidad es obligatoria'
            USING ERRCODE = '22023', HINT = 'p_descripcion no puede ser NULL ni vacio';
    END IF;
    IF NULLIF(TRIM(p_nombre_asignatura), '') IS NULL THEN
        RAISE EXCEPTION 'Nombre de la asignatura es obligatorio'
            USING ERRCODE = '22023', HINT = 'p_nombre_asignatura no puede ser NULL ni vacio';
    END IF;
    -- Nivel educativo: N:N, pero al menos UNO (el formulario lo exige y la
    -- tabla puente no puede quedar vacia -- ver nota en V212).
    IF p_fk_tnivel_ensenanza_ids IS NULL
       OR COALESCE(array_length(p_fk_tnivel_ensenanza_ids, 1), 0) = 0 THEN
        RAISE EXCEPTION 'Debe indicar al menos un nivel educativo'
            USING ERRCODE = '22023', HINT = 'p_fk_tnivel_ensenanza_ids no puede ser NULL ni un array vacio';
    END IF;
    IF EXISTS (SELECT 1 FROM unnest(p_fk_tnivel_ensenanza_ids) n WHERE n IS NULL) THEN
        RAISE EXCEPTION 'La lista de niveles educativos no puede contener valores nulos'
            USING ERRCODE = '22023';
    END IF;
    IF p_fk_tlv_enfoque_pedagogico IS NULL THEN
        RAISE EXCEPTION 'Enfoque pedagogico es obligatorio'
            USING ERRCODE = '22023';
    END IF;
    IF p_fk_tlv_tipo_evaluacion IS NULL THEN
        RAISE EXCEPTION 'Tipo de evaluacion es obligatorio'
            USING ERRCODE = '22023';
    END IF;
    IF NULLIF(TRIM(p_instrumento), '') IS NULL THEN
        RAISE EXCEPTION 'Instrumento es obligatorio'
            USING ERRCODE = '22023';
    END IF;
    IF NULLIF(TRIM(p_normatividad), '') IS NULL THEN
        RAISE EXCEPTION 'Normatividad es obligatoria'
            USING ERRCODE = '22023';
    END IF;
    IF p_anio_vigencia_desde IS NULL THEN
        RAISE EXCEPTION 'Anio de vigencia (desde) es obligatorio'
            USING ERRCODE = '22023';
    END IF;
    IF p_anio_vigencia_hasta IS NOT NULL AND p_anio_vigencia_hasta < p_anio_vigencia_desde THEN
        RAISE EXCEPTION 'El anio de vigencia hasta (%) no puede ser anterior al anio desde (%)',
            p_anio_vigencia_hasta, p_anio_vigencia_desde
            USING ERRCODE = '22023';
    END IF;
    IF UPPER(TRIM(COALESCE(p_estado, ''))) NOT IN ('A', 'I') THEN
        RAISE EXCEPTION 'Estado invalido: % (use ''A'' o ''I'')', p_estado
            USING ERRCODE = '22023';
    END IF;

    -- 2. FKs existen y activas.
    IF EXISTS (
        SELECT 1 FROM unnest(p_fk_tnivel_ensenanza_ids) ne_id
         WHERE NOT EXISTS (
             SELECT 1 FROM academico_test.TNIVEL_ENSENANZA ne
              WHERE ne.PK_NIVEL_ENSENANZA = ne_id AND ne.ACTIVE = TRUE
         )
    ) THEN
        RAISE EXCEPTION 'Uno o mas niveles educativos (TNIVEL_ENSENANZA) no existen o no estan activos'
            USING ERRCODE = '23503';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_fk_tlv_enfoque_pedagogico AND CATEGORIA = 'ENFOQUE_PEDAGOGICO' AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'FK_TLV_ENFOQUE_PEDAGOGICO (%) no existe, no esta activo o no es de la categoria ENFOQUE_PEDAGOGICO', p_fk_tlv_enfoque_pedagogico
            USING ERRCODE = '23503';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_fk_tlv_tipo_evaluacion AND CATEGORIA = 'TIPO_EVALUACION' AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'FK_TLV_TIPO_EVALUACION (%) no existe, no esta activo o no es de la categoria TIPO_EVALUACION', p_fk_tlv_tipo_evaluacion
            USING ERRCODE = '23503';
    END IF;

    -- 3. Unicidad de nombre entre activos, POR NIVEL (chequeo a nivel de
    --    funcion, mismo criterio que TESTABLECIMIENTO/TSEDE en V52/V53). NO
    --    es solo por NOMBRE: dos referentes distintos pueden compartir
    --    nombre si no comparten ningun nivel educativo (p.ej. "DBA" para
    --    Basica primaria y "DBA" para Basica secundaria). Con la relacion
    --    N:N eso se traduce en: choca si ya hay un referente activo con el
    --    mismo nombre cuyo set de niveles se SOLAPA con el que se pide.
    IF EXISTS (
        SELECT 1
          FROM academico_test.TREFERENTE_CURRICULAR rc
          JOIN academico_test.TREFERENTE_CURRICULAR_NIVEL rcn
            ON rcn.FK_REFERENTE_CURRICULAR = rc.PK_REFERENTE_CURRICULAR
           AND rcn.ACTIVE = TRUE
         WHERE UPPER(TRIM(rc.NOMBRE)) = UPPER(TRIM(p_nombre))
           AND rc.ACTIVE = TRUE
           AND rcn.FK_TNIVEL_ENSENANZA = ANY(p_fk_tnivel_ensenanza_ids)
    ) THEN
        RAISE EXCEPTION 'Ya existe un referente curricular activo con el nombre "%" para al menos uno de esos niveles educativos', p_nombre
            USING ERRCODE = '23505';
    END IF;

    -- 4. INSERT.
    INSERT INTO academico_test.TREFERENTE_CURRICULAR (
        NOMBRE, NOMBRE_ASIGNATURA, DESCRIPCION, FK_TLV_ENFOQUE_PEDAGOGICO,
        FK_TLV_TIPO_EVALUACION, NIVEL_1_ETIQUETA, NIVEL_2_ETIQUETA, INSTRUMENTO,
        INSTRUMENTO_INFO_ADICIONAL, NORMATIVIDAD, ANIO_VIGENCIA_DESDE,
        ANIO_VIGENCIA_HASTA, ESTADO, CREATED_BY, CREATED_AT, ACTIVE
    ) VALUES (
        p_nombre, TRIM(p_nombre_asignatura), p_descripcion, p_fk_tlv_enfoque_pedagogico,
        p_fk_tlv_tipo_evaluacion,
        COALESCE(NULLIF(TRIM(p_nivel_1_etiqueta), ''), 'Enunciado'),
        COALESCE(NULLIF(TRIM(p_nivel_2_etiqueta), ''), 'Evidencia'),
        p_instrumento, p_instrumento_info_adicional, p_normatividad,
        p_anio_vigencia_desde, p_anio_vigencia_hasta, UPPER(TRIM(p_estado)),
        p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
    )
    RETURNING PK_REFERENTE_CURRICULAR INTO v_id_creado;

    -- 5. Niveles educativos (N:N, al menos uno -- ya validado arriba).
    INSERT INTO academico_test.TREFERENTE_CURRICULAR_NIVEL (
        FK_REFERENTE_CURRICULAR, FK_TNIVEL_ENSENANZA, CREATED_BY, CREATED_AT, ACTIVE
    )
    SELECT DISTINCT v_id_creado, ne_id, p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
      FROM unnest(p_fk_tnivel_ensenanza_ids) ne_id;

    -- 6. Areas/dimensiones iniciales (opcional -- vacio/NULL = aplica a todas).
    IF p_fk_tarea_asignatura_ids IS NOT NULL AND array_length(p_fk_tarea_asignatura_ids, 1) > 0 THEN
        IF EXISTS (
            SELECT 1 FROM unnest(p_fk_tarea_asignatura_ids) ta_id
             WHERE NOT EXISTS (
                 SELECT 1 FROM academico_test.TAREA_ASIGNATURA ta
                  WHERE ta.PK_TAREA_ASIGNATURA = ta_id AND ta.ACTIVE = TRUE
             )
        ) THEN
            RAISE EXCEPTION 'Una o mas areas/dimensiones (TAREA_ASIGNATURA) no existen o no estan activas'
                USING ERRCODE = '23503';
        END IF;

        INSERT INTO academico_test.TREFERENTE_CURRICULAR_AREA (
            FK_REFERENTE_CURRICULAR, FK_TAREA_ASIGNATURA, CREATED_BY, CREATED_AT, ACTIVE
        )
        SELECT DISTINCT v_id_creado, ta_id, p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
          FROM unnest(p_fk_tarea_asignatura_ids) ta_id;
    END IF;

    RETURN v_id_creado;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_refcurr_crear(BIGINT, VARCHAR, VARCHAR, BIGINT[], BIGINT, BIGINT, VARCHAR, VARCHAR, INTEGER, VARCHAR, VARCHAR, VARCHAR, INTEGER, VARCHAR, BIGINT[], VARCHAR)
    IS 'V214.3 -- == V213 mas p_nombre_asignatura, obligatorio de negocio (22023 si falta o viene vacio) aunque en la firma lleve DEFAULT NULL para no reordenar los parametros existentes. Gate CREAR sobre REFERENTES_CURRICULARES.';

-- ---------------------------------------------------------------------------
-- 3) fn_refcurr_actualizar -- p_nombre_asignatura opcional (NULL = no tocar).
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_refcurr_actualizar(
    BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT[], BIGINT, BIGINT, VARCHAR,
    VARCHAR, VARCHAR, VARCHAR, VARCHAR, INTEGER, INTEGER, VARCHAR, BIGINT[]);
DROP FUNCTION IF EXISTS academico_test.fn_refcurr_actualizar(
    BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT[], BIGINT, BIGINT, VARCHAR,
    VARCHAR, VARCHAR, VARCHAR, VARCHAR, INTEGER, INTEGER, VARCHAR, BIGINT[], VARCHAR);

CREATE OR REPLACE FUNCTION academico_test.fn_refcurr_actualizar(
    p_pk_usuario_solicitante        BIGINT,
    p_pk_referente_curricular       BIGINT,
    p_nombre                        VARCHAR(150) DEFAULT NULL,
    p_descripcion                   VARCHAR(400) DEFAULT NULL,
    -- NULL = no tocar los niveles; array = reemplazo completo del set
    -- (nunca vacio: el referente siempre tiene al menos un nivel).
    p_fk_tnivel_ensenanza_ids       BIGINT[]     DEFAULT NULL,
    p_fk_tlv_enfoque_pedagogico     BIGINT       DEFAULT NULL,
    p_fk_tlv_tipo_evaluacion        BIGINT       DEFAULT NULL,
    p_nivel_1_etiqueta              VARCHAR(60)  DEFAULT NULL,
    p_nivel_2_etiqueta              VARCHAR(60)  DEFAULT NULL,
    p_instrumento                   VARCHAR(400) DEFAULT NULL,
    p_instrumento_info_adicional    VARCHAR(400) DEFAULT NULL,
    p_normatividad                  VARCHAR(400) DEFAULT NULL,
    p_anio_vigencia_desde           INTEGER     DEFAULT NULL,
    p_anio_vigencia_hasta           INTEGER     DEFAULT NULL,
    p_estado                        VARCHAR(1)   DEFAULT NULL,
    -- NULL = no tocar areas; ARRAY[]::BIGINT[] = vaciarlas (aplica a todas).
    p_fk_tarea_asignatura_ids       BIGINT[]     DEFAULT NULL,
    -- V214.3 -- NULL = no tocar; cadena vacia = 22023 (la columna es NOT NULL).
    p_nombre_asignatura             VARCHAR(150) DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_actual         academico_test.TREFERENTE_CURRICULAR%ROWTYPE;
    v_nuevo_desde    INTEGER;
    v_nuevo_hasta    INTEGER;
    v_nuevo_nombre   VARCHAR;
    v_niveles_efect  BIGINT[];
BEGIN
    SELECT * INTO v_actual
      FROM academico_test.TREFERENTE_CURRICULAR
     WHERE PK_REFERENTE_CURRICULAR = p_pk_referente_curricular;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el referente curricular solicitado'
            USING ERRCODE = 'P0002';
    END IF;

    -- Gate: capability EDITAR (catalogo global, sin scope).
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'REFERENTES_CURRICULARES', 'EDITAR'
    );

    IF v_actual.ACTIVE = FALSE THEN
        RAISE EXCEPTION 'El referente curricular "%" esta inactivo (borrado logico); no se puede editar', v_actual.NOMBRE
            USING ERRCODE = '22023';
    END IF;

    IF p_nombre IS NOT NULL AND NULLIF(TRIM(p_nombre), '') IS NULL THEN
        RAISE EXCEPTION 'Nombre del referente no puede quedar vacio' USING ERRCODE = '22023';
    END IF;

    IF p_nombre_asignatura IS NOT NULL AND NULLIF(TRIM(p_nombre_asignatura), '') IS NULL THEN
        RAISE EXCEPTION 'Nombre de la asignatura no puede quedar vacio' USING ERRCODE = '22023';
    END IF;

    -- Niveles educativos EFECTIVOS: los que llegan en el PATCH, o los que
    -- el referente ya tiene si el parametro no viene. Un array vacio no es
    -- "vaciar" (a diferencia de las areas): el nivel es obligatorio.
    IF p_fk_tnivel_ensenanza_ids IS NOT NULL THEN
        IF COALESCE(array_length(p_fk_tnivel_ensenanza_ids, 1), 0) = 0 THEN
            RAISE EXCEPTION 'El referente debe conservar al menos un nivel educativo'
                USING ERRCODE = '22023', HINT = 'omita p_fk_tnivel_ensenanza_ids para no tocar los niveles actuales';
        END IF;
        IF EXISTS (SELECT 1 FROM unnest(p_fk_tnivel_ensenanza_ids) n WHERE n IS NULL) THEN
            RAISE EXCEPTION 'La lista de niveles educativos no puede contener valores nulos'
                USING ERRCODE = '22023';
        END IF;
        IF EXISTS (
            SELECT 1 FROM unnest(p_fk_tnivel_ensenanza_ids) ne_id
             WHERE NOT EXISTS (
                 SELECT 1 FROM academico_test.TNIVEL_ENSENANZA ne
                  WHERE ne.PK_NIVEL_ENSENANZA = ne_id AND ne.ACTIVE = TRUE
             )
        ) THEN
            RAISE EXCEPTION 'Uno o mas niveles educativos (TNIVEL_ENSENANZA) no existen o no estan activos'
                USING ERRCODE = '23503';
        END IF;
        v_niveles_efect := p_fk_tnivel_ensenanza_ids;
    ELSE
        SELECT array_agg(rcn.FK_TNIVEL_ENSENANZA) INTO v_niveles_efect
          FROM academico_test.TREFERENTE_CURRICULAR_NIVEL rcn
         WHERE rcn.FK_REFERENTE_CURRICULAR = p_pk_referente_curricular
           AND rcn.ACTIVE = TRUE;
    END IF;

    -- Unicidad de nombre entre activos POR NIVEL, igual que en
    -- fn_refcurr_crear: choca si otro referente activo lleva el mismo
    -- nombre y comparte al menos uno de los niveles efectivos.
    v_nuevo_nombre := COALESCE(p_nombre, v_actual.NOMBRE);
    IF v_niveles_efect IS NOT NULL AND EXISTS (
        SELECT 1
          FROM academico_test.TREFERENTE_CURRICULAR rc
          JOIN academico_test.TREFERENTE_CURRICULAR_NIVEL rcn
            ON rcn.FK_REFERENTE_CURRICULAR = rc.PK_REFERENTE_CURRICULAR
           AND rcn.ACTIVE = TRUE
         WHERE UPPER(TRIM(rc.NOMBRE)) = UPPER(TRIM(v_nuevo_nombre))
           AND rc.ACTIVE = TRUE
           AND rc.PK_REFERENTE_CURRICULAR <> p_pk_referente_curricular
           AND rcn.FK_TNIVEL_ENSENANZA = ANY(v_niveles_efect)
    ) THEN
        RAISE EXCEPTION 'Ya existe otro referente curricular activo con el nombre "%" para al menos uno de esos niveles educativos', v_nuevo_nombre
            USING ERRCODE = '23505';
    END IF;
    IF p_fk_tlv_enfoque_pedagogico IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_fk_tlv_enfoque_pedagogico AND CATEGORIA = 'ENFOQUE_PEDAGOGICO' AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'FK_TLV_ENFOQUE_PEDAGOGICO (%) no existe, no esta activo o no es de la categoria ENFOQUE_PEDAGOGICO', p_fk_tlv_enfoque_pedagogico USING ERRCODE = '23503';
    END IF;
    IF p_fk_tlv_tipo_evaluacion IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_fk_tlv_tipo_evaluacion AND CATEGORIA = 'TIPO_EVALUACION' AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'FK_TLV_TIPO_EVALUACION (%) no existe, no esta activo o no es de la categoria TIPO_EVALUACION', p_fk_tlv_tipo_evaluacion USING ERRCODE = '23503';
    END IF;
    IF p_estado IS NOT NULL AND UPPER(TRIM(p_estado)) NOT IN ('A', 'I') THEN
        RAISE EXCEPTION 'Estado invalido: % (use ''A'' o ''I'')', p_estado USING ERRCODE = '22023';
    END IF;

    v_nuevo_desde := COALESCE(p_anio_vigencia_desde, v_actual.ANIO_VIGENCIA_DESDE);
    v_nuevo_hasta := COALESCE(p_anio_vigencia_hasta, v_actual.ANIO_VIGENCIA_HASTA);
    IF v_nuevo_hasta IS NOT NULL AND v_nuevo_hasta < v_nuevo_desde THEN
        RAISE EXCEPTION 'El anio de vigencia hasta (%) no puede ser anterior al anio desde (%)', v_nuevo_hasta, v_nuevo_desde
            USING ERRCODE = '22023';
    END IF;

    UPDATE academico_test.TREFERENTE_CURRICULAR
       SET NOMBRE                       = COALESCE(p_nombre, NOMBRE),
           NOMBRE_ASIGNATURA            = COALESCE(NULLIF(TRIM(p_nombre_asignatura), ''), NOMBRE_ASIGNATURA),
           DESCRIPCION                  = COALESCE(p_descripcion, DESCRIPCION),
           FK_TLV_ENFOQUE_PEDAGOGICO    = COALESCE(p_fk_tlv_enfoque_pedagogico, FK_TLV_ENFOQUE_PEDAGOGICO),
           FK_TLV_TIPO_EVALUACION       = COALESCE(p_fk_tlv_tipo_evaluacion, FK_TLV_TIPO_EVALUACION),
           NIVEL_1_ETIQUETA             = COALESCE(NULLIF(TRIM(p_nivel_1_etiqueta), ''), NIVEL_1_ETIQUETA),
           NIVEL_2_ETIQUETA             = COALESCE(NULLIF(TRIM(p_nivel_2_etiqueta), ''), NIVEL_2_ETIQUETA),
           INSTRUMENTO                  = COALESCE(p_instrumento, INSTRUMENTO),
           INSTRUMENTO_INFO_ADICIONAL   = COALESCE(p_instrumento_info_adicional, INSTRUMENTO_INFO_ADICIONAL),
           NORMATIVIDAD                 = COALESCE(p_normatividad, NORMATIVIDAD),
           ANIO_VIGENCIA_DESDE          = v_nuevo_desde,
           ANIO_VIGENCIA_HASTA          = v_nuevo_hasta,
           ESTADO                       = COALESCE(UPPER(TRIM(p_estado)), ESTADO),
           MODIFIED_BY                  = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT                  = CURRENT_TIMESTAMP
     WHERE PK_REFERENTE_CURRICULAR = p_pk_referente_curricular;

    -- Reemplazo completo de niveles educativos, solo si el caller mando el
    -- parametro (ya validado arriba: no nulo, no vacio, todos activos).
    IF p_fk_tnivel_ensenanza_ids IS NOT NULL THEN
        UPDATE academico_test.TREFERENTE_CURRICULAR_NIVEL
           SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_REFERENTE_CURRICULAR = p_pk_referente_curricular
           AND ACTIVE = TRUE
           AND NOT (FK_TNIVEL_ENSENANZA = ANY(p_fk_tnivel_ensenanza_ids));

        INSERT INTO academico_test.TREFERENTE_CURRICULAR_NIVEL (
            FK_REFERENTE_CURRICULAR, FK_TNIVEL_ENSENANZA, CREATED_BY, CREATED_AT, ACTIVE
        )
        SELECT DISTINCT p_pk_referente_curricular, ne_id, p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
          FROM unnest(p_fk_tnivel_ensenanza_ids) ne_id
         WHERE NOT EXISTS (
             SELECT 1 FROM academico_test.TREFERENTE_CURRICULAR_NIVEL rcn
              WHERE rcn.FK_REFERENTE_CURRICULAR = p_pk_referente_curricular
                AND rcn.FK_TNIVEL_ENSENANZA = ne_id
                AND rcn.ACTIVE = TRUE
         );
    END IF;

    -- Reemplazo completo de areas, solo si el caller mando el parametro.
    IF p_fk_tarea_asignatura_ids IS NOT NULL THEN
        -- Bloquea quitar un area que todavia tiene enunciados amarrados.
        IF EXISTS (
            SELECT 1
              FROM academico_test.TREFERENTE_CURRICULAR_AREA rca
              JOIN academico_test.TREFERENTE_ENUNCIADO re
                ON re.FK_REFERENTE_CURRICULAR_AREA = rca.PK_REFERENTE_CURRICULAR_AREA
               AND re.ACTIVE = TRUE
             WHERE rca.FK_REFERENTE_CURRICULAR = p_pk_referente_curricular
               AND rca.ACTIVE = TRUE
               AND NOT (rca.FK_TAREA_ASIGNATURA = ANY(p_fk_tarea_asignatura_ids))
        ) THEN
            RAISE EXCEPTION 'No se puede quitar un area/dimension que todavia tiene enunciados asociados; reasigne o elimine esos enunciados primero'
                USING ERRCODE = '23503';
        END IF;

        IF array_length(p_fk_tarea_asignatura_ids, 1) > 0 AND EXISTS (
            SELECT 1 FROM unnest(p_fk_tarea_asignatura_ids) ta_id
             WHERE NOT EXISTS (
                 SELECT 1 FROM academico_test.TAREA_ASIGNATURA ta
                  WHERE ta.PK_TAREA_ASIGNATURA = ta_id AND ta.ACTIVE = TRUE
             )
        ) THEN
            RAISE EXCEPTION 'Una o mas areas/dimensiones (TAREA_ASIGNATURA) no existen o no estan activas'
                USING ERRCODE = '23503';
        END IF;

        -- Desactiva las que ya no vienen en la lista.
        UPDATE academico_test.TREFERENTE_CURRICULAR_AREA
           SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_REFERENTE_CURRICULAR = p_pk_referente_curricular
           AND ACTIVE = TRUE
           AND NOT (FK_TAREA_ASIGNATURA = ANY(p_fk_tarea_asignatura_ids));

        -- Reactiva/crea las de la lista que no estan activas todavia.
        INSERT INTO academico_test.TREFERENTE_CURRICULAR_AREA (
            FK_REFERENTE_CURRICULAR, FK_TAREA_ASIGNATURA, CREATED_BY, CREATED_AT, ACTIVE
        )
        SELECT DISTINCT p_pk_referente_curricular, ta_id, p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
          FROM unnest(p_fk_tarea_asignatura_ids) ta_id
         WHERE NOT EXISTS (
             SELECT 1 FROM academico_test.TREFERENTE_CURRICULAR_AREA rca
              WHERE rca.FK_REFERENTE_CURRICULAR = p_pk_referente_curricular
                AND rca.FK_TAREA_ASIGNATURA = ta_id
                AND rca.ACTIVE = TRUE
         );
    END IF;

    RETURN p_pk_referente_curricular;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_refcurr_actualizar(BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT[], BIGINT, BIGINT, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, INTEGER, INTEGER, VARCHAR, BIGINT[], VARCHAR)
    IS 'V214.3 -- == V213 mas p_nombre_asignatura: ausente/NULL no toca el valor actual; cadena vacia o solo espacios lanza 22023 (la columna es NOT NULL). Gate EDITAR sobre REFERENTES_CURRICULARES.';

-- ---------------------------------------------------------------------------
-- 4) fn_refcurr_listar -- nueva columna nombre_asignatura en el RETURNS TABLE
--    (y el search ahora tambien pega sobre ella).
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_refcurr_listar(
    BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, VARCHAR, BOOLEAN, VARCHAR, BOOLEAN, INT, INT);

CREATE OR REPLACE FUNCTION academico_test.fn_refcurr_listar(
    p_pk_usuario_solicitante      BIGINT,
    p_search                      VARCHAR   DEFAULT NULL,
    p_fk_tnivel_ensenanza         BIGINT    DEFAULT NULL,
    p_fk_tlv_enfoque_pedagogico   BIGINT    DEFAULT NULL,
    p_fk_tlv_tipo_evaluacion      BIGINT    DEFAULT NULL,
    p_estado                      VARCHAR   DEFAULT NULL,
    p_incluir_inactivos           BOOLEAN   DEFAULT FALSE,
    p_orden_por                   VARCHAR   DEFAULT 'nombre',
    p_orden_asc                   BOOLEAN   DEFAULT TRUE,
    p_limite                      INT       DEFAULT 20,
    p_offset                      INT       DEFAULT 0
)
RETURNS TABLE (
    pk_referente_curricular   BIGINT,
    nombre                    VARCHAR,
    descripcion                VARCHAR,
    -- V214.3 -- nombre con el que se rotula la asignatura en el planeador.
    nombre_asignatura          VARCHAR,
    -- N:N con TNIVEL_ENSENANZA: la columna de la tabla-listado muestra los
    -- nombres concatenados; niveles trae el detalle [{id, codigo, nombre}]
    -- para pintar chips y precargar el multi-select de edicion.
    niveles_educativos         VARCHAR,
    niveles                    JSONB,
    instrumento                VARCHAR,
    instrumento_info_adicional VARCHAR,
    enfoque_pedagogico         VARCHAR,
    tipo_evaluacion            VARCHAR,
    estado                     VARCHAR,
    anio_vigencia_desde        INTEGER,
    anio_vigencia_hasta        INTEGER,
    active                     BOOLEAN,
    total_count                BIGINT
)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'REFERENTES_CURRICULARES', 'VER'
    );

    RETURN QUERY
    SELECT rc.PK_REFERENTE_CURRICULAR,
           rc.NOMBRE,
           rc.DESCRIPCION,
           rc.NOMBRE_ASIGNATURA,
           niv.niveles_texto,
           niv.niveles_json,
           rc.INSTRUMENTO,
           rc.INSTRUMENTO_INFO_ADICIONAL,
           lve.NOMBRE,
           lvt.NOMBRE,
           rc.ESTADO::VARCHAR,
           rc.ANIO_VIGENCIA_DESDE,
           rc.ANIO_VIGENCIA_HASTA,
           rc.ACTIVE,
           COUNT(*) OVER()
      FROM academico_test.TREFERENTE_CURRICULAR rc
      -- LATERAL y no JOIN + GROUP BY: agrupar rompería el COUNT(*) OVER()
      -- que alimenta total_count.
      LEFT JOIN LATERAL (
          SELECT COALESCE(string_agg(ne.NOMBRE, ', ' ORDER BY ne.NOMBRE), '')::VARCHAR AS niveles_texto,
                 COALESCE(jsonb_agg(jsonb_build_object(
                     'id', ne.PK_NIVEL_ENSENANZA, 'codigo', ne.CODIGO, 'nombre', ne.NOMBRE
                 ) ORDER BY ne.NOMBRE), '[]'::jsonb) AS niveles_json
            FROM academico_test.TREFERENTE_CURRICULAR_NIVEL rcn
            JOIN academico_test.TNIVEL_ENSENANZA ne ON ne.PK_NIVEL_ENSENANZA = rcn.FK_TNIVEL_ENSENANZA
           WHERE rcn.FK_REFERENTE_CURRICULAR = rc.PK_REFERENTE_CURRICULAR
             AND rcn.ACTIVE = TRUE
      ) niv ON TRUE
      JOIN academico_test.TLISTA_VALOR lve ON lve.PK_LISTA_VALOR = rc.FK_TLV_ENFOQUE_PEDAGOGICO
      JOIN academico_test.TLISTA_VALOR lvt ON lvt.PK_LISTA_VALOR = rc.FK_TLV_TIPO_EVALUACION
     WHERE (p_incluir_inactivos OR rc.ACTIVE = TRUE)
       AND (p_search IS NULL OR rc.NOMBRE ILIKE '%' || p_search || '%' OR rc.DESCRIPCION ILIKE '%' || p_search || '%' OR rc.NOMBRE_ASIGNATURA ILIKE '%' || p_search || '%')
       -- Filtro por nivel: el referente califica si ALGUNO de sus niveles
       -- activos es el pedido.
       AND (p_fk_tnivel_ensenanza IS NULL OR EXISTS (
               SELECT 1 FROM academico_test.TREFERENTE_CURRICULAR_NIVEL rcn_f
                WHERE rcn_f.FK_REFERENTE_CURRICULAR = rc.PK_REFERENTE_CURRICULAR
                  AND rcn_f.FK_TNIVEL_ENSENANZA = p_fk_tnivel_ensenanza
                  AND rcn_f.ACTIVE = TRUE
           ))
       AND (p_fk_tlv_enfoque_pedagogico IS NULL OR rc.FK_TLV_ENFOQUE_PEDAGOGICO = p_fk_tlv_enfoque_pedagogico)
       AND (p_fk_tlv_tipo_evaluacion IS NULL OR rc.FK_TLV_TIPO_EVALUACION = p_fk_tlv_tipo_evaluacion)
       AND (p_estado IS NULL OR rc.ESTADO = UPPER(TRIM(p_estado)))
     ORDER BY
       CASE WHEN p_orden_asc THEN
           CASE LOWER(TRIM(COALESCE(p_orden_por, 'nombre')))
               WHEN 'nombre'          THEN rc.NOMBRE
               WHEN 'nivel_educativo' THEN niv.niveles_texto
               WHEN 'instrumento'     THEN rc.INSTRUMENTO
               WHEN 'estado'          THEN rc.ESTADO::VARCHAR
               ELSE rc.NOMBRE
           END
       END ASC,
       CASE WHEN NOT p_orden_asc THEN
           CASE LOWER(TRIM(COALESCE(p_orden_por, 'nombre')))
               WHEN 'nombre'          THEN rc.NOMBRE
               WHEN 'nivel_educativo' THEN niv.niveles_texto
               WHEN 'instrumento'     THEN rc.INSTRUMENTO
               WHEN 'estado'          THEN rc.ESTADO::VARCHAR
               ELSE rc.NOMBRE
           END
       END DESC
     LIMIT GREATEST(p_limite, 1)
    OFFSET GREATEST(p_offset, 0);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_refcurr_listar(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, VARCHAR, BOOLEAN, VARCHAR, BOOLEAN, INT, INT)
    IS 'V214.3 -- == V213 mas la columna nombre_asignatura en el RETURNS TABLE; p_search ahora tambien busca sobre NOMBRE_ASIGNATURA ademas de NOMBRE/DESCRIPCION. total_count via COUNT(*) OVER(). Gate VER.';

-- ---------------------------------------------------------------------------
-- 5) fn_refcurr_buscar_por_pk -- nueva columna nombre_asignatura.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_refcurr_buscar_por_pk(BIGINT, BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_refcurr_buscar_por_pk(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_referente_curricular  BIGINT
)
RETURNS TABLE (
    pk_referente_curricular    BIGINT,
    nombre                     VARCHAR,
    descripcion                VARCHAR,
    -- V214.3 -- rotulo de la asignatura (obligatorio en TREFERENTE_CURRICULAR).
    nombre_asignatura          VARCHAR,
    -- N:N: [{id, codigo, nombre}] de los niveles educativos activos del
    -- referente -- precarga el multi-select "Nivel educativo".
    niveles                    JSONB,
    fk_tlv_enfoque_pedagogico  BIGINT,
    enfoque_pedagogico         VARCHAR,
    fk_tlv_tipo_evaluacion     BIGINT,
    tipo_evaluacion            VARCHAR,
    nivel_1_etiqueta           VARCHAR,
    nivel_2_etiqueta           VARCHAR,
    instrumento                VARCHAR,
    instrumento_info_adicional VARCHAR,
    normatividad               VARCHAR,
    anio_vigencia_desde        INTEGER,
    anio_vigencia_hasta        INTEGER,
    estado                     VARCHAR,
    active                     BOOLEAN
)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'REFERENTES_CURRICULARES', 'VER'
    );

    RETURN QUERY
    SELECT rc.PK_REFERENTE_CURRICULAR, rc.NOMBRE, rc.DESCRIPCION, rc.NOMBRE_ASIGNATURA,
           COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                          'id', ne.PK_NIVEL_ENSENANZA, 'codigo', ne.CODIGO, 'nombre', ne.NOMBRE
                      ) ORDER BY ne.NOMBRE)
                 FROM academico_test.TREFERENTE_CURRICULAR_NIVEL rcn
                 JOIN academico_test.TNIVEL_ENSENANZA ne ON ne.PK_NIVEL_ENSENANZA = rcn.FK_TNIVEL_ENSENANZA
                WHERE rcn.FK_REFERENTE_CURRICULAR = rc.PK_REFERENTE_CURRICULAR
                  AND rcn.ACTIVE = TRUE
           ), '[]'::jsonb),
           rc.FK_TLV_ENFOQUE_PEDAGOGICO, lve.NOMBRE,
           rc.FK_TLV_TIPO_EVALUACION, lvt.NOMBRE,
           rc.NIVEL_1_ETIQUETA, rc.NIVEL_2_ETIQUETA,
           rc.INSTRUMENTO, rc.INSTRUMENTO_INFO_ADICIONAL, rc.NORMATIVIDAD,
           rc.ANIO_VIGENCIA_DESDE, rc.ANIO_VIGENCIA_HASTA,
           rc.ESTADO::VARCHAR, rc.ACTIVE
      FROM academico_test.TREFERENTE_CURRICULAR rc
      JOIN academico_test.TLISTA_VALOR lve ON lve.PK_LISTA_VALOR = rc.FK_TLV_ENFOQUE_PEDAGOGICO
      JOIN academico_test.TLISTA_VALOR lvt ON lvt.PK_LISTA_VALOR = rc.FK_TLV_TIPO_EVALUACION
     WHERE rc.PK_REFERENTE_CURRICULAR = p_pk_referente_curricular;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_refcurr_buscar_por_pk(BIGINT, BIGINT)
    IS 'V214.3 -- == V213 mas la columna nombre_asignatura. SETOF 0 o 1 fila. Gate VER.';

-- ---------------------------------------------------------------------------
-- 6) fn_refcurr_nombre_asignatura -- resolucion de UN nombre de asignatura.
-- ---------------------------------------------------------------------------
-- Gate distinto al del CRUD a proposito: el CRUD del catalogo exige
-- capability sobre REFERENTES_CURRICULARES, pero LEER como se llama la
-- asignatura lo necesita cualquiera que tenga la ventana de gestion
-- academica (PLANEADOR / ASISTENCIAS) o la de PERIODOS_ACADEMICOS.
-- Basta VER en CUALQUIERA de los tres menus (OR, no AND).
--
-- Sin scope territorial: TREFERENTE_CURRICULAR es catalogo global, no cuelga
-- de establecimiento ni de sede, asi que no hay nada que recortar con
-- fn_planeador_assert_alcance.
--
-- fn_usuario_puede_en_menu (V29) envuelve fn_usuario_permisos_menu (V185),
-- asi que hereda "TROL_MENU concede / TUSUARIO_ROL_PERMISO recorta" y es
-- fail-closed ante menu no concedido.
DROP FUNCTION IF EXISTS academico_test.fn_refcurr_nombre_asignatura(BIGINT, BIGINT);
CREATE OR REPLACE FUNCTION academico_test.fn_refcurr_nombre_asignatura(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_referente_curricular  BIGINT
)
RETURNS TABLE (
    pk_referente_curricular    BIGINT,
    nombre                     VARCHAR,
    nombre_asignatura          VARCHAR,
    active                     BOOLEAN
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF NOT (
           academico_test.fn_usuario_puede_en_menu(p_pk_usuario_solicitante, 'PLANEADOR', 'VER')
        OR academico_test.fn_usuario_puede_en_menu(p_pk_usuario_solicitante, 'ASISTENCIAS', 'VER')
        OR academico_test.fn_usuario_puede_en_menu(p_pk_usuario_solicitante, 'PERIODOS_ACADEMICOS', 'VER')
    ) THEN
        RAISE EXCEPTION 'No tiene permiso para consultar el nombre de la asignatura del referente curricular'
            USING ERRCODE = '42501',
                  HINT = 'requiere VER en alguno de los menus PLANEADOR, ASISTENCIAS o PERIODOS_ACADEMICOS';
    END IF;

    RETURN QUERY
    SELECT rc.PK_REFERENTE_CURRICULAR,
           rc.NOMBRE,
           rc.NOMBRE_ASIGNATURA,
           rc.ACTIVE
      FROM academico_test.TREFERENTE_CURRICULAR rc
     WHERE rc.PK_REFERENTE_CURRICULAR = p_pk_referente_curricular
       AND rc.ACTIVE = TRUE;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_refcurr_nombre_asignatura(BIGINT, BIGINT)
    IS 'V214.3 -- Resuelve el nombre con el que se debe rotular la asignatura de UN referente curricular. Gate por CAPABILITY de menu, no por el gate del catalogo: basta VER en PLANEADOR, ASISTENCIAS o PERIODOS_ACADEMICOS (OR). Sin scope territorial (catalogo global). Devuelve 0 filas si el referente no existe o esta inactivo -- el front lo trata como 404. 42501 -> HTTP 403.';

-- ===========================================================================
-- 7) public.query -- filas del gateway (serviceid eval-col).
-- ===========================================================================
-- Las de crear/actualizar se REEMPLAZAN con UPDATE y no editando V214: esa
-- migracion ya corrio y su ON CONFLICT no se reejecuta.

-- 7.1 refcurr-crear -- + BODY.NOMBRE_ASIGNATURA (obligatorio).
UPDATE public.query
   SET query = $q$SELECT academico_test.fn_refcurr_crear(
    p_pk_usuario_solicitante     => public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    p_nombre                     => CAST(:BODY.NOMBRE AS VARCHAR),
    p_descripcion                => CAST(:BODY.DESCRIPCION AS VARCHAR),
    p_fk_tnivel_ensenanza_ids    => CAST(:BODY.NIVELES_IDS AS BIGINT[]),
    p_fk_tlv_enfoque_pedagogico  => CAST(:BODY.ENFOQUE_PEDAGOGICO AS BIGINT),
    p_fk_tlv_tipo_evaluacion     => CAST(:BODY.TIPO_EVALUACION AS BIGINT),
    p_instrumento                => CAST(:BODY.INSTRUMENTO AS VARCHAR),
    p_normatividad               => CAST(:BODY.NORMATIVIDAD AS VARCHAR),
    p_anio_vigencia_desde        => CAST(:BODY.ANIO_DESDE AS INTEGER),
    p_nivel_1_etiqueta           => CAST(:BODY.NIVEL_1_ETIQUETA AS VARCHAR),
    p_nivel_2_etiqueta           => CAST(:BODY.NIVEL_2_ETIQUETA AS VARCHAR),
    p_instrumento_info_adicional => CAST(:BODY.INSTRUMENTO_INFO AS VARCHAR),
    p_anio_vigencia_hasta        => CAST(:BODY.ANIO_HASTA AS INTEGER),
    p_estado                     => COALESCE(CAST(:BODY.ESTADO AS VARCHAR), 'A'),
    p_fk_tarea_asignatura_ids    => CAST(:BODY.AREAS_IDS AS BIGINT[]),
    p_nombre_asignatura          => CAST(:BODY.NOMBRE_ASIGNATURA AS VARCHAR)
) AS pk_referente_curricular_creado$q$,
       param_types = '{
       "BODY.NOMBRE":             "VARCHAR",
       "BODY.NOMBRE_ASIGNATURA":  "VARCHAR",
       "BODY.DESCRIPCION":        "VARCHAR",
       "BODY.NIVELES_IDS":        "BIGINT[]",
       "BODY.ENFOQUE_PEDAGOGICO": "BIGINT",
       "BODY.TIPO_EVALUACION":    "BIGINT",
       "BODY.INSTRUMENTO":        "VARCHAR",
       "BODY.NORMATIVIDAD":       "VARCHAR",
       "BODY.ANIO_DESDE":         "INTEGER",
       "BODY.NIVEL_1_ETIQUETA":   "VARCHAR",
       "BODY.NIVEL_2_ETIQUETA":   "VARCHAR",
       "BODY.INSTRUMENTO_INFO":   "VARCHAR",
       "BODY.ANIO_HASTA":         "INTEGER",
       "BODY.ESTADO":             "VARCHAR",
       "BODY.AREAS_IDS":          "BIGINT[]"
     }'::jsonb,
       detail = 'V214.3 -- crea un referente curricular. BODY.NOMBRE_ASIGNATURA es OBLIGATORIO (22023 si falta): es el rotulo con el que se llamara la asignatura en planeador/asistencias/periodos. BODY.NIVELES_IDS obligatorio con al menos un nivel; BODY.AREAS_IDS vacio/ausente = aplica a todas las areas'
 WHERE uuid = 'refcurr-crear';

-- 7.2 refcurr-actualizar -- + BODY.NOMBRE_ASIGNATURA (ausente = no tocar).
UPDATE public.query
   SET query = $q$SELECT academico_test.fn_refcurr_actualizar(
    p_pk_usuario_solicitante     => public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    p_pk_referente_curricular    => CAST(:PARAM.ID AS BIGINT),
    p_nombre                     => CAST(:BODY.NOMBRE AS VARCHAR),
    p_descripcion                => CAST(:BODY.DESCRIPCION AS VARCHAR),
    p_fk_tnivel_ensenanza_ids    => CAST(:BODY.NIVELES_IDS AS BIGINT[]),
    p_fk_tlv_enfoque_pedagogico  => CAST(:BODY.ENFOQUE_PEDAGOGICO AS BIGINT),
    p_fk_tlv_tipo_evaluacion     => CAST(:BODY.TIPO_EVALUACION AS BIGINT),
    p_nivel_1_etiqueta           => CAST(:BODY.NIVEL_1_ETIQUETA AS VARCHAR),
    p_nivel_2_etiqueta           => CAST(:BODY.NIVEL_2_ETIQUETA AS VARCHAR),
    p_instrumento                => CAST(:BODY.INSTRUMENTO AS VARCHAR),
    p_instrumento_info_adicional => CAST(:BODY.INSTRUMENTO_INFO AS VARCHAR),
    p_normatividad               => CAST(:BODY.NORMATIVIDAD AS VARCHAR),
    p_anio_vigencia_desde        => CAST(:BODY.ANIO_DESDE AS INTEGER),
    p_anio_vigencia_hasta        => CAST(:BODY.ANIO_HASTA AS INTEGER),
    p_estado                     => CAST(:BODY.ESTADO AS VARCHAR),
    p_fk_tarea_asignatura_ids    => CAST(:BODY.AREAS_IDS AS BIGINT[]),
    p_nombre_asignatura          => CAST(:BODY.NOMBRE_ASIGNATURA AS VARCHAR)
) AS pk_referente_curricular$q$,
       param_types = '{
       "PARAM.ID":                "BIGINT",
       "BODY.NOMBRE":             "VARCHAR",
       "BODY.NOMBRE_ASIGNATURA":  "VARCHAR",
       "BODY.DESCRIPCION":        "VARCHAR",
       "BODY.NIVELES_IDS":        "BIGINT[]",
       "BODY.ENFOQUE_PEDAGOGICO": "BIGINT",
       "BODY.TIPO_EVALUACION":    "BIGINT",
       "BODY.NIVEL_1_ETIQUETA":   "VARCHAR",
       "BODY.NIVEL_2_ETIQUETA":   "VARCHAR",
       "BODY.INSTRUMENTO":        "VARCHAR",
       "BODY.INSTRUMENTO_INFO":   "VARCHAR",
       "BODY.NORMATIVIDAD":       "VARCHAR",
       "BODY.ANIO_DESDE":         "INTEGER",
       "BODY.ANIO_HASTA":         "INTEGER",
       "BODY.ESTADO":             "VARCHAR",
       "BODY.AREAS_IDS":          "BIGINT[]"
     }'::jsonb,
       detail = 'V214.3 -- PATCH parcial de un referente curricular; cada campo ausente preserva su valor actual. BODY.NOMBRE_ASIGNATURA ausente = no tocar, cadena vacia = 22023. BODY.NIVELES_IDS ausente = no tocar los niveles, array = reemplazo completo del set. BODY.AREAS_IDS ausente = no tocar areas, [] = vaciarlas'
 WHERE uuid = 'refcurr-actualizar';

-- 7.3 refcurr-nombre-asignatura -- endpoint nuevo.
INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id,
                           path_template, execution_mode, http_method, param_types, detail)
SELECT
    'refcurr-nombre-asignatura',
    $q$SELECT * FROM academico_test.fn_refcurr_nombre_asignatura(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
);$q$,
    'postgres', false, false, m.id_microservice,
    '/referentes-curriculares/:ID/nombre-asignatura', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    'V214.3 -- nombre con el que se debe rotular la asignatura de este referente, segun el acceso del usuario. Gate por capability de menu: basta VER en PLANEADOR, ASISTENCIAS o PERIODOS_ACADEMICOS (403 si no tiene ninguno). 0 filas si el referente no existe o esta inactivo'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (uuid) DO UPDATE
   SET query = EXCLUDED.query, param_types = EXCLUDED.param_types,
       path_template = EXCLUDED.path_template, http_method = EXCLUDED.http_method,
       execution_mode = EXCLUDED.execution_mode, microservice_id = EXCLUDED.microservice_id,
       detail = EXCLUDED.detail;
