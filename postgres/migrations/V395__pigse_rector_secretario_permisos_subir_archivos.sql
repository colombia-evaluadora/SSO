-- ============================================================================
-- V395 — PIGSE-RECTOR y PIGSE-SECRETARIO no podían subir archivos
-- (POST /files/pigse/documentos/upload devolvia 403, "sin binding
-- role_endpoint para subir" en file-service/ReenvioController). Comparado
-- contra sus analogos de CEVAL:
--
--   CEVAL-RECTOR tiene POST/PUT/PATCH /files/** -- PIGSE-RECTOR solo
--   tenia PUT.
--
--   CEVAL-AUXILIAR_ADMINISTRATIVO (analogo mas cercano a "secretario")
--   tiene POST/PUT/PATCH /files/** -- PIGSE-SECRETARIO no tenia NINGUNO
--   de los tres, solo lectura (view/download/view-token).
--
-- Se completan los bindings faltantes en public.role_endpoint para que
-- ambos roles queden a la par de sus equivalentes en CEVAL.
-- ============================================================================

INSERT INTO public.role_endpoint (role_id, endpoint_id)
SELECT r.id_role, e.id_endpoint
  FROM public.role r
  JOIN public.endpoint e ON e.path = '/files/**'
 WHERE (r.name, e.method) IN (
     ('PIGSE-RECTOR', 'POST'),
     ('PIGSE-RECTOR', 'PATCH'),
     ('PIGSE-SECRETARIO', 'POST'),
     ('PIGSE-SECRETARIO', 'PUT'),
     ('PIGSE-SECRETARIO', 'PATCH')
 )
   AND NOT EXISTS (
       SELECT 1 FROM public.role_endpoint re
        WHERE re.role_id = r.id_role AND re.endpoint_id = e.id_endpoint
   );

DO $$
DECLARE
    v_missing INTEGER;
BEGIN
    SELECT count(*) INTO v_missing
      FROM (VALUES
          ('PIGSE-RECTOR', 'POST'), ('PIGSE-RECTOR', 'PATCH'), ('PIGSE-RECTOR', 'PUT'),
          ('PIGSE-SECRETARIO', 'POST'), ('PIGSE-SECRETARIO', 'PUT'), ('PIGSE-SECRETARIO', 'PATCH')
      ) AS expected(role_name, method)
     WHERE NOT EXISTS (
         SELECT 1
           FROM public.role_endpoint re
           JOIN public.role r ON r.id_role = re.role_id
           JOIN public.endpoint e ON e.id_endpoint = re.endpoint_id
          WHERE r.name = expected.role_name
            AND e.method = expected.method
            AND e.path = '/files/**'
     );

    IF v_missing > 0 THEN
        RAISE EXCEPTION 'V395: faltan % bindings role_endpoint esperados para PIGSE-RECTOR/PIGSE-SECRETARIO', v_missing;
    END IF;

    RAISE NOTICE 'V395 OK: PIGSE-RECTOR y PIGSE-SECRETARIO tienen POST/PUT/PATCH /files/** igual que sus analogos de CEVAL.';
END $$;
