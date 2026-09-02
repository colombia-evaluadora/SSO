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
--
-- Depende de (orden de version de Flyway):
--   * V22  — TACTIVIDAD, TUNIDAD, TGRUPO.
--   * V218 — TACTIVIDAD.FK_TUNIDAD nullable.
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
-- 2. Regla del 100% por (unidad, grupo) — trigger
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

    SELECT COALESCE(SUM(a.PONDERACION), 0)
      INTO v_suma
      FROM academico_test.TACTIVIDAD a
     WHERE a.FK_TUNIDAD = NEW.FK_TUNIDAD
       AND a.FK_TGRUPO IS NOT DISTINCT FROM NEW.FK_TGRUPO
       AND a.ACTIVE = TRUE
       AND a.PONDERACION IS NOT NULL
       AND a.PK_TACTIVIDAD <> COALESCE(NEW.PK_TACTIVIDAD, -1);

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
-- 3. Funciones de apoyo para la UI.
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
        SELECT COALESCE(SUM(a.PONDERACION), 0)
          INTO v_suma
          FROM academico_test.TACTIVIDAD a
         WHERE a.FK_TUNIDAD = p_pk_tunidad
           AND a.FK_TGRUPO IS NOT DISTINCT FROM v_fk_grupo
           AND a.ACTIVE = TRUE
           AND a.PONDERACION IS NOT NULL
           AND a.PK_TACTIVIDAD <> p_pk_tactividad;
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

    SELECT COALESCE(SUM(a.PONDERACION), 0)
      INTO v_suma
      FROM academico_test.TACTIVIDAD a
     WHERE a.FK_TUNIDAD = v_fk_unidad
       AND a.FK_TGRUPO IS NOT DISTINCT FROM v_fk_grupo
       AND a.ACTIVE = TRUE
       AND a.PONDERACION IS NOT NULL
       AND a.PK_TACTIVIDAD <> p_pk_tactividad;
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
    IS 'Fija la PONDERACION (%) de una actividad ya vinculada a una unidad (edicion inline de la columna (%)). Valida 0..100 y la regla del 100% por (unidad, grupo). Gate EDITAR sobre PLANEADOR. Retorna PK_TACTIVIDAD.';
