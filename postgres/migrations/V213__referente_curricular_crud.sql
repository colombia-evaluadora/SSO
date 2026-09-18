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
--     fn_refcurr_crear            — crea el referente + sus niveles
--                                    educativos (obligatorio, N:N, al menos
--                                    uno) + (opcional) su set inicial de
--                                    areas/dimensiones.
--     fn_refcurr_actualizar       — PATCH parcial; p_fk_tnivel_ensenanza_ids
--                                    NULL = no tocar niveles, array =
--                                    reemplazo completo (nunca vacio);
--                                    p_fk_tarea_asignatura_ids NULL = no
--                                    tocar areas, ARRAY[]::BIGINT[] =
--                                    vaciarlas ("aplica a todas").
--     fn_refcurr_eliminar         — soft delete en cascada: evidencias ->
--                                    enunciados -> areas -> niveles ->
--                                    referente. Exige confirmacion explicita
--                                    (p_confirmar_cascada) si hay contenido
--                                    vigente colgando. Ver regla 10.
--     fn_refcurr_listar           — pagina con filtros/orden (pantalla
--                                    "Referentes curriculares").
--     fn_refcurr_buscar_por_pk    — detalle (pestaña "Información general").
--     fn_refcurr_areas_listar     — areas ya asociadas (select de la pestaña
--                                    "Enunciado").
--     fn_refcurr_niveles_listar   — niveles educativos ya asociados
--                                    (multi-select del formulario).
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
--      fuerza ningun valor especial cuando el referente incluye Preescolar
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
--   8) REVISION: unicidad de NOMBRE es POR NIVEL EDUCATIVO, NO solo por
--      NOMBRE -- dos referentes activos pueden compartir nombre si no
--      comparten ningun nivel (p.ej. "DBA" en Basica primaria y "DBA" en
--      Basica secundaria son validos a la vez; dos "DBA" que comparten al
--      menos un nivel siguen dando 23505). Con la relacion N:N de V212
--      (TREFERENTE_CURRICULAR_NIVEL) el chequeo es de SOLAPAMIENTO de sets:
--      implementado en fn_refcurr_crear y fn_refcurr_actualizar (esta
--      ultima evalua el set EFECTIVO, considerando lo que llega en el
--      PATCH y lo que el referente ya tenia).
--   9) REVISION: un referente aplica a UNO O VARIOS niveles educativos
--      (TREFERENTE_CURRICULAR_NIVEL, V212). El set es obligatorio y nunca
--      queda vacio: fn_refcurr_crear exige al menos un nivel (22023) y
--      fn_refcurr_actualizar rechaza un array vacio -- para no tocar los
--      niveles actuales se omite el parametro. A diferencia de las areas,
--      "vacio" NO significa "aplica a todos".
--  10) REVISION: dar de baja el referente NO es lo mismo que inactivarlo.
--      ESTADO ('A'/'I') es un dato de negocio y viaja por
--      fn_refcurr_actualizar, que jamas toca TREFERENTE_ENUNCIADO; ACTIVE
--      es el borrado logico y solo lo apaga fn_refcurr_eliminar. Como los
--      dos endpoints son PATCH sobre el mismo :ID (V214: /:ID vs
--      /:ID/eliminar — ck_query_http_method no admite DELETE), un caller
--      que confunda las rutas se lleva por delante todo el contenido del
--      referente. Defensa en profundidad: fn_refcurr_eliminar rechaza
--      (23503, sin escribir nada) la baja de un referente que todavia
--      tiene enunciados o evidencias ACTIVE=TRUE, salvo que el caller
--      mande p_confirmar_cascada = TRUE. Es la misma forma de la regla 7:
--      primero se limpia el contenido, o se reconoce que se va con el.
--
-- Idempotencia: CREATE OR REPLACE FUNCTION; las funciones cuya FIRMA o
-- cuyo RETURNS TABLE cambio al pasar a la relacion N:N de niveles llevan
-- un DROP FUNCTION IF EXISTS previo con la firma vieja (patron V58) --
-- fn_refcurr_crear, fn_refcurr_actualizar, fn_refcurr_listar y
-- fn_refcurr_buscar_por_pk. El seed de TMENU/TROL_MENU usa WHERE NOT
-- EXISTS (mismo patron V59/V113/V118, sin ON CONFLICT por el indice
-- parcial).
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
-- Cambia el tipo del parametro de nivel educativo (BIGINT -> BIGINT[], N:N
-- via TREFERENTE_CURRICULAR_NIVEL): CREATE OR REPLACE crearia una sobrecarga
-- nueva en vez de reemplazar, hay que borrar la firma vieja (patron V58).
DROP FUNCTION IF EXISTS academico_test.fn_refcurr_crear(BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT, VARCHAR, VARCHAR, INTEGER, VARCHAR, VARCHAR, VARCHAR, INTEGER, VARCHAR, BIGINT[]);
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
        NOMBRE, DESCRIPCION, FK_TLV_ENFOQUE_PEDAGOGICO,
        FK_TLV_TIPO_EVALUACION, NIVEL_1_ETIQUETA, NIVEL_2_ETIQUETA, INSTRUMENTO,
        INSTRUMENTO_INFO_ADICIONAL, NORMATIVIDAD, ANIO_VIGENCIA_DESDE,
        ANIO_VIGENCIA_HASTA, ESTADO, CREATED_BY, CREATED_AT, ACTIVE
    ) VALUES (
        p_nombre, p_descripcion, p_fk_tlv_enfoque_pedagogico,
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

COMMENT ON FUNCTION academico_test.fn_refcurr_crear(BIGINT, VARCHAR, VARCHAR, BIGINT[], BIGINT, BIGINT, VARCHAR, VARCHAR, INTEGER, VARCHAR, VARCHAR, VARCHAR, INTEGER, VARCHAR, BIGINT[])
    IS 'Crea un TREFERENTE_CURRICULAR (gate CREAR, solo SUPER_ADMIN por defecto), sus niveles educativos en TREFERENTE_CURRICULAR_NIVEL (p_fk_tnivel_ensenanza_ids, obligatorio, al menos uno -- N:N) y, si se pasan, sus areas/dimensiones iniciales en TREFERENTE_CURRICULAR_AREA. p_fk_tarea_asignatura_ids NULL o vacio = sin areas ("aplica a todas"). p_estado acepta ''A''/''I'' -- se puede crear inactivo. Retorna PK_REFERENTE_CURRICULAR.';

-- ===========================================================================
-- fn_refcurr_actualizar
-- ===========================================================================
-- Cambia el tipo del parametro de nivel educativo (BIGINT -> BIGINT[]): hay
-- que borrar la firma vieja, si no CREATE OR REPLACE deja una sobrecarga.
DROP FUNCTION IF EXISTS academico_test.fn_refcurr_actualizar(BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, INTEGER, INTEGER, VARCHAR, BIGINT[]);
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
    p_fk_tarea_asignatura_ids       BIGINT[]     DEFAULT NULL
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

COMMENT ON FUNCTION academico_test.fn_refcurr_actualizar(BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT[], BIGINT, BIGINT, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, INTEGER, INTEGER, VARCHAR, BIGINT[])
    IS 'PATCH parcial de TREFERENTE_CURRICULAR (gate EDITAR, solo SUPER_ADMIN por defecto): cada parametro NULL preserva el valor actual. p_fk_tnivel_ensenanza_ids NULL = no tocar los niveles educativos; array = reemplazo completo del set en TREFERENTE_CURRICULAR_NIVEL, nunca vacio (22023: el referente conserva al menos un nivel). p_fk_tarea_asignatura_ids NULL = no tocar areas; ARRAY[]::BIGINT[] = vaciarlas (vuelve a "aplica a todas"); cualquier otro array = reemplazo completo del set, bloqueado (23503) si intenta quitar un area con enunciados activos amarrados.';

-- ===========================================================================
-- fn_refcurr_uso_assert — bloquea la baja de un referente o de un enunciado
-- que ya esta en uso por unidades o actividades. Sin puerta de confirmacion.
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_refcurr_uso_assert(
    p_pk_referente_curricular BIGINT,
    p_pk_referente_enunciado  BIGINT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_unidades    BIGINT;
    v_actividades BIGINT;
    v_que         TEXT;
BEGIN
    WITH enunciados AS (
        SELECT e.PK_REFERENTE_ENUNCIADO
          FROM academico_test.TREFERENTE_ENUNCIADO e
         WHERE (p_pk_referente_enunciado IS NULL AND e.FK_REFERENTE_CURRICULAR = p_pk_referente_curricular)
            OR e.PK_REFERENTE_ENUNCIADO = p_pk_referente_enunciado
            OR e.FK_PADRE = p_pk_referente_enunciado
    )
    SELECT
        (SELECT COUNT(DISTINCT u.PK_TUNIDAD)
           FROM academico_test.TUNIDAD u
          WHERE u.ACTIVE = TRUE
            AND ((p_pk_referente_enunciado IS NULL AND u.FK_REFERENTE_CURRICULAR = p_pk_referente_curricular)
                 OR EXISTS (SELECT 1 FROM academico_test.TUNIDAD_ENUNCIADO ue
                             JOIN enunciados en ON en.PK_REFERENTE_ENUNCIADO = ue.FK_REFERENTE_ENUNCIADO
                            WHERE ue.FK_TUNIDAD = u.PK_TUNIDAD AND ue.ACTIVE = TRUE))),
        (SELECT COUNT(DISTINCT a.PK_TACTIVIDAD)
           FROM academico_test.TACTIVIDAD a
           JOIN academico_test.TACTIVIDAD_EVIDENCIA ae ON ae.FK_TACTIVIDAD = a.PK_TACTIVIDAD AND ae.ACTIVE = TRUE
           JOIN enunciados en ON en.PK_REFERENTE_ENUNCIADO = ae.FK_REFERENTE_ENUNCIADO
          WHERE a.ACTIVE = TRUE)
      INTO v_unidades, v_actividades;

    IF v_unidades > 0 OR v_actividades > 0 THEN
        v_que := CASE WHEN p_pk_referente_enunciado IS NULL THEN 'el referente curricular' ELSE 'el enunciado' END;
        RAISE EXCEPTION 'No se puede eliminar %: esta siendo usado en % unidad(es) y % actividad(es)',
              v_que, v_unidades, v_actividades
            USING ERRCODE = '23503',
                  HINT = 'Retire primero el referente de esas unidades y actividades';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_refcurr_uso_assert(BIGINT, BIGINT)
    IS 'Guarda de uso previa a la baja de un referente curricular (solo primer argumento) o de un enunciado/evidencia (segundo argumento). Cuenta las UNIDADES activas que citan el referente (TUNIDAD.FK_REFERENTE_CURRICULAR) o alguno de sus enunciados (TUNIDAD_ENUNCIADO, V214.1) y las ACTIVIDADES activas que amarran alguna de sus evidencias (TACTIVIDAD_EVIDENCIA, V214.1); para un enunciado se cuentan el y sus evidencias hijas. Si hay alguna, lanza 23503 con el conteo y NO existe forma de confirmar para saltarsela: p_confirmar_cascada de fn_refcurr_eliminar solo cubre el contenido propio del referente (enunciados y evidencias), nunca el trabajo de los docentes que cuelga de el, porque una unidad o una actividad que apunta a un referente inactivo se rompe en silencio en el Planeador. Solo mira filas ACTIVE en las tres tablas: lo ya dado de baja no retiene nada. Helper interno, no gatea; lo invocan fn_refcurr_eliminar y fn_refenunc_eliminar.';

-- ===========================================================================
-- fn_refcurr_eliminar — soft delete en cascada, con confirmacion explicita.
-- ===========================================================================
-- Gana un tercer parametro (p_confirmar_cascada): CREATE OR REPLACE dejaria
-- viva la firma de 2 argumentos y la llamada de 2 argumentos quedaria
-- ambigua, hay que borrar la firma vieja (patron V58).
DROP FUNCTION IF EXISTS academico_test.fn_refcurr_eliminar(BIGINT, BIGINT);
CREATE OR REPLACE FUNCTION academico_test.fn_refcurr_eliminar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_referente_curricular  BIGINT,
    p_confirmar_cascada        BOOLEAN DEFAULT FALSE
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
    v_niveles        BIGINT := 0;
    v_pendientes     BIGINT := 0;
    v_pend_evid      BIGINT := 0;
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

    -- En uso por unidades o actividades: se bloquea, sin confirmacion posible.
    PERFORM academico_test.fn_refcurr_uso_assert(p_pk_referente_curricular);

    -- Regla 10: un referente con contenido vivo no se da de baja "de paso".
    -- Simetrico a la regla 7 (quitar un area con enunciados amarrados): el
    -- caller tiene que reconocer que se lleva por delante los enunciados y
    -- sus evidencias, mandando p_confirmar_cascada = TRUE. Sin eso, 23503 y
    -- no se toca ninguna fila.
    IF NOT COALESCE(p_confirmar_cascada, FALSE) THEN
        SELECT COUNT(*) FILTER (WHERE FK_PADRE IS NULL),
               COUNT(*) FILTER (WHERE FK_PADRE IS NOT NULL)
          INTO v_pendientes, v_pend_evid
          FROM academico_test.TREFERENTE_ENUNCIADO
         WHERE FK_REFERENTE_CURRICULAR = p_pk_referente_curricular
           AND ACTIVE = TRUE;

        IF v_pendientes > 0 OR v_pend_evid > 0 THEN
            RAISE EXCEPTION 'El referente curricular "%" todavia tiene % enunciado(s) y % evidencia(s) vigentes; eliminelos primero o confirme que quiere darlos de baja junto con el referente', v_nombre_actual, v_pendientes, v_pend_evid
                USING ERRCODE = '23503',
                      HINT = 'Repita la peticion con confirmar = true si de verdad quiere dar de baja el referente y todo su contenido';
        END IF;
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

    -- 4. Niveles educativos asociados (N:N, V212).
    UPDATE academico_test.TREFERENTE_CURRICULAR_NIVEL
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_REFERENTE_CURRICULAR = p_pk_referente_curricular
       AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_niveles = ROW_COUNT;

    -- 5. El referente.
    UPDATE academico_test.TREFERENTE_CURRICULAR
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_REFERENTE_CURRICULAR = p_pk_referente_curricular;

    RAISE NOTICE 'Soft delete TREFERENTE_CURRICULAR=% (autor: %): enunciados=%, evidencias=%, areas=%, niveles=%',
        p_pk_referente_curricular, p_pk_usuario_solicitante, v_enunciados, v_evidencias, v_areas, v_niveles;

    RETURN p_pk_referente_curricular;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_refcurr_eliminar(BIGINT, BIGINT, BOOLEAN)
    IS 'Soft delete (ACTIVE=FALSE) de un TREFERENTE_CURRICULAR (gate ELIMINAR, solo SUPER_ADMIN por defecto). Si el referente tiene enunciados o evidencias vigentes exige p_confirmar_cascada = TRUE; sin esa confirmacion lanza 23503 sin tocar ninguna fila (simetrico a la regla 7 de las areas). Confirmada, la baja es en cascada: evidencias (nivel 2) -> enunciados (nivel 1) -> TREFERENTE_CURRICULAR_AREA -> TREFERENTE_CURRICULAR_NIVEL -> el referente. ANTES de todo eso, fn_refcurr_uso_assert bloquea con 23503 si alguna unidad activa cita el referente o uno de sus enunciados, o alguna actividad activa amarra una de sus evidencias: ese bloqueo no se puede confirmar, porque lo que colgaria de un referente inactivo es trabajo de los docentes, no contenido del referente.';

-- ===========================================================================
-- fn_refcurr_listar — pagina con filtros/orden (pantalla listado).
-- ===========================================================================
-- Cambia el RETURNS TABLE (agrega columna): CREATE OR REPLACE no lo permite,
-- hay que borrar la firma vieja primero (mismo patron que V58).
DROP FUNCTION IF EXISTS academico_test.fn_refcurr_listar(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, VARCHAR, BOOLEAN, VARCHAR, BOOLEAN, INT, INT);
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
       AND (p_search IS NULL OR rc.NOMBRE ILIKE '%' || p_search || '%' OR rc.DESCRIPCION ILIKE '%' || p_search || '%')
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
    IS 'Pagina de TREFERENTE_CURRICULAR con filtros (search sobre NOMBRE/DESCRIPCION, nivel educativo -- califica si CUALQUIERA de los niveles del referente coincide, enfoque, tipo de evaluacion, estado) y orden (nombre|nivel_educativo|instrumento|estado). Devuelve niveles_educativos (nombres concatenados, tambien usado para ordenar) y niveles ([{id, codigo, nombre}] de TREFERENTE_CURRICULAR_NIVEL activos), mas instrumento + instrumento_info_adicional (texto complementario del instrumento). total_count via COUNT(*) OVER() para totalCount/pageCount. Gate VER (capability, sin scope: catalogo global). p_incluir_inactivos=FALSE por defecto (solo ACTIVE=TRUE).';

-- ===========================================================================
-- fn_refcurr_buscar_por_pk — detalle (pestaña "Información general").
-- ===========================================================================
-- Cambia el RETURNS TABLE (los dos campos de nivel unico se reemplazan por
-- el arreglo niveles): CREATE OR REPLACE no lo permite, hay que borrar la
-- firma vieja primero (mismo patron que fn_refcurr_listar / V58).
DROP FUNCTION IF EXISTS academico_test.fn_refcurr_buscar_por_pk(BIGINT, BIGINT);
CREATE OR REPLACE FUNCTION academico_test.fn_refcurr_buscar_por_pk(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_referente_curricular  BIGINT
)
RETURNS TABLE (
    pk_referente_curricular    BIGINT,
    nombre                     VARCHAR,
    descripcion                VARCHAR,
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
    SELECT rc.PK_REFERENTE_CURRICULAR, rc.NOMBRE, rc.DESCRIPCION,
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
    IS 'Detalle de un TREFERENTE_CURRICULAR (pestaña "Información general"), con los niveles educativos como arreglo JSONB [{id, codigo, nombre}] (relacion N:N, V212) y nombres resueltos de enfoque/tipo de evaluacion. SETOF 0 o 1 fila (incluye inactivos: el caller decide si los muestra). Gate VER.';

-- ===========================================================================
-- fn_refcurr_niveles_listar — niveles educativos ya asociados al referente
-- (multi-select "Nivel educativo" del formulario de edicion). Mismo patron
-- que fn_refcurr_areas_listar.
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_refcurr_niveles_listar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_referente_curricular  BIGINT
)
RETURNS TABLE (
    pk_referente_curricular_nivel  BIGINT,
    fk_tnivel_ensenanza            BIGINT,
    codigo                         VARCHAR,
    nombre                         VARCHAR
)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'REFERENTES_CURRICULARES', 'VER'
    );

    RETURN QUERY
    SELECT rcn.PK_REFERENTE_CURRICULAR_NIVEL, rcn.FK_TNIVEL_ENSENANZA, ne.CODIGO, ne.NOMBRE
      FROM academico_test.TREFERENTE_CURRICULAR_NIVEL rcn
      JOIN academico_test.TNIVEL_ENSENANZA ne ON ne.PK_NIVEL_ENSENANZA = rcn.FK_TNIVEL_ENSENANZA
     WHERE rcn.FK_REFERENTE_CURRICULAR = p_pk_referente_curricular
       AND rcn.ACTIVE = TRUE
     ORDER BY ne.NOMBRE;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_refcurr_niveles_listar(BIGINT, BIGINT)
    IS 'Niveles educativos ACTIVE asociados a un referente (TREFERENTE_CURRICULAR_NIVEL, N:N), con codigo y nombre de TNIVEL_ENSENANZA -- precarga el multi-select "Nivel educativo". Nunca deberia devolver 0 filas para un referente activo (el set es obligatorio). Gate VER.';

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

    -- En uso por unidades o actividades: se bloquea (mismo guard del referente).
    PERFORM academico_test.fn_refcurr_uso_assert(v_actual.FK_REFERENTE_CURRICULAR, p_pk_referente_enunciado);

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
    IS 'Soft delete (ACTIVE=FALSE) de un enunciado o evidencia (gate ELIMINAR, solo SUPER_ADMIN por defecto). Si es un enunciado (FK_PADRE IS NULL), en cascada da de baja tambien sus evidencias (FK_PADRE = este pk) ACTIVE. Si es una evidencia, solo se da de baja ella misma. En ambos casos fn_refcurr_uso_assert bloquea antes con 23503 si el enunciado (o alguna de sus evidencias) esta amarrado a una unidad o actividad activa.';

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
