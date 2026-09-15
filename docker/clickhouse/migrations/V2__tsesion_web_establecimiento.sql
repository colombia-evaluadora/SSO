-- V2 — contraparte ClickHouse de postgres/migrations/V400: agrega
-- `establecimiento` a auditoria.tsesion_web (mismo patrón que V1 con
-- app_name). Poblada por ClickHouseSessionMirrorStage a partir de
-- academico_test.tsesion_web.establecimiento (auth-center la escribe
-- en el login, mismo valor que el claim `est` del JWT).
--
-- Idempotente (IF NOT EXISTS): correrlo en un ambiente donde la columna
-- ya existe es un no-op seguro.
ALTER TABLE auditoria.tsesion_web
    ADD COLUMN IF NOT EXISTS establecimiento LowCardinality(String) DEFAULT '';
