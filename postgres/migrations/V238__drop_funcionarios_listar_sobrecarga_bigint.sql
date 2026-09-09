-- =============================================================================
-- V238 -- Elimina las sobrecargas bigint[] de fn_usu_empleados_listar y
-- fn_usu_empleados_listar_paginado, que son codigo muerto.
--
-- -----------------------------------------------------------------------------
-- Por que hay dos de cada una
-- -----------------------------------------------------------------------------
-- V51 creo las dos funciones recibiendo los filtros de rol y de jornada como
-- BIGINT[] (PKs). V116 (filtros por codigo) cambio el contrato para que el
-- front mandara CODIGOS en vez de PKs, y al cambiar el tipo del parametro de
-- BIGINT[] a VARCHAR[] Postgres no reemplazo la funcion: creo una SEGUNDA con
-- distinta firma. Desde entonces convivieron dos implementaciones de cada una.
--
-- La viva es la VARCHAR[], y es la unica que alcanzan los dos endpoints del
-- catalogo, porque los dos castean el filtro explicitamente:
--
--   POST /establecimientos/funcionarios/query     (listado de la interfaz)
--     -> fn_usu_empleados_listar_paginado(..., CAST(:BODY.FILTERS.ROLES AS VARCHAR[]), ...)
--        que a su vez delega en fn_usu_empleados_contar + fn_usu_empleados_listar
--
--   POST /establecimientos/funcionarios/reporte   (exportar)
--     -> fn_usu_empleados_listar(..., CAST(:BODY.FILTERS.ROLES AS VARCHAR[]), ...)
--
-- Nada mas en la base llama a estas funciones: el unico llamador interno es el
-- propio wrapper _listar_paginado, y de fn_usu_empleados_contar no hay ni
-- sobrecarga ni otro llamador.
--
-- -----------------------------------------------------------------------------
-- Por que se eliminan en vez de actualizarlas
-- -----------------------------------------------------------------------------
-- Al no estar en el camino de nadie, la copia BIGINT[] fue quedandose atras.
-- Medido: la VARCHAR[] tiene 10 filtros de rol (FK_TROL >= 7 / >= 9, excluyendo
-- 15 y 16) mas una capa que acota sedes_agg y estados_agg a las sedes del
-- solicitante; la BIGINT[] tiene 1. Esa deriva es visible: llamada a mano, la
-- BIGINT[] devolvia a un rector 12 funcionarios donde la VARCHAR[] devuelve 6,
-- y los 6 de diferencia eran todos rol 1 -- cuentas internas de soporte de la
-- plataforma, que no deben aparecer en la lista de empleados de un
-- establecimiento. Por la API eso nunca se vio, porque la API no llega ahi.
--
-- Mantener dos copias divergentes de la misma logica de negocio no aporta, y
-- ademas la duplicidad es una trampa activa: llamar a fn_usu_empleados_listar
-- sin castear los arrays falla con 42725 "function is not unique" en vez de
-- ejecutar. Con una sola firma, esa llamada resuelve sola.
--
-- El gate dinamico de permisos (V237) se aplico sobre la VARCHAR[], que es la
-- que queda. Aqui no se toca ningun permiso.
--
-- Idempotente: IF EXISTS.
-- =============================================================================

DROP FUNCTION IF EXISTS academico_test.fn_usu_empleados_listar_paginado(
    BIGINT, CHARACTER VARYING, BIGINT[], BIGINT[], CHARACTER VARYING[],
    BIGINT, CHARACTER VARYING, BOOLEAN, INTEGER, INTEGER);

DROP FUNCTION IF EXISTS academico_test.fn_usu_empleados_listar(
    BIGINT, CHARACTER VARYING, BIGINT[], BIGINT[], CHARACTER VARYING[],
    BIGINT, CHARACTER VARYING, BOOLEAN, INTEGER, INTEGER);
