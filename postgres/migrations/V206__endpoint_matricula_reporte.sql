-- ===========================================================================
-- V206 — endpoint de reporte para Matricula: exportar en PDF/Excel las filas
-- que ve el listado de la pantalla, con SOLO las columnas que el front tenga
-- visibles en ese momento.
--
-- ---------------------------------------------------------------------------
-- POR QUE NO HAY FUNCION PL/PGSQL NUEVA
-- ---------------------------------------------------------------------------
-- Mismo patron ya usado en V67 (Establecimientos/Funcionarios/Sedes) y V290/
-- V281 (Asistencia): un reporte es la MISMA funcion del listado interactivo
-- (fn_matricula_listar, V200/V270), invocada SIN paginar (PAGEINDEX/PAGESIZE
-- en NULL), detras de una ruta separada que reporting-service llama para
-- armar el PDF o el Excel a partir de las filas.
--
-- fn_matricula_listar YA soporta "sin paginar" de fabrica -- su propio
-- comentario de parametro dice "0/NULL = sin paginar" -- asi que no hace
-- falta ni siquiera el truco de V66 (LIMIT NULLIF(...,0)) para habilitarlo;
-- la funcion ya lo hacia.
--
-- ---------------------------------------------------------------------------
-- COLUMNAS VISIBLES (la parte nueva de esta entrega)
-- ---------------------------------------------------------------------------
-- Esta migracion SOLO registra la ruta -- que columnas salen en el archivo
-- ya no depende unicamente de `reporting.reports.matricula.columns` (fijo,
-- application.yml): reporting-service ahora acepta tambien un `columns` en
-- el body de POST /reportes/:clave, y filtra/reordena el mapa configurado
-- por esa lista (ignora claves que no esten declaradas -- no hay forma de
-- pedir por este camino una columna interna que no estuviera ya pensada
-- para exportarse). Ver ReportRequest.java / ColumnLayout.java /
-- reporting-service/application.yml (entrada `matricula`) en el mismo
-- commit. Esta fila de public.query es agnostica a eso: solo trae las
-- filas, reporting-service decide que imprimir de cada una.
--
-- ---------------------------------------------------------------------------
-- ROLES: los MISMOS que ya pueden ver /matricula/query (V127)
-- ---------------------------------------------------------------------------
-- Se copian 1:1 los role_query de la fila 'q-mtc0mvvz-mlz97d71'
-- (/matricula/query, POST) -- "quien ve el listado puede exportarlo" (V67).
-- Si esos roles cambian y se reaplica la migracion que los define, basta
-- reaplicar esta para que el reporte quede sincronizado.
--
-- Idempotencia: uuid propio + mismo criterio de conflicto que V127
-- (microservice_id, path_template, http_method) DO NOTHING -- este modulo no
-- usa ON CONFLICT (uuid) DO UPDATE como V220/V221/V281/V290; se sigue el
-- criterio ya establecido en el archivo hermano de Matricula.
--
-- Depende de: V200/V270 (fn_matricula_listar), V127 (fila /matricula/query y
-- sus role_query), V68 (microservicio reporting-service) -- todas numeradas
-- por debajo, asi que Flyway las aplica primero sin importar el hueco elegido.
-- Numeracion: V206 es un hueco libre (nunca usado en ninguna rama de origin,
-- V206..V210 seguidos estaban disponibles) -- se prefiere sobre seguir
-- apilando al final de la cola (que en el momento de escribir esto ya iba en
-- V293) para no dejar huecos permanentes en la numeracion.
-- ===========================================================================

SET search_path TO public;

-- ---------------------------------------------------------------------------
-- 1. Endpoint del reporte -- misma fn_matricula_listar, sin paginar.
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-matricula-reporte',
    'SELECT * FROM academico_test.fn_matricula_listar(
              p_search     => CAST(:BODY.SEARCH AS TEXT),
              p_statuses   => CAST(:BODY.STATUSES AS TEXT[]),
              p_campus     => CAST(:BODY.CAMPUS AS TEXT),
              p_shift      => CAST(:BODY.SHIFT AS TEXT),
              p_grade      => CAST(:BODY.GRADE AS INT),
              p_group      => CAST(:BODY.GROUP AS TEXT),
              p_page_index => NULL::INT,
              p_page_size  => NULL::INT,
              p_pk_usuario => public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
              p_sort_by    => CAST(:BODY.SORTBY AS TEXT),
              p_sort_dir   => CAST(:BODY.SORTDIR AS TEXT)
          )',
    'postgres', false, false,
    m.id_microservice,
    '/matricula/reporte', 'SELECT', 'POST',
    -- Mismos binds que /matricula/query MENOS PAGEINDEX/PAGESIZE (no se
    -- puede paginar un reporte ni por accidente -- mismo criterio que V67).
    -- BODY.COLUMNS no se declara aqui: lo consume reporting-service antes de
    -- llegar a query-service (ver ReportController), asi que ni siquiera
    -- viaja hasta esta fila.
    '{"BODY.GRADE": "INTEGER", "BODY.GROUP": "TEXT", "BODY.SHIFT": "TEXT", "BODY.CAMPUS": "TEXT", "BODY.SEARCH": "TEXT", "BODY.SORTBY": "TEXT", "BODY.SORTDIR": "TEXT", "BODY.STATUSES": "TEXT[]"}'::jsonb,
    NULL,
    'V206 -- Reporte de Matricula: igual que /matricula/query (fn_matricula_listar) pero SIN paginar -- el insumo que reporting-service usa para armar el PDF/Excel. Las columnas del archivo las decide reporting-service (config + el `columns` que mande el front con las que tenga visibles en la tabla), no esta fila. Mismo gate que el listado: fn_matricula_puede_ver por fila dentro de la funcion reusada.',
    NULL,
    NULL,
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. role_query -- copia 1:1 de /matricula/query (POST).
-- ---------------------------------------------------------------------------
INSERT INTO public.role_query (role_id, query_id)
SELECT rq.role_id, q_new.id_query
  FROM public.role_query rq
  JOIN public.query q_old ON q_old.id_query = rq.query_id
                          AND q_old.path_template = '/matricula/query'
                          AND q_old.http_method = 'POST'
  JOIN public.query q_new ON q_new.uuid = 'q-matricula-reporte'
 WHERE NOT EXISTS (
     SELECT 1 FROM public.role_query rq2
      WHERE rq2.query_id = q_new.id_query AND rq2.role_id = rq.role_id
 );
