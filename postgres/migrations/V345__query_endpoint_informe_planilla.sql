-- ===========================================================================
-- V345 - Endpoint de la planilla del modulo de informes.
--
--   POST /informes/planilla  ->  fn_informe_planilla_listar (V344)
--
-- POR QUE UNA RUTA PROPIA Y NO /planeador/planilla/*
--   Esas dos rutas ya existen y sirven a la planilla del planeador (V239), que
--   no se toca. Esta es otra pantalla: se llega desde las alertas de informes,
--   acota por periodo de evaluacion, usa la misma proyeccion que detecta los
--   cambios y toma su linea base de TASIGNATURA_NOTA. Compartir ruta obligaria
--   a cambiar el contrato de aquella.
--
-- POR QUE POST SI SOLO LEE
--   Por coherencia con los otros siete endpoints del modulo (V342, V343). El
--   execution_mode sigue siendo SELECT: no escribe nada.
--
-- UN SOLO ENDPOINT, NO DOS
--   La planilla del planeador separa columnas y cuerpo en dos llamadas. Aca
--   las actividades viajan dentro de cada fila, en ACTIVIDADES, con su ORDEN:
--   el front arma el header con las celdas de cualquier fila -- todas traen
--   las mismas columnas y en el mismo orden, incluidas las NO_ASIGNADA -- y no
--   hay forma de que header y cuerpo se desalineen, porque salen de la misma
--   consulta.
--
-- QUIEN LO PUEDE LLAMAR
--   El reparto de lectura del modulo, el mismo de /informes/grupo.
--
-- Idempotente: ON CONFLICT DO NOTHING.
-- ===========================================================================


INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action, style)
SELECT
    'eval-col-informes-planilla-listar-001',
    'SELECT * FROM academico_test.fn_informe_planilla_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FK_TGRUPO AS BIGINT),
    CAST(:BODY.FK_TASIGNATURA AS BIGINT),
    CAST(:BODY.FK_TPERIODO_EVALUACION AS BIGINT),
    CAST(:BODY.SEARCH AS VARCHAR)
);',
    'postgres', false, false,
    m.id_microservice,
    '/informes/planilla', 'SELECT', 'POST',
    '{"BODY.FK_TGRUPO": "BIGINT", "BODY.FK_TASIGNATURA": "BIGINT", "BODY.FK_TPERIODO_EVALUACION": "BIGINT", "BODY.SEARCH": "VARCHAR"}'::jsonb,
    NULL,
    'Planilla de calificacion a la que llevan las dos alertas de informes. Una fila por estudiante del grupo con su definitiva del periodo -- guardada y proyectada, ambas en porcentaje y tambien homologadas a la escala del colegio -- y las actividades del periodo embebidas en ACTIVIDADES (JSONB): una celda por actividad con orden, titulo, estado (CALIFICADA / PENDIENTE / NO_ASIGNADA / NO_CALIFICABLE), porcentaje, nota homologada y el pkTactividadEstudiante que el popover necesita para precargar y guardar. Todas las filas traen las mismas columnas en el mismo orden, incluidas las NO_ASIGNADA, asi que el header se arma con las celdas de cualquier fila y no puede desalinearse del cuerpo. NO es /planeador/planilla/*, que sirve a la planilla del docente y no se toca: esta acota por PERIODO DE EVALUACION, usa la misma proyeccion que detecta los cambios (fn_asignatura_definitiva_proyectada_periodo) y toma su linea base de TASIGNATURA_NOTA, que es donde el modulo consolida -- aquella la toma de TUNIDAD_NOTA, que nadie escribe. Las flechas de subida/bajada las pinta el front comparando las dos definitivas homologadas; no se manda una columna tendencia porque calcularla sobre porcentajes daria flecha cuando dos porcentajes distintos redondean a la misma nota. SEARCH es un solo texto para dos dimensiones: filtra estudiantes por nombre/documento y actividades por titulo, dejando INTACTA la dimension donde nada coincidio -- buscar un nombre filtra filas y conserva columnas, buscar una actividad conserva filas y filtra columnas, y un texto que no coincide con ninguna devuelve vacio. Sin paginacion. Errores: 404 si no existe el grupo, la asignatura o el periodo; 400 si falta grupo o asignatura, o si el periodo no es del periodo academico del grupo; 409 si el grado enviado no es el del grupo.',
    'informes-planilla-listar', 'DEFAULT'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;


INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN (
        'CEVAL-AUXILIAR_ADMINISTRATIVO',
        'CEVAL-COORDINADOR',
        'CEVAL-DIRECTOR_GRUPO',
        'CEVAL-DOCENTE',
        'CEVAL-JEFE_AREA',
        'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL',
        'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO',
        'CEVAL-PSICO_ORIENTADOR',
        'CEVAL-RECTOR',
        'CEVAL-SUPER_ADMINISTRADOR',
        'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/informes/planilla'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;
