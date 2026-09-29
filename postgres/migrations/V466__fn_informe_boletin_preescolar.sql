-- ===========================================================================
-- V466 - Endpoint del boletin de preescolar (fila de public.query + roles).
--   La funcion fn_informe_boletin_preescolar vigente esta en V468.
-- ===========================================================================


DELETE FROM public.role_query
 WHERE query_id IN (SELECT id_query FROM public.query
                     WHERE uuid = 'eval-col-informes-boletin-preescolar-001');

DELETE FROM public.query
 WHERE uuid = 'eval-col-informes-boletin-preescolar-001';

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action, style)
SELECT 'eval-col-informes-boletin-preescolar-001',
       'SELECT * FROM academico_test.fn_informe_boletin_preescolar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FILTERS.FK_TGRUPO AS BIGINT),
    CAST(:BODY.FILTERS.FK_TPERIODO_EVALUACION AS BIGINT),
    CAST(:BODY.FILTERS.FK_TMATRICULAS AS BIGINT[])
);',
       'postgres', FALSE, FALSE, m.id_microservice,
       '/informes/boletin-preescolar', 'SELECT', 'POST',
       '{"BODY.FILTERS.FK_TGRUPO": "BIGINT", "BODY.FILTERS.FK_TPERIODO_EVALUACION": "BIGINT", "BODY.FILTERS.FK_TMATRICULAS": "BIGINT[]"}'::jsonb,
       NULL,
       'Los datos del boletin de preescolar de un grupo en un periodo: una fila por estudiante, que es una pagina del PDF que arma reporting-service. FK_TGRUPO y FK_TPERIODO_EVALUACION son obligatorios; FK_TMATRICULAS acota a unos estudiantes y sin el sale el grupo entero. Solo devuelve estudiantes cualitativos: sobre un grupo numerico responde una lista vacia, no un error, porque el boletin numerico es otro reporte. Las tres columnas de imagen (FONDO_ARCHIVO, FOTO_ARCHIVO, EVIDENCIAN_ARCHIVO) son PK_TARCHIVO, no URLs: quien las consuma tiene que pedirle los bytes a file-service. Hereda gate, alcance y filtros de POST /informes/grupo, del que esta funcion se cuelga.',
       'informes-boletin-preescolar', 'DEFAULT'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col';

INSERT INTO public.role_query (query_id, role_id)
SELECT boletin.id_query, rq.role_id
  FROM public.query boletin
  JOIN public.query listado
    ON listado.microservice_id = boletin.microservice_id
   AND listado.path_template   = '/informes/grupo'
   AND listado.http_method     = 'POST'
  JOIN public.role_query rq ON rq.query_id = listado.id_query
 WHERE boletin.uuid = 'eval-col-informes-boletin-preescolar-001'
ON CONFLICT DO NOTHING;
