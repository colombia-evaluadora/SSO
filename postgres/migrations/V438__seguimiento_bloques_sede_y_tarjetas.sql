-- V438 -- Seguimiento: una fila por corrida de bloques consecutivos, filtro por
-- sede y tarjetas sobre el set filtrado completo; fn_asistencia_editar_bulk
-- para editar la corrida entera.
-- Tras aplicar, reiniciar query-service-eval-col (cachea el catalogo).
-- Depende de: V136 (alcance), V138 (fn_asistencia_editar), V140 (franja),
-- V221/V228 (catalogo HTTP), V496.18 (solicitud pendiente, Regla 75).

SET search_path TO public;


-- ---------------------------------------------------------------------------
-- 1. Que estado manda en una corrida de bloques mezclada.
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
-- DROP de ambas firmas: CREATE OR REPLACE no puede cambiar el RETURNS TABLE.
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
    -- Primer registro de la corrida: la clave de fila del front.
    pk_tasistencia        BIGINT,
    pks                   BIGINT[],           -- TODOS los registros de la corrida
    registros             INTEGER,            -- cardinality(pks)
    estudiante            TEXT,
    documento             VARCHAR,
    grupo                 VARCHAR,
    grado                 VARCHAR,            -- NOMBRE de TGRADO
    grado_valor           VARCHAR,            -- CODIGO de TGRADO ("2" -> la pantalla pinta "2 02")
    jornada               VARCHAR,            -- NOMBRE de TLISTA_VALOR JORNADA del grupo
    asignatura            VARCHAR,
    fk_tactividad         BIGINT,
    actividad             VARCHAR,
    es_formativa          BOOLEAN,
    fecha                 DATE,
    bloque                NUMERIC,            -- el primero de la corrida
    bloques               NUMERIC[],
    hora_inicio           TIMESTAMP,          -- inicio del primer bloque
    hora_fin              TIMESTAMP,          -- fin del ultimo
    -- Bloques que llevan el estado ganador de la corrida, y su franja.
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
    total_count           BIGINT,
    cambio_pendiente      BOOLEAN             -- Regla 75: algún registro de la corrida espera aprobación
)
-- jit off: el estimado inflado dispara JIT y compilar costaba como la consulta.
LANGUAGE plpgsql STABLE SET jit = off AS $function$
DECLARE
    v_col  TEXT;
    v_dir  TEXT;
    v_expr TEXT;   -- la misma columna, sobre g y lo que haga falta unirle
    v_join TEXT;
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
    -- Se pagina antes de poner los textos: solo se une lo que pide el orden.
    v_expr := CASE v_col
        WHEN 'estudiante' THEN 'e.estudiante'
        WHEN 'documento'  THEN 'e.documento'
        WHEN 'grupo'      THEN 'e.grupo'
        WHEN 'asignatura' THEN 'asig.NOMBRE'
        WHEN 'actividad'  THEN 'act.TITULO'
        ELSE 'g.' || v_col
    END;
    v_join := CASE
        WHEN v_col IN ('estudiante', 'documento', 'grupo')
            THEN 'JOIN est e ON e.fk_tmatricula = g.fk_tmatricula'
        WHEN v_col = 'asignatura'
            THEN 'LEFT JOIN academico_test.TASIGNATURA asig ON asig.PK_TASIGNATURA = g.fk_tasignatura'
        WHEN v_col = 'actividad'
            THEN 'LEFT JOIN academico_test.TACTIVIDAD act ON act.PK_TACTIVIDAD = g.fk_tactividad'
        ELSE ''
    END;

    RETURN QUERY EXECUTE format($q$
      -- Matriculas del filtro; la busqueda por estudiante/grupo se evalua aqui,
      -- una vez por matricula y no por registro.
      WITH mat AS MATERIALIZED (
        SELECT m.PK_TMATRICULA AS pk_tmatricula, m.FK_TGRUPO AS fk_tgrupo,
               pa.HORA_INICIO AS jornada_inicio, pa.HORA_FIN AS jornada_fin,
               ($7 IS NOT NULL AND (
                   NULLIF(TRIM(regexp_replace(
                       concat_ws(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
                                      u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO),
                       '\s+', ' ', 'g')), '')  ILIKE '%%' || $7 || '%%' OR
                   u.IDENTIFICACION ILIKE '%%' || $7 || '%%' OR
                   gr.NOMBRE        ILIKE '%%' || $7 || '%%'))         AS coincide
          FROM academico_test.TPERIODO_ACADEMICO pa
          JOIN academico_test.TGRADO g       ON g.FK_TPERIODO_ACADEMICO = pa.PK_TPERIODO_ACADEMICO
          JOIN academico_test.TGRUPO gr      ON gr.FK_TGRADO = g.PK_TGRADO
          JOIN academico_test.TMATRICULA m   ON m.FK_TGRUPO = gr.PK_TGRUPO
          JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
          JOIN academico_test.TUSUARIO u     ON u.PK_TUSUARIO = es.FK_TUSUARIO
          LEFT JOIN academico_test.TLISTA_VALOR jor ON jor.PK_LISTA_VALOR = gr.FK_TLV_JORNADA
                                                   AND jor.CATEGORIA = 'JORNADA'
         WHERE ($4  IS NULL OR gr.PK_TGRUPO = $4)
           AND ($11 IS NULL OR jor.NOMBRE = $11)
           AND ($12 IS NULL OR g.NOMBRE = $12)
           AND ($13 IS NULL OR pa.FK_TSEDE = $13)
      ),
      -- Entra por el indice (matricula, fecha). Solo ids y numeros hasta
      -- paginar: los textos se unen al final, una vez por fila.
      base AS MATERIALIZED (
        SELECT a.PK_TASISTENCIA AS pk_tasistencia, a.FK_TMATRICULA AS fk_tmatricula,
               mt.fk_tgrupo,
               a.FK_TASIGNATURA AS fk_tasignatura, a.FK_TACTIVIDAD AS fk_tactividad,
               a.FECHA AS fecha, a.BLOQUE AS bloque,
               CASE lv.VALOR WHEN '1' THEN 1 WHEN '2' THEN 2 WHEN '3' THEN 3
                             WHEN '5' THEN 5 WHEN '6' THEN 6 END       AS tipo_valor,
               a.FK_TLV_TIPO_ASISTENCIA AS fk_tipo,
               (a.OBSERVACION IS NOT NULL) AS tiene_observacion,
               a.FK_SOPORTE_ARCHIVO AS fk_soporte_archivo,
               mt.jornada_inicio, mt.jornada_fin
          FROM mat mt
          JOIN academico_test.TASISTENCIA a  ON a.FK_TMATRICULA = mt.pk_tmatricula
          JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = a.FK_TLV_TIPO_ASISTENCIA
          LEFT JOIN academico_test.TASIGNATURA asig ON asig.PK_TASIGNATURA = a.FK_TASIGNATURA
          LEFT JOIN academico_test.TACTIVIDAD  act  ON act.PK_TACTIVIDAD  = a.FK_TACTIVIDAD
         WHERE a.ACTIVE = TRUE
           AND ($2  IS NULL OR a.FECHA >= $2)
           AND ($3  IS NULL OR a.FECHA <= $3)
           AND ($5  IS NULL OR a.FK_TASIGNATURA = $5)
           AND ($10 IS NULL OR a.FK_TACTIVIDAD = $10)
           -- Incluye ACTIVIDAD: en preescolar la asignatura viene NULL.
           AND ($7 IS NULL OR mt.coincide OR
                asig.NOMBRE ILIKE '%%' || $7 || '%%' OR
                act.TITULO  ILIKE '%%' || $7 || '%%' OR
                lv.NOMBRE   ILIKE '%%' || $7 || '%%')
      ),
      -- Alcance una vez por (grupo, asignatura). MATERIALIZED: si no, el planner
      -- empuja el filtro bajo el DISTINCT y lo evalua por registro.
      pares AS MATERIALIZED (
        SELECT DISTINCT fk_tgrupo, fk_tasignatura FROM base
      ),
      visibles AS (
        SELECT x.fk_tgrupo, COALESCE(x.fk_tasignatura, 0) AS fk_tasignatura
          FROM pares x
         WHERE academico_test.fn_asistencia_puede_ver_asignatura($1, x.fk_tgrupo, x.fk_tasignatura)
      ),
      -- Horario por (grupo, asignatura, bloque, dia), una vez y no por registro.
      hor AS (
        SELECT DISTINCT ON (th.FK_TGRUPO, th.FK_TASIGNATURA, th.NUMERO_BLOQUE, dia.VALOR)
               th.FK_TGRUPO AS fk_tgrupo, th.FK_TASIGNATURA AS fk_tasignatura,
               th.NUMERO_BLOQUE AS bloque, dia.VALOR AS dia,
               th.HORA_INICIO AS hora_inicio, th.HORA_FIN AS hora_fin
          FROM academico_test.THORARIO th
          JOIN academico_test.TLISTA_VALOR dia ON dia.PK_LISTA_VALOR = th.FK_TLV_DIA_SEMANA
                                              AND dia.CATEGORIA = 'DIA_SEMANA'
         WHERE th.ACTIVE = TRUE
           AND th.FK_TGRUPO IN (SELECT fk_tgrupo FROM pares)
      ),
      d AS (
        SELECT b.*, franja.hora_inicio, franja.hora_fin
          FROM base b
          LEFT JOIN hor h ON h.fk_tgrupo = b.fk_tgrupo
                         AND h.fk_tasignatura = b.fk_tasignatura
                         AND h.bloque = b.bloque
                         AND h.dia = (EXTRACT(DOW FROM b.fecha)::INT + 1)::TEXT
          CROSS JOIN LATERAL academico_test.fn_asistencia_franja_bloque(
              b.fecha, h.hora_inicio, h.hora_fin, b.jornada_inicio, b.jornada_fin) franja
         WHERE (b.fk_tgrupo, COALESCE(b.fk_tasignatura, 0)) IN (SELECT fk_tgrupo, fk_tasignatura FROM visibles)
           -- Con filtro de tipo solo entran las sesiones que lo contienen: el
           -- estado de la corrida es el de alguno de sus registros.
           AND ($6 IS NULL OR (b.fk_tmatricula, b.fecha, COALESCE(b.fk_tasignatura, 0),
                               COALESCE(b.fk_tactividad, 0)) IN (
                   SELECT x.fk_tmatricula, x.fecha, COALESCE(x.fk_tasignatura, 0),
                          COALESCE(x.fk_tactividad, 0)
                     FROM base x WHERE x.tipo_valor = $6::INT))
      ),
      -- Una fila por corrida. Un solo orden (bloque, pk) en todos los agregados.
      g AS MATERIALIZED (
        SELECT
            (array_agg(b.pk_tasistencia ORDER BY b.bloque, b.pk_tasistencia))[1] AS pk_tasistencia,
             array_agg(b.pk_tasistencia ORDER BY b.bloque, b.pk_tasistencia)     AS pks,
             COUNT(*)::INTEGER                                                   AS registros,
             b.fk_tmatricula, b.fk_tasignatura, b.fk_tactividad, b.fecha,
             MIN(b.bloque)                                                       AS bloque,
             array_remove(array_agg(b.bloque ORDER BY b.bloque, b.pk_tasistencia), NULL) AS bloques,
             MIN(b.hora_inicio)                                                  AS hora_inicio,
             MAX(b.hora_fin)                                                     AS hora_fin,
             MIN(b.tipo_corrida)                                                 AS tipo_asistencia_valor,
             MIN(b.fk_tipo_corrida)                                              AS fk_tipo,
             array_remove(array_agg(b.bloque ORDER BY b.bloque, b.pk_tasistencia)
                          FILTER (WHERE b.prioridad = b.prioridad_corrida), NULL)    AS bloques_estado,
             MIN(b.hora_inicio) FILTER (WHERE b.prioridad = b.prioridad_corrida)     AS hora_inicio_estado,
             MAX(b.hora_fin)    FILTER (WHERE b.prioridad = b.prioridad_corrida)     AS hora_fin_estado,
             MIN(b.observacion_pk)                                               AS observacion_pk,
             bool_or(b.fk_soporte_archivo IS NOT NULL)                           AS tiene_soporte,
             MIN(b.soporte_corrida)                                              AS fk_soporte_archivo
          FROM (
           -- Ganadores por prioridad (tarde gana): estado, primera observacion
           -- y primer soporte, aunque vivan en otro bloque de la corrida.
           SELECT b0.*,
                  first_value(b0.prioridad)  OVER wc                             AS prioridad_corrida,
                  first_value(b0.tipo_valor) OVER wc                             AS tipo_corrida,
                  first_value(b0.fk_tipo)    OVER wc                             AS fk_tipo_corrida,
                  (array_agg(b0.pk_tasistencia) FILTER (WHERE b0.tiene_observacion) OVER wc)[1]
                                                                                 AS observacion_pk,
                  (array_agg(b0.fk_soporte_archivo) FILTER (WHERE b0.fk_soporte_archivo IS NOT NULL) OVER wc)[1]
                                                                                 AS soporte_corrida
             FROM (
            SELECT d.*,
                   academico_test.fn_asistencia_tipo_prioridad(d.tipo_valor)        AS prioridad,
                   -- Isla: (bloque - posicion) es constante en una corrida;
                   -- sin bloque, isla propia.
                   CASE WHEN d.bloque IS NULL THEN -d.pk_tasistencia
                        ELSE d.bloque - row_number() OVER (
                                 PARTITION BY d.fk_tmatricula, d.fecha,
                                              d.fk_tasignatura, d.fk_tactividad
                                     ORDER BY d.bloque)
                   END                                                              AS isla
              FROM d
             ) b0
           WINDOW wc AS (PARTITION BY b0.fk_tmatricula, b0.fecha, b0.fk_tasignatura,
                                      b0.fk_tactividad, b0.isla
                             ORDER BY b0.prioridad, b0.bloque, b0.pk_tasistencia
                             ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)
          ) b
         GROUP BY b.fk_tmatricula, b.fecha, b.fk_tasignatura, b.fk_tactividad, b.isla
         -- El tipo filtra el estado de la corrida, antes de las tarjetas.
        HAVING ($6 IS NULL OR MIN(b.tipo_corrida) = $6::INT)
      ),
      -- Tarjetas: estudiantes distintos sobre el set filtrado completo.
      tot AS (
        SELECT COUNT(DISTINCT fk_tmatricula)                                                AS total_estudiantes,
               COUNT(DISTINCT fk_tmatricula) FILTER (WHERE tipo_asistencia_valor = 1)       AS asistieron,
               COUNT(DISTINCT fk_tmatricula) FILTER (WHERE tipo_asistencia_valor IN (5,6))  AS tarde,
               COUNT(DISTINCT fk_tmatricula) FILTER (WHERE tipo_asistencia_valor IN (2,3))  AS ausentes,
               COUNT(*)                                                                     AS total_count
          FROM g
      ),
      -- Para ordenar por estudiante/documento/grupo: una vez por matricula.
      est AS MATERIALIZED (
        SELECT m.PK_TMATRICULA AS fk_tmatricula,
               NULLIF(TRIM(regexp_replace(
                   concat_ws(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
                                  u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO),
                   '\s+', ' ', 'g')), '')                         AS estudiante,
               u.IDENTIFICACION AS documento, gr.NOMBRE AS grupo,
               gd.NOMBRE AS grado, gd.CODIGO AS grado_valor, jor.NOMBRE AS jornada
          FROM academico_test.TMATRICULA m
          JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
          JOIN academico_test.TUSUARIO u     ON u.PK_TUSUARIO = es.FK_TUSUARIO
          JOIN academico_test.TGRUPO gr      ON gr.PK_TGRUPO = m.FK_TGRUPO
          JOIN academico_test.TGRADO gd      ON gd.PK_TGRADO = gr.FK_TGRADO
          LEFT JOIN academico_test.TLISTA_VALOR jor ON jor.PK_LISTA_VALOR = gr.FK_TLV_JORNADA
                                                   AND jor.CATEGORIA = 'JORNADA'
         WHERE m.PK_TMATRICULA IN (SELECT fk_tmatricula FROM g)
      ),
      sel AS (
        SELECT g.* FROM g %3$s
         ORDER BY %4$s %2$s, g.pk_tasistencia
         LIMIT NULLIF($9, 0)
        OFFSET COALESCE($8, 0) * COALESCE(NULLIF($9, 0), 0)
      )
      -- Textos, observacion, soporte y solicitud pendiente solo para la pagina.
      SELECT p.pk_tasistencia, p.pks, p.registros,
             NULLIF(TRIM(regexp_replace(
                 concat_ws(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
                                u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO),
                 '\s+', ' ', 'g')), '')                              AS estudiante,
             u.IDENTIFICACION::VARCHAR AS documento, gr.NOMBRE::VARCHAR AS grupo,
             gd.NOMBRE::VARCHAR AS grado, gd.CODIGO::VARCHAR AS grado_valor,
             jor.NOMBRE::VARCHAR AS jornada, asig.NOMBRE::VARCHAR AS asignatura,
             p.fk_tactividad, act.TITULO::VARCHAR AS actividad,
             (p.fk_tactividad IS NOT NULL) AS es_formativa, p.fecha, p.bloque, p.bloques,
             p.hora_inicio, p.hora_fin, p.bloques_estado, p.hora_inicio_estado, p.hora_fin_estado,
             p.tipo_asistencia_valor, lvt.NOMBRE::VARCHAR AS tipo_asistencia,
             obs.OBSERVACION::VARCHAR AS observacion,
             p.tiene_soporte, p.fk_soporte_archivo, arch.NOMBRE::VARCHAR AS soporte_nombre,
             t.total_estudiantes, t.asistieron, t.tarde, t.ausentes, t.total_count,
             EXISTS (SELECT 1 FROM unnest(p.pks) x
                      WHERE academico_test.fn_asistencia_solicitud_pendiente(x) IS NOT NULL) AS cambio_pendiente
        FROM sel p
        CROSS JOIN tot t
        JOIN academico_test.TMATRICULA m   ON m.PK_TMATRICULA = p.fk_tmatricula
        JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
        JOIN academico_test.TUSUARIO u     ON u.PK_TUSUARIO = es.FK_TUSUARIO
        JOIN academico_test.TGRUPO gr      ON gr.PK_TGRUPO = m.FK_TGRUPO
        JOIN academico_test.TGRADO gd      ON gd.PK_TGRADO = gr.FK_TGRADO
        JOIN academico_test.TLISTA_VALOR lvt ON lvt.PK_LISTA_VALOR = p.fk_tipo
        LEFT JOIN academico_test.TLISTA_VALOR jor ON jor.PK_LISTA_VALOR = gr.FK_TLV_JORNADA
                                                 AND jor.CATEGORIA = 'JORNADA'
        LEFT JOIN academico_test.TASIGNATURA asig ON asig.PK_TASIGNATURA = p.fk_tasignatura
        LEFT JOIN academico_test.TACTIVIDAD  act  ON act.PK_TACTIVIDAD  = p.fk_tactividad
        LEFT JOIN academico_test.TASISTENCIA obs  ON obs.PK_TASISTENCIA = p.observacion_pk
        LEFT JOIN academico_test.TARCHIVO arch    ON arch.PK_TARCHIVO = p.fk_soporte_archivo
       ORDER BY %1$s %2$s, pk_tasistencia
    $q$, v_col, v_dir, v_join, v_expr)
    USING p_pk_usuario, p_fecha_desde, p_fecha_hasta, p_fk_tgrupo, p_fk_tasignatura,
          p_tipo_asistencia, NULLIF(TRIM(p_search), ''), p_page_index, p_page_size,
          p_fk_tactividad, NULLIF(TRIM(p_jornada), ''), NULLIF(TRIM(p_grado), ''),
          p_fk_tsede;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_asistencia_listar_seguimiento(
    BIGINT, DATE, DATE, BIGINT, BIGINT, NUMERIC, TEXT, INT, INT, TEXT, TEXT, BIGINT, TEXT, TEXT, BIGINT
) IS 'Pantalla Seguimiento: listado paginado directo sobre TASISTENCIA (mismas columnas y reglas que v_asistencia_detalle; entra por sede/grupo -> matriculas, y el alcance por rol se evalua una vez por grupo+asignatura). UNA FILA POR CORRIDA DE BLOQUES: los bloques CONSECUTIVOS de la misma (matricula, fecha, asignatura/actividad) colapsan en una sola fila -- antes la misma asignatura dictada en 5 bloques salia 5 veces. La fila trae grado/grado_valor (antes solo salia el grupo, y la pantalla pinta el curso junto al grupo) y jornada (NOMBRE, la que exporta /asistencias/export-all), pks (todos los registros de la corrida, para editarla entera con fn_asistencia_editar_bulk), registros, bloques, y hora_inicio/hora_fin del bloque formado; su tipo_asistencia sale de fn_asistencia_tipo_prioridad, donde la tardanza manda sobre la inasistencia: llegar tarde a un bloque marca toda la corrida como Llego tarde aunque en otro bloque figure ausente. bloques_estado + hora_inicio_estado/hora_fin_estado dicen DONDE ocurrio eso: los bloques que llevan el estado ganador (todos, si la corrida entera comparte estado) -- es lo que la pantalla pinta bajo el estado ("Bloque 2 (8:30 - 10:00)"). Una toma sin bloque (manual suelta) no se agrupa con nadie. Filtros INDEPENDIENTES y combinables en AND: rango de fecha / SEDE / JORNADA / GRADO / grupo / asignatura / ACTIVIDAD / tipo (VALOR, comparado contra el estado YA resuelto de la fila: pedir "Llego tarde" trae la corrida entera, no solo el bloque tarde) / busqueda libre (estudiante, documento, grupo, asignatura, actividad, estado); p_jornada y p_grado comparan contra el NOMBRE (TLISTA_VALOR.NOMBRE / TGRADO.NOMBRE), los mismos valores que devuelve fn_asistencia_calendario. p_fk_tsede ACOTA, no autoriza: el alcance por rol sigue siendo fn_asistencia_puede_ver. total_estudiantes, asistieron (tipo 1), tarde (5/6) y ausentes (2/3) cuentan ESTUDIANTES DISTINTOS del set filtrado completo y NO suman entre si (un estudiante puede asistir a una sesion y faltar a otra); total_count cuenta FILAS AGRUPADAS, para que la paginacion del front cuadre. cambio_pendiente (Regla 75): algun registro de la corrida tiene una correccion esperando al Coordinador; se calcula solo para la pagina. Orden por estudiante|documento|fecha|tipo|grupo|asignatura|actividad.';


-- ---------------------------------------------------------------------------
-- 3. Editar la corrida completa: fn_asistencia_editar por registro (un solo
--    sitio para los gates), todo en una transaccion.
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
) IS 'Aplica la MISMA edicion (estado, observacion, soporte) a varios registros de TASISTENCIA: los pks de una fila agrupada de Seguimiento (columna pks de fn_asistencia_listar_seguimiento). Delega en fn_asistencia_editar uno por uno, de modo que cada registro pasa por su gate (capability EDITAR + scope del grupo + periodo academico cerrado + soporte de la sede correcta) y por la Regla 75 (en periodo no calificable abre la solicitud en vez de editar), y todo corre en una sola transaccion: si uno falla, no queda la corrida a medio editar. Devuelve cuantos registros toco. Rechaza (22023) el arreglo vacio o NULL.';


-- ---------------------------------------------------------------------------
-- 4. Catalogo HTTP.
--    4a. SEDE en el listado (la fila es de V221); idempotente por el NOT LIKE.
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

-- 4b. Edicion masiva. POST para no chocar con PATCH /asistencias/:ID. Nace con
--     el envoltorio de solicitudes de V496.21: re-aplicar esto solo no lo pierde.
INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id,
                          path_template, execution_mode, http_method, param_types, detail)
SELECT
    'asis-editar-masivo',
    $q$WITH w AS MATERIALIZED (SELECT academico_test.fn_asistencia_editar_bulk(
    p_pk_usuario_solicitante => public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    p_pks                    => CAST(:BODY.IDS AS BIGINT[]),
    p_tipo_asistencia_valor  => CAST(:BODY.TIPO_ASISTENCIA AS NUMERIC),
    p_observacion            => CAST(:BODY.OBSERVACION AS VARCHAR),
    p_fk_soporte_archivo     => CAST(:BODY.SOPORTE_ARCHIVO AS BIGINT),
    p_limpiar_archivo        => COALESCE(CAST(:BODY.LIMPIAR_ARCHIVO AS BOOLEAN), FALSE),
    p_limpiar_observacion    => COALESCE(CAST(:BODY.LIMPIAR_OBSERVACION AS BOOLEAN), FALSE)
) AS registros_afectados)
SELECT w.*, academico_test.fn_solicitud_aprobacion_creadas() AS solicitudes_pendientes FROM w;$q$,
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
    'V438 -- edita de una vez todos los registros de una fila agrupada de Seguimiento (IDS = la columna pks que devuelve fn_asistencia_listar_seguimiento para la corrida de bloques). Mismos campos y mismas reglas que PATCH /asistencias/:ID: campos ausentes = no se tocan, LIMPIAR_ARCHIVO / LIMPIAR_OBSERVACION = true los ponen en NULL, TIPO_ASISTENCIA es el VALOR del catalogo (1,2,3,5,6). Cada registro pasa por su propio gate y todo corre en una transaccion. Devuelve cuantos registros toco. RECHAZA (22023) si el TPERIODO_ACADEMICO del grupo esta Cerrado, o si IDS viene vacio. Si el cambio exige aprobación del Coordinador (Reglas 55, 69, 75) no se aplica todavía: solicitudes_pendientes trae el PK de la solicitud abierta (vacío = se aplicó).'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (uuid) DO UPDATE
   SET query = EXCLUDED.query, param_types = EXCLUDED.param_types,
       path_template = EXCLUDED.path_template, http_method = EXCLUDED.http_method,
       execution_mode = EXCLUDED.execution_mode, microservice_id = EXCLUDED.microservice_id,
       detail = EXCLUDED.detail;

-- Mismos roles que 'asis-editar', copiados, nunca por nombre.
INSERT INTO public.role_query (query_id, role_id)
SELECT masivo.id_query, rq.role_id
  FROM public.query masivo
  JOIN public.query editar   ON editar.uuid = 'asis-editar'
  JOIN public.role_query rq  ON rq.query_id = editar.id_query
 WHERE masivo.uuid = 'asis-editar-masivo'
ON CONFLICT (query_id, role_id) DO NOTHING;

-- 4c. Formato de los parametros (sin fila aqui el parametro pasa sin validar).
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
