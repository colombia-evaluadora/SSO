-- ===========================================================================
-- V486 - Fuentes estructuradas de las observaciones para ai-control-service
-- Que hace: expone como FILAS lo que V332 (periodo) y V435 (ano) concatenan,
--   mas el estado ya guardado, para que el modelo redacte el consolidado sin
--   pisar un texto que el docente modifico. Nucleo _interno + wrapper con gate.
-- Por que aqui: V332/V435 conservan su contrato; el front actual no cambia.
-- Depende de: V332 (fn_actividad_en_periodo_eval), V330/V435 (tablas),
--   V218 (TACTIVIDAD.FK_TASIGNATURA).
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 1. Periodo de evaluacion: observaciones por actividad.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_estudiante_periodo_observacion_fuentes_interno(
    p_fk_tmatricula          BIGINT,
    p_fk_tperiodo_evaluacion BIGINT
)
RETURNS TABLE(
    fecha       DATE,
    actividad   TEXT,
    asignatura  TEXT,
    observacion TEXT
)
LANGUAGE sql
STABLE
AS $function$
    SELECT COALESCE(a.FECHA_CIERRE, a.FECHA_INICIO, a.FECHA_CREACION::DATE),
           a.TITULO::TEXT,
           asg.NOMBRE::TEXT,
           TRIM(n.OBSERVACION)
      FROM academico_test.TACTIVIDAD a
      JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
        ON ae.FK_TACTIVIDAD = a.PK_TACTIVIDAD
       AND ae.FK_TMATRICULA = p_fk_tmatricula
       AND ae.ACTIVE = TRUE
      JOIN academico_test.TACTIVIDAD_NOTA n
        ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
       AND n.ACTIVE = TRUE
      LEFT JOIN academico_test.TASIGNATURA asg
        ON asg.PK_TASIGNATURA = a.FK_TASIGNATURA
     WHERE a.ACTIVE = TRUE
       AND NULLIF(TRIM(COALESCE(n.OBSERVACION, '')), '') IS NOT NULL
       AND academico_test.fn_actividad_en_periodo_eval(
               a.PK_TACTIVIDAD, p_fk_tperiodo_evaluacion) = TRUE
     ORDER BY 1, a.PK_TACTIVIDAD;
$function$;

COMMENT ON FUNCTION academico_test.fn_estudiante_periodo_observacion_fuentes_interno(BIGINT, BIGINT)
    IS 'INTERNO: las observaciones del docente de una matricula en un periodo de evaluacion, una fila por actividad y en orden cronologico, sin gate. Mismo criterio que fn_estudiante_periodo_observacion_generar (sin filtrar por asignatura ni CALIFICABLE). La reutiliza fn_estudiante_periodo_observacion_fuentes.';


CREATE OR REPLACE FUNCTION academico_test.fn_estudiante_periodo_observacion_fuentes(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tmatricula          BIGINT,
    p_fk_tperiodo_evaluacion BIGINT
)
RETURNS TABLE(
    fecha                 DATE,
    actividad             TEXT,
    asignatura            TEXT,
    observacion           TEXT,
    estudiante            TEXT,
    estado_guardado       TEXT,
    origen_guardado       NUMERIC
)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_fk_peraca  BIGINT;
    v_fk_sede    BIGINT;
    v_fk_jornada BIGINT;
    v_fk_ee      BIGINT;
    v_estudiante TEXT;
    v_pe_peraca  BIGINT;
    v_estado     TEXT;
    v_origen     NUMERIC;
BEGIN
    SELECT gd.FK_TPERIODO_ACADEMICO, s.PK_TSEDE, gr.FK_TLV_JORNADA,
           s.FK_TESTABLECIMIENTO, NULLIF(TRIM(u.PRIMER_NOMBRE), '')
      INTO v_fk_peraca, v_fk_sede, v_fk_jornada, v_fk_ee, v_estudiante
      FROM academico_test.TMATRICULA m
      JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = m.FK_TGRUPO
      JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa
        ON pa.PK_TPERIODO_ACADEMICO = gd.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
      LEFT JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
      LEFT JOIN academico_test.TUSUARIO u     ON u.PK_TUSUARIO     = es.FK_TUSUARIO
     WHERE m.PK_TMATRICULA = p_fk_tmatricula
       AND m.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la matricula solicitada'
            USING ERRCODE = 'P0002';
    END IF;

    SELECT pe.FK_TPERIODO_ACADEMICO
      INTO v_pe_peraca
      FROM academico_test.TPERIODO_EVALUACION pe
     WHERE pe.PK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion
       AND pe.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el periodo de evaluacion solicitado'
            USING ERRCODE = 'P0002';
    END IF;

    IF v_pe_peraca IS DISTINCT FROM v_fk_peraca THEN
        RAISE EXCEPTION 'El periodo de evaluacion no pertenece al periodo academico de la matricula'
            USING ERRCODE = '22023';
    END IF;

    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'INFORMES', 'VER',
        v_fk_ee, v_fk_sede, v_fk_jornada
    );

    SELECT lv.VALOR::TEXT, ob.OBSERVACIONES_ORIGEN
      INTO v_estado, v_origen
      FROM academico_test.TESTUDIANTE_PERIODO_OBSERVACION ob
      JOIN academico_test.TLISTA_VALOR lv
        ON lv.PK_LISTA_VALOR = ob.FK_TLV_ESTADO_OBSERVACION
     WHERE ob.FK_TMATRICULA = p_fk_tmatricula
       AND ob.FK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion
       AND ob.ACTIVE = TRUE;

    RETURN QUERY
    SELECT f.fecha, f.actividad, f.asignatura, f.observacion,
           v_estudiante, v_estado, v_origen
      FROM academico_test.fn_estudiante_periodo_observacion_fuentes_interno(
               p_fk_tmatricula, p_fk_tperiodo_evaluacion) f;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No hay observaciones del docente para resumir en ese periodo'
            USING ERRCODE = '22023';
    END IF;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_estudiante_periodo_observacion_fuentes(BIGINT, BIGINT, BIGINT)
    IS 'POST /informes/observacion/fuentes. Materia prima del resumen de periodo para ai-control-service: una fila por observacion (fecha, actividad, asignatura, texto) mas el primer nombre del estudiante y el estado/origen del resumen ya guardado (NULL si no hay). El nombre NO se envia al modelo; lo reinserta el servicio. Errores iguales a fn_estudiante_periodo_observacion_generar: P0002 matricula/periodo, 22023 periodo de otro ano o sin observaciones. Gate INFORMES/VER.';


-- ---------------------------------------------------------------------------
-- 2. Ano: resumenes de periodo ya guardados.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_estudiante_anio_observacion_fuentes_interno(
    p_fk_tmatricula BIGINT
)
RETURNS TABLE(
    periodo      TEXT,
    fecha_inicio DATE,
    fecha_fin    DATE,
    observacion  TEXT
)
LANGUAGE sql
STABLE
AS $function$
    SELECT pe.NOMBRE::TEXT, pe.FECHA_INICIO::DATE, pe.FECHA_FIN::DATE,
           TRIM(ob.OBSERVACION)
      FROM academico_test.TMATRICULA m
      JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = m.FK_TGRUPO
      JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TESTUDIANTE_PERIODO_OBSERVACION ob
        ON ob.FK_TMATRICULA = m.PK_TMATRICULA
       AND ob.ACTIVE = TRUE
      JOIN academico_test.TPERIODO_EVALUACION pe
        ON pe.PK_TPERIODO_EVALUACION = ob.FK_TPERIODO_EVALUACION
       AND pe.ACTIVE = TRUE
       AND pe.FK_TPERIODO_ACADEMICO = gd.FK_TPERIODO_ACADEMICO
     WHERE m.PK_TMATRICULA = p_fk_tmatricula
       AND NULLIF(TRIM(COALESCE(ob.OBSERVACION, '')), '') IS NOT NULL
     ORDER BY pe.FECHA_INICIO, pe.PK_TPERIODO_EVALUACION;
$function$;

COMMENT ON FUNCTION academico_test.fn_estudiante_anio_observacion_fuentes_interno(BIGINT)
    IS 'INTERNO: los resumenes de periodo guardados de una matricula dentro de su periodo academico, en orden, sin gate. Mismo criterio que fn_estudiante_final_observacion. La reutiliza fn_estudiante_anio_observacion_fuentes.';


CREATE OR REPLACE FUNCTION academico_test.fn_estudiante_anio_observacion_fuentes(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tmatricula          BIGINT
)
RETURNS TABLE(
    periodo          TEXT,
    fecha_inicio     DATE,
    fecha_fin        DATE,
    observacion      TEXT,
    estudiante       TEXT,
    estado_guardado  TEXT,
    origen_guardado  NUMERIC
)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_fk_sede    BIGINT;
    v_fk_jornada BIGINT;
    v_fk_ee      BIGINT;
    v_estudiante TEXT;
    v_estado     TEXT;
    v_origen     NUMERIC;
BEGIN
    SELECT s.PK_TSEDE, gr.FK_TLV_JORNADA, s.FK_TESTABLECIMIENTO,
           NULLIF(TRIM(u.PRIMER_NOMBRE), '')
      INTO v_fk_sede, v_fk_jornada, v_fk_ee, v_estudiante
      FROM academico_test.TMATRICULA m
      JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = m.FK_TGRUPO
      JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa
        ON pa.PK_TPERIODO_ACADEMICO = gd.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
      LEFT JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
      LEFT JOIN academico_test.TUSUARIO u     ON u.PK_TUSUARIO     = es.FK_TUSUARIO
     WHERE m.PK_TMATRICULA = p_fk_tmatricula
       AND m.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la matricula solicitada'
            USING ERRCODE = 'P0002';
    END IF;

    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'INFORMES', 'VER',
        v_fk_ee, v_fk_sede, v_fk_jornada
    );

    SELECT lv.VALOR::TEXT, ob.PERIODOS_ORIGEN
      INTO v_estado, v_origen
      FROM academico_test.TESTUDIANTE_ANIO_OBSERVACION ob
      JOIN academico_test.TLISTA_VALOR lv
        ON lv.PK_LISTA_VALOR = ob.FK_TLV_ESTADO_OBSERVACION
     WHERE ob.FK_TMATRICULA = p_fk_tmatricula
       AND ob.ACTIVE = TRUE;

    RETURN QUERY
    SELECT f.periodo, f.fecha_inicio, f.fecha_fin, f.observacion,
           v_estudiante, v_estado, v_origen
      FROM academico_test.fn_estudiante_anio_observacion_fuentes_interno(p_fk_tmatricula) f;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El estudiante no tiene resumenes de periodo guardados para consolidar'
            USING ERRCODE = '22023';
    END IF;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_estudiante_anio_observacion_fuentes(BIGINT, BIGINT)
    IS 'POST /informes/observacion/final/fuentes. Materia prima del consolidado del ano para ai-control-service: una fila por resumen de periodo guardado mas el primer nombre del estudiante y el estado/origen del texto anual ya guardado (NULL si no hay). Errores: P0002 matricula, 22023 sin resumenes de periodo. Gate INFORMES/VER.';


-- ---------------------------------------------------------------------------
-- 3. Endpoints (execution_mode SELECT: no escriben).
-- ---------------------------------------------------------------------------
DELETE FROM public.role_query
 WHERE query_id IN (SELECT id_query FROM public.query WHERE uuid = 'eval-col-informes-observacion-fuentes-001');
DELETE FROM public.query WHERE uuid = 'eval-col-informes-observacion-fuentes-001';

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action, style)
SELECT
    'eval-col-informes-observacion-fuentes-001',
    'SELECT * FROM academico_test.fn_estudiante_periodo_observacion_fuentes(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FK_TMATRICULA AS BIGINT),
    CAST(:BODY.FK_TPERIODO_EVALUACION AS BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/informes/observacion/fuentes', 'SELECT', 'POST',
    '{"BODY.FK_TMATRICULA": "BIGINT", "BODY.FK_TPERIODO_EVALUACION": "BIGINT"}'::jsonb,
    NULL,
    'Observaciones del docente de un estudiante en un periodo, una fila por actividad (fecha, actividad, asignatura, observacion), con el primer nombre del estudiante y el estado/origen del resumen ya guardado. Lo consume ai-control-service para redactar el resumen con el modelo. No escribe. Errores: 404 matricula o periodo inexistente; 400 periodo de otro ano o sin observaciones.',
    'informes-observacion-fuentes', 'DEFAULT'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

DELETE FROM public.role_query
 WHERE query_id IN (SELECT id_query FROM public.query WHERE uuid = 'eval-col-informes-observacion-final-fuentes-001');
DELETE FROM public.query WHERE uuid = 'eval-col-informes-observacion-final-fuentes-001';

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action, style)
SELECT
    'eval-col-informes-observacion-final-fuentes-001',
    'SELECT * FROM academico_test.fn_estudiante_anio_observacion_fuentes(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FK_TMATRICULA AS BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/informes/observacion/final/fuentes', 'SELECT', 'POST',
    '{"BODY.FK_TMATRICULA": "BIGINT"}'::jsonb,
    NULL,
    'Resumenes de periodo guardados de un estudiante, una fila por periodo, con el primer nombre del estudiante y el estado/origen del texto anual ya guardado. Lo consume ai-control-service para redactar el consolidado del ano. No escribe. Errores: 404 matricula inexistente; 400 sin resumenes de periodo.',
    'informes-observacion-final-fuentes', 'DEFAULT'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;


-- ---------------------------------------------------------------------------
-- 4. Roles: los mismos del endpoint que cada uno alimenta.
-- ---------------------------------------------------------------------------
INSERT INTO public.role_query (role_id, query_id)
SELECT rq.role_id, dst.id_query
  FROM public.query src
  JOIN public.microservice m ON m.id_microservice = src.microservice_id
  JOIN public.role_query rq  ON rq.query_id = src.id_query
  JOIN public.query dst
    ON dst.microservice_id = src.microservice_id
   AND dst.http_method     = 'POST'
   AND dst.path_template   = CASE src.path_template
                                 WHEN '/informes/observacion/generar' THEN '/informes/observacion/fuentes'
                                 WHEN '/informes/observacion/final'   THEN '/informes/observacion/final/fuentes'
                             END
 WHERE m.serviceid       = 'eval-col'
   AND src.http_method   = 'POST'
   AND src.path_template IN ('/informes/observacion/generar', '/informes/observacion/final')
ON CONFLICT DO NOTHING;
