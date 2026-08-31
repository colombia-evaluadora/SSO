-- =============================================================================
-- V214 — Registra en `public.query` los endpoints de Referente Curricular
-- (CU-86e311xqh — G. Academico Back Referente Curricular), sobre las
-- funciones academico_test.fn_refcurr_* / fn_refenunc_* de V213, mas dos
-- catalogos para los selects del formulario.
--
-- Sin fila en `query` -> 404 por el gateway (api/eval-col/...). Sin fila en
-- `role_query` -> 403 a cualquier caller. Ninguna de las dos cosas sustituye
-- el gate real (academico_test.fn_assert_permiso_seccion, V29/V213): esa
-- es la autoridad de negocio; esto es solo el catalogo HTTP.
--
-- microservice_id: 'eval-col', igual que /cobertura-academica/matricula/:ID
-- (V168) y el resto de endpoints que llaman funciones de academico_test.
--
-- execution_mode = 'SELECT' en TODAS las filas, incluidas las que escriben:
-- 'SELECT academico_test.fn_x(...)' es un SELECT statement aunque fn_x haga
-- INSERT/UPDATE por dentro -- mismo patron que fn_est_crear/fn_est_actualizar
-- (V64) y fn_pigse_documento_guardar/eliminar (V149).
--
-- http_method: GET para lecturas, POST para crear y para el listado
-- paginado (POST .../query, sufijo que marca "lee, no muta" -- mismo
-- criterio que /cumplimiento/query en V197), PATCH para editar Y para
-- eliminar (soft delete). NO se usa DELETE: ck_query_http_method solo
-- admite GET/POST/PUT/PATCH (Query.httpMethod excluye DELETE a proposito,
-- ver V149) -- el "eliminar" es PATCH sobre un sub-path .../eliminar para
-- no chocar con el path+metodo de "actualizar" (mismo PATCH, mismo :ID).
--
-- p_pk_usuario_solicitante SIEMPRE resuelto server-side con
-- public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT) -- el
-- caller nunca lo manda (evita que alguien se haga pasar por otro usuario).
--
-- Endpoints registrados (11 del modulo + 2 catalogos reusados, ninguno
-- nuevo en PL/pgSQL -- fn_nivel_ensenanza_listar de V43 y
-- fn_area_asignatura_listar de V40 nunca habian sido expuestos como query):
--
--   Referente:
--     POST   /referentes-curriculares                       fn_refcurr_crear
--     PATCH  /referentes-curriculares/:ID                    fn_refcurr_actualizar
--     PATCH  /referentes-curriculares/:ID/eliminar            fn_refcurr_eliminar
--     POST   /referentes-curriculares/query                   fn_refcurr_listar (paginado)
--     GET    /referentes-curriculares/:ID                     fn_refcurr_buscar_por_pk
--     GET    /referentes-curriculares/:ID/areas                fn_refcurr_areas_listar
--   Enunciado / evidencia:
--     POST   /referentes-curriculares/:ID/enunciados           fn_refenunc_crear
--     PATCH  /referentes-curriculares/enunciados/:ID           fn_refenunc_actualizar
--     PATCH  /referentes-curriculares/enunciados/:ID/eliminar   fn_refenunc_eliminar
--     GET    /referentes-curriculares/:ID/enunciados            fn_refenunc_listar
--     GET    /referentes-curriculares/enunciados/:ID/evidencias fn_refenunc_evidencias_listar
--   Catalogos (selects del formulario "Agregar referente curricular"):
--     GET    /catalogos/niveles-ensenanza                      fn_nivel_ensenanza_listar (V43)
--     GET    /catalogos/areas-asignaturas                      fn_area_asignatura_listar (V40)
--   NO se registran endpoints para Enfoque pedagogico / Tipo de evaluacion:
--   son TLISTA_VALOR (V212), ya cubiertos por el catalogo generico
--   GET /eval-col/select/:CATEGORIA (V94) -- el front llama
--   /select/ENFOQUE_PEDAGOGICO y /select/TIPO_EVALUACION directo.
--
-- role_query: SOLO 'CEVAL-SUPER_ADMINISTRADOR' (public.role; academico_test
-- .trol.codigo='SUPER_ADMINISTRADOR', ver V113) en TODOS -- incluidos los
-- 2 catalogos -- porque hoy es el UNICO rol que puede pasar el gate interno
-- de fn_assert_permiso_seccion (nadie mas tiene el TMENU concedido, V213);
-- mismo criterio que V87 (audit-clickhouse). Ampliar a otros roles cuando
-- el super admin les conceda el menu es un cambio de datos en la
-- plataforma, no una migracion nueva.
--
-- Idempotencia: uuid literal corto y legible por fila + ON CONFLICT (uuid)
-- DO UPDATE (permite corregir el texto/params en el mismo archivo sin
-- duplicar filas, releer la nota de flyway-migrations sobre "editar, no
-- duplicar"); role_query con WHERE NOT EXISTS (no tiene UNIQUE compuesto
-- util para ON CONFLICT aqui).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Referente — CREAR
-- ---------------------------------------------------------------------------
INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id,
                           path_template, execution_mode, http_method, param_types, detail)
SELECT
    'refcurr-crear',
    $q$SELECT academico_test.fn_refcurr_crear(
    p_pk_usuario_solicitante     => public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    p_nombre                     => CAST(:BODY.NOMBRE AS VARCHAR),
    p_descripcion                => CAST(:BODY.DESCRIPCION AS VARCHAR),
    p_fk_tnivel_ensenanza        => CAST(:BODY.NIVEL_EDUCATIVO AS BIGINT),
    p_fk_tlv_enfoque_pedagogico  => CAST(:BODY.ENFOQUE_PEDAGOGICO AS BIGINT),
    p_fk_tlv_tipo_evaluacion     => CAST(:BODY.TIPO_EVALUACION AS BIGINT),
    p_instrumento                => CAST(:BODY.INSTRUMENTO AS VARCHAR),
    p_normatividad                => CAST(:BODY.NORMATIVIDAD AS VARCHAR),
    p_anio_vigencia_desde         => CAST(:BODY.ANIO_DESDE AS INTEGER),
    p_nivel_1_etiqueta             => CAST(:BODY.NIVEL_1_ETIQUETA AS VARCHAR),
    p_nivel_2_etiqueta             => CAST(:BODY.NIVEL_2_ETIQUETA AS VARCHAR),
    p_instrumento_info_adicional  => CAST(:BODY.INSTRUMENTO_INFO AS VARCHAR),
    p_anio_vigencia_hasta          => CAST(:BODY.ANIO_HASTA AS INTEGER),
    p_estado                       => CAST(:BODY.ESTADO AS VARCHAR),
    p_fk_tarea_asignatura_ids      => CAST(:BODY.AREAS_IDS AS BIGINT[])
) AS pk_referente_curricular_creado$q$,
    'postgres', false, false, m.id_microservice,
    '/referentes-curriculares', 'SELECT', 'POST',
    '{
       "BODY.NOMBRE":             "VARCHAR",
       "BODY.DESCRIPCION":        "VARCHAR",
       "BODY.NIVEL_EDUCATIVO":    "BIGINT",
       "BODY.ENFOQUE_PEDAGOGICO": "BIGINT",
       "BODY.TIPO_EVALUACION":    "BIGINT",
       "BODY.INSTRUMENTO":        "VARCHAR",
       "BODY.NORMATIVIDAD":       "VARCHAR",
       "BODY.ANIO_DESDE":         "INTEGER",
       "BODY.NIVEL_1_ETIQUETA":   "VARCHAR",
       "BODY.NIVEL_2_ETIQUETA":   "VARCHAR",
       "BODY.INSTRUMENTO_INFO":   "VARCHAR",
       "BODY.ANIO_HASTA":         "INTEGER",
       "BODY.ESTADO":             "VARCHAR",
       "BODY.AREAS_IDS":          "BIGINT[]"
     }'::jsonb,
    'V214 -- crea un referente curricular (DBA, Propositos e Imprescindibles, etc.); BODY.AREAS_IDS vacio/ausente = aplica a todas las areas'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (uuid) DO UPDATE
   SET query = EXCLUDED.query, param_types = EXCLUDED.param_types,
       path_template = EXCLUDED.path_template, http_method = EXCLUDED.http_method,
       execution_mode = EXCLUDED.execution_mode, microservice_id = EXCLUDED.microservice_id,
       detail = EXCLUDED.detail;

-- ---------------------------------------------------------------------------
-- 2. Referente — ACTUALIZAR (PATCH parcial)
-- ---------------------------------------------------------------------------
INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id,
                           path_template, execution_mode, http_method, param_types, detail)
SELECT
    'refcurr-actualizar',
    $q$SELECT academico_test.fn_refcurr_actualizar(
    p_pk_usuario_solicitante     => public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    p_pk_referente_curricular    => CAST(:PARAM.ID AS BIGINT),
    p_nombre                     => CAST(:BODY.NOMBRE AS VARCHAR),
    p_descripcion                => CAST(:BODY.DESCRIPCION AS VARCHAR),
    p_fk_tnivel_ensenanza        => CAST(:BODY.NIVEL_EDUCATIVO AS BIGINT),
    p_fk_tlv_enfoque_pedagogico  => CAST(:BODY.ENFOQUE_PEDAGOGICO AS BIGINT),
    p_fk_tlv_tipo_evaluacion     => CAST(:BODY.TIPO_EVALUACION AS BIGINT),
    p_nivel_1_etiqueta             => CAST(:BODY.NIVEL_1_ETIQUETA AS VARCHAR),
    p_nivel_2_etiqueta             => CAST(:BODY.NIVEL_2_ETIQUETA AS VARCHAR),
    p_instrumento                => CAST(:BODY.INSTRUMENTO AS VARCHAR),
    p_instrumento_info_adicional  => CAST(:BODY.INSTRUMENTO_INFO AS VARCHAR),
    p_normatividad                => CAST(:BODY.NORMATIVIDAD AS VARCHAR),
    p_anio_vigencia_desde         => CAST(:BODY.ANIO_DESDE AS INTEGER),
    p_anio_vigencia_hasta          => CAST(:BODY.ANIO_HASTA AS INTEGER),
    p_estado                       => CAST(:BODY.ESTADO AS VARCHAR),
    p_fk_tarea_asignatura_ids      => CAST(:BODY.AREAS_IDS AS BIGINT[])
) AS pk_referente_curricular$q$,
    'postgres', false, false, m.id_microservice,
    '/referentes-curriculares/:ID', 'SELECT', 'PATCH',
    '{
       "PARAM.ID":                "BIGINT",
       "BODY.NOMBRE":             "VARCHAR",
       "BODY.DESCRIPCION":        "VARCHAR",
       "BODY.NIVEL_EDUCATIVO":    "BIGINT",
       "BODY.ENFOQUE_PEDAGOGICO": "BIGINT",
       "BODY.TIPO_EVALUACION":    "BIGINT",
       "BODY.NIVEL_1_ETIQUETA":   "VARCHAR",
       "BODY.NIVEL_2_ETIQUETA":   "VARCHAR",
       "BODY.INSTRUMENTO":        "VARCHAR",
       "BODY.INSTRUMENTO_INFO":   "VARCHAR",
       "BODY.NORMATIVIDAD":       "VARCHAR",
       "BODY.ANIO_DESDE":         "INTEGER",
       "BODY.ANIO_HASTA":         "INTEGER",
       "BODY.ESTADO":             "VARCHAR",
       "BODY.AREAS_IDS":          "BIGINT[]"
     }'::jsonb,
    'V214 -- PATCH parcial de un referente curricular; cada campo ausente preserva su valor actual. BODY.AREAS_IDS ausente = no tocar areas, [] = vaciarlas'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (uuid) DO UPDATE
   SET query = EXCLUDED.query, param_types = EXCLUDED.param_types,
       path_template = EXCLUDED.path_template, http_method = EXCLUDED.http_method,
       execution_mode = EXCLUDED.execution_mode, microservice_id = EXCLUDED.microservice_id,
       detail = EXCLUDED.detail;

-- ---------------------------------------------------------------------------
-- 3. Referente — ELIMINAR (soft delete). DELETE -> PATCH, ver cabecera.
-- ---------------------------------------------------------------------------
INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id,
                           path_template, execution_mode, http_method, param_types, detail)
SELECT
    'refcurr-eliminar',
    $q$SELECT academico_test.fn_refcurr_eliminar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
) AS pk_referente_curricular$q$,
    'postgres', false, false, m.id_microservice,
    '/referentes-curriculares/:ID/eliminar', 'SELECT', 'PATCH',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    'V214 -- baja logica en cascada (evidencias -> enunciados -> areas -> referente)'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (uuid) DO UPDATE
   SET query = EXCLUDED.query, param_types = EXCLUDED.param_types,
       path_template = EXCLUDED.path_template, http_method = EXCLUDED.http_method,
       execution_mode = EXCLUDED.execution_mode, microservice_id = EXCLUDED.microservice_id,
       detail = EXCLUDED.detail;

-- ---------------------------------------------------------------------------
-- 4. Referente — LISTADO paginado (pantalla principal). Mismo contrato
--    BODY.FILTERS/BODY.SORTING/BODY.PAGEINDEX/BODY.PAGESIZE que
--    /cumplimiento/query (V197) y /establecimientos/query.
-- ---------------------------------------------------------------------------
INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id,
                           path_template, execution_mode, http_method, param_types, detail)
SELECT
    'refcurr-listar',
    $q$SELECT * FROM academico_test.fn_refcurr_listar(
    p_pk_usuario_solicitante      => public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    p_search                      => CAST(:BODY.FILTERS.SEARCH AS VARCHAR),
    p_fk_tnivel_ensenanza         => CAST(:BODY.FILTERS.NIVEL_EDUCATIVO AS BIGINT),
    p_fk_tlv_enfoque_pedagogico   => CAST(:BODY.FILTERS.ENFOQUE_PEDAGOGICO AS BIGINT),
    p_fk_tlv_tipo_evaluacion      => CAST(:BODY.FILTERS.TIPO_EVALUACION AS BIGINT),
    p_estado                      => CAST(:BODY.FILTERS.ESTADO AS VARCHAR),
    p_orden_por                   => CAST(:BODY.SORTING.ID AS VARCHAR),
    p_orden_asc                   => NOT COALESCE(CAST(:BODY.SORTING.DESC AS BOOLEAN), FALSE),
    p_limite                      => CAST(:BODY.PAGESIZE AS INTEGER),
    p_offset                      => CAST(:BODY.PAGEINDEX AS INTEGER) * CAST(:BODY.PAGESIZE AS INTEGER)
);$q$,
    'postgres', false, false, m.id_microservice,
    '/referentes-curriculares/query', 'SELECT', 'POST',
    '{
       "BODY.FILTERS.SEARCH":             "VARCHAR",
       "BODY.FILTERS.NIVEL_EDUCATIVO":    "BIGINT",
       "BODY.FILTERS.ENFOQUE_PEDAGOGICO": "BIGINT",
       "BODY.FILTERS.TIPO_EVALUACION":    "BIGINT",
       "BODY.FILTERS.ESTADO":             "VARCHAR",
       "BODY.SORTING.ID":                 "VARCHAR",
       "BODY.SORTING.DESC":               "BOOLEAN",
       "BODY.PAGEINDEX":                  "INTEGER",
       "BODY.PAGESIZE":                   "INTEGER"
     }'::jsonb,
    'V214 -- pagina de referentes con filtros/orden; columna total_count trae el total para pageCount. Sin filtros cae a la primera pagina completa'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (uuid) DO UPDATE
   SET query = EXCLUDED.query, param_types = EXCLUDED.param_types,
       path_template = EXCLUDED.path_template, http_method = EXCLUDED.http_method,
       execution_mode = EXCLUDED.execution_mode, microservice_id = EXCLUDED.microservice_id,
       detail = EXCLUDED.detail;

-- ---------------------------------------------------------------------------
-- 5. Referente — DETALLE (pestaña "Información general")
-- ---------------------------------------------------------------------------
INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id,
                           path_template, execution_mode, http_method, param_types, detail)
SELECT
    'refcurr-detalle',
    $q$SELECT * FROM academico_test.fn_refcurr_buscar_por_pk(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
);$q$,
    'postgres', false, false, m.id_microservice,
    '/referentes-curriculares/:ID', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    'V214 -- detalle de un referente curricular (0 filas si no existe: el front lo trata como 404)'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (uuid) DO UPDATE
   SET query = EXCLUDED.query, param_types = EXCLUDED.param_types,
       path_template = EXCLUDED.path_template, http_method = EXCLUDED.http_method,
       execution_mode = EXCLUDED.execution_mode, microservice_id = EXCLUDED.microservice_id,
       detail = EXCLUDED.detail;

-- ---------------------------------------------------------------------------
-- 6. Referente — AREAS asociadas (select "Areas o dimensiones" pestaña
--    Enunciado)
-- ---------------------------------------------------------------------------
INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id,
                           path_template, execution_mode, http_method, param_types, detail)
SELECT
    'refcurr-areas',
    $q$SELECT * FROM academico_test.fn_refcurr_areas_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
);$q$,
    'postgres', false, false, m.id_microservice,
    '/referentes-curriculares/:ID/areas', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    'V214 -- areas/dimensiones ACTIVE asociadas al referente; lista vacia = aplica a todas'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (uuid) DO UPDATE
   SET query = EXCLUDED.query, param_types = EXCLUDED.param_types,
       path_template = EXCLUDED.path_template, http_method = EXCLUDED.http_method,
       execution_mode = EXCLUDED.execution_mode, microservice_id = EXCLUDED.microservice_id,
       detail = EXCLUDED.detail;

-- ---------------------------------------------------------------------------
-- 7. Enunciado/evidencia — CREAR (p_fk_padre en el body: ausente/NULL =
--    enunciado nivel 1; PK de un enunciado ya existente = evidencia nivel 2)
-- ---------------------------------------------------------------------------
INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id,
                           path_template, execution_mode, http_method, param_types, detail)
SELECT
    'refenunc-crear',
    $q$SELECT academico_test.fn_refenunc_crear(
    p_pk_usuario_solicitante        => public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    p_pk_referente_curricular       => CAST(:PARAM.ID AS BIGINT),
    p_texto                         => CAST(:BODY.TEXTO AS VARCHAR),
    p_fk_padre                      => CAST(:BODY.ENUNCIADO_PADRE AS BIGINT),
    p_fk_referente_curricular_area  => CAST(:BODY.AREA_ID AS BIGINT),
    p_estado                        => CAST(:BODY.ESTADO AS VARCHAR)
) AS pk_referente_enunciado_creado$q$,
    'postgres', false, false, m.id_microservice,
    '/referentes-curriculares/:ID/enunciados', 'SELECT', 'POST',
    '{
       "PARAM.ID":              "BIGINT",
       "BODY.TEXTO":            "VARCHAR",
       "BODY.ENUNCIADO_PADRE":  "BIGINT",
       "BODY.AREA_ID":          "BIGINT",
       "BODY.ESTADO":           "VARCHAR"
     }'::jsonb,
    'V214 -- crea un enunciado (BODY.ENUNCIADO_PADRE ausente) o una evidencia (BODY.ENUNCIADO_PADRE = PK de un enunciado ya creado); BODY.AREA_ID solo aplica a enunciados, ausente = aplica a todas las areas'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (uuid) DO UPDATE
   SET query = EXCLUDED.query, param_types = EXCLUDED.param_types,
       path_template = EXCLUDED.path_template, http_method = EXCLUDED.http_method,
       execution_mode = EXCLUDED.execution_mode, microservice_id = EXCLUDED.microservice_id,
       detail = EXCLUDED.detail;

-- ---------------------------------------------------------------------------
-- 8. Enunciado/evidencia — ACTUALIZAR
-- ---------------------------------------------------------------------------
INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id,
                           path_template, execution_mode, http_method, param_types, detail)
SELECT
    'refenunc-actualizar',
    $q$SELECT academico_test.fn_refenunc_actualizar(
    p_pk_usuario_solicitante        => public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    p_pk_referente_enunciado        => CAST(:PARAM.ID AS BIGINT),
    p_texto                         => CAST(:BODY.TEXTO AS VARCHAR),
    p_estado                        => CAST(:BODY.ESTADO AS VARCHAR),
    p_fk_referente_curricular_area  => CAST(:BODY.AREA_ID AS BIGINT),
    p_limpiar_area                  => COALESCE(CAST(:BODY.LIMPIAR_AREA AS BOOLEAN), FALSE)
) AS pk_referente_enunciado$q$,
    'postgres', false, false, m.id_microservice,
    '/referentes-curriculares/enunciados/:ID', 'SELECT', 'PATCH',
    '{
       "PARAM.ID":        "BIGINT",
       "BODY.TEXTO":      "VARCHAR",
       "BODY.ESTADO":     "VARCHAR",
       "BODY.AREA_ID":    "BIGINT",
       "BODY.LIMPIAR_AREA": "BOOLEAN"
     }'::jsonb,
    'V214 -- PATCH parcial; BODY.LIMPIAR_AREA=true vuelve el area a NULL (aplica a todas). FK_PADRE y el referente son inmutables'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (uuid) DO UPDATE
   SET query = EXCLUDED.query, param_types = EXCLUDED.param_types,
       path_template = EXCLUDED.path_template, http_method = EXCLUDED.http_method,
       execution_mode = EXCLUDED.execution_mode, microservice_id = EXCLUDED.microservice_id,
       detail = EXCLUDED.detail;

-- ---------------------------------------------------------------------------
-- 9. Enunciado/evidencia — ELIMINAR (soft delete; cascada a evidencias si
--    es un enunciado). DELETE -> PATCH, ver cabecera.
-- ---------------------------------------------------------------------------
INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id,
                           path_template, execution_mode, http_method, param_types, detail)
SELECT
    'refenunc-eliminar',
    $q$SELECT academico_test.fn_refenunc_eliminar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
) AS pk_referente_enunciado$q$,
    'postgres', false, false, m.id_microservice,
    '/referentes-curriculares/enunciados/:ID/eliminar', 'SELECT', 'PATCH',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    'V214 -- baja logica; si es un enunciado (nivel 1) da de baja tambien sus evidencias activas'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (uuid) DO UPDATE
   SET query = EXCLUDED.query, param_types = EXCLUDED.param_types,
       path_template = EXCLUDED.path_template, http_method = EXCLUDED.http_method,
       execution_mode = EXCLUDED.execution_mode, microservice_id = EXCLUDED.microservice_id,
       detail = EXCLUDED.detail;

-- ---------------------------------------------------------------------------
-- 10. Enunciados de un referente (panel izquierdo pestaña Enunciado),
--     filtro opcional por area via querystring.
-- ---------------------------------------------------------------------------
INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id,
                           path_template, execution_mode, http_method, param_types, detail)
SELECT
    'refenunc-listar',
    $q$SELECT * FROM academico_test.fn_refenunc_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:QUERY.AREA AS BIGINT)
);$q$,
    'postgres', false, false, m.id_microservice,
    '/referentes-curriculares/:ID/enunciados', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT", "QUERY.AREA": "BIGINT"}'::jsonb,
    'V214 -- enunciados (nivel 1) del referente, opcionalmente filtrados por ?area=<PK de TREFERENTE_CURRICULAR_AREA>; incluye total_evidencias por fila'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (uuid) DO UPDATE
   SET query = EXCLUDED.query, param_types = EXCLUDED.param_types,
       path_template = EXCLUDED.path_template, http_method = EXCLUDED.http_method,
       execution_mode = EXCLUDED.execution_mode, microservice_id = EXCLUDED.microservice_id,
       detail = EXCLUDED.detail;

-- ---------------------------------------------------------------------------
-- 11. Evidencias de UN enunciado (tabla "Evidencias del enunciado")
-- ---------------------------------------------------------------------------
INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id,
                           path_template, execution_mode, http_method, param_types, detail)
SELECT
    'refenunc-evidencias',
    $q$SELECT * FROM academico_test.fn_refenunc_evidencias_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
);$q$,
    'postgres', false, false, m.id_microservice,
    '/referentes-curriculares/enunciados/:ID/evidencias', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    'V214 -- evidencias (nivel 2) de un enunciado puntual, numeradas (columna #)'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (uuid) DO UPDATE
   SET query = EXCLUDED.query, param_types = EXCLUDED.param_types,
       path_template = EXCLUDED.path_template, http_method = EXCLUDED.http_method,
       execution_mode = EXCLUDED.execution_mode, microservice_id = EXCLUDED.microservice_id,
       detail = EXCLUDED.detail;

-- ---------------------------------------------------------------------------
-- 12. Catalogo — Niveles de ensenanza (select "Nivel educativo"). Reusa
--     fn_nivel_ensenanza_listar (V43), nunca antes expuesta como query.
-- ---------------------------------------------------------------------------
INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id,
                           path_template, execution_mode, http_method, param_types, detail)
SELECT
    'cat-niveles-ensenanza',
    $q$SELECT * FROM academico_test.fn_nivel_ensenanza_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);$q$,
    'postgres', false, false, m.id_microservice,
    '/catalogos/niveles-ensenanza', 'SELECT', 'GET', '{}'::jsonb,
    'V214 -- TNIVEL_ENSENANZA activos (id, codigo, nombre) para el select "Nivel educativo"'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (uuid) DO UPDATE
   SET query = EXCLUDED.query, param_types = EXCLUDED.param_types,
       path_template = EXCLUDED.path_template, http_method = EXCLUDED.http_method,
       execution_mode = EXCLUDED.execution_mode, microservice_id = EXCLUDED.microservice_id,
       detail = EXCLUDED.detail;

-- ---------------------------------------------------------------------------
-- 13. Catalogo — Areas/asignaturas (select "Areas o dimensiones"). Reusa
--     fn_area_asignatura_listar (V40), nunca antes expuesta como query.
-- ---------------------------------------------------------------------------
INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id,
                           path_template, execution_mode, http_method, param_types, detail)
SELECT
    'cat-areas-asignaturas',
    $q$SELECT * FROM academico_test.fn_area_asignatura_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);$q$,
    'postgres', false, false, m.id_microservice,
    '/catalogos/areas-asignaturas', 'SELECT', 'GET', '{}'::jsonb,
    'V214 -- TAREA_ASIGNATURA activas (id, nombre, especialidad_id) para el select "Areas o dimensiones"'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (uuid) DO UPDATE
   SET query = EXCLUDED.query, param_types = EXCLUDED.param_types,
       path_template = EXCLUDED.path_template, http_method = EXCLUDED.http_method,
       execution_mode = EXCLUDED.execution_mode, microservice_id = EXCLUDED.microservice_id,
       detail = EXCLUDED.detail;

-- ---------------------------------------------------------------------------
-- 14. role_query — SOLO CEVAL-SUPER_ADMINISTRADOR, en las 13 filas de arriba.
-- ---------------------------------------------------------------------------
INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id AND m.serviceid = 'eval-col'
 CROSS JOIN public.role r
 WHERE r.name = 'CEVAL-SUPER_ADMINISTRADOR'
   AND q.uuid IN (
       'refcurr-crear', 'refcurr-actualizar', 'refcurr-eliminar', 'refcurr-listar',
       'refcurr-detalle', 'refcurr-areas',
       'refenunc-crear', 'refenunc-actualizar', 'refenunc-eliminar',
       'refenunc-listar', 'refenunc-evidencias',
       'cat-niveles-ensenanza', 'cat-areas-asignaturas'
   )
   AND NOT EXISTS (
       SELECT 1 FROM public.role_query rq
        WHERE rq.query_id = q.id_query AND rq.role_id = r.id_role
   );
