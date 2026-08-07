-- =============================================================================
-- V28 — execution mode discriminator (SELECT / PROCEDURE / FUNCTION).
--
-- Until now every QUERY row was assumed to be a SELECT (or WITH) that
-- the JDBC layer could execute via JdbcTemplate.query(). This migration
-- adds EXECUTION_MODE so the same catalog row can also describe:
--
--   PROCEDURE  — CALL schema.proc(...)  (PostgreSQL / Oracle / SQL Server)
--                Used for stored procedures that return rows via
--                RETURN QUERY (PL/pgSQL) or that need an IN/OUT
--                signature.
--   FUNCTION   — SELECT * FROM schema.func(...)  (PostgreSQL)
--                Used for scalar / set-returning functions.
--
-- Default = 'SELECT' preserves every existing query's behavior. The
-- first keyword of QUERY.query is checked against the mode at save
-- time by sso-admin's QueryAdminService — saves an admin from
-- discovering the mismatch at runtime when JdbcTemplate refuses
-- to execute a CALL.
--
-- The CHECK constraint rejects unknown values (defense in depth:
-- the Java enum already restricts, but a direct psql edit shouldn't
-- be able to slip a typo past the schema).
-- =============================================================================

ALTER TABLE QUERY
    ADD COLUMN IF NOT EXISTS EXECUTION_MODE VARCHAR(20) NOT NULL DEFAULT 'SELECT';

-- Idempotent CHECK constraint. The DO block makes this safe to re-run
-- against a DB where V28 already applied (CHECK exists) or where
-- someone pre-created it manually.
DO $vm$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'chk_query_execution_mode'
    ) THEN
        ALTER TABLE QUERY
            ADD CONSTRAINT chk_query_execution_mode
            CHECK (EXECUTION_MODE IN ('SELECT', 'PROCEDURE', 'FUNCTION'));
    END IF;
END
$vm$;

COMMENT ON COLUMN QUERY.EXECUTION_MODE IS
    'SELECT = lectura estándar (default); PROCEDURE = CALL schema.proc(...); FUNCTION = SELECT * FROM schema.func(...). El primer keyword de QUERY.query debe coincidir con el modo.';
