-- =============================================================================
-- V110 — cache opt-in por fila de QUERY.
--
-- query-service ahora puede servir GET /** (rutas por PATH_TEMPLATE) desde
-- Redis en vez de golpear la base cada vez. Como esas rutas ejecutan SQL
-- arbitrario del catálogo, con parámetros de :CONTEXT.* atados al llamante,
-- cachear TODA fila por defecto arriesgaría devolver datos de un usuario a
-- otro o servir resultados desactualizados de una escritura concurrente.
--
-- Por eso el cache es opt-in: el autor de cada fila decide explícitamente
-- si SU query es segura de reutilizar durante una ventana, marcando CACHEABLE.
-- CACHE_TTL_SECONDS controla esa ventana por fila — filas distintas toleran
-- staleness muy distinta (un catálogo de valores fijos puede vivir minutos;
-- un conteo casi en vivo, unos pocos segundos).
--
-- El default (CACHEABLE=false) es lo que hace que V110 NO sea un cambio con
-- ruptura: toda fila existente conserva exactamente el comportamiento que
-- tiene hoy — siempre golpea la base — sin migrar un solo dato.
-- =============================================================================

ALTER TABLE QUERY
    ADD COLUMN IF NOT EXISTS CACHEABLE BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE QUERY
    ADD COLUMN IF NOT EXISTS CACHE_TTL_SECONDS INTEGER NOT NULL DEFAULT 60;

-- Última línea de defensa. La validación de verdad vive en
-- QueryAdminService (mensaje para un humano en un formulario); esto
-- cubre inserciones que no pasen por ahí.
ALTER TABLE QUERY
    DROP CONSTRAINT IF EXISTS ck_query_cache_ttl_positive;
ALTER TABLE QUERY
    ADD CONSTRAINT ck_query_cache_ttl_positive
    CHECK (CACHE_TTL_SECONDS > 0);

COMMENT ON COLUMN QUERY.CACHEABLE IS
    'Opt-in: si es true, query-service puede servir el resultado de esta fila desde Redis (solo aplica a filas GET con PATH_TEMPLATE) durante CACHE_TTL_SECONDS. Default false = comportamiento previo a V110, siempre golpea la base. La clave de cache incluye el llamante (CONTEXT), asi que dos usuarios nunca comparten una entrada.';

COMMENT ON COLUMN QUERY.CACHE_TTL_SECONDS IS
    'Ventana de staleness tolerada cuando CACHEABLE=true. Ignorado si CACHEABLE=false. Default 60s.';
