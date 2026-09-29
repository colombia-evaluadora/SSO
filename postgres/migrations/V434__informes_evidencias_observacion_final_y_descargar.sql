-- ===========================================================================
-- V434 - Endpoints de informes: evidencias, observacion del Final y descargar.
--
--   POST /informes/evidencias          fn_informe_periodo_evidencias_listar
--   POST /informes/observacion/final   fn_estudiante_final_observacion
--   POST /informes/tabla               fn_informe_grupo_tabla (reporting-service)
--
-- Los roles se copian del listado /informes/grupo: quien ve el informe ve sus
-- evidencias, su observacion del Final y puede bajarlo.
-- ===========================================================================

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action, style)
SELECT
    'eval-col-informes-evidencias-001',
    'SELECT * FROM academico_test.fn_informe_periodo_evidencias_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FK_TMATRICULA AS BIGINT),
    CAST(:BODY.FK_TPERIODO_EVALUACION AS BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/informes/evidencias', 'SELECT', 'POST',
    '{"BODY.FK_TMATRICULA": "BIGINT", "BODY.FK_TPERIODO_EVALUACION": "BIGINT"}'::jsonb,
    NULL,
    'Las evidencias (imagenes adjuntas a las observaciones) de UN estudiante en un periodo, para la pantalla de informes. FK_TPERIODO_EVALUACION nulo o ausente = TODO el año, que es lo que necesita la fila Final. Una fila por adjunto: pk_tactividad_soporte, fk_tarchivo (el que se le pasa a POST /files/view-token/{id} para mostrarlo), nombre, urls3, peso, etiqueta, fecha, el periodo en que cae, la actividad de la que sale y su observacion. NO es el mismo que GET /planeador/actividades/estudiantes/:ID/soportes: aquel tiene gate PLANEADOR/VER -- quien mira informes puede no tener planeador -- y se pide por actividad, no por periodo. Gate INFORMES/VER; 404 si la matricula no existe.',
    'informes-evidencias', 'DEFAULT'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action, style)
SELECT
    'eval-col-informes-observacion-final-001',
    'SELECT * FROM academico_test.fn_estudiante_final_observacion(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FK_TMATRICULA AS BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/informes/observacion/final', 'SELECT', 'POST',
    '{"BODY.FK_TMATRICULA": "BIGINT"}'::jsonb,
    NULL,
    'La observacion de la fila FINAL de un estudiante: sus resumenes de periodo YA CONSOLIDADOS, encadenados en orden y prefijados con el nombre del periodo. NO es /informes/observacion/generar, que concatena las observaciones por ACTIVIDAD dentro de un periodo -- eso es materia prima y se revisa antes de guardar; esto es texto que alguien ya aprobo. NO ESCRIBE y no hay como guardarlo: el Final no es un periodo real, asi que se calcula al mirarlo igual que su nota, y de paso se actualiza solo cuando alguien reconsolida un periodo. Devuelve siempre una fila: observacion y periodos_incluidos, en NULL y cero si el estudiante no tiene ningun resumen guardado. Es la misma informacion que ya trae la fila Final de /informes/grupo; existe como endpoint propio para refrescarla sin recargar el listado entero. Gate INFORMES/VER.',
    'informes-observacion-final', 'DEFAULT'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action, style)
SELECT
    'eval-col-informes-tabla-001',
    'SELECT * FROM academico_test.fn_informe_grupo_tabla(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FILTERS.FK_TGRUPO AS BIGINT),
    CAST(:BODY.FILTERS.PERIODOS AS BIGINT[]),
    CAST(:BODY.FILTERS.SEARCH AS VARCHAR),
    CAST(:BODY.FILTERS.INCLUIR_FINAL AS BOOLEAN)
);',
    'postgres', false, false,
    m.id_microservice,
    '/informes/tabla', 'SELECT', 'POST',
    '{"BODY.FILTERS.FK_TGRUPO": "BIGINT", "BODY.FILTERS.PERIODOS": "BIGINT[]", "BODY.FILTERS.SEARCH": "VARCHAR", "BODY.FILTERS.INCLUIR_FINAL": "BOOLEAN"}'::jsonb,
    NULL,
    'La tabla de informes tal como se esta viendo, aplanada para bajarla. Lo consume reporting-service bajo la clave "informes-tabla" (POST /reportes/informes-tabla), no el front directamente. A diferencia de /informes/reporte -- el BOLETIN -- no filtra nada: salen lo consolidado, lo proyectado, lo requerido y lo que no tiene nota, cada uno dicho con todas las letras en ESTADO, mas una columna CONSOLIDADO. Respeta los filtros de la pantalla, SEARCH incluido.',
    'informes-tabla', 'DEFAULT'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (query_id, role_id)
SELECT nuevo.id_query, rq.role_id
  FROM public.query nuevo
  JOIN public.query listado  ON listado.microservice_id = nuevo.microservice_id
                            AND listado.path_template   = '/informes/grupo'
                            AND listado.http_method     = 'POST'
  JOIN public.role_query rq  ON rq.query_id = listado.id_query
 WHERE nuevo.uuid IN ('eval-col-informes-evidencias-001',
                      'eval-col-informes-observacion-final-001',
                      'eval-col-informes-tabla-001')
ON CONFLICT DO NOTHING;
