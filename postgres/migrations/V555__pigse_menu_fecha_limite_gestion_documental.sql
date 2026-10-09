-- V555 -- item de menu PIGSE "Fecha limite documental" para la pantalla de V522
-- (front_pigse: /app/administracion/gestion-documental/fecha-limite), hoy solo
-- alcanzable por URL y bloqueada por el guard de rutas del front.
-- Raiz (idparent NULL), como V499: el padre natural "Gestion Documental" no lo
-- tiene Secretaria Territorial (V149/V519) y un hijo de un padre invisible no
-- se pinta. Path sin '/app' (el front lo antepone en toAppPath).
-- Roles: los mismos que escriben la fecha/excepciones en V522. Sin codigo: ni
-- los endpoints ni la pantalla consultan fn_usuario_puede_en_menu.
-- Depende de: V149 (catalogo PIGSE), V370 (puede_*), V522.

INSERT INTO public.route (name, path, icon, menuorder, type, idparent)
SELECT 'Fecha límite documental', 'administracion/gestion-documental/fecha-limite',
       'calendar-alt', 8, NULL, NULL
 WHERE NOT EXISTS (
     SELECT 1 FROM public.route r
      WHERE regexp_replace(r.path, '^/?(app/)?', '') = 'administracion/gestion-documental/fecha-limite'
 );

INSERT INTO public.app_route (id_app, id_route)
SELECT a.id_app, r.id_route
  FROM public.app a
  JOIN public.route r
    ON regexp_replace(r.path, '^/?(app/)?', '') = 'administracion/gestion-documental/fecha-limite'
 WHERE a.name = 'PIGSE'
ON CONFLICT DO NOTHING;

INSERT INTO public.role_route (role_id, route_id, puede_crear, puede_editar, puede_eliminar, puede_ver)
SELECT ro.id_role, r.id_route, TRUE, TRUE, TRUE, TRUE
  FROM public.route r
 CROSS JOIN public.role ro
 WHERE regexp_replace(r.path, '^/?(app/)?', '') = 'administracion/gestion-documental/fecha-limite'
   AND ro.name IN ('PIGSE-ADMINISTRADOR', 'PIGSE-SECRETARIA_TERRITORIAL')
ON CONFLICT DO NOTHING;

DO $$
DECLARE
    v_grants INTEGER;
BEGIN
    SELECT count(DISTINCT ro.id_role) INTO v_grants
      FROM public.role_route rr
      JOIN public.role ro ON ro.id_role = rr.role_id
      JOIN public.route r ON r.id_route = rr.route_id
      JOIN public.app_route ar ON ar.id_route = r.id_route
      JOIN public.app a ON a.id_app = ar.id_app AND a.name = 'PIGSE'
     WHERE regexp_replace(r.path, '^/?(app/)?', '') = 'administracion/gestion-documental/fecha-limite'
       AND ro.name IN ('PIGSE-ADMINISTRADOR', 'PIGSE-SECRETARIA_TERRITORIAL');
    IF v_grants <> 2 THEN
        RAISE WARNING 'V555: menu fecha limite con % de 2 roles esperados -- revisa public.role', v_grants;
    END IF;
END $$;
