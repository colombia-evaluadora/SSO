-- =============================================================================
-- V35 — registers file-service as a MICROSERVICE row of kind=REST, plus the
-- two endpoints it actually exposes. Until this migration file-service was
-- reachable only through the static route in api-gateway/application.yml
-- (lb://file-service, Path=/api/files/**): reachable, but invisible to the
-- catalog — MICROSERVICE had no row for it, ENDPOINT had no rows for its
-- paths, and ENDPOINT_MICROSERVICE had nothing to bind.
--
-- Why the catalog matters even with a working static route:
--   1. role_endpoint gating. Every other endpoint since V15 is gated by a
--      row in role_endpoint. file-service had no rows, so the catalog
--      effectively asked "is this path in role_endpoint?" → no → "deny".
--      Any user without the wildcard bypass that ADMIN had in V15 would
--      have been rejected. Adding the rows fixes that for ADMIN out of
--      the box (we grant ADMIN below, like V15 did for every other seed).
--   2. Endpoints admin screen consistency. The Microservicios tab lists
--      whatever is in MICROSERVICE; missing file-service made the catalog
--      look incomplete.
--   3. Internal-route audit. Anything in MICROSERVICE.REQUESTURI shows up
--      in the /internal/gateway/routes polling as a known service. Even
--      though CatalogRoutesRefresher skips kind=REST rows for routing,
--      the listing is still the source of truth for "what services does
--      the SSO know about".
--
-- Paths written WITHOUT the /api gateway prefix — same convention V15
-- uses everywhere: catalog paths are the post-StripPrefix paths the
-- controllers actually see. /api/files/** → /files/**, but the catalog
-- row is for the controller's own @RequestMapping, so /files/download/{id}.
--
-- /files/** (POST/PUT) is a true catch-all, not a single path. We model
-- it as one row with NUMBERPARAMS=0 and a description that calls out the
-- wildcard — there's no way to express "any path under /files" with a
-- fixed NUMBERPARAMS, and pinning it to 0 matches the runtime: the path
-- variables for these come from the multipart body, not the URL.
-- =============================================================================

INSERT INTO microservice (serviceid, description, requesturi) VALUES
('file-service', 'Servicio de binarios: sube multipart a S3/Garage y streamea la descarga por el gateway', '/api/files/**')
ON CONFLICT (serviceid) DO NOTHING;

INSERT INTO endpoint (method, path, description, numberparams) VALUES
('GET',  '/files/download/{archivoId}', 'Descargar binario streameando desde S3/Garage a través del gateway (autenticación: X-Internal-Token)', 1),
('POST', '/files/**',                   'Reenvío de subida multipart: transforma a JSON y delega al catálogo (catch-all)',                          0),
('PUT',  '/files/**',                   'Idem POST, método PUT (catch-all)',                                                                      0)
ON CONFLICT (path, method, description) DO NOTHING;

INSERT INTO endpoint_microservice (endpoint_id, microservice_id)
SELECT e.id_endpoint, m.id_microservice
FROM endpoint e
CROSS JOIN microservice m
WHERE m.serviceid = 'file-service'
  AND (
        (e.method = 'GET'  AND e.path = '/files/download/{archivoId}')
     OR (e.method = 'POST' AND e.path = '/files/**')
     OR (e.method = 'PUT'  AND e.path = '/files/**')
      )
ON CONFLICT (endpoint_id, microservice_id) DO NOTHING;

-- Grant ADMIN everything we just seeded, like V15 did for every other
-- endpoint. Without this the catalog would 403 the first admin request
-- against file-service even though the gateway happily routed it.
INSERT INTO role_endpoint (endpoint_id, role_id)
SELECT e.id_endpoint, r.id_role
FROM endpoint e
CROSS JOIN role r
WHERE r.name = 'ADMIN'
  AND (
        (e.method = 'GET'  AND e.path = '/files/download/{archivoId}')
     OR (e.method = 'POST' AND e.path = '/files/**')
     OR (e.method = 'PUT'  AND e.path = '/files/**')
      )
ON CONFLICT (endpoint_id, role_id) DO NOTHING;
