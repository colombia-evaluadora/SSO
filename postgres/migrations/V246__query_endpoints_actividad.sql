-- ===========================================================================
-- V246 — Planeador educativo: registro en public.query (motor SSO /
-- query-service) de los endpoints del dominio ACTIVIDAD (CU-86e311xxp,
-- LOTE 2 de la tanda de endpoints del Planeador).
--
-- Este archivo NO crea funciones nuevas: las funciones ya existen y estan
-- validadas en esta rama (V224, V137, V223, V244, V243, V136). Solo registra
-- las filas public.query (+ role_query) para exponerlas via el gateway como
-- api/eval-col/... . El LOTE 1 (V245, dominio UNIDAD) y el lote de
-- INSTRUMENTOS (V226/V240/V241, en paralelo) registran sus propios
-- endpoints por separado -- NO se duplican aqui ni se expone nada de
-- instrumentos (rubrica/cotejo/escala).
--
-- microservice_id se resuelve por serviceid='eval-col' (mismo microservicio
-- que sirve el resto del modulo academico -- V51/V64/V149/V185/V198/V199/V245).
--
-- p_pk_usuario_solicitante SIEMPRE se resuelve de :CONTEXT.USER_ID via
-- public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT) -- igual que
-- V149/V167/V168/V185/V198/V199/V245 -- nunca se expone como parametro
-- editable por el cliente.
--
-- AUTORIZACION
--   El gate real (capability CREAR/VER/EDITAR/ELIMINAR sobre la seccion
--   PLANEADOR, TROL_MENU + TUSUARIO_ROL_PERMISO) lo hace cada funcion via
--   fn_assert_permiso_seccion (V29/V185/V213/V216). role_query aqui NO
--   sustituye ese gate, solo decide que ROLES DE public.role pueden llamar
--   al endpoint por el gateway -- role_query NO tiene bypass de admin
--   (a diferencia de otras rutas, aqui no hay atajo para SSO-ADMIN/ADMIN
--   salvo que el rol este explicitamente listado).
--
--   Mismo criterio ya aplicado (y funcionando) en V245/V214: en este
--   Postgres local de Docker solo existe el rol 'CEVAL-SUPER_ADMINISTRADOR'
--   sincronizado a public.role (el catalogo real de TROL -- DOCENTE, RECTOR,
--   etc -- no esta sembrado en las migraciones, ver nota "TROL: el catalogo
--   de roles no esta en las migraciones" en memoria del proyecto). Cuando el
--   ambiente real tenga el rol de DOCENTE sincronizado, agregar esa fila a
--   role_query es un cambio de una linea (INSERT posterior a
--   public.role_query, no requiere tocar esta migracion).
--
-- CAVEAT DE RECARGA (dejar constancia, igual que V149/V167/V185/V198/V199/V245):
--   Las filas nuevas en public.query dan 404 por el gateway hasta que el
--   contenedor query-service-eval-col se reinicia. No aplica a esta
--   validacion SQL (fuera de alcance segun el enunciado de la tarea).
--
-- CONVENCIONES DE PARAMETROS (V32/V49, igual que V245):
--   :PARAM.<VAR>   -> variable de la ruta (path_template ...:VAR...).
--   :QUERY.<VAR>   -> filtro por query-string (?var=...); QUERY.SIZE/
--                     QUERY.OFFSET son system-bound (paginacion), el resto
--                     de nombres de QUERY.* SI necesita entrada en
--                     param_types.
--   :BODY.<VAR>    -> campo del body JSON.
--   :CONTEXT.*     -> system-bound (JWT verificado), nunca en param_types.
--
-- execution_mode = 'SELECT' en TODAS las filas (incluidas las de escritura):
--   "SELECT * FROM fn_x(...)" sigue siendo una sentencia SELECT aunque fn_x
--   escriba por dentro -- mismo patron que V64/V149/V185/V198/V199/V245.
--
-- DELETE -> PATCH: el CHECK ck_query_http_method de public.query solo admite
-- {GET,POST,PUT,PATCH} -- no existe DELETE en este catalogo. Los borrados
-- logicos / desvinculaciones de este lote (eliminar actividad, quitar
-- evidencia, quitar criterio) se registran como PATCH, mismo criterio ya
-- documentado en V149/V245.
--
-- NOMENCLATURA DE RUTAS (decision de este lote):
--   * /planeador/actividades                              (coleccion)
--   * /planeador/actividades/:ID                           (recurso, PK_TACTIVIDAD)
--   * /planeador/actividades/:ID/configuracion              (GET, secciones
--     dinamicas -- ver punto 6 mas abajo, el mas importante del pedido)
--   * /planeador/actividades/huerfanas                      (GET, sin unidad)
--   * /planeador/unidades/:ID/actividades-disponibles       (GET, candidatas
--     a vincularse a ESA unidad -- vive bajo /unidades porque el parametro de
--     ruta es PK_TUNIDAD, no PK_TACTIVIDAD; distinto de
--     /planeador/unidades/:ID/actividades de V245, que lista las YA
--     vinculadas)
--   * /planeador/actividades/:ID/materiales-reutilizables   (GET, picker)
--   * /planeador/actividades/:ID/materiales                 (PUT, reemplazo)
--   * /planeador/actividades/:ID/adaptaciones               (PUT, reemplazo)
--   * /planeador/actividades/:ID/observar-grupal            (POST, preescolar)
--   * /planeador/actividades/estudiantes/:ID/observar       (PUT, :ID =
--     PK_TACTIVIDAD_ESTUDIANTE, no PK_TACTIVIDAD -- ver punto 13)
--   * /planeador/actividades/:ID/evidencias                 (POST)
--   * /planeador/actividades/evidencias/:ID                 (PATCH, :ID =
--     PK_TACTIVIDAD_EVIDENCIA)
--   * /planeador/actividades/:ID/criterios                  (POST)
--   * /planeador/actividades/criterios/:ID                  (PATCH, :ID =
--     PK_TACTIVIDAD_CRITERIO_UNIDAD)
--
-- DECISIONES DE ALCANCE (documentadas, no son olvidos):
--   * fn_actividad_es_formativa NO se expone standalone: es un helper
--     booleano puro (BOOLEAN, sin gate VER propio, ver su propio COMMENT en
--     V243) consumido internamente por fn_actividad_nota_calificar y
--     fn_actividad_observar_grupal/_estudiante para decidir la rama de
--     negocio; el front ya recibe la senal equivalente (mas rica: visible/
--     requerido/motivo) via el bloque "evaluacion" de
--     fn_actividad_campos_disponibles (punto 6) y via los propios mensajes
--     22023 de calificar/observar cuando la rama no aplica. Exponerlo aparte
--     duplicaria una fuente de verdad sin aportar informacion nueva al
--     cliente.
--   * fn_actividad_estudiantes_asignar y fn_actividad_recuperacion_configurar
--     NO se exponen standalone: son helpers de fn_actividad_crear/_actualizar
--     (llamados desde adentro con los parametros p_fk_tmatriculas/
--     p_asignar_todo_el_grupo y p_recuperacion/p_quitar_recuperacion, puntos
--     1 y 2 de este archivo) -- exponerlos aparte permitiria escribir esas
--     tablas saltandose la validacion de coherencia que crear/actualizar ya
--     hacen sobre el resto de la actividad (p.ej. p_recuperacion exige
--     ES_EVALUATIVA='S' evaluado sobre el estado RESULTANTE completo).
--   * fn_actividad_resumen_estados y fn_actividad_calendario (V224, tarjetas
--     del tablero y grilla mensual) y fn_actividad_lv_assert / fn_actividad_estado
--     (helpers puros) quedan FUERA DE ALCANCE de este lote -- no estan en la
--     lista de funciones a registrar del enunciado; se registran en un lote
--     posterior si se confirma la pantalla de tablero/calendario.
--
-- Depende de (orden de version de Flyway): V224 (CRUD + helpers de
-- actividad), V137 (campos dinamicos / configuracion), V223 (disponibles por
-- unidad), V244 (huerfanas), V243 (observar preescolar), V136 (evidencias /
-- criterios de unidad).
-- ===========================================================================


-- ===========================================================================
-- 1. POST /planeador/actividades — fn_actividad_crear (V224).
-- ===========================================================================
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


-- ===========================================================================
-- 2. PUT /planeador/actividades/:ID — fn_actividad_actualizar (V224, PATCH
--    parcial).
-- ===========================================================================
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
    COALESCE(CAST(:BODY.QUITAR_RECUPERACION AS BOOLEAN), FALSE)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades/:ID', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT", "BODY.TITULO": "VARCHAR", "BODY.DESCRIPCION": "VARCHAR", "BODY.FK_TASIGNATURA": "BIGINT", "BODY.FK_TGRUPO": "BIGINT", "BODY.FK_TUNIDAD": "BIGINT", "BODY.PONDERACION": "NUMERIC", "BODY.DESVINCULAR_UNIDAD": "BOOLEAN", "BODY.FK_TLV_TIPO_ACTIVIDAD": "BIGINT", "BODY.FECHA_INICIO": "DATE", "BODY.FECHA_CIERRE": "DATE", "BODY.DURACION_ESTIMADA": "NUMERIC", "BODY.SEMANA_CRONOGRAMA": "VARCHAR", "BODY.FK_TLV_MODALIDAD": "BIGINT", "BODY.MATERIAL_REQUERIDO": "VARCHAR", "BODY.ES_EVALUATIVA": "VARCHAR", "BODY.FK_TLV_INSTRUMENTO_EVALUACION": "BIGINT", "BODY.DESCRIPCION_INSTRUMENTO": "VARCHAR", "BODY.FK_TLV_TIPO_EVIDENCIA": "BIGINT", "BODY.FK_TLV_METODO_VALORACION": "BIGINT", "BODY.FK_TLV_TIPO_CALCULO": "BIGINT", "BODY.INFLUENCIA": "NUMERIC", "BODY.NOTA_MAXIMA": "NUMERIC", "BODY.REQUIERE_ARCHIVO": "VARCHAR", "BODY.REQUIERE_TEXTO": "VARCHAR", "BODY.GENERA_EVIDENCIAS": "VARCHAR", "BODY.REQUIERE_VALIDACION_COORDINADOR": "VARCHAR", "BODY.OBSERVACIONES_DOCENTE": "VARCHAR", "BODY.MATERIALES": "JSONB", "BODY.ADAPTACIONES": "JSONB", "BODY.FK_TMATRICULAS": "BIGINT[]", "BODY.ASIGNAR_TODO_EL_GRUPO": "BOOLEAN", "BODY.RECUPERACION": "JSONB", "BODY.QUITAR_RECUPERACION": "BOOLEAN"}'::jsonb,
    'V246 -- PATCH parcial de una actividad (fn_actividad_actualizar, V224). :ID = PK_TACTIVIDAD. Cada campo ausente/NULL preserva el valor actual; MATERIALES/ADAPTACIONES/FK_TMATRICULAS: NULL = no tocar, array (incl. vacio) = reemplazo completo. DESVINCULAR_UNIDAD=true es excluyente con FK_TUNIDAD/PONDERACION (unidad/ponderacion se delegan en fn_unidad_actividad_vincular/_ponderacion_set/_desvincular, V223, mismo punto unico de la regla del 100%). QUITAR_RECUPERACION=true es excluyente con RECUPERACION. Revalida fechas, catalogos, unicidad (titulo, unidad, grupo, jerarquia) y las condiciones dinamicas de evaluacion/ponderacion contra los valores RESULTANTES del PATCH (ver campos_disponibles del punto 6). Gate EDITAR sobre PLANEADOR. 404 (P0002) si la actividad no existe; 22023 si esta inactiva.'
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


-- ===========================================================================
-- 3. PATCH /planeador/actividades/:ID — fn_actividad_eliminar (V224, soft
--    delete en cascada; bloquea si tiene notas registradas o es recuperada
--    por otra actividad activa). DELETE -> PATCH: ver nota de cabecera.
-- ===========================================================================
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


-- ===========================================================================
-- 4. GET /planeador/actividades/:ID — fn_actividad_buscar_por_pk (V224,
--    detalle completo).
-- ===========================================================================
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
    'V246 -- detalle completo de una actividad (fn_actividad_buscar_por_pk, V224): todos los campos con nombres de catalogo resueltos, estado DERIVADO (?diasGracia=, default 2), progreso de evaluacion (asignados/evaluados), materiales/adaptaciones como JSONB, config de recuperacion (o NULL), campos_disponibles (secciones dinamicas -- ver punto 6, misma funcion) y unidad_configuracion (snapshot de la unidad: objetivos, contenidos, referente curricular, rubrica, enunciados/evidencias). :ID = PK_TACTIVIDAD. SETOF 0 o 1 fila (incluye inactivas). Gate VER sobre PLANEADOR.'
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


-- ===========================================================================
-- 5. GET /planeador/actividades — fn_actividad_listar (V224, paginado +
--    filtros; buscador unico nombre/nivel/instrumento).
-- ===========================================================================
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
    COALESCE(CAST(:QUERY.OFFSET AS INT), 0)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades', 'SELECT', 'GET',
    '{"QUERY.SEARCH": "VARCHAR", "QUERY.ASIGNATURA": "BIGINT", "QUERY.GRUPO": "BIGINT", "QUERY.UNIDAD": "BIGINT", "QUERY.TIPO_ACTIVIDAD": "BIGINT", "QUERY.INSTRUMENTO": "BIGINT", "QUERY.FECHA_DESDE": "DATE", "QUERY.FECHA_HASTA": "DATE", "QUERY.ESTADOS": "TEXT[]", "QUERY.DIAS_GRACIA": "INT", "QUERY.INCLUIR_INACTIVAS": "BOOLEAN", "QUERY.ORDEN_POR": "VARCHAR", "QUERY.ORDEN_ASC": "BOOLEAN"}'::jsonb,
    'V246 -- pagina de actividades (fn_actividad_listar, V224) con filtros indexados ?asignatura=, ?grupo=, ?unidad=, ?tipoActividad=, ?instrumento= y ventana ?fechaDesde=/?fechaHasta=. ?search= es el buscador unico "nombre, nivel educativo o instrumento" (titulo+descripcion via trigram, o nivel de ensenanza de la unidad, o nombre del instrumento). ?estados= filtra por el estado DERIVADO (array de FINALIZADA/VENCIDA/PENDIENTE_POR_EVALUAR/PROGRAMADA/EN_EVALUACION/SIN_PROGRAMAR), ?diasGracia= (default 2) ajusta el umbral de VENCIDA. ?incluirInactivas= (default false). ?ordenPor= (whitelist fecha_inicio|fecha_cierre|fecha_creacion|titulo|ponderacion, cualquier otro cae a fecha_inicio) / ?ordenAsc=. Paginacion system-bound ?size=/?offset= (default 20/0). Devuelve nombres resueltos (asignatura, area, unidad, grupo, tipo, instrumento), estado derivado y progreso de evaluacion (asignados/evaluados/%). total_count via COUNT(*) OVER(). Gate VER sobre PLANEADOR.'
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


-- ===========================================================================
-- 6. GET /planeador/actividades/:ID/configuracion — "visualizacion construida
--    por endpoint" / secciones dinamicas del formulario de actividad
--    (fn_actividad_campos_disponibles + fn_actividad_unidad_configuracion,
--    V137). ESTE ES EL ENDPOINT MAS IMPORTANTE DEL PEDIDO ORIGINAL: le dice
--    al front, para ESTA actividad puntual, que secciones/campos del
--    formulario mostrar habilitados/deshabilitados y POR QUE.
--
--    campos_disponibles = {
--      criterio:   {visible, requerido, motivo}                       -- la
--        seccion "Relacionar con criterio de rubrica" se OCULTA solo si el
--        nivel de ensenanza del grado de la unidad es Preescolar; en
--        cualquier otro nivel es visible y OPCIONAL (nunca requerida).
--      evaluacion: {visible, requerido, motivo, instrumentosPermitidos}  --
--        la seccion "Evaluacion" (instrumento, ponderacion, etc.) se
--        muestra y se EXIGE solo si la actividad tiene unidad y el
--        referente curricular de esa unidad es EVALUATIVO;
--        instrumentosPermitidos ya viene FILTRADO por el TIPO_EVALUACION
--        del referente (CUALITATIVA -> Rubrica/Lista de cotejo;
--        CUANTITATIVA -> Escala de valoracion; CUANTITATIVA_CUALITATIVA o
--        sin tipo -> los 4; Otro siempre disponible).
--      ponderacion: {visible, requerido, modo, motivo, autocalculado?,
--        campo?} -- el campo "Ponderacion (%)" se oculta si la actividad no
--        tiene unidad o no es evaluativa; si aplica, el METODO DE CALCULO
--        de la unidad (Ponderar/Sumatoria/Promediar, V73) decide si se
--        captura el % a mano (modo PORCENTAJE, campo PONDERACION) o el
--        puntaje (modo PUNTAJE, campo NOTA_MAXIMA, autocalculado=true --
--        el sistema calcula el % solo).
--    }
--    unidad_configuracion = snapshot de la unidad relacionada (objetivos,
--      contenidos, referente curricular, rubrica con criterios/niveles,
--      enunciados/evidencias) o {tieneUnidad:false} si la actividad no
--      tiene unidad -- para pintar de un tiro todo lo heredado sin otro
--      round-trip a /planeador/unidades/:ID.
-- ===========================================================================
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
    'V246 -- "visualizacion construida por endpoint": secciones dinamicas habilitadas/deshabilitadas del formulario de actividad para ESTA actividad puntual, con el MOTIVO de cada decision (fn_actividad_campos_disponibles + fn_actividad_unidad_configuracion, V137). :ID = PK_TACTIVIDAD. campos_disponibles = {criterio:{visible,requerido,motivo} -- oculto solo en Preescolar, opcional en el resto; evaluacion:{visible,requerido,motivo,instrumentosPermitidos} -- visible/requerido solo si la unidad tiene referente EVALUATIVO, instrumentosPermitidos ya filtrado por el TIPO_EVALUACION del referente; ponderacion:{visible,requerido,modo,motivo,autocalculado?,campo?} -- oculto sin unidad o si ES_EVALUATIVA=N, si aplica el modo (PORCENTAJE sobre PONDERACION, o PUNTAJE autocalculado sobre NOTA_MAXIMA) lo decide el metodo de calculo de la unidad (V73)}. unidad_configuracion = snapshot completo de la unidad relacionada (objetivos, contenidos, referente curricular, rubrica con criterios/niveles, enunciados/evidencias) o {"tieneUnidad":false} si la actividad no tiene unidad. Gate VER sobre PLANEADOR (en ambas funciones). 404 (P0002) si la actividad no existe.'
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


-- ===========================================================================
-- 7. GET /planeador/actividades/huerfanas — fn_actividad_huerfanas_listar
--    (V244, actividades sin unidad).
-- ===========================================================================
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
    'V246 -- actividades sin unidad (TACTIVIDAD.FK_TUNIDAD IS NULL, ACTIVE) para la pantalla de vinculacion posterior (fn_actividad_huerfanas_listar, V244). Filtros ?search= (trigram TITULO+DESCRIPCION), ?asignatura=, ?grupo=, ?fechaDesde=/?fechaHasta=. No proyecta PONDERACION (siempre NULL en una huerfana). Paginacion ?pagina= (default 1) / ?size= (default 20; tamano_pagina de la funcion). Para vincular una fila del resultado usar PUT /planeador/unidades/:ID/actividades/:ACTIVIDADID (V245). total_count via COUNT(*) OVER(). Gate VER sobre PLANEADOR.'
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


-- ===========================================================================
-- 8. GET /planeador/unidades/:ID/actividades-disponibles —
--    fn_actividad_disponibles_listar (V223; candidatas a vincularse a ESA
--    unidad; :ID = PK_TUNIDAD, distinto de .../:ID/actividades de V245 que
--    lista las YA vinculadas).
-- ===========================================================================
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_actividad_disponibles_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:QUERY.SEARCH AS VARCHAR),
    COALESCE(CAST(:QUERY.PAGINA AS INT), 1),
    COALESCE(CAST(:QUERY.SIZE AS INT), 20)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/unidades/:ID/actividades-disponibles', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT", "QUERY.SEARCH": "VARCHAR", "QUERY.PAGINA": "INT"}'::jsonb,
    'V246 -- actividades candidatas a vincularse a la unidad :ID (modal "Vincular actividad"; fn_actividad_disponibles_listar, V223). :ID = PK_TUNIDAD. Candidata = ACTIVE, sin unidad (FK_TUNIDAD IS NULL), misma asignatura que la unidad, y mismo grado via el grupo de la actividad (sin grupo tambien es candidata). ?search= (trigram TITULO+DESCRIPCION). Devuelve tipo/instrumento resueltos, grupo y porcentaje_disponible = fn_unidad_ponderacion_disponible(unidad, grupo de esa fila) para pintar "Disponible para asignar: X%". Paginacion ?pagina= (default 1) / ?size= (default 20). total_count via COUNT(*) OVER(). Gate VER sobre PLANEADOR. 404 (P0002) si la unidad no existe.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/unidades/:ID/actividades-disponibles'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;


-- ===========================================================================
-- 9. GET /planeador/actividades/:ID/materiales-reutilizables —
--    fn_actividad_materiales_reutilizables_listar (V224, picker de reuso).
-- ===========================================================================
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


-- ===========================================================================
-- 10. PUT /planeador/actividades/:ID/materiales — fn_actividad_material_reemplazar
--     (V224, reemplazo completo de materiales de apoyo).
-- ===========================================================================
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


-- ===========================================================================
-- 11. PUT /planeador/actividades/:ID/adaptaciones —
--     fn_actividad_adaptacion_reemplazar (V224, reemplazo completo de
--     adaptaciones curriculares).
-- ===========================================================================
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


-- ===========================================================================
-- 12. POST /planeador/actividades/:ID/observar-grupal —
--     fn_actividad_observar_grupal (V243, preescolar/formativo).
-- ===========================================================================
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT academico_test.fn_actividad_observar_grupal(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.OBSERVACION AS TEXT),
    COALESCE(CAST(:BODY.FECHA AS DATE), CURRENT_DATE)
) AS estudiantes_observados;',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades/:ID/observar-grupal', 'SELECT', 'POST',
    '{"PARAM.ID": "BIGINT", "BODY.OBSERVACION": "VARCHAR", "BODY.FECHA": "DATE"}'::jsonb,
    'V246 -- aplica la MISMA observacion (texto libre) a todos los estudiantes activos de una actividad FORMATIVA (preescolar/"Proyecto Pedagogico"; fn_actividad_observar_grupal, V243). :ID = PK_TACTIVIDAD. BODY.OBSERVACION obligatoria (no vacia); BODY.FECHA opcional (default hoy) para el gate de asistencia. Por cada estudiante exige asistencia valida ese dia; si un estudiante puntual no la tiene se OMITE (no detiene al resto). Guarda OBSERVACION + CALIFICACION=NULL + CALIFICABLE=N. Retorna la cantidad de estudiantes efectivamente observados. Gate EDITAR sobre PLANEADOR. 22023 si la actividad no es FORMATIVA (tiene referente EVALUATIVO o no tiene unidad) -- usar el endpoint de calificar con nota numerica en ese caso; 404 (P0002) si la actividad no existe.'
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


-- ===========================================================================
-- 13. PUT /planeador/actividades/estudiantes/:ID/observar —
--     fn_actividad_observar_estudiante (V243; :ID = PK_TACTIVIDAD_ESTUDIANTE,
--     NO PK_TACTIVIDAD -- de ahi el segmento /estudiantes/ antes del :ID,
--     mismo criterio de desambiguacion de :ID que
--     /planeador/unidades/criterios/:ID de V245).
-- ===========================================================================
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT academico_test.fn_actividad_observar_estudiante(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.OBSERVACION AS TEXT),
    COALESCE(CAST(:BODY.FECHA AS DATE), CURRENT_DATE)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades/estudiantes/:ID/observar', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT", "BODY.OBSERVACION": "VARCHAR", "BODY.FECHA": "DATE"}'::jsonb,
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


-- ===========================================================================
-- 14. POST /planeador/actividades/:ID/evidencias —
--     fn_actividad_evidencia_relacionar (V136).
-- ===========================================================================
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
    'V246 -- relaciona (o reactiva) una evidencia del referente curricular (TREFERENTE_ENUNCIADO nivel 2, FK_PADRE NOT NULL) con la actividad :ID (fn_actividad_evidencia_relacionar, V136). :ID = PK_TACTIVIDAD (FK_TACTIVIDAD de la relacion). Exige que la actividad tenga FK_TUNIDAD y que el enunciado padre de la evidencia ya este relacionado (activo) con esa misma unidad via TUNIDAD_ENUNCIADO (POST /planeador/unidades/:ID/enunciados, V245). Retorna PK_TACTIVIDAD_EVIDENCIA. Gate EDITAR sobre PLANEADOR. 23503 si la actividad o la evidencia no existen/no estan activas; 22023 si la actividad no tiene unidad, el PK es un enunciado (nivel 1) en vez de evidencia, o el enunciado padre no esta relacionado con la unidad.'
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


-- ===========================================================================
-- 15. PATCH /planeador/actividades/evidencias/:ID —
--     fn_actividad_evidencia_quitar (V136; :ID = PK_TACTIVIDAD_EVIDENCIA).
-- ===========================================================================
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
    'V246 -- borrado logico (ACTIVE=FALSE) de una relacion actividad<->evidencia (fn_actividad_evidencia_quitar, V136). :ID = PK_TACTIVIDAD_EVIDENCIA. Gate EDITAR sobre PLANEADOR. 23503 si la relacion no existe o ya esta inactiva.'
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


-- ===========================================================================
-- 16. POST /planeador/actividades/:ID/criterios —
--     fn_actividad_criterio_relacionar (V136).
-- ===========================================================================
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
    'V246 -- relaciona (o reactiva) un criterio de la rubrica de la unidad (TCRITERIO_UNIDAD) con la actividad :ID (fn_actividad_criterio_relacionar, V136). :ID = PK_TACTIVIDAD (FK_TACTIVIDAD de la relacion). Exige que la actividad tenga FK_TUNIDAD y que el criterio pertenezca a la rubrica (TRUBRICA_UNIDAD) de esa misma unidad (rubrica gestionada en POST /planeador/unidades/:ID/criterios, V245). Retorna PK_TACTIVIDAD_CRITERIO_UNIDAD. Gate EDITAR sobre PLANEADOR. 23503 si la actividad o el criterio no existen/no estan activos; 22023 si la actividad no tiene unidad o el criterio pertenece a la rubrica de otra unidad.'
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


-- ===========================================================================
-- 17. PATCH /planeador/actividades/criterios/:ID —
--     fn_actividad_criterio_quitar (V136; :ID = PK_TACTIVIDAD_CRITERIO_UNIDAD).
-- ===========================================================================
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
    'V246 -- borrado logico (ACTIVE=FALSE) de una relacion actividad<->criterio de rubrica (fn_actividad_criterio_quitar, V136). :ID = PK_TACTIVIDAD_CRITERIO_UNIDAD. Gate EDITAR sobre PLANEADOR. 23503 si la relacion no existe o ya esta inactiva.'
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
