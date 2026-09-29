-- ===========================================================================
-- V502 - Prematricula (1/9): el estado con el que nace.
--
--   ESTADO_PREMATRICULA gana 'PENDIENTE'
--   fn_prematricula_estado(valor) -> PK_LISTA_VALOR
--
--
-- POR QUE
--   TPREMATRICULA.FK_TLV_ESTADO_PREMATRICULA es NOT NULL y el catalogo tenia
--   un unico valor activo: LEGALIZADA. Una prematricula recien creada no esta
--   legalizada -- se legaliza cuando se convierte en matricula, que es
--   justamente lo que registra TMATRICULA.FK_TPREMATRICULA. Sin un estado
--   inicial habria que nacer mintiendo.
--
--   El ciclo queda:
--     PENDIENTE   <- la crea el proceso de prematricula masiva
--     LEGALIZADA  <- al volverse matricula
--
--
-- LA FUNCION
--   Los ids de TLISTA_VALOR no son estables entre entornos (LEGALIZADA es
--   51955 en test y no hay razon para que lo sea en produccion), asi que
--   ninguna funcion de este modulo va a quemar un numero: todas resuelven por
--   CATEGORIA + VALOR con este helper. Es el mismo criterio que usa
--   fn_matricula_cupo_ocupado, que ya comenta por que filtra por VALOR y no
--   por NOMBRE ('Promovido' y 'Promovido Anticipadamente' empiezan igual).
--
-- Idempotente: el NOT EXISTS evita duplicar el valor.
-- ===========================================================================

INSERT INTO academico_test.TLISTA_VALOR (CATEGORIA, NOMBRE, VALOR, CREATED_BY)
SELECT 'ESTADO_PREMATRICULA', 'Pendiente', 'PENDIENTE', 'V502_seed'
 WHERE NOT EXISTS (
       SELECT 1 FROM academico_test.TLISTA_VALOR
        WHERE CATEGORIA = 'ESTADO_PREMATRICULA' AND VALOR = 'PENDIENTE'
   );

CREATE OR REPLACE FUNCTION academico_test.fn_prematricula_estado(
    p_valor  VARCHAR
)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT lv.PK_LISTA_VALOR
      FROM academico_test.TLISTA_VALOR lv
     WHERE lv.CATEGORIA = 'ESTADO_PREMATRICULA'
       AND lv.VALOR     = p_valor
       AND lv.ACTIVE    = TRUE
     LIMIT 1;
$$;

COMMENT ON FUNCTION academico_test.fn_prematricula_estado(VARCHAR)
    IS 'PK_LISTA_VALOR de un estado de ESTADO_PREMATRICULA por su VALOR (''PENDIENTE'', ''LEGALIZADA''). Existe para que ninguna funcion del modulo queme un id: los PK de TLISTA_VALOR no son estables entre entornos. Devuelve NULL si el valor no esta sembrado o esta inactivo, y quien la llama decide si eso es un error.';
