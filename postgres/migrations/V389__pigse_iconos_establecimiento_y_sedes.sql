-- ============================================================================
-- V389 — los menús "Establecimiento" y "Sedes" (V375/V370) se registraron
-- sin icono: getNavIcon (front) cae al genérico de interrogación cuando
-- `icon` es null/vacío. Se asignan íconos reales, siguiendo la misma
-- convención ya usada por el resto de las rutas de public.route.
-- ============================================================================

UPDATE public.route SET icon = 'Buildings-Icon' WHERE codigo = 'ESTABLECIMIENTO';
UPDATE public.route SET icon = 'house-line' WHERE codigo = 'SEDES_EDUCATIVAS';

DO $$
DECLARE
    v_ok BOOLEAN;
BEGIN
    SELECT bool_and(icon IS NOT NULL AND icon != '') INTO v_ok
      FROM public.route WHERE codigo IN ('ESTABLECIMIENTO', 'SEDES_EDUCATIVAS');

    IF NOT coalesce(v_ok, false) THEN
        RAISE WARNING 'V389: alguna de las dos rutas no tiene icono asignado (puede ser normal si la ruta aun no existe en este ambiente).';
    ELSE
        RAISE NOTICE 'V389 OK: Establecimiento y Sedes tienen icono real.';
    END IF;
END $$;
