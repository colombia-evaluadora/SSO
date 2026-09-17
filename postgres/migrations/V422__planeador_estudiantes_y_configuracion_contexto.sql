-- ===========================================================================
-- V422 — Planeador: los estudiantes de una actividad y la configuracion de la
-- pantalla cuando todavia no hay unidad.
--
-- Tres huecos de crear actividad: listar estudiantes candidatos del grupo bajo
-- el gate del Planeador; dar endpoint propio a fn_actividad_estudiantes_asignar
-- (V224); y pintar el formulario sin unidad (V282 exige PK_TUNIDAD).
--
-- Depende de: V224, V282 (forma del JSON), V216, V214.2, V277.
-- Reapply: V214.2 -> V224 -> V241 -> V243 -> V246 -> V255 -> V278 -> V282 ->
-- V353 -> V422. V422 va en el MISMO despliegue que V224: fn_actividad_crear/
-- _actualizar llaman a fn_actividad_programacion_assert, que define V422 (42883).
-- ===========================================================================
SET search_path TO academico_test, public;

-- ===========================================================================
-- 1) Estudiantes candidatos de un grupo, con marca de asignado
--
-- La asignatura NO recorta la lista: en el modelo todos los matriculados en
-- el grupo cursan la asignatura. Se exige y se valida para que el endpoint
-- falle claro si el contexto es incoherente, no para filtrar.
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_planeador_estudiantes_candidatos_listar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tgrupo              BIGINT,
    p_fk_tasignatura         BIGINT DEFAULT NULL,
    p_pk_tactividad          BIGINT DEFAULT NULL,
    p_search                 VARCHAR DEFAULT NULL,
    p_limite                 INT DEFAULT NULL,
    p_offset                 INT DEFAULT 0
)
RETURNS TABLE (
    pk_tmatricula            BIGINT,
    fk_testudiante           BIGINT,
    estudiante               VARCHAR,
    fk_tgrupo                BIGINT,
    grupo                    VARCHAR,
    fk_tgrado                BIGINT,
    grado                    VARCHAR,
    asignado                 BOOLEAN,
    pk_tactividad_estudiante BIGINT,
    total_count              BIGINT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_search VARCHAR := NULLIF(TRIM(COALESCE(p_search, '')), '');
BEGIN
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', p_fk_tgrupo, NULL, NULL, p_pk_tactividad
    );

    IF p_fk_tgrupo IS NULL THEN
        RAISE EXCEPTION 'Se requiere el grupo para listar sus estudiantes'
            USING ERRCODE = '22023';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM academico_test.TGRUPO
                    WHERE PK_TGRUPO = p_fk_tgrupo AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'No se encontro el grupo solicitado' USING ERRCODE = 'P0002';
    END IF;

    IF p_fk_tasignatura IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM academico_test.TASIGNATURA
                        WHERE PK_TASIGNATURA = p_fk_tasignatura AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'No se encontro la asignatura solicitada' USING ERRCODE = 'P0002';
    END IF;

    -- La actividad, si se pasa, tiene que ser la del mismo grupo: si no, la
    -- marca "asignado" seria de otra actividad y el front la creeria buena.
    IF p_pk_tactividad IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM academico_test.TACTIVIDAD a
                        WHERE a.PK_TACTIVIDAD = p_pk_tactividad
                          AND (a.FK_TGRUPO IS NULL OR a.FK_TGRUPO = p_fk_tgrupo)) THEN
        RAISE EXCEPTION 'La actividad indicada no existe o no pertenece a ese grupo'
            USING ERRCODE = '22023';
    END IF;

    RETURN QUERY
    WITH base AS (
        SELECT m.PK_TMATRICULA,
               m.FK_TESTUDIANTE,
               NULLIF(TRIM(CONCAT_WS(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
                                          u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO)), '')::VARCHAR AS nombre,
               gr.PK_TGRUPO,
               gr.NOMBRE AS grupo_nombre,
               gr.FK_TGRADO,
               gd.NOMBRE AS grado_nombre,
               ae.PK_TACTIVIDAD_ESTUDIANTE
          FROM academico_test.TMATRICULA m
          JOIN academico_test.TGRUPO gr      ON gr.PK_TGRUPO = m.FK_TGRUPO
          LEFT JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
          JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
          JOIN academico_test.TUSUARIO u     ON u.PK_TUSUARIO = es.FK_TUSUARIO
          LEFT JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
                 ON ae.FK_TMATRICULA = m.PK_TMATRICULA
                AND ae.FK_TACTIVIDAD = p_pk_tactividad
                AND ae.ACTIVE = TRUE
         WHERE m.FK_TGRUPO = p_fk_tgrupo
           AND m.ACTIVE = TRUE
    )
    SELECT b.PK_TMATRICULA,
           b.FK_TESTUDIANTE,
           b.nombre,
           b.PK_TGRUPO,
           b.grupo_nombre,
           b.FK_TGRADO,
           b.grado_nombre,
           (b.PK_TACTIVIDAD_ESTUDIANTE IS NOT NULL),
           b.PK_TACTIVIDAD_ESTUDIANTE,
           COUNT(*) OVER()
      FROM base b
     WHERE v_search IS NULL OR b.nombre ILIKE '%' || v_search || '%'
     ORDER BY b.nombre, b.PK_TMATRICULA
     LIMIT p_limite OFFSET GREATEST(COALESCE(p_offset, 0), 0);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_planeador_estudiantes_candidatos_listar(BIGINT, BIGINT, BIGINT, BIGINT, VARCHAR, INT, INT)
    IS 'Los estudiantes matriculados ACTIVOS de un grupo, para escoger a quien se le asigna una actividad del Planeador. La ASIGNATURA no recorta la lista -- en el modelo todos los matriculados en el grupo cursan la asignatura --: se valida su existencia para que un contexto incoherente falle claro, no para filtrar. Con p_pk_tactividad cada fila trae asignado (BOOLEAN) y pk_tactividad_estudiante, que es el PK que piden las adaptaciones (TACTIVIDAD_ADAPTACION_ESTUDIANTE cuelga de TACTIVIDAD_ESTUDIANTE, no de la matricula) y la calificacion por estudiante; sin actividad, asignado viene FALSE en todas. La actividad debe ser del mismo grupo o se rechaza con 22023: si no, la marca seria de otra actividad y el front la creeria buena. p_limite NULL = sin paginar. total_count via COUNT(*) OVER() sobre el filtro de busqueda. Gate VER sobre PLANEADOR + alcance territorial por el grupo (V277). V422.';

-- ===========================================================================
-- 2) Fijar los estudiantes de una actividad ya creada
--
-- fn_actividad_estudiantes_asignar (V224) ya tiene semantica de reemplazo y
-- valida que las matriculas sean del grupo de la actividad, pero NO lleva
-- gate: se invocaba solo desde fn_actividad_crear, que ya habia gateado.
-- Exponerla directamente seria un endpoint sin gate, asi que se envuelve.
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_estudiantes_set(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT,
    p_fk_tmatriculas         BIGINT[] DEFAULT NULL,
    p_todo_el_grupo          BOOLEAN DEFAULT FALSE
)
RETURNS INT
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'EDITAR', NULL, NULL, NULL, p_pk_tactividad
    );

    IF NOT EXISTS (SELECT 1 FROM academico_test.TACTIVIDAD
                    WHERE PK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'No se encontro la actividad solicitada' USING ERRCODE = 'P0002';
    END IF;

    -- Un array vacio es "dejar la actividad sin estudiantes", no "no tocar":
    -- NULL + todo_el_grupo FALSE es lo que significa no tocar, y ahi la
    -- funcion de V224 devuelve 0 sin escribir.
    RETURN academico_test.fn_actividad_estudiantes_asignar(
        p_pk_usuario_solicitante, p_pk_tactividad,
        p_fk_tmatriculas, COALESCE(p_todo_el_grupo, FALSE)
    );
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_estudiantes_set(BIGINT, BIGINT, BIGINT[], BOOLEAN)
    IS 'Fija los estudiantes asignados a una actividad YA CREADA, con semantica de REEMPLAZO: el set queda exactamente el que se envia (las que ya no vienen se desactivan, las que vuelven se reactivan). Envuelve fn_actividad_estudiantes_asignar (V224), que ya valida que cada matricula exista, este activa y pertenezca al grupo de la actividad (23503), pero que NO lleva gate porque solo se invocaba desde fn_actividad_crear: sin esta envoltura el endpoint quedaria sin control de permisos. p_todo_el_grupo = TRUE ignora el array y asigna todos los matriculados activos del grupo (22023 si la actividad no tiene grupo). Un array VACIO deja la actividad sin estudiantes; NULL con p_todo_el_grupo FALSE no toca nada y devuelve 0. Retorna el total de asignados activos tras la operacion. Gate EDITAR sobre PLANEADOR + alcance por la actividad. P0002 si la actividad no existe o esta inactiva. V422.';

-- ===========================================================================
-- 3) Limites de la seccion "Programacion", en un solo sitio
--
-- Los usan la pantalla (para pintar min/max) y la escritura (para validarlos):
-- si se calcularan por separado, el formulario y el backend acabarian
-- discrepando. La ventana la fija el PERIODO ACADEMICO del grado y los dias
-- habiles el HORARIO de ese (grupo, asignatura).
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_programacion_limites(
    p_fk_tgrupo      BIGINT,
    p_fk_tasignatura BIGINT
)
RETURNS TABLE (
    fk_tperiodo_academico BIGINT,
    periodo_academico     VARCHAR,
    periodo_desde         DATE,
    periodo_hasta         DATE,
    semanas               INT,
    bloques_por_semana    INT,
    dias_habiles          INT[],
    dias_habiles_nombre   JSONB,
    fecha_min             DATE,
    fecha_max             DATE,
    duracion_max          NUMERIC
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_desde DATE; v_hasta DATE; v_sem INT; v_blo INT;
    v_dias INT[]; v_nom JSONB; v_fmin DATE; v_fmax DATE;
    v_pk BIGINT; v_nombre VARCHAR;
BEGIN
    SELECT pa.PK_TPERIODO_ACADEMICO, pa.NOMBRE, pa.FECHA_INICIO, pa.FECHA_FIN
      INTO v_pk, v_nombre, v_desde, v_hasta
      FROM academico_test.TGRUPO gr
      JOIN academico_test.TGRADO g ON g.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa
            ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
           AND pa.ACTIVE = TRUE
     WHERE gr.PK_TGRUPO = p_fk_tgrupo;

    IF v_desde IS NOT NULL AND v_hasta IS NOT NULL THEN
        v_sem := CEIL(((v_hasta - v_desde) + 1) / 7.0)::INT;
    END IF;

    SELECT COUNT(*)::INT,
           COALESCE(ARRAY_AGG(DISTINCT lv.VALOR::INT ORDER BY lv.VALOR::INT), ARRAY[]::INT[]),
           COALESCE(jsonb_agg(DISTINCT jsonb_build_object(
                        'valor', lv.VALOR::INT, 'nombre', lv.NOMBRE)), '[]'::jsonb)
      INTO v_blo, v_dias, v_nom
      FROM academico_test.THORARIO h
      JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = h.FK_TLV_DIA_SEMANA
     WHERE h.FK_TGRUPO = p_fk_tgrupo
       AND h.FK_TASIGNATURA = p_fk_tasignatura
       AND h.ACTIVE = TRUE;

    -- DIA_SEMANA.VALOR es EXTRACT(DOW)+1 (Domingo = 1).
    IF v_desde IS NOT NULL AND COALESCE(array_length(v_dias, 1), 0) > 0 THEN
        SELECT MIN(d)::DATE, MAX(d)::DATE INTO v_fmin, v_fmax
          FROM generate_series(v_desde, v_hasta, INTERVAL '1 day') d
         WHERE (EXTRACT(DOW FROM d)::INT + 1) = ANY(v_dias);
    ELSE
        v_fmin := v_desde; v_fmax := v_hasta;
    END IF;

    RETURN QUERY SELECT v_pk, v_nombre, v_desde, v_hasta, v_sem, v_blo, v_dias, v_nom,
                        v_fmin, v_fmax,
                        CASE WHEN COALESCE(v_blo, 0) > 0 AND v_sem IS NOT NULL
                             THEN (v_sem * v_blo)::NUMERIC END;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_programacion_limites(BIGINT, BIGINT)
    IS 'Fuente UNICA de los limites de la seccion Programacion de una actividad, para que la pantalla (fn_actividad_configuracion_contexto) y la escritura (fn_actividad_programacion_assert, llamada desde fn_actividad_crear/_actualizar) no puedan discrepar. La ventana la fija el PERIODO ACADEMICO del grado del grupo (TGRUPO -> TGRADO.FK_TPERIODO_ACADEMICO); semanas = CEIL(dias del periodo / 7); bloques_por_semana = la intensidad horaria, contada sobre THORARIO ACTIVO de ese (grupo, asignatura); dias_habiles = los dias en que esa asignatura se dicta, con DIA_SEMANA.VALOR = EXTRACT(DOW)+1 (Domingo = 1); fecha_min / fecha_max = primer y ultimo dia habil DENTRO del periodo (si no hay horario, los extremos del periodo); duracion_max = semanas x bloques_por_semana. Cuando falta el dato base devuelve NULL en vez de inventar un tope: sin periodo academico no hay ventana ni semanas, y sin horario no hay duracion_max. V422.';

-- ===========================================================================
-- 4) Configuracion del formulario de actividad SIN depender de la unidad
--
-- Misma forma de JSON y mismos textos de motivo que V282/V214.2, para que el
-- front use el mismo codigo de render en los tres momentos (sin unidad, con
-- unidad, y con la actividad ya creada). El referente se deriva del grado del
-- grupo + la asignatura con fn_unidad_referente_aplicable (V216), la misma
-- regla que usa la creacion de unidades.
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_configuracion_contexto(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tgrupo              BIGINT,
    p_fk_tasignatura         BIGINT,
    p_fk_tunidad             BIGINT DEFAULT NULL,
    p_es_evaluativa          VARCHAR DEFAULT 'S'
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_es_evaluativa VARCHAR := UPPER(TRIM(COALESCE(p_es_evaluativa, 'S')));
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
    v_ponderacion   JSONB;
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

    -- Preescolar por NOMBRE del nivel, no por PK (V214.2/V282): los pks de
    -- TNIVEL_ENSENANZA no son estables entre bases.
    v_es_preescolar := COALESCE(v_nivel ILIKE 'preescolar%', FALSE);

    -- Con unidad manda la unidad (es la que ya eligio referente y metodo de
    -- calculo); sin unidad, el referente se deriva del grado + asignatura.
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

    v_instrumentos := CASE
        WHEN NOT COALESCE(v_evaluativo, FALSE) OR v_es_evaluativa = 'N'
            THEN '[]'::jsonb
        ELSE COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'pk',     lv.PK_LISTA_VALOR,
                       'valor',  lv.VALOR,
                       'nombre', lv.NOMBRE)
                       ORDER BY lv.PK_LISTA_VALOR)
              FROM academico_test.TLISTA_VALOR lv
             WHERE lv.CATEGORIA = 'INSTRUMENTO_EVALUACION'
               AND lv.ACTIVE = TRUE
               AND academico_test.fn_instrumento_permitido_por_tipo_evaluacion(lv.VALOR, v_tipo)
        ), '[]'::jsonb)
    END;

    -- La ponderacion depende del metodo de calculo de la UNIDAD: sin unidad no
    -- hay con que decidirla, y se apaga con un motivo explicito en vez de
    -- inventar un modo.
    v_ponderacion := CASE
        WHEN v_es_evaluativa = 'N' THEN jsonb_build_object(
            'visible', FALSE, 'requerido', FALSE, 'modo', NULL,
            'motivo', 'La actividad no es evaluativa; la ponderacion no aplica')
        WHEN p_fk_tunidad IS NULL THEN jsonb_build_object(
            'visible', FALSE, 'requerido', FALSE, 'modo', NULL,
            'motivo', 'La actividad aun no pertenece a una unidad; la ponderacion la define el metodo de calculo de la unidad')
        WHEN v_modo = 'PONDERAR' THEN jsonb_build_object(
            'visible', TRUE, 'requerido', TRUE, 'modo', 'PORCENTAJE',
            'campo', 'PONDERACION',
            'motivo', 'la unidad pondera sus actividades')
        WHEN v_modo = 'SUMATORIA' THEN jsonb_build_object(
            'visible', TRUE, 'requerido', TRUE, 'modo', 'PUNTAJE',
            'campo', 'NOTA_MAXIMA', 'autocalculado', TRUE,
            'motivo', 'la unidad suma puntajes; el % lo calcula el sistema')
        WHEN v_modo = 'PROMEDIAR' THEN jsonb_build_object(
            'visible', FALSE, 'requerido', FALSE, 'modo', NULL,
            'motivo', 'la unidad promedia, la ponderacion no aplica')
        ELSE jsonb_build_object(
            'visible', FALSE, 'requerido', FALSE, 'modo', NULL,
            'motivo', 'la unidad aun no tiene metodo de calculo elegido')
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
        'esEvaluativaConsultada', v_es_evaluativa,
        'campos_disponibles', jsonb_build_object(
            'criterio', jsonb_build_object(
                'visible',   NOT v_es_preescolar AND p_fk_tunidad IS NOT NULL,
                'requerido', FALSE,
                'motivo',    CASE
                    WHEN v_es_preescolar AND p_fk_tunidad IS NOT NULL
                        THEN 'El grado de la unidad pertenece al nivel Preescolar: la relacion con criterios de rubrica no aplica'
                    WHEN v_es_preescolar
                        THEN 'El grado pertenece al nivel Preescolar: la relacion con criterios de rubrica no aplica'
                    WHEN p_fk_tunidad IS NULL
                        THEN 'Los criterios pertenecen a la rubrica de una unidad; la actividad aun no tiene unidad'
                    ELSE 'Opcional: la actividad puede relacionarse con criterios de la rubrica de la unidad'
                END),
            'evaluacion', jsonb_build_object(
                'visible',   COALESCE(v_evaluativo, FALSE) AND v_es_evaluativa <> 'N',
                'requerido', COALESCE(v_evaluativo, FALSE) AND v_es_evaluativa <> 'N',
                'motivo',    CASE
                    WHEN v_es_evaluativa = 'N'
                        THEN 'La actividad se creara como NO evaluativa; no hay seccion de evaluacion'
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
            'ponderacion', v_ponderacion,
            'recuperacion', academico_test.fn_actividad_recuperacion_campos_disponibles(
                                COALESCE(v_evaluativo, FALSE), v_es_evaluativa))
    );
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_configuracion_contexto(BIGINT, BIGINT, BIGINT, BIGINT, VARCHAR)
    IS 'Que pintar en el formulario de actividad a partir de los DOS filtros de la pantalla -- grupo y asignatura --, con la unidad como dato OPCIONAL. Cubre el hueco de V282, que exige PK_TUNIDAD y por tanto no sirve para una actividad sin unidad. Deriva grupo -> grado -> nivel de ensenanza y, si no hay unidad, el referente con fn_unidad_referente_aplicable(grado, asignatura) -- la misma regla que usa la creacion de unidades (V216) y que expone GET /planeador/referente-curricular (V278). Si SI hay unidad manda la unidad, que es la que ya eligio referente y metodo de calculo, y se superpone lo que solo ella aporta: criterios de rubrica y ponderacion. origenConfiguracion dice cual de los dos caminos se uso (CONTEXTO o UNIDAD). Conserva la forma del JSON y los textos de motivo de V282/V214.2 para que el front use el mismo codigo de render en los tres momentos del flujo. Sin unidad, criterio y ponderacion vienen visible=false con motivo explicito (los criterios pertenecen a la rubrica de una unidad; la ponderacion la decide el metodo de calculo de la unidad), en vez de inventar un modo. Ademas devuelve programacion: los limites de la seccion Programacion del formulario, que la pantalla debe usar como min/max de sus campos en vez de dejarlos libres. La ventana la fija el PERIODO ACADEMICO del grado (TGRADO.FK_TPERIODO_ACADEMICO) y los dias habiles el HORARIO de ese (grupo, asignatura): fechaInicio/fechaCierre {min, max, diasHabiles} acotan al primer y ultimo dia dentro del periodo en que la asignatura realmente se dicta (DIA_SEMANA.VALOR es EXTRACT(DOW)+1, Domingo = 1); semanaCronograma {min: 1, max} donde max son las semanas que dura el periodo; duracionEstimada {min: 1, max} donde max = semanas del periodo x bloques semanales de la asignatura (la intensidad horaria, contada sobre THORARIO activo), e intensidadHoraria {bloquesPorSemana, diasHabiles:[{valor,nombre}]}. Cuando falta el dato base no se inventa un tope: sin horario, las fechas solo se acotan por el periodo y duracionEstimada.max viene NULL; sin periodo academico en el grado, todo el bloque viene NULL con su motivo. Preescolar se detecta por NOMBRE del nivel (ILIKE preescolar%), no por PK, igual que V214.2/V282. Gate VER sobre PLANEADOR + alcance por el grupo (y por la unidad si viene). P0002 si el grupo, la asignatura o la unidad no existen o estan inactivos. V422.';

-- ===========================================================================
-- 5) La validacion de esos limites al ESCRIBIR
--
-- Sin esto los topes son decorativos: un cliente que no los respete guarda lo
-- que quiera. Se llama desde fn_actividad_crear y fn_actividad_actualizar
-- (V224). Cuando falta el dato base (sin periodo academico, sin horario) no
-- valida: no hay tope que aplicar, el mismo criterio que la pantalla.
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_programacion_assert(
    p_fk_tgrupo         BIGINT,
    p_fk_tasignatura    BIGINT,
    p_fecha_inicio      DATE,
    p_fecha_cierre      DATE,
    p_duracion          NUMERIC,
    p_semana_cronograma VARCHAR
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    l      RECORD;
    v_sem  INT;
BEGIN
    IF p_fk_tgrupo IS NULL OR p_fk_tasignatura IS NULL THEN
        RETURN;                       -- sin contexto no hay limites que aplicar
    END IF;

    SELECT * INTO l
      FROM academico_test.fn_actividad_programacion_limites(p_fk_tgrupo, p_fk_tasignatura);

    IF l.periodo_desde IS NOT NULL THEN
        IF p_fecha_inicio IS NOT NULL
           AND (p_fecha_inicio < l.periodo_desde OR p_fecha_inicio > l.periodo_hasta) THEN
            RAISE EXCEPTION 'La fecha de inicio (%) esta fuera del periodo academico % (% a %)',
                p_fecha_inicio, COALESCE(l.periodo_academico, ''), l.periodo_desde, l.periodo_hasta
                USING ERRCODE = '22023';
        END IF;

        IF p_fecha_cierre IS NOT NULL
           AND (p_fecha_cierre < l.periodo_desde OR p_fecha_cierre > l.periodo_hasta) THEN
            RAISE EXCEPTION 'La fecha de cierre (%) esta fuera del periodo academico % (% a %)',
                p_fecha_cierre, COALESCE(l.periodo_academico, ''), l.periodo_desde, l.periodo_hasta
                USING ERRCODE = '22023';
        END IF;
    END IF;

    -- Dia habil: solo la fecha de INICIO. El cierre es una fecha de entrega y
    -- puede caer en un dia sin clase; exigirselo rechazaria un uso legitimo.
    IF COALESCE(array_length(l.dias_habiles, 1), 0) > 0
       AND p_fecha_inicio IS NOT NULL
       AND NOT ((EXTRACT(DOW FROM p_fecha_inicio)::INT + 1) = ANY(l.dias_habiles)) THEN
        RAISE EXCEPTION 'La fecha de inicio (%) cae en un dia en que no se dicta la asignatura segun el horario del grupo',
            p_fecha_inicio USING ERRCODE = '22023';
    END IF;

    IF p_duracion IS NOT NULL THEN
        IF p_duracion < 1 THEN
            RAISE EXCEPTION 'La duracion estimada (%) debe ser al menos 1', p_duracion
                USING ERRCODE = '22023';
        END IF;
        IF l.duracion_max IS NOT NULL AND p_duracion > l.duracion_max THEN
            RAISE EXCEPTION 'La duracion estimada (%) supera el maximo de % bloques: % semanas del periodo academico por % bloques semanales de la asignatura',
                p_duracion, l.duracion_max, l.semanas, l.bloques_por_semana
                USING ERRCODE = '22023';
        END IF;
    END IF;

    -- SEMANA_CRONOGRAMA es texto y admite rangos ("10-12"): se valida CADA
    -- numero que aparezca, no el campo entero como un entero.
    IF l.semanas IS NOT NULL AND NULLIF(TRIM(COALESCE(p_semana_cronograma, '')), '') IS NOT NULL THEN
        FOR v_sem IN
            SELECT t[1]::INT
              FROM regexp_matches(p_semana_cronograma, '\d+', 'g') t
        LOOP
            IF v_sem < 1 OR v_sem > l.semanas THEN
                RAISE EXCEPTION 'La semana del cronograma (%) esta fuera de rango: el periodo academico tiene % semanas',
                    v_sem, l.semanas USING ERRCODE = '22023';
            END IF;
        END LOOP;
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_programacion_assert(BIGINT, BIGINT, DATE, DATE, NUMERIC, VARCHAR)
    IS 'Valida al ESCRIBIR los mismos limites que fn_actividad_configuracion_contexto pinta en la pantalla, leyendolos del mismo sitio (fn_actividad_programacion_limites) para que no puedan discrepar. Sin esto los topes serian decorativos: un cliente que no los respete guardaria cualquier cosa. Comprueba que fecha de inicio y de cierre caigan DENTRO del periodo academico del grado; que la de INICIO caiga en un dia en que la asignatura se dicta segun THORARIO -- el CIERRE no, porque es una fecha de entrega y puede caer en un dia sin clase; que la duracion estimada este entre 1 y semanas x bloques semanales; y que CADA numero de SEMANA_CRONOGRAMA este entre 1 y las semanas del periodo (el campo es texto y admite rangos como "10-12", asi que se validan todos sus numeros, no el campo como un entero). Todo error es 22023 con el limite en el mensaje. NO valida lo que no puede acotar: sin grupo o sin asignatura retorna sin hacer nada, sin periodo academico no valida fechas ni semana, y sin horario no valida ni dia habil ni duracion -- el mismo criterio de "no inventar un tope" que usa la pantalla. Llamada desde fn_actividad_crear y fn_actividad_actualizar (V224). V422.';

-- ===========================================================================
-- ENDPOINTS
-- ===========================================================================
-- Por uuid Y por (ruta, metodo): la fila puede existir con otro uuid, y el
-- ON CONFLICT de abajo es por (microservice, path_template, http_method).
DELETE FROM public.query q
 USING public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND (q.uuid = 'eval-col-planeador-estudiantes-001'
        OR (q.path_template = '/planeador/estudiantes' AND q.http_method = 'GET'));

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    'eval-col-planeador-estudiantes-001',
    'SELECT * FROM academico_test.fn_planeador_estudiantes_candidatos_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.GRUPO AS BIGINT),
    CAST(:QUERY.ASIGNATURA AS BIGINT),
    CAST(:QUERY.ACTIVIDAD AS BIGINT),
    CAST(:QUERY.SEARCH AS VARCHAR),
    CAST(:QUERY.SIZE AS INT),
    COALESCE(CAST(:QUERY.OFFSET AS INT), 0)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/estudiantes', 'SELECT', 'GET',
    '{"QUERY.GRUPO": "BIGINT", "QUERY.ASIGNATURA": "BIGINT", "QUERY.ACTIVIDAD": "BIGINT", "QUERY.SEARCH": "VARCHAR", "QUERY.SIZE": "INT", "QUERY.OFFSET": "INT"}'::jsonb,
    'V422 -- los estudiantes matriculados activos de un ?grupo= (obligatorio), para escoger a quien se le asigna una actividad del Planeador. ?asignatura= NO recorta la lista: en el modelo todos los matriculados en el grupo cursan la asignatura, y solo se valida que exista para que un contexto incoherente falle claro. Con ?actividad= cada fila trae asignado (true/false) y pk_tactividad_estudiante, que es el PK que piden las adaptaciones (TACTIVIDAD_ADAPTACION_ESTUDIANTE cuelga de TACTIVIDAD_ESTUDIANTE, no de la matricula), la nota por estudiante y la observacion; sin ?actividad= asignado viene false en todas y sirve como catalogo de candidatos para POST /planeador/actividades (BODY.FK_TMATRICULAS). La actividad tiene que ser del mismo grupo o responde 22023. Devuelve pk_tmatricula, fk_testudiante, estudiante, grupo, grado, asignado, pk_tactividad_estudiante y total_count. ?search= filtra por nombre; ?size= NULL devuelve sin paginar. Gate VER sobre PLANEADOR + alcance territorial por el grupo; 404 (P0002) si el grupo o la asignatura no existen.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

-- Por uuid Y por (ruta, metodo): la fila puede existir con otro uuid, y el
-- ON CONFLICT de abajo es por (microservice, path_template, http_method).
DELETE FROM public.query q
 USING public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND (q.uuid = 'eval-col-planeador-actividad-estudiantes-set-001'
        OR (q.path_template = '/planeador/actividades/:ID/estudiantes' AND q.http_method = 'PUT'));

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    'eval-col-planeador-actividad-estudiantes-set-001',
    'SELECT academico_test.fn_actividad_estudiantes_set(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.FK_TMATRICULAS AS BIGINT[]),
    COALESCE(CAST(:BODY.ASIGNAR_TODO_EL_GRUPO AS BOOLEAN), FALSE)
) AS total_asignados;',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades/:ID/estudiantes', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT", "BODY.FK_TMATRICULAS": "BIGINT[]", "BODY.ASIGNAR_TODO_EL_GRUPO": "BOOLEAN"}'::jsonb,
    'V422 -- fija los estudiantes asignados a una actividad YA CREADA, con semantica de REEMPLAZO: el set queda exactamente el que se envia (los que ya no vienen se desactivan, los que vuelven se reactivan). :ID = PK_TACTIVIDAD. Cubre el hueco de que fn_actividad_estudiantes_asignar (V224) solo se podia invocar al CREAR la actividad (POST /planeador/actividades, BODY.FK_TMATRICULAS): no habia forma de cambiar los asignados despues. BODY.FK_TMATRICULAS son PK_TMATRICULA -- sacarlos de GET /planeador/estudiantes?grupo= --; cada uno debe existir, estar activo y pertenecer al grupo de la actividad o responde 23503. BODY.ASIGNAR_TODO_EL_GRUPO = true ignora el array y asigna todos los matriculados activos del grupo (22023 si la actividad no tiene grupo). Un array VACIO deja la actividad sin estudiantes; omitir los dos campos no toca nada y devuelve 0. Devuelve total_asignados = el total de asignados activos tras la operacion. OJO: quitar un estudiante desactiva su TACTIVIDAD_ESTUDIANTE, y con el las adaptaciones y la nota que colgaban de esa fila. Gate EDITAR sobre PLANEADOR + alcance por la actividad; 404 (P0002) si la actividad no existe o esta inactiva.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

-- Por uuid Y por (ruta, metodo): la fila puede existir con otro uuid, y el
-- ON CONFLICT de abajo es por (microservice, path_template, http_method).
DELETE FROM public.query q
 USING public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND (q.uuid = 'eval-col-planeador-actividad-configuracion-001'
        OR (q.path_template = '/planeador/actividades/configuracion' AND q.http_method = 'GET'));

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    'eval-col-planeador-actividad-configuracion-001',
    'SELECT academico_test.fn_actividad_configuracion_contexto(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.GRUPO AS BIGINT),
    CAST(:QUERY.ASIGNATURA AS BIGINT),
    CAST(:QUERY.UNIDAD AS BIGINT),
    COALESCE(CAST(:QUERY.ES_EVALUATIVA AS VARCHAR), ''S'')
) AS configuracion;',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades/configuracion', 'SELECT', 'GET',
    '{"QUERY.GRUPO": "BIGINT", "QUERY.ASIGNATURA": "BIGINT", "QUERY.UNIDAD": "BIGINT", "QUERY.ES_EVALUATIVA": "VARCHAR"}'::jsonb,
    'V422 -- que pintar en el formulario de actividad a partir de los DOS filtros de la pantalla: ?grupo= y ?asignatura= (ambos obligatorios), con ?unidad= OPCIONAL. Cubre el hueco de GET /planeador/unidades/:ID/configuracion-actividad (V282), que exige una unidad y por tanto no sirve para la actividad que aun no pertenece a ninguna. Deriva grupo -> grado -> nivel de ensenanza y, sin unidad, el referente con la misma regla que usa la creacion de unidades (fn_unidad_referente_aplicable, V216); con unidad manda la unidad, que es la que ya eligio referente y metodo de calculo, y se superponen las configuraciones que solo ella aporta: criterios de rubrica y ponderacion. Lee origenConfiguracion (CONTEXTO o UNIDAD) para saber cual de los dos caminos se uso. Devuelve el contexto resuelto (grupo, grado, nivelEnsenanza, asignatura, referente {pk, nombre}) y campos_disponibles con la MISMA forma y los mismos textos de motivo que V282 y que GET /planeador/actividades/:ID/configuracion, para reutilizar el codigo de render en los tres momentos del flujo: criterio {visible, requerido, motivo}, evaluacion {visible, requerido, motivo, tipoEvaluacion, instrumentosPermitidos:[{pk,valor,nombre}]} y ponderacion {visible, requerido, modo, campo?, autocalculado?, motivo}. Sin unidad, criterio y ponderacion vienen visible=false con motivo explicito en vez de un modo inventado. ?ES_EVALUATIVA=S|N (default S) es lo que el usuario acaba de marcar en el formulario; con N se apagan la seccion de evaluacion y la ponderacion. Ademas devuelve programacion: los limites de la seccion Programacion del formulario, que la pantalla debe usar como min/max de sus campos en vez de dejarlos libres. La ventana la fija el PERIODO ACADEMICO del grado (TGRADO.FK_TPERIODO_ACADEMICO) y los dias habiles el HORARIO de ese (grupo, asignatura): fechaInicio/fechaCierre {min, max, diasHabiles} acotan al primer y ultimo dia dentro del periodo en que la asignatura realmente se dicta (DIA_SEMANA.VALOR es EXTRACT(DOW)+1, Domingo = 1); semanaCronograma {min: 1, max} donde max son las semanas que dura el periodo; duracionEstimada {min: 1, max} donde max = semanas del periodo x bloques semanales de la asignatura (la intensidad horaria, contada sobre THORARIO activo), e intensidadHoraria {bloquesPorSemana, diasHabiles:[{valor,nombre}]}. Cuando falta el dato base no se inventa un tope: sin horario, las fechas solo se acotan por el periodo y duracionEstimada.max viene NULL; sin periodo academico en el grado, todo el bloque viene NULL con su motivo. El arbol de enunciados y evidencias NO viene aqui: pedirlo a GET /planeador/referente-curricular?grado=&asignatura= (V278). Gate VER sobre PLANEADOR + alcance por el grupo; 404 (P0002) si el grupo, la asignatura o la unidad no existen.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

-- Mismos roles que el resto del Planeador. V284 concede la lectura a todo rol
-- que tenga el menu; aqui se siembran los dos base para no depender del orden.
INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR', 'CEVAL-DOCENTE')
 WHERE m.serviceid = 'eval-col'
   AND q.path_template IN ('/planeador/estudiantes',
                           '/planeador/actividades/:ID/estudiantes',
                           '/planeador/actividades/configuracion')
ON CONFLICT DO NOTHING;
