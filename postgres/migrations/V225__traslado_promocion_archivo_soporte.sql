-- ===========================================================================
-- V225 — Archivo de soporte para traslados y promociones + justificacion
--        libre en la promocion.
--
-- Que hace (sobre tablas creadas en V22):
--   1. TTRASLADO_ESTUDIANTE.FK_TARCHIVO  BIGINT NULL
--        -> referencia opcional al documento de soporte del traslado
--           (TARCHIVO, V22 linea ~726). FK + indice + comentario.
--   2. TMATRICULA_PROMOCION.FK_TARCHIVO  BIGINT NULL
--        -> referencia opcional al documento de soporte de la promocion.
--           FK + indice + comentario.
--   3. TMATRICULA_PROMOCION.JUSTIFICACION VARCHAR(4000) NULL
--        -> justificacion pedagogica en texto libre, complementaria a los
--           10 campos estructurados JUSTIFICACION_* ya existentes (V22).
--
-- Columnas nullable, sin default y sin backfill: las filas existentes quedan
-- con FK_TARCHIVO / JUSTIFICACION en NULL (sin soporte / sin nota libre).
--
-- Idempotente:
--   - ADD COLUMN IF NOT EXISTS en las 3 columnas.
--   - FKs creadas dentro de DO ... IF NOT EXISTS (pg_constraint).
--   - CREATE INDEX IF NOT EXISTS.
--   - COMMENT ON COLUMN reejecutable.
-- ===========================================================================

SET search_path TO academico_test, public;

-- ---------------------------------------------------------------------------
-- 1. TTRASLADO_ESTUDIANTE.FK_TARCHIVO
-- ---------------------------------------------------------------------------
ALTER TABLE academico_test.TTRASLADO_ESTUDIANTE
    ADD COLUMN IF NOT EXISTS FK_TARCHIVO BIGINT;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'fk_ttraslado_estudiante_6'
          AND conrelid = 'academico_test.TTRASLADO_ESTUDIANTE'::regclass
    ) THEN
        ALTER TABLE academico_test.TTRASLADO_ESTUDIANTE
            ADD CONSTRAINT FK_TTRASLADO_ESTUDIANTE_6
            FOREIGN KEY (FK_TARCHIVO) REFERENCES academico_test.TARCHIVO (PK_TARCHIVO)
            ON DELETE SET NULL;
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS IDX_TTRASLADO_ESTUDIANTE_10
    ON academico_test.TTRASLADO_ESTUDIANTE (FK_TARCHIVO) ;

COMMENT ON COLUMN academico_test.TTRASLADO_ESTUDIANTE.FK_TARCHIVO IS
    'Llave foranea opcional a tabla TARCHIVO (documento de soporte del traslado). NULL = sin soporte adjunto.';

-- ---------------------------------------------------------------------------
-- 2. TMATRICULA_PROMOCION.FK_TARCHIVO
-- ---------------------------------------------------------------------------
ALTER TABLE academico_test.TMATRICULA_PROMOCION
    ADD COLUMN IF NOT EXISTS FK_TARCHIVO BIGINT;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'fk_tmatricula_promocion_4'
          AND conrelid = 'academico_test.TMATRICULA_PROMOCION'::regclass
    ) THEN
        ALTER TABLE academico_test.TMATRICULA_PROMOCION
            ADD CONSTRAINT FK_TMATRICULA_PROMOCION_4
            FOREIGN KEY (FK_TARCHIVO) REFERENCES academico_test.TARCHIVO (PK_TARCHIVO)
            ON DELETE SET NULL;
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS IDX_TMATRICULA_PROMOCION_4
    ON academico_test.TMATRICULA_PROMOCION (FK_TARCHIVO) ;

COMMENT ON COLUMN academico_test.TMATRICULA_PROMOCION.FK_TARCHIVO IS
    'Llave foranea opcional a tabla TARCHIVO (documento de soporte de la promocion). NULL = sin soporte adjunto.';

-- ---------------------------------------------------------------------------
-- 3. TMATRICULA_PROMOCION.JUSTIFICACION (texto libre)
-- ---------------------------------------------------------------------------
ALTER TABLE academico_test.TMATRICULA_PROMOCION
    ADD COLUMN IF NOT EXISTS JUSTIFICACION VARCHAR(4000);

COMMENT ON COLUMN academico_test.TMATRICULA_PROMOCION.JUSTIFICACION IS
    'Justificacion pedagogica en texto libre de la promocion, complementaria a los campos estructurados JUSTIFICACION_* (V22). NULL permitido.';
