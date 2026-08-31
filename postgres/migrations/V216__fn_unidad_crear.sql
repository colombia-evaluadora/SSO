-- ===========================================================================
-- V216 — Planeador educativo: creacion de una unidad tematica con sus
-- contenidos, objetivos, referente curricular y forma de calculo de nota
-- (CU-86e311xxp — G. Academico Back Planeador educativo).
--
-- Contexto (pantallas "Nueva unidad" / "Unidad tematica" del Planeador):
-- al crear una unidad el docente captura, ademas de la identificacion
-- (nombre, asignatura, grado, periodo de evaluacion, autor):
--   * Objetivos especificos de la unidad  -> TUNIDAD_OBJETIVO  (uno por
--     fila, ORDEN = posicion en la lista).
--   * Contenidos / componentes de la unidad -> TUNIDAD_CONTENIDO (idem).
--   * Referente curricular al que se acoge (DBA / Propositos e
--     Imprescindibles / ...) -> TUNIDAD.FK_REFERENTE_CURRICULAR, opcional
--     (V212, rama CU-86e311xqh).
--   * "Forma en que se van a calcular las actividades dentro de la unidad"
--     (Promediar / Ponderar / Sumatoria de Actividades) ->
--     TUNIDAD.FK_TLV_CALCULO_DEFINITIVA, TLISTA_VALOR CATEGORIA=
--     'CALCULO_DEFINITIVA' (V73, rama CU-86e30a25v).
--
-- Depende de (se aplican antes por orden de version de Flyway):
--   * V22  — TUNIDAD, TUNIDAD_CONTENIDO, TUNIDAD_OBJETIVO.
--   * V73  — TUNIDAD.FK_TLV_CALCULO_DEFINITIVA + catalogo CALCULO_DEFINITIVA.
--   * V212 — TREFERENTE_CURRICULAR + TUNIDAD.FK_REFERENTE_CURRICULAR.
--   * V29/V185/V213 — modelo de capability por menu (fn_assert_permiso_seccion).
--
-- Nomenclatura/estilo: sigue V213 (fn_ con gate fn_assert_permiso_seccion,
-- validaciones 22023/23503/23505/P0002, CREATED_BY = usuario solicitante,
-- COMMENT ON FUNCTION) y V59/V113/V213 (seed de TMENU/TROL_MENU via
-- WHERE NOT EXISTS, sin ON CONFLICT — indice parcial).
--
-- AUTORIZACION: el gate es fn_assert_permiso_seccion(usuario, 'PLANEADOR',
-- 'CREAR'), sin scope territorial (la unidad la crea el docente sobre su
-- propia asignacion; el alcance fino por asignatura/grupo se valida en la
-- capa de asignacion, fuera de esta migracion). Seed nuevo: menu
-- 'PLANEADOR' concedido a DOCENTE y SUPER_ADMINISTRADOR (4 permisos).
--
-- Fuera de alcance: actualizar / eliminar / listar unidades y el vinculo
-- fino unidad <-> enunciado concreto del referente (hoy la unidad se acoge
-- al referente completo via FK_REFERENTE_CURRICULAR) — migraciones
-- posteriores una vez cerrado ese contrato.
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
    p_fk_tperiodo_evaluacion        BIGINT,
    p_fk_tfuncionario               BIGINT,
    p_descripcion                   VARCHAR(4000) DEFAULT NULL,
    p_fk_tlv_calculo_definitiva     BIGINT        DEFAULT NULL,
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
    IF p_fk_tperiodo_evaluacion IS NULL THEN
        RAISE EXCEPTION 'El periodo de evaluacion (FK_TPERIODO_EVALUACION) es obligatorio' USING ERRCODE = '22023';
    END IF;
    IF p_fk_tfuncionario IS NULL THEN
        RAISE EXCEPTION 'El docente autor (FK_TFUNCIONARIO) es obligatorio' USING ERRCODE = '22023';
    END IF;

    -- 2. FKs existen y estan activas.
    IF NOT EXISTS (SELECT 1 FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_fk_tasignatura AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'FK_TASIGNATURA (%) no existe o no esta activa', p_fk_tasignatura USING ERRCODE = '23503';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_tgrado AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'FK_TGRADO (%) no existe o no esta activo', p_fk_tgrado USING ERRCODE = '23503';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM academico_test.TPERIODO_EVALUACION WHERE PK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'FK_TPERIODO_EVALUACION (%) no existe o no esta activo', p_fk_tperiodo_evaluacion USING ERRCODE = '23503';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM academico_test.TFUNCIONARIO WHERE PK_TFUNCIONARIO = p_fk_tfuncionario AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'FK_TFUNCIONARIO (%) no existe o no esta activo', p_fk_tfuncionario USING ERRCODE = '23503';
    END IF;

    -- 2.a Forma de calculo de la nota de la unidad (opcional).
    IF p_fk_tlv_calculo_definitiva IS NOT NULL AND NOT EXISTS (
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

    -- 3. Unicidad (NOMBRE, asignatura, grado, periodo de evaluacion) entre
    --    unidades activas — backstop del constraint UN_TUNIDAD_1 (V22).
    IF EXISTS (
        SELECT 1 FROM academico_test.TUNIDAD
         WHERE UPPER(TRIM(NOMBRE)) = UPPER(TRIM(p_nombre))
           AND FK_TASIGNATURA = p_fk_tasignatura
           AND FK_TGRADO = p_fk_tgrado
           AND FK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion
           AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'Ya existe una unidad activa "%" para esa asignatura, grado y periodo de evaluacion', p_nombre
            USING ERRCODE = '23505';
    END IF;

    -- 4. INSERT de la unidad.
    INSERT INTO academico_test.TUNIDAD (
        NOMBRE, FK_TASIGNATURA, FK_TGRADO, FK_TPERIODO_EVALUACION, FK_TFUNCIONARIO,
        DESCRIPCION, FK_TLV_CALCULO_DEFINITIVA, FK_REFERENTE_CURRICULAR,
        CREATED_BY, CREATED_AT, ACTIVE
    ) VALUES (
        TRIM(p_nombre), p_fk_tasignatura, p_fk_tgrado, p_fk_tperiodo_evaluacion, p_fk_tfuncionario,
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

COMMENT ON FUNCTION academico_test.fn_unidad_crear(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, VARCHAR, BIGINT, BIGINT, VARCHAR[], VARCHAR[])
    IS 'Crea una unidad tematica del Planeador (gate CREAR sobre PLANEADOR): inserta TUNIDAD (identificacion + DESCRIPCION + FK_TLV_CALCULO_DEFINITIVA [forma de calculo de la nota, catalogo CALCULO_DEFINITIVA, V73] + FK_REFERENTE_CURRICULAR [referente al que se acoge, V212], ambos opcionales) y, si se pasan, sus objetivos (TUNIDAD_OBJETIVO) y contenidos/componentes (TUNIDAD_CONTENIDO) con ORDEN por posicion del array, ignorando los vacios. Valida existencia/estado de todas las FKs y unicidad (nombre, asignatura, grado, periodo de evaluacion) entre unidades activas. Retorna PK_TUNIDAD.';
