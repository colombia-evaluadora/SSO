-- =============================================================================
-- V50 — PATCH HTTP method + TIME / TIME[] / CHAR(1) parameter types.
--
-- Two independent changes grouped because they share the same validate-at-save
-- pattern (allowlist extension), not because they are coupled:
--   1. QUERY.HTTP_METHOD grows from {GET, POST, PUT} to include PATCH.
--   2. The curated set behind QUERY.PARAM_TYPES grows from 18 to 21 entries
--      (adds TIME, TIME[], CHAR(1)).
--
-- Both changes preserve the existing behavior because:
--   - HTTP_METHOD has DEFAULT 'POST', so every existing row keeps its verb.
--   - PARAM_TYPES has DEFAULT '{}', so every existing row keeps working as
--     legacy until the next edit (strict validation still fires only on edit).
--
-- No data backfill is required. The application-layer validator
-- (QueryAdminService.normalizeHttpMethod / ParamTypes.CURATED) is the
-- single source of truth for the allowlists; the CHECK constraint and
-- the COMMENT here are defense-in-depth and self-documentation.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- (1) HTTP_METHOD — admit PATCH.
-- ---------------------------------------------------------------------------

ALTER TABLE QUERY
    DROP CONSTRAINT IF EXISTS ck_query_http_method;
ALTER TABLE QUERY
    ADD CONSTRAINT ck_query_http_method
    CHECK (HTTP_METHOD IN ('GET', 'POST', 'PUT', 'PATCH'));

COMMENT ON COLUMN QUERY.HTTP_METHOD IS
    'Verbo HTTP que expone esta fila cuando tiene PATH_TEMPLATE: GET, POST, PUT o PATCH. Default POST = comportamiento previo a V33. DELETE no se admite a proposito; para borrar, publica un procedimiento y llamalo con CALL. PATCH (RFC 5789) lleva cuerpo parcial y admite DML (INSERT/UPDATE directo) igual que POST/PUT; igual que PUT, no se restringe a :BODY.* (eso sigue siendo exclusivo de GET).';

-- ---------------------------------------------------------------------------
-- (2) PARAM_TYPES — broaden the curated set with TIME, TIME[] and CHAR(1).
-- ---------------------------------------------------------------------------
--
-- The validation lives in
--   sso-admin ...service.QueryAdminService.validateParamTypes
-- plus the catalog source-of-truth in
--   common ...query.ParamTypes.java
-- A CHECK constraint is not enforceable here because PostgreSQL disallows
-- subqueries in CHECK (the curated set lives in application code), and a
-- trigger would duplicate the app-layer rule. We only refresh the COMMENT
-- so the schema self-description matches the application-layer set — anyone
-- running `\d+ QUERY` in psql sees the full allowlist.

COMMENT ON COLUMN QUERY.PARAM_TYPES IS
    'Author-declared JDBC/PG type per caller-controlled placeholder. '
    'Shape: {"PLACEHOLDER":"SQL_TYPE",...}. '
    'SQL_TYPE ∈ {TEXT,VARCHAR,CHAR(1),BIGINT,INTEGER,SMALLINT,NUMERIC,BOOLEAN,'
    'DATE,TIME,TIMESTAMP,TIMESTAMPTZ,UUID,JSONB,JSON,'
    'TEXT[],BIGINT[],INTEGER[],NUMERIC[],BOOLEAN[],TIME[]}. '
    'Strict: every :PARAM.* / :BODY.* placeholder in QUERY must appear as a key. '
    ':CONTEXT.* and :QUERY.{SIZE,OFFSET} are system-bound (no entry required).';
