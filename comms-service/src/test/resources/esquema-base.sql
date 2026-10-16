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
-- Lo minimo del esquema academico que usa la busqueda de personas.
CREATE TABLE IF NOT EXISTS academico_test.tusuario (
    pk_tusuario BIGSERIAL PRIMARY KEY, cuenta VARCHAR(150) NOT NULL UNIQUE, identificacion VARCHAR(30),
    primer_nombre VARCHAR(40) NOT NULL, segundo_nombre VARCHAR(40), primer_apellido VARCHAR(40) NOT NULL,
    segundo_apellido VARCHAR(40), correo_electronico VARCHAR(120), active BOOLEAN NOT NULL DEFAULT TRUE);
CREATE TABLE IF NOT EXISTS academico_test.tsede (
    pk_tsede BIGSERIAL PRIMARY KEY, fk_testablecimiento BIGINT NOT NULL, active BOOLEAN NOT NULL DEFAULT TRUE);
CREATE TABLE IF NOT EXISTS academico_test.tsede_usuario (
    fk_tsede BIGINT NOT NULL, fk_tusuario BIGINT NOT NULL, active BOOLEAN NOT NULL DEFAULT TRUE);
CREATE TABLE IF NOT EXISTS academico_test.tgrupo (
    pk_tgrupo BIGSERIAL PRIMARY KEY, fk_testablecimiento BIGINT, active BOOLEAN NOT NULL DEFAULT TRUE);
CREATE TABLE IF NOT EXISTS academico_test.testudiante (pk_testudiante BIGSERIAL PRIMARY KEY, fk_tusuario BIGINT);
CREATE TABLE IF NOT EXISTS academico_test.tpadre (pk_tpadre BIGSERIAL PRIMARY KEY, fk_tusuario BIGINT);
CREATE TABLE IF NOT EXISTS academico_test.tmatricula (
    fk_testudiante BIGINT NOT NULL, fk_tgrupo BIGINT NOT NULL, fk_tpadre BIGINT,
    active BOOLEAN NOT NULL DEFAULT TRUE);
CREATE OR REPLACE FUNCTION academico_test.fn_grupo_establecimiento(p BIGINT)
RETURNS BIGINT LANGUAGE sql STABLE AS 'SELECT fk_testablecimiento FROM academico_test.tgrupo WHERE pk_tgrupo = p';
CREATE OR REPLACE FUNCTION public.fn_get_academico_usuario_id(p BIGINT)
RETURNS BIGINT LANGUAGE sql STABLE AS
'SELECT tu.pk_tusuario FROM academico_test.tusuario tu JOIN users u ON u.email = tu.cuenta WHERE u.id_user = p LIMIT 1';
-- Adjuntos (file-service): TARCHIVO y su ubicacion (V1, V35).
CREATE TABLE IF NOT EXISTS academico_test.tarchivo (
    pk_tarchivo BIGINT PRIMARY KEY,
    nombre      VARCHAR(255),
    peso        BIGINT,
    created_by  VARCHAR(200),
    active      BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE TABLE IF NOT EXISTS public.file_reference_location (
    pk_tarchivo BIGINT PRIMARY KEY,
    schema_name TEXT NOT NULL,
    table_name  TEXT NOT NULL,
    urls3       TEXT
);
