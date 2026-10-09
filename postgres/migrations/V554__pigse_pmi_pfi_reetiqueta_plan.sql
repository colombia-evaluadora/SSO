-- ===========================================================================
-- V554 — PMI/PFI: lo cargado hasta hoy en AUTOEVALUACION_INSTITUCIONAL es el
-- plan, no la autoevaluación. Se reetiqueta a la categoría del plan
-- (PLAN_MEJORAMIENTO / PLAN_FORTALECIMIENTO); la autoevaluación queda como
-- anexo pendiente. El archivo no se toca (mismo fk_tarchivo).
-- Depende de: V521 (constraints y categorías de PMI/PFI).
-- ===========================================================================
UPDATE pigse.tdocumento_institucional
   SET categoria   = CASE tipo WHEN 'PMI' THEN 'PLAN_MEJORAMIENTO' ELSE 'PLAN_FORTALECIMIENTO' END,
       modified_by = 'V554',
       modified_at = CURRENT_TIMESTAMP
 WHERE tipo IN ('PMI', 'PFI')
   AND categoria = 'AUTOEVALUACION_INSTITUCIONAL';

DO $$
DECLARE
    v_restantes INTEGER;
BEGIN
    SELECT count(*) INTO v_restantes
      FROM pigse.tdocumento_institucional
     WHERE tipo IN ('PMI', 'PFI') AND categoria = 'AUTOEVALUACION_INSTITUCIONAL';

    IF v_restantes > 0 THEN
        RAISE EXCEPTION 'V554 fallo: % documento(s) PMI/PFI siguen en AUTOEVALUACION_INSTITUCIONAL', v_restantes;
    END IF;
END $$;
