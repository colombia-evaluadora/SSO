-- ===========================================================================
-- V47 - registro del microservicio 'eval-col' (query-service del modulo
--       academico) en public.microservice.
--
-- POR QUE ESTA MIGRACION EXISTE
--   'eval-col' es el query-service que sirve TODO el modulo academico
--   (areas, grados, periodos, establecimientos, sedes, funcionarios,
--   planeador, ...), pero su fila en public.microservice nunca estuvo en
--   Flyway: llego al servidor de test por el dump base. Comparar con los
--   dos microservicios QUERY que si estan versionados -- 'audit-clickhouse'
--   (V84) y 'pigse' (V148) -- deja el hueco a la vista.
--
--   El efecto sobre una base limpia es silencioso y total: cada migracion
--   que registra endpoints hace
--       ... FROM public.microservice m WHERE m.serviceid = 'eval-col'
--   (V135, V149, V167, V168, V185, V198, V199, V245-V255, V278-V282, y las
--   V75..V127 que acompanan a esta), asi que sin esta fila el SELECT origen
--   no devuelve nada y NINGUNO de esos INSERT inserta nada -- sin error.
--
-- NUMERACION
--   Hueco libre V47, verificado contra TODAS las ramas de origin. Va por
--   encima de V4 (que anade a microservice las columnas kind/dialect/
--   jdbcurl/dbusername/dbpassword/instancename) y por debajo de la primera
--   migracion que registra endpoints de eval-col, que es lo unico que esta
--   fila necesita preceder. Flyway corre con -outOfOrder=true
--   (docker-compose.yml): en los entornos ya migrados esta migracion se
--   aplica sin conflicto y es un no-op por el guard NOT EXISTS.
--
-- CREDENCIALES
--   jdbcurl / dbusername / dbpassword se dejan a proposito en NULL: son
--   datos de conexion propios de cada despliegue, no algo que una migracion
--   portable deba fijar, y no deben viajar en el repositorio. Mismo criterio
--   que V148 para 'pigse'. Se completan por admin-ui (Microservicios >
--   eval-col > editar), que es donde MicroserviceService valida los campos y
--   prueba la conexion. Los valores no sensibles (kind, dialect, requesturi,
--   instancename, poolsize) si se fijan aqui porque son los que usan
--   QueryPathRegistry para resolver el microserviceId a partir de
--   QUERY_INSTANCE_NAME=eval-col, y CatalogRoutesRefresher (api-gateway)
--   para publicar la ruta dinamica /api/eval-col/**.
-- ===========================================================================

INSERT INTO public.microservice
    (serviceid, description, requesturi, kind, dialect, instancename, poolsize)
SELECT
    'eval-col',
    'servicio de consumo de colombia evaluadora v4',
    '/api/eval-col/**',
    'QUERY',
    'postgres',
    'eval-col',
    10
 WHERE NOT EXISTS (
     SELECT 1 FROM public.microservice WHERE serviceid = 'eval-col'
 );
