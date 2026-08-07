-- =============================================================================
-- V27 — path-template based query addressing.
--
-- Each QUERY row optionally carries a PATH_TEMPLATE, the URL path (relative
-- to the owning MICROSERVICE.REQUEST_URI prefix) that exposes this query as
-- a first-class HTTP endpoint. Composed with the prefix:
--
--   MICROSERVICE.REQUEST_URI = /api/eval-col/**
--   QUERY.PATH_TEMPLATE      = /establecimiento/{id}
--   => full URL              = POST /api/eval-col/establecimiento/{id}
--
-- Templates without the column (NULL) are reachable only via the legacy
-- POST /<svc>/query {uuid} flow — no behavior change for old queries.
--
-- The catalog author must pick a template that, after stripping the
-- prefix, makes sense as a URL. Validation of the literal "/", the
-- absence of "**", and uniqueness within a microservice is enforced in
-- sso-admin at write time; the partial unique index below is the
-- last-mile defense for legacy / concurrent insert paths.
-- =============================================================================

ALTER TABLE QUERY
    ADD COLUMN IF NOT EXISTS PATH_TEMPLATE VARCHAR(500);

-- (microservice_id, path_template) must be unique when path_template
-- is non-null. Two queries under the same microservice can't claim
-- the same URL. Queries without path_template (NULL) are out of the
-- index, so legacy rows stay unaffected.
CREATE UNIQUE INDEX IF NOT EXISTS uq_query_microservice_path
    ON QUERY(MICROSERVICE_ID, PATH_TEMPLATE)
    WHERE PATH_TEMPLATE IS NOT NULL;

COMMENT ON COLUMN QUERY.PATH_TEMPLATE IS
    'Path dentro del microservicio (ej /establecimiento/{id}). Componer con MICROSERVICE.REQUEST_URI para la URL completa. NULL = solo accesible vía POST /<svc>/query (legacy).';
