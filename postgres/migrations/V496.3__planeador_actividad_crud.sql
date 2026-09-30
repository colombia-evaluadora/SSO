-- V496.3 — Planeador, actividad: funciones de endpoint (3 de 4).
--
-- Qué hace: cada escritura de /planeador/actividades* queda como wrapper
-- delgado en este orden: existencia (P0002) → estado (22023) → alcance
-- (42501, en origen y en destino si la mueve) → propiedad (42501, Regla 25)
-- → edición bloqueada por resultados (23503, Regla 37) → etiqueta de
-- auditoría → núcleo _interno de V496.2. Antes materiales y adaptaciones no
-- tenían gate y solo el alta declaraba etiqueta.
-- Depende de: V496.1, V496.2, V277 (fn_planeador_assert_alcance), V26/V276
-- (fn_audit_declarar), V479 (fn_actividad_sede), V482 (eliminar_interno).

SET search_path TO academico_test, public;

-- Pasos comunes a toda escritura sobre una actividad existente.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_assert_escritura(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT,
    p_accion                 VARCHAR,
    p_validar_editable       BOOLEAN DEFAULT TRUE
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_actividad_validar_existente(p_pk_tactividad);
    PERFORM academico_test.fn_actividad_validar_activa(p_pk_tactividad);
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, p_accion, NULL, NULL, NULL, p_pk_tactividad);
    PERFORM academico_test.fn_actividad_assert_propietario(p_pk_usuario_solicitante, p_pk_tactividad);
    IF p_validar_editable THEN
        PERFORM academico_test.fn_actividad_validar_editable(p_pk_tactividad);
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_auditar(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT,
    p_etiqueta               TEXT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante, p_etiqueta, NULL,
        (SELECT academico_test.fn_actividad_sede(FK_TGRUPO, FK_TUNIDAD)
           FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_pk_tactividad));
END;
$$;

-- ---------------------------------------------------------------------------
-- Actividad
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_actividad_crear(
    BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, VARCHAR, BIGINT, BIGINT, NUMERIC, DATE, DATE, NUMERIC, VARCHAR,
    BIGINT, VARCHAR, academico_test.bool_sn, BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, NUMERIC, NUMERIC,
    academico_test.bool_sn, academico_test.bool_sn, academico_test.bool_sn, academico_test.bool_sn, VARCHAR,
    JSONB, JSONB, BIGINT[], BOOLEAN, JSONB, BIGINT[], BIGINT[]);

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_crear(
    p_pk_usuario_solicitante            BIGINT,
    p_titulo                            VARCHAR(250),
    p_fk_tasignatura                    BIGINT,
    p_fk_tlv_tipo_actividad             BIGINT,
    p_fk_tlv_jerarquia                  BIGINT,
    p_descripcion                       VARCHAR(4000) DEFAULT NULL,
    p_fk_tgrupo                         BIGINT        DEFAULT NULL,
    p_fk_tunidad                        BIGINT        DEFAULT NULL,
    p_ponderacion                       NUMERIC       DEFAULT NULL,
    p_fecha_inicio                      DATE          DEFAULT NULL,
    p_fecha_cierre                      DATE          DEFAULT NULL,
    p_duracion_estimada                 NUMERIC       DEFAULT NULL,
    p_semana_cronograma                 VARCHAR(50)   DEFAULT NULL,
    p_fk_tlv_modalidad                  BIGINT        DEFAULT NULL,
    p_material_requerido                VARCHAR(4000) DEFAULT NULL,
    p_es_evaluativa                     academico_test.bool_sn DEFAULT NULL,
    p_fk_tlv_instrumento_evaluacion     BIGINT        DEFAULT NULL,
    p_descripcion_instrumento           VARCHAR(4000) DEFAULT NULL,
    p_fk_tlv_tipo_evidencia             BIGINT        DEFAULT NULL,
    p_fk_tlv_metodo_valoracion          BIGINT        DEFAULT NULL,
    p_fk_tlv_tipo_calculo               BIGINT        DEFAULT NULL,
    p_influencia                        NUMERIC       DEFAULT NULL,
    p_nota_maxima                       NUMERIC       DEFAULT NULL,
    p_requiere_archivo                  academico_test.bool_sn DEFAULT 'N',
    p_requiere_texto                    academico_test.bool_sn DEFAULT 'N',
    p_genera_evidencias                 academico_test.bool_sn DEFAULT 'N',
    p_requiere_validacion_coordinador   academico_test.bool_sn DEFAULT 'N',
    p_observaciones_docente             VARCHAR(4000) DEFAULT NULL,
    p_materiales                        JSONB         DEFAULT NULL,
    p_adaptaciones                      JSONB         DEFAULT NULL,
    p_fk_tmatriculas                    BIGINT[]      DEFAULT NULL,
    p_asignar_todo_el_grupo             BOOLEAN       DEFAULT FALSE,
    p_recuperacion                      JSONB         DEFAULT NULL,
    p_evidencias                        BIGINT[]      DEFAULT NULL,
    p_criterios                         BIGINT[]      DEFAULT NULL,
    p_exigir_minimos                    BOOLEAN       DEFAULT TRUE
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_recuperar BIGINT := NULLIF(p_recuperacion->>'fkActividadRecuperar', '')::BIGINT;
BEGIN
    -- La actividad sin grupo ni unidad no tiene sede contra la que comprobar
    -- alcance; vincularla después sí lo comprueba.
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'CREAR', p_fk_tgrupo, NULL, p_fk_tunidad,
        NULL, p_permitir_sin_ancla => TRUE);
    IF v_recuperar IS NOT NULL THEN
        PERFORM academico_test.fn_actividad_validar_existente(v_recuperar);
        PERFORM academico_test.fn_planeador_assert_alcance(
            p_pk_usuario_solicitante, 'VER', NULL, NULL, NULL, v_recuperar);
    END IF;

    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Creación de la actividad %s', TRIM(p_titulo)), NULL,
        academico_test.fn_actividad_sede(p_fk_tgrupo, p_fk_tunidad));

    RETURN academico_test.fn_actividad_crear_interno(
        p_pk_usuario_solicitante, p_titulo, p_fk_tasignatura, p_fk_tlv_tipo_actividad,
        p_fk_tlv_jerarquia, p_descripcion, p_fk_tgrupo, p_fk_tunidad, p_ponderacion,
        p_fecha_inicio, p_fecha_cierre, p_duracion_estimada, p_semana_cronograma,
        p_fk_tlv_modalidad, p_material_requerido, p_es_evaluativa,
        p_fk_tlv_instrumento_evaluacion, p_descripcion_instrumento,
        p_fk_tlv_tipo_evidencia, p_fk_tlv_metodo_valoracion, p_fk_tlv_tipo_calculo,
        p_influencia, p_nota_maxima, p_requiere_archivo, p_requiere_texto,
        p_genera_evidencias, p_requiere_validacion_coordinador, p_observaciones_docente,
        p_materiales, p_adaptaciones, p_fk_tmatriculas, p_asignar_todo_el_grupo,
        p_recuperacion, p_evidencias, p_criterios, p_exigir_minimos);
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_actualizar(
    p_pk_usuario_solicitante            BIGINT,
    p_pk_tactividad                     BIGINT,
    p_titulo                            VARCHAR(250)  DEFAULT NULL,
    p_descripcion                       VARCHAR(4000) DEFAULT NULL,
    p_fk_tasignatura                    BIGINT        DEFAULT NULL,
    p_fk_tgrupo                         BIGINT        DEFAULT NULL,
    p_fk_tunidad                        BIGINT        DEFAULT NULL,
    p_ponderacion                       NUMERIC       DEFAULT NULL,
    p_desvincular_unidad                BOOLEAN       DEFAULT FALSE,
    p_fk_tlv_tipo_actividad             BIGINT        DEFAULT NULL,
    p_fecha_inicio                      DATE          DEFAULT NULL,
    p_fecha_cierre                      DATE          DEFAULT NULL,
    p_duracion_estimada                 NUMERIC       DEFAULT NULL,
    p_semana_cronograma                 VARCHAR(50)   DEFAULT NULL,
    p_fk_tlv_modalidad                  BIGINT        DEFAULT NULL,
    p_material_requerido                VARCHAR(4000) DEFAULT NULL,
    p_es_evaluativa                     academico_test.bool_sn DEFAULT NULL,
    p_fk_tlv_instrumento_evaluacion     BIGINT        DEFAULT NULL,
    p_descripcion_instrumento           VARCHAR(4000) DEFAULT NULL,
    p_fk_tlv_tipo_evidencia             BIGINT        DEFAULT NULL,
    p_fk_tlv_metodo_valoracion          BIGINT        DEFAULT NULL,
    p_fk_tlv_tipo_calculo               BIGINT        DEFAULT NULL,
    p_influencia                        NUMERIC       DEFAULT NULL,
    p_nota_maxima                       NUMERIC       DEFAULT NULL,
    p_requiere_archivo                  academico_test.bool_sn DEFAULT NULL,
    p_requiere_texto                    academico_test.bool_sn DEFAULT NULL,
    p_genera_evidencias                 academico_test.bool_sn DEFAULT NULL,
    p_requiere_validacion_coordinador   academico_test.bool_sn DEFAULT NULL,
    p_observaciones_docente             VARCHAR(4000) DEFAULT NULL,
    p_materiales                        JSONB         DEFAULT NULL,
    p_adaptaciones                      JSONB         DEFAULT NULL,
    p_fk_tmatriculas                    BIGINT[]      DEFAULT NULL,
    p_asignar_todo_el_grupo             BOOLEAN       DEFAULT FALSE,
    p_recuperacion                      JSONB         DEFAULT NULL,
    p_quitar_recuperacion               BOOLEAN       DEFAULT FALSE,
    p_evidencias                        BIGINT[]      DEFAULT NULL,
    p_criterios                         BIGINT[]      DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_recuperar BIGINT := NULLIF(p_recuperacion->>'fkActividadRecuperar', '')::BIGINT;
BEGIN
    -- Alcance sobre donde está hoy; si la mueve, también sobre adonde va:
    -- con solo el destino se podía traer una actividad de una sede ajena.
    PERFORM academico_test.fn_actividad_assert_escritura(p_pk_usuario_solicitante, p_pk_tactividad, 'EDITAR');
    IF p_fk_tgrupo IS NOT NULL OR p_fk_tunidad IS NOT NULL THEN
        PERFORM academico_test.fn_planeador_assert_alcance(
            p_pk_usuario_solicitante, 'EDITAR', p_fk_tgrupo, NULL, p_fk_tunidad, p_pk_tactividad);
    END IF;
    IF v_recuperar IS NOT NULL THEN
        PERFORM academico_test.fn_actividad_validar_existente(v_recuperar);
        PERFORM academico_test.fn_planeador_assert_alcance(
            p_pk_usuario_solicitante, 'VER', NULL, NULL, NULL, v_recuperar);
    END IF;

    PERFORM academico_test.fn_actividad_auditar(p_pk_usuario_solicitante, p_pk_tactividad,
        format('Actualización de la actividad %s',
               COALESCE(NULLIF(TRIM(p_titulo), ''),
                        (SELECT TITULO FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_pk_tactividad))));

    RETURN academico_test.fn_actividad_actualizar_interno(
        p_pk_usuario_solicitante, p_pk_tactividad, p_titulo, p_descripcion,
        p_fk_tasignatura, p_fk_tgrupo, p_fk_tunidad, p_ponderacion, p_desvincular_unidad,
        p_fk_tlv_tipo_actividad, p_fecha_inicio, p_fecha_cierre, p_duracion_estimada,
        p_semana_cronograma, p_fk_tlv_modalidad, p_material_requerido, p_es_evaluativa,
        p_fk_tlv_instrumento_evaluacion, p_descripcion_instrumento, p_fk_tlv_tipo_evidencia,
        p_fk_tlv_metodo_valoracion, p_fk_tlv_tipo_calculo, p_influencia, p_nota_maxima,
        p_requiere_archivo, p_requiere_texto, p_genera_evidencias,
        p_requiere_validacion_coordinador, p_observaciones_docente, p_materiales,
        p_adaptaciones, p_fk_tmatriculas, p_asignar_todo_el_grupo, p_recuperacion,
        p_quitar_recuperacion, p_evidencias, p_criterios);
END;
$$;

-- Regla 38: con resultados, asistencias o un refuerzo que la recupera no se
-- elimina (23503, después del gate: a quien no puede borrar no se le cuenta
-- qué hay dentro).
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_eliminar(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_actividad_assert_escritura(p_pk_usuario_solicitante, p_pk_tactividad, 'ELIMINAR', FALSE);
    PERFORM academico_test.fn_actividad_validar_eliminable(p_pk_tactividad);

    PERFORM academico_test.fn_actividad_auditar(p_pk_usuario_solicitante, p_pk_tactividad,
        format('Eliminación de la actividad %s',
               (SELECT TITULO FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_pk_tactividad)));

    RETURN academico_test.fn_actividad_eliminar_interno(p_pk_tactividad, p_pk_usuario_solicitante);
END;
$$;

-- ---------------------------------------------------------------------------
-- Evidencias y criterios
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_evidencia_relacionar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tactividad          BIGINT,
    p_fk_referente_enunciado BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_actividad_assert_escritura(p_pk_usuario_solicitante, p_fk_tactividad, 'EDITAR');
    PERFORM academico_test.fn_actividad_auditar(p_pk_usuario_solicitante, p_fk_tactividad,
        format('%s marcada en la actividad %s',
               COALESCE(academico_test.fn_unidad_enunciado_etiqueta(p_fk_referente_enunciado), 'Evidencia'),
               (SELECT TITULO FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_fk_tactividad)));
    RETURN academico_test.fn_actividad_evidencia_relacionar_interno(
        p_pk_usuario_solicitante, p_fk_tactividad, p_fk_referente_enunciado);
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_evidencia_quitar(
    p_pk_usuario_solicitante  BIGINT,
    p_pk_tactividad_evidencia BIGINT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_actividad BIGINT;
    v_enunciado BIGINT;
BEGIN
    SELECT FK_TACTIVIDAD, FK_REFERENTE_ENUNCIADO INTO v_actividad, v_enunciado
      FROM academico_test.TACTIVIDAD_EVIDENCIA WHERE PK_TACTIVIDAD_EVIDENCIA = p_pk_tactividad_evidencia;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontró la evidencia marcada en la actividad' USING ERRCODE = 'P0002';
    END IF;
    PERFORM academico_test.fn_actividad_assert_escritura(p_pk_usuario_solicitante, v_actividad, 'EDITAR');
    PERFORM academico_test.fn_actividad_auditar(p_pk_usuario_solicitante, v_actividad,
        format('%s desmarcada de la actividad %s',
               COALESCE(academico_test.fn_unidad_enunciado_etiqueta(v_enunciado), 'Evidencia'),
               (SELECT TITULO FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = v_actividad)));
    RETURN academico_test.fn_actividad_evidencia_quitar_interno(p_pk_usuario_solicitante, p_pk_tactividad_evidencia);
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_criterio_relacionar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tactividad          BIGINT,
    p_fk_tcriterio_unidad    BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_actividad_assert_escritura(p_pk_usuario_solicitante, p_fk_tactividad, 'EDITAR');
    PERFORM academico_test.fn_actividad_auditar(p_pk_usuario_solicitante, p_fk_tactividad,
        format('Criterio %s asociado a la actividad %s',
               COALESCE((SELECT DESCRIPCION FROM academico_test.TCRITERIO_UNIDAD WHERE PK_TCRITERIO_UNIDAD = p_fk_tcriterio_unidad), ''),
               (SELECT TITULO FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_fk_tactividad)));
    RETURN academico_test.fn_actividad_criterio_relacionar_interno(
        p_pk_usuario_solicitante, p_fk_tactividad, p_fk_tcriterio_unidad);
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_criterio_quitar(
    p_pk_usuario_solicitante        BIGINT,
    p_pk_tactividad_criterio_unidad BIGINT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_actividad BIGINT;
    v_criterio  BIGINT;
BEGIN
    SELECT FK_TACTIVIDAD, FK_TCRITERIO_UNIDAD INTO v_actividad, v_criterio
      FROM academico_test.TACTIVIDAD_CRITERIO_UNIDAD WHERE PK_TACTIVIDAD_CRITERIO_UNIDAD = p_pk_tactividad_criterio_unidad;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontró el criterio asociado a la actividad' USING ERRCODE = 'P0002';
    END IF;
    PERFORM academico_test.fn_actividad_assert_escritura(p_pk_usuario_solicitante, v_actividad, 'EDITAR');
    PERFORM academico_test.fn_actividad_auditar(p_pk_usuario_solicitante, v_actividad,
        format('Criterio %s retirado de la actividad %s',
               COALESCE((SELECT DESCRIPCION FROM academico_test.TCRITERIO_UNIDAD WHERE PK_TCRITERIO_UNIDAD = v_criterio), ''),
               (SELECT TITULO FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = v_actividad)));
    RETURN academico_test.fn_actividad_criterio_quitar_interno(p_pk_usuario_solicitante, p_pk_tactividad_criterio_unidad);
END;
$$;

-- ---------------------------------------------------------------------------
-- Estudiantes, materiales y adaptaciones
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_estudiantes_set(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT,
    p_fk_tmatriculas         BIGINT[] DEFAULT NULL,
    p_todo_el_grupo          BOOLEAN  DEFAULT FALSE
)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_total INT;
BEGIN
    PERFORM academico_test.fn_actividad_assert_escritura(p_pk_usuario_solicitante, p_pk_tactividad, 'EDITAR');
    PERFORM academico_test.fn_actividad_auditar(p_pk_usuario_solicitante, p_pk_tactividad,
        format('Estudiantes de la actividad %s',
               (SELECT TITULO FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_pk_tactividad)));
    v_total := academico_test.fn_actividad_estudiantes_asignar_interno(
        p_pk_usuario_solicitante, p_pk_tactividad, p_fk_tmatriculas, COALESCE(p_todo_el_grupo, FALSE));
    IF p_fk_tmatriculas IS NOT NULL OR COALESCE(p_todo_el_grupo, FALSE) THEN
        PERFORM academico_test.fn_actividad_validar_estudiantes_minimo(p_pk_tactividad);
    END IF;
    RETURN v_total;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_material_reemplazar(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT,
    p_materiales             JSONB
)
RETURNS INT
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_actividad_assert_escritura(p_pk_usuario_solicitante, p_pk_tactividad, 'EDITAR');
    PERFORM academico_test.fn_actividad_auditar(p_pk_usuario_solicitante, p_pk_tactividad,
        format('Materiales de apoyo de la actividad %s',
               (SELECT TITULO FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_pk_tactividad)));
    RETURN academico_test.fn_actividad_material_reemplazar_interno(
        p_pk_usuario_solicitante, p_pk_tactividad, p_materiales);
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_adaptacion_reemplazar(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT,
    p_adaptaciones           JSONB
)
RETURNS INT
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_actividad_assert_escritura(p_pk_usuario_solicitante, p_pk_tactividad, 'EDITAR');
    PERFORM academico_test.fn_actividad_auditar(p_pk_usuario_solicitante, p_pk_tactividad,
        format('Adaptaciones curriculares de la actividad %s',
               (SELECT TITULO FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_pk_tactividad)));
    RETURN academico_test.fn_actividad_adaptacion_reemplazar_interno(
        p_pk_usuario_solicitante, p_pk_tactividad, p_adaptaciones);
END;
$$;

-- Subida en un paso por file-service: el archivo ya existe cuando se llama y
-- aquí solo se decide si la actividad lo admite. Materiales y adaptaciones
-- comparten las mismas reglas.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_archivo_recibido(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT,
    p_fk_tarchivo            BIGINT,
    p_que                    VARCHAR
)
RETURNS BIGINT
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_actividad_assert_escritura(p_pk_usuario_solicitante, p_pk_tactividad, 'EDITAR');
    IF p_fk_tarchivo IS NULL THEN
        RAISE EXCEPTION 'No llegó ningún archivo para %: vuelva a adjuntarlo', p_que USING ERRCODE = '22023';
    END IF;
    PERFORM academico_test.fn_actividad_validar_archivo_existente(p_fk_tarchivo, p_que);
    RETURN p_fk_tarchivo;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_material_archivo_registrar(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT,
    p_fk_tarchivo            BIGINT
)
RETURNS BIGINT
LANGUAGE sql
AS $$
    SELECT academico_test.fn_actividad_archivo_recibido(
        p_pk_usuario_solicitante, p_pk_tactividad, p_fk_tarchivo, 'el material de apoyo');
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_adaptacion_archivo_registrar(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT,
    p_fk_tarchivo            BIGINT
)
RETURNS BIGINT
LANGUAGE sql
AS $$
    SELECT academico_test.fn_actividad_archivo_recibido(
        p_pk_usuario_solicitante, p_pk_tactividad, p_fk_tarchivo, 'la versión modificada del instrumento');
$$;

-- ---------------------------------------------------------------------------
-- Instrumento de evaluación (Bloque 5)
-- ---------------------------------------------------------------------------

-- Despacha a la definición de cada instrumento según el que tenga la actividad.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_instrumento_definir(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT,
    p_definicion             JSONB
)
RETURNS VARCHAR
LANGUAGE plpgsql
AS $$
DECLARE
    v_valor  VARCHAR;
    v_nombre VARCHAR;
    v_titulo VARCHAR;
BEGIN
    PERFORM academico_test.fn_actividad_assert_escritura(p_pk_usuario_solicitante, p_pk_tactividad, 'EDITAR');

    SELECT lv.VALOR, lv.NOMBRE, a.TITULO INTO v_valor, v_nombre, v_titulo
      FROM academico_test.TACTIVIDAD a
      LEFT JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = a.FK_TLV_INSTRUMENTO_EVALUACION
     WHERE a.PK_TACTIVIDAD = p_pk_tactividad;
    IF v_valor IS NULL OR v_valor NOT IN ('RUBRICA', 'LISTA_COTEJO', 'ESCALA_VALORACION', 'OTRO') THEN
        RAISE EXCEPTION 'La actividad "%" no tiene un instrumento de evaluación que se pueda configurar: elíjalo primero en el formulario de la actividad',
            v_titulo USING ERRCODE = '22023';
    END IF;

    PERFORM academico_test.fn_actividad_auditar(p_pk_usuario_solicitante, p_pk_tactividad,
        format('Definición del instrumento %s de la actividad %s', v_nombre, v_titulo));

    CASE v_valor
        WHEN 'RUBRICA' THEN
            PERFORM academico_test.fn_actividad_rubrica_definir(p_pk_usuario_solicitante, p_pk_tactividad, p_definicion);
        WHEN 'LISTA_COTEJO' THEN
            PERFORM academico_test.fn_actividad_cotejo_definir(p_pk_usuario_solicitante, p_pk_tactividad, p_definicion);
        WHEN 'ESCALA_VALORACION' THEN
            PERFORM academico_test.fn_actividad_escala_definir(p_pk_usuario_solicitante, p_pk_tactividad, p_definicion);
        ELSE
            -- p_definicion es el p_config de fn_actividad_otro_definir.
            PERFORM academico_test.fn_actividad_otro_definir(p_pk_usuario_solicitante, p_pk_tactividad, p_definicion);
    END CASE;
    RETURN v_valor;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_crear(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, VARCHAR, BIGINT, BIGINT, NUMERIC, DATE, DATE, NUMERIC, VARCHAR, BIGINT, VARCHAR, academico_test.bool_sn, BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, NUMERIC, NUMERIC, academico_test.bool_sn, academico_test.bool_sn, academico_test.bool_sn, academico_test.bool_sn, VARCHAR, JSONB, JSONB, BIGINT[], BOOLEAN, JSONB, BIGINT[], BIGINT[], BOOLEAN)
    IS 'POST /planeador/actividades. Wrapper: gate CREAR con alcance (la actividad sin grupo ni unidad pasa con solo capability), VER sobre la actividad a recuperar, etiqueta de auditoría y delega en fn_actividad_crear_interno. p_exigir_minimos lo apaga la importación.';
COMMENT ON FUNCTION academico_test.fn_actividad_actualizar(BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT, NUMERIC, BOOLEAN, BIGINT, DATE, DATE, NUMERIC, VARCHAR, BIGINT, VARCHAR, academico_test.bool_sn, BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, NUMERIC, NUMERIC, academico_test.bool_sn, academico_test.bool_sn, academico_test.bool_sn, academico_test.bool_sn, VARCHAR, JSONB, JSONB, BIGINT[], BOOLEAN, JSONB, BOOLEAN, BIGINT[], BIGINT[])
    IS 'PUT /planeador/actividades/:ID. Wrapper: existencia, estado, alcance EDITAR en origen y destino, propiedad (Regla 25), bloqueo por resultados (Regla 37), etiqueta de auditoría; delega en fn_actividad_actualizar_interno.';
COMMENT ON FUNCTION academico_test.fn_actividad_eliminar(BIGINT, BIGINT)
    IS 'PATCH /planeador/actividades/:ID (borrado lógico). Wrapper: existencia, estado, alcance ELIMINAR, propiedad (Regla 25), dependencias que lo impiden (Regla 38, 23503), etiqueta de auditoría; delega en fn_actividad_eliminar_interno.';
COMMENT ON FUNCTION academico_test.fn_actividad_evidencia_relacionar(BIGINT, BIGINT, BIGINT)
    IS 'POST /planeador/actividades/:ID/evidencias. Wrapper con gate EDITAR, propiedad, Regla 37 y etiqueta; la evidencia debe ser de un enunciado de la unidad de la actividad (fn_actividad_validar_evidencia).';
COMMENT ON FUNCTION academico_test.fn_actividad_evidencia_quitar(BIGINT, BIGINT)
    IS 'PATCH /planeador/actividades/evidencias/:ID. Wrapper con gate EDITAR, propiedad, Regla 37 y etiqueta; el mínimo de una evidencia lo impone el trigger diferido de V483.';
COMMENT ON FUNCTION academico_test.fn_actividad_criterio_relacionar(BIGINT, BIGINT, BIGINT)
    IS 'POST /planeador/actividades/:ID/criterios. Wrapper con gate EDITAR, propiedad, Regla 37 y etiqueta; el criterio debe ser de la rúbrica de la unidad de la actividad.';
COMMENT ON FUNCTION academico_test.fn_actividad_criterio_quitar(BIGINT, BIGINT)
    IS 'PATCH /planeador/actividades/criterios/:ID. Wrapper con gate EDITAR, propiedad, Regla 37 y etiqueta.';
COMMENT ON FUNCTION academico_test.fn_actividad_estudiantes_set(BIGINT, BIGINT, BIGINT[], BOOLEAN)
    IS 'PUT /planeador/actividades/:ID/estudiantes. Wrapper con gate EDITAR, propiedad, Regla 37 y etiqueta; reemplaza el set (fn_actividad_estudiantes_asignar_interno) y exige al menos un estudiante cuando el grupo tiene matrículas.';
COMMENT ON FUNCTION academico_test.fn_actividad_material_reemplazar(BIGINT, BIGINT, JSONB)
    IS 'PUT /planeador/actividades/:ID/materiales. Wrapper con gate EDITAR, propiedad, Regla 37 y etiqueta; reemplaza la lista (máximo 10, Regla 82).';
COMMENT ON FUNCTION academico_test.fn_actividad_adaptacion_reemplazar(BIGINT, BIGINT, JSONB)
    IS 'PUT /planeador/actividades/:ID/adaptaciones. Wrapper con gate EDITAR, propiedad, Regla 37 y etiqueta; reemplaza la lista (Bloque 6).';
COMMENT ON FUNCTION academico_test.fn_actividad_material_archivo_registrar(BIGINT, BIGINT, BIGINT)
    IS 'POST /planeador/actividades/:ID/materiales/archivo (multipart vía file-service). Devuelve el PK_TARCHIVO para usarlo como fkTarchivo en PUT :ID/materiales.';
COMMENT ON FUNCTION academico_test.fn_actividad_adaptacion_archivo_registrar(BIGINT, BIGINT, BIGINT)
    IS 'POST /planeador/actividades/:ID/adaptaciones/archivo (multipart vía file-service). Devuelve el PK_TARCHIVO para usarlo como fkTarchivo en PUT :ID/adaptaciones.';
COMMENT ON FUNCTION academico_test.fn_actividad_instrumento_definir(BIGINT, BIGINT, JSONB)
    IS 'PUT /planeador/actividades/:ID/instrumento. Wrapper con gate EDITAR, propiedad, Regla 37 y etiqueta; despacha a la definición de rúbrica, lista de cotejo, escala u Otro según el instrumento de la actividad.';
