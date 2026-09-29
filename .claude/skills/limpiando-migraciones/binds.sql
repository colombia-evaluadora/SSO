-- Permisos por NOMBRE (los ids difieren entre bases): quien puede que.
\pset tuples_only on
\pset format unaligned
SELECT 'rq|' || r.name || '|' || coalesce(m.serviceid, '?') || '|' || q.path_template || '|' || q.http_method
  FROM public.role_query x JOIN public.role r ON r.id_role = x.role_id
  JOIN public.query q ON q.id_query = x.query_id
  LEFT JOIN public.microservice m ON m.id_microservice = q.microservice_id
UNION ALL
SELECT 'rr|' || r.name || '|' || ro.name || '|' || ro.path
  FROM public.role_route x JOIN public.role r ON r.id_role = x.role_id JOIN public.route ro ON ro.id_route = x.route_id
UNION ALL
SELECT 'ar|' || a.name || '|' || ro.name || '|' || ro.path || '|' || coalesce(ro.menuorder::text, '') || '|' || coalesce(ro.icon, '')
  FROM public.app_route x JOIN public.app a ON a.id_app = x.id_app JOIN public.route ro ON ro.id_route = x.id_route
UNION ALL
SELECT 're|' || r.name || '|' || e.method || '|' || e.path
  FROM public.role_endpoint x JOIN public.role r ON r.id_role = x.role_id JOIN public.endpoint e ON e.id_endpoint = x.endpoint_id
UNION ALL
SELECT 'rg|' || a.name || '|' || b.name
  FROM public.role_grant x JOIN public.role a ON a.id_role = x.granting_role_id JOIN public.role b ON b.id_role = x.grantable_role_id
UNION ALL
SELECT 'ra|' || a.name || '|' || r.name
  FROM public.role_app x JOIN public.app a ON a.id_app = x.id_app JOIN public.role r ON r.id_role = x.id_role
UNION ALL
SELECT 'ro|' || name FROM public.role
ORDER BY 1;
