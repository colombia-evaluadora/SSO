-- V539 — Informes: endpoints de consulta y guardado en un solo sitio.
--
-- Qué hace: las 14 filas de /informes/* cuyas funciones viven en V535-V538,
-- con upsert que conserva el id y con él los role_query de cada servidor: no
-- se tocan roles (V496.26 quitó DOCENTE y DIRECTOR_GRUPO de las escrituras).
-- Las consultas no cambian; el detail de /informes/grupo agrega la C y la R.
-- Quedan fuera las de observaciones, final, formativo, tabla, desactualizado
-- y boletin, que siguen en sus migraciones.
-- Depende de: V537, V538 (funciones), V342-V496.24 (filas).

-- POST /informes/anos
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT 'eval-col-informes-anos-listar-001', m.id_microservice, '/informes/anos', 'POST', 'postgres', 'SELECT', NULL,
       'false', 'false', 'false', '60', 'informes-anos-listar', 'DEFAULT',
       '{"BODY.FK_TSEDE":"BIGINT"}'::jsonb,
       'Segundo select de la pantalla de informes: los años lectivos con periodos academicos activos en esa sede, del año en curso hacia atras. Los años futuros no se ofrecen aunque existan periodos creados (hay para 2027, 2028 y 2029): son configuracion adelantada, no años sobre los que pedir informes. FK_TSEDE acota y nunca amplia -- una sede fuera del alcance devuelve lista vacia. Sin FK_TSEDE devuelve los años de todo el alcance, util si el front quiere precargar.',
       $q$SELECT * FROM academico_test.fn_informe_anos_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FK_TSEDE AS BIGINT)
);$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- POST /informes/cambios-pendientes
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT 'eval-col-informes-cambios-pendientes-001', m.id_microservice, '/informes/cambios-pendientes', 'POST', 'postgres', 'SELECT', NULL,
       'false', 'false', 'false', '60', 'informes-cambios-pendientes', 'DEFAULT',
       '{"BODY.GRUPOS":"BIGINT[]","BODY.PERIODOS":"BIGINT[]"}'::jsonb,
       'Alerta NARANJA: docentes que cambiaron notas DESPUES de que el periodo se consolidara. Una fila por (grupo, asignatura, periodo) con el docente asignado, cuantos estudiantes quedaron afectados y la fecha del ultimo cambio. GRUPOS es obligatorio y admite varios, porque la pantalla trabaja con pestanas y la alerta habla de todos los seleccionados; un grupo fuera del alcance del usuario hace fallar la llamada entera con 403, no devuelve una alerta incompleta. El periodo viaja porque el boton "Ir" lleva a la planilla y la planilla carga las actividades DE ESE periodo. Suma de estudiantes_afectados = total del boton; cuenta de grupos distintos = encabezado del panel.',
       $q$SELECT * FROM academico_test.fn_informe_cambios_pendientes(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.GRUPOS AS BIGINT[]),
    CAST(:BODY.PERIODOS AS BIGINT[])
);$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- POST /informes/evidencias
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT 'eval-col-informes-evidencias-001', m.id_microservice, '/informes/evidencias', 'POST', 'postgres', 'SELECT', NULL,
       'false', 'false', 'false', '60', 'informes-evidencias', 'DEFAULT',
       '{"BODY.FK_TMATRICULA":"BIGINT","BODY.FK_TPERIODO_EVALUACION":"BIGINT"}'::jsonb,
       'Las evidencias (imagenes adjuntas a las observaciones) de UN estudiante en un periodo, para la pantalla de informes. FK_TPERIODO_EVALUACION nulo o ausente = TODO el año, que es lo que necesita la fila Final. Una fila por adjunto: pk_tactividad_soporte, fk_tarchivo (el que se le pasa a POST /files/view-token/{id} para mostrarlo), nombre, urls3, peso, etiqueta, fecha, el periodo en que cae, la actividad de la que sale y su observacion. NO es el mismo que GET /planeador/actividades/estudiantes/:ID/soportes: aquel tiene gate PLANEADOR/VER -- quien mira informes puede no tener planeador -- y se pide por actividad, no por periodo. Gate INFORMES/VER; 404 si la matricula no existe.',
       $q$SELECT e.*, so.ES_FAVORITO AS es_favorito
  FROM academico_test.fn_informe_periodo_evidencias_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FK_TMATRICULA AS BIGINT),
    CAST(:BODY.FK_TPERIODO_EVALUACION AS BIGINT)
  ) e
  JOIN academico_test.TACTIVIDAD_SOPORTE so
    ON so.PK_TACTIVIDAD_SOPORTE = e.pk_tactividad_soporte;$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- POST /informes/grupo
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT 'eval-col-informes-grupo-listar-001', m.id_microservice, '/informes/grupo', 'POST', 'postgres', 'SELECT', NULL,
       'false', 'false', 'false', '60', 'informes-grupo-listar', 'DEFAULT',
       '{"BODY.SEARCH":"VARCHAR","BODY.PERIODOS":"BIGINT[]","BODY.FK_TGRUPO":"BIGINT"}'::jsonb,
       'Listado principal de informes: una fila por (estudiante, periodo) del grupo, con promedio, puesto, aprobadas/reprobadas, la cuenta de EVIDENCIAS y las asignaturas embebidas en JSONB. FORMATO dice si la fila se lee como numerica o cualitativa (preescolar); en el caso cualitativo lo que vale es OBSERVACION. EL FINAL SE PIDE METIENDO -1 EN PERIODOS (V439; antes era el bind INCLUIR_FINAL, que ya no existe): PERIODOS nulo o vacio = todos los periodos reales sin Final, [622,-1] = ese periodo y el Final, [-1] = SOLO el Final. Esa ultima combinacion es la que motiva el cambio: con la bandera era imposible, porque un arreglo vacio significa TODOS. La fila Final llega con FK_TPERIODO_EVALUACION = -1 -- un centinela, no un PK --, MODO_PERIODO "final", CONSOLIDADO false y cada asignatura con ESTADO "final"; vale lo guardado en TASIGNATURA_DEFINITIVA (POST /informes/final/guardar) o, si no hay, se calcula al vuelo: cada periodo con su nota guardada o proyectada, pesado por PORCENTAJE segun el criterio final; un periodo sin ningun valor no cuenta. Sin paginacion: paginar romperia el puesto. SEARCH filtra por nombre y documento DESPUES de calcular el puesto. V474: PROMEDIO_GUARDADO y PROMEDIO_PROYECTADO llegan en el FORMATO DE CALIFICACION del criterio de evaluacion general del periodo academico (3,3 sobre cinco), no en el porcentaje guardado. Si ese formato no es numerico llegan NULL y lo que se pinta son PROMEDIO_VALORACION / PROMEDIO_SIMBOLO y PROMEDIO_PROYECTADO_VALORACION / PROMEDIO_PROYECTADO_SIMBOLO; sin criterio configurado se recibe el porcentaje crudo. PROMEDIO_FORMATO (CINCO/DIEZ/CIEN/LITERAL/SIMBOLO/CARITA) dice con cual se homologo. El PUESTO se sigue calculando sobre el porcentaje. Cada asignatura trae CON_RECUPERACION y, si hubo Habilitacion (recuperacion de NOTA_FINAL), NOTA_ORIGINAL / VALORACION_ORIGINAL / SIMBOLO_ORIGINAL: la nota antes de recuperar; NOTA es la resultante (Regla 68).',
       $q$SELECT * FROM academico_test.fn_informe_grupo_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FK_TGRUPO AS BIGINT),
    CAST(:BODY.PERIODOS AS BIGINT[]),
    CAST(:BODY.SEARCH AS VARCHAR)
);$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- POST /informes/grupos-periodo
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT 'eval-col-informes-grupos-periodo-001', m.id_microservice, '/informes/grupos-periodo', 'POST', 'postgres', 'SELECT', NULL,
       'false', 'false', 'false', '60', 'informes-grupos-periodo', 'DEFAULT',
       '{"BODY.ANIO":"INTEGER","BODY.SEARCH":"VARCHAR","BODY.FK_TSEDE":"BIGINT","BODY.FK_TLV_JORNADA":"BIGINT"}'::jsonb,
       'Los grupos del periodo academico que resuelven la sede, el año y la jornada elegidos en los tres selects de la pantalla. Reemplaza el uso que la vista de informes hacia de GET /planeador/docentes/grupos, que exigia permiso de PLANEADOR y ademas solo devolvia los grupos donde el docente dicta -- con lo cual un rector o una secretaria no veian ninguno. Aqui no se filtra por quien dicta: eso lo decide el permiso INFORMES/VER con alcance de sede y jornada. Cada fila trae la etiqueta ya armada ("Quinto A"), el conteo de matriculas activas, el director de grupo si lo hay y la jornada del propio grupo, que en los años viejos no coincide con la del periodo academico. SEARCH filtra por nombre y codigo de grupo, nombre de grado y la etiqueta compuesta. Responde 42501 si el usuario no alcanza esa sede y jornada, y P0002 si no hay periodo academico para esa combinacion.',
       $q$SELECT * FROM academico_test.fn_informe_grupos_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FK_TSEDE AS BIGINT),
    CAST(:BODY.ANIO AS INTEGER),
    CAST(:BODY.FK_TLV_JORNADA AS BIGINT),
    CAST(:BODY.SEARCH AS VARCHAR)
);$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- POST /informes/guardar
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT 'eval-col-informes-periodo-guardar-001', m.id_microservice, '/informes/guardar', 'POST', 'postgres', 'SELECT', NULL,
       'false', 'false', 'false', '60', 'informes-periodo-guardar', 'DEFAULT',
       '{"BODY.FK_TGRUPO":"BIGINT","BODY.MATRICULAS":"BIGINT[]","BODY.FK_TPERIODO_EVALUACION":"BIGINT"}'::jsonb,
       'Consolida un periodo: congela la nota proyectada de cada asignatura en TASIGNATURA_NOTA y las metricas del estudiante (promedio, aprobadas, reprobadas) en TINFORME_PERIODO_MATRICULA. Es el paso de gris a negro. MATRICULAS vacio o ausente = todo el grupo; con lista, solo esos estudiantes. UN SOLO PERIODO por llamada, a diferencia de los endpoints de lectura: guardar es un acto puntual sobre un periodo concreto y aceptar un arreglo invitaria a consolidar varios de un clic sin que el usuario vea que va a congelar. Devuelve un informe POR ESTUDIANTE -- guardadas, actualizadas, sin_proyeccion, sin_cambio, promedio, aprobadas, reprobadas y el detalle en JSONB -- y no un contador. PREESCOLAR NO USA ESTE ENDPOINT: alli no hay nota que congelar y todo saldria sin_proyeccion; lo que se guarda es el resumen de la IA, que es otra funcion. Volver a llamarlo es seguro: lo que no cambio se reporta sin_cambio y no se toca.',
       $q$SELECT * FROM academico_test.fn_informe_periodo_guardar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FK_TGRUPO AS BIGINT),
    CAST(:BODY.FK_TPERIODO_EVALUACION AS BIGINT),
    CAST(:BODY.MATRICULAS AS BIGINT[])
);$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- POST /informes/historial
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT 'eval-col-informes-historial-listar-001', m.id_microservice, '/informes/historial', 'POST', 'postgres', 'SELECT', NULL,
       'false', 'false', 'false', '60', 'informes-historial-listar', 'DEFAULT',
       '{"BODY.ANIO":"INTEGER","BODY.GRUPOS":"BIGINT[]","BODY.LIMITE":"INTEGER","BODY.PERIODOS":"BIGINT[]"}'::jsonb,
       'Historial de guardados del modulo de informes: una fila por guardado, de mas reciente a mas antiguo, con FECHA aparte del MOMENTO para agrupar por dia en el front. Trae grupo, asignatura (NULL = informe completo; con valor = una sola asignatura desde la planilla), periodo, quien lo hizo, cuantos estudiantes y el detalle en JSONB con nombre, documento y promedio de cada uno. El conteo es POR ESTUDIANTE: un estudiante guardado es un cambio, asi que guardar un curso de 30 son 30 cambios. Solo aparecen los dias con movimiento, porque solo se registran guardados que escribieron algo -- volver a pulsar guardar sin cambios no deja entrada. El promedio del detalle es el del momento del guardado y no se recalcula: el historial dice que paso ese dia. Todos los parametros son OPCIONALES: sin nada devuelve el ano lectivo en curso dentro del alcance del usuario, que es lo que hace la pantalla al abrirse; GRUPOS, PERIODOS y ANIO solo acotan, y LIMITE tope por defecto 100 porque el modal es una lista con scroll, no una tabla paginada. No devuelve flecha de subida o bajada: un guardado abarca varios estudiantes y a unos les puede subir la nota y a otros bajarsela.',
       $q$SELECT * FROM academico_test.fn_informe_historial_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.GRUPOS AS BIGINT[]),
    CAST(:BODY.PERIODOS AS BIGINT[]),
    CAST(:BODY.ANIO AS INTEGER),
    CAST(:BODY.LIMITE AS INTEGER)
);$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- POST /informes/jornadas
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT 'eval-col-informes-jornadas-listar-001', m.id_microservice, '/informes/jornadas', 'POST', 'postgres', 'SELECT', NULL,
       'false', 'false', 'false', '60', 'informes-jornadas-listar', 'DEFAULT',
       '{"BODY.ANIO":"INTEGER","BODY.FK_TSEDE":"BIGINT"}'::jsonb,
       'Tercer select de la pantalla de informes: las jornadas con periodo academico activo en esa sede y ese año. Devuelve una fila por PERIODO ACADEMICO, no una por jornada distinta: hoy la tripleta (sede, año, jornada) identifica un solo periodo entre las sedes activas, pero ningun indice lo garantiza y en el historico paso 24 veces, asi que ese caso se ve en pantalla en vez de resolverse en silencio. Cada fila trae FK_TPERIODO_ACADEMICO, por si el front prefiere mandar esa PK directamente en vez de la tripleta. Sin ANIO se toma el año en curso.',
       $q$SELECT * FROM academico_test.fn_informe_jornadas_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FK_TSEDE AS BIGINT),
    CAST(:BODY.ANIO AS INTEGER)
);$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- POST /informes/periodos
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT 'eval-col-informes-periodos-listar-001', m.id_microservice, '/informes/periodos', 'POST', 'postgres', 'SELECT', NULL,
       'false', 'false', 'false', '60', 'informes-periodos-listar', 'DEFAULT',
       '{"BODY.ANIO":"INTEGER","BODY.FK_TSEDE":"BIGINT","BODY.FK_TLV_JORNADA":"BIGINT"}'::jsonb,
       'Los periodos de evaluacion del periodo academico que resuelven la sede, el año y la jornada elegidos en los tres selects de la pantalla (POST /informes/sedes, /informes/anos, /informes/jornadas). Antes devolvia los de todo el año dentro del alcance del usuario -- todas las sedes y jornadas juntas --, que es de donde venia que a un usuario con alcance amplio le salieran muchos y repetidos. FK_TSEDE y FK_TLV_JORNADA son obligatorios; sin ANIO se toma el año en curso. Responde 42501 si el usuario no alcanza esa sede y jornada, y P0002 si no hay periodo academico para esa combinacion -- un error explicito en vez de una lista vacia que se confunde con "no hay nada configurado". Cada fila trae CALIFICABLE, TERMINO y EN_CURSO ya resueltos; TERMINO es la misma condicion con la que la alerta roja decide si una planilla esta pendiente.',
       $q$SELECT * FROM academico_test.fn_informe_periodos_evaluacion_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FK_TSEDE AS BIGINT),
    CAST(:BODY.ANIO AS INTEGER),
    CAST(:BODY.FK_TLV_JORNADA AS BIGINT)
);$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- POST /informes/planilla
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT 'eval-col-informes-planilla-listar-001', m.id_microservice, '/informes/planilla', 'POST', 'postgres', 'SELECT', NULL,
       'false', 'false', 'false', '60', 'informes-planilla-listar', 'DEFAULT',
       '{"BODY.SEARCH":"VARCHAR","BODY.FK_TGRUPO":"BIGINT","BODY.FK_TASIGNATURA":"BIGINT","BODY.FK_TPERIODO_EVALUACION":"BIGINT"}'::jsonb,
       'Planilla de calificacion a la que llevan las dos alertas de informes. Una fila por estudiante del grupo con su definitiva del periodo -- guardada y proyectada, ambas en porcentaje y tambien homologadas a la escala del colegio -- y las actividades del periodo embebidas en ACTIVIDADES (JSONB): una celda por actividad con orden, titulo, estado (CALIFICADA / PENDIENTE / NO_ASIGNADA / NO_CALIFICABLE), porcentaje, nota homologada y el pkTactividadEstudiante que el popover necesita para precargar y guardar. Todas las filas traen las mismas columnas en el mismo orden, incluidas las NO_ASIGNADA, asi que el header se arma con las celdas de cualquier fila y no puede desalinearse del cuerpo. NO es /planeador/planilla/*, que sirve a la planilla del docente y no se toca: esta acota por PERIODO DE EVALUACION, usa la misma proyeccion que detecta los cambios (fn_asignatura_definitiva_proyectada_periodo) y toma su linea base de TASIGNATURA_NOTA, que es donde el modulo consolida -- aquella la toma de TUNIDAD_NOTA, que nadie escribe. Las flechas de subida/bajada las pinta el front comparando las dos definitivas homologadas; no se manda una columna tendencia porque calcularla sobre porcentajes daria flecha cuando dos porcentajes distintos redondean a la misma nota. SEARCH es un solo texto para dos dimensiones: filtra estudiantes por nombre/documento y actividades por titulo, dejando INTACTA la dimension donde nada coincidio -- buscar un nombre filtra filas y conserva columnas, buscar una actividad conserva filas y filtra columnas, y un texto que no coincide con ninguna devuelve vacio. Sin paginacion. Errores: 404 si no existe el grupo, la asignatura o el periodo; 400 si falta grupo o asignatura, o si el periodo no es del periodo academico del grupo; 409 si el grado enviado no es el del grupo.',
       $q$SELECT * FROM academico_test.fn_informe_planilla_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FK_TGRUPO AS BIGINT),
    CAST(:BODY.FK_TASIGNATURA AS BIGINT),
    CAST(:BODY.FK_TPERIODO_EVALUACION AS BIGINT),
    CAST(:BODY.SEARCH AS VARCHAR)
);$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- POST /informes/planilla/guardar
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT 'eval-col-informes-planilla-guardar-001', m.id_microservice, '/informes/planilla/guardar', 'POST', 'postgres', 'SELECT', NULL,
       'false', 'false', 'false', '60', 'informes-planilla-guardar', 'DEFAULT',
       '{"BODY.FK_TGRUPO":"BIGINT","BODY.MATRICULAS":"BIGINT[]","BODY.FK_TASIGNATURA":"BIGINT","BODY.FK_TPERIODO_EVALUACION":"BIGINT"}'::jsonb,
       'Congela la definitiva de UNA asignatura desde la planilla ("Aprobar y actualizar consolidado"). MATRICULAS vacio o ausente = todos los estudiantes del grupo; con lista, solo esos. Devuelve por estudiante el RESULTADO -- guardada / actualizada (con nota_anterior) / sin_cambio / sin_proyeccion -- y ademas el promedio del periodo, aprobadas y reprobadas YA RECALCULADOS, para que la pantalla refresque sin volver a pedir el listado. CONVIVE CON /informes/guardar, que congela todas las asignaturas: no se pisan porque TASIGNATURA_NOTA es por (matricula, periodo, asignatura), y ambos llaman al mismo recalculo de metricas, asi que el promedio del periodo queda coherente sin importar el orden; los dos son idempotentes. Usar este no deja al otro a medias: despues, el guardado completo reporta sin_cambio para esta asignatura y congela el resto. En sin_proyeccion (no hay actividad evaluativa calificada en el periodo) lo ya guardado NO se borra: quitar un consolidado por una ausencia no es decision de un boton de guardar. La nota se guarda en PORCENTAJE, no homologada, porque la escala depende de TCRITERIO_EVALUACION y puede cambiar. Errores: 404 si no existe grupo, asignatura o periodo; 400 si el periodo no es del periodo academico del grupo; 409 si el grado no es el del grupo.',
       $q$SELECT * FROM academico_test.fn_informe_planilla_guardar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FK_TGRUPO AS BIGINT),
    CAST(:BODY.FK_TASIGNATURA AS BIGINT),
    CAST(:BODY.FK_TPERIODO_EVALUACION AS BIGINT),
    CAST(:BODY.MATRICULAS AS BIGINT[])
);$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- POST /informes/planillas-pendientes
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT 'eval-col-informes-planillas-pendientes-001', m.id_microservice, '/informes/planillas-pendientes', 'POST', 'postgres', 'SELECT', NULL,
       'false', 'false', 'false', '60', 'informes-planillas-pendientes', 'DEFAULT',
       '{"BODY.GRUPOS":"BIGINT[]","BODY.PERIODOS":"BIGINT[]"}'::jsonb,
       'Alerta ROJA: planillas sin NADA registrado. Una fila por (grupo, asignatura, periodo) con el docente asignado, cuantos estudiantes tiene el grupo y cuantas actividades existen -- 0 significa que ni siquiera las armo. SOLO considera periodos YA TERMINADOS (FECHA_FIN < hoy): un periodo en curso no puede tener planillas pendientes porque el docente esta dentro de su plazo, y marcarlo llenaria la alerta de rojo el primer dia de cada periodo. Cuenta como calificado cualquier nota U OBSERVACION, para que los docentes de preescolar -- que no ponen numeros sino comentarios por actividad -- no salgan como morosos. Misma firma que la alerta naranja para que el front las trate igual.',
       $q$SELECT * FROM academico_test.fn_informe_planillas_pendientes(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.GRUPOS AS BIGINT[]),
    CAST(:BODY.PERIODOS AS BIGINT[])
);$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- POST /informes/reporte
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT 'eval-col-informes-reporte-001', m.id_microservice, '/informes/reporte', 'POST', 'postgres', 'SELECT', NULL,
       'false', 'false', 'false', '60', 'informes-reporte', 'DEFAULT',
       '{"BODY.FILTERS.SEARCH":"VARCHAR","BODY.FILTERS.PERIODOS":"BIGINT[]","BODY.FILTERS.FK_TGRUPO":"BIGINT","BODY.FILTERS.MATRICULAS":"BIGINT[]"}'::jsonb,
       'EL BOLETIN. Una fila por (estudiante, periodo, asignatura). Lo consume reporting-service bajo la clave "informes" (POST /reportes/informes), no el front directamente. FILTRA: solo sale lo consolidado -- las proyecciones y las notas requeridas quedan fuera, porque impresas se leerian como calificaciones reales. Para bajar la tabla tal como se ve esta POST /informes/tabla. MATRICULAS acota a uno o varios estudiantes, que es lo que es un boletin; vacio o ausente = el grupo entero. EL FINAL SE PIDE CON -1 EN PERIODOS (V439; el bind INCLUIR_FINAL ya no existe), asi que el boletin de solo el Final es PERIODOS [-1]. EVIDENCIAS trae la CUENTA de imagenes de la fila, no las imagenes.',
       $q$SELECT * FROM academico_test.fn_informe_grupo_reporte(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FILTERS.FK_TGRUPO AS BIGINT),
    CAST(:BODY.FILTERS.PERIODOS AS BIGINT[]),
    CAST(:BODY.FILTERS.SEARCH AS VARCHAR),
    CAST(:BODY.FILTERS.MATRICULAS AS BIGINT[])
);$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- POST /informes/sedes
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT 'eval-col-informes-sedes-listar-001', m.id_microservice, '/informes/sedes', 'POST', 'postgres', 'SELECT', NULL,
       'false', 'false', 'false', '60', 'informes-sedes-listar', 'DEFAULT',
       '{}'::jsonb,
       'Primer select de la pantalla de informes: las sedes que el usuario alcanza y que tienen algun periodo academico activo del año en curso o anterior. No recibe parametros -- el alcance sale de quien pregunta, no del cuerpo, para que no se pueda pedir una sede ajena y descubrirla por la respuesta vacia. Devuelve tambien el establecimiento, porque quien alcanza varios necesita distinguir sedes de nombre parecido.',
       $q$SELECT * FROM academico_test.fn_informe_sedes_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;
