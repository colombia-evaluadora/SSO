-- V247 - Primer alta de las filas de instrumento y calificación de
-- /planeador/actividades* y sus roles. PUT :ID/instrumento lo define hoy V496.4
-- y PUT :ID/calificar-bulk/escala V484.


INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT academico_test.fn_actividad_instrumento_definir(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.DEFINICION AS JSONB)
) AS instrumento_aplicado;',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades/:ID/instrumento', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT", "BODY.DEFINICION": "JSONB"}'::jsonb,
    'V247 -- define (reemplazo completo) el instrumento de evaluacion vigente de una actividad: fachada que lee TACTIVIDAD.FK_TLV_INSTRUMENTO_EVALUACION y despacha internamente a fn_actividad_rubrica_definir / _cotejo_definir / _escala_definir / _otro_definir (fn_actividad_instrumento_definir, V226, editada en V240). :ID = PK_TACTIVIDAD. BODY.DEFINICION cambia de forma segun el instrumento vigente de la actividad (consultar antes con GET /planeador/actividades/:ID/configuracion, campos_disponibles.evaluacion.instrumentosPermitidos, o el detalle de la actividad): si es RUBRICA, un array [{nombre, descripcion?, niveles:[{etiqueta?, descripcion, ponderacion}]}]; si es LISTA_COTEJO, un array [{descripcion, ponderacion?}]; si es ESCALA_VALORACION, un objeto {tipoEscala, criteriosGenerales?, interpretacionRangos?, valorMin/valorMax (solo NUMERICA), niveles (solo CUALITATIVA)}; si es OTRO, un objeto {tipoEvidencia, metodoValoracion, definicion} donde metodoValoracion en {RUBRICA,LISTA_COTEJO,ESCALA_VALORACION} y definicion reutiliza el mismo formato del metodo elegido (fn_actividad_otro_definir, V240). SOLO se expone esta ruta generica: las 3 funciones especificas de rubrica/cotejo/escala y fn_actividad_otro_definir NO se registran aparte porque la fachada ya hace todo su trabajo de despacho (decision documentada en la cabecera de esta migracion). Retorna el VALOR del instrumento aplicado. Gate EDITAR sobre PLANEADOR (dentro de la funcion destino). 404 (P0002) si la actividad no existe; 22023 si el instrumento de la actividad no coincide con el esperado o el payload no cumple el formato exigido por ese instrumento.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/actividades/:ID/instrumento'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_actividad_instrumento_obtener(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades/:ID/instrumento', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    'V247 -- lee el instrumento de evaluacion definido para una actividad (fn_actividad_instrumento_obtener, V226, editada en V240). :ID = PK_TACTIVIDAD. Retorna {instrumento (VALOR de TLISTA_VALOR), instrumento_nombre, definicion (JSONB)}: RUBRICA -> [{pk,orden,nombre,descripcion,niveles:[{pk,etiqueta,descripcion,ponderacion}]}] (niveles ordenados por ponderacion DESC); LISTA_COTEJO -> [{pk,orden,descripcion,ponderacion}]; ESCALA_VALORACION -> {pk,tipoEscala,tipoEscalaNombre,tipoEscalaValor,criteriosGenerales,valorMin,valorMax,interpretacionRangos,niveles:[...]}; OTRO -> {pk,tipoEvidencia,tipoEvidenciaNombre,metodoValoracion,metodoValoracionNombre,metodoValoracionValor,definicion} (definicion reutiliza el mismo formato de RUBRICA/LISTA_COTEJO/ESCALA_VALORACION segun el metodo elegido); sin instrumento definido -> definicion NULL. Gate VER sobre PLANEADOR.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/actividades/:ID/instrumento'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT academico_test.fn_actividad_nota_calificar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.CALIFICACION AS JSONB),
    COALESCE(CAST(:BODY.FECHA AS DATE), CURRENT_DATE)
) AS calificacion;',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades/estudiantes/:ID/calificar', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT", "BODY.CALIFICACION": "JSONB", "BODY.FECHA": "DATE"}'::jsonb,
    'V247 -- califica con nota numerica a UN estudiante de una actividad, segun su instrumento vigente (fn_actividad_nota_calificar, V227, editada en V241 -- OTRO estructurado -- y V243 -- rechazo de FORMATIVAS). :ID = PK_TACTIVIDAD_ESTUDIANTE (NO PK_TACTIVIDAD). BODY.CALIFICACION cambia de forma segun el instrumento: RUBRICA -> {niveles:[{pkCriterio,pkNivel}]} (debe cubrir TODOS los criterios activos, ni de mas ni de menos); LISTA_COTEJO -> {itemsMarcados:[pk,...]} (PKs de TACTIVIDAD_COTEJO_ITEM cumplidos); ESCALA_VALORACION -> {pkNivel} (CUALITATIVA) o {valorNumerico} (NUMERICA), exactamente uno segun el tipo de la escala; OTRO -> {porcentaje} si no tiene metodo de valoracion configurado (V240), o el mismo payload del metodo equivalente si si lo tiene. BODY.FECHA opcional (default hoy): el "dia de clase" contra el que se valida asistencia (bloquea si no hay asistencia registrada esa fecha o es una inasistencia injustificada) y, si aplica, el tope de recuperacion / piso institucional (TCRITERIO_EVALUACION). Guarda el % (0-100) en TACTIVIDAD_NOTA.CALIFICACION. RECHAZA (22023) de entrada cualquier actividad de referente FORMATIVO (preescolar) -- usar PUT .../observar / POST .../observar-grupal (V246) en ese caso. Gate EDITAR sobre PLANEADOR. 404 (P0002) si la asignacion actividad-estudiante no existe; 22023 si falta asistencia, el payload no calza con el instrumento, o (RUBRICA) faltan/sobran criterios.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/actividades/estudiantes/:ID/calificar'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_actividad_nota_calificar_rubrica_bulk(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.PK_CRITERIO AS BIGINT),
    CAST(:BODY.PK_NIVEL AS BIGINT),
    CAST(:BODY.ESTUDIANTES AS BIGINT[]),
    COALESCE(CAST(:BODY.FECHA AS DATE), CURRENT_DATE)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades/:ID/calificar-bulk/rubrica', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT", "BODY.PK_CRITERIO": "BIGINT", "BODY.PK_NIVEL": "BIGINT", "BODY.ESTUDIANTES": "BIGINT[]", "BODY.FECHA": "DATE"}'::jsonb,
    'V247 -- calificacion BULK por rubrica: aplica UN criterio + UN nivel de desempeno a VARIOS estudiantes de la misma actividad de una sola pasada (fn_actividad_nota_calificar_rubrica_bulk, V227) -- el flujo real de la pantalla "Planilla" cuando el docente elige la columna "Criterio: Nivel" y la aplica a los estudiantes marcados. :ID = PK_TACTIVIDAD. BODY.PK_CRITERIO/PK_NIVEL deben pertenecer a la rubrica de esta actividad; BODY.ESTUDIANTES (obligatorio, >=1) = PKs de TACTIVIDAD_ESTUDIANTE, cada uno debe pertenecer a esta actividad y tener asistencia valida en BODY.FECHA (default hoy). Hace upsert de UNA sola fila por estudiante (la de ese criterio): NO toca los demas criterios ya capturados (a diferencia de PUT .../calificar, que exige el set completo). Devuelve una fila por estudiante {pk_tactividad_estudiante, criterios_totales, criterios_cubiertos, calificacion, calificacion_actualizada}: calificacion_actualizada=true significa que ese estudiante ya cubrio todos los criterios y se guardo/recalculo la nota (TACTIVIDAD_NOTA.CALIFICACION); false es informativo (faltan criterios), no un error. Gate EDITAR sobre PLANEADOR. 22023 si la actividad no tiene instrumento RUBRICA, el criterio/nivel no pertenecen a esta rubrica, o algun estudiante no pertenece a la actividad o no tiene asistencia valida esa fecha.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/actividades/:ID/calificar-bulk/rubrica'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_actividad_nota_calificar_cotejo_bulk(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.PK_ITEM AS BIGINT),
    CAST(:BODY.CUMPLIDO AS CHAR(1)),
    CAST(:BODY.ESTUDIANTES AS BIGINT[]),
    COALESCE(CAST(:BODY.FECHA AS DATE), CURRENT_DATE)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades/:ID/calificar-bulk/cotejo', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT", "BODY.PK_ITEM": "BIGINT", "BODY.CUMPLIDO": "VARCHAR", "BODY.ESTUDIANTES": "BIGINT[]", "BODY.FECHA": "DATE"}'::jsonb,
    'V247 -- calificacion BULK por lista de cotejo: marca UN item como cumplido (BODY.CUMPLIDO=''S'') o no cumplido (''N'') para VARIOS estudiantes de la misma actividad de una sola pasada (fn_actividad_nota_calificar_cotejo_bulk, V227) -- el flujo real de la pantalla cuando el docente recorre la lista item por item. :ID = PK_TACTIVIDAD. BODY.PK_ITEM debe pertenecer a la lista de cotejo de esta actividad; BODY.CUMPLIDO obligatorio, en {S,N}; BODY.ESTUDIANTES (obligatorio, >=1) = PKs de TACTIVIDAD_ESTUDIANTE, cada uno debe pertenecer a esta actividad y tener asistencia valida en BODY.FECHA (default hoy). Hace upsert de UNA sola fila por estudiante (la de ese item): NO toca los demas items ya capturados. A diferencia del bulk de rubrica, SIEMPRE recalcula y guarda TACTIVIDAD_NOTA.CALIFICACION en la misma pasada (un item sin captura cuenta como no cumplido por diseño, no hay "incompleto"). Devuelve una fila por estudiante {pk_tactividad_estudiante, items_totales, items_cumplidos, calificacion}. Gate EDITAR sobre PLANEADOR. 22023 si la actividad no tiene instrumento LISTA_COTEJO, el item no pertenece a esta lista, CUMPLIDO invalido, o algun estudiante no pertenece a la actividad o no tiene asistencia valida esa fecha.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/actividades/:ID/calificar-bulk/cotejo'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_actividad_nota_calificar_escala_bulk(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.PK_NIVEL AS BIGINT),
    CAST(:BODY.VALOR_NUMERICO AS NUMERIC),
    CAST(:BODY.ESTUDIANTES AS BIGINT[]),
    COALESCE(CAST(:BODY.FECHA AS DATE), CURRENT_DATE)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades/:ID/calificar-bulk/escala', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT", "BODY.PK_NIVEL": "BIGINT", "BODY.VALOR_NUMERICO": "NUMERIC", "BODY.ESTUDIANTES": "BIGINT[]", "BODY.FECHA": "DATE"}'::jsonb,
    'V247 -- calificacion BULK por escala de valoracion: aplica UN mismo valor a VARIOS estudiantes de la misma actividad de una sola pasada (fn_actividad_nota_calificar_escala_bulk, V227). Sirve los DOS tipos de escala y hay que mandar EXACTAMENTE UNO de los dos campos, el que corresponda al tipo de escala de la actividad: BODY.PK_NIVEL si es CUALITATIVA (un nivel de la escala de esta actividad), BODY.VALOR_NUMERICO si es NUMERICA (un numero dentro de [VALOR_MIN, VALOR_MAX] de la escala) -- es el caso del "Valor (1-5)" que la pantalla de calificacion masiva de la Planilla aplica a los estudiantes marcados. :ID = PK_TACTIVIDAD. BODY.ESTUDIANTES (obligatorio, >=1) = PKs de TACTIVIDAD_ESTUDIANTE, cada uno debe pertenecer a esta actividad y tener asistencia valida en BODY.FECHA (default hoy). Devuelve una fila por estudiante {pk_tactividad_estudiante, calificacion} con el porcentaje 0-100 resultante. Gate EDITAR sobre PLANEADOR. 22023 si la actividad no tiene instrumento ESCALA_VALORACION, si vienen los dos campos o ninguno, si el campo enviado no corresponde al tipo de escala, si el nivel no pertenece a ella o el valor cae fuera del rango, o si algun estudiante no pertenece a la actividad o no tiene asistencia valida esa fecha.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/actividades/:ID/calificar-bulk/escala'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_actividad_nota_obtener(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades/estudiantes/:ID/nota', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    'V247 -- detalle de la calificacion de UN estudiante en una actividad (fn_actividad_nota_obtener, V227, editada en V241 -- OTRO estructurado). :ID = PK_TACTIVIDAD_ESTUDIANTE (NO PK_TACTIVIDAD). Retorna {instrumento, calificacion (% 0-100 o NULL si aun no hay nota), calificable (S/N), observacion (texto libre de fn_actividad_observar_*, V246, o NULL), detalle (JSONB con la captura cruda segun instrumento: RUBRICA -> [{pkCriterio,pkNivel,ponderacion}]; LISTA_COTEJO -> [{pkItem,cumplido}]; ESCALA_VALORACION -> {pkNivel,valor,ponderacion}; OTRO con metodo configurado -> el mismo formato del metodo equivalente)}. Distinta de GET /planeador/actividades/:ID/calificaciones (V247, punto 8), que es la TABLA completa de todos los estudiantes de la actividad. Gate VER sobre PLANEADOR. 404 (P0002) si la asignacion actividad-estudiante no existe.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/actividades/estudiantes/:ID/nota'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_actividad_estudiantes_calificaciones_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    COALESCE(CAST(:QUERY.FECHA AS DATE), CURRENT_DATE),
    CAST(:QUERY.SEARCH AS VARCHAR)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades/:ID/calificaciones', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT", "QUERY.FECHA": "DATE", "QUERY.SEARCH": "VARCHAR"}'::jsonb,
    'V247 -- tabla completa de la pantalla "Calificaciones: <actividad>": una fila por cada estudiante ACTIVO asignado a la actividad, con su asistencia de ?fecha= (default hoy) y su nota (fn_actividad_estudiantes_calificaciones_listar, V227). :ID = PK_TACTIVIDAD. Cada fila = {pk_tactividad_estudiante, pk_tmatricula, nombre_estudiante, instrumento (repetido por fila, evita una segunda consulta), fecha, pk_tasistencia, fk_tlv_tipo_asistencia, tipo_asistencia, asistencia_observacion, fk_soporte_archivo (todos NULL si no hay asistencia registrada esa fecha -- no es un error), calificacion, calificable, nota_observacion}. ?search= filtra por nombre (ILIKE simple). Sin paginacion (universo acotado a una actividad, normalmente un grupo). Ordena por nombre. Distinta de GET /planeador/actividades/estudiantes/:ID/nota (V247, punto 7), que es el detalle de captura completo de UN estudiante. Gate VER sobre PLANEADOR. 404 (P0002) si la actividad no existe.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/actividades/:ID/calificaciones'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;
