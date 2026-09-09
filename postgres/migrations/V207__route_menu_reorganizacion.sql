-- ===========================================================================
-- V207 - reorganizacion del menu de administracion (public.route): tipos,
--        jerarquia y las rutas que se reemplazaron.
--
-- POR QUE ESTA MIGRACION EXISTE
--   Las rutas de administracion heredadas de V9 se crearon antes de que
--   route.type y route.idparent existieran, asi que las migraciones las dejan
--   planas (type NULL, sin padre). En el servidor de test alguien las
--   reorganizo a mano por admin-ui: agrupo servicios y usuarios bajo
--   contenedores, y reemplazo dos rutas por otras. Nada de eso esta
--   versionado, asi que sobre una base limpia el menu sale plano y con dos
--   entradas muertas.
--
--   OJO con el alcance: NO es cierto que todas las rutas esten sin type. Las
--   de /administracion/*, /cobertura-educativa/*, /establecimiento-educativo/*
--   y /usuarios/equipo ya se crean bien en sus migraciones. Las unicas
--   afectadas son las de /admin/* de la epoca de V9.
--
-- NUMERACION
--   Hueco libre V207, verificado contra TODAS las ramas de origin. Va despues
--   de V205, que crea la ruta /app/activity-log y su bind de app_route: si
--   corriera antes, esta migracion reorganizaria un arbol al que todavia le
--   falta una rama. Flyway corre con -outOfOrder=true (docker-compose.yml).
--
-- COMO SE IDENTIFICA CADA FILA
--   public.route NO tiene restriccion unica sobre `path`, y despues de esta
--   migracion hay dos paths con dos filas cada uno (un contenedor + su hijo
--   con el mismo path, que es como quedo el servidor). Por eso cada fila se
--   localiza por el par (path, name), nunca por path solo ni por id.
--
-- LO QUE NO REPLICA
--   El servidor tiene /app/activity-log DUPLICADO (dos filas identicas, sin
--   restriccion unica que lo impida). Aqui existe una sola: es un defecto de
--   datos del servidor, no algo que valga la pena versionar.
--
-- BORRADOS
--   El paso 4 borra dos rutas. route tiene ON DELETE CASCADE hacia app_route,
--   role_route y hacia si misma por idparent, asi que el borrado arrastra sus
--   binds y sus hijos. Por eso el paso 3 REPARENTA /usuarios/equipo ANTES:
--   si se borrara /admin/users primero, el cascade se llevaria por delante a
--   /usuarios/equipo, que es justamente la ruta que se conserva.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 1. Contenedores nuevos.
--
--    Dos filas que solo existen en el servidor y que son la cabecera de cada
--    grupo del menu. Comparten `path` con su hijo a proposito: es como quedo
--    modelado alli (el contenedor no navega, solo agrupa).
-- ---------------------------------------------------------------------------
INSERT INTO route (name, icon, path, menuorder, type, idparent)
SELECT 'Servicios', '', '/admin/microservices', 4, 'MENU', NULL
 WHERE NOT EXISTS (
       SELECT 1 FROM route WHERE path = '/admin/microservices' AND name = 'Servicios'
 );

INSERT INTO route (name, icon, path, menuorder, type, idparent)
SELECT 'Usuarios', 'Users-Icon', '/usuarios/equipo', 4, 'GROUP', NULL
 WHERE NOT EXISTS (
       SELECT 1 FROM route WHERE path = '/usuarios/equipo' AND name = 'Usuarios'
 );


-- ---------------------------------------------------------------------------
-- 2. Tipo y orden de las rutas /admin/* que quedaron planas desde V9.
--
--    /admin/endpoints, /admin/file-references, /admin/groups y /admin/writes
--    se dejan con type NULL a proposito: asi estan tambien en el servidor.
-- ---------------------------------------------------------------------------
UPDATE route SET type = 'ITEM'
 WHERE type IS NULL
   AND (path, name) IN (
        ('/admin/apps',          'Apps'),
        ('/admin/dynamic-crud',  'Dynamic CRUD'),
        ('/admin/microservices', 'Microservicios'),
        ('/admin/query-catalog', 'Queries Catalog'),
        ('/admin/roles',         'Roles'),
        ('/admin/routes',        'Rutas')
   );

-- Orden dentro del grupo "Servicios" y del grupo "Usuarios".
UPDATE route SET menuorder = 5 WHERE path = '/admin/microservices' AND name = 'Microservicios';
UPDATE route SET menuorder = 6 WHERE path = '/admin/query-catalog' AND name = 'Queries Catalog';

-- En el servidor este icono quedo vacio al mover la entrada bajo Usuarios.
UPDATE route SET icon = '' WHERE path = '/admin/roles' AND name = 'Roles';


-- ---------------------------------------------------------------------------
-- 3. Jerarquia: colgar cada ITEM de su contenedor.
--
--    Se resuelve el padre por (path, name) dentro del propio UPDATE para no
--    depender de ids. Los tres primeros cuelgan del MENU "Servicios"; los dos
--    ultimos, del GROUP "Usuarios".
--
--    El reparentado de /usuarios/equipo es ademas el prerequisito del paso 4:
--    hoy cuelga de /admin/users, que esta a punto de borrarse en cascada.
-- ---------------------------------------------------------------------------
UPDATE route r
   SET idparent = (SELECT p.id_route FROM route p
                    WHERE p.path = '/admin/microservices' AND p.name = 'Servicios')
 WHERE (r.path, r.name) IN (
        ('/admin/dynamic-crud',  'Dynamic CRUD'),
        ('/admin/microservices', 'Microservicios'),
        ('/admin/query-catalog', 'Queries Catalog')
   )
   AND EXISTS (SELECT 1 FROM route p
                WHERE p.path = '/admin/microservices' AND p.name = 'Servicios');

UPDATE route r
   SET idparent = (SELECT p.id_route FROM route p
                    WHERE p.path = '/usuarios/equipo' AND p.name = 'Usuarios')
 WHERE (r.path, r.name) IN (
        ('/admin/roles',      'Roles'),
        ('/usuarios/equipo',  'Equipo')
   )
   AND EXISTS (SELECT 1 FROM route p
                WHERE p.path = '/usuarios/equipo' AND p.name = 'Usuarios');


-- ---------------------------------------------------------------------------
-- 4. Rutas reemplazadas: se borran.
--
--    /admin/users  -> reemplazada por el GROUP "Usuarios" + /usuarios/equipo.
--    /usuarios/roles -> reemplazada por /admin/roles colgado de ese grupo.
--
--    Ninguna de las dos existe ya en el servidor. Se borran explicitamente y
--    en este orden (hija antes que padre) aunque el CASCADE por idparent
--    haria lo mismo: dejarlo escrito evita que un cambio futuro de la FK
--    convierta esto en un borrado silencioso o en un error.
--
--    El CASCADE se lleva sus filas de app_route y role_route. Eso es lo que
--    se busca: son binds de una ruta que ya no existe.
-- ---------------------------------------------------------------------------
DELETE FROM route WHERE path = '/usuarios/roles' AND name = 'Roles';
DELETE FROM route WHERE path = '/admin/users'    AND name = 'Usuarios';


-- ---------------------------------------------------------------------------
-- 5. Binds de los dos contenedores creados en el paso 1.
--
--    Sin estas filas los grupos existen pero no se pintan: role_route decide
--    que roles ven cada entrada del menu y app_route a que app pertenece. Se
--    copian los mismos binds que tienen sus hermanas en el servidor.
--
--    El rol se resuelve por nombre entre ('SSO-ADMIN','ADMIN') porque el
--    catalogo de roles esta partido entre entornos: el servidor usa SSO-ADMIN
--    y una base construida solo por Flyway se queda con ADMIN (ver V36 paso 2
--    y su caveat sobre DataInitializer). Aceptar ambos hace que la migracion
--    funcione en los dos sin decidir esa discusion aqui.
-- ---------------------------------------------------------------------------
INSERT INTO role_route (route_id, role_id)
SELECT rt.id_route, ro.id_role
  FROM route rt
  JOIN role ro ON ro.name IN ('SSO-ADMIN', 'ADMIN')
 WHERE (rt.path, rt.name) IN (
        ('/admin/microservices', 'Servicios'),
        ('/usuarios/equipo',     'Usuarios')
   )
   AND NOT EXISTS (
       SELECT 1 FROM role_route x
        WHERE x.route_id = rt.id_route AND x.role_id = ro.id_role
   );

-- app_route incluye ademas /usuarios/equipo|Equipo: V205 ata a la app las
-- rutas que empiezan por /admin/ (replicando V10) y esta no encaja en ese
-- patron, asi que se ata aqui junto a su contenedor.
INSERT INTO app_route (id_app, id_route)
SELECT a.id_app, rt.id_route
  FROM app a
  JOIN route rt ON (rt.path, rt.name) IN (
        ('/admin/microservices', 'Servicios'),
        ('/usuarios/equipo',     'Usuarios'),
        ('/usuarios/equipo',     'Equipo')
   )
 WHERE a.name = 'SSO-ADMIN'
   AND NOT EXISTS (
       SELECT 1 FROM app_route x
        WHERE x.id_app = a.id_app AND x.id_route = rt.id_route
   );
