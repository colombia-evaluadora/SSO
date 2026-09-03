-- ===========================================================================
-- V223 — Planeador educativo: conexion Actividad <-> Unidad con ponderacion
-- (CU-86e311xxp — G. Academico Back Planeador educativo).
--
-- Pantalla "Actividades de la unidad" ("Vincular actividad" + columna (%)):
-- una actividad se vincula a una unidad y lleva un peso dentro de ella.
--
-- Cambios:
--   1. TACTIVIDAD.FK_TUNIDAD ya existe (V22; opcional desde V218) — es la
--      "fk de la unidad" de la relacion. No se re-crea.
--   2. TACTIVIDAD.PONDERACION (nueva): peso (%) de la actividad dentro de
--      su unidad. NUMERIC(5,2), 0..100, CHECK. Distinta de INFLUENCIA
--      (que V22 usa para el promedio ponderado de TUNIDAD_NOTA): PONDERACION
--      es el dato que edita el docente en la pestaña "Actividades" de la
--      unidad.
--   3. Regla de negocio: por cada (unidad, grupo) la suma de PONDERACION de
--      las actividades ACTIVE no puede pasar de 100. Se impone con un
--      trigger BEFORE INSERT/UPDATE (grupo NULL es su propio bucket,
--      IS NOT DISTINCT FROM).
--   4. Funciones de apoyo para la UI: fn_unidad_actividad_vincular /
--      _desvincular / _ponderacion_set (gate EDITAR sobre PLANEADOR, con
--      chequeo previo del 100% para dar un error claro antes del trigger).
--   5. fn_unidad_ponderacion_asignada — UNICA definicion de "cuanto %
--      lleva asignado esta (unidad, grupo)". La usan el trigger del punto 3
--      y las tres funciones del punto 4 (antes cada una repetia la misma
--      SUM correlacionada).
--   6. fn_unidad_ponderacion_disponible (gate VER) = 100 - lo asignado, para
--      que el modal "Vincular actividad" pinte "Disponible para asignar: X%"
--      por fila/grupo, y fn_actividad_disponibles_listar — el listado de
--      actividades candidatas de ese modal.
--
-- Depende de (orden de version de Flyway):
--   * V22  — TACTIVIDAD, TUNIDAD, TGRUPO.
--   * V218 — TACTIVIDAD.FK_TUNIDAD nullable, TACTIVIDAD.FK_TASIGNATURA.
--   * V216 — menu 'PLANEADOR' + fn_assert_permiso_seccion.
--
-- Estilo: DDL idempotente (ADD COLUMN IF NOT EXISTS, DROP CONSTRAINT IF
-- EXISTS, CREATE OR REPLACE, DROP TRIGGER IF EXISTS). search_path fijado
-- aqui (cada migracion corre en su propia transaccion).
-- ===========================================================================

SET search_path TO academico_test, public;

-- ---------------------------------------------------------------------------
-- 1. TACTIVIDAD.PONDERACION
-- ---------------------------------------------------------------------------
ALTER TABLE TACTIVIDAD
  ADD COLUMN IF NOT EXISTS PONDERACION NUMERIC(5,2);

ALTER TABLE TACTIVIDAD DROP CONSTRAINT IF EXISTS CK_TACTIVIDAD_PONDERACION;
ALTER TABLE TACTIVIDAD ADD CONSTRAINT CK_TACTIVIDAD_PONDERACION
  CHECK (PONDERACION IS NULL OR (PONDERACION >= 0 AND PONDERACION <= 100));

CREATE INDEX IF NOT EXISTS IDX_TACTIVIDAD_27
  ON TACTIVIDAD (FK_TUNIDAD, FK_TGRUPO) WHERE ACTIVE = true;

COMMENT ON COLUMN TACTIVIDAD.PONDERACION IS
  'Peso (%) de la actividad dentro de su unidad (FK_TUNIDAD), por grupo (FK_TGRUPO). 0..100. La suma por (FK_TUNIDAD, FK_TGRUPO) de las actividades ACTIVE no puede pasar de 100 (trigger tr_tactividad_ponderacion_unidad). Distinta de INFLUENCIA (V22, promedio ponderado de TUNIDAD_NOTA).';

-- ---------------------------------------------------------------------------
-- 2. fn_unidad_ponderacion_asignada — punto UNICO de la suma de ponderacion
--    por (unidad, grupo). Se define antes del trigger y de las funciones de
--    apoyo porque las tres la llaman.
--
--    p_excluir_tactividad permite pedir la suma "sin contar esta actividad",
--    que es lo que necesitan el trigger (la fila NEW todavia no esta
--    reflejada / lo va a estar) y los UPDATE de vincular / ponderacion_set
--    (no se debe contar el peso viejo de la actividad que se esta tocando).
--
--    Grupo NULL es su propio bucket (IS NOT DISTINCT FROM), igual que en el
--    indice IDX_TACTIVIDAD_27.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_ponderacion_asignada(
    p_pk_tunidad           BIGINT,
    p_fk_tgrupo            BIGINT,
    p_excluir_tactividad   BIGINT DEFAULT NULL
)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(SUM(a.PONDERACION), 0)::NUMERIC
      FROM academico_test.TACTIVIDAD a
     WHERE a.FK_TUNIDAD = p_pk_tunidad
       AND a.FK_TGRUPO IS NOT DISTINCT FROM p_fk_tgrupo
       AND a.ACTIVE = TRUE
       AND a.PONDERACION IS NOT NULL
       AND a.PK_TACTIVIDAD IS DISTINCT FROM p_excluir_tactividad;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_ponderacion_asignada(BIGINT, BIGINT, BIGINT)
    IS 'Suma de PONDERACION de las actividades ACTIVE (y con PONDERACION no nula) de una (FK_TUNIDAD, FK_TGRUPO); grupo NULL es su propio bucket (IS NOT DISTINCT FROM). p_excluir_tactividad (opcional) deja fuera una actividad concreta, para validar un INSERT/UPDATE sin contar la fila que se esta tocando. Definicion UNICA usada por el trigger tr_tactividad_ponderacion_unidad, fn_unidad_actividad_vincular, fn_unidad_actividad_ponderacion_set y fn_unidad_ponderacion_disponible. Retorna 0 (nunca NULL) si no hay nada asignado. V223.';

-- ---------------------------------------------------------------------------
-- 3. Regla del 100% por (unidad, grupo) — trigger
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_tactividad_ponderacion_unidad_check()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_suma NUMERIC(9,2);
BEGIN
    IF NEW.ACTIVE IS DISTINCT FROM TRUE
       OR NEW.FK_TUNIDAD IS NULL
       OR NEW.PONDERACION IS NULL THEN
        RETURN NEW;
    END IF;

    v_suma := academico_test.fn_unidad_ponderacion_asignada(
                  NEW.FK_TUNIDAD, NEW.FK_TGRUPO, NEW.PK_TACTIVIDAD);

    IF v_suma + NEW.PONDERACION > 100 THEN
        RAISE EXCEPTION
          'La ponderacion de las actividades de la unidad % para el grupo % ya suma % y con % nueva llegaria a % (maximo 100)',
          NEW.FK_TUNIDAD, NEW.FK_TGRUPO, v_suma, NEW.PONDERACION, v_suma + NEW.PONDERACION
          USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_tactividad_ponderacion_unidad_check()
    IS 'Trigger BEFORE INSERT/UPDATE de TACTIVIDAD: impide que la suma de PONDERACION de las actividades ACTIVE de un mismo (FK_TUNIDAD, FK_TGRUPO) pase de 100. Grupo NULL es su propio bucket (IS NOT DISTINCT FROM).';

DROP TRIGGER IF EXISTS tr_tactividad_ponderacion_unidad ON TACTIVIDAD;
CREATE TRIGGER tr_tactividad_ponderacion_unidad
  BEFORE INSERT OR UPDATE OF PONDERACION, FK_TUNIDAD, FK_TGRUPO, ACTIVE ON TACTIVIDAD
  FOR EACH ROW
  EXECUTE FUNCTION academico_test.fn_tactividad_ponderacion_unidad_check();

-- ===========================================================================
-- 4. Funciones de apoyo para la UI.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- fn_unidad_actividad_vincular — vincula/actualiza (unidad + ponderacion).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_actividad_vincular(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad            BIGINT,
    p_pk_tunidad               BIGINT,
    p_ponderacion              NUMERIC DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_act_active     BOOLEAN;
    v_fk_grupo       BIGINT;
    v_unidad_active  BOOLEAN;
    v_suma           NUMERIC(9,2);
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'EDITAR'
    );

    SELECT ACTIVE, FK_TGRUPO INTO v_act_active, v_fk_grupo
      FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_pk_tactividad;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la actividad solicitada' USING ERRCODE = 'P0002';
    END IF;
    IF v_act_active = FALSE THEN
        RAISE EXCEPTION 'La actividad esta inactiva; no se puede vincular' USING ERRCODE = '22023';
    END IF;

    SELECT ACTIVE INTO v_unidad_active
      FROM academico_test.TUNIDAD WHERE PK_TUNIDAD = p_pk_tunidad;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'FK_TUNIDAD (%) no existe', p_pk_tunidad USING ERRCODE = '23503';
    END IF;
    IF v_unidad_active = FALSE THEN
        RAISE EXCEPTION 'La unidad (%) esta inactiva', p_pk_tunidad USING ERRCODE = '22023';
    END IF;

    IF p_ponderacion IS NOT NULL AND (p_ponderacion < 0 OR p_ponderacion > 100) THEN
        RAISE EXCEPTION 'La ponderacion (%) debe estar entre 0 y 100', p_ponderacion USING ERRCODE = '22023';
    END IF;

    -- Chequeo previo del 100% (error claro antes del trigger).
    IF p_ponderacion IS NOT NULL THEN
        v_suma := academico_test.fn_unidad_ponderacion_asignada(
                      p_pk_tunidad, v_fk_grupo, p_pk_tactividad);
        IF v_suma + p_ponderacion > 100 THEN
            RAISE EXCEPTION
              'La unidad % ya tiene % %% ponderado para el grupo %; % %% adicionales pasarian de 100',
              p_pk_tunidad, v_suma, v_fk_grupo, p_ponderacion
              USING ERRCODE = '23514';
        END IF;
    END IF;

    UPDATE academico_test.TACTIVIDAD
       SET FK_TUNIDAD   = p_pk_tunidad,
           PONDERACION  = COALESCE(p_ponderacion, PONDERACION),
           MODIFIED_BY  = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT  = CURRENT_TIMESTAMP
     WHERE PK_TACTIVIDAD = p_pk_tactividad;

    RETURN p_pk_tactividad;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_actividad_vincular(BIGINT, BIGINT, BIGINT, NUMERIC)
    IS 'Vincula una actividad a una unidad (TACTIVIDAD.FK_TUNIDAD) y fija su PONDERACION (%) dentro de ella. p_ponderacion NULL = no cambiar el peso actual. Valida 0..100 y que la suma por (unidad, grupo de la actividad) no pase de 100 (mismo criterio que el trigger). Gate EDITAR sobre PLANEADOR. Retorna PK_TACTIVIDAD.';

-- ---------------------------------------------------------------------------
-- fn_unidad_actividad_desvincular — quita la unidad y su ponderacion.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_actividad_desvincular(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad            BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_act_active BOOLEAN;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'EDITAR'
    );

    SELECT ACTIVE INTO v_act_active
      FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_pk_tactividad;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la actividad solicitada' USING ERRCODE = 'P0002';
    END IF;

    UPDATE academico_test.TACTIVIDAD
       SET FK_TUNIDAD   = NULL,
           PONDERACION  = NULL,
           MODIFIED_BY  = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT  = CURRENT_TIMESTAMP
     WHERE PK_TACTIVIDAD = p_pk_tactividad;

    RETURN p_pk_tactividad;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_actividad_desvincular(BIGINT, BIGINT)
    IS 'Quita la vinculacion de una actividad con su unidad: FK_TUNIDAD = NULL y PONDERACION = NULL. Gate EDITAR sobre PLANEADOR. Retorna PK_TACTIVIDAD.';

-- ---------------------------------------------------------------------------
-- fn_unidad_actividad_ponderacion_set — edicion inline de la columna (%).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_actividad_ponderacion_set(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad            BIGINT,
    p_ponderacion              NUMERIC
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_act_active  BOOLEAN;
    v_fk_unidad   BIGINT;
    v_fk_grupo    BIGINT;
    v_suma        NUMERIC(9,2);
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'EDITAR'
    );

    SELECT ACTIVE, FK_TUNIDAD, FK_TGRUPO INTO v_act_active, v_fk_unidad, v_fk_grupo
      FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_pk_tactividad;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la actividad solicitada' USING ERRCODE = 'P0002';
    END IF;
    IF v_act_active = FALSE THEN
        RAISE EXCEPTION 'La actividad esta inactiva' USING ERRCODE = '22023';
    END IF;
    IF v_fk_unidad IS NULL THEN
        RAISE EXCEPTION 'La actividad no esta vinculada a ninguna unidad; use fn_unidad_actividad_vincular' USING ERRCODE = '22023';
    END IF;
    IF p_ponderacion IS NULL OR p_ponderacion < 0 OR p_ponderacion > 100 THEN
        RAISE EXCEPTION 'La ponderacion (%) debe estar entre 0 y 100', p_ponderacion USING ERRCODE = '22023';
    END IF;

    v_suma := academico_test.fn_unidad_ponderacion_asignada(
                  v_fk_unidad, v_fk_grupo, p_pk_tactividad);
    IF v_suma + p_ponderacion > 100 THEN
        RAISE EXCEPTION
          'La unidad % ya tiene % %% ponderado para el grupo %; % %% pasarian de 100',
          v_fk_unidad, v_suma, v_fk_grupo, p_ponderacion
          USING ERRCODE = '23514';
    END IF;

    UPDATE academico_test.TACTIVIDAD
       SET PONDERACION = p_ponderacion,
           MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TACTIVIDAD = p_pk_tactividad;

    RETURN p_pk_tactividad;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_actividad_ponderacion_set(BIGINT, BIGINT, NUMERIC)
    IS 'Fija la PONDERACION (%) de una actividad ya vinculada a una unidad (edicion inline de la columna (%)). Valida 0..100 y la regla del 100% por (unidad, grupo) via fn_unidad_ponderacion_asignada. Gate EDITAR sobre PLANEADOR. Retorna PK_TACTIVIDAD.';

-- ===========================================================================
-- 5. Lectura para el modal "Vincular actividad".
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- fn_unidad_ponderacion_disponible — "Disponible para asignar: X%".
--
-- Contraparte de lectura (gate VER) de fn_unidad_ponderacion_asignada: lo
-- que le queda libre a ese (unidad, grupo) para repartir. Nunca negativo:
-- el trigger del punto 3 impide pasar de 100, pero se acota con GREATEST
-- por si un dato historico (previo al trigger) ya estuviera por encima.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_ponderacion_disponible(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tunidad               BIGINT,
    p_fk_tgrupo                BIGINT
)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    IF NOT EXISTS (SELECT 1 FROM academico_test.TUNIDAD WHERE PK_TUNIDAD = p_pk_tunidad) THEN
        RAISE EXCEPTION 'No se encontro la unidad tematica solicitada' USING ERRCODE = 'P0002';
    END IF;

    RETURN GREATEST(
        100 - academico_test.fn_unidad_ponderacion_asignada(p_pk_tunidad, p_fk_tgrupo, NULL),
        0
    );
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_ponderacion_disponible(BIGINT, BIGINT, BIGINT)
    IS 'Porcentaje que le queda LIBRE a una (unidad, grupo) para repartir entre actividades: 100 - fn_unidad_ponderacion_asignada(unidad, grupo). Alimenta el "Disponible para asignar: X%" del modal "Vincular actividad" (una lectura por fila/grupo). Grupo NULL es su propio bucket. Acotado a >= 0 por si algun dato historico previo al trigger tr_tactividad_ponderacion_unidad pasara de 100. Gate VER sobre PLANEADOR. P0002 si la unidad no existe. V223.';

-- ---------------------------------------------------------------------------
-- fn_actividad_disponibles_listar — actividades candidatas a vincularse a
-- una unidad (el listado del modal "Vincular actividad").
--
-- CRITERIO DE "ACTIVIDAD CANDIDATA" (decision documentada):
--   a) ACTIVE = TRUE y FK_TUNIDAD IS NULL — una actividad ya vinculada a
--      CUALQUIER unidad no vuelve a aparecer: reasignarla es mover, no
--      vincular, y para eso esta fn_actividad_actualizar / _desvincular.
--   b) Misma asignatura que la unidad (TACTIVIDAD.FK_TASIGNATURA =
--      TUNIDAD.FK_TASIGNATURA, ambas NOT NULL desde V218): una unidad de
--      Matematicas no puede ponderar una actividad de Sociales.
--   c) Mismo grado, resuelto por el GRUPO de la actividad
--      (TGRUPO.FK_TGRADO = TUNIDAD.FK_TGRADO). La actividad SIN grupo
--      (FK_TGRUPO NULL) SI es candidata: no hay con que contradecir el
--      grado de la unidad y es el caso normal de una actividad creada
--      "suelta" que luego se cuelga de la unidad. Se filtra solo cuando el
--      grupo existe y pertenece a otro grado.
--
-- El "% disponible" de la fila es el del GRUPO de esa actividad (bucket que
-- le tocaria al vincularla), via fn_unidad_ponderacion_disponible.
--
-- Sigue el patron CTE-base + COUNT(*) OVER() de fn_actividad_listar (V224):
-- el CTE pagina tocando solo TACTIVIDAD (+ el TGRUPO necesario para el
-- filtro de grado) y los joins de catalogo corren contra la pagina.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_disponibles_listar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tunidad               BIGINT,
    p_search                   VARCHAR DEFAULT NULL,
    p_pagina                   INT     DEFAULT 1,
    p_tamano_pagina            INT     DEFAULT 20
)
RETURNS TABLE (
    pk_tactividad                   BIGINT,
    titulo                          VARCHAR,
    fk_tlv_tipo_actividad           BIGINT,
    tipo_actividad                  VARCHAR,
    fk_tlv_instrumento_evaluacion   BIGINT,
    instrumento_evaluacion          VARCHAR,
    fk_tgrupo                       BIGINT,
    grupo                           VARCHAR,
    porcentaje_disponible           NUMERIC,
    total_count                     BIGINT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_fk_tasignatura BIGINT;
    v_fk_tgrado      BIGINT;
    v_limite         INT;
    v_offset         INT;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    SELECT u.FK_TASIGNATURA, u.FK_TGRADO
      INTO v_fk_tasignatura, v_fk_tgrado
      FROM academico_test.TUNIDAD u
     WHERE u.PK_TUNIDAD = p_pk_tunidad AND u.ACTIVE = TRUE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la unidad tematica solicitada' USING ERRCODE = 'P0002';
    END IF;

    v_limite := GREATEST(COALESCE(p_tamano_pagina, 20), 1);
    v_offset := (GREATEST(COALESCE(p_pagina, 1), 1) - 1) * v_limite;

    RETURN QUERY
    WITH base AS (
        SELECT a.PK_TACTIVIDAD AS pk,
               COUNT(*) OVER() AS total
          FROM academico_test.TACTIVIDAD a
          LEFT JOIN academico_test.TGRUPO g ON g.PK_TGRUPO = a.FK_TGRUPO
         WHERE a.ACTIVE = TRUE
           AND a.FK_TUNIDAD IS NULL
           AND a.FK_TASIGNATURA = v_fk_tasignatura
           AND (a.FK_TGRUPO IS NULL OR g.FK_TGRADO = v_fk_tgrado)
           -- Misma expresion que idx_tactividad_busqueda_trgm (V224) para
           -- que el GIN trigram se use tambien aqui.
           AND (p_search IS NULL OR
                (COALESCE(a.TITULO,'') || ' ' || COALESCE(a.DESCRIPCION,''))
                    ILIKE '%' || p_search || '%')
         ORDER BY a.TITULO, a.PK_TACTIVIDAD
         LIMIT v_limite
        OFFSET v_offset
    )
    SELECT a.PK_TACTIVIDAD,
           a.TITULO,
           a.FK_TLV_TIPO_ACTIVIDAD,
           lvt.NOMBRE,
           a.FK_TLV_INSTRUMENTO_EVALUACION,
           lvi.NOMBRE,
           a.FK_TGRUPO,
           g.NOMBRE,
           academico_test.fn_unidad_ponderacion_disponible(
               p_pk_usuario_solicitante, p_pk_tunidad, a.FK_TGRUPO),
           b.total
      FROM base b
      JOIN academico_test.TACTIVIDAD a          ON a.PK_TACTIVIDAD = b.pk
      LEFT JOIN academico_test.TGRUPO g         ON g.PK_TGRUPO = a.FK_TGRUPO
      LEFT JOIN academico_test.TLISTA_VALOR lvt ON lvt.PK_LISTA_VALOR = a.FK_TLV_TIPO_ACTIVIDAD
      LEFT JOIN academico_test.TLISTA_VALOR lvi ON lvi.PK_LISTA_VALOR = a.FK_TLV_INSTRUMENTO_EVALUACION
     ORDER BY a.TITULO, a.PK_TACTIVIDAD;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_disponibles_listar(BIGINT, BIGINT, VARCHAR, INT, INT)
    IS 'Actividades candidatas a vincularse a una unidad (listado del modal "Vincular actividad"), paginado con p_pagina/p_tamano_pagina y total_count via COUNT(*) OVER() sobre el mismo CTE-base de fn_actividad_listar (V224). Criterio de candidata: ACTIVE, FK_TUNIDAD IS NULL (una actividad ya vinculada a otra unidad NO aparece: moverla es fn_actividad_actualizar / fn_unidad_actividad_desvincular), misma FK_TASIGNATURA que la unidad, y mismo grado resuelto por el grupo de la actividad (TGRUPO.FK_TGRADO = TUNIDAD.FK_TGRADO) -- la actividad SIN grupo si es candidata, solo se descarta la que tiene un grupo de otro grado. p_search hace ILIKE sobre TITULO+DESCRIPCION con la misma expresion de idx_tactividad_busqueda_trgm. Devuelve pk, titulo, tipo e instrumento con NOMBRE resuelto, grupo, y porcentaje_disponible = fn_unidad_ponderacion_disponible(unidad, grupo de esa fila) para pintar "Disponible para asignar: X%". Gate VER sobre PLANEADOR. V223.';
