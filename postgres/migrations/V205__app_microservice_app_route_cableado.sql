-- ===========================================================================
-- V205 - cableado app <-> microservicio y app <-> ruta que solo existia en la
--        base del servidor de test.
--
-- POR QUE ESTA MIGRACION EXISTE
--   public.app_microservice tiene 11 filas en el servidor y las migraciones
--   solo crean 1 (V148, el bind de 'pigse' a la app PIGSE). Las otras 10 se
--   hicieron a mano por admin-ui (pestana "Microservices" del formulario de
--   App). public.app_route tenia el mismo problema, aunque ahi el hueco real
--   es una sola fila.
--
--   No es cosmetico: QueryAdminService.rolesPermitidosPara consulta
--   app_microservice via AppRepository.findByMicroserviceId para filtrar los
--   roles por app. Sobre una base limpia esa tabla queda casi vacia y el
--   filtro se vuelve permisivo -- exactamente lo que V148 ya advertia para
--   'pigse' ("sin esto ... el filtro de roles por app seguiria permisivo").
--   Lo que V148 arreglo para una app, esta migracion lo cierra para las tres.
--
-- NUMERACION
--   Hueco libre V205, verificado contra TODAS las ramas de origin. Tiene que
--   ir por encima de:
--     * V6/V10/V14  - crean las apps y sus columnas.
--     * V16/V35/V68 - microservicios sso-admin, auth-center, file-service,
--                     reporting-service.
--     * V47         - microservicio 'eval-col' (esta tanda).
--     * V148        - microservicio 'pigse' y la app PIGSE.
--   V148 es la que fuerza el numero alto: dos de las filas de aqui apuntan a
--   la app PIGSE, que no existe antes. Flyway corre con -outOfOrder=true
--   (docker-compose.yml), asi que los entornos ya migrados la aplican sin
--   conflicto y todo queda en no-op por los guards.
--
-- IDEMPOTENCIA
--   app_microservice y app_route son tablas puente sin PK declarada en varios
--   entornos, asi que NO se puede usar ON CONFLICT: el guard es NOT EXISTS.
--   Eso ademas evita reintroducir los duplicados que hoy tiene el servidor
--   (ver la nota de /app/activity-log mas abajo).
--
-- LO QUE NO HACE
--   No borra el cableado sobrante. En el servidor hay filas duplicadas en
--   app_route (/app/activity-log, /admin/microservices, /usuarios/equipo) y
--   dos rutas que las migraciones crean pero que alli ya no existen
--   (/admin/users, /usuarios/roles, reemplazadas por /usuarios/equipo).
--   Limpiar eso es una decision de datos, no de esquema, y se deja fuera a
--   proposito.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 1. app_microservice - las 10 filas que faltaban.
--
--    Se resuelve por nombre de app y serviceid, nunca por id: los ids son de
--    secuencia y no coinciden entre entornos. Si en algun entorno todavia no
--    existe una de las dos puntas, el SELECT no devuelve filas y esa linea
--    simplemente no se inserta.
-- ---------------------------------------------------------------------------
INSERT INTO app_microservice (id_app, id_microservice)
SELECT a.id_app, m.id_microservice
  FROM (VALUES
        -- La app del modulo academico consume su propio query-service mas
        -- la infraestructura compartida (login, archivos, reportes).
        ('COLOMBIA-EVALUADORA', 'eval-col'),
        ('COLOMBIA-EVALUADORA', 'auth-center'),
        ('COLOMBIA-EVALUADORA', 'file-service'),
        ('COLOMBIA-EVALUADORA', 'reporting-service'),
        -- PIGSE: V148 ya ato su propio query-service ('pigse'); faltaba la
        -- infraestructura compartida.
        ('PIGSE',               'auth-center'),
        ('PIGSE',               'file-service'),
        -- La consola de administracion.
        ('SSO-ADMIN',           'sso-admin'),
        ('SSO-ADMIN',           'auth-center'),
        ('SSO-ADMIN',           'file-service'),
        ('SSO-ADMIN',           'eval-col')
       ) AS v(app_name, serviceid)
  JOIN app          a ON a.name      = v.app_name
  JOIN microservice m ON m.serviceid = v.serviceid
 WHERE NOT EXISTS (
       SELECT 1 FROM app_microservice am
        WHERE am.id_app = a.id_app AND am.id_microservice = m.id_microservice
 );


-- ---------------------------------------------------------------------------
-- 2. route /app/activity-log - prerequisito de la fila de app_route.
--
--    La ruta existe en el servidor y en ninguna migracion. Se crea aqui
--    porque sin ella el bind del punto 3 no tendria a que apuntar.
--
--    OJO: en el servidor esta DUPLICADA (dos filas identicas, sin restriccion
--    unica que lo impida). Aqui se crea UNA sola; el guard NOT EXISTS por
--    `path` evita crear una segunda en entornos que ya la tengan, y no toca
--    las duplicadas existentes.
--
--    El resto de columnas (icon/menuorder/type) se copian del servidor.
--    `type` merece una nota: las migraciones crean todas las demas rutas con
--    type NULL y en el servidor estan en ITEM/MENU/GROUP, puestos a mano.
--    Ese hueco general de route.type queda FUERA de esta migracion.
-- ---------------------------------------------------------------------------
INSERT INTO route (name, icon, path, menuorder, type, idparent)
SELECT 'Actividad', 'book', '/app/activity-log', 0, 'ITEM', NULL
 WHERE NOT EXISTS (
       SELECT 1 FROM route WHERE path = '/app/activity-log'
 );


-- ---------------------------------------------------------------------------
-- 3. app_route - la unica fila que faltaba.
--
--    El resto del contenido de app_route ya lo producen las migraciones; el
--    diff aparente era mas grande solo por las filas duplicadas del servidor.
-- ---------------------------------------------------------------------------
INSERT INTO app_route (id_app, id_route)
SELECT a.id_app, r.id_route
  FROM app a
  JOIN route r ON r.path = '/app/activity-log'
 WHERE a.name = 'COLOMBIA-EVALUADORA'
   AND NOT EXISTS (
       SELECT 1 FROM app_route ar
        WHERE ar.id_app = a.id_app AND ar.id_route = r.id_route
   );
