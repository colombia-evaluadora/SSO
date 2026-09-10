-- ===========================================================================
-- V292 - cableado endpoint <-> microservicio que solo existia en la base del
--        servidor de test.
--
-- POR QUE ESTA MIGRACION EXISTE
--   public.endpoint_microservice tiene 119 filas en el servidor y las
--   migraciones reproducen 109. Las 10 restantes se ataron a mano por
--   admin-ui. Esta tabla es la que dice, en la consola de administracion, que
--   servicio es el dueno de cada endpoint del catalogo public.endpoint;
--   sin ella un endpoint aparece huerfano en la pantalla de Endpoints.
--
--   No es un gate de autorizacion -- eso es role_endpoint (V15 y sucesivas),
--   que si esta versionado y cuyo unico hueco se cerro en V129.
--
-- NUMERACION
--   Hueco libre V292, verificado contra TODAS las ramas de origin. Va por
--   encima de todas las migraciones que crean los endpoints referenciados:
--     * V15  - el catalogo base.
--     * V56  - /register/funcionario y /register/usuario.
--     * V82  - /microservice/{id}/container/recreate.
--     * V125 - /audit/revert.
--     * V129 - GET / y PATCH /files/** (esta tanda).
--     * V154 - /file-references/{pkTarchivo}.
--   V154 es la que fuerza el numero. Flyway corre con -outOfOrder=true
--   (docker-compose.yml): en entornos ya migrados esto es un no-op.
--
-- IDEMPOTENCIA
--   Guard por NOT EXISTS, no ON CONFLICT: la tabla es una puente sin PK
--   declarada en varios entornos.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- Las 8 ataduras que faltaban.
--
-- Se resuelven por (method, path) y serviceid, nunca por id. Si en un entorno
-- todavia no existe alguna de las dos puntas, esa linea no inserta nada.
-- ---------------------------------------------------------------------------
INSERT INTO endpoint_microservice (endpoint_id, microservice_id)
SELECT e.id_endpoint, m.id_microservice
  FROM (VALUES
        -- auth-center es el dueno real del alta de cuentas (V56).
        ('POST',  '/register/funcionario',                 'auth-center'),
        ('POST',  '/register/usuario',                     'auth-center'),
        -- file-service sirve el comodin de archivos; el PATCH se registro en
        -- V129 junto con su role_endpoint.
        ('PATCH', '/files/**',                             'file-service'),
        -- sso-admin: raiz del gateway, tambien registrada en V129.
        ('GET',   '/',                                     'sso-admin'),
        -- Referencias de archivo (V154).
        ('GET',   '/file-references/{pkTarchivo}',          'sso-admin'),
        ('PUT',   '/file-references/{pkTarchivo}',          'sso-admin'),
        -- Reversion de auditoria (V125).
        ('POST',  '/audit/revert',                         'sso-admin'),
        -- Recreacion de contenedor (V82).
        ('POST',  '/microservice/{id}/container/recreate', 'sso-admin')
       ) AS v(method, path, serviceid)
  JOIN endpoint     e ON e.method = v.method AND e.path = v.path
  JOIN microservice m ON m.serviceid = v.serviceid
 WHERE NOT EXISTS (
       SELECT 1 FROM endpoint_microservice em
        WHERE em.endpoint_id = e.id_endpoint
          AND em.microservice_id = m.id_microservice
 );


-- ===========================================================================
-- DELIBERADAMENTE FUERA: dos ataduras del servidor que parecen un clic errado
--
--   El servidor tiene exactamente dos endpoints atados a MAS de un
--   microservicio, y en ambos casos la segunda atadura contradice al dueno
--   real del codigo:
--
--     POST /app/save    -> auth-center, sso-admin
--         /app/save lo sirve AppController de sso-admin. auth-center no tiene
--         ningun handler para esa ruta. La atadura a sso-admin ya la crean
--         las migraciones; la de auth-center sobra.
--
--     POST /googleLogin -> auth-center, sso-admin
--         El login con Google lo sirve auth-center, y esa atadura ya la crean
--         las migraciones. La de sso-admin sobra.
--
--   No se replican: sembrar una atadura incorrecta en todos los entornos es
--   peor que la diferencia con el servidor, y el efecto de la que falta es
--   solo cosmetico (a que servicio se atribuye el endpoint en la consola).
--   Si resultan ser intencionales, basta descomentar:
--
-- INSERT INTO endpoint_microservice (endpoint_id, microservice_id)
-- SELECT e.id_endpoint, m.id_microservice
--   FROM (VALUES
--         ('POST', '/app/save',    'auth-center'),
--         ('POST', '/googleLogin', 'sso-admin')
--        ) AS v(method, path, serviceid)
--   JOIN endpoint     e ON e.method = v.method AND e.path = v.path
--   JOIN microservice m ON m.serviceid = v.serviceid
--  WHERE NOT EXISTS (
--        SELECT 1 FROM endpoint_microservice em
--         WHERE em.endpoint_id = e.id_endpoint
--           AND em.microservice_id = m.id_microservice
--  );
-- ===========================================================================
