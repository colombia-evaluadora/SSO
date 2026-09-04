-- ===========================================================================
-- V245 — Planeador educativo: registro en public.query (motor SSO /
-- query-service) de los endpoints del dominio UNIDAD (CU-86e311xxp,
-- LOTE 1 de la tanda de endpoints del Planeador).
--
-- Este archivo NO crea funciones nuevas: las funciones ya existen y estan
-- validadas en esta rama (V216, V222, V136, V223, editada en V244). Solo
-- registra las filas public.query (+ role_query) para exponerlas via el
-- gateway como api/eval-col/... . Otros lotes (actividad, instrumentos,
-- planilla/observar, docente-grupos/huerfanas) registran sus propios
-- endpoints por separado -- NO se duplican aqui.
--
-- microservice_id se resuelve por serviceid='eval-col' (mismo microservicio
-- que sirve el resto del modulo academico -- V51/V64/V149/V185/V198/V199).
--
-- p_pk_usuario_solicitante SIEMPRE se resuelve de :CONTEXT.USER_ID via
-- public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT) -- igual que
-- V149/V167/V168/V185/V198/V199 -- nunca se expone como parametro editable
-- por el cliente.
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
--   El catalogo real de roles academicos (TROL: DOCENTE, SUPER_ADMINISTRADOR,
--   RECTOR, ...) NO esta sembrado en las migraciones de este repo (viene del
--   dump base del servidor -- ver nota "TROL: el catalogo de roles no esta
--   en las migraciones" en memoria del proyecto), y su puente hacia
--   public.role (sincronizado por V111) tampoco trae, en este Postgres local
--   de Docker, un rol 'CEVAL-DOCENTE': solo existe 'CEVAL-SUPER_ADMINISTRADOR'.
--   Se sigue el MISMO patron ya aplicado (y funcionando) en este mismo
--   entorno para los endpoints hermanos de Referente Curricular
--   (/referentes-curriculares/:ID/enunciados, V214, rama CU-86e311xqh):
--   role_query = 'CEVAL-SUPER_ADMINISTRADOR' unicamente. Cuando el ambiente
--   real tenga el rol de DOCENTE sincronizado a public.role, agregar esa
--   fila a role_query es un cambio de una linea (no requiere tocar esta
--   migracion: un INSERT posterior a public.role_query basta).
--
-- CAVEAT DE RECARGA (dejar constancia, igual que V149/V167/V185/V198/V199):
--   Las filas nuevas en public.query dan 404 por el gateway hasta que el
--   contenedor query-service-eval-col se reinicia. No aplica a esta
--   validacion SQL (fuera de alcance segun el enunciado de la tarea).
--
-- CONVENCIONES DE PARAMETROS (V32/V49):
--   :PARAM.<VAR>   -> variable de la ruta (path_template ...:VAR...).
--   :QUERY.<VAR>   -> filtro por query-string (?var=...); QUERY.SIZE/
--                     QUERY.OFFSET son system-bound (paginacion), el resto
--                     de nombres de QUERY.* SI necesita entrada en
--                     param_types (confirmado contra V214, ya aplicada).
--   :BODY.<VAR>    -> campo del body JSON.
--   :CONTEXT.*     -> system-bound (JWT verificado), nunca en param_types.
--
-- execution_mode = 'SELECT' en TODAS las filas (incluidas las de escritura):
--   "SELECT * FROM fn_x(...)" sigue siendo una sentencia SELECT aunque fn_x
--   escriba por dentro -- mismo patron que V64/V149/V185/V198/V199.
--
-- DELETE -> PATCH: el CHECK ck_query_http_method de public.query (verificado
-- contra el Postgres local de Docker) solo admite {GET,POST,PUT,PATCH} -- no
-- existe DELETE en este catalogo. Los 4 endpoints de borrado/desvinculacion
-- de este lote (unidad, criterio, enunciado, actividad-unidad) se registran
-- como PATCH, mismo criterio ya documentado en V149 ("DELETE -> PATCH: ver
-- la nota de desviaciones al inicio del archivo").
-- ===========================================================================


-- ===========================================================================
-- 1. POST /planeador/unidades — fn_unidad_crear (V216).
-- ===========================================================================
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
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
    CAST(:BODY.PONDERACION AS NUMERIC)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/unidades', 'SELECT', 'POST',
    '{"BODY.NOMBRE": "VARCHAR", "BODY.FK_TASIGNATURA": "BIGINT", "BODY.FK_TGRADO": "BIGINT", "BODY.FK_TFUNCIONARIO": "BIGINT", "BODY.FK_TLV_CALCULO_DEFINITIVA": "BIGINT", "BODY.DESCRIPCION": "VARCHAR", "BODY.FK_REFERENTE_CURRICULAR": "BIGINT", "BODY.OBJETIVOS": "TEXT[]", "BODY.CONTENIDOS": "TEXT[]", "BODY.ENUNCIADOS": "BIGINT[]", "BODY.PONDERACION": "NUMERIC"}'::jsonb,
    'V245 -- crea una unidad tematica del Planeador (fn_unidad_crear, V216). Obligatorios: NOMBRE, FK_TASIGNATURA, FK_TGRADO, FK_TFUNCIONARIO, FK_TLV_CALCULO_DEFINITIVA (forma de calculo, catalogo TLISTA_VALOR CATEGORIA=CALCULO_DEFINITIVA). Opcionales: DESCRIPCION, FK_REFERENTE_CURRICULAR, OBJETIVOS/CONTENIDOS (arrays, ORDEN por posicion), ENUNCIADOS (PKs de TREFERENTE_ENUNCIADO nivel 1, via fn_unidad_enunciado_relacionar), PONDERACION (0..100, peso dentro de (asignatura,grado), valida regla del 100% y que el plan de la asignatura la admita). Retorna PK_TUNIDAD. Gate CREAR sobre PLANEADOR (fn_assert_permiso_seccion, dentro de la funcion).'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/unidades'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;


-- ===========================================================================
-- 2. PUT /planeador/unidades/:ID — fn_unidad_actualizar (V216, PATCH parcial).
-- ===========================================================================
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_unidad_actualizar(
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
    COALESCE(CAST(:BODY.LIMPIAR_PONDERACION AS BOOLEAN), FALSE)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/unidades/:ID', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT", "BODY.NOMBRE": "VARCHAR", "BODY.DESCRIPCION": "VARCHAR", "BODY.FK_TASIGNATURA": "BIGINT", "BODY.FK_TGRADO": "BIGINT", "BODY.FK_TFUNCIONARIO": "BIGINT", "BODY.FK_TLV_CALCULO_DEFINITIVA": "BIGINT", "BODY.FK_REFERENTE_CURRICULAR": "BIGINT", "BODY.LIMPIAR_REFERENTE": "BOOLEAN", "BODY.OBJETIVOS": "TEXT[]", "BODY.CONTENIDOS": "TEXT[]", "BODY.PONDERACION": "NUMERIC", "BODY.LIMPIAR_PONDERACION": "BOOLEAN"}'::jsonb,
    'V245 -- PATCH parcial de una unidad (fn_unidad_actualizar, V216). Cada campo del body ausente/NULL preserva el valor actual. LIMPIAR_REFERENTE=true fuerza FK_REFERENTE_CURRICULAR a NULL; LIMPIAR_PONDERACION=true fuerza PONDERACION a NULL. OBJETIVOS/CONTENIDOS: NULL = no tocar, cualquier array (incl. vacio) = reemplazo completo. Revalida FKs, unicidad (nombre, asignatura, grado) y la regla del 100% de PONDERACION contra los valores RESULTANTES del PATCH. :ID = PK_TUNIDAD. Gate EDITAR sobre PLANEADOR. 404 (P0002) si la unidad no existe.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/unidades/:ID'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;


-- ===========================================================================
-- 3. PATCH /planeador/unidades/:ID — fn_unidad_eliminar (V216, soft delete
--    en cascada; bloquea si hay actividades activas vinculadas). DELETE ->
--    PATCH: el CHECK ck_query_http_method de public.query solo admite
--    {GET,POST,PUT,PATCH} (verificado en el Postgres local), mismo criterio
--    que V149.
-- ===========================================================================
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_unidad_eliminar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/unidades/:ID', 'SELECT', 'PATCH',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    'V245 -- soft delete (ACTIVE=FALSE) en cascada de una unidad: niveles -> criterios -> rubrica, objetivos, contenidos y la unidad (fn_unidad_eliminar, V216). :ID = PK_TUNIDAD. Se rechaza (23503) si la unidad todavia tiene actividades ACTIVE vinculadas (TACTIVIDAD.FK_TUNIDAD); desvincularlas antes con PATCH /planeador/unidades/actividades/:ACTIVIDADID o eliminarlas. Gate ELIMINAR sobre PLANEADOR. 404 (P0002) si la unidad no existe.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/unidades/:ID'
   AND q.http_method   = 'PATCH'
ON CONFLICT DO NOTHING;


-- ===========================================================================
-- 4. GET /planeador/unidades/:ID — fn_unidad_buscar_por_pk (V216, detalle).
-- ===========================================================================
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_unidad_buscar_por_pk(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/unidades/:ID', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    'V245 -- detalle de una unidad (fn_unidad_buscar_por_pk, V216): escalares + nombres resueltos (asignatura, area, grado, docente, forma de calculo, referente curricular), Inicio/Fin DERIVADOS (MIN/MAX de fechas de sus actividades activas), objetivos/contenidos como JSONB ordenados, campos_disponibles (dependencia referente->rubrica, V137) y active. :ID = PK_TUNIDAD. SETOF 0 o 1 fila (incluye inactivas). Gate VER sobre PLANEADOR.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/unidades/:ID'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;


-- ===========================================================================
-- 5. GET /planeador/unidades — fn_unidad_listar (V216, paginado + filtros).
-- ===========================================================================
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
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
    COALESCE(CAST(:QUERY.OFFSET AS INT), 0)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/unidades', 'SELECT', 'GET',
    '{"QUERY.SEARCH": "VARCHAR", "QUERY.ASIGNATURA": "BIGINT", "QUERY.GRADO": "BIGINT", "QUERY.FUNCIONARIO": "BIGINT", "QUERY.INCLUIR_INACTIVOS": "BOOLEAN", "QUERY.ORDEN_POR": "VARCHAR", "QUERY.ORDEN_ASC": "BOOLEAN"}'::jsonb,
    'V245 -- pagina de unidades (fn_unidad_listar, V216) con filtros ?search=, ?asignatura=, ?grado=, ?funcionario=, ?incluirInactivos= (default false) y orden ?ordenPor= (whitelist nombre|asignatura|grado, cualquier otro cae a nombre) / ?ordenAsc= (default true). Paginacion system-bound ?size=/?offset= (default 20/0). Devuelve nombres resueltos (asignatura, area, grado, docente, forma de calculo, referente curricular), conteos (actividades/objetivos/contenidos activos), fechas DERIVADAS y total_count via COUNT(*) OVER(). Gate VER sobre PLANEADOR.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/unidades'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;


-- ===========================================================================
-- 6. GET /planeador/unidades/:ID/actividades — fn_unidad_actividades_listar
--    (V216, editada por el DROP+CREATE de la misma migracion para agregar
--    PONDERACION; pestaña "Actividades" del detalle de unidad).
-- ===========================================================================
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
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
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/unidades/:ID/actividades', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT", "QUERY.SEARCH": "VARCHAR", "QUERY.GRUPO": "BIGINT", "QUERY.INCLUIR_INACTIVAS": "BOOLEAN", "QUERY.ORDEN_POR": "VARCHAR", "QUERY.ORDEN_ASC": "BOOLEAN"}'::jsonb,
    'V245 -- actividades vinculadas a una unidad (fn_unidad_actividades_listar, V216) con su PONDERACION (%, TACTIVIDAD.PONDERACION, V223 -- la columna "(%)" de la pantalla; distinta de INFLUENCIA que tambien se devuelve por compatibilidad). :ID = PK_TUNIDAD. Filtros ?search= (TITULO), ?grupo=, ?incluirInactivas= (default false). Orden ?ordenPor= en {actividad,tipo,instrumento,grupo,porcentaje} / ?ordenAsc=. Paginacion ?size=(default 50)/?offset=. total_count via COUNT(*) OVER(). Gate VER sobre PLANEADOR. 404 (P0002) si la unidad no existe.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/unidades/:ID/actividades'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;


-- ===========================================================================
-- 7. GET /planeador/unidades/:ID/objetivos — fn_unidad_objetivos_listar
--    (V216, lista plana para el editor "Nueva unidad").
-- ===========================================================================
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_unidad_objetivos_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/unidades/:ID/objetivos', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    'V245 -- objetivos ACTIVE de una unidad (TUNIDAD_OBJETIVO), ordenados por ORDEN (fn_unidad_objetivos_listar, V216). :ID = PK_TUNIDAD. Gate VER sobre PLANEADOR.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/unidades/:ID/objetivos'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;


-- ===========================================================================
-- 8. GET /planeador/unidades/:ID/contenidos — fn_unidad_contenidos_listar
--    (V216, lista plana para el editor "Nueva unidad").
-- ===========================================================================
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_unidad_contenidos_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/unidades/:ID/contenidos', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    'V245 -- contenidos/componentes ACTIVE de una unidad (TUNIDAD_CONTENIDO), ordenados por ORDEN (fn_unidad_contenidos_listar, V216). :ID = PK_TUNIDAD. Gate VER sobre PLANEADOR.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/unidades/:ID/contenidos'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;


-- ===========================================================================
-- 9. GET /planeador/unidades/:ID/criterios — fn_unidad_criterio_listar
--    (V222, rubrica de la unidad con niveles agregados en JSONB).
-- ===========================================================================
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_unidad_criterio_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    COALESCE(CAST(:QUERY.INCLUIR_INACTIVOS AS BOOLEAN), FALSE)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/unidades/:ID/criterios', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT", "QUERY.INCLUIR_INACTIVOS": "BOOLEAN"}'::jsonb,
    'V245 -- criterios de la rubrica de la unidad (TCRITERIO_UNIDAD), ordenados por ORDEN, con sus niveles (TNIVEL_CRITERIO_UNIDAD) agregados en JSONB ordenado por la valoracion de la escala: [{pk,fkTescalaValoracion,valoracion,orden,indicador,recomendacion,tarea}] (fn_unidad_criterio_listar, V222). :ID = PK_TUNIDAD. ?incluirInactivos= (default false). Gate VER sobre PLANEADOR. 404 (P0002) si la unidad no existe.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/unidades/:ID/criterios'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;


-- ===========================================================================
-- 10. POST /planeador/unidades/:ID/criterios — fn_unidad_criterio_agregar
--     (V216; get-or-create de la rubrica delegado en fn_unidad_rubrica_asegurar
--     de V222, resuelto en tiempo de ejecucion).
-- ===========================================================================
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_unidad_criterio_agregar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.DESCRIPCION AS VARCHAR),
    CAST(:BODY.NIVELES AS JSONB),
    COALESCE(CAST(:BODY.PUBLICO AS VARCHAR), ''S''),
    CAST(:BODY.CODIGO AS VARCHAR),
    COALESCE(CAST(:BODY.DESCRIPTOR_PROM AS VARCHAR), ''N'')
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/unidades/:ID/criterios', 'SELECT', 'POST',
    '{"PARAM.ID": "BIGINT", "BODY.DESCRIPCION": "VARCHAR", "BODY.NIVELES": "JSONB", "BODY.PUBLICO": "VARCHAR", "BODY.CODIGO": "VARCHAR", "BODY.DESCRIPTOR_PROM": "VARCHAR"}'::jsonb,
    'V245 -- agrega un criterio a la rubrica de la unidad (fn_unidad_criterio_agregar, V216; get-or-create de TRUBRICA_UNIDAD delegado en fn_unidad_rubrica_asegurar, V222). :ID = PK_TUNIDAD. BODY.NIVELES = [{"fkTescalaValoracion":N,"indicador":"..","recomendacion":"?","tarea":"?"}], obligatorio EXACTAMENTE un elemento por cada valoracion activa de la escala definida en TCRITERIO_EVALUACION.FK_TESCALA del periodo academico del grado de la unidad (sin faltantes/sobrantes/duplicados). BODY.PUBLICO en {S,N} (default S), BODY.DESCRIPTOR_PROM en {S,N} (default N). Retorna PK_TCRITERIO_UNIDAD. Gate EDITAR sobre PLANEADOR. 22023 si la escala del periodo no esta configurada o el payload no calza exacto con las valoraciones.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/unidades/:ID/criterios'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;


-- ===========================================================================
-- 11. PUT /planeador/unidades/criterios/:ID — fn_unidad_criterio_actualizar
--     (V222, PATCH parcial; :ID = PK_TCRITERIO_UNIDAD).
-- ===========================================================================
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_unidad_criterio_actualizar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.DESCRIPCION AS VARCHAR),
    CAST(:BODY.PUBLICO AS VARCHAR),
    CAST(:BODY.CODIGO AS VARCHAR),
    COALESCE(CAST(:BODY.LIMPIAR_CODIGO AS BOOLEAN), FALSE),
    CAST(:BODY.DESCRIPTOR_PROM AS VARCHAR),
    CAST(:BODY.NIVELES AS JSONB)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/unidades/criterios/:ID', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT", "BODY.DESCRIPCION": "VARCHAR", "BODY.PUBLICO": "VARCHAR", "BODY.CODIGO": "VARCHAR", "BODY.LIMPIAR_CODIGO": "BOOLEAN", "BODY.DESCRIPTOR_PROM": "VARCHAR", "BODY.NIVELES": "JSONB"}'::jsonb,
    'V245 -- PATCH parcial de un criterio de la rubrica de la unidad (fn_unidad_criterio_actualizar, V222). :ID = PK_TCRITERIO_UNIDAD. Campos ausentes/NULL preservan; LIMPIAR_CODIGO=true fuerza CODIGO a NULL. BODY.NIVELES (opcional) = [{"fkTescalaValoracion":N,"indicador":"?","recomendacion":"?","tarea":"?"}] actualiza SOLO los textos de niveles YA existentes de ese criterio (no crea niveles nuevos). Gate EDITAR sobre PLANEADOR. 404 (P0002) si el criterio no existe; 22023 si esta inactivo o un nivel referencia una valoracion ajena al criterio.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/unidades/criterios/:ID'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;


-- ===========================================================================
-- 12. PATCH /planeador/unidades/criterios/:ID — fn_unidad_criterio_eliminar
--     (V222, soft delete del criterio y sus niveles).
-- ===========================================================================
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_unidad_criterio_eliminar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/unidades/criterios/:ID', 'SELECT', 'PATCH',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    'V245 -- soft delete (ACTIVE=FALSE) de un criterio de la rubrica de la unidad y sus niveles (fn_unidad_criterio_eliminar, V222). :ID = PK_TCRITERIO_UNIDAD. No renumera el ORDEN de los criterios restantes. Gate ELIMINAR sobre PLANEADOR. 404 (P0002) si el criterio no existe; 22023 si ya esta inactivo.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/unidades/criterios/:ID'
   AND q.http_method   = 'PATCH'
ON CONFLICT DO NOTHING;


-- ===========================================================================
-- 13. POST /planeador/unidades/:ID/enunciados — fn_unidad_enunciado_relacionar
--     (V136; :ID = FK_TUNIDAD, body FK_REFERENTE_ENUNCIADO).
-- ===========================================================================
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_unidad_enunciado_relacionar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.FK_REFERENTE_ENUNCIADO AS BIGINT)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/unidades/:ID/enunciados', 'SELECT', 'POST',
    '{"PARAM.ID": "BIGINT", "BODY.FK_REFERENTE_ENUNCIADO": "BIGINT"}'::jsonb,
    'V245 -- relaciona (o reactiva) un enunciado del referente curricular (TREFERENTE_ENUNCIADO nivel 1) con la unidad (fn_unidad_enunciado_relacionar, V136). :ID = PK_TUNIDAD (FK_TUNIDAD de la relacion). Valida que el enunciado sea nivel 1 (FK_PADRE IS NULL) y comparta el mismo nivel de ensenanza que la unidad (via TGRADO.FK_TNIVEL_ENSENANZA). Retorna PK_TUNIDAD_ENUNCIADO. Gate EDITAR sobre PLANEADOR. 23503 si la unidad o el enunciado no existen/no estan activos; 22023 si el enunciado es una evidencia (nivel 2) o el nivel de ensenanza no coincide.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/unidades/:ID/enunciados'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;


-- ===========================================================================
-- 14. PATCH /planeador/unidades/enunciados/:ID — fn_unidad_enunciado_quitar
--     (V136; :ID = PK_TUNIDAD_ENUNCIADO).
-- ===========================================================================
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_unidad_enunciado_quitar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/unidades/enunciados/:ID', 'SELECT', 'PATCH',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    'V245 -- borrado logico de una relacion unidad<->enunciado (fn_unidad_enunciado_quitar, V136). :ID = PK_TUNIDAD_ENUNCIADO. Arrastra la desactivacion de las TACTIVIDAD_EVIDENCIA de esa unidad cuyo enunciado padre era este. Gate EDITAR sobre PLANEADOR. 23503 si la relacion no existe o ya esta inactiva.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/unidades/enunciados/:ID'
   AND q.http_method   = 'PATCH'
ON CONFLICT DO NOTHING;


-- ===========================================================================
-- 15. PUT /planeador/unidades/:ID/actividades/:ACTIVIDADID —
--     fn_unidad_actividad_vincular (V223, editada en V244 con
--     p_permitir_mover_de_unidad). :ID = PK_TUNIDAD destino,
--     :ACTIVIDADID = PK_TACTIVIDAD.
-- ===========================================================================
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_unidad_actividad_vincular(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ACTIVIDADID AS BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.PONDERACION AS NUMERIC),
    COALESCE(CAST(:BODY.PERMITIR_MOVER_DE_UNIDAD AS BOOLEAN), FALSE)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/unidades/:ID/actividades/:ACTIVIDADID', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT", "PARAM.ACTIVIDADID": "BIGINT", "BODY.PONDERACION": "NUMERIC", "BODY.PERMITIR_MOVER_DE_UNIDAD": "BOOLEAN"}'::jsonb,
    'V245 -- vincula una actividad a una unidad y fija su PONDERACION (%) dentro de ella (fn_unidad_actividad_vincular, V223, editada en V244). :ID = PK_TUNIDAD destino, :ACTIVIDADID = PK_TACTIVIDAD. BODY.PONDERACION NULL = no cambiar el peso actual; se rechaza (22023) si la unidad Promedia o calcula por Sumatoria (en Sumatoria el % se autocalcula desde NOTA_MAXIMA). BODY.PERMITIR_MOVER_DE_UNIDAD=true (default false) es OBLIGATORIO si la actividad YA estaba vinculada a OTRA unidad (fix V244: evita mover de unidad en silencio); vincular una huerfana (sin unidad previa) no lo requiere. Valida la regla del 100% por (unidad,grupo). Retorna PK_TACTIVIDAD. Gate EDITAR sobre PLANEADOR.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/unidades/:ID/actividades/:ACTIVIDADID'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;


-- ===========================================================================
-- 16. PATCH /planeador/unidades/actividades/:ACTIVIDADID —
--     fn_unidad_actividad_desvincular (V223). Solo necesita PK_TACTIVIDAD
--     (la funcion no recibe la unidad); no lleva :ID de unidad en la ruta.
-- ===========================================================================
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_unidad_actividad_desvincular(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ACTIVIDADID AS BIGINT)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/unidades/actividades/:ACTIVIDADID', 'SELECT', 'PATCH',
    '{"PARAM.ACTIVIDADID": "BIGINT"}'::jsonb,
    'V245 -- desvincula una actividad de su unidad: FK_TUNIDAD y PONDERACION quedan en NULL (fn_unidad_actividad_desvincular, V223). :ACTIVIDADID = PK_TACTIVIDAD. Si la unidad de origen calculaba por Sumatoria, recalcula el % de las actividades que quedan en ese (unidad,grupo). Retorna PK_TACTIVIDAD. Gate EDITAR sobre PLANEADOR. 404 (P0002) si la actividad no existe.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/unidades/actividades/:ACTIVIDADID'
   AND q.http_method   = 'PATCH'
ON CONFLICT DO NOTHING;


-- ===========================================================================
-- 17. PUT /planeador/unidades/actividades/:ACTIVIDADID/ponderacion —
--     fn_unidad_actividad_ponderacion_set (V223, edicion inline de la
--     columna (%)).
-- ===========================================================================
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_unidad_actividad_ponderacion_set(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ACTIVIDADID AS BIGINT),
    CAST(:BODY.PONDERACION AS NUMERIC)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/unidades/actividades/:ACTIVIDADID/ponderacion', 'SELECT', 'PUT',
    '{"PARAM.ACTIVIDADID": "BIGINT", "BODY.PONDERACION": "NUMERIC"}'::jsonb,
    'V245 -- edicion inline del peso (%) de una actividad ya vinculada a una unidad (fn_unidad_actividad_ponderacion_set, V223). :ACTIVIDADID = PK_TACTIVIDAD. BODY.PONDERACION obligatorio, 0..100; se rechaza (22023) si la unidad Promedia (no aplica) o calcula por Sumatoria (se autocalcula desde NOTA_MAXIMA) o si la actividad no esta vinculada a ninguna unidad. Valida la regla del 100% por (unidad,grupo). Retorna PK_TACTIVIDAD. Gate EDITAR sobre PLANEADOR.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/unidades/actividades/:ACTIVIDADID/ponderacion'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;


-- ===========================================================================
-- 18. GET /planeador/unidades/:ID/ponderacion-disponible —
--     fn_unidad_ponderacion_disponible (V223; "Disponible para asignar: X%").
-- ===========================================================================
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_unidad_ponderacion_disponible(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:QUERY.GRUPO AS BIGINT)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/unidades/:ID/ponderacion-disponible', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT", "QUERY.GRUPO": "BIGINT"}'::jsonb,
    'V245 -- porcentaje LIBRE para repartir en una (unidad, grupo): 100 - fn_unidad_ponderacion_asignada (fn_unidad_ponderacion_disponible, V223). :ID = PK_TUNIDAD, ?grupo= (opcional; grupo NULL es su propio bucket). Alimenta el "Disponible para asignar: X%" del modal "Vincular actividad". Acotado a >= 0. Gate VER sobre PLANEADOR. 404 (P0002) si la unidad no existe.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/unidades/:ID/ponderacion-disponible'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;
