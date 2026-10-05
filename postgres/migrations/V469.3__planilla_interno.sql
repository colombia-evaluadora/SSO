-- V469.3 — Planilla de calificación: núcleos _interno sin permisos (3 de 5).
--
-- Qué hace: el periodo de evaluación de la planilla (pedido o por defecto),
-- el universo de columnas acotado a ese periodo con la misma regla de la
-- definitiva proyectada, y las tres lecturas: header, celdas por matrícula y
-- cortes de un periodo académico. Reciben los ids ya resueltos y no saben de
-- permisos: los reutilizan los wrappers de V469.4.
-- Antes en V239, V254, V454 y V469.
-- Depende de: V469.2, V332 (fn_actividad_en_periodo_eval), V333 (definitiva
-- por periodo), V428 (fn_nota_homologar), V496.6 (resultado del instrumento).

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_planilla_periodo_eval_resolver(
    p_fk_tgrupo              BIGINT,
    p_fk_tperiodo_evaluacion BIGINT DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_pe BIGINT;
BEGIN
    IF p_fk_tperiodo_evaluacion IS NOT NULL THEN
        PERFORM academico_test.fn_planilla_validar_periodo_del_grupo(
            p_fk_tgrupo, p_fk_tperiodo_evaluacion);
        RETURN p_fk_tperiodo_evaluacion;
    END IF;

    -- Sin periodo pedido: el que contiene hoy; si no, el ultimo cerrado; si
    -- el año aun no empieza, el primero.
    SELECT pe.PK_TPERIODO_EVALUACION INTO v_pe
      FROM academico_test.TPERIODO_EVALUACION pe
     WHERE pe.FK_TPERIODO_ACADEMICO = academico_test.fn_grupo_periodo(p_fk_tgrupo)
       AND pe.ACTIVE = TRUE
     ORDER BY (CURRENT_DATE BETWEEN pe.FECHA_INICIO AND pe.FECHA_FIN) DESC,
              (pe.FECHA_FIN < CURRENT_DATE) DESC,
              CASE WHEN pe.FECHA_FIN < CURRENT_DATE THEN pe.FECHA_FIN END DESC NULLS LAST,
              pe.FECHA_INICIO,
              pe.PK_TPERIODO_EVALUACION
     LIMIT 1;
    RETURN v_pe;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_planilla_periodo_eval_resolver(BIGINT, BIGINT)
    IS 'INTERNO: periodo de evaluacion de la planilla de un grupo. El pedido, validado con fn_planilla_validar_periodo_del_grupo; sin el, el que contiene hoy, si no el ultimo cerrado, si no el primero. Lo comparten el header y las celdas para que columnas, celdas y definitiva hablen del mismo periodo.';

-- La firma de 5 parametros (sin periodo) quedo atras.
DROP FUNCTION IF EXISTS academico_test.fn_planilla_actividades_universo(BIGINT, BIGINT, DATE, DATE, VARCHAR);

CREATE OR REPLACE FUNCTION academico_test.fn_planilla_actividades_universo(
    p_fk_tgrupo              BIGINT,
    p_fk_tasignatura         BIGINT,
    p_fecha_desde            DATE    DEFAULT NULL,
    p_fecha_hasta            DATE    DEFAULT NULL,
    p_search_actividad       VARCHAR DEFAULT NULL,
    p_fk_tperiodo_evaluacion BIGINT  DEFAULT NULL
)
RETURNS TABLE (
    orden_columna   INT,
    pk_tactividad   BIGINT,
    fk_tunidad      BIGINT
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT ROW_NUMBER() OVER (
               ORDER BY u.NOMBRE NULLS LAST,
                        a.FK_TUNIDAD NULLS LAST,
                        a.FECHA_INICIO NULLS LAST,
                        a.PK_TACTIVIDAD
           )::INT,
           a.PK_TACTIVIDAD,
           a.FK_TUNIDAD
      FROM academico_test.TACTIVIDAD a
      LEFT JOIN academico_test.TUNIDAD u ON u.PK_TUNIDAD = a.FK_TUNIDAD
     WHERE a.ACTIVE = TRUE
       AND a.FK_TASIGNATURA = p_fk_tasignatura
       -- Las del grupo, mas las sin grupo con algun estudiante de este grupo.
       AND (a.FK_TGRUPO = p_fk_tgrupo
            OR (a.FK_TGRUPO IS NULL AND EXISTS (
                    SELECT 1
                      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
                      JOIN academico_test.TMATRICULA m ON m.PK_TMATRICULA = ae.FK_TMATRICULA
                     WHERE ae.FK_TACTIVIDAD = a.PK_TACTIVIDAD
                       AND ae.ACTIVE = TRUE
                       AND m.FK_TGRUPO = p_fk_tgrupo)))
       -- El periodo con la misma regla que la definitiva proyectada: una
       -- actividad que cruza dos cortes aparece solo en el que la cierra.
       AND (p_fk_tperiodo_evaluacion IS NULL
            OR academico_test.fn_actividad_en_periodo_eval(a.PK_TACTIVIDAD, p_fk_tperiodo_evaluacion))
       AND (p_fecha_desde IS NULL OR COALESCE(a.FECHA_CIERRE, a.FECHA_INICIO) >= p_fecha_desde)
       AND (p_fecha_hasta IS NULL OR COALESCE(a.FECHA_INICIO, a.FECHA_CIERRE) <= p_fecha_hasta)
       AND (p_search_actividad IS NULL
            OR TRIM(p_search_actividad) = ''
            OR (COALESCE(a.TITULO, '') || ' ' || COALESCE(a.DESCRIPCION, ''))
                   ILIKE '%' || TRIM(p_search_actividad) || '%');
END;
$$;

COMMENT ON FUNCTION academico_test.fn_planilla_actividades_universo(BIGINT, BIGINT, DATE, DATE, VARCHAR, BIGINT)
    IS 'INTERNO: definicion UNICA de las COLUMNAS de la "Planilla de calificacion" y de su orden. Actividades ACTIVE de la asignatura del grupo, mas las sin grupo con algun estudiante del grupo asignado. Con p_fk_tperiodo_evaluacion se queda con las del periodo segun fn_actividad_en_periodo_eval, la misma regla de fn_asignatura_definitiva_proyectada_periodo, para que una columna visible siempre sume en la definitiva mostrada. Ademas ventana de fechas (solapamiento) y texto sobre TITULO+DESCRIPCION. orden_columna agrupa las actividades de una unidad contiguas (NOMBRE de unidad -> FECHA_INICIO -> PK). La usan fn_planilla_columnas_listar y fn_planilla_calificaciones_listar.';

CREATE OR REPLACE FUNCTION academico_test.fn_planilla_columnas_listar_interno(
    p_fk_tgrupo              BIGINT,
    p_fk_tasignatura         BIGINT,
    p_fk_tperiodo_evaluacion BIGINT,
    p_fecha_desde            DATE    DEFAULT NULL,
    p_fecha_hasta            DATE    DEFAULT NULL,
    p_search_actividad       VARCHAR DEFAULT NULL
)
RETURNS TABLE (
    orden_columna                  INTEGER,
    pk_tactividad                  BIGINT,
    titulo                         VARCHAR,
    fk_tunidad                     BIGINT,
    unidad                         VARCHAR,
    fk_tlv_instrumento_evaluacion  BIGINT,
    instrumento                    VARCHAR,
    instrumento_nombre             VARCHAR,
    metodo_valoracion              VARCHAR,
    ponderacion                    NUMERIC,
    nota_maxima                    NUMERIC,
    es_evaluativa                  VARCHAR,
    es_formativa                   BOOLEAN,
    fecha_inicio                   DATE,
    fecha_cierre                   DATE,
    estudiantes_asignados          BIGINT,
    estudiantes_calificados        BIGINT,
    pk_tperiodo_evaluacion         BIGINT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_pe BIGINT := p_fk_tperiodo_evaluacion;
BEGIN
    RETURN QUERY
    SELECT uni.orden_columna,
           a.PK_TACTIVIDAD,
           a.TITULO,
           a.FK_TUNIDAD,
           u.NOMBRE,
           a.FK_TLV_INSTRUMENTO_EVALUACION,
           lvi.VALOR::VARCHAR,
           lvi.NOMBRE::VARCHAR,
           CASE WHEN lvi.VALOR = 'OTRO'
                THEN academico_test.fn_actividad_otro_metodo_valoracion(a.PK_TACTIVIDAD)
           END::VARCHAR,
           a.PONDERACION,
           a.NOTA_MAXIMA,
           a.ES_EVALUATIVA::VARCHAR,
           academico_test.fn_actividad_es_formativa(a.PK_TACTIVIDAD),
           a.FECHA_INICIO,
           a.FECHA_CIERRE,
           prog.asignados,
           prog.calificados,
           v_pe
      FROM academico_test.fn_planilla_actividades_universo(
               p_fk_tgrupo, p_fk_tasignatura, p_fecha_desde, p_fecha_hasta, p_search_actividad, v_pe
           ) uni
      JOIN academico_test.TACTIVIDAD a ON a.PK_TACTIVIDAD = uni.pk_tactividad
      LEFT JOIN academico_test.TUNIDAD u        ON u.PK_TUNIDAD = a.FK_TUNIDAD
      LEFT JOIN academico_test.TLISTA_VALOR lvi ON lvi.PK_LISTA_VALOR = a.FK_TLV_INSTRUMENTO_EVALUACION
      LEFT JOIN LATERAL (
          SELECT COUNT(*)::BIGINT AS asignados,
                 COUNT(*) FILTER (
                     WHERE n.PK_TACTIVIDAD_NOTA IS NOT NULL
                       AND ( COALESCE(n.DEFINITIVA, n.CALIFICACION) IS NOT NULL
                        OR (n.CALIFICABLE = 'N' AND NULLIF(TRIM(n.OBSERVACION), '') IS NOT NULL) )
                 )::BIGINT AS calificados
            FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
            JOIN academico_test.TMATRICULA m ON m.PK_TMATRICULA = ae.FK_TMATRICULA
            LEFT JOIN academico_test.TACTIVIDAD_NOTA n
                   ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                  AND n.ACTIVE = TRUE
           WHERE ae.FK_TACTIVIDAD = a.PK_TACTIVIDAD
             AND ae.ACTIVE = TRUE
             AND m.FK_TGRUPO = p_fk_tgrupo
      ) prog ON TRUE
     ORDER BY uni.orden_columna;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_planilla_columnas_listar_interno(BIGINT, BIGINT, BIGINT, DATE, DATE, VARCHAR)
    IS 'INTERNO: header de la planilla para un periodo ya resuelto: una fila por actividad-columna del (grupo, asignatura) en el periodo, en el orden de fn_planilla_actividades_universo, con unidad, instrumento (y metodo si es OTRO), PONDERACION/NOTA_MAXIMA, ES_EVALUATIVA, es_formativa, fechas y progreso de ESE grupo (calificado = con nota o con OBSERVACION y CALIFICABLE = N). Lo usa fn_planilla_columnas_listar.';

-- Cambia el tipo de retorno: CREATE OR REPLACE no basta.
DROP FUNCTION IF EXISTS academico_test.fn_planilla_calificaciones_listar_interno(BIGINT, BIGINT, BIGINT, DATE, DATE, VARCHAR, VARCHAR, INT, INT);

CREATE OR REPLACE FUNCTION academico_test.fn_planilla_calificaciones_listar_interno(
    p_fk_tgrupo              BIGINT,
    p_fk_tasignatura         BIGINT,
    p_fk_tperiodo_evaluacion BIGINT,
    p_fecha_desde            DATE    DEFAULT NULL,
    p_fecha_hasta            DATE    DEFAULT NULL,
    p_search_actividad       VARCHAR DEFAULT NULL,
    p_search_estudiante      VARCHAR DEFAULT NULL,
    p_limite                 INT     DEFAULT 50,
    p_offset                 INT     DEFAULT 0
)
RETURNS TABLE (
    pk_tmatricula                    BIGINT,
    pk_testudiante                   BIGINT,
    nombre_estudiante                VARCHAR,
    definitiva_proyectada            NUMERIC,
    definitiva_registrada            NUMERIC,
    tendencia                        VARCHAR,
    celdas                           JSONB,
    total_count                      BIGINT,
    pk_tperiodo_evaluacion           BIGINT,
    definitiva_proyectada_homologada NUMERIC,
    definitiva_registrada_homologada NUMERIC,
    formato_valor                    VARCHAR,
    nota_maxima                      NUMERIC,
    es_numerico                      BOOLEAN,
    definitiva_propuesta_homologada  NUMERIC
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_pe        BIGINT := p_fk_tperiodo_evaluacion;
    v_fk_tgrado BIGINT;
BEGIN
    SELECT gr.FK_TGRADO INTO v_fk_tgrado
      FROM academico_test.TGRUPO gr WHERE gr.PK_TGRUPO = p_fk_tgrupo;

    RETURN QUERY
    WITH columnas AS MATERIALIZED (
        SELECT uni.orden_columna,
               uni.pk_tactividad,
               uni.fk_tunidad,
               a.FK_TASIGNATURA AS fk_tasignatura,
               a.FECHA_INICIO   AS fecha_inicio,
               a.FECHA_CIERRE   AS fecha_cierre,
               academico_test.fn_actividad_es_formativa(uni.pk_tactividad) AS es_formativa
          FROM academico_test.fn_planilla_actividades_universo(
                   p_fk_tgrupo, p_fk_tasignatura, p_fecha_desde, p_fecha_hasta, p_search_actividad, v_pe
               ) uni
          JOIN academico_test.TACTIVIDAD a ON a.PK_TACTIVIDAD = uni.pk_tactividad
    ),
    base AS (
        SELECT m.PK_TMATRICULA,
               es.PK_TESTUDIANTE,
               NULLIF(TRIM(CONCAT_WS(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
                                          u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO)), '')::VARCHAR AS nombre,
               COUNT(*) OVER() AS total
          FROM academico_test.TMATRICULA m
          JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
          JOIN academico_test.TUSUARIO u     ON u.PK_TUSUARIO = es.FK_TUSUARIO
         WHERE m.FK_TGRUPO = p_fk_tgrupo
           AND m.ACTIVE = TRUE
           AND (p_search_estudiante IS NULL
                OR TRIM(p_search_estudiante) = ''
                OR TRIM(CONCAT_WS(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
                                       u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO))
                       ILIKE '%' || TRIM(p_search_estudiante) || '%')
         ORDER BY NULLIF(TRIM(CONCAT_WS(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
                                             u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO)), ''),
                  m.PK_TMATRICULA
         LIMIT GREATEST(p_limite, 1)
        OFFSET GREATEST(p_offset, 0)
    )
    SELECT b.PK_TMATRICULA,
           b.PK_TESTUDIANTE,
           b.nombre,
           def.proyectada,
           reg.registrada,
           CASE
               WHEN def.proyectada IS NULL OR reg.registrada IS NULL THEN NULL
               WHEN def.proyectada > reg.registrada THEN 'SUBE'
               WHEN def.proyectada < reg.registrada THEN 'BAJA'
               ELSE 'IGUAL'
           END::VARCHAR,
           COALESCE(cel.celdas, '[]'::jsonb),
           b.total,
           v_pe,
           hp.nota_homologada,
           hr.nota_homologada,
           hv.formato_valor,
           hv.nota_maxima,
           COALESCE(hv.formato_valor IN ('CINCO', 'DIEZ', 'CIEN'), FALSE),
           hpr.nota_homologada
      FROM base b
      LEFT JOIN LATERAL (
          SELECT academico_test.fn_asignatura_definitiva_proyectada_periodo(
                     b.PK_TMATRICULA, p_fk_tasignatura, v_pe) AS proyectada
      ) def ON TRUE
      -- Registrada = la definitiva consolidada del periodo (TASIGNATURA_NOTA,
      -- lo que escribe /informes/planilla/guardar); antes leia TUNIDAD_NOTA,
      -- que nada escribe, y la tendencia salia siempre NULL.
      LEFT JOIN LATERAL (
          SELECT sn.DEFINITIVA AS registrada
            FROM academico_test.TASIGNATURA_NOTA sn
           WHERE sn.FK_TMATRICULA = b.PK_TMATRICULA
             AND sn.FK_TASIGNATURA = p_fk_tasignatura
             AND sn.FK_TPERIODO_EVALUACION = v_pe
             AND sn.ACTIVE = TRUE
           LIMIT 1
      ) reg ON TRUE
      LEFT JOIN LATERAL academico_test.fn_nota_homologar(def.proyectada, p_fk_tasignatura, v_fk_tgrado) hp ON TRUE
      LEFT JOIN LATERAL academico_test.fn_nota_homologar(reg.registrada, p_fk_tasignatura, v_fk_tgrado) hr ON TRUE
      LEFT JOIN LATERAL academico_test.fn_nota_homologar(COALESCE(reg.registrada, def.proyectada), p_fk_tasignatura, v_fk_tgrado) hv ON TRUE
      -- Definitiva con las correcciones pendientes (Regla 55); solo si hay alguna.
      LEFT JOIN LATERAL (
          SELECT academico_test.fn_asignatura_definitiva_proyectada_periodo(
                     b.PK_TMATRICULA, p_fk_tasignatura, v_pe, TRUE) AS propuesta
           WHERE EXISTS (
                     SELECT 1
                       FROM academico_test.TSOLICITUD_APROBACION s
                       JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae2
                         ON ae2.PK_TACTIVIDAD_ESTUDIANTE = s.FK_OBJETO
                      WHERE s.TABLA_OBJETO = 'TACTIVIDAD_ESTUDIANTE'
                        AND ae2.FK_TMATRICULA = b.PK_TMATRICULA
                        AND s.FK_TASIGNATURA = p_fk_tasignatura
                        AND s.FK_TPERIODO_EVALUACION = v_pe
                        AND s.FK_TLV_TIPO = academico_test.fn_tlv_solicitud_tipo_pk('CORRECCION_RESULTADO')
                        AND s.FK_TLV_ESTADO = academico_test.fn_tlv_solicitud_estado_pk('PENDIENTE')
                        AND s.ACTIVE = TRUE)
      ) prop ON TRUE
      LEFT JOIN LATERAL academico_test.fn_nota_homologar(prop.propuesta, p_fk_tasignatura, v_fk_tgrado) hpr ON TRUE
      LEFT JOIN LATERAL (
          SELECT jsonb_agg(jsonb_build_object(
                     'ordenColumna',            c.orden_columna,
                     'pkTactividad',            c.pk_tactividad,
                     'pkTunidad',               c.fk_tunidad,
                     'pkTactividadEstudiante',  ae.PK_TACTIVIDAD_ESTUDIANTE,
                     'esFormativa',             c.es_formativa,
                     'estado',
                         CASE
                             WHEN ae.PK_TACTIVIDAD_ESTUDIANTE IS NULL          THEN 'NO_ASIGNADA'
                             WHEN COALESCE(n.CALIFICABLE, 'S') = 'N'           THEN 'NO_CALIFICABLE'
                             WHEN COALESCE(n.DEFINITIVA, n.CALIFICACION) IS NULL THEN 'SIN_CALIFICAR'
                             ELSE 'CALIFICADA'
                         END,
                     'calificacion',  n.CALIFICACION,
                     'recuperacion',  n.RECUPERACION,
                     'definitiva',    n.DEFINITIVA,
                     'nota',          COALESCE(n.DEFINITIVA, n.CALIFICACION),
                     'notaHomologada', hc.nota_homologada,
                     'valoracion',    hc.valoracion_nombre,
                     'resultadoInstrumento',
                         academico_test.fn_actividad_nota_resultado_instrumento(ae.PK_TACTIVIDAD_ESTUDIANTE),
                     'calificable',   n.CALIFICABLE,
                     'observacion',   n.OBSERVACION,
                     'fechaAsistencia', asi.fecha,
                     'tieneAsistencia', (asi.fecha IS NOT NULL),
                     'estadoResultado',
                         CASE
                             WHEN ae.PK_TACTIVIDAD_ESTUDIANTE IS NULL             THEN NULL
                             WHEN lve.VALOR IS NOT NULL                           THEN lve.VALOR
                             WHEN COALESCE(n.DEFINITIVA, n.CALIFICACION) IS NOT NULL THEN 'CALIFICADO'
                             WHEN sa.ausente AND sa.justificada                   THEN 'NO_ASISTIO_JUSTIFICADA'
                             WHEN sa.ausente                                      THEN 'NO_ASISTIO_NO_JUSTIFICADA'
                             ELSE 'PENDIENTE'
                         END,
                     -- Regla 55: corrección pendiente de aprobación y su nota propuesta.
                     'solicitudPendiente',      (sp.pk IS NOT NULL),
                     'notaPropuestaHomologada', hpp.nota_homologada,
                     'calificacionPropuesta',   sp.calificacion,
                     'evidencias',    COALESCE(ev.evidencias, '[]'::jsonb))
                     ORDER BY c.orden_columna) AS celdas
            FROM columnas c
            LEFT JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
                   ON ae.FK_TACTIVIDAD = c.pk_tactividad
                  AND ae.FK_TMATRICULA = b.PK_TMATRICULA
                  AND ae.ACTIVE = TRUE
            LEFT JOIN academico_test.TACTIVIDAD_NOTA n
                   ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                  AND n.ACTIVE = TRUE
            LEFT JOIN LATERAL academico_test.fn_nota_homologar(
                          COALESCE(n.DEFINITIVA, n.CALIFICACION), p_fk_tasignatura, v_fk_tgrado) hc ON TRUE
            -- Estado del resultado y asistencia de la actividad.
            LEFT JOIN academico_test.TLISTA_VALOR lve
                   ON lve.PK_LISTA_VALOR = n.FK_TLV_ESTADO_RESULTADO
            LEFT JOIN LATERAL academico_test.fn_actividad_asistencia_estudiante(
                          ae.PK_TACTIVIDAD_ESTUDIANTE) sa ON ae.PK_TACTIVIDAD_ESTUDIANTE IS NOT NULL
            LEFT JOIN LATERAL (
                SELECT s.PK_TSOLICITUD_APROBACION AS pk,
                       (s.VALOR_PROPUESTO->>'porcentaje')::NUMERIC AS porcentaje,
                       -- Solo una captura completa (CALIFICAR) sirve para precargar el form;
                       -- las de bloque son de un criterio o elemento.
                       CASE WHEN s.VALOR_PROPUESTO->'capturas'->-1->>'operacion' = 'CALIFICAR'
                            THEN s.VALOR_PROPUESTO->'capturas'->-1->'calificacion' END AS calificacion
                  FROM academico_test.TSOLICITUD_APROBACION s
                 WHERE s.TABLA_OBJETO = 'TACTIVIDAD_ESTUDIANTE'
                   AND s.FK_OBJETO = ae.PK_TACTIVIDAD_ESTUDIANTE
                   AND s.FK_TLV_TIPO = academico_test.fn_tlv_solicitud_tipo_pk('CORRECCION_RESULTADO')
                   AND s.FK_TLV_ESTADO = academico_test.fn_tlv_solicitud_estado_pk('PENDIENTE')
                   AND s.ACTIVE = TRUE
                 LIMIT 1
            ) sp ON ae.PK_TACTIVIDAD_ESTUDIANTE IS NOT NULL
            LEFT JOIN LATERAL academico_test.fn_nota_homologar(
                          sp.porcentaje, p_fk_tasignatura, v_fk_tgrado) hpp ON TRUE
            LEFT JOIN LATERAL (
                SELECT academico_test.fn_actividad_asistencia_fecha_resolver(
                           b.PK_TMATRICULA, c.pk_tactividad) AS fecha
            ) asi ON ae.PK_TACTIVIDAD_ESTUDIANTE IS NOT NULL
            LEFT JOIN LATERAL (
                SELECT jsonb_agg(jsonb_build_object(
                           'pk',         so.PK_TACTIVIDAD_SOPORTE,
                           'fkTarchivo', so.FK_TARCHIVO,
                           'nombre',     ar.NOMBRE,
                           'fecha',      so.FECHA)
                           ORDER BY so.PK_TACTIVIDAD_SOPORTE) AS evidencias
                  FROM academico_test.TACTIVIDAD_SOPORTE so
                  LEFT JOIN academico_test.TARCHIVO ar ON ar.PK_TARCHIVO = so.FK_TARCHIVO
                 WHERE so.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                   AND so.ACTIVE = TRUE
                   AND so.FK_TARCHIVO IS NOT NULL
            ) ev ON c.es_formativa AND ae.PK_TACTIVIDAD_ESTUDIANTE IS NOT NULL
      ) cel ON TRUE
     ORDER BY b.nombre, b.PK_TMATRICULA;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_planilla_calificaciones_listar_interno(BIGINT, BIGINT, BIGINT, DATE, DATE, VARCHAR, VARCHAR, INT, INT)
    IS 'INTERNO: celdas de la planilla para un periodo ya resuelto: una fila por matricula del grupo con definitiva_proyectada (fn_asignatura_definitiva_proyectada_periodo) y definitiva_registrada (TASIGNATURA_NOTA) del periodo, tendencia, homologaciones al formato de la asignatura y definitiva_propuesta_homologada (la proyectada con las correcciones pendientes, solo si hay alguna) y una celda por actividad del periodo (mismo universo y orden que el header), con estadoResultado como en la tabla de calificaciones del Planeador, y solicitudPendiente / notaPropuestaHomologada / calificacionPropuesta (el body de calificar) cuando hay una corrección CORRECCION_RESULTADO pendiente (Regla 55). Lo usa fn_planilla_calificaciones_listar.';

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_evaluacion_listar_interno(
    p_fk_tperiodo_academico BIGINT,
    p_fk_tlv_estado         BIGINT DEFAULT NULL
)
RETURNS TABLE (
    pk_tperiodo_evaluacion  BIGINT,
    codigo                  VARCHAR,
    nombre                  VARCHAR,
    abreviacion             VARCHAR,
    fecha_inicio            DATE,
    fecha_fin               DATE,
    porcentaje              NUMERIC,
    vigente_hoy             BOOLEAN,
    fk_tlv_estado           BIGINT,
    estado_valor            VARCHAR,
    estado_nombre           VARCHAR,
    fk_tperiodo_academico   BIGINT,
    periodo_academico       VARCHAR
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT pe.PK_TPERIODO_EVALUACION,
           pe.CODIGO,
           pe.NOMBRE,
           pe.ABREVIACION,
           pe.FECHA_INICIO,
           pe.FECHA_FIN,
           pe.PORCENTAJE,
           (CURRENT_DATE BETWEEN pe.FECHA_INICIO AND pe.FECHA_FIN),
           pe.FK_TLV_ESTADO,
           lv.VALOR,
           lv.NOMBRE,
           pe.FK_TPERIODO_ACADEMICO,
           pa.NOMBRE
      FROM academico_test.TPERIODO_EVALUACION pe
      JOIN academico_test.TPERIODO_ACADEMICO pa
        ON pa.PK_TPERIODO_ACADEMICO = pe.FK_TPERIODO_ACADEMICO
      LEFT JOIN academico_test.TLISTA_VALOR lv
        ON lv.PK_LISTA_VALOR = pe.FK_TLV_ESTADO
     WHERE pe.ACTIVE = TRUE
       AND pe.FK_TPERIODO_ACADEMICO = p_fk_tperiodo_academico
       AND (p_fk_tlv_estado IS NULL OR pe.FK_TLV_ESTADO = p_fk_tlv_estado)
     ORDER BY pe.FECHA_INICIO, pe.PK_TPERIODO_EVALUACION;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_evaluacion_listar_interno(BIGINT, BIGINT)
    IS 'INTERNO: todos los periodos de evaluacion ACTIVE de un periodo academico, de los cuatro estados de ESTADOPERIODOEVALUACION (no hay uno llamado "activo"; cada fila trae estado_valor/estado_nombre), con vigente_hoy derivado. p_fk_tlv_estado acota a uno. Lo usa fn_periodo_evaluacion_listar.';
