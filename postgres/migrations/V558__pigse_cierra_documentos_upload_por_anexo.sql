-- ===========================================================================
-- V558 — Cierra POST /documentos/upload (pigse-documentos-upload).
--   Guardaba un anexo suelto con pigse.fn_documento_guardar y permitia saltarse
--   la regla "todo o nada" de V555.4/V555.5 (todos los obligatorios a la vez).
--   El front ya usa /documentos/archivos + PUT /documentos/:TIPO/anexos.
--   Se quitan sus grants de role_query: el motor responde 403 a todo rol.
--   La fila de public.query se conserva (historial y rollback por grants).
-- Depende de: V149, V512, V521 (grants), V555.5 (endpoints de reemplazo).
-- ===========================================================================

DELETE FROM public.role_query rq
 USING public.query q
 WHERE rq.query_id = q.id_query
   AND q.uuid = 'pigse-documentos-upload';

DO $$
DECLARE
    v_grants INTEGER;
BEGIN
    SELECT count(*) INTO v_grants
      FROM public.role_query rq
      JOIN public.query q ON q.id_query = rq.query_id
     WHERE q.uuid = 'pigse-documentos-upload';

    IF v_grants > 0 THEN
        RAISE EXCEPTION 'V558: pigse-documentos-upload conserva % grants', v_grants;
    END IF;
END $$;
