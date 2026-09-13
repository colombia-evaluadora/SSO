-- ============================================================================
-- V363 — agrega al menú dinámico de PIGSE (public.route/app_route/role_route)
-- los 4 ítems que ya existen como pantallas reales en front_pigse pero nunca
-- se registraron en el menú: Funcionarios, Sedes, Auditoría (registro de
-- actividad) y Roles y Menús.
--
-- POR QUE FALTABAN
--   public.route/app_route/role_route es el catálogo de menú dinámico de
--   PIGSE (a diferencia de CEVAL, que sigue en academico_test.tmenu/trol_menu).
--   Hasta esta migración solo tenía 2 filas para PIGSE (Gestión Documental,
--   Monitoreo y Cumplimiento, ver id_route 51/52) -- las pantallas de
--   establecimiento/funcionarios/sedes y auditoría YA existen y funcionan en
--   front_pigse (rutas reales en src/config/paths.ts), pero al no estar en
--   este catálogo eran invisibles en el sidebar e inalcanzables por
--   navegación normal (solo por URL directa, y aun así bloqueadas por
--   `appLayoutRoute.beforeLoad`, que redirige a "no-autorizado" si la ruta no
--   está en el menú del usuario -- ver lib/auth-routes.ts).
--
-- PATHS: SIN prefijo /app (ver use-nav-items-query.ts#toAppPath, que lo
--   antepone en el front) -- deben coincidir EXACTO con
--   front_pigse/src/config/paths.ts:
--     establishments.officials -> "establecimiento-educativo/funcionarios"
--     establishments.campuses  -> "establecimiento-educativo/sedes"
--     auditoriaSesiones        -> "registro-de-actividad/sesiones"
--     rolesMenus               -> "administracion/roles-menus"
--
-- ROL: solo PIGSE-ADMINISTRADOR (pedido explícito -- "a laura"). Si más
--   adelante se decide dar acceso a otro rol (p.ej. PIGSE-SECRETARIA_TERRITORIAL
--   a auditoría, mismo criterio que V358 aplicó a las queries), se agrega
--   con otra migración siguiendo este mismo patrón, sin tocar V363.
-- ============================================================================

INSERT INTO public.route (name, path, icon, menuorder, type, idparent)
SELECT v.name, v.path, v.icon, v.menuorder, NULL, NULL
  FROM (VALUES
        ('Funcionarios',   'establecimiento-educativo/funcionarios', 'id-card',  3),
        ('Sedes',          'establecimiento-educativo/sedes',        'university', 4),
        ('Auditoría',      'registro-de-actividad/sesiones',         'history',  5),
        ('Roles y Menús',  'administracion/roles-menus',             'cog',      6)
       ) AS v(name, path, icon, menuorder)
 WHERE NOT EXISTS (
     SELECT 1 FROM public.route r WHERE r.name = v.name AND r.path = v.path
 );

INSERT INTO public.app_route (id_app, id_route)
SELECT a.id_app, r.id_route
  FROM public.app a
  JOIN public.route r ON r.name IN ('Funcionarios', 'Sedes', 'Auditoría', 'Roles y Menús')
                      AND r.path IN ('establecimiento-educativo/funcionarios',
                                     'establecimiento-educativo/sedes',
                                     'registro-de-actividad/sesiones',
                                     'administracion/roles-menus')
 WHERE a.name = 'PIGSE'
ON CONFLICT DO NOTHING;

INSERT INTO public.role_route (role_id, route_id)
SELECT ro.id_role, r.id_route
  FROM public.route r
  CROSS JOIN public.role ro
 WHERE r.name IN ('Funcionarios', 'Sedes', 'Auditoría', 'Roles y Menús')
   AND r.path IN ('establecimiento-educativo/funcionarios',
                  'establecimiento-educativo/sedes',
                  'registro-de-actividad/sesiones',
                  'administracion/roles-menus')
   AND ro.name = 'PIGSE-ADMINISTRADOR'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- Verificación
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_routes BIGINT;
    v_app_routes BIGINT;
    v_role_routes BIGINT;
BEGIN
    -- Scoped por (name, path) exacto -- no basta con el nombre: ya existia
    -- una fila huerfana "Funcionarios" (id_route=47, sin app_route, atada
    -- solo a SSO-ADMIN) con un path distinto (con "/" inicial en vez de
    -- sin el). No interfiere con PIGSE (no tiene app_route), pero un
    -- conteo por nombre a secas la contaria de mas.
    SELECT count(*) INTO v_routes
      FROM public.route
     WHERE (name, path) IN (
         ('Funcionarios',  'establecimiento-educativo/funcionarios'),
         ('Sedes',         'establecimiento-educativo/sedes'),
         ('Auditoría',     'registro-de-actividad/sesiones'),
         ('Roles y Menús', 'administracion/roles-menus')
     );

    SELECT count(*) INTO v_app_routes
      FROM public.app_route ar
      JOIN public.app a ON a.id_app = ar.id_app
      JOIN public.route r ON r.id_route = ar.id_route
     WHERE a.name = 'PIGSE'
       AND r.name IN ('Funcionarios', 'Sedes', 'Auditoría', 'Roles y Menús');

    SELECT count(*) INTO v_role_routes
      FROM public.role_route rr
      JOIN public.role ro ON ro.id_role = rr.role_id
      JOIN public.route r ON r.id_route = rr.route_id
     WHERE ro.name = 'PIGSE-ADMINISTRADOR'
       AND r.name IN ('Funcionarios', 'Sedes', 'Auditoría', 'Roles y Menús');

    RAISE NOTICE 'V363: routes=% app_route(PIGSE)=% role_route(PIGSE-ADMINISTRADOR)=% (esperado 4/4/4)',
        v_routes, v_app_routes, v_role_routes;

    IF v_routes != 4 THEN
        RAISE EXCEPTION 'V363 fallo: se esperaban 4 filas nuevas en public.route, se encontraron %', v_routes;
    END IF;
    IF v_app_routes != 4 THEN
        RAISE EXCEPTION 'V363 fallo: se esperaban 4 binds app_route(PIGSE), se encontraron %', v_app_routes;
    END IF;
    IF v_role_routes != 4 THEN
        RAISE WARNING 'V363: PIGSE-ADMINISTRADOR quedo con % de 4 binds de role_route -- revisa que el rol exista con ese nombre exacto en public.role', v_role_routes;
    END IF;
END $$;
