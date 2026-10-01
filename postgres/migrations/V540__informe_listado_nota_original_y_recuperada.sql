-- ===========================================================================
-- V540 - El listado de informes manda al front la C y la R.
--
--   fn_informe_grupo_listar, en el JSON de cada asignatura del periodo:
--     con_recuperacion     TRUE si hubo recuperacion de NOTA_FINAL
--     nota_original        la C, homologada (la R sigue siendo 'nota')
--     valoracion_original  / simbolo_original, para escalas cualitativas
--
--   Y el PROMEDIO_PROYECTADO: se calculaba con COALESCE(proyectada,
--   guardada), y la proyectada excluye la actividad de recuperacion
--   (V496.23), asi que en una asignatura recuperada promediaba la C. Ahi se
--   usa la resultante, que es la vigente. El guardado, la aprobacion y el
--   Final (fn_asignatura_definitiva_anual_interno, que lee DEFINITIVA) ya
--   usaban la R.
--
-- Depende de: V496.24 (ultimo cuerpo), V535.
-- ===========================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_informe_grupo_listar(p_pk_usuario_solicitante bigint, p_fk_tgrupo bigint, p_fk_periodos_evaluacion bigint[] DEFAULT NULL::bigint[], p_search character varying DEFAULT NULL::character varying)
 RETURNS TABLE(fk_tmatricula bigint, estudiante character varying, documento character varying, fk_tperiodo_evaluacion bigint, periodo_nombre character varying, periodo_abreviacion character varying, periodo_inicio date, modo_periodo character varying, formato character varying, es_cualitativo boolean, consolidado boolean, promedio_guardado numeric, promedio_proyectado numeric, puesto bigint, asignaturas_total bigint, aprobadas bigint, reprobadas bigint, sin_definir bigint, tiene_cambios_propuestos boolean, asignaturas jsonb, observacion text, observacion_estado character varying, observacion_desactualizada boolean, evidencias bigint, total_count bigint, promedio_valoracion character varying, promedio_simbolo character varying, promedio_proyectado_valoracion character varying, promedio_proyectado_simbolo character varying, promedio_formato character varying)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_fk_sede     BIGINT;
    v_fk_jornada  BIGINT;
    v_fk_ee       BIGINT;
    v_fk_peraca   BIGINT;
    v_fk_grado    BIGINT;
    v_minimo         NUMERIC;
    v_n_periodos     INTEGER;
    v_incluir_final  BOOLEAN;
BEGIN
    SELECT s.PK_TSEDE, gr.FK_TLV_JORNADA, s.FK_TESTABLECIMIENTO,
           gd.FK_TPERIODO_ACADEMICO, gd.PK_TGRADO
      INTO v_fk_sede, v_fk_jornada, v_fk_ee, v_fk_peraca, v_fk_grado
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

    -- V490 -- el recorte por grupo, DESPUES del gate de arriba. Para
    -- quien alcanza la sede entera es un no-op.
    PERFORM academico_test.fn_informe_assert_grupo_propio(
        p_pk_usuario_solicitante, p_fk_tgrupo);

    v_minimo := academico_test.fn_grado_desempeno_minimo(v_fk_grado);

    -- *** V439 *** El Final ya no es un parametro aparte: es un id mas de la
    -- lista de periodos, el mismo -1 con el que la fila viaja. Que sea un
    -- elemento y no una bandera es lo que permite pedir "solo el Final":
    -- ARRAY[-1] no matchea ningun periodo real, asi que la CTE de periodos
    -- queda vacia sin que haya que inventar un segundo significado para el
    -- arreglo vacio. NULL o vacio siguen siendo TODOS los periodos reales,
    -- sin Final, exactamente como antes.
    v_incluir_final := p_fk_periodos_evaluacion IS NOT NULL
                      AND (-1) = ANY (p_fk_periodos_evaluacion);

    SELECT COUNT(*)
      INTO v_n_periodos
      FROM academico_test.TPERIODO_EVALUACION pe
     WHERE pe.ACTIVE = TRUE
       AND pe.FK_TPERIODO_ACADEMICO = v_fk_peraca;

    RETURN QUERY
    WITH periodos AS (
        SELECT pe.PK_TPERIODO_EVALUACION AS pk,
               pe.NOMBRE                 AS nombre,
               pe.ABREVIACION            AS abrev,
               pe.FECHA_INICIO           AS inicio
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
                                          u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO)),
                      '')::VARCHAR AS nombre,
               u.IDENTIFICACION::VARCHAR AS doc
          FROM academico_test.TMATRICULA m
          LEFT JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
          LEFT JOIN academico_test.TUSUARIO u     ON u.PK_TUSUARIO     = es.FK_TUSUARIO
         WHERE m.FK_TGRUPO = p_fk_tgrupo
           AND m.ACTIVE = TRUE
    ),
    detalle AS (
        SELECT e.pk AS mat, d.*
          FROM estudiantes e
          CROSS JOIN LATERAL academico_test.fn_informe_estudiante_asignaturas(
                         p_pk_usuario_solicitante, e.pk, p_fk_periodos_evaluacion) d
    ),
    observaciones AS (
        SELECT e.pk AS mat,
               p.pk AS pe,
               (SELECT COUNT(*)
                  FROM academico_test.TACTIVIDAD a2
                  JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae2
                    ON ae2.FK_TACTIVIDAD = a2.PK_TACTIVIDAD
                   AND ae2.FK_TMATRICULA = e.pk
                   AND ae2.ACTIVE = TRUE
                  JOIN academico_test.TACTIVIDAD_NOTA n2
                    ON n2.FK_TACTIVIDAD_ESTUDIANTE = ae2.PK_TACTIVIDAD_ESTUDIANTE
                   AND n2.ACTIVE = TRUE
                 WHERE a2.ACTIVE = TRUE
                   AND NULLIF(TRIM(COALESCE(n2.OBSERVACION, '')), '') IS NOT NULL
                   AND academico_test.fn_actividad_en_periodo_eval(a2.PK_TACTIVIDAD, p.pk) = TRUE
               ) AS n
          FROM estudiantes e
          CROSS JOIN periodos p
    ),
    evidencias_periodo AS (
        SELECT e.pk AS mat,
               p.pk AS pe,
               (SELECT COUNT(*)
                  FROM academico_test.TACTIVIDAD_SOPORTE so
                  JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae3
                    ON ae3.PK_TACTIVIDAD_ESTUDIANTE = so.FK_TACTIVIDAD_ESTUDIANTE
                   AND ae3.FK_TMATRICULA = e.pk
                   AND ae3.ACTIVE = TRUE
                  JOIN academico_test.TACTIVIDAD a4
                    ON a4.PK_TACTIVIDAD = ae3.FK_TACTIVIDAD
                   AND a4.ACTIVE = TRUE
                 WHERE so.ACTIVE = TRUE
                   AND so.FK_TARCHIVO IS NOT NULL
                   AND academico_test.fn_actividad_en_periodo_eval(a4.PK_TACTIVIDAD, p.pk) = TRUE
               ) AS n
          FROM estudiantes e
          CROSS JOIN periodos p
    ),
    por_periodo AS (
        SELECT e.pk   AS mat,
               e.nombre,
               e.doc,
               p.pk     AS pe,
               p.nombre AS pe_nombre,
               p.abrev  AS pe_abrev,
               p.inicio AS pe_inicio,
               COALESCE(BOOL_OR(COALESCE(d.nota_guardada, d.nota_proyectada)
                                IS NOT NULL), FALSE)             AS tiene_notas,
               COUNT(d.fk_tasignatura)                           AS calc_total,
               AVG(d.nota_guardada)                              AS calc_prom_guardado,
               AVG(COALESCE(d.nota_guardada, d.nota_proyectada)) AS calc_prom_visible,
               -- V540 -- la proyectada excluye la recuperacion; en una
               -- asignatura recuperada lo vigente es la resultante.
               AVG(CASE WHEN d.con_recuperacion THEN d.nota_guardada
                        ELSE COALESCE(d.nota_proyectada, d.nota_guardada) END) AS calc_prom_proyectado,
               COUNT(*) FILTER (WHERE d.aprobada IS TRUE)        AS calc_aprob,
               COUNT(*) FILTER (WHERE d.aprobada IS FALSE)       AS calc_reprob,
               COUNT(*) FILTER (WHERE d.fk_tasignatura IS NOT NULL
                                  AND d.aprobada IS NULL)        AS calc_sindef,
               COALESCE(BOOL_OR(d.es_numerico), FALSE)           AS hay_numerico,
               COALESCE(BOOL_OR(d.estado_nota = 'cambio_propuesto'), FALSE) AS cambios,
               COALESCE(
                   JSONB_AGG(
                       JSONB_BUILD_OBJECT(
                           'asignatura',  d.fk_tasignatura,
                           'nombre',      d.asignatura_nombre,
                           'abreviacion', asg.ABREVIACION,
                           'area',        d.area_nombre,
                           'orden',       asg.ORDEN_REPORTE,
                           'nota',        d.nota_homologada,
                           'nota_propuesta',
                               CASE WHEN d.estado_nota = 'cambio_propuesto'
                                    THEN d.nota_proyectada_homologada END,
                           'estado',      d.estado_nota,
                           'es_numerico', d.es_numerico,
                           'valoracion',  d.valoracion_nombre,
                           'simbolo',     d.valoracion_simbolo,
                           'aprobada',    d.aprobada,
                           -- V540 -- Regla 68: con recuperacion de NOTA_FINAL,
                           -- 'nota' es la resultante (R) y estas la original (C).
                           'con_recuperacion',    COALESCE(d.con_recuperacion, FALSE),
                           'nota_original',       d.nota_original_homologada,
                           'valoracion_original', d.nota_original_valoracion,
                           'simbolo_original',    d.nota_original_simbolo
                       ) ORDER BY asg.ORDEN_REPORTE NULLS LAST, d.asignatura_nombre
                   ) FILTER (WHERE d.fk_tasignatura IS NOT NULL),
                   '[]'::JSONB
               ) AS asigs
          FROM estudiantes e
          CROSS JOIN periodos p
          LEFT JOIN detalle d
                 ON d.mat = e.pk
                AND d.fk_tperiodo_evaluacion = p.pk
          LEFT JOIN academico_test.TASIGNATURA asg
                 ON asg.PK_TASIGNATURA = d.fk_tasignatura
         GROUP BY e.pk, e.nombre, e.doc, p.pk, p.nombre, p.abrev, p.inicio
    ),
    base AS (
        SELECT pp.*,
               COALESCE(ob.n, 0) AS obs_hoy,
               COALESCE(ev.n, 0) AS evid
          FROM por_periodo pp
          LEFT JOIN observaciones      ob ON ob.mat = pp.mat AND ob.pe = pp.pe
          LEFT JOIN evidencias_periodo ev ON ev.mat = pp.mat AND ev.pe = pp.pe
    ),
    requeridos AS (
        SELECT b.mat,
               b.pe,
               COALESCE(BOOL_OR(r.es_numerico), FALSE) AS hay_numerico,
               COUNT(*)                                AS total,
               COALESCE(
                   JSONB_AGG(
                       JSONB_BUILD_OBJECT(
                           'asignatura',   r.fk_tasignatura,
                           'nombre',       r.asignatura_nombre,
                           'abreviacion',  r.abreviacion,
                           'area',         r.area_nombre,
                           'orden',        r.orden_reporte,
                           'nota',         r.requerido_homologado,
                           'porcentaje',   r.requerido,
                           'estado',       'requerido',
                           'es_numerico',  r.es_numerico,
                           'ya_asegurado', r.ya_asegurado,
                           'alcanzable',   r.alcanzable
                       ) ORDER BY r.orden_reporte NULLS LAST, r.asignatura_nombre
                   ),
                   '[]'::JSONB
               ) AS asigs
          FROM base b
          CROSS JOIN LATERAL academico_test.fn_informe_periodo_requerido(
                         p_pk_usuario_solicitante, b.mat, b.pe) r
         WHERE NOT b.tiene_notas
           AND b.obs_hoy = 0
         GROUP BY b.mat, b.pe
    ),
    resuelto AS (
        SELECT b.*,
               (NOT b.tiene_notas
                AND COALESCE(rq.hay_numerico, FALSE))  AS es_requerido,
               rq.total AS req_total,
               rq.asigs AS req_asigs,
               COALESCE(rq.hay_numerico, b.hay_numerico) AS es_num_final
          FROM base b
          LEFT JOIN requeridos rq ON rq.mat = b.mat AND rq.pe = b.pe
    ),
    con_metricas AS (
        SELECT rs.*,
               (ipm.PK_TINFORME_PERIODO_MATRICULA IS NOT NULL) AS esta_consolidado,
               COALESCE(ipm.PROMEDIO,    ROUND(rs.calc_prom_guardado, 2)) AS prom_guardado,
               COALESCE(ipm.ASIGNATURAS, rs.calc_total)                   AS total_asig,
               COALESCE(ipm.APROBADAS,   rs.calc_aprob)                   AS aprob,
               COALESCE(ipm.REPROBADAS,  rs.calc_reprob)                  AS reprob,
               COALESCE(ipm.SIN_DEFINIR, rs.calc_sindef)                  AS sindef,
               ob.OBSERVACION                                             AS obs,
               lv.VALOR                                                   AS obs_estado,
               CASE WHEN ob.PK_TESTUDIANTE_PERIODO_OBSERVACION IS NULL THEN NULL
                    ELSE rs.obs_hoy > COALESCE(ob.OBSERVACIONES_ORIGEN, 0)
               END                                                        AS obs_vieja
          FROM resuelto rs
          LEFT JOIN academico_test.TINFORME_PERIODO_MATRICULA ipm
                 ON ipm.FK_TMATRICULA          = rs.mat
                AND ipm.FK_TPERIODO_EVALUACION = rs.pe
                AND ipm.ACTIVE = TRUE
          LEFT JOIN academico_test.TESTUDIANTE_PERIODO_OBSERVACION ob
                 ON ob.FK_TMATRICULA          = rs.mat
                AND ob.FK_TPERIODO_EVALUACION = rs.pe
                AND ob.ACTIVE = TRUE
          LEFT JOIN academico_test.TLISTA_VALOR lv
                 ON lv.PK_LISTA_VALOR = ob.FK_TLV_ESTADO_OBSERVACION
    ),
    con_puesto AS (
        SELECT cm.*,
               CASE WHEN cm.es_requerido OR cm.calc_prom_visible IS NULL THEN NULL
                    ELSE RANK() OVER (PARTITION BY cm.pe
                                          ORDER BY cm.calc_prom_visible DESC NULLS LAST)
               END AS pos
          FROM con_metricas cm
    ),

    -- =======================================================================
    -- La fila Final (V431).
    -- =======================================================================
    estudiantes_final AS (
        SELECT e.* FROM estudiantes e WHERE v_incluir_final
    ),
    detalle_ano AS (
        SELECT e.pk AS mat, d.*
          FROM estudiantes_final e
          CROSS JOIN LATERAL academico_test.fn_informe_estudiante_asignaturas(
                         p_pk_usuario_solicitante, e.pk, NULL) d
    ),
    final_asig AS (
        SELECT d.mat                                    AS mat,
               d.fk_tasignatura                         AS asig,
               MAX(d.asignatura_nombre)                 AS nombre,
               MAX(asg.ABREVIACION)                     AS abrev,
               MAX(d.area_nombre)                       AS area,
               MAX(asg.ORDEN_REPORTE)                   AS orden,
               COALESCE(BOOL_OR(d.es_numerico), FALSE)  AS es_numerico,
               MAX(d.desempeno_minimo)                  AS minimo,
               academico_test.fn_asignatura_definitiva_anual_interno(d.mat, d.fk_tasignatura) AS nota
          FROM detalle_ano d
          JOIN academico_test.TASIGNATURA asg ON asg.PK_TASIGNATURA = d.fk_tasignatura
         WHERE d.fk_tasignatura IS NOT NULL
         GROUP BY d.mat, d.fk_tasignatura
    ),
    final_agregado AS (
        SELECT fa.mat,
               COALESCE(BOOL_OR(fa.es_numerico), FALSE) AS hay_numerico,
               COUNT(*)                                 AS total,
               COUNT(*) FILTER (
                   WHERE fa.nota >= COALESCE(fa.minimo, v_minimo))         AS aprob,
               COUNT(*) FILTER (
                   WHERE fa.nota <  COALESCE(fa.minimo, v_minimo))         AS reprob,
               COUNT(*) FILTER (
                   WHERE fa.nota IS NULL
                      OR COALESCE(fa.minimo, v_minimo) IS NULL)            AS sindef,
               ROUND(AVG(fa.nota), 2)                   AS promedio,
               JSONB_AGG(
                   JSONB_BUILD_OBJECT(
                       'asignatura',  fa.asig,
                       'nombre',      fa.nombre,
                       'abreviacion', fa.abrev,
                       'area',        fa.area,
                       'orden',       fa.orden,
                       'nota',        h.nota_homologada,
                       'estado',      'final',
                       'es_numerico', fa.es_numerico,
                       'valoracion',  h.valoracion_nombre,
                       'simbolo',     h.valoracion_simbolo,
                       'aprobada',    CASE
                                          WHEN fa.nota IS NULL
                                            OR COALESCE(fa.minimo, v_minimo) IS NULL
                                          THEN NULL
                                          ELSE fa.nota >= COALESCE(fa.minimo, v_minimo)
                                      END
                   ) ORDER BY fa.orden NULLS LAST, fa.nombre
               )                                        AS asigs
          FROM final_asig fa
          LEFT JOIN LATERAL academico_test.fn_nota_homologar(
                        fa.nota, fa.asig, v_fk_grado) h ON TRUE
         GROUP BY fa.mat
    ),
    -- *** V435 *** Cuantos resumenes de periodo hay HOY. Es lo que se compara
    -- contra PERIODOS_ORIGEN para saber si el texto del año quedo viejo: lo
    -- que lo envejece es que se cierre un periodo nuevo, no que el docente
    -- escriba una observacion mas.
    final_periodos_hoy AS (
        SELECT e.pk AS mat,
               (SELECT COUNT(*)
                  FROM academico_test.TESTUDIANTE_PERIODO_OBSERVACION ob2
                  JOIN academico_test.TPERIODO_EVALUACION pe3
                    ON pe3.PK_TPERIODO_EVALUACION = ob2.FK_TPERIODO_EVALUACION
                   AND pe3.ACTIVE = TRUE
                   AND pe3.FK_TPERIODO_ACADEMICO = v_fk_peraca
                 WHERE ob2.FK_TMATRICULA = e.pk
                   AND ob2.ACTIVE = TRUE
                   AND NULLIF(TRIM(COALESCE(ob2.OBSERVACION, '')), '') IS NOT NULL
               ) AS n
          FROM estudiantes_final e
    ),
    final_evidencias AS (
        SELECT e.pk AS mat,
               (SELECT COUNT(*)
                  FROM academico_test.TACTIVIDAD_SOPORTE so
                  JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae5
                    ON ae5.PK_TACTIVIDAD_ESTUDIANTE = so.FK_TACTIVIDAD_ESTUDIANTE
                   AND ae5.FK_TMATRICULA = e.pk
                   AND ae5.ACTIVE = TRUE
                  JOIN academico_test.TACTIVIDAD a6
                    ON a6.PK_TACTIVIDAD = ae5.FK_TACTIVIDAD
                   AND a6.ACTIVE = TRUE
                 WHERE so.ACTIVE = TRUE
                   AND so.FK_TARCHIVO IS NOT NULL
                   AND EXISTS (SELECT 1
                                 FROM academico_test.TPERIODO_EVALUACION pe2
                                WHERE pe2.ACTIVE = TRUE
                                  AND pe2.FK_TPERIODO_ACADEMICO = v_fk_peraca
                                  AND academico_test.fn_actividad_en_periodo_eval(
                                          a6.PK_TACTIVIDAD, pe2.PK_TPERIODO_EVALUACION) = TRUE)
               ) AS n
          FROM estudiantes_final e
    ),
    final_fila AS (
        SELECT e.pk AS mat,
               e.nombre,
               e.doc,
               COALESCE(fg.hay_numerico, FALSE) AS hay_numerico,
               COALESCE(fg.total,  0)           AS total,
               COALESCE(fg.aprob,  0)           AS aprob,
               COALESCE(fg.reprob, 0)           AS reprob,
               COALESCE(fg.sindef, 0)           AS sindef,
               fg.promedio,
               COALESCE(fg.asigs, '[]'::JSONB)  AS asigs,
               -- *** V435 *** Lo GUARDADO, no el concatenado. El concatenado
               -- pasa a ser el borrador que devuelve generar, asi que la fila
               -- arranca vacia como los periodos hasta que alguien lo acepte.
               ao.OBSERVACION                   AS obs,
               lva.VALOR                        AS obs_estado,
               CASE WHEN ao.PK_TESTUDIANTE_ANIO_OBSERVACION IS NULL THEN NULL
                    ELSE COALESCE(fph.n, 0) > COALESCE(ao.PERIODOS_ORIGEN, 0)
               END                              AS obs_vieja,
               COALESCE(fe.n, 0)                AS evid
          FROM estudiantes_final e
          LEFT JOIN final_agregado     fg  ON fg.mat  = e.pk
          LEFT JOIN final_evidencias   fe  ON fe.mat  = e.pk
          LEFT JOIN final_periodos_hoy fph ON fph.mat = e.pk
          LEFT JOIN academico_test.TESTUDIANTE_ANIO_OBSERVACION ao
                 ON ao.FK_TMATRICULA = e.pk
                AND ao.ACTIVE = TRUE
          LEFT JOIN academico_test.TLISTA_VALOR lva
                 ON lva.PK_LISTA_VALOR = ao.FK_TLV_ESTADO_OBSERVACION
    ),
    final_puesto AS (
        SELECT ff.*,
               CASE WHEN ff.hay_numerico IS TRUE AND ff.promedio IS NOT NULL
                    THEN RANK() OVER (ORDER BY ff.promedio DESC NULLS LAST)
               END AS pos
          FROM final_fila ff
    ),

    salida AS (
        SELECT cp.mat                    AS o_mat,
               cp.nombre                 AS o_nombre,
               cp.doc                    AS o_doc,
               cp.pe                     AS o_pe,
               cp.pe_nombre              AS o_pe_nombre,
               cp.pe_abrev               AS o_pe_abrev,
               cp.pe_inicio              AS o_pe_inicio,
               CASE WHEN cp.es_requerido THEN 'requerido' ELSE 'real' END::VARCHAR
                                         AS o_modo,
               CASE WHEN cp.es_num_final THEN 'numerico' ELSE 'cualitativo' END::VARCHAR
                                         AS o_formato,
               NOT cp.es_num_final       AS o_cualitativo,
               CASE WHEN cp.es_requerido THEN FALSE ELSE cp.esta_consolidado END
                                         AS o_consolidado,
               CASE WHEN cp.es_requerido THEN NULL ELSE cp.prom_guardado END
                                         AS o_prom_guardado,
               CASE WHEN cp.es_requerido THEN v_minimo
                    ELSE ROUND(cp.calc_prom_proyectado, 2) END
                                         AS o_prom_proyectado,
               cp.pos                    AS o_puesto,
               CASE WHEN cp.es_requerido THEN cp.req_total ELSE cp.total_asig END::BIGINT
                                         AS o_total,
               CASE WHEN cp.es_requerido THEN 0 ELSE cp.aprob  END::BIGINT AS o_aprob,
               CASE WHEN cp.es_requerido THEN 0 ELSE cp.reprob END::BIGINT AS o_reprob,
               CASE WHEN cp.es_requerido THEN cp.req_total ELSE cp.sindef END::BIGINT
                                         AS o_sindef,
               cp.cambios                AS o_cambios,
               CASE WHEN cp.es_requerido THEN cp.req_asigs ELSE cp.asigs END
                                         AS o_asigs,
               cp.obs                    AS o_obs,
               cp.obs_estado             AS o_obs_estado,
               cp.obs_vieja              AS o_obs_vieja,
               cp.evid::BIGINT           AS o_evidencias
          FROM con_puesto cp

        UNION ALL

        SELECT fp.mat,
               fp.nombre,
               fp.doc,
               (-1)::BIGINT,
               'Final'::VARCHAR,
               'FIN'::VARCHAR,
               '9999-12-31'::DATE,
               'final'::VARCHAR,
               CASE WHEN fp.hay_numerico THEN 'numerico' ELSE 'cualitativo' END::VARCHAR,
               NOT fp.hay_numerico,
               FALSE,
               CASE WHEN fp.hay_numerico THEN fp.promedio END,
               CASE WHEN fp.hay_numerico THEN fp.promedio END,
               fp.pos,
               CASE WHEN fp.hay_numerico THEN fp.total  ELSE 0 END::BIGINT,
               CASE WHEN fp.hay_numerico THEN fp.aprob  ELSE 0 END::BIGINT,
               CASE WHEN fp.hay_numerico THEN fp.reprob ELSE 0 END::BIGINT,
               CASE WHEN fp.hay_numerico THEN fp.sindef ELSE 0 END::BIGINT,
               FALSE,
               CASE WHEN fp.hay_numerico THEN fp.asigs ELSE '[]'::JSONB END,
               fp.obs,
               fp.obs_estado,
               fp.obs_vieja,
               fp.evid::BIGINT
          FROM final_puesto fp
    )
    SELECT s.o_mat,
           s.o_nombre,
           s.o_doc,
           s.o_pe,
           s.o_pe_nombre,
           s.o_pe_abrev,
           s.o_pe_inicio,
           s.o_modo,
           s.o_formato,
           s.o_cualitativo,
           s.o_consolidado,
           -- V474 -- el promedio ya no sale en porcentaje: se homologa con el
           -- formato del criterio general del periodo academico, el mismo
           -- criterio con el que la pantalla pinta cada asignatura. En un
           -- formato no numerico estos dos vienen NULL y lo que vale es la
           -- valoracion, al final de la fila.
           hg.promedio,
           hp.promedio,
           s.o_puesto,
           s.o_total,
           s.o_aprob,
           s.o_reprob,
           s.o_sindef,
           s.o_cambios,
           s.o_asigs,
           s.o_obs,
           s.o_obs_estado,
           s.o_obs_vieja,
           s.o_evidencias,
           COUNT(*) OVER ()::BIGINT,
           hg.valoracion_nombre,
           hg.valoracion_simbolo,
           hp.valoracion_nombre,
           hp.valoracion_simbolo,
           COALESCE(hg.formato_valor, hp.formato_valor)
      FROM salida s
      -- Las dos laterales devuelven SIEMPRE una fila -- con todo en NULL si no
      -- hay porcentaje --, asi que no pueden perder estudiantes.
      LEFT JOIN LATERAL academico_test.fn_promedio_homologar(
                    s.o_prom_guardado, v_fk_peraca) hg ON TRUE
      LEFT JOIN LATERAL academico_test.fn_promedio_homologar(
                    s.o_prom_proyectado, v_fk_peraca) hp ON TRUE
     WHERE NULLIF(TRIM(COALESCE(p_search, '')), '') IS NULL
        OR s.o_nombre ILIKE '%' || TRIM(p_search) || '%'
        OR s.o_doc    ILIKE '%' || TRIM(p_search) || '%'
     ORDER BY s.o_nombre NULLS LAST, s.o_mat, s.o_pe_inicio;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_grupo_listar(BIGINT, BIGINT, BIGINT[], CHARACTER VARYING)
    IS 'Listado principal de informes: una fila por (estudiante, periodo) del grupo. EL FINAL SE PIDE METIENDO -1 EN PERIODOS (V439), que es el mismo centinela con el que esa fila viaja en FK_TPERIODO_EVALUACION; antes era el parametro p_incluir_final, que se retira. El cambio no es cosmetico: como -1 no matchea ningun periodo real, ARRAY[-1] deja la CTE de periodos vacia y por fin se puede pedir SOLO el Final -- con la bandera era imposible, porque un arreglo vacio significa (y sigue significando) TODOS los periodos reales, de modo que no habia forma de decir "ninguno". La fila Final llega con FK_TPERIODO_EVALUACION = -1, modo_periodo "final", consolidado false y asignaturas con estado "final"; su nota se calcula al vuelo sobre TODOS los periodos del año, el periodo sin nota guardada vale cero y el promedio general sale de esas mismas asignaturas (V431). EVIDENCIAS cuenta las imagenes adjuntas a observaciones de la fila, y en el Final las del año (V434). Su observacion es la que este GUARDADA en TESTUDIANTE_ANIO_OBSERVACION, con su estado y su marca de desactualizado, que se dispara cuando se CONSOLIDA UN PERIODO NUEVO y no cuando el docente escribe una observacion mas (V435). V335, V411, V412, V428, V431, V434, V435, V439. V474: PROMEDIO_GUARDADO y PROMEDIO_PROYECTADO ya NO salen en porcentaje -- se homologan con fn_promedio_homologar al formato del criterio de evaluacion GENERAL del periodo academico, el mismo con el que se pintan las asignaturas de la fila; antes la columna PR mostraba 70,0 al lado de asignaturas en 3,3. En un formato no numerico los dos vienen NULL y lo que vale son PROMEDIO_VALORACION / PROMEDIO_SIMBOLO y sus gemelas del proyectado; sin criterio configurado se sigue devolviendo el porcentaje crudo. PROMEDIO_FORMATO dice con cual se homologo. Cubre tambien el promedio de la fila Final y la nota requerida que viaja en PROMEDIO_PROYECTADO, porque la conversion esta en un solo punto de la salida. El PUESTO se sigue calculando sobre el porcentaje: la conversion es monotona y redondear antes de ordenar crearia empates que no existen. V540: cada asignatura del JSON trae CON_RECUPERACION y, si hubo recuperacion de destino NOTA_FINAL, NOTA_ORIGINAL / VALORACION_ORIGINAL / SIMBOLO_ORIGINAL (la nota antes de recuperar, homologada); NOTA sigue siendo la resultante (Regla 68). El PROMEDIO_PROYECTADO usa la resultante en las asignaturas recuperadas, porque la proyectada excluye la actividad de recuperacion.';
