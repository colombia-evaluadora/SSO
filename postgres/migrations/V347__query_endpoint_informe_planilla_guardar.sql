-- ===========================================================================
-- V347 - Endpoint del guardado de la planilla.
--
--   POST /informes/planilla/guardar  ->  fn_informe_planilla_guardar (V346)
--
-- CONVIVE CON /informes/guardar
--   Aquel congela TODAS las asignaturas del estudiante en el periodo; este,
--   UNA sola. No se pisan -- TASIGNATURA_NOTA es por (matricula, periodo,
--   asignatura) -- y ambos terminan llamando a fn_informe_metricas_recalcular,
--   asi que el promedio y los conteos del periodo quedan coherentes sin
--   importar en que orden se usen. Los dos son idempotentes.
--
--   Usar este NO deja al otro a medias: despues de guardar una asignatura
--   desde la planilla, el guardado completo reporta 'sin_cambio' para esa y
--   congela el resto.
--
-- POR QUE DEVUELVE EL PROMEDIO
--   Para que la pantalla pueda refrescar la cabecera del estudiante sin
--   volver a pedir el listado entero. Es el valor YA recalculado, no una
--   estimacion del cliente.
--
-- Idempotente: ON CONFLICT DO NOTHING.
-- ===========================================================================


INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action, style)
SELECT
    'eval-col-informes-planilla-guardar-001',
    'SELECT * FROM academico_test.fn_informe_planilla_guardar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FK_TGRUPO AS BIGINT),
    CAST(:BODY.FK_TASIGNATURA AS BIGINT),
    CAST(:BODY.FK_TPERIODO_EVALUACION AS BIGINT),
    CAST(:BODY.MATRICULAS AS BIGINT[])
);',
    'postgres', false, false,
    m.id_microservice,
    '/informes/planilla/guardar', 'SELECT', 'POST',
    '{"BODY.FK_TGRUPO": "BIGINT", "BODY.FK_TASIGNATURA": "BIGINT", "BODY.FK_TPERIODO_EVALUACION": "BIGINT", "BODY.MATRICULAS": "BIGINT[]"}'::jsonb,
    NULL,
    'Congela la definitiva de UNA asignatura desde la planilla ("Aprobar y actualizar consolidado"). MATRICULAS vacio o ausente = todos los estudiantes del grupo; con lista, solo esos. Devuelve por estudiante el RESULTADO -- guardada / actualizada (con nota_anterior) / sin_cambio / sin_proyeccion -- y ademas el promedio del periodo, aprobadas y reprobadas YA RECALCULADOS, para que la pantalla refresque sin volver a pedir el listado. CONVIVE CON /informes/guardar, que congela todas las asignaturas: no se pisan porque TASIGNATURA_NOTA es por (matricula, periodo, asignatura), y ambos llaman al mismo recalculo de metricas, asi que el promedio del periodo queda coherente sin importar el orden; los dos son idempotentes. Usar este no deja al otro a medias: despues, el guardado completo reporta sin_cambio para esta asignatura y congela el resto. En sin_proyeccion (no hay actividad evaluativa calificada en el periodo) lo ya guardado NO se borra: quitar un consolidado por una ausencia no es decision de un boton de guardar. La nota se guarda en PORCENTAJE, no homologada, porque la escala depende de TCRITERIO_EVALUACION y puede cambiar. Errores: 404 si no existe grupo, asignatura o periodo; 400 si el periodo no es del periodo academico del grupo; 409 si el grado no es el del grupo.',
    'informes-planilla-guardar', 'DEFAULT'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;


-- Mismo reparto estrecho que /informes/guardar: congelar es un acto
-- administrativo. El docente entra porque cierra su propia planilla, y el gate
-- de la funcion lo limita a sus grupos.
INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN (
        'CEVAL-AUXILIAR_ADMINISTRATIVO',
        'CEVAL-COORDINADOR',
        'CEVAL-DOCENTE',
        'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL',
        'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO',
        'CEVAL-RECTOR',
        'CEVAL-SUPER_ADMINISTRADOR',
        'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/informes/planilla/guardar'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;
