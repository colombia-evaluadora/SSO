-- ===========================================================================
-- V490 - informes enganche alcance por grupo
-- Recortada: las funciones de informes que V535-V541 reescriben en capas
-- se quitaron de aqui y viven alli. Queda lo que sigue vivo y lo que una
-- base limpia necesita al migrar (CREATE solo si la funcion no existe).
-- ===========================================================================


-- La vigente es posterior; esta solo hace falta en una base limpia (V513:objeto).
DO $guarda$
BEGIN
    IF to_regprocedure('academico_test.fn_informe_planilla_listar(bigint,bigint,bigint,bigint,varchar)') IS NULL THEN
        EXECUTE $crear$CREATE OR REPLACE FUNCTION academico_test.fn_informe_planilla_listar(p_pk_usuario_solicitante bigint, p_fk_tgrupo bigint, p_fk_tasignatura bigint, p_fk_tperiodo_evaluacion bigint, p_search character varying DEFAULT NULL::character varying)
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
$function$$crear$;
    END IF;
END $guarda$;

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
$function$;

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
    PERFORM academico_test.fn_informe_assert_puede_escribir(p_pk_usuario_solicitante);

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
$function$;

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
    PERFORM academico_test.fn_informe_assert_puede_escribir(p_pk_usuario_solicitante);

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
$function$;

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
$function$;

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
    PERFORM academico_test.fn_informe_assert_puede_escribir(p_pk_usuario_solicitante);

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
$function$;

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
    PERFORM academico_test.fn_informe_assert_puede_escribir(p_pk_usuario_solicitante);

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
$function$;

-- La vigente es posterior; esta solo hace falta en una base limpia (V491.1:objeto).
DO $guarda$
BEGIN
    IF to_regprocedure('academico_test.fn_informe_grupos_listar(bigint,bigint,integer,bigint,varchar)') IS NULL THEN
        EXECUTE $crear$CREATE OR REPLACE FUNCTION academico_test.fn_informe_grupos_listar(p_pk_usuario_solicitante bigint, p_fk_tsede bigint, p_anio integer, p_fk_tlv_jornada bigint, p_search character varying DEFAULT NULL::character varying)
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
$function$$crear$;
    END IF;
END $guarda$;
