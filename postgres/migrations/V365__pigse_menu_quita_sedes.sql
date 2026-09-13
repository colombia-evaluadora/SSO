-- ============================================================================
-- V365 — quita "Sedes" del menú de PIGSE (agregado por error en V363).
--
-- PIGSE no tiene tabla de sedes: un establecimiento no tiene sub-entidades
-- propias (a diferencia de CEVAL, TSEDE). La pantalla de front_pigse
-- (features/establishment/campuses) se copió de CEVAL sin adaptar a ese
-- hueco de modelo -- llama a endpoints (`/eval-col/establecimientos/sedes/*`)
-- que ni siquiera existen para 'pigse'. Se saca del menú hasta que se
-- decida qué debería representar "sedes" en PIGSE, si algo.
--
-- DELETE de public.route, no solo el bind: route.idparent/app_route/
-- role_route son ON DELETE CASCADE por id_route, así que basta con
-- borrar la fila de route (mismo mecanismo de fn_pigse_ruta_eliminar,
-- V364).
-- ============================================================================

DELETE FROM public.route
 WHERE name = 'Sedes' AND path = 'establecimiento-educativo/sedes';

DO $$
DECLARE
    v_remaining BIGINT;
BEGIN
    SELECT count(*) INTO v_remaining
      FROM public.route
     WHERE name = 'Sedes' AND path = 'establecimiento-educativo/sedes';

    IF v_remaining != 0 THEN
        RAISE EXCEPTION 'V365 fallo: la fila "Sedes" no se borro';
    END IF;

    RAISE NOTICE 'V365 OK: "Sedes" fuera del menu de PIGSE';
END $$;
