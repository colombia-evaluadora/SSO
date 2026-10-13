-- ===========================================================================
-- V475 - El referente decide si la actividad lleva nota, tambien sin unidad
-- (desde V218 una actividad puede nacer sin TUNIDAD). fn_actividad_contexto_
-- evaluativo y fn_actividad_es_formativa viven en V243; aqui solo se corrige
-- el detail de los endpoints que anunciaban la decision vieja. Pantalla de
-- edicion y /planeador/actividades/configuracion ya traen este texto en V496.4.
-- Depende de: V243 (funciones), V450, V246.
-- ===========================================================================

SET search_path TO academico_test, public;

-- Los detail de V450 anunciaban la decision vieja como contrato del endpoint.
UPDATE public.query q
   SET detail = q.detail || ' V475 -- Correccion del parrafo anterior: una actividad SIN unidad ya NO devuelve FALSE por defecto. Su referente se deriva del grado del grupo y la asignatura (fn_unidad_referente_aplicable), asi que una actividad de Preescolar sin unidad responde es_formativa = true, como corresponde a su referente y como ya la pintaba GET /planeador/actividades/configuracion. Solo queda FALSE si no hay ningun referente activo para ese (grado, asignatura).'
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/actividades/:ID'
   AND q.http_method     = 'GET'
   AND q.detail NOT LIKE '%V475 --%';

-- Las filas de configuracion anuncian esFormativo / esSumativoSugerido.
UPDATE public.query q
   SET detail = q.detail || ' V476 -- campos_disponibles gana esFormativo (boolean) y esSumativoSugerido (S|N): el VALOR que le corresponde al referente de la actividad, no su visibilidad. Es lo que el formulario debe traer marcado en "Es sumativa" y lo que fn_actividad_crear guarda cuando no se le manda es_evaluativa; hasta V475 el front tenia que deducirlo de evaluacion.visible y, en una actividad SIN unidad, ni siquiera eso funcionaba.'
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/actividades/:ID/configuracion'
   AND q.http_method     = 'GET'
   AND q.detail NOT LIKE '%V476 --%';
