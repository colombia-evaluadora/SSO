-- ===========================================================================
-- V496.25 - Regla 80 / seccion 8: vista formativa de informes.
--   POST /informes/formativo (fn_informe_formativo_listar): por estudiante y
--   periodo, cada actividad formativa agrupada por Unidad con su observacion,
--   Momento y evidencias, mas estado del periodo (Abierto/Cerrado/Sin
--   registros), numero de evidencias y ultima actualizacion. Sin notas.
--   fn_informe_grupo_tabla (POST /informes/tabla) deja fuera las asignaturas
--   de referente Formativo.
-- Depende de: V439, V475 (contexto evaluativo), V489, V496.5 (FK_TLV_MOMENTO).
-- ===========================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_informe_formativo_listar_interno(
    p_fk_tgrupo              BIGINT,
    p_fk_periodos_evaluacion BIGINT[] DEFAULT NULL,
    p_search                 VARCHAR  DEFAULT NULL
)
RETURNS TABLE(
    fk_tmatricula                BIGINT,
    estudiante                   VARCHAR,
    documento                    VARCHAR,
    fk_tperiodo_evaluacion       BIGINT,
    periodo_nombre               VARCHAR,
    estado_periodo               VARCHAR,
    evidencias_periodo           BIGINT,
    ultima_actualizacion_periodo TIMESTAMP,
    fk_tasignatura               BIGINT,
    asignatura                   VARCHAR,
    fk_tunidad                   BIGINT,
    unidad                       VARCHAR,
    fk_tactividad                BIGINT,
    actividad                    VARCHAR,
    observacion                  VARCHAR,
    momento                      VARCHAR,
    momento_nombre               VARCHAR,
    evidencias                   BIGINT,
    archivos                     BIGINT[],
    actualizado_en               TIMESTAMP
)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_fk_peraca BIGINT;
BEGIN
    SELECT gd.FK_TPERIODO_ACADEMICO INTO v_fk_peraca
      FROM academico_test.TGRUPO gr
      JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
     WHERE gr.PK_TGRUPO = p_fk_tgrupo;

    RETURN QUERY
    WITH periodos AS (
        SELECT pe.PK_TPERIODO_EVALUACION AS pk, pe.NOMBRE::VARCHAR AS nombre,
               pe.FECHA_INICIO AS inicio, pe.FECHA_FIN AS fin
          FROM academico_test.TPERIODO_EVALUACION pe
         WHERE pe.ACTIVE = TRUE
           AND pe.FK_TPERIODO_ACADEMICO = v_fk_peraca
           AND (p_fk_periodos_evaluacion IS NULL
                OR CARDINALITY(p_fk_periodos_evaluacion) = 0
                OR pe.PK_TPERIODO_EVALUACION = ANY (p_fk_periodos_evaluacion))
    ),
    estudiantes AS (
        SELECT m.PK_TMATRICULA AS pk,
               NULLIF(TRIM(CONCAT_WS(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
                                          u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO)), '')::VARCHAR AS nombre,
               u.IDENTIFICACION::VARCHAR AS doc
          FROM academico_test.TMATRICULA m
          LEFT JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
          LEFT JOIN academico_test.TUSUARIO u     ON u.PK_TUSUARIO     = es.FK_TUSUARIO
         WHERE m.FK_TGRUPO = p_fk_tgrupo
           AND m.ACTIVE = TRUE
           AND (NULLIF(TRIM(COALESCE(p_search, '')), '') IS NULL
                OR CONCAT_WS(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE, u.PRIMER_APELLIDO,
                             u.SEGUNDO_APELLIDO, u.IDENTIFICACION) ILIKE '%' || TRIM(p_search) || '%')
    ),
    registros AS (
        SELECT e.pk AS mat, p.pk AS pe,
               a.PK_TACTIVIDAD AS act, a.TITULO::VARCHAR AS titulo,
               a.FK_TASIGNATURA AS asig, asg.NOMBRE::VARCHAR AS asig_nombre,
               a.FK_TUNIDAD AS uni, tu.NOMBRE::VARCHAR AS unidad_nombre,
               NULLIF(TRIM(n.OBSERVACION), '')::VARCHAR AS obs,
               mo.VALOR::VARCHAR  AS mom,
               mo.NOMBRE::VARCHAR AS mom_nombre,
               CASE WHEN NULLIF(TRIM(n.OBSERVACION), '') IS NOT NULL
                    THEN COALESCE(n.MODIFIED_AT, n.CREATED_AT) END AS actualizado,
               ev.n   AS n_evid,
               ev.ids AS ids_evid
          FROM estudiantes e
          CROSS JOIN periodos p
          JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
            ON ae.FK_TMATRICULA = e.pk AND ae.ACTIVE = TRUE
          JOIN academico_test.TACTIVIDAD a
            ON a.PK_TACTIVIDAD = ae.FK_TACTIVIDAD AND a.ACTIVE = TRUE
          JOIN academico_test.TASIGNATURA asg ON asg.PK_TASIGNATURA = a.FK_TASIGNATURA
          LEFT JOIN academico_test.TUNIDAD tu ON tu.PK_TUNIDAD = a.FK_TUNIDAD
          LEFT JOIN academico_test.TACTIVIDAD_NOTA n
            ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE AND n.ACTIVE = TRUE
          LEFT JOIN academico_test.TLISTA_VALOR mo ON mo.PK_LISTA_VALOR = n.FK_TLV_MOMENTO
          LEFT JOIN LATERAL (
                SELECT COUNT(*) AS n,
                       ARRAY_AGG(so.FK_TARCHIVO ORDER BY so.PK_TACTIVIDAD_SOPORTE) AS ids
                  FROM academico_test.TACTIVIDAD_SOPORTE so
                 WHERE so.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                   AND so.ACTIVE = TRUE
                   AND so.FK_TARCHIVO IS NOT NULL
               ) ev ON TRUE
         WHERE academico_test.fn_actividad_en_periodo_eval(a.PK_TACTIVIDAD, p.pk) = TRUE
           AND academico_test.fn_actividad_es_formativa(a.PK_TACTIVIDAD) = TRUE
    ),
    resumen AS (
        SELECT r.mat, r.pe,
               SUM(r.n_evid)::BIGINT AS evid,
               MAX(r.actualizado)    AS ultima,
               BOOL_OR(r.obs IS NOT NULL OR r.n_evid > 0) AS hay
          FROM registros r
         GROUP BY r.mat, r.pe
    )
    SELECT e.pk, e.nombre, e.doc, p.pk, p.nombre,
           (CASE WHEN NOT COALESCE(rs.hay, FALSE) THEN 'Sin registros'
                 WHEN p.fin < CURRENT_DATE        THEN 'Cerrado'
                 ELSE 'Abierto' END)::VARCHAR,
           COALESCE(rs.evid, 0)::BIGINT,
           rs.ultima,
           r.asig, r.asig_nombre, r.uni, r.unidad_nombre,
           r.act, r.titulo, r.obs, r.mom, r.mom_nombre,
           r.n_evid::BIGINT, r.ids_evid, r.actualizado
      FROM estudiantes e
      CROSS JOIN periodos p
      LEFT JOIN resumen   rs ON rs.mat = e.pk AND rs.pe = p.pk
      LEFT JOIN registros r  ON r.mat  = e.pk AND r.pe  = p.pk
     ORDER BY e.nombre NULLS LAST, e.pk, p.inicio,
              r.asig_nombre, r.unidad_nombre NULLS LAST, r.titulo;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_formativo_listar_interno(BIGINT, BIGINT[], VARCHAR)
    IS 'INTERNO: vista formativa de informes (Regla 80). Una fila por (estudiante, periodo, actividad formativa asignada) -- fn_actividad_es_formativa -- con asignatura, Unidad (NULL si la actividad no tiene), observacion, Momento del registro (TACTIVIDAD_NOTA.FK_TLV_MOMENTO: VALOR y NOMBRE), cuantas evidencias con archivo y sus FK_TARCHIVO, y la fecha de la observacion. Repite por fila el resumen del (estudiante, periodo): estado_periodo Sin registros (ni observaciones ni evidencias) / Cerrado (FECHA_FIN ya paso) / Abierto, evidencias_periodo y ultima_actualizacion_periodo (observacion mas reciente). Un estudiante sin actividades formativas en el periodo sale una vez con las columnas de actividad en NULL. No devuelve ninguna nota. Sin gate. La usa fn_informe_formativo_listar.';


CREATE OR REPLACE FUNCTION academico_test.fn_informe_formativo_listar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tgrupo              BIGINT,
    p_fk_periodos_evaluacion BIGINT[] DEFAULT NULL,
    p_search                 VARCHAR  DEFAULT NULL
)
RETURNS TABLE(
    fk_tmatricula                BIGINT,
    estudiante                   VARCHAR,
    documento                    VARCHAR,
    fk_tperiodo_evaluacion       BIGINT,
    periodo_nombre               VARCHAR,
    estado_periodo               VARCHAR,
    evidencias_periodo           BIGINT,
    ultima_actualizacion_periodo TIMESTAMP,
    fk_tasignatura               BIGINT,
    asignatura                   VARCHAR,
    fk_tunidad                   BIGINT,
    unidad                       VARCHAR,
    fk_tactividad                BIGINT,
    actividad                    VARCHAR,
    observacion                  VARCHAR,
    momento                      VARCHAR,
    momento_nombre               VARCHAR,
    evidencias                   BIGINT,
    archivos                     BIGINT[],
    actualizado_en               TIMESTAMP
)
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

    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'INFORMES', 'VER',
        v_fk_ee, v_fk_sede, v_fk_jornada
    );
    PERFORM academico_test.fn_informe_assert_grupo_propio(
        p_pk_usuario_solicitante, p_fk_tgrupo);

    RETURN QUERY
    SELECT * FROM academico_test.fn_informe_formativo_listar_interno(
                      p_fk_tgrupo, p_fk_periodos_evaluacion, p_search);
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_formativo_listar(BIGINT, BIGINT, BIGINT[], VARCHAR)
    IS 'POST /informes/formativo: vista de informes en Enfoque Formativo (fn_informe_formativo_listar_interno). Gate VER sobre INFORMES con alcance del grupo y recorte por grupo propio (fn_informe_assert_grupo_propio). 404 (P0002) si el grupo no existe.';


-- ---------------------------------------------------------------------------
-- fn_informe_grupo_tabla: sin asignaturas de referente Formativo.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_informe_grupo_tabla(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tgrupo              BIGINT,
    p_fk_periodos_evaluacion BIGINT[] DEFAULT NULL,
    p_search                 VARCHAR  DEFAULT NULL
)
RETURNS TABLE(
    estudiante   VARCHAR,
    documento    VARCHAR,
    periodo      VARCHAR,
    consolidado  VARCHAR,
    asignatura   VARCHAR,
    area         VARCHAR,
    nota         NUMERIC,
    desempeno    VARCHAR,
    estado       VARCHAR,
    aprobada     BOOLEAN,
    promedio     NUMERIC,
    puesto       BIGINT,
    observacion  TEXT,
    evidencias   BIGINT
)
LANGUAGE sql
STABLE
AS $function$
    WITH filas AS (
        SELECT *
          FROM academico_test.fn_informe_grupo_listar(
                   p_pk_usuario_solicitante,
                   p_fk_tgrupo,
                   p_fk_periodos_evaluacion,
                   p_search)
    )
    SELECT f.estudiante,
           f.documento,
           f.periodo_nombre,
           CASE WHEN f.modo_periodo = 'final' THEN 'Calculado'
                WHEN f.consolidado IS TRUE    THEN 'Si'
                ELSE 'No'
           END::VARCHAR,
           a.nombre,
           a.area,
           a.nota,
           COALESCE(a.valoracion, a.simbolo)::VARCHAR,
           -- Aca NO se esconde nada, pero cada numero viene dicho con todas
           -- las letras. Un volcado que no distingue una nota guardada de una
           -- proyeccion es peor que no tenerlo: se lee como definitivo.
           CASE a.estado
               WHEN 'guardada'         THEN 'Guardada'
               WHEN 'cambio_propuesto' THEN 'Guardada (con cambio propuesto)'
               WHEN 'proyectada'       THEN 'Proyectada (sin consolidar)'
               WHEN 'requerido'        THEN 'Requerida para aprobar el año'
               WHEN 'final'            THEN 'Final (promedio del año)'
               WHEN 'sin_nota'         THEN 'Sin nota'
               ELSE a.estado
           END::VARCHAR,
           a.aprobada,
           COALESCE(f.promedio_guardado, f.promedio_proyectado),
           f.puesto,
           f.observacion,
           f.evidencias
      FROM filas f
      -- Sin CASE de vaciado: aca las asignaturas sin nota TAMBIEN salen, con
      -- su "Sin nota". El vaciado del V430 existe para que el boletin no
      -- pierda la fila; en un volcado no hay nada que perder.
      LEFT JOIN LATERAL JSONB_TO_RECORDSET(f.asignaturas) AS a(
               asignatura   BIGINT,
               nombre       VARCHAR,
               abreviacion  VARCHAR,
               area         VARCHAR,
               orden        INTEGER,
               nota         NUMERIC,
               estado       VARCHAR,
               es_numerico  BOOLEAN,
               valoracion   VARCHAR,
               simbolo      VARCHAR,
               aprobada     BOOLEAN,
               ya_asegurado BOOLEAN,
               alcanzable   BOOLEAN
           ) ON TRUE
     -- Regla 80: en Formativo no hay nota ni consolidado que descargar.
     WHERE a.asignatura IS NOT NULL
       AND academico_test.fn_actividad_contexto_evaluativo(
               p_fk_tgrupo, a.asignatura, NULL)
     ORDER BY f.estudiante,
              f.periodo_inicio,
              a.orden NULLS LAST,
              a.nombre;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_grupo_tabla(BIGINT, BIGINT, BIGINT[], VARCHAR)
    IS 'POST /informes/tabla: la tabla de informes tal como se esta viendo, aplanada para descargarla. A diferencia del boletin no filtra estados: salen lo consolidado, lo proyectado, lo requerido y lo que no tiene nota, cada uno dicho en ESTADO, mas CONSOLIDADO. Solo asignaturas de referente EVALUATIVO (fn_actividad_contexto_evaluativo): en Formativo no hay nota ni consolidado (Regla 80); un grupo enteramente formativo devuelve vacio y se consulta con POST /informes/formativo. El Final se pide metiendo -1 en el arreglo de periodos. Delega en fn_informe_grupo_listar, que lleva el gate.';


-- role_query cae por ON DELETE CASCADE y se vuelve a copiar abajo.
DELETE FROM public.query WHERE uuid = 'eval-col-informes-formativo-listar-001';

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action, style)
SELECT
    'eval-col-informes-formativo-listar-001',
    'SELECT * FROM academico_test.fn_informe_formativo_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FK_TGRUPO AS BIGINT),
    CAST(:BODY.PERIODOS AS BIGINT[]),
    CAST(:BODY.SEARCH AS VARCHAR)
);',
    'postgres', false, false,
    m.id_microservice,
    '/informes/formativo', 'SELECT', 'POST',
    '{"BODY.FK_TGRUPO": "BIGINT", "BODY.PERIODOS": "BIGINT[]", "BODY.SEARCH": "VARCHAR"}'::jsonb,
    NULL,
    'Vista de informes en Enfoque Formativo (Regla 80): sin ninguna nota. Una fila por (estudiante, periodo, actividad formativa) con asignatura, unidad (para agrupar), actividad, observacion, momento / momento_nombre (Inicio, Proceso, Cierre), evidencias y archivos (FK_TARCHIVO de cada evidencia) y actualizado_en. Cada fila repite el resumen del (estudiante, periodo): estado_periodo (Abierto, Cerrado o Sin registros), evidencias_periodo y ultima_actualizacion_periodo. Un estudiante sin actividades formativas en el periodo sale una vez con las columnas de actividad en null. PERIODOS vacio o ausente = todos los del periodo academico del grupo. SEARCH filtra por nombre o documento. Sin paginacion.',
    'informes-formativo-listar', 'DEFAULT'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

-- Mismos roles que el listado evaluativo.
INSERT INTO public.role_query (role_id, query_id)
SELECT rq.role_id, nuevo.id_query
  FROM public.query nuevo
  JOIN public.query base
    ON base.microservice_id = nuevo.microservice_id
   AND base.path_template   = '/informes/grupo'
   AND base.http_method     = 'POST'
  JOIN public.role_query rq ON rq.query_id = base.id_query
 WHERE nuevo.uuid = 'eval-col-informes-formativo-listar-001'
ON CONFLICT DO NOTHING;
