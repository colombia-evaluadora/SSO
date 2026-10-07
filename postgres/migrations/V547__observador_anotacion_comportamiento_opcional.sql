-- Observador: la anotacion puede no tener comportamiento calificado.
-- FK_TCOMPORTAMIENTO_CALIFICADO era NOT NULL aunque su FK es ON DELETE SET NULL
-- (borrar el comportamiento fallaba), y las anotaciones academicas o de
-- reconocimiento no tienen comportamiento que enlazar.
-- Depende de: V22 (TOBSERVADOR_ANOTACION).

ALTER TABLE academico_test.TOBSERVADOR_ANOTACION
    ALTER COLUMN FK_TCOMPORTAMIENTO_CALIFICADO DROP NOT NULL;

COMMENT ON COLUMN academico_test.TOBSERVADOR_ANOTACION.FK_TCOMPORTAMIENTO_CALIFICADO IS
    'Comportamiento calificado que origina la anotacion; NULL en anotaciones sin falta (academicas, reconocimientos).';
