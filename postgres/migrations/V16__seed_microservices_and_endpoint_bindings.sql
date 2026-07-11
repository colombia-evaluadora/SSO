-- =============================================================================
-- V16 — registers sso-admin and auth-center as MICROSERVICE rows (kind=REST,
-- the default — pure catalog entries, no provisioner container lifecycle
-- attached) and associates every V15-seeded ENDPOINT with the service that
-- actually owns it.
--
-- MICROSERVICE has been empty since the schema existed — nothing ever
-- registered these two static, docker-compose-managed services here (the
-- table's real usage so far has been the provisioner's dynamic
-- kind=QUERY rows). serviceid mirrors the lb:// name api-gateway's own
-- application.yml already routes to (lb://sso-admin, lb://auth-center),
-- so the catalog stays consistent with the actual gateway config.
--
-- ENDPOINT_MICROSERVICE bind/unbind has been fully wired in both backend
-- (EndpointController) and frontend (useEndpoints.ts) since before this
-- migration — same "built but never populated" situation V15 fixed for
-- role_endpoint. The Endpoints admin screen's new Microservicios tab
-- (admin-ui) is the dynamic assign/unassign UI for this join going
-- forward; this seed is just the initial state matching each endpoint's
-- real owning service.
-- =============================================================================

INSERT INTO microservice (serviceid, description, requesturi) VALUES
('sso-admin',   'SSO Admin console API',      '/api/sso-admin/**'),
('auth-center', 'Shared authentication service', '/api/auth/**')
ON CONFLICT (serviceid) DO NOTHING;

-- The 8 auth-center-owned paths (see V15's own auth-center section) go to
-- the auth-center row; everything else V15 seeded belongs to sso-admin.
INSERT INTO endpoint_microservice (endpoint_id, microservice_id)
SELECT e.id_endpoint, m.id_microservice
FROM endpoint e
CROSS JOIN microservice m
WHERE m.serviceid = 'auth-center'
  AND e.path IN (
      '/login', '/getApiToken', '/getInfoUser', '/myApps',
      '/getUsersSSO', '/auth/refresh', '/auth/logout', '/googleLogin'
  )
ON CONFLICT (endpoint_id, microservice_id) DO NOTHING;

INSERT INTO endpoint_microservice (endpoint_id, microservice_id)
SELECT e.id_endpoint, m.id_microservice
FROM endpoint e
CROSS JOIN microservice m
WHERE m.serviceid = 'sso-admin'
  AND e.path NOT IN (
      '/login', '/getApiToken', '/getInfoUser', '/myApps',
      '/getUsersSSO', '/auth/refresh', '/auth/logout', '/googleLogin'
  )
ON CONFLICT (endpoint_id, microservice_id) DO NOTHING;
