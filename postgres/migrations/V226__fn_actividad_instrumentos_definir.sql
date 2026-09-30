-- V226 - Definición de instrumentos de una actividad: rúbrica, lista de cotejo
-- y escala (fn_actividad_*_definir + fn_actividad_instrumento_reset), con sus
-- ajustes de tablas y el saneamiento de datos. La fachada
-- fn_actividad_instrumento_definir vive hoy en V496.3.


SET search_path TO academico_test, public;

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

ALTER TABLE TACTIVIDAD_COTEJO_ITEM
  ADD COLUMN IF NOT EXISTS PONDERACION NUMERIC(5,2);

ALTER TABLE TACTIVIDAD_COTEJO_ITEM DROP CONSTRAINT IF EXISTS CK_TAC_COTEJO_ITEM_PONDERACION;

ALTER TABLE TACTIVIDAD_COTEJO_ITEM ADD CONSTRAINT CK_TAC_COTEJO_ITEM_PONDERACION
  CHECK (PONDERACION IS NULL OR (PONDERACION >= 0 AND PONDERACION <= 100));

COMMENT ON COLUMN TACTIVIDAD_COTEJO_ITEM.PONDERACION IS
  'Peso (%) OPCIONAL del item dentro de la lista de cotejo (0..100). NULL = el item no pondera. Se permite mezclar items con y sin peso y NO se exige que sumen 100. V226.';

ALTER TABLE TACTIVIDAD_RUBRICA_NIVEL ADD COLUMN IF NOT EXISTS ETIQUETA VARCHAR(130);

ALTER TABLE TACTIVIDAD_ESCALA_NIVEL  ADD COLUMN IF NOT EXISTS ETIQUETA VARCHAR(130);

COMMENT ON COLUMN TACTIVIDAD_RUBRICA_NIVEL.ETIQUETA IS
  'Rotulo del nivel de desempeno (ej: "Excelente", "Bueno"). El texto largo va en DESCRIPCION ("Descriptor por nivel" del figma). Nullable. V226.';

COMMENT ON COLUMN TACTIVIDAD_ESCALA_NIVEL.ETIQUETA IS
  'Rotulo del nivel de la escala cualitativa (ej: "Bajo", "Medio", "Alto"). El texto largo va en DESCRIPCION ("Interpretacion / descriptor" del figma). Nullable. V226.';

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_instrumento_reset(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad            BIGINT,
    
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
    v_tipo_eval   VARCHAR;
BEGIN
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'EDITAR', NULL, NULL, NULL, p_pk_tactividad
    );
    PERFORM academico_test.fn_actividad_instrumento_assert(p_pk_tactividad, 'RUBRICA');

    -- Consistencia con el "listado dado por el referente" (V214.2): definir no
    -- puede permitir lo que fn_actividad_instrumentos_permitidos ya prohibio.
    -- Un referente CUANTITATIVA solo admite ESCALA_VALORACION (numerica).
    v_tipo_eval := academico_test.fn_actividad_referente_tipo_evaluacion(p_pk_tactividad);
    IF NOT academico_test.fn_instrumento_permitido_por_tipo_evaluacion('RUBRICA', v_tipo_eval) THEN
        RAISE EXCEPTION 'La rubrica no aplica: el referente curricular de la unidad de la actividad es de tipo de evaluacion % y solo admite escala de valoracion numerica', v_tipo_eval
            USING ERRCODE = '22023';
    END IF;

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
        -- Al menos un nivel con ponderacion > 0: si el MAX fuera 0, V227
        -- (fn_actividad_nota_calificar_rubrica, NULLIF(MAX(ponderacion),0))
        -- calcularia un % indefinido (NULL) sin importar el nivel elegido.
        IF (SELECT MAX((n->>'ponderacion')::NUMERIC) FROM jsonb_array_elements(v_niveles) n) = 0 THEN
            RAISE EXCEPTION 'El criterio "%" tiene todos sus niveles en ponderacion 0: al menos uno debe ser mayor a 0 para poder calcular un porcentaje al calificar', v_crit->>'nombre'
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
    IS 'Define (reemplazo completo) la rubrica de una actividad: TACTIVIDAD_RUBRICA_CRITERIO + TACTIVIDAD_RUBRICA_NIVEL. p_criterios = [{nombre, descripcion?, niveles:[{etiqueta?, descripcion, ponderacion}]}] con ORDEN por posicion. La PONDERACION del nivel es OBLIGATORIA (0..100) y no se puede repetir dentro de un mismo criterio (UN_TAC_RUBRICA_NIVEL_1); ademas el MAX de las ponderaciones de cada criterio debe ser > 0 (si no, el % al calificar en V227 quedaria indefinido). El criterio NO lleva peso propio. Exige que el instrumento de la actividad sea RUBRICA y desactiva los otros instrumentos. Ademas RECHAZA (22023) definir la rubrica cuando el referente curricular de la unidad de la actividad es de TIPO_EVALUACION CUANTITATIVA (que solo admite escala de valoracion numerica): mismo mapeo unico -- fn_instrumento_permitido_por_tipo_evaluacion (V214.2) -- que usa fn_actividad_instrumentos_permitidos, para que definir no permita lo que el listado ya prohibio. Gate EDITAR sobre PLANEADOR. Retorna cuantos criterios quedaron. V226.';

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
    v_tipo_eval  VARCHAR;
BEGIN
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'EDITAR', NULL, NULL, NULL, p_pk_tactividad
    );
    PERFORM academico_test.fn_actividad_instrumento_assert(p_pk_tactividad, 'LISTA_COTEJO');

    -- Misma consistencia que en la rubrica: un referente CUANTITATIVA solo
    -- admite escala de valoracion numerica (mapeo unico de V214.2).
    v_tipo_eval := academico_test.fn_actividad_referente_tipo_evaluacion(p_pk_tactividad);
    IF NOT academico_test.fn_instrumento_permitido_por_tipo_evaluacion('LISTA_COTEJO', v_tipo_eval) THEN
        RAISE EXCEPTION 'La lista de cotejo no aplica: el referente curricular de la unidad de la actividad es de tipo de evaluacion % y solo admite escala de valoracion numerica', v_tipo_eval
            USING ERRCODE = '22023';
    END IF;

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
    -- SUM(COALESCE(ponderacion, 1)) > 0: solo se rompe si TODOS los items
    -- tienen ponderacion EXPLICITA en 0 (sin ningun NULL, que aporta peso 1).
    -- Si no, V227 (fn_actividad_nota_calificar_cotejo) calcularia un %
    -- indefinido (division por 0/NULLIF).
    IF (SELECT SUM(COALESCE((e->>'ponderacion')::NUMERIC, 1)) FROM jsonb_array_elements(p_items) e) = 0 THEN
        RAISE EXCEPTION 'Todos los items de la lista de cotejo tienen ponderacion explicita en 0: al menos uno debe quedar sin ponderacion o con ponderacion mayor a 0 para poder calcular un porcentaje al calificar'
            USING ERRCODE = '22023';
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
    IS 'Define (reemplazo completo) la lista de cotejo de una actividad: TACTIVIDAD_COTEJO_ITEM. p_items = [{descripcion, ponderacion?}] con ORDEN por posicion. La PONDERACION es OPCIONAL (0..100): NULL = el item no pondera (peso 1 en el calculo de V227); se permite mezclar items con y sin peso y NO se exige que sumen 100. Se exige SUM(COALESCE(ponderacion,1)) > 0, es decir se rechaza solo si TODOS los items traen ponderacion explicita en 0 (sin ningun NULL que aporte peso 1), pues dejaria el % al calificar indefinido. Exige que el instrumento de la actividad sea LISTA_COTEJO y desactiva los otros instrumentos. Ademas RECHAZA (22023) definirla cuando el referente curricular de la unidad de la actividad es de TIPO_EVALUACION CUANTITATIVA (que solo admite escala de valoracion numerica), via fn_instrumento_permitido_por_tipo_evaluacion (V214.2). Gate EDITAR sobre PLANEADOR. Retorna cuantos items quedaron. V226.';

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
    v_tipo_eval VARCHAR;
BEGIN
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'EDITAR', NULL, NULL, NULL, p_pk_tactividad
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

    -- Consistencia con el "listado dado por el referente" (V214.2): el TIPO de
    -- la escala debe encajar con el TIPO_EVALUACION del referente de la
    -- unidad de la actividad. A diferencia de rubrica/cotejo aqui NO se usa
    -- fn_instrumento_permitido_por_tipo_evaluacion, porque la restriccion no
    -- es sobre el instrumento sino sobre COMO se configura:
    --   * referente CUALITATIVA  -> escala NUMERICA prohibida.
    --   * referente CUANTITATIVA -> escala CUALITATIVA prohibida (ese tipo de
    --     evaluacion solo admite la escala numerica).
    --   * CUANTITATIVA_CUALITATIVA, o sin unidad/referente/tipo -> sin
    --     restriccion.
    v_tipo_eval := academico_test.fn_actividad_referente_tipo_evaluacion(p_pk_tactividad);
    IF v_tipo_val = 'NUMERICA' AND v_tipo_eval = 'CUALITATIVA' THEN
        RAISE EXCEPTION 'No se puede definir una escala NUMERICA: el referente curricular de la unidad de la actividad es de tipo de evaluacion CUALITATIVA'
            USING ERRCODE = '22023',
                  HINT = 'Use una escala CUALITATIVA, o una rubrica / lista de cotejo';
    END IF;
    IF v_tipo_val = 'CUALITATIVA' AND v_tipo_eval = 'CUANTITATIVA' THEN
        RAISE EXCEPTION 'No se puede definir una escala CUALITATIVA: el referente curricular de la unidad de la actividad es de tipo de evaluacion CUANTITATIVA'
            USING ERRCODE = '22023',
                  HINT = 'Use una escala NUMERICA (valorMin / valorMax)';
    END IF;

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
        -- Al menos un nivel con ponderacion > 0 (misma razon que en rubrica):
        -- si el MAX fuera 0, V227 (fn_actividad_nota_calificar_escala, rama
        -- CUALITATIVA) calcularia un % indefinido. La rama NUMERICA ya esta
        -- a salvo porque exige valorMin < valorMax.
        IF (SELECT MAX((n->>'ponderacion')::NUMERIC) FROM jsonb_array_elements(v_niveles) n) = 0 THEN
            RAISE EXCEPTION 'Todos los niveles de la escala tienen ponderacion 0: al menos uno debe ser mayor a 0 para poder calcular un porcentaje al calificar'
                USING ERRCODE = '22023';
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
    IS 'Define (reemplazo completo) la escala de valoracion de una actividad: TACTIVIDAD_ESCALA (1:1, upsert porque UN_TAC_ESCALA_1 no filtra por ACTIVE) + TACTIVIDAD_ESCALA_NIVEL. p_config = {tipoEscala, criteriosGenerales?, interpretacionRangos?, valorMin/valorMax (solo NUMERICA), niveles (solo CUALITATIVA)}. NUMERICA exige valorMin<valorMax y prohibe niveles; CUALITATIVA exige >=1 nivel con descripcion y PONDERACION OBLIGATORIA (0..100, sin repetir — UN_TAC_ESCALA_NIVEL_1, y con MAX > 0 para que el % al calificar en V227 no quede indefinido) y prohibe valorMin/valorMax. Exige que el instrumento de la actividad sea ESCALA_VALORACION y desactiva los otros. Coherencia con el TIPO_EVALUACION del referente de la unidad (fn_actividad_referente_tipo_evaluacion, V214.2): con referente CUALITATIVA se RECHAZA (22023) una escala NUMERICA, y con referente CUANTITATIVA se rechaza una escala CUALITATIVA; con CUANTITATIVA_CUALITATIVA, o sin unidad/referente/tipo, no se restringe. Gate EDITAR sobre PLANEADOR. Retorna PK_TACTIVIDAD_ESCALA. V226.';

DO $sane$
DECLARE
    r           RECORD;
    v_afectadas INT := 0;
BEGIN
    FOR r IN
        SELECT a.PK_TACTIVIDAD, a.TITULO
          FROM academico_test.TACTIVIDAD a
         WHERE a.ACTIVE = TRUE
           AND a.FK_TLV_INSTRUMENTO_EVALUACION IS NOT NULL
           -- fn_unidad_referente_evaluativo devuelve FALSE tanto si la unidad
           -- es formativa como si la actividad no tiene unidad (FK_TUNIDAD
           -- NULL no casa con ninguna fila), que son los dos estados rotos.
           AND NOT academico_test.fn_unidad_referente_evaluativo(a.FK_TUNIDAD)
    LOOP
        -- Baja logica de rubrica / lista de cotejo / escala de la actividad.
        -- p_conservar = NULL las limpia las tres. Se pasa el usuario del
        -- sistema (0) como autor del cambio: no hay sesion en una migracion.
        PERFORM academico_test.fn_actividad_instrumento_reset(0, r.PK_TACTIVIDAD, NULL);

        UPDATE academico_test.TACTIVIDAD
           SET FK_TLV_INSTRUMENTO_EVALUACION = NULL,
               DESCRIPCION_INSTRUMENTO       = NULL,
               MODIFIED_BY                   = '0',
               MODIFIED_AT                   = CURRENT_TIMESTAMP
         WHERE PK_TACTIVIDAD = r.PK_TACTIVIDAD;

        v_afectadas := v_afectadas + 1;
        RAISE NOTICE 'Saneada la actividad % ("%"): se retiro el instrumento de evaluacion que su unidad ya no admitia',
            r.PK_TACTIVIDAD, r.TITULO;
    END LOOP;

    RAISE NOTICE 'Saneamiento de instrumentos huerfanos: % actividad(es) corregida(s)', v_afectadas;
END;
$sane$;
