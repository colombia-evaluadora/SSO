-- =============================================================================
-- V501 -- Elimina la firma de 7 argumentos de
-- fn_actividad_materiales_reutilizables_listar (V224).
--
-- V429 le anadio p_fk_tgrupo como 8o argumento con DEFAULT, pero no hizo DROP
-- de la firma vieja: quedaron las dos vivas y toda llamada con 7 argumentos
-- falla con 42725 "is not unique". La rompe GET
-- /planeador/actividades/:ID/materiales-reutilizables, que llama con 7.
-- Sin la vieja, esa llamada resuelve a la de V429 con p_fk_tgrupo NULL.
--
-- Depende de: V429 (la firma que queda). Idempotente: IF EXISTS.
-- =============================================================================

DROP FUNCTION IF EXISTS academico_test.fn_actividad_materiales_reutilizables_listar(
    BIGINT, BIGINT, BIGINT, BIGINT, CHARACTER VARYING, INTEGER, INTEGER);
