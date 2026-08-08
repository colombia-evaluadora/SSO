-- =============================================================================
-- V33 — método HTTP en los endpoints por ruta.
--
-- Hasta ahora toda ruta del catálogo era un POST: QueryPathController era un
-- único @PostMapping("/**") y el registro de rutas no tenía noción de verbo.
--
-- El default 'POST' es lo que hace que esto NO sea un cambio con ruptura:
-- toda fila existente conserva exactamente el comportamiento que tiene hoy,
-- sin migrar un solo dato.
-- =============================================================================

ALTER TABLE QUERY
    ADD COLUMN IF NOT EXISTS HTTP_METHOD VARCHAR(10) NOT NULL DEFAULT 'POST';

-- Última línea de defensa. La validación de verdad vive en
-- QueryAdminService (mensaje para un humano en un formulario); esto
-- cubre inserciones que no pasen por ahí.
ALTER TABLE QUERY
    DROP CONSTRAINT IF EXISTS ck_query_http_method;
ALTER TABLE QUERY
    ADD CONSTRAINT ck_query_http_method
    CHECK (HTTP_METHOD IN ('GET', 'POST', 'PUT'));

-- La unicidad pasa a incluir el método: es lo que permite que
-- GET /establecimiento/:ID y PUT /establecimiento/:ID sean dos filas
-- distintas sobre la misma ruta.
DROP INDEX IF EXISTS uq_query_microservice_path;
CREATE UNIQUE INDEX IF NOT EXISTS uq_query_microservice_path_method
    ON QUERY(MICROSERVICE_ID, PATH_TEMPLATE, HTTP_METHOD)
    WHERE PATH_TEMPLATE IS NOT NULL;

COMMENT ON COLUMN QUERY.HTTP_METHOD IS
    'Verbo HTTP que expone esta fila cuando tiene PATH_TEMPLATE: GET, POST o PUT. Default POST = comportamiento previo a V33. DELETE no se admite a proposito; para borrar, publica un procedimiento y llamalo con CALL.';
