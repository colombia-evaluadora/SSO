-- =============================================================================
-- V130.1 - Borra las sobrecargas BIGINT[] de fn_est_listar, fn_sed_listar y sus
-- _paginado, igual que V238 hizo con fn_usu_empleados_listar.
-- V116 paso los filtros a codigos (VARCHAR[]); V130 volvio a crear las cuatro con
-- BIGINT[] como firma nueva, sin reemplazar las de V116. Las que se usan son las
-- VARCHAR[]: /establecimientos/query, /establecimientos/reporte,
-- /establecimientos/sedes/query y /establecimientos/sedes/reporte las castean asi.
-- A las BIGINT[] solo las llama su propio _paginado BIGINT[].
-- Hueco junto a V130: los servidores la aplican con -outOfOrder. Idempotente.
-- =============================================================================

DROP FUNCTION IF EXISTS academico_test.fn_est_listar_paginado(
    BIGINT, CHARACTER VARYING, BIGINT[], BIGINT[], BIGINT[],
    CHARACTER VARYING, BOOLEAN, INTEGER, INTEGER);

DROP FUNCTION IF EXISTS academico_test.fn_est_listar(
    BIGINT, CHARACTER VARYING, BIGINT[], BIGINT[], BIGINT[],
    CHARACTER VARYING, BOOLEAN, INTEGER, INTEGER);

DROP FUNCTION IF EXISTS academico_test.fn_sed_listar_paginado(
    BIGINT, CHARACTER VARYING, BIGINT[], CHARACTER VARYING, BOOLEAN, INTEGER, INTEGER);

DROP FUNCTION IF EXISTS academico_test.fn_sed_listar(
    BIGINT, CHARACTER VARYING, BIGINT[], CHARACTER VARYING, BOOLEAN, INTEGER, INTEGER);
