-- ===========================================================================
-- V459 — Recuperacion dinamica en la configuracion de actividad. Preescolar
-- (formativo por definicion) apaga evaluacion y recuperacion aunque el
-- referente diga EVALUATIVO. GET /planeador/actividades/configuracion gana
-- ?RECUPERAR=S (lista las sumativas recuperables del grupo+asignatura) y
-- ?ACTIVIDAD_RECUPERAR=<pk> (contexto heredado + estudiantes de la origen).
-- fn_actividad_recuperacion_configurar deja de exigir tipoCalculo con
-- REEMPLAZAR, rechaza ahi valorPonderacion y exige origen sumativa.
-- Depende de: V458 (firmas y helpers), V224 (writer), V408 (combinar),
-- V422 (fila public.query).
-- ===========================================================================
SET search_path TO academico_test, public;

-- ---------------------------------------------------------------------------
-- 1) Bloque recuperacion: nueva firma (DROP + CREATE), listado y origen.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_actividad_recuperacion_campos_disponibles(BOOLEAN, VARCHAR);
DROP FUNCTION IF EXISTS academico_test.fn_actividad_recuperacion_campos_disponibles(BOOLEAN, VARCHAR, BOOLEAN, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT);
CREATE FUNCTION academico_test.fn_actividad_recuperacion_campos_disponibles(
    p_evaluativo              BOOLEAN,
    p_es_sumativo             VARCHAR DEFAULT 'S',
    p_es_preescolar           BOOLEAN DEFAULT FALSE,
    p_recuperar               VARCHAR DEFAULT 'N',
    p_fk_tgrupo               BIGINT  DEFAULT NULL,
    p_fk_tasignatura          BIGINT  DEFAULT NULL,
    p_fk_tactividad_recuperar BIGINT  DEFAULT NULL,
    p_pk_tactividad_actual    BIGINT  DEFAULT NULL,
    p_pk_usuario_solicitante  BIGINT  DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_sum       VARCHAR := UPPER(TRIM(COALESCE(p_es_sumativo, 'S')));
    v_rec       VARCHAR := UPPER(TRIM(COALESCE(p_recuperar, 'N')));
    v_visible   BOOLEAN := COALESCE(p_evaluativo, FALSE) AND v_sum <> 'N'
                           AND NOT COALESCE(p_es_preescolar, FALSE);
    v_lista     JSONB;
    v_origen    JSONB;
    v_o         RECORD;
BEGIN
    -- "¿Que desea recuperar?": solo con la casilla marcada y el contexto
    -- (grupo, asignatura) resuelto. Sumativas, no recuperaciones, activas,
    -- sin otra recuperacion activa apuntandoles.
    IF v_visible AND v_rec = 'S' AND p_fk_tasignatura IS NOT NULL THEN
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
                   'pk',          a.PK_TACTIVIDAD,
                   'titulo',      a.TITULO,
                   'fkTgrupo',    a.FK_TGRUPO,
                   'fkTunidad',   a.FK_TUNIDAD,
                   'unidad',      u.NOMBRE,
                   'fechaInicio', a.FECHA_INICIO,
                   'fechaCierre', a.FECHA_CIERRE,
                   'estudiantesAsignados',
                       (SELECT COUNT(*) FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
                         WHERE ae.FK_TACTIVIDAD = a.PK_TACTIVIDAD AND ae.ACTIVE = TRUE))
                   ORDER BY a.FECHA_INICIO DESC NULLS LAST, a.PK_TACTIVIDAD DESC), '[]'::jsonb)
          INTO v_lista
          FROM academico_test.TACTIVIDAD a
          LEFT JOIN academico_test.TUNIDAD u ON u.PK_TUNIDAD = a.FK_TUNIDAD
         WHERE a.ACTIVE = TRUE
           AND a.FK_TASIGNATURA = p_fk_tasignatura
           AND (p_fk_tgrupo IS NULL
                OR a.FK_TGRUPO = p_fk_tgrupo
                OR (a.FK_TGRUPO IS NULL AND u.FK_TGRADO = (SELECT g.FK_TGRADO FROM academico_test.TGRUPO g
                                                             WHERE g.PK_TGRUPO = p_fk_tgrupo)))
           AND COALESCE(a.ES_EVALUATIVA::VARCHAR, 'S') = 'S'
           AND COALESCE(a.ES_RECUPERACION::VARCHAR, 'N') = 'N'
           AND (p_pk_tactividad_actual IS NULL OR a.PK_TACTIVIDAD <> p_pk_tactividad_actual)
           AND NOT EXISTS (SELECT 1 FROM academico_test.TACTIVIDAD_RECUPERACION r
                            WHERE r.FK_TACTIVIDAD_RECUPERAR = a.PK_TACTIVIDAD
                              AND r.ACTIVE = TRUE
                              AND (p_pk_tactividad_actual IS NULL OR r.FK_TACTIVIDAD <> p_pk_tactividad_actual));
    END IF;

    -- Actividad origen elegida: contexto heredado + estudiantes asignados
    -- (todos marcados; el docente desmarca los que no la necesitan).
    IF p_fk_tactividad_recuperar IS NOT NULL THEN
        SELECT a.PK_TACTIVIDAD, a.TITULO, a.FK_TGRUPO, gr.NOMBRE AS grupo,
               COALESCE(gd.PK_TGRADO, gdu.PK_TGRADO) AS PK_TGRADO,
               COALESCE(gd.NOMBRE, gdu.NOMBRE)       AS grado,
               a.FK_TASIGNATURA, asg.NOMBRE AS asignatura,
               a.FK_TUNIDAD, u.NOMBRE AS unidad,
               COALESCE(a.ES_EVALUATIVA::VARCHAR, 'S')   AS es_sumativa,
               COALESCE(a.ES_RECUPERACION::VARCHAR, 'N') AS es_recuperacion,
               a.ACTIVE
          INTO v_o
          FROM academico_test.TACTIVIDAD a
          LEFT JOIN academico_test.TGRUPO gr       ON gr.PK_TGRUPO = a.FK_TGRUPO
          LEFT JOIN academico_test.TGRADO gd       ON gd.PK_TGRADO = gr.FK_TGRADO
          LEFT JOIN academico_test.TASIGNATURA asg ON asg.PK_TASIGNATURA = a.FK_TASIGNATURA
          LEFT JOIN academico_test.TUNIDAD u       ON u.PK_TUNIDAD = a.FK_TUNIDAD
          LEFT JOIN academico_test.TGRADO gdu      ON gdu.PK_TGRADO = u.FK_TGRADO
         WHERE a.PK_TACTIVIDAD = p_fk_tactividad_recuperar;

        IF v_o.PK_TACTIVIDAD IS NULL OR NOT v_o.ACTIVE THEN
            RAISE EXCEPTION 'No se encontro la actividad a recuperar' USING ERRCODE = 'P0002';
        END IF;
        IF v_o.es_sumativa = 'N' THEN
            RAISE EXCEPTION 'La actividad "%" no es sumativa: no afecta la nota y no se puede recuperar', v_o.TITULO
                USING ERRCODE = '22023';
        END IF;
        IF v_o.es_recuperacion = 'S' THEN
            RAISE EXCEPTION 'La actividad "%" ya es una recuperacion: no se encadenan', v_o.TITULO
                USING ERRCODE = '22023';
        END IF;
        IF p_fk_tasignatura IS NOT NULL AND v_o.FK_TASIGNATURA IS NOT NULL
           AND v_o.FK_TASIGNATURA <> p_fk_tasignatura THEN
            RAISE EXCEPTION 'La actividad "%" es de otra asignatura', v_o.TITULO USING ERRCODE = '22023';
        END IF;
        IF p_pk_usuario_solicitante IS NOT NULL THEN
            PERFORM academico_test.fn_planeador_assert_alcance(
                p_pk_usuario_solicitante, 'VER', NULL, NULL, NULL, p_fk_tactividad_recuperar);
        END IF;

        v_origen := jsonb_build_object(
            'pkActividad',    v_o.PK_TACTIVIDAD,
            'tituloBase',     v_o.TITULO,
            'tituloSugerido', 'Recuperacion - ' || v_o.TITULO,
            'fkTgrado',       v_o.PK_TGRADO,      'grado',      v_o.grado,
            'fkTgrupo',       v_o.FK_TGRUPO,      'grupo',      v_o.grupo,
            'fkTasignatura',  v_o.FK_TASIGNATURA, 'asignatura', v_o.asignatura,
            'fkTunidad',      v_o.FK_TUNIDAD,     'unidad',     v_o.unidad,
            'camposHeredados', jsonb_build_array('FK_TGRUPO', 'FK_TASIGNATURA', 'FK_TUNIDAD'),
            'estudiantes', COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                           'pkTmatricula',           ae.FK_TMATRICULA,
                           'pkTactividadEstudiante', ae.PK_TACTIVIDAD_ESTUDIANTE,
                           'fkTestudiante',          m.FK_TESTUDIANTE,
                           'estudiante',             NULLIF(TRIM(CONCAT_WS(' ', us.PRIMER_NOMBRE, us.SEGUNDO_NOMBRE,
                                                                                us.PRIMER_APELLIDO, us.SEGUNDO_APELLIDO)), ''),
                           'notaPrevia',             COALESCE(n.DEFINITIVA, n.CALIFICACION),
                           'seleccionado',           TRUE)
                           ORDER BY us.PRIMER_APELLIDO, us.PRIMER_NOMBRE, ae.PK_TACTIVIDAD_ESTUDIANTE)
                  FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
                  JOIN academico_test.TMATRICULA m   ON m.PK_TMATRICULA = ae.FK_TMATRICULA
                  JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
                  JOIN academico_test.TUSUARIO us    ON us.PK_TUSUARIO = es.FK_TUSUARIO
                  LEFT JOIN academico_test.TACTIVIDAD_NOTA n
                         ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE AND n.ACTIVE = TRUE
                 WHERE ae.FK_TACTIVIDAD = v_o.PK_TACTIVIDAD AND ae.ACTIVE = TRUE), '[]'::jsonb));
    END IF;

    RETURN jsonb_build_object(
        'visible',   v_visible,
        'requerido', FALSE,
        'motivo', CASE
            WHEN COALESCE(p_es_preescolar, FALSE)
                THEN 'El nivel Preescolar se rige por un referente formativo: no hay nota que recuperar'
            WHEN v_sum = 'N' THEN 'La actividad se creara como NO sumativa; una actividad de recuperacion debe ser sumativa'
            WHEN NOT COALESCE(p_evaluativo, FALSE) THEN 'El referente curricular no es EVALUATIVO: no hay nota que recuperar'
            ELSE 'Opcional: la actividad puede registrarse como recuperacion de otra actividad o de la nota final'
        END,
        'recuperarConsultado', v_rec,
        'catalogos', (
            SELECT jsonb_object_agg(k, v)
              FROM (SELECT CASE lv.CATEGORIA
                               WHEN 'DESTINO_RECUPERACION'         THEN 'destino'
                               WHEN 'TIPO_APLICACION_RECUPERACION' THEN 'tipoAplicacion'
                               ELSE 'tipoCalculo' END AS k,
                           jsonb_agg(jsonb_build_object(
                               'pk', lv.PK_LISTA_VALOR, 'valor', lv.VALOR, 'nombre', lv.NOMBRE)
                               ORDER BY lv.VALOR) AS v
                      FROM academico_test.TLISTA_VALOR lv
                     WHERE lv.CATEGORIA IN ('DESTINO_RECUPERACION',
                                            'TIPO_APLICACION_RECUPERACION',
                                            'TIPO_CALCULO_RECUPERACION')
                       AND lv.ACTIVE = TRUE
                     GROUP BY lv.CATEGORIA) c),
        'reglas', jsonb_build_object(
            'actividadRecuperarRequeridaSi', 'destino = ACTIVIDAD',
            'actividadRecuperableSi',        'ES_EVALUATIVA = S y ES_RECUPERACION = N y sin otra recuperacion activa',
            'tipoCalculoRequeridoSi',        'tipoAplicacion = COMPUTAR',
            'tipoCalculoOcultoSi',           'tipoAplicacion = REEMPLAZAR',
            'valorPonderacionRequeridoSi',   'tipoAplicacion = COMPUTAR y tipoCalculo = PONDERADO',
            'valorPonderacionRango',         jsonb_build_object('min', 0, 'max', 100),
            'estudiantesPorDefecto',         'los asignados a la actividad origen; se envian en FK_TMATRICULAS los que quedan marcados'),
        'actividadesRecuperables', v_lista,
        'origen', v_origen);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_recuperacion_campos_disponibles(BOOLEAN, VARCHAR, BOOLEAN, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT)
    IS 'La seccion "Es una recuperacion" del formulario de actividad, punto unico de las tres configuraciones: {visible, requerido, motivo, recuperarConsultado, catalogos:{destino, tipoAplicacion, tipoCalculo}, reglas, actividadesRecuperables, origen}. visible exige referente EVALUATIVO, ES_SUMATIVO distinto de N y nivel distinto de Preescolar (formativo por definicion). actividadesRecuperables (solo con p_recuperar = S y asignatura resuelta; NULL en otro caso): las actividades sumativas (ES_EVALUATIVA = S), que no son recuperacion, activas y sin otra recuperacion activa apuntandoles, del (grupo, asignatura) del contexto -- lo que lista "Que desea recuperar". origen (solo con p_fk_tactividad_recuperar; NULL en otro caso): el contexto que el formulario hereda e inhabilita (grado, grupo, asignatura, unidad, tituloBase) y los estudiantes asignados a esa actividad con su notaPrevia, todos seleccionado = true para que el docente desmarque; valida que la origen exista, sea sumativa, no sea recuperacion y sea de la misma asignatura (P0002 / 22023). reglas expone lo que fn_actividad_recuperacion_configurar hace cumplir: REEMPLAZAR oculta tipoCalculo, COMPUTAR lo exige y PONDERADO exige valorPonderacion. Catalogos como {pk, valor, nombre}: el front decide por VALOR.';

-- ---------------------------------------------------------------------------
-- 2) Las tres configuraciones: gate Preescolar y nuevos parametros.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_campos_disponibles(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT
) RETURNS JSONB
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_titulo            VARCHAR;
    v_fk_tunidad        BIGINT;
    v_nombre_nivel      VARCHAR;
    v_es_preescolar     BOOLEAN;
    v_evaluacion_req    BOOLEAN;
    v_instrumentos      JSONB;
    v_es_sumativo       VARCHAR(1);
    v_es_recuperacion   VARCHAR(1);
    v_fk_tgrupo         BIGINT;
    v_fk_tasignatura    BIGINT;
    v_fk_recuperar      BIGINT;
    v_modo_calculo      VARCHAR;
    v_tipo              VARCHAR;
BEGIN
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', NULL, NULL, NULL, p_pk_tactividad
    );

    -- TACTIVIDAD.ES_EVALUATIVA es la columna que persiste "sumativa" (S/N).
    SELECT a.TITULO, a.FK_TUNIDAD, UPPER(TRIM(COALESCE(a.ES_EVALUATIVA::VARCHAR, 'S'))),
           UPPER(TRIM(COALESCE(a.ES_RECUPERACION::VARCHAR, 'N'))), a.FK_TGRUPO, a.FK_TASIGNATURA,
           (SELECT r.FK_TACTIVIDAD_RECUPERAR FROM academico_test.TACTIVIDAD_RECUPERACION r
             WHERE r.FK_TACTIVIDAD = a.PK_TACTIVIDAD AND r.ACTIVE = TRUE)
      INTO v_titulo, v_fk_tunidad, v_es_sumativo,
           v_es_recuperacion, v_fk_tgrupo, v_fk_tasignatura, v_fk_recuperar
      FROM academico_test.TACTIVIDAD a
     WHERE a.PK_TACTIVIDAD = p_pk_tactividad;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la actividad solicitada' USING ERRCODE = 'P0002';
    END IF;

    IF v_fk_tunidad IS NOT NULL THEN
        SELECT ne.NOMBRE
          INTO v_nombre_nivel
          FROM academico_test.TUNIDAD u
          JOIN academico_test.TGRADO g ON g.PK_TGRADO = u.FK_TGRADO
          JOIN academico_test.TNIVEL_ENSENANZA ne ON ne.PK_NIVEL_ENSENANZA = g.FK_TNIVEL_ENSENANZA
         WHERE u.PK_TUNIDAD = v_fk_tunidad;

        v_modo_calculo := academico_test.fn_unidad_calculo_definitiva_modo(v_fk_tunidad);
    END IF;

    v_es_preescolar := COALESCE(v_nombre_nivel ILIKE 'preescolar%', FALSE);

    v_evaluacion_req := academico_test.fn_actividad_evaluacion_requerida(p_pk_tactividad);

    v_tipo := academico_test.fn_actividad_referente_tipo_evaluacion(p_pk_tactividad);

    -- Preescolar es formativo por definicion: sin evaluacion con nota.
    v_evaluacion_req := COALESCE(v_evaluacion_req, FALSE) AND NOT v_es_preescolar;

    v_instrumentos := CASE
        WHEN NOT v_evaluacion_req THEN '[]'::jsonb
        ELSE academico_test.fn_actividad_instrumentos_campos_disponibles(v_tipo)
    END;

    RETURN jsonb_build_object(
        'criterio', academico_test.fn_actividad_criterio_campos_disponibles(
                        v_es_preescolar, v_fk_tunidad IS NOT NULL),
        'evaluacion', jsonb_build_object(
            'visible',  v_evaluacion_req,
            'requerido', v_evaluacion_req,
            'motivo', CASE
                WHEN v_es_preescolar THEN 'El nivel Preescolar se rige por un referente formativo: no hay evaluacion con nota ni recuperacion'
                WHEN v_fk_tunidad IS NULL THEN 'La actividad no tiene unidad relacionada'
                WHEN v_evaluacion_req THEN 'El referente curricular de la unidad de la actividad es EVALUATIVO'
                ELSE 'El referente curricular de la unidad no es EVALUATIVO (o la unidad no tiene referente)'
            END,
            'tipoEvaluacion', v_tipo,
            'instrumentosPermitidos', v_instrumentos
        ),
        'ponderacion', academico_test.fn_actividad_ponderacion_campos_disponibles(
                           v_es_sumativo, v_fk_tunidad IS NOT NULL, v_modo_calculo),
        'recuperacion', academico_test.fn_actividad_recuperacion_campos_disponibles(
                            v_evaluacion_req, v_es_sumativo, v_es_preescolar,
                            v_es_recuperacion, v_fk_tgrupo, v_fk_tasignatura,
                            v_fk_recuperar, p_pk_tactividad, NULL)
    );
END;
$$;

DROP FUNCTION IF EXISTS academico_test.fn_unidad_configuracion_actividad(BIGINT, BIGINT, VARCHAR);
CREATE FUNCTION academico_test.fn_unidad_configuracion_actividad(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tunidad             BIGINT,
    p_es_sumativo            VARCHAR DEFAULT 'S'
) RETURNS JSONB
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_nombre_unidad   VARCHAR;
    v_nivel_nombre    VARCHAR;
    v_es_sumativo     VARCHAR := UPPER(TRIM(COALESCE(p_es_sumativo, 'S')));
    v_evaluativo      BOOLEAN;
    v_tipo            VARCHAR;
    v_modo            VARCHAR;
    v_es_preescolar   BOOLEAN;
    v_instrumentos    JSONB;
BEGIN
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', NULL, NULL, p_pk_tunidad
    );

    SELECT u.NOMBRE, ne.NOMBRE
      INTO v_nombre_unidad, v_nivel_nombre
      FROM academico_test.TUNIDAD u
      JOIN academico_test.TGRADO g            ON g.PK_TGRADO = u.FK_TGRADO
      LEFT JOIN academico_test.TNIVEL_ENSENANZA ne
             ON ne.PK_NIVEL_ENSENANZA = g.FK_TNIVEL_ENSENANZA
     WHERE u.PK_TUNIDAD = p_pk_tunidad
       AND u.ACTIVE = TRUE;

    IF v_nombre_unidad IS NULL THEN
        RAISE EXCEPTION 'No se encontro la unidad solicitada' USING ERRCODE = 'P0002';
    END IF;

    v_es_preescolar := COALESCE(v_nivel_nombre ILIKE 'preescolar%', FALSE);

    v_evaluativo := academico_test.fn_unidad_referente_evaluativo(p_pk_tunidad);
    v_tipo       := academico_test.fn_unidad_referente_tipo_evaluacion(p_pk_tunidad);
    v_modo       := academico_test.fn_unidad_calculo_definitiva_modo(p_pk_tunidad);

    -- Preescolar es formativo por definicion: sin evaluacion con nota.
    v_evaluativo := COALESCE(v_evaluativo, FALSE) AND NOT v_es_preescolar;

    v_instrumentos := CASE
        WHEN NOT v_evaluativo THEN '[]'::jsonb
        ELSE academico_test.fn_actividad_instrumentos_campos_disponibles(v_tipo)
    END;

    RETURN jsonb_build_object(
        'pkTunidad', p_pk_tunidad,
        'unidad',    v_nombre_unidad,
        'nivelEnsenanza', v_nivel_nombre,
        'esSumativoConsultado', v_es_sumativo,
        'campos_disponibles', jsonb_build_object(
            'criterio', academico_test.fn_actividad_criterio_campos_disponibles(
                            v_es_preescolar, TRUE),
            'evaluacion', jsonb_build_object(
                'visible',   COALESCE(v_evaluativo, FALSE),
                'requerido', COALESCE(v_evaluativo, FALSE),
                'motivo',    CASE
                    WHEN v_es_preescolar THEN 'El nivel Preescolar se rige por un referente formativo: no hay evaluacion con nota ni recuperacion'
                    WHEN NOT COALESCE(v_evaluativo, FALSE)
                        THEN 'El referente curricular de la unidad no es EVALUATIVO (o la unidad no tiene referente)'
                    ELSE 'El referente curricular de la unidad es EVALUATIVO: la actividad requiere instrumento de evaluacion'
                END,
                'tipoEvaluacion', v_tipo,
                'instrumentosPermitidos', v_instrumentos),
            'ponderacion', academico_test.fn_actividad_ponderacion_campos_disponibles(
                               v_es_sumativo, TRUE, v_modo),
            'recuperacion', academico_test.fn_actividad_recuperacion_campos_disponibles(
                                v_evaluativo, v_es_sumativo, v_es_preescolar))
    );
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_configuracion_actividad(BIGINT, BIGINT, VARCHAR)
    IS 'Que pintar en el formulario de NUEVA ACTIVIDAD para la unidad escogida, antes de crearla: {pkTunidad, unidad, nivelEnsenanza, esSumativoConsultado, campos_disponibles:{criterio, evaluacion, ponderacion, recuperacion}}. p_es_sumativo (S|N, default S) es lo que el usuario acaba de marcar: con N solo se apagan recuperacion y ponderacion; la evaluacion (instrumentosPermitidos, con `campos` en OTRO) sale del referente de la unidad igual que con S. Gate VER sobre PLANEADOR + alcance por la unidad; P0002 si no existe o esta inactiva.';

DROP FUNCTION IF EXISTS academico_test.fn_actividad_configuracion_contexto(BIGINT, BIGINT, BIGINT, BIGINT, VARCHAR);
DROP FUNCTION IF EXISTS academico_test.fn_actividad_configuracion_contexto(BIGINT, BIGINT, BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT);
CREATE FUNCTION academico_test.fn_actividad_configuracion_contexto(
    p_pk_usuario_solicitante  BIGINT,
    p_fk_tgrupo               BIGINT,
    p_fk_tasignatura          BIGINT,
    p_fk_tunidad              BIGINT  DEFAULT NULL,
    p_es_sumativo             VARCHAR DEFAULT 'S',
    p_recuperar               VARCHAR DEFAULT 'N',
    p_fk_tactividad_recuperar BIGINT  DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_es_sumativo   VARCHAR := UPPER(TRIM(COALESCE(p_es_sumativo, 'S')));
    v_fk_tgrado     BIGINT;
    v_grado         VARCHAR;
    v_grupo         VARCHAR;
    v_nivel         VARCHAR;
    v_asignatura    VARCHAR;
    v_es_preescolar BOOLEAN;
    v_pk_referente  BIGINT;
    v_ref_nombre    VARCHAR;
    v_evaluativo    BOOLEAN := FALSE;
    v_tipo          VARCHAR;
    v_modo          VARCHAR;
    v_instrumentos  JSONB;
    v_pk_periodo    BIGINT;
    v_periodo       VARCHAR;
    v_pa_desde      DATE;
    v_pa_hasta      DATE;
    v_semanas       INT;
    v_bloques       INT;
    v_dias          INT[];
    v_dias_nombre   JSONB;
    v_fecha_min     DATE;
    v_fecha_max     DATE;
    v_duracion_max  NUMERIC;
    v_programacion  JSONB;
BEGIN
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', p_fk_tgrupo, NULL, p_fk_tunidad
    );

    SELECT gr.NOMBRE, gr.FK_TGRADO, gd.NOMBRE, ne.NOMBRE
      INTO v_grupo, v_fk_tgrado, v_grado, v_nivel
      FROM academico_test.TGRUPO gr
      LEFT JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
      LEFT JOIN academico_test.TNIVEL_ENSENANZA ne
             ON ne.PK_NIVEL_ENSENANZA = gd.FK_TNIVEL_ENSENANZA
     WHERE gr.PK_TGRUPO = p_fk_tgrupo
       AND gr.ACTIVE = TRUE;

    IF v_grupo IS NULL THEN
        RAISE EXCEPTION 'No se encontro el grupo solicitado' USING ERRCODE = 'P0002';
    END IF;

    SELECT a.NOMBRE INTO v_asignatura
      FROM academico_test.TASIGNATURA a
     WHERE a.PK_TASIGNATURA = p_fk_tasignatura
       AND a.ACTIVE = TRUE;

    IF v_asignatura IS NULL THEN
        RAISE EXCEPTION 'No se encontro la asignatura solicitada' USING ERRCODE = 'P0002';
    END IF;

    IF p_fk_tunidad IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM academico_test.TUNIDAD
                        WHERE PK_TUNIDAD = p_fk_tunidad AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'No se encontro la unidad solicitada' USING ERRCODE = 'P0002';
    END IF;

    v_es_preescolar := COALESCE(v_nivel ILIKE 'preescolar%', FALSE);

    -- Con unidad manda la unidad (ya eligio referente y metodo de calculo);
    -- sin unidad, el referente se deriva del grado + asignatura.
    IF p_fk_tunidad IS NOT NULL THEN
        v_evaluativo := academico_test.fn_unidad_referente_evaluativo(p_fk_tunidad);
        v_tipo       := academico_test.fn_unidad_referente_tipo_evaluacion(p_fk_tunidad);
        v_modo       := academico_test.fn_unidad_calculo_definitiva_modo(p_fk_tunidad);

        SELECT u.FK_REFERENTE_CURRICULAR INTO v_pk_referente
          FROM academico_test.TUNIDAD u WHERE u.PK_TUNIDAD = p_fk_tunidad;
    ELSE
        v_pk_referente := academico_test.fn_unidad_referente_aplicable(
                              v_fk_tgrado, p_fk_tasignatura, NULL);

        SELECT (enf.VALOR = 'EVALUATIVO'), tev.VALOR
          INTO v_evaluativo, v_tipo
          FROM academico_test.TREFERENTE_CURRICULAR rc
          LEFT JOIN academico_test.TLISTA_VALOR enf ON enf.PK_LISTA_VALOR = rc.FK_TLV_ENFOQUE_PEDAGOGICO
          LEFT JOIN academico_test.TLISTA_VALOR tev ON tev.PK_LISTA_VALOR = rc.FK_TLV_TIPO_EVALUACION
         WHERE rc.PK_REFERENTE_CURRICULAR = v_pk_referente;
    END IF;

    SELECT rc.NOMBRE INTO v_ref_nombre
      FROM academico_test.TREFERENTE_CURRICULAR rc
     WHERE rc.PK_REFERENTE_CURRICULAR = v_pk_referente;

    -- Preescolar es formativo por definicion: sin evaluacion con nota.
    v_evaluativo := COALESCE(v_evaluativo, FALSE) AND NOT v_es_preescolar;

    v_instrumentos := CASE
        WHEN NOT v_evaluativo THEN '[]'::jsonb
        ELSE academico_test.fn_actividad_instrumentos_campos_disponibles(v_tipo)
    END;

    -- Limites de la seccion "Programacion": un solo calculo, compartido con la
    -- validacion de escritura (fn_actividad_programacion_assert).
    SELECT l.fk_tperiodo_academico, l.periodo_academico, l.periodo_desde, l.periodo_hasta,
           l.semanas, l.bloques_por_semana, l.dias_habiles, l.dias_habiles_nombre,
           l.fecha_min, l.fecha_max, l.duracion_max
      INTO v_pk_periodo, v_periodo, v_pa_desde, v_pa_hasta,
           v_semanas, v_bloques, v_dias, v_dias_nombre,
           v_fecha_min, v_fecha_max, v_duracion_max
      FROM academico_test.fn_actividad_programacion_limites(p_fk_tgrupo, p_fk_tasignatura) l;

    v_programacion := jsonb_build_object(
        'periodoAcademico', CASE WHEN v_pk_periodo IS NULL THEN NULL
            ELSE jsonb_build_object('pk', v_pk_periodo, 'nombre', v_periodo,
                                    'fechaInicio', v_pa_desde, 'fechaFin', v_pa_hasta,
                                    'semanas', v_semanas) END,
        'intensidadHoraria', jsonb_build_object(
            'bloquesPorSemana', v_bloques,
            'diasHabiles',      v_dias_nombre,
            'motivo', CASE WHEN COALESCE(v_bloques, 0) = 0
                THEN 'El grupo no tiene horario configurado para esta asignatura'
                ELSE 'Bloques activos de THORARIO para este grupo y asignatura' END),
        'fechaInicio', jsonb_build_object(
            'min', v_fecha_min, 'max', v_fecha_max,
            'diasHabiles', v_dias,
            'motivo', CASE
                WHEN v_pa_desde IS NULL THEN 'El grado no tiene periodo academico asociado; no hay ventana que aplicar'
                WHEN COALESCE(array_length(v_dias, 1), 0) = 0 THEN 'Sin horario configurado: solo aplica la ventana del periodo academico'
                ELSE 'Dentro del periodo academico y en un dia en que se dicta la asignatura' END),
        'fechaCierre', jsonb_build_object(
            'min', v_fecha_min, 'max', v_fecha_max,
            'diasHabiles', v_dias,
            'motivo', 'No puede ser anterior a la fecha de inicio ni exceder el periodo academico'),
        'semanaCronograma', jsonb_build_object(
            'min', CASE WHEN v_semanas IS NULL THEN NULL ELSE 1 END,
            'max', v_semanas,
            'motivo', CASE WHEN v_semanas IS NULL
                THEN 'El grado no tiene periodo academico asociado; no se puede acotar'
                ELSE 'Semanas que dura el periodo academico' END),
        'duracionEstimada', jsonb_build_object(
            'min', CASE WHEN v_duracion_max IS NULL THEN NULL ELSE 1 END,
            'max', v_duracion_max,
            'unidad', 'BLOQUES',
            'motivo', CASE WHEN v_duracion_max IS NULL
                THEN 'Falta el periodo academico o el horario de la asignatura; no hay tope que calcular'
                ELSE 'Semanas del periodo academico por los bloques semanales de la asignatura' END));

    RETURN jsonb_build_object(
        'programacion',   v_programacion,
        'fkTgrupo',       p_fk_tgrupo,
        'grupo',          v_grupo,
        'fkTgrado',       v_fk_tgrado,
        'grado',          v_grado,
        'nivelEnsenanza', v_nivel,
        'fkTasignatura',  p_fk_tasignatura,
        'asignatura',     v_asignatura,
        'pkTunidad',      p_fk_tunidad,
        'origenConfiguracion', CASE WHEN p_fk_tunidad IS NULL THEN 'CONTEXTO' ELSE 'UNIDAD' END,
        'referente', CASE WHEN v_pk_referente IS NULL THEN NULL
                          ELSE jsonb_build_object('pk', v_pk_referente, 'nombre', v_ref_nombre) END,
        'esSumativoConsultado', v_es_sumativo,
        'campos_disponibles', jsonb_build_object(
            'criterio', academico_test.fn_actividad_criterio_campos_disponibles(
                            v_es_preescolar, p_fk_tunidad IS NOT NULL),
            'evaluacion', jsonb_build_object(
                'visible',   COALESCE(v_evaluativo, FALSE),
                'requerido', COALESCE(v_evaluativo, FALSE),
                'motivo',    CASE
                    WHEN v_es_preescolar THEN 'El nivel Preescolar se rige por un referente formativo: no hay evaluacion con nota ni recuperacion'
                    WHEN NOT COALESCE(v_evaluativo, FALSE) AND p_fk_tunidad IS NOT NULL
                        THEN 'El referente curricular de la unidad no es EVALUATIVO (o la unidad no tiene referente)'
                    WHEN NOT COALESCE(v_evaluativo, FALSE)
                        THEN 'El referente curricular que aplica no es EVALUATIVO (o no hay referente para ese grado y asignatura)'
                    WHEN p_fk_tunidad IS NOT NULL
                        THEN 'El referente curricular de la unidad es EVALUATIVO: la actividad requiere instrumento de evaluacion'
                    ELSE 'El referente curricular que aplica es EVALUATIVO: la actividad requiere instrumento de evaluacion'
                END,
                'tipoEvaluacion', v_tipo,
                'instrumentosPermitidos', v_instrumentos),
            'ponderacion', academico_test.fn_actividad_ponderacion_campos_disponibles(
                               v_es_sumativo, p_fk_tunidad IS NOT NULL, v_modo),
            'recuperacion', academico_test.fn_actividad_recuperacion_campos_disponibles(
                                v_evaluativo, v_es_sumativo, v_es_preescolar,
                                p_recuperar, p_fk_tgrupo, p_fk_tasignatura,
                                p_fk_tactividad_recuperar, NULL, p_pk_usuario_solicitante))
    );
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_configuracion_contexto(BIGINT, BIGINT, BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT)
    IS 'Que pintar en el formulario de actividad a partir de grupo + asignatura, con unidad OPCIONAL (con unidad manda la unidad; sin ella el referente se deriva con fn_unidad_referente_aplicable). Devuelve el contexto resuelto, programacion (limites de fechas, semanas y duracion) y campos_disponibles con la misma forma que las otras dos configuraciones. p_es_sumativo (S|N, default S) es lo que el usuario acaba de marcar: con N solo se apagan recuperacion y ponderacion; la evaluacion (instrumentosPermitidos, con `campos` en OTRO) sale del referente igual que con S. p_recuperar (S|N, default N) es la casilla "es una recuperacion": con S, recuperacion.actividadesRecuperables lista las sumativas del (grupo, asignatura) que se pueden recuperar; p_fk_tactividad_recuperar es la elegida en "Que desea recuperar" y devuelve recuperacion.origen con el contexto heredado y sus estudiantes. En nivel Preescolar la evaluacion y la recuperacion vienen apagadas: es formativo por definicion. Gate VER sobre PLANEADOR + alcance por el grupo; P0002 si el grupo, la asignatura o la unidad no existen.';

-- ---------------------------------------------------------------------------
-- 3) Escritura: REEMPLAZAR no pide tipoCalculo (columna NOT NULL: se guarda
--    PROMEDIADO, fn_recuperacion_combinar lo ignora), COMPUTAR lo exige,
--    la origen debe ser sumativa. Misma firma que V224: CREATE OR REPLACE.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_recuperacion_configurar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad            BIGINT,
    p_config                   JSONB
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_act_active    BOOLEAN;
    v_destino_val   VARCHAR;
    v_aplic_val     VARCHAR;
    v_calculo_val   VARCHAR;
    v_pk_calculo    BIGINT;
    v_fk_recuperar  BIGINT;
    v_valor_pond    NUMERIC(5,2);
    v_pk            BIGINT;
    v_titulo_orig   VARCHAR;
BEGIN
    SELECT ACTIVE INTO v_act_active
      FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_pk_tactividad;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la actividad solicitada' USING ERRCODE = 'P0002';
    END IF;

    IF p_config IS NULL THEN
        PERFORM academico_test.fn_actividad_recuperacion_revertir(p_pk_usuario_solicitante, p_pk_tactividad);
        UPDATE academico_test.TACTIVIDAD_RECUPERACION
           SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE;
        UPDATE academico_test.TACTIVIDAD
           SET ES_RECUPERACION = 'N', MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TACTIVIDAD = p_pk_tactividad AND ES_RECUPERACION <> 'N';
        RETURN NULL;
    END IF;

    IF jsonb_typeof(p_config) <> 'object' THEN
        RAISE EXCEPTION 'p_config (recuperacion) debe ser un objeto JSON' USING ERRCODE = '22023';
    END IF;

    IF (p_config->>'destino') IS NULL OR (p_config->>'tipoAplicacion') IS NULL THEN
        RAISE EXCEPTION 'La recuperacion requiere destino y tipoAplicacion' USING ERRCODE = '22023';
    END IF;
    PERFORM academico_test.fn_actividad_lv_assert((p_config->>'destino')::BIGINT,        'DESTINO_RECUPERACION',         'destino');
    PERFORM academico_test.fn_actividad_lv_assert((p_config->>'tipoAplicacion')::BIGINT, 'TIPO_APLICACION_RECUPERACION', 'tipoAplicacion');

    SELECT VALOR INTO v_destino_val FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = (p_config->>'destino')::BIGINT;
    SELECT VALOR INTO v_aplic_val   FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = (p_config->>'tipoAplicacion')::BIGINT;

    -- ¿Como se aplicara la nota?
    v_pk_calculo := NULLIF(p_config->>'tipoCalculo', '')::BIGINT;
    v_valor_pond := NULLIF(p_config->>'valorPonderacion', '')::NUMERIC;
    IF v_aplic_val = 'REEMPLAZAR' THEN
        IF v_valor_pond IS NOT NULL THEN
            RAISE EXCEPTION 'Con tipoAplicacion = REEMPLAZAR la nota nueva sustituye a la anterior: no aplica valorPonderacion'
                USING ERRCODE = '22023';
        END IF;
        IF v_pk_calculo IS NULL THEN
            SELECT PK_LISTA_VALOR INTO v_pk_calculo
              FROM academico_test.TLISTA_VALOR
             WHERE CATEGORIA = 'TIPO_CALCULO_RECUPERACION' AND VALOR = 'PROMEDIADO' AND ACTIVE = TRUE
             LIMIT 1;
        END IF;
        v_calculo_val := NULL;
    ELSE
        IF v_pk_calculo IS NULL THEN
            RAISE EXCEPTION 'Con tipoAplicacion = COMPUTAR hay que indicar tipoCalculo (PROMEDIADO o PONDERADO)'
                USING ERRCODE = '22023';
        END IF;
        SELECT VALOR INTO v_calculo_val FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = v_pk_calculo;
        IF v_calculo_val = 'PONDERADO' THEN
            IF v_valor_pond IS NULL OR v_valor_pond < 0 OR v_valor_pond > 100 THEN
                RAISE EXCEPTION 'tipoCalculo = PONDERADO exige valorPonderacion entre 0 y 100' USING ERRCODE = '22023';
            END IF;
        ELSIF v_valor_pond IS NOT NULL THEN
            RAISE EXCEPTION 'valorPonderacion solo aplica con tipoCalculo = PONDERADO' USING ERRCODE = '22023';
        END IF;
    END IF;
    PERFORM academico_test.fn_actividad_lv_assert(v_pk_calculo, 'TIPO_CALCULO_RECUPERACION', 'tipoCalculo');

    -- Destino: ACTIVIDAD exige la actividad origen; NOTA_FINAL la prohibe.
    v_fk_recuperar := (p_config->>'fkActividadRecuperar')::BIGINT;
    IF v_destino_val = 'ACTIVIDAD' THEN
        IF v_fk_recuperar IS NULL THEN
            RAISE EXCEPTION 'destino = ACTIVIDAD exige fkActividadRecuperar' USING ERRCODE = '22023';
        END IF;
        IF v_fk_recuperar = p_pk_tactividad THEN
            RAISE EXCEPTION 'Una actividad no puede recuperarse a si misma' USING ERRCODE = '22023';
        END IF;
        SELECT TITULO INTO v_titulo_orig FROM academico_test.TACTIVIDAD
         WHERE PK_TACTIVIDAD = v_fk_recuperar AND ACTIVE = TRUE;
        IF v_titulo_orig IS NULL THEN
            RAISE EXCEPTION 'fkActividadRecuperar (%) no existe o no esta activa', v_fk_recuperar USING ERRCODE = '23503';
        END IF;
        IF EXISTS (SELECT 1 FROM academico_test.TACTIVIDAD
                    WHERE PK_TACTIVIDAD = v_fk_recuperar AND COALESCE(ES_EVALUATIVA::VARCHAR, 'S') = 'N') THEN
            RAISE EXCEPTION 'La actividad "%" no es sumativa: no afecta la nota y no se puede recuperar', v_titulo_orig
                USING ERRCODE = '22023';
        END IF;
        IF EXISTS (SELECT 1 FROM academico_test.TACTIVIDAD
                    WHERE PK_TACTIVIDAD = v_fk_recuperar AND ES_RECUPERACION = 'S') THEN
            RAISE EXCEPTION 'La actividad "%" ya es una recuperacion: no se encadenan', v_titulo_orig USING ERRCODE = '22023';
        END IF;
        IF EXISTS (SELECT 1
                     FROM academico_test.TACTIVIDAD orig, academico_test.TACTIVIDAD rec
                    WHERE orig.PK_TACTIVIDAD = v_fk_recuperar
                      AND rec.PK_TACTIVIDAD  = p_pk_tactividad
                      AND orig.FK_TASIGNATURA IS NOT NULL
                      AND rec.FK_TASIGNATURA  IS NOT NULL
                      AND orig.FK_TASIGNATURA <> rec.FK_TASIGNATURA) THEN
            RAISE EXCEPTION 'La recuperacion y la actividad que recupera deben ser de la misma asignatura' USING ERRCODE = '22023';
        END IF;
        IF EXISTS (SELECT 1 FROM academico_test.TACTIVIDAD_RECUPERACION
                    WHERE FK_TACTIVIDAD_RECUPERAR = v_fk_recuperar
                      AND FK_TACTIVIDAD <> p_pk_tactividad
                      AND ACTIVE = TRUE) THEN
            RAISE EXCEPTION 'La actividad "%" ya tiene otra recuperacion activa', v_titulo_orig USING ERRCODE = '23505';
        END IF;
    ELSE
        IF v_fk_recuperar IS NOT NULL THEN
            RAISE EXCEPTION 'destino = NOTA_FINAL no admite fkActividadRecuperar' USING ERRCODE = '22023';
        END IF;
    END IF;

    UPDATE academico_test.TACTIVIDAD
       SET ES_RECUPERACION = 'S', MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TACTIVIDAD = p_pk_tactividad AND ES_RECUPERACION <> 'S';

    SELECT PK_TACTIVIDAD_RECUPERACION INTO v_pk
      FROM academico_test.TACTIVIDAD_RECUPERACION
     WHERE FK_TACTIVIDAD = p_pk_tactividad;

    IF v_pk IS NULL THEN
        INSERT INTO academico_test.TACTIVIDAD_RECUPERACION (
            FK_TACTIVIDAD, FK_TLV_DESTINO_RECUPERACION, FK_TACTIVIDAD_RECUPERAR,
            FK_TLV_TIPO_APLICACION_RECUPERACION, FK_TLV_TIPO_CALCULO_RECUPERACION,
            VALOR_PONDERACION_RECUPERACION, CREATED_BY, CREATED_AT, ACTIVE
        ) VALUES (
            p_pk_tactividad, (p_config->>'destino')::BIGINT, v_fk_recuperar,
            (p_config->>'tipoAplicacion')::BIGINT, v_pk_calculo,
            v_valor_pond, p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
        )
        RETURNING PK_TACTIVIDAD_RECUPERACION INTO v_pk;
    ELSE
        UPDATE academico_test.TACTIVIDAD_RECUPERACION
           SET FK_TLV_DESTINO_RECUPERACION           = (p_config->>'destino')::BIGINT,
               FK_TACTIVIDAD_RECUPERAR               = v_fk_recuperar,
               FK_TLV_TIPO_APLICACION_RECUPERACION   = (p_config->>'tipoAplicacion')::BIGINT,
               FK_TLV_TIPO_CALCULO_RECUPERACION      = v_pk_calculo,
               VALOR_PONDERACION_RECUPERACION        = v_valor_pond,
               ACTIVE                                = TRUE,
               MODIFIED_BY                           = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT                           = CURRENT_TIMESTAMP
         WHERE PK_TACTIVIDAD_RECUPERACION = v_pk;
    END IF;

    RETURN v_pk;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_recuperacion_configurar(BIGINT, BIGINT, JSONB)
    IS 'Punto unico para la config 1:1 de recuperacion (TACTIVIDAD_RECUPERACION). p_config NULL = la actividad NO es de recuperacion (desactiva la fila, revierte lo consolidado y pone ES_RECUPERACION = N). Con objeto {destino, fkActividadRecuperar?, tipoAplicacion, tipoCalculo?, valorPonderacion?}: destino y tipoAplicacion son obligatorios. tipoAplicacion = REEMPLAZAR: la nota nueva sustituye a la anterior, tipoCalculo se ignora (si no viene se guarda PROMEDIADO porque la columna es NOT NULL y fn_recuperacion_combinar no lo mira) y valorPonderacion se rechaza. tipoAplicacion = COMPUTAR: tipoCalculo obligatorio (PROMEDIADO o PONDERADO) y valorPonderacion 0..100 obligatorio sii PONDERADO. destino = ACTIVIDAD exige fkActividadRecuperar distinta de la propia, activa, SUMATIVA (ES_EVALUATIVA = S: una formativa no afecta la nota y no hay nada que recuperar), que no sea a su vez recuperacion, de la misma asignatura y sin otra recuperacion activa apuntandole; destino = NOTA_FINAL la prohibe. Marca ES_RECUPERACION = S y hace upsert de la fila. Llamada por fn_actividad_crear/_actualizar. Retorna PK_TACTIVIDAD_RECUPERACION (o NULL).';

-- ---------------------------------------------------------------------------
-- 4) Fila public.query del contexto: nuevos QUERY.RECUPERAR y
--    QUERY.ACTIVIDAD_RECUPERAR (UPDATE: la fila ya existe).
-- ---------------------------------------------------------------------------
UPDATE public.query q
   SET query = 'SELECT academico_test.fn_actividad_configuracion_contexto(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.GRUPO AS BIGINT),
    CAST(:QUERY.ASIGNATURA AS BIGINT),
    CAST(:QUERY.UNIDAD AS BIGINT),
    COALESCE(CAST(:QUERY.ES_SUMATIVO AS VARCHAR), ''S''),
    COALESCE(CAST(:QUERY.RECUPERAR AS VARCHAR), ''N''),
    CAST(:QUERY.ACTIVIDAD_RECUPERAR AS BIGINT)
) AS configuracion;',
       param_types = '{"QUERY.GRUPO": "BIGINT", "QUERY.ASIGNATURA": "BIGINT", "QUERY.UNIDAD": "BIGINT", "QUERY.ES_SUMATIVO": "VARCHAR", "QUERY.RECUPERAR": "VARCHAR", "QUERY.ACTIVIDAD_RECUPERAR": "BIGINT"}'::jsonb,
       detail = 'Que pintar en el formulario de actividad a partir de los DOS filtros de la pantalla: ?grupo= y ?asignatura= (obligatorios), con ?unidad= OPCIONAL. Con unidad manda la unidad (referente y metodo de calculo); sin unidad el referente se deriva del grado + asignatura (fn_unidad_referente_aplicable). origenConfiguracion dice cual camino se uso (CONTEXTO o UNIDAD). Devuelve el contexto resuelto (grupo, grado, nivelEnsenanza, asignatura, referente {pk, nombre}), programacion (limites de fechaInicio/fechaCierre, semanaCronograma, duracionEstimada e intensidadHoraria a partir del periodo academico del grado y del horario) y campos_disponibles con la MISMA forma que GET /planeador/unidades/:ID/configuracion-actividad y GET /planeador/actividades/:ID/configuracion: criterio {visible, requerido, motivo}, evaluacion {visible, requerido, motivo, tipoEvaluacion, instrumentosPermitidos:[{pk, valor, nombre, variantes, campos}]}, ponderacion {visible, requerido, modo, campo?, autocalculado?, motivo} y recuperacion {visible, requerido, motivo, catalogos, reglas}. ?ES_SUMATIVO=S|N (default S: si no se envia, se responde la configuracion de una actividad sumativa) es lo que el usuario acaba de marcar en el formulario; con N SOLO se apagan recuperacion (una recuperacion debe ser sumativa) y ponderacion (la escritura la rechaza); la seccion de evaluacion y sus instrumentosPermitidos salen del referente igual que con S. En instrumentosPermitidos la entrada OTRO trae `campos`: tipoEvidencia {catalogo TIPO_EVIDENCIA_OTRO}, metodoValoracion {catalogo: los demas instrumentos que admite el tipo de evaluacion del referente, con variantes de escala}, definicion {formaPorMetodo}, descripcionInstrumento, requiereArchivo y requiereTexto; los demas instrumentos traen campos = null. El front decide por VALOR: los pk no son estables entre entornos. Recuperacion: ?RECUPERAR=S (la casilla "es una recuperacion") hace que recuperacion.actividadesRecuperables liste las actividades sumativas del (grupo, asignatura) que aun se pueden recuperar (ES_EVALUATIVA = S, no son recuperacion, sin otra recuperacion activa) -- el selector "Que desea recuperar"; ?ACTIVIDAD_RECUPERAR=<PK_TACTIVIDAD> devuelve recuperacion.origen con el contexto que el formulario hereda e inhabilita (grado, grupo, asignatura, unidad, tituloBase) y los estudiantes asignados a esa actividad con su notaPrevia, todos seleccionado=true para que el docente desmarque los que no la necesitan y envie los restantes en BODY.FK_TMATRICULAS del POST; 404/422 si la origen no existe, no es sumativa, ya es recuperacion o es de otra asignatura. recuperacion.reglas dice que tipoCalculo se oculta con REEMPLAZAR y se exige con COMPUTAR. En nivel Preescolar (formativo por definicion) evaluacion y recuperacion vienen visible=false. El arbol de enunciados y evidencias NO viene aqui: GET /planeador/referente-curricular?grado=&asignatura=. Gate VER sobre PLANEADOR + alcance por el grupo; 404 (P0002) si el grupo, la asignatura o la unidad no existen.'
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/actividades/configuracion'
   AND q.http_method     = 'GET';

