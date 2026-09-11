-- ===========================================================================
-- V189 - completa los campos NO sensibles de conexion del microservice
--        'pigse' (dialect, poolsize, instancename), que V148 dejo sin fijar.
--
-- POR QUE ESTA MIGRACION EXISTE
--   V148 crea la fila public.microservice para 'pigse' con
--   dialect/jdbcurl/dbusername/dbpassword/poolsize/instancename en NULL,
--   documentando explicitamente (mismo criterio que V47 para 'eval-col')
--   que jdbcurl/dbusername/dbpassword son credenciales de despliegue y NO
--   deben viajar en una migracion portable. Ese razonamiento sigue vigente
--   y esta migracion lo respeta: NO fija jdbcurl/dbusername/dbpassword.
--
--   Pero dialect/poolsize/instancename NO son secretos -- son el mismo
--   tipo de dato no-sensible que V47 SI fija para 'eval-col' (comparar
--   V47__microservice_eval_col.sql). Faltaban para 'pigse' por una
--   inconsistencia entre ambas migraciones, no por diseno: sin ellos,
--   QueryPathRegistry no puede resolver microserviceId a partir de
--   QUERY_INSTANCE_NAME=pigse ni CatalogRoutesRefresher (api-gateway)
--   publicar /api/pigse/** hasta que alguien complete TODO el formulario
--   de conexion via admin-ui, incluyendo campos que no tenian por que
--   esperar a las credenciales.
--
-- QUE SIGUE FALTANDO A PROPOSITO
--   jdbcurl / dbusername / dbpassword: se completan por admin-ui
--   (Microservicios > pigse > editar) o via UPDATE manual directo en cada
--   servidor, igual que 'eval-col' -- nunca via migracion versionada.
--
-- NUMERACION
--   Hueco libre V189, verificado contra TODAS las ramas de origin. Va por
--   encima de V148 (que crea la fila 'pigse'; el UPDATE necesita que ya
--   exista) y no tiene ninguna migracion posterior que dependa de este
--   valor en particular.
-- ===========================================================================

UPDATE public.microservice
   SET dialect = 'postgres',
       poolsize = 10,
       instancename = 'pigse'
 WHERE serviceid = 'pigse'
   AND dialect IS NULL
   AND poolsize IS NULL
   AND instancename IS NULL;
