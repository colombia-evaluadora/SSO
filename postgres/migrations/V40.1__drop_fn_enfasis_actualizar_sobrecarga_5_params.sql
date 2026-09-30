-- =============================================================================
-- V40.1 - Borra la sobrecarga de 5 parametros de fn_enfasis_actualizar.
-- V40 creo dos firmas (3 y 5 parametros, casi todos con DEFAULT). La unica que
-- se usa es la de 3: PUT /enfasis/:ID -> fn_enfasis_actualizar(id, nombre, usuario).
-- La de 5 no la llama ninguna fila de public.query, ninguna funcion ni el Java.
-- Hueco junto a V40: los servidores la aplican con -outOfOrder. Idempotente.
-- =============================================================================

DROP FUNCTION IF EXISTS academico_test.fn_enfasis_actualizar(
    BIGINT, CHARACTER VARYING, CHARACTER VARYING, BIGINT, BIGINT);
