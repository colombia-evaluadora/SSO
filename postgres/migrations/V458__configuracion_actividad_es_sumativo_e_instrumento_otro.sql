-- ===========================================================================
-- V458 — Configuracion del formulario de actividad: ES_SUMATIVO reemplaza a
-- ES_EVALUATIVA en GET /planeador/actividades/configuracion y en
-- GET /planeador/unidades/:ID/configuracion-actividad (default S). Con N ya
-- no se apaga la seccion de evaluacion: solo la recuperacion (y la
-- ponderacion, que fn_actividad_crear sigue rechazando con N). La entrada
-- OTRO de instrumentosPermitidos gana `campos`: tipoEvidencia,
-- metodoValoracion (los demas instrumentos que admite el referente, con sus
-- variantes), definicion, descripcionInstrumento, requiereArchivo/Texto.
-- Depende de: V440 (firmas), V453 (helper + variantes), V240 (TACTIVIDAD_OTRO),
-- V214.2 (recuperacion), V282/V422 (filas public.query).
-- ===========================================================================
SET search_path TO academico_test, public;

-- ---------------------------------------------------------------------------
-- 1) Campos del instrumento OTRO (personalizado), por TIPO_EVALUACION resuelto.
--    metodoValoracion reutiliza INSTRUMENTO_EVALUACION sin OTRO y con el mismo
--    filtro por referente que aplica fn_actividad_*_definir al guardar.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_otro_campos_disponibles(
    p_tipo_evaluacion VARCHAR
) RETURNS JSONB
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'tipoEvidencia', jsonb_build_object(
            'requerido', TRUE,
            'catalogo', COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                           'pk', lv.PK_LISTA_VALOR, 'valor', lv.VALOR, 'nombre', lv.NOMBRE)
                           ORDER BY lv.NOMBRE)
                  FROM academico_test.TLISTA_VALOR lv
                 WHERE lv.CATEGORIA = 'TIPO_EVIDENCIA_OTRO'
                   AND lv.ACTIVE = TRUE), '[]'::jsonb),
            'motivo', 'Tipo de evidencia esperada del instrumento personalizado'),
        'metodoValoracion', jsonb_build_object(
            'requerido', TRUE,
            'catalogo', COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                           'pk',        lv.PK_LISTA_VALOR,
                           'valor',     lv.VALOR,
                           'nombre',    lv.NOMBRE,
                           'variantes', CASE WHEN lv.VALOR = 'ESCALA_VALORACION'
                                             THEN academico_test.fn_escala_variantes_permitidas(p_tipo_evaluacion)
                                             ELSE '[]'::jsonb END)
                           ORDER BY lv.NOMBRE)
                  FROM academico_test.TLISTA_VALOR lv
                 WHERE lv.CATEGORIA = 'INSTRUMENTO_EVALUACION'
                   AND lv.ACTIVE = TRUE
                   AND lv.VALOR <> 'OTRO'
                   AND academico_test.fn_instrumento_permitido_por_tipo_evaluacion(lv.VALOR, p_tipo_evaluacion)),
                '[]'::jsonb),
            'motivo', 'Instrumento con el que se califica el personalizado; se ofrecen los que admite el tipo de evaluacion del referente'),
        'definicion', jsonb_build_object(
            'requerido', TRUE,
            'formaPorMetodo', jsonb_build_object(
                'RUBRICA',           '[{nombre, descripcion?, niveles:[{etiqueta?, descripcion, ponderacion}]}]',
                'LISTA_COTEJO',      '[{descripcion, ponderacion?}]',
                'ESCALA_VALORACION', '{tipoEscala, criteriosGenerales?, interpretacionRangos?, valorMin?, valorMax?, niveles?}'),
            'motivo', 'Misma forma que el metodoValoracion elegido; se envia en PUT /planeador/actividades/:ID/instrumento como {tipoEvidencia, metodoValoracion, definicion}'),
        'descripcionInstrumento', jsonb_build_object(
            'requerido', FALSE, 'campo', 'DESCRIPCION_INSTRUMENTO', 'maxLength', 4000,
            'motivo', 'Descripcion libre del instrumento; va en el POST/PATCH de la actividad'),
        'requiereArchivo', jsonb_build_object(
            'requerido', FALSE, 'campo', 'REQUIERE_ARCHIVO', 'valores', jsonb_build_array('S', 'N'), 'default', 'N',
            'motivo', 'Si el estudiante debe adjuntar un archivo'),
        'requiereTexto', jsonb_build_object(
            'requerido', FALSE, 'campo', 'REQUIERE_TEXTO', 'valores', jsonb_build_array('S', 'N'), 'default', 'N',
            'motivo', 'Si el estudiante debe escribir una respuesta en texto'));
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_otro_campos_disponibles(VARCHAR)
    IS 'Bloque `campos` de la entrada OTRO de instrumentosPermitidos: lo que pide el instrumento "Otro (personalizado)" (TACTIVIDAD_OTRO + campos libres de TACTIVIDAD). tipoEvidencia: catalogo TIPO_EVIDENCIA_OTRO. metodoValoracion: los INSTRUMENTO_EVALUACION distintos de OTRO que fn_instrumento_permitido_por_tipo_evaluacion admite para el TIPO_EVALUACION del referente, con `variantes` de escala (fn_escala_variantes_permitidas); es la misma regla que fn_actividad_otro_definir hace cumplir al delegar en fn_actividad_*_definir. definicion: la forma segun el metodo. descripcionInstrumento / requiereArchivo / requiereTexto: columnas de TACTIVIDAD que captura el POST/PATCH. El front decide por VALOR: los pk no son estables entre entornos.';

-- Misma firma que V453: CREATE OR REPLACE. Solo se agrega `campos` (aditivo).
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_instrumentos_campos_disponibles(
    p_tipo_evaluacion VARCHAR
) RETURNS JSONB
LANGUAGE sql STABLE AS $$
    SELECT COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
                   'pk',        lv.PK_LISTA_VALOR,
                   'valor',     lv.VALOR,
                   'etiqueta',  lv.NOMBRE,
                   'nombre',    lv.NOMBRE,
                   'variantes', CASE WHEN lv.VALOR = 'ESCALA_VALORACION'
                                     THEN academico_test.fn_escala_variantes_permitidas(p_tipo_evaluacion)
                                     ELSE '[]'::jsonb END,
                   'campos',    CASE WHEN lv.VALOR = 'OTRO'
                                     THEN academico_test.fn_actividad_otro_campos_disponibles(p_tipo_evaluacion)
                                     ELSE NULL END)
                   ORDER BY lv.NOMBRE)
          FROM academico_test.TLISTA_VALOR lv
         WHERE lv.CATEGORIA = 'INSTRUMENTO_EVALUACION'
           AND lv.ACTIVE = TRUE
           AND academico_test.fn_instrumento_permitido_por_tipo_evaluacion(lv.VALOR, p_tipo_evaluacion)
    ), '[]'::jsonb);
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_instrumentos_campos_disponibles(VARCHAR)
    IS 'instrumentosPermitidos de campos_disponibles.evaluacion, unico para las tres configuraciones (por actividad, por unidad y por contexto): los INSTRUMENTO_EVALUACION que fn_instrumento_permitido_por_tipo_evaluacion admite para el TIPO_EVALUACION, como [{pk, valor, etiqueta, nombre, variantes, campos}] ordenados por nombre. variantes: para ESCALA_VALORACION, las de TIPO_ESCALA que ese tipo admite; [] en los demas. campos: solo en OTRO, lo que pide el instrumento personalizado (fn_actividad_otro_campos_disponibles); NULL en los demas. El front debe decidir por VALOR.';

-- ---------------------------------------------------------------------------
-- 2) Helpers por sumativo. El nombre del parametro cambia: DROP + CREATE.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_actividad_recuperacion_campos_disponibles(BOOLEAN, VARCHAR);
CREATE FUNCTION academico_test.fn_actividad_recuperacion_campos_disponibles(
    p_evaluativo   BOOLEAN,
    p_es_sumativo  VARCHAR DEFAULT 'S'
)
RETURNS JSONB
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_sum     VARCHAR := UPPER(TRIM(COALESCE(p_es_sumativo, 'S')));
    v_visible BOOLEAN := COALESCE(p_evaluativo, FALSE) AND v_sum <> 'N';
BEGIN
    RETURN jsonb_build_object(
        'visible',   v_visible,
        'requerido', FALSE,
        'motivo', CASE
            WHEN v_sum = 'N' THEN 'La actividad se creara como NO sumativa; una actividad de recuperacion debe ser sumativa'
            WHEN NOT COALESCE(p_evaluativo, FALSE) THEN 'El referente curricular no es EVALUATIVO: no hay nota que recuperar'
            ELSE 'Opcional: la actividad puede registrarse como recuperacion de otra actividad o de la nota final'
        END,
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
            'valorPonderacionRequeridoSi',   'tipoCalculo = PONDERADO',
            'valorPonderacionRango',         jsonb_build_object('min', 0, 'max', 100)));
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_recuperacion_campos_disponibles(BOOLEAN, VARCHAR)
    IS 'La seccion "Es una recuperacion" del formulario de actividad: {visible, requerido, motivo, catalogos:{destino, tipoAplicacion, tipoCalculo}, reglas}. Punto unico de las tres configuraciones. visible exige DOS gates: referente EVALUATIVO y ES_SUMATIVO distinto de N -- fn_actividad_crear/_actualizar rechazan con 22023 "una actividad de recuperacion debe ser evaluativa" (ES_EVALUATIVA=N en TACTIVIDAD), asi que ofrecerla en una no sumativa seria ofrecer lo que la escritura rechaza. requerido siempre FALSE. Catalogos como {pk, valor, nombre}: el front decide por VALOR. reglas expone las condicionales de fn_actividad_recuperacion_configurar.';

DROP FUNCTION IF EXISTS academico_test.fn_actividad_ponderacion_campos_disponibles(VARCHAR, BOOLEAN, VARCHAR);
CREATE FUNCTION academico_test.fn_actividad_ponderacion_campos_disponibles(
    p_es_sumativo  VARCHAR,
    p_tiene_unidad BOOLEAN,
    p_modo_calculo VARCHAR
) RETURNS JSONB
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN UPPER(TRIM(COALESCE(p_es_sumativo, 'S'))) = 'N' THEN jsonb_build_object(
            'visible', FALSE, 'requerido', FALSE, 'modo', NULL, 'valor', 0,
            'motivo', 'La actividad no es sumativa: pesa 0 frente a la unidad; no enviar PONDERACION ni NOTA_MAXIMA')
        WHEN NOT COALESCE(p_tiene_unidad, FALSE) THEN jsonb_build_object(
            'visible', FALSE, 'requerido', FALSE, 'modo', NULL,
            'motivo', 'La actividad aun no pertenece a una unidad; la ponderacion la define el metodo de calculo de la unidad')
        WHEN p_modo_calculo = 'PONDERAR' THEN jsonb_build_object(
            'visible', TRUE, 'requerido', TRUE, 'modo', 'PORCENTAJE',
            'campo', 'PONDERACION', 'autocalculado', FALSE,
            'motivo', 'la unidad pondera sus actividades')
        WHEN p_modo_calculo = 'SUMATORIA' THEN jsonb_build_object(
            'visible', TRUE, 'requerido', TRUE, 'modo', 'PUNTAJE',
            'campo', 'NOTA_MAXIMA', 'autocalculado', TRUE,
            'motivo', 'la unidad suma puntajes; el % lo calcula el sistema')
        WHEN p_modo_calculo = 'PROMEDIAR' THEN jsonb_build_object(
            'visible', FALSE, 'requerido', FALSE, 'modo', NULL,
            'motivo', 'la unidad promedia, la ponderacion no aplica')
        ELSE jsonb_build_object(
            'visible', FALSE, 'requerido', FALSE, 'modo', NULL,
            'motivo', 'la unidad aun no tiene metodo de calculo elegido')
    END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_ponderacion_campos_disponibles(VARCHAR, BOOLEAN, VARCHAR)
    IS 'Bloque ponderacion del formulario de actividad, por metodo de calculo de la unidad (fn_unidad_calculo_definitiva_modo): PONDERAR -> PORCENTAJE sobre PONDERACION; SUMATORIA -> PUNTAJE sobre NOTA_MAXIMA con autocalculado; PROMEDIAR o sin metodo -> no visible. Con ES_SUMATIVO = N no aplica y se informa valor 0 (la actividad pesa cero frente a su unidad): fn_actividad_crear/_actualizar rechazan PONDERACION cuando ES_EVALUATIVA = N, asi que el front no la envia.';

-- ---------------------------------------------------------------------------
-- 3) Las tres configuraciones: la evaluacion ya no depende del sumativo.
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
    v_modo_calculo      VARCHAR;
    v_tipo              VARCHAR;
BEGIN
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', NULL, NULL, NULL, p_pk_tactividad
    );

    -- TACTIVIDAD.ES_EVALUATIVA es la columna que persiste "sumativa" (S/N).
    SELECT a.TITULO, a.FK_TUNIDAD, UPPER(TRIM(COALESCE(a.ES_EVALUATIVA::VARCHAR, 'S')))
      INTO v_titulo, v_fk_tunidad, v_es_sumativo
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

    v_instrumentos := CASE
        WHEN NOT COALESCE(v_evaluacion_req, FALSE) THEN '[]'::jsonb
        ELSE academico_test.fn_actividad_instrumentos_campos_disponibles(v_tipo)
    END;

    RETURN jsonb_build_object(
        'criterio', academico_test.fn_actividad_criterio_campos_disponibles(
                        v_es_preescolar, v_fk_tunidad IS NOT NULL),
        'evaluacion', jsonb_build_object(
            'visible',  v_evaluacion_req,
            'requerido', v_evaluacion_req,
            'motivo', CASE
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
                            v_evaluacion_req, v_es_sumativo)
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

    v_instrumentos := CASE
        WHEN NOT COALESCE(v_evaluativo, FALSE) THEN '[]'::jsonb
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
                    WHEN NOT COALESCE(v_evaluativo, FALSE)
                        THEN 'El referente curricular de la unidad no es EVALUATIVO (o la unidad no tiene referente)'
                    ELSE 'El referente curricular de la unidad es EVALUATIVO: la actividad requiere instrumento de evaluacion'
                END,
                'tipoEvaluacion', v_tipo,
                'instrumentosPermitidos', v_instrumentos),
            'ponderacion', academico_test.fn_actividad_ponderacion_campos_disponibles(
                               v_es_sumativo, TRUE, v_modo),
            'recuperacion', academico_test.fn_actividad_recuperacion_campos_disponibles(
                                COALESCE(v_evaluativo, FALSE), v_es_sumativo))
    );
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_configuracion_actividad(BIGINT, BIGINT, VARCHAR)
    IS 'Que pintar en el formulario de NUEVA ACTIVIDAD para la unidad escogida, antes de crearla: {pkTunidad, unidad, nivelEnsenanza, esSumativoConsultado, campos_disponibles:{criterio, evaluacion, ponderacion, recuperacion}}. p_es_sumativo (S|N, default S) es lo que el usuario acaba de marcar: con N solo se apagan recuperacion y ponderacion; la evaluacion (instrumentosPermitidos, con `campos` en OTRO) sale del referente de la unidad igual que con S. Gate VER sobre PLANEADOR + alcance por la unidad; P0002 si no existe o esta inactiva.';

DROP FUNCTION IF EXISTS academico_test.fn_actividad_configuracion_contexto(BIGINT, BIGINT, BIGINT, BIGINT, VARCHAR);
CREATE FUNCTION academico_test.fn_actividad_configuracion_contexto(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tgrupo              BIGINT,
    p_fk_tasignatura         BIGINT,
    p_fk_tunidad             BIGINT DEFAULT NULL,
    p_es_sumativo            VARCHAR DEFAULT 'S'
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

    v_instrumentos := CASE
        WHEN NOT COALESCE(v_evaluativo, FALSE) THEN '[]'::jsonb
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
                                COALESCE(v_evaluativo, FALSE), v_es_sumativo))
    );
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_configuracion_contexto(BIGINT, BIGINT, BIGINT, BIGINT, VARCHAR)
    IS 'Que pintar en el formulario de actividad a partir de grupo + asignatura, con unidad OPCIONAL (con unidad manda la unidad; sin ella el referente se deriva con fn_unidad_referente_aplicable). Devuelve el contexto resuelto, programacion (limites de fechas, semanas y duracion) y campos_disponibles con la misma forma que las otras dos configuraciones. p_es_sumativo (S|N, default S) es lo que el usuario acaba de marcar: con N solo se apagan recuperacion y ponderacion; la evaluacion (instrumentosPermitidos, con `campos` en OTRO) sale del referente igual que con S. Gate VER sobre PLANEADOR + alcance por el grupo; P0002 si el grupo, la asignatura o la unidad no existen.';

-- ---------------------------------------------------------------------------
-- 4) Filas de public.query: el parametro pasa a QUERY.ES_SUMATIVO. Las filas
--    ya existen (ON CONFLICT DO NOTHING en V282/V422): se reconcilian con UPDATE.
-- ---------------------------------------------------------------------------
UPDATE public.query q
   SET query = 'SELECT academico_test.fn_actividad_configuracion_contexto(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.GRUPO AS BIGINT),
    CAST(:QUERY.ASIGNATURA AS BIGINT),
    CAST(:QUERY.UNIDAD AS BIGINT),
    COALESCE(CAST(:QUERY.ES_SUMATIVO AS VARCHAR), ''S'')
) AS configuracion;',
       param_types = '{"QUERY.GRUPO": "BIGINT", "QUERY.ASIGNATURA": "BIGINT", "QUERY.UNIDAD": "BIGINT", "QUERY.ES_SUMATIVO": "VARCHAR"}'::jsonb,
       detail = 'Que pintar en el formulario de actividad a partir de los DOS filtros de la pantalla: ?grupo= y ?asignatura= (obligatorios), con ?unidad= OPCIONAL. Con unidad manda la unidad (referente y metodo de calculo); sin unidad el referente se deriva del grado + asignatura (fn_unidad_referente_aplicable). origenConfiguracion dice cual camino se uso (CONTEXTO o UNIDAD). Devuelve el contexto resuelto (grupo, grado, nivelEnsenanza, asignatura, referente {pk, nombre}), programacion (limites de fechaInicio/fechaCierre, semanaCronograma, duracionEstimada e intensidadHoraria a partir del periodo academico del grado y del horario) y campos_disponibles con la MISMA forma que GET /planeador/unidades/:ID/configuracion-actividad y GET /planeador/actividades/:ID/configuracion: criterio {visible, requerido, motivo}, evaluacion {visible, requerido, motivo, tipoEvaluacion, instrumentosPermitidos:[{pk, valor, nombre, variantes, campos}]}, ponderacion {visible, requerido, modo, campo?, autocalculado?, motivo} y recuperacion {visible, requerido, motivo, catalogos, reglas}. ?ES_SUMATIVO=S|N (default S: si no se envia, se responde la configuracion de una actividad sumativa) es lo que el usuario acaba de marcar en el formulario; con N SOLO se apagan recuperacion (una recuperacion debe ser sumativa) y ponderacion (la escritura la rechaza); la seccion de evaluacion y sus instrumentosPermitidos salen del referente igual que con S. En instrumentosPermitidos la entrada OTRO trae `campos`: tipoEvidencia {catalogo TIPO_EVIDENCIA_OTRO}, metodoValoracion {catalogo: los demas instrumentos que admite el tipo de evaluacion del referente, con variantes de escala}, definicion {formaPorMetodo}, descripcionInstrumento, requiereArchivo y requiereTexto; los demas instrumentos traen campos = null. El front decide por VALOR: los pk no son estables entre entornos. El arbol de enunciados y evidencias NO viene aqui: GET /planeador/referente-curricular?grado=&asignatura=. Gate VER sobre PLANEADOR + alcance por el grupo; 404 (P0002) si el grupo, la asignatura o la unidad no existen.'
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/actividades/configuracion'
   AND q.http_method     = 'GET';

UPDATE public.query q
   SET query = 'SELECT academico_test.fn_unidad_configuracion_actividad(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    COALESCE(CAST(:QUERY.ES_SUMATIVO AS VARCHAR), ''S'')
) AS configuracion;',
       param_types = '{"PARAM.ID": "BIGINT", "QUERY.ES_SUMATIVO": "VARCHAR"}'::jsonb,
       detail = 'Que pintar en el formulario de NUEVA ACTIVIDAD para la unidad escogida, ANTES de crearla. :ID = PK_TUNIDAD. Devuelve campos_disponibles con la MISMA forma que GET /planeador/actividades/configuracion y GET /planeador/actividades/:ID/configuracion: criterio {visible, requerido, motivo} (visible=false solo en Preescolar), evaluacion {visible, requerido, motivo, tipoEvaluacion, instrumentosPermitidos:[{pk, valor, nombre, variantes, campos}]} segun el referente de la unidad y su TIPO_EVALUACION, ponderacion {visible, requerido, modo, campo?, autocalculado?, motivo} segun el metodo de calculo de la unidad, y recuperacion {visible, requerido, motivo, catalogos, reglas}. ?ES_SUMATIVO=S|N (default S: si no se envia, se responde la configuracion de una actividad sumativa) es lo unico que no sale de la unidad; con N SOLO se apagan recuperacion y ponderacion, la evaluacion se ofrece igual que con S. En instrumentosPermitidos la entrada OTRO trae `campos` (tipoEvidencia, metodoValoracion = los demas instrumentos que admite el referente, definicion, descripcionInstrumento, requiereArchivo, requiereTexto); los demas traen campos = null. El front decide por VALOR. El arbol de enunciados y evidencias se pide a GET /planeador/referente-curricular?grado=&asignatura= y los ya relacionados a GET /planeador/unidades/:ID/referente. Sin unidad, usar GET /planeador/actividades/configuracion?grupo=&asignatura=. Gate VER sobre PLANEADOR + alcance por la unidad; 404 (P0002) si la unidad no existe o esta inactiva.'
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/unidades/:ID/configuracion-actividad'
   AND q.http_method     = 'GET';
