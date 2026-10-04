-- V469.5 — Planilla de calificación: endpoints y sus roles (5 de 5).
--
-- Qué hace: única definición de las filas de public.query de
-- /planeador/planilla/columnas, /planeador/planilla/calificaciones y
-- /planeador/periodos-evaluacion (antes repartidas entre V248, V252, V254,
-- V441, V450, V454 y V469) y de sus role_query (antes en V248, V249, V254,
-- V284 y V305). Upsert por (microservicio, ruta, método): una fila que ya
-- existe conserva su id, y con él los role_query que ya tenga.
-- Depende de: V469.4 (funciones de endpoint), V215 (fn_get_academico_usuario_id).

SET search_path TO academico_test, public;

-- GET /planeador/planilla/columnas
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode,
                          public_end, captcha, param_types, detail, query)
SELECT '0b6f4f8e-2c1d-4c55-9a51-7c3e0c0f1a01', m.id_microservice, '/planeador/planilla/columnas', 'GET', 'postgres', 'SELECT',
       FALSE, FALSE, '{"QUERY.GRUPO": "BIGINT", "QUERY.ASIGNATURA": "BIGINT", "QUERY.GRADO": "BIGINT", "QUERY.FECHA_DESDE": "DATE", "QUERY.FECHA_HASTA": "DATE", "QUERY.SEARCH": "VARCHAR", "QUERY.PERIODO": "BIGINT"}'::jsonb,
       'Header de la "Planilla de calificacion" (fn_planilla_columnas_listar): una fila por actividad-columna del (grupo, asignatura) en el periodo de evaluacion, en el mismo orden_columna que las celdas de GET /planeador/planilla/calificaciones. ?GRUPO= y ?ASIGNATURA= obligatorios (22023); ?GRADO= opcional, debe ser el del grupo (23503); ?PERIODO=<pk_tperiodo_evaluacion> opcional: por defecto el que contiene hoy, si no el ultimo cerrado, si no el primero; 23503 si es de otro periodo academico. Solo salen las actividades cuya fecha de cierre (o de inicio) cae en el periodo. ?FECHA_DESDE/?FECHA_HASTA acotan ademas por ventana y ?SEARCH por titulo+descripcion. Cada fila trae pk_tperiodo_evaluacion (el periodo resuelto), orden_columna, pk_tactividad, titulo, fk_tunidad + unidad (toggle "Ver por: Unidad"), instrumento (VALOR/NOMBRE) y metodo_valoracion si es OTRO, ponderacion, nota_maxima, es_evaluativa, es_formativa, fechas y el progreso de ESE grupo (asignados / calificados). Sin paginacion. Alcance VER del Planeador sobre el grupo.',
       'SELECT * FROM academico_test.fn_planilla_columnas_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.GRUPO AS BIGINT),
    CAST(:QUERY.ASIGNATURA AS BIGINT),
    CAST(:QUERY.GRADO AS BIGINT),
    CAST(:QUERY.FECHA_DESDE AS DATE),
    CAST(:QUERY.FECHA_HASTA AS DATE),
    CAST(:QUERY.SEARCH AS VARCHAR),
    CAST(:QUERY.PERIODO AS BIGINT)
);'
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, public_end = EXCLUDED.public_end,
       captcha = EXCLUDED.captcha, param_types = EXCLUDED.param_types, detail = EXCLUDED.detail,
       query = EXCLUDED.query;

-- GET /planeador/planilla/calificaciones
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode,
                          public_end, captcha, param_types, detail, query)
SELECT '0b6f4f8e-2c1d-4c55-9a51-7c3e0c0f1a02', m.id_microservice, '/planeador/planilla/calificaciones', 'GET', 'postgres', 'SELECT',
       FALSE, FALSE, '{"QUERY.GRUPO": "BIGINT", "QUERY.ASIGNATURA": "BIGINT", "QUERY.GRADO": "BIGINT", "QUERY.FECHA_DESDE": "DATE", "QUERY.FECHA_HASTA": "DATE", "QUERY.SEARCH_ACTIVIDAD": "VARCHAR", "QUERY.SEARCH_ESTUDIANTE": "VARCHAR", "QUERY.SIZE": "INT", "QUERY.OFFSET": "INT", "QUERY.PERIODO": "BIGINT"}'::jsonb,
       'Celdas de la "Planilla de calificacion" (fn_planilla_calificaciones_listar): una fila por matricula del grupo con definitiva_proyectada (con lo calificado en el periodo) y definitiva_registrada (TASIGNATURA_NOTA del periodo), tendencia SUBE/BAJA/IGUAL, sus homologaciones al formato de la asignatura (formato_valor, nota_maxima, es_numerico) y celdas: una por actividad del periodo, en el mismo orden que GET /planeador/planilla/columnas, con estado (NO_ASIGNADA / NO_CALIFICABLE / SIN_CALIFICAR / CALIFICADA), calificacion, recuperacion, definitiva, nota, notaHomologada, valoracion, resultadoInstrumento, observacion, fecha de asistencia, esFormativa y evidencias (solo formativas). Mismos filtros y errores que el header (?PERIODO= igual), mas ?SEARCH_ESTUDIANTE= y paginacion ?SIZE=/?OFFSET= (50/0). Alcance VER del Planeador sobre el grupo.',
       'SELECT * FROM academico_test.fn_planilla_calificaciones_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.GRUPO AS BIGINT),
    CAST(:QUERY.ASIGNATURA AS BIGINT),
    CAST(:QUERY.GRADO AS BIGINT),
    CAST(:QUERY.FECHA_DESDE AS DATE),
    CAST(:QUERY.FECHA_HASTA AS DATE),
    CAST(:QUERY.SEARCH_ACTIVIDAD AS VARCHAR),
    CAST(:QUERY.SEARCH_ESTUDIANTE AS VARCHAR),
    COALESCE(CAST(:QUERY.SIZE AS INT), 50),
    COALESCE(CAST(:QUERY.OFFSET AS INT), 0),
    CAST(:QUERY.PERIODO AS BIGINT)
);'
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, public_end = EXCLUDED.public_end,
       captcha = EXCLUDED.captcha, param_types = EXCLUDED.param_types, detail = EXCLUDED.detail,
       query = EXCLUDED.query;

-- GET /planeador/periodos-evaluacion
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode,
                          public_end, captcha, param_types, detail, query)
SELECT '0b6f4f8e-2c1d-4c55-9a51-7c3e0c0f1a03', m.id_microservice, '/planeador/periodos-evaluacion', 'GET', 'postgres', 'SELECT',
       FALSE, FALSE, '{"QUERY.PERIODO": "BIGINT", "QUERY.ESTADO": "BIGINT", "QUERY.GRUPO": "BIGINT"}'::jsonb,
       'Periodos de evaluacion de un periodo academico (fn_periodo_evaluacion_listar), de los cuatro estados de ESTADOPERIODOEVALUACION: cada fila trae estado_valor/estado_nombre para que el cliente decida cual habilitar. ?GRUPO= (el selector de la planilla): los del periodo academico del grupo, con el alcance del Planeador sobre el grupo; 404 si el grupo no existe, 23503 si ?PERIODO= no es el del grupo. Sin grupo: ?PERIODO= o el de las asignaciones del docente. ?ESTADO= acota a un estado. Cada fila trae codigo, nombre, abreviacion, fechas, porcentaje, vigente_hoy (para preseleccionar) y el periodo academico. Gate VER sobre PLANEADOR.',
       'SELECT * FROM academico_test.fn_periodo_evaluacion_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.PERIODO AS BIGINT),
    CAST(:QUERY.ESTADO AS BIGINT),
    NULL,
    CAST(:QUERY.GRUPO AS BIGINT)
);'
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, public_end = EXCLUDED.public_end,
       captcha = EXCLUDED.captcha, param_types = EXCLUDED.param_types, detail = EXCLUDED.detail,
       query = EXCLUDED.query;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id AND m.serviceid = 'eval-col'
  JOIN public.role r ON r.name IN (
        'CEVAL-SUPER_ADMINISTRADOR', 'CEVAL-DOCENTE', 'CEVAL-RECTOR',
        'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO')
 WHERE q.http_method = 'GET'
   AND q.path_template IN ('/planeador/planilla/columnas', '/planeador/planilla/calificaciones',
                           '/planeador/periodos-evaluacion')
ON CONFLICT DO NOTHING;
