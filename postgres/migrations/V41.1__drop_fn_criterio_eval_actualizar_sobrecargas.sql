-- =============================================================================
-- V41.1 - Borra las sobrecargas de 12 y 15 parametros de fn_criterio_eval_actualizar.
-- V41 creo tres firmas; la unica que se usa es la de 14 (con MODIF_FINAL_PERACA y
-- ROUNDING_MODE BIGINT), la de PUT /periodos/:ID/criterio-evaluacion. Las otras
-- dos no las llama nada y, al tener casi todo con DEFAULT, vuelven ambigua (42725)
-- cualquier llamada corta. V41 no se edita: su DO de backfill recalcularia datos.
-- Hueco junto a V41: los servidores la aplican con -outOfOrder. Idempotente.
-- =============================================================================

DROP FUNCTION IF EXISTS academico_test.fn_criterio_eval_actualizar(
    BIGINT, BIGINT, BIGINT, BOOLEAN, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT,
    NUMERIC, NUMERIC, BIGINT);

DROP FUNCTION IF EXISTS academico_test.fn_criterio_eval_actualizar(
    BIGINT, BIGINT, BIGINT, BOOLEAN, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT,
    NUMERIC, NUMERIC, BIGINT, NUMERIC, BIGINT, NUMERIC);
