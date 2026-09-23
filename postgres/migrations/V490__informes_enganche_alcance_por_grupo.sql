-- ===========================================================================
-- V490 - Se engancha el recorte por grupo en los puntos de entrada.
--
--   V489 definio la regla (fn_informe_assert_grupo_propio) pero nadie la
--   llamaba. Aqui se llama, y con eso empieza a aplicar.
--
--
-- DOS FORMAS, SEGUN LA PREGUNTA
--   En el LISTADO de grupos se FILTRAN las filas: la pregunta es "cuales
--   puedo ver" y la respuesta correcta es la lista corta, no un error.
--
--   En todo lo que recibe un grupo o una matricula CONCRETOS se falla con
--   42501: pedir por id el informe de un grupo ajeno no es "no hay datos"
--   sino no tener permiso, y devolver vacio ahi se lee como que al grupo
--   le falta configuracion.
--
--
-- QUE SE ENGANCHA Y QUE NO
--   Se enganchan los que ABREN DATOS de un grupo concreto -- leerlos o
--   escribirlos -- y el listado. Las escrituras son las que mas importan:
--   hasta aqui un docente podia consolidar notas o guardar la observacion
--   de un estudiante de otro grupo de su sede.
--
--   NO se enganchan, a proposito:
--
--     fn_informe_grupo_reporte / _tabla / fn_informe_boletin_preescolar
--       delegan en fn_informe_grupo_listar, asi que ya quedan cubiertos.
--       Agregarlo seria repetir el mismo control dos veces por llamada.
--
--     fn_informe_estudiante_asignaturas, fn_informe_periodo_requerido,
--     fn_informe_metricas_recalcular, fn_informe_historial_registrar
--       son internas: no tienen fila en public.query. Sus callers si estan
--       enganchados. Y la primera se llama UNA VEZ POR ESTUDIANTE desde el
--       listado, de modo que el control ahi se pagaria treinta veces por
--       pantalla para responder lo mismo que ya se respondio arriba.
--
--     fn_informe_planillas_pendientes, fn_informe_cambios_pendientes,
--     fn_informe_historial_listar
--       reciben un ARREGLO de grupos y son agregados, no accesos: lo que
--       devuelven son alertas y registros de lo que ya paso, no los datos
--       del informe. Dejarlas fuera no abre ningun dato que el usuario no
--       pueda pedir por otro lado -- para verlos tendria que pasar por las
--       que si estan enganchadas. Lo que si producen es RUIDO: un docente
--       vera alertas e historial de grupos que no puede abrir. Es un
--       problema de experiencia, no de seguridad, y se arregla filtrando
--       igual que el listado. Queda anotado.
--
-- Idempotente: solo CREATE OR REPLACE, y ninguna cambia de firma.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- fn_informe_grupo_listar
-- ---------------------------------------------------------------------------
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
               AVG(COALESCE(d.nota_proyectada, d.nota_guardada)) AS calc_prom_proyectado,
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
                           'aprobada',    d.aprobada
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
               SUM(COALESCE(d.nota_guardada, 0)) / NULLIF(v_n_periodos, 0) AS nota
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
$function$
;

-- ---------------------------------------------------------------------------
-- fn_informe_planilla_listar
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_informe_planilla_listar(p_pk_usuario_solicitante bigint, p_fk_tgrupo bigint, p_fk_tasignatura bigint, p_fk_tperiodo_evaluacion bigint, p_search character varying DEFAULT NULL::character varying)
 RETURNS TABLE(fk_tmatricula bigint, fk_testudiante bigint, estudiante character varying, documento character varying, definitiva_guardada numeric, definitiva_proyectada numeric, definitiva_guardada_homologada numeric, definitiva_proyectada_homologada numeric, estado_nota character varying, es_numerico boolean, nota_maxima numeric, formato_valor character varying, valoracion_nombre character varying, aprobada boolean, actividades jsonb, total_count bigint)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_fk_grado    BIGINT;
    v_fk_peraca   BIGINT;
    v_fk_sede     BIGINT;
    v_fk_jornada  BIGINT;
    v_fk_ee       BIGINT;
    v_pe_peraca   BIGINT;
    v_minimo      NUMERIC;
    v_search      VARCHAR;
    v_hay_alumno  BOOLEAN := FALSE;
    v_hay_activ   BOOLEAN := FALSE;
BEGIN
    -- -----------------------------------------------------------------
    -- 1. Ubicacion del grupo y alcance.
    -- -----------------------------------------------------------------
    SELECT gd.PK_TGRADO, gd.FK_TPERIODO_ACADEMICO,
           s.PK_TSEDE, gr.FK_TLV_JORNADA, s.FK_TESTABLECIMIENTO
      INTO v_fk_grado, v_fk_peraca, v_fk_sede, v_fk_jornada, v_fk_ee
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

    -- Validador PURO de V239: mismo filtro invalido, mismo error en las dos
    -- planillas. No tiene gate ni efectos, por eso se puede reutilizar.
    PERFORM academico_test.fn_planilla_grupo_asignatura_assert(
        p_fk_tgrupo, p_fk_tasignatura, v_fk_grado);

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
        RAISE EXCEPTION 'El periodo de evaluacion no pertenece al periodo academico del grupo'
            USING ERRCODE = '22023';
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
    v_search := NULLIF(TRIM(COALESCE(p_search, '')), '');

    -- -----------------------------------------------------------------
    -- 2. Contra que coincidio la busqueda. Se resuelve ANTES de filtrar,
    --    porque la regla es "la dimension sin coincidencias se deja
    --    intacta" y eso no se puede decidir mirando una sola.
    -- -----------------------------------------------------------------
    IF v_search IS NOT NULL THEN
        SELECT EXISTS (
            SELECT 1
              FROM academico_test.TMATRICULA m
              LEFT JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
              LEFT JOIN academico_test.TUSUARIO u     ON u.PK_TUSUARIO     = es.FK_TUSUARIO
             WHERE m.FK_TGRUPO = p_fk_tgrupo
               AND m.ACTIVE = TRUE
               AND (CONCAT_WS(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
                                   u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO) ILIKE '%' || v_search || '%'
                    OR u.IDENTIFICACION ILIKE '%' || v_search || '%')
        ) INTO v_hay_alumno;

        SELECT EXISTS (
            SELECT 1
              FROM academico_test.TACTIVIDAD a
             WHERE a.ACTIVE = TRUE
               AND a.FK_TASIGNATURA = p_fk_tasignatura
               AND academico_test.fn_actividad_en_periodo_eval(
                       a.PK_TACTIVIDAD, p_fk_tperiodo_evaluacion) = TRUE
               AND EXISTS (
                     SELECT 1
                       FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
                       JOIN academico_test.TMATRICULA m2 ON m2.PK_TMATRICULA = ae.FK_TMATRICULA
                      WHERE ae.FK_TACTIVIDAD = a.PK_TACTIVIDAD
                        AND ae.ACTIVE = TRUE
                        AND m2.FK_TGRUPO = p_fk_tgrupo
                   )
               AND a.TITULO ILIKE '%' || v_search || '%'
        ) INTO v_hay_activ;

        -- Si no coincidio con NINGUNA de las dos dimensiones no hay
        -- resultados, y hay que cortar aqui: la regla de "dejar intacta la
        -- dimension sin coincidencias" aplicada a las dos a la vez devolveria
        -- la tabla completa, que es justo lo contrario de lo que espera quien
        -- escribio un texto que no existe.
        IF NOT v_hay_alumno AND NOT v_hay_activ THEN
            RETURN;
        END IF;
    END IF;

    RETURN QUERY
    WITH estudiantes AS (
        SELECT m.PK_TMATRICULA AS mat,
               es.PK_TESTUDIANTE AS est,
               NULLIF(TRIM(CONCAT_WS(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
                                          u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO)),
                      '')::VARCHAR AS nombre,
               u.IDENTIFICACION::VARCHAR AS doc
          FROM academico_test.TMATRICULA m
          LEFT JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
          LEFT JOIN academico_test.TUSUARIO u     ON u.PK_TUSUARIO     = es.FK_TUSUARIO
         WHERE m.FK_TGRUPO = p_fk_tgrupo
           AND m.ACTIVE = TRUE
           -- Se filtra solo si el texto coincidio con ALGUN alumno.
           AND (v_search IS NULL OR NOT v_hay_alumno
                OR CONCAT_WS(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
                                  u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO) ILIKE '%' || v_search || '%'
                OR u.IDENTIFICACION ILIKE '%' || v_search || '%')
    ),
    -- Las COLUMNAS: actividades de la asignatura que caen en el periodo y
    -- tienen al menos un estudiante de este grupo asignado. Esa segunda
    -- condicion es la que hace que una actividad sin FK_TGRUPO pertenezca a
    -- esta planilla -- la trae el haberle asignado alumnos de aqui, no un
    -- campo. Es el mismo criterio de fn_planilla_actividades_universo.
    columnas AS (
        SELECT a.PK_TACTIVIDAD AS pk,
               a.TITULO        AS titulo,
               a.FK_TUNIDAD    AS unidad,
               a.PONDERACION   AS ponderacion,
               a.NOTA_MAXIMA   AS nota_maxima,
               a.ES_EVALUATIVA AS evaluativa,
               a.FECHA_INICIO  AS f_ini,
               a.FECHA_CIERRE  AS f_cie,
               ie.VALOR        AS instrumento,
               ROW_NUMBER() OVER (
                   ORDER BY tu.NOMBRE NULLS LAST, a.FECHA_INICIO NULLS LAST, a.PK_TACTIVIDAD
               )::INT          AS orden
          FROM academico_test.TACTIVIDAD a
          LEFT JOIN academico_test.TUNIDAD tu ON tu.PK_TUNIDAD = a.FK_TUNIDAD
          LEFT JOIN academico_test.TLISTA_VALOR ie
                 ON ie.PK_LISTA_VALOR = a.FK_TLV_INSTRUMENTO_EVALUACION
         WHERE a.ACTIVE = TRUE
           AND a.FK_TASIGNATURA = p_fk_tasignatura
           AND academico_test.fn_actividad_en_periodo_eval(
                   a.PK_TACTIVIDAD, p_fk_tperiodo_evaluacion) = TRUE
           AND EXISTS (
                 SELECT 1
                   FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
                   JOIN academico_test.TMATRICULA m2 ON m2.PK_TMATRICULA = ae.FK_TMATRICULA
                  WHERE ae.FK_TACTIVIDAD = a.PK_TACTIVIDAD
                    AND ae.ACTIVE = TRUE
                    AND m2.FK_TGRUPO = p_fk_tgrupo
                    AND m2.ACTIVE = TRUE
               )
           -- Se filtra solo si el texto coincidio con ALGUNA actividad.
           AND (v_search IS NULL OR NOT v_hay_activ
                OR a.TITULO ILIKE '%' || v_search || '%')
    ),
    base AS (
        SELECT e.*,
               sn.DEFINITIVA AS guardada,
               academico_test.fn_asignatura_definitiva_proyectada_periodo(
                   e.mat, p_fk_tasignatura, p_fk_tperiodo_evaluacion) AS proyectada
          FROM estudiantes e
          LEFT JOIN academico_test.TASIGNATURA_NOTA sn
                 ON sn.FK_TMATRICULA          = e.mat
                AND sn.FK_TASIGNATURA         = p_fk_tasignatura
                AND sn.FK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion
                AND sn.ACTIVE = TRUE
    )
    SELECT b.mat,
           b.est,
           b.nombre,
           b.doc,
           b.guardada,
           b.proyectada,
           hg.nota_homologada,
           hp.nota_homologada,
           -- Mismo vocabulario que fn_informe_estudiante_asignaturas (V334):
           -- el front no aprende dos juegos de estados para la misma idea.
           CASE
               WHEN b.guardada IS NULL AND b.proyectada IS NULL THEN 'sin_nota'
               WHEN b.guardada IS NULL                          THEN 'proyectada'
               WHEN b.proyectada IS NULL                        THEN 'cambio_propuesto'
               WHEN b.proyectada = b.guardada                   THEN 'guardada'
               ELSE 'cambio_propuesto'
           END::VARCHAR,
           COALESCE(hv.formato_valor IN ('CINCO', 'DIEZ', 'CIEN'), FALSE),
           hv.nota_maxima,
           hv.formato_valor,
           hv.valoracion_nombre,
           CASE WHEN v_minimo IS NULL
                     OR COALESCE(b.guardada, b.proyectada) IS NULL THEN NULL
                ELSE COALESCE(b.guardada, b.proyectada) >= v_minimo
           END,
           COALESCE(cel.celdas, '[]'::JSONB),
           COUNT(*) OVER ()::BIGINT
      FROM base b
      -- Tres homologaciones distintas porque convierten valores distintos: lo
      -- guardado, lo proyectado, y lo VISIBLE (de donde salen formato y
      -- valoracion, que describen lo que se pinta).
      LEFT JOIN LATERAL academico_test.fn_nota_homologar(
                    b.guardada, p_fk_tasignatura, v_fk_grado) hg ON TRUE
      LEFT JOIN LATERAL academico_test.fn_nota_homologar(
                    b.proyectada, p_fk_tasignatura, v_fk_grado) hp ON TRUE
      LEFT JOIN LATERAL academico_test.fn_nota_homologar(
                    COALESCE(b.guardada, b.proyectada), p_fk_tasignatura, v_fk_grado) hv ON TRUE
      LEFT JOIN LATERAL (
            SELECT JSONB_AGG(
                       JSONB_BUILD_OBJECT(
                           'orden',                  c.orden,
                           'pkTactividad',           c.pk,
                           'titulo',                 c.titulo,
                           'pkTunidad',              c.unidad,
                           -- Llave que necesita el popover para precargar y
                           -- guardar. NULL cuando la celda no aplica: por
                           -- construccion no se puede calificar una actividad
                           -- que el estudiante no tiene asignada.
                           'pkTactividadEstudiante', ae.PK_TACTIVIDAD_ESTUDIANTE,
                           'estado',
                               CASE
                                   WHEN ae.PK_TACTIVIDAD_ESTUDIANTE IS NULL   THEN 'NO_ASIGNADA'
                                   WHEN COALESCE(n.CALIFICABLE, 'S') = 'N'    THEN 'NO_CALIFICABLE'
                                   WHEN COALESCE(n.DEFINITIVA, n.CALIFICACION) IS NOT NULL
                                                                              THEN 'CALIFICADA'
                                   ELSE 'PENDIENTE'
                               END,
                           'porcentaje',  COALESCE(n.DEFINITIVA, n.CALIFICACION),
                           'nota',        hc.nota_homologada,
                           'valoracion',  hc.valoracion_nombre,
                           'resultadoInstrumento',
                               academico_test.fn_actividad_nota_resultado_instrumento(ae.PK_TACTIVIDAD_ESTUDIANTE),
                           'observacion', NULLIF(TRIM(COALESCE(n.OBSERVACION, '')), ''),
                           'esEvaluativa', COALESCE(c.evaluativa::VARCHAR, 'S') = 'S',
                           'ponderacion', c.ponderacion,
                           'notaMaxima',  c.nota_maxima,
                           'instrumento', c.instrumento,
                           'fechaInicio', c.f_ini,
                           'fechaCierre', c.f_cie
                       ) ORDER BY c.orden
                   ) AS celdas
              FROM columnas c
              LEFT JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
                     ON ae.FK_TACTIVIDAD = c.pk
                    AND ae.FK_TMATRICULA = b.mat
                    AND ae.ACTIVE = TRUE
              LEFT JOIN academico_test.TACTIVIDAD_NOTA n
                     ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                    AND n.ACTIVE = TRUE
              LEFT JOIN LATERAL academico_test.fn_nota_homologar(
                            COALESCE(n.DEFINITIVA, n.CALIFICACION),
                            p_fk_tasignatura, v_fk_grado) hc ON TRUE
      ) cel ON TRUE
     ORDER BY b.nombre NULLS LAST, b.mat;
END;
$function$
;

-- ---------------------------------------------------------------------------
-- fn_informe_periodo_guardar
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_informe_periodo_guardar(p_pk_usuario_solicitante bigint, p_fk_tgrupo bigint, p_fk_tperiodo_evaluacion bigint, p_fk_tmatriculas bigint[] DEFAULT NULL::bigint[])
 RETURNS TABLE(fk_tmatricula bigint, estudiante character varying, guardadas bigint, actualizadas bigint, sin_proyeccion bigint, sin_cambio bigint, promedio numeric, aprobadas bigint, reprobadas bigint, detalle jsonb)
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
DECLARE
    v_fk_sede    BIGINT;
    v_fk_jornada BIGINT;
    v_fk_ee      BIGINT;
    v_fk_peraca  BIGINT;
    v_pe_peraca  BIGINT;
    r_mat        RECORD;
    r_asig       RECORD;
    v_prev       NUMERIC;
    v_existe     BOOLEAN;
    v_g          BIGINT;
    v_a          BIGINT;
    v_s          BIGINT;
    v_n          BIGINT;
    v_det        JSONB;
    v_m          RECORD;
    v_hist       JSONB := '[]'::JSONB;
BEGIN
    SELECT s.PK_TSEDE, gr.FK_TLV_JORNADA, s.FK_TESTABLECIMIENTO,
           gd.FK_TPERIODO_ACADEMICO
      INTO v_fk_sede, v_fk_jornada, v_fk_ee, v_fk_peraca
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
        RAISE EXCEPTION 'El periodo de evaluacion no pertenece al periodo academico del grupo'
            USING ERRCODE = '22023';
    END IF;

    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'INFORMES', 'EDITAR',
        v_fk_ee, v_fk_sede, v_fk_jornada
    );

    -- V490 -- el recorte por grupo, DESPUES del gate de arriba. Para
    -- quien alcanza la sede entera es un no-op.
    PERFORM academico_test.fn_informe_assert_grupo_propio(
        p_pk_usuario_solicitante, p_fk_tgrupo);

    FOR r_mat IN
        SELECT m.PK_TMATRICULA AS pk,
               NULLIF(TRIM(CONCAT_WS(' ', u.PRIMER_NOMBRE, u.PRIMER_APELLIDO)), '')::VARCHAR AS nombre
          FROM academico_test.TMATRICULA m
          LEFT JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
          LEFT JOIN academico_test.TUSUARIO u     ON u.PK_TUSUARIO     = es.FK_TUSUARIO
         WHERE m.FK_TGRUPO = p_fk_tgrupo
           AND m.ACTIVE = TRUE
           AND (p_fk_tmatriculas IS NULL
                OR CARDINALITY(p_fk_tmatriculas) = 0
                OR m.PK_TMATRICULA = ANY (p_fk_tmatriculas))
         ORDER BY 2, 1
    LOOP
        v_g := 0; v_a := 0; v_s := 0; v_n := 0; v_det := '[]'::JSONB;

        FOR r_asig IN
            SELECT d.fk_tasignatura, d.asignatura_nombre, d.nota_proyectada
              FROM academico_test.fn_informe_estudiante_asignaturas(
                       p_pk_usuario_solicitante, r_mat.pk,
                       ARRAY[p_fk_tperiodo_evaluacion]::BIGINT[]) d
        LOOP
            IF r_asig.nota_proyectada IS NULL THEN
                v_s := v_s + 1;
                v_det := v_det || JSONB_BUILD_OBJECT(
                    'asignatura', r_asig.asignatura_nombre,
                    'resultado',  'sin_proyeccion');
                CONTINUE;
            END IF;

            SELECT sn.DEFINITIVA, TRUE
              INTO v_prev, v_existe
              FROM academico_test.TASIGNATURA_NOTA sn
             WHERE sn.FK_TMATRICULA          = r_mat.pk
               AND sn.FK_TASIGNATURA         = r_asig.fk_tasignatura
               AND sn.FK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion
               AND sn.ACTIVE = TRUE;

            IF COALESCE(v_existe, FALSE) AND v_prev = r_asig.nota_proyectada THEN
                v_n := v_n + 1;
                v_det := v_det || JSONB_BUILD_OBJECT(
                    'asignatura', r_asig.asignatura_nombre,
                    'resultado',  'sin_cambio',
                    'nota',       r_asig.nota_proyectada);
                v_existe := NULL;
                CONTINUE;
            END IF;

            INSERT INTO academico_test.TASIGNATURA_NOTA (
                FK_TMATRICULA, FK_TASIGNATURA, FK_TPERIODO_EVALUACION,
                CALIFICACION, DEFINITIVA, CREATED_BY, CREATED_AT, ACTIVE
            ) VALUES (
                r_mat.pk, r_asig.fk_tasignatura, p_fk_tperiodo_evaluacion,
                r_asig.nota_proyectada, r_asig.nota_proyectada,
                p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
            )
            ON CONFLICT (FK_TMATRICULA, FK_TPERIODO_EVALUACION, FK_TASIGNATURA)
                WHERE ACTIVE
            DO UPDATE SET CALIFICACION = EXCLUDED.CALIFICACION,
                          DEFINITIVA   = EXCLUDED.DEFINITIVA,
                          MODIFIED_BY  = p_pk_usuario_solicitante::VARCHAR,
                          MODIFIED_AT  = CURRENT_TIMESTAMP;

            IF COALESCE(v_existe, FALSE) THEN
                v_a := v_a + 1;
                v_det := v_det || JSONB_BUILD_OBJECT(
                    'asignatura', r_asig.asignatura_nombre,
                    'resultado',  'actualizada',
                    'nota',       r_asig.nota_proyectada,
                    'anterior',   v_prev);
            ELSE
                v_g := v_g + 1;
                v_det := v_det || JSONB_BUILD_OBJECT(
                    'asignatura', r_asig.asignatura_nombre,
                    'resultado',  'guardada',
                    'nota',       r_asig.nota_proyectada);
            END IF;

            v_existe := NULL;
        END LOOP;

        PERFORM academico_test.fn_informe_metricas_recalcular(
            p_pk_usuario_solicitante, r_mat.pk, p_fk_tperiodo_evaluacion);

        SELECT ipm.PROMEDIO, ipm.APROBADAS, ipm.REPROBADAS
          INTO v_m
          FROM academico_test.TINFORME_PERIODO_MATRICULA ipm
         WHERE ipm.FK_TMATRICULA          = r_mat.pk
           AND ipm.FK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion
           AND ipm.ACTIVE = TRUE;

        -- Al historial SOLO si se escribio algo. Ver el punto (2).
        IF v_g + v_a > 0 THEN
            v_hist := v_hist || JSONB_BUILD_OBJECT(
                'matricula',   r_mat.pk,
                'promedio',    v_m.PROMEDIO,
                'asignaturas', v_g + v_a);
        END IF;

        fk_tmatricula  := r_mat.pk;
        estudiante     := r_mat.nombre;
        guardadas      := v_g;
        actualizadas   := v_a;
        sin_proyeccion := v_s;
        sin_cambio     := v_n;
        promedio       := v_m.PROMEDIO;
        aprobadas      := COALESCE(v_m.APROBADAS, 0)::BIGINT;
        reprobadas     := COALESCE(v_m.REPROBADAS, 0)::BIGINT;
        detalle        := v_det;
        RETURN NEXT;
    END LOOP;

    PERFORM academico_test.fn_informe_historial_registrar(
        p_pk_usuario_solicitante, p_fk_tgrupo, NULL,
        p_fk_tperiodo_evaluacion, 'INFORME', v_hist);
END;
$function$
;

-- ---------------------------------------------------------------------------
-- fn_informe_planilla_guardar
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_informe_planilla_guardar(p_pk_usuario_solicitante bigint, p_fk_tgrupo bigint, p_fk_tasignatura bigint, p_fk_tperiodo_evaluacion bigint, p_fk_tmatriculas bigint[] DEFAULT NULL::bigint[])
 RETURNS TABLE(fk_tmatricula bigint, estudiante character varying, resultado character varying, nota_anterior numeric, nota_guardada numeric, promedio_periodo numeric, aprobadas bigint, reprobadas bigint)
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
DECLARE
    v_fk_grado   BIGINT;
    v_fk_peraca  BIGINT;
    v_fk_sede    BIGINT;
    v_fk_jornada BIGINT;
    v_fk_ee      BIGINT;
    v_pe_peraca  BIGINT;
    r_mat        RECORD;
    v_proy       NUMERIC;
    v_prev       NUMERIC;
    v_existe     BOOLEAN;
    v_res        VARCHAR;
    v_m          RECORD;
    v_hist       JSONB := '[]'::JSONB;
BEGIN
    SELECT gd.PK_TGRADO, gd.FK_TPERIODO_ACADEMICO,
           s.PK_TSEDE, gr.FK_TLV_JORNADA, s.FK_TESTABLECIMIENTO
      INTO v_fk_grado, v_fk_peraca, v_fk_sede, v_fk_jornada, v_fk_ee
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

    PERFORM academico_test.fn_planilla_grupo_asignatura_assert(
        p_fk_tgrupo, p_fk_tasignatura, v_fk_grado);

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
        RAISE EXCEPTION 'El periodo de evaluacion no pertenece al periodo academico del grupo'
            USING ERRCODE = '22023';
    END IF;

    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'INFORMES', 'EDITAR',
        v_fk_ee, v_fk_sede, v_fk_jornada
    );

    -- V490 -- el recorte por grupo, DESPUES del gate de arriba. Para
    -- quien alcanza la sede entera es un no-op.
    PERFORM academico_test.fn_informe_assert_grupo_propio(
        p_pk_usuario_solicitante, p_fk_tgrupo);

    FOR r_mat IN
        SELECT m.PK_TMATRICULA AS pk,
               NULLIF(TRIM(CONCAT_WS(' ', u.PRIMER_NOMBRE, u.PRIMER_APELLIDO)), '')::VARCHAR AS nombre
          FROM academico_test.TMATRICULA m
          LEFT JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
          LEFT JOIN academico_test.TUSUARIO u     ON u.PK_TUSUARIO     = es.FK_TUSUARIO
         WHERE m.FK_TGRUPO = p_fk_tgrupo
           AND m.ACTIVE = TRUE
           AND (p_fk_tmatriculas IS NULL
                OR CARDINALITY(p_fk_tmatriculas) = 0
                OR m.PK_TMATRICULA = ANY (p_fk_tmatriculas))
         ORDER BY 2, 1
    LOOP
        v_proy := academico_test.fn_asignatura_definitiva_proyectada_periodo(
                      r_mat.pk, p_fk_tasignatura, p_fk_tperiodo_evaluacion);

        SELECT sn.DEFINITIVA, TRUE
          INTO v_prev, v_existe
          FROM academico_test.TASIGNATURA_NOTA sn
         WHERE sn.FK_TMATRICULA          = r_mat.pk
           AND sn.FK_TASIGNATURA         = p_fk_tasignatura
           AND sn.FK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion
           AND sn.ACTIVE = TRUE;

        IF v_proy IS NULL THEN
            v_res := 'sin_proyeccion';
        ELSIF COALESCE(v_existe, FALSE) AND v_prev = v_proy THEN
            v_res := 'sin_cambio';
        ELSE
            INSERT INTO academico_test.TASIGNATURA_NOTA (
                FK_TMATRICULA, FK_TASIGNATURA, FK_TPERIODO_EVALUACION,
                CALIFICACION, DEFINITIVA, CREATED_BY, CREATED_AT, ACTIVE
            ) VALUES (
                r_mat.pk, p_fk_tasignatura, p_fk_tperiodo_evaluacion,
                v_proy, v_proy,
                p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
            )
            ON CONFLICT (FK_TMATRICULA, FK_TPERIODO_EVALUACION, FK_TASIGNATURA)
                WHERE ACTIVE
            DO UPDATE SET CALIFICACION = EXCLUDED.CALIFICACION,
                          DEFINITIVA   = EXCLUDED.DEFINITIVA,
                          MODIFIED_BY  = p_pk_usuario_solicitante::VARCHAR,
                          MODIFIED_AT  = CURRENT_TIMESTAMP;

            v_res := CASE WHEN COALESCE(v_existe, FALSE) THEN 'actualizada'
                          ELSE 'guardada' END;
        END IF;

        PERFORM academico_test.fn_informe_metricas_recalcular(
            p_pk_usuario_solicitante, r_mat.pk, p_fk_tperiodo_evaluacion);

        SELECT ipm.PROMEDIO, ipm.APROBADAS, ipm.REPROBADAS
          INTO v_m
          FROM academico_test.TINFORME_PERIODO_MATRICULA ipm
         WHERE ipm.FK_TMATRICULA          = r_mat.pk
           AND ipm.FK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion
           AND ipm.ACTIVE = TRUE;

        -- Al historial SOLO si se escribio. Una asignatura por estudiante,
        -- de ahi el 1.
        IF v_res IN ('guardada', 'actualizada') THEN
            v_hist := v_hist || JSONB_BUILD_OBJECT(
                'matricula',   r_mat.pk,
                'promedio',    v_m.PROMEDIO,
                'asignaturas', 1);
        END IF;

        fk_tmatricula    := r_mat.pk;
        estudiante       := r_mat.nombre;
        resultado        := v_res;
        nota_anterior    := v_prev;
        nota_guardada    := CASE WHEN v_res IN ('guardada', 'actualizada', 'sin_cambio')
                                 THEN v_proy END;
        promedio_periodo := v_m.PROMEDIO;
        aprobadas        := COALESCE(v_m.APROBADAS, 0)::BIGINT;
        reprobadas       := COALESCE(v_m.REPROBADAS, 0)::BIGINT;
        RETURN NEXT;

        v_prev := NULL; v_existe := NULL;
    END LOOP;

    PERFORM academico_test.fn_informe_historial_registrar(
        p_pk_usuario_solicitante, p_fk_tgrupo, p_fk_tasignatura,
        p_fk_tperiodo_evaluacion, 'PLANILLA', v_hist);
END;
$function$
;

-- ---------------------------------------------------------------------------
-- fn_informe_periodo_evidencias_listar
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_informe_periodo_evidencias_listar(p_pk_usuario_solicitante bigint, p_fk_tmatricula bigint, p_fk_tperiodo_evaluacion bigint DEFAULT NULL::bigint)
 RETURNS TABLE(pk_tactividad_soporte bigint, fk_tarchivo bigint, nombre character varying, urls3 character varying, peso bigint, etiqueta character varying, fecha date, fk_tperiodo_evaluacion bigint, periodo_nombre character varying, fk_tactividad bigint, actividad_titulo character varying, observacion character varying)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_fk_peraca  BIGINT;
    v_fk_sede    BIGINT;
    v_fk_jornada BIGINT;
    v_fk_ee      BIGINT;
BEGIN
    SELECT gd.FK_TPERIODO_ACADEMICO, s.PK_TSEDE, gr.FK_TLV_JORNADA, s.FK_TESTABLECIMIENTO
      INTO v_fk_peraca, v_fk_sede, v_fk_jornada, v_fk_ee
      FROM academico_test.TMATRICULA m
      JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = m.FK_TGRUPO
      JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa
        ON pa.PK_TPERIODO_ACADEMICO = gd.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE m.PK_TMATRICULA = p_fk_tmatricula
       AND m.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la matricula solicitada'
            USING ERRCODE = 'P0002';
    END IF;

    -- INFORMES, no PLANEADOR: ver las evidencias desde esta pantalla es
    -- parte de leer el informe. Ver la cabecera, punto 2.
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'INFORMES', 'VER',
        v_fk_ee, v_fk_sede, v_fk_jornada
    );

    -- V490 -- el recorte por grupo, DESPUES del gate de arriba. Para
    -- quien alcanza la sede entera es un no-op.
    PERFORM academico_test.fn_informe_assert_grupo_propio(
        p_pk_usuario_solicitante, academico_test.fn_matricula_grupo(p_fk_tmatricula));

    RETURN QUERY
    WITH periodos AS (
        -- Sin periodo pedido, el AÑO COMPLETO: es lo que necesita la fila
        -- Final, con el mismo criterio con que calcula la nota.
        SELECT pe.PK_TPERIODO_EVALUACION AS pk,
               pe.NOMBRE                 AS nombre,
               pe.FECHA_INICIO           AS inicio
          FROM academico_test.TPERIODO_EVALUACION pe
         WHERE pe.ACTIVE = TRUE
           AND pe.FK_TPERIODO_ACADEMICO = v_fk_peraca
           AND (p_fk_tperiodo_evaluacion IS NULL
                OR pe.PK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion)
    )
    SELECT so.PK_TACTIVIDAD_SOPORTE,
           so.FK_TARCHIVO,
           ar.NOMBRE,
           ar.URLS3,
           ar.PESO,
           ar.ETIQUETA,
           so.FECHA,
           p.pk,
           p.nombre,
           a.PK_TACTIVIDAD,
           a.TITULO,
           so.OBSERVACION
      FROM academico_test.TACTIVIDAD_SOPORTE so
      JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
        ON ae.PK_TACTIVIDAD_ESTUDIANTE = so.FK_TACTIVIDAD_ESTUDIANTE
       AND ae.FK_TMATRICULA = p_fk_tmatricula
       AND ae.ACTIVE = TRUE
      JOIN academico_test.TACTIVIDAD a
        ON a.PK_TACTIVIDAD = ae.FK_TACTIVIDAD
       AND a.ACTIVE = TRUE
      JOIN academico_test.TARCHIVO ar
        ON ar.PK_TARCHIVO = so.FK_TARCHIVO
      -- El JOIN contra periodos es lo que ubica cada evidencia en SU
      -- periodo. Una actividad cae en un periodo por fechas, no por una FK.
      JOIN periodos p
        ON academico_test.fn_actividad_en_periodo_eval(a.PK_TACTIVIDAD, p.pk) = TRUE
     WHERE so.ACTIVE = TRUE
       AND so.FK_TARCHIVO IS NOT NULL
     ORDER BY p.inicio, so.FECHA NULLS LAST, so.PK_TACTIVIDAD_SOPORTE;
END;
$function$
;

-- ---------------------------------------------------------------------------
-- fn_estudiante_periodo_observacion_generar
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_estudiante_periodo_observacion_generar(p_pk_usuario_solicitante bigint, p_fk_tmatricula bigint, p_fk_tperiodo_evaluacion bigint)
 RETURNS TABLE(observacion_ia text, observaciones_origen numeric)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_fk_peraca  BIGINT;
    v_fk_sede    BIGINT;
    v_fk_jornada BIGINT;
    v_fk_ee      BIGINT;
    v_estudiante VARCHAR;
    v_pe_peraca  BIGINT;
    v_texto      TEXT;
    v_cuantas    NUMERIC := 0;
BEGIN
    -- 2.1 La matricula y su ubicacion.
    SELECT gd.FK_TPERIODO_ACADEMICO, s.PK_TSEDE, gr.FK_TLV_JORNADA,
           s.FK_TESTABLECIMIENTO,
           NULLIF(TRIM(CONCAT_WS(' ', u.PRIMER_NOMBRE, u.PRIMER_APELLIDO)), '')
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

    -- 2.2 El periodo tiene que ser del MISMO periodo academico. Sin esto se
    --     podria pedir el resumen de un periodo de otro ano y saldria vacio
    --     sin explicar por que.
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
            USING ERRCODE = '22023',
                  HINT    = 'Elija un periodo del mismo ano lectivo y sede en que esta matriculado el estudiante';
    END IF;

    -- 2.3 Gate: VER, porque generar no escribe nada.
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'INFORMES', 'VER',
        v_fk_ee, v_fk_sede, v_fk_jornada
    );

    -- V490 -- el recorte por grupo, DESPUES del gate de arriba. Para
    -- quien alcanza la sede entera es un no-op.
    PERFORM academico_test.fn_informe_assert_grupo_propio(
        p_pk_usuario_solicitante, academico_test.fn_matricula_grupo(p_fk_tmatricula));

    -- -----------------------------------------------------------------
    -- 2.4 *** AQUI IRA LA IA ***
    --
    --     Por ahora: concatenar TODAS las observaciones del estudiante en
    --     el periodo -- sin filtrar por asignatura, porque en preescolar
    --     la evaluacion no es por dimension -- en orden cronologico y
    --     prefijadas con el titulo de la actividad.
    -- -----------------------------------------------------------------
    SELECT STRING_AGG(FORMAT('%s: %s', x.titulo, x.observacion),
                      ' ' ORDER BY x.fecha, x.pk),
           COUNT(*)
      INTO v_texto, v_cuantas
      FROM (
            SELECT a.TITULO                          AS titulo,
                   TRIM(n.OBSERVACION)               AS observacion,
                   COALESCE(a.FECHA_CIERRE, a.FECHA_INICIO,
                            a.FECHA_CREACION::DATE)  AS fecha,
                   a.PK_TACTIVIDAD                   AS pk
              FROM academico_test.TACTIVIDAD a
              JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
                ON ae.FK_TACTIVIDAD = a.PK_TACTIVIDAD
               AND ae.FK_TMATRICULA = p_fk_tmatricula
               AND ae.ACTIVE = TRUE
              JOIN academico_test.TACTIVIDAD_NOTA n
                ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
               AND n.ACTIVE = TRUE
             WHERE a.ACTIVE = TRUE
               AND NULLIF(TRIM(COALESCE(n.OBSERVACION, '')), '') IS NOT NULL
               AND academico_test.fn_actividad_en_periodo_eval(
                       a.PK_TACTIVIDAD, p_fk_tperiodo_evaluacion) = TRUE
           ) x;

    IF v_texto IS NULL THEN
        RAISE EXCEPTION 'No hay observaciones del docente para resumir en ese periodo%',
            CASE WHEN v_estudiante IS NULL THEN '' ELSE ' para "' || v_estudiante || '"' END
            USING ERRCODE = '22023',
                  HINT    = 'El resumen se arma con las observaciones que el docente dejo por actividad; sin ellas no hay nada que resumir';
    END IF;

    RETURN QUERY SELECT v_texto, v_cuantas;
END;
$function$
;

-- ---------------------------------------------------------------------------
-- fn_estudiante_periodo_observacion_guardar
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_estudiante_periodo_observacion_guardar(p_pk_usuario_solicitante bigint, p_fk_tmatricula bigint, p_fk_tperiodo_evaluacion bigint, p_observacion text, p_observacion_ia text DEFAULT NULL::text, p_observaciones_origen numeric DEFAULT NULL::numeric)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_fk_peraca  BIGINT;
    v_fk_sede    BIGINT;
    v_fk_jornada BIGINT;
    v_fk_ee      BIGINT;
    v_pe_peraca  BIGINT;
    v_texto      TEXT;
    v_ia         TEXT;
    v_ia_previa  TEXT;
    v_origen     NUMERIC;
    v_estado     VARCHAR;
    v_pk_estado  BIGINT;
    v_pk         BIGINT;
BEGIN
    v_texto := NULLIF(TRIM(COALESCE(p_observacion, '')), '');
    IF v_texto IS NULL THEN
        RAISE EXCEPTION 'La observacion no puede quedar vacia'
            USING ERRCODE = '22023',
                  HINT    = 'Para quitar un resumen ya guardado use fn_estudiante_periodo_observacion_eliminar';
    END IF;

    SELECT gd.FK_TPERIODO_ACADEMICO, s.PK_TSEDE, gr.FK_TLV_JORNADA, s.FK_TESTABLECIMIENTO
      INTO v_fk_peraca, v_fk_sede, v_fk_jornada, v_fk_ee
      FROM academico_test.TMATRICULA m
      JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = m.FK_TGRUPO
      JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa
        ON pa.PK_TPERIODO_ACADEMICO = gd.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
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
        p_pk_usuario_solicitante, 'INFORMES', 'EDITAR',
        v_fk_ee, v_fk_sede, v_fk_jornada
    );

    -- V490 -- el recorte por grupo, DESPUES del gate de arriba. Para
    -- quien alcanza la sede entera es un no-op.
    PERFORM academico_test.fn_informe_assert_grupo_propio(
        p_pk_usuario_solicitante, academico_test.fn_matricula_grupo(p_fk_tmatricula));

    -- *** V433 (2) *** El borrador guardado, si lo hay.
    SELECT ob.OBSERVACION_IA
      INTO v_ia_previa
      FROM academico_test.TESTUDIANTE_PERIODO_OBSERVACION ob
     WHERE ob.FK_TMATRICULA          = p_fk_tmatricula
       AND ob.FK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion
       AND ob.ACTIVE = TRUE;

    -- Prioridad: lo que reenvia el caller, luego el borrador que ya estaba
    -- guardado, y recien al final el texto mismo. Ese ultimo caso es el de
    -- "lo escribi a mano desde cero", donde no hay borrador contra el cual
    -- comparar. Antes se saltaba el escalon del medio, y por eso editar un
    -- resumen ya guardado lo dejaba como APROBADA sin cambios.
    v_ia := COALESCE(
                NULLIF(TRIM(COALESCE(p_observacion_ia, '')), ''),
                NULLIF(TRIM(COALESCE(v_ia_previa,      '')), ''),
                v_texto);

    -- *** V433 (1) *** Si no me dicen cuantas habia, las cuento. NULL aca
    -- termina leyendose como CERO en el listado, y cero significa "no habia
    -- ninguna", que deja la fila marcada como desactualizada para siempre.
    v_origen := p_observaciones_origen;

    IF v_origen IS NULL THEN
        -- La MISMA cuenta que hace fn_estudiante_periodo_observacion_generar:
        -- las observaciones por actividad del estudiante en ese periodo, sin
        -- filtrar por asignatura -- en preescolar la evaluacion no es por
        -- dimension.
        SELECT COUNT(*)
          INTO v_origen
          FROM academico_test.TACTIVIDAD a
          JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
            ON ae.FK_TACTIVIDAD = a.PK_TACTIVIDAD
           AND ae.FK_TMATRICULA = p_fk_tmatricula
           AND ae.ACTIVE = TRUE
          JOIN academico_test.TACTIVIDAD_NOTA n
            ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
           AND n.ACTIVE = TRUE
         WHERE a.ACTIVE = TRUE
           AND NULLIF(TRIM(COALESCE(n.OBSERVACION, '')), '') IS NOT NULL
           AND academico_test.fn_actividad_en_periodo_eval(
                   a.PK_TACTIVIDAD, p_fk_tperiodo_evaluacion) = TRUE;
    END IF;

    -- El estado se DEDUCE del texto, no se pide por parametro: asi no puede
    -- contradecirlo.
    v_estado := CASE WHEN v_texto = TRIM(v_ia) THEN 'APROBADA' ELSE 'MODIFICADA' END;

    SELECT lv.PK_LISTA_VALOR INTO v_pk_estado
      FROM academico_test.TLISTA_VALOR lv
     WHERE lv.CATEGORIA = 'ESTADO_OBSERVACION_IA'
       AND lv.VALOR     = v_estado
       AND lv.ACTIVE    = TRUE;

    IF v_pk_estado IS NULL THEN
        RAISE EXCEPTION 'Falta el estado % en el catalogo ESTADO_OBSERVACION_IA', v_estado
            USING ERRCODE = 'P0002';
    END IF;

    -- El unico es TOTAL sobre (matricula, periodo): guardar REEMPLAZA. No se
    -- versiona, la unica verdad es lo que el docente acepto por ultima vez.
    INSERT INTO academico_test.TESTUDIANTE_PERIODO_OBSERVACION (
        FK_TMATRICULA, FK_TPERIODO_EVALUACION, FK_TLV_ESTADO_OBSERVACION,
        OBSERVACION, OBSERVACION_IA, OBSERVACIONES_ORIGEN,
        CREATED_BY, CREATED_AT, ACTIVE
    ) VALUES (
        p_fk_tmatricula, p_fk_tperiodo_evaluacion, v_pk_estado,
        v_texto, v_ia, v_origen,
        p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
    )
    ON CONFLICT (FK_TMATRICULA, FK_TPERIODO_EVALUACION)
    DO UPDATE SET FK_TLV_ESTADO_OBSERVACION = EXCLUDED.FK_TLV_ESTADO_OBSERVACION,
                  OBSERVACION               = EXCLUDED.OBSERVACION,
                  OBSERVACION_IA            = EXCLUDED.OBSERVACION_IA,
                  OBSERVACIONES_ORIGEN      = EXCLUDED.OBSERVACIONES_ORIGEN,
                  ACTIVE                    = TRUE,
                  MODIFIED_BY               = p_pk_usuario_solicitante::VARCHAR,
                  MODIFIED_AT               = CURRENT_TIMESTAMP
    RETURNING PK_TESTUDIANTE_PERIODO_OBSERVACION INTO v_pk;

    RETURN v_pk;
END;
$function$
;

-- ---------------------------------------------------------------------------
-- fn_estudiante_periodo_observacion_eliminar
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_estudiante_periodo_observacion_eliminar(p_pk_usuario_solicitante bigint, p_fk_tmatricula bigint, p_fk_tperiodo_evaluacion bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_fk_sede    BIGINT;
    v_fk_jornada BIGINT;
    v_fk_ee      BIGINT;
    v_pk         BIGINT;
BEGIN
    SELECT o.PK_TESTUDIANTE_PERIODO_OBSERVACION,
           s.PK_TSEDE, gr.FK_TLV_JORNADA, s.FK_TESTABLECIMIENTO
      INTO v_pk, v_fk_sede, v_fk_jornada, v_fk_ee
      FROM academico_test.TESTUDIANTE_PERIODO_OBSERVACION o
      JOIN academico_test.TMATRICULA m ON m.PK_TMATRICULA = o.FK_TMATRICULA
      JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = m.FK_TGRUPO
      JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa
        ON pa.PK_TPERIODO_ACADEMICO = gd.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE o.FK_TMATRICULA          = p_fk_tmatricula
       AND o.FK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No hay un resumen guardado para ese estudiante en ese periodo'
            USING ERRCODE = 'P0002';
    END IF;

    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'INFORMES', 'ELIMINAR',
        v_fk_ee, v_fk_sede, v_fk_jornada
    );

    -- V490 -- el recorte por grupo, DESPUES del gate de arriba. Para
    -- quien alcanza la sede entera es un no-op.
    PERFORM academico_test.fn_informe_assert_grupo_propio(
        p_pk_usuario_solicitante, academico_test.fn_matricula_grupo(p_fk_tmatricula));

    -- Borrado fisico, no logico: el unico es TOTAL sobre (matricula,
    -- periodo), asi que una fila inactiva seguiria ocupando el lugar e
    -- impediria guardar un resumen nuevo. Y no hay nada que conservar -- el
    -- resumen se puede volver a generar desde las observaciones, que son las
    -- que si son el dato original.
    DELETE FROM academico_test.TESTUDIANTE_PERIODO_OBSERVACION
     WHERE PK_TESTUDIANTE_PERIODO_OBSERVACION = v_pk;

    RETURN v_pk;
END;
$function$
;

-- ---------------------------------------------------------------------------
-- fn_estudiante_final_observacion
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_estudiante_final_observacion(p_pk_usuario_solicitante bigint, p_fk_tmatricula bigint)
 RETURNS TABLE(observacion_ia text, periodos_origen numeric)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_fk_peraca  BIGINT;
    v_fk_sede    BIGINT;
    v_fk_jornada BIGINT;
    v_fk_ee      BIGINT;
BEGIN
    SELECT gd.FK_TPERIODO_ACADEMICO, s.PK_TSEDE, gr.FK_TLV_JORNADA, s.FK_TESTABLECIMIENTO
      INTO v_fk_peraca, v_fk_sede, v_fk_jornada, v_fk_ee
      FROM academico_test.TMATRICULA m
      JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = m.FK_TGRUPO
      JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa
        ON pa.PK_TPERIODO_ACADEMICO = gd.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE m.PK_TMATRICULA = p_fk_tmatricula
       AND m.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la matricula solicitada'
            USING ERRCODE = 'P0002';
    END IF;

    -- VER y no EDITAR: generar no escribe nada, igual que su gemela de
    -- periodo. Quien guarde necesitara EDITAR.
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'INFORMES', 'VER',
        v_fk_ee, v_fk_sede, v_fk_jornada
    );

    -- V490 -- el recorte por grupo, DESPUES del gate de arriba. Para
    -- quien alcanza la sede entera es un no-op.
    PERFORM academico_test.fn_informe_assert_grupo_propio(
        p_pk_usuario_solicitante, academico_test.fn_matricula_grupo(p_fk_tmatricula));

    RETURN QUERY
    -- -----------------------------------------------------------------
    -- *** AQUI IRA LA IA ***
    --
    -- Por ahora: encadenar los RESUMENES DE PERIODO ya consolidados, en
    -- orden y prefijados con el nombre del periodo. No las observaciones
    -- por actividad -- esas son la materia prima del resumen de PERIODO,
    -- y volver a masticarlas aca daria un texto de tres paginas.
    -- -----------------------------------------------------------------
    SELECT STRING_AGG(FORMAT('%s: %s', pe.NOMBRE, TRIM(ob.OBSERVACION)),
                      ' ' ORDER BY pe.FECHA_INICIO, pe.PK_TPERIODO_EVALUACION),
           COUNT(*)::NUMERIC
      FROM academico_test.TESTUDIANTE_PERIODO_OBSERVACION ob
      JOIN academico_test.TPERIODO_EVALUACION pe
        ON pe.PK_TPERIODO_EVALUACION = ob.FK_TPERIODO_EVALUACION
       AND pe.ACTIVE = TRUE
       AND pe.FK_TPERIODO_ACADEMICO = v_fk_peraca
     WHERE ob.FK_TMATRICULA = p_fk_tmatricula
       AND ob.ACTIVE = TRUE
       AND NULLIF(TRIM(COALESCE(ob.OBSERVACION, '')), '') IS NOT NULL;
END;
$function$
;

-- ---------------------------------------------------------------------------
-- fn_estudiante_anio_observacion_guardar
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_estudiante_anio_observacion_guardar(p_pk_usuario_solicitante bigint, p_fk_tmatricula bigint, p_observacion text, p_observacion_ia text DEFAULT NULL::text, p_periodos_origen numeric DEFAULT NULL::numeric)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_fk_peraca  BIGINT;
    v_fk_sede    BIGINT;
    v_fk_jornada BIGINT;
    v_fk_ee      BIGINT;
    v_texto      TEXT;
    v_ia         TEXT;
    v_ia_previa  TEXT;
    v_origen     NUMERIC;
    v_estado     VARCHAR;
    v_pk_estado  BIGINT;
    v_pk         BIGINT;
BEGIN
    v_texto := NULLIF(TRIM(COALESCE(p_observacion, '')), '');
    IF v_texto IS NULL THEN
        RAISE EXCEPTION 'La observacion no puede quedar vacia'
            USING ERRCODE = '22023',
                  HINT    = 'Para quitar el comentario del año use fn_estudiante_anio_observacion_eliminar';
    END IF;

    SELECT gd.FK_TPERIODO_ACADEMICO, s.PK_TSEDE, gr.FK_TLV_JORNADA, s.FK_TESTABLECIMIENTO
      INTO v_fk_peraca, v_fk_sede, v_fk_jornada, v_fk_ee
      FROM academico_test.TMATRICULA m
      JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = m.FK_TGRUPO
      JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa
        ON pa.PK_TPERIODO_ACADEMICO = gd.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE m.PK_TMATRICULA = p_fk_tmatricula
       AND m.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la matricula solicitada'
            USING ERRCODE = 'P0002';
    END IF;

    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'INFORMES', 'EDITAR',
        v_fk_ee, v_fk_sede, v_fk_jornada
    );

    -- V490 -- el recorte por grupo, DESPUES del gate de arriba. Para
    -- quien alcanza la sede entera es un no-op.
    PERFORM academico_test.fn_informe_assert_grupo_propio(
        p_pk_usuario_solicitante, academico_test.fn_matricula_grupo(p_fk_tmatricula));

    SELECT ao.OBSERVACION_IA
      INTO v_ia_previa
      FROM academico_test.TESTUDIANTE_ANIO_OBSERVACION ao
     WHERE ao.FK_TMATRICULA = p_fk_tmatricula
       AND ao.ACTIVE = TRUE;

    -- Misma prioridad que en la tabla de periodos desde el V433: lo que
    -- reenvia el caller, luego el borrador ya guardado, y recien al final el
    -- texto mismo. Sin el escalon del medio, editar un texto ya guardado lo
    -- dejaria como APROBADA sin cambios.
    v_ia := COALESCE(
                NULLIF(TRIM(COALESCE(p_observacion_ia, '')), ''),
                NULLIF(TRIM(COALESCE(v_ia_previa,      '')), ''),
                v_texto);

    v_origen := p_periodos_origen;

    IF v_origen IS NULL THEN
        -- Si no me dicen cuantos habia, los cuento. NULL aca significa "no
        -- se", y quien lo lea no puede distinguirlo de cero: ese fue el
        -- defecto que el V433 tuvo que arreglar en la otra tabla.
        SELECT COUNT(*)
          INTO v_origen
          FROM academico_test.TESTUDIANTE_PERIODO_OBSERVACION ob
          JOIN academico_test.TPERIODO_EVALUACION pe
            ON pe.PK_TPERIODO_EVALUACION = ob.FK_TPERIODO_EVALUACION
           AND pe.ACTIVE = TRUE
           AND pe.FK_TPERIODO_ACADEMICO = v_fk_peraca
         WHERE ob.FK_TMATRICULA = p_fk_tmatricula
           AND ob.ACTIVE = TRUE
           AND NULLIF(TRIM(COALESCE(ob.OBSERVACION, '')), '') IS NOT NULL;
    END IF;

    v_estado := CASE WHEN v_texto = TRIM(v_ia) THEN 'APROBADA' ELSE 'MODIFICADA' END;

    SELECT lv.PK_LISTA_VALOR INTO v_pk_estado
      FROM academico_test.TLISTA_VALOR lv
     WHERE lv.CATEGORIA = 'ESTADO_OBSERVACION_IA'
       AND lv.VALOR     = v_estado
       AND lv.ACTIVE    = TRUE;

    IF v_pk_estado IS NULL THEN
        RAISE EXCEPTION 'Falta el estado % en el catalogo ESTADO_OBSERVACION_IA', v_estado
            USING ERRCODE = 'P0002';
    END IF;

    INSERT INTO academico_test.TESTUDIANTE_ANIO_OBSERVACION (
        FK_TMATRICULA, FK_TLV_ESTADO_OBSERVACION,
        OBSERVACION, OBSERVACION_IA, PERIODOS_ORIGEN,
        CREATED_BY, CREATED_AT, ACTIVE
    ) VALUES (
        p_fk_tmatricula, v_pk_estado,
        v_texto, v_ia, v_origen,
        p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
    )
    ON CONFLICT (FK_TMATRICULA)
    DO UPDATE SET FK_TLV_ESTADO_OBSERVACION = EXCLUDED.FK_TLV_ESTADO_OBSERVACION,
                  OBSERVACION               = EXCLUDED.OBSERVACION,
                  OBSERVACION_IA            = EXCLUDED.OBSERVACION_IA,
                  PERIODOS_ORIGEN           = EXCLUDED.PERIODOS_ORIGEN,
                  ACTIVE                    = TRUE,
                  MODIFIED_BY               = p_pk_usuario_solicitante::VARCHAR,
                  MODIFIED_AT               = CURRENT_TIMESTAMP
    RETURNING PK_TESTUDIANTE_ANIO_OBSERVACION INTO v_pk;

    RETURN v_pk;
END;
$function$
;

-- ---------------------------------------------------------------------------
-- fn_estudiante_anio_observacion_eliminar
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_estudiante_anio_observacion_eliminar(p_pk_usuario_solicitante bigint, p_fk_tmatricula bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_fk_sede    BIGINT;
    v_fk_jornada BIGINT;
    v_fk_ee      BIGINT;
    v_pk         BIGINT;
BEGIN
    SELECT s.PK_TSEDE, gr.FK_TLV_JORNADA, s.FK_TESTABLECIMIENTO
      INTO v_fk_sede, v_fk_jornada, v_fk_ee
      FROM academico_test.TMATRICULA m
      JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = m.FK_TGRUPO
      JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa
        ON pa.PK_TPERIODO_ACADEMICO = gd.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE m.PK_TMATRICULA = p_fk_tmatricula
       AND m.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la matricula solicitada'
            USING ERRCODE = 'P0002';
    END IF;

    -- ELIMINAR y no EDITAR, igual que en la tabla de periodos (V413):
    -- rehacer un texto es corregir, borrarlo es deshacer.
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'INFORMES', 'ELIMINAR',
        v_fk_ee, v_fk_sede, v_fk_jornada
    );

    -- V490 -- el recorte por grupo, DESPUES del gate de arriba. Para
    -- quien alcanza la sede entera es un no-op.
    PERFORM academico_test.fn_informe_assert_grupo_propio(
        p_pk_usuario_solicitante, academico_test.fn_matricula_grupo(p_fk_tmatricula));

    -- Borrado FISICO y no baja logica, por el mismo motivo que en la otra
    -- tabla: el indice unico es total, asi que una fila inactiva seguiria
    -- ocupando el lugar e impediria guardar una nueva. Y no hay nada que
    -- conservar: el texto se vuelve a generar desde los resumenes de
    -- periodo, que son el dato original.
    DELETE FROM academico_test.TESTUDIANTE_ANIO_OBSERVACION ao
     WHERE ao.FK_TMATRICULA = p_fk_tmatricula
    RETURNING ao.PK_TESTUDIANTE_ANIO_OBSERVACION INTO v_pk;

    IF v_pk IS NULL THEN
        RAISE EXCEPTION 'El estudiante no tiene comentario del año guardado'
            USING ERRCODE = 'P0002';
    END IF;

    RETURN v_pk;
END;
$function$
;

-- ---------------------------------------------------------------------------
-- fn_informe_grupos_listar -- el listado: filtra, no falla.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_informe_grupos_listar(p_pk_usuario_solicitante bigint, p_fk_tsede bigint, p_anio integer, p_fk_tlv_jornada bigint, p_search character varying DEFAULT NULL::character varying)
 RETURNS TABLE(grupo_id bigint, grupo_codigo character varying, grupo_nombre character varying, grupo_etiqueta character varying, capacidad numeric, estudiantes bigint, jornada_id bigint, jornada_nombre character varying, grado_id bigint, grado_codigo character varying, grado_nombre character varying, nivel_ensenanza_id bigint, nivel_ensenanza_nombre character varying, director_id bigint, director_nombre character varying, fk_tperiodo_academico bigint)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_periodo BIGINT;
    v_search  VARCHAR;
BEGIN
    -- El resolvedor valida el alcance (42501) y la existencia (P0002).
    v_periodo := academico_test.fn_informe_periodo_academico_resolver(
        p_pk_usuario_solicitante, p_fk_tsede, p_anio, p_fk_tlv_jornada);

    v_search := NULLIF(TRIM(COALESCE(p_search, '')), '');

    RETURN QUERY
    SELECT gr.PK_TGRUPO,
           gr.CODIGO,
           gr.NOMBRE,
           academico_test.fn_grado_grupo_etiqueta(g.NOMBRE, g.CODIGO, gr.NOMBRE),
           gr.CAPACIDAD,
           (SELECT COUNT(*)
              FROM academico_test.TMATRICULA m
             WHERE m.FK_TGRUPO = gr.PK_TGRUPO
               AND m.ACTIVE = TRUE),
           jor.PK_LISTA_VALOR,
           jor.NOMBRE,
           g.PK_TGRADO,
           g.CODIGO,
           g.NOMBRE,
           ne.PK_NIVEL_ENSENANZA,
           ne.NOMBRE,
           f.PK_TFUNCIONARIO,
           NULLIF(TRIM(CONCAT_WS(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
                                      u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO)),
                  '')::VARCHAR,
           v_periodo
      FROM academico_test.TGRUPO gr
      JOIN academico_test.TGRADO g
        ON g.PK_TGRADO = gr.FK_TGRADO
       AND g.ACTIVE = TRUE
      LEFT JOIN academico_test.TNIVEL_ENSENANZA ne
             ON ne.PK_NIVEL_ENSENANZA = g.FK_TNIVEL_ENSENANZA
      -- LEFT: la jornada del grupo es informativa, no un requisito. Ver la
      -- cabecera -- en los periodos viejos ni siquiera coincide con la del
      -- periodo academico, y perder el grupo por eso seria peor.
      LEFT JOIN academico_test.TLISTA_VALOR jor
             ON jor.PK_LISTA_VALOR = gr.FK_TLV_JORNADA
      LEFT JOIN academico_test.TFUNCIONARIO f
             ON f.PK_TFUNCIONARIO = gr.FK_TFUNCIONARIO
            AND f.ACTIVE = TRUE
      LEFT JOIN academico_test.TUSUARIO u
             ON u.PK_TUSUARIO = f.FK_TUSUARIO
     WHERE gr.ACTIVE = TRUE
       AND g.FK_TPERIODO_ACADEMICO = v_periodo
       -- V490 -- aca se FILTRA en vez de fallar: la pregunta es "cuales
       -- puedo ver", y la respuesta correcta es la lista corta. Para quien
       -- alcanza la sede entera la condicion es TRUE y no cambia nada.
       AND (NOT academico_test.fn_usuario_solo_sus_grupos(p_pk_usuario_solicitante)
            OR gr.PK_TGRUPO IN (SELECT g2.grupo_id
                                  FROM academico_test.fn_usuario_grupos_dirigidos(
                                           p_pk_usuario_solicitante) g2))
       -- Busca por grupo, por grado y por la etiqueta compuesta: quien
       -- escribe "quinto a" espera encontrarlo aunque ese texto no exista
       -- entero en ninguna columna.
       AND (v_search IS NULL
            OR gr.NOMBRE ILIKE '%' || v_search || '%'
            OR gr.CODIGO ILIKE '%' || v_search || '%'
            OR g.NOMBRE  ILIKE '%' || v_search || '%'
            OR academico_test.fn_grado_grupo_etiqueta(g.NOMBRE, g.CODIGO, gr.NOMBRE)
               ILIKE '%' || v_search || '%')
     ORDER BY g.CODIGO, g.NOMBRE, gr.NOMBRE;
END;
$function$
;
