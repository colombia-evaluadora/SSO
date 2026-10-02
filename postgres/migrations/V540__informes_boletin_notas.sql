-- V540 — Informes: boletín de notas del periodo (Evaluativo), por capas.
--
-- Qué hace: (1) núcleos compartidos de los boletines -- encabezado
-- institucional, foto y firma del rector, sacados del de preescolar para que
-- los dos impriman lo mismo --; (2) el núcleo del boletín de notas: una fila
-- por (estudiante, asignatura) de los estudiantes con el periodo consolidado
-- (Regla 81), con la nota resultante y, si hubo Habilitación, la original
-- (Regla 68); (3) su wrapper con gate; (4) el endpoint.
-- Por qué aquí: módulo de boletines; un cambio futuro edita esta migración.
-- Depende de: V535, V536 (fn_informe_grupo_listar_interno), V466 (catálogos).

-- ============================================================ núcleos
CREATE OR REPLACE FUNCTION academico_test.fn_informe_boletin_cabecera_interno(
    p_fk_tgrupo BIGINT
)
RETURNS TABLE(ee_nombre character varying, ee_dane character varying, ee_nit character varying,
              ciudad character varying, sede_nombre character varying, nivel_ensenanza character varying,
              grado_nombre character varying, grupo_etiqueta character varying, anio integer,
              fondo_archivo bigint, pk_ee bigint, pk_sede bigint)
LANGUAGE sql
STABLE
AS $function$
    SELECT ee.NOMBRE::VARCHAR, ee.CODIGO::VARCHAR, ee.NIT::VARCHAR, mun.NOMBRE::VARCHAR,
           s.NOMBRE::VARCHAR, niv.NOMBRE::VARCHAR, gd.NOMBRE::VARCHAR,
           academico_test.fn_grado_grupo_etiqueta(gd.NOMBRE, gd.CODIGO, gr.NOMBRE)::VARCHAR,
           academico_test.fn_anio_lectivo_numero(al.NOMBRE),
           ee.FK_TARCHIVO_FONDO_BOLETIN::BIGINT,
           ee.PK_ESTABLECIMIENTO::BIGINT,
           s.PK_TSEDE::BIGINT
      FROM academico_test.TGRUPO gr
      JOIN academico_test.TGRADO gd  ON gd.PK_TGRADO = gr.FK_TGRADO
      LEFT JOIN academico_test.TNIVEL_ENSENANZA niv
             ON niv.PK_NIVEL_ENSENANZA = gd.FK_TNIVEL_ENSENANZA
      JOIN academico_test.TPERIODO_ACADEMICO pa
        ON pa.PK_TPERIODO_ACADEMICO = gd.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TANO_LECTIVO al ON al.PK_ANO_LECTIVO = pa.FK_TANO_LECTIVO
      JOIN academico_test.TSEDE s  ON s.PK_TSEDE = pa.FK_TSEDE
      JOIN academico_test.TESTABLECIMIENTO ee
        ON ee.PK_ESTABLECIMIENTO = s.FK_TESTABLECIMIENTO
      LEFT JOIN academico_test.TMUNICIPIO mun
             ON mun.PK_TMUNICIPIO = ee.FK_TMUNICIPIO
     WHERE gr.PK_TGRUPO = p_fk_tgrupo;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_boletin_cabecera_interno(BIGINT)
    IS 'INTERNO: encabezado institucional de un boletin para un grupo -- establecimiento (nombre, DANE, NIT, ciudad), sede, nivel, grado, etiqueta del grupo, año y el fondo del boletin (PK_TARCHIVO) -- mas los pk de establecimiento y sede para resolver la firma. Sin gate. La usan fn_informe_boletin_notas_interno y fn_informe_boletin_preescolar_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_informe_boletin_rector_interno(
    p_pk_ee   BIGINT,
    p_pk_sede BIGINT
)
RETURNS TABLE(nombre character varying, documento character varying)
LANGUAGE sql
STABLE
AS $function$
    -- El rol RECTOR en una sede del establecimiento, la del grupo primero. No
    -- por TFUNCIONARIO: su FK_ESTABLECIMIENTO viene NULL en casi todos.
    SELECT NULLIF(TRIM(CONCAT_WS(' ', u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO,
                                      u.PRIMER_NOMBRE,   u.SEGUNDO_NOMBRE)), '')::VARCHAR,
           CASE WHEN NULLIF(TRIM(u.IDENTIFICACION), '') IS NOT NULL
                THEN CONCAT_WS(' ', td.VALOR || ':', TRIM(u.IDENTIFICACION))
           END::VARCHAR
      FROM academico_test.TSEDE s
      JOIN academico_test.TSEDE_USUARIO su
        ON su.FK_TSEDE = s.PK_TSEDE AND su.ACTIVE = TRUE
      JOIN academico_test.TROL r
        ON r.PK_TROL = su.FK_TROL AND r.CODIGO = 'RECTOR'
      JOIN academico_test.TUSUARIO u
        ON u.PK_TUSUARIO = su.FK_TUSUARIO AND u.ACTIVE = TRUE
      LEFT JOIN academico_test.TLISTA_VALOR td
             ON td.PK_LISTA_VALOR = u.FK_TLV_TIPO_DOCUMENTO
     WHERE s.FK_TESTABLECIMIENTO = p_pk_ee
       AND s.ACTIVE = TRUE
     ORDER BY (s.PK_TSEDE = p_pk_sede) DESC, u.PK_TUSUARIO
     LIMIT 1;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_boletin_rector_interno(BIGINT, BIGINT)
    IS 'INTERNO: nombre y documento ("CC: ...") de quien firma un boletin: el usuario con rol RECTOR en una sede del establecimiento, la sede del grupo primero. Sin gate. La usan los dos boletines.';

CREATE OR REPLACE FUNCTION academico_test.fn_informe_boletin_foto_interno(
    p_fk_tmatricula BIGINT
)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $function$
    SELECT MAX(ma.FK_TARCHIVO)::BIGINT
      FROM academico_test.TMATRICULA_ARCHIVO ma
      JOIN academico_test.TLISTA_VALOR lv
        ON lv.PK_LISTA_VALOR = ma.FK_TLV_TIPO_ARCHIVO
       AND lv.CATEGORIA = 'ARCHIVO_MATRICULA'
       AND lv.VALOR     = '05'
     WHERE ma.FK_TMATRICULA = p_fk_tmatricula
       AND ma.ACTIVE = TRUE;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_boletin_foto_interno(BIGINT)
    IS 'INTERNO: PK_TARCHIVO de la foto del estudiante de una matricula (TMATRICULA_ARCHIVO tipo ARCHIVO_MATRICULA 05); NULL si no tiene. Sin gate. La usan los dos boletines.';

CREATE OR REPLACE FUNCTION academico_test.fn_informe_boletin_nota_texto(
    p_nota NUMERIC
)
RETURNS VARCHAR
LANGUAGE sql
IMMUTABLE
AS $function$
    -- Un decimal (Regla 30) y coma decimal, como se lee en Colombia.
    SELECT REPLACE(TO_CHAR(p_nota, 'FM999990.0'), '.', ',')::VARCHAR;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_boletin_nota_texto(NUMERIC)
    IS 'INTERNO: una nota ya homologada como se imprime en un boletin, con un decimal y coma decimal ("4,2"). NULL si la nota es NULL.';

CREATE OR REPLACE FUNCTION academico_test.fn_informe_boletin_notas_interno(
    p_fk_tgrupo              BIGINT,
    p_fk_tperiodo_evaluacion BIGINT,
    p_fk_tmatriculas         BIGINT[] DEFAULT NULL
)
RETURNS TABLE(ee_nombre character varying, ee_dane character varying, ee_nit character varying,
              ciudad character varying, sede_nombre character varying, nivel_ensenanza character varying,
              grado_nombre character varying, grupo_etiqueta character varying,
              periodo_nombre character varying, anio integer, fondo_archivo bigint,
              matricula bigint, estudiante character varying, documento character varying,
              foto_archivo bigint, promedio character varying, puesto bigint, total_estudiantes bigint,
              aprobadas bigint, reprobadas bigint, observacion text,
              area_nombre character varying, asignatura_nombre character varying,
              nota character varying, nota_original character varying, con_recuperacion boolean,
              desempeno character varying, aprobada boolean, inasistencias numeric,
              rector_nombre character varying, rector_documento character varying)
LANGUAGE sql
STABLE
AS $function$
    WITH listado AS (
        -- El mismo nucleo de la pantalla; solo lo consolidado entra (Regla 81):
        -- un periodo sin consolidar solo existe en la previsualizacion.
        SELECT l.*
          FROM academico_test.fn_informe_grupo_listar_interno(
                   p_fk_tgrupo, ARRAY[p_fk_tperiodo_evaluacion], NULL) l
         WHERE l.es_cualitativo IS NOT TRUE
           AND l.consolidado IS TRUE
    ),
    elegidos AS (
        SELECT l.*
          FROM listado l
         WHERE p_fk_tmatriculas IS NULL
            OR CARDINALITY(p_fk_tmatriculas) = 0
            OR l.fk_tmatricula = ANY (p_fk_tmatriculas)
    ),
    asignaturas AS (
        SELECT e.fk_tmatricula, a.value AS j
          FROM elegidos e
          CROSS JOIN LATERAL JSONB_ARRAY_ELEMENTS(COALESCE(e.asignaturas, '[]'::JSONB)) a
    )
    SELECT c.ee_nombre, c.ee_dane, c.ee_nit, c.ciudad, c.sede_nombre, c.nivel_ensenanza,
           c.grado_nombre, c.grupo_etiqueta, e.periodo_nombre, c.anio, c.fondo_archivo,
           e.fk_tmatricula, e.estudiante, e.documento,
           academico_test.fn_informe_boletin_foto_interno(e.fk_tmatricula),
           COALESCE(academico_test.fn_informe_boletin_nota_texto(e.promedio_guardado),
                    e.promedio_valoracion)::VARCHAR,
           e.puesto,
           (SELECT COUNT(*) FROM listado),
           e.aprobadas, e.reprobadas,
           -- Un boletin publica lo que alguien acepto.
           CASE WHEN e.observacion_estado = 'APROBADA' THEN e.observacion END,
           (x.j->>'area')::VARCHAR,
           (x.j->>'nombre')::VARCHAR,
           -- Solo lo guardado: una proyectada no es una nota oficial.
           CASE WHEN x.j->>'estado' IN ('guardada', 'cambio_propuesto')
                THEN COALESCE(academico_test.fn_informe_boletin_nota_texto((x.j->>'nota')::NUMERIC),
                              x.j->>'valoracion')
           END::VARCHAR,
           CASE WHEN (x.j->>'con_recuperacion')::BOOLEAN
                THEN COALESCE(academico_test.fn_informe_boletin_nota_texto((x.j->>'nota_original')::NUMERIC),
                              x.j->>'valoracion_original')
           END::VARCHAR,
           COALESCE((x.j->>'con_recuperacion')::BOOLEAN, FALSE),
           CASE WHEN x.j->>'estado' IN ('guardada', 'cambio_propuesto') THEN x.j->>'valoracion' END::VARCHAR,
           CASE WHEN x.j->>'estado' IN ('guardada', 'cambio_propuesto') THEN (x.j->>'aprobada')::BOOLEAN END,
           TRIM_SCALE(sn.INASISTENCIA),
           r.nombre, r.documento
      FROM elegidos e
      CROSS JOIN academico_test.fn_informe_boletin_cabecera_interno(p_fk_tgrupo) c
      -- LEFT: un estudiante sin asignaturas conserva su pagina.
      LEFT JOIN asignaturas x ON x.fk_tmatricula = e.fk_tmatricula
      LEFT JOIN academico_test.TASIGNATURA_NOTA sn
             ON sn.FK_TMATRICULA          = e.fk_tmatricula
            AND sn.FK_TASIGNATURA         = (x.j->>'asignatura')::BIGINT
            AND sn.FK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion
            AND sn.ACTIVE = TRUE
      LEFT JOIN LATERAL academico_test.fn_informe_boletin_rector_interno(c.pk_ee, c.pk_sede) r ON TRUE
     ORDER BY e.estudiante, e.fk_tmatricula,
              (x.j->>'orden')::NUMERIC NULLS LAST, x.j->>'nombre';
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_boletin_notas_interno(BIGINT, BIGINT, BIGINT[])
    IS 'INTERNO: los datos del boletin de notas de un periodo (Enfoque Evaluativo): una fila por (estudiante, asignatura), que la plantilla agrupa en un boletin por estudiante. Solo estudiantes no cualitativos con el periodo CONSOLIDADO (Regla 81), sobre fn_informe_grupo_listar_interno. NOTA es la guardada (la resultante, R) en la escala del colegio y con un decimal; solo lo guardado, una proyectada sale vacia. Con Habilitacion (recuperacion de NOTA_FINAL) CON_RECUPERACION es TRUE y NOTA_ORIGINAL trae la nota antes de recuperar (C, Regla 68). PROMEDIO, PUESTO (sobre los consolidados del grupo, de TOTAL_ESTUDIANTES), APROBADAS y REPROBADAS son los del listado; la OBSERVACION solo si esta APROBADA; INASISTENCIAS de TASIGNATURA_NOTA. Un estudiante sin asignaturas conserva su fila. Sin gate: lo aplica fn_informe_boletin_notas.';

-- ============================================================ wrapper
CREATE OR REPLACE FUNCTION academico_test.fn_informe_boletin_notas(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tgrupo              BIGINT,
    p_fk_tperiodo_evaluacion BIGINT,
    p_fk_tmatriculas         BIGINT[] DEFAULT NULL
)
RETURNS TABLE(ee_nombre character varying, ee_dane character varying, ee_nit character varying,
              ciudad character varying, sede_nombre character varying, nivel_ensenanza character varying,
              grado_nombre character varying, grupo_etiqueta character varying,
              periodo_nombre character varying, anio integer, fondo_archivo bigint,
              matricula bigint, estudiante character varying, documento character varying,
              foto_archivo bigint, promedio character varying, puesto bigint, total_estudiantes bigint,
              aprobadas bigint, reprobadas bigint, observacion text,
              area_nombre character varying, asignatura_nombre character varying,
              nota character varying, nota_original character varying, con_recuperacion boolean,
              desempeno character varying, aprobada boolean, inasistencias numeric,
              rector_nombre character varying, rector_documento character varying)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_fk_sede    BIGINT;
    v_fk_jornada BIGINT;
    v_fk_ee      BIGINT;
BEGIN
    SELECT s.PK_TSEDE, gr.FK_TLV_JORNADA, s.FK_TESTABLECIMIENTO
      INTO v_fk_sede, v_fk_jornada, v_fk_ee
      FROM academico_test.TGRUPO gr
      JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa
        ON pa.PK_TPERIODO_ACADEMICO = gd.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE gr.PK_TGRUPO = p_fk_tgrupo
       AND gr.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el grupo solicitado'
            USING ERRCODE = 'P0002';
    END IF;

    PERFORM academico_test.fn_informe_validar_periodo_del_grupo(
        p_fk_tgrupo, p_fk_tperiodo_evaluacion);

    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'INFORMES', 'VER',
        v_fk_ee, v_fk_sede, v_fk_jornada
    );
    PERFORM academico_test.fn_informe_assert_grupo_propio(
        p_pk_usuario_solicitante, p_fk_tgrupo);

    RETURN QUERY
    SELECT * FROM academico_test.fn_informe_boletin_notas_interno(
                      p_fk_tgrupo, p_fk_tperiodo_evaluacion, p_fk_tmatriculas);
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_boletin_notas(BIGINT, BIGINT, BIGINT, BIGINT[])
    IS 'POST /informes/boletin-notas: los datos del boletin de notas de un grupo en un periodo, para que reporting-service arme un boletin por estudiante, uno detras de otro (agrupando por MATRICULA). FK_TMATRICULAS acota a unos estudiantes; sin el sale el grupo entero. Valida el grupo y que el periodo sea de su año, pide INFORMES/VER sobre la sede y jornada del grupo, recorta a grupos propios y delega en fn_informe_boletin_notas_interno, donde esta el contrato de la salida. Sobre un grupo de preescolar o un periodo sin consolidar devuelve una lista vacia, no un error.';

-- ============================================================ endpoint
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT 'eval-col-informes-boletin-notas-001', m.id_microservice, '/informes/boletin-notas', 'POST', 'postgres', 'SELECT', NULL,
       'false', 'false', 'false', '60', 'informes-boletin-notas', 'DEFAULT',
       '{"BODY.FILTERS.FK_TGRUPO": "BIGINT", "BODY.FILTERS.FK_TMATRICULAS": "BIGINT[]", "BODY.FILTERS.FK_TPERIODO_EVALUACION": "BIGINT"}'::jsonb,
       'Los datos del boletin de notas de un grupo en un periodo: una fila por (estudiante, asignatura), agrupable por MATRICULA en un boletin por estudiante. FK_TGRUPO y FK_TPERIODO_EVALUACION son obligatorios; FK_TMATRICULAS acota a unos estudiantes. Solo estudiantes no cualitativos con el periodo consolidado (Regla 81). NOTA es la resultante y, con Habilitacion, NOTA_ORIGINAL la de antes (Regla 68). FONDO_ARCHIVO y FOTO_ARCHIVO son PK_TARCHIVO, no URLs.',
       $q$SELECT * FROM academico_test.fn_informe_boletin_notas(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FILTERS.FK_TGRUPO AS BIGINT),
    CAST(:BODY.FILTERS.FK_TPERIODO_EVALUACION AS BIGINT),
    CAST(:BODY.FILTERS.FK_TMATRICULAS AS BIGINT[])
);$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- Lo ve quien ve el listado de informes, del que cuelga.
INSERT INTO public.role_query (role_id, query_id)
SELECT rq.role_id, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id AND m.serviceid = 'eval-col'
  JOIN public.query listado ON listado.microservice_id = q.microservice_id
                           AND listado.path_template = '/informes/grupo' AND listado.http_method = 'POST'
  JOIN public.role_query rq ON rq.query_id = listado.id_query
 WHERE q.path_template = '/informes/boletin-notas' AND q.http_method = 'POST'
ON CONFLICT DO NOTHING;
