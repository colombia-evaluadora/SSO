-- =============================================================================
-- V228 -- Reporte PDF/Excel de la pantalla Asistencia > Seguimiento.
--
--   POST /asistencias/export-all  ->  fn_asistencia_listar_seguimiento (V220)
--                                     sin paginar
--
-- Es la fila que consume el reporting-service (clave `asistencias` en su
-- application.yml) cuando el front pulsa el boton de descarga de
-- GESTION ACADEMICA > ASISTENCIA > SEGUIMIENTO, la pantalla que hoy lista con
-- POST /asistencias/query (fila 'asis-seguimiento', V221) y cuyo boton de
-- descarga todavia no hacia nada.
--
-- -----------------------------------------------------------------------------
-- NUMERACION FUERA DE ORDEN -- LEER ANTES DE DESPLEGAR
-- -----------------------------------------------------------------------------
-- El techo del repo ronda los V400 y el siguiente secuencial libre estaba muy
-- por encima. Se eligio V228 A PROPOSITO, para que este archivo quede
-- fisicamente junto al resto del modulo de Asistencias (V220 dominio, V221
-- endpoints, V290 reporte por grupo) y no a casi 200 numeros de distancia.
-- V228 se verifico libre en TODAS las ramas de origin.
--
-- Consecuencia operativa: en cualquier base que YA paso de V228 -- y todas las
-- desplegadas lo estan -- Flyway tiene que aplicarla OUT-OF-ORDER. El
-- `flyway migrate` normal de .github/workflows/deploy.yml la RECHAZA
-- ("Detected resolved migration not applied to database"); solo entra por la
-- ruta de recuperacion del mismo workflow (lineas ~478-480), que corre
-- `flyway -outOfOrder=true migrate`. Quien despliegue esto debe contar con que
-- se pasara por esa rama, o aplicar el SQL a mano y registrarlo.
--
-- -----------------------------------------------------------------------------
-- POR QUE NO HAY FUNCION PL/PGSQL NUEVA NI HUBO QUE EDITAR V220
-- -----------------------------------------------------------------------------
-- Patron de reporte del repo (V67/V68/V124/V290/V404): un reporte no es una
-- funcion nueva, es la MISMA funcion del listado invocada sin paginar detras de
-- una ruta separada. Asi la pantalla y su exportacion no pueden divergir ni en
-- el WHERE ni en el alcance por rol (fn_asistencia_puede_ver, V220).
--
-- fn_asistencia_listar_seguimiento YA soporta "sin limite" sin tocarla: su SQL
-- dice `LIMIT NULLIF($9, 0)`, asi que p_page_size NULL (o 0) deja el LIMIT en
-- NULL, que en PostgreSQL es "sin clausula" -- lo mismo que V124 encontro en
-- fn_periodo_listar. NO cae en la trampa de V224/V404, donde el LIMIT estaba
-- escrito `GREATEST(p_limite, 1)` y, como GREATEST ignora los NULL,
-- GREATEST(NULL, 1) = 1 habria exportado UNA sola fila. Aqui no habia nada que
-- arreglar, asi que V220 se deja intacta (no se toca su checksum).
--
-- -----------------------------------------------------------------------------
-- DIFERENCIA CON /asistencias/reporte (V290, clave `asistencia`)
-- -----------------------------------------------------------------------------
-- Son DOS reportes distintos sobre la misma funcion y conviven a proposito:
--   * /asistencias/reporte (V290, E03HU57) es el "Reporte de asistencia por
--     grupo": exige GRUPO + FECHA_DESDE + FECHA_HASTA, porque un reporte por
--     grupo sin acotar no tiene sentido.
--   * /asistencias/export-all (esta) es "exporta LO QUE ESTOY VIENDO en
--     Seguimiento": recibe exactamente los filtros que el usuario dejo puestos
--     en la pantalla, TODOS opcionales -- si el usuario no filtro nada, el
--     boton igual tiene que descargar. El freno no es un filtro obligatorio
--     sino el max-rows del reporting-service y el gate de la funcion.
-- Por eso esta no duplica la entrada `asistencia` del reporting-service: se
-- suma la clave `asistencias` al lado.
--
-- -----------------------------------------------------------------------------
-- EL CUERPO: { format, filters, sorting }
-- -----------------------------------------------------------------------------
-- Los binds van bajo BODY.FILTERS.* con los MISMOS nombres que ya usa
-- 'asis-seguimiento' (FECHA_DESDE, FECHA_HASTA, GRUPO, ASIGNATURA, ACTIVIDAD,
-- TIPO_ASISTENCIA, SEARCH). Es el contrato unico de POST /reportes/{clave}: el
-- front manda el mismo objeto de filtros que ya arma para el listado y el
-- reporting-service no tiene que conocer la forma de cada dominio. SEARCH es el
-- buscador "Buscar por nombre, grupo o asignatura"; TIPO_ASISTENCIA es el chip
-- tipo:(NO Asistio) (VALOR 1..6 de TLISTA_VALOR TIPO_ASISTENCIA).
--
-- BODY.PAGEINDEX / BODY.PAGESIZE NO se declaran: no se puede paginar un reporte
-- ni por accidente. Se pasan NULL::INTEGER (= sin limite, ver arriba).
--
-- BODY.FILTERS.IDS -- "exportar seleccionados" (V69/V124/V404). La PK
-- exportable es pk_tasistencia, que la funcion ya devuelve. El recorte va en un
-- WHERE POR FUERA de la funcion, DESPUES de que esta aplico su gate, asi que
-- mandar el id de una fila que el usuario no puede ver no la revela: si la
-- funcion no la devolvio, el WHERE no tiene nada que recortar.
--
-- BODY.SORTING.ID / BODY.SORTING.DESC -> p_sort_by / p_sort_dir. ID cae a
-- 'fecha' si no esta en la whitelist de la funcion
-- (estudiante|documento|fecha|tipo|grupo|asignatura|actividad).
-- OJO con el default de DESC: en 'asis-seguimiento' es TRUE (mas recientes
-- primero, que es lo que la pantalla muestra) -- aqui se repite ese TRUE para
-- que el PDF salga en el MISMO orden que la tabla que el usuario esta viendo.
--
-- -----------------------------------------------------------------------------
-- LA COLUMNA GRADO
-- -----------------------------------------------------------------------------
-- La pantalla pinta ESTUDIANTE / TIPO DE ASISTENCIA / ASIGNATURA / GRADO /
-- FECHA / SOPORTE, pero fn_asistencia_listar_seguimiento devuelve `grupo` (el
-- nombre del grupo: 'A', 'B') y NO expone `grado` en su RETURNS TABLE. Ampliar
-- el RETURNS TABLE obligaria a DROP + CREATE de una funcion ya aplicada en
-- todos los entornos (cambio de checksum de V220, que es una migracion enorme y
-- ajena a esto). En su lugar el grado se trae con un LEFT JOIN a
-- academico_test.v_asistencia_detalle -- la MISMA vista de la que sale la
-- funcion, donde grado/grado_valor ya vienen resueltos -- emparejando por
-- pk_tasistencia. No abre ningun agujero: solo se enriquecen filas que la
-- funcion YA devolvio y por tanto YA pasaron el gate; el join no puede agregar
-- filas (pk_tasistencia es PK de la vista).
--
-- -----------------------------------------------------------------------------
-- ROLES
-- -----------------------------------------------------------------------------
-- "Quien ve el listado puede exportarlo" (V67/V124/V290/V404): los role_query se
-- COPIAN con un SELECT de los de 'asis-seguimiento'. No se escribe ni un nombre
-- de rol a mano -- en bases donde falten roles del dump base, hardcodearlos
-- seria un no-op silencioso y el endpoint responderia 403 a todo el mundo.
-- El control fino sigue siendo fn_asistencia_puede_ver (capability VER sobre el
-- menu 'ASISTENCIAS' + scope por categoria de rol), que corre DENTRO de la
-- funcion reusada.
--
-- Idempotente: DELETE por uuid + INSERT (role_query cascadea), igual que V404.
--
-- Tras aplicar: el contenedor query-service-eval-col cachea el catalogo -- hay
-- que REINICIARLO o el gateway sigue respondiendo 404 a la ruta nueva.
--
-- Depende de: V220 (fn_asistencia_listar_seguimiento, v_asistencia_detalle,
-- fn_asistencia_puede_ver), V221 (fila 'asis-seguimiento' y sus role_query),
-- V48 (fn_get_academico_usuario_id), V68 (reporting-service).
-- =============================================================================

DELETE FROM public.query WHERE uuid = 'eval-col-asistencias-seguimiento-export-all-001';

INSERT INTO public.query (
    uuid, query, type, public_end, captcha, detail, action, style,
    createddate, microservice_id, path_template, execution_mode,
    out_param_names, http_method, param_types, cacheable, cache_ttl_seconds
)
SELECT
    'eval-col-asistencias-seguimiento-export-all-001',
    $q$SELECT t.*, d.grado, d.grado_valor, d.jornada
  FROM academico_test.fn_asistencia_listar_seguimiento(
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
    p_sort_by         => CAST(:BODY.SORTING.ID AS TEXT),
    p_sort_dir        => CASE WHEN COALESCE(CAST(:BODY.SORTING.DESC AS BOOLEAN), TRUE)
                              THEN 'desc' ELSE 'asc' END
) t
  LEFT JOIN academico_test.v_asistencia_detalle d
         ON d.pk_tasistencia = t.pk_tasistencia
 WHERE CAST(:BODY.FILTERS.IDS AS BIGINT[]) IS NULL
    OR t.pk_tasistencia = ANY(CAST(:BODY.FILTERS.IDS AS BIGINT[]));$q$,
    listado.type, FALSE, FALSE,
    'V228 -- registros de asistencia SIN PAGINAR para el reporte PDF/Excel de la pantalla Seguimiento (reporting-service, clave asistencias). Misma funcion, mismos filtros y mismo gate/alcance que POST /asistencias/query (fn_asistencia_listar_seguimiento, V220/V221), con los binds bajo BODY.FILTERS.* (FECHA_DESDE, FECHA_HASTA, GRUPO, ASIGNATURA, ACTIVIDAD, TIPO_ASISTENCIA, SEARCH) + FILTERS.IDS para exportar seleccionados y SORTING.ID/DESC para el orden. TODOS los filtros son opcionales (exporta lo que el usuario este viendo). Agrega grado/grado_valor/jornada con un LEFT JOIN a v_asistencia_detalle por pk_tasistencia, porque la funcion devuelve grupo pero no grado y la pantalla pinta GRADO. No es /asistencias/reporte (V290), que es el reporte por grupo con GRUPO y rango de fechas obligatorios.',
    listado.action, listado.style,
    CURRENT_TIMESTAMP, listado.microservice_id,
    '/asistencias/export-all',
    listado.execution_mode, NULL, 'POST',
    '{"BODY.FILTERS.FECHA_DESDE":     "VARCHAR",
      "BODY.FILTERS.FECHA_HASTA":     "VARCHAR",
      "BODY.FILTERS.GRUPO":           "BIGINT",
      "BODY.FILTERS.ASIGNATURA":      "BIGINT",
      "BODY.FILTERS.ACTIVIDAD":       "BIGINT",
      "BODY.FILTERS.TIPO_ASISTENCIA": "NUMERIC",
      "BODY.FILTERS.SEARCH":          "VARCHAR",
      "BODY.FILTERS.IDS":             "BIGINT[]",
      "BODY.SORTING.ID":              "VARCHAR",
      "BODY.SORTING.DESC":            "BOOLEAN"}'::JSONB,
    FALSE, COALESCE(listado.cache_ttl_seconds, 0)
  FROM public.query listado
  JOIN public.microservice m ON m.id_microservice = listado.microservice_id
 WHERE m.serviceid = 'eval-col'
   AND listado.uuid = 'asis-seguimiento'
 LIMIT 1;

-- "Quien ve el listado puede exportarlo": se copian los roles de
-- 'asis-seguimiento' tal cual, nunca por nombre de rol.
INSERT INTO public.role_query (query_id, role_id)
SELECT reporte.id_query, rq.role_id
  FROM public.query reporte
  JOIN public.query listado  ON listado.uuid = 'asis-seguimiento'
  JOIN public.role_query rq  ON rq.query_id = listado.id_query
 WHERE reporte.uuid = 'eval-col-asistencias-seguimiento-export-all-001'
ON CONFLICT (query_id, role_id) DO NOTHING;

-- Mismas reglas de formato que 'asis-seguimiento' para los filtros compartidos
-- (ids positivos, TIPO_ASISTENCIA 1..6, SEARCH <= 100). FECHA_DESDE/FECHA_HASTA
-- no se acotan aqui, igual que en el listado: son VARCHAR casteados a DATE en el
-- SQL y un formato invalido lo rechaza el propio cast.
INSERT INTO public.query_param_constraint
       (query_id, param_key, only_positive, allow_decimals, max_digits,
        numeric_text, min_length, max_length, min_value, max_value)
SELECT q.id_query, c.param_key, c.only_positive, c.allow_decimals, c.max_digits,
       c.numeric_text, c.min_length, c.max_length, c.min_value, c.max_value
  FROM (VALUES
    ('BODY.FILTERS.GRUPO',           TRUE,  FALSE, NULL::integer, NULL::boolean, NULL::integer, NULL::integer, NULL::numeric, NULL::numeric),
    ('BODY.FILTERS.ASIGNATURA',      TRUE,  FALSE, NULL,   NULL,   NULL,   NULL,   NULL,   NULL),
    ('BODY.FILTERS.ACTIVIDAD',       TRUE,  FALSE, NULL,   NULL,   NULL,   NULL,   NULL,   NULL),
    ('BODY.FILTERS.TIPO_ASISTENCIA', TRUE,  FALSE, 1,      NULL,   NULL,   NULL,   1::numeric, 6::numeric),
    ('BODY.FILTERS.SEARCH',          NULL,  NULL,  NULL,   FALSE,  NULL,   100,    NULL,   NULL)
  ) AS c(param_key, only_positive, allow_decimals, max_digits,
         numeric_text, min_length, max_length, min_value, max_value)
 CROSS JOIN (SELECT id_query FROM public.query
              WHERE uuid = 'eval-col-asistencias-seguimiento-export-all-001') q
ON CONFLICT (query_id, param_key) DO UPDATE
   SET only_positive  = EXCLUDED.only_positive,
       allow_decimals = EXCLUDED.allow_decimals,
       max_digits     = EXCLUDED.max_digits,
       numeric_text   = EXCLUDED.numeric_text,
       min_length     = EXCLUDED.min_length,
       max_length     = EXCLUDED.max_length,
       min_value      = EXCLUDED.min_value,
       max_value      = EXCLUDED.max_value;

-- Red de seguridad: si 'asis-seguimiento' no existia en esta base, el INSERT de
-- arriba no inserto nada y el reporting-service respondera 404 en silencio.
-- Mejor que reviente la migracion.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.query
                    WHERE uuid = 'eval-col-asistencias-seguimiento-export-all-001') THEN
        RAISE EXCEPTION 'V228: no se creo la fila de /asistencias/export-all (falta la fila asis-seguimiento de POST /asistencias/query, V221)';
    END IF;
END $$;
