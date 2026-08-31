-- ===========================================================================
-- V213 — Referente Curricular: CRUD + listados (CU-86e311xqh — G. Academico
-- Back Referente Curricular). Complementa el esquema de V212
-- (TREFERENTE_CURRICULAR, TREFERENTE_CURRICULAR_AREA, TREFERENTE_ENUNCIADO,
-- TUNIDAD.FK_REFERENTE_CURRICULAR).
--
-- -------------------------------------------------------------------------
-- AUTORIZACION
--
--   Escritura (CREAR/EDITAR/ELIMINAR) es exclusiva de SUPER_ADMIN. Lectura
--   (VER: listar/detalle) queda bajo el mismo modelo de capability por menu
--   ya construido en V29/V185/V198 (CU-86e2w4xdt) — el gate es UNO SOLO,
--   fn_assert_permiso_seccion(usuario, 'REFERENTES_CURRICULARES', accion),
--   sin parametros de scope (p_fk_establecimiento/p_fk_tsede quedan NULL):
--   Referente Curricular es un catalogo GLOBAL, no ligado a un
--   establecimiento/sede, asi que no aplica scope territorial — solo
--   capability. En la practica hoy eso significa "solo SUPER_ADMIN" (bypass
--   de nivel 0 en el paso 0 del gate) porque este seed NO concede el menu a
--   ningun otro rol; el super admin puede abrirselo despues a otros roles
--   (p.ej. en solo lectura, TROL_MENU.SOLO_LECTURA='SI') desde
--   PUT /roles/{roleId}/menus sin tocar SQL — igual que cualquier otro menu.
--
--   Seed nuevo (idempotente, mismo patron NOT EXISTS de V59/V113/V118 — el
--   indice de TROL_MENU es UNIQUE PARCIAL, nada de ON CONFLICT):
--     (A) TMENU 'REFERENTES_CURRICULARES' (grupo top-level, fk_tmenu NULL).
--     (B) TROL_MENU: SUPER_ADMINISTRADOR <-> REFERENTES_CURRICULARES,
--         SOLO_LECTURA=NULL (los 4 permisos, semantica V99).
--
-- -------------------------------------------------------------------------
-- FUNCIONES (prefijos fn_refcurr_ / fn_refenunc_)
--
--   Referente:
--     fn_refcurr_crear            — crea el referente + (opcional) su set
--                                    inicial de areas/dimensiones.
--     fn_refcurr_actualizar       — PATCH parcial; p_fk_tarea_asignatura_ids
--                                    NULL = no tocar areas, ARRAY[]::BIGINT[]
--                                    = vaciarlas ("aplica a todas").
--     fn_refcurr_eliminar         — soft delete en cascada: evidencias ->
--                                    enunciados -> areas -> referente.
--     fn_refcurr_listar           — pagina con filtros/orden (pantalla
--                                    "Referentes curriculares").
--     fn_refcurr_buscar_por_pk    — detalle (pestaña "Información general").
--     fn_refcurr_areas_listar     — areas ya asociadas (select de la pestaña
--                                    "Enunciado").
--
--   Enunciado / evidencia (TREFERENTE_ENUNCIADO, auto-referenciada):
--     fn_refenunc_crear           — nivel 1 (enunciado) o nivel 2 (evidencia,
--                                    con p_fk_padre). Ver reglas abajo.
--     fn_refenunc_actualizar      — PATCH; FK_PADRE/FK_REFERENTE_CURRICULAR
--                                    inmutables.
--     fn_refenunc_eliminar        — soft delete; en cascada a sus evidencias
--                                    si es un enunciado (nivel 1).
--     fn_refenunc_listar          — enunciados (nivel 1) de un referente,
--                                    opcionalmente filtrados por area, con
--                                    conteo de evidencias (panel izquierdo).
--     fn_refenunc_evidencias_listar — evidencias (nivel 2) de UN enunciado
--                                    (tabla "Evidencias del enunciado").
--
-- -------------------------------------------------------------------------
-- REGLAS DE NEGOCIO IMPLEMENTADAS
--
--   1) "Se deben crear primero enunciados antes que evidencias": no es una
--      regla aparte, es consecuencia directa de la FK — fn_refenunc_crear
--      con p_fk_padre exige que ese padre YA EXISTA (SELECT ... FOR
--      lectura), este ACTIVE=TRUE y sea el mismo referente; si no, 22023 /
--      P0002. No puede existir una evidencia sin su enunciado.
--   2) Un solo nivel de anidamiento: el padre de una evidencia debe ser el
--      mismo un enunciado de nivel 1 (FK_PADRE IS NULL) — no se permiten
--      evidencias de evidencias. 22023 si se intenta.
--   3) Filtrado de areas por enunciado (constraint de V212,
--      CHK_TREFENUNC_AREA_SOLO_NIVEL1, mas la regla de negocio decidida):
--        * FK_REFERENTE_CURRICULAR_AREA en un enunciado (nivel 1) es
--          SIEMPRE OPCIONAL, tenga o no el referente areas asociadas. NULL
--          = el enunciado aplica a TODAS las areas/dimensiones (revision:
--          la version anterior de esta migracion la exigia cuando el
--          referente tenia areas; se relaja porque un referente con areas
--          puede igual querer enunciados transversales a todas ellas). Si
--          se manda un valor, debe ser una de las areas ACTIVAS de ESE
--          mismo referente (23503 si no).
--        * Evidencias (nivel 2) NUNCA reciben area propia: la heredan del
--          enunciado padre. Si el caller manda una, 22023.
--   4) Preescolar / NIVEL_1_ETIQUETA / NIVEL_2_ETIQUETA: quedan como texto
--      libre (ya default 'Enunciado'/'Evidencia' en el DDL, V212). NO se
--      fuerza ningun valor especial cuando FK_TNIVEL_ENSENANZA = Preescolar
--      — es una sugerencia de UI, no una regla de servidor (decision del
--      usuario en el hilo de esta migracion).
--   5) "Se puede crear inactivo": p_estado acepta 'I' desde el alta (no se
--      exige 'A'); igual que TENTE/TROL, ESTADO es independiente de ACTIVE.
--   6) "Se puede dejar vacio (aplica para todas)": fn_refcurr_crear /
--      fn_refcurr_actualizar aceptan p_fk_tarea_asignatura_ids NULL o vacio
--      sin error — el referente simplemente no queda amarrado a ninguna
--      area (V212, TREFERENTE_CURRICULAR_AREA).
--   7) Quitarle a un referente un area que todavia tiene enunciados
--      amarrados (FK_REFERENTE_CURRICULAR_AREA) esta BLOQUEADO (23503): el
--      caller debe reasignar o borrar esos enunciados primero.
--
-- Idempotencia: CREATE OR REPLACE FUNCTION (sin cambios de firma, nada de
-- DROP previo necesario); el seed de TMENU/TROL_MENU usa WHERE NOT EXISTS
-- (mismo patron V59/V113/V118, sin ON CONFLICT por el indice parcial).
-- ===========================================================================

SET search_path TO academico_test, public;

-- ---------------------------------------------------------------------------
-- (A) TMENU — grupo top-level 'REFERENTES_CURRICULARES'.
-- ---------------------------------------------------------------------------
INSERT INTO academico_test.tmenu (codigo, nombre, icono, visible, estado, url, fk_tmenu, orden, created_by)
SELECT 'REFERENTES_CURRICULARES', 'Referentes Curriculares', 'BookBookmark-Icon', 'S', 'A',
       '/academico/referentes-curriculares', NULL, 5::NUMERIC, 'V213_seed'
 WHERE NOT EXISTS (
     SELECT 1 FROM academico_test.tmenu m
      WHERE m.codigo = 'REFERENTES_CURRICULARES' AND m.active = TRUE
 );

-- ---------------------------------------------------------------------------
-- (B) TROL_MENU — concede el menu a SUPER_ADMINISTRADOR (4 permisos).
-- ---------------------------------------------------------------------------
INSERT INTO academico_test.trol_menu (fk_trol, fk_tmenu, orden_rol, active, created_by)
SELECT t.pk_trol, m.pk_tmenu, 1, TRUE, 'V213_seed'
  FROM academico_test.tmenu m
 CROSS JOIN academico_test.trol t
 WHERE t.codigo = 'SUPER_ADMINISTRADOR'
   AND t.active = TRUE
   AND m.codigo = 'REFERENTES_CURRICULARES'
   AND m.active = TRUE
   AND NOT EXISTS (
       SELECT 1 FROM academico_test.trol_menu tm
        WHERE tm.fk_trol = t.pk_trol AND tm.fk_tmenu = m.pk_tmenu AND tm.active = TRUE
       );

-- ===========================================================================
-- fn_refcurr_crear
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_refcurr_crear(
    p_pk_usuario_solicitante        BIGINT,
    p_nombre                        VARCHAR(150),
    p_descripcion                   VARCHAR(400),
    p_fk_tnivel_ensenanza           BIGINT,
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
    p_fk_tarea_asignatura_ids       BIGINT[]     DEFAULT NULL
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
    IF p_fk_tnivel_ensenanza IS NULL THEN
        RAISE EXCEPTION 'Nivel educativo (FK_TNIVEL_ENSENANZA) es obligatorio'
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
    IF NOT EXISTS (SELECT 1 FROM academico_test.TNIVEL_ENSENANZA WHERE PK_NIVEL_ENSENANZA = p_fk_tnivel_ensenanza AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'FK_TNIVEL_ENSENANZA (%) no existe o no esta activo', p_fk_tnivel_ensenanza
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

    -- 3. Unicidad de NOMBRE entre activos (chequeo a nivel de funcion, mismo
    --    criterio que TESTABLECIMIENTO/TSEDE en V52/V53).
    IF EXISTS (SELECT 1 FROM academico_test.TREFERENTE_CURRICULAR WHERE NOMBRE = p_nombre AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'Ya existe un referente curricular activo con el nombre "%"', p_nombre
            USING ERRCODE = '23505';
    END IF;

    -- 4. INSERT.
    INSERT INTO academico_test.TREFERENTE_CURRICULAR (
        NOMBRE, DESCRIPCION, FK_TNIVEL_ENSENANZA, FK_TLV_ENFOQUE_PEDAGOGICO,
        FK_TLV_TIPO_EVALUACION, NIVEL_1_ETIQUETA, NIVEL_2_ETIQUETA, INSTRUMENTO,
        INSTRUMENTO_INFO_ADICIONAL, NORMATIVIDAD, ANIO_VIGENCIA_DESDE,
        ANIO_VIGENCIA_HASTA, ESTADO, CREATED_BY, CREATED_AT, ACTIVE
    ) VALUES (
        p_nombre, p_descripcion, p_fk_tnivel_ensenanza, p_fk_tlv_enfoque_pedagogico,
        p_fk_tlv_tipo_evaluacion,
        COALESCE(NULLIF(TRIM(p_nivel_1_etiqueta), ''), 'Enunciado'),
        COALESCE(NULLIF(TRIM(p_nivel_2_etiqueta), ''), 'Evidencia'),
        p_instrumento, p_instrumento_info_adicional, p_normatividad,
        p_anio_vigencia_desde, p_anio_vigencia_hasta, UPPER(TRIM(p_estado)),
        p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
    )
    RETURNING PK_REFERENTE_CURRICULAR INTO v_id_creado;

    -- 5. Areas/dimensiones iniciales (opcional -- vacio/NULL = aplica a todas).
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

COMMENT ON FUNCTION academico_test.fn_refcurr_crear(BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT, VARCHAR, VARCHAR, INTEGER, VARCHAR, VARCHAR, VARCHAR, INTEGER, VARCHAR, BIGINT[])
    IS 'Crea un TREFERENTE_CURRICULAR (gate CREAR, solo SUPER_ADMIN por defecto) y, si se pasan, sus areas/dimensiones iniciales en TREFERENTE_CURRICULAR_AREA. p_fk_tarea_asignatura_ids NULL o vacio = sin areas ("aplica a todas"). p_estado acepta ''A''/''I'' -- se puede crear inactivo. Retorna PK_REFERENTE_CURRICULAR.';

-- ===========================================================================
-- fn_refcurr_actualizar
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_refcurr_actualizar(
    p_pk_usuario_solicitante        BIGINT,
    p_pk_referente_curricular       BIGINT,
    p_nombre                        VARCHAR(150) DEFAULT NULL,
    p_descripcion                   VARCHAR(400) DEFAULT NULL,
    p_fk_tnivel_ensenanza           BIGINT       DEFAULT NULL,
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
    p_fk_tarea_asignatura_ids       BIGINT[]     DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_actual         academico_test.TREFERENTE_CURRICULAR%ROWTYPE;
    v_nuevo_desde    INTEGER;
    v_nuevo_hasta    INTEGER;
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
    IF p_nombre IS NOT NULL AND UPPER(TRIM(p_nombre)) <> UPPER(TRIM(v_actual.NOMBRE))
       AND EXISTS (SELECT 1 FROM academico_test.TREFERENTE_CURRICULAR
                    WHERE NOMBRE = p_nombre AND ACTIVE = TRUE AND PK_REFERENTE_CURRICULAR <> p_pk_referente_curricular) THEN
        RAISE EXCEPTION 'Ya existe otro referente curricular activo con el nombre "%"', p_nombre
            USING ERRCODE = '23505';
    END IF;

    IF p_fk_tnivel_ensenanza IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TNIVEL_ENSENANZA WHERE PK_NIVEL_ENSENANZA = p_fk_tnivel_ensenanza AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'FK_TNIVEL_ENSENANZA (%) no existe o no esta activo', p_fk_tnivel_ensenanza USING ERRCODE = '23503';
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
           DESCRIPCION                  = COALESCE(p_descripcion, DESCRIPCION),
           FK_TNIVEL_ENSENANZA          = COALESCE(p_fk_tnivel_ensenanza, FK_TNIVEL_ENSENANZA),
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

COMMENT ON FUNCTION academico_test.fn_refcurr_actualizar(BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, INTEGER, INTEGER, VARCHAR, BIGINT[])
    IS 'PATCH parcial de TREFERENTE_CURRICULAR (gate EDITAR, solo SUPER_ADMIN por defecto): cada parametro NULL preserva el valor actual. p_fk_tarea_asignatura_ids NULL = no tocar areas; ARRAY[]::BIGINT[] = vaciarlas (vuelve a "aplica a todas"); cualquier otro array = reemplazo completo del set, bloqueado (23503) si intenta quitar un area con enunciados activos amarrados.';

-- ===========================================================================
-- fn_refcurr_eliminar — soft delete en cascada.
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_refcurr_eliminar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_referente_curricular  BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_estado_actual  BOOLEAN;
    v_nombre_actual  VARCHAR;
    v_evidencias     BIGINT := 0;
    v_enunciados     BIGINT := 0;
    v_areas          BIGINT := 0;
BEGIN
    SELECT ACTIVE, NOMBRE INTO v_estado_actual, v_nombre_actual
      FROM academico_test.TREFERENTE_CURRICULAR
     WHERE PK_REFERENTE_CURRICULAR = p_pk_referente_curricular;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el referente curricular solicitado'
            USING ERRCODE = 'P0002';
    END IF;

    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'REFERENTES_CURRICULARES', 'ELIMINAR'
    );

    IF v_estado_actual = FALSE THEN
        RAISE EXCEPTION 'El referente curricular "%" ya se encuentra inactivo', v_nombre_actual
            USING ERRCODE = '22023';
    END IF;

    -- 1. Evidencias (nivel 2) primero.
    UPDATE academico_test.TREFERENTE_ENUNCIADO
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_REFERENTE_CURRICULAR = p_pk_referente_curricular
       AND FK_PADRE IS NOT NULL
       AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_evidencias = ROW_COUNT;

    -- 2. Enunciados (nivel 1).
    UPDATE academico_test.TREFERENTE_ENUNCIADO
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_REFERENTE_CURRICULAR = p_pk_referente_curricular
       AND FK_PADRE IS NULL
       AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_enunciados = ROW_COUNT;

    -- 3. Areas/dimensiones asociadas.
    UPDATE academico_test.TREFERENTE_CURRICULAR_AREA
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_REFERENTE_CURRICULAR = p_pk_referente_curricular
       AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_areas = ROW_COUNT;

    -- 4. El referente.
    UPDATE academico_test.TREFERENTE_CURRICULAR
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_REFERENTE_CURRICULAR = p_pk_referente_curricular;

    RAISE NOTICE 'Soft delete TREFERENTE_CURRICULAR=% (autor: %): enunciados=%, evidencias=%, areas=%',
        p_pk_referente_curricular, p_pk_usuario_solicitante, v_enunciados, v_evidencias, v_areas;

    RETURN p_pk_referente_curricular;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_refcurr_eliminar(BIGINT, BIGINT)
    IS 'Soft delete (ACTIVE=FALSE) de un TREFERENTE_CURRICULAR (gate ELIMINAR, solo SUPER_ADMIN por defecto), en cascada: evidencias (nivel 2) -> enunciados (nivel 1) -> TREFERENTE_CURRICULAR_AREA -> el referente. No toca TUNIDAD.FK_REFERENTE_CURRICULAR (unidades que citaban este referente simplemente quedan apuntando a un referente inactivo; es responsabilidad del caller/UI avisar).';

-- ===========================================================================
-- fn_refcurr_listar — pagina con filtros/orden (pantalla listado).
-- ===========================================================================
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
    nivel_educativo            VARCHAR,
    instrumento                VARCHAR,
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
           ne.NOMBRE,
           rc.INSTRUMENTO,
           lve.NOMBRE,
           lvt.NOMBRE,
           rc.ESTADO::VARCHAR,
           rc.ANIO_VIGENCIA_DESDE,
           rc.ANIO_VIGENCIA_HASTA,
           rc.ACTIVE,
           COUNT(*) OVER()
      FROM academico_test.TREFERENTE_CURRICULAR rc
      JOIN academico_test.TNIVEL_ENSENANZA ne ON ne.PK_NIVEL_ENSENANZA = rc.FK_TNIVEL_ENSENANZA
      JOIN academico_test.TLISTA_VALOR lve ON lve.PK_LISTA_VALOR = rc.FK_TLV_ENFOQUE_PEDAGOGICO
      JOIN academico_test.TLISTA_VALOR lvt ON lvt.PK_LISTA_VALOR = rc.FK_TLV_TIPO_EVALUACION
     WHERE (p_incluir_inactivos OR rc.ACTIVE = TRUE)
       AND (p_search IS NULL OR rc.NOMBRE ILIKE '%' || p_search || '%' OR rc.DESCRIPCION ILIKE '%' || p_search || '%')
       AND (p_fk_tnivel_ensenanza IS NULL OR rc.FK_TNIVEL_ENSENANZA = p_fk_tnivel_ensenanza)
       AND (p_fk_tlv_enfoque_pedagogico IS NULL OR rc.FK_TLV_ENFOQUE_PEDAGOGICO = p_fk_tlv_enfoque_pedagogico)
       AND (p_fk_tlv_tipo_evaluacion IS NULL OR rc.FK_TLV_TIPO_EVALUACION = p_fk_tlv_tipo_evaluacion)
       AND (p_estado IS NULL OR rc.ESTADO = UPPER(TRIM(p_estado)))
     ORDER BY
       CASE WHEN p_orden_asc THEN
           CASE LOWER(TRIM(COALESCE(p_orden_por, 'nombre')))
               WHEN 'nombre'          THEN rc.NOMBRE
               WHEN 'nivel_educativo' THEN ne.NOMBRE
               WHEN 'instrumento'     THEN rc.INSTRUMENTO
               WHEN 'estado'          THEN rc.ESTADO::VARCHAR
               ELSE rc.NOMBRE
           END
       END ASC,
       CASE WHEN NOT p_orden_asc THEN
           CASE LOWER(TRIM(COALESCE(p_orden_por, 'nombre')))
               WHEN 'nombre'          THEN rc.NOMBRE
               WHEN 'nivel_educativo' THEN ne.NOMBRE
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
    IS 'Pagina de TREFERENTE_CURRICULAR con filtros (search sobre NOMBRE/DESCRIPCION, nivel educativo, enfoque, tipo de evaluacion, estado) y orden (nombre|nivel_educativo|instrumento|estado). total_count via COUNT(*) OVER() para totalCount/pageCount. Gate VER (capability, sin scope: catalogo global). p_incluir_inactivos=FALSE por defecto (solo ACTIVE=TRUE).';

-- ===========================================================================
-- fn_refcurr_buscar_por_pk — detalle (pestaña "Información general").
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_refcurr_buscar_por_pk(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_referente_curricular  BIGINT
)
RETURNS TABLE (
    pk_referente_curricular    BIGINT,
    nombre                     VARCHAR,
    descripcion                VARCHAR,
    fk_tnivel_ensenanza        BIGINT,
    nivel_educativo            VARCHAR,
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
    SELECT rc.PK_REFERENTE_CURRICULAR, rc.NOMBRE, rc.DESCRIPCION,
           rc.FK_TNIVEL_ENSENANZA, ne.NOMBRE,
           rc.FK_TLV_ENFOQUE_PEDAGOGICO, lve.NOMBRE,
           rc.FK_TLV_TIPO_EVALUACION, lvt.NOMBRE,
           rc.NIVEL_1_ETIQUETA, rc.NIVEL_2_ETIQUETA,
           rc.INSTRUMENTO, rc.INSTRUMENTO_INFO_ADICIONAL, rc.NORMATIVIDAD,
           rc.ANIO_VIGENCIA_DESDE, rc.ANIO_VIGENCIA_HASTA,
           rc.ESTADO::VARCHAR, rc.ACTIVE
      FROM academico_test.TREFERENTE_CURRICULAR rc
      JOIN academico_test.TNIVEL_ENSENANZA ne ON ne.PK_NIVEL_ENSENANZA = rc.FK_TNIVEL_ENSENANZA
      JOIN academico_test.TLISTA_VALOR lve ON lve.PK_LISTA_VALOR = rc.FK_TLV_ENFOQUE_PEDAGOGICO
      JOIN academico_test.TLISTA_VALOR lvt ON lvt.PK_LISTA_VALOR = rc.FK_TLV_TIPO_EVALUACION
     WHERE rc.PK_REFERENTE_CURRICULAR = p_pk_referente_curricular;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_refcurr_buscar_por_pk(BIGINT, BIGINT)
    IS 'Detalle de un TREFERENTE_CURRICULAR (pestaña "Información general"), con nombres resueltos de nivel educativo/enfoque/tipo de evaluacion. SETOF 0 o 1 fila (incluye inactivos: el caller decide si los muestra). Gate VER.';

-- ===========================================================================
-- fn_refcurr_areas_listar — areas ya asociadas (select pestaña "Enunciado").
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_refcurr_areas_listar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_referente_curricular  BIGINT
)
RETURNS TABLE (
    pk_referente_curricular_area  BIGINT,
    fk_tarea_asignatura           BIGINT,
    nombre                        VARCHAR
)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'REFERENTES_CURRICULARES', 'VER'
    );

    RETURN QUERY
    SELECT rca.PK_REFERENTE_CURRICULAR_AREA, rca.FK_TAREA_ASIGNATURA, ta.NOMBRE
      FROM academico_test.TREFERENTE_CURRICULAR_AREA rca
      JOIN academico_test.TAREA_ASIGNATURA ta ON ta.PK_TAREA_ASIGNATURA = rca.FK_TAREA_ASIGNATURA
     WHERE rca.FK_REFERENTE_CURRICULAR = p_pk_referente_curricular
       AND rca.ACTIVE = TRUE
     ORDER BY ta.NOMBRE;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_refcurr_areas_listar(BIGINT, BIGINT)
    IS 'Areas/dimensiones ACTIVE asociadas a un referente (TREFERENTE_CURRICULAR_AREA), con el nombre de TAREA_ASIGNATURA -- alimenta el select "Areas o dimensiones" de la pestaña Enunciado. Lista vacia = el referente aplica a todas las areas. Gate VER.';

-- ===========================================================================
-- fn_refenunc_crear — enunciado (nivel 1) o evidencia (nivel 2, p_fk_padre).
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_refenunc_crear(
    p_pk_usuario_solicitante         BIGINT,
    p_pk_referente_curricular        BIGINT,
    p_texto                          VARCHAR(400),
    p_fk_padre                       BIGINT      DEFAULT NULL,
    p_fk_referente_curricular_area   BIGINT      DEFAULT NULL,
    p_estado                         VARCHAR(1)  DEFAULT 'A'
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_id_creado       BIGINT;
    v_referente_activo BOOLEAN;
    v_padre_fk_padre  BIGINT;
    v_padre_referente BIGINT;
    v_padre_active    BOOLEAN;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'REFERENTES_CURRICULARES', 'CREAR'
    );

    IF NULLIF(TRIM(p_texto), '') IS NULL THEN
        RAISE EXCEPTION 'Texto del enunciado/evidencia es obligatorio'
            USING ERRCODE = '22023';
    END IF;
    IF UPPER(TRIM(COALESCE(p_estado, ''))) NOT IN ('A', 'I') THEN
        RAISE EXCEPTION 'Estado invalido: % (use ''A'' o ''I'')', p_estado USING ERRCODE = '22023';
    END IF;

    SELECT ACTIVE INTO v_referente_activo
      FROM academico_test.TREFERENTE_CURRICULAR
     WHERE PK_REFERENTE_CURRICULAR = p_pk_referente_curricular;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el referente curricular solicitado'
            USING ERRCODE = 'P0002';
    END IF;
    IF v_referente_activo = FALSE THEN
        RAISE EXCEPTION 'El referente curricular esta inactivo; no se le pueden agregar enunciados/evidencias'
            USING ERRCODE = '22023';
    END IF;

    IF p_fk_padre IS NOT NULL THEN
        -- ---------------------------------------------------------------
        -- Nivel 2 (evidencia): regla "enunciados antes que evidencias" --
        -- el padre debe existir YA, estar activo y ser del mismo referente.
        -- ---------------------------------------------------------------
        SELECT FK_PADRE, FK_REFERENTE_CURRICULAR, ACTIVE
          INTO v_padre_fk_padre, v_padre_referente, v_padre_active
          FROM academico_test.TREFERENTE_ENUNCIADO
         WHERE PK_REFERENTE_ENUNCIADO = p_fk_padre;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'El enunciado padre (p_fk_padre=%) no existe; debe crear el enunciado antes de agregarle evidencias', p_fk_padre
                USING ERRCODE = 'P0002';
        END IF;
        IF v_padre_active = FALSE THEN
            RAISE EXCEPTION 'El enunciado padre (%) esta inactivo; no se le pueden agregar evidencias', p_fk_padre
                USING ERRCODE = '22023';
        END IF;
        IF v_padre_referente <> p_pk_referente_curricular THEN
            RAISE EXCEPTION 'El enunciado padre (%) pertenece a otro referente curricular', p_fk_padre
                USING ERRCODE = '22023';
        END IF;
        IF v_padre_fk_padre IS NOT NULL THEN
            RAISE EXCEPTION 'Solo se permite un nivel de anidamiento: el padre (%) ya es una evidencia, no un enunciado', p_fk_padre
                USING ERRCODE = '22023';
        END IF;
        IF p_fk_referente_curricular_area IS NOT NULL THEN
            RAISE EXCEPTION 'Una evidencia no elige area propia: hereda la de su enunciado padre'
                USING ERRCODE = '22023';
        END IF;
    ELSE
        -- ---------------------------------------------------------------
        -- Nivel 1 (enunciado): area SIEMPRE opcional, tenga o no el
        -- referente areas asociadas. NULL = el enunciado aplica a TODAS
        -- las areas/dimensiones (mismo significado que un referente sin
        -- areas propias, V212) -- incluso cuando el referente si tiene
        -- areas especificas, el usuario puede dejar un enunciado sin
        -- amarrar a ninguna en particular. Si se manda una, debe ser una
        -- de las areas ACTIVAS de ESE referente.
        -- ---------------------------------------------------------------
        IF p_fk_referente_curricular_area IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM academico_test.TREFERENTE_CURRICULAR_AREA
             WHERE PK_REFERENTE_CURRICULAR_AREA = p_fk_referente_curricular_area
               AND FK_REFERENTE_CURRICULAR = p_pk_referente_curricular
               AND ACTIVE = TRUE
        ) THEN
            RAISE EXCEPTION 'FK_REFERENTE_CURRICULAR_AREA (%) no existe, no esta activa o no pertenece a este referente', p_fk_referente_curricular_area
                USING ERRCODE = '23503';
        END IF;
    END IF;

    INSERT INTO academico_test.TREFERENTE_ENUNCIADO (
        FK_REFERENTE_CURRICULAR, FK_REFERENTE_CURRICULAR_AREA, FK_PADRE, TEXTO,
        ESTADO, CREATED_BY, CREATED_AT, ACTIVE
    ) VALUES (
        p_pk_referente_curricular, p_fk_referente_curricular_area, p_fk_padre, p_texto,
        UPPER(TRIM(p_estado)), p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
    )
    RETURNING PK_REFERENTE_ENUNCIADO INTO v_id_creado;

    RETURN v_id_creado;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_refenunc_crear(BIGINT, BIGINT, VARCHAR, BIGINT, BIGINT, VARCHAR)
    IS 'Crea un enunciado (p_fk_padre NULL, nivel 1) o una evidencia (p_fk_padre = PK de un enunciado ya existente, nivel 2) en TREFERENTE_ENUNCIADO. Gate CREAR, solo SUPER_ADMIN por defecto. Reglas: (1) el padre debe existir/estar activo/ser del mismo referente/ser el mismo nivel 1 -- no se puede crear una evidencia sin su enunciado, ni anidar mas de 2 niveles; (2) una evidencia nunca elige area (hereda la del padre); (3) el area de un enunciado SIEMPRE es opcional (NULL = aplica a todas las areas), tenga o no el referente areas asociadas; si se manda una, debe ser un area ACTIVA de ese mismo referente.';

-- ===========================================================================
-- fn_refenunc_actualizar
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_refenunc_actualizar(
    p_pk_usuario_solicitante        BIGINT,
    p_pk_referente_enunciado        BIGINT,
    p_texto                         VARCHAR(400) DEFAULT NULL,
    p_estado                        VARCHAR(1)   DEFAULT NULL,
    -- solo aplica a un enunciado (nivel 1); ignorado para evidencias.
    p_fk_referente_curricular_area  BIGINT       DEFAULT NULL,
    p_limpiar_area                  BOOLEAN      DEFAULT FALSE
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_actual  academico_test.TREFERENTE_ENUNCIADO%ROWTYPE;
BEGIN
    SELECT * INTO v_actual
      FROM academico_test.TREFERENTE_ENUNCIADO
     WHERE PK_REFERENTE_ENUNCIADO = p_pk_referente_enunciado;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el enunciado/evidencia solicitado'
            USING ERRCODE = 'P0002';
    END IF;

    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'REFERENTES_CURRICULARES', 'EDITAR'
    );

    IF v_actual.ACTIVE = FALSE THEN
        RAISE EXCEPTION 'Este enunciado/evidencia esta inactivo; no se puede editar'
            USING ERRCODE = '22023';
    END IF;
    IF p_texto IS NOT NULL AND NULLIF(TRIM(p_texto), '') IS NULL THEN
        RAISE EXCEPTION 'Texto no puede quedar vacio' USING ERRCODE = '22023';
    END IF;
    IF p_estado IS NOT NULL AND UPPER(TRIM(p_estado)) NOT IN ('A', 'I') THEN
        RAISE EXCEPTION 'Estado invalido: % (use ''A'' o ''I'')', p_estado USING ERRCODE = '22023';
    END IF;

    IF (p_fk_referente_curricular_area IS NOT NULL OR p_limpiar_area) AND v_actual.FK_PADRE IS NOT NULL THEN
        RAISE EXCEPTION 'Una evidencia no tiene area propia (hereda la de su enunciado padre); no aplica reasignarla'
            USING ERRCODE = '22023';
    END IF;
    IF p_fk_referente_curricular_area IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TREFERENTE_CURRICULAR_AREA
         WHERE PK_REFERENTE_CURRICULAR_AREA = p_fk_referente_curricular_area
           AND FK_REFERENTE_CURRICULAR = v_actual.FK_REFERENTE_CURRICULAR
           AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'FK_REFERENTE_CURRICULAR_AREA (%) no existe, no esta activa o no pertenece a este referente', p_fk_referente_curricular_area
            USING ERRCODE = '23503';
    END IF;

    UPDATE academico_test.TREFERENTE_ENUNCIADO
       SET TEXTO                        = COALESCE(p_texto, TEXTO),
           ESTADO                       = COALESCE(UPPER(TRIM(p_estado)), ESTADO),
           FK_REFERENTE_CURRICULAR_AREA = CASE
               WHEN p_limpiar_area THEN NULL
               ELSE COALESCE(p_fk_referente_curricular_area, FK_REFERENTE_CURRICULAR_AREA)
           END,
           MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_REFERENTE_ENUNCIADO = p_pk_referente_enunciado;

    RETURN p_pk_referente_enunciado;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_refenunc_actualizar(BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT, BOOLEAN)
    IS 'PATCH parcial de TREFERENTE_ENUNCIADO (gate EDITAR, solo SUPER_ADMIN por defecto). FK_PADRE y FK_REFERENTE_CURRICULAR son inmutables (mover un nodo de referente o de nivel no esta soportado; borre y cree de nuevo). p_fk_referente_curricular_area / p_limpiar_area solo aplican a un enunciado (nivel 1); en una evidencia lanzan 22023.';

-- ===========================================================================
-- fn_refenunc_eliminar — soft delete; cascada a evidencias si es enunciado.
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_refenunc_eliminar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_referente_enunciado   BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_actual      academico_test.TREFERENTE_ENUNCIADO%ROWTYPE;
    v_evidencias  BIGINT := 0;
BEGIN
    SELECT * INTO v_actual
      FROM academico_test.TREFERENTE_ENUNCIADO
     WHERE PK_REFERENTE_ENUNCIADO = p_pk_referente_enunciado;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el enunciado/evidencia solicitado'
            USING ERRCODE = 'P0002';
    END IF;

    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'REFERENTES_CURRICULARES', 'ELIMINAR'
    );

    IF v_actual.ACTIVE = FALSE THEN
        RAISE EXCEPTION 'Este enunciado/evidencia ya se encuentra inactivo'
            USING ERRCODE = '22023';
    END IF;

    IF v_actual.FK_PADRE IS NULL THEN
        -- Es un enunciado (nivel 1): cascada a sus evidencias activas.
        UPDATE academico_test.TREFERENTE_ENUNCIADO
           SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_PADRE = p_pk_referente_enunciado
           AND ACTIVE = TRUE;
        GET DIAGNOSTICS v_evidencias = ROW_COUNT;
    END IF;

    UPDATE academico_test.TREFERENTE_ENUNCIADO
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_REFERENTE_ENUNCIADO = p_pk_referente_enunciado;

    RAISE NOTICE 'Soft delete TREFERENTE_ENUNCIADO=% (autor: %): evidencias afectadas=%',
        p_pk_referente_enunciado, p_pk_usuario_solicitante, v_evidencias;

    RETURN p_pk_referente_enunciado;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_refenunc_eliminar(BIGINT, BIGINT)
    IS 'Soft delete (ACTIVE=FALSE) de un enunciado o evidencia (gate ELIMINAR, solo SUPER_ADMIN por defecto). Si es un enunciado (FK_PADRE IS NULL), en cascada da de baja tambien sus evidencias (FK_PADRE = este pk) ACTIVE. Si es una evidencia, solo se da de baja ella misma.';

-- ===========================================================================
-- fn_refenunc_listar — enunciados (nivel 1) de un referente (panel izquierdo).
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_refenunc_listar(
    p_pk_usuario_solicitante        BIGINT,
    p_pk_referente_curricular       BIGINT,
    p_fk_referente_curricular_area  BIGINT   DEFAULT NULL,
    p_incluir_inactivos             BOOLEAN  DEFAULT FALSE
)
RETURNS TABLE (
    pk_referente_enunciado         BIGINT,
    texto                          VARCHAR,
    estado                         VARCHAR,
    active                         BOOLEAN,
    fk_referente_curricular_area   BIGINT,
    total_evidencias                BIGINT
)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'REFERENTES_CURRICULARES', 'VER'
    );

    RETURN QUERY
    SELECT e.PK_REFERENTE_ENUNCIADO, e.TEXTO, e.ESTADO::VARCHAR, e.ACTIVE,
           e.FK_REFERENTE_CURRICULAR_AREA,
           (SELECT COUNT(*) FROM academico_test.TREFERENTE_ENUNCIADO ev
             WHERE ev.FK_PADRE = e.PK_REFERENTE_ENUNCIADO
               AND (p_incluir_inactivos OR ev.ACTIVE = TRUE))
      FROM academico_test.TREFERENTE_ENUNCIADO e
     WHERE e.FK_REFERENTE_CURRICULAR = p_pk_referente_curricular
       AND e.FK_PADRE IS NULL
       AND (p_incluir_inactivos OR e.ACTIVE = TRUE)
       AND (p_fk_referente_curricular_area IS NULL OR e.FK_REFERENTE_CURRICULAR_AREA = p_fk_referente_curricular_area)
     ORDER BY e.PK_REFERENTE_ENUNCIADO;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_refenunc_listar(BIGINT, BIGINT, BIGINT, BOOLEAN)
    IS 'Enunciados (nivel 1, FK_PADRE IS NULL) de un referente, opcionalmente filtrados por FK_REFERENTE_CURRICULAR_AREA (select "Areas o dimensiones" de la pantalla), con el conteo de sus evidencias. Alimenta el panel izquierdo de la pestaña Enunciado. Gate VER.';

-- ===========================================================================
-- fn_refenunc_evidencias_listar — evidencias (nivel 2) de UN enunciado.
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_refenunc_evidencias_listar(
    p_pk_usuario_solicitante          BIGINT,
    p_pk_referente_enunciado_padre    BIGINT,
    p_incluir_inactivos               BOOLEAN  DEFAULT FALSE
)
RETURNS TABLE (
    numero                     BIGINT,
    pk_referente_enunciado     BIGINT,
    texto                      VARCHAR,
    estado                     VARCHAR,
    active                     BOOLEAN
)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'REFERENTES_CURRICULARES', 'VER'
    );

    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TREFERENTE_ENUNCIADO pad
         WHERE pad.PK_REFERENTE_ENUNCIADO = p_pk_referente_enunciado_padre AND pad.FK_PADRE IS NULL
    ) THEN
        RAISE EXCEPTION 'El enunciado padre (%) no existe o no es un enunciado de nivel 1', p_pk_referente_enunciado_padre
            USING ERRCODE = 'P0002';
    END IF;

    RETURN QUERY
    SELECT ROW_NUMBER() OVER (ORDER BY ev.PK_REFERENTE_ENUNCIADO),
           ev.PK_REFERENTE_ENUNCIADO, ev.TEXTO, ev.ESTADO::VARCHAR, ev.ACTIVE
      FROM academico_test.TREFERENTE_ENUNCIADO ev
     WHERE ev.FK_PADRE = p_pk_referente_enunciado_padre
       AND (p_incluir_inactivos OR ev.ACTIVE = TRUE)
     ORDER BY ev.PK_REFERENTE_ENUNCIADO;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_refenunc_evidencias_listar(BIGINT, BIGINT, BOOLEAN)
    IS 'Evidencias (nivel 2, FK_PADRE = p_pk_referente_enunciado_padre) de un enunciado puntual, numeradas -- alimenta la tabla "Evidencias del enunciado" (columna #). P0002 si el padre no existe o no es un enunciado de nivel 1. Gate VER.';
