-- ===========================================================================
-- V412 - Dos correcciones en fn_informe_grupo_listar, las dos medidas.
--
--   (1) el PUESTO lo desplazaban los estudiantes sin promedio
--   (2) el PROMEDIO PROYECTADO se congelaba al consolidar
--
--
-- (1) EL PUESTO
--   RANK() iba con ORDER BY ... DESC, sin NULLS LAST. En Postgres los NULL
--   ordenan PRIMERO en DESC, asi que todo estudiante sin promedio -- los que
--   estan en modo 'requerido', o cualquiera sin calificar -- entraba delante
--   de los demas y les corria el puesto.
--
--   El CASE que devuelve NULL para ellos ocultaba SU puesto, pero no
--   renumeraba a los otros: RANK() ya se habia calculado sobre toda la
--   particion.
--
--   Medido en el servidor, grupo de 6 con 2 calificados:
--
--     promedio 90  ->  puesto 5
--     promedio 70  ->  puesto 6
--
--   Los 4 sin promedio empataban en el rank 1 y empujaban a los reales al 5 y
--   al 6. Con NULLS LAST quedan 1 y 2, que es lo que la pantalla debe mostrar.
--
--
-- (2) EL PROMEDIO PROYECTADO
--   PROMEDIO_PROYECTADO -- el "gris", lo que daria si se reconsolidara hoy --
--   se calculaba como AVG(COALESCE(nota_guardada, nota_proyectada)). Esa
--   COALESCE prefiere lo GUARDADO, asi que en cuanto el periodo se consolida
--   el gris pasa a ser una copia del negro y deja de moverse.
--
--   Medido: con el periodo consolidado en 90, el docente baja la nota a 30.
--   La asignatura reacciona bien -- nota 90, propuesta 30, estado
--   cambio_propuesto -- pero el promedio proyectado se queda en 90.00, igual
--   al guardado. La fila decia "hay un cambio" y a la vez "el promedio es el
--   mismo", que es imposible.
--
--   La COALESCE correcta para el gris es la inversa: preferir la PROYECCION y
--   caer a lo guardado solo cuando no hay proyeccion -- el caso de la
--   asignatura cuyas actividades se dieron de baja, donde lo unico que se
--   sabe es lo que quedo congelado.
--
--   Se agrega un agregado aparte en vez de cambiar el existente, porque el
--   PUESTO sigue ordenando por la nota VISIBLE: el puesto es la posicion
--   oficial de hoy -- sobre lo consolidado cuando existe -- y no sobre una
--   propuesta que nadie aprobo todavia. Son dos preguntas distintas y ahora
--   tienen dos agregados distintos.
--
-- Idempotente: CREATE OR REPLACE. No cambia el RETURNS TABLE, asi que no
-- necesita DROP.
-- ===========================================================================


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
               COALESCE(BOOL_OR(COALESCE(d.nota_guardada, d.nota_proyectada)
                                IS NOT NULL), FALSE)             AS tiene_notas,
               COUNT(d.fk_tasignatura)                           AS calc_total,
               AVG(d.nota_guardada)                              AS calc_prom_guardado,
               -- Para el PUESTO: la posicion OFICIAL de hoy, sobre lo
               -- consolidado cuando existe.
               AVG(COALESCE(d.nota_guardada, d.nota_proyectada)) AS calc_prom_visible,
               -- Para el GRIS: lo que daria si se reconsolidara AHORA. La
               -- COALESCE va al reves -- prefiere la PROYECCION -- y cae a lo
               -- guardado solo cuando no hay proyeccion, que es el caso de la
               -- asignatura cuyas actividades se dieron de baja.
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
        SELECT pp.*, COALESCE(ob.n, 0) AS obs_hoy
          FROM por_periodo pp
          LEFT JOIN observaciones ob ON ob.mat = pp.mat AND ob.pe = pp.pe
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
                AND b.obs_hoy = 0
                AND COALESCE(rq.hay_numerico, FALSE))  AS es_requerido,
               rq.total AS req_total,
               rq.asigs AS req_asigs,
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
               -- NULLS LAST: sin esto, en DESC los NULL van PRIMERO y cada
               -- estudiante sin promedio le corre el puesto a los demas. El
               -- CASE oculta el puesto de esos estudiantes pero NO renumera a
               -- los otros, porque RANK() ya corrio sobre toda la particion.
               CASE WHEN cm.es_requerido OR cm.calc_prom_visible IS NULL THEN NULL
                    ELSE RANK() OVER (PARTITION BY cm.pe
                                          ORDER BY cm.calc_prom_visible DESC NULLS LAST)
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
           -- El gris sale del agregado que PREFIERE la proyeccion, no del que
           -- prefiere lo guardado: ver el punto (2) de la cabecera.
           CASE WHEN cp.es_requerido THEN v_minimo
                ELSE ROUND(cp.calc_prom_proyectado, 2) END,
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
    IS 'La tabla principal del modulo de informes: una fila por (estudiante, periodo). MODO_PERIODO dice como leer la fila -- "real" cuando el periodo tiene calificaciones y "requerido" cuando no tiene ninguna, en cuyo caso las notas de ASIGNATURAS son lo que el estudiante NECESITA sacar para no perder la asignatura en el ano. El modo requerido exige tres condiciones: sin notas, que califique con numeros (tomado del CRITERIO, no de homologar un valor inexistente) y que el docente no haya dejado observaciones -- esta ultima es la salvaguarda de preescolar, porque la primera depende de una configuracion ausente y la presencia de observaciones es una senal del trabajo real. V412 corrige dos defectos medidos: (1) el RANK() del PUESTO iba DESC sin NULLS LAST, y como en Postgres los NULL ordenan primero en DESC, cada estudiante sin promedio corria el puesto de los demas -- medido en un grupo de 6 con 2 calificados, el de promedio 90 salia puesto 5 y el de 70 puesto 6, porque los 4 sin promedio empataban en el rank 1; el CASE ocultaba el puesto de esos cuatro pero no renumeraba a los otros, ya que RANK() habia corrido sobre toda la particion. (2) PROMEDIO_PROYECTADO -- el gris -- se calculaba con AVG(COALESCE(guardada, proyectada)), que prefiere lo guardado, de modo que al consolidar se volvia copia del negro y dejaba de moverse: medido, con el periodo consolidado en 90 y el docente bajando la nota a 30, la asignatura reaccionaba (nota 90, propuesta 30, estado cambio_propuesto) pero el promedio proyectado seguia en 90, de forma que la fila decia a la vez "hay un cambio" y "el promedio es el mismo". Ahora el gris usa AVG(COALESCE(proyectada, guardada)), que prefiere la proyeccion y cae a lo guardado solo cuando no hay proyeccion -- el caso de la asignatura cuyas actividades se dieron de baja. Se mantiene un agregado aparte para el PUESTO, que sigue ordenando por la nota visible: el puesto es la posicion oficial de hoy, sobre lo consolidado cuando existe, y no sobre una propuesta que nadie aprobo.';
