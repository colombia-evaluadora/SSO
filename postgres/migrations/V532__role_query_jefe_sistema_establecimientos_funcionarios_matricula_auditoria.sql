-- ===========================================================================
-- V532 - role_query: los dos roles de jefe de sistema (establecimiento y ente
--        territorial) acceden a los endpoints de establecimientos, sedes,
--        funcionarios, matricula y auditoria de acciones (audit-clickhouse-cval).
--
-- Por que: cada rol tenia solo una parte de esos endpoints y query-service
-- respondia 403 antes de llegar a Postgres. El alcance real lo siguen
-- decidiendo los gates de cada funcion (capability por menu + scope).
-- Se omiten las queries sin ningun rol CEVAL (internas o sin gate), salvo las
-- tres del bloque 2, cuyo gate (V29/V52/V166) ya admite al nivel 2.
-- Depende de: V98/V95/V93/V127 y V84-V87 (filas de public.query). Idempotente.
-- ===========================================================================

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO',
                                   'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL')
 WHERE (   (m.serviceid = 'eval-col'
            AND q.path_template ~* '^/?(establecimientos|funcionarios|matricula)(/|$)')
        OR m.serviceid = 'audit-clickhouse-cval')
   AND EXISTS (
       SELECT 1
         FROM public.role_query rq
         JOIN public.role ro ON ro.id_role = rq.role_id
        WHERE rq.query_id = q.id_query AND ro.name LIKE 'CEVAL-%')
   AND NOT EXISTS (
       SELECT 1 FROM public.role_query rq
        WHERE rq.query_id = q.id_query AND rq.role_id = r.id_role);

-- 2. Endpoints fuera del patron de ruta, solo para el jefe de establecimiento:
--    POST /funcionario/cancelar-pendiente, POST /cobertura-academica/matricula/
--    bulk-delete y GET /establecimientos/:ID/sedes.
INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name = 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO'
 WHERE m.serviceid = 'eval-col'
   AND (q.http_method, q.path_template) IN (
           ('POST', '/funcionario/cancelar-pendiente'),
           ('POST', '/cobertura-academica/matricula/bulk-delete'),
           ('GET',  '/establecimientos/:ID/sedes'))
   AND NOT EXISTS (
       SELECT 1 FROM public.role_query rq
        WHERE rq.query_id = q.id_query AND rq.role_id = r.id_role);
