-- ===========================================================================
-- V533 - CEVAL-PSICO_ORIENTADOR recibe los mismos endpoints que
--        CEVAL-COORDINADOR (role_query + role_endpoint).
--
-- Por que: el psico-orientador no podia consultar Asistencias; los filtros de
-- la pantalla (/establecimientos/sedes/opciones, /planeador/sedes/opciones,
-- ...) solo estaban atados al coordinador y query-service respondia 403. Por
-- decision de negocio ambos roles comparten alcance de endpoints.
-- role_query/role_endpoint son la puerta gruesa: los datos y la escritura los
-- siguen decidiendo los gates PL/pgSQL (menu + alcance por categoria).
-- Depende de: todas las filas de coordinador sembradas antes (incl. V95.1);
-- por eso va al final y no en un hueco. Idempotente.
-- ===========================================================================

INSERT INTO public.role_query (role_id, query_id)
SELECT p.id_role, rq.query_id
  FROM public.role_query rq
  JOIN public.role c ON c.id_role = rq.role_id AND c.name = 'CEVAL-COORDINADOR'
  JOIN public.role p ON p.name = 'CEVAL-PSICO_ORIENTADOR'
ON CONFLICT DO NOTHING;

INSERT INTO public.role_endpoint (endpoint_id, role_id)
SELECT re.endpoint_id, p.id_role
  FROM public.role_endpoint re
  JOIN public.role c ON c.id_role = re.role_id AND c.name = 'CEVAL-COORDINADOR'
  JOIN public.role p ON p.name = 'CEVAL-PSICO_ORIENTADOR'
ON CONFLICT DO NOTHING;
