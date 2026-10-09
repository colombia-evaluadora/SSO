-- ===========================================================================
-- V140 - Lectura de la pantalla Asistencia: v_asistencia_detalle y sus 3
-- helpers de duracion/franja, el nucleo fn_asistencia_sesiones_registradas_
-- interno, fn_asistencia_calendario (REGISTRADA exige el padron completo) y
-- fn_asistencia_resumen_horas.
-- Depende de: V136 (alcance), V457 (sesiones programadas), V436
-- (grupo_es_formativo), V22.
-- ===========================================================================

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_horas_bloque(
    p_hora_inicio         TIMESTAMP,
    p_hora_fin            TIMESTAMP,
    p_jornada_inicio      TIME,
    p_jornada_fin         TIME,
    p_bloques_por_defecto BIGINT
)
RETURNS NUMERIC
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT ROUND(COALESCE(
               EXTRACT(EPOCH FROM (p_hora_fin - p_hora_inicio)) / 3600.0,
               EXTRACT(EPOCH FROM (p_jornada_fin - p_jornada_inicio)) / 3600.0
                   / NULLIF(p_bloques_por_defecto, 0),
               0)::NUMERIC, 2);
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_horas_bloque(TIMESTAMP, TIMESTAMP, TIME, TIME, BIGINT)
    IS 'Duracion en horas de un bloque de THORARIO; sin HORA_INICIO/HORA_FIN propias, se estima con la jornada del TPERIODO_ACADEMICO / BLOQUES_POR_DEFECTO. La usan v_asistencia_detalle y fn_asistencia_sesiones_registradas_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_franja_bloque(
    p_fecha          DATE,
    p_hora_inicio    TIMESTAMP,
    p_hora_fin       TIMESTAMP,
    p_jornada_inicio TIME,
    p_jornada_fin    TIME
)
RETURNS TABLE (hora_inicio TIMESTAMP, hora_fin TIMESTAMP)
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT p_fecha + COALESCE(p_hora_inicio::TIME, p_jornada_inicio),
           p_fecha + COALESCE(p_hora_fin::TIME,    p_jornada_fin);
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_franja_bloque(DATE, TIMESTAMP, TIMESTAMP, TIME, TIME)
    IS 'Franja horaria (reloj) de un bloque de THORARIO estampada sobre la FECHA de la sesion, con la misma reserva de jornada que fn_asistencia_horas_bloque. La usan v_asistencia_detalle, fn_asistencia_sesiones_registradas_interno y fn_asistencia_listar_seguimiento.';

CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_horas_actividad(
    p_duracion_estimada NUMERIC,
    p_fecha_inicio      DATE,
    p_fecha_cierre      DATE
)
RETURNS NUMERIC
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT ROUND(COALESCE(
               p_duracion_estimada
                   / NULLIF(GREATEST(p_fecha_cierre - p_fecha_inicio + 1, 0), 0),
               0)::NUMERIC, 2);
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_horas_actividad(NUMERIC, DATE, DATE)
    IS 'Horas que aporta UN dia de una actividad: DURACION_ESTIMADA (duracion de la actividad COMPLETA) repartida entre los dias de su rango. La usan v_asistencia_detalle y fn_asistencia_sesiones_registradas_interno.';

CREATE OR REPLACE VIEW academico_test.v_asistencia_detalle AS
SELECT
    a.PK_TASISTENCIA                          AS pk_tasistencia,
    a.FK_TMATRICULA                           AS fk_tmatricula,
    m.FK_TGRUPO                               AS fk_tgrupo,
    gr.NOMBRE                                 AS grupo,
    gr.FK_TLV_JORNADA                         AS fk_tlv_jornada,
    jor.NOMBRE                                AS jornada,
    jor.VALOR                                 AS jornada_valor,
    g.PK_TGRADO                               AS fk_tgrado,
    g.NOMBRE                                  AS grado,
    g.CODIGO                                  AS grado_valor,
    pa.PK_TPERIODO_ACADEMICO                  AS fk_tperiodo_academico,
    pa.FK_TSEDE                               AS fk_tsede,
    a.FK_TASIGNATURA                          AS fk_tasignatura,
    asig.NOMBRE                               AS asignatura,
    a.FK_TACTIVIDAD                           AS fk_tactividad,
    act.TITULO                                AS actividad,
    (a.FK_TACTIVIDAD IS NOT NULL)             AS es_formativa,
    a.FK_TPERIODO_EVALUACION                  AS fk_tperiodo_evaluacion,
    a.FECHA                                   AS fecha,
    a.BLOQUE                                  AS bloque,
    franja.hora_inicio                        AS hora_inicio,
    franja.hora_fin                            AS hora_fin,
    CASE WHEN a.FK_TACTIVIDAD IS NOT NULL
         THEN academico_test.fn_asistencia_horas_actividad(
                  act.DURACION_ESTIMADA,
                  COALESCE(act.FECHA_INICIO, act.FECHA_CREACION),
                  COALESCE(act.FECHA_CIERRE, act.FECHA_INICIO, act.FECHA_CREACION))
         ELSE academico_test.fn_asistencia_horas_bloque(
                  h.HORA_INICIO, h.HORA_FIN, pa.HORA_INICIO, pa.HORA_FIN, pa.BLOQUES_POR_DEFECTO)
    END                                       AS horas,
    a.FK_TLV_TIPO_ASISTENCIA                  AS fk_tlv_tipo_asistencia,
    -- El estado se compara SIEMPRE como TEXTO: lv.VALOR::INT puede evaluarse
    -- sobre filas de TLISTA_VALOR de otra categoria antes del filtro y
    -- reventar con 22P02.
    CASE lv.VALOR WHEN '1' THEN 1 WHEN '2' THEN 2 WHEN '3' THEN 3
                  WHEN '5' THEN 5 WHEN '6' THEN 6 END  AS tipo_valor,
    lv.NOMBRE                                 AS tipo_nombre,
    (lv.VALOR IN ('1','5','6'))               AS es_presente,
    (lv.VALOR IN ('5','6'))                   AS es_tarde,
    (lv.VALOR IN ('2','3'))                   AS es_ausente,
    -- La excusa es el archivo de soporte; 3/6 solo en filas históricas.
    (lv.VALOR IN ('3','6') OR (lv.VALOR IN ('2','5') AND a.FK_SOPORTE_ARCHIVO IS NOT NULL)) AS es_justificado,
    a.OBSERVACION                             AS observacion,
    a.FK_SOPORTE_ARCHIVO                      AS fk_soporte_archivo,
    (a.FK_SOPORTE_ARCHIVO IS NOT NULL)        AS tiene_soporte,
    arch.NOMBRE                               AS soporte_nombre,
    es.PK_TESTUDIANTE                         AS fk_testudiante,
    u.IDENTIFICACION                          AS documento,
    NULLIF(TRIM(regexp_replace(
        concat_ws(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
                       u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO),
        '\s+', ' ', 'g')), '')                AS estudiante,
    a.CREATED_BY                              AS registrado_por,
    a.CREATED_AT                              AS registrado_at
  FROM academico_test.TASISTENCIA a
  JOIN academico_test.TMATRICULA  m    ON m.PK_TMATRICULA = a.FK_TMATRICULA
  JOIN academico_test.TESTUDIANTE es   ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
  JOIN academico_test.TUSUARIO    u    ON u.PK_TUSUARIO = es.FK_TUSUARIO
  JOIN academico_test.TGRUPO      gr   ON gr.PK_TGRUPO = m.FK_TGRUPO
  JOIN academico_test.TGRADO      g    ON g.PK_TGRADO = gr.FK_TGRADO
  JOIN academico_test.TPERIODO_ACADEMICO pa
                                       ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
  -- LEFT y no INNER: FK_TASIGNATURA es nullable (asistencia formativa). Con
  -- INNER, toda la asistencia de preescolar desaparecia de la vista.
  LEFT JOIN academico_test.TASIGNATURA asig ON asig.PK_TASIGNATURA = a.FK_TASIGNATURA
  LEFT JOIN academico_test.TACTIVIDAD  act  ON act.PK_TACTIVIDAD  = a.FK_TACTIVIDAD
  JOIN academico_test.TLISTA_VALOR lv  ON lv.PK_LISTA_VALOR = a.FK_TLV_TIPO_ASISTENCIA
  LEFT JOIN academico_test.TLISTA_VALOR jor ON jor.PK_LISTA_VALOR = gr.FK_TLV_JORNADA
                                            AND jor.CATEGORIA = 'JORNADA'
  LEFT JOIN academico_test.TARCHIVO arch ON arch.PK_TARCHIVO = a.FK_SOPORTE_ARCHIVO
  -- Franja horaria: LATERAL + LIMIT 1 y match por DIA DE SEMANA de la FECHA
  -- (sin el dia, (grupo, asignatura, bloque) devuelve varias filas y duplica
  -- la asistencia -- el mismo bloque se repite una vez por dia de semana).
  LEFT JOIN LATERAL (
      SELECT th.HORA_INICIO, th.HORA_FIN
        FROM academico_test.THORARIO th
        JOIN academico_test.TLISTA_VALOR dia
          ON dia.PK_LISTA_VALOR = th.FK_TLV_DIA_SEMANA
         AND dia.CATEGORIA = 'DIA_SEMANA'
         AND dia.VALOR = (EXTRACT(DOW FROM a.FECHA)::INT + 1)::TEXT
       WHERE th.FK_TGRUPO      = m.FK_TGRUPO
         AND th.FK_TASIGNATURA = a.FK_TASIGNATURA
         AND th.NUMERO_BLOQUE  = a.BLOQUE
         AND th.ACTIVE = TRUE
       LIMIT 1
  ) h ON TRUE
  CROSS JOIN LATERAL academico_test.fn_asistencia_franja_bloque(
      a.FECHA, h.HORA_INICIO, h.HORA_FIN, pa.HORA_INICIO, pa.HORA_FIN) franja
 WHERE a.ACTIVE = TRUE;

COMMENT ON VIEW academico_test.v_asistencia_detalle
    IS 'Detalle plano de TASISTENCIA (solo ACTIVE), evaluativo y formativo. Cadena de joins: estudiante, grupo, grado, periodo academico, sede, jornada, asignatura, soporte, franja horaria + duracion via THORARIO por (grupo, asignatura, bloque, dia de semana). Expone banderas de estado (es_presente/es_tarde/es_ausente/es_justificado).';

CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_sesiones_registradas_interno(
    p_fk_tsede       BIGINT,
    p_fecha_desde    DATE,
    p_fecha_hasta    DATE,
    p_fk_tgrupo      BIGINT DEFAULT NULL,
    p_fk_tasignatura BIGINT DEFAULT NULL
)
RETURNS TABLE (
    fecha          DATE,
    fk_tgrupo      BIGINT,
    grupo          VARCHAR,
    fk_tgrado      BIGINT,
    grado          VARCHAR,
    grado_valor    VARCHAR,
    fk_tlv_jornada BIGINT,
    jornada        VARCHAR,
    jornada_valor  VARCHAR,
    fk_tasignatura BIGINT,
    asignatura     VARCHAR,
    fk_tactividad  BIGINT,
    actividad      VARCHAR,
    bloque         NUMERIC,
    hora_inicio    TIMESTAMP,
    hora_fin       TIMESTAMP,
    horas          NUMERIC,
    n_total        BIGINT,
    n_presentes    BIGINT,
    n_a_tiempo     BIGINT,
    n_tarde        BIGINT,
    n_ausentes     BIGINT
)
-- jit off: el estimado de filas por matricula sale inflado y la compilacion
-- JIT costaba mas que la consulta (700 ms frente a 30 ms con 20M filas).
LANGUAGE plpgsql STABLE SET jit = off AS $$
#variable_conflict use_column
BEGIN
-- Se agrega sobre TASISTENCIA entrando por las matriculas de la sede, y la
-- franja/horas de v_asistencia_detalle se calculan una vez por sesion y no
-- por fila: por la vista se leia el mes de toda la institucion.
RETURN QUERY
WITH conteo AS (
    SELECT a.FECHA AS fecha, m.FK_TGRUPO AS fk_tgrupo,
           a.FK_TASIGNATURA AS fk_tasignatura, a.FK_TACTIVIDAD AS fk_tactividad,
           a.BLOQUE AS bloque,
           COUNT(*)                                          AS n_total,
           COUNT(*) FILTER (WHERE lv.VALOR IN ('1','5','6')) AS n_presentes,
           COUNT(*) FILTER (WHERE lv.VALOR = '1')            AS n_a_tiempo,
           COUNT(*) FILTER (WHERE lv.VALOR IN ('5','6'))     AS n_tarde,
           COUNT(*) FILTER (WHERE lv.VALOR IN ('2','3'))     AS n_ausentes
      FROM academico_test.TPERIODO_ACADEMICO pa
      JOIN academico_test.TGRADO g      ON g.FK_TPERIODO_ACADEMICO = pa.PK_TPERIODO_ACADEMICO
      JOIN academico_test.TGRUPO gr     ON gr.FK_TGRADO = g.PK_TGRADO
      JOIN academico_test.TMATRICULA m  ON m.FK_TGRUPO = gr.PK_TGRUPO
      JOIN academico_test.TASISTENCIA a ON a.FK_TMATRICULA = m.PK_TMATRICULA
      JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = a.FK_TLV_TIPO_ASISTENCIA
     WHERE pa.FK_TSEDE = p_fk_tsede
       AND a.ACTIVE = TRUE
       AND a.FECHA BETWEEN p_fecha_desde AND p_fecha_hasta
       AND (p_fk_tgrupo      IS NULL OR gr.PK_TGRUPO = p_fk_tgrupo)
       AND (p_fk_tasignatura IS NULL OR a.FK_TASIGNATURA = p_fk_tasignatura)
     GROUP BY a.FECHA, m.FK_TGRUPO, a.FK_TASIGNATURA, a.FK_TACTIVIDAD, a.BLOQUE
)
    SELECT c.fecha, c.fk_tgrupo, gr.NOMBRE AS grupo, g.PK_TGRADO AS fk_tgrado,
           g.NOMBRE AS grado, g.CODIGO AS grado_valor,
           gr.FK_TLV_JORNADA AS fk_tlv_jornada, jor.NOMBRE AS jornada, jor.VALOR AS jornada_valor,
           c.fk_tasignatura, asig.NOMBRE AS asignatura,
           c.fk_tactividad, act.TITULO AS actividad,
           c.bloque,
           franja.hora_inicio, franja.hora_fin,
           CASE WHEN c.fk_tactividad IS NOT NULL
                THEN academico_test.fn_asistencia_horas_actividad(
                         act.DURACION_ESTIMADA,
                         COALESCE(act.FECHA_INICIO, act.FECHA_CREACION),
                         COALESCE(act.FECHA_CIERRE, act.FECHA_INICIO, act.FECHA_CREACION))
                ELSE academico_test.fn_asistencia_horas_bloque(
                         h.HORA_INICIO, h.HORA_FIN, pa.HORA_INICIO, pa.HORA_FIN, pa.BLOQUES_POR_DEFECTO)
           END AS horas,
           c.n_total, c.n_presentes, c.n_a_tiempo, c.n_tarde, c.n_ausentes
      FROM conteo c
      JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = c.fk_tgrupo
      JOIN academico_test.TGRADO g  ON g.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
      LEFT JOIN academico_test.TASIGNATURA asig ON asig.PK_TASIGNATURA = c.fk_tasignatura
      LEFT JOIN academico_test.TACTIVIDAD  act  ON act.PK_TACTIVIDAD  = c.fk_tactividad
      LEFT JOIN academico_test.TLISTA_VALOR jor ON jor.PK_LISTA_VALOR = gr.FK_TLV_JORNADA
                                               AND jor.CATEGORIA = 'JORNADA'
      LEFT JOIN LATERAL (
          SELECT th.HORA_INICIO, th.HORA_FIN
            FROM academico_test.THORARIO th
            JOIN academico_test.TLISTA_VALOR dia
              ON dia.PK_LISTA_VALOR = th.FK_TLV_DIA_SEMANA
             AND dia.CATEGORIA = 'DIA_SEMANA'
             AND dia.VALOR = (EXTRACT(DOW FROM c.fecha)::INT + 1)::TEXT
           WHERE th.FK_TGRUPO      = c.fk_tgrupo
             AND th.FK_TASIGNATURA = c.fk_tasignatura
             AND th.NUMERO_BLOQUE  = c.bloque
             AND th.ACTIVE = TRUE
           LIMIT 1
      ) h ON TRUE
      CROSS JOIN LATERAL academico_test.fn_asistencia_franja_bloque(
          c.fecha, h.HORA_INICIO, h.HORA_FIN, pa.HORA_INICIO, pa.HORA_FIN) franja;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_sesiones_registradas_interno(BIGINT, DATE, DATE, BIGINT, BIGINT)
    IS 'INTERNO: sesiones con asistencia registrada (ACTIVE) de una sede en un rango, una fila por (fecha, grupo, asignatura, actividad, bloque) con nombres, franja/horas (mismas reglas que v_asistencia_detalle) y conteos por estado. Sin alcance: el llamador filtra por rol/docente. La usan fn_asistencia_calendario y fn_asistencia_resumen_horas.';

CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_calendario(
    p_pk_usuario      BIGINT,
    p_fk_tsede        BIGINT,
    p_anio            INTEGER,
    p_mes             INTEGER,
    p_fk_tgrupo       BIGINT DEFAULT NULL,
    p_fk_tasignatura  BIGINT DEFAULT NULL,
    p_fecha_hoy       DATE   DEFAULT CURRENT_DATE,
    p_fk_tfuncionario BIGINT DEFAULT NULL
)
RETURNS TABLE (
    fecha             DATE,
    fk_tgrupo         BIGINT,
    grupo             VARCHAR,
    fk_tgrado         BIGINT,
    grado             VARCHAR,
    grado_valor       VARCHAR,
    fk_tlv_jornada    BIGINT,
    jornada           VARCHAR,
    jornada_valor     VARCHAR,
    fk_tasignatura    BIGINT,
    asignatura        VARCHAR,
    fk_tactividad     BIGINT,
    actividad         VARCHAR,
    es_formativa      BOOLEAN,
    bloque            NUMERIC,
    hora_inicio       TIMESTAMP,
    hora_fin          TIMESTAMP,
    horas             NUMERIC,
    total_estudiantes BIGINT,
    registrados       BIGINT,
    a_tiempo          BIGINT,
    tarde             BIGINT,
    ausentes          BIGINT,
    estado_sesion     TEXT
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_ini DATE := make_date(p_anio, p_mes, 1);
    v_fin DATE := (make_date(p_anio, p_mes, 1) + INTERVAL '1 month')::date;  -- exclusivo
BEGIN
    IF p_fk_tsede IS NULL OR p_anio IS NULL OR p_mes IS NULL THEN
        RAISE EXCEPTION 'sede, anio y mes son obligatorios para el calendario' USING ERRCODE = '22023';
    END IF;
    IF p_mes NOT BETWEEN 1 AND 12 THEN
        RAISE EXCEPTION 'mes invalido: % (1..12)', p_mes USING ERRCODE = '22023';
    END IF;

    RETURN QUERY
    WITH programadas AS (
        SELECT sp.fecha, sp.fk_tgrupo, sp.grupo, sp.fk_tgrado, sp.grado, sp.grado_valor,
               sp.fk_tlv_jornada, sp.jornada, sp.jornada_valor, sp.fk_tasignatura, sp.asignatura,
               NULL::BIGINT  AS fk_tactividad,
               NULL::VARCHAR AS actividad,
               sp.bloque, sp.hora_inicio, sp.hora_fin, sp.horas
          FROM academico_test.fn_asistencia_sesiones_programadas(
                   p_pk_usuario, p_fk_tsede, v_ini, v_fin - 1,
                   p_fk_tgrupo, p_fk_tasignatura, p_fk_tfuncionario) sp
         WHERE NOT academico_test.fn_asistencia_grupo_es_formativo(sp.fk_tgrupo)
        UNION ALL
        SELECT ap.fecha, ap.fk_tgrupo, ap.grupo, ap.fk_tgrado, ap.grado, ap.grado_valor,
               ap.fk_tlv_jornada, ap.jornada, ap.jornada_valor, ap.fk_tasignatura, ap.asignatura,
               ap.fk_tactividad, ap.actividad,
               NULL::NUMERIC   AS bloque,
               NULL::TIMESTAMP AS hora_inicio,
               NULL::TIMESTAMP AS hora_fin,
               ap.horas
          FROM academico_test.fn_asistencia_actividades_programadas(
                   p_pk_usuario, p_fk_tsede, v_ini, v_fin - 1,
                   p_fk_tgrupo, p_fk_tfuncionario) ap
         WHERE p_fk_tasignatura IS NULL OR ap.fk_tasignatura = p_fk_tasignatura
    ),
    registradas AS (
        SELECT r.fecha, r.fk_tgrupo, r.grupo, r.fk_tgrado, r.grado, r.grado_valor,
               r.fk_tlv_jornada, r.jornada, r.jornada_valor, r.fk_tasignatura, r.asignatura,
               r.fk_tactividad, r.actividad, r.bloque, r.hora_inicio, r.hora_fin, r.horas,
               r.n_total, r.n_a_tiempo, r.n_tarde, r.n_ausentes
          FROM academico_test.fn_asistencia_sesiones_registradas_interno(
                   p_fk_tsede, v_ini, v_fin - 1, p_fk_tgrupo, p_fk_tasignatura) r
         WHERE (p_fk_tfuncionario IS NULL OR EXISTS (
                   SELECT 1 FROM academico_test.TDOCENTE_ASIGNATURA da
                    WHERE da.FK_TFUNCIONARIO = p_fk_tfuncionario
                      AND da.FK_TGRUPO       = r.fk_tgrupo
                      AND da.FK_TASIGNATURA  = r.fk_tasignatura
                      AND da.ACTIVE = TRUE))
           AND academico_test.fn_asistencia_puede_ver_asignatura(p_pk_usuario, r.fk_tgrupo, r.fk_tasignatura)
    ),
    padron AS (
        SELECT m.FK_TGRUPO AS fk_tgrupo, COUNT(*)::BIGINT AS matriculas
          FROM academico_test.TMATRICULA m
         WHERE m.ACTIVE = TRUE
           AND m.FK_TGRUPO IN (SELECT pg.fk_tgrupo FROM programadas pg
                               UNION SELECT rg.fk_tgrupo FROM registradas rg)
         GROUP BY m.FK_TGRUPO
    )
    SELECT
        COALESCE(p.fecha, r.fecha),
        COALESCE(p.fk_tgrupo, r.fk_tgrupo),
        COALESCE(p.grupo, r.grupo),
        COALESCE(p.fk_tgrado, r.fk_tgrado),
        COALESCE(p.grado, r.grado),
        COALESCE(p.grado_valor, r.grado_valor),
        COALESCE(p.fk_tlv_jornada, r.fk_tlv_jornada),
        COALESCE(p.jornada, r.jornada),
        COALESCE(p.jornada_valor, r.jornada_valor),
        COALESCE(p.fk_tasignatura, r.fk_tasignatura),
        COALESCE(p.asignatura, r.asignatura),
        COALESCE(p.fk_tactividad, r.fk_tactividad),
        COALESCE(p.actividad, r.actividad),
        (COALESCE(p.fk_tactividad, r.fk_tactividad) IS NOT NULL),
        COALESCE(p.bloque, r.bloque),
        COALESCE(p.hora_inicio, r.hora_inicio),
        COALESCE(p.hora_fin, r.hora_fin),
        COALESCE(p.horas, r.horas, 0),
        COALESCE(pad.matriculas, 0)::BIGINT,
        COALESCE(r.n_total, 0)::BIGINT,
        COALESCE(r.n_a_tiempo, 0)::BIGINT,
        COALESCE(r.n_tarde, 0)::BIGINT,
        COALESCE(r.n_ausentes, 0)::BIGINT,
        -- REGISTRADA exige que TODO el padron activo del grupo tenga
        -- fila de asistencia, no solo que exista alguna. Con registro parcial
        -- (ej. 1 de 7) la sesion sigue contando lo que falte, igual que si no
        -- se hubiera tomado nada.
        CASE WHEN r.n_total IS NOT NULL
                  AND COALESCE(pad.matriculas, 0) > 0
                  AND r.n_total >= pad.matriculas             THEN 'REGISTRADA'
             WHEN COALESCE(p.fecha, r.fecha) <  p_fecha_hoy   THEN 'RETRASADA'
             ELSE 'PENDIENTE'
        END
      FROM programadas p
      FULL OUTER JOIN registradas r
        ON r.fecha          = p.fecha
       AND r.fk_tgrupo      = p.fk_tgrupo
       AND COALESCE(r.fk_tactividad, -1) = COALESCE(p.fk_tactividad, -1)
       AND (p.fk_tactividad IS NOT NULL
            OR (COALESCE(r.fk_tasignatura, -1) = COALESCE(p.fk_tasignatura, -1)
                AND COALESCE(r.bloque, -1) = COALESCE(p.bloque, -1)))
      LEFT JOIN padron pad ON pad.fk_tgrupo = COALESCE(p.fk_tgrupo, r.fk_tgrupo)
     ORDER BY 1, 3, 11, 15;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_calendario(
    BIGINT, BIGINT, INTEGER, INTEGER, BIGINT, BIGINT, DATE, BIGINT
) IS 'Pantalla Asistencia (calendario mensual por sede). Una fila por SESION del mes: las PROGRAMADAS (fn_asistencia_sesiones_programadas) en FULL OUTER JOIN con las REGISTRADAS, de modo que tambien aparecen las tomas manuales sin bloque programado. Incluye grado (fk_tgrado/grado/grado_valor -- CODIGO de TGRADO) y jornada (fk_tlv_jornada/jornada/jornada_valor -- NOMBRE/VALOR de TLISTA_VALOR CATEGORIA=''JORNADA'') del grupo de cada sesion. estado_sesion = REGISTRADA (registrados >= matriculas del padron activo del grupo -- V140, antes bastaba con que existiera una sola fila y un registro PARCIAL ya se veia como completo) | RETRASADA (fecha < p_fecha_hoy sin registro completo, contada desde el DIA ANTERIOR, V464) | PENDIENTE (hoy o futuro, o registro parcial sin vencer). p_fk_tfuncionario no NULL acota a las asignaturas asignadas a ese docente en TDOCENTE_ASIGNATURA (vista "mis clases"). Rango de fechas sargable. Alcance por rol via fn_asistencia_puede_ver.';

-- Depende de esta misma migracion (fn_asistencia_sesiones_registradas_interno,
-- fn_asistencia_calendario) y de V457 (sesiones/
-- actividades programadas), V436 (grupo_es_formativo).
CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_resumen_horas(
    p_pk_usuario      BIGINT,
    p_fk_tsede        BIGINT,
    p_fecha_ref       DATE   DEFAULT CURRENT_DATE,
    p_fk_tgrupo       BIGINT DEFAULT NULL,
    p_fk_tasignatura  BIGINT DEFAULT NULL,
    p_fk_tfuncionario BIGINT DEFAULT NULL
)
RETURNS TABLE (
    horas_semana             NUMERIC,
    horas_mes                NUMERIC,
    horas_anio               NUMERIC,
    horas_programadas_semana NUMERIC,
    horas_programadas_mes    NUMERIC,
    horas_efectivas_mes      NUMERIC,
    sesiones_mes             BIGINT,
    registros_mes            BIGINT,
    a_tiempo_mes             BIGINT,
    tarde_mes                BIGINT,
    ausentes_mes             BIGINT,
    registradas_mes          BIGINT,
    retrasadas_mes           BIGINT,
    pendientes_mes           BIGINT
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_anio_ini DATE := date_trunc('year',  p_fecha_ref::timestamp)::date;
    v_anio_fin DATE := (date_trunc('year',  p_fecha_ref::timestamp) + INTERVAL '1 year')::date;
    v_mes_ini  DATE := date_trunc('month', p_fecha_ref::timestamp)::date;
    v_mes_fin  DATE := (date_trunc('month', p_fecha_ref::timestamp) + INTERVAL '1 month')::date;
    v_sem_ini  DATE := date_trunc('week',  p_fecha_ref::timestamp)::date;
    v_sem_fin  DATE := (date_trunc('week',  p_fecha_ref::timestamp) + INTERVAL '1 week')::date;
BEGIN
    RETURN QUERY
    WITH sesion AS (
        SELECT r.fecha,
               MIN(r.horas)              AS horas_sesion,
               SUM(r.n_total)            AS n_total,
               SUM(r.n_presentes)        AS n_presentes,
               SUM(r.n_a_tiempo)         AS n_a_tiempo,
               SUM(r.n_tarde)            AS n_tarde,
               SUM(r.n_ausentes)         AS n_ausentes
          FROM academico_test.fn_asistencia_sesiones_registradas_interno(
                   p_fk_tsede, v_anio_ini, v_anio_fin - 1, p_fk_tgrupo, p_fk_tasignatura) r
         WHERE (p_fk_tfuncionario IS NULL OR EXISTS (
                   SELECT 1 FROM academico_test.TDOCENTE_ASIGNATURA da
                    WHERE da.FK_TFUNCIONARIO = p_fk_tfuncionario
                      AND da.FK_TGRUPO       = r.fk_tgrupo
                      AND da.FK_TASIGNATURA  = r.fk_tasignatura
                      AND da.ACTIVE = TRUE))
           AND academico_test.fn_asistencia_puede_ver_asignatura(p_pk_usuario, r.fk_tgrupo, r.fk_tasignatura)
         GROUP BY r.fecha, r.fk_tgrupo, r.fk_tasignatura, r.bloque
    ),
    programadas AS (
        SELECT sp.fecha, sp.horas
          FROM academico_test.fn_asistencia_sesiones_programadas(
                   p_pk_usuario, p_fk_tsede,
                   LEAST(v_sem_ini, v_mes_ini),
                   GREATEST(v_sem_fin, v_mes_fin) - 1,
                   p_fk_tgrupo, p_fk_tasignatura, p_fk_tfuncionario) sp
         WHERE NOT academico_test.fn_asistencia_grupo_es_formativo(sp.fk_tgrupo)
        UNION ALL
        SELECT ap.fecha, ap.horas
          FROM academico_test.fn_asistencia_actividades_programadas(
                   p_pk_usuario, p_fk_tsede,
                   LEAST(v_sem_ini, v_mes_ini),
                   GREATEST(v_sem_fin, v_mes_fin) - 1,
                   p_fk_tgrupo, p_fk_tfuncionario) ap
         WHERE p_fk_tasignatura IS NULL OR ap.fk_tasignatura = p_fk_tasignatura
    ),
    estados AS (
        SELECT c.estado_sesion, COUNT(*) AS n
          FROM academico_test.fn_asistencia_calendario(
                   p_pk_usuario      => p_pk_usuario,
                   p_fk_tsede        => p_fk_tsede,
                   p_anio            => EXTRACT(YEAR  FROM p_fecha_ref)::INT,
                   p_mes             => EXTRACT(MONTH FROM p_fecha_ref)::INT,
                   p_fk_tgrupo       => p_fk_tgrupo,
                   p_fk_tasignatura  => p_fk_tasignatura,
                   p_fk_tfuncionario => p_fk_tfuncionario) c
         GROUP BY c.estado_sesion
    )
    SELECT
        ROUND(COALESCE(SUM(s.horas_sesion) FILTER (WHERE s.fecha >= v_sem_ini AND s.fecha < v_sem_fin), 0), 2),
        ROUND(COALESCE(SUM(s.horas_sesion) FILTER (WHERE s.fecha >= v_mes_ini AND s.fecha < v_mes_fin), 0), 2),
        ROUND(COALESCE(SUM(s.horas_sesion), 0), 2),
        (SELECT ROUND(COALESCE(SUM(pr.horas) FILTER (WHERE pr.fecha >= v_sem_ini AND pr.fecha < v_sem_fin), 0), 2)
           FROM programadas pr),
        (SELECT ROUND(COALESCE(SUM(pr.horas) FILTER (WHERE pr.fecha >= v_mes_ini AND pr.fecha < v_mes_fin), 0), 2)
           FROM programadas pr),
        ROUND(COALESCE(SUM(s.horas_sesion * s.n_presentes::NUMERIC / NULLIF(s.n_total, 0))
                       FILTER (WHERE s.fecha >= v_mes_ini AND s.fecha < v_mes_fin), 0), 2),
        COUNT(*)          FILTER (WHERE s.fecha >= v_mes_ini AND s.fecha < v_mes_fin)::BIGINT,
        COALESCE(SUM(s.n_total)    FILTER (WHERE s.fecha >= v_mes_ini AND s.fecha < v_mes_fin), 0)::BIGINT,
        COALESCE(SUM(s.n_a_tiempo) FILTER (WHERE s.fecha >= v_mes_ini AND s.fecha < v_mes_fin), 0)::BIGINT,
        COALESCE(SUM(s.n_tarde)    FILTER (WHERE s.fecha >= v_mes_ini AND s.fecha < v_mes_fin), 0)::BIGINT,
        COALESCE(SUM(s.n_ausentes) FILTER (WHERE s.fecha >= v_mes_ini AND s.fecha < v_mes_fin), 0)::BIGINT,
        (SELECT COALESCE(SUM(e.n), 0) FROM estados e WHERE e.estado_sesion = 'REGISTRADA')::BIGINT,
        (SELECT COALESCE(SUM(e.n), 0) FROM estados e WHERE e.estado_sesion = 'RETRASADA')::BIGINT,
        (SELECT COALESCE(SUM(e.n), 0) FROM estados e WHERE e.estado_sesion = 'PENDIENTE')::BIGINT
      FROM sesion s;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_resumen_horas(
    BIGINT, BIGINT, DATE, BIGINT, BIGINT, BIGINT
) IS 'Tarjetas del encabezado de la pantalla Asistencia. Horas DICTADAS (registradas) de semana/mes/anio + horas PROGRAMADAS del horario de semana/mes. horas_efectivas_mes ponderada por fraccion de presentes. Los 3 contadores de estado (registradas/retrasadas/pendientes) delegados en fn_asistencia_calendario. p_fk_tfuncionario no NULL acota todo a las asignaturas asignadas a ese docente. Alcance por rol via fn_asistencia_puede_ver.';
