-- ===========================================================================
-- V342 - Endpoints del modulo de informes y consolidacion.
--
--   POST /informes/grupo                  listado principal (V335)
--   POST /informes/cambios-pendientes     alerta naranja    (V337)
--   POST /informes/planillas-pendientes   alerta roja       (V338)
--   POST /informes/periodos               periodos del ano  (V339)
--   POST /informes/guardar                consolidar        (V336)
--
--
-- POR QUE TODOS SON POST, INCLUIDOS LOS DE LECTURA
--   Cuatro de los cinco reciben ARREGLOS -- grupos y periodos seleccionados
--   -- y en este esquema NO hay un solo endpoint GET que pase un arreglo: se
--   reviso, param_types con '[]' aparece unicamente en POST y PUT, siempre
--   por BODY (ver /periodo-evaluacion/bulk-delete, /periodos-academicos,
--   /establecimientos/funcionarios/eliminar-multiple).
--
--   Inventar aqui la primera convencion de arreglos por query string seria
--   apostar a como los serializa el gateway sin tener un caso previo que lo
--   confirme. Se sigue la convencion que ya existe.
--
--   /informes/periodos es el unico que NO lleva arreglos y podria ser GET.
--   Va POST igual, por coherencia: los cinco endpoints de una misma pantalla
--   se consumen del mismo modo, y el front no tiene que recordar cual es la
--   excepcion. El execution_mode sigue siendo SELECT, asi que no escribe
--   nada.
--
--
-- QUIEN LOS PUEDE LLAMAR
--   Los mismos roles que hoy tienen los endpoints del planeador, MENOS
--   CEVAL-ESTUDIANTE y CEVAL-ACUDIENTE. El planeador se los concede porque
--   un estudiante consulta sus propias actividades; el informe consolidado de
--   un GRUPO entero -- con puestos, promedios y quien no ha calificado -- es
--   otra cosa.
--
--   /informes/guardar es mas estrecho todavia: consolidar un periodo es un
--   acto administrativo. Se concede a rector, coordinador, jefe de sistema,
--   auxiliar administrativo, docente y los dos administradores. El docente
--   entra porque es quien cierra su propia planilla; el gate de la funcion
--   (INFORMES/EDITAR con alcance de sede y jornada) lo limita a sus grupos.
--
--   Esta es solo la capa de RUTA. El permiso real lo sigue decidiendo
--   fn_assert_permiso_seccion dentro de cada funcion, contra el menu INFORMES
--   (V331) y el alcance del objeto. Un rol listado aqui que no tenga la
--   capability sigue recibiendo 42501.
--
--
-- LO QUE NO INCLUYE
--   Los tres endpoints del resumen de la IA para preescolar
--   (fn_estudiante_periodo_observacion_generar / _guardar / _eliminar, V332)
--   y el detalle por asignatura (fn_informe_estudiante_asignaturas, V334).
--   No se pidieron en este corte; las funciones estan listas y registrarlas
--   es otra migracion igual a esta.
--
-- Idempotente: ON CONFLICT DO NOTHING sobre (microservice_id, path_template,
-- http_method) y sobre (role_id, query_id).
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 1. POST /informes/grupo  ->  fn_informe_grupo_listar
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action, style)
SELECT
    'eval-col-informes-grupo-listar-001',
    'SELECT * FROM academico_test.fn_informe_grupo_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FK_TGRUPO AS BIGINT),
    CAST(:BODY.PERIODOS AS BIGINT[]),
    CAST(:BODY.SEARCH AS VARCHAR)
);',
    'postgres', false, false,
    m.id_microservice,
    '/informes/grupo', 'SELECT', 'POST',
    '{"BODY.FK_TGRUPO": "BIGINT", "BODY.PERIODOS": "BIGINT[]", "BODY.SEARCH": "VARCHAR"}'::jsonb,
    NULL,
    'Listado principal de informes: una fila por (estudiante, periodo) del grupo, con promedio, puesto, aprobadas/reprobadas y las asignaturas embebidas en JSONB (nota homologada y nota_propuesta cuando hay cambio). La columna FORMATO dice si la fila se lee como numerica o cualitativa (preescolar); en el caso cualitativo lo que vale es OBSERVACION. PERIODOS vacio o ausente = todos los del periodo academico del grupo. Sin paginacion: la pantalla muestra el grupo entero y paginar romperia el puesto, que se calcula sobre el conjunto. SEARCH filtra por nombre y documento DESPUES de calcular el puesto, para que buscar a alguien no cambie su posicion.',
    'informes-grupo-listar', 'DEFAULT'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;


-- ---------------------------------------------------------------------------
-- 2. POST /informes/cambios-pendientes  ->  fn_informe_cambios_pendientes
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action, style)
SELECT
    'eval-col-informes-cambios-pendientes-001',
    'SELECT * FROM academico_test.fn_informe_cambios_pendientes(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.GRUPOS AS BIGINT[]),
    CAST(:BODY.PERIODOS AS BIGINT[])
);',
    'postgres', false, false,
    m.id_microservice,
    '/informes/cambios-pendientes', 'SELECT', 'POST',
    '{"BODY.GRUPOS": "BIGINT[]", "BODY.PERIODOS": "BIGINT[]"}'::jsonb,
    NULL,
    'Alerta NARANJA: docentes que cambiaron notas DESPUES de que el periodo se consolidara. Una fila por (grupo, asignatura, periodo) con el docente asignado, cuantos estudiantes quedaron afectados y la fecha del ultimo cambio. GRUPOS es obligatorio y admite varios, porque la pantalla trabaja con pestanas y la alerta habla de todos los seleccionados; un grupo fuera del alcance del usuario hace fallar la llamada entera con 403, no devuelve una alerta incompleta. El periodo viaja porque el boton "Ir" lleva a la planilla y la planilla carga las actividades DE ESE periodo. Suma de estudiantes_afectados = total del boton; cuenta de grupos distintos = encabezado del panel.',
    'informes-cambios-pendientes', 'DEFAULT'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;


-- ---------------------------------------------------------------------------
-- 3. POST /informes/planillas-pendientes  ->  fn_informe_planillas_pendientes
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action, style)
SELECT
    'eval-col-informes-planillas-pendientes-001',
    'SELECT * FROM academico_test.fn_informe_planillas_pendientes(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.GRUPOS AS BIGINT[]),
    CAST(:BODY.PERIODOS AS BIGINT[])
);',
    'postgres', false, false,
    m.id_microservice,
    '/informes/planillas-pendientes', 'SELECT', 'POST',
    '{"BODY.GRUPOS": "BIGINT[]", "BODY.PERIODOS": "BIGINT[]"}'::jsonb,
    NULL,
    'Alerta ROJA: planillas sin NADA registrado. Una fila por (grupo, asignatura, periodo) con el docente asignado, cuantos estudiantes tiene el grupo y cuantas actividades existen -- 0 significa que ni siquiera las armo. SOLO considera periodos YA TERMINADOS (FECHA_FIN < hoy): un periodo en curso no puede tener planillas pendientes porque el docente esta dentro de su plazo, y marcarlo llenaria la alerta de rojo el primer dia de cada periodo. Cuenta como calificado cualquier nota U OBSERVACION, para que los docentes de preescolar -- que no ponen numeros sino comentarios por actividad -- no salgan como morosos. Misma firma que la alerta naranja para que el front las trate igual.',
    'informes-planillas-pendientes', 'DEFAULT'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;


-- ---------------------------------------------------------------------------
-- 4. POST /informes/periodos  ->  fn_periodo_evaluacion_listar_ano
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action, style)
SELECT
    'eval-col-informes-periodos-listar-001',
    'SELECT * FROM academico_test.fn_periodo_evaluacion_listar_ano(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.ANIO AS INTEGER),
    CAST(:BODY.FK_TESTABLECIMIENTO AS BIGINT),
    CAST(:BODY.FK_TSEDE AS BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/informes/periodos', 'SELECT', 'POST',
    '{"BODY.ANIO": "INTEGER", "BODY.FK_TESTABLECIMIENTO": "BIGINT", "BODY.FK_TSEDE": "BIGINT"}'::jsonb,
    NULL,
    'Periodos de evaluacion de un ano lectivo, para poblar los checkboxes de la pantalla de informes. ANIO es el ano como numero (2026) y no una FK, porque TANO_LECTIVO es por establecimiento y no existe "el ano lectivo 2026" como registro unico; si no se manda se usa el ano de hoy, que es lo que pasa al abrir la pantalla. El alcance lo pone quien pregunta: solo se devuelven periodos de establecimientos que el usuario alcanza, y FK_TESTABLECIMIENTO / FK_TSEDE solo sirven para ACOTAR, nunca para ampliar. Devuelve TERMINO y EN_CURSO ya calculados -- TERMINO es exactamente la condicion que usa la alerta roja para decidir si una planilla puede considerarse pendiente. La sede y la jornada viajan porque dos periodos pueden llamarse igual en sedes distintas.',
    'informes-periodos-listar', 'DEFAULT'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;


-- ---------------------------------------------------------------------------
-- 5. POST /informes/guardar  ->  fn_informe_periodo_guardar
--
--    Es el unico que ESCRIBE. execution_mode sigue siendo SELECT porque la
--    funcion se invoca con SELECT -- es como el resto del esquema registra
--    sus funciones de escritura (ver fn_unidad_crear en V245).
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action, style)
SELECT
    'eval-col-informes-periodo-guardar-001',
    'SELECT * FROM academico_test.fn_informe_periodo_guardar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FK_TGRUPO AS BIGINT),
    CAST(:BODY.FK_TPERIODO_EVALUACION AS BIGINT),
    CAST(:BODY.MATRICULAS AS BIGINT[])
);',
    'postgres', false, false,
    m.id_microservice,
    '/informes/guardar', 'SELECT', 'POST',
    '{"BODY.FK_TGRUPO": "BIGINT", "BODY.FK_TPERIODO_EVALUACION": "BIGINT", "BODY.MATRICULAS": "BIGINT[]"}'::jsonb,
    NULL,
    'Consolida un periodo: congela la nota proyectada de cada asignatura en TASIGNATURA_NOTA y las metricas del estudiante (promedio, aprobadas, reprobadas) en TINFORME_PERIODO_MATRICULA. Es el paso de gris a negro. MATRICULAS vacio o ausente = todo el grupo; con lista, solo esos estudiantes. UN SOLO PERIODO por llamada, a diferencia de los endpoints de lectura: guardar es un acto puntual sobre un periodo concreto y aceptar un arreglo invitaria a consolidar varios de un clic sin que el usuario vea que va a congelar. Devuelve un informe POR ESTUDIANTE -- guardadas, actualizadas, sin_proyeccion, sin_cambio, promedio, aprobadas, reprobadas y el detalle en JSONB -- y no un contador. PREESCOLAR NO USA ESTE ENDPOINT: alli no hay nota que congelar y todo saldria sin_proyeccion; lo que se guarda es el resumen de la IA, que es otra funcion. Volver a llamarlo es seguro: lo que no cambio se reporta sin_cambio y no se toca.',
    'informes-periodo-guardar', 'DEFAULT'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;


-- ---------------------------------------------------------------------------
-- 6. Roles.
--
--    Los cuatro de LECTURA comparten reparto: los mismos roles que ya tienen
--    el planeador, menos ESTUDIANTE y ACUDIENTE.
-- ---------------------------------------------------------------------------
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
 WHERE m.serviceid = 'eval-col'
   AND q.http_method = 'POST'
   AND q.path_template IN ('/informes/grupo',
                           '/informes/cambios-pendientes',
                           '/informes/planillas-pendientes',
                           '/informes/periodos')
ON CONFLICT DO NOTHING;

-- El de ESCRITURA va mas estrecho: consolidar es un acto administrativo. Se
-- deja fuera a jefe de area y psico-orientador, que consultan pero no cierran
-- periodos. El docente si entra -- cierra su propia planilla -- y el gate de
-- la funcion lo limita a sus grupos.
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
   AND q.path_template = '/informes/guardar'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;
