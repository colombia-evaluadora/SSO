-- V457: la proyeccion del horario (calendario / tarjetas de Asistencia) se
-- acota a las fechas del periodo academico y a sus periodos de evaluacion.
--
-- Antes fn_asistencia_sesiones_programadas proyectaba THORARIO sobre TODOS los
-- dias del mes: un periodo que arranca el 15 mostraba sesiones "vencidas" del
-- 1 al 14, un periodo cerrado seguia proyectando meses despues, y un grupo /
-- grado / asignatura / periodo desactivado seguia contando horas. Ademas esas
-- fechas no se pueden registrar: fn_asistencia_registrar_bulk exige un
-- periodo de evaluacion activo que contenga la fecha (22023), asi que quedaban
-- RETRASADAS para siempre. Un periodo Cerrado (ESTADOPERIODO 'C') tampoco
-- proyecta: solo quedan sus registradas. Mismo recorte en fn_asistencia_actividades_programadas.
-- Depende de: V220 (firmas y contrato), V436 (rama formativa apagada).

CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_sesiones_programadas(
    p_pk_usuario      BIGINT,
    p_fk_tsede        BIGINT,
    p_fecha_desde     DATE,
    p_fecha_hasta     DATE,     -- INCLUSIVO
    p_fk_tgrupo       BIGINT DEFAULT NULL,
    p_fk_tasignatura  BIGINT DEFAULT NULL,
    p_fk_tfuncionario BIGINT DEFAULT NULL
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
    bloque         NUMERIC,
    hora_inicio    TIMESTAMP,
    hora_fin       TIMESTAMP,
    horas          NUMERIC
)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN QUERY
    SELECT dd::date,
           th.FK_TGRUPO,      gr.NOMBRE,
           g.PK_TGRADO,       g.NOMBRE,        g.CODIGO,
           gr.FK_TLV_JORNADA, jor.NOMBRE,      jor.VALOR,
           th.FK_TASIGNATURA, asig.NOMBRE,
           th.NUMERO_BLOQUE,
           franja.hora_inicio, franja.hora_fin,
           academico_test.fn_asistencia_horas_bloque(
               th.HORA_INICIO, th.HORA_FIN, pa.HORA_INICIO, pa.HORA_FIN, pa.BLOQUES_POR_DEFECTO)
      FROM generate_series(p_fecha_desde, p_fecha_hasta, INTERVAL '1 day') dd
      JOIN academico_test.TLISTA_VALOR dia
        ON dia.CATEGORIA = 'DIA_SEMANA'
       AND dia.VALOR = (EXTRACT(DOW FROM dd)::INT + 1)::TEXT
      JOIN academico_test.THORARIO th
        ON th.FK_TLV_DIA_SEMANA = dia.PK_LISTA_VALOR
       AND th.ACTIVE = TRUE
      JOIN academico_test.TGRUPO gr             ON gr.PK_TGRUPO = th.FK_TGRUPO
                                                AND gr.ACTIVE = TRUE
      JOIN academico_test.TGRADO g              ON g.PK_TGRADO = gr.FK_TGRADO
                                                AND g.ACTIVE = TRUE
      JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
                                                AND pa.ACTIVE = TRUE
                                                -- Sin periodo no hay clase: el
                                                -- horario solo vive dentro de
                                                -- [FECHA_INICIO, FECHA_FIN].
                                                AND dd::date BETWEEN pa.FECHA_INICIO AND pa.FECHA_FIN
      JOIN academico_test.TASIGNATURA asig      ON asig.PK_TASIGNATURA = th.FK_TASIGNATURA
                                                AND asig.ACTIVE = TRUE
      LEFT JOIN academico_test.TLISTA_VALOR est ON est.PK_LISTA_VALOR = pa.FK_TLV_ESTADO
                                                AND est.CATEGORIA = 'ESTADOPERIODO'
      LEFT JOIN academico_test.TLISTA_VALOR jor ON jor.PK_LISTA_VALOR = gr.FK_TLV_JORNADA
                                                AND jor.CATEGORIA = 'JORNADA'
      CROSS JOIN LATERAL academico_test.fn_asistencia_franja_bloque(
          dd::date, th.HORA_INICIO, th.HORA_FIN, pa.HORA_INICIO, pa.HORA_FIN) franja
     WHERE pa.FK_TSEDE = p_fk_tsede
       -- Periodo Cerrado (ESTADOPERIODO 'C'): no proyecta; quedan solo las
       -- registradas. Mismo criterio que fn_asistencia_periodo_estado
       -- (sin estado clasificado = no cerrado).
       AND COALESCE(est.VALOR, '') <> 'C'
       -- Solo fechas REGISTRABLES: la misma regla que fn_asistencia_registrar_bulk
       -- (fn_asistencia_periodo_eval). Una sesion sin periodo de evaluacion no
       -- se puede tomar, asi que tampoco cuenta como programada.
       AND EXISTS (
               SELECT 1 FROM academico_test.TPERIODO_EVALUACION pe
                WHERE pe.FK_TPERIODO_ACADEMICO = pa.PK_TPERIODO_ACADEMICO
                  AND pe.ACTIVE = TRUE
                  AND dd::date BETWEEN pe.FECHA_INICIO AND pe.FECHA_FIN)
       AND (p_fk_tgrupo      IS NULL OR th.FK_TGRUPO = p_fk_tgrupo)
       AND (p_fk_tasignatura IS NULL OR th.FK_TASIGNATURA = p_fk_tasignatura)
       AND (p_fk_tfuncionario IS NULL OR EXISTS (
               SELECT 1 FROM academico_test.TDOCENTE_ASIGNATURA da
                WHERE da.FK_TFUNCIONARIO = p_fk_tfuncionario
                  AND da.FK_TGRUPO       = th.FK_TGRUPO
                  AND da.FK_TASIGNATURA  = th.FK_TASIGNATURA
                  AND da.ACTIVE = TRUE))
       AND academico_test.fn_asistencia_puede_ver(p_pk_usuario, th.FK_TGRUPO)
     GROUP BY dd::date, th.FK_TGRUPO, gr.NOMBRE, g.PK_TGRADO, g.NOMBRE, g.CODIGO,
              gr.FK_TLV_JORNADA, jor.NOMBRE, jor.VALOR, th.FK_TASIGNATURA, asig.NOMBRE,
              th.NUMERO_BLOQUE, th.HORA_INICIO, th.HORA_FIN,
              franja.hora_inicio, franja.hora_fin,
              pa.HORA_INICIO, pa.HORA_FIN, pa.BLOQUES_POR_DEFECTO;  -- colapsa bloques duplicados
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_sesiones_programadas(
    BIGINT, BIGINT, DATE, DATE, BIGINT, BIGINT, BIGINT
) IS 'Proyeccion del horario (THORARIO) sobre las fechas reales de [p_fecha_desde, p_fecha_hasta] (INCLUSIVO): una fila por sesion que TOCA dictar (grupo, asignatura, bloque, fecha) con su franja horaria (fn_asistencia_franja_bloque, con reserva de jornada) y duracion en horas, e incluye grado (fk_tgrado/grado/grado_valor -- CODIGO de TGRADO) y jornada (fk_tlv_jornada/jornada/jornada_valor -- NOMBRE/VALOR de TLISTA_VALOR CATEGORIA=''JORNADA'') del grupo. SOLO fechas dentro de [FECHA_INICIO, FECHA_FIN] del periodo academico del grupo Y contenidas en un periodo de evaluacion activo (misma regla que fn_asistencia_registrar_bulk: lo que no se puede registrar no se programa), y solo grupo/grado/asignatura/periodo ACTIVE y periodo NO Cerrado (ESTADOPERIODO ''C'': solo quedan las registradas). Scope por sede + fn_asistencia_puede_ver. Si p_fk_tfuncionario no es NULL, solo las (grupo, asignatura) asignadas a ese docente en TDOCENTE_ASIGNATURA. La usan fn_asistencia_calendario (rama "programadas") y fn_asistencia_resumen_horas (horas programadas de la semana / del mes).';


CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_actividades_programadas(
    p_pk_usuario      BIGINT,
    p_fk_tsede        BIGINT,
    p_fecha_desde     DATE,
    p_fecha_hasta     DATE,     -- INCLUSIVO
    p_fk_tgrupo       BIGINT DEFAULT NULL,
    p_fk_tfuncionario BIGINT DEFAULT NULL
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
    fk_tactividad  BIGINT,
    actividad      VARCHAR,
    fk_tasignatura BIGINT,
    asignatura     VARCHAR,
    horas          NUMERIC
)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN QUERY
    SELECT dd::date,
           gr.PK_TGRUPO,      gr.NOMBRE,
           g.PK_TGRADO,       g.NOMBRE,       g.CODIGO,
           gr.FK_TLV_JORNADA, jor.NOMBRE,     jor.VALOR,
           a.PK_TACTIVIDAD,   a.TITULO,
           a.FK_TASIGNATURA,  asig.NOMBRE,
           academico_test.fn_asistencia_horas_actividad(
               a.DURACION_ESTIMADA, v.inicio, v.cierre)
      FROM academico_test.TACTIVIDAD a
      JOIN academico_test.TGRUPO gr             ON gr.PK_TGRUPO = a.FK_TGRUPO AND gr.ACTIVE = TRUE
      JOIN academico_test.TGRADO g              ON g.PK_TGRADO = gr.FK_TGRADO AND g.ACTIVE = TRUE
      JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
                                                AND pa.ACTIVE = TRUE
      LEFT JOIN academico_test.TASIGNATURA asig ON asig.PK_TASIGNATURA = a.FK_TASIGNATURA
      LEFT JOIN academico_test.TLISTA_VALOR est ON est.PK_LISTA_VALOR = pa.FK_TLV_ESTADO
                                                AND est.CATEGORIA = 'ESTADOPERIODO'
      LEFT JOIN academico_test.TLISTA_VALOR jor ON jor.PK_LISTA_VALOR = gr.FK_TLV_JORNADA
                                                AND jor.CATEGORIA = 'JORNADA'
      -- Vigencia de la actividad, mismo criterio que fn_asistencia_actividades_dia.
      CROSS JOIN LATERAL (
          SELECT COALESCE(a.FECHA_INICIO, a.FECHA_CREACION)                 AS inicio,
                 COALESCE(a.FECHA_CIERRE, a.FECHA_INICIO, a.FECHA_CREACION) AS cierre
      ) v
      -- Interseccion del rango de la actividad con la ventana pedida Y con el
      -- periodo academico: fuera del periodo no hay sesion que tomar.
      CROSS JOIN LATERAL generate_series(
          GREATEST(v.inicio, p_fecha_desde, pa.FECHA_INICIO),
          LEAST(v.cierre,  p_fecha_hasta,  pa.FECHA_FIN),
          INTERVAL '1 day') dd
     WHERE a.ACTIVE = TRUE
       AND pa.FK_TSEDE = p_fk_tsede
       AND COALESCE(est.VALOR, '') <> 'C'   -- periodo Cerrado no proyecta
       AND EXISTS (
               SELECT 1 FROM academico_test.TPERIODO_EVALUACION pe
                WHERE pe.FK_TPERIODO_ACADEMICO = pa.PK_TPERIODO_ACADEMICO
                  AND pe.ACTIVE = TRUE
                  AND dd::date BETWEEN pe.FECHA_INICIO AND pe.FECHA_FIN)
       AND academico_test.fn_asistencia_grupo_es_formativo(gr.PK_TGRUPO)
       AND (p_fk_tgrupo IS NULL OR gr.PK_TGRUPO = p_fk_tgrupo)
       AND (p_fk_tfuncionario IS NULL OR EXISTS (
               SELECT 1 FROM academico_test.TDOCENTE_ASIGNATURA da
                WHERE da.FK_TFUNCIONARIO = p_fk_tfuncionario
                  AND da.FK_TGRUPO       = a.FK_TGRUPO
                  AND da.FK_TASIGNATURA  = a.FK_TASIGNATURA
                  AND da.ACTIVE = TRUE))
       AND academico_test.fn_asistencia_puede_ver(p_pk_usuario, gr.PK_TGRUPO);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_actividades_programadas(
    BIGINT, BIGINT, DATE, DATE, BIGINT, BIGINT
) IS 'Equivalente FORMATIVO de fn_asistencia_sesiones_programadas: proyecta el RANGO de cada actividad ([COALESCE(FECHA_INICIO,FECHA_CREACION), COALESCE(FECHA_CIERRE,FECHA_INICIO,FECHA_CREACION)] intersectado con la ventana pedida y con [FECHA_INICIO, FECHA_FIN] del periodo academico) sobre las fechas reales, una fila por (actividad, fecha), solo en fechas con periodo de evaluacion activo y periodo NO Cerrado (ESTADOPERIODO ''C''). SOLO grupos formativos (fn_asistencia_grupo_es_formativo -- FALSE siempre desde V436), para que fn_asistencia_calendario pueda unir las dos fuentes sin duplicar ningun grupo. horas = TACTIVIDAD.DURACION_ESTIMADA (NULL = 0). Scope por sede + fn_asistencia_puede_ver; p_fk_tfuncionario acota por TDOCENTE_ASIGNATURA segun la asignatura de la actividad.';
