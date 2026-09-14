-- ============================================================================
-- V375 — "Establecimiento" nunca tuvo entrada en el menu de PIGSE: la
-- pantalla (features/establishment/institution) existe en el front desde
-- el import inicial y tiene sus propios endpoints reales (/establecimientos*,
-- V257/V258), pero nadie la registro en public.route/app_route/role_route
-- -- a diferencia de Funcionarios/Sedes/Auditoria/Roles y Menus, que si se
-- agregaron (V363/V364/V370). Mismo patron que esas.
--
-- De paso, se reordena el menu para que Establecimiento quede antes de
-- Sedes/Funcionarios (es su padre conceptual), sin cambiar nada mas.
-- ============================================================================

INSERT INTO public.route (name, path, menuorder, idparent, codigo)
SELECT 'Establecimiento', 'establecimiento-educativo/general', 2, r.idparent, 'ESTABLECIMIENTO'
  FROM public.route r
 WHERE r.name = 'Funcionarios' AND r.path = 'establecimiento-educativo/funcionarios'
   AND NOT EXISTS (
       SELECT 1 FROM public.route WHERE name = 'Establecimiento' AND path = 'establecimiento-educativo/general'
   );

INSERT INTO public.app_route (id_app, id_route)
SELECT a.id_app, rt.id_route
  FROM public.app a
  JOIN public.route rt ON rt.name = 'Establecimiento' AND rt.path = 'establecimiento-educativo/general'
 WHERE a.name = 'PIGSE'
   AND NOT EXISTS (SELECT 1 FROM public.app_route ar WHERE ar.id_app = a.id_app AND ar.id_route = rt.id_route);

-- Mismos roles que ya alcanzan Sedes/Funcionarios en escritura o lectura
-- (administracion territorial + ente territorial + establecimiento).
INSERT INTO public.role_route (route_id, role_id)
SELECT rt.id_route, ro.id_role
  FROM public.route rt
 CROSS JOIN public.role ro
 WHERE rt.name = 'Establecimiento' AND rt.path = 'establecimiento-educativo/general'
   AND ro.name IN ('PIGSE-ADMINISTRADOR', 'PIGSE-SECRETARIA_TERRITORIAL',
                   'PIGSE-DIRECTOR_ENTE_TERRITORIAL', 'PIGSE-JEFE_SISTEMA_ENTE_TERRITORIAL',
                   'PIGSE-JEFE_AREA_PLANEACION', 'PIGSE-JEFE_AREA_COBERTURA', 'PIGSE-JEFE_AREA_CALIDAD',
                   'PIGSE-RECTOR', 'PIGSE-JEFE_SISTEMA_ESTABLECIMIENTO', 'PIGSE-AUXILIAR_ADMINISTRATIVO')
   AND NOT EXISTS (SELECT 1 FROM public.role_route rr WHERE rr.route_id = rt.id_route AND rr.role_id = ro.id_role);

-- Reordena para que quede: Gestion Documental(1), Establecimiento(2),
-- Sedes(3), Funcionarios(4), Monitoreo y Cumplimiento(5), Auditoria(6),
-- Roles y Menus(7).
UPDATE public.route SET menuorder = 3 WHERE name = 'Sedes' AND path = 'establecimiento-educativo/sedes';
UPDATE public.route SET menuorder = 4 WHERE name = 'Funcionarios' AND path = 'establecimiento-educativo/funcionarios';
UPDATE public.route SET menuorder = 5 WHERE name = 'Monitoreo y Cumplimiento' AND path = '/monitoreo-cumplimiento';
UPDATE public.route SET menuorder = 6 WHERE name = 'Auditoría' AND path = 'registro-de-actividad/sesiones';
UPDATE public.route SET menuorder = 7 WHERE name = 'Roles y Menús' AND path = 'administracion/roles-menus';

DO $$
DECLARE
    v_binds BIGINT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.route WHERE name = 'Establecimiento' AND codigo = 'ESTABLECIMIENTO') THEN
        RAISE EXCEPTION 'V375 fallo: la ruta Establecimiento no quedo creada con codigo ESTABLECIMIENTO';
    END IF;

    SELECT count(*) INTO v_binds
      FROM public.role_route rr
      JOIN public.route rt ON rt.id_route = rr.route_id
     WHERE rt.name = 'Establecimiento' AND rt.path = 'establecimiento-educativo/general';
    IF v_binds != 10 THEN
        RAISE EXCEPTION 'V375 fallo: se esperaban 10 binds de role_route para Establecimiento, se encontraron %', v_binds;
    END IF;

    RAISE NOTICE 'V375 OK: Establecimiento agregado al menu de PIGSE (% binds).', v_binds;
END $$;
