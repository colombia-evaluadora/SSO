-- V1 — mismo ALTER que postgres/migrations/V377 aplicó del lado de
-- Postgres, ahora versionado y auto-aplicado del lado de ClickHouse
-- (ver scripts/clickhouse-migrate.sh). Este es el ALTER que faltó
-- correr a mano en producción (V391 documenta el incidente completo:
-- /audits/stats y /audits/query devolviendo 500 "Database error" en
-- audit-clickhouse-cval).
--
-- Idempotente (IF NOT EXISTS): correrlo en un ambiente donde la columna
-- ya existe (dev/test, agregada a mano) es un no-op seguro.
ALTER TABLE auditoria.tsesion_web
    ADD COLUMN IF NOT EXISTS app_name LowCardinality(String) DEFAULT '';
