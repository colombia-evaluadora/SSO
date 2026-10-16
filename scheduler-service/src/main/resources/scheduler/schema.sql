-- Esquema propio del scheduler-service: solo la tabla de bloqueo de ShedLock.
-- Lo crea el servicio al arrancar (spring.sql.init) y no Flyway, para no
-- acoplarlo a las migraciones de academico_test. Idempotente.
CREATE SCHEMA IF NOT EXISTS scheduler;

CREATE TABLE IF NOT EXISTS scheduler.shedlock (
    name       VARCHAR(64)  NOT NULL PRIMARY KEY,
    lock_until TIMESTAMP    NOT NULL,
    locked_at  TIMESTAMP    NOT NULL,
    locked_by  VARCHAR(255) NOT NULL
);
