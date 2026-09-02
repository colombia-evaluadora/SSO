-- ===========================================================================
-- V216 — Planeador educativo: CRUD de la unidad tematica (crear / listar /
-- editar / eliminar soft) con sus contenidos, objetivos, referente
-- curricular y forma de calculo de nota
-- (CU-86e311xxp — G. Academico Back Planeador educativo).
--
-- Contexto (pantallas "Nueva unidad" / "Unidad tematica" del Planeador):
-- al crear/editar una unidad el docente captura, ademas de la
-- identificacion (nombre, asignatura, grado, autor):
--   * Objetivos especificos de la unidad    -> TUNIDAD_OBJETIVO  (uno por
--     fila, ORDEN = posicion en la lista).
--   * Contenidos / componentes de la unidad -> TUNIDAD_CONTENIDO (idem).
--   * Referente curricular al que se acoge (DBA / Propositos e
--     Imprescindibles / ...) -> TUNIDAD.FK_REFERENTE_CURRICULAR, opcional
--     (V212, rama CU-86e311xqh).
--   * "Forma en que se van a calcular las actividades dentro de la unidad"
--     (Promediar / Ponderar / Sumatoria de Actividades) ->
--     TUNIDAD.FK_TLV_CALCULO_DEFINITIVA, TLISTA_VALOR CATEGORIA=
--     'CALCULO_DEFINITIVA' (V73, rama CU-86e30a25v). OBLIGATORIO al crear.
--
-- La unidad YA NO esta atada a un periodo de evaluacion: V218
-- (CU-86e329pvq) elimino TUNIDAD.FK_TPERIODO_EVALUACION y recompuso el
-- UNIQUE UN_TUNIDAD_1 como (NOMBRE, FK_TASIGNATURA, FK_TGRADO). Tambien
-- hizo TACTIVIDAD.FK_TUNIDAD NULLABLE (la actividad ya no exige unidad) y
-- agrego TACTIVIDAD.FK_TASIGNATURA. Este archivo se escribe para ese estado.
--
-- Fechas de la unidad ("10/02/2025 – 28/02/2025" en el listado): se
-- DERIVAN de MIN(FECHA_INICIO) / MAX(FECHA_CIERRE) de las actividades
-- activas de la unidad; TUNIDAD no tiene fechas propias.
--
-- Depende de (se aplican antes por orden de version de Flyway):
--   * V22  — TUNIDAD, TUNIDAD_CONTENIDO, TUNIDAD_OBJETIVO, TACTIVIDAD,
--            TRUBRICA_UNIDAD, TCRITERIO_UNIDAD, TNIVEL_CRITERIO_UNIDAD,
--            TCRITERIO_EVALUACION, TESCALA_VALORACION.
--   * V73  — TUNIDAD.FK_TLV_CALCULO_DEFINITIVA + catalogo CALCULO_DEFINITIVA.
--   * V212 — TREFERENTE_CURRICULAR + TUNIDAD.FK_REFERENTE_CURRICULAR.
--   * V218 — TUNIDAD sin FK_TPERIODO_EVALUACION, UN_TUNIDAD_1 (NOMBRE,
--            FK_TASIGNATURA, FK_TGRADO), TACTIVIDAD.FK_TUNIDAD nullable.
--   * V29/V185/V213 — modelo de capability por menu (fn_assert_permiso_seccion).
--
-- Nomenclatura/estilo: sigue V213 (fn_ con gate fn_assert_permiso_seccion,
-- validaciones 22023/23503/23505/P0002, PATCH parcial con COALESCE,
-- CREATED_BY = usuario solicitante, soft delete en cascada, listado
-- paginado con COUNT(*) OVER(), COMMENT ON FUNCTION) y V59/V113/V213 (seed
-- de TMENU/TROL_MENU via WHERE NOT EXISTS, sin ON CONFLICT — indice parcial).
--
-- AUTORIZACION: gate fn_assert_permiso_seccion(usuario, 'PLANEADOR',
-- <accion>), sin scope territorial (el alcance fino por asignatura/grupo se
-- valida en la capa de asignacion, fuera de esta migracion). Seed nuevo:
-- menu 'PLANEADOR' concedido a DOCENTE y SUPER_ADMINISTRADOR (4 permisos).
--
-- Fuera de alcance: el vinculo fino unidad <-> enunciado concreto del
-- referente (hoy la unidad se acoge al referente completo via
-- FK_REFERENTE_CURRICULAR) y el CRUD de actividades/rubricas de la unidad.
-- ===========================================================================

SET search_path TO academico_test, public;

-- ---------------------------------------------------------------------------
-- (A) TMENU — grupo top-level 'PLANEADOR'.
-- ---------------------------------------------------------------------------
INSERT INTO academico_test.tmenu (codigo, nombre, icono, visible, estado, url, fk_tmenu, orden, created_by)
SELECT 'PLANEADOR', 'Planeador', 'CalendarCheck-Icon', 'S', 'A',
       '/academico/planeador', NULL, 6::NUMERIC, 'V216_seed'
 WHERE NOT EXISTS (
     SELECT 1 FROM academico_test.tmenu m
      WHERE m.codigo = 'PLANEADOR' AND m.active = TRUE
 );

-- ---------------------------------------------------------------------------
-- (B) TROL_MENU — concede el menu a DOCENTE y SUPER_ADMINISTRADOR.
-- ---------------------------------------------------------------------------
INSERT INTO academico_test.trol_menu (fk_trol, fk_tmenu, orden_rol, active, created_by)
SELECT t.pk_trol, m.pk_tmenu, 1, TRUE, 'V216_seed'
  FROM academico_test.tmenu m
 CROSS JOIN academico_test.trol t
 WHERE t.codigo IN ('DOCENTE', 'SUPER_ADMINISTRADOR')
   AND t.active = TRUE
   AND m.codigo = 'PLANEADOR'
   AND m.active = TRUE
   AND NOT EXISTS (
       SELECT 1 FROM academico_test.trol_menu tm
        WHERE tm.fk_trol = t.pk_trol AND tm.fk_tmenu = m.pk_tmenu AND tm.active = TRUE
       );

-- ===========================================================================
-- fn_unidad_crear
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_crear(
    p_pk_usuario_solicitante        BIGINT,
    p_nombre                        VARCHAR(250),
    p_fk_tasignatura                BIGINT,
    p_fk_tgrado                     BIGINT,
    p_fk_tfuncionario               BIGINT,
    p_fk_tlv_calculo_definitiva     BIGINT,
    p_descripcion                   VARCHAR(4000) DEFAULT NULL,
    p_fk_referente_curricular       BIGINT        DEFAULT NULL,
    -- Uno por elemento; el ORDEN se toma de la posicion en el array.
    -- Elementos NULL o en blanco se ignoran.
    p_objetivos                     VARCHAR[]     DEFAULT NULL,
    p_contenidos                    VARCHAR[]     DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_id_creado  BIGINT;
BEGIN
    -- 0. Gate: capability CREAR sobre PLANEADOR (sin scope territorial).
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'CREAR'
    );

    -- 1. Obligatorios.
    IF NULLIF(TRIM(p_nombre), '') IS NULL THEN
        RAISE EXCEPTION 'El nombre de la unidad es obligatorio'
            USING ERRCODE = '22023', HINT = 'p_nombre no puede ser NULL ni vacio';
    END IF;
    IF p_fk_tasignatura IS NULL THEN
        RAISE EXCEPTION 'La asignatura (FK_TASIGNATURA) es obligatoria' USING ERRCODE = '22023';
    END IF;
    IF p_fk_tgrado IS NULL THEN
        RAISE EXCEPTION 'El grado (FK_TGRADO) es obligatorio' USING ERRCODE = '22023';
    END IF;
    IF p_fk_tfuncionario IS NULL THEN
        RAISE EXCEPTION 'El docente autor (FK_TFUNCIONARIO) es obligatorio' USING ERRCODE = '22023';
    END IF;
    IF p_fk_tlv_calculo_definitiva IS NULL THEN
        RAISE EXCEPTION 'La forma de calculo de la nota (FK_TLV_CALCULO_DEFINITIVA) es obligatoria'
            USING ERRCODE = '22023', HINT = 'Promediar / Ponderar / Sumatoria de Actividades';
    END IF;

    -- 2. FKs existen y estan activas.
    IF NOT EXISTS (SELECT 1 FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_fk_tasignatura AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'FK_TASIGNATURA (%) no existe o no esta activa', p_fk_tasignatura USING ERRCODE = '23503';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_tgrado AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'FK_TGRADO (%) no existe o no esta activo', p_fk_tgrado USING ERRCODE = '23503';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM academico_test.TFUNCIONARIO WHERE PK_TFUNCIONARIO = p_fk_tfuncionario AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'FK_TFUNCIONARIO (%) no existe o no esta activo', p_fk_tfuncionario USING ERRCODE = '23503';
    END IF;

    -- 2.a Forma de calculo de la nota de la unidad (obligatoria).
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_fk_tlv_calculo_definitiva
           AND CATEGORIA = 'CALCULO_DEFINITIVA'
           AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'FK_TLV_CALCULO_DEFINITIVA (%) no existe, no esta activo o no es de la categoria CALCULO_DEFINITIVA', p_fk_tlv_calculo_definitiva
            USING ERRCODE = '23503';
    END IF;

    -- 2.b Referente curricular al que se acoge la unidad (opcional).
    IF p_fk_referente_curricular IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TREFERENTE_CURRICULAR
         WHERE PK_REFERENTE_CURRICULAR = p_fk_referente_curricular
           AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'FK_REFERENTE_CURRICULAR (%) no existe o no esta activo', p_fk_referente_curricular
            USING ERRCODE = '23503';
    END IF;

    -- 3. Unicidad (NOMBRE, asignatura, grado) entre unidades activas —
    --    backstop del constraint UN_TUNIDAD_1 (V218).
    IF EXISTS (
        SELECT 1 FROM academico_test.TUNIDAD
         WHERE UPPER(TRIM(NOMBRE)) = UPPER(TRIM(p_nombre))
           AND FK_TASIGNATURA = p_fk_tasignatura
           AND FK_TGRADO = p_fk_tgrado
           AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'Ya existe una unidad activa "%" para esa asignatura y grado', p_nombre
            USING ERRCODE = '23505';
    END IF;

    -- 4. INSERT de la unidad.
    INSERT INTO academico_test.TUNIDAD (
        NOMBRE, FK_TASIGNATURA, FK_TGRADO, FK_TFUNCIONARIO,
        DESCRIPCION, FK_TLV_CALCULO_DEFINITIVA, FK_REFERENTE_CURRICULAR,
        CREATED_BY, CREATED_AT, ACTIVE
    ) VALUES (
        TRIM(p_nombre), p_fk_tasignatura, p_fk_tgrado, p_fk_tfuncionario,
        NULLIF(TRIM(p_descripcion), ''), p_fk_tlv_calculo_definitiva, p_fk_referente_curricular,
        p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
    )
    RETURNING PK_TUNIDAD INTO v_id_creado;

    -- 5. Objetivos (opcional) — ORDEN por posicion, se ignoran los vacios.
    IF p_objetivos IS NOT NULL THEN
        INSERT INTO academico_test.TUNIDAD_OBJETIVO (FK_TUNIDAD, ORDEN, DESCRIPCION, CREATED_BY, CREATED_AT, ACTIVE)
        SELECT v_id_creado,
               ROW_NUMBER() OVER (ORDER BY o.pos),
               TRIM(o.txt),
               p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
          FROM unnest(p_objetivos) WITH ORDINALITY AS o(txt, pos)
         WHERE NULLIF(TRIM(o.txt), '') IS NOT NULL;
    END IF;

    -- 6. Contenidos / componentes (opcional) — misma regla.
    IF p_contenidos IS NOT NULL THEN
        INSERT INTO academico_test.TUNIDAD_CONTENIDO (FK_TUNIDAD, ORDEN, DESCRIPCION, CREATED_BY, CREATED_AT, ACTIVE)
        SELECT v_id_creado,
               ROW_NUMBER() OVER (ORDER BY c.pos),
               TRIM(c.txt),
               p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
          FROM unnest(p_contenidos) WITH ORDINALITY AS c(txt, pos)
         WHERE NULLIF(TRIM(c.txt), '') IS NOT NULL;
    END IF;

    RETURN v_id_creado;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_crear(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, VARCHAR, BIGINT, VARCHAR[], VARCHAR[])
    IS 'Crea una unidad tematica del Planeador (gate CREAR sobre PLANEADOR): inserta TUNIDAD (identificacion nombre/asignatura/grado/autor + DESCRIPCION + FK_TLV_CALCULO_DEFINITIVA [forma de calculo de la nota, catalogo CALCULO_DEFINITIVA, OBLIGATORIA, V73] + FK_REFERENTE_CURRICULAR [referente al que se acoge, opcional, V212]) y, si se pasan, sus objetivos (TUNIDAD_OBJETIVO) y contenidos/componentes (TUNIDAD_CONTENIDO) con ORDEN por posicion del array, ignorando los vacios. La unidad ya no depende de un periodo de evaluacion (V218). Valida existencia/estado de todas las FKs y unicidad (nombre, asignatura, grado) entre unidades activas. Retorna PK_TUNIDAD.';

-- ===========================================================================
-- fn_unidad_listar — pagina con filtros/orden (pantalla "Unidad tematica").
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_listar(
    p_pk_usuario_solicitante      BIGINT,
    p_search                      VARCHAR   DEFAULT NULL,
    p_fk_tasignatura              BIGINT    DEFAULT NULL,
    p_fk_tgrado                   BIGINT    DEFAULT NULL,
    p_fk_tfuncionario             BIGINT    DEFAULT NULL,
    p_incluir_inactivos           BOOLEAN   DEFAULT FALSE,
    p_orden_por                   VARCHAR   DEFAULT 'nombre',
    p_orden_asc                   BOOLEAN   DEFAULT TRUE,
    p_limite                      INT       DEFAULT 20,
    p_offset                      INT       DEFAULT 0
)
RETURNS TABLE (
    pk_tunidad                  BIGINT,
    nombre                      VARCHAR,
    descripcion                 VARCHAR,
    fk_tasignatura              BIGINT,
    asignatura                  VARCHAR,
    fk_tarea                    BIGINT,
    area                        VARCHAR,
    fk_tgrado                   BIGINT,
    grado                       VARCHAR,
    fk_tfuncionario             BIGINT,
    docente                     VARCHAR,
    fk_tlv_calculo_definitiva   BIGINT,
    calculo_definitiva          VARCHAR,
    fk_referente_curricular     BIGINT,
    referente_curricular        VARCHAR,
    total_actividades           BIGINT,
    total_objetivos             BIGINT,
    total_contenidos            BIGINT,
    fecha_inicio                DATE,
    fecha_fin                   DATE,
    active                      BOOLEAN,
    total_count                 BIGINT
)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    RETURN QUERY
    SELECT u.PK_TUNIDAD,
           u.NOMBRE,
           u.DESCRIPCION,
           u.FK_TASIGNATURA,
           asig.NOMBRE,
           asig.FK_TAREA,
           ar.NOMBRE,
           u.FK_TGRADO,
           gr.NOMBRE,
           u.FK_TFUNCIONARIO,
           NULLIF(TRIM(CONCAT_WS(' ', us.PRIMER_NOMBRE, us.SEGUNDO_NOMBRE, us.PRIMER_APELLIDO, us.SEGUNDO_APELLIDO)), '')::VARCHAR,
           u.FK_TLV_CALCULO_DEFINITIVA,
           lvc.NOMBRE,
           u.FK_REFERENTE_CURRICULAR,
           rc.NOMBRE,
           (SELECT COUNT(*) FROM academico_test.TACTIVIDAD a       WHERE a.FK_TUNIDAD = u.PK_TUNIDAD AND a.ACTIVE = TRUE),
           (SELECT COUNT(*) FROM academico_test.TUNIDAD_OBJETIVO o  WHERE o.FK_TUNIDAD = u.PK_TUNIDAD AND o.ACTIVE = TRUE),
           (SELECT COUNT(*) FROM academico_test.TUNIDAD_CONTENIDO c WHERE c.FK_TUNIDAD = u.PK_TUNIDAD AND c.ACTIVE = TRUE),
           (SELECT MIN(a.FECHA_INICIO) FROM academico_test.TACTIVIDAD a WHERE a.FK_TUNIDAD = u.PK_TUNIDAD AND a.ACTIVE = TRUE),
           (SELECT MAX(a.FECHA_CIERRE) FROM academico_test.TACTIVIDAD a WHERE a.FK_TUNIDAD = u.PK_TUNIDAD AND a.ACTIVE = TRUE),
           u.ACTIVE,
           COUNT(*) OVER()
      FROM academico_test.TUNIDAD u
      JOIN academico_test.TASIGNATURA asig       ON asig.PK_TASIGNATURA = u.FK_TASIGNATURA
      LEFT JOIN academico_test.TAREA ar          ON ar.PK_TAREA = asig.FK_TAREA
      JOIN academico_test.TGRADO gr              ON gr.PK_TGRADO = u.FK_TGRADO
      LEFT JOIN academico_test.TFUNCIONARIO fu   ON fu.PK_TFUNCIONARIO = u.FK_TFUNCIONARIO
      LEFT JOIN academico_test.TUSUARIO us       ON us.PK_TUSUARIO = fu.FK_TUSUARIO
      LEFT JOIN academico_test.TLISTA_VALOR lvc  ON lvc.PK_LISTA_VALOR = u.FK_TLV_CALCULO_DEFINITIVA
      LEFT JOIN academico_test.TREFERENTE_CURRICULAR rc ON rc.PK_REFERENTE_CURRICULAR = u.FK_REFERENTE_CURRICULAR
     WHERE (p_incluir_inactivos OR u.ACTIVE = TRUE)
       AND (p_search IS NULL OR u.NOMBRE ILIKE '%' || p_search || '%' OR u.DESCRIPCION ILIKE '%' || p_search || '%')
       AND (p_fk_tasignatura IS NULL OR u.FK_TASIGNATURA = p_fk_tasignatura)
       AND (p_fk_tgrado IS NULL OR u.FK_TGRADO = p_fk_tgrado)
       AND (p_fk_tfuncionario IS NULL OR u.FK_TFUNCIONARIO = p_fk_tfuncionario)
     ORDER BY
       CASE WHEN p_orden_asc THEN
           CASE LOWER(TRIM(COALESCE(p_orden_por, 'nombre')))
               WHEN 'nombre'     THEN u.NOMBRE
               WHEN 'asignatura' THEN asig.NOMBRE
               WHEN 'grado'      THEN gr.NOMBRE
               ELSE u.NOMBRE
           END
       END ASC,
       CASE WHEN NOT p_orden_asc THEN
           CASE LOWER(TRIM(COALESCE(p_orden_por, 'nombre')))
               WHEN 'nombre'     THEN u.NOMBRE
               WHEN 'asignatura' THEN asig.NOMBRE
               WHEN 'grado'      THEN gr.NOMBRE
               ELSE u.NOMBRE
           END
       END DESC
     LIMIT GREATEST(p_limite, 1)
    OFFSET GREATEST(p_offset, 0);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_listar(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, BOOLEAN, VARCHAR, BOOLEAN, INT, INT)
    IS 'Pagina de TUNIDAD con filtros (search sobre NOMBRE/DESCRIPCION, asignatura, grado, docente) y orden (nombre|asignatura|grado). Devuelve nombres resueltos (asignatura, area via TASIGNATURA.FK_TAREA->TAREA -- la etiqueta "Comunicativa/Cognitiva/..." de las tarjetas), forma de calculo, referente curricular, conteos de actividades/objetivos/contenidos activos y las fechas DERIVADAS de la unidad (MIN FECHA_INICIO / MAX FECHA_CIERRE de sus actividades activas). La unidad ya no depende de un periodo de evaluacion (V218). total_count via COUNT(*) OVER(). Gate VER. p_incluir_inactivos=FALSE por defecto.';

-- ===========================================================================
-- fn_unidad_actualizar — PATCH parcial (cada parametro NULL preserva).
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_actualizar(
    p_pk_usuario_solicitante        BIGINT,
    p_pk_tunidad                    BIGINT,
    p_nombre                        VARCHAR(250)  DEFAULT NULL,
    p_descripcion                   VARCHAR(4000) DEFAULT NULL,
    p_fk_tasignatura                BIGINT        DEFAULT NULL,
    p_fk_tgrado                     BIGINT        DEFAULT NULL,
    p_fk_tfuncionario               BIGINT        DEFAULT NULL,
    p_fk_tlv_calculo_definitiva     BIGINT        DEFAULT NULL,
    p_fk_referente_curricular       BIGINT        DEFAULT NULL,
    -- NULL param no distingue "no tocar" de "quitar" el referente:
    -- p_limpiar_referente = TRUE fuerza FK_REFERENTE_CURRICULAR a NULL.
    p_limpiar_referente             BOOLEAN       DEFAULT FALSE,
    -- NULL = no tocar la lista; array (incl. vacio) = reemplazo completo:
    -- se desactivan los activos y se re-insertan los del array.
    p_objetivos                     VARCHAR[]     DEFAULT NULL,
    p_contenidos                    VARCHAR[]     DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_actual   academico_test.TUNIDAD%ROWTYPE;
    v_nombre   VARCHAR(250);
    v_asig     BIGINT;
    v_grado    BIGINT;
BEGIN
    SELECT * INTO v_actual
      FROM academico_test.TUNIDAD
     WHERE PK_TUNIDAD = p_pk_tunidad;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la unidad tematica solicitada'
            USING ERRCODE = 'P0002';
    END IF;

    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'EDITAR'
    );

    IF v_actual.ACTIVE = FALSE THEN
        RAISE EXCEPTION 'La unidad "%" esta inactiva (borrado logico); no se puede editar', v_actual.NOMBRE
            USING ERRCODE = '22023';
    END IF;

    IF p_nombre IS NOT NULL AND NULLIF(TRIM(p_nombre), '') IS NULL THEN
        RAISE EXCEPTION 'El nombre de la unidad no puede quedar vacio' USING ERRCODE = '22023';
    END IF;

    -- FKs nuevas (solo si vienen) existen y estan activas.
    IF p_fk_tasignatura IS NOT NULL AND NOT EXISTS (SELECT 1 FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_fk_tasignatura AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'FK_TASIGNATURA (%) no existe o no esta activa', p_fk_tasignatura USING ERRCODE = '23503';
    END IF;
    IF p_fk_tgrado IS NOT NULL AND NOT EXISTS (SELECT 1 FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_tgrado AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'FK_TGRADO (%) no existe o no esta activo', p_fk_tgrado USING ERRCODE = '23503';
    END IF;
    IF p_fk_tfuncionario IS NOT NULL AND NOT EXISTS (SELECT 1 FROM academico_test.TFUNCIONARIO WHERE PK_TFUNCIONARIO = p_fk_tfuncionario AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'FK_TFUNCIONARIO (%) no existe o no esta activo', p_fk_tfuncionario USING ERRCODE = '23503';
    END IF;
    IF p_fk_tlv_calculo_definitiva IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_fk_tlv_calculo_definitiva AND CATEGORIA = 'CALCULO_DEFINITIVA' AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'FK_TLV_CALCULO_DEFINITIVA (%) no existe, no esta activo o no es de la categoria CALCULO_DEFINITIVA', p_fk_tlv_calculo_definitiva
            USING ERRCODE = '23503';
    END IF;
    IF NOT p_limpiar_referente AND p_fk_referente_curricular IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TREFERENTE_CURRICULAR WHERE PK_REFERENTE_CURRICULAR = p_fk_referente_curricular AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'FK_REFERENTE_CURRICULAR (%) no existe o no esta activo', p_fk_referente_curricular USING ERRCODE = '23503';
    END IF;

    -- Unicidad con los valores resultantes (NOMBRE, asignatura, grado).
    v_nombre := COALESCE(NULLIF(TRIM(p_nombre), ''), v_actual.NOMBRE);
    v_asig   := COALESCE(p_fk_tasignatura, v_actual.FK_TASIGNATURA);
    v_grado  := COALESCE(p_fk_tgrado, v_actual.FK_TGRADO);
    IF EXISTS (
        SELECT 1 FROM academico_test.TUNIDAD
         WHERE UPPER(TRIM(NOMBRE)) = UPPER(TRIM(v_nombre))
           AND FK_TASIGNATURA = v_asig
           AND FK_TGRADO = v_grado
           AND ACTIVE = TRUE
           AND PK_TUNIDAD <> p_pk_tunidad
    ) THEN
        RAISE EXCEPTION 'Ya existe otra unidad activa "%" para esa asignatura y grado', v_nombre
            USING ERRCODE = '23505';
    END IF;

    UPDATE academico_test.TUNIDAD
       SET NOMBRE                    = v_nombre,
           DESCRIPCION               = CASE WHEN p_descripcion IS NULL THEN DESCRIPCION
                                            ELSE NULLIF(TRIM(p_descripcion), '') END,
           FK_TASIGNATURA            = v_asig,
           FK_TGRADO                 = v_grado,
           FK_TFUNCIONARIO           = COALESCE(p_fk_tfuncionario, FK_TFUNCIONARIO),
           FK_TLV_CALCULO_DEFINITIVA = COALESCE(p_fk_tlv_calculo_definitiva, FK_TLV_CALCULO_DEFINITIVA),
           FK_REFERENTE_CURRICULAR   = CASE WHEN p_limpiar_referente THEN NULL
                                            ELSE COALESCE(p_fk_referente_curricular, FK_REFERENTE_CURRICULAR) END,
           MODIFIED_BY               = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT               = CURRENT_TIMESTAMP
     WHERE PK_TUNIDAD = p_pk_tunidad;

    -- Objetivos: reemplazo completo solo si el caller mando el parametro.
    IF p_objetivos IS NOT NULL THEN
        UPDATE academico_test.TUNIDAD_OBJETIVO
           SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TUNIDAD = p_pk_tunidad AND ACTIVE = TRUE;

        INSERT INTO academico_test.TUNIDAD_OBJETIVO (FK_TUNIDAD, ORDEN, DESCRIPCION, CREATED_BY, CREATED_AT, ACTIVE)
        SELECT p_pk_tunidad, ROW_NUMBER() OVER (ORDER BY o.pos), TRIM(o.txt),
               p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
          FROM unnest(p_objetivos) WITH ORDINALITY AS o(txt, pos)
         WHERE NULLIF(TRIM(o.txt), '') IS NOT NULL;
    END IF;

    -- Contenidos: idem.
    IF p_contenidos IS NOT NULL THEN
        UPDATE academico_test.TUNIDAD_CONTENIDO
           SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TUNIDAD = p_pk_tunidad AND ACTIVE = TRUE;

        INSERT INTO academico_test.TUNIDAD_CONTENIDO (FK_TUNIDAD, ORDEN, DESCRIPCION, CREATED_BY, CREATED_AT, ACTIVE)
        SELECT p_pk_tunidad, ROW_NUMBER() OVER (ORDER BY c.pos), TRIM(c.txt),
               p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
          FROM unnest(p_contenidos) WITH ORDINALITY AS c(txt, pos)
         WHERE NULLIF(TRIM(c.txt), '') IS NOT NULL;
    END IF;

    RETURN p_pk_tunidad;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_actualizar(BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, BOOLEAN, VARCHAR[], VARCHAR[])
    IS 'PATCH parcial de TUNIDAD (gate EDITAR): cada parametro NULL preserva el valor actual. p_limpiar_referente=TRUE fuerza FK_REFERENTE_CURRICULAR a NULL. p_objetivos / p_contenidos NULL = no tocar; cualquier array (incl. vacio) = reemplazo completo (desactiva los activos y re-inserta con ORDEN por posicion, ignora vacios). Revalida FKs y unicidad (nombre, asignatura, grado) -- la unidad ya no depende de un periodo de evaluacion (V218). Retorna PK_TUNIDAD.';

-- ===========================================================================
-- fn_unidad_eliminar — soft delete en cascada.
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_eliminar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tunidad               BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_active         BOOLEAN;
    v_nombre         VARCHAR;
    v_actividades    BIGINT := 0;
    v_objetivos      BIGINT := 0;
    v_contenidos     BIGINT := 0;
    v_criterios      BIGINT := 0;
BEGIN
    SELECT ACTIVE, NOMBRE INTO v_active, v_nombre
      FROM academico_test.TUNIDAD
     WHERE PK_TUNIDAD = p_pk_tunidad;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la unidad tematica solicitada'
            USING ERRCODE = 'P0002';
    END IF;

    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'ELIMINAR'
    );

    IF v_active = FALSE THEN
        RAISE EXCEPTION 'La unidad "%" ya se encuentra inactiva', v_nombre
            USING ERRCODE = '22023';
    END IF;

    -- Bloqueo: no se elimina una unidad que todavia tiene actividades activas
    -- vinculadas (TACTIVIDAD.FK_TUNIDAD es opcional desde V218, pero si hay
    -- actividades apuntando a esta unidad hay que soltarlas/eliminarlas antes).
    SELECT COUNT(*) INTO v_actividades
      FROM academico_test.TACTIVIDAD
     WHERE FK_TUNIDAD = p_pk_tunidad AND ACTIVE = TRUE;
    IF v_actividades > 0 THEN
        RAISE EXCEPTION 'La unidad "%" tiene % actividad(es) activa(s) vinculada(s); desvinculelas o eliminelas antes de eliminar la unidad', v_nombre, v_actividades
            USING ERRCODE = '23503';
    END IF;

    -- 1. Niveles de criterio de la rubrica de la unidad.
    UPDATE academico_test.TNIVEL_CRITERIO_UNIDAD ncu
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
      FROM academico_test.TCRITERIO_UNIDAD cu
      JOIN academico_test.TRUBRICA_UNIDAD ru ON ru.PK_TRUBRICA_UNIDAD = cu.FK_TRUBRICA_UNIDAD
     WHERE ncu.FK_TCRITERIO_UNIDAD = cu.PK_TCRITERIO_UNIDAD
       AND ru.FK_TUNIDAD = p_pk_tunidad
       AND ncu.ACTIVE = TRUE;

    -- 2. Criterios de la rubrica de la unidad.
    UPDATE academico_test.TCRITERIO_UNIDAD cu
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
      FROM academico_test.TRUBRICA_UNIDAD ru
     WHERE cu.FK_TRUBRICA_UNIDAD = ru.PK_TRUBRICA_UNIDAD
       AND ru.FK_TUNIDAD = p_pk_tunidad
       AND cu.ACTIVE = TRUE;
    GET DIAGNOSTICS v_criterios = ROW_COUNT;

    -- 3. Rubrica de la unidad.
    UPDATE academico_test.TRUBRICA_UNIDAD
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TUNIDAD = p_pk_tunidad AND ACTIVE = TRUE;

    -- 4. Objetivos.
    UPDATE academico_test.TUNIDAD_OBJETIVO
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TUNIDAD = p_pk_tunidad AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_objetivos = ROW_COUNT;

    -- 5. Contenidos.
    UPDATE academico_test.TUNIDAD_CONTENIDO
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TUNIDAD = p_pk_tunidad AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_contenidos = ROW_COUNT;

    -- 6. La unidad.
    UPDATE academico_test.TUNIDAD
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TUNIDAD = p_pk_tunidad;

    RAISE NOTICE 'Soft delete TUNIDAD=% (autor: %): objetivos=%, contenidos=%, criterios_rubrica=%',
        p_pk_tunidad, p_pk_usuario_solicitante, v_objetivos, v_contenidos, v_criterios;

    RETURN p_pk_tunidad;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_eliminar(BIGINT, BIGINT)
    IS 'Soft delete (ACTIVE=FALSE) de una TUNIDAD (gate ELIMINAR), en cascada: niveles -> criterios -> rubrica de la unidad, objetivos, contenidos y la unidad. Se BLOQUEA (23503) si la unidad todavia tiene actividades activas vinculadas (TACTIVIDAD.FK_TUNIDAD): el caller debe desvincularlas o eliminarlas primero. Retorna PK_TUNIDAD.';

-- ===========================================================================
-- fn_unidad_criterio_agregar — agrega un criterio a la rubrica de la unidad
-- con un indicador (descriptor) por cada valoracion de la ESCALA definida
-- en los criterios de evaluacion del periodo academico del GRADO de la unidad.
--
-- Resolucion de la escala (modal "Agregar criterio", niveles Bajo/Basico/
-- Alto/Superior -- en realidad los que traiga la escala). Como la unidad ya
-- no tiene FK_TPERIODO_EVALUACION (V218), el periodo academico se toma del
-- grado:
--   TUNIDAD.FK_TGRADO
--     -> TGRADO.FK_TPERIODO_ACADEMICO
--     -> TCRITERIO_EVALUACION (PK = ese periodo academico, 1:1)
--     -> FK_TESCALA -> TESCALA -> TESCALA_VALORACION (una fila por
--        valoracion: Bajo/Basico/Alto/Superior..., con ORDEN y limites).
--
-- El caller manda un indicador por valoracion via p_niveles JSONB
-- (mismo patron JSONB de V113/V198):
--   [ { "fkTescalaValoracion": <PK_TESCALA_VALORACION>,
--       "indicador": "texto del nivel",           -- obligatorio
--       "recomendacion": "texto opcional",
--       "tarea": "texto opcional" }, ... ]
-- Se exige exactamente una entrada por cada valoracion ACTIVA de la escala
-- (ni faltantes ni sobrantes ni duplicadas) -- respeta el UNIQUE
-- (FK_TCRITERIO_UNIDAD, FK_TESCALA_VALORACION) de V22 y el "*" de todos los
-- niveles del modal.
--
-- La rubrica de la unidad (TRUBRICA_UNIDAD, 1:1) se crea al vuelo la
-- primera vez (get-or-create; reactiva una inactiva si la hubiera).
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_criterio_agregar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tunidad               BIGINT,
    p_descripcion              VARCHAR(4000),
    p_niveles                  JSONB,
    p_publico                  VARCHAR(1) DEFAULT 'S',
    p_codigo                   VARCHAR(6) DEFAULT NULL,
    p_descriptor_prom          VARCHAR(1) DEFAULT 'N'
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_unidad_active   BOOLEAN;
    v_fk_tgrado       BIGINT;
    v_fk_tescala      BIGINT;
    v_pk_rubrica      BIGINT;
    v_pk_criterio     BIGINT;
    v_orden           NUMERIC(4);
    v_valoraciones    BIGINT;
    v_payload_total   BIGINT;
    v_payload_unicos  BIGINT;
BEGIN
    -- 0. Gate: capability EDITAR sobre PLANEADOR (se edita la unidad).
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'EDITAR'
    );

    -- 1. Unidad existe y esta activa.
    SELECT ACTIVE, FK_TGRADO
      INTO v_unidad_active, v_fk_tgrado
      FROM academico_test.TUNIDAD
     WHERE PK_TUNIDAD = p_pk_tunidad;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la unidad tematica solicitada' USING ERRCODE = 'P0002';
    END IF;
    IF v_unidad_active = FALSE THEN
        RAISE EXCEPTION 'La unidad esta inactiva; no se le pueden agregar criterios' USING ERRCODE = '22023';
    END IF;

    -- 2. Datos del criterio.
    IF NULLIF(TRIM(p_descripcion), '') IS NULL THEN
        RAISE EXCEPTION 'El texto del criterio es obligatorio' USING ERRCODE = '22023';
    END IF;
    IF UPPER(TRIM(COALESCE(p_publico, ''))) NOT IN ('S', 'N') THEN
        RAISE EXCEPTION 'PUBLICO invalido: % (use ''S'' o ''N'')', p_publico USING ERRCODE = '22023';
    END IF;
    IF p_descriptor_prom IS NOT NULL AND UPPER(TRIM(p_descriptor_prom)) NOT IN ('S', 'N') THEN
        RAISE EXCEPTION 'DESCRIPTOR_PROM invalido: % (use ''S'' o ''N'')', p_descriptor_prom USING ERRCODE = '22023';
    END IF;

    -- 3. Escala definida en los criterios de evaluacion del periodo academico
    --    del grado de la unidad.
    SELECT ce.FK_TESCALA
      INTO v_fk_tescala
      FROM academico_test.TGRADO g
      JOIN academico_test.TCRITERIO_EVALUACION ce
        ON ce.PK_TCRITERIO_EVALUACION = g.FK_TPERIODO_ACADEMICO
       AND ce.ACTIVE = TRUE
     WHERE g.PK_TGRADO = v_fk_tgrado;

    IF v_fk_tescala IS NULL THEN
        RAISE EXCEPTION 'El periodo academico del grado de la unidad no tiene una escala definida en sus criterios de evaluacion'
            USING ERRCODE = '22023',
                  HINT = 'Configure TCRITERIO_EVALUACION.FK_TESCALA para ese periodo academico antes de crear criterios de unidad';
    END IF;

    SELECT COUNT(*) INTO v_valoraciones
      FROM academico_test.TESCALA_VALORACION
     WHERE FK_TESCALA = v_fk_tescala AND ACTIVE = TRUE;
    IF v_valoraciones = 0 THEN
        RAISE EXCEPTION 'La escala (%) no tiene valoraciones activas', v_fk_tescala USING ERRCODE = '22023';
    END IF;

    -- 4. Validacion del payload de niveles.
    IF p_niveles IS NULL OR jsonb_typeof(p_niveles) <> 'array' OR jsonb_array_length(p_niveles) = 0 THEN
        RAISE EXCEPTION 'p_niveles debe ser un arreglo JSON no vacio con un indicador por valoracion de la escala'
            USING ERRCODE = '22023';
    END IF;

    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(p_niveles) e
         WHERE NULLIF(TRIM(e->>'indicador'), '') IS NULL
    ) THEN
        RAISE EXCEPTION 'Cada nivel del criterio requiere un indicador no vacio' USING ERRCODE = '22023';
    END IF;

    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(p_niveles) e
         WHERE (e->>'fkTescalaValoracion') IS NULL
            OR NOT EXISTS (
                SELECT 1 FROM academico_test.TESCALA_VALORACION ev
                 WHERE ev.PK_TESCALA_VALORACION = (e->>'fkTescalaValoracion')::BIGINT
                   AND ev.FK_TESCALA = v_fk_tescala
                   AND ev.ACTIVE = TRUE
            )
    ) THEN
        RAISE EXCEPTION 'Un nivel referencia una valoracion (fkTescalaValoracion) que no pertenece a la escala de evaluacion de la unidad'
            USING ERRCODE = '23503';
    END IF;

    SELECT COUNT(*), COUNT(DISTINCT (e->>'fkTescalaValoracion')::BIGINT)
      INTO v_payload_total, v_payload_unicos
      FROM jsonb_array_elements(p_niveles) e;

    IF v_payload_total <> v_payload_unicos THEN
        RAISE EXCEPTION 'El payload de niveles tiene valoraciones repetidas' USING ERRCODE = '22023';
    END IF;
    IF v_payload_unicos <> v_valoraciones THEN
        RAISE EXCEPTION 'Debe enviar exactamente un indicador por cada valoracion activa de la escala (esperados: %, recibidos: %)',
            v_valoraciones, v_payload_unicos
            USING ERRCODE = '22023';
    END IF;

    -- 5. Get-or-create de la rubrica de la unidad (1:1).
    SELECT PK_TRUBRICA_UNIDAD INTO v_pk_rubrica
      FROM academico_test.TRUBRICA_UNIDAD
     WHERE FK_TUNIDAD = p_pk_tunidad AND ACTIVE = TRUE;

    IF NOT FOUND THEN
        UPDATE academico_test.TRUBRICA_UNIDAD
           SET ACTIVE = TRUE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TUNIDAD = p_pk_tunidad
        RETURNING PK_TRUBRICA_UNIDAD INTO v_pk_rubrica;

        IF v_pk_rubrica IS NULL THEN
            INSERT INTO academico_test.TRUBRICA_UNIDAD (FK_TUNIDAD, CREATED_BY, CREATED_AT, ACTIVE)
            VALUES (p_pk_tunidad, p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE)
            RETURNING PK_TRUBRICA_UNIDAD INTO v_pk_rubrica;
        END IF;
    END IF;

    -- 6. Siguiente ORDEN dentro de la rubrica (UNIQUE FK_TRUBRICA_UNIDAD, ORDEN).
    SELECT COALESCE(MAX(ORDEN), 0) + 1 INTO v_orden
      FROM academico_test.TCRITERIO_UNIDAD
     WHERE FK_TRUBRICA_UNIDAD = v_pk_rubrica;

    -- 7. Criterio.
    INSERT INTO academico_test.TCRITERIO_UNIDAD (
        FK_TRUBRICA_UNIDAD, ORDEN, DESCRIPCION, PUBLICO, CODIGO, DESCRIPTOR_PROM,
        CREATED_BY, CREATED_AT, ACTIVE
    ) VALUES (
        v_pk_rubrica, v_orden, TRIM(p_descripcion), UPPER(TRIM(p_publico)),
        NULLIF(TRIM(p_codigo), ''), COALESCE(UPPER(TRIM(p_descriptor_prom)), 'N'),
        p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
    )
    RETURNING PK_TCRITERIO_UNIDAD INTO v_pk_criterio;

    -- 8. Un nivel por valoracion de la escala.
    INSERT INTO academico_test.TNIVEL_CRITERIO_UNIDAD (
        FK_TCRITERIO_UNIDAD, INDICADOR, RECOMENDACION, TAREA, FK_TESCALA_VALORACION,
        CREATED_BY, CREATED_AT, ACTIVE
    )
    SELECT v_pk_criterio,
           TRIM(e->>'indicador'),
           NULLIF(TRIM(e->>'recomendacion'), ''),
           NULLIF(TRIM(e->>'tarea'), ''),
           (e->>'fkTescalaValoracion')::BIGINT,
           p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
      FROM jsonb_array_elements(p_niveles) e;

    RETURN v_pk_criterio;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_criterio_agregar(BIGINT, BIGINT, VARCHAR, JSONB, VARCHAR, VARCHAR, VARCHAR)
    IS 'Agrega un criterio (TCRITERIO_UNIDAD) a la rubrica de la unidad (TRUBRICA_UNIDAD, get-or-create) con un indicador (TNIVEL_CRITERIO_UNIDAD) por cada valoracion de la escala definida en TCRITERIO_EVALUACION.FK_TESCALA del periodo academico del GRADO de la unidad (TGRADO.FK_TPERIODO_ACADEMICO -- la unidad ya no tiene FK_TPERIODO_EVALUACION, V218). p_niveles JSONB = [{fkTescalaValoracion, indicador, recomendacion?, tarea?}]; se exige exactamente una entrada por valoracion activa de la escala (sin faltantes/sobrantes/duplicados). Gate EDITAR sobre PLANEADOR. Retorna PK_TCRITERIO_UNIDAD.';

-- ===========================================================================
-- fn_unidad_actividades_listar — actividades vinculadas a una unidad y su
-- peso dentro de la unidad (pestaña "Actividades" del detalle de unidad:
-- ACTIVIDAD / TIPO / INSTRUMENTO / GRUPO / (%)).
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_actividades_listar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tunidad               BIGINT,
    p_search                   VARCHAR   DEFAULT NULL,
    p_fk_tgrupo                BIGINT    DEFAULT NULL,
    p_incluir_inactivas        BOOLEAN   DEFAULT FALSE,
    p_orden_por                VARCHAR   DEFAULT 'actividad',
    p_orden_asc                BOOLEAN   DEFAULT TRUE,
    p_limite                   INT       DEFAULT 50,
    p_offset                   INT       DEFAULT 0
)
RETURNS TABLE (
    pk_tactividad                   BIGINT,
    titulo                          VARCHAR,
    fk_tasignatura                  BIGINT,
    asignatura                      VARCHAR,
    fk_tlv_tipo_actividad           BIGINT,
    tipo_actividad                  VARCHAR,
    fk_tlv_instrumento_evaluacion   BIGINT,
    instrumento_evaluacion          VARCHAR,
    fk_tgrupo                       BIGINT,
    grupo                           VARCHAR,
    fk_tlv_jerarquia                BIGINT,
    jerarquia                       VARCHAR,
    influencia                      NUMERIC,
    es_evaluativa                   VARCHAR,
    fecha_inicio                    DATE,
    fecha_cierre                    DATE,
    active                          BOOLEAN,
    total_count                     BIGINT
)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    IF NOT EXISTS (SELECT 1 FROM academico_test.TUNIDAD WHERE PK_TUNIDAD = p_pk_tunidad) THEN
        RAISE EXCEPTION 'No se encontro la unidad tematica solicitada' USING ERRCODE = 'P0002';
    END IF;

    RETURN QUERY
    SELECT a.PK_TACTIVIDAD,
           a.TITULO,
           a.FK_TASIGNATURA,
           asig.NOMBRE,
           a.FK_TLV_TIPO_ACTIVIDAD,
           lvt.NOMBRE,
           a.FK_TLV_INSTRUMENTO_EVALUACION,
           lvi.NOMBRE,
           a.FK_TGRUPO,
           g.NOMBRE,
           a.FK_TLV_JERARQUIA,
           lvj.NOMBRE,
           a.INFLUENCIA,
           a.ES_EVALUATIVA::VARCHAR,
           a.FECHA_INICIO,
           a.FECHA_CIERRE,
           a.ACTIVE,
           COUNT(*) OVER()
      FROM academico_test.TACTIVIDAD a
      LEFT JOIN academico_test.TASIGNATURA asig ON asig.PK_TASIGNATURA = a.FK_TASIGNATURA
      LEFT JOIN academico_test.TLISTA_VALOR lvt ON lvt.PK_LISTA_VALOR = a.FK_TLV_TIPO_ACTIVIDAD
      LEFT JOIN academico_test.TLISTA_VALOR lvi ON lvi.PK_LISTA_VALOR = a.FK_TLV_INSTRUMENTO_EVALUACION
      LEFT JOIN academico_test.TLISTA_VALOR lvj ON lvj.PK_LISTA_VALOR = a.FK_TLV_JERARQUIA
      LEFT JOIN academico_test.TGRUPO g         ON g.PK_TGRUPO = a.FK_TGRUPO
     WHERE a.FK_TUNIDAD = p_pk_tunidad
       AND (p_incluir_inactivas OR a.ACTIVE = TRUE)
       AND (p_search IS NULL OR a.TITULO ILIKE '%' || p_search || '%')
       AND (p_fk_tgrupo IS NULL OR a.FK_TGRUPO = p_fk_tgrupo)
     ORDER BY
       CASE WHEN p_orden_asc THEN
           CASE LOWER(TRIM(COALESCE(p_orden_por, 'actividad')))
               WHEN 'actividad'   THEN a.TITULO
               WHEN 'tipo'         THEN lvt.NOMBRE
               WHEN 'instrumento'  THEN lvi.NOMBRE
               WHEN 'grupo'        THEN g.NOMBRE
               ELSE a.TITULO
           END
       END ASC,
       CASE WHEN p_orden_asc AND LOWER(TRIM(COALESCE(p_orden_por, 'actividad'))) = 'porcentaje'
            THEN a.INFLUENCIA END ASC,
       CASE WHEN NOT p_orden_asc THEN
           CASE LOWER(TRIM(COALESCE(p_orden_por, 'actividad')))
               WHEN 'actividad'   THEN a.TITULO
               WHEN 'tipo'         THEN lvt.NOMBRE
               WHEN 'instrumento'  THEN lvi.NOMBRE
               WHEN 'grupo'        THEN g.NOMBRE
               ELSE a.TITULO
           END
       END DESC,
       CASE WHEN NOT p_orden_asc AND LOWER(TRIM(COALESCE(p_orden_por, 'actividad'))) = 'porcentaje'
            THEN a.INFLUENCIA END DESC
     LIMIT GREATEST(p_limite, 1)
    OFFSET GREATEST(p_offset, 0);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_actividades_listar(BIGINT, BIGINT, VARCHAR, BIGINT, BOOLEAN, VARCHAR, BOOLEAN, INT, INT)
    IS 'Lista las actividades (TACTIVIDAD) vinculadas a una unidad (FK_TUNIDAD, opcional desde V218) y su peso (INFLUENCIA) dentro de ella -- pestaña "Actividades" del detalle de unidad. Devuelve titulo, asignatura (TACTIVIDAD.FK_TASIGNATURA, propia de la actividad desde V218), tipo de actividad, instrumento de evaluacion, grupo y jerarquia resueltos, fechas y ES_EVALUATIVA. Filtros: search sobre TITULO, grupo, incluir_inactivas. Orden: actividad|tipo|instrumento|grupo|porcentaje. total_count via COUNT(*) OVER(). Gate VER sobre PLANEADOR.';

-- ===========================================================================
-- fn_unidad_buscar_por_pk — detalle de la unidad (pestaña "Informacion
-- general": Descripcion + Objetivos + Contenidos + metodo de calculo +
-- Grado + Asignatura + Inicio/Fin derivados + referente curricular).
-- Objetivos y contenidos se devuelven como arreglos JSONB ordenados
-- (mismo patron de agregacion que otros detalles del back).
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_buscar_por_pk(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tunidad               BIGINT
)
RETURNS TABLE (
    pk_tunidad                  BIGINT,
    nombre                      VARCHAR,
    descripcion                 VARCHAR,
    fk_tasignatura              BIGINT,
    asignatura                  VARCHAR,
    fk_tarea                    BIGINT,
    area                        VARCHAR,
    fk_tgrado                   BIGINT,
    grado                       VARCHAR,
    fk_tfuncionario             BIGINT,
    docente                     VARCHAR,
    fk_tlv_calculo_definitiva   BIGINT,
    calculo_definitiva          VARCHAR,
    fk_referente_curricular     BIGINT,
    referente_curricular        VARCHAR,
    total_actividades           BIGINT,
    fecha_inicio                DATE,
    fecha_fin                   DATE,
    objetivos                   JSONB,
    contenidos                  JSONB,
    active                      BOOLEAN
)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    RETURN QUERY
    SELECT u.PK_TUNIDAD,
           u.NOMBRE,
           u.DESCRIPCION,
           u.FK_TASIGNATURA,
           asig.NOMBRE,
           asig.FK_TAREA,
           ar.NOMBRE,
           u.FK_TGRADO,
           gr.NOMBRE,
           u.FK_TFUNCIONARIO,
           NULLIF(TRIM(CONCAT_WS(' ', us.PRIMER_NOMBRE, us.SEGUNDO_NOMBRE, us.PRIMER_APELLIDO, us.SEGUNDO_APELLIDO)), '')::VARCHAR,
           u.FK_TLV_CALCULO_DEFINITIVA,
           lvc.NOMBRE,
           u.FK_REFERENTE_CURRICULAR,
           rc.NOMBRE,
           (SELECT COUNT(*) FROM academico_test.TACTIVIDAD a WHERE a.FK_TUNIDAD = u.PK_TUNIDAD AND a.ACTIVE = TRUE),
           (SELECT MIN(a.FECHA_INICIO) FROM academico_test.TACTIVIDAD a WHERE a.FK_TUNIDAD = u.PK_TUNIDAD AND a.ACTIVE = TRUE),
           (SELECT MAX(a.FECHA_CIERRE) FROM academico_test.TACTIVIDAD a WHERE a.FK_TUNIDAD = u.PK_TUNIDAD AND a.ACTIVE = TRUE),
           COALESCE((
               SELECT jsonb_agg(jsonb_build_object('pk', o.PK_TUNIDAD_OBJETIVO, 'orden', o.ORDEN, 'descripcion', o.DESCRIPCION)
                                ORDER BY o.ORDEN)
                 FROM academico_test.TUNIDAD_OBJETIVO o
                WHERE o.FK_TUNIDAD = u.PK_TUNIDAD AND o.ACTIVE = TRUE
           ), '[]'::jsonb),
           COALESCE((
               SELECT jsonb_agg(jsonb_build_object('pk', c.PK_TUNIDAD_CONTENIDO, 'orden', c.ORDEN, 'descripcion', c.DESCRIPCION)
                                ORDER BY c.ORDEN)
                 FROM academico_test.TUNIDAD_CONTENIDO c
                WHERE c.FK_TUNIDAD = u.PK_TUNIDAD AND c.ACTIVE = TRUE
           ), '[]'::jsonb),
           u.ACTIVE
      FROM academico_test.TUNIDAD u
      JOIN academico_test.TASIGNATURA asig       ON asig.PK_TASIGNATURA = u.FK_TASIGNATURA
      LEFT JOIN academico_test.TAREA ar          ON ar.PK_TAREA = asig.FK_TAREA
      JOIN academico_test.TGRADO gr              ON gr.PK_TGRADO = u.FK_TGRADO
      LEFT JOIN academico_test.TFUNCIONARIO fu   ON fu.PK_TFUNCIONARIO = u.FK_TFUNCIONARIO
      LEFT JOIN academico_test.TUSUARIO us       ON us.PK_TUSUARIO = fu.FK_TUSUARIO
      LEFT JOIN academico_test.TLISTA_VALOR lvc  ON lvc.PK_LISTA_VALOR = u.FK_TLV_CALCULO_DEFINITIVA
      LEFT JOIN academico_test.TREFERENTE_CURRICULAR rc ON rc.PK_REFERENTE_CURRICULAR = u.FK_REFERENTE_CURRICULAR
     WHERE u.PK_TUNIDAD = p_pk_tunidad;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_buscar_por_pk(BIGINT, BIGINT)
    IS 'Detalle de una TUNIDAD (pestaña "Informacion general"): escalares + nombres resueltos (asignatura, area, grado, docente, forma de calculo, referente curricular), total de actividades activas, Inicio/Fin DERIVADOS (MIN FECHA_INICIO / MAX FECHA_CIERRE de sus actividades activas) y los arreglos JSONB ordenados objetivos [{pk,orden,descripcion}] y contenidos [{pk,orden,descripcion}]. La unidad ya no depende de un periodo de evaluacion (V218). SETOF 0 o 1 fila (incluye inactivas). Gate VER.';

-- ===========================================================================
-- fn_unidad_objetivos_listar / fn_unidad_contenidos_listar — listas planas
-- para el editor de la unidad ("Nueva unidad" -> Objetivos / Contenidos).
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_objetivos_listar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tunidad               BIGINT
)
RETURNS TABLE (
    pk_tunidad_objetivo   BIGINT,
    orden                 NUMERIC,
    descripcion           VARCHAR
)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    RETURN QUERY
    SELECT o.PK_TUNIDAD_OBJETIVO, o.ORDEN, o.DESCRIPCION
      FROM academico_test.TUNIDAD_OBJETIVO o
     WHERE o.FK_TUNIDAD = p_pk_tunidad AND o.ACTIVE = TRUE
     ORDER BY o.ORDEN;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_objetivos_listar(BIGINT, BIGINT)
    IS 'Objetivos ACTIVE de una unidad (TUNIDAD_OBJETIVO), ordenados por ORDEN. Gate VER sobre PLANEADOR.';

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_contenidos_listar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tunidad               BIGINT
)
RETURNS TABLE (
    pk_tunidad_contenido   BIGINT,
    orden                  NUMERIC,
    descripcion            VARCHAR
)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    RETURN QUERY
    SELECT c.PK_TUNIDAD_CONTENIDO, c.ORDEN, c.DESCRIPCION
      FROM academico_test.TUNIDAD_CONTENIDO c
     WHERE c.FK_TUNIDAD = p_pk_tunidad AND c.ACTIVE = TRUE
     ORDER BY c.ORDEN;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_contenidos_listar(BIGINT, BIGINT)
    IS 'Contenidos/componentes ACTIVE de una unidad (TUNIDAD_CONTENIDO), ordenados por ORDEN. Gate VER sobre PLANEADOR.';
