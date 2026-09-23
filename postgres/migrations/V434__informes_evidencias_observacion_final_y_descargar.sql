-- ===========================================================================
-- V434 - Preescolar completo en informes, y separar el BOLETIN del DESCARGAR.
--
--   fn_informe_periodo_evidencias_listar   nueva    POST /informes/evidencias
--   fn_estudiante_final_observacion        nueva    POST /informes/observacion/final
--   fn_informe_grupo_listar                +evidencias, +observacion del Final
--   fn_informe_grupo_reporte               +MATRICULAS, +evidencias   (el BOLETIN)
--   fn_informe_grupo_tabla                 nueva    POST /informes/tabla (el DESCARGAR)
--
--
-- SON CUATRO COSAS, Y CONVIENE LEERLAS EN ESTE ORDEN
--
-- =========================================================================
-- 1. EL PERIODO FINAL DE PREESCOLAR YA NO SALE VACIO
-- =========================================================================
--   El V431 dejo la fila Final de un grupo cualitativo sin nada: no se
--   promedian observaciones. Eso se corrige: el Final SI lleva observacion,
--   pero armada de otra fuente.
--
--   La distincion importa. fn_estudiante_periodo_observacion_generar
--   concatena las observaciones que el docente dejo POR ACTIVIDAD dentro de
--   un periodo -- es materia prima, y por eso se revisa antes de guardar. La
--   del Final concatena los RESUMENES YA CONSOLIDADOS de cada periodo, que
--   son texto que alguien ya leyo y acepto. No es lo mismo ni sale de la
--   misma tabla, asi que es una funcion aparte y no un parametro de la otra.
--
--   El Final no se guarda: se calcula al mirarlo, igual que la nota Final.
--   No hay donde guardarlo -- TESTUDIANTE_PERIODO_OBSERVACION tiene FK
--   obligatoria a un periodo real y el Final no lo es -- y ademas no
--   conviene: si manana alguien reconsolida un periodo, el texto del Final
--   se actualiza solo en vez de quedar viejo sin avisar.
--
--   La concatenacion va INLINE en el listado y ademas existe como funcion
--   propia para el endpoint. Es duplicacion deliberada: meter la funcion en
--   un LATERAL del listado significaria re-resolver la matricula y repetir
--   el gate una vez por estudiante, y el listado ya lo hizo por el grupo.
--
--
-- =========================================================================
-- 2. LAS EVIDENCIAS (LAS FOTOS) DE PREESCOLAR
-- =========================================================================
--   En preescolar la observacion de una actividad puede traer imagenes
--   adjuntas (TACTIVIDAD_SOPORTE). Hoy solo se ven desde planeador. Ahora
--   tambien en informes: las del periodo en cada fila, y en la fila Final
--   las de todo el año.
--
--   POR QUE NO SE REUSA EL ENDPOINT QUE YA EXISTE
--     GET /planeador/actividades/estudiantes/:ID/soportes (V461) no sirve
--     aca, por dos razones independientes:
--
--       - El gate es PLANEADOR/VER. Quien mira informes puede no tener
--         planeador -- un rector, una secretaria academica -- y se comeria
--         un 403 en una pantalla donde SI tiene permiso de ver. El gate
--         tiene que ser INFORMES/VER.
--       - La clave es PK_TACTIVIDAD_ESTUDIANTE: es por actividad. Informes
--         necesita por (estudiante, periodo), o sea el union de todas las
--         actividades del periodo. Reusarlo serian N llamadas y el front
--         tendria que saber antes que actividades hay.
--
--     Asi que va endpoint propio. La tabla que se lee es la misma y las
--     filas que devuelve son las mismas; lo que cambia es quien puede
--     pedirlas y con que llave.
--
--   FK_TPERIODO_EVALUACION nulo = TODO el año, que es lo que pide la fila
--   Final. No es un atajo: es el mismo criterio que usa el Final para la
--   nota.
--
--
-- =========================================================================
-- 3. EL BOLETIN Y EL DESCARGAR SON DOS COSAS DISTINTAS
-- =========================================================================
--   Hasta ahora habia un solo boton de descarga y llamaba a
--   fn_informe_grupo_reporte, que es el BOLETIN: solo lo consolidado, sin
--   proyecciones ni notas requeridas, porque impresas se leen como
--   calificaciones reales. Eso esta bien para un boletin y esta mal para
--   "bajame lo que estoy viendo".
--
--   Se separan:
--
--     BOLETIN    fn_informe_grupo_reporte   filtra. Ahora ademas acepta
--                                           MATRICULAS, porque un boletin es
--                                           de un estudiante.
--     DESCARGAR  fn_informe_grupo_tabla     NO filtra. Es la tabla tal cual,
--                                           con lo consolidado, lo proyectado
--                                           y lo requerido, cada uno dicho
--                                           con todas las letras en la
--                                           columna ESTADO.
--
--   MATRICULAS es un ARREGLO aunque el front hoy mande uno solo. Un boletin
--   por grupo entero es la clase de pedido que aparece en la primera semana
--   de entrega de notas, y que la funcion lo aguante desde el principio
--   cuesta un ANY() -- volver despues a cambiarle la firma cuesta otra
--   migracion y otro despliegue.
--
--   El DESCARGAR conserva SEARCH: "lo que la tabla esta mostrando" incluye
--   el filtro de busqueda, no solo el grupo.
--
--
-- =========================================================================
-- 4. LA COLUMNA evidencias
-- =========================================================================
--   El listado gana una columna mas: cuantas evidencias tiene esa fila. Se
--   necesita en los dos reportes -- ambos salen del listado -- y le ahorra
--   al front una peticion solo para saber si dibuja o no la seccion.
--
--   En el archivo va LA CUENTA, no las imagenes. El reporting-service arma
--   una tabla de texto desde el mapa `columns` del application.yml; meter
--   una imagen por fila es codigo Java nuevo en un servicio compartido
--   (bajar cada binario de file-service con su view-token, cachear, decidir
--   que pasa si una falla, y en Excel anclarlas con POI). Queda fuera de
--   esta migracion a proposito. La cuenta al menos dice que hay algo que
--   mirar y donde.
--
-- Idempotente: DROP ... IF EXISTS + CREATE OR REPLACE, ON CONFLICT DO
-- NOTHING en los endpoints y los roles, UPDATE en los que ya existian.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 1. Las evidencias de un estudiante en un periodo (o en todo el año).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_informe_periodo_evidencias_listar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tmatricula          BIGINT,
    p_fk_tperiodo_evaluacion BIGINT DEFAULT NULL
)
RETURNS TABLE(
    pk_tactividad_soporte  BIGINT,
    fk_tarchivo            BIGINT,
    nombre                 VARCHAR,
    urls3                  VARCHAR,
    peso                   BIGINT,
    etiqueta               VARCHAR,
    fecha                  DATE,
    fk_tperiodo_evaluacion BIGINT,
    periodo_nombre         VARCHAR,
    fk_tactividad          BIGINT,
    actividad_titulo       VARCHAR,
    observacion            VARCHAR
)
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
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_periodo_evidencias_listar(BIGINT, BIGINT, BIGINT)
    IS 'Las evidencias (imagenes adjuntas a la observacion) de UN estudiante en un periodo, para la pantalla de informes. Con FK_TPERIODO_EVALUACION nulo devuelve las de TODO el año, que es lo que necesita la fila Final. Lee la misma TACTIVIDAD_SOPORTE que GET /planeador/actividades/estudiantes/:ID/soportes (V461) y devuelve las mismas filas, pero NO se puede reusar aquel: su gate es PLANEADOR/VER -- quien mira informes puede no tener planeador y se comeria un 403 en una pantalla donde si puede ver -- y su llave es PK_TACTIVIDAD_ESTUDIANTE, o sea por actividad, mientras que aca hace falta por (estudiante, periodo), que es el union de todas las actividades del periodo. Cada evidencia viene con el periodo en que cae, que se resuelve por fechas con fn_actividad_en_periodo_eval y no por una FK. Gate INFORMES/VER sobre el establecimiento, sede y jornada de la matricula; 404 si la matricula no existe. V434.';


-- ---------------------------------------------------------------------------
-- 2. La observacion del Final: los resumenes YA consolidados, encadenados.
--
--    El DROP previo no es decorativo: CREATE OR REPLACE no puede cambiar el
--    tipo de retorno de una funcion que ya existe, y una migracion posterior
--    puede haberle cambiado los nombres de las columnas de salida. Sin esto,
--    re-aplicar esta migracion sobre un esquema que ya avanzo falla con
--    "cannot change return type of existing function".
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_estudiante_final_observacion(BIGINT, BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_estudiante_final_observacion(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tmatricula          BIGINT
)
RETURNS TABLE(
    observacion          TEXT,
    periodos_incluidos   NUMERIC
)
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

    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'INFORMES', 'VER',
        v_fk_ee, v_fk_sede, v_fk_jornada
    );

    RETURN QUERY
    -- Se encadenan los RESUMENES DE PERIODO, no las observaciones por
    -- actividad: son texto que un docente ya leyo y acepto. Ver la cabecera,
    -- punto 1. Prefijados con el nombre del periodo, porque un texto de tres
    -- periodos corridos sin separacion no se puede leer.
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
$function$;

COMMENT ON FUNCTION academico_test.fn_estudiante_final_observacion(BIGINT, BIGINT)
    IS 'La observacion de la fila FINAL: los resumenes de periodo YA CONSOLIDADOS de un estudiante, encadenados en orden y prefijados con el nombre de cada periodo. NO es lo mismo que fn_estudiante_periodo_observacion_generar, que concatena las observaciones que el docente dejo POR ACTIVIDAD dentro de un periodo -- eso es materia prima y por eso se revisa antes de guardar; esto es texto que alguien ya leyo y acepto. Por eso son dos funciones y no un parametro. NO se guarda en ninguna parte: se calcula al mirarlo, igual que la nota Final. No hay donde -- TESTUDIANTE_PERIODO_OBSERVACION tiene FK obligatoria a un periodo real y el Final no lo es -- y ademas asi el texto se actualiza solo cuando alguien reconsolida un periodo, en vez de quedar viejo sin avisar. Devuelve una fila siempre: con NULL y cero si el estudiante no tiene ningun resumen guardado. Gate INFORMES/VER. V434.';


-- ---------------------------------------------------------------------------
-- 3. El listado: gana la columna `evidencias` y la observacion del Final.
--
--    DROP porque cambia RETURNS TABLE, no la lista de parametros.
-- ---------------------------------------------------------------------------
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

    -- El divisor del Final. Sale del AÑO, no del filtro (V431).
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
    -- V434 -- cuantas evidencias tiene la fila. Misma forma que la CTE de
    -- arriba: una actividad cae en un periodo por fechas, no por una FK.
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
    -- La fila Final (V431). Nada de esto se evalua si no se pidio.
    -- =======================================================================
    estudiantes_final AS (
        SELECT e.* FROM estudiantes e WHERE COALESCE(p_incluir_final, FALSE)
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
    -- V434 -- la observacion del Final: los resumenes YA consolidados,
    -- encadenados. Va inline y no por LATERAL contra
    -- fn_estudiante_final_observacion para no repetir el gate una vez por
    -- estudiante; el listado ya lo hizo por el grupo. Ver la cabecera.
    final_observacion AS (
        SELECT e.pk AS mat,
               STRING_AGG(FORMAT('%s: %s', pe.NOMBRE, TRIM(ob.OBSERVACION)),
                          ' ' ORDER BY pe.FECHA_INICIO, pe.PK_TPERIODO_EVALUACION) AS texto,
               COUNT(*) AS periodos
          FROM estudiantes_final e
          JOIN academico_test.TESTUDIANTE_PERIODO_OBSERVACION ob
            ON ob.FK_TMATRICULA = e.pk
           AND ob.ACTIVE = TRUE
           AND NULLIF(TRIM(COALESCE(ob.OBSERVACION, '')), '') IS NOT NULL
          JOIN academico_test.TPERIODO_EVALUACION pe
            ON pe.PK_TPERIODO_EVALUACION = ob.FK_TPERIODO_EVALUACION
           AND pe.ACTIVE = TRUE
           AND pe.FK_TPERIODO_ACADEMICO = v_fk_peraca
         GROUP BY e.pk
    ),
    -- V434 -- las evidencias del Final son las de TODO el año, no las de un
    -- periodo: el mismo criterio con que se calcula su nota.
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
               fo.texto                         AS obs,
               COALESCE(fe.n, 0)                AS evid
          FROM estudiantes_final e
          LEFT JOIN final_agregado    fg ON fg.mat = e.pk
          LEFT JOIN final_observacion fo ON fo.mat = e.pk
          LEFT JOIN final_evidencias  fe ON fe.mat = e.pk
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
               -- V434 -- ya no va en NULL: el Final lleva encadenados los
               -- resumenes consolidados del año. Sin estado, porque nadie lo
               -- aprobo: es un derivado, como la nota Final.
               fp.obs,
               NULL::VARCHAR,
               NULL::BOOLEAN,
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

COMMENT ON FUNCTION academico_test.fn_informe_grupo_listar(BIGINT, BIGINT, BIGINT[], VARCHAR, BOOLEAN)
    IS 'Listado principal de informes: una fila por (estudiante, periodo) del grupo. p_incluir_final agrega la fila con la nota del año -- FK_TPERIODO_EVALUACION = -1 (centinela, no un PK), modo_periodo "final", consolidado false, asignaturas con estado "final" --, calculada al vuelo sobre TODOS los periodos, con el periodo sin nota guardada valiendo cero y el promedio general sacado de esas mismas asignaturas (V431). V434 agrega la columna EVIDENCIAS -- cuantas imagenes adjuntas a observaciones tiene la fila, y en la fila Final las de todo el año -- y le pone observacion a la fila Final: los resumenes de periodo YA CONSOLIDADOS encadenados en orden, que es texto que alguien ya leyo, a diferencia de las observaciones por actividad que concatena fn_estudiante_periodo_observacion_generar. Esa observacion llega SIN estado, porque nadie la aprobo: es un derivado, igual que la nota Final, y por eso tampoco se guarda. V335, V411, V412, V428, V431, V434.';


-- ---------------------------------------------------------------------------
-- 4. El BOLETIN: acepta MATRICULAS y expone las evidencias.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_informe_grupo_reporte(BIGINT, BIGINT, BIGINT[], VARCHAR, BOOLEAN);

CREATE OR REPLACE FUNCTION academico_test.fn_informe_grupo_reporte(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tgrupo              BIGINT,
    p_fk_periodos_evaluacion BIGINT[] DEFAULT NULL,
    p_search                 VARCHAR  DEFAULT NULL,
    p_incluir_final          BOOLEAN  DEFAULT FALSE,
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
               -- V430 -- en preescolar las asignaturas existen pero llegan
               -- sin nota, y explotar la fila contra ellas la mataba entera,
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
             -- V434 -- el Final de preescolar ya no es una linea sin datos:
             -- trae los resumenes consolidados del año, asi que tambien va
             -- al boletin. La condicion de antes lo excluia por cualitativo.
             OR f.modo_periodo = 'final'
           )
       AND (a.estado IS NULL
            OR a.estado IN ('guardada', 'cambio_propuesto', 'final'))
       -- V434 -- un boletin es de un estudiante. Vacio o ausente = el grupo
       -- entero, que es como se venia comportando.
       AND (p_fk_matriculas IS NULL
            OR CARDINALITY(p_fk_matriculas) = 0
            OR f.fk_tmatricula = ANY (p_fk_matriculas))
     ORDER BY f.periodo_inicio,
              f.estudiante,
              a.orden NULLS LAST,
              a.nombre;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_grupo_reporte(BIGINT, BIGINT, BIGINT[], VARCHAR, BOOLEAN, BIGINT[])
    IS 'EL BOLETIN. El informe aplanado para imprimir: una fila por (estudiante, periodo, asignatura). Llama a fn_informe_grupo_listar con los mismos filtros y el mismo gate, y FILTRA: solo sale lo consolidado -- las proyecciones y las notas requeridas quedan fuera, porque impresas se leen como calificaciones reales. Para bajar la tabla tal como se ve, sin ese filtro, esta fn_informe_grupo_tabla. PREESCOLAR entra por la rama cualitativo-con-observacion, y se le vacia el arreglo de asignaturas antes de aplanarlo cuando ninguna iba a sobrevivir el filtro (V430). La fila Final entra por una rama propia, porque su consolidado es FALSE y tiene que serlo. V434 agrega p_fk_matriculas -- un boletin es de UN estudiante; vacio o nulo sigue siendo el grupo entero, y es un arreglo desde el principio para no volver a cambiarle la firma cuando pidan el grupo completo -- y la columna EVIDENCIAS, la cuenta de imagenes de la fila. En el archivo va la CUENTA y no las imagenes: el reporting-service arma una tabla de texto desde su application.yml, y una imagen por fila es codigo Java nuevo en un servicio compartido. Ademas, desde V434 el Final de un grupo cualitativo SI se exporta, porque ya no es una linea sin datos: trae los resumenes consolidados del año. V420, V430, V431, V434.';


-- ---------------------------------------------------------------------------
-- 5. El DESCARGAR: la tabla tal cual, sin filtrar nada.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_informe_grupo_tabla(
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
                   p_search,
                   p_incluir_final)
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
           -- las letras. Un volcado que no distingue una nota guardada de
           -- una proyeccion es peor que no tenerlo: se lee como definitivo.
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
           -- El promedio visible: el guardado cuando existe, y si no el
           -- proyectado, que es exactamente lo que muestra la pantalla.
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

COMMENT ON FUNCTION academico_test.fn_informe_grupo_tabla(BIGINT, BIGINT, BIGINT[], VARCHAR, BOOLEAN)
    IS 'EL DESCARGAR. La tabla de informes tal como se esta viendo, aplanada para bajarla: una fila por (estudiante, periodo, asignatura). A diferencia de fn_informe_grupo_reporte -- el BOLETIN -- no filtra NADA: salen lo consolidado, lo proyectado, lo requerido y lo que no tiene nota, cada uno dicho con todas las letras en la columna ESTADO, y una columna CONSOLIDADO que dice si ese periodo ya se congelo. Esa es la diferencia entre las dos y es deliberada: un boletin no puede imprimir una proyeccion porque fuera del sistema se lee como una calificacion real, y un volcado que esconde la mitad de la tabla no sirve para revisar. Respeta los mismos filtros de la pantalla, SEARCH incluido, porque "lo que la tabla esta mostrando" incluye la busqueda. V434.';


-- ---------------------------------------------------------------------------
-- 6. Los endpoints.
-- ---------------------------------------------------------------------------

-- 6.a  POST /informes/evidencias
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action, style)
SELECT
    'eval-col-informes-evidencias-001',
    'SELECT * FROM academico_test.fn_informe_periodo_evidencias_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FK_TMATRICULA AS BIGINT),
    CAST(:BODY.FK_TPERIODO_EVALUACION AS BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/informes/evidencias', 'SELECT', 'POST',
    '{"BODY.FK_TMATRICULA": "BIGINT", "BODY.FK_TPERIODO_EVALUACION": "BIGINT"}'::jsonb,
    NULL,
    'Las evidencias (imagenes adjuntas a las observaciones) de UN estudiante en un periodo, para la pantalla de informes. FK_TPERIODO_EVALUACION nulo o ausente = TODO el año, que es lo que necesita la fila Final. Una fila por adjunto: pk_tactividad_soporte, fk_tarchivo (el que se le pasa a POST /files/view-token/{id} para mostrarlo), nombre, urls3, peso, etiqueta, fecha, el periodo en que cae, la actividad de la que sale y su observacion. NO es el mismo que GET /planeador/actividades/estudiantes/:ID/soportes: aquel tiene gate PLANEADOR/VER -- quien mira informes puede no tener planeador -- y se pide por actividad, no por periodo. Gate INFORMES/VER; 404 si la matricula no existe.',
    'informes-evidencias', 'DEFAULT'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

-- 6.b  POST /informes/observacion/final
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action, style)
SELECT
    'eval-col-informes-observacion-final-001',
    'SELECT * FROM academico_test.fn_estudiante_final_observacion(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FK_TMATRICULA AS BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/informes/observacion/final', 'SELECT', 'POST',
    '{"BODY.FK_TMATRICULA": "BIGINT"}'::jsonb,
    NULL,
    'La observacion de la fila FINAL de un estudiante: sus resumenes de periodo YA CONSOLIDADOS, encadenados en orden y prefijados con el nombre del periodo. NO es /informes/observacion/generar, que concatena las observaciones por ACTIVIDAD dentro de un periodo -- eso es materia prima y se revisa antes de guardar; esto es texto que alguien ya aprobo. NO ESCRIBE y no hay como guardarlo: el Final no es un periodo real, asi que se calcula al mirarlo igual que su nota, y de paso se actualiza solo cuando alguien reconsolida un periodo. Devuelve siempre una fila: observacion y periodos_incluidos, en NULL y cero si el estudiante no tiene ningun resumen guardado. Es la misma informacion que ya trae la fila Final de /informes/grupo; existe como endpoint propio para refrescarla sin recargar el listado entero. Gate INFORMES/VER.',
    'informes-observacion-final', 'DEFAULT'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

-- 6.c  POST /informes/tabla  (lo consume reporting-service, no el front)
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action, style)
SELECT
    'eval-col-informes-tabla-001',
    'SELECT * FROM academico_test.fn_informe_grupo_tabla(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FILTERS.FK_TGRUPO AS BIGINT),
    CAST(:BODY.FILTERS.PERIODOS AS BIGINT[]),
    CAST(:BODY.FILTERS.SEARCH AS VARCHAR),
    CAST(:BODY.FILTERS.INCLUIR_FINAL AS BOOLEAN)
);',
    'postgres', false, false,
    m.id_microservice,
    '/informes/tabla', 'SELECT', 'POST',
    '{"BODY.FILTERS.FK_TGRUPO": "BIGINT", "BODY.FILTERS.PERIODOS": "BIGINT[]", "BODY.FILTERS.SEARCH": "VARCHAR", "BODY.FILTERS.INCLUIR_FINAL": "BOOLEAN"}'::jsonb,
    NULL,
    'La tabla de informes tal como se esta viendo, aplanada para bajarla. Lo consume reporting-service bajo la clave "informes-tabla" (POST /reportes/informes-tabla), no el front directamente. A diferencia de /informes/reporte -- el BOLETIN -- no filtra nada: salen lo consolidado, lo proyectado, lo requerido y lo que no tiene nota, cada uno dicho con todas las letras en ESTADO, mas una columna CONSOLIDADO. Respeta los filtros de la pantalla, SEARCH incluido.',
    'informes-tabla', 'DEFAULT'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

-- 6.d  El BOLETIN pasa a recibir MATRICULAS. UPDATE: la fila ya existe.
UPDATE public.query q
   SET query = 'SELECT * FROM academico_test.fn_informe_grupo_reporte(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FILTERS.FK_TGRUPO AS BIGINT),
    CAST(:BODY.FILTERS.PERIODOS AS BIGINT[]),
    CAST(:BODY.FILTERS.SEARCH AS VARCHAR),
    CAST(:BODY.FILTERS.INCLUIR_FINAL AS BOOLEAN),
    CAST(:BODY.FILTERS.MATRICULAS AS BIGINT[])
);',
       param_types = '{"BODY.FILTERS.FK_TGRUPO": "BIGINT", "BODY.FILTERS.PERIODOS": "BIGINT[]", "BODY.FILTERS.SEARCH": "VARCHAR", "BODY.FILTERS.INCLUIR_FINAL": "BOOLEAN", "BODY.FILTERS.MATRICULAS": "BIGINT[]"}'::jsonb,
       detail = 'EL BOLETIN. El informe aplanado para imprimir: una fila por (estudiante, periodo, asignatura). Lo consume reporting-service bajo la clave "informes" (POST /reportes/informes), no el front directamente. FILTRA: solo sale lo consolidado -- las proyecciones y las notas requeridas quedan fuera, porque impresas se leen como calificaciones reales. Para bajar la tabla tal como se ve, sin filtrar, esta POST /informes/tabla. MATRICULAS (V434, opcional) acota a uno o varios estudiantes, que es lo que es un boletin; vacio o ausente = el grupo entero. INCLUIR_FINAL agrega la fila Final, que desde V434 tambien sale en preescolar, porque ya lleva los resumenes consolidados del año encadenados. La columna EVIDENCIAS trae la CUENTA de imagenes de la fila, no las imagenes.'
  FROM public.microservice m
 WHERE q.microservice_id = m.id_microservice
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/informes/reporte'
   AND q.http_method     = 'POST';


-- ---------------------------------------------------------------------------
-- 7. Roles: se COPIAN los del listado. "Quien ve el informe puede ver sus
--    evidencias, su observacion del Final y bajarlo."
-- ---------------------------------------------------------------------------
INSERT INTO public.role_query (query_id, role_id)
SELECT nuevo.id_query, rq.role_id
  FROM public.query nuevo
  JOIN public.query listado  ON listado.microservice_id = nuevo.microservice_id
                            AND listado.path_template   = '/informes/grupo'
                            AND listado.http_method     = 'POST'
  JOIN public.role_query rq  ON rq.query_id = listado.id_query
 WHERE nuevo.uuid IN ('eval-col-informes-evidencias-001',
                      'eval-col-informes-observacion-final-001',
                      'eval-col-informes-tabla-001')
ON CONFLICT DO NOTHING;
