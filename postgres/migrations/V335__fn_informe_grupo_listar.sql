-- ===========================================================================
-- V335 - fn_informe_grupo_listar: la tabla principal del modulo de informes.
--
-- UNA FILA POR (ESTUDIANTE, PERIODO)
--   No por estudiante. La pantalla lo pide asi: al elegir "1. Primer periodo"
--   y "2. Segundo periodo" cada estudiante ocupa DOS sub-filas, con la columna
--   PE indicando cual, y PR / PU / AP / RE distintos en cada una. Devolver una
--   fila por estudiante obligaria a anidar los periodos en JSON y a que el
--   front los desarme para pintar filas -- trabajo de mas para reconstruir
--   algo que SQL ya sabe producir.
--
--   Ademas este grano coincide con el de TINFORME_PERIODO_MATRICULA, que es
--   de donde salen las metricas ya consolidadas.
--
--
-- UN SOLO ENDPOINT PARA LOS DOS MUNDOS
--   Sirve para el numerico y para el cualitativo (preescolar). No se partio en
--   dos funciones: el front pregunta una vez y la RESPUESTA le dice que
--   renderizar, en vez de tener que saber de antemano si el grupo es de
--   preescolar. Eso ademas resuelve el grupo mixto sin que nadie decida a mano.
--
--   La columna que manda es FORMATO:
--     'cualitativo'  ninguna asignatura califica con numero. Vale OBSERVACION;
--                    promedio, puesto, aprobadas y reprobadas vienen NULL / 0.
--     'numerico'     hay al menos una. Valen las columnas numericas.
--
--   Se decide por el RESULTADO y no por el grado: es cualitativo cuando
--   ninguna fila del detalle es numerica. Con CERO filas -- el caso tipico de
--   preescolar -- tambien. Por eso la formula es
--   NOT COALESCE(BOOL_OR(es_numerico), FALSE) y no BOOL_AND(NOT es_numerico):
--   BOOL_AND sobre conjunto vacio devuelve NULL, que al caer a FALSE habria
--   clasificado como numerico justo al grupo que menos lo es.
--
--
-- LAS ASIGNATURAS VIENEN DENTRO
--   ASIGNATURAS es un JSONB con una entrada por asignatura del periodo. Son
--   las columnas MAT / LEN / CN / ING ... de la tabla, y por eso van aca y no
--   en una segunda llamada: sin esto el front necesitaria 1 + N peticiones
--   -- una por estudiante -- para pintar UNA tabla.
--
--     {"asignatura": 4190, "nombre": "MATEMATICAS", "abreviacion": "MAT",
--      "area": "MATEMATICAS", "orden": 1,
--      "nota": 2.5,            <- homologada, lo que se muestra
--      "nota_propuesta": 2.3,  <- homologada, SOLO si hay cambio propuesto
--      "estado": "cambio_propuesto", "es_numerico": true,
--      "valoracion": null, "simbolo": null, "aprobada": true}
--
--   Se manda la nota HOMOLOGADA y no el porcentaje: es lo que se dibuja, y es
--   la escala en la que hay que compararlas. La direccion de la flecha
--   (subio / bajo) la calcula el front comparando esas dos, que ya tiene --
--   mandarla seria duplicar un dato derivado, y calcularla sobre porcentajes
--   daria flechas sin cambio visible cuando dos porcentajes distintos
--   redondean a la misma nota.
--
--   nota_propuesta solo aparece cuando el estado es 'cambio_propuesto'. Si
--   viene NULL con ese estado, la propuesta es que YA NO HAY NOTA: el docente
--   dio de baja las actividades que la sustentaban.
--
--
-- METRICAS: GUARDADAS SI EXISTEN, CALCULADAS SI NO
--   PROMEDIO_GUARDADO, APROBADAS, REPROBADAS y SIN_DEFINIR se leen de
--   TINFORME_PERIODO_MATRICULA cuando el periodo ya se consolido; mientras no
--   exista la fila se calculan al vuelo. La pantalla se ve igual antes y
--   despues de guardar, que es el punto.
--
--   PROMEDIO_PROYECTADO se calcula SIEMPRE, porque es el "gris": lo que daria
--   hoy si se volviera a consolidar. Compararlo con el guardado es lo que
--   delata que hubo cambios.
--
--   Los dos son media simple en PORCENTAJE, no de notas homologadas: mezclar
--   escalas distintas en una media no significa nada.
--
--
-- EL PUESTO SE RECALCULA SIEMPRE
--   Es la excepcion deliberada a lo anterior, y por eso no esta en
--   TINFORME_PERIODO_MATRICULA: no es un dato del estudiante sino de su
--   posicion RELATIVA en el grupo. Subir la nota de uno cambia el puesto de
--   otro que nadie toco, asi que guardarlo obligaria a reescribir todo el
--   grupo en cada guardado -- y a ese costo no se gana nada frente a este
--   RANK(), que corre sobre un conjunto que de todas formas hay que traer.
--
--   RANK y no ROW_NUMBER, para que dos empatados compartan puesto. Se ordena
--   por el promedio VISIBLE (guardado, o proyectado si aun no se consolido) y
--   se particiona por periodo, porque el puesto es del periodo. Quien no tiene
--   promedio queda con puesto NULL en vez de ultimo: no tener notas no es
--   rendir mal.
--
--
-- SIN PAGINACION
--   La pantalla muestra el grupo entero -- son decenas de estudiantes -- y
--   paginar solo romperia el puesto, que se calcula sobre el conjunto. Se
--   mantiene la busqueda por nombre y documento, que es lo que la vista si
--   ofrece, y el filtro se aplica DESPUES de calcular el puesto para que
--   buscar a un estudiante no cambie su posicion.
--
--
-- EL DOCENTE NO VIENE AQUI
--   Quien hizo los cambios se consulta con fn_informe_cambios_pendientes
--   (V337), que trabaja sobre VARIOS grupos a la vez y devuelve
--   (grupo, asignatura, docente) -- otro grano y otra pantalla: la alerta
--   naranja. Aca solo viaja TIENE_CAMBIOS_PROPUESTOS, que es lo que la fila
--   del estudiante necesita para marcarse.
--
-- Idempotente: CREATE OR REPLACE. DROP previo porque cambia el RETURNS TABLE.
-- ===========================================================================


-- La firma ANTERIOR, de ocho argumentos: esta migracion le quita la
-- paginacion y el orden, asi que hay que retirarla o quedaria una sobrecarga.
DROP FUNCTION IF EXISTS academico_test.fn_informe_grupo_listar(BIGINT, BIGINT, BIGINT[], VARCHAR, VARCHAR, BOOLEAN, INTEGER, INTEGER);

-- Y la PROPIA. No es redundante con el CREATE OR REPLACE de abajo: migraciones
-- posteriores (V411, V412) cambian el RETURNS TABLE de esta misma firma, y
-- CREATE OR REPLACE no puede cambiar un tipo de retorno. Sin este DROP, volver
-- a ejecutar V335 sobre un esquema que ya tiene esas migraciones falla con
-- "cannot change return type of existing function" -- que es justo lo que
-- comprueba el check de idempotencia del pipeline.
--
-- La regla general: si una migracion define una funcion con RETURNS TABLE,
-- debe DROPear su propia firma antes de crearla, porque no controla que forma
-- tendra esa funcion cuando alguien la re-ejecute.
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

    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'INFORMES', 'VER',
        v_fk_ee, v_fk_sede, v_fk_jornada
    );

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
    -- Todo el detalle del grupo, de una sola vez. Un LATERAL por estudiante
    -- sobre fn_informe_estudiante_asignaturas (V334) en vez de reimplementar
    -- las formulas: mas caro -- una llamada y un gate por estudiante -- pero
    -- imposibilita que la LISTA y el DETALLE se contradigan, un bug invisible
    -- hasta que alguien reclama que la tabla dice 3,8 y las notas promedian
    -- 3,9. Los grupos son de decenas; si algun dia no alcanza, lo correcto es
    -- materializar el detalle, no duplicar la formula.
    detalle AS (
        SELECT e.pk AS mat, d.*
          FROM estudiantes e
          CROSS JOIN LATERAL academico_test.fn_informe_estudiante_asignaturas(
                         p_pk_usuario_solicitante, e.pk, p_fk_periodos_evaluacion) d
    ),
    por_periodo AS (
        SELECT e.pk   AS mat,
               e.nombre,
               e.doc,
               p.pk    AS pe,
               p.nombre AS pe_nombre,
               p.abrev  AS pe_abrev,
               p.inicio AS pe_inicio,
               -- Metricas calculadas al vuelo, para cuando aun no se consolido.
               COUNT(d.fk_tasignatura)                             AS calc_total,
               AVG(d.nota_guardada)                                AS calc_prom_guardado,
               AVG(COALESCE(d.nota_guardada, d.nota_proyectada))   AS calc_prom_visible,
               COUNT(*) FILTER (WHERE d.aprobada IS TRUE)          AS calc_aprob,
               COUNT(*) FILTER (WHERE d.aprobada IS FALSE)         AS calc_reprob,
               COUNT(*) FILTER (WHERE d.fk_tasignatura IS NOT NULL
                                  AND d.aprobada IS NULL)          AS calc_sindef,
               COALESCE(BOOL_OR(d.es_numerico), FALSE)             AS hay_numerico,
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
                           -- Solo cuando hay algo que proponer. NULL con
                           -- estado 'cambio_propuesto' significa "ya no hay
                           -- nota", no "no hay propuesta".
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
    con_metricas AS (
        SELECT pp.*,
               (ipm.PK_TINFORME_PERIODO_MATRICULA IS NOT NULL) AS esta_consolidado,
               -- Guardadas si existen, calculadas si no.
               COALESCE(ipm.PROMEDIO,    ROUND(pp.calc_prom_guardado, 2)) AS prom_guardado,
               COALESCE(ipm.ASIGNATURAS, pp.calc_total)                   AS total_asig,
               COALESCE(ipm.APROBADAS,   pp.calc_aprob)                   AS aprob,
               COALESCE(ipm.REPROBADAS,  pp.calc_reprob)                  AS reprob,
               COALESCE(ipm.SIN_DEFINIR, pp.calc_sindef)                  AS sindef,
               ob.OBSERVACION                                             AS obs,
               lv.VALOR                                                   AS obs_estado,
               CASE WHEN ob.PK_TESTUDIANTE_PERIODO_OBSERVACION IS NULL THEN NULL
                    ELSE COALESCE(hoy.n, 0) > COALESCE(ob.OBSERVACIONES_ORIGEN, 0)
               END                                                        AS obs_vieja
          FROM por_periodo pp
          LEFT JOIN academico_test.TINFORME_PERIODO_MATRICULA ipm
                 ON ipm.FK_TMATRICULA          = pp.mat
                AND ipm.FK_TPERIODO_EVALUACION = pp.pe
                AND ipm.ACTIVE = TRUE
          LEFT JOIN academico_test.TESTUDIANTE_PERIODO_OBSERVACION ob
                 ON ob.FK_TMATRICULA          = pp.mat
                AND ob.FK_TPERIODO_EVALUACION = pp.pe
                AND ob.ACTIVE = TRUE
          LEFT JOIN academico_test.TLISTA_VALOR lv
                 ON lv.PK_LISTA_VALOR = ob.FK_TLV_ESTADO_OBSERVACION
          LEFT JOIN LATERAL (
                SELECT COUNT(*) AS n
                  FROM academico_test.TACTIVIDAD a2
                  JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae2
                    ON ae2.FK_TACTIVIDAD = a2.PK_TACTIVIDAD
                   AND ae2.FK_TMATRICULA = pp.mat
                   AND ae2.ACTIVE = TRUE
                  JOIN academico_test.TACTIVIDAD_NOTA n2
                    ON n2.FK_TACTIVIDAD_ESTUDIANTE = ae2.PK_TACTIVIDAD_ESTUDIANTE
                   AND n2.ACTIVE = TRUE
                 WHERE a2.ACTIVE = TRUE
                   AND NULLIF(TRIM(COALESCE(n2.OBSERVACION, '')), '') IS NOT NULL
                   AND academico_test.fn_actividad_en_periodo_eval(a2.PK_TACTIVIDAD, pp.pe) = TRUE
          ) hoy ON TRUE
    ),
    con_puesto AS (
        -- El puesto se calcula ANTES del filtro de busqueda: buscar a un
        -- estudiante no debe cambiar su posicion en el grupo. Y se particiona
        -- por periodo, porque el puesto es del periodo.
        SELECT cm.*,
               CASE WHEN cm.calc_prom_visible IS NULL THEN NULL
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
           CASE WHEN cp.hay_numerico THEN 'numerico' ELSE 'cualitativo' END::VARCHAR,
           NOT cp.hay_numerico,
           cp.esta_consolidado,
           cp.prom_guardado,
           ROUND(cp.calc_prom_visible, 2),
           cp.pos,
           cp.total_asig::BIGINT,
           cp.aprob::BIGINT,
           cp.reprob::BIGINT,
           cp.sindef::BIGINT,
           cp.cambios,
           cp.asigs,
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
    IS 'La tabla principal del modulo de informes: UNA FILA POR (ESTUDIANTE, PERIODO) de los periodos seleccionados (NULL o vacio = todos los del periodo academico del grupo). El grano es ese y no por estudiante porque la pantalla lo pide asi -- al elegir dos periodos cada estudiante ocupa dos sub-filas, con PE indicando cual y PR/PU/AP/RE distintos en cada una -- y ademas coincide con el de TINFORME_PERIODO_MATRICULA, de donde salen las metricas consolidadas. UN SOLO ENDPOINT PARA LOS DOS MUNDOS: la columna FORMATO dice cualitativo (ninguna asignatura califica con numero: vale OBSERVACION y las metricas vienen NULL/0) o numerico. Se decide por el RESULTADO y no por el grado, y con cero filas de detalle -- preescolar tipico -- tambien da cualitativo; por eso la formula es NOT COALESCE(BOOL_OR(es_numerico), FALSE) y no BOOL_AND(NOT es_numerico), que sobre conjunto vacio da NULL y habria clasificado como numerico justo al grupo que menos lo es. ASIGNATURAS viene DENTRO como JSONB -- son las columnas MAT/LEN/CN/ING de la tabla -- porque si no el front necesitaria 1+N peticiones, una por estudiante, para pintar una sola tabla; cada entrada trae la nota HOMOLOGADA (lo que se dibuja) y nota_propuesta homologada solo cuando el estado es cambio_propuesto, con NULL ahi significando "ya no hay nota" porque el docente dio de baja las actividades. La direccion de la flecha la calcula el front comparando esas dos: mandarla seria duplicar un dato derivado, y calcularla sobre porcentajes daria flechas sin cambio visible cuando dos porcentajes distintos redondean a la misma nota. METRICAS: promedio guardado, aprobadas, reprobadas y sin_definir se leen de TINFORME_PERIODO_MATRICULA si el periodo ya se consolido (CONSOLIDADO dice si fue asi) y se calculan al vuelo mientras no; PROMEDIO_PROYECTADO se calcula siempre porque es el gris, lo que daria hoy si se reconsolidara. Ambos son media simple en PORCENTAJE, no de notas homologadas, porque mezclar escalas en una media no significa nada. EL PUESTO SE RECALCULA SIEMPRE y por eso no esta en la tabla de metricas: es posicion RELATIVA, y guardarlo obligaria a reescribir todo el grupo en cada guardado para que no quedara viejo; es RANK() -- no ROW_NUMBER, para que los empatados compartan puesto -- particionado por periodo y sobre el promedio visible, NULL para quien no tiene promedio en vez de ultimo. SIN PAGINACION: la pantalla muestra el grupo entero y paginar romperia el puesto; queda la busqueda por nombre y documento, aplicada DESPUES de calcular el puesto para que buscar a alguien no cambie su posicion. El docente que hizo los cambios NO viene aqui: eso es fn_informe_cambios_pendientes (V337), que trabaja sobre varios grupos y devuelve (grupo, asignatura, docente) para la alerta naranja; aca solo viaja TIENE_CAMBIOS_PROPUESTOS, que es lo que la fila necesita para marcarse. Gate: INFORMES/VER.';
