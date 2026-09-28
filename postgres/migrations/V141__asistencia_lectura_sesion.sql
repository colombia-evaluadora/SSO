-- ===========================================================================
-- V141 -- Las 3 funciones de lectura de asistencia que vivian solo en V220
-- (eliminada): fn_asistencia_actividades_dia, fn_asistencia_estudiantes_sesion,
-- fn_asistencia_asignaturas_sesion. Cierra la trazabilidad del modulo
-- consolidada en V136-V141.
-- Depende de: TGRUPO/TGRADO/TPERIODO_ACADEMICO/TMATRICULA/TESTUDIANTE/
-- TUSUARIO/TASIGNATURA/TACTIVIDAD/THORARIO/TLISTA_VALOR/TDOCENTE_ASIGNATURA
-- (V22), V140 (fn_asistencia_puede_ver, v_asistencia_detalle,
-- fn_asistencia_franja_bloque), V137 (fn_asistencia_periodo_eval).
-- ===========================================================================

SET search_path TO academico_test, public;

-- Definicion sin cambios respecto a la V220 original (eliminada).
CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_actividades_dia(
    p_pk_usuario      BIGINT,
    p_fk_tgrupo       BIGINT,
    p_fecha           DATE,
    p_fk_tfuncionario BIGINT DEFAULT NULL
)
RETURNS TABLE (
    fk_tactividad  BIGINT,
    actividad      VARCHAR,
    fk_tasignatura BIGINT,
    asignatura     VARCHAR,
    fecha_inicio   DATE,
    fecha_cierre   DATE
)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF NOT academico_test.fn_asistencia_puede_ver(p_pk_usuario, p_fk_tgrupo) THEN
        RAISE EXCEPTION 'El usuario no puede ver la asistencia del grupo %', p_fk_tgrupo
            USING ERRCODE = '42501';
    END IF;
    IF p_fk_tgrupo IS NULL OR p_fecha IS NULL THEN
        RAISE EXCEPTION 'grupo y fecha son obligatorios' USING ERRCODE = '23502';
    END IF;

    RETURN QUERY
    SELECT a.PK_TACTIVIDAD, a.TITULO,
           a.FK_TASIGNATURA, asig.NOMBRE,
           v.inicio, v.cierre
      FROM academico_test.TACTIVIDAD a
      LEFT JOIN academico_test.TASIGNATURA asig
             ON asig.PK_TASIGNATURA = a.FK_TASIGNATURA
      CROSS JOIN LATERAL (
          SELECT COALESCE(a.FECHA_INICIO, a.FECHA_CREACION)                    AS inicio,
                 COALESCE(a.FECHA_CIERRE, a.FECHA_INICIO, a.FECHA_CREACION)    AS cierre
      ) v
     WHERE a.FK_TGRUPO = p_fk_tgrupo
       AND a.ACTIVE = TRUE
       AND p_fecha BETWEEN v.inicio AND v.cierre
       AND (p_fk_tfuncionario IS NULL OR EXISTS (
               SELECT 1 FROM academico_test.TDOCENTE_ASIGNATURA da
                WHERE da.FK_TFUNCIONARIO = p_fk_tfuncionario
                  AND da.FK_TGRUPO       = a.FK_TGRUPO
                  AND da.FK_TASIGNATURA  = a.FK_TASIGNATURA
                  AND da.ACTIVE = TRUE))
     ORDER BY v.inicio, a.TITULO, a.PK_TACTIVIDAD;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_actividades_dia(BIGINT, BIGINT, DATE, BIGINT)
    IS 'Actividades de un grupo VIGENTES en una fecha (equivalente formativo de fn_asistencia_asignaturas_sesion). Vigencia por RANGO [COALESCE(FECHA_INICIO,FECHA_CREACION), COALESCE(FECHA_CIERRE,FECHA_INICIO,FECHA_CREACION)]. p_fk_tfuncionario no NULL acota a TDOCENTE_ASIGNATURA. Gate: fn_asistencia_puede_ver. Copia identica de V220, redefinida aqui (V141) para trazabilidad.';

CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_estudiantes_sesion(
    p_pk_usuario     BIGINT,
    p_fk_tgrupo      BIGINT,
    p_fk_tasignatura BIGINT,
    p_fecha          DATE,
    p_bloque         NUMERIC DEFAULT NULL,
    p_fk_tactividad  BIGINT  DEFAULT NULL
)
RETURNS TABLE (
    fk_tmatricula          BIGINT,
    fk_testudiante         BIGINT,
    estudiante             TEXT,
    documento              VARCHAR,
    pk_tasistencia         BIGINT,
    tipo_asistencia_valor  INTEGER,
    tipo_asistencia        VARCHAR,
    observacion            VARCHAR,
    fk_soporte_archivo     BIGINT,
    soporte_nombre         VARCHAR,
    fk_tperiodo_evaluacion BIGINT,
    hora_inicio            TIMESTAMP,
    hora_fin               TIMESTAMP,
    total_estudiantes      BIGINT,
    registrados            BIGINT
)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF NOT academico_test.fn_asistencia_puede_ver(p_pk_usuario, p_fk_tgrupo) THEN
        RAISE EXCEPTION 'El usuario no puede ver la asistencia del grupo %', p_fk_tgrupo
            USING ERRCODE = '42501';
    END IF;

    IF p_fk_tgrupo IS NULL OR p_fecha IS NULL THEN
        RAISE EXCEPTION 'grupo y fecha son obligatorios' USING ERRCODE = '23502';
    END IF;
    IF p_fk_tasignatura IS NULL AND p_fk_tactividad IS NULL THEN
        RAISE EXCEPTION 'debe enviar la asignatura (sesion por horario) o la actividad (sesion formativa)'
            USING ERRCODE = '23502';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM academico_test.TGRUPO
                    WHERE PK_TGRUPO = p_fk_tgrupo AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'grupo (%) no existe o no esta activo', p_fk_tgrupo USING ERRCODE = '23503';
    END IF;
    IF p_fk_tasignatura IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM academico_test.TASIGNATURA
                        WHERE PK_TASIGNATURA = p_fk_tasignatura AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'asignatura (%) no existe o no esta activa', p_fk_tasignatura USING ERRCODE = '23503';
    END IF;
    IF p_fk_tactividad IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM academico_test.TACTIVIDAD
                        WHERE PK_TACTIVIDAD = p_fk_tactividad AND ACTIVE = TRUE
                          AND FK_TGRUPO = p_fk_tgrupo) THEN
        RAISE EXCEPTION 'la actividad (%) no existe, no esta activa o no pertenece al grupo %',
            p_fk_tactividad, p_fk_tgrupo USING ERRCODE = '23503';
    END IF;

    RETURN QUERY
    WITH horario AS (
        SELECT franja.hora_inicio AS HORA_INICIO, franja.hora_fin AS HORA_FIN
          FROM academico_test.TGRUPO gr
          JOIN academico_test.TGRADO g              ON g.PK_TGRADO = gr.FK_TGRADO
          JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
          JOIN academico_test.THORARIO th ON th.FK_TGRUPO = gr.PK_TGRUPO AND th.ACTIVE = TRUE
          JOIN academico_test.TLISTA_VALOR dia
            ON dia.PK_LISTA_VALOR = th.FK_TLV_DIA_SEMANA
           AND dia.CATEGORIA = 'DIA_SEMANA'
           AND dia.VALOR = (EXTRACT(DOW FROM p_fecha)::INT + 1)::TEXT
          CROSS JOIN LATERAL academico_test.fn_asistencia_franja_bloque(
              p_fecha, th.HORA_INICIO, th.HORA_FIN, pa.HORA_INICIO, pa.HORA_FIN) franja
         WHERE gr.PK_TGRUPO      = p_fk_tgrupo AND gr.ACTIVE = TRUE
           AND th.FK_TASIGNATURA = p_fk_tasignatura
           AND th.NUMERO_BLOQUE  = p_bloque
         LIMIT 1
    ),
    registros AS (
        SELECT d.fk_tmatricula, d.pk_tasistencia, d.tipo_valor, d.tipo_nombre,
               d.observacion, d.fk_soporte_archivo, d.soporte_nombre
          FROM academico_test.v_asistencia_detalle d
         WHERE d.fecha = p_fecha
           AND COALESCE(d.fk_tasignatura, 0) = COALESCE(p_fk_tasignatura, 0)
           AND COALESCE(d.fk_tactividad, 0)  = COALESCE(p_fk_tactividad, 0)
           AND COALESCE(d.bloque, 0) = COALESCE(p_bloque, 0)
    )
    SELECT
        m.PK_TMATRICULA,
        es.PK_TESTUDIANTE,
        NULLIF(TRIM(regexp_replace(
            concat_ws(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
                           u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO),
            '\s+', ' ', 'g')), ''),
        u.IDENTIFICACION,
        r.PK_TASISTENCIA,
        r.tipo_valor,
        r.tipo_nombre,
        r.OBSERVACION,
        r.FK_SOPORTE_ARCHIVO,
        r.soporte_nombre,
        academico_test.fn_asistencia_periodo_eval(p_fk_tgrupo, p_fecha),
        (SELECT h.HORA_INICIO FROM horario h),
        (SELECT h.HORA_FIN    FROM horario h),
        count(*)            OVER ()::BIGINT,
        count(r.PK_TASISTENCIA) OVER ()::BIGINT
      FROM academico_test.TMATRICULA  m
      JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
      JOIN academico_test.TUSUARIO    u  ON u.PK_TUSUARIO = es.FK_TUSUARIO
 LEFT JOIN registros r ON r.FK_TMATRICULA = m.PK_TMATRICULA
     WHERE m.FK_TGRUPO = p_fk_tgrupo AND m.ACTIVE = TRUE
     ORDER BY u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO, u.PRIMER_NOMBRE,
              u.SEGUNDO_NOMBRE, m.PK_TMATRICULA;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_estudiantes_sesion(
    BIGINT, BIGINT, BIGINT, DATE, NUMERIC, BIGINT
) IS 'Padron de una sesion para "Asistencia manual": una fila por matricula activa del grupo con su estado ACTUAL (NULL si falta tomarlo). Cabecera de sesion (fk_tperiodo_evaluacion, hora_inicio/hora_fin) repetida en cada fila. Gate: fn_asistencia_puede_ver. Copia identica de V220, redefinida aqui (V141) para trazabilidad.';

CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_asignaturas_sesion(
    p_pk_usuario      BIGINT,
    p_fk_tgrupo       BIGINT,
    p_fecha           DATE,
    p_fk_tfuncionario BIGINT DEFAULT NULL
)
RETURNS TABLE (
    fk_tasignatura BIGINT,
    asignatura     VARCHAR,
    bloque         NUMERIC,
    hora_inicio    TIMESTAMP,
    hora_fin       TIMESTAMP
)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF NOT academico_test.fn_asistencia_puede_ver(p_pk_usuario, p_fk_tgrupo) THEN
        RAISE EXCEPTION 'El usuario no puede ver la asistencia del grupo %', p_fk_tgrupo
            USING ERRCODE = '42501';
    END IF;
    IF p_fk_tgrupo IS NULL OR p_fecha IS NULL THEN
        RAISE EXCEPTION 'grupo y fecha son obligatorios' USING ERRCODE = '23502';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM academico_test.TGRUPO
                    WHERE PK_TGRUPO = p_fk_tgrupo AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'grupo (%) no existe o no esta activo', p_fk_tgrupo USING ERRCODE = '23503';
    END IF;

    RETURN QUERY
    SELECT DISTINCT th.FK_TASIGNATURA, asig.NOMBRE, th.NUMERO_BLOQUE,
           franja.hora_inicio, franja.hora_fin
      FROM academico_test.TGRUPO gr
      JOIN academico_test.TGRADO g              ON g.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
      JOIN academico_test.THORARIO th ON th.FK_TGRUPO = gr.PK_TGRUPO AND th.ACTIVE = TRUE
      JOIN academico_test.TLISTA_VALOR dia
        ON dia.PK_LISTA_VALOR = th.FK_TLV_DIA_SEMANA
       AND dia.CATEGORIA = 'DIA_SEMANA'
       AND dia.VALOR = (EXTRACT(DOW FROM p_fecha)::INT + 1)::TEXT
      JOIN academico_test.TASIGNATURA asig ON asig.PK_TASIGNATURA = th.FK_TASIGNATURA
      CROSS JOIN LATERAL academico_test.fn_asistencia_franja_bloque(
          p_fecha, th.HORA_INICIO, th.HORA_FIN, pa.HORA_INICIO, pa.HORA_FIN) franja
     WHERE gr.PK_TGRUPO = p_fk_tgrupo AND gr.ACTIVE = TRUE
       AND (p_fk_tfuncionario IS NULL OR EXISTS (
               SELECT 1 FROM academico_test.TDOCENTE_ASIGNATURA da
                WHERE da.FK_TFUNCIONARIO = p_fk_tfuncionario
                  AND da.FK_TGRUPO       = th.FK_TGRUPO
                  AND da.FK_TASIGNATURA  = th.FK_TASIGNATURA
                  AND da.ACTIVE = TRUE))
     ORDER BY th.NUMERO_BLOQUE, asig.NOMBRE;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_asignaturas_sesion(
    BIGINT, BIGINT, DATE, BIGINT
) IS 'Pestanas por asignatura de "Asistencia manual": (asignatura, bloque, franja) que THORARIO tiene programadas para el grupo en el DIA DE SEMANA de p_fecha. p_fk_tfuncionario no NULL acota a TDOCENTE_ASIGNATURA. Gate: fn_asistencia_puede_ver. Copia identica de V220, redefinida aqui (V141) para trazabilidad.';
