-- ============================================================================
-- V499 — agrega al menú dinámico de PIGSE (public.route/app_route/role_route)
-- el ítem "Actividad de usuarios", pantalla que ya existe en front_pigse
-- (`/app/actividad-usuarios`, PR colombia-evaluadora/front_pigse#40) pero
-- nunca se registró acá -- mismo problema que V363 con Funcionarios/Sedes/
-- Auditoría/Roles y Menús: sin esta fila, la pantalla es invisible en el
-- sidebar e inalcanzable por navegación normal (bloqueada por
-- `appLayoutRoute.beforeLoad`, que redirige a "no-autorizado" si la ruta no
-- está en el menú del usuario -- ver front_pigse/src/lib/auth-routes.ts).
--
-- La query que alimenta la pantalla (`POST /usuarios/actividad/query`,
-- `pigse.fn_usuarios_actividad_listar`) ya se dio de alta en V495 -- esta
-- migración solo agrega el ITEM DE MENÚ, que es un catálogo aparte
-- (public.route/role_route) del catálogo de queries (public.query/role_query).
--
-- PATH: SIN prefijo /app (ver use-nav-items-query.ts#toAppPath, que lo
--   antepone en el front) -- coincide EXACTO con
--   front_pigse/src/config/paths.ts: actividadUsuarios -> "actividad-usuarios".
--
-- ROL: los mismos 6 que acepta `fn_usuarios_actividad_listar` (V495) --
--   Secretaría Territorial, Secretario, Jefe de Área Calidad/Planeación/
--   Cobertura y Administrador. Sin alcance territorial, igual que la query.
-- ============================================================================

INSERT INTO public.route (name, path, icon, menuorder, type, idparent)
SELECT 'Actividad de usuarios', 'actividad-usuarios', 'users', 7, NULL, NULL
 WHERE NOT EXISTS (
     SELECT 1 FROM public.route r WHERE r.name = 'Actividad de usuarios' AND r.path = 'actividad-usuarios'
 );

INSERT INTO public.app_route (id_app, id_route)
SELECT a.id_app, r.id_route
  FROM public.app a
  JOIN public.route r ON r.name = 'Actividad de usuarios' AND r.path = 'actividad-usuarios'
 WHERE a.name = 'PIGSE'
ON CONFLICT DO NOTHING;

INSERT INTO public.role_route (role_id, route_id)
SELECT ro.id_role, r.id_route
  FROM public.route r
  CROSS JOIN public.role ro
 WHERE r.name = 'Actividad de usuarios'
   AND r.path = 'actividad-usuarios'
   AND ro.name IN ('PIGSE-SECRETARIA_TERRITORIAL', 'PIGSE-SECRETARIO',
                   'PIGSE-JEFE_AREA_CALIDAD', 'PIGSE-JEFE_AREA_PLANEACION',
                   'PIGSE-JEFE_AREA_COBERTURA', 'PIGSE-ADMINISTRADOR')
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
    SELECT count(*) INTO v_routes
      FROM public.route
     WHERE name = 'Actividad de usuarios' AND path = 'actividad-usuarios';

    SELECT count(*) INTO v_app_routes
      FROM public.app_route ar
      JOIN public.app a ON a.id_app = ar.id_app
      JOIN public.route r ON r.id_route = ar.id_route
     WHERE a.name = 'PIGSE'
       AND r.name = 'Actividad de usuarios' AND r.path = 'actividad-usuarios';

    SELECT count(*) INTO v_role_routes
      FROM public.role_route rr
      JOIN public.role ro ON ro.id_role = rr.role_id
      JOIN public.route r ON r.id_route = rr.route_id
     WHERE r.name = 'Actividad de usuarios' AND r.path = 'actividad-usuarios'
       AND ro.name IN ('PIGSE-SECRETARIA_TERRITORIAL', 'PIGSE-SECRETARIO',
                       'PIGSE-JEFE_AREA_CALIDAD', 'PIGSE-JEFE_AREA_PLANEACION',
                       'PIGSE-JEFE_AREA_COBERTURA', 'PIGSE-ADMINISTRADOR');

    RAISE NOTICE 'V499: routes=% app_route(PIGSE)=% role_route=% (esperado 1/1/6)',
        v_routes, v_app_routes, v_role_routes;

    IF v_routes != 1 THEN
        RAISE EXCEPTION 'V499 fallo: se esperaba 1 fila nueva en public.route, se encontraron %', v_routes;
    END IF;
    IF v_app_routes != 1 THEN
        RAISE EXCEPTION 'V499 fallo: se esperaba 1 bind app_route(PIGSE), se encontraron %', v_app_routes;
    END IF;
    IF v_role_routes != 6 THEN
        RAISE WARNING 'V499: role_route quedo con % de 6 binds esperados -- revisa que los 6 roles existan con ese nombre exacto en public.role', v_role_routes;
    END IF;
END $$;
