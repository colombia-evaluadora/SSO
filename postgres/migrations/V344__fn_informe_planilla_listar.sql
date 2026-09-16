-- ===========================================================================
-- V344 - fn_informe_planilla_listar: la planilla de calificacion a la que
--        llevan las dos alertas del modulo de informes.
--
-- POR QUE UNA PROPIA Y NO LA DE V239
--   El modulo de planeador ya tiene su planilla -- fn_planilla_columnas_listar
--   + fn_planilla_calificaciones_listar, endpoints /planeador/planilla/*. NO
--   se toca. Esta es otra pantalla con otra pregunta, y si se intentara servir
--   a las dos con la misma funcion habria que cambiar el comportamiento de
--   aquella, que es la del docente calificando dia a dia.
--
--   Tres diferencias de fondo, no de forma:
--
--   1. ACOTA POR PERIODO DE EVALUACION, no por ventana de fechas libre. Aca se
--      llega desde una alerta que habla de un periodo concreto.
--
--   2. USA LA MISMA PROYECCION QUE DETECTA LOS CAMBIOS
--      (fn_asignatura_definitiva_proyectada_periodo, V333). La de V239 usa
--      fn_planilla_definitiva_proyectada, que NO filtra por periodo: son
--      numeros distintos, y si esta pantalla mostrara el otro, el revisor
--      veria una definitiva que no corresponde al cambio que vino a aprobar.
--
--   3. LA LINEA BASE SALE DE TASIGNATURA_NOTA. La de V239 la toma de
--      TUNIDAD_NOTA y su propio autor dejo anotado que HOY ES SIEMPRE NULL
--      porque nadie consolida esa tabla -- la dejo calculada "para que la
--      flecha funcione sola en cuanto exista la consolidacion". Esa
--      consolidacion ya existe (V336) pero vive en TASIGNATURA_NOTA, asi que
--      apuntar ahi es lo que enciende la flecha.
--
--   Lo que SI se reutiliza es fn_planilla_grupo_asignatura_assert (V239): es
--   un validador puro, sin gate ni efectos, y usarlo hace que el mismo filtro
--   invalido de el mismo error en las dos pantallas.
--
--
-- EL CRITERIO DE FECHA ES EL NUESTRO, Y ESO IMPORTA
--   fn_planilla_actividades_universo decide columnas por SOLAPAMIENTO con la
--   ventana:
--       COALESCE(CIERRE,INICIO) >= desde AND COALESCE(INICIO,CIERRE) <= hasta
--   Nosotros decidimos pertenencia por FECHA DE CORTE
--   (fn_actividad_en_periodo_eval, V332):
--       COALESCE(CIERRE,INICIO,CREACION) BETWEEN inicio AND fin
--
--   No son equivalentes: una actividad que ABRE en el primer periodo y CIERRA
--   en el segundo entra en las dos ventanas por solapamiento, pero solo suma
--   al segundo en nuestra proyeccion. Si aca se usara el solapamiento, esa
--   actividad seria una columna del primer periodo cuya nota NO estaria
--   incluida en la definitiva proyectada de ese periodo -- y nadie podria
--   explicar la diferencia mirando la pantalla.
--
--   Por eso las columnas se definen con fn_actividad_en_periodo_eval: columnas
--   y definitiva salen del MISMO conjunto de actividades, siempre.
--
--
-- UN SOLO BUSCADOR PARA DOS DIMENSIONES
--   La caja dice "Buscar por nombre, apellido o actividad", asi que el mismo
--   texto tiene que poder filtrar filas o columnas. La regla es:
--
--     - se filtran los ESTUDIANTES por nombre/documento,
--     - se filtran las ACTIVIDADES por titulo,
--     - pero una dimension donde NADA coincidio se deja INTACTA.
--
--   Asi, buscar "Mariana" filtra las filas y conserva todas las columnas;
--   buscar "fracciones" conserva todas las filas y filtra las columnas. Si no
--   coincide con ninguna de las dos, no hay resultados -- que es lo honesto.
--
--   La alternativa (filtrar las dos siempre) vaciaria la tabla en cuanto se
--   escribiera un nombre, porque ninguna actividad se llama como un alumno.
--
--
-- SIN PAGINACION
--   La planilla muestra el grupo entero; son decenas de estudiantes y las
--   columnas son las actividades del periodo. Paginar obligaria ademas a
--   decidir que hacer con las columnas, que no son filas.
--
--
-- LAS FLECHAS LAS PINTA EL FRONT
--   Se devuelven las dos definitivas YA HOMOLOGADAS -- guardada y proyectada
--   -- y el front compara. No se manda una columna "tendencia": seria
--   duplicar un dato derivado, y calcularla sobre porcentajes daria flecha
--   cuando dos porcentajes distintos redondean a la misma nota. Comparando lo
--   que se DIBUJA, la flecha aparece solo si el numero cambia a la vista.
--
-- Idempotente: CREATE OR REPLACE. Funcion nueva, sin sobrecarga previa.
-- ===========================================================================


CREATE OR REPLACE FUNCTION academico_test.fn_informe_planilla_listar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tgrupo              BIGINT,
    p_fk_tasignatura         BIGINT,
    p_fk_tperiodo_evaluacion BIGINT,
    p_search                 VARCHAR DEFAULT NULL
)
RETURNS TABLE(
    fk_tmatricula                     BIGINT,
    fk_testudiante                    BIGINT,
    estudiante                        VARCHAR,
    documento                         VARCHAR,
    definitiva_guardada               NUMERIC,
    definitiva_proyectada             NUMERIC,
    definitiva_guardada_homologada    NUMERIC,
    definitiva_proyectada_homologada  NUMERIC,
    estado_nota                       VARCHAR,
    es_numerico                       BOOLEAN,
    nota_maxima                       NUMERIC,
    formato_valor                     VARCHAR,
    valoracion_nombre                 VARCHAR,
    aprobada                          BOOLEAN,
    actividades                       JSONB,
    total_count                       BIGINT
)
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
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_planilla_listar(BIGINT, BIGINT, BIGINT, BIGINT, VARCHAR)
    IS 'La planilla de calificacion a la que llevan las dos alertas del modulo de informes: una fila por estudiante del grupo, con su definitiva del periodo -- guardada y proyectada, ambas en porcentaje y ya homologadas -- y las actividades del periodo embebidas en ACTIVIDADES (JSONB), una celda por actividad con su nota, estado y el pkTactividadEstudiante que el popover necesita. NO ES la planilla del planeador (fn_planilla_columnas_listar / fn_planilla_calificaciones_listar, V239), que no se toca: aquella es la del docente calificando dia a dia y difiere en tres cosas de fondo -- acota por ventana de fechas libre y no por periodo de evaluacion; usa fn_planilla_definitiva_proyectada, que NO filtra por periodo, de modo que mostraria una definitiva que no corresponde al cambio que el revisor vino a aprobar; y toma su linea base de TUNIDAD_NOTA, que nadie consolida (su autor lo dejo anotado, calculado para que la flecha funcionara sola cuando la consolidacion existiera), mientras esta la toma de TASIGNATURA_NOTA, que es donde V336 si consolida. Lo unico que reutiliza de V239 es fn_planilla_grupo_asignatura_assert, un validador puro sin gate ni efectos, para que el mismo filtro invalido de el mismo error en las dos pantallas. EL CRITERIO DE FECHA ES EL NUESTRO: las columnas se definen con fn_actividad_en_periodo_eval (fecha de corte) y no con el solapamiento de fn_planilla_actividades_universo, porque no son equivalentes -- una actividad que abre en un periodo y cierra en el siguiente entra en las dos ventanas por solapamiento pero solo suma al segundo en la proyeccion, y seria una columna cuya nota no esta en la definitiva de esa pantalla, sin que nadie pudiera explicar la diferencia. Asi columnas y definitiva salen siempre del mismo conjunto. UN SOLO BUSCADOR para dos dimensiones: filtra estudiantes por nombre/documento y actividades por titulo, pero la dimension donde NADA coincidio se deja INTACTA -- buscar un nombre filtra filas y conserva columnas, buscar una actividad conserva filas y filtra columnas; filtrar ambas siempre vaciaria la tabla al escribir un nombre, porque ninguna actividad se llama como un alumno. Sin paginacion: se muestra el grupo entero, y paginar obligaria ademas a decidir que hacer con las columnas, que no son filas. Las flechas las pinta el front comparando las dos definitivas homologadas; no se manda una columna tendencia porque seria duplicar un dato derivado y calcularla sobre porcentajes daria flecha cuando dos porcentajes distintos redondean a la misma nota. ESTADO_NOTA usa el mismo vocabulario que fn_informe_estudiante_asignaturas (sin_nota / proyectada / guardada / cambio_propuesto) para que el front no aprenda dos juegos de estados para la misma idea. Gate: INFORMES/VER sobre el grupo.';
