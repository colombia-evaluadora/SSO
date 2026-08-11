-- =============================================================================
-- V49 — Parameter type metadata for the QUERY table.
--
-- Purpose.
--   Allow the author of a query to declare the JDBC/PG type of each
--   caller-controlled placeholder (:PARAM.*, :BODY.*) so the query-service
--   can bind with an explicit sqlType instead of relying on Spring's
--   value-based auto-derivation. The metadata is required at write time
--   (strict) — every detected placeholder in the SQL must have an entry
--   here.
--
-- Shape.
--   { "<PLACEHOLDER>": "<SQL_TYPE>", ... }
--     PLACEHOLDER matches [A-Z][A-Z0-9_]*(\.[A-Z][A-Z0-9_]*)*
--     SQL_TYPE   ∈ curated PG set (see comment on column)
--
-- Implicit / excluded namespaces (system handles, no entry required):
--   :CONTEXT.*            → bound by query-service from JWT principal
--   :QUERY.SIZE, :QUERY.OFFSET → bound by query-service for pagination
--
-- Strict validation is enforced in the application layer
-- (sso-admin QueryAdminService.validateParamTypes) before INSERT/UPDATE.
-- We do not add a CHECK constraint because PostgreSQL disallows subqueries
-- in CHECK; a trigger would duplicate the app-layer rule.
--
-- Idempotency. Safe to re-run: ADD COLUMN IF NOT EXISTS, default '{}'
-- means existing rows get an empty map (legacy). Strict validation will
-- force authors to fill types the next time they edit a legacy query.
-- =============================================================================

ALTER TABLE QUERY
    ADD COLUMN IF NOT EXISTS PARAM_TYPES JSONB NOT NULL DEFAULT '{}'::jsonb;

COMMENT ON COLUMN QUERY.PARAM_TYPES IS 'Author-declared JDBC/PG type per caller-controlled placeholder. '
    'Shape: {"PLACEHOLDER":"SQL_TYPE",...}. '
    'SQL_TYPE ∈ {TEXT,VARCHAR,BIGINT,INTEGER,SMALLINT,NUMERIC,BOOLEAN,'
    'DATE,TIMESTAMP,TIMESTAMPTZ,UUID,JSONB,JSON,'
    'TEXT[],BIGINT[],INTEGER[],NUMERIC[],BOOLEAN[]}. '
    'Strict: every :PARAM.* / :BODY.* placeholder in QUERY must appear as a key. '
    ':CONTEXT.* and :QUERY.{SIZE,OFFSET} are system-bound (no entry required).';

-- (1) endpoint row
INSERT INTO endpoint (method, path, description, numberParams)
VALUES ('GET', '/query/param-types',
        'Set curado de tipos PG/JDBC para el dropdown de tipos de parámetro', 0)
ON CONFLICT (path, method, description) DO NOTHING;

-- (2) bind ADMIN. Other roles stay without access — the dropdown is
--     only useful to people who can edit queries, and that requires
--     the existing /query/update binding they already have.
INSERT INTO role_endpoint (endpoint_id, role_id)
SELECT e.id_endpoint, r.id_role
FROM endpoint e
CROSS JOIN role r
WHERE r.name = 'SSO-ADMIN'
  AND e.method = 'GET'
  AND e.path = '/query/param-types'
ON CONFLICT (endpoint_id, role_id) DO NOTHING;