-- ===========================================================================
-- V60 — TFUNCIONARIO: DIRECCION + vinculo opcional a TESTABLECIMIENTO.
--
-- Dos columnas nuevas, ambas NULLABLE, sobre academico_test.TFUNCIONARIO
-- (creada en V22, sin estas columnas):
--
--   * DIRECCION VARCHAR(130) — direccion de residencia/contacto del
--     funcionario. Mismo tipo que TESTABLECIMIENTO.DIRECCION (V22) para
--     consistencia con el resto del esquema. Sin FK ni catalogo: es texto
--     libre, igual que TELEFONOS en la misma tabla.
--
--   * FK_ESTABLECIMIENTO BIGINT — vinculo opcional del funcionario a un
--     establecimiento educativo (academico_test.TESTABLECIMIENTO). Nullable
--     porque no todo funcionario tiene (o necesita) esta asociacion directa
--     hoy — TSEDE_USUARIO (V22) ya modela la vinculacion funcional
--     funcionario<->sede<->establecimiento para quienes la tienen; esta
--     columna es un atajo de lectura para casos donde se requiere el
--     establecimiento sin resolver el join via TSEDE_USUARIO.
--     ON DELETE SET NULL: si el establecimiento se hard-elimina, la fila de
--     TFUNCIONARIO no desaparece ni queda huerfana — mismo patron que V59
--     (fk_tplan en TROL_MENU) para FKs nullable agregadas post-hoc sobre
--     tablas ya en produccion.
--
-- Patron: ADD COLUMN IF NOT EXISTS + CREATE INDEX IF NOT EXISTS, igual que
-- V59. Indice parcial (WHERE FK_ESTABLECIMIENTO IS NOT NULL) porque la
-- mayoria de las filas historicas no van a tener este campo poblado.
--
-- Fuera de alcance: esta migracion solo toca el esquema. fn_fun_crear /
-- fn_fun_actualizar (V51) no ganan parametros para estas columnas aqui —
-- eso es un cambio de la capa PL/pgSQL, no del DDL, y se hace en una
-- migracion aparte si/cuando se necesite.
-- ===========================================================================

SET search_path TO academico_test, public;

ALTER TABLE academico_test.TFUNCIONARIO
    ADD COLUMN IF NOT EXISTS DIRECCION VARCHAR(130),
    ADD COLUMN IF NOT EXISTS FK_ESTABLECIMIENTO BIGINT
        REFERENCES academico_test.TESTABLECIMIENTO (PK_ESTABLECIMIENTO)
        ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS IDX_TFUNCIONARIO_FK_ESTABLECIMIENTO
    ON academico_test.TFUNCIONARIO (FK_ESTABLECIMIENTO)
    WHERE FK_ESTABLECIMIENTO IS NOT NULL;

COMMENT ON COLUMN academico_test.TFUNCIONARIO.DIRECCION IS
    'Direccion de residencia/contacto del funcionario. Texto libre, sin catalogo (V60).';
COMMENT ON COLUMN academico_test.TFUNCIONARIO.FK_ESTABLECIMIENTO IS
    'Vinculo opcional a TESTABLECIMIENTO. Nullable; ON DELETE SET NULL (V60).';
