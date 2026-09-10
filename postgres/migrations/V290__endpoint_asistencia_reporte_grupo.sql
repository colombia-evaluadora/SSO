-- ===========================================================================
-- V281 — endpoint de reporte para "Resumen: Reporte de asistencia por grupo"
-- (E03HU57, modulo Asistencias / V220-V221).
--
-- Criterios de aceptacion de la HU:
--   * seleccionar grupo y rango de fechas.
--   * el reporte muestra porcentajes de asistencia, faltas y tardanzas.
--   * incluye observaciones y justificaciones.
--   * exportable en PDF/Excel.
--
-- ---------------------------------------------------------------------------
-- POR QUE NO HAY UNA FUNCION PL/PGSQL NUEVA
-- ---------------------------------------------------------------------------
-- Este backend YA tiene un patron para "reporte" (V67/V68/V69, modulo
-- Establecimientos): un reporte NO es una funcion nueva, es la MISMA funcion
-- del listado interactivo, invocada sin paginar, detras de una ruta separada
-- que reporting-service (microservicio REST, V68) llama para armar el PDF o
-- el Excel -- "corre las mismas funciones PL/pgSQL de los listados sin
-- paginar y devuelve PDF o Excel". Ese microservicio, no esta migracion, es
-- quien calcula/tabula porcentajes al renderizar.
--
-- La pantalla "Seguimiento" (fn_asistencia_listar_seguimiento, V220) YA es
-- exactamente el listado que hace falta: filtra por grupo + rango de fecha,
-- y cada fila trae observacion + tiene_soporte/soporte_nombre (justificacion)
-- ademas de total_estudiantes/ausentes como ventana sobre el set filtrado
-- completo -- lo mismo que ya usa esa pantalla para sus tarjetas de resumen.
-- No hay nada que agregar en PL/pgSQL: se reusa 1:1, igual que V67 reuso
-- fn_usu_empleados_listar/fn_est_listar/fn_sed_listar para sus 3 reportes.
--
-- Diferencia con /asistencias/query (la pantalla interactiva):
--   * BODY.PAGEINDEX / BODY.PAGESIZE NO se declaran (no se puede paginar un
--     reporte ni por accidente) -- se pasan NULL::INTEGER, que desde V66
--     significa "sin limite" (ver fn_asistencia_listar_seguimiento: con
--     $9 NULL, NULLIF($9,0) es NULL -> LIMIT sin tope).
--   * BODY.FILTERS.GRUPO, FECHA_DESDE y FECHA_HASTA pasan a ser
--     OBLIGATORIOS ("!"): un reporte "por grupo" sin acotar por grupo Y por
--     fecha materializaria el historico completo de asistencia de la sede en
--     una sola llamada sin paginar -- el mismo costo que V69 acepta para
--     "exportar seleccionados" (calcular todo el listado) pero aqui sin
--     limite superior de filas si faltara el grupo o el rango. En
--     /asistencias/query los tres quedan opcionales porque esa pantalla SI
--     pagina.
--
-- ---------------------------------------------------------------------------
-- ROLES: los MISMOS que ya pueden ver Seguimiento
-- ---------------------------------------------------------------------------
-- "Quien puede ver el listado puede exportarlo" (V67). Se copian 1:1 los
-- role_query de 'asis-seguimiento' -- ni un permiso nuevo ni un rol excluido
-- a mano, asi que si mañana se le concede/quita ASISTENCIAS a un rol y se
-- reaplica V221, este reporte queda sincronizado sin tocar este archivo. El
-- control fino (capability + scope + periodo) sigue siendo
-- fn_asistencia_puede_ver (V220), que corre DENTRO de la funcion reusada.
--
-- ---------------------------------------------------------------------------
-- Idempotencia: uuid corto + ON CONFLICT (uuid) DO UPDATE (igual que V221);
-- role_query y query_param_constraint por INSERT ... WHERE NOT EXISTS /
-- ON CONFLICT sobre su UNIQUE.
--
-- Tras aplicar: el contenedor query-service-eval-col cachea el catalogo --
-- hay que reiniciarlo para que la ruta nueva deje de dar 404.
--
-- Depende de: V220 (fn_asistencia_listar_seguimiento, fn_asistencia_puede_ver),
-- V221 ('asis-seguimiento', sus role_query y su query_param_constraint), V68
-- (microservicio reporting-service).
-- Numeracion: V281 es el primer hueco libre por encima de V280; revisadas
-- todas las ramas de origin.
-- ===========================================================================

SET search_path TO public;

-- ---------------------------------------------------------------------------
-- 1. Endpoint del reporte -- misma funcion que 'asis-seguimiento', sin
--    paginar, con GRUPO + rango de fecha obligatorios.
-- ---------------------------------------------------------------------------
INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id,
                          path_template, execution_mode, http_method, param_types, detail)
SELECT
    'asis-reporte-grupo',
    $q$SELECT * FROM academico_test.fn_asistencia_listar_seguimiento(
    p_pk_usuario      => public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    p_fecha_desde     => CAST(:BODY.FILTERS.FECHA_DESDE AS DATE),
    p_fecha_hasta     => CAST(:BODY.FILTERS.FECHA_HASTA AS DATE),
    p_fk_tgrupo       => CAST(:BODY.FILTERS.GRUPO AS BIGINT),
    p_fk_tasignatura  => CAST(:BODY.FILTERS.ASIGNATURA AS BIGINT),
    p_fk_tactividad   => CAST(:BODY.FILTERS.ACTIVIDAD AS BIGINT),
    p_tipo_asistencia => CAST(:BODY.FILTERS.TIPO_ASISTENCIA AS NUMERIC),
    p_search          => CAST(:BODY.FILTERS.SEARCH AS TEXT),
    p_page_index      => NULL::INTEGER,
    p_page_size       => NULL::INTEGER,
    p_sort_by         => COALESCE(CAST(:BODY.SORTING.ID AS TEXT), 'estudiante'),
    p_sort_dir        => CASE WHEN COALESCE(CAST(:BODY.SORTING.DESC AS BOOLEAN), FALSE)
                              THEN 'desc' ELSE 'asc' END
);$q$,
    'postgres', false, false, m.id_microservice,
    '/asistencias/reporte', 'SELECT', 'POST',
    '{
       "BODY.FILTERS.FECHA_DESDE":     "VARCHAR!",
       "BODY.FILTERS.FECHA_HASTA":     "VARCHAR!",
       "BODY.FILTERS.GRUPO":           "BIGINT!",
       "BODY.FILTERS.ASIGNATURA":      "BIGINT",
       "BODY.FILTERS.ACTIVIDAD":       "BIGINT",
       "BODY.FILTERS.TIPO_ASISTENCIA": "NUMERIC",
       "BODY.FILTERS.SEARCH":          "VARCHAR",
       "BODY.SORTING.ID":              "VARCHAR",
       "BODY.SORTING.DESC":            "BOOLEAN"
     }'::jsonb,
    'V281 -- Reporte de asistencia por grupo (E03HU57): igual que /asistencias/query (fn_asistencia_listar_seguimiento) pero SIN paginar y con GRUPO + FECHA_DESDE + FECHA_HASTA obligatorios -- el insumo que reporting-service (V68) usa para armar el PDF/Excel. Cada fila trae observacion y soporte (tiene_soporte/soporte_nombre = justificacion) ademas de total_estudiantes/ausentes como ventana sobre el set filtrado completo; los porcentajes de asistencia/faltas/tardanzas se tabulan a partir de esas filas, no en esta funcion. FILTERS.ASIGNATURA y FILTERS.ACTIVIDAD siguen siendo opcionales y combinables (preescolar/formativo). Mismo gate que Seguimiento: fn_asistencia_puede_ver dentro de la funcion reusada.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (uuid) DO UPDATE
   SET query = EXCLUDED.query, param_types = EXCLUDED.param_types,
       path_template = EXCLUDED.path_template, http_method = EXCLUDED.http_method,
       execution_mode = EXCLUDED.execution_mode, microservice_id = EXCLUDED.microservice_id,
       detail = EXCLUDED.detail;

-- ---------------------------------------------------------------------------
-- 2. role_query -- copia 1:1 de 'asis-seguimiento' ("quien ve el listado
--    puede exportarlo", V67). Si el listado gana/pierde un rol y se reaplica
--    V221, basta reaplicar este archivo para que el reporte quede igual.
-- ---------------------------------------------------------------------------
INSERT INTO public.role_query (role_id, query_id)
SELECT rq.role_id, q_new.id_query
  FROM public.role_query rq
  JOIN public.query q_old ON q_old.id_query = rq.query_id AND q_old.uuid = 'asis-seguimiento'
  JOIN public.query q_new ON q_new.uuid = 'asis-reporte-grupo'
 WHERE NOT EXISTS (
     SELECT 1 FROM public.role_query rq2
      WHERE rq2.query_id = q_new.id_query AND rq2.role_id = rq.role_id
 );

-- ---------------------------------------------------------------------------
-- 3. query_param_constraint -- mismas reglas de formato que 'asis-seguimiento'
--    para los filtros que este reporte comparte con ella (ids positivos,
--    TIPO_ASISTENCIA 1..6, SEARCH <= 100). FECHA_DESDE/FECHA_HASTA no se
--    acotan aqui tampoco (igual que en 'asis-seguimiento'): son VARCHAR
--    casteados a DATE en el SQL, y un formato invalido lo rechaza el cast.
-- ---------------------------------------------------------------------------
INSERT INTO public.query_param_constraint
       (query_id, param_key, only_positive, allow_decimals, max_digits,
        numeric_text, min_length, max_length, min_value, max_value)
SELECT q.id_query, c.param_key, c.only_positive, c.allow_decimals, c.max_digits,
       c.numeric_text, c.min_length, c.max_length, c.min_value, c.max_value
  FROM (VALUES
    -- param_key,                      pos,   dec,   digits, numtxt, minlen, maxlen, minval, maxval
    ('BODY.FILTERS.GRUPO',           TRUE,  FALSE, NULL::integer, NULL::boolean, NULL::integer, NULL::integer, NULL::numeric, NULL::numeric),
    ('BODY.FILTERS.ASIGNATURA',      TRUE,  FALSE, NULL,   NULL,   NULL,   NULL,   NULL,   NULL),
    ('BODY.FILTERS.ACTIVIDAD',       TRUE,  FALSE, NULL,   NULL,   NULL,   NULL,   NULL,   NULL),
    ('BODY.FILTERS.TIPO_ASISTENCIA', TRUE,  FALSE, 1,      NULL,   NULL,   NULL,   1::numeric, 6::numeric),
    ('BODY.FILTERS.SEARCH',          NULL,  NULL,  NULL,   FALSE,  NULL,   100,    NULL,   NULL)
  ) AS c(param_key, only_positive, allow_decimals, max_digits,
         numeric_text, min_length, max_length, min_value, max_value)
 CROSS JOIN (SELECT id_query FROM public.query WHERE uuid = 'asis-reporte-grupo') q
ON CONFLICT (query_id, param_key) DO UPDATE
   SET only_positive  = EXCLUDED.only_positive,
       allow_decimals = EXCLUDED.allow_decimals,
       max_digits     = EXCLUDED.max_digits,
       numeric_text   = EXCLUDED.numeric_text,
       min_length     = EXCLUDED.min_length,
       max_length     = EXCLUDED.max_length,
       min_value      = EXCLUDED.min_value,
       max_value      = EXCLUDED.max_value;
