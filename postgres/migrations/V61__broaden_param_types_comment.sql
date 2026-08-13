-- =============================================================================
-- V61 — refresh the COMMENT ON COLUMN QUERY.PARAM_TYPES self-description.
--
-- Three gaps found comparing ParamTypes.CURATED (application source of truth)
-- against this column comment:
--   1. DATE[], TIMESTAMP[] and TIMESTAMPTZ[] were added to the curated set
--      (common ...query.ParamTypes.java) — only TIME[] had an array
--      counterpart among the temporal types, so an author could not declare
--      `WHERE fecha = ANY(:BODY.FECHAS)` without falling back to Spring's
--      auto-derive (breaks with lists, see spec 2026-08-10).
--   2. JSONB[] was added — a list of JSON objects (each element is a
--      sub-object or an already-serialized JSON string; ParamBinder quotes
--      the JSON text as a plain PG-array string element and the `as jsonb[]`
--      cast validates each one is well-formed).
--   3. The academico_test DOMAIN types (BOOL_SN, ESTADO_AI, ESTADO_AC,
--      ESTADO_ACTIVO_INACTIVO, NODO_CURRICULAR, TITULACION_GRADO) were added
--      to CURATED in a prior commit that did not touch this comment — the
--      schema self-description has been stale since then.
--
-- No data backfill, no CHECK constraint change: same reasoning as V55 — the
-- curated set lives in application code (PostgreSQL disallows subqueries in
-- CHECK), this COMMENT is defense-in-depth / self-documentation only.
-- =============================================================================

COMMENT ON COLUMN QUERY.PARAM_TYPES IS
    'Author-declared JDBC/PG type per caller-controlled placeholder. '
    'Shape: {"PLACEHOLDER":"SQL_TYPE",...}. '
    'SQL_TYPE ∈ {TEXT,VARCHAR,CHAR(1),BIGINT,INTEGER,SMALLINT,NUMERIC,BOOLEAN,'
    'DATE,TIME,TIMESTAMP,TIMESTAMPTZ,UUID,JSONB,JSON,'
    'TEXT[],BIGINT[],INTEGER[],NUMERIC[],BOOLEAN[],TIME[],DATE[],TIMESTAMP[],TIMESTAMPTZ[],JSONB[],'
    'BOOL_SN,ESTADO_AI,ESTADO_AC,ESTADO_ACTIVO_INACTIVO,NODO_CURRICULAR,TITULACION_GRADO}. '
    'Strict: every :PARAM.* / :BODY.* placeholder in QUERY must appear as a key. '
    ':CONTEXT.* and :QUERY.{SIZE,OFFSET} are system-bound (no entry required). '
    'BOOL_SN..TITULACION_GRADO are academico_test DOMAIN types — the binder '
    'serializes them to text and lets PG enforce the CHECK constraint via cast.';
