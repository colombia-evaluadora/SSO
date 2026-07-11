-- =============================================================================
-- V15 — populates ENDPOINT with every real sso-admin + auth-center REST
-- endpoint (method + path + description + path-variable count) and binds
-- ALL of them to ADMIN via role_endpoint.
--
-- ENDPOINT/ROLE_ENDPOINT have existed since V3 with full CRUD + bind/unbind
-- already wired in both backend and frontend, but the table was empty and
-- nothing consulted it — purely decorative. This seed is step 1 of making
-- role_endpoint a REAL authorization gate (see SsoAdminAccessManager,
-- sso-admin): populate the catalog and grant ADMIN everything it already
-- has today, so enforcement lands with zero behavior change for ADMIN.
-- Non-ADMIN roles get NOTHING here — fine-grained access is opt-in per
-- role via the Endpoints admin screen's new Roles tab.
--
-- `path` is written exactly as sso-admin/auth-center's own @RequestMapping
-- (no gateway prefix — the gateway strips it before forwarding), using
-- {var} for path variables, matched at runtime by AntPathMatcher (which
-- understands {var} the same way Spring MVC does).
--
-- auth-center's endpoints are cataloged for completeness (and to keep
-- ADMIN's grant total), but are NOT gated by this mechanism — they're
-- shared, app-agnostic infrastructure with their own SecurityConfig
-- (login has no JWT yet to check a role against in the first place).
-- Same for the sso-admin paths already carved out of the anyRequest()
-- catch-all (/myMenu, /getQuery, /getWrite, /myQueries, /activateAccount,
-- /restorePassword, /forgotPassword) — cataloged, not gated; they keep
-- their existing permitAll/per-row authorization untouched.
-- =============================================================================

INSERT INTO endpoint (method, path, description, numberparams) VALUES
-- ---------- sso-admin: AppController (/app) ----------
('POST',   '/app/save',                                 'Crear app', 0),
('PUT',    '/app/update',                                'Actualizar app', 0),
('GET',    '/app/getApps',                               'Listar apps', 0),
('GET',    '/app/{id}',                                  'Obtener app por id', 1),
('DELETE', '/app/{id}',                                  'Eliminar app', 1),
('POST',   '/app/{id}/role/{roleId}',                    'Vincular rol a app', 2),
('DELETE', '/app/{id}/role/{roleId}',                    'Desvincular rol de app', 2),
('GET',    '/app/{id}/roles/checked',                    'Roles vinculados a app (checked)', 1),
('POST',   '/app/{id}/user/{userId}',                    'Vincular usuario a app', 2),
('DELETE', '/app/{id}/user/{userId}',                    'Desvincular usuario de app', 2),
('GET',    '/app/{id}/users/checked',                     'Usuarios vinculados a app (checked)', 1),
('POST',   '/app/{id}/route/{routeId}',                  'Vincular ruta a app', 2),
('DELETE', '/app/{id}/route/{routeId}',                  'Desvincular ruta de app', 2),
('GET',    '/app/{id}/routes/checked',                    'Rutas vinculadas a app (checked)', 1),
('POST',   '/app/{id}/microservice/{microserviceId}',    'Vincular microservicio a app', 2),
('DELETE', '/app/{id}/microservice/{microserviceId}',    'Desvincular microservicio de app', 2),
('GET',    '/app/{id}/microservices/checked',             'Microservicios vinculados a app (checked)', 1),

-- ---------- sso-admin: EndpointController (/endpoint) ----------
('POST',   '/endpoint/save',                              'Crear endpoint', 0),
('PUT',    '/endpoint/update',                            'Actualizar endpoint', 0),
('GET',    '/endpoint/getEndpoints',                      'Listar endpoints', 0),
('GET',    '/endpoint/{id}',                               'Obtener endpoint por id', 1),
('DELETE', '/endpoint/{id}',                               'Eliminar endpoint', 1),
('POST',   '/endpoint/{id}/microservice/{microserviceId}', 'Vincular microservicio a endpoint', 2),
('DELETE', '/endpoint/{id}/microservice/{microserviceId}', 'Desvincular microservicio de endpoint', 2),
('GET',    '/endpoint/{id}/microservices/checked',         'Microservicios vinculados a endpoint (checked)', 1),
('POST',   '/endpoint/{id}/role/{roleId}',                 'Vincular rol a endpoint', 2),
('DELETE', '/endpoint/{id}/role/{roleId}',                 'Desvincular rol de endpoint', 2),
('GET',    '/endpoint/{id}/roles/checked',                  'Roles vinculados a endpoint (checked)', 1),
('GET',    '/endpoint/bySignature',                        'Buscar endpoint por firma (method+path)', 0),

-- ---------- sso-admin: GroupController (/group) ----------
('POST',   '/group',                                       'Crear grupo', 0),
('PUT',    '/group/update',                                'Actualizar grupo', 0),
('GET',    '/group',                                       'Listar grupos', 0),
('POST',   '/group/bindUserGroup',                         'Vincular usuario a grupo', 0),
('POST',   '/group/{id}/role/{roleId}',                    'Vincular rol a grupo', 2),
('DELETE', '/group/{id}/role/{roleId}',                    'Desvincular rol de grupo', 2),
('GET',    '/group/{id}/roles/checked',                     'Roles vinculados a grupo (checked)', 1),

-- ---------- sso-admin: MicroserviceController (/microservice) ----------
('POST',   '/microservice/save',                           'Crear microservicio', 0),
('POST',   '/microservice/testConnection',                 'Probar conexión de microservicio', 0),
('PUT',    '/microservice/update',                          'Actualizar microservicio', 0),
('GET',    '/microservice/getMicroservices',                'Listar microservicios', 0),
('GET',    '/microservice/getMicroservice',                 'Obtener microservicio por serviceId', 0),
('GET',    '/microservice/{id}',                            'Obtener microservicio por id', 1),
('DELETE', '/microservice/{id}',                            'Eliminar microservicio', 1),
('GET',    '/microservice/{id}/container/status',           'Estado del contenedor', 1),
('GET',    '/microservice/{id}/container/logs',             'Logs del contenedor', 1),
('POST',   '/microservice/{id}/container/restart',          'Reiniciar contenedor', 1),

-- ---------- sso-admin: MyMenuController ----------
('GET',    '/myMenu',                                       'Menú del caller (por role_route)', 0),

-- ---------- sso-admin: QueryAdminController (/query) ----------
('POST',   '/query/save',                                   'Crear query', 0),
('PUT',    '/query/update',                                 'Actualizar query', 0),
('GET',    '/query/getQueries',                              'Listar queries', 0),
('GET',    '/query/{id}',                                   'Obtener query por id', 1),
('DELETE', '/query/{id}',                                   'Eliminar query', 1),
('POST',   '/query/{id}/role/{roleId}',                     'Vincular rol a query', 2),
('DELETE', '/query/{id}/role/{roleId}',                     'Desvincular rol de query', 2),
('GET',    '/query/{id}/roles/checked',                      'Roles vinculados a query (checked)', 1),
('GET',    '/query/byUuid',                                  'Obtener query por uuid', 0),

-- ---------- sso-admin: QueryCatalogController ----------
('GET',    '/getQuery',                                     'Ejecutar/consultar query del catálogo', 0),
('GET',    '/myQueries',                                     'Queries visibles para el caller', 0),

-- ---------- sso-admin: RoleController (/role) ----------
('POST',   '/role/createRole',                               'Crear rol', 0),
('PUT',    '/role/updateRole',                               'Actualizar rol', 0),
('GET',    '/role/getRoles',                                 'Listar roles', 0),
('GET',    '/role/getRolesOwn',                              'Listar roles propios del caller', 0),
('GET',    '/role/users',                                    'Usuarios de un rol', 0),
('GET',    '/role/users/checked',                             'Usuarios de un rol (checked)', 0),

-- ---------- sso-admin: RouteController (/route) ----------
('POST',   '/route/save',                                   'Crear ruta', 0),
('PUT',    '/route/update',                                  'Actualizar ruta', 0),
('GET',    '/route/getRoutes',                                'Listar rutas', 0),
('GET',    '/route/getRoutesByParent',                        'Listar rutas por padre', 0),
('GET',    '/route/{id}',                                    'Obtener ruta por id', 1),
('DELETE', '/route/{id}',                                    'Eliminar ruta', 1),
('POST',   '/route/{id}/role/{roleId}',                      'Vincular rol a ruta', 2),
('DELETE', '/route/{id}/role/{roleId}',                      'Desvincular rol de ruta', 2),
('GET',    '/route/{id}/roles/checked',                       'Roles vinculados a ruta (checked)', 1),

-- ---------- sso-admin: UserController (sin prefijo) ----------
('POST',   '/createAccount',                                 'Crear cuenta de usuario', 0),
('PUT',    '/updateAccount',                                 'Actualizar cuenta de usuario', 0),
('POST',   '/activateAccount',                               'Activar cuenta (link de email)', 0),
('GET',    '/forgotPassword',                                'Solicitar restauración de contraseña', 0),
('POST',   '/restorePassword',                               'Restaurar contraseña (link de email)', 0),
('GET',    '/getUsers',                                      'Listar usuarios', 0),
('POST',   '/resendActivation/{id}',                          'Reenviar activación de cuenta', 1),
('POST',   '/deactivateAccount/{id}',                         'Inactivar cuenta', 1),
('POST',   '/reactivateAccount/{id}',                         'Reactivar cuenta', 1),
('GET',    '/getRolesByEmail',                                'Roles de un usuario por email', 0),
('GET',    '/user/roles',                                    'Roles de un usuario por id', 0),
('POST',   '/bindUserRole',                                  'Vincular rol a usuario', 0),
('DELETE', '/unbindUserRole',                                 'Desvincular rol de usuario', 0),

-- ---------- sso-admin: WriteCatalogController ----------
('GET',    '/getWrite',                                      'Ejecutar/consultar write del catálogo', 0),

-- ---------- sso-admin: WriteDefinitionAdminController (/write) ----------
('POST',   '/write/save',                                    'Crear write', 0),
('PUT',    '/write/update',                                  'Actualizar write', 0),
('GET',    '/write/getWrites',                                'Listar writes', 0),
('GET',    '/write/{id}',                                    'Obtener write por id', 1),
('DELETE', '/write/{id}',                                    'Eliminar write', 1),
('POST',   '/write/{id}/role/{roleId}',                       'Vincular rol a write', 2),
('DELETE', '/write/{id}/role/{roleId}',                       'Desvincular rol de write', 2),
('GET',    '/write/{id}/roles/checked',                        'Roles vinculados a write (checked)', 1),
('GET',    '/write/byUuid',                                   'Obtener write por uuid', 0),

-- ---------- auth-center ----------
('POST',   '/login',                                         'Login (JsonLoginFilter, no gated)', 0),
('GET',    '/getApiToken',                                   'Login servicio-a-servicio por apiToken', 0),
('GET',    '/getInfoUser',                                    'Perfil del caller autenticado', 0),
('GET',    '/myApps',                                        'Apps visibles para el caller (por role_app)', 0),
('GET',    '/getUsersSSO',                                    'Listar usuarios activos (público en MVP)', 0),
('POST',   '/auth/refresh',                                   'Rotar access token vía cookie de refresh', 0),
('POST',   '/auth/logout',                                    'Cerrar sesión / revocar refresh', 0),
('POST',   '/googleLogin',                                    'Login vía Google (stub)', 0)
ON CONFLICT (path, method, description) DO NOTHING;

-- ADMIN gets every endpoint above — zero behavior change once enforcement
-- lands, since ADMIN already has unconditional access to all of them today.
INSERT INTO role_endpoint (endpoint_id, role_id)
SELECT e.id_endpoint, r.id_role
FROM endpoint e
CROSS JOIN role r
WHERE r.name = 'ADMIN'
ON CONFLICT (endpoint_id, role_id) DO NOTHING;
