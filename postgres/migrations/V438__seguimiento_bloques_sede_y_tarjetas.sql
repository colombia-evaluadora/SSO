-- V438 -- Seguimiento: una fila por corrida de bloques CONSECUTIVOS (la misma
-- asignatura dictada en 5 bloques salia 5 veces), filtro por SEDE (el front ya
-- la mandaba pero no habia por donde recibirla, y un rector veia las de todas
-- sus sedes), y las tarjetas asistieron/tarde como ventanas sobre el set
-- filtrado completo -- la funcion no las devolvia y el front terminaba
-- contandolas sobre la pagina visible. Suma fn_asistencia_editar_bulk: una
-- fila agrupada son N registros de TASISTENCIA.
-- Va aparte de V220/V436 (ya aplicadas) por el mismo motivo que V436: se
-- revierte con un CREATE OR REPLACE. Cambia la aridad (14 -> 15) y el
-- RETURNS TABLE. Tras aplicar, REINICIAR query-service-eval-col (cachea el
-- catalogo) o la ruta nueva responde 404.
-- Depende de: V220 (modulo, vista, fn_asistencia_editar), V221 / V228 / V290
-- (catalogo HTTP), V436 (jornada/grado).

SET search_path TO public;


-- ---------------------------------------------------------------------------
-- 1. Que estado manda en una corrida de bloques mezclada. Un solo sitio para
--    la regla, como las banderas es_presente/es_tarde/es_ausente de la vista.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_tipo_prioridad(
    p_tipo_valor INTEGER
)
RETURNS INTEGER
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE p_tipo_valor
        WHEN 5 THEN 1   -- Llego tarde
        WHEN 2 THEN 3   -- No asistio
        WHEN 1 THEN 5   -- Asistio
        ELSE 9          -- desconocido: nunca gana
    END;
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_tipo_prioridad(INTEGER)
    IS 'Que estado manda cuando una corrida de bloques mezcla varios, 1 = gana: 5 Llego tarde, 6 Llego tarde justificado, 2 No asistio, 3 No asistio justificado, 1 Asistio. La tardanza gana a la inasistencia a proposito: si el estudiante llego tarde a uno de los cinco bloques seguidos de la misma asignatura, ESTUVO, y la fila agrupada dice "Llego tarde" -- es la lectura que pide la pantalla de Seguimiento, y hace juego con la de Asistencia manual, donde el bloque solo se elige al marcar Llego tarde. La usa fn_asistencia_listar_seguimiento. Cualquier valor fuera del dominio queda ultimo (9) para que nunca gane.';


-- ---------------------------------------------------------------------------
-- 2. El listado.
-- ---------------------------------------------------------------------------
-- Se sueltan las DOS firmas: la de V436 (14 params) porque cambia la aridad, y
-- la propia (15) porque al reaplicar la migracion cambia el RETURNS TABLE, y
-- eso CREATE OR REPLACE no lo permite ("cannot change return type").
DROP FUNCTION IF EXISTS academico_test.fn_asistencia_listar_seguimiento(
    BIGINT, DATE, DATE, BIGINT, BIGINT, NUMERIC, TEXT, INT, INT, TEXT, TEXT, BIGINT, TEXT, TEXT);
DROP FUNCTION IF EXISTS academico_test.fn_asistencia_listar_seguimiento(
    BIGINT, DATE, DATE, BIGINT, BIGINT, NUMERIC, TEXT, INT, INT, TEXT, TEXT, BIGINT, TEXT, TEXT, BIGINT);

DROP FUNCTION IF EXISTS academico_test.fn_asistencia_listar_seguimiento(bigint,date,date,bigint,bigint,numeric,text,integer,integer,text,text,bigint,text,text,bigint);

CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_listar_seguimiento(
    p_pk_usuario      BIGINT  DEFAULT NULL,   -- alcance (fn_asistencia_puede_ver)
    p_fecha_desde     DATE    DEFAULT NULL,
    p_fecha_hasta     DATE    DEFAULT NULL,
    p_fk_tgrupo       BIGINT  DEFAULT NULL,
    p_fk_tasignatura  BIGINT  DEFAULT NULL,
    p_tipo_asistencia NUMERIC DEFAULT NULL,   -- VALOR de TIPO_ASISTENCIA
    p_search          TEXT    DEFAULT NULL,
    p_page_index      INT     DEFAULT 0,
    p_page_size       INT     DEFAULT 10,
    p_sort_by         TEXT    DEFAULT NULL,   -- estudiante|fecha|tipo|grupo|asignatura|actividad|documento
    p_sort_dir        TEXT    DEFAULT NULL,   -- asc|desc
    p_fk_tactividad   BIGINT  DEFAULT NULL,   -- filtro formativo, independiente de la asignatura
    p_jornada         TEXT    DEFAULT NULL,   -- NOMBRE de TLISTA_VALOR JORNADA
    p_grado           TEXT    DEFAULT NULL,   -- NOMBRE de TGRADO
    p_fk_tsede        BIGINT  DEFAULT NULL    -- acota, no autoriza (el gate sigue siendo el rol)
)
RETURNS TABLE (
    -- Primer registro de la corrida: sigue siendo la clave de fila del front
    -- y lo que espera /asistencias/export-all para el LEFT JOIN a la vista.
    pk_tasistencia        BIGINT,
    pks                   BIGINT[],           -- TODOS los registros de la corrida
    registros             INTEGER,            -- cardinality(pks)
    estudiante            TEXT,
    documento             VARCHAR,
    grupo                 VARCHAR,
    grado                 VARCHAR,            -- NOMBRE de TGRADO
    grado_valor           VARCHAR,            -- CODIGO de TGRADO ("2" -> la pantalla pinta "2 02")
    asignatura            VARCHAR,
    fk_tactividad         BIGINT,
    actividad             VARCHAR,
    es_formativa          BOOLEAN,
    fecha                 DATE,
    bloque                NUMERIC,            -- el primero de la corrida
    bloques               NUMERIC[],
    hora_inicio           TIMESTAMP,          -- inicio del primer bloque
    hora_fin              TIMESTAMP,          -- fin del ultimo
    -- Donde ocurrio lo que la fila reporta: los bloques de la corrida que
    -- llevan el estado ganador, y su franja. Con la corrida entera en el mismo
    -- estado son todos; si llego tarde solo al bloque 2 de cinco, es ese.
    bloques_estado        NUMERIC[],
    hora_inicio_estado    TIMESTAMP,
    hora_fin_estado       TIMESTAMP,
    tipo_asistencia_valor INTEGER,            -- el PEOR de la corrida
    tipo_asistencia       VARCHAR,
    observacion           VARCHAR,
    tiene_soporte         BOOLEAN,
    fk_soporte_archivo    BIGINT,
    soporte_nombre        VARCHAR,
    total_estudiantes     BIGINT,
    asistieron            BIGINT,
    tarde                 BIGINT,
    ausentes              BIGINT,
    total_count           BIGINT
)
LANGUAGE plpgsql STABLE AS $function$
DECLARE
    v_col TEXT;
    v_dir TEXT;
BEGIN
    v_col := CASE lower(coalesce(p_sort_by, ''))
        WHEN 'estudiante' THEN 'estudiante'
        WHEN 'documento'  THEN 'documento'
        WHEN 'fecha'      THEN 'fecha'
        WHEN 'tipo'       THEN 'tipo_asistencia_valor'
        WHEN 'grupo'      THEN 'grupo'
        WHEN 'asignatura' THEN 'asignatura'
        WHEN 'actividad'  THEN 'actividad'
        ELSE 'fecha'
    END;
    v_dir := CASE WHEN lower(coalesce(p_sort_dir, '')) = 'asc' THEN 'ASC' ELSE 'DESC' END;

    RETURN QUERY EXECUTE format($q$
        SELECT
            pk_tasistencia, pks, registros, estudiante, documento, grupo, grado, grado_valor, asignatura,
            fk_tactividad, actividad, es_formativa, fecha, bloque, bloques,
            hora_inicio, hora_fin, bloques_estado, hora_inicio_estado, hora_fin_estado,
            tipo_asistencia_valor, tipo_asistencia,
            observacion, tiene_soporte, fk_soporte_archivo, soporte_nombre,
            -- DISTINCT no existe en funciones de ventana: se cuenta la primera
            -- aparicion de cada matricula (rn_* = 1). Las cuatro son ventanas
            -- sobre el SET FILTRADO COMPLETO, no sobre la pagina.
            SUM((rn_mat = 1)::int) OVER ()::BIGINT  AS total_estudiantes,
            SUM((rn_pre = 1)::int) OVER ()::BIGINT  AS asistieron,
            SUM((rn_tar = 1)::int) OVER ()::BIGINT  AS tarde,
            SUM((rn_aus = 1)::int) OVER ()::BIGINT  AS ausentes,
            COUNT(*) OVER ()::BIGINT                AS total_count
        FROM (
            SELECT g.*,
                   row_number() OVER (PARTITION BY g.fk_tmatricula
                                          ORDER BY g.pk_tasistencia)          AS rn_mat,
                   -- Cada tarjeta cuenta estudiantes distintos con AL MENOS una
                   -- fila en ese estado, sobre el estado YA resuelto de la corrida.
                   CASE WHEN g.tipo_asistencia_valor = 1
                        THEN row_number() OVER (PARTITION BY g.fk_tmatricula,
                                                             (g.tipo_asistencia_valor = 1)
                                                    ORDER BY g.pk_tasistencia)
                        ELSE 0 END                                            AS rn_pre,
                   CASE WHEN g.tipo_asistencia_valor IN (5,6)
                        THEN row_number() OVER (PARTITION BY g.fk_tmatricula,
                                                             (g.tipo_asistencia_valor IN (5,6))
                                                    ORDER BY g.pk_tasistencia)
                        ELSE 0 END                                            AS rn_tar,
                   CASE WHEN g.tipo_asistencia_valor IN (2,3)
                        THEN row_number() OVER (PARTITION BY g.fk_tmatricula,
                                                             (g.tipo_asistencia_valor IN (2,3))
                                                    ORDER BY g.pk_tasistencia)
                        ELSE 0 END                                            AS rn_aus
              FROM (
                SELECT
                    (array_agg(b.pk_tasistencia ORDER BY b.bloque, b.pk_tasistencia))[1] AS pk_tasistencia,
                     array_agg(b.pk_tasistencia ORDER BY b.bloque, b.pk_tasistencia)     AS pks,
                     COUNT(*)::INTEGER                                                   AS registros,
                     b.fk_tmatricula, b.estudiante, b.documento, b.grupo, b.grado, b.grado_valor,
                     b.asignatura, b.fk_tactividad, b.actividad, b.es_formativa, b.fecha,
                     MIN(b.bloque)                                                       AS bloque,
                     array_remove(array_agg(b.bloque ORDER BY b.bloque), NULL)           AS bloques,
                     MIN(b.hora_inicio)                                                  AS hora_inicio,
                     MAX(b.hora_fin)                                                     AS hora_fin,
                     -- Estado de la corrida (fn_asistencia_tipo_prioridad: tarde gana).
                     (array_agg(b.tipo_valor  ORDER BY b.prioridad, b.bloque))[1]        AS tipo_asistencia_valor,
                     (array_agg(b.tipo_nombre ORDER BY b.prioridad, b.bloque))[1]        AS tipo_asistencia,
                     array_remove(array_agg(b.bloque ORDER BY b.bloque)
                                  FILTER (WHERE b.prioridad = b.prioridad_corrida), NULL)    AS bloques_estado,
                     MIN(b.hora_inicio) FILTER (WHERE b.prioridad = b.prioridad_corrida)     AS hora_inicio_estado,
                     MAX(b.hora_fin)    FILTER (WHERE b.prioridad = b.prioridad_corrida)     AS hora_fin_estado,
                     -- La observacion y el soporte que se muestran son los del
                     -- bloque que define el estado de la fila; el soporte se
                     -- ordena ademas por "tiene archivo" para no perder la
                     -- justificacion cuando vive en otro bloque de la corrida.
                     (array_remove(array_agg(b.observacion ORDER BY b.prioridad, b.bloque), NULL))[1] AS observacion,
                     bool_or(b.tiene_soporte)                                            AS tiene_soporte,
                     (array_agg(b.fk_soporte_archivo
                                ORDER BY (b.fk_soporte_archivo IS NULL), b.prioridad, b.bloque))[1]  AS fk_soporte_archivo,
                     (array_agg(b.soporte_nombre
                                ORDER BY (b.fk_soporte_archivo IS NULL), b.prioridad, b.bloque))[1]  AS soporte_nombre
                  FROM (
                   -- La prioridad ganadora de la corrida, para saber CUALES
                   -- bloques son los que la fila esta reportando.
                   SELECT b0.*,
                          MIN(b0.prioridad) OVER (PARTITION BY b0.fk_tmatricula, b0.fecha,
                                                               b0.fk_tasignatura, b0.fk_tactividad,
                                                               b0.isla)              AS prioridad_corrida
                     FROM (
                    SELECT
                        d.pk_tasistencia, d.fk_tmatricula, d.estudiante, d.documento,
                        d.grupo, d.grado, d.grado_valor,
                        d.fk_tasignatura, d.asignatura, d.fk_tactividad, d.actividad,
                        d.es_formativa, d.fecha, d.bloque, d.hora_inicio, d.hora_fin,
                        d.tipo_valor, d.tipo_nombre,
                        d.observacion, d.tiene_soporte, d.fk_soporte_archivo, d.soporte_nombre,
                        academico_test.fn_asistencia_tipo_prioridad(d.tipo_valor)        AS prioridad,
                        -- Islas de bloques CONSECUTIVOS: dentro de una corrida,
                        -- (bloque - su posicion) es constante. Una toma sin
                        -- bloque (manual suelta o formativa) no se agrupa con
                        -- nadie -- se le da una isla propia con su PK.
                        CASE WHEN d.bloque IS NULL THEN -d.pk_tasistencia
                             ELSE d.bloque - row_number() OVER (
                                      PARTITION BY d.fk_tmatricula, d.fecha,
                                                   d.fk_tasignatura, d.fk_tactividad
                                          ORDER BY d.bloque)
                        END                                                              AS isla
                      FROM academico_test.v_asistencia_detalle d
                     WHERE ($2  IS NULL OR d.fecha >= $2)
                       AND ($3  IS NULL OR d.fecha <= $3)
                       AND ($4  IS NULL OR d.fk_tgrupo = $4)
                       AND ($5  IS NULL OR d.fk_tasignatura = $5)
                       AND ($10 IS NULL OR d.fk_tactividad = $10)
                       AND ($11 IS NULL OR d.jornada = $11)
                       AND ($12 IS NULL OR d.grado   = $12)
                       AND ($13 IS NULL OR d.fk_tsede = $13)
                       -- La busqueda libre incluye la ACTIVIDAD: en preescolar
                       -- es lo que la pantalla muestra en esa columna, y buscar
                       -- por asignatura ahi no encuentra nada (viene NULL).
                       AND ($7 IS NULL OR (
                               d.estudiante  ILIKE '%%' || $7 || '%%' OR
                               d.documento   ILIKE '%%' || $7 || '%%' OR
                               d.grupo       ILIKE '%%' || $7 || '%%' OR
                               d.asignatura  ILIKE '%%' || $7 || '%%' OR
                               d.actividad   ILIKE '%%' || $7 || '%%' OR
                               d.tipo_nombre ILIKE '%%' || $7 || '%%'
                           ))
                       -- Alcance por rol. Se evalua al final y una sola vez por
                       -- grupo distinto (fn_asistencia_puede_ver es STABLE).
                       AND academico_test.fn_asistencia_puede_ver($1, d.fk_tgrupo)
                     ) b0
                  ) b
                 -- fk_tasignatura no sale a la pantalla pero agrupa: dos
                 -- asignaturas homonimas no tienen por que fusionarse.
                 GROUP BY b.fk_tmatricula, b.estudiante, b.documento, b.grupo,
                          b.grado, b.grado_valor,
                          b.fk_tasignatura, b.asignatura, b.fk_tactividad, b.actividad,
                          b.es_formativa, b.fecha, b.isla
              ) g
             -- El tipo filtra el estado de la FILA, no el de cada bloque: pedir
             -- "Llego tarde" devuelve la corrida entera marcada asi, no solo el
             -- bloque en el que llego tarde. Va antes que las ventanas (WHERE
             -- se evalua primero), asi que las tarjetas cuentan lo filtrado.
             WHERE ($6 IS NULL OR g.tipo_asistencia_valor = $6::INT)
        ) q
        ORDER BY %s %s, pk_tasistencia
        LIMIT NULLIF($9, 0)
       OFFSET COALESCE($8, 0) * COALESCE(NULLIF($9, 0), 0)
    $q$, v_col, v_dir)
    USING p_pk_usuario, p_fecha_desde, p_fecha_hasta, p_fk_tgrupo, p_fk_tasignatura,
          p_tipo_asistencia, NULLIF(TRIM(p_search), ''), p_page_index, p_page_size,
          p_fk_tactividad, NULLIF(TRIM(p_jornada), ''), NULLIF(TRIM(p_grado), ''),
          p_fk_tsede;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_asistencia_listar_seguimiento(
    BIGINT, DATE, DATE, BIGINT, BIGINT, NUMERIC, TEXT, INT, INT, TEXT, TEXT, BIGINT, TEXT, TEXT, BIGINT
) IS 'Pantalla Seguimiento: listado paginado sobre v_asistencia_detalle. UNA FILA POR CORRIDA DE BLOQUES: los bloques CONSECUTIVOS de la misma (matricula, fecha, asignatura/actividad) colapsan en una sola fila -- antes la misma asignatura dictada en 5 bloques salia 5 veces. La fila trae grado/grado_valor (antes solo salia el grupo, y la pantalla pinta el curso junto al grupo), pks (todos los registros de la corrida, para editarla entera con fn_asistencia_editar_bulk), registros, bloques, y hora_inicio/hora_fin del bloque formado; su tipo_asistencia sale de fn_asistencia_tipo_prioridad, donde la tardanza manda sobre la inasistencia: llegar tarde a un bloque marca toda la corrida como Llego tarde aunque en otro bloque figure ausente. bloques_estado + hora_inicio_estado/hora_fin_estado dicen DONDE ocurrio eso: los bloques que llevan el estado ganador (todos, si la corrida entera comparte estado) -- es lo que la pantalla pinta bajo el estado ("Bloque 2 (8:30 - 10:00)"). Una toma sin bloque (manual suelta) no se agrupa con nadie. Filtros INDEPENDIENTES y combinables en AND: rango de fecha / SEDE / JORNADA / GRADO / grupo / asignatura / ACTIVIDAD / tipo (VALOR, comparado contra el estado YA resuelto de la fila: pedir "Llego tarde" trae la corrida entera, no solo el bloque tarde) / busqueda libre (estudiante, documento, grupo, asignatura, actividad, estado); p_jornada y p_grado comparan contra el NOMBRE (TLISTA_VALOR.NOMBRE / TGRADO.NOMBRE), los mismos valores que devuelve fn_asistencia_calendario. p_fk_tsede ACOTA, no autoriza: el alcance por rol sigue siendo fn_asistencia_puede_ver. total_estudiantes, asistieron (tipo 1), tarde (5/6) y ausentes (2/3) cuentan ESTUDIANTES DISTINTOS del set filtrado completo y NO suman entre si (un estudiante puede asistir a una sesion y faltar a otra); total_count cuenta FILAS AGRUPADAS, para que la paginacion del front cuadre. Orden por estudiante|documento|fecha|tipo|grupo|asignatura|actividad.';


-- ---------------------------------------------------------------------------
-- 3. Editar la corrida completa.
--    Se delega en fn_asistencia_editar registro por registro: asi los gates
--    (capability + scope + periodo cerrado + validacion del soporte) siguen
--    viviendo en un solo sitio. Va todo en la misma transaccion, asi que si
--    un registro falla no queda la corrida a medio editar.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_editar_bulk(
    p_pk_usuario_solicitante BIGINT,
    p_pks                    BIGINT[],
    p_tipo_asistencia_valor  NUMERIC   DEFAULT NULL,
    p_observacion            VARCHAR   DEFAULT NULL,
    p_fk_soporte_archivo     BIGINT    DEFAULT NULL,
    p_limpiar_archivo        BOOLEAN   DEFAULT FALSE,
    p_limpiar_observacion    BOOLEAN   DEFAULT FALSE
)
RETURNS BIGINT
LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    v_pk    BIGINT;
    v_total BIGINT := 0;
BEGIN
    IF p_pks IS NULL OR cardinality(p_pks) = 0 THEN
        RAISE EXCEPTION 'no se recibio ningun registro de asistencia para editar'
            USING ERRCODE = '22023';
    END IF;

    FOREACH v_pk IN ARRAY p_pks LOOP
        PERFORM academico_test.fn_asistencia_editar(
            p_pk_usuario_solicitante => p_pk_usuario_solicitante,
            p_pk_tasistencia         => v_pk,
            p_tipo_asistencia_valor  => p_tipo_asistencia_valor,
            p_observacion            => p_observacion,
            p_fk_soporte_archivo     => p_fk_soporte_archivo,
            p_limpiar_archivo        => p_limpiar_archivo,
            p_limpiar_observacion    => p_limpiar_observacion);
        v_total := v_total + 1;
    END LOOP;

    RETURN v_total;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_editar_bulk(
    BIGINT, BIGINT[], NUMERIC, VARCHAR, BIGINT, BOOLEAN, BOOLEAN
) IS 'Aplica la MISMA edicion (estado, observacion, soporte) a varios registros de TASISTENCIA: los pks de una fila agrupada de Seguimiento (columna pks de fn_asistencia_listar_seguimiento). Delega en fn_asistencia_editar uno por uno, de modo que cada registro pasa por su gate (capability EDITAR + scope del grupo + periodo academico cerrado + soporte de la sede correcta) y todo corre en una sola transaccion: si uno falla, no queda la corrida a medio editar. Devuelve cuantos registros toco. Rechaza (22023) el arreglo vacio o NULL.';


-- ---------------------------------------------------------------------------
-- 4. Catalogo HTTP.
--    4a. SEDE en el listado y en el export -- se parchea el texto almacenado
--        en vez de reescribir la fila, para no duplicar el SQL del que
--        V221/V228 son duenas; el guard NOT LIKE hace el UPDATE idempotente.
--        /asistencias/reporte (V290) no la necesita: ahi GRUPO es obligatorio
--        y el grupo ya determina la sede.
-- ---------------------------------------------------------------------------
UPDATE public.query
   SET query = replace(
           query,
           '    p_search          => CAST(:BODY.FILTERS.SEARCH AS TEXT),',
           '    p_search          => CAST(:BODY.FILTERS.SEARCH AS TEXT),' || chr(10) ||
           '    p_fk_tsede        => CAST(:BODY.FILTERS.SEDE AS BIGINT),'),
       param_types = param_types || '{"BODY.FILTERS.SEDE": "BIGINT"}'::JSONB
 WHERE uuid IN ('asis-seguimiento', 'eval-col-asistencias-seguimiento-export-all-001')
   AND query LIKE '%p_search          => CAST(:BODY.FILTERS.SEARCH AS TEXT),%'
   AND query NOT LIKE '%p_fk_tsede%';

-- 4a-bis. El export (V228) agregaba grado/grado_valor con un LEFT JOIN a la
--     vista porque la funcion no los devolvia; ahora si, y repetirlos daria dos
--     columnas con el mismo nombre en el payload del reporte. El JOIN se queda:
--     jornada sigue viniendo solo de ahi.
UPDATE public.query
   SET query = replace(query, 'SELECT t.*, d.grado, d.grado_valor, d.jornada', 'SELECT t.*, d.jornada')
 WHERE uuid = 'eval-col-asistencias-seguimiento-export-all-001'
   AND query LIKE '%SELECT t.*, d.grado, d.grado_valor, d.jornada%';

-- 4b. El endpoint de la edicion masiva. POST y no PATCH /asistencias/:ID para
--     que el gateway no tenga que desempatar 'editar-masivo' contra un :ID.
INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id,
                          path_template, execution_mode, http_method, param_types, detail)
SELECT
    'asis-editar-masivo',
    $q$SELECT academico_test.fn_asistencia_editar_bulk(
    p_pk_usuario_solicitante => public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    p_pks                    => CAST(:BODY.IDS AS BIGINT[]),
    p_tipo_asistencia_valor  => CAST(:BODY.TIPO_ASISTENCIA AS NUMERIC),
    p_observacion            => CAST(:BODY.OBSERVACION AS VARCHAR),
    p_fk_soporte_archivo     => CAST(:BODY.SOPORTE_ARCHIVO AS BIGINT),
    p_limpiar_archivo        => COALESCE(CAST(:BODY.LIMPIAR_ARCHIVO AS BOOLEAN), FALSE),
    p_limpiar_observacion    => COALESCE(CAST(:BODY.LIMPIAR_OBSERVACION AS BOOLEAN), FALSE)
) AS registros_afectados$q$,
    'postgres', false, false, m.id_microservice,
    '/asistencias/editar-masivo', 'SELECT', 'POST',
    '{
       "BODY.IDS":                  "BIGINT[]",
       "BODY.TIPO_ASISTENCIA":      "NUMERIC",
       "BODY.OBSERVACION":          "VARCHAR",
       "BODY.SOPORTE_ARCHIVO":      "BIGINT",
       "BODY.LIMPIAR_ARCHIVO":      "BOOLEAN",
       "BODY.LIMPIAR_OBSERVACION":  "BOOLEAN"
     }'::jsonb,
    'V438 -- edita de una vez todos los registros de una fila agrupada de Seguimiento (IDS = la columna pks que devuelve fn_asistencia_listar_seguimiento para la corrida de bloques). Mismos campos y mismas reglas que PATCH /asistencias/:ID: campos ausentes = no se tocan, LIMPIAR_ARCHIVO / LIMPIAR_OBSERVACION = true los ponen en NULL, TIPO_ASISTENCIA es el VALOR del catalogo (1,2,3,5,6). Cada registro pasa por su propio gate y todo corre en una transaccion. Devuelve cuantos registros toco. RECHAZA (22023) si el TPERIODO_ACADEMICO del grupo esta Cerrado, o si IDS viene vacio.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (uuid) DO UPDATE
   SET query = EXCLUDED.query, param_types = EXCLUDED.param_types,
       path_template = EXCLUDED.path_template, http_method = EXCLUDED.http_method,
       execution_mode = EXCLUDED.execution_mode, microservice_id = EXCLUDED.microservice_id,
       detail = EXCLUDED.detail;

-- "Quien puede editar un registro puede editar la corrida": se copian los
-- roles de 'asis-editar' tal cual, nunca por nombre de rol.
INSERT INTO public.role_query (query_id, role_id)
SELECT masivo.id_query, rq.role_id
  FROM public.query masivo
  JOIN public.query editar   ON editar.uuid = 'asis-editar'
  JOIN public.role_query rq  ON rq.query_id = editar.id_query
 WHERE masivo.uuid = 'asis-editar-masivo'
ON CONFLICT (query_id, role_id) DO NOTHING;

-- 4c. Formato de los parametros caller-controlled (V70/V83). Sin fila aqui el
--     parametro pasa sin validar.
INSERT INTO public.query_param_constraint
       (query_id, param_key, only_positive, allow_decimals, max_digits,
        numeric_text, min_length, max_length, min_value, max_value)
SELECT q.id_query, c.param_key, c.only_positive, c.allow_decimals, c.max_digits,
       c.numeric_text, c.min_length, c.max_length, c.min_value, c.max_value
  FROM (VALUES
    ('asis-seguimiento',    'BODY.FILTERS.SEDE',        TRUE,  FALSE, NULL::integer, NULL::boolean, NULL::integer, NULL::integer, NULL::numeric, NULL::numeric),
    ('eval-col-asistencias-seguimiento-export-all-001',
                            'BODY.FILTERS.SEDE',        TRUE,  FALSE, NULL,   NULL,   NULL,   NULL,   NULL,   NULL),
    ('asis-editar-masivo',  'BODY.TIPO_ASISTENCIA',     TRUE,  FALSE, 1,      NULL,   NULL,   NULL,   1::numeric, 6::numeric),
    ('asis-editar-masivo',  'BODY.SOPORTE_ARCHIVO',     TRUE,  FALSE, NULL,   NULL,   NULL,   NULL,   NULL,   NULL),
    ('asis-editar-masivo',  'BODY.OBSERVACION',         NULL,  NULL,  NULL,   FALSE,  NULL,   4000,   NULL,   NULL)
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
