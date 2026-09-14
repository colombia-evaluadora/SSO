-- ============================================================================
-- V391 — documenta un gap real encontrado en vivo: `/audits/stats` y
-- `/audits/query` (audit-clickhouse-cval) devolvían 500 "Database error" en
-- PRODUCCION porque `auditoria.tsesion_web` (ClickHouse) le falta la
-- columna `app_name` que V377 agregó -- V377 ya documentaba explícitamente
-- que ese ALTER es MANUAL por ambiente (Flyway solo migra Postgres, nunca
-- toca ClickHouse) y solo se había aplicado en dev/test, nunca en
-- producción.
--
-- Confirmado en vivo (solo lectura, sin tocar producción):
--   - La conexión/contraseña de query-service a ClickHouse está bien
--     (auth OK con las mismas credenciales del contenedor).
--   - Corriendo la query real de /audits/stats a mano contra ClickHouse:
--     `DB::Exception: Unknown expression or function identifier 'app_name'`.
--   - `DESCRIBE TABLE auditoria.tsesion_web` en producción: sin columna
--     `app_name`. En dev/test (172.233.184.248) SÍ existe
--     (`LowCardinality(String) DEFAULT ''`), agregada a mano cuando se hizo
--     V377.
--
-- Esta migración NO ejecuta el ALTER (Flyway no tiene acceso a ClickHouse
-- desde ningún ambiente) -- lo deja documentado acá para que quede en el
-- historial igual que el resto de cambios de esquema, y sirve de
-- verificación cuando alguien la aplique a mano:
--
--   ALTER TABLE auditoria.tsesion_web
--       ADD COLUMN IF NOT EXISTS app_name LowCardinality(String) DEFAULT '';
--
-- `clickhouse-init.sql` (docker/clickhouse/) YA declara `app_name` en el
-- `CREATE TABLE IF NOT EXISTS auditoria.tsesion_web` desde V377 -- eso
-- alcanza para un ambiente NUEVO (la tabla nace con la columna), pero es un
-- no-op sobre una tabla que YA EXISTE sin ella (como producción), de ahí
-- que este ALTER explícito siga siendo necesario ahí.
--
-- Este archivo es puramente documental (no hay nada que migrar en
-- Postgres: la fila de catálogo de /audits/stats y /audits/query ya está
-- correcta desde V383/V384, confirmado en vivo contra producción). Sirve de
-- registro del incidente y de recordatorio para el ALTER pendiente.
-- ============================================================================

DO $$
BEGIN
    RAISE NOTICE 'V391: recordatorio -- aplicar a mano en cada ClickHouse que le falte "app_name" en auditoria.tsesion_web: ALTER TABLE auditoria.tsesion_web ADD COLUMN IF NOT EXISTS app_name LowCardinality(String) DEFAULT '''';';
END $$;
