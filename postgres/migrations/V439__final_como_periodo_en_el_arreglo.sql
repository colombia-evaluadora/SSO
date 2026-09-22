-- ===========================================================================
-- V439 - El Final se pide como un periodo mas, no como una bandera.
--
--   fn_informe_grupo_listar    -p_incluir_final   (el Final entra como -1)
--   fn_informe_grupo_reporte   idem
--   fn_informe_grupo_tabla     idem
--   POST /informes/grupo       -BODY.INCLUIR_FINAL
--   POST /informes/reporte     -BODY.FILTERS.INCLUIR_FINAL
--   POST /informes/tabla       -BODY.FILTERS.INCLUIR_FINAL
--
--
-- EL PROBLEMA QUE LO MOTIVA
--   En la pantalla, el checkbox "Final" esta al lado de los de periodo, pero
--   por debajo era otra cosa: un booleano aparte. Y eso hacia imposible una
--   operacion que el usuario da por obvia -- marcar SOLO el Final --, porque
--   para el listado un arreglo de periodos vacio significa TODOS. Sin Final
--   no habia manera de expresar "ninguno": desmarcar todo devolvia todo.
--
--   Se podria haber separado NULL (todos) de [] (ninguno), pero esa clase de
--   distincion silenciosa entre nulo y vacio es la que despues alguien rompe
--   sin enterarse, y ademas le cambiaba el significado a un contrato ya
--   documentado.
--
--
-- LA SOLUCION: UN SOLO CONCEPTO
--   El Final pasa a ser un elemento mas del arreglo, con el id -1 -- el mismo
--   centinela con el que esa fila ya viaja en FK_TPERIODO_EVALUACION, asi que
--   no se inventa nada nuevo. Y el resto sale solo:
--
--     PERIODOS = NULL o []      todos los periodos reales, sin Final (igual
--                               que siempre)
--     PERIODOS = [622, 627]     esos dos, sin Final
--     PERIODOS = [622, -1]      ese periodo y el Final
--     PERIODOS = [-1]           SOLO el Final  <- lo que antes no se podia
--
--   Lo ultimo funciona sin ningun caso especial: -1 no matchea ningun
--   PK_TPERIODO_EVALUACION, de modo que la CTE de periodos queda vacia por su
--   propia condicion. No hay un IF nuevo en ninguna parte.
--
--   De paso desaparece un bind y la pantalla deja de tener dos conceptos
--   -- una lista de periodos y una bandera -- para lo que el usuario ve como
--   una sola fila de checkboxes.
--
--
-- LO QUE HAY QUE SABER ANTES DE INTEGRAR
--   INCLUIR_FINAL DEJA DE EXISTIR en los tres endpoints. Mandarlo no rompe
--   nada -- query-service ignora lo que no esta declarado en param_types --
--   pero tampoco hace nada: la fila Final no va a aparecer. Si un cliente
--   viejo lo manda y espera el Final, deja de verlo en silencio. Es el riesgo
--   real de este cambio y por eso conviene que salga junto con el front.
--
-- Idempotente: DROP ... IF EXISTS + CREATE OR REPLACE, y UPDATE de las filas
-- de public.query, que ya existen.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 1. El listado.
--
--    DROP de la firma de 5: quitar un parametro no la reemplaza, crea otra
--    sobrecarga, y entonces una llamada de 4 argumentos calzaria con las dos.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_informe_grupo_listar(BIGINT, BIGINT, BIGINT[], VARCHAR, BOOLEAN);
DROP FUNCTION IF EXISTS academico_test.fn_informe_grupo_listar(BIGINT, BIGINT, BIGINT[], VARCHAR);
CREATE OR REPLACE FUNCTION academico_test.fn_informe_grupo_listar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tgrupo              BIGINT,
    p_fk_periodos_evaluacion BIGINT[] DEFAULT NULL,
    p_search                 VARCHAR  DEFAULT NULL
)
RETURNS TABLE(
    fk_tmatricula              BIGINT,
    estudiante                 VARCHAR,
    documento                  VARCHAR,
    fk_tperiodo_evaluacion     BIGINT,
    periodo_nombre             VARCHAR,
    periodo_abreviacion        VARCHAR,
    periodo_inicio             DATE,
    modo_periodo               VARCHAR,
    formato                    VARCHAR,
    es_cualitativo             BOOLEAN,
    consolidado                BOOLEAN,
    promedio_guardado          NUMERIC,
    promedio_proyectado        NUMERIC,
    puesto                     BIGINT,
    asignaturas_total          BIGINT,
    aprobadas                  BIGINT,
    reprobadas                 BIGINT,
    sin_definir                BIGINT,
    tiene_cambios_propuestos   BOOLEAN,
    asignaturas                JSONB,
    observacion                TEXT,
    observacion_estado         VARCHAR,
    observacion_desactualizada BOOLEAN,
    evidencias                 BIGINT,
    total_count                BIGINT
)
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
           s.o_prom_guardado,
           s.o_prom_proyectado,
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
           COUNT(*) OVER ()::BIGINT
      FROM salida s
     WHERE NULLIF(TRIM(COALESCE(p_search, '')), '') IS NULL
        OR s.o_nombre ILIKE '%' || TRIM(p_search) || '%'
        OR s.o_doc    ILIKE '%' || TRIM(p_search) || '%'
     ORDER BY s.o_nombre NULLS LAST, s.o_mat, s.o_pe_inicio;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_grupo_listar(BIGINT, BIGINT, BIGINT[], VARCHAR)
    IS 'Listado principal de informes: una fila por (estudiante, periodo) del grupo. EL FINAL SE PIDE METIENDO -1 EN PERIODOS (V439), que es el mismo centinela con el que esa fila viaja en FK_TPERIODO_EVALUACION; antes era el parametro p_incluir_final, que se retira. El cambio no es cosmetico: como -1 no matchea ningun periodo real, ARRAY[-1] deja la CTE de periodos vacia y por fin se puede pedir SOLO el Final -- con la bandera era imposible, porque un arreglo vacio significa (y sigue significando) TODOS los periodos reales, de modo que no habia forma de decir "ninguno". La fila Final llega con FK_TPERIODO_EVALUACION = -1, modo_periodo "final", consolidado false y asignaturas con estado "final"; su nota se calcula al vuelo sobre TODOS los periodos del año, el periodo sin nota guardada vale cero y el promedio general sale de esas mismas asignaturas (V431). EVIDENCIAS cuenta las imagenes adjuntas a observaciones de la fila, y en el Final las del año (V434). Su observacion es la que este GUARDADA en TESTUDIANTE_ANIO_OBSERVACION, con su estado y su marca de desactualizado, que se dispara cuando se CONSOLIDA UN PERIODO NUEVO y no cuando el docente escribe una observacion mas (V435). V335, V411, V412, V428, V431, V434, V435, V439.';


-- ---------------------------------------------------------------------------
-- 2. El BOLETIN. Pierde la bandera y conserva MATRICULAS.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_informe_grupo_reporte(BIGINT, BIGINT, BIGINT[], VARCHAR, BOOLEAN, BIGINT[]);
DROP FUNCTION IF EXISTS academico_test.fn_informe_grupo_reporte(BIGINT, BIGINT, BIGINT[], VARCHAR, BOOLEAN);
DROP FUNCTION IF EXISTS academico_test.fn_informe_grupo_reporte(BIGINT, BIGINT, BIGINT[], VARCHAR);

CREATE OR REPLACE FUNCTION academico_test.fn_informe_grupo_reporte(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tgrupo              BIGINT,
    p_fk_periodos_evaluacion BIGINT[] DEFAULT NULL,
    p_search                 VARCHAR  DEFAULT NULL,
    p_fk_matriculas          BIGINT[] DEFAULT NULL
)
RETURNS TABLE(
    estudiante   VARCHAR,
    documento    VARCHAR,
    periodo      VARCHAR,
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
           a.nombre,
           a.area,
           a.nota,
           COALESCE(a.valoracion, a.simbolo)::VARCHAR,
           CASE a.estado
               WHEN 'guardada'         THEN 'Guardada'
               WHEN 'cambio_propuesto' THEN 'Guardada (con cambio propuesto)'
               WHEN 'final'            THEN 'Final (promedio del año)'
               ELSE a.estado
           END::VARCHAR,
           a.aprobada,
           f.promedio_guardado,
           f.puesto,
           f.observacion,
           f.evidencias
      FROM filas f
      LEFT JOIN LATERAL JSONB_TO_RECORDSET(
               -- V430 -- en preescolar las asignaturas existen pero llegan sin
               -- nota, y explotar la fila contra ellas la mataba entera, con
               -- observacion incluida.
               CASE WHEN f.es_cualitativo IS TRUE
                     AND f.observacion_estado IS NOT NULL
                     AND NOT EXISTS (
                           SELECT 1
                             FROM JSONB_ARRAY_ELEMENTS(f.asignaturas) e
                            WHERE e->>'estado' IN ('guardada', 'cambio_propuesto'))
                    THEN '[]'::JSONB
                    ELSE f.asignaturas
               END
           ) AS a(
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
     WHERE (
             f.consolidado IS TRUE
             OR (f.es_cualitativo IS TRUE AND f.observacion_estado IS NOT NULL)
             -- V435 -- el Final entra si tiene algo que decir: notas, o su
             -- comentario del año ya guardado. Sin eso seria una linea en
             -- blanco, el mismo defecto que el V430 vino a evitar.
             OR (f.modo_periodo = 'final'
                 AND (f.es_cualitativo IS FALSE OR f.observacion IS NOT NULL))
           )
       AND (a.estado IS NULL
            OR a.estado IN ('guardada', 'cambio_propuesto', 'final'))
       AND (p_fk_matriculas IS NULL
            OR CARDINALITY(p_fk_matriculas) = 0
            OR f.fk_tmatricula = ANY (p_fk_matriculas))
     ORDER BY f.periodo_inicio,
              f.estudiante,
              a.orden NULLS LAST,
              a.nombre;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_grupo_reporte(BIGINT, BIGINT, BIGINT[], VARCHAR, BIGINT[])
    IS 'EL BOLETIN. El informe aplanado para imprimir: una fila por (estudiante, periodo, asignatura). Llama a fn_informe_grupo_listar con los mismos filtros y el mismo gate, y FILTRA: solo sale lo consolidado -- las proyecciones y las notas requeridas quedan fuera, porque impresas se leen como calificaciones reales. Para bajar la tabla tal como se ve, sin filtrar, esta fn_informe_grupo_tabla. p_fk_matriculas acota a uno o varios estudiantes, que es lo que es un boletin; vacio o nulo = el grupo entero. V439: se retira p_incluir_final -- el Final se pide metiendo -1 en el arreglo de periodos, igual que en el listado --, de modo que un boletin de SOLO el Final es PERIODOS = ARRAY[-1]. PREESCOLAR entra por la rama cualitativo-con-observacion y se le vacia el arreglo de asignaturas cuando ninguna iba a sobrevivir el filtro (V430). El Final entra por su propia rama y solo si tiene algo que decir, notas o su comentario del año guardado (V435). EVIDENCIAS trae la CUENTA de imagenes, no las imagenes. V420, V430, V431, V434, V435, V439.';


-- ---------------------------------------------------------------------------
-- 3. El DESCARGAR. Idem.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_informe_grupo_tabla(BIGINT, BIGINT, BIGINT[], VARCHAR, BOOLEAN);
DROP FUNCTION IF EXISTS academico_test.fn_informe_grupo_tabla(BIGINT, BIGINT, BIGINT[], VARCHAR);

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
     ORDER BY f.estudiante,
              f.periodo_inicio,
              a.orden NULLS LAST,
              a.nombre;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_grupo_tabla(BIGINT, BIGINT, BIGINT[], VARCHAR)
    IS 'EL DESCARGAR. La tabla de informes tal como se esta viendo, aplanada para bajarla. A diferencia del BOLETIN no filtra NADA: salen lo consolidado, lo proyectado, lo requerido y lo que no tiene nota, cada uno dicho con todas las letras en ESTADO, mas una columna CONSOLIDADO. Esa diferencia es deliberada: un boletin no puede imprimir una proyeccion porque fuera del sistema se lee como una calificacion real, y un volcado que esconde la mitad de la tabla no sirve para revisar. Respeta los mismos filtros de la pantalla, SEARCH incluido. V439: se retira p_incluir_final; el Final se pide metiendo -1 en el arreglo de periodos. V434, V439.';


-- ---------------------------------------------------------------------------
-- 4. Los tres endpoints pierden el bind.
-- ---------------------------------------------------------------------------
UPDATE public.query q
   SET query = 'SELECT * FROM academico_test.fn_informe_grupo_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FK_TGRUPO AS BIGINT),
    CAST(:BODY.PERIODOS AS BIGINT[]),
    CAST(:BODY.SEARCH AS VARCHAR)
);',
       param_types = '{"BODY.FK_TGRUPO": "BIGINT", "BODY.PERIODOS": "BIGINT[]", "BODY.SEARCH": "VARCHAR"}'::jsonb,
       detail = 'Listado principal de informes: una fila por (estudiante, periodo) del grupo, con promedio, puesto, aprobadas/reprobadas, la cuenta de EVIDENCIAS y las asignaturas embebidas en JSONB. FORMATO dice si la fila se lee como numerica o cualitativa (preescolar); en el caso cualitativo lo que vale es OBSERVACION. EL FINAL SE PIDE METIENDO -1 EN PERIODOS (V439; antes era el bind INCLUIR_FINAL, que ya no existe): PERIODOS nulo o vacio = todos los periodos reales sin Final, [622,-1] = ese periodo y el Final, [-1] = SOLO el Final. Esa ultima combinacion es la que motiva el cambio: con la bandera era imposible, porque un arreglo vacio significa TODOS. La fila Final llega con FK_TPERIODO_EVALUACION = -1 -- un centinela, no un PK --, MODO_PERIODO "final", CONSOLIDADO false y cada asignatura con ESTADO "final"; se calcula al vuelo sobre todos los periodos del año y un periodo sin nota guardada vale cero. Sin paginacion: paginar romperia el puesto. SEARCH filtra por nombre y documento DESPUES de calcular el puesto.'
  FROM public.microservice m
 WHERE q.microservice_id = m.id_microservice
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/informes/grupo'
   AND q.http_method     = 'POST';

UPDATE public.query q
   SET query = 'SELECT * FROM academico_test.fn_informe_grupo_reporte(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FILTERS.FK_TGRUPO AS BIGINT),
    CAST(:BODY.FILTERS.PERIODOS AS BIGINT[]),
    CAST(:BODY.FILTERS.SEARCH AS VARCHAR),
    CAST(:BODY.FILTERS.MATRICULAS AS BIGINT[])
);',
       param_types = '{"BODY.FILTERS.FK_TGRUPO": "BIGINT", "BODY.FILTERS.PERIODOS": "BIGINT[]", "BODY.FILTERS.SEARCH": "VARCHAR", "BODY.FILTERS.MATRICULAS": "BIGINT[]"}'::jsonb,
       detail = 'EL BOLETIN. Una fila por (estudiante, periodo, asignatura). Lo consume reporting-service bajo la clave "informes" (POST /reportes/informes), no el front directamente. FILTRA: solo sale lo consolidado -- las proyecciones y las notas requeridas quedan fuera, porque impresas se leerian como calificaciones reales. Para bajar la tabla tal como se ve esta POST /informes/tabla. MATRICULAS acota a uno o varios estudiantes, que es lo que es un boletin; vacio o ausente = el grupo entero. EL FINAL SE PIDE CON -1 EN PERIODOS (V439; el bind INCLUIR_FINAL ya no existe), asi que el boletin de solo el Final es PERIODOS [-1]. EVIDENCIAS trae la CUENTA de imagenes de la fila, no las imagenes.'
  FROM public.microservice m
 WHERE q.microservice_id = m.id_microservice
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/informes/reporte'
   AND q.http_method     = 'POST';

UPDATE public.query q
   SET query = 'SELECT * FROM academico_test.fn_informe_grupo_tabla(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FILTERS.FK_TGRUPO AS BIGINT),
    CAST(:BODY.FILTERS.PERIODOS AS BIGINT[]),
    CAST(:BODY.FILTERS.SEARCH AS VARCHAR)
);',
       param_types = '{"BODY.FILTERS.FK_TGRUPO": "BIGINT", "BODY.FILTERS.PERIODOS": "BIGINT[]", "BODY.FILTERS.SEARCH": "VARCHAR"}'::jsonb,
       detail = 'La tabla de informes tal como se esta viendo, aplanada para bajarla. Lo consume reporting-service bajo la clave "informes-tabla" (POST /reportes/informes-tabla), no el front directamente. A diferencia del BOLETIN no filtra nada: salen lo consolidado, lo proyectado, lo requerido y lo que no tiene nota, cada uno dicho con todas las letras en ESTADO, mas una columna CONSOLIDADO. Respeta los filtros de la pantalla, SEARCH incluido. EL FINAL SE PIDE CON -1 EN PERIODOS (V439; el bind INCLUIR_FINAL ya no existe).'
  FROM public.microservice m
 WHERE q.microservice_id = m.id_microservice
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/informes/tabla'
   AND q.http_method     = 'POST';
