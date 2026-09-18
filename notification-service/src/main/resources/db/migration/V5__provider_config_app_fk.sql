-- ---------------------------------------------------------------
-- FK real de provider_config.app_name hacia app.name (sso-admin).
--
-- provider_config y app viven en el MISMO Postgres y el MISMO
-- esquema public en cada ambiente real (dev/test/main) -- por eso
-- la FK es posible sin tocar red ni cruzar servicios: app.name ya
-- tiene un UNIQUE constraint (app_name_key) para apoyarla, así que
-- no hace falta agregar una columna app_id nueva.
--
-- Va en un bloque condicional (DO $$ ... IF EXISTS ... END $$) por
-- una razón muy concreta: la suite de integración de este MISMO
-- servicio (AbstractIntegrationTest) levanta un Postgres EFÍMERO
-- con Testcontainers que solo corre las migraciones de
-- notification-service -- ahí "app" no existe. Sin la condicional,
-- esa suite rompe con "relation app does not exist" en cada corrida
-- de CI. En un ambiente real (dev/test/main), donde sso-admin ya
-- creó "app" antes de que este servicio arrancara, la FK SÍ se crea
-- y SÍ se hace cumplir -- un app_name con un valor que no exista en
-- app.name queda rechazado por el motor, no solo por un WARN en el
-- log.
--
-- Riesgo conocido y aceptado: si algún día "notification-service"
-- arranca por primera vez en un Postgres donde sso-admin todavía no
-- corrió su propia migración/JPA (o donde "app" existe pero sigue
-- vacía), esta migración no agrega la FK esa vez -- se queda como
-- estaba (sin exigirla), no falla. No hay forma de esperar a que
-- otro servicio termine su propio arranque desde una migración SQL.
--
-- ON UPDATE CASCADE: si alguien renombra una app en sso-admin,
-- provider_config.app_name se actualiza solo -- no hay que
-- acordarse de tocar esta tabla aparte.
-- ON DELETE SET NULL: si alguien borra una app, la fila de
-- provider_config no se borra con ella -- vuelve a "aplica para
-- cualquier app" en vez de desaparecer una cuenta de correo entera
-- por una limpieza en una tabla de otro servicio.
-- ---------------------------------------------------------------
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
         WHERE table_schema = 'public' AND table_name = 'app'
    ) AND NOT EXISTS (
        SELECT 1 FROM information_schema.table_constraints
         WHERE constraint_schema = 'public'
           AND table_name = 'provider_config'
           AND constraint_name = 'fk_provider_config_app_name'
    ) THEN
        ALTER TABLE provider_config
            ADD CONSTRAINT fk_provider_config_app_name
            FOREIGN KEY (app_name) REFERENCES app(name)
            ON UPDATE CASCADE ON DELETE SET NULL;
    END IF;
END $$;
