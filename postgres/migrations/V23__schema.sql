-- CDC init: slot + publication are created in 02-publication.sql and 03-replica-identity.sql.
-- The academic schema (147 tables in academico_test) is loaded by 00-academic-schema.sql
-- (which is tables.sql mounted from the repo root).
-- This file is kept for ordering compatibility with the Postgres entrypoint.
SELECT '01-schema.sql loaded — academic schema in 00-academic-schema.sql' AS status;
