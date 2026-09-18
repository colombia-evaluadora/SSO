-- ===========================================================================
-- V411 - fn_informe_grupo_listar: los periodos SIN calificaciones dejan de
--        venir vacios y muestran la nota REQUERIDA.
--
-- QUE CAMBIA
--   Hasta ahora, un periodo seleccionado sin ninguna calificacion devolvia
--   todo en NULL. Correcto pero inutil: ahi lo que el colegio quiere ver es
--   cuanto necesita el estudiante en ese periodo para no perder la asignatura
--   en el ano.
--
--   Se agrega MODO_PERIODO, el eje nuevo de la respuesta:
--
--     'real'       el periodo tiene calificaciones. Todo como antes: notas
--                  guardadas y/o proyectadas, promedio, puesto, aprobadas.
--     'requerido'  el periodo no tiene NINGUNA. Las notas de ASIGNATURAS son
--                  lo que hace falta sacar, no lo que se saco.
--
--   Es un eje DISTINTO de FORMATO (numerico / cualitativo) y no lo reemplaza.
--
--
-- COMO SE DETECTA: TRES CONDICIONES
--   Un (estudiante, periodo) es 'requerido' cuando:
--     a) ninguna asignatura tiene nota visible -- ni guardada ni proyectada,
--     b) el estudiante califica con numeros, y
--     c) el docente NO dejo observaciones en ese periodo.
--
--   (b) no se puede preguntar al detalle de ese periodo, porque puede venir
--   con CERO filas: sin actividades ni notas no hay de donde sacar la
--   asignatura. Por eso el universo y el ES_NUMERICO salen de
--   fn_informe_periodo_requerido (V410), que arma la lista desde el AÑO
--   COMPLETO y toma es_numerico del CRITERIO de evaluacion, no de homologar
--   un valor inexistente. Ese es el caso que el parche de V410 desbloquea:
--   antes, un periodo numerico vacio se habria clasificado como cualitativo.
--
--   (c) ES LA SALVAGUARDA DE PREESCOLAR, y merece explicacion. Normalmente
--   bastaria con (a) y (b), porque las dimensiones de preescolar no tienen
--   criterio de evaluacion configurado y por tanto no son numericas. Pero eso
--   depende de una CONFIGURACION AUSENTE, no de una regla: el dia que alguien
--   le ponga un criterio CIEN a una dimension por error, ese grupo pasaria a
--   mostrar "cuanto necesitas" en lugar de las observaciones del docente --
--   justo el sector que menos lo tolera.
--
--   Si el docente dejo observaciones, el flujo en uso es el cualitativo y ahi
--   no hay nada que requerir. Esa senal viene del TRABAJO REAL, no de la
--   configuracion, y por eso es mas confiable. FORMATO sigue la misma senal:
--   con observaciones y sin notas, la fila se lee como cualitativa aunque la
--   asignatura tenga criterio numerico.
--
--
-- QUE SE DEVUELVE EN MODO 'requerido'
--   ASIGNATURAS trae, por cada una, la nota que hace falta -- homologada a la
--   escala del colegio -- con estado 'requerido' y dos banderas:
--   YA_ASEGURADO (lo que lleva ya le alcanza, el valor sale <= 0) y
--   ALCANZABLE (FALSE si supera el maximo: ya perdio pase lo que pase).
--
--   PUESTO viene NULL. No son notas reales, asi que ordenar a los estudiantes
--   por ellas produciria un ranking de "quien necesita menos", que se leeria
--   como uno de rendimiento y es lo contrario.
--
--   PROMEDIO_PROYECTADO viene con el DESEMPENHO_MINIMO del grado. Decision
--   explicita: la fila entera habla de alcanzar el minimo, asi que ese es el
--   unico promedio que la describe. Promediar los requeridos de cada
--   asignatura daria un numero distinto por estudiante que no significa nada
--   -- ni una nota que alguien vaya a sacar ni un objetivo que alguien se
--   haya puesto.
--
--   PROMEDIO_GUARDADO, CONSOLIDADO, APROBADAS y REPROBADAS vienen vacios o en
--   cero: no hay nada consolidado ni nada que aprobar todavia.
--
--
-- LO QUE NO CAMBIA
--   El guardado. Un periodo sin notas no genera consolidado --
--   fn_informe_metricas_recalcular da de baja la fila cuando no queda ninguna
--   nota guardada, para no escribir ceros que se leerian como "saco cero" --
--   y estos requeridos no son notas, asi que nada de esto se persiste.
--
-- Idempotente: CREATE OR REPLACE. DROP previo porque cambia el RETURNS TABLE.
-- ===========================================================================


DROP FUNCTION IF EXISTS academico_test.fn_informe_grupo_listar(BIGINT, BIGINT, BIGINT[], VARCHAR);


CREATE OR REPLACE FUNCTION academico_test.fn_informe_grupo_listar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tgrupo              BIGINT,
    p_fk_periodos_evaluacion BIGINT[] DEFAULT NULL,
    p_search                 VARCHAR  DEFAULT NULL
)
RETURNS TABLE(
    fk_tmatricula               BIGINT,
    estudiante                  VARCHAR,
    documento                   VARCHAR,
    fk_tperiodo_evaluacion      BIGINT,
    periodo_nombre              VARCHAR,
    periodo_abreviacion         VARCHAR,
    periodo_inicio              DATE,
    modo_periodo                VARCHAR,
    formato                     VARCHAR,
    es_cualitativo              BOOLEAN,
    consolidado                 BOOLEAN,
    promedio_guardado           NUMERIC,
    promedio_proyectado         NUMERIC,
    puesto                      BIGINT,
    asignaturas_total           BIGINT,
    aprobadas                   BIGINT,
    reprobadas                  BIGINT,
    sin_definir                 BIGINT,
    tiene_cambios_propuestos    BOOLEAN,
    asignaturas                 JSONB,
    observacion                 TEXT,
    observacion_estado          VARCHAR,
    observacion_desactualizada  BOOLEAN,
    total_count                 BIGINT
)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_fk_sede    BIGINT;
    v_fk_jornada BIGINT;
    v_fk_ee      BIGINT;
    v_fk_peraca  BIGINT;
    v_fk_grado   BIGINT;
    v_minimo     NUMERIC;
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

    -- El umbral es del GRADO, asi que es el mismo para todo el grupo: se
    -- resuelve una vez y no por estudiante.
    v_minimo := academico_test.fn_grado_desempeno_minimo(v_fk_grado);

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
    -- Observaciones del docente por (estudiante, periodo). Se calcula aparte
    -- y no dentro de la agregacion porque sirve para DOS cosas: decidir el
    -- modo (condicion c) y saber si el resumen de la IA quedo viejo.
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
    por_periodo AS (
        SELECT e.pk   AS mat,
               e.nombre,
               e.doc,
               p.pk     AS pe,
               p.nombre AS pe_nombre,
               p.abrev  AS pe_abrev,
               p.inicio AS pe_inicio,
               -- La pregunta (a) que decide el modo.
               COALESCE(BOOL_OR(COALESCE(d.nota_guardada, d.nota_proyectada)
                                IS NOT NULL), FALSE)             AS tiene_notas,
               COUNT(d.fk_tasignatura)                           AS calc_total,
               AVG(d.nota_guardada)                              AS calc_prom_guardado,
               AVG(COALESCE(d.nota_guardada, d.nota_proyectada)) AS calc_prom_visible,
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
        SELECT pp.*, COALESCE(ob.n, 0) AS obs_hoy
          FROM por_periodo pp
          LEFT JOIN observaciones ob ON ob.mat = pp.mat AND ob.pe = pp.pe
    ),
    -- SOLO para los (estudiante, periodo) sin notas Y sin observaciones. El
    -- filtro va sobre base, que el planificador puede aplicar antes del
    -- LATERAL, de modo que fn_informe_periodo_requerido no se llama para los
    -- periodos que ya tienen calificaciones o que van por el flujo
    -- cualitativo.
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
                           -- La nota que HACE FALTA, no la que se saco.
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
               -- Las tres condiciones. Ver la cabecera.
               (NOT b.tiene_notas
                AND b.obs_hoy = 0
                AND COALESCE(rq.hay_numerico, FALSE))  AS es_requerido,
               rq.total AS req_total,
               rq.asigs AS req_asigs,
               -- El formato sigue la MISMA senal que la condicion (c): con
               -- observaciones y sin notas la fila se lee como cualitativa,
               -- aunque la asignatura tenga criterio numerico configurado.
               CASE WHEN b.obs_hoy > 0 AND NOT b.tiene_notas THEN FALSE
                    ELSE COALESCE(rq.hay_numerico, b.hay_numerico)
               END AS es_num_final
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
               -- Sin puesto en modo 'requerido': no son notas reales, y
               -- ordenar por ellas produciria un ranking de "quien necesita
               -- menos" que se leeria como uno de rendimiento.
               CASE WHEN cm.es_requerido OR cm.calc_prom_visible IS NULL THEN NULL
                    ELSE RANK() OVER (PARTITION BY cm.pe
                                          ORDER BY cm.calc_prom_visible DESC)
               END AS pos
          FROM con_metricas cm
    )
    SELECT cp.mat,
           cp.nombre,
           cp.doc,
           cp.pe,
           cp.pe_nombre,
           cp.pe_abrev,
           cp.pe_inicio,
           CASE WHEN cp.es_requerido THEN 'requerido' ELSE 'real' END::VARCHAR,
           CASE WHEN cp.es_num_final THEN 'numerico' ELSE 'cualitativo' END::VARCHAR,
           NOT cp.es_num_final,
           CASE WHEN cp.es_requerido THEN FALSE ELSE cp.esta_consolidado END,
           CASE WHEN cp.es_requerido THEN NULL ELSE cp.prom_guardado END,
           -- En modo 'requerido' el promedio es el MINIMO: la fila entera
           -- habla de alcanzarlo. Ver la cabecera.
           CASE WHEN cp.es_requerido THEN v_minimo
                ELSE ROUND(cp.calc_prom_visible, 2) END,
           cp.pos,
           CASE WHEN cp.es_requerido THEN cp.req_total ELSE cp.total_asig END::BIGINT,
           CASE WHEN cp.es_requerido THEN 0 ELSE cp.aprob  END::BIGINT,
           CASE WHEN cp.es_requerido THEN 0 ELSE cp.reprob END::BIGINT,
           CASE WHEN cp.es_requerido THEN cp.req_total ELSE cp.sindef END::BIGINT,
           cp.cambios,
           CASE WHEN cp.es_requerido THEN cp.req_asigs ELSE cp.asigs END,
           cp.obs,
           cp.obs_estado,
           cp.obs_vieja,
           COUNT(*) OVER ()::BIGINT
      FROM con_puesto cp
     WHERE NULLIF(TRIM(COALESCE(p_search, '')), '') IS NULL
        OR cp.nombre ILIKE '%' || TRIM(p_search) || '%'
        OR cp.doc    ILIKE '%' || TRIM(p_search) || '%'
     ORDER BY cp.nombre NULLS LAST, cp.mat, cp.pe_inicio;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_grupo_listar(BIGINT, BIGINT, BIGINT[], VARCHAR)
    IS 'La tabla principal del modulo de informes: UNA FILA POR (ESTUDIANTE, PERIODO) de los periodos seleccionados (NULL o vacio = todos los del periodo academico del grupo). MODO_PERIODO es el eje que dice como leer la fila: "real" cuando el periodo tiene calificaciones, y "requerido" cuando NO tiene ninguna, en cuyo caso las notas de ASIGNATURAS son lo que el estudiante NECESITA sacar ahi para no perder la asignatura en el ano (fn_informe_periodo_requerido, V410), con estado "requerido" y las banderas ya_asegurado y alcanzable. Se exigen TRES condiciones para el modo requerido: que no haya notas, que el estudiante califique con numeros, y que el docente NO haya dejado observaciones en el periodo. La segunda no se puede preguntar al detalle del periodo, que puede venir con cero filas, asi que el universo y el es_numerico salen del AÑO COMPLETO y del CRITERIO de evaluacion -- ese es el caso que el parche de V410 desbloquea, porque antes un periodo numerico vacio se habria clasificado como cualitativo. La tercera es la SALVAGUARDA DE PREESCOLAR: normalmente bastarian las dos primeras, porque las dimensiones no tienen criterio configurado y por tanto no son numericas, pero eso depende de una configuracion AUSENTE y no de una regla -- el dia que alguien le ponga un criterio CIEN a una dimension por error, ese grupo mostraria "cuanto necesitas" en vez de las observaciones del docente. La presencia de observaciones es una senal del trabajo real y no de la configuracion, y por eso es mas confiable; FORMATO la sigue tambien, de modo que con observaciones y sin notas la fila se lee cualitativa aunque la asignatura tenga criterio numerico. En modo requerido: PUESTO viene NULL, porque ordenar por notas que nadie saco produciria un ranking de "quien necesita menos" que se leeria como uno de rendimiento; PROMEDIO_PROYECTADO viene con el DESEMPENHO_MINIMO del grado, decision explicita porque la fila entera habla de alcanzar el minimo y promediar los requeridos daria un numero que no significa nada; y CONSOLIDADO, PROMEDIO_GUARDADO, APROBADAS y REPROBADAS vienen vacios o en cero. Nada de esto se persiste: un periodo sin notas no genera consolidado, porque fn_informe_metricas_recalcular da de baja la fila cuando no queda ninguna nota guardada. El resto del contrato no cambia: asignaturas embebidas en JSONB para que el front no necesite 1+N peticiones, metricas leidas de TINFORME_PERIODO_MATRICULA cuando existen y calculadas al vuelo mientras no, puesto por RANK() particionado por periodo, sin paginacion y con busqueda por nombre y documento aplicada despues de calcular el puesto. Gate: INFORMES/VER.';
