-- ===========================================================================
-- V282 - Endpoint GET de configuracion de actividad de una unidad (fila de
-- public.query + roles). La funcion vigente esta en V458.
-- ===========================================================================


SET search_path TO academico_test, public;

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT academico_test.fn_unidad_configuracion_actividad(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    COALESCE(CAST(:QUERY.ES_EVALUATIVA AS VARCHAR), ''S'')
) AS configuracion;',
    'postgres', false, false,
    m.id_microservice, '/planeador/unidades/:ID/configuracion-actividad', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT", "QUERY.ES_EVALUATIVA": "VARCHAR"}'::jsonb,
    'V282 -- que pintar en el formulario de NUEVA ACTIVIDAD para la unidad escogida, ANTES de crearla. :ID = PK_TUNIDAD. Es el paso que faltaba del flujo: GET /planeador/actividades/:ID/configuracion devuelve lo mismo pero pide el PK de una actividad que en el formulario de creacion todavia no existe. Devuelve campos_disponibles con la MISMA forma y los mismos textos de motivo que la version por actividad, para reutilizar el codigo de render: criterio {visible, requerido, motivo} (visible=false solo en Preescolar), evaluacion {visible, requerido, motivo, tipoEvaluacion, instrumentosPermitidos:[{pk,valor,nombre}]} (segun el referente de la unidad y su TIPO_EVALUACION) y ponderacion {visible, requerido, modo, campo?, autocalculado?, motivo} (segun el metodo de calculo de la unidad: Ponderar -> PORCENTAJE sobre PONDERACION; Sumatoria -> PUNTAJE sobre NOTA_MAXIMA y autocalculado; Promediar o sin metodo -> no visible). ?ES_EVALUATIVA=S|N (default S) es lo unico que no sale de la unidad: lo que el usuario acaba de marcar en el formulario; con N la seccion de evaluacion y la ponderacion se apagan. El ARBOL de enunciados y evidencias NO viene aqui para no duplicarlo: el CATALOGO a ofrecer se pide a GET /planeador/referente-curricular?grado=&asignatura= (V278) y los que la unidad YA relaciono a GET /planeador/unidades/:ID/referente (que desde su ultima version devuelve SOLO los relacionados). Si la actividad aun no tiene unidad, usar GET /planeador/actividades/configuracion?grupo=&asignatura= (V422), que ademas trae los limites de la seccion Programacion. Gate VER sobre PLANEADOR + alcance por la unidad; 404 (P0002) si la unidad no existe o esta inactiva.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR', 'CEVAL-DOCENTE')
 WHERE m.serviceid = 'eval-col'
   AND q.path_template = '/planeador/unidades/:ID/configuracion-actividad'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;
