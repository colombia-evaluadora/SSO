-- ===========================================================================
-- V474 - El promedio del informe, en el formato de calificacion del colegio.
--
-- QUE HACE  PROMEDIO_GUARDADO / PROMEDIO_PROYECTADO de fn_informe_grupo_listar
--   dejan de salir en porcentaje (la columna PR mostraba 70,0 al lado de
--   asignaturas en 3,3) y se homologan al formato del criterio de evaluacion
--   GENERAL del periodo academico. La conversion vive en la funcion nueva
--   fn_promedio_homologar.
-- POR QUE AQUI  Solo a la salida: lo guardado sigue en porcentaje, que es lo
--   unico que sobrevive a un cambio de formato. El formato es el del periodo
--   academico y no la cadena por asignatura de V428, porque un promedio agrega
--   asignaturas que podrian resolver a formatos distintos.
-- DEPENDE DE  V227 (fn_criterio_evaluacion_formato), V431 (la funcion que se
--   reescribe), V22 (TCRITERIO_EVALUACION comparte PK con TPERIODO_ACADEMICO).
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 1. fn_promedio_homologar -- porcentaje 0-100 -> lo que se muestra.
--
--    Hermana de fn_nota_homologar (V227/V428), con dos diferencias: el
--    formato lo resuelve el PERIODO ACADEMICO y no la (asignatura, grado), y
--    devuelve la valoracion tambien cuando el formato SI es numerico, porque
--    la banda existe igual y el que la quiera pintar no tiene que volver a
--    buscarla.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_promedio_homologar(
    p_porcentaje            NUMERIC,
    p_fk_tperiodo_academico BIGINT
)
RETURNS TABLE (
    promedio           NUMERIC,
    formato_valor      VARCHAR,
    es_numerico        BOOLEAN,
    valoracion_nombre  VARCHAR,
    valoracion_simbolo VARCHAR
)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_fmt RECORD;
BEGIN
    -- Sin porcentaje no hay nada que homologar. Se devuelve la fila con todo
    -- en NULL y no cero filas, para que un LEFT JOIN LATERAL no pierda al
    -- estudiante sin calificar.
    IF p_porcentaje IS NULL OR p_fk_tperiodo_academico IS NULL THEN
        RETURN QUERY SELECT NULL::NUMERIC, NULL::VARCHAR, NULL::BOOLEAN,
                            NULL::VARCHAR, NULL::VARCHAR;
        RETURN;
    END IF;

    SELECT f.* INTO v_fmt
      FROM academico_test.fn_criterio_evaluacion_formato(p_fk_tperiodo_academico) f;

    -- Sin criterio, o con criterio sin formato: se devuelve el crudo. Es el
    -- comportamiento anterior a V474, y es lo unico honesto -- no hay formato
    -- al que convertir y poner NULL borraria el dato.
    IF v_fmt.formato_valor IS NULL THEN
        RETURN QUERY SELECT p_porcentaje, NULL::VARCHAR, NULL::BOOLEAN,
                            NULL::VARCHAR, NULL::VARCHAR;
        RETURN;
    END IF;

    RETURN QUERY
    SELECT CASE WHEN v_fmt.es_numerico
                THEN ROUND(p_porcentaje / 100 * v_fmt.nota_maxima, v_fmt.decimales)
           END,
           v_fmt.formato_valor,
           v_fmt.es_numerico,
           val.NOMBRE,
           val.GRAFICA_SIMBOLO
      -- LEFT JOIN LATERAL: las escalas reales tienen huecos entre bandas y un
      -- promedio que caiga en uno sale igual, con la valoracion en NULL.
      FROM (SELECT 1) _base
      LEFT JOIN LATERAL (
            SELECT sv.FK_TVALORACION
              FROM academico_test.TESCALA_VALORACION sv
             WHERE sv.FK_TESCALA = v_fmt.fk_tescala
               AND sv.ACTIVE = TRUE
               AND p_porcentaje BETWEEN sv.LIMITE_INFERIOR AND sv.LIMITE_SUPERIOR
             ORDER BY sv.ORDEN
             LIMIT 1
      ) ev ON TRUE
      LEFT JOIN academico_test.TVALORACION val
             ON val.PK_TVALORACION = ev.FK_TVALORACION;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_promedio_homologar(NUMERIC, BIGINT)
    IS 'Convierte un PROMEDIO en porcentaje 0-100 al FORMATO DE CALIFICACION configurado en el criterio de evaluacion GENERAL de un periodo academico, y devuelve ademas la banda de la escala en la que cae. Hermana de fn_nota_homologar (V227/V428) para el grano en el que no hay una asignatura de la que sacar el formato: un promedio agrega varias, y cada una podria resolver por la cadena de V428 a un formato distinto. El criterio general se lee con fn_criterio_evaluacion_formato del PK del periodo academico, porque TCRITERIO_EVALUACION comparte PK con TPERIODO_ACADEMICO (V22). En los formatos numericos (CINCO/DIEZ/CIEN) devuelve el numero redondeado a los decimales configurados; en LITERAL/SIMBOLO/CARITA devuelve promedio NULL y lo que vale es la valoracion, igual que hace fn_nota_homologar con las notas. Sin criterio o sin formato configurado devuelve el porcentaje CRUDO -- no hay formato al que convertir y anularlo borraria el dato. Nunca devuelve cero filas: con porcentaje NULL devuelve la fila en NULL, para que un LEFT JOIN LATERAL no pierda al estudiante sin calificar. Punto unico de esta conversion; la consume fn_informe_grupo_listar. V474.';


-- ---------------------------------------------------------------------------
-- 2. El listado. Mismo cuerpo de V431 con el promedio homologado a la salida
--    y cuatro columnas nuevas al final (la valoracion del promedio guardado y
--    la del proyectado). Se recrea entero y no con CREATE OR REPLACE porque
--    cambia el tipo de retorno.
-- ---------------------------------------------------------------------------
-- Las DOS firmas: V439 volvio a la de 4 argumentos, asi que en toda base que
-- haya pasado por V439 esa es la viva. Recrear la de 5 sin dropearla deja las
-- dos, y como p_incluir_final tiene DEFAULT, la llamada de 4 argumentos que
-- hace la fila de public.query matchea con ambas: 42725 ambiguous_function,
-- que el query-service traduce a QUERY_DEFINITION.
DROP FUNCTION IF EXISTS academico_test.fn_informe_grupo_listar(BIGINT, BIGINT, BIGINT[], VARCHAR);
DROP FUNCTION IF EXISTS academico_test.fn_informe_grupo_listar(BIGINT, BIGINT, BIGINT[], VARCHAR, BOOLEAN);


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
    total_count                BIGINT,
    -- V474 -- la banda de la escala del criterio general en la que cae cada
    -- promedio. En un formato no numerico es LO UNICO que hay que mostrar,
    -- porque ahi el promedio viene NULL.
    promedio_valoracion            VARCHAR,
    promedio_simbolo               VARCHAR,
    promedio_proyectado_valoracion VARCHAR,
    promedio_proyectado_simbolo    VARCHAR,
    -- El formato con el que se homologo (NULL si el colegio no configuro
    -- criterio general y el promedio salio en porcentaje crudo).
    promedio_formato               VARCHAR
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
           -- V474 -- el promedio ya no sale en porcentaje: se homologa con el
           -- formato del criterio general del periodo academico, el mismo
           -- criterio con el que la pantalla pinta cada asignatura. En un
           -- formato no numerico estos dos vienen NULL y lo que vale es la
           -- valoracion, cuatro columnas mas abajo.
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
     -- La fila Final tiene fecha 9999-12-31 justamente para caer al final del
     -- bloque de su estudiante sin un ORDER BY especial.
     ORDER BY s.o_nombre NULLS LAST, s.o_mat, s.o_pe_inicio;
END;
$function$;


COMMENT ON FUNCTION academico_test.fn_informe_grupo_listar(BIGINT, BIGINT, BIGINT[], VARCHAR, BOOLEAN)
    IS 'Listado principal de informes: una fila por (estudiante, periodo) del grupo, con promedio, puesto, aprobadas/reprobadas y las asignaturas en JSONB. p_incluir_final (V431): con TRUE, cada estudiante recibe ademas una fila con la nota FINAL del año -- fk_tperiodo_evaluacion = -1 (centinela, no un PK), periodo_nombre "Final", modo_periodo "final", consolidado FALSE y cada asignatura con estado "final". No se guarda en ninguna parte: se calcula al vuelo. Tres reglas: (1) se calcula sobre TODOS los periodos activos del periodo academico, NO sobre los que el usuario tenga marcados, porque el filtro de periodos es de vista y un final que cambia segun lo que este desmarcado no es un final; (2) el periodo sin nota GUARDADA vale CERO y el divisor es el total de periodos del año, de modo que a mitad de año el Final se lee como incompleto en vez de como un promedio cerrado; (3) el promedio general es el promedio de las notas finales por asignatura, para que la fila cierre consigo misma. En un grupo cualitativo (preescolar) no hay nada que promediar: la fila aparece vacia, sin observacion y sin puesto. V474: PROMEDIO_GUARDADO y PROMEDIO_PROYECTADO ya NO salen en porcentaje -- se homologan con fn_promedio_homologar al formato del criterio de evaluacion GENERAL del periodo academico, que es el mismo formato con el que se pintan las asignaturas de la fila; antes la columna PR mostraba 70,0 al lado de asignaturas en 3,3. En un formato no numerico los dos vienen NULL y lo que vale son PROMEDIO_VALORACION / PROMEDIO_SIMBOLO (y sus gemelas del proyectado); sin criterio configurado se sigue devolviendo el porcentaje crudo. PROMEDIO_FORMATO dice con cual se homologo. Esto cubre tambien el promedio de la fila Final y la nota requerida que viaja en PROMEDIO_PROYECTADO cuando el modo es "requerido", porque la conversion esta en un solo punto de la salida. El PUESTO se sigue calculando sobre el porcentaje: la conversion es monotona y redondear antes de ordenar crearia empates que no existen. V335, V411, V412, V428, V431, V474.';


-- ---------------------------------------------------------------------------
-- 3. El endpoint. Solo cambia la documentacion -- el SQL es SELECT *, asi que
--    las columnas nuevas viajan solas. UPDATE y no INSERT: la fila existe
--    desde V342 y su INSERT original es ON CONFLICT DO NOTHING.
-- ---------------------------------------------------------------------------
UPDATE public.query q
   SET detail = 'Listado principal de informes: una fila por (estudiante, periodo) del grupo, con promedio, puesto, aprobadas/reprobadas y las asignaturas embebidas en JSONB (nota homologada y nota_propuesta cuando hay cambio). La columna FORMATO dice si la fila se lee como numerica o cualitativa (preescolar); en el caso cualitativo lo que vale es OBSERVACION. PERIODOS vacio o ausente = todos los del periodo academico del grupo. Sin paginacion: la pantalla muestra el grupo entero y paginar romperia el puesto. SEARCH filtra por nombre y documento DESPUES de calcular el puesto. INCLUIR_FINAL (V431, opcional, por defecto false) agrega a cada estudiante una fila mas con la nota FINAL del año: llega con FK_TPERIODO_EVALUACION = -1 -- un centinela, no un PK --, PERIODO_NOMBRE "Final", MODO_PERIODO "final", CONSOLIDADO false y cada asignatura con ESTADO "final". Se calcula al vuelo sobre TODOS los periodos del año, no sobre los de PERIODOS, y un periodo sin nota guardada vale cero. En preescolar la fila llega vacia y sin observacion. V474: PROMEDIO_GUARDADO y PROMEDIO_PROYECTADO llegan en el FORMATO DE CALIFICACION del criterio de evaluacion general del periodo academico (3,3 sobre cinco), no en el porcentaje guardado. Si ese formato no es numerico llegan NULL y lo que se pinta son PROMEDIO_VALORACION / PROMEDIO_SIMBOLO y PROMEDIO_PROYECTADO_VALORACION / PROMEDIO_PROYECTADO_SIMBOLO; sin criterio configurado se recibe el porcentaje crudo. PROMEDIO_FORMATO (CINCO/DIEZ/CIEN/LITERAL/SIMBOLO/CARITA) dice con cual se homologo.'
  FROM public.microservice m
 WHERE q.microservice_id = m.id_microservice
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/informes/grupo'
   AND q.http_method     = 'POST';
