-- ===========================================================================
-- V496.26 - informes docente director solo consultan
-- Recortada: las funciones de informes que V535-V541 reescriben en capas
-- se quitaron de aqui y viven alli. Queda lo que sigue vivo y lo que una
-- base limpia necesita al migrar (CREATE solo si la funcion no existe).
-- ===========================================================================


DELETE FROM public.role_query rq
 USING public.query q, public.microservice m, public.role r
 WHERE rq.query_id        = q.id_query
   AND rq.role_id         = r.id_role
   AND q.microservice_id  = m.id_microservice
   AND m.serviceid        = 'eval-col'
   AND q.http_method      = 'POST'
   AND q.path_template IN ('/informes/guardar',
                           '/informes/planilla/guardar',
                           '/informes/final/guardar',
                           '/informes/observacion/guardar',
                           '/informes/observacion/eliminar',
                           '/informes/observacion/final/guardar',
                           '/informes/observacion/final/eliminar')
   AND r.name IN ('CEVAL-DOCENTE', 'CEVAL-DIRECTOR_GRUPO');

DELETE FROM public.role_endpoint re
 USING public.endpoint e, public.role r
 WHERE re.endpoint_id = e.id_endpoint
   AND re.role_id     = r.id_role
   AND e.method       = 'POST'
   AND e.path IN ('/ai/observaciones/periodo', '/ai/observaciones/anio')
   AND r.name IN ('CEVAL-DOCENTE', 'CEVAL-DIRECTOR_GRUPO');
