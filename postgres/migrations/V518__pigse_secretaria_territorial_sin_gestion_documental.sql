-- ============================================================================
-- V518 — Saca a PIGSE-SECRETARIA_TERRITORIAL del grant de "Gestion
-- Documental" (POST /documentos/todos*, V368): quedaba en desacuerdo con
-- role_route de "/gestion-documental" (V149), que la excluye a propósito —
-- reportado en vivo (veía la tabla completa por URL directa, sin tener el
-- ítem en el sidebar). DELETE: idempotente por sí solo, sin patrón DROP+CREATE.
-- ============================================================================

DELETE FROM public.role_query rq
 USING public.query q,
       public.microservice m,
       public.role ro
 WHERE rq.query_id = q.id_query
   AND rq.role_id = ro.id_role
   AND q.microservice_id = m.id_microservice
   AND m.serviceid = 'pigse'
   AND q.path_template IN ('/documentos/todos', '/documentos/todos/query')
   AND ro.name = 'PIGSE-SECRETARIA_TERRITORIAL';

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
          FROM public.role_query rq
          JOIN public.query q ON q.id_query = rq.query_id
          JOIN public.microservice m ON m.id_microservice = q.microservice_id
          JOIN public.role ro ON ro.id_role = rq.role_id
         WHERE m.serviceid = 'pigse'
           AND q.path_template IN ('/documentos/todos', '/documentos/todos/query')
           AND ro.name = 'PIGSE-SECRETARIA_TERRITORIAL'
    ) THEN
        RAISE EXCEPTION 'V518 fallo: PIGSE-SECRETARIA_TERRITORIAL sigue con grant en /documentos/todos*';
    END IF;
    RAISE NOTICE 'V518 OK: PIGSE-SECRETARIA_TERRITORIAL sin grant en /documentos/todos*.';
END $$;
