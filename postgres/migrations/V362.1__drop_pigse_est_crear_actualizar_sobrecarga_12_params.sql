-- =============================================================================
-- V362.1 - Borra las firmas de 12 parametros de pigse.fn_est_crear y
-- pigse.fn_est_actualizar, que V257 creo y V362 dejo obsoletas al anadir rector y
-- secretaria (14 parametros) como firma nueva sin borrar la vieja.
-- Los endpoints POST y PUT /establecimientos de PIGSE pasan los 14. Con las dos
-- vivas y casi todo con DEFAULT, una llamada corta falla con 42725 (ambigua).
-- Hueco junto a V362: los servidores la aplican con -outOfOrder. Idempotente.
-- =============================================================================

DROP FUNCTION IF EXISTS pigse.fn_est_crear(
    BIGINT, BIGINT, CHARACTER VARYING, CHARACTER VARYING, BIGINT, CHARACTER VARYING,
    BIGINT, CHARACTER VARYING, CHARACTER VARYING, CHARACTER VARYING, BIGINT, BIGINT);

DROP FUNCTION IF EXISTS pigse.fn_est_actualizar(
    BIGINT, BIGINT, CHARACTER VARYING, CHARACTER VARYING, CHARACTER VARYING, BIGINT,
    BIGINT, CHARACTER VARYING, CHARACTER VARYING, CHARACTER VARYING, BIGINT, BIGINT);
