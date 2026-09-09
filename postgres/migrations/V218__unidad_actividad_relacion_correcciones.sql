-- ===========================================================================
-- V218 — Correcciones de la relacion Unidad <-> Actividad
-- (CU-86e329pvq — Fix Correcciones de Relacion Unidad-Actividad).
--
-- Cambios:
--   1. TACTIVIDAD.FK_TASIGNATURA (nueva): la actividad se ancla directamente
--      a una asignatura, sin depender de la unidad. Se backfillea desde
--      TUNIDAD.FK_TASIGNATURA para las filas existentes (hoy toda actividad
--      tiene unidad) y queda NOT NULL.
--   2. TACTIVIDAD.FK_TUNIDAD pasa a ser NULLABLE: una actividad ya no exige
--      pertenecer a una unidad pedagogica (queda como agrupador opcional).
--   3. TUNIDAD.FK_TPERIODO_EVALUACION se elimina: la unidad deja de estar
--      atada a un periodo de evaluacion. Implica soltar el FK, el indice y
--      recomponer el UNIQUE UN_TUNIDAD_1 sin esa columna.
--   4. TUSUARIO.FECHA_NACIMIENTO pasa a NULLABLE: V22 la creo NOT NULL pero
--      el servidor ya la tiene relajada (no se exige en varios flujos de
--      alta de usuario); se alinea el esquema.
--
-- Depende de (se aplica antes por orden de version de Flyway):
--   * V22 — TUNIDAD, TACTIVIDAD, TASIGNATURA, TUSUARIO.
--
-- Estilo: DDL idempotente (IF [NOT] EXISTS / DROP ... IF EXISTS). El
-- search_path se fija aqui (cada migracion corre en su propia transaccion,
-- el SET de V22 no persiste).
-- ===========================================================================

SET search_path TO academico_test, public;

-- ---------------------------------------------------------------------------
-- 1. TACTIVIDAD.FK_TASIGNATURA
-- ---------------------------------------------------------------------------
ALTER TABLE TACTIVIDAD
  ADD COLUMN IF NOT EXISTS FK_TASIGNATURA BIGINT;

-- Backfill desde la unidad actual (mientras FK_TUNIDAD siga poblado)
UPDATE TACTIVIDAD a
   SET FK_TASIGNATURA = u.FK_TASIGNATURA
  FROM TUNIDAD u
 WHERE a.FK_TUNIDAD = u.PK_TUNIDAD
   AND a.FK_TASIGNATURA IS NULL;

ALTER TABLE TACTIVIDAD
  ALTER COLUMN FK_TASIGNATURA SET NOT NULL;

ALTER TABLE TACTIVIDAD
  DROP CONSTRAINT IF EXISTS FK_TACTIVIDAD_15_AS;
ALTER TABLE TACTIVIDAD
  ADD CONSTRAINT FK_TACTIVIDAD_15_AS FOREIGN KEY (FK_TASIGNATURA)
    REFERENCES TASIGNATURA (PK_TASIGNATURA) ON DELETE CASCADE;

CREATE INDEX IF NOT EXISTS IDX_TACTIVIDAD_26 ON TACTIVIDAD (FK_TASIGNATURA) ;

COMMENT ON COLUMN TACTIVIDAD.FK_TASIGNATURA IS 'Llave foranea a tabla TASIGNATURA. La actividad se ancla a una asignatura de forma independiente de la unidad.';

-- ---------------------------------------------------------------------------
-- 2. TACTIVIDAD.FK_TUNIDAD ahora es opcional
-- ---------------------------------------------------------------------------
ALTER TABLE TACTIVIDAD
  ALTER COLUMN FK_TUNIDAD DROP NOT NULL;

COMMENT ON COLUMN TACTIVIDAD.FK_TUNIDAD IS 'Llave foranea a tabla TUNIDAD. Opcional: agrupa la actividad dentro de una unidad pedagogica cuando aplica.';

-- ---------------------------------------------------------------------------
-- 3. TUNIDAD deja de depender del periodo de evaluacion
-- ---------------------------------------------------------------------------
ALTER TABLE TUNIDAD DROP CONSTRAINT IF EXISTS UN_TUNIDAD_1;
ALTER TABLE TUNIDAD DROP CONSTRAINT IF EXISTS FK_TUNIDAD_3;
DROP INDEX IF EXISTS IDX_TUNIDAD_3;

ALTER TABLE TUNIDAD DROP COLUMN IF EXISTS FK_TPERIODO_EVALUACION;

ALTER TABLE TUNIDAD
  ADD CONSTRAINT UN_TUNIDAD_1 UNIQUE (NOMBRE, FK_TASIGNATURA, FK_TGRADO)
    DEFERRABLE INITIALLY DEFERRED;

-- ---------------------------------------------------------------------------
-- 4. TUSUARIO.FECHA_NACIMIENTO nullable (alinea con el servidor; V22 NOT NULL)
-- ---------------------------------------------------------------------------
ALTER TABLE TUSUARIO ALTER COLUMN FECHA_NACIMIENTO DROP NOT NULL;
