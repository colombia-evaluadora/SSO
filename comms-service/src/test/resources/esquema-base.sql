-- Minimo de la base real que V560 y comms-service necesitan (en produccion lo
-- crean V1 y V283 de postgres/migrations).
CREATE TABLE IF NOT EXISTS users (
    id_user   BIGSERIAL PRIMARY KEY,
    username  VARCHAR(80) NOT NULL UNIQUE,
    full_name VARCHAR(200),
    email     VARCHAR(200),
    enabled   BOOLEAN NOT NULL DEFAULT TRUE,
    active    BOOLEAN NOT NULL DEFAULT TRUE
);
CREATE TABLE IF NOT EXISTS role (id_role BIGSERIAL PRIMARY KEY, name VARCHAR(60) NOT NULL UNIQUE);
CREATE TABLE IF NOT EXISTS role_users (user_id BIGINT NOT NULL, role_id BIGINT NOT NULL, PRIMARY KEY (user_id, role_id));
CREATE SCHEMA IF NOT EXISTS academico_test;
CREATE OR REPLACE FUNCTION academico_test.fn_cdc_asegurar_auditoria(p_schema TEXT, p_tabla TEXT)
RETURNS BOOLEAN LANGUAGE sql AS 'SELECT FALSE';
CREATE OR REPLACE FUNCTION academico_test.fn_mi_establecimiento_para_auditoria(p BIGINT)
RETURNS TEXT LANGUAGE sql AS 'SELECT ''COLEGIO DEMO''';
