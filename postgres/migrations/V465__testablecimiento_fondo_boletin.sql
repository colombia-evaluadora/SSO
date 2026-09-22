-- ===========================================================================
-- V465 - El fondo del boletin, por establecimiento.
--
--   TESTABLECIMIENTO.FK_TARCHIVO_FONDO_BOLETIN -> TARCHIVO
--
-- El boletin se imprime sobre una imagen de pagina completa que cada
-- institucion elige. Es FK y no un VARCHAR con el nombre de un modelo --como
-- TACTA_GRADO.MODELO_FONDO, V22-- porque la imagen vive en S3 y la sirve
-- file-service. NULL = sin fondo: sale sobre blanco. El resto, en el COMMENT.
--
-- Idempotente: ADD COLUMN IF NOT EXISTS y la FK guardada por NOT EXISTS.
-- ===========================================================================

ALTER TABLE academico_test.TESTABLECIMIENTO
    ADD COLUMN IF NOT EXISTS FK_TARCHIVO_FONDO_BOLETIN BIGINT;


-- La FK va aparte porque ADD COLUMN IF NOT EXISTS no admite REFERENCES de
-- forma idempotente: repetirla daria "constraint already exists".
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname = 'fk_testablecimiento_fondo_boletin'
    ) THEN
        ALTER TABLE academico_test.TESTABLECIMIENTO
            ADD CONSTRAINT fk_testablecimiento_fondo_boletin
            FOREIGN KEY (FK_TARCHIVO_FONDO_BOLETIN)
            REFERENCES academico_test.TARCHIVO (PK_TARCHIVO);
    END IF;
END $$;


COMMENT ON COLUMN academico_test.TESTABLECIMIENTO.FK_TARCHIVO_FONDO_BOLETIN
    IS 'Imagen de fondo a pagina completa sobre la que se imprime el boletin de este establecimiento (membrete arriba, pie institucional abajo). Apunta a TARCHIVO porque el binario vive en S3 y lo sirve file-service, que es de donde lo baja reporting-service al generar el PDF -- a diferencia de TACTA_GRADO.MODELO_FONDO, que es un VARCHAR con el nombre de un modelo empaquetado. El tamaño de pagina (Carta u Oficio) queda implicito en la imagen que se suba: no hay una segunda columna para elegirlo, porque un establecimiento imprime sus boletines en un solo formato. NULL significa sin fondo, y entonces el boletin se imprime sobre blanco en vez de fallar. V465.';
