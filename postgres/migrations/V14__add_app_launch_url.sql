-- =============================================================================
-- V14 — launch_url on app + registers the Colombia Evaluadora app.
--
-- Until now every app row was purely a grouping concept (routes/
-- microservices/roles/users) with no notion of "where does clicking
-- this app actually take you" — fine while admin-ui was the only
-- app in the system. A second real app (external, its own frontend)
-- is coming online, so App needs a launch URL: SSO-ADMIN's is the
-- relative "/admin/" (this same SPA), Colombia Evaluadora's is an
-- absolute external URL.
--
-- role_app for COLOMBIA-EVALUADORA is intentionally NOT seeded here
-- — bind it to a role from the existing Apps admin screen (Roles
-- tab), same onboarding path as any other app.
-- =============================================================================

ALTER TABLE app ADD COLUMN IF NOT EXISTS launch_url VARCHAR(500);

UPDATE app SET launch_url = '/admin/' WHERE name = 'SSO-ADMIN' AND launch_url IS NULL;

INSERT INTO app (name, description, launch_url)
VALUES ('COLOMBIA-EVALUADORA', 'Colombia Evaluadora', 'https://cartagena.colombiaevaluadora.co/')
ON CONFLICT (name) DO NOTHING;
