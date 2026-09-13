-- ============================================================================
-- V367 — PIGSE-RESPONSABLE_CARGUE era un duplicado de PIGSE-SECRETARIO: el
-- secretario que se crea al dar de alta un establecimiento (fn_est_crear,
-- p_fk_tfuncionario_secretaria) usa el rol PIGSE-SECRETARIO, no
-- RESPONSABLE_CARGUE. Confirmado sin usuarios reales asignados (role_users
-- vacío) antes de borrarlo.
-- ============================================================================

DELETE FROM public.role WHERE name = 'PIGSE-RESPONSABLE_CARGUE';

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM public.role WHERE name = 'PIGSE-RESPONSABLE_CARGUE') THEN
        RAISE EXCEPTION 'V367 fallo: PIGSE-RESPONSABLE_CARGUE sigue existiendo';
    END IF;
    RAISE NOTICE 'V367 OK: PIGSE-RESPONSABLE_CARGUE eliminado';
END $$;
