-- ===========================================================================
-- V420 - Endpoint del reporte del grupo (fila de public.query + roles).
--   La funcion fn_informe_grupo_reporte vigente esta en V439.
-- ===========================================================================


INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action, style)
SELECT
    'eval-col-informes-reporte-001',
    'SELECT * FROM academico_test.fn_informe_grupo_reporte(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FILTERS.FK_TGRUPO AS BIGINT),
    CAST(:BODY.FILTERS.PERIODOS AS BIGINT[]),
    CAST(:BODY.FILTERS.SEARCH AS VARCHAR)
);',
    'postgres', false, false,
    m.id_microservice,
    '/informes/reporte', 'SELECT', 'POST',
    '{"BODY.FILTERS.FK_TGRUPO": "BIGINT", "BODY.FILTERS.PERIODOS": "BIGINT[]", "BODY.FILTERS.SEARCH": "VARCHAR"}'::jsonb,
    NULL,
    'El informe de un grupo aplanado para exportar: una fila por (estudiante, periodo, asignatura). Lo consume reporting-service bajo la clave "informes" (POST /reportes/informes), no el front directamente. Llama a la misma fn_informe_grupo_listar de la pantalla, con los mismos filtros y el mismo gate, y expande su columna JSONB de asignaturas. EXPORTA SOLO LO CONSOLIDADO -- las notas guardadas --: las proyecciones (las que la pantalla pinta en gris) y las notas requeridas para aprobar quedan fuera, porque impresas en un boletin se leerian como calificaciones reales. Una asignatura con cambio propuesto si sale, con su nota guardada. Un grupo sin nada cerrado devuelve cero filas. PREESCOLAR entra por otra puerta: ahi el informe se cierra guardando la OBSERVACION y no consolidando notas, asi que esas filas salen con la asignatura vacia y su texto -- que siempre es uno que un docente aprobo o edito, porque el estado PENDIENTE no existe.',
    'informes-reporte', 'DEFAULT'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (query_id, role_id)
SELECT reporte.id_query, rq.role_id
  FROM public.query reporte
  JOIN public.microservice m ON m.id_microservice = reporte.microservice_id
  JOIN public.query listado  ON listado.microservice_id = reporte.microservice_id
                            AND listado.path_template   = '/informes/grupo'
                            AND listado.http_method     = 'POST'
  JOIN public.role_query rq  ON rq.query_id = listado.id_query
 WHERE reporte.uuid = 'eval-col-informes-reporte-001'
ON CONFLICT DO NOTHING;
