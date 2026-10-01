-- V492.4 — Planeador, unidad: endpoints (/planeador/unidades*) y sus roles.
--
-- Qué hace: única definición de las 24 filas de public.query de unidades
-- (antes repartidas entre V227, V245, V246, V255, V279, V281, V282, V406,
-- V455, V488, V492 y V496) y de sus role_query (antes en V245, V249, V284,
-- V305 y V406). Upsert por (microservicio, ruta, método): una fila que ya
-- existe conserva su id, y con él los role_query que ya tenga.
-- POST/PUT aceptan CONTENIDOS_TITULOS opcional (§4); el PUT añade
-- actividades_afectadas (Regla 28) sin cambiar la clave fn_unidad_actualizar.
-- Depende de: V492.3 (funciones de endpoint), V488 (listar/buscar), V480,
-- V244/V223 (actividades), V281/V407 (tabs), V496 (configuración de actividad).

SET search_path TO academico_test, public;

-- GET /planeador/unidades
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT 'ca56c0db-a7a4-4af0-abfa-66101f171ef4', m.id_microservice, '/planeador/unidades', 'GET', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL, '{"QUERY.DIA": "DATE", "QUERY.SIZE": "INT", "QUERY.GRADO": "BIGINT", "QUERY.OFFSET": "INT", "QUERY.SEARCH": "VARCHAR", "QUERY.ORDEN_ASC": "BOOLEAN", "QUERY.ORDEN_POR": "VARCHAR", "QUERY.ASIGNATURA": "BIGINT", "QUERY.DIAS_GRACIA": "INT", "QUERY.FUNCIONARIO": "BIGINT", "QUERY.INCLUIR_INACTIVOS": "BOOLEAN"}'::jsonb,
       'V245 -- pagina de unidades (fn_unidad_listar, V216). Devuelve estado: el estado DERIVADO de la unidad, agregando el de sus actividades -- UNA sola VENCIDA marca la unidad como VENCIDA; si no hay vencidas pero si alguna PENDIENTE_POR_EVALUAR, PENDIENTE_POR_EVALUAR; si TODAS estan finalizadas, FINALIZADA; en cualquier otro caso EN_EVALUACION (incluida la unidad sin actividades, que se reconoce por total_actividades = 0). Son los mismos cuatro valores del estado de actividad, asi que el chip se pinta con la misma paleta; ?DIAS_GRACIA= (default 2) ajusta el umbral de VENCIDA. PAGINADO POR DIA ACTIVO ?dia=YYYY-MM-DD (la barra "Hoy | MARTES 16 | < >"): deja solo las unidades con ALGUNA actividad activa VIGENTE ese dia -- vigente = la ventana [fechaInicio, fechaCierre] CUBRE el dia, no que empiece o cierre en el; una actividad de tres dias aparece en los tres. La respuesta trae dia, dia_anterior y dia_siguiente para las flechas: el dia ocupado mas cercano a cada lado bajo los MISMOS filtros, SALTANDO los dias vacios (no es dia-1/dia+1 a ciegas), y NULL cuando no hay mas dias por ese lado -- con eso se deshabilita la flecha. Sin ?dia= el listado es el de siempre y esas tres columnas vienen NULL. Filtros ?search=, ?asignatura=, ?grado=, ?funcionario=, ?INCLUIR_INACTIVOS= (default false) y orden ?ORDEN_POR= (whitelist nombre|asignatura|grado, cualquier otro cae a nombre) / ?ORDEN_ASC= (default true). Paginacion system-bound ?size=/?offset= (default 20/0). Devuelve nombres resueltos (asignatura, area, grado, docente, forma de calculo, referente curricular), conteos (actividades/objetivos/contenidos activos), fechas DERIVADAS y total_count via COUNT(*) OVER(). Gate VER sobre PLANEADOR.',
       'SELECT * FROM academico_test.fn_unidad_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.SEARCH AS VARCHAR),
    CAST(:QUERY.ASIGNATURA AS BIGINT),
    CAST(:QUERY.GRADO AS BIGINT),
    CAST(:QUERY.FUNCIONARIO AS BIGINT),
    COALESCE(CAST(:QUERY.INCLUIR_INACTIVOS AS BOOLEAN), FALSE),
    COALESCE(CAST(:QUERY.ORDEN_POR AS VARCHAR), ''nombre''),
    COALESCE(CAST(:QUERY.ORDEN_ASC AS BOOLEAN), TRUE),
    COALESCE(CAST(:QUERY.SIZE AS INT), 20),
    COALESCE(CAST(:QUERY.OFFSET AS INT), 0),
    CAST(:QUERY.DIA AS DATE),
    COALESCE(CAST(:QUERY.DIAS_GRACIA AS INT), 2)
);'
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- POST /planeador/unidades
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT '1092ae72-15f3-4173-80b0-e2370de302e4', m.id_microservice, '/planeador/unidades', 'POST', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL, '{"BODY.NOMBRE": "VARCHAR", "BODY.FK_TGRADO": "BIGINT", "BODY.OBJETIVOS": "TEXT[]", "BODY.CONTENIDOS": "TEXT[]", "BODY.CONTENIDOS_TITULOS": "TEXT[]", "BODY.ENUNCIADOS": "BIGINT[]", "BODY.DESCRIPCION": "VARCHAR", "BODY.PONDERACION": "NUMERIC", "BODY.FK_TASIGNATURA": "BIGINT", "BODY.FK_TFUNCIONARIO": "BIGINT", "BODY.FK_REFERENTE_CURRICULAR": "BIGINT", "BODY.FK_TLV_CALCULO_DEFINITIVA": "BIGINT"}'::jsonb,
       'Crea una unidad temática del Planeador (fn_unidad_crear). Obligatorios: NOMBRE, FK_TASIGNATURA, FK_TGRADO y FK_TLV_CALCULO_DEFINITIVA salvo que el referente del grado sea de enfoque Formativo (Regla 19). FK_TFUNCIONARIO se deriva del usuario si no llega. Opcionales: DESCRIPCION, FK_REFERENTE_CURRICULAR, OBJETIVOS, CONTENIDOS (ningún elemento vacío) y CONTENIDOS_TITULOS (§4: si llega, un título no vacío de máx. 200 por contenido, en la misma posición; si no llega, los contenidos quedan sin título, como antes), ENUNCIADOS, PONDERACION. El referente debe cubrir el nivel y el grado (Regla 12). Retorna PK_TUNIDAD. Gate: alcance CREAR sobre el grado.',
       'SELECT * FROM academico_test.fn_unidad_crear(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.NOMBRE AS VARCHAR),
    CAST(:BODY.FK_TASIGNATURA AS BIGINT),
    CAST(:BODY.FK_TGRADO AS BIGINT),
    CAST(:BODY.FK_TFUNCIONARIO AS BIGINT),
    CAST(:BODY.FK_TLV_CALCULO_DEFINITIVA AS BIGINT),
    CAST(:BODY.DESCRIPCION AS VARCHAR),
    CAST(:BODY.FK_REFERENTE_CURRICULAR AS BIGINT),
    CAST(:BODY.OBJETIVOS AS VARCHAR[]),
    CAST(:BODY.CONTENIDOS AS VARCHAR[]),
    CAST(:BODY.ENUNCIADOS AS BIGINT[]),
    CAST(:BODY.PONDERACION AS NUMERIC),
    CAST(:BODY.CONTENIDOS_TITULOS AS VARCHAR[])
);'
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- GET /planeador/unidades/:ID
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT '4f8c7792-540b-481c-9148-63c54b692255', m.id_microservice, '/planeador/unidades/:ID', 'GET', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL, '{"PARAM.ID": "BIGINT"}'::jsonb,
       'V245 -- detalle de una unidad (fn_unidad_buscar_por_pk, V216): escalares + nombres resueltos (asignatura, area, grado, docente, forma de calculo, referente curricular), Inicio/Fin DERIVADOS (MIN/MAX de fechas de sus actividades activas), objetivos/contenidos como JSONB ordenados, campos_disponibles (dependencia referente->rubrica, V214.2) y active. :ID = PK_TUNIDAD. SETOF 0 o 1 fila (incluye inactivas). Gate VER sobre PLANEADOR.',
       'SELECT * FROM academico_test.fn_unidad_buscar_por_pk(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
);'
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- PATCH /planeador/unidades/:ID
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT '78b784ca-d168-48c1-b928-3ce180da0933', m.id_microservice, '/planeador/unidades/:ID', 'PATCH', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL, '{"PARAM.ID": "BIGINT"}'::jsonb,
       'Baja lógica de una unidad (fn_unidad_eliminar): la unidad, su rúbrica (niveles, criterios), objetivos, contenidos y enunciados. :ID = PK_TUNIDAD. Regla 27: se rechaza (23503) si otros docentes tienen actividades o criterios propios en ella (se cede en lugar de eliminarla); las actividades del dueño se desvinculan y siguen vivas. Gate: alcance ELIMINAR + propietario. 404 (P0002) si la unidad no existe.',
       'SELECT * FROM academico_test.fn_unidad_eliminar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
);'
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- PUT /planeador/unidades/:ID
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT 'd017297c-7254-4463-8e68-967f45df05eb', m.id_microservice, '/planeador/unidades/:ID', 'PUT', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL, '{"PARAM.ID": "BIGINT", "BODY.NOMBRE": "VARCHAR", "BODY.FK_TGRADO": "BIGINT", "BODY.OBJETIVOS": "TEXT[]", "BODY.CONTENIDOS": "TEXT[]", "BODY.CONTENIDOS_TITULOS": "TEXT[]", "BODY.ENUNCIADOS": "BIGINT[]", "BODY.DESCRIPCION": "VARCHAR", "BODY.PONDERACION": "NUMERIC", "BODY.FK_TASIGNATURA": "BIGINT", "BODY.FK_TFUNCIONARIO": "BIGINT", "BODY.LIMPIAR_REFERENTE": "BOOLEAN", "BODY.LIMPIAR_PONDERACION": "BOOLEAN", "BODY.FK_REFERENTE_CURRICULAR": "BIGINT", "BODY.FK_TLV_CALCULO_DEFINITIVA": "BIGINT"}'::jsonb,
       'PATCH parcial de una unidad (fn_unidad_actualizar). Campo ausente/NULL = no tocar; OBJETIVOS/CONTENIDOS son reemplazo completo y CONTENIDOS_TITULOS acompaña a CONTENIDOS (§4: si llega, uno no vacío de máx. 200 por contenido; si no llega, los contenidos se guardan sin título). LIMPIAR_REFERENTE / LIMPIAR_PONDERACION fuerzan NULL. Cambiar FK_TFUNCIONARIO cede la unidad: el nuevo dueño debe tener actividades o criterios propios en ella o dictar la asignatura en su grado (Regla 27). Responde la clave fn_unidad_actualizar con el PK_TUNIDAD y actividades_afectadas [{pk, titulo}]: las actividades cuyo peso o puntaje se convirtió por un cambio de criterio de cálculo, [] si no cambió (Regla 28). Gate: alcance EDITAR + propietario de la unidad.',
       'SELECT r.pk_tunidad AS fn_unidad_actualizar, r.actividades_afectadas
  FROM academico_test.fn_unidad_actualizar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.NOMBRE AS VARCHAR),
    CAST(:BODY.DESCRIPCION AS VARCHAR),
    CAST(:BODY.FK_TASIGNATURA AS BIGINT),
    CAST(:BODY.FK_TGRADO AS BIGINT),
    CAST(:BODY.FK_TFUNCIONARIO AS BIGINT),
    CAST(:BODY.FK_TLV_CALCULO_DEFINITIVA AS BIGINT),
    CAST(:BODY.FK_REFERENTE_CURRICULAR AS BIGINT),
    COALESCE(CAST(:BODY.LIMPIAR_REFERENTE AS BOOLEAN), FALSE),
    CAST(:BODY.OBJETIVOS AS VARCHAR[]),
    CAST(:BODY.CONTENIDOS AS VARCHAR[]),
    CAST(:BODY.PONDERACION AS NUMERIC),
    COALESCE(CAST(:BODY.LIMPIAR_PONDERACION AS BOOLEAN), FALSE),
    CAST(:BODY.ENUNCIADOS AS BIGINT[]),
    CAST(:BODY.CONTENIDOS_TITULOS AS VARCHAR[])
) r;'
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- GET /planeador/unidades/:ID/actividades
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT 'f07d2353-007f-47b7-96b1-fd8c6f3b6828', m.id_microservice, '/planeador/unidades/:ID/actividades', 'GET', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL, '{"PARAM.ID": "BIGINT", "QUERY.SIZE": "INT", "QUERY.GRUPO": "BIGINT", "QUERY.OFFSET": "INT", "QUERY.SEARCH": "VARCHAR", "QUERY.ORDEN_ASC": "BOOLEAN", "QUERY.ORDEN_POR": "VARCHAR", "QUERY.INCLUIR_INACTIVAS": "BOOLEAN"}'::jsonb,
       'V245 -- actividades vinculadas a una unidad (fn_unidad_actividades_listar, V216) con su PONDERACION (%, TACTIVIDAD.PONDERACION, V223 -- la columna "(%)" de la pantalla; distinta de INFLUENCIA que tambien se devuelve por compatibilidad). :ID = PK_TUNIDAD. Filtros ?search= (TITULO), ?grupo=, ?INCLUIR_INACTIVAS= (default false). Orden ?ORDEN_POR= en {actividad,tipo,instrumento,grupo,porcentaje} / ?ORDEN_ASC=. Paginacion ?size=(default 50)/?offset=. total_count via COUNT(*) OVER(). Gate VER sobre PLANEADOR; a un docente de aula solo le lista las actividades que creó (Regla 25c). 404 (P0002) si la unidad no existe.',
       'SELECT * FROM academico_test.fn_unidad_actividades_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:QUERY.SEARCH AS VARCHAR),
    CAST(:QUERY.GRUPO AS BIGINT),
    COALESCE(CAST(:QUERY.INCLUIR_INACTIVAS AS BOOLEAN), FALSE),
    COALESCE(CAST(:QUERY.ORDEN_POR AS VARCHAR), ''actividad''),
    COALESCE(CAST(:QUERY.ORDEN_ASC AS BOOLEAN), TRUE),
    COALESCE(CAST(:QUERY.SIZE AS INT), 50),
    COALESCE(CAST(:QUERY.OFFSET AS INT), 0)
);'
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- GET /planeador/unidades/:ID/actividades-disponibles
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT 'db574702-3f4c-41ea-ad12-dd801e68979c', m.id_microservice, '/planeador/unidades/:ID/actividades-disponibles', 'GET', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL, '{"PARAM.ID": "BIGINT", "QUERY.SIZE": "INT", "QUERY.PAGINA": "INT", "QUERY.SEARCH": "VARCHAR"}'::jsonb,
       'V246 -- actividades candidatas a vincularse a la unidad :ID (modal "Vincular actividad"; fn_actividad_disponibles_listar, V223). :ID = PK_TUNIDAD. Candidata = ACTIVE, sin unidad (FK_TUNIDAD IS NULL), misma asignatura que la unidad, y mismo grado via el grupo de la actividad (sin grupo tambien es candidata). ?search= (trigram TITULO+DESCRIPCION). Devuelve tipo/instrumento resueltos, grupo y porcentaje_disponible = fn_unidad_ponderacion_disponible(unidad, grupo de esa fila) para pintar "Disponible para asignar: X%". Paginacion ?pagina= (default 1) / ?size= (default 20). total_count via COUNT(*) OVER(). Gate VER sobre PLANEADOR. 404 (P0002) si la unidad no existe.',
       'SELECT * FROM academico_test.fn_actividad_disponibles_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:QUERY.SEARCH AS VARCHAR),
    COALESCE(CAST(:QUERY.PAGINA AS INT), 1),
    COALESCE(CAST(:QUERY.SIZE AS INT), 20)
);'
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- PUT /planeador/unidades/:ID/actividades/:ACTIVIDADID
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT '6969c674-9f7e-4ceb-9388-3a92c3bc614e', m.id_microservice, '/planeador/unidades/:ID/actividades/:ACTIVIDADID', 'PUT', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL, '{"PARAM.ID": "BIGINT", "BODY.PONDERACION": "NUMERIC", "PARAM.ACTIVIDADID": "BIGINT", "BODY.PERMITIR_MOVER_DE_UNIDAD": "BOOLEAN"}'::jsonb,
       'V245 -- vincula una actividad a una unidad y fija su PONDERACION (%) dentro de ella (fn_unidad_actividad_vincular, V223, editada en V244). :ID = PK_TUNIDAD destino, :ACTIVIDADID = PK_TACTIVIDAD. BODY.PONDERACION NULL = no cambiar el peso actual; se rechaza (22023) si la unidad Promedia o calcula por Sumatoria (en Sumatoria el % se autocalcula desde NOTA_MAXIMA). BODY.PERMITIR_MOVER_DE_UNIDAD=true (default false) es OBLIGATORIO si la actividad YA estaba vinculada a OTRA unidad (fix V244: evita mover de unidad en silencio); vincular una huerfana (sin unidad previa) no lo requiere. Valida la regla del 100% por (unidad,grupo). Retorna PK_TACTIVIDAD. Gate EDITAR sobre PLANEADOR.',
       'SELECT * FROM academico_test.fn_unidad_actividad_vincular(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ACTIVIDADID AS BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.PONDERACION AS NUMERIC),
    COALESCE(CAST(:BODY.PERMITIR_MOVER_DE_UNIDAD AS BOOLEAN), FALSE)
);'
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- GET /planeador/unidades/:ID/configuracion-actividad
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT '95cbf99b-4ad8-4baa-898f-473528465a82', m.id_microservice, '/planeador/unidades/:ID/configuracion-actividad', 'GET', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL, '{"PARAM.ID": "BIGINT", "QUERY.GRUPO": "BIGINT", "QUERY.RECUPERAR": "VARCHAR", "QUERY.ES_SUMATIVO": "VARCHAR", "QUERY.ACTIVIDAD_RECUPERAR": "BIGINT"}'::jsonb,
       'Que pintar en el formulario de NUEVA ACTIVIDAD para la unidad escogida, antes de crearla. :ID = PK_TUNIDAD. Responde lo MISMO que GET /planeador/actividades/configuracion?grupo=&asignatura=&unidad= (mismo nucleo, la asignatura sale de la unidad): programacion {periodoAcademico, intensidadHoraria {bloquesPorSemana, minutosPorBloque, minutosPorSemana, diasHabiles, horario:[{valor, nombre, bloques:[{numero, horaInicio, horaFin, minutos}]}]}, fechaInicio/fechaCierre {min, max, diasHabiles}, semanaCronograma {min, max}, duracionEstimada {min, max, unidad: MINUTOS, paso}}, contexto (fkTgrupo, grupo, fkTgrado, grado, nivelEnsenanza, fkTasignatura, asignatura, pkTunidad, referente {pk, nombre}), esSumativoConsultado, esFormativo, esSumativoSugerido y campos_disponibles {criterio, evaluacion, ponderacion, recuperacion}; ademas unidad (nombre) y origenGrupo. La unidad es de un GRADO y el horario de un GRUPO: ?grupo= (opcional) tiene que ser del grado de la unidad (422 si no); sin el se usa el unico grupo activo del grado (origenGrupo = UNICO_DEL_GRADO) y si hay varios origenGrupo = NULL y programacion viene con sus limites NULL y el motivo "Falta el grupo": el front debe pedir el grupo y volver a consultar. ?ES_SUMATIVO=S|N (default S): con N solo se apagan recuperacion y ponderacion. ?RECUPERAR=S lista en recuperacion.actividadesRecuperables las sumativas del (grupo, asignatura); ?ACTIVIDAD_RECUPERAR= devuelve recuperacion.origen con sus estudiantes. El front decide por VALOR: los pk no son estables entre entornos. Gate VER sobre PLANEADOR + alcance por la unidad; 404 (P0002) si la unidad o el grupo no existen o estan inactivos.',
       'SELECT academico_test.fn_unidad_configuracion_actividad(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    COALESCE(CAST(:QUERY.ES_SUMATIVO AS VARCHAR), ''S''),
    CAST(:QUERY.GRUPO AS BIGINT),
    COALESCE(CAST(:QUERY.RECUPERAR AS VARCHAR), ''N''),
    CAST(:QUERY.ACTIVIDAD_RECUPERAR AS BIGINT)
) AS configuracion;'
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- GET /planeador/unidades/:ID/contenidos
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT 'af761b1a-7192-4001-bf39-3123227fadde', m.id_microservice, '/planeador/unidades/:ID/contenidos', 'GET', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL, '{"PARAM.ID": "BIGINT"}'::jsonb,
       'V245 -- contenidos/componentes ACTIVE de una unidad (TUNIDAD_CONTENIDO), ordenados por ORDEN (fn_unidad_contenidos_listar, V216). :ID = PK_TUNIDAD. Columnas pk_tunidad_contenido, orden, descripcion y titulo (§4, título de sección; NULL si no lo tiene), en ese orden. Gate VER sobre PLANEADOR.',
       'SELECT * FROM academico_test.fn_unidad_contenidos_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
);'
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- GET /planeador/unidades/:ID/criterios
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT '4e8ca5d8-83f0-42e3-8065-cd0735dd43ee', m.id_microservice, '/planeador/unidades/:ID/criterios', 'GET', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL, '{"PARAM.ID": "BIGINT", "QUERY.INCLUIR_INACTIVOS": "BOOLEAN"}'::jsonb,
       'V245 -- criterios de la rubrica de la unidad (TCRITERIO_UNIDAD), ordenados por ORDEN, con sus niveles (TNIVEL_CRITERIO_UNIDAD) agregados en JSONB ordenado por la valoracion de la escala: [{pk,fkTescalaValoracion,valoracion,orden,indicador,recomendacion,tarea}] (fn_unidad_criterio_listar, V222). :ID = PK_TUNIDAD. ?INCLUIR_INACTIVOS= (default false). Gate VER sobre PLANEADOR. 404 (P0002) si la unidad no existe.',
       'SELECT * FROM academico_test.fn_unidad_criterio_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    COALESCE(CAST(:QUERY.INCLUIR_INACTIVOS AS BOOLEAN), FALSE)
);'
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- POST /planeador/unidades/:ID/criterios
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT 'a01194f1-45a4-4a0a-9035-d54ff72b26b3', m.id_microservice, '/planeador/unidades/:ID/criterios', 'POST', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL, '{"PARAM.ID": "BIGINT", "BODY.CODIGO": "VARCHAR", "BODY.NIVELES": "JSONB", "BODY.PUBLICO": "VARCHAR", "BODY.DESCRIPCION": "VARCHAR", "BODY.DESCRIPTOR_PROM": "VARCHAR"}'::jsonb,
       'V245/V455 -- agrega un criterio a la rubrica de la unidad (fn_unidad_criterio_agregar). :ID = PK_TUNIDAD. BODY.NIVELES = [{"fkTescalaValoracion":N,"indicador":"..","recomendacion":"?","tarea":"?"}], obligatorio EXACTAMENTE un elemento por cada valoracion activa de la escala que aplica a la unidad -- la misma que devuelve GET /planeador/unidades/:ID/valoraciones (fn_unidad_escala_aplicable: criterio vigente de (asignatura, grado) -> criterio del periodo del grado -> escala del nivel de ensenanza, "cada nivel tendra su escala"). BODY.PUBLICO en {S,N} (default S), BODY.DESCRIPTOR_PROM en {S,N} (default N). Retorna PK_TCRITERIO_UNIDAD. Gate EDITAR sobre PLANEADOR. 22023 si no hay escala aplicable o el payload no calza exacto con las valoraciones.',
       'SELECT * FROM academico_test.fn_unidad_criterio_agregar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.DESCRIPCION AS VARCHAR),
    CAST(:BODY.NIVELES AS JSONB),
    COALESCE(CAST(:BODY.PUBLICO AS VARCHAR), ''S''),
    CAST(:BODY.CODIGO AS VARCHAR),
    COALESCE(CAST(:BODY.DESCRIPTOR_PROM AS VARCHAR), ''N'')
);'
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- POST /planeador/unidades/:ID/enunciados
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT '92cf1178-cc25-4856-bb33-5653441a9ee6', m.id_microservice, '/planeador/unidades/:ID/enunciados', 'POST', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL, '{"PARAM.ID": "BIGINT", "BODY.FK_REFERENTE_ENUNCIADO": "BIGINT"}'::jsonb,
       'V245 -- relaciona (o reactiva) un enunciado del referente curricular (TREFERENTE_ENUNCIADO nivel 1) con la unidad (fn_unidad_enunciado_relacionar, V214.1). :ID = PK_TUNIDAD (FK_TUNIDAD de la relacion). Valida que el enunciado sea nivel 1 (FK_PADRE IS NULL) y comparta el mismo nivel de ensenanza que la unidad (via TGRADO.FK_TNIVEL_ENSENANZA). Retorna PK_TUNIDAD_ENUNCIADO. Gate EDITAR sobre PLANEADOR. 23503 si la unidad o el enunciado no existen/no estan activos; 22023 si el enunciado es una evidencia (nivel 2) o el nivel de ensenanza no coincide.',
       'SELECT * FROM academico_test.fn_unidad_enunciado_relacionar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.FK_REFERENTE_ENUNCIADO AS BIGINT)
);'
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- GET /planeador/unidades/:ID/objetivos
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT '3844a4d3-a385-42dc-b54b-954017c397cb', m.id_microservice, '/planeador/unidades/:ID/objetivos', 'GET', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL, '{"PARAM.ID": "BIGINT"}'::jsonb,
       'V245 -- objetivos ACTIVE de una unidad (TUNIDAD_OBJETIVO), ordenados por ORDEN (fn_unidad_objetivos_listar, V216). :ID = PK_TUNIDAD. Gate VER sobre PLANEADOR.',
       'SELECT * FROM academico_test.fn_unidad_objetivos_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
);'
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- GET /planeador/unidades/:ID/ponderacion-disponible
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT '855b1f63-6393-452f-874c-d00e22d1b977', m.id_microservice, '/planeador/unidades/:ID/ponderacion-disponible', 'GET', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL, '{"PARAM.ID": "BIGINT", "QUERY.GRUPO": "BIGINT"}'::jsonb,
       'V245 -- porcentaje LIBRE para repartir en una (unidad, grupo): 100 - fn_unidad_ponderacion_asignada (fn_unidad_ponderacion_disponible, V223). :ID = PK_TUNIDAD, ?grupo= (opcional; grupo NULL es su propio bucket). Alimenta el "Disponible para asignar: X%" del modal "Vincular actividad". Acotado a >= 0. Gate VER sobre PLANEADOR. 404 (P0002) si la unidad no existe.',
       'SELECT * FROM academico_test.fn_unidad_ponderacion_disponible(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:QUERY.GRUPO AS BIGINT)
);'
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- GET /planeador/unidades/:ID/referente
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT '60761ba0-3d48-4819-b96a-bda489d63281', m.id_microservice, '/planeador/unidades/:ID/referente', 'GET', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL, '{"PARAM.ID": "BIGINT"}'::jsonb,
       'V255 -- los enunciados del referente curricular que ESTA unidad relaciono, con sus evidencias. :ID = PK_TUNIDAD. Es LECTURA de lo relacionado, NO un catalogo: solo vienen los enunciados presentes en TUNIDAD_ENUNCIADO. Para OFRECER enunciados que marcar en el formulario usa GET /planeador/referente-curricular?grado=&asignatura= (V278), que devuelve el arbol completo del referente. El referente NO se elige a mano: se deriva del GRADO de la unidad -> nivel de ensenanza -> referente de ese nivel, y este endpoint hace ese recorrido en una sola llamada. Devuelve: el contexto (unidad, grado, nivel_ensenanza), el referente (nombre, descripcion), enfoque_valor + es_evaluativo y tipo_evaluacion_valor -- las dos reglas que deciden que secciones e instrumentos se habilitan en la actividad (ver GET /planeador/actividades/:ID/configuracion) --, nivel_1_etiqueta y nivel_2_etiqueta (como llama ESE referente a sus niveles: "Enunciado"/"Evidencia" en primaria, "Proposito"/"Evidencia" en preescolar -- rotula con esto, no con literales), y enunciados: [{pk, texto, relacionadoConUnidad, pkTunidadEnunciado, evidencias:[{pk, texto}]}]. relacionadoConUnidad viene siempre true (la clave se conserva para no romper el contrato) y pkTunidadEnunciado es el PK que pide PATCH /planeador/unidades/enunciados/:ID para quitar la relacion (es el de la RELACION, no el del enunciado). Las evidencias son todas las hijas activas del enunciado: no hay relacion evidencia<->unidad, TACTIVIDAD_EVIDENCIA es por ACTIVIDAD. Si la unidad no tiene referente activo o no relaciono ningun enunciado, enunciados viene []. Gate VER sobre PLANEADOR; 404 (P0002) si la unidad no existe.',
       'SELECT * FROM academico_test.fn_unidad_referente_detalle(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
);'
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- GET /planeador/unidades/:ID/valoraciones
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT 'b99f171c-6784-4b9f-9a02-dfb19d41d2cb', m.id_microservice, '/planeador/unidades/:ID/valoraciones', 'GET', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL, '{"PARAM.ID": "BIGINT"}'::jsonb,
       'V227 -- valoraciones (las bandas Bajo/Basico/Alto/Superior) de la escala que aplica a la unidad :ID. Es el select que faltaba para poder AGREGAR UN CRITERIO a la rubrica de la unidad: POST /planeador/unidades/:ID/criterios exige un indicador por cada valoracion activa de la escala, y cada uno se identifica con el pk_tescala_valoracion que devuelve esta ruta. La escala se deriva de la unidad (asignatura + grado -> criterio de evaluacion vigente -> escala; si no hay, por el nivel de ensenanza del grado), asi que el cliente no tiene que conocerla ni filtrar entre las escalas del periodo. Cada fila trae el orden, el codigo/nombre de la valoracion y sus graficas (simbolo, carita), los limites crudos en porcentaje 0-100 (limite_inferior/limite_superior, que es como se guardan) y esos mismos limites ya convertidos al formato de calificacion del colegio (nota_minima/nota_maxima, NULL si el formato no es numerico) para poder rotular "Alto (4.0 - 4.7)". Sin paginacion: una escala tiene unas pocas bandas. Gate VER sobre PLANEADOR.',
       'SELECT * FROM academico_test.fn_unidad_valoraciones_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
);'
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- PATCH /planeador/unidades/actividades/:ACTIVIDADID
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT '529aba8e-501c-4749-a229-214083f2cd1a', m.id_microservice, '/planeador/unidades/actividades/:ACTIVIDADID', 'PATCH', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL, '{"PARAM.ACTIVIDADID": "BIGINT"}'::jsonb,
       'V245 -- desvincula una actividad de su unidad: FK_TUNIDAD y PONDERACION quedan en NULL (fn_unidad_actividad_desvincular, V223). :ACTIVIDADID = PK_TACTIVIDAD. Si la unidad de origen calculaba por Sumatoria, recalcula el % de las actividades que quedan en ese (unidad,grupo). Retorna fn_unidad_actividad_desvincular (el PK, como antes) y, si la unidad pondera, porcentaje_libre y aviso (Al desvincular esta actividad, quedará un X% libre en la unidad...); no redistribuye (Regla 39). Gate EDITAR sobre PLANEADOR + autor de la actividad (Regla 25c). 404 (P0002) si la actividad no existe.',
       'SELECT r.pk_tactividad AS fn_unidad_actividad_desvincular, r.porcentaje_libre, r.aviso
  FROM academico_test.fn_unidad_actividad_desvincular(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ACTIVIDADID AS BIGINT)
) r;'
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- PUT /planeador/unidades/actividades/:ACTIVIDADID/ponderacion
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT '25ffaf0b-3db2-4489-8b09-727aee1c3ec4', m.id_microservice, '/planeador/unidades/actividades/:ACTIVIDADID/ponderacion', 'PUT', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL, '{"BODY.PONDERACION": "NUMERIC", "PARAM.ACTIVIDADID": "BIGINT"}'::jsonb,
       'V245 -- edicion inline del peso (%) de una actividad ya vinculada a una unidad (fn_unidad_actividad_ponderacion_set, V223). :ACTIVIDADID = PK_TACTIVIDAD. BODY.PONDERACION obligatorio, 0..100; se rechaza (22023) si la unidad Promedia (no aplica) o calcula por Sumatoria (se autocalcula desde NOTA_MAXIMA) o si la actividad no esta vinculada a ninguna unidad. Valida la regla del 100% por (unidad,grupo). Retorna PK_TACTIVIDAD. Gate EDITAR sobre PLANEADOR + autor de la actividad (Regla 25c).',
       'SELECT * FROM academico_test.fn_unidad_actividad_ponderacion_set(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ACTIVIDADID AS BIGINT),
    CAST(:BODY.PONDERACION AS NUMERIC)
);'
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- PATCH /planeador/unidades/criterios/:ID
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT '4e7926f5-1e8f-4ae5-893e-03bd5cbefe2e', m.id_microservice, '/planeador/unidades/criterios/:ID', 'PATCH', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL, '{"PARAM.ID": "BIGINT"}'::jsonb,
       'V245 -- soft delete (ACTIVE=FALSE) de un criterio de la rubrica de la unidad y sus niveles (fn_unidad_criterio_eliminar, V222). :ID = PK_TCRITERIO_UNIDAD. No renumera el ORDEN de los criterios restantes. Gate ELIMINAR sobre PLANEADOR. 404 (P0002) si el criterio no existe; 22023 si ya esta inactivo.',
       'SELECT * FROM academico_test.fn_unidad_criterio_eliminar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
);'
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- PUT /planeador/unidades/criterios/:ID
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT 'a52319d7-6035-400c-9e8e-de00f8cc3b13', m.id_microservice, '/planeador/unidades/criterios/:ID', 'PUT', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL, '{"PARAM.ID": "BIGINT", "BODY.CODIGO": "VARCHAR", "BODY.NIVELES": "JSONB", "BODY.PUBLICO": "VARCHAR", "BODY.DESCRIPCION": "VARCHAR", "BODY.LIMPIAR_CODIGO": "BOOLEAN", "BODY.DESCRIPTOR_PROM": "VARCHAR"}'::jsonb,
       'V245 -- PATCH parcial de un criterio de la rubrica de la unidad (fn_unidad_criterio_actualizar, V222). :ID = PK_TCRITERIO_UNIDAD. Campos ausentes/NULL preservan; LIMPIAR_CODIGO=true fuerza CODIGO a NULL. BODY.NIVELES (opcional) = [{"fkTescalaValoracion":N,"indicador":"?","recomendacion":"?","tarea":"?"}] actualiza SOLO los textos de niveles YA existentes de ese criterio (no crea niveles nuevos). Gate EDITAR sobre PLANEADOR. 404 (P0002) si el criterio no existe; 22023 si esta inactivo o un nivel referencia una valoracion ajena al criterio.',
       'SELECT * FROM academico_test.fn_unidad_criterio_actualizar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.DESCRIPCION AS VARCHAR),
    CAST(:BODY.PUBLICO AS VARCHAR),
    CAST(:BODY.CODIGO AS VARCHAR),
    COALESCE(CAST(:BODY.LIMPIAR_CODIGO AS BOOLEAN), FALSE),
    CAST(:BODY.DESCRIPTOR_PROM AS VARCHAR),
    CAST(:BODY.NIVELES AS JSONB)
);'
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- PATCH /planeador/unidades/enunciados/:ID
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT '2144e03a-7082-44ca-8c03-4429eab44f1b', m.id_microservice, '/planeador/unidades/enunciados/:ID', 'PATCH', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL, '{"PARAM.ID": "BIGINT"}'::jsonb,
       'V245 -- borrado logico de una relacion unidad<->enunciado (fn_unidad_enunciado_quitar, V214.1). :ID = PK_TUNIDAD_ENUNCIADO. Arrastra la desactivacion de las TACTIVIDAD_EVIDENCIA de esa unidad cuyo enunciado padre era este. Gate EDITAR sobre PLANEADOR. 23503 si la relacion no existe o ya esta inactiva.',
       'SELECT * FROM academico_test.fn_unidad_enunciado_quitar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
);'
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- POST /planeador/unidades/export-all
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT 'eval-col-planeador-unidades-export-all-001', m.id_microservice, '/planeador/unidades/export-all', 'POST', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL, '{"BODY.SORTING.ID": "VARCHAR", "BODY.FILTERS.DIA": "DATE", "BODY.FILTERS.IDS": "BIGINT[]", "BODY.SORTING.DESC": "TEXT", "BODY.FILTERS.GRADO": "BIGINT", "BODY.FILTERS.SEARCH": "VARCHAR", "BODY.FILTERS.ASIGNATURA": "BIGINT", "BODY.FILTERS.DIAS_GRACIA": "INT", "BODY.FILTERS.FUNCIONARIO": "BIGINT", "BODY.FILTERS.INCLUIR_INACTIVOS": "BOOLEAN"}'::jsonb,
       'V406 -- unidades tematicas del planeador SIN PAGINAR para el reporte PDF/Excel (reporting-service, clave planeador-unidades). Misma funcion, mismos filtros y mismo gate/alcance que GET /planeador/unidades (fn_unidad_listar, V216), con los binds bajo BODY.FILTERS.* (SEARCH, ASIGNATURA, GRADO, FUNCIONARIO, INCLUIR_INACTIVOS, DIA, DIAS_GRACIA) + FILTERS.IDS para exportar las seleccionadas y SORTING.ID/DESC para el orden. Todos opcionales. Exporta lo que la pantalla muestra (nombre, descripcion, asignatura, area, grado, docente, estado, fechas, metodo de calculo y los contadores de actividades/objetivos/contenidos); los textos de los objetivos y contenidos NO salen -- eso seria un reporte maestro-detalle distinto. Gemela de V404, que hace lo mismo con la pestana Actividades.',
       'SELECT * FROM academico_test.fn_unidad_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FILTERS.SEARCH AS VARCHAR),
    CAST(:BODY.FILTERS.ASIGNATURA AS BIGINT),
    CAST(:BODY.FILTERS.GRADO AS BIGINT),
    CAST(:BODY.FILTERS.FUNCIONARIO AS BIGINT),
    COALESCE(CAST(:BODY.FILTERS.INCLUIR_INACTIVOS AS BOOLEAN), FALSE),
    COALESCE(CAST(:BODY.SORTING.ID AS VARCHAR), ''nombre''),
    COALESCE(CAST(:BODY.SORTING.DESC AS TEXT), ''false'') <> ''true'',
    NULL::INT,
    0,
    CAST(:BODY.FILTERS.DIA AS DATE),
    COALESCE(CAST(:BODY.FILTERS.DIAS_GRACIA AS INT), 2)
) t
WHERE CAST(:BODY.FILTERS.IDS AS BIGINT[]) IS NULL
   OR t.pk_tunidad = ANY(CAST(:BODY.FILTERS.IDS AS BIGINT[]));'
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- GET /planeador/unidades/tabs
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT 'cf74d77d-0d41-4113-b4e8-5025a6f6767a', m.id_microservice, '/planeador/unidades/tabs', 'GET', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL, '{}'::jsonb,
       'V281 -- las PESTANAS de unidad del docente autenticado, una por referente curricular de los niveles educativos que dicta. El rotulo de la pestana NO es fijo: sale de instrumento (TREFERENTE_CURRICULAR.INSTRUMENTO del referente del nivel -- "Proyecto pedagogico" en Preescolar, "Unidad tematica" en Primaria, "Valores"...) y instrumento_info_adicional es su descripcion larga. Un docente que solo dicta Preescolar recibe UNA fila; uno con grados de varios niveles recibe la lista completa. Sin parametros: el docente se resuelve del token (no se pueden consultar las pestanas de otro), y si el usuario no es un docente activo devuelve 0 filas. Cada fila trae, ademas del rotulo: pk_referente_curricular y referente_nombre; enfoque_valor + es_evaluativo y tipo_evaluacion_valor (que secciones e instrumentos se habilitan dentro); nivel_1_etiqueta / nivel_2_etiqueta (como llama ESE referente a sus niveles -- rotular con esto); y niveles / grados / asignaturas: [{pk,nombre}] con lo que cae bajo esa pestana, para filtrar el contenido al cambiar de pestana sin volver a preguntar. Si dos niveles comparten referente es UNA sola pestana (la relacion referente<->nivel es N:N). Los niveles cuyo grado aun no tiene referente cargado NO se omiten: vienen con pk_referente_curricular null e instrumento "Unidad tematica" -- hay que pintar la pestana igual, aunque dentro no haya arbol de enunciados. Orden estable: primero las pestanas con referente, luego por rotulo. Gate VER sobre PLANEADOR.',
       'SELECT * FROM academico_test.fn_docente_unidad_tabs_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);'
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- Roles: los once del Planeador en todas las rutas; JEFE_AREA además lee el referente.
INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id AND m.serviceid = 'eval-col'
  JOIN public.role r ON r.name IN (
        'CEVAL-SUPER_ADMINISTRADOR', 'CEVAL-RECTOR', 'CEVAL-COORDINADOR', 'CEVAL-DOCENTE',
        'CEVAL-DIRECTOR_GRUPO', 'CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO',
        'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-JEFE_AREA_CALIDAD', 'CEVAL-JEFE_AREA_COBERTURA',
        'CEVAL-JEFE_AREA_PLANEACION')
 WHERE q.path_template LIKE '/planeador/unidades%'
ON CONFLICT DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id AND m.serviceid = 'eval-col'
  JOIN public.role r ON r.name = 'CEVAL-JEFE_AREA'
 WHERE q.path_template = '/planeador/unidades/:ID/referente' AND q.http_method = 'GET'
ON CONFLICT DO NOTHING;
