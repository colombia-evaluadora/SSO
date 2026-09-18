-- ===========================================================================
-- V62  - academico_test.TARCHIVO.URLS3 pasa a NULLABLE.
--        Sin esto, TODA subida de fichero al esquema academico_test falla
--        con 502 UPLOAD_FAILED.
--
-- POR QUE ESTA MIGRACION EXISTE
--   file-service no escribe la fila de TARCHIVO de una vez. Reserva primero
--   y sube despues, para no dejar huerfanos en S3 si el registro falla:
--
--       ArchivoRepository#reservar   -> INSERT ... (pk, nombre, peso,
--                                        etiqueta, fecha, created_by,
--                                        created_at, active=false)
--       (sube el binario a S3)
--       (UPDATE con la urls3 definitiva y active=true)
--
--   Ese INSERT no menciona URLS3 en absoluto -- no puede, la URL todavia no
--   existe -- de modo que la columna se queda en NULL. Con URLS3 NOT NULL el
--   primer paso revienta antes de intentar nada:
--
--       ERROR: null value in column "urls3" of relation "tarchivo"
--              violates not-null constraint
--       Failing row contains (10, qa.png, null, 68, perfilUsuario, ...)
--
--   file-service traduce ese fallo a 502 {"code":"UPLOAD_FAILED"}, y si hay
--   un proxy delante (Cloudflare) el usuario solo ve "502: Bad gateway".
--
-- YA ESTABA DIAGNOSTICADO, PERO SOLO SE ARREGLO A MEDIAS
--   V148 se topo con esto al crear pigse.TARCHIVO y lo dejo escrito en su
--   propia cabecera:
--
--       "urls3 queda NULLABLE a proposito, a diferencia de
--        academico_test.tarchivo (que la tiene NOT NULL): ArchivoRepository
--        #reservar inserta la fila ANTES de subir a S3, sin valor de urls3"
--
--   Es decir: la incompatibilidad estaba identificada y se resolvio para el
--   esquema nuevo, pero nunca se corrigio el que ya existia. Resultado:
--   pigse.TARCHIVO.URLS3 es nullable desde V148 y academico_test.TARCHIVO
--   siguio siendo NOT NULL. Esta migracion los iguala.
--
-- COMO PASO DESAPERCIBIDO
--   En el servidor de pruebas alguien le hizo el DROP NOT NULL a mano en
--   algun momento, sin migracion, asi que alli las subidas funcionan y el
--   fallo no se reproduce. En produccion, que conserva el esquema del repo,
--   TARCHIVO tenia 0 filas: ninguna subida a academico_test habia
--   funcionado nunca.
--
-- NUMERACION
--   Se ocupa el hueco libre V62 en vez de anadir al final: el numero mas bajo
--   disponible que sea POSTERIOR a V22, donde se crea academico_test.TARCHIVO
--   (V20 y V21 tambien estan libres, pero en una base nueva correrian antes de
--   que la tabla exista). Entra out-of-order en los servidores ya desplegados,
--   que es algo que el pipeline contempla: docker-compose invoca Flyway con
--   -outOfOrder=true y deploy.yml reintenta con repair.
--
-- ALCANCE
--   Relaja una restriccion, no la impone: ninguna fila existente queda
--   invalida y no hace falta backfill. Las filas con URLS3 NULL son
--   transitorias por diseno -- nacen con active=false y el UPDATE posterior
--   las completa; una fila que se quede en NULL indica una subida a S3
--   fallida y es justo lo que conviene poder observar en vez de perder el
--   registro entero.
--
--   Idempotente: solo actua si la columna sigue siendo NOT NULL, de modo que
--   reaplicarla (o aplicarla sobre el servidor de pruebas, ya parcheado a
--   mano) no es un error.
-- ===========================================================================

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
          FROM information_schema.columns
         WHERE table_schema = 'academico_test'
           AND table_name   = 'tarchivo'
           AND column_name  = 'urls3'
           AND is_nullable  = 'NO'
    ) THEN
        ALTER TABLE academico_test.TARCHIVO ALTER COLUMN URLS3 DROP NOT NULL;
        RAISE NOTICE 'V62: academico_test.TARCHIVO.URLS3 pasa a NULLABLE';
    ELSE
        RAISE NOTICE 'V62: academico_test.TARCHIVO.URLS3 ya era NULLABLE, no se toca';
    END IF;
END $$;

COMMENT ON COLUMN academico_test.TARCHIVO.URLS3 IS
    'Ruta del objeto en S3. NULLABLE a proposito (V62): ArchivoRepository#reservar inserta la fila con active=false ANTES de subir el binario, y la completa despues. Una fila con URLS3 NULL y active=false es una subida que no llego a termino.';
