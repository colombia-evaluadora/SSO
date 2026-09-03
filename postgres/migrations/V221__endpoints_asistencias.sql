-- ===========================================================================
-- V221 — Registra en `public.query` los endpoints del modulo de Asistencias
-- (CU-86e32gvpp — G. Academico Back Asistencias), sobre las funciones
-- academico_test.fn_asistencia_* de V220.
--
-- Sin fila en `query` -> 404 por el gateway (api/eval-col/...). Sin fila en
-- `role_query` -> 403 a cualquier caller. Ninguna de las dos cosas sustituye
-- el gate real (academico_test.fn_asistencia_gate_escritura /
-- fn_asistencia_puede_ver, V220, sobre el menu 'ASISTENCIAS'): esa es la
-- autoridad de negocio; esto es solo el catalogo HTTP.
--
-- microservice_id: 'eval-col', resuelto por serviceid (no id literal: varia
-- por entorno), igual que V214 / V219.
--
-- execution_mode = 'SELECT' en TODAS las filas, incluidas las que escriben:
-- 'SELECT academico_test.fn_x(...)' es un SELECT statement aunque fn_x haga
-- INSERT/UPDATE por dentro — mismo patron que V214 / V64 / V149.
--
-- http_method: GET para las lecturas por query-string, POST para el registro
-- masivo y para el listado paginado (POST .../query, sufijo que marca "lee,
-- no muta" — criterio de V197/V214), PATCH para editar un registro. NO se
-- usa DELETE: ck_query_http_method solo admite GET/POST/PUT/PATCH.
--
-- p_pk_usuario_solicitante / p_pk_usuario SIEMPRE se resuelven server-side
-- con public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT) — el
-- caller NUNCA los manda (si no, cualquiera se haria pasar por otro usuario
-- y saltaria el scope por rol de V220).
--
-- Endpoints registrados (6):
--   GET    /asistencias/sesion/estudiantes  fn_asistencia_estudiantes_sesion
--          padron de la pantalla "Asistencia manual" (alumnos + estado actual)
--   POST   /asistencias/registrar     fn_asistencia_registrar_bulk
--          "Asistencia manual" (BODY.REGISTROS) y "Marcar todo como Asistio"
--          (BODY.MARCAR_TODOS = 1, sin REGISTROS).
--   PATCH  /asistencias/:ID           fn_asistencia_editar
--   POST   /asistencias/query         fn_asistencia_listar_seguimiento (paginado)
--   GET    /asistencias/calendario    fn_asistencia_calendario
--          QUERY.MIAS=true (o QUERY.FUNCIONARIO=<id>) -> solo las asignaturas
--          asignadas a ese docente (TDOCENTE_ASIGNATURA); vista "mis clases".
--   GET    /asistencias/resumen-horas fn_asistencia_resumen_horas
--          horas DICTADAS vs PROGRAMADAS del horario (widget "16h / 20h");
--          acepta el mismo QUERY.MIAS / QUERY.FUNCIONARIO.
--
-- BODY.REGISTROS es un ARREGLO JSON, asi que se enlaza con :BODY_RAW.* y se
-- declara en param_types por partida doble (BODY.REGISTROS y
-- BODY_RAW.REGISTROS = "JSONB") — mismo patron que V198 para
-- fn_associate_menus_to_rol.
--
-- Las FECHAS se declaran "VARCHAR" en param_types (es el tipo de la entrada)
-- y se castean a DATE en el SQL — mismo patron que FECHA_DE_NACIMIENTO en
-- V219 y LICENSEDATE en V64.
--
-- role_query: CEVAL-SUPER_ADMINISTRADOR + los roles con el menu 'ASISTENCIAS'
-- concedido (DOCENTE y RECTOR salen del dump base). Ver bloque 6. Ampliar
-- a mas roles: concederles 'ASISTENCIAS' desde la pantalla de roles y
-- re-aplicar esta migracion (o un INSERT en role_query). Mismo criterio
-- migracion nueva: el gate de V220 lee TROL_MENU en caliente. Mismo criterio
-- que V214.
--
-- Idempotencia: uuid literal corto por fila + ON CONFLICT (uuid) DO UPDATE
-- (permite corregir el texto/params editando este mismo archivo, "editar, no
-- duplicar"); role_query y query_param_constraint con WHERE NOT EXISTS /
-- ON CONFLICT sobre su UNIQUE.
--
-- Tras aplicar: el contenedor query-service-eval-col cachea el catalogo —
-- hay que REINICIARLO para que tome las filas nuevas, o el gateway sigue
-- respondiendo 404. (Ver memoria "query-service-provisioned-route-reload".)
--
-- Depende de: V220 (las funciones y el menu), V113 (menus), V49/V70/V83
-- (param_types y query_param_constraint), V48 (fn_get_academico_usuario_id).
-- ===========================================================================

SET search_path TO public;

-- ---------------------------------------------------------------------------
-- 1. REGISTRAR (masivo) — "Asistencia manual" y "Marcar todo como Asistio"
-- ---------------------------------------------------------------------------
INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id,
                          path_template, execution_mode, http_method, param_types, detail)
SELECT
    'asis-registrar',
    $q$SELECT academico_test.fn_asistencia_registrar_bulk(
    p_pk_usuario_solicitante => public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    p_fk_tgrupo              => CAST(:BODY.GRUPO AS BIGINT),
    p_fk_tasignatura         => CAST(:BODY.ASIGNATURA AS BIGINT),
    p_fecha                  => CAST(:BODY.FECHA AS DATE),
    p_bloque                 => CAST(:BODY.BLOQUE AS NUMERIC),
    p_registros              => CAST(:BODY_RAW.REGISTROS AS JSONB),
    p_marcar_todos_valor     => CAST(:BODY.MARCAR_TODOS AS NUMERIC)
) AS registros_afectados$q$,
    'postgres', false, false, m.id_microservice,
    '/asistencias/registrar', 'SELECT', 'POST',
    '{
       "BODY.GRUPO":         "BIGINT!",
       "BODY.ASIGNATURA":    "BIGINT!",
       "BODY.FECHA":         "VARCHAR!",
       "BODY.BLOQUE":        "NUMERIC",
       "BODY.REGISTROS":     "JSONB",
       "BODY_RAW.REGISTROS": "JSONB",
       "BODY.MARCAR_TODOS":  "NUMERIC"
     }'::jsonb,
    'V221 -- registra/actualiza la asistencia de un grupo en una sesion (FECHA + BLOQUE). REGISTROS = [{fkMatricula,tipoAsistencia,observacion,fkArchivo}]. Si REGISTROS viene vacio y MARCAR_TODOS trae un valor de TIPO_ASISTENCIA (1=Asistio), lo aplica a todo el grupo. Upsert idempotente por (matricula, asignatura, fecha, bloque). RECHAZA (22023) si el TPERIODO_ACADEMICO del grupo esta Cerrado.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (uuid) DO UPDATE
   SET query = EXCLUDED.query, param_types = EXCLUDED.param_types,
       path_template = EXCLUDED.path_template, http_method = EXCLUDED.http_method,
       execution_mode = EXCLUDED.execution_mode, microservice_id = EXCLUDED.microservice_id,
       detail = EXCLUDED.detail;

-- ---------------------------------------------------------------------------
-- 2. EDITAR un registro (PATCH parcial)
--    Los flags LIMPIAR_* existen porque un NULL en el body significa "no
--    tocar"; para BORRAR la observacion o el soporte hay que pedirlo explicito.
-- ---------------------------------------------------------------------------
INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id,
                          path_template, execution_mode, http_method, param_types, detail)
SELECT
    'asis-editar',
    $q$SELECT academico_test.fn_asistencia_editar(
    p_pk_usuario_solicitante => public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    p_pk_tasistencia         => CAST(:PARAM.ID AS BIGINT),
    p_tipo_asistencia_valor  => CAST(:BODY.TIPO_ASISTENCIA AS NUMERIC),
    p_observacion            => CAST(:BODY.OBSERVACION AS VARCHAR),
    p_fk_soporte_archivo     => CAST(:BODY.SOPORTE_ARCHIVO AS BIGINT),
    p_limpiar_archivo        => COALESCE(CAST(:BODY.LIMPIAR_ARCHIVO AS BOOLEAN), FALSE),
    p_limpiar_observacion    => COALESCE(CAST(:BODY.LIMPIAR_OBSERVACION AS BOOLEAN), FALSE)
) AS pk_tasistencia$q$,
    'postgres', false, false, m.id_microservice,
    '/asistencias/:ID', 'SELECT', 'PATCH',
    '{
       "PARAM.ID":                  "BIGINT",
       "BODY.TIPO_ASISTENCIA":      "NUMERIC",
       "BODY.OBSERVACION":          "VARCHAR",
       "BODY.SOPORTE_ARCHIVO":      "BIGINT",
       "BODY.LIMPIAR_ARCHIVO":      "BOOLEAN",
       "BODY.LIMPIAR_OBSERVACION":  "BOOLEAN"
     }'::jsonb,
    'V221 -- edita un registro de asistencia (estado, observacion, soporte). Campos ausentes = no se tocan; LIMPIAR_ARCHIVO / LIMPIAR_OBSERVACION = true los pone en NULL. TIPO_ASISTENCIA es el VALOR del catalogo (1,2,3,5,6). RECHAZA (22023) si el TPERIODO_ACADEMICO del grupo del registro esta Cerrado.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (uuid) DO UPDATE
   SET query = EXCLUDED.query, param_types = EXCLUDED.param_types,
       path_template = EXCLUDED.path_template, http_method = EXCLUDED.http_method,
       execution_mode = EXCLUDED.execution_mode, microservice_id = EXCLUDED.microservice_id,
       detail = EXCLUDED.detail;

-- ---------------------------------------------------------------------------
-- 3. SEGUIMIENTO — listado paginado
--    Nombres de bind calcados de /referentes-curriculares/query (V214) y
--    /cumplimiento/query (V197): FILTERS.* / SORTING.{ID,DESC} / PAGEINDEX /
--    PAGESIZE. Las columnas total_estudiantes, ausentes y total_count vienen
--    en cada fila (ventanas sobre el set filtrado completo).
-- ---------------------------------------------------------------------------
INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id,
                          path_template, execution_mode, http_method, param_types, detail)
SELECT
    'asis-seguimiento',
    $q$SELECT * FROM academico_test.fn_asistencia_listar_seguimiento(
    p_pk_usuario      => public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    p_fecha_desde     => CAST(:BODY.FILTERS.FECHA_DESDE AS DATE),
    p_fecha_hasta     => CAST(:BODY.FILTERS.FECHA_HASTA AS DATE),
    p_fk_tgrupo       => CAST(:BODY.FILTERS.GRUPO AS BIGINT),
    p_fk_tasignatura  => CAST(:BODY.FILTERS.ASIGNATURA AS BIGINT),
    p_tipo_asistencia => CAST(:BODY.FILTERS.TIPO_ASISTENCIA AS NUMERIC),
    p_search          => CAST(:BODY.FILTERS.SEARCH AS TEXT),
    p_page_index      => COALESCE(CAST(:BODY.PAGEINDEX AS INTEGER), 0),
    p_page_size       => COALESCE(CAST(:BODY.PAGESIZE AS INTEGER), 10),
    p_sort_by         => CAST(:BODY.SORTING.ID AS TEXT),
    p_sort_dir        => CASE WHEN COALESCE(CAST(:BODY.SORTING.DESC AS BOOLEAN), TRUE)
                              THEN 'desc' ELSE 'asc' END
);$q$,
    'postgres', false, false, m.id_microservice,
    '/asistencias/query', 'SELECT', 'POST',
    '{
       "BODY.FILTERS.FECHA_DESDE":     "VARCHAR",
       "BODY.FILTERS.FECHA_HASTA":     "VARCHAR",
       "BODY.FILTERS.GRUPO":           "BIGINT",
       "BODY.FILTERS.ASIGNATURA":      "BIGINT",
       "BODY.FILTERS.TIPO_ASISTENCIA": "NUMERIC",
       "BODY.FILTERS.SEARCH":          "VARCHAR",
       "BODY.SORTING.ID":              "VARCHAR",
       "BODY.SORTING.DESC":            "BOOLEAN",
       "BODY.PAGEINDEX":               "INTEGER",
       "BODY.PAGESIZE":                "INTEGER"
     }'::jsonb,
    'V221 -- pantalla Seguimiento: pagina de registros de asistencia con filtros rango de fecha / grupo / asignatura / tipo y busqueda libre. Cada fila trae total_estudiantes, ausentes y total_count (ventanas sobre el set filtrado completo, para las tarjetas y el pageCount). SORTING.ID: estudiante|documento|fecha|tipo|grupo|asignatura.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (uuid) DO UPDATE
   SET query = EXCLUDED.query, param_types = EXCLUDED.param_types,
       path_template = EXCLUDED.path_template, http_method = EXCLUDED.http_method,
       execution_mode = EXCLUDED.execution_mode, microservice_id = EXCLUDED.microservice_id,
       detail = EXCLUDED.detail;

-- ---------------------------------------------------------------------------
-- 3b. PADRON de una sesion (pantalla "Asistencia manual", GET query-string)
--     Todas las matriculas activas del grupo con su estado actual para esa
--     (asignatura, fecha, bloque); NULL = falta tomarlo. Cada fila repite la
--     cabecera de la sesion (hora_inicio/hora_fin, fk_tperiodo_evaluacion).
-- ---------------------------------------------------------------------------
INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id,
                          path_template, execution_mode, http_method, param_types, detail)
SELECT
    'asis-sesion-estudiantes',
    $q$SELECT * FROM academico_test.fn_asistencia_estudiantes_sesion(
    p_pk_usuario     => public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    p_fk_tgrupo      => CAST(:QUERY.GRUPO AS BIGINT),
    p_fk_tasignatura => CAST(:QUERY.ASIGNATURA AS BIGINT),
    p_fecha          => CAST(:QUERY.FECHA AS DATE),
    p_bloque         => CAST(:QUERY.BLOQUE AS NUMERIC)
);$q$,
    'postgres', false, false, m.id_microservice,
    '/asistencias/sesion/estudiantes', 'SELECT', 'GET',
    '{
       "QUERY.GRUPO":      "BIGINT!",
       "QUERY.ASIGNATURA": "BIGINT!",
       "QUERY.FECHA":      "VARCHAR!",
       "QUERY.BLOQUE":     "NUMERIC"
     }'::jsonb,
    'V221 -- padron de la pantalla "Asistencia manual": una fila por matricula activa del grupo, con el estado ACTUAL del alumno (pk_tasistencia / tipo_asistencia_valor / observacion / soporte) o NULL si falta tomarlo. Repite en cada fila la cabecera de la sesion: hora_inicio/hora_fin (THORARIO por dia de semana de la fecha) y fk_tperiodo_evaluacion. total_estudiantes y registrados son ventanas sobre el padron.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (uuid) DO UPDATE
   SET query = EXCLUDED.query, param_types = EXCLUDED.param_types,
       path_template = EXCLUDED.path_template, http_method = EXCLUDED.http_method,
       execution_mode = EXCLUDED.execution_mode, microservice_id = EXCLUDED.microservice_id,
       detail = EXCLUDED.detail;

-- ---------------------------------------------------------------------------
-- 4. CALENDARIO mensual por sede (GET con query-string)
-- ---------------------------------------------------------------------------
INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id,
                          path_template, execution_mode, http_method, param_types, detail)
SELECT
    'asis-calendario',
    $q$SELECT * FROM academico_test.fn_asistencia_calendario(
    p_pk_usuario      => public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    p_fk_tsede        => CAST(:QUERY.SEDE AS BIGINT),
    p_anio            => CAST(:QUERY.ANIO AS INTEGER),
    p_mes             => CAST(:QUERY.MES AS INTEGER),
    p_fk_tgrupo       => CAST(:QUERY.GRUPO AS BIGINT),
    p_fk_tasignatura  => CAST(:QUERY.ASIGNATURA AS BIGINT),
    p_fecha_hoy       => COALESCE(CAST(:QUERY.HOY AS DATE), CURRENT_DATE),
    -- "mis clases": QUERY.MIAS=true -> se resuelve el docente desde el token
    -- (si el usuario no es funcionario -> -1, no matchea nada -> calendario
    -- vacio). Alternativa: QUERY.FUNCIONARIO explicito (admin filtrando por
    -- un docente). NULL en ambos -> todas las asignaturas del scope.
    p_fk_tfuncionario => CASE
        WHEN COALESCE(CAST(:QUERY.MIAS AS BOOLEAN), FALSE)
        THEN COALESCE((SELECT f.PK_TFUNCIONARIO FROM academico_test.TFUNCIONARIO f
                        WHERE f.FK_TUSUARIO = public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
                          AND f.ACTIVE = TRUE), -1)
        ELSE CAST(:QUERY.FUNCIONARIO AS BIGINT)
    END
);$q$,
    'postgres', false, false, m.id_microservice,
    '/asistencias/calendario', 'SELECT', 'GET',
    '{
       "QUERY.SEDE":       "BIGINT!",
       "QUERY.ANIO":       "INTEGER!",
       "QUERY.MES":        "INTEGER!",
       "QUERY.GRUPO":      "BIGINT",
       "QUERY.ASIGNATURA": "BIGINT",
       "QUERY.HOY":        "VARCHAR",
       "QUERY.MIAS":       "BOOLEAN",
       "QUERY.FUNCIONARIO":"BIGINT"
     }'::jsonb,
    'V221 -- pantalla Asistencia: sesiones del mes por sede. Incluye las PROGRAMADAS en THORARIO proyectadas sobre las fechas reales y las REGISTRADAS sin bloque programado. estado_sesion = REGISTRADA | RETRASADA (fecha pasada sin registro) | PENDIENTE (fecha futura). QUERY.MIAS=true acota a las asignaturas asignadas al docente del token (vista "mis clases"); QUERY.FUNCIONARIO filtra por un docente concreto. QUERY.HOY es opcional (pruebas), por defecto CURRENT_DATE.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (uuid) DO UPDATE
   SET query = EXCLUDED.query, param_types = EXCLUDED.param_types,
       path_template = EXCLUDED.path_template, http_method = EXCLUDED.http_method,
       execution_mode = EXCLUDED.execution_mode, microservice_id = EXCLUDED.microservice_id,
       detail = EXCLUDED.detail;

-- ---------------------------------------------------------------------------
-- 5. RESUMEN DE HORAS (tarjetas del encabezado)
-- ---------------------------------------------------------------------------
INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id,
                          path_template, execution_mode, http_method, param_types, detail)
SELECT
    'asis-resumen-horas',
    $q$SELECT * FROM academico_test.fn_asistencia_resumen_horas(
    p_pk_usuario      => public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    p_fk_tsede        => CAST(:QUERY.SEDE AS BIGINT),
    p_fecha_ref       => COALESCE(CAST(:QUERY.FECHA AS DATE), CURRENT_DATE),
    p_fk_tgrupo       => CAST(:QUERY.GRUPO AS BIGINT),
    p_fk_tasignatura  => CAST(:QUERY.ASIGNATURA AS BIGINT),
    -- Igual que /asistencias/calendario: QUERY.MIAS=true -> docente del token
    -- (no funcionario -> -1 -> todo en cero); QUERY.FUNCIONARIO -> docente
    -- concreto; NULL -> todo el scope.
    p_fk_tfuncionario => CASE
        WHEN COALESCE(CAST(:QUERY.MIAS AS BOOLEAN), FALSE)
        THEN COALESCE((SELECT f.PK_TFUNCIONARIO FROM academico_test.TFUNCIONARIO f
                        WHERE f.FK_TUSUARIO = public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
                          AND f.ACTIVE = TRUE), -1)
        ELSE CAST(:QUERY.FUNCIONARIO AS BIGINT)
    END
);$q$,
    'postgres', false, false, m.id_microservice,
    '/asistencias/resumen-horas', 'SELECT', 'GET',
    '{
       "QUERY.SEDE":       "BIGINT!",
       "QUERY.FECHA":      "VARCHAR",
       "QUERY.GRUPO":      "BIGINT",
       "QUERY.ASIGNATURA": "BIGINT",
       "QUERY.MIAS":       "BOOLEAN",
       "QUERY.FUNCIONARIO":"BIGINT"
     }'::jsonb,
    'V221 -- tarjetas del encabezado de Asistencia. Horas DICTADAS (horas_semana/mes/anio) vs PROGRAMADAS del horario (horas_programadas_semana/mes) -> el widget "16 h / 20 h - faltan 4 h" es horas_semana vs horas_programadas_semana. Mas horas_efectivas_mes, conteos del mes y los 3 estados (registradas/retrasadas/pendientes). QUERY.MIAS=true acota a las asignaturas del docente del token; QUERY.FUNCIONARIO por un docente concreto.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (uuid) DO UPDATE
   SET query = EXCLUDED.query, param_types = EXCLUDED.param_types,
       path_template = EXCLUDED.path_template, http_method = EXCLUDED.http_method,
       execution_mode = EXCLUDED.execution_mode, microservice_id = EXCLUDED.microservice_id,
       detail = EXCLUDED.detail;


-- ---------------------------------------------------------------------------
-- 6. role_query — capa del GATEWAY para los 6 endpoints.
--
--    Se otorga a CEVAL-SUPER_ADMINISTRADOR MAS a todo rol academico que ya
--    tenga concedido el menu 'ASISTENCIAS' (academico_test.trol_menu ACTIVE)
--    -- del dump base eso incluye DOCENTE y RECTOR. El mapeo rol academico ->
--    public.role es 'CEVAL-' || trol.codigo (p.ej. DOCENTE -> CEVAL-DOCENTE).
--    Asi el catalogo HTTP queda sincronizado con la capability real: cuando
--    el super admin concede 'ASISTENCIAS' a un rol nuevo desde la pantalla de
--    roles, basta re-aplicar esta migracion (o un INSERT manual) para abrirle
--    tambien el gateway. El control FINO (capability + scope + periodo
--    cerrado) sigue en V220.
-- ---------------------------------------------------------------------------
INSERT INTO public.role_query (role_id, query_id)
SELECT pr.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id AND m.serviceid = 'eval-col'
 CROSS JOIN LATERAL (
       -- super admin siempre + los roles con el menu ASISTENCIAS concedido
       SELECT 'CEVAL-SUPER_ADMINISTRADOR'::text AS rname
       UNION
       SELECT 'CEVAL-' || tr.codigo
         FROM academico_test.trol_menu rm
         JOIN academico_test.tmenu tm ON tm.pk_tmenu = rm.fk_tmenu
          AND tm.codigo = 'ASISTENCIAS' AND tm.active = TRUE
         JOIN academico_test.trol tr  ON tr.pk_trol = rm.fk_trol AND tr.active = TRUE
        WHERE rm.active = TRUE
 ) src
  JOIN public.role pr ON pr.name = src.rname
 WHERE q.uuid IN ('asis-registrar', 'asis-editar', 'asis-seguimiento',
                  'asis-sesion-estudiantes', 'asis-calendario', 'asis-resumen-horas')
   AND NOT EXISTS (
       SELECT 1 FROM public.role_query rq
        WHERE rq.query_id = q.id_query AND rq.role_id = pr.id_role
   );


-- ---------------------------------------------------------------------------
-- 7. query_param_constraint — formato de los parametros caller-controlled.
--    param_types ya declara TIPO y obligatoriedad; esto acota el FORMATO,
--    para que query-service devuelva 400 PARAM_CONSTRAINT_VIOLATION antes de
--    llegar a Postgres (V70/V83).
--
--    Criterios:
--      * ids (grupo, asignatura, sede, matricula, archivo, :ID) -> positivos.
--      * TIPO_ASISTENCIA / MARCAR_TODOS -> 1..6 (dominio real del catalogo
--        TIPO_ASISTENCIA; 4 no existe pero el rango cubre 1,2,3,5,6 y la
--        funcion rechaza el 4 con un mensaje claro).
--      * BLOQUE -> 0..30 sin decimales (NUMERO_BLOQUE es NUMERIC(2)).
--      * MES 1..12, ANIO 2000..2100.
--      * PAGESIZE 1..200 -> impide que un cliente pida la tabla entera.
--      * SEARCH <= 100 y OBSERVACION <= 4000 (largo real de la columna).
-- ---------------------------------------------------------------------------
INSERT INTO public.query_param_constraint
       (query_id, param_key, only_positive, allow_decimals, max_digits,
        numeric_text, min_length, max_length, min_value, max_value)
SELECT q.id_query, c.param_key, c.only_positive, c.allow_decimals, c.max_digits,
       c.numeric_text, c.min_length, c.max_length, c.min_value, c.max_value
  FROM (VALUES
    -- uuid,              param_key,                      pos,   dec,   digits, numtxt, minlen, maxlen, minval, maxval
    -- La primera fila lleva casts explicitos: si una columna es NULL en
    -- todas las filas, PostgreSQL infiere `text` para el VALUES y el INSERT
    -- falla contra las columnas integer/boolean/numeric de la tabla.
    ('asis-registrar',    'BODY.GRUPO',                   TRUE,  FALSE, NULL::integer, NULL::boolean, NULL::integer, NULL::integer, NULL::numeric, NULL::numeric),
    ('asis-registrar',    'BODY.ASIGNATURA',              TRUE,  FALSE, NULL,   NULL,   NULL,   NULL,   NULL,   NULL),
    ('asis-registrar',    'BODY.BLOQUE',                  NULL,  FALSE, 2,      NULL,   NULL,   NULL,   0::numeric,  30::numeric),
    ('asis-registrar',    'BODY.MARCAR_TODOS',            TRUE,  FALSE, 1,      NULL,   NULL,   NULL,   1::numeric,  6::numeric),
    ('asis-editar',       'PARAM.ID',                     TRUE,  FALSE, NULL,   NULL,   NULL,   NULL,   NULL,   NULL),
    ('asis-editar',       'BODY.TIPO_ASISTENCIA',         TRUE,  FALSE, 1,      NULL,   NULL,   NULL,   1::numeric,  6::numeric),
    ('asis-editar',       'BODY.SOPORTE_ARCHIVO',         TRUE,  FALSE, NULL,   NULL,   NULL,   NULL,   NULL,   NULL),
    ('asis-editar',       'BODY.OBSERVACION',             NULL,  NULL,  NULL,   FALSE,  NULL,   4000,   NULL,   NULL),
    ('asis-sesion-estudiantes', 'QUERY.GRUPO',            TRUE,  FALSE, NULL,   NULL,   NULL,   NULL,   NULL,   NULL),
    ('asis-sesion-estudiantes', 'QUERY.ASIGNATURA',       TRUE,  FALSE, NULL,   NULL,   NULL,   NULL,   NULL,   NULL),
    ('asis-sesion-estudiantes', 'QUERY.BLOQUE',           NULL,  FALSE, 2,      NULL,   NULL,   NULL,   0::numeric,  30::numeric),
    ('asis-seguimiento',  'BODY.FILTERS.GRUPO',           TRUE,  FALSE, NULL,   NULL,   NULL,   NULL,   NULL,   NULL),
    ('asis-seguimiento',  'BODY.FILTERS.ASIGNATURA',      TRUE,  FALSE, NULL,   NULL,   NULL,   NULL,   NULL,   NULL),
    ('asis-seguimiento',  'BODY.FILTERS.TIPO_ASISTENCIA', TRUE,  FALSE, 1,      NULL,   NULL,   NULL,   1::numeric,  6::numeric),
    ('asis-seguimiento',  'BODY.FILTERS.SEARCH',          NULL,  NULL,  NULL,   FALSE,  NULL,   100,    NULL,   NULL),
    ('asis-seguimiento',  'BODY.PAGEINDEX',               NULL,  FALSE, 6,      NULL,   NULL,   NULL,   0::numeric,  NULL),
    ('asis-seguimiento',  'BODY.PAGESIZE',                TRUE,  FALSE, 3,      NULL,   NULL,   NULL,   1::numeric,  200::numeric),
    ('asis-calendario',   'QUERY.SEDE',                   TRUE,  FALSE, NULL,   NULL,   NULL,   NULL,   NULL,   NULL),
    ('asis-calendario',   'QUERY.ANIO',                   TRUE,  FALSE, 4,      NULL,   NULL,   NULL,   2000::numeric, 2100::numeric),
    ('asis-calendario',   'QUERY.MES',                    TRUE,  FALSE, 2,      NULL,   NULL,   NULL,   1::numeric,  12::numeric),
    ('asis-calendario',   'QUERY.GRUPO',                  TRUE,  FALSE, NULL,   NULL,   NULL,   NULL,   NULL,   NULL),
    ('asis-calendario',   'QUERY.ASIGNATURA',             TRUE,  FALSE, NULL,   NULL,   NULL,   NULL,   NULL,   NULL),
    ('asis-calendario',   'QUERY.FUNCIONARIO',            TRUE,  FALSE, NULL,   NULL,   NULL,   NULL,   NULL,   NULL),
    ('asis-resumen-horas','QUERY.SEDE',                   TRUE,  FALSE, NULL,   NULL,   NULL,   NULL,   NULL,   NULL),
    ('asis-resumen-horas','QUERY.GRUPO',                  TRUE,  FALSE, NULL,   NULL,   NULL,   NULL,   NULL,   NULL),
    ('asis-resumen-horas','QUERY.ASIGNATURA',             TRUE,  FALSE, NULL,   NULL,   NULL,   NULL,   NULL,   NULL),
    ('asis-resumen-horas','QUERY.FUNCIONARIO',            TRUE,  FALSE, NULL,   NULL,   NULL,   NULL,   NULL,   NULL)
  ) AS c(uuid, param_key, only_positive, allow_decimals, max_digits,
         numeric_text, min_length, max_length, min_value, max_value)
  JOIN public.query q ON q.uuid = c.uuid
ON CONFLICT (query_id, param_key) DO UPDATE
   SET only_positive  = EXCLUDED.only_positive,
       allow_decimals = EXCLUDED.allow_decimals,
       max_digits     = EXCLUDED.max_digits,
       numeric_text   = EXCLUDED.numeric_text,
       min_length     = EXCLUDED.min_length,
       max_length     = EXCLUDED.max_length,
       min_value      = EXCLUDED.min_value,
       max_value      = EXCLUDED.max_value;
