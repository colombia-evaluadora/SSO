-- V19 — ensancha users.password para alojar hashes Argon2id.
--
-- La columna se dimensionó (68) para un hash BCrypt de 60 caracteres.
-- Un hash Argon2id codificado ocupa ~95-100:
--
--   $argon2id$v=19$m=16384,t=2,p=1$<salt b64>$<hash b64>
--
-- Con VARCHAR(68) el INSERT falla en Postgres con "value too long",
-- así que la columna tiene que crecer ANTES de que se despliegue el
-- código que rehashea. 255 deja margen para subir los parámetros de
-- coste más adelante sin otra migración.
--
-- No se tocan los hashes existentes: DelegatingPasswordEncoder los
-- reconoce por su prefijo y se reescriben a Argon2id en el siguiente
-- login correcto de cada usuario (ver PasswordUpgradeService en
-- auth-center). Los hashes BCrypt antiguos no llevan prefijo
-- {bcrypt}; el UPDATE de abajo se lo pone para que el encoder
-- delegante sepa a quién enrutarlos.

ALTER TABLE users
    ALTER COLUMN password TYPE VARCHAR(255);

-- Los hashes previos a esta migración se guardaron con
-- BCryptPasswordEncoder directo, sin identificador de algoritmo.
-- DelegatingPasswordEncoder exige el prefijo {id} para saber qué
-- delegado usar; sin esto todos los logins existentes fallarían con
-- "There is no PasswordEncoder mapped for the id null".
--
-- El patrón cubre las tres variantes del formato BCrypt ($2a$, $2b$,
-- $2y$) y evita reetiquetar filas ya migradas o con password NULL
-- (usuarios en PENDING_ACTIVATION, que aún no han fijado contraseña).
UPDATE users
   SET password = '{bcrypt}' || password
 WHERE password IS NOT NULL
   AND password LIKE '$2%';
