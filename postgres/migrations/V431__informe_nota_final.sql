-- ===========================================================================
-- V431 - La nota FINAL: un periodo mas que no existe en el calendario.
--
--   fn_informe_grupo_listar    +p_incluir_final
--   fn_informe_grupo_reporte   +p_incluir_final
--   POST /informes/grupo       +BODY.INCLUIR_FINAL
--   POST /informes/reporte     +BODY.FILTERS.INCLUIR_FINAL
--
--
-- QUE ES
--   Al lado de los checkbox de periodo la pantalla tiene uno mas, que se
--   llama siempre "Final" y no corresponde a ninguna fila de
--   TPERIODO_EVALUACION. Marcado, cada estudiante recibe una fila extra con
--   la nota definitiva del año: por asignatura y en el promedio general, con
--   su puesto y su conteo de aprobadas y reprobadas.
--
--   No se guarda en ninguna parte. Se calcula al vuelo cada vez, igual que el
--   promedio proyectado, y por eso no hay migracion de datos ni tabla nueva.
--
--
-- LAS TRES DECISIONES DE CALCULO (y por que estas)
--
--   (1) SOBRE TODOS LOS PERIODOS DEL AÑO, no sobre los marcados.
--       El filtro de periodos es de VISTA: sirve para mirar P1 y P3 uno al
--       lado del otro. Si el Final se calculara sobre esa seleccion, el mismo
--       estudiante tendria un "final" distinto segun lo que el usuario
--       hubiera desmarcado, y un boletin sacado con un solo periodo marcado
--       imprimiria como definitiva la nota de ese periodo. Una nota final es
--       del año o no es final.
--
--       En codigo: el Final no usa la CTE `periodos` -- que si respeta el
--       filtro -- sino un conteo aparte de los periodos activos del periodo
--       academico, y llama al detalle con periodos NULL.
--
--   (2) EL PERIODO SIN NOTA GUARDADA VALE CERO.
--       El divisor es siempre el total de periodos del año, no "los que
--       tengan nota". Asi el Final de mitad de año se lee como lo que es --
--       una nota todavia incompleta, que sube a medida que se consolida --
--       y no como un promedio ya cerrado que despues baja sin explicacion.
--       Es tambien lo que hace un profesor con su planilla en la mano.
--
--       Ojo con la consecuencia, que es real y hay que saberla: en marzo casi
--       todo el mundo pierde. El Final no es una prediccion.
--
--       Solo cuenta la nota GUARDADA. La proyectada no entra ni aqui ni en el
--       boletin, por lo mismo que explica el V420: impresa deja de parecer
--       una proyeccion.
--
--   (3) EL PROMEDIO GENERAL SALE DE LAS ASIGNATURAS DEL FINAL.
--       Se promedian las notas finales ya calculadas, no los promedios de
--       cada periodo. Asi la fila cierra consigo misma: el numero de la
--       columna de promedio es el promedio de los numeros que estan a su
--       lado, que es lo primero que alguien verifica a mano.
--
--
-- PREESCOLAR NO TIENE FINAL
--   Un grupo cualitativo no califica asignaturas: lo que hay es la
--   observacion de cada periodo, y no existe el promedio de tres textos.
--   La fila Final igual aparece en la PANTALLA -- vacia, sin observacion y
--   sin ofrecer generarla -- para que no se vea como que falto cargar algo;
--   en el BOLETIN no sale, porque una fila sin un solo dato no es nada que
--   imprimir.
--
--   Cualitativo se decide por estudiante y sobre el año entero: es numerico
--   el que tenga al menos una asignatura numerica segun
--   fn_asignatura_tipo_evaluacion (V428). No se mira lo que se cargo.
--
--
-- COMO VIAJA LA FILA
--   Con la misma forma que las demas, para que la tabla, el aplanado del
--   boletin y el front no necesiten un camino aparte:
--
--     fk_tperiodo_evaluacion  -1          no es un PK; es el centinela de
--                                         "esta fila no es un periodo"
--     periodo_nombre          'Final'
--     periodo_abreviacion     'FIN'
--     periodo_inicio          9999-12-31  para que ordene de ultima
--     modo_periodo            'final'     el tercer modo, junto a 'real' y
--                                         'requerido'
--     consolidado             FALSE       porque no lo esta: no hay fila en
--                                         TINFORME_PERIODO_MATRICULA ni la
--                                         va a haber
--     estado de cada asignatura  'final'  no 'guardada': la nota de la celda
--                                         no la guardo nadie
--
--   Que `consolidado` sea FALSE obliga a que el boletin la deje entrar por su
--   propia rama -- abajo --, y esta bien que asi sea: es una excepcion
--   explicita y no una fila que se cuela porque mentimos en una bandera.
--
--
-- POR QUE HAY QUE HACER DROP Y NO ALCANZA CON CREATE OR REPLACE
--   El parametro nuevo va al final y con DEFAULT, asi que las llamadas
--   viejas de cuatro argumentos siguen compilando. Pero CREATE OR REPLACE con
--   distinta cantidad de parametros no reemplaza: CREA UNA SOBRECARGA, y
--   entonces una llamada de cuatro argumentos calza con las dos y Postgres
--   responde "function is not unique". Por eso se borra primero la firma de
--   cuatro.
--
-- Idempotente: DROP ... IF EXISTS, CREATE OR REPLACE, y UPDATE de las filas
-- de public.query (no INSERT: ya existen).
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 1. El listado, con la fila Final.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_informe_grupo_listar(BIGINT, BIGINT, BIGINT[], VARCHAR);

CREATE OR REPLACE FUNCTION academico_test.fn_informe_grupo_listar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tgrupo              BIGINT,
    p_fk_periodos_evaluacion BIGINT[] DEFAULT NULL,
    p_search                 VARCHAR  DEFAULT NULL,
    p_incluir_final          BOOLEAN  DEFAULT FALSE
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
    v_minimo      NUMERIC;
    v_n_periodos  INTEGER;
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

    -- El divisor del Final. Sale del AÑO, no del filtro: ver (1) y (2) en la
    -- cabecera. Si por lo que sea no hubiera ninguno, el NULLIF de mas abajo
    -- evita la division por cero y el Final queda en NULL.
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
               -- V428 -- el MODO depende solo de si hay notas.
               (NOT b.tiene_notas
                AND COALESCE(rq.hay_numerico, FALSE))  AS es_requerido,
               rq.total AS req_total,
               rq.asigs AS req_asigs,
               -- V428 -- el TIPO lo resuelve fn_asignatura_tipo_evaluacion
               -- (referente -> plan -> criterio) por (asignatura, grado), sin
               -- mirar que se cargo.
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
               -- NULLS LAST: sin esto, en DESC los NULL van PRIMERO y cada
               -- estudiante sin promedio le corre el puesto a los demas. El
               -- CASE oculta el puesto de esos estudiantes pero NO renumera a
               -- los otros, porque RANK() ya corrio sobre toda la particion.
               CASE WHEN cm.es_requerido OR cm.calc_prom_visible IS NULL THEN NULL
                    ELSE RANK() OVER (PARTITION BY cm.pe
                                          ORDER BY cm.calc_prom_visible DESC NULLS LAST)
               END AS pos
          FROM con_metricas cm
    ),

    -- =======================================================================
    -- V431 -- la fila Final. Todo lo que sigue solo se evalua si el usuario
    -- marco el checkbox: `estudiantes_final` filtra por el parametro ANTES de
    -- la lateral, de modo que sin Final el CROSS JOIN LATERAL no corre para
    -- ningun estudiante y esta rama no cuesta nada.
    -- =======================================================================
    estudiantes_final AS (
        SELECT e.* FROM estudiantes e WHERE COALESCE(p_incluir_final, FALSE)
    ),
    detalle_ano AS (
        -- Periodos NULL: el AÑO COMPLETO, sin el filtro de la pantalla. Ver
        -- (1) en la cabecera. El gate lo vuelve a aplicar esta llamada.
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
               -- (2) El periodo sin nota guardada suma CERO y el divisor
               -- sigue siendo el año entero. La proyectada no entra.
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
               -- (3) El general es el promedio de las asignaturas de esta
               -- misma fila, no el de los promedios de cada periodo.
               ROUND(AVG(fa.nota), 2)                   AS promedio,
               JSONB_AGG(
                   JSONB_BUILD_OBJECT(
                       'asignatura',  fa.asig,
                       'nombre',      fa.nombre,
                       'abreviacion', fa.abrev,
                       'area',        fa.area,
                       'orden',       fa.orden,
                       'nota',        h.nota_homologada,
                       -- 'final' y no 'guardada': la celda no la guardo
                       -- nadie, y quien lea el JSON tiene que poder
                       -- distinguirlo sin mirar de que fila viene.
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
    final_fila AS (
        -- LEFT: el estudiante sin una sola asignatura en el año igual recibe
        -- su fila Final, vacia. Desaparecer solo a algunos se lee como un
        -- error de carga.
        SELECT e.pk AS mat,
               e.nombre,
               e.doc,
               COALESCE(fg.hay_numerico, FALSE) AS hay_numerico,
               COALESCE(fg.total,  0)           AS total,
               COALESCE(fg.aprob,  0)           AS aprob,
               COALESCE(fg.reprob, 0)           AS reprob,
               COALESCE(fg.sindef, 0)           AS sindef,
               fg.promedio,
               COALESCE(fg.asigs, '[]'::JSONB)  AS asigs
          FROM estudiantes_final e
          LEFT JOIN final_agregado fg ON fg.mat = e.pk
    ),
    final_puesto AS (
        SELECT ff.*,
               -- Mismo criterio que el puesto de un periodo: sin promedio no
               -- hay puesto, y preescolar nunca lo tiene.
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
               -- El gris sale del agregado que PREFIERE la proyeccion.
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
               cp.obs_vieja              AS o_obs_vieja
          FROM con_puesto cp

        UNION ALL

        SELECT fp.mat,
               fp.nombre,
               fp.doc,
               -- Centinela, no un PK. Ver "COMO VIAJA LA FILA".
               (-1)::BIGINT,
               'Final'::VARCHAR,
               'FIN'::VARCHAR,
               '9999-12-31'::DATE,
               'final'::VARCHAR,
               CASE WHEN fp.hay_numerico THEN 'numerico' ELSE 'cualitativo' END::VARCHAR,
               NOT fp.hay_numerico,
               -- No esta consolidada y no lo va a estar: no hay fila en
               -- TINFORME_PERIODO_MATRICULA para un periodo que no existe.
               FALSE,
               -- Preescolar no promedia observaciones: la fila sale vacia.
               CASE WHEN fp.hay_numerico THEN fp.promedio END,
               CASE WHEN fp.hay_numerico THEN fp.promedio END,
               fp.pos,
               CASE WHEN fp.hay_numerico THEN fp.total  ELSE 0 END::BIGINT,
               CASE WHEN fp.hay_numerico THEN fp.aprob  ELSE 0 END::BIGINT,
               CASE WHEN fp.hay_numerico THEN fp.reprob ELSE 0 END::BIGINT,
               CASE WHEN fp.hay_numerico THEN fp.sindef ELSE 0 END::BIGINT,
               FALSE,
               CASE WHEN fp.hay_numerico THEN fp.asigs ELSE '[]'::JSONB END,
               -- Sin observacion, y el front no ofrece generarla: el Final no
               -- es un periodo y no hay actividades suyas que resumir.
               NULL::TEXT,
               NULL::VARCHAR,
               NULL::BOOLEAN
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
           COUNT(*) OVER ()::BIGINT
      FROM salida s
     WHERE NULLIF(TRIM(COALESCE(p_search, '')), '') IS NULL
        OR s.o_nombre ILIKE '%' || TRIM(p_search) || '%'
        OR s.o_doc    ILIKE '%' || TRIM(p_search) || '%'
     -- La fila Final tiene fecha 9999-12-31 justamente para caer al final del
     -- bloque de su estudiante sin un ORDER BY especial.
     ORDER BY s.o_nombre NULLS LAST, s.o_mat, s.o_pe_inicio;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_grupo_listar(BIGINT, BIGINT, BIGINT[], VARCHAR, BOOLEAN)
    IS 'Listado principal de informes: una fila por (estudiante, periodo) del grupo, con promedio, puesto, aprobadas/reprobadas y las asignaturas en JSONB. V431 agrega p_incluir_final: con TRUE, cada estudiante recibe ademas una fila con la nota FINAL del año -- fk_tperiodo_evaluacion = -1 (centinela, no un PK), periodo_nombre "Final", modo_periodo "final", consolidado FALSE y cada asignatura con estado "final". No se guarda en ninguna parte: se calcula al vuelo. Tres reglas: (1) se calcula sobre TODOS los periodos activos del periodo academico, NO sobre los que el usuario tenga marcados, porque el filtro de periodos es de vista y un final que cambia segun lo que este desmarcado no es un final; (2) el periodo sin nota GUARDADA vale CERO y el divisor es el total de periodos del año, de modo que a mitad de año el Final se lee como incompleto en vez de como un promedio cerrado -- la nota proyectada no entra, por lo mismo que no entra en el boletin; (3) el promedio general es el promedio de las notas finales por asignatura, para que la fila cierre consigo misma. En un grupo cualitativo (preescolar) no hay nada que promediar: la fila aparece vacia, sin observacion y sin puesto, y el boletin la deja fuera. V335, V411, V412, V428, V431.';


-- ---------------------------------------------------------------------------
-- 2. El boletin: acepta el Final y lo deja entrar por su propia rama.
--
--    Incluye el arreglo del V430 -- el vaciado del arreglo de asignaturas
--    cuando la fila solo tiene la observacion para decir.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_informe_grupo_reporte(BIGINT, BIGINT, BIGINT[], VARCHAR);

CREATE OR REPLACE FUNCTION academico_test.fn_informe_grupo_reporte(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tgrupo              BIGINT,
    p_fk_periodos_evaluacion BIGINT[] DEFAULT NULL,
    p_search                 VARCHAR  DEFAULT NULL,
    p_incluir_final          BOOLEAN  DEFAULT FALSE
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
    observacion  TEXT
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
                   p_search,
                   p_incluir_final)
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
               -- V431 -- la del Final no la guardo nadie, y el boletin tiene
               -- que decirlo: es el promedio del año calculado al imprimir.
               WHEN 'final'            THEN 'Final (promedio del año)'
               ELSE a.estado
           END::VARCHAR,
           a.aprobada,
           f.promedio_guardado,
           f.puesto,
           f.observacion
      FROM filas f
      LEFT JOIN LATERAL JSONB_TO_RECORDSET(
               -- V430 -- ver esa migracion: en preescolar las asignaturas
               -- existen pero llegan sin nota, y explotar la fila contra
               -- ellas la mataba entera, observacion incluida.
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
             -- V431 -- el Final necesita su propia puerta: no esta
             -- consolidado (no existe la fila que lo consolidaria) y aun asi
             -- va en el boletin cuando el usuario lo pidio. En un grupo
             -- cualitativo no entra: seria una linea sin un solo dato.
             OR (f.modo_periodo = 'final' AND f.es_cualitativo IS FALSE)
           )
       AND (a.estado IS NULL
            OR a.estado IN ('guardada', 'cambio_propuesto', 'final'))
     ORDER BY f.periodo_inicio,
              f.estudiante,
              a.orden NULLS LAST,
              a.nombre;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_grupo_reporte(BIGINT, BIGINT, BIGINT[], VARCHAR, BOOLEAN)
    IS 'El informe de un grupo aplanado para exportar a PDF o Excel: una fila por (estudiante, periodo, asignatura). Llama a fn_informe_grupo_listar con los mismos parametros y expande su columna JSONB, asi que hereda el gate y los filtros de la pantalla. EXPORTA SOLO LO CONSOLIDADO -- las proyecciones y las notas requeridas quedan fuera porque impresas se leen como calificaciones reales. PREESCOLAR entra por la rama cualitativo-con-observacion, y ademas se le vacia el arreglo de asignaturas antes de aplanarlo cuando ninguna iba a sobrevivir el filtro (V430: sin eso, las asignaturas sin nota de preescolar explotaban la fila y se llevaban la observacion, borrando al estudiante del PDF). V431 agrega p_incluir_final: la fila Final -- el promedio del año, calculado al vuelo -- entra por una tercera rama explicita, porque su consolidado es FALSE y tiene que serlo; sus asignaturas llegan con estado "final" y el boletin las imprime como "Final (promedio del año)" para que nadie las confunda con una nota que alguien guardo. En un grupo cualitativo el Final no se exporta: seria una linea sin datos. V420, V430, V431.';


-- ---------------------------------------------------------------------------
-- 3. Los dos endpoints. Son UPDATE, no INSERT: las filas ya existen desde el
--    V342 y el V420, y lo unico que cambia es que pasan el parametro nuevo.
--
--    El bind es opcional: si el front no lo manda llega NULL, y el
--    COALESCE(p_incluir_final, FALSE) de la funcion lo trata como "sin
--    Final". Asi la pantalla vieja sigue funcionando sin tocar nada.
-- ---------------------------------------------------------------------------
UPDATE public.query q
   SET query = 'SELECT * FROM academico_test.fn_informe_grupo_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FK_TGRUPO AS BIGINT),
    CAST(:BODY.PERIODOS AS BIGINT[]),
    CAST(:BODY.SEARCH AS VARCHAR),
    CAST(:BODY.INCLUIR_FINAL AS BOOLEAN)
);',
       param_types = '{"BODY.FK_TGRUPO": "BIGINT", "BODY.PERIODOS": "BIGINT[]", "BODY.SEARCH": "VARCHAR", "BODY.INCLUIR_FINAL": "BOOLEAN"}'::jsonb,
       detail = 'Listado principal de informes: una fila por (estudiante, periodo) del grupo, con promedio, puesto, aprobadas/reprobadas y las asignaturas embebidas en JSONB (nota homologada y nota_propuesta cuando hay cambio). La columna FORMATO dice si la fila se lee como numerica o cualitativa (preescolar); en el caso cualitativo lo que vale es OBSERVACION. PERIODOS vacio o ausente = todos los del periodo academico del grupo. Sin paginacion: la pantalla muestra el grupo entero y paginar romperia el puesto. SEARCH filtra por nombre y documento DESPUES de calcular el puesto. INCLUIR_FINAL (V431, opcional, por defecto false) agrega a cada estudiante una fila mas con la nota FINAL del año: llega con FK_TPERIODO_EVALUACION = -1 -- un centinela, no un PK --, PERIODO_NOMBRE "Final", MODO_PERIODO "final", CONSOLIDADO false y cada asignatura con ESTADO "final". Se calcula al vuelo sobre TODOS los periodos del año, no sobre los de PERIODOS, y un periodo sin nota guardada vale cero; el promedio general es el promedio de esas notas finales. En preescolar la fila llega vacia y sin observacion, porque no se promedian observaciones.'
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
    CAST(:BODY.FILTERS.INCLUIR_FINAL AS BOOLEAN)
);',
       param_types = '{"BODY.FILTERS.FK_TGRUPO": "BIGINT", "BODY.FILTERS.PERIODOS": "BIGINT[]", "BODY.FILTERS.SEARCH": "VARCHAR", "BODY.FILTERS.INCLUIR_FINAL": "BOOLEAN"}'::jsonb,
       detail = 'El informe de un grupo aplanado para exportar: una fila por (estudiante, periodo, asignatura). Lo consume reporting-service bajo la clave "informes" (POST /reportes/informes), no el front directamente. Llama a la misma fn_informe_grupo_listar de la pantalla, con los mismos filtros y el mismo gate. EXPORTA SOLO LO CONSOLIDADO: las proyecciones y las notas requeridas para aprobar quedan fuera, porque impresas en un boletin se leerian como calificaciones reales. Una asignatura con cambio propuesto si sale, con su nota guardada. PREESCOLAR entra por otra puerta: ahi el informe se cierra guardando la OBSERVACION, asi que esas filas salen con la asignatura vacia y su texto. INCLUIR_FINAL (V431, opcional) agrega la fila Final -- el promedio del año calculado al vuelo, no una nota guardada --, que se imprime con estado "Final (promedio del año)"; en un grupo cualitativo no se agrega, porque seria una linea sin datos. Un grupo sin nada cerrado devuelve cero filas.'
  FROM public.microservice m
 WHERE q.microservice_id = m.id_microservice
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/informes/reporte'
   AND q.http_method     = 'POST';
