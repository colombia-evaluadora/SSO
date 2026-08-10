-- =============================================================================
-- V31 — OUT parameter support for stored procedures.
--
-- Until now every PROCEDURE-mode row in the QUERY table
-- relied on PL/pgSQL `RETURN QUERY` to feed rows back through
-- the JDBC ResultSet. PL/pgSQL procedures that use the
-- OUT / INOUT parameter signature (the canonical "write to
-- a status param and short-circuit" pattern) had no path
-- through QueryService — JdbcTemplate.query() never sees
-- OUT values because the result set is what the driver
-- returns, and PL/pgSQL OUT params don't populate the
-- result set.
--
-- This migration adds `OUT_PARAM_NAMES` so the catalog
-- author can declare which `:placeholder` names are OUT.
-- When set, QueryService switches from JdbcTemplate.query
-- to CallableStatement, calling
-- `registerOutParameter(name, Types.OTHER)` for each
-- declared OUT and reading the values back into a
-- separate `outParams` map the controller returns next
-- to the rows.
--
-- Format: comma-separated `:placeholder` names, e.g.
--   'out_status,out_message'
-- Whitespace tolerated; empty string and NULL both mean
-- "no OUT params" (legacy behaviour). The catalog-write
-- side (QueryAdminService) validates each name is present
-- in the SQL and starts with ':'.
--
-- Storage: VARCHAR(500). 500 chars fits ~30 names at typical
-- 16-char-each length, which is plenty for any real
-- procedure signature.
-- =============================================================================

ALTER TABLE QUERY
    ADD COLUMN IF NOT EXISTS OUT_PARAM_NAMES VARCHAR(500);

COMMENT ON COLUMN QUERY.OUT_PARAM_NAMES IS
    'V31 — comma-separated :placeholder names that are OUT params of a PROCEDURE-mode row. When set, QueryService uses CallableStatement + registerOutParameter and returns an outParams map alongside the rows.';
