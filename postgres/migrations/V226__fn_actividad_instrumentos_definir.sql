-- ===========================================================================
-- V226 — Planeador educativo: definicion de los instrumentos de evaluacion
-- de una actividad (Rubrica / Lista de cotejo / Escala de valoracion)
-- (CU-86e311xxp — G. Academico Back Planeador educativo).
--
-- Complementa V224 (CRUD de actividades). Alli la actividad elige SU
-- instrumento en TACTIVIDAD.FK_TLV_INSTRUMENTO_EVALUACION
-- (RUBRICA | LISTA_COTEJO | ESCALA_VALORACION | OTRO, seed de V224); aqui
-- se define el CONTENIDO de ese instrumento.
--
-- Modulos:
--   (1) Seed TIPO_ESCALA          — no existia en el servidor.
--   (2) DDL                       — PONDERACION opcional en cotejo,
--                                    ETIQUETA en los niveles.
--   (3) Helper                    — fn_actividad_instrumento_reset.
--   (4) Definicion por instrumento— fn_actividad_rubrica_definir,
--                                    fn_actividad_cotejo_definir,
--                                    fn_actividad_escala_definir.
--   (5) Fachada                   — fn_actividad_instrumento_definir
--                                    (despacha segun el instrumento de la
--                                    actividad) y _obtener (lectura).
--
-- -------------------------------------------------------------------------
-- PONDERACION — reglas confirmadas con negocio:
--
--   * RUBRICA: la ponderacion va en el NIVEL de desempeno y es OBLIGATORIA
--     (TACTIVIDAD_RUBRICA_NIVEL.PONDERACION ya es NOT NULL en V22). El
--     CRITERIO no lleva peso propio: no se agrega ninguna columna.
--     UN_TAC_RUBRICA_NIVEL_1 (criterio, ponderacion) impide dos niveles con
--     el mismo peso dentro de un criterio — se valida antes para dar un
--     mensaje claro en vez del 23505 crudo.
--
--   * ESCALA DE VALORACION: la ponderacion va en el NIVEL y es OBLIGATORIA
--     (TACTIVIDAD_ESCALA_NIVEL.PONDERACION ya es NOT NULL en V22). Solo
--     aplica a la escala CUALITATIVA (la NUMERICA se define con
--     VALOR_MIN/VALOR_MAX, sin niveles — ver figma).
--
--   * LISTA DE COTEJO: la ponderacion es OPCIONAL y va por ITEM. V22 no
--     creo la columna -> se agrega TACTIVIDAD_COTEJO_ITEM.PONDERACION
--     NUMERIC(5,2) NULLABLE (0..100). NULL = el item no pondera (todos los
--     items sin peso cuentan igual); se permite mezclar items con y sin
--     peso, no se exige que sumen 100 (decision de negocio).
--
-- -------------------------------------------------------------------------
-- ETIQUETA de los niveles: el figma muestra, tanto en rubrica como en
-- escala cualitativa, un rotulo del nivel ("Excelente", "Bajo", "Medio",
-- "Alto") SEPARADO del texto descriptivo ("Descriptor por nivel",
-- "Interpretacion / descriptor"). V22 solo dejo DESCRIPCION en
-- TACTIVIDAD_RUBRICA_NIVEL y TACTIVIDAD_ESCALA_NIVEL, asi que se agrega
-- ETIQUETA VARCHAR(130) NULLABLE en ambas: ETIQUETA = rotulo,
-- DESCRIPCION = descriptor. Nullable para no romper filas existentes.
--
-- -------------------------------------------------------------------------
-- Un instrumento por actividad: TACTIVIDAD.FK_TLV_INSTRUMENTO_EVALUACION es
-- una sola FK, asi que definir uno desactiva los otros dos
-- (fn_actividad_instrumento_reset). Cada fn_*_definir exige ademas que el
-- instrumento de la actividad coincida (22023 si no) — primero se fija el
-- instrumento con fn_actividad_crear/_actualizar y despues se define.
--
-- Depende de (orden de version de Flyway):
--   * V22  — TACTIVIDAD_RUBRICA_CRITERIO/_NIVEL, TACTIVIDAD_COTEJO_ITEM,
--            TACTIVIDAD_ESCALA/_NIVEL, TLISTA_VALOR.
--   * V224 — seed INSTRUMENTO_EVALUACION, fn_actividad_lv_assert, menu
--            'PLANEADOR'; V29/V185 — fn_assert_permiso_seccion.
--
-- Estilo: V213/V216/V224 (gate, 22023/23503/23505/P0002, reemplazo completo
-- con soft delete, JSONB de entrada/salida, COMMENT ON FUNCTION) y
-- V120/V212 (seed idempotente WHERE NOT EXISTS).
-- ===========================================================================

SET search_path TO academico_test, public;

-- ===========================================================================
-- (1) SEED TIPO_ESCALA — no existe en el servidor (verificado).
-- ===========================================================================
INSERT INTO academico_test.tlista_valor (categoria, nombre, valor, created_by)
SELECT v.categoria, v.nombre, v.valor, 'V226_seed'
  FROM (VALUES
    ('TIPO_ESCALA'::VARCHAR, 'Numérica'::VARCHAR,    'NUMERICA'::VARCHAR),
    ('TIPO_ESCALA',          'Cualitativa',          'CUALITATIVA')
  ) AS v(categoria, nombre, valor)
 WHERE NOT EXISTS (
     SELECT 1 FROM academico_test.tlista_valor lv
      WHERE lv.categoria = v.categoria AND lv.valor = v.valor
 );

-- ===========================================================================
-- (2) DDL
-- ===========================================================================

-- Lista de cotejo: peso por item, OPCIONAL.
ALTER TABLE TACTIVIDAD_COTEJO_ITEM
  ADD COLUMN IF NOT EXISTS PONDERACION NUMERIC(5,2);

ALTER TABLE TACTIVIDAD_COTEJO_ITEM DROP CONSTRAINT IF EXISTS CK_TAC_COTEJO_ITEM_PONDERACION;
ALTER TABLE TACTIVIDAD_COTEJO_ITEM ADD CONSTRAINT CK_TAC_COTEJO_ITEM_PONDERACION
  CHECK (PONDERACION IS NULL OR (PONDERACION >= 0 AND PONDERACION <= 100));

COMMENT ON COLUMN TACTIVIDAD_COTEJO_ITEM.PONDERACION IS
  'Peso (%) OPCIONAL del item dentro de la lista de cotejo (0..100). NULL = el item no pondera. Se permite mezclar items con y sin peso y NO se exige que sumen 100. V226.';

-- Rotulo del nivel, separado del descriptor (ver cabecera).
ALTER TABLE TACTIVIDAD_RUBRICA_NIVEL ADD COLUMN IF NOT EXISTS ETIQUETA VARCHAR(130);
ALTER TABLE TACTIVIDAD_ESCALA_NIVEL  ADD COLUMN IF NOT EXISTS ETIQUETA VARCHAR(130);

COMMENT ON COLUMN TACTIVIDAD_RUBRICA_NIVEL.ETIQUETA IS
  'Rotulo del nivel de desempeno (ej: "Excelente", "Bueno"). El texto largo va en DESCRIPCION ("Descriptor por nivel" del figma). Nullable. V226.';
COMMENT ON COLUMN TACTIVIDAD_ESCALA_NIVEL.ETIQUETA IS
  'Rotulo del nivel de la escala cualitativa (ej: "Bajo", "Medio", "Alto"). El texto largo va en DESCRIPCION ("Interpretacion / descriptor" del figma). Nullable. V226.';

-- ===========================================================================
-- (3) HELPER — un solo instrumento vivo por actividad.
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_instrumento_reset(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad            BIGINT,
    -- 'RUBRICA' | 'LISTA_COTEJO' | 'ESCALA_VALORACION': el que se conserva.
    p_conservar                VARCHAR DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    -- Rubrica: niveles antes que criterios (FK).
    IF p_conservar IS DISTINCT FROM 'RUBRICA' THEN
        UPDATE academico_test.TACTIVIDAD_RUBRICA_NIVEL n
           SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
          FROM academico_test.TACTIVIDAD_RUBRICA_CRITERIO c
         WHERE n.FK_TACTIVIDAD_RUBRICA_CRITERIO = c.PK_TACTIVIDAD_RUBRICA_CRITERIO
           AND c.FK_TACTIVIDAD = p_pk_tactividad
           AND n.ACTIVE = TRUE;
        UPDATE academico_test.TACTIVIDAD_RUBRICA_CRITERIO
           SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE;
    END IF;

    IF p_conservar IS DISTINCT FROM 'LISTA_COTEJO' THEN
        UPDATE academico_test.TACTIVIDAD_COTEJO_ITEM
           SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE;
    END IF;

    IF p_conservar IS DISTINCT FROM 'ESCALA_VALORACION' THEN
        UPDATE academico_test.TACTIVIDAD_ESCALA_NIVEL n
           SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
          FROM academico_test.TACTIVIDAD_ESCALA e
         WHERE n.FK_TACTIVIDAD_ESCALA = e.PK_TACTIVIDAD_ESCALA
           AND e.FK_TACTIVIDAD = p_pk_tactividad
           AND n.ACTIVE = TRUE;
        UPDATE academico_test.TACTIVIDAD_ESCALA
           SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE;
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_instrumento_reset(BIGINT, BIGINT, VARCHAR)
    IS 'Soft delete de los instrumentos de evaluacion de una actividad EXCEPTO el indicado en p_conservar (RUBRICA | LISTA_COTEJO | ESCALA_VALORACION; NULL = borra los tres). Una actividad tiene UN solo instrumento (TACTIVIDAD.FK_TLV_INSTRUMENTO_EVALUACION), asi que definir uno limpia los otros. Helper de fn_actividad_*_definir. V226.';

-- ---------------------------------------------------------------------------
-- Helper interno: valida que el instrumento de la actividad sea el esperado.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_instrumento_assert(
    p_pk_tactividad   BIGINT,
    p_valor_esperado  VARCHAR
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_active BOOLEAN;
    v_valor  VARCHAR;
BEGIN
    SELECT a.ACTIVE, lv.VALOR
      INTO v_active, v_valor
      FROM academico_test.TACTIVIDAD a
      LEFT JOIN academico_test.TLISTA_VALOR lv
             ON lv.PK_LISTA_VALOR = a.FK_TLV_INSTRUMENTO_EVALUACION
     WHERE a.PK_TACTIVIDAD = p_pk_tactividad;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la actividad solicitada' USING ERRCODE = 'P0002';
    END IF;
    IF v_active = FALSE THEN
        RAISE EXCEPTION 'La actividad esta inactiva; no se le puede definir el instrumento' USING ERRCODE = '22023';
    END IF;
    IF v_valor IS NULL THEN
        RAISE EXCEPTION 'La actividad no tiene instrumento de evaluacion definido; fijelo primero con fn_actividad_crear/_actualizar (FK_TLV_INSTRUMENTO_EVALUACION)'
            USING ERRCODE = '22023';
    END IF;
    IF v_valor <> p_valor_esperado THEN
        RAISE EXCEPTION 'El instrumento de la actividad es % y no % — cambielo antes de definirlo', v_valor, p_valor_esperado
            USING ERRCODE = '22023';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_instrumento_assert(BIGINT, VARCHAR)
    IS 'Valida que la actividad exista, este activa y que su FK_TLV_INSTRUMENTO_EVALUACION (VALOR de TLISTA_VALOR) sea el esperado. Lanza P0002 / 22023. Helper de fn_actividad_*_definir. V226.';

-- ===========================================================================
-- (4) DEFINICION POR INSTRUMENTO
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- fn_actividad_rubrica_definir — reemplazo completo de la rubrica.
--
-- p_criterios JSONB = [
--   { "nombre": "Argumentacion",            -- obligatorio
--     "descripcion": "texto opcional",
--     "niveles": [                          -- obligatorio, >= 1
--       { "etiqueta": "Excelente",          -- opcional (rotulo)
--         "descripcion": "descriptor...",   -- obligatorio
--         "ponderacion": 5 }                -- OBLIGATORIA, 0..100, unica en el criterio
--     ] }
-- ]
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_rubrica_definir(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad            BIGINT,
    p_criterios                JSONB
)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_crit        JSONB;
    v_pos         INT := 0;
    v_pk_criterio BIGINT;
    v_niveles     JSONB;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'EDITAR'
    );
    PERFORM academico_test.fn_actividad_instrumento_assert(p_pk_tactividad, 'RUBRICA');

    IF p_criterios IS NULL OR jsonb_typeof(p_criterios) <> 'array'
       OR jsonb_array_length(p_criterios) = 0 THEN
        RAISE EXCEPTION 'p_criterios debe ser un arreglo JSON con al menos un criterio'
            USING ERRCODE = '22023';
    END IF;

    -- Limpia la rubrica anterior y cualquier otro instrumento.
    PERFORM academico_test.fn_actividad_instrumento_reset(p_pk_usuario_solicitante, p_pk_tactividad, NULL);

    FOR v_crit IN SELECT * FROM jsonb_array_elements(p_criterios) LOOP
        v_pos := v_pos + 1;

        IF NULLIF(TRIM(v_crit->>'nombre'), '') IS NULL THEN
            RAISE EXCEPTION 'El criterio #% requiere nombre', v_pos USING ERRCODE = '22023';
        END IF;

        v_niveles := v_crit->'niveles';
        IF v_niveles IS NULL OR jsonb_typeof(v_niveles) <> 'array'
           OR jsonb_array_length(v_niveles) = 0 THEN
            RAISE EXCEPTION 'El criterio "%" requiere al menos un nivel de desempeno', v_crit->>'nombre'
                USING ERRCODE = '22023';
        END IF;

        -- Ponderacion OBLIGATORIA y valida en cada nivel.
        IF EXISTS (
            SELECT 1 FROM jsonb_array_elements(v_niveles) n
             WHERE (n->>'ponderacion') IS NULL
                OR (n->>'ponderacion')::NUMERIC < 0
                OR (n->>'ponderacion')::NUMERIC > 100
        ) THEN
            RAISE EXCEPTION 'Cada nivel del criterio "%" requiere ponderacion entre 0 y 100 (es obligatoria en la rubrica)', v_crit->>'nombre'
                USING ERRCODE = '22023';
        END IF;
        IF EXISTS (
            SELECT 1 FROM jsonb_array_elements(v_niveles) n
             WHERE NULLIF(TRIM(n->>'descripcion'), '') IS NULL
        ) THEN
            RAISE EXCEPTION 'Cada nivel del criterio "%" requiere descripcion (descriptor por nivel)', v_crit->>'nombre'
                USING ERRCODE = '22023';
        END IF;
        -- UN_TAC_RUBRICA_NIVEL_1 (criterio, ponderacion): mensaje claro antes del 23505.
        IF (SELECT COUNT(*) FROM jsonb_array_elements(v_niveles) n)
           <> (SELECT COUNT(DISTINCT (n->>'ponderacion')::NUMERIC) FROM jsonb_array_elements(v_niveles) n) THEN
            RAISE EXCEPTION 'El criterio "%" tiene dos niveles con la misma ponderacion', v_crit->>'nombre'
                USING ERRCODE = '22023';
        END IF;

        INSERT INTO academico_test.TACTIVIDAD_RUBRICA_CRITERIO (
            FK_TACTIVIDAD, ORDEN, NOMBRE, DESCRIPCION, CREATED_BY, CREATED_AT, ACTIVE
        ) VALUES (
            p_pk_tactividad, v_pos, TRIM(v_crit->>'nombre'),
            NULLIF(TRIM(v_crit->>'descripcion'), ''),
            p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
        )
        RETURNING PK_TACTIVIDAD_RUBRICA_CRITERIO INTO v_pk_criterio;

        INSERT INTO academico_test.TACTIVIDAD_RUBRICA_NIVEL (
            FK_TACTIVIDAD_RUBRICA_CRITERIO, ETIQUETA, DESCRIPCION, PONDERACION,
            CREATED_BY, CREATED_AT, ACTIVE
        )
        SELECT v_pk_criterio,
               NULLIF(TRIM(n->>'etiqueta'), ''),
               TRIM(n->>'descripcion'),
               (n->>'ponderacion')::NUMERIC,
               p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
          FROM jsonb_array_elements(v_niveles) n;
    END LOOP;

    RETURN v_pos;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_rubrica_definir(BIGINT, BIGINT, JSONB)
    IS 'Define (reemplazo completo) la rubrica de una actividad: TACTIVIDAD_RUBRICA_CRITERIO + TACTIVIDAD_RUBRICA_NIVEL. p_criterios = [{nombre, descripcion?, niveles:[{etiqueta?, descripcion, ponderacion}]}] con ORDEN por posicion. La PONDERACION del nivel es OBLIGATORIA (0..100) y no se puede repetir dentro de un mismo criterio (UN_TAC_RUBRICA_NIVEL_1); el criterio NO lleva peso propio. Exige que el instrumento de la actividad sea RUBRICA y desactiva los otros instrumentos. Gate EDITAR sobre PLANEADOR. Retorna cuantos criterios quedaron. V226.';

-- ---------------------------------------------------------------------------
-- fn_actividad_cotejo_definir — reemplazo completo de la lista de cotejo.
--
-- p_items JSONB = [{ "descripcion": "...", "ponderacion": 20 }]
--   ponderacion OPCIONAL (0..100). NULL = el item no pondera.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_cotejo_definir(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad            BIGINT,
    p_items                    JSONB
)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_insertados INT := 0;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'EDITAR'
    );
    PERFORM academico_test.fn_actividad_instrumento_assert(p_pk_tactividad, 'LISTA_COTEJO');

    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array'
       OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'p_items debe ser un arreglo JSON con al menos un item'
            USING ERRCODE = '22023';
    END IF;

    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(p_items) e
         WHERE NULLIF(TRIM(e->>'descripcion'), '') IS NULL
    ) THEN
        RAISE EXCEPTION 'Cada item de la lista de cotejo requiere descripcion' USING ERRCODE = '22023';
    END IF;
    -- Ponderacion OPCIONAL: solo se valida el rango cuando viene.
    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(p_items) e
         WHERE (e->>'ponderacion') IS NOT NULL
           AND ((e->>'ponderacion')::NUMERIC < 0 OR (e->>'ponderacion')::NUMERIC > 100)
    ) THEN
        RAISE EXCEPTION 'La ponderacion de un item de cotejo debe estar entre 0 y 100' USING ERRCODE = '22023';
    END IF;

    PERFORM academico_test.fn_actividad_instrumento_reset(p_pk_usuario_solicitante, p_pk_tactividad, NULL);

    INSERT INTO academico_test.TACTIVIDAD_COTEJO_ITEM (
        FK_TACTIVIDAD, ORDEN, DESCRIPCION, PONDERACION, CREATED_BY, CREATED_AT, ACTIVE
    )
    SELECT p_pk_tactividad,
           e.pos,
           TRIM(e.j->>'descripcion'),
           (e.j->>'ponderacion')::NUMERIC,
           p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
      FROM (SELECT elem AS j, ord AS pos
              FROM jsonb_array_elements(p_items) WITH ORDINALITY AS t(elem, ord)) e;

    GET DIAGNOSTICS v_insertados = ROW_COUNT;
    RETURN v_insertados;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_cotejo_definir(BIGINT, BIGINT, JSONB)
    IS 'Define (reemplazo completo) la lista de cotejo de una actividad: TACTIVIDAD_COTEJO_ITEM. p_items = [{descripcion, ponderacion?}] con ORDEN por posicion. La PONDERACION es OPCIONAL (0..100): NULL = el item no pondera; se permite mezclar items con y sin peso y NO se exige que sumen 100. Exige que el instrumento de la actividad sea LISTA_COTEJO y desactiva los otros instrumentos. Gate EDITAR sobre PLANEADOR. Retorna cuantos items quedaron. V226.';

-- ---------------------------------------------------------------------------
-- fn_actividad_escala_definir — reemplazo completo de la escala (1:1).
--
-- p_config JSONB = {
--   "tipoEscala": <pk_lv TIPO_ESCALA>,      -- obligatorio: NUMERICA | CUALITATIVA
--   "criteriosGenerales": "Criterio A, Criterio B",
--   "interpretacionRangos": "texto",
--   -- Solo NUMERICA:
--   "valorMin": 1, "valorMax": 5,           -- obligatorios, min < max
--   -- Solo CUALITATIVA:
--   "niveles": [{ "etiqueta": "Bajo", "descripcion": "...", "ponderacion": 1 }]
-- }
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_escala_definir(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad            BIGINT,
    p_config                   JSONB
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_tipo_val  VARCHAR;
    v_niveles   JSONB;
    v_min       NUMERIC;
    v_max       NUMERIC;
    v_pk_escala BIGINT;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'EDITAR'
    );
    PERFORM academico_test.fn_actividad_instrumento_assert(p_pk_tactividad, 'ESCALA_VALORACION');

    IF p_config IS NULL OR jsonb_typeof(p_config) <> 'object' THEN
        RAISE EXCEPTION 'p_config debe ser un objeto JSON' USING ERRCODE = '22023';
    END IF;
    IF (p_config->>'tipoEscala') IS NULL THEN
        RAISE EXCEPTION 'La escala requiere tipoEscala (NUMERICA o CUALITATIVA)' USING ERRCODE = '22023';
    END IF;
    PERFORM academico_test.fn_actividad_lv_assert((p_config->>'tipoEscala')::BIGINT, 'TIPO_ESCALA', 'tipoEscala');

    SELECT VALOR INTO v_tipo_val FROM academico_test.TLISTA_VALOR
     WHERE PK_LISTA_VALOR = (p_config->>'tipoEscala')::BIGINT;

    v_niveles := p_config->'niveles';
    v_min     := (p_config->>'valorMin')::NUMERIC;
    v_max     := (p_config->>'valorMax')::NUMERIC;

    IF v_tipo_val = 'NUMERICA' THEN
        IF v_min IS NULL OR v_max IS NULL THEN
            RAISE EXCEPTION 'La escala NUMERICA requiere valorMin y valorMax' USING ERRCODE = '22023';
        END IF;
        IF v_min >= v_max THEN
            RAISE EXCEPTION 'valorMin (%) debe ser menor que valorMax (%)', v_min, v_max USING ERRCODE = '22023';
        END IF;
        IF jsonb_typeof(v_niveles) = 'array' AND jsonb_array_length(v_niveles) > 0 THEN
            RAISE EXCEPTION 'La escala NUMERICA no lleva niveles: se define con valorMin/valorMax e interpretacionRangos'
                USING ERRCODE = '22023';
        END IF;
    ELSE  -- CUALITATIVA
        IF v_min IS NOT NULL OR v_max IS NOT NULL THEN
            RAISE EXCEPTION 'La escala CUALITATIVA no lleva valorMin/valorMax: se define con niveles' USING ERRCODE = '22023';
        END IF;
        IF v_niveles IS NULL OR jsonb_typeof(v_niveles) <> 'array' OR jsonb_array_length(v_niveles) = 0 THEN
            RAISE EXCEPTION 'La escala CUALITATIVA requiere al menos un nivel (definiciones cualitativas)'
                USING ERRCODE = '22023';
        END IF;
        -- Ponderacion OBLIGATORIA en cada nivel de la escala.
        IF EXISTS (
            SELECT 1 FROM jsonb_array_elements(v_niveles) n
             WHERE (n->>'ponderacion') IS NULL
                OR (n->>'ponderacion')::NUMERIC < 0
                OR (n->>'ponderacion')::NUMERIC > 100
        ) THEN
            RAISE EXCEPTION 'Cada nivel de la escala requiere ponderacion entre 0 y 100 (es obligatoria)'
                USING ERRCODE = '22023';
        END IF;
        IF EXISTS (
            SELECT 1 FROM jsonb_array_elements(v_niveles) n
             WHERE NULLIF(TRIM(n->>'descripcion'), '') IS NULL
        ) THEN
            RAISE EXCEPTION 'Cada nivel de la escala requiere descripcion (interpretacion / descriptor)'
                USING ERRCODE = '22023';
        END IF;
        -- UN_TAC_ESCALA_NIVEL_1 (escala, ponderacion).
        IF (SELECT COUNT(*) FROM jsonb_array_elements(v_niveles) n)
           <> (SELECT COUNT(DISTINCT (n->>'ponderacion')::NUMERIC) FROM jsonb_array_elements(v_niveles) n) THEN
            RAISE EXCEPTION 'Hay dos niveles de la escala con la misma ponderacion' USING ERRCODE = '22023';
        END IF;
    END IF;

    -- Limpia los otros instrumentos (la escala se hace upsert, no delete:
    -- UN_TAC_ESCALA_1 es UNIQUE(FK_TACTIVIDAD) sin filtro por ACTIVE).
    PERFORM academico_test.fn_actividad_instrumento_reset(
                p_pk_usuario_solicitante, p_pk_tactividad, 'ESCALA_VALORACION');

    SELECT PK_TACTIVIDAD_ESCALA INTO v_pk_escala
      FROM academico_test.TACTIVIDAD_ESCALA WHERE FK_TACTIVIDAD = p_pk_tactividad;

    IF v_pk_escala IS NULL THEN
        INSERT INTO academico_test.TACTIVIDAD_ESCALA (
            FK_TACTIVIDAD, CRITERIOS_GENERALES, FK_TLV_TIPO_ESCALA,
            VALOR_MIN, VALOR_MAX, INTERPRETACION_RANGOS,
            CREATED_BY, CREATED_AT, ACTIVE
        ) VALUES (
            p_pk_tactividad, NULLIF(TRIM(p_config->>'criteriosGenerales'), ''),
            (p_config->>'tipoEscala')::BIGINT, v_min, v_max,
            NULLIF(TRIM(p_config->>'interpretacionRangos'), ''),
            p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
        )
        RETURNING PK_TACTIVIDAD_ESCALA INTO v_pk_escala;
    ELSE
        UPDATE academico_test.TACTIVIDAD_ESCALA
           SET CRITERIOS_GENERALES   = NULLIF(TRIM(p_config->>'criteriosGenerales'), ''),
               FK_TLV_TIPO_ESCALA    = (p_config->>'tipoEscala')::BIGINT,
               VALOR_MIN             = v_min,
               VALOR_MAX             = v_max,
               INTERPRETACION_RANGOS = NULLIF(TRIM(p_config->>'interpretacionRangos'), ''),
               ACTIVE                = TRUE,
               MODIFIED_BY           = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT           = CURRENT_TIMESTAMP
         WHERE PK_TACTIVIDAD_ESCALA = v_pk_escala;

        UPDATE academico_test.TACTIVIDAD_ESCALA_NIVEL
           SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TACTIVIDAD_ESCALA = v_pk_escala AND ACTIVE = TRUE;
    END IF;

    IF v_tipo_val = 'CUALITATIVA' THEN
        INSERT INTO academico_test.TACTIVIDAD_ESCALA_NIVEL (
            FK_TACTIVIDAD_ESCALA, ORDEN, ETIQUETA, DESCRIPCION, PONDERACION,
            CREATED_BY, CREATED_AT, ACTIVE
        )
        SELECT v_pk_escala,
               e.pos,
               NULLIF(TRIM(e.j->>'etiqueta'), ''),
               TRIM(e.j->>'descripcion'),
               (e.j->>'ponderacion')::NUMERIC,
               p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
          FROM (SELECT elem AS j, ord AS pos
                  FROM jsonb_array_elements(v_niveles) WITH ORDINALITY AS t(elem, ord)) e;
    END IF;

    RETURN v_pk_escala;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_escala_definir(BIGINT, BIGINT, JSONB)
    IS 'Define (reemplazo completo) la escala de valoracion de una actividad: TACTIVIDAD_ESCALA (1:1, upsert porque UN_TAC_ESCALA_1 no filtra por ACTIVE) + TACTIVIDAD_ESCALA_NIVEL. p_config = {tipoEscala, criteriosGenerales?, interpretacionRangos?, valorMin/valorMax (solo NUMERICA), niveles (solo CUALITATIVA)}. NUMERICA exige valorMin<valorMax y prohibe niveles; CUALITATIVA exige >=1 nivel con descripcion y PONDERACION OBLIGATORIA (0..100, sin repetir — UN_TAC_ESCALA_NIVEL_1) y prohibe valorMin/valorMax. Exige que el instrumento de la actividad sea ESCALA_VALORACION y desactiva los otros. Gate EDITAR sobre PLANEADOR. Retorna PK_TACTIVIDAD_ESCALA. V226.';

-- ===========================================================================
-- (5) FACHADA — despacha segun el instrumento de la actividad + lectura.
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_instrumento_definir(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad            BIGINT,
    p_definicion               JSONB
)
RETURNS VARCHAR
LANGUAGE plpgsql
AS $$
DECLARE
    v_valor VARCHAR;
BEGIN
    SELECT lv.VALOR INTO v_valor
      FROM academico_test.TACTIVIDAD a
      LEFT JOIN academico_test.TLISTA_VALOR lv
             ON lv.PK_LISTA_VALOR = a.FK_TLV_INSTRUMENTO_EVALUACION
     WHERE a.PK_TACTIVIDAD = p_pk_tactividad;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la actividad solicitada' USING ERRCODE = 'P0002';
    END IF;

    CASE v_valor
        WHEN 'RUBRICA' THEN
            PERFORM academico_test.fn_actividad_rubrica_definir(
                        p_pk_usuario_solicitante, p_pk_tactividad, p_definicion);
        WHEN 'LISTA_COTEJO' THEN
            PERFORM academico_test.fn_actividad_cotejo_definir(
                        p_pk_usuario_solicitante, p_pk_tactividad, p_definicion);
        WHEN 'ESCALA_VALORACION' THEN
            PERFORM academico_test.fn_actividad_escala_definir(
                        p_pk_usuario_solicitante, p_pk_tactividad, p_definicion);
        WHEN 'OTRO' THEN
            -- Instrumento libre: el detalle va en TACTIVIDAD.DESCRIPCION_INSTRUMENTO,
            -- no hay estructura que definir. Se limpian los otros tres.
            PERFORM academico_test.fn_assert_permiso_seccion(
                        p_pk_usuario_solicitante, 'PLANEADOR', 'EDITAR');
            PERFORM academico_test.fn_actividad_instrumento_reset(
                        p_pk_usuario_solicitante, p_pk_tactividad, NULL);
        ELSE
            RAISE EXCEPTION 'La actividad no tiene un instrumento de evaluacion valido para definir (%)',
                COALESCE(v_valor, 'sin instrumento') USING ERRCODE = '22023';
    END CASE;

    RETURN v_valor;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_instrumento_definir(BIGINT, BIGINT, JSONB)
    IS 'Fachada: lee TACTIVIDAD.FK_TLV_INSTRUMENTO_EVALUACION y despacha a fn_actividad_rubrica_definir (array de criterios), fn_actividad_cotejo_definir (array de items) o fn_actividad_escala_definir (objeto de config). Con instrumento OTRO solo limpia los tres instrumentos estructurados (el detalle vive en DESCRIPCION_INSTRUMENTO). Gate EDITAR sobre PLANEADOR (via las funciones destino). Retorna el VALOR del instrumento aplicado. V226.';

-- ---------------------------------------------------------------------------
-- fn_actividad_instrumento_obtener — lectura del instrumento definido.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_instrumento_obtener(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad            BIGINT
)
RETURNS TABLE (
    instrumento         VARCHAR,
    instrumento_nombre  VARCHAR,
    definicion          JSONB
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    RETURN QUERY
    SELECT lv.VALOR,
           lv.NOMBRE,
           CASE lv.VALOR
               WHEN 'RUBRICA' THEN COALESCE((
                   SELECT jsonb_agg(jsonb_build_object(
                              'pk',          c.PK_TACTIVIDAD_RUBRICA_CRITERIO,
                              'orden',       c.ORDEN,
                              'nombre',      c.NOMBRE,
                              'descripcion', c.DESCRIPCION,
                              'niveles', COALESCE((
                                  SELECT jsonb_agg(jsonb_build_object(
                                             'pk',          n.PK_TACTIVIDAD_RUBRICA_NIVEL,
                                             'etiqueta',    n.ETIQUETA,
                                             'descripcion', n.DESCRIPCION,
                                             'ponderacion', n.PONDERACION)
                                             ORDER BY n.PONDERACION DESC)
                                    FROM academico_test.TACTIVIDAD_RUBRICA_NIVEL n
                                   WHERE n.FK_TACTIVIDAD_RUBRICA_CRITERIO = c.PK_TACTIVIDAD_RUBRICA_CRITERIO
                                     AND n.ACTIVE = TRUE
                              ), '[]'::jsonb))
                              ORDER BY c.ORDEN)
                     FROM academico_test.TACTIVIDAD_RUBRICA_CRITERIO c
                    WHERE c.FK_TACTIVIDAD = a.PK_TACTIVIDAD AND c.ACTIVE = TRUE
               ), '[]'::jsonb)

               WHEN 'LISTA_COTEJO' THEN COALESCE((
                   SELECT jsonb_agg(jsonb_build_object(
                              'pk',          i.PK_TACTIVIDAD_COTEJO_ITEM,
                              'orden',       i.ORDEN,
                              'descripcion', i.DESCRIPCION,
                              'ponderacion', i.PONDERACION)
                              ORDER BY i.ORDEN)
                     FROM academico_test.TACTIVIDAD_COTEJO_ITEM i
                    WHERE i.FK_TACTIVIDAD = a.PK_TACTIVIDAD AND i.ACTIVE = TRUE
               ), '[]'::jsonb)

               WHEN 'ESCALA_VALORACION' THEN (
                   SELECT jsonb_build_object(
                              'pk',                   e.PK_TACTIVIDAD_ESCALA,
                              'tipoEscala',           e.FK_TLV_TIPO_ESCALA,
                              'tipoEscalaNombre',     lte.NOMBRE,
                              'tipoEscalaValor',      lte.VALOR,
                              'criteriosGenerales',   e.CRITERIOS_GENERALES,
                              'valorMin',             e.VALOR_MIN,
                              'valorMax',             e.VALOR_MAX,
                              'interpretacionRangos', e.INTERPRETACION_RANGOS,
                              'niveles', COALESCE((
                                  SELECT jsonb_agg(jsonb_build_object(
                                             'pk',          en.PK_TACTIVIDAD_ESCALA_NIVEL,
                                             'orden',       en.ORDEN,
                                             'etiqueta',    en.ETIQUETA,
                                             'descripcion', en.DESCRIPCION,
                                             'ponderacion', en.PONDERACION)
                                             ORDER BY en.ORDEN)
                                    FROM academico_test.TACTIVIDAD_ESCALA_NIVEL en
                                   WHERE en.FK_TACTIVIDAD_ESCALA = e.PK_TACTIVIDAD_ESCALA
                                     AND en.ACTIVE = TRUE
                              ), '[]'::jsonb))
                     FROM academico_test.TACTIVIDAD_ESCALA e
                     LEFT JOIN academico_test.TLISTA_VALOR lte ON lte.PK_LISTA_VALOR = e.FK_TLV_TIPO_ESCALA
                    WHERE e.FK_TACTIVIDAD = a.PK_TACTIVIDAD AND e.ACTIVE = TRUE
               )

               ELSE NULL
           END
      FROM academico_test.TACTIVIDAD a
      LEFT JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = a.FK_TLV_INSTRUMENTO_EVALUACION
     WHERE a.PK_TACTIVIDAD = p_pk_tactividad;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_instrumento_obtener(BIGINT, BIGINT)
    IS 'Lee el instrumento de evaluacion definido para una actividad: devuelve su VALOR/NOMBRE y la definicion como JSONB segun el tipo — RUBRICA: [{pk,orden,nombre,descripcion,niveles:[{pk,etiqueta,descripcion,ponderacion}]}] (niveles ordenados por ponderacion DESC); LISTA_COTEJO: [{pk,orden,descripcion,ponderacion}]; ESCALA_VALORACION: {tipoEscala,criteriosGenerales,valorMin,valorMax,interpretacionRangos,niveles:[...]}; OTRO/sin instrumento: NULL. Gate VER sobre PLANEADOR. V226.';
