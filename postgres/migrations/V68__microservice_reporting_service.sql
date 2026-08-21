-- =============================================================================
-- V68 — registra reporting-service en el catalogo de microservicios.
--
-- La fila NO crea la ruta del gateway. CatalogRoutesRefresher solo genera
-- rutas dinamicas para las filas kind = 'QUERY' (las instancias de
-- query-service provisionadas); las kind = 'REST' se rutean estaticamente en
-- api-gateway/src/main/resources/application.yml, donde el StripPrefix va
-- afinado a mano.
--
-- Y tiene que ser asi, no al reves: el stripPrefix del feed dinamico se deduce
-- contando segmentos del requestUri (InternalGatewayController.stripPrefixFrom),
-- o sea que '/api/reportes/**' daria StripPrefix=2 y el gateway reenviaria
-- '/{clave}' — sin el '/reportes' que espera el controlador. La ruta estatica
-- usa StripPrefix=1, que deja '/reportes/{clave}'. Es exactamente el mismo
-- motivo por el que file-service y auth-center viven en el YAML.
--
-- Entonces, ¿para que la fila? Para que el servicio exista en el catalogo que
-- consumen el agregador de OpenAPI del gateway (que antepone el requestUri a
-- las rutas del doc unificado de /api/docs) y la UI de administracion. Sin
-- ella el reporting-service funciona, pero es invisible: no aparece en la
-- documentacion ni en las pantallas que listan microservicios.
--
-- id_microservice queda al DEFAULT de la secuencia. Ojo: la secuencia de esta
-- tabla puede estar atras de los ids sembrados a mano, igual que le pasaba a
-- public.query (ver V67); por eso se reajusta antes de insertar.
--
-- Idempotente: no inserta si ya existe una fila con ese serviceid (que ademas
-- tiene UNIQUE).
-- =============================================================================

SELECT setval(
    pg_get_serial_sequence('public.microservice', 'id_microservice'),
    (SELECT COALESCE(MAX(id_microservice), 1) FROM public.microservice),
    TRUE
);

INSERT INTO public.microservice (serviceid, description, requesturi, kind)
SELECT 'reporting-service',
       'Servicio de reportes: corre las mismas funciones PL/pgSQL de los listados sin paginar y devuelve PDF o Excel',
       '/api/reportes/**',
       'REST'
 WHERE NOT EXISTS (
     SELECT 1 FROM public.microservice WHERE serviceid = 'reporting-service'
 );
