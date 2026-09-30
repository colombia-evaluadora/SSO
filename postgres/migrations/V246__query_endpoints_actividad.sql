-- V246 - Primer alta de las filas de public.query de /planeador/actividades*
-- y sus roles. Las filas de escritura las define hoy V496.4 (upsert); estos
-- INSERT se conservan porque V421, V426, V470 y V471 copian de ellos los roles
-- de sus propias filas al migrar.


INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_actividad_crear(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.TITULO AS VARCHAR),
    CAST(:BODY.FK_TASIGNATURA AS BIGINT),
    CAST(:BODY.FK_TLV_TIPO_ACTIVIDAD AS BIGINT),
    CAST(:BODY.FK_TLV_JERARQUIA AS BIGINT),
    CAST(:BODY.DESCRIPCION AS VARCHAR),
    CAST(:BODY.FK_TGRUPO AS BIGINT),
    CAST(:BODY.FK_TUNIDAD AS BIGINT),
    CAST(:BODY.PONDERACION AS NUMERIC),
    CAST(:BODY.FECHA_INICIO AS DATE),
    CAST(:BODY.FECHA_CIERRE AS DATE),
    CAST(:BODY.DURACION_ESTIMADA AS NUMERIC),
    CAST(:BODY.SEMANA_CRONOGRAMA AS VARCHAR),
    CAST(:BODY.FK_TLV_MODALIDAD AS BIGINT),
    CAST(:BODY.MATERIAL_REQUERIDO AS VARCHAR),
    COALESCE(CAST(:BODY.ES_EVALUATIVA AS academico_test.bool_sn), ''S''),
    CAST(:BODY.FK_TLV_INSTRUMENTO_EVALUACION AS BIGINT),
    CAST(:BODY.DESCRIPCION_INSTRUMENTO AS VARCHAR),
    CAST(:BODY.FK_TLV_TIPO_EVIDENCIA AS BIGINT),
    CAST(:BODY.FK_TLV_METODO_VALORACION AS BIGINT),
    CAST(:BODY.FK_TLV_TIPO_CALCULO AS BIGINT),
    CAST(:BODY.INFLUENCIA AS NUMERIC),
    CAST(:BODY.NOTA_MAXIMA AS NUMERIC),
    COALESCE(CAST(:BODY.REQUIERE_ARCHIVO AS academico_test.bool_sn), ''N''),
    COALESCE(CAST(:BODY.REQUIERE_TEXTO AS academico_test.bool_sn), ''N''),
    COALESCE(CAST(:BODY.GENERA_EVIDENCIAS AS academico_test.bool_sn), ''N''),
    COALESCE(CAST(:BODY.REQUIERE_VALIDACION_COORDINADOR AS academico_test.bool_sn), ''N''),
    CAST(:BODY.OBSERVACIONES_DOCENTE AS VARCHAR),
    CAST(:BODY.MATERIALES AS JSONB),
    CAST(:BODY.ADAPTACIONES AS JSONB),
    CAST(:BODY.FK_TMATRICULAS AS BIGINT[]),
    COALESCE(CAST(:BODY.ASIGNAR_TODO_EL_GRUPO AS BOOLEAN), FALSE),
    CAST(:BODY.RECUPERACION AS JSONB),
    CAST(:BODY.EVIDENCIAS AS BIGINT[]),
    CAST(:BODY.CRITERIOS AS BIGINT[])
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades', 'SELECT', 'POST',
    '{"BODY.TITULO": "VARCHAR", "BODY.FK_TASIGNATURA": "BIGINT", "BODY.FK_TLV_TIPO_ACTIVIDAD": "BIGINT", "BODY.FK_TLV_JERARQUIA": "BIGINT", "BODY.DESCRIPCION": "VARCHAR", "BODY.FK_TGRUPO": "BIGINT", "BODY.FK_TUNIDAD": "BIGINT", "BODY.PONDERACION": "NUMERIC", "BODY.FECHA_INICIO": "DATE", "BODY.FECHA_CIERRE": "DATE", "BODY.DURACION_ESTIMADA": "NUMERIC", "BODY.SEMANA_CRONOGRAMA": "VARCHAR", "BODY.FK_TLV_MODALIDAD": "BIGINT", "BODY.MATERIAL_REQUERIDO": "VARCHAR", "BODY.ES_EVALUATIVA": "VARCHAR", "BODY.FK_TLV_INSTRUMENTO_EVALUACION": "BIGINT", "BODY.DESCRIPCION_INSTRUMENTO": "VARCHAR", "BODY.FK_TLV_TIPO_EVIDENCIA": "BIGINT", "BODY.FK_TLV_METODO_VALORACION": "BIGINT", "BODY.FK_TLV_TIPO_CALCULO": "BIGINT", "BODY.INFLUENCIA": "NUMERIC", "BODY.NOTA_MAXIMA": "NUMERIC", "BODY.REQUIERE_ARCHIVO": "VARCHAR", "BODY.REQUIERE_TEXTO": "VARCHAR", "BODY.GENERA_EVIDENCIAS": "VARCHAR", "BODY.REQUIERE_VALIDACION_COORDINADOR": "VARCHAR", "BODY.OBSERVACIONES_DOCENTE": "VARCHAR", "BODY.MATERIALES": "JSONB", "BODY.ADAPTACIONES": "JSONB", "BODY.FK_TMATRICULAS": "BIGINT[]", "BODY.ASIGNAR_TODO_EL_GRUPO": "BOOLEAN", "BODY.RECUPERACION": "JSONB", "BODY.EVIDENCIAS": "BIGINT[]", "BODY.CRITERIOS": "BIGINT[]"}'::jsonb,
    'V246 -- crea una actividad del Planeador (fn_actividad_crear, V224). Obligatorios: TITULO, FK_TASIGNATURA, FK_TLV_TIPO_ACTIVIDAD (catalogo TIPO_ACTIVIDAD), FK_TLV_JERARQUIA (catalogo TIPO_JERARQUIA_ACTIVIDAD: Actividad/Criterio). Opcionales: FK_TGRUPO, FK_TUNIDAD + PONDERACION (% dentro de la unidad -- rechazada 22023 si la actividad no es evaluativa o el metodo de calculo de la unidad no la admite, ver campos_disponibles.ponderacion del punto 6), fechas, FK_TLV_MODALIDAD, ES_EVALUATIVA (S/N, default S), FK_TLV_INSTRUMENTO_EVALUACION (solo admitido si hay unidad con referente EVALUATIVO), FK_TLV_TIPO_EVIDENCIA, FK_TLV_TIPO_CALCULO, INFLUENCIA, NOTA_MAXIMA (puntaje si la unidad calcula por Sumatoria), banderas REQUIERE_ARCHIVO/REQUIERE_TEXTO/GENERA_EVIDENCIAS/REQUIERE_VALIDACION_COORDINADOR (S/N, default N), MATERIALES/ADAPTACIONES (arrays JSONB, ver PUT .../materiales y .../adaptaciones para el formato de cada elemento), FK_TMATRICULAS y/o ASIGNAR_TODO_EL_GRUPO (asignacion de estudiantes; sin ninguno de los dos no se asigna nadie), RECUPERACION (objeto {destino,fkActividadRecuperar?,tipoAplicacion,tipoCalculo,valorPonderacion?}; exige ES_EVALUATIVA=S), EVIDENCIAS (PKs de TREFERENTE_ENUNCIADO nivel 2, exige unidad y enunciado padre ya relacionado con ella) y CRITERIOS (PKs de TCRITERIO_UNIDAD de la rubrica de la unidad). Retorna PK_TACTIVIDAD. Gate CREAR sobre PLANEADOR.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/actividades'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_actividad_actualizar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.TITULO AS VARCHAR),
    CAST(:BODY.DESCRIPCION AS VARCHAR),
    CAST(:BODY.FK_TASIGNATURA AS BIGINT),
    CAST(:BODY.FK_TGRUPO AS BIGINT),
    CAST(:BODY.FK_TUNIDAD AS BIGINT),
    CAST(:BODY.PONDERACION AS NUMERIC),
    COALESCE(CAST(:BODY.DESVINCULAR_UNIDAD AS BOOLEAN), FALSE),
    CAST(:BODY.FK_TLV_TIPO_ACTIVIDAD AS BIGINT),
    CAST(:BODY.FECHA_INICIO AS DATE),
    CAST(:BODY.FECHA_CIERRE AS DATE),
    CAST(:BODY.DURACION_ESTIMADA AS NUMERIC),
    CAST(:BODY.SEMANA_CRONOGRAMA AS VARCHAR),
    CAST(:BODY.FK_TLV_MODALIDAD AS BIGINT),
    CAST(:BODY.MATERIAL_REQUERIDO AS VARCHAR),
    CAST(:BODY.ES_EVALUATIVA AS academico_test.bool_sn),
    CAST(:BODY.FK_TLV_INSTRUMENTO_EVALUACION AS BIGINT),
    CAST(:BODY.DESCRIPCION_INSTRUMENTO AS VARCHAR),
    CAST(:BODY.FK_TLV_TIPO_EVIDENCIA AS BIGINT),
    CAST(:BODY.FK_TLV_METODO_VALORACION AS BIGINT),
    CAST(:BODY.FK_TLV_TIPO_CALCULO AS BIGINT),
    CAST(:BODY.INFLUENCIA AS NUMERIC),
    CAST(:BODY.NOTA_MAXIMA AS NUMERIC),
    CAST(:BODY.REQUIERE_ARCHIVO AS academico_test.bool_sn),
    CAST(:BODY.REQUIERE_TEXTO AS academico_test.bool_sn),
    CAST(:BODY.GENERA_EVIDENCIAS AS academico_test.bool_sn),
    CAST(:BODY.REQUIERE_VALIDACION_COORDINADOR AS academico_test.bool_sn),
    CAST(:BODY.OBSERVACIONES_DOCENTE AS VARCHAR),
    CAST(:BODY.MATERIALES AS JSONB),
    CAST(:BODY.ADAPTACIONES AS JSONB),
    CAST(:BODY.FK_TMATRICULAS AS BIGINT[]),
    COALESCE(CAST(:BODY.ASIGNAR_TODO_EL_GRUPO AS BOOLEAN), FALSE),
    CAST(:BODY.RECUPERACION AS JSONB),
    COALESCE(CAST(:BODY.QUITAR_RECUPERACION AS BOOLEAN), FALSE),
    CAST(:BODY.EVIDENCIAS AS BIGINT[]),
    CAST(:BODY.CRITERIOS AS BIGINT[])
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades/:ID', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT", "BODY.TITULO": "VARCHAR", "BODY.DESCRIPCION": "VARCHAR", "BODY.FK_TASIGNATURA": "BIGINT", "BODY.FK_TGRUPO": "BIGINT", "BODY.FK_TUNIDAD": "BIGINT", "BODY.PONDERACION": "NUMERIC", "BODY.DESVINCULAR_UNIDAD": "BOOLEAN", "BODY.FK_TLV_TIPO_ACTIVIDAD": "BIGINT", "BODY.FECHA_INICIO": "DATE", "BODY.FECHA_CIERRE": "DATE", "BODY.DURACION_ESTIMADA": "NUMERIC", "BODY.SEMANA_CRONOGRAMA": "VARCHAR", "BODY.FK_TLV_MODALIDAD": "BIGINT", "BODY.MATERIAL_REQUERIDO": "VARCHAR", "BODY.ES_EVALUATIVA": "VARCHAR", "BODY.FK_TLV_INSTRUMENTO_EVALUACION": "BIGINT", "BODY.DESCRIPCION_INSTRUMENTO": "VARCHAR", "BODY.FK_TLV_TIPO_EVIDENCIA": "BIGINT", "BODY.FK_TLV_METODO_VALORACION": "BIGINT", "BODY.FK_TLV_TIPO_CALCULO": "BIGINT", "BODY.INFLUENCIA": "NUMERIC", "BODY.NOTA_MAXIMA": "NUMERIC", "BODY.REQUIERE_ARCHIVO": "VARCHAR", "BODY.REQUIERE_TEXTO": "VARCHAR", "BODY.GENERA_EVIDENCIAS": "VARCHAR", "BODY.REQUIERE_VALIDACION_COORDINADOR": "VARCHAR", "BODY.OBSERVACIONES_DOCENTE": "VARCHAR", "BODY.MATERIALES": "JSONB", "BODY.ADAPTACIONES": "JSONB", "BODY.FK_TMATRICULAS": "BIGINT[]", "BODY.ASIGNAR_TODO_EL_GRUPO": "BOOLEAN", "BODY.RECUPERACION": "JSONB", "BODY.QUITAR_RECUPERACION": "BOOLEAN", "BODY.EVIDENCIAS": "BIGINT[]", "BODY.CRITERIOS": "BIGINT[]"}'::jsonb,
    'V246 -- PATCH parcial de una actividad (fn_actividad_actualizar, V224). :ID = PK_TACTIVIDAD. Cada campo ausente/NULL preserva el valor actual; MATERIALES/ADAPTACIONES/FK_TMATRICULAS: NULL = no tocar, array (incl. vacio) = reemplazo completo. EVIDENCIAS (PKs de TREFERENTE_ENUNCIADO nivel 2) y CRITERIOS (PKs de TCRITERIO_UNIDAD) siguen el mismo contrato: NULL = no tocar, array (incl. vacio) = el set queda exactamente ese (se desactivan las relaciones que ya no vienen y el resto se relaciona/reactiva con fn_actividad_evidencia_relacionar / fn_actividad_criterio_relacionar, V214.1; agregar exige que la actividad tenga unidad). Los pk de esas relaciones se leen en GET /planeador/actividades/:ID (columnas evidencias y criterios). DESVINCULAR_UNIDAD=true es excluyente con FK_TUNIDAD/PONDERACION (unidad/ponderacion se delegan en fn_unidad_actividad_vincular/_ponderacion_set/_desvincular, V223, mismo punto unico de la regla del 100%). QUITAR_RECUPERACION=true es excluyente con RECUPERACION. Revalida fechas, catalogos, unicidad (titulo, unidad, grupo, jerarquia) y las condiciones dinamicas de evaluacion/ponderacion contra los valores RESULTANTES del PATCH (ver campos_disponibles del punto 6). Gate EDITAR sobre PLANEADOR. 404 (P0002) si la actividad no existe; 22023 si esta inactiva.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/actividades/:ID'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_actividad_eliminar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades/:ID', 'SELECT', 'PATCH',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    'V246 -- soft delete (ACTIVE=FALSE) en cascada de una actividad y TODOS sus satelites activos: capturas de calificacion, TACTIVIDAD_ESTUDIANTE, definicion del instrumento (V226), materiales, adaptaciones, recuperacion, evidencias y criterios de unidad (fn_actividad_eliminar, V224). :ID = PK_TACTIVIDAD. Se BLOQUEA (23503) si la actividad tiene notas registradas (CALIFICACION no nula para algun estudiante) o si otra actividad de recuperacion ACTIVA la referencia. Suelta la actividad de su unidad y recalcula el bucket si era de Sumatoria. Gate ELIMINAR sobre PLANEADOR. 404 (P0002) si no existe; 22023 si ya esta inactiva.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/actividades/:ID'
   AND q.http_method   = 'PATCH'
ON CONFLICT DO NOTHING;

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_actividad_buscar_por_pk(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    COALESCE(CAST(:QUERY.DIAS_GRACIA AS INT), 2)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades/:ID', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT", "QUERY.DIAS_GRACIA": "INT"}'::jsonb,
    'V246 -- detalle completo de una actividad (fn_actividad_buscar_por_pk, V224): todos los campos con nombres de catalogo resueltos, estado DERIVADO (?DIAS_GRACIA=, default 2), progreso de evaluacion (asignados/evaluados), materiales/adaptaciones como JSONB, config de recuperacion (o NULL), campos_disponibles (secciones dinamicas -- ver punto 6, misma funcion) y unidad_configuracion (snapshot de la unidad: objetivos, contenidos, referente curricular, rubrica, enunciados/evidencias). :ID = PK_TACTIVIDAD. SETOF 0 o 1 fila (incluye inactivas). Gate VER sobre PLANEADOR.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/actividades/:ID'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_actividad_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.SEARCH AS VARCHAR),
    CAST(:QUERY.ASIGNATURA AS BIGINT),
    CAST(:QUERY.GRUPO AS BIGINT),
    CAST(:QUERY.UNIDAD AS BIGINT),
    CAST(:QUERY.TIPO_ACTIVIDAD AS BIGINT),
    CAST(:QUERY.INSTRUMENTO AS BIGINT),
    CAST(:QUERY.FECHA_DESDE AS DATE),
    CAST(:QUERY.FECHA_HASTA AS DATE),
    CAST(:QUERY.ESTADOS AS VARCHAR[]),
    COALESCE(CAST(:QUERY.DIAS_GRACIA AS INT), 2),
    COALESCE(CAST(:QUERY.INCLUIR_INACTIVAS AS BOOLEAN), FALSE),
    COALESCE(CAST(:QUERY.ORDEN_POR AS VARCHAR), ''fecha_inicio''),
    COALESCE(CAST(:QUERY.ORDEN_ASC AS BOOLEAN), TRUE),
    COALESCE(CAST(:QUERY.SIZE AS INT), 20),
    COALESCE(CAST(:QUERY.OFFSET AS INT), 0),
    NULL,
    CAST(:QUERY.DIA AS DATE)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades', 'SELECT', 'GET',
    '{"QUERY.SEARCH": "VARCHAR", "QUERY.ASIGNATURA": "BIGINT", "QUERY.GRUPO": "BIGINT", "QUERY.UNIDAD": "BIGINT", "QUERY.TIPO_ACTIVIDAD": "BIGINT", "QUERY.INSTRUMENTO": "BIGINT", "QUERY.FECHA_DESDE": "DATE", "QUERY.FECHA_HASTA": "DATE", "QUERY.ESTADOS": "TEXT[]", "QUERY.DIAS_GRACIA": "INT", "QUERY.INCLUIR_INACTIVAS": "BOOLEAN", "QUERY.ORDEN_POR": "VARCHAR", "QUERY.ORDEN_ASC": "BOOLEAN", "QUERY.DIA": "DATE"}'::jsonb,
    'V246 -- pagina de actividades (fn_actividad_listar, V224) con filtros indexados ?asignatura=, ?grupo=, ?unidad=, ?TIPO_ACTIVIDAD=, ?instrumento= y ventana ?FECHA_DESDE=/?FECHA_HASTA=. ?search= es el buscador unico "nombre, nivel educativo o instrumento" (titulo+descripcion via trigram, o nivel de ensenanza de la unidad, o nombre del instrumento). ?estados= filtra por el estado DERIVADO (array de FINALIZADA/VENCIDA/PENDIENTE_POR_EVALUAR/PROGRAMADA/EN_EVALUACION/SIN_PROGRAMAR), ?DIAS_GRACIA= (default 2) ajusta el umbral de VENCIDA. ?INCLUIR_INACTIVAS= (default false). ?ORDEN_POR= (whitelist fecha_inicio|fecha_cierre|fecha_creacion|titulo|ponderacion, cualquier otro cae a fecha_inicio) / ?ORDEN_ASC=. Paginacion system-bound ?size=/?offset= (default 20/0). PAGINADO POR DIA ACTIVO ?dia=YYYY-MM-DD (la barra "Hoy | MARTES 16 | < >"): deja solo las actividades VIGENTES ese dia -- vigente = la ventana [fechaInicio, fechaCierre] CUBRE el dia, NO que empiece o cierre en el, para que una actividad de tres dias aparezca en los tres; una actividad sin ninguna fecha no esta en ningun dia y no sale en esta vista. La respuesta trae dia, dia_anterior y dia_siguiente para las flechas: el dia ocupado mas cercano a cada lado bajo los MISMOS filtros, SALTANDO los dias vacios (no es dia-1/dia+1 a ciegas), y NULL cuando no hay mas dias por ese lado -- con eso se deshabilita la flecha. Sin ?dia= el listado es el de siempre y esas tres columnas vienen NULL. Devuelve nombres resueltos (asignatura, area, unidad, grupo, tipo, instrumento), estado derivado y progreso de evaluacion (asignados/evaluados/%). total_count via COUNT(*) OVER(). Gate VER sobre PLANEADOR.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/actividades'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT academico_test.fn_actividad_campos_disponibles(
        public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
        CAST(:PARAM.ID AS BIGINT)
    ) AS campos_disponibles,
    academico_test.fn_actividad_unidad_configuracion(
        public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
        CAST(:PARAM.ID AS BIGINT)
    ) AS unidad_configuracion;',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades/:ID/configuracion', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    'V246 -- "visualizacion construida por endpoint": secciones dinamicas habilitadas/deshabilitadas del formulario de actividad para ESTA actividad puntual, con el MOTIVO de cada decision (fn_actividad_campos_disponibles + fn_actividad_unidad_configuracion, V214.2). :ID = PK_TACTIVIDAD. campos_disponibles = {criterio:{visible,requerido,motivo} -- oculto solo en Preescolar, opcional en el resto; evaluacion:{visible,requerido,motivo,instrumentosPermitidos} -- visible/requerido solo si la unidad tiene referente EVALUATIVO, instrumentosPermitidos ya filtrado por el TIPO_EVALUACION del referente; ponderacion:{visible,requerido,modo,motivo,autocalculado?,campo?} -- oculto sin unidad o si ES_EVALUATIVA=N, si aplica el modo (PORCENTAJE sobre PONDERACION, o PUNTAJE autocalculado sobre NOTA_MAXIMA) lo decide el metodo de calculo de la unidad (V73)}. unidad_configuracion = snapshot completo de la unidad relacionada (objetivos, contenidos, referente curricular, rubrica con criterios/niveles, enunciados/evidencias) o {"tieneUnidad":false} si la actividad no tiene unidad. Gate VER sobre PLANEADOR (en ambas funciones). 404 (P0002) si la actividad no existe.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/actividades/:ID/configuracion'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_actividad_huerfanas_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.SEARCH AS VARCHAR),
    CAST(:QUERY.ASIGNATURA AS BIGINT),
    CAST(:QUERY.GRUPO AS BIGINT),
    CAST(:QUERY.FECHA_DESDE AS DATE),
    CAST(:QUERY.FECHA_HASTA AS DATE),
    COALESCE(CAST(:QUERY.PAGINA AS INT), 1),
    COALESCE(CAST(:QUERY.SIZE AS INT), 20)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades/huerfanas', 'SELECT', 'GET',
    '{"QUERY.SEARCH": "VARCHAR", "QUERY.ASIGNATURA": "BIGINT", "QUERY.GRUPO": "BIGINT", "QUERY.FECHA_DESDE": "DATE", "QUERY.FECHA_HASTA": "DATE", "QUERY.PAGINA": "INT"}'::jsonb,
    'V246 -- actividades sin unidad (TACTIVIDAD.FK_TUNIDAD IS NULL, ACTIVE) para la pantalla de vinculacion posterior (fn_actividad_huerfanas_listar, V244). Filtros ?search= (trigram TITULO+DESCRIPCION), ?asignatura=, ?grupo=, ?FECHA_DESDE=/?FECHA_HASTA=. No proyecta PONDERACION (siempre NULL en una huerfana). Paginacion ?pagina= (default 1) / ?size= (default 20; tamano_pagina de la funcion). Para vincular una fila del resultado usar PUT /planeador/unidades/:ID/actividades/:ACTIVIDADID (V245). total_count via COUNT(*) OVER(). Gate VER sobre PLANEADOR.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/actividades/huerfanas'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_actividad_materiales_reutilizables_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:QUERY.ASIGNATURA AS BIGINT),
    CAST(:QUERY.FUNCIONARIO AS BIGINT),
    CAST(:QUERY.SEARCH AS VARCHAR),
    COALESCE(CAST(:QUERY.PAGINA AS INT), 1),
    COALESCE(CAST(:QUERY.SIZE AS INT), 20)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades/:ID/materiales-reutilizables', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT", "QUERY.ASIGNATURA": "BIGINT", "QUERY.FUNCIONARIO": "BIGINT", "QUERY.SEARCH": "VARCHAR", "QUERY.PAGINA": "INT"}'::jsonb,
    'V246 -- picker de reutilizacion de materiales de apoyo (badge "Unidad virtual / repositorio" del figma): materiales con archivo de OTRAS actividades activas, para referenciar el mismo TARCHIVO en la actividad :ID que se esta editando (fn_actividad_materiales_reutilizables_listar, V224). :ID = PK_TACTIVIDAD (excluye sus propios materiales). ?asignatura=/?funcionario= (via la unidad de la actividad de origen) acotan el universo; ?search= busca por nombre de archivo o titulo de la actividad de origen. Si un archivo ya fue reutilizado antes, aparece una fila por cada actividad de origen distinta. Paginacion ?pagina= (default 1) / ?size= (default 20). total_count via COUNT(*) OVER(). Gate VER sobre PLANEADOR.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/actividades/:ID/materiales-reutilizables'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT academico_test.fn_actividad_material_reemplazar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.MATERIALES AS JSONB)
) AS cantidad;',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades/:ID/materiales', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT", "BODY.MATERIALES": "JSONB"}'::jsonb,
    'V246 -- reemplazo completo de los materiales de apoyo de una actividad (fn_actividad_material_reemplazar, V224). :ID = PK_TACTIVIDAD. BODY.MATERIALES (obligatorio, array JSON; array vacio = dejarla sin materiales) = [{"tipoRecurso": PK TLISTA_VALOR categoria TIPO_RECURSO, "url": "..."|"fkTarchivo": N, "descripcion": "?"}], EXACTAMENTE uno de url/fkTarchivo por elemento. Para REUTILIZAR un archivo de otra actividad (picker GET .../materiales-reutilizables) se pasa el mismo fkTarchivo con tipoRecurso=REPOSITORIO. ORDEN se fija por la posicion en el array. Retorna la cantidad de materiales que quedaron activos. Gate EDITAR sobre PLANEADOR. 22023 si el array no cumple el formato; 23503 si algun fkTarchivo no existe.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/actividades/:ID/materiales'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT academico_test.fn_actividad_adaptacion_reemplazar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.ADAPTACIONES AS JSONB)
) AS cantidad;',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades/:ID/adaptaciones', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT", "BODY.ADAPTACIONES": "JSONB"}'::jsonb,
    'V246 -- reemplazo completo de las adaptaciones curriculares de una actividad (fn_actividad_adaptacion_reemplazar, V224). :ID = PK_TACTIVIDAD. BODY.ADAPTACIONES (obligatorio, array JSON; array vacio = quitarlas todas) = [{"tipoAdaptacion": PK TLISTA_VALOR TIPO_ADAPTACION, "descripcion": "..." (obligatorio, max 500), "usaVersionModificada": "S"|"N" (default N), "formatoAdaptacion": PK FORMATO_ADAPTACION (si S: ARCHIVO/ENLACE/BIBLIOTECA), "fkTarchivo": N (si ARCHIVO/BIBLIOTECA), "url": "..." (si ENLACE), "aplicaA": PK APLICA_A (TODO_EL_GRUPO/ESTUDIANTES_SELECCIONADOS), "estudiantes": [pk_tmatricula,...] (si ESTUDIANTES_SELECCIONADOS -- deben estar YA asignados a la actividad via TACTIVIDAD_ESTUDIANTE)}]. Una actividad SIN unidad SI puede tener adaptaciones (confirmado con negocio: independiente de si se evalua). Gate EDITAR sobre PLANEADOR. 22023 si el array no cumple el formato o algun estudiante no esta asignado a la actividad.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/actividades/:ID/adaptaciones'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT academico_test.fn_actividad_observar_grupal(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.OBSERVACION AS TEXT),
    COALESCE(CAST(:BODY.FECHA AS DATE), CURRENT_DATE),
    CAST(:BODY.EVIDENCIAS AS BIGINT[])
) AS estudiantes_observados;',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades/:ID/observar-grupal', 'SELECT', 'POST',
    '{"PARAM.ID": "BIGINT", "BODY.OBSERVACION": "VARCHAR", "BODY.FECHA": "DATE", "BODY.EVIDENCIAS": "BIGINT[]"}'::jsonb,
    'V246 -- aplica la MISMA observacion (texto libre) a todos los estudiantes activos de una actividad FORMATIVA (preescolar/"Proyecto Pedagogico"; fn_actividad_observar_grupal, V243). :ID = PK_TACTIVIDAD. BODY.OBSERVACION obligatoria (no vacia); BODY.FECHA opcional (default hoy) para el gate de asistencia. Por cada estudiante exige asistencia valida ese dia; si un estudiante puntual no la tiene se OMITE (no detiene al resto). Guarda OBSERVACION + CALIFICACION=NULL + CALIFICABLE=N. Retorna la cantidad de estudiantes efectivamente observados. BODY.EVIDENCIAS (BIGINT[] de PK_TARCHIVO, opcional) adjunta las imagenes/archivos de la observacion, con semantica de REEMPLAZO: omitirlo no toca los adjuntos, un array vacio los quita. El binario se sube ANTES por el file-service (POST /api/files/**) y aqui solo viajan los PK. Se guardan en TACTIVIDAD_SOPORTE, que es N:1 y por eso admite VARIAS imagenes por observacion; se leen en GET /planeador/actividades/estudiantes/:ID/nota (columna evidencias). Las evidencias se adjuntan a CADA estudiante observado: en la grupal son las fotos de la sesion, no unas por estudiante. Gate EDITAR sobre PLANEADOR. 22023 si la actividad no es FORMATIVA (tiene referente EVALUATIVO o no tiene unidad) -- usar el endpoint de calificar con nota numerica en ese caso; 404 (P0002) si la actividad no existe.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/actividades/:ID/observar-grupal'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT academico_test.fn_actividad_observar_estudiante(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.OBSERVACION AS TEXT),
    COALESCE(CAST(:BODY.FECHA AS DATE), CURRENT_DATE),
    CAST(:BODY.EVIDENCIAS AS BIGINT[])
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades/estudiantes/:ID/observar', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT", "BODY.OBSERVACION": "VARCHAR", "BODY.FECHA": "DATE", "BODY.EVIDENCIAS": "BIGINT[]"}'::jsonb,
    'V246 -- comentario particular de UN estudiante para una actividad FORMATIVA (preescolar; fn_actividad_observar_estudiante, V243). :ID = PK_TACTIVIDAD_ESTUDIANTE (NO PK_TACTIVIDAD). Sobreescribe lo que haya dejado la observacion grupal (o una llamada previa) para ese estudiante puntual. BODY.OBSERVACION obligatoria; BODY.FECHA opcional (default hoy). A diferencia de la grupal, PROPAGA el error de asistencia si no la hay (accion puntual). Gate EDITAR sobre PLANEADOR. 22023 si la actividad de ese estudiante no es FORMATIVA o si no hay asistencia valida ese dia; 404 (P0002) si la asignacion actividad-estudiante no existe.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/actividades/estudiantes/:ID/observar'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT academico_test.fn_actividad_evidencia_relacionar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.FK_REFERENTE_ENUNCIADO AS BIGINT)
) AS pk_tactividad_evidencia;',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades/:ID/evidencias', 'SELECT', 'POST',
    '{"PARAM.ID": "BIGINT", "BODY.FK_REFERENTE_ENUNCIADO": "BIGINT"}'::jsonb,
    'V246 -- relaciona (o reactiva) una evidencia del referente curricular (TREFERENTE_ENUNCIADO nivel 2, FK_PADRE NOT NULL) con la actividad :ID (fn_actividad_evidencia_relacionar, V214.1). :ID = PK_TACTIVIDAD (FK_TACTIVIDAD de la relacion). Exige que la actividad tenga FK_TUNIDAD y que el enunciado padre de la evidencia ya este relacionado (activo) con esa misma unidad via TUNIDAD_ENUNCIADO (POST /planeador/unidades/:ID/enunciados, V245). Retorna PK_TACTIVIDAD_EVIDENCIA. Gate EDITAR sobre PLANEADOR. 23503 si la actividad o la evidencia no existen/no estan activas; 22023 si la actividad no tiene unidad, el PK es un enunciado (nivel 1) en vez de evidencia, o el enunciado padre no esta relacionado con la unidad.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/actividades/:ID/evidencias'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT academico_test.fn_actividad_evidencia_quitar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
) AS eliminado;',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades/evidencias/:ID', 'SELECT', 'PATCH',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    'V246 -- borrado logico (ACTIVE=FALSE) de una relacion actividad<->evidencia (fn_actividad_evidencia_quitar, V214.1). :ID = PK_TACTIVIDAD_EVIDENCIA. Gate EDITAR sobre PLANEADOR. 23503 si la relacion no existe o ya esta inactiva.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/actividades/evidencias/:ID'
   AND q.http_method   = 'PATCH'
ON CONFLICT DO NOTHING;

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT academico_test.fn_actividad_criterio_relacionar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.FK_TCRITERIO_UNIDAD AS BIGINT)
) AS pk_tactividad_criterio_unidad;',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades/:ID/criterios', 'SELECT', 'POST',
    '{"PARAM.ID": "BIGINT", "BODY.FK_TCRITERIO_UNIDAD": "BIGINT"}'::jsonb,
    'V246 -- relaciona (o reactiva) un criterio de la rubrica de la unidad (TCRITERIO_UNIDAD) con la actividad :ID (fn_actividad_criterio_relacionar, V214.1). :ID = PK_TACTIVIDAD (FK_TACTIVIDAD de la relacion). Exige que la actividad tenga FK_TUNIDAD y que el criterio pertenezca a la rubrica (TRUBRICA_UNIDAD) de esa misma unidad (rubrica gestionada en POST /planeador/unidades/:ID/criterios, V245). Retorna PK_TACTIVIDAD_CRITERIO_UNIDAD. Gate EDITAR sobre PLANEADOR. 23503 si la actividad o el criterio no existen/no estan activos; 22023 si la actividad no tiene unidad o el criterio pertenece a la rubrica de otra unidad.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/actividades/:ID/criterios'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT academico_test.fn_actividad_criterio_quitar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
) AS eliminado;',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades/criterios/:ID', 'SELECT', 'PATCH',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    'V246 -- borrado logico (ACTIVE=FALSE) de una relacion actividad<->criterio de rubrica (fn_actividad_criterio_quitar, V214.1). :ID = PK_TACTIVIDAD_CRITERIO_UNIDAD. Gate EDITAR sobre PLANEADOR. 23503 si la relacion no existe o ya esta inactiva.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/actividades/criterios/:ID'
   AND q.http_method   = 'PATCH'
ON CONFLICT DO NOTHING;

UPDATE public.query q
   SET query       = replace(q.query,
                             'COALESCE(CAST(:BODY.FECHA AS DATE), CURRENT_DATE)' || chr(10) || ')',
                             'COALESCE(CAST(:BODY.FECHA AS DATE), CURRENT_DATE),' || chr(10)
                             || '    CAST(:BODY.EVIDENCIAS AS BIGINT[])' || chr(10) || ')'),
       param_types = COALESCE(q.param_types, '{}'::jsonb) || '{"BODY.EVIDENCIAS": "BIGINT[]"}'::jsonb
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template IN ('/planeador/actividades/:ID/observar-grupal',
                           '/planeador/actividades/estudiantes/:ID/observar')
   AND q.query NOT LIKE '%:BODY.EVIDENCIAS%';
