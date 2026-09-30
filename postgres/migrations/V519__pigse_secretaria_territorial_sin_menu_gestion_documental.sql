-- ============================================================================
-- V519 — Saca a PIGSE-SECRETARIA_TERRITORIAL del MENU "Gestion Documental"
-- (role_route de "/app/gestion-documental").
--
-- Confirmado en test: hay DOS filas `route` duplicadas para ese path (un
-- guardado de "Roles y Menus" que no matcheo la existente por path). Una
-- tiene los roles correctos (V149); la otra, de mas, incluye a Secretaria
-- Territorial — `/my-menus` no dedupe por path, asi que el redirect de
-- `/app` la tomaba de ahi. No se tocan las filas `route` en si (pueden
-- tener otras referencias); solo el grant puntual, en cualquier id_route.
-- ============================================================================

DELETE FROM public.role_route rr
 USING public.route rt,
       public.role ro
 WHERE rr.route_id = rt.id_route
   AND rr.role_id = ro.id_role
   AND rt.path = '/app/gestion-documental'
   AND ro.name = 'PIGSE-SECRETARIA_TERRITORIAL';

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
          FROM public.role_route rr
          JOIN public.route rt ON rt.id_route = rr.route_id
          JOIN public.role ro ON ro.id_role = rr.role_id
         WHERE rt.path = '/app/gestion-documental'
           AND ro.name = 'PIGSE-SECRETARIA_TERRITORIAL'
    ) THEN
        RAISE EXCEPTION 'V519 fallo: PIGSE-SECRETARIA_TERRITORIAL sigue con el menu /app/gestion-documental';
    END IF;
    RAISE NOTICE 'V519 OK: PIGSE-SECRETARIA_TERRITORIAL sin el menu /app/gestion-documental.';
END $$;
