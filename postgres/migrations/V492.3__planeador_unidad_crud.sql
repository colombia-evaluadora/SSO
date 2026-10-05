-- V492.3 — Planeador, unidad: funciones de endpoint (3 de 3).
--
-- Qué hace: cada función de /planeador/unidades* queda como wrapper delgado,
-- con las mismas firmas que ya usan las filas de public.query (V245), en este
-- orden: existencia (P0002) → estado (22023) → alcance (42501) → propiedad de
-- la unidad o del criterio (42501, Regla 25) → etiqueta de auditoría → núcleo
-- _interno de V492.2, que valida los datos y escribe (23503/23505/23514).
-- Las lecturas siguen el mismo corte, sin etiqueta. crear/actualizar reciben
-- CONTENIDOS_TITULOS (§4); actualizar devuelve las actividades afectadas
-- (Regla 28); desvincular y peso exigen ser autor de la actividad (25c).
-- Depende de: V492.1, V492.2, V277 (fn_planeador_assert_alcance), V26/V276
-- (fn_audit_declarar), V224 (fn_funcionario_actual), V496.1 (autor de actividad).

SET search_path TO academico_test, public;

-- Sede de la unidad (o del grado, en el alta) para la etiqueta de auditoría.
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_sede(p_pk_tunidad BIGINT, p_fk_tgrado BIGINT DEFAULT NULL)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT pa.FK_TSEDE
      FROM academico_test.TGRADO g
      JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
     WHERE g.PK_TGRADO = COALESCE(p_fk_tgrado,
                                  (SELECT u.FK_TGRADO FROM academico_test.TUNIDAD u WHERE u.PK_TUNIDAD = p_pk_tunidad));
$$;

-- ---------------------------------------------------------------------------
-- Unidad
-- ---------------------------------------------------------------------------

-- Firmas anteriores a CONTENIDOS_TITULOS (§4); el PUT cambia además el retorno.
DROP FUNCTION IF EXISTS academico_test.fn_unidad_crear(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, VARCHAR, BIGINT, VARCHAR[], VARCHAR[], BIGINT[], NUMERIC);
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_crear(
    p_pk_usuario_solicitante    BIGINT,
    p_nombre                    VARCHAR,
    p_fk_tasignatura            BIGINT,
    p_fk_tgrado                 BIGINT,
    p_fk_tfuncionario           BIGINT,
    p_fk_tlv_calculo_definitiva BIGINT,
    p_descripcion               VARCHAR   DEFAULT NULL,
    p_fk_referente_curricular   BIGINT    DEFAULT NULL,
    p_objetivos                 VARCHAR[] DEFAULT NULL,
    p_contenidos                VARCHAR[] DEFAULT NULL,
    p_enunciados                BIGINT[]  DEFAULT NULL,
    p_ponderacion               NUMERIC   DEFAULT NULL,
    p_contenidos_titulos        VARCHAR[] DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    -- El JWT no trae el funcionario: se deriva del usuario. Coordinación
    -- puede crear a nombre de otro docente.
    v_autor BIGINT := COALESCE(p_fk_tfuncionario,
                               academico_test.fn_funcionario_actual(p_pk_usuario_solicitante));
BEGIN
    -- Sin grado el alcance no tiene sede contra la cual comprobarse.
    IF p_fk_tgrado IS NULL THEN
        RAISE EXCEPTION 'Seleccione el grado de %',
            lower(academico_test.fn_unidad_rotulo(p_fk_referente_curricular)) USING ERRCODE = '22023';
    END IF;
    PERFORM academico_test.fn_planeador_assert_alcance(p_pk_usuario_solicitante, 'CREAR', NULL, p_fk_tgrado);
    PERFORM academico_test.fn_unidad_assert_autor(p_pk_usuario_solicitante, v_autor,
        COALESCE(p_fk_referente_curricular,
                 academico_test.fn_unidad_referente_aplicable(p_fk_tgrado, p_fk_tasignatura)));

    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Creación de la unidad %s', TRIM(p_nombre)), NULL,
        academico_test.fn_unidad_sede(NULL, p_fk_tgrado));

    RETURN academico_test.fn_unidad_crear_interno(
        p_pk_usuario_solicitante, p_nombre, p_fk_tasignatura, p_fk_tgrado, v_autor,
        p_fk_tlv_calculo_definitiva, p_descripcion, p_fk_referente_curricular,
        p_objetivos, p_contenidos, p_enunciados, p_ponderacion, p_contenidos_titulos);
END;
$$;

DROP FUNCTION IF EXISTS academico_test.fn_unidad_actualizar(BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, BOOLEAN, VARCHAR[], VARCHAR[], NUMERIC, BOOLEAN, BIGINT[]);
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_actualizar(
    p_pk_usuario_solicitante    BIGINT,
    p_pk_tunidad                BIGINT,
    p_nombre                    VARCHAR   DEFAULT NULL,
    p_descripcion               VARCHAR   DEFAULT NULL,
    p_fk_tasignatura            BIGINT    DEFAULT NULL,
    p_fk_tgrado                 BIGINT    DEFAULT NULL,
    p_fk_tfuncionario           BIGINT    DEFAULT NULL,
    p_fk_tlv_calculo_definitiva BIGINT    DEFAULT NULL,
    p_fk_referente_curricular   BIGINT    DEFAULT NULL,
    p_limpiar_referente         BOOLEAN   DEFAULT FALSE,
    p_objetivos                 VARCHAR[] DEFAULT NULL,
    p_contenidos                VARCHAR[] DEFAULT NULL,
    p_ponderacion               NUMERIC   DEFAULT NULL,
    p_limpiar_ponderacion       BOOLEAN   DEFAULT FALSE,
    p_enunciados                BIGINT[]  DEFAULT NULL,
    p_contenidos_titulos        VARCHAR[] DEFAULT NULL
)
RETURNS TABLE (pk_tunidad BIGINT, actividades_afectadas JSONB)
LANGUAGE plpgsql
AS $$
#variable_conflict use_column
DECLARE
    v_nombre      VARCHAR;
    v_calculo     BIGINT;
    v_modo_previo VARCHAR;
    v_etiqueta    TEXT;
BEGIN
    PERFORM academico_test.fn_unidad_validar_existente(p_pk_tunidad);
    PERFORM academico_test.fn_unidad_validar_activa(p_pk_tunidad);
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'EDITAR', NULL, p_fk_tgrado, p_pk_tunidad);
    PERFORM academico_test.fn_unidad_assert_propietario(p_pk_usuario_solicitante, p_pk_tunidad);

    SELECT u.NOMBRE, u.FK_TLV_CALCULO_DEFINITIVA INTO v_nombre, v_calculo
      FROM academico_test.TUNIDAD u WHERE u.PK_TUNIDAD = p_pk_tunidad;
    v_modo_previo := academico_test.fn_unidad_calculo_definitiva_modo(p_pk_tunidad);
    v_etiqueta := format('Actualización de la unidad %s', COALESCE(NULLIF(TRIM(p_nombre), ''), v_nombre));
    -- Regla 28: el cambio de criterio de cálculo es de alto impacto y se rotula aparte.
    IF p_fk_tlv_calculo_definitiva IS DISTINCT FROM v_calculo AND p_fk_tlv_calculo_definitiva IS NOT NULL THEN
        v_etiqueta := v_etiqueta || format(' (criterio de cálculo: %s → %s)',
            (SELECT lv.NOMBRE FROM academico_test.TLISTA_VALOR lv WHERE lv.PK_LISTA_VALOR = v_calculo),
            (SELECT lv.NOMBRE FROM academico_test.TLISTA_VALOR lv WHERE lv.PK_LISTA_VALOR = p_fk_tlv_calculo_definitiva));
    END IF;
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante, v_etiqueta, NULL,
        academico_test.fn_unidad_sede(p_pk_tunidad, p_fk_tgrado));

    PERFORM academico_test.fn_unidad_actualizar_interno(
        p_pk_usuario_solicitante, p_pk_tunidad, p_nombre, p_descripcion, p_fk_tasignatura,
        p_fk_tgrado, p_fk_tfuncionario, p_fk_tlv_calculo_definitiva, p_fk_referente_curricular,
        p_limpiar_referente, p_objetivos, p_contenidos, p_ponderacion, p_limpiar_ponderacion,
        p_enunciados, p_contenidos_titulos);

    RETURN QUERY
    SELECT p_pk_tunidad,
           CASE WHEN academico_test.fn_unidad_calculo_definitiva_modo(p_pk_tunidad) IS DISTINCT FROM v_modo_previo
                THEN academico_test.fn_unidad_actividades_resumen_interno(p_pk_tunidad)
                ELSE '[]'::jsonb END;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_eliminar(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tunidad             BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_unidad_validar_existente(p_pk_tunidad);
    PERFORM academico_test.fn_unidad_validar_activa(p_pk_tunidad);
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'ELIMINAR', NULL, NULL, p_pk_tunidad);
    PERFORM academico_test.fn_unidad_assert_propietario(p_pk_usuario_solicitante, p_pk_tunidad);

    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Eliminación de la unidad %s', (SELECT NOMBRE FROM academico_test.TUNIDAD WHERE PK_TUNIDAD = p_pk_tunidad)),
        NULL, academico_test.fn_unidad_sede(p_pk_tunidad));

    RETURN academico_test.fn_unidad_eliminar_interno(p_pk_usuario_solicitante, p_pk_tunidad);
END;
$$;

-- ---------------------------------------------------------------------------
-- Enunciados de la unidad
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_enunciado_relacionar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tunidad             BIGINT,
    p_fk_referente_enunciado BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_unidad_validar_existente(p_fk_tunidad);
    PERFORM academico_test.fn_unidad_validar_activa(p_fk_tunidad);
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'EDITAR', NULL, NULL, p_fk_tunidad);
    PERFORM academico_test.fn_unidad_assert_propietario(p_pk_usuario_solicitante, p_fk_tunidad);

    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Relación de %s con la unidad %s',
               COALESCE(academico_test.fn_unidad_enunciado_etiqueta(p_fk_referente_enunciado), 'un enunciado'),
               (SELECT NOMBRE FROM academico_test.TUNIDAD WHERE PK_TUNIDAD = p_fk_tunidad)),
        NULL, academico_test.fn_unidad_sede(p_fk_tunidad));

    RETURN academico_test.fn_unidad_enunciado_relacionar_interno(
        p_pk_usuario_solicitante, p_fk_tunidad, p_fk_referente_enunciado);
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_enunciado_quitar(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tunidad_enunciado   BIGINT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_unidad    BIGINT;
    v_enunciado BIGINT;
BEGIN
    SELECT FK_TUNIDAD, FK_REFERENTE_ENUNCIADO INTO v_unidad, v_enunciado
      FROM academico_test.TUNIDAD_ENUNCIADO WHERE PK_TUNIDAD_ENUNCIADO = p_pk_tunidad_enunciado;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontró el enunciado de la unidad solicitado' USING ERRCODE = 'P0002';
    END IF;
    PERFORM academico_test.fn_unidad_validar_activa(v_unidad);
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'EDITAR', NULL, NULL, v_unidad);
    PERFORM academico_test.fn_unidad_assert_propietario(p_pk_usuario_solicitante, v_unidad);

    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Retiro de %s de la unidad %s',
               academico_test.fn_unidad_enunciado_etiqueta(v_enunciado),
               (SELECT NOMBRE FROM academico_test.TUNIDAD WHERE PK_TUNIDAD = v_unidad)),
        NULL, academico_test.fn_unidad_sede(v_unidad));

    RETURN academico_test.fn_unidad_enunciado_quitar_interno(p_pk_usuario_solicitante, p_pk_tunidad_enunciado);
END;
$$;

-- ---------------------------------------------------------------------------
-- Criterios de la rúbrica de la unidad
-- ---------------------------------------------------------------------------

-- Agregar criterios está abierto a todo docente con alcance (Regla 25): no
-- exige ser el propietario de la unidad.
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_criterio_agregar(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tunidad             BIGINT,
    p_descripcion            VARCHAR,
    p_niveles                JSONB,
    p_publico                VARCHAR DEFAULT 'S',
    p_codigo                 VARCHAR DEFAULT NULL,
    p_descriptor_prom        VARCHAR DEFAULT 'N'
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_unidad_validar_existente(p_pk_tunidad);
    PERFORM academico_test.fn_unidad_validar_activa(p_pk_tunidad);
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'EDITAR', NULL, NULL, p_pk_tunidad);

    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Creación del criterio %s en la unidad %s', TRIM(p_descripcion),
               (SELECT NOMBRE FROM academico_test.TUNIDAD WHERE PK_TUNIDAD = p_pk_tunidad)),
        NULL, academico_test.fn_unidad_sede(p_pk_tunidad));

    RETURN academico_test.fn_unidad_criterio_agregar_interno(
        p_pk_usuario_solicitante, p_pk_tunidad, p_descripcion, p_niveles,
        p_publico, p_codigo, p_descriptor_prom);
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_criterio_actualizar(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tcriterio_unidad    BIGINT,
    p_descripcion            VARCHAR DEFAULT NULL,
    p_publico                VARCHAR DEFAULT NULL,
    p_codigo                 VARCHAR DEFAULT NULL,
    p_limpiar_codigo         BOOLEAN DEFAULT FALSE,
    p_descriptor_prom        VARCHAR DEFAULT NULL,
    p_niveles                JSONB   DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_unidad BIGINT;
BEGIN
    PERFORM academico_test.fn_unidad_validar_criterio_existente(p_pk_tcriterio_unidad);
    PERFORM academico_test.fn_unidad_validar_criterio_activo(p_pk_tcriterio_unidad);
    SELECT ru.FK_TUNIDAD INTO v_unidad
      FROM academico_test.TCRITERIO_UNIDAD cu
      JOIN academico_test.TRUBRICA_UNIDAD ru ON ru.PK_TRUBRICA_UNIDAD = cu.FK_TRUBRICA_UNIDAD
     WHERE cu.PK_TCRITERIO_UNIDAD = p_pk_tcriterio_unidad;
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'EDITAR', NULL, NULL, v_unidad);
    PERFORM academico_test.fn_unidad_assert_criterio_propietario(p_pk_usuario_solicitante, p_pk_tcriterio_unidad);

    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Actualización del criterio %s de la unidad %s',
               (SELECT DESCRIPCION FROM academico_test.TCRITERIO_UNIDAD WHERE PK_TCRITERIO_UNIDAD = p_pk_tcriterio_unidad),
               (SELECT NOMBRE FROM academico_test.TUNIDAD WHERE PK_TUNIDAD = v_unidad)),
        NULL, academico_test.fn_unidad_sede(v_unidad));

    RETURN academico_test.fn_unidad_criterio_actualizar_interno(
        p_pk_usuario_solicitante, p_pk_tcriterio_unidad, p_descripcion, p_publico,
        p_codigo, p_limpiar_codigo, p_descriptor_prom, p_niveles);
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_criterio_eliminar(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tcriterio_unidad    BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_unidad BIGINT;
BEGIN
    PERFORM academico_test.fn_unidad_validar_criterio_existente(p_pk_tcriterio_unidad);
    PERFORM academico_test.fn_unidad_validar_criterio_activo(p_pk_tcriterio_unidad);
    SELECT ru.FK_TUNIDAD INTO v_unidad
      FROM academico_test.TCRITERIO_UNIDAD cu
      JOIN academico_test.TRUBRICA_UNIDAD ru ON ru.PK_TRUBRICA_UNIDAD = cu.FK_TRUBRICA_UNIDAD
     WHERE cu.PK_TCRITERIO_UNIDAD = p_pk_tcriterio_unidad;
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'ELIMINAR', NULL, NULL, v_unidad);
    PERFORM academico_test.fn_unidad_assert_criterio_propietario(p_pk_usuario_solicitante, p_pk_tcriterio_unidad);

    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Eliminación del criterio %s de la unidad %s',
               (SELECT DESCRIPCION FROM academico_test.TCRITERIO_UNIDAD WHERE PK_TCRITERIO_UNIDAD = p_pk_tcriterio_unidad),
               (SELECT NOMBRE FROM academico_test.TUNIDAD WHERE PK_TUNIDAD = v_unidad)),
        NULL, academico_test.fn_unidad_sede(v_unidad));

    RETURN academico_test.fn_unidad_criterio_eliminar_interno(p_pk_usuario_solicitante, p_pk_tcriterio_unidad);
END;
$$;

-- ---------------------------------------------------------------------------
-- Actividades de la unidad
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_actividad_vincular(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad            BIGINT,
    p_pk_tunidad               BIGINT,
    p_ponderacion              NUMERIC DEFAULT NULL,
    p_permitir_mover_de_unidad BOOLEAN DEFAULT FALSE
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_unidad_validar_actividad_existente(p_pk_tactividad);
    PERFORM academico_test.fn_unidad_validar_existente(p_pk_tunidad);
    PERFORM academico_test.fn_unidad_validar_actividad_activa(p_pk_tactividad);
    PERFORM academico_test.fn_unidad_validar_activa(p_pk_tunidad);
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'EDITAR', NULL, NULL, p_pk_tunidad, p_pk_tactividad);

    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Vinculación de la actividad %s a la unidad %s',
               (SELECT TITULO FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_pk_tactividad),
               (SELECT NOMBRE FROM academico_test.TUNIDAD WHERE PK_TUNIDAD = p_pk_tunidad)),
        NULL, academico_test.fn_unidad_sede(p_pk_tunidad));

    RETURN academico_test.fn_unidad_actividad_vincular_interno(
        p_pk_usuario_solicitante, p_pk_tactividad, p_pk_tunidad, p_ponderacion, p_permitir_mover_de_unidad);
END;
$$;

-- Cambia el retorno (antes BIGINT): hace falta el DROP de la firma.
DROP FUNCTION IF EXISTS academico_test.fn_unidad_actividad_desvincular(BIGINT, BIGINT);
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_actividad_desvincular(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT
)
RETURNS TABLE (pk_tactividad BIGINT, porcentaje_libre NUMERIC, aviso VARCHAR)
LANGUAGE plpgsql
AS $$
#variable_conflict use_column
DECLARE
    v_unidad BIGINT;
    v_grupo  BIGINT;
    v_peso   NUMERIC;
BEGIN
    PERFORM academico_test.fn_unidad_validar_actividad_existente(p_pk_tactividad);
    PERFORM academico_test.fn_unidad_validar_actividad_activa(p_pk_tactividad);
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'EDITAR', NULL, NULL, NULL, p_pk_tactividad);
    PERFORM academico_test.fn_actividad_assert_propietario(p_pk_usuario_solicitante, p_pk_tactividad);

    SELECT FK_TUNIDAD INTO v_unidad FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_pk_tactividad;
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Desvinculación de la actividad %s de la unidad %s',
               (SELECT TITULO FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_pk_tactividad),
               COALESCE((SELECT NOMBRE FROM academico_test.TUNIDAD WHERE PK_TUNIDAD = v_unidad), '(ninguna)')),
        NULL, academico_test.fn_unidad_sede(v_unidad));

    SELECT FK_TGRUPO, PONDERACION INTO v_grupo, v_peso FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_pk_tactividad;
    PERFORM academico_test.fn_unidad_actividad_desvincular_interno(p_pk_usuario_solicitante, p_pk_tactividad);
    RETURN QUERY
    SELECT p_pk_tactividad, l.porcentaje_libre, l.aviso
      FROM academico_test.fn_unidad_aviso_peso_liberado(v_unidad, v_grupo, v_peso, 'DESVINCULAR') l;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_actividad_ponderacion_set(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT,
    p_ponderacion            NUMERIC
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_unidad BIGINT;
BEGIN
    PERFORM academico_test.fn_unidad_validar_actividad_existente(p_pk_tactividad);
    PERFORM academico_test.fn_unidad_validar_actividad_activa(p_pk_tactividad);
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'EDITAR', NULL, NULL, NULL, p_pk_tactividad);
    PERFORM academico_test.fn_actividad_assert_propietario(p_pk_usuario_solicitante, p_pk_tactividad);

    SELECT FK_TUNIDAD INTO v_unidad FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_pk_tactividad;
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Peso de la actividad %s en la unidad: %s %%',
               (SELECT TITULO FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_pk_tactividad), p_ponderacion),
        NULL, academico_test.fn_unidad_sede(v_unidad));

    RETURN academico_test.fn_unidad_actividad_ponderacion_set_interno(
        p_pk_usuario_solicitante, p_pk_tactividad, p_ponderacion);
END;
$$;

-- ---------------------------------------------------------------------------
-- Lecturas
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_objetivos_listar(p_pk_usuario_solicitante BIGINT, p_pk_tunidad BIGINT)
RETURNS TABLE(pk_tunidad_objetivo BIGINT, orden NUMERIC, descripcion VARCHAR)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_unidad_validar_existente(p_pk_tunidad);
    PERFORM academico_test.fn_planeador_assert_alcance(p_pk_usuario_solicitante, 'VER', NULL, NULL, p_pk_tunidad);
    RETURN QUERY SELECT * FROM academico_test.fn_unidad_objetivos_listar_interno(p_pk_tunidad);
END;
$$;

-- Cambia el retorno (título de sección, al final).
DROP FUNCTION IF EXISTS academico_test.fn_unidad_contenidos_listar(BIGINT, BIGINT);
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_contenidos_listar(p_pk_usuario_solicitante BIGINT, p_pk_tunidad BIGINT)
RETURNS TABLE(pk_tunidad_contenido BIGINT, orden NUMERIC, descripcion VARCHAR, titulo VARCHAR)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_unidad_validar_existente(p_pk_tunidad);
    PERFORM academico_test.fn_planeador_assert_alcance(p_pk_usuario_solicitante, 'VER', NULL, NULL, p_pk_tunidad);
    RETURN QUERY SELECT * FROM academico_test.fn_unidad_contenidos_listar_interno(p_pk_tunidad);
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_criterio_listar(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tunidad             BIGINT,
    p_incluir_inactivos      BOOLEAN DEFAULT FALSE
)
RETURNS TABLE(pk_tcriterio_unidad BIGINT, orden NUMERIC, descripcion VARCHAR, publico VARCHAR,
              codigo VARCHAR, descriptor_prom VARCHAR, niveles JSONB, active BOOLEAN)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_unidad_validar_existente(p_pk_tunidad);
    PERFORM academico_test.fn_planeador_assert_alcance(p_pk_usuario_solicitante, 'VER', NULL, NULL, p_pk_tunidad);
    RETURN QUERY SELECT * FROM academico_test.fn_unidad_criterio_listar_interno(p_pk_tunidad, p_incluir_inactivos);
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_ponderacion_disponible(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tunidad             BIGINT,
    p_fk_tgrupo              BIGINT
)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_unidad_validar_existente(p_pk_tunidad);
    PERFORM academico_test.fn_planeador_assert_alcance(p_pk_usuario_solicitante, 'VER', NULL, NULL, p_pk_tunidad);
    RETURN academico_test.fn_unidad_ponderacion_disponible_interno(p_pk_tunidad, p_fk_tgrupo);
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_referente_detalle(p_pk_usuario_solicitante BIGINT, p_pk_tunidad BIGINT)
RETURNS TABLE(pk_tunidad BIGINT, unidad_nombre VARCHAR, fk_tgrado BIGINT, grado VARCHAR,
              fk_tnivel_ensenanza BIGINT, nivel_ensenanza VARCHAR, pk_referente_curricular BIGINT,
              referente_nombre VARCHAR, referente_descripcion VARCHAR, enfoque_valor VARCHAR,
              enfoque_nombre VARCHAR, es_evaluativo BOOLEAN, tipo_evaluacion_valor VARCHAR,
              tipo_evaluacion_nombre VARCHAR, nivel_1_etiqueta VARCHAR, nivel_2_etiqueta VARCHAR,
              enunciados JSONB)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_unidad_validar_existente(p_pk_tunidad);
    PERFORM academico_test.fn_planeador_assert_alcance(p_pk_usuario_solicitante, 'VER', NULL, NULL, p_pk_tunidad);
    RETURN QUERY SELECT * FROM academico_test.fn_unidad_referente_detalle_interno(p_pk_tunidad);
END;
$$;

-- ---------------------------------------------------------------------------
-- Comentarios
-- ---------------------------------------------------------------------------

COMMENT ON FUNCTION academico_test.fn_unidad_crear(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, VARCHAR, BIGINT, VARCHAR[], VARCHAR[], BIGINT[], NUMERIC, VARCHAR[])
    IS 'POST /planeador/unidades: alcance CREAR sobre el grado, un docente solo crea a su nombre (autor derivado del usuario si no llega), etiqueta de auditoría y fn_unidad_crear_interno. CONTENIDOS_TITULOS opcional: si llega, un título por contenido (§4).';
COMMENT ON FUNCTION academico_test.fn_unidad_actualizar(BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, BOOLEAN, VARCHAR[], VARCHAR[], NUMERIC, BOOLEAN, BIGINT[], VARCHAR[])
    IS 'PUT /planeador/unidades/:ID: PATCH parcial (NULL = no tocar, arrays = reemplazo). Alcance EDITAR + propietario (Regla 25); cambiar FK_TFUNCIONARIO es ceder la unidad a un docente que la usa (Regla 27). Devuelve pk_tunidad y actividades_afectadas [{pk, titulo}] si cambió el criterio de cálculo (Regla 28). Lógica en fn_unidad_actualizar_interno.';
COMMENT ON FUNCTION academico_test.fn_unidad_eliminar(BIGINT, BIGINT)
    IS 'PATCH /planeador/unidades/:ID: baja lógica. Alcance ELIMINAR + propietario; bloquea con actividades o criterios de otros docentes (23503); las actividades del dueño se desvinculan. Lógica en fn_unidad_eliminar_interno.';
COMMENT ON FUNCTION academico_test.fn_unidad_enunciado_relacionar(BIGINT, BIGINT, BIGINT)
    IS 'POST /planeador/unidades/:ID/enunciados: relaciona un enunciado (nivel 1) del referente de la unidad, de su grado y área. Alcance EDITAR + propietario. Lógica en fn_unidad_enunciado_relacionar_interno.';
COMMENT ON FUNCTION academico_test.fn_unidad_enunciado_quitar(BIGINT, BIGINT)
    IS 'PATCH /planeador/unidades/enunciados/:ID: quita el enunciado y las evidencias que las actividades de la unidad habían marcado de él. Alcance EDITAR + propietario.';
COMMENT ON FUNCTION academico_test.fn_unidad_criterio_agregar(BIGINT, BIGINT, VARCHAR, JSONB, VARCHAR, VARCHAR, VARCHAR)
    IS 'POST /planeador/unidades/:ID/criterios: criterio de la rúbrica con un indicador por nivel de la escala de la unidad. Cualquier docente con alcance EDITAR (Regla 25). Lógica en fn_unidad_criterio_agregar_interno.';
COMMENT ON FUNCTION academico_test.fn_unidad_criterio_actualizar(BIGINT, BIGINT, VARCHAR, VARCHAR, VARCHAR, BOOLEAN, VARCHAR, JSONB)
    IS 'PUT /planeador/unidades/criterios/:ID: PATCH del criterio y de los indicadores de sus niveles. Alcance EDITAR + autor del criterio (Regla 25).';
COMMENT ON FUNCTION academico_test.fn_unidad_criterio_eliminar(BIGINT, BIGINT)
    IS 'PATCH /planeador/unidades/criterios/:ID: baja lógica del criterio y sus niveles. Alcance ELIMINAR + autor del criterio (Regla 25).';
COMMENT ON FUNCTION academico_test.fn_unidad_actividad_vincular(BIGINT, BIGINT, BIGINT, NUMERIC, BOOLEAN)
    IS 'PUT /planeador/unidades/:ID/actividades/:ACTIVIDADID: vincula una actividad de la misma asignatura y grado; mover desde otra unidad exige PERMITIR_MOVER_DE_UNIDAD. Lógica en fn_unidad_actividad_vincular_interno.';
COMMENT ON FUNCTION academico_test.fn_unidad_actividad_desvincular(BIGINT, BIGINT)
    IS 'PATCH /planeador/unidades/actividades/:ACTIVIDADID: suelta la actividad de su unidad (idempotente). Alcance EDITAR + autor de la actividad (Regla 25c). Devuelve pk_tactividad y, si la unidad pondera, el % libre y el aviso (Regla 39). Lógica en fn_unidad_actividad_desvincular_interno.';
COMMENT ON FUNCTION academico_test.fn_unidad_actividad_ponderacion_set(BIGINT, BIGINT, NUMERIC)
    IS 'PUT /planeador/unidades/actividades/:ACTIVIDADID/ponderacion: peso (%) de la actividad, solo en unidades que Ponderan, sin pasar de 100 por grupo. Alcance EDITAR + autor de la actividad (Regla 25c).';
COMMENT ON FUNCTION academico_test.fn_unidad_objetivos_listar(BIGINT, BIGINT)
    IS 'GET /planeador/unidades/:ID/objetivos: alcance VER + fn_unidad_objetivos_listar_interno.';
COMMENT ON FUNCTION academico_test.fn_unidad_contenidos_listar(BIGINT, BIGINT)
    IS 'GET /planeador/unidades/:ID/contenidos: alcance VER + fn_unidad_contenidos_listar_interno (titulo, el título de sección, va al final).';
COMMENT ON FUNCTION academico_test.fn_unidad_criterio_listar(BIGINT, BIGINT, BOOLEAN)
    IS 'GET /planeador/unidades/:ID/criterios: alcance VER + fn_unidad_criterio_listar_interno.';
COMMENT ON FUNCTION academico_test.fn_unidad_ponderacion_disponible(BIGINT, BIGINT, BIGINT)
    IS 'GET /planeador/unidades/:ID/ponderacion-disponible: % libre del grupo en la unidad. Alcance VER.';
COMMENT ON FUNCTION academico_test.fn_unidad_referente_detalle(BIGINT, BIGINT)
    IS 'GET /planeador/unidades/:ID/referente: referente vigente de la unidad, sus rótulos y los enunciados relacionados con sus evidencias. Alcance VER.';

COMMENT ON FUNCTION academico_test.fn_unidad_crear_interno(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, VARCHAR, BIGINT, VARCHAR[], VARCHAR[], BIGINT[], NUMERIC, VARCHAR[])
    IS 'INTERNO: alta de la unidad sin permisos (campos, títulos de sección, criterio de cálculo según el enfoque del referente derivado, coherencia). La usa fn_unidad_crear.';
COMMENT ON FUNCTION academico_test.fn_unidad_actualizar_interno(BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, BOOLEAN, VARCHAR[], VARCHAR[], NUMERIC, BOOLEAN, BIGINT[], VARCHAR[])
    IS 'INTERNO: PATCH de la unidad sin permisos; valida la cesión (Regla 27), depura enunciados de otro referente y convierte peso/puntaje de las actividades al cambiar el criterio de cálculo (Regla 18). La usa fn_unidad_actualizar.';
COMMENT ON FUNCTION academico_test.fn_unidad_eliminar_interno(BIGINT, BIGINT)
    IS 'INTERNO: baja lógica de la unidad, su rúbrica, objetivos, contenidos y enunciados; desvincula las actividades del dueño (las de colegas bloquean). La usa fn_unidad_eliminar.';
COMMENT ON FUNCTION academico_test.fn_unidad_enunciado_relacionar_interno(BIGINT, BIGINT, BIGINT)
    IS 'INTERNO: relaciona (o reactiva) un enunciado validado con fn_unidad_validar_enunciado. La usan fn_unidad_enunciado_relacionar y fn_unidad_enunciados_reemplazar_interno.';
COMMENT ON FUNCTION academico_test.fn_unidad_enunciado_quitar_interno(BIGINT, BIGINT)
    IS 'INTERNO: quita un enunciado de la unidad y sus evidencias marcadas en actividades. La usa fn_unidad_enunciado_quitar.';
COMMENT ON FUNCTION academico_test.fn_unidad_criterio_agregar_interno(BIGINT, BIGINT, VARCHAR, JSONB, VARCHAR, VARCHAR, VARCHAR)
    IS 'INTERNO: crea el criterio (y la rúbrica si falta) validando la escala de la unidad. La usa fn_unidad_criterio_agregar.';
COMMENT ON FUNCTION academico_test.fn_unidad_actividad_vincular_interno(BIGINT, BIGINT, BIGINT, NUMERIC, BOOLEAN)
    IS 'INTERNO: vínculo actividad-unidad sin permisos. La usan fn_unidad_actividad_vincular y fn_actividad_actualizar_interno.';
COMMENT ON FUNCTION academico_test.fn_unidad_actividad_desvincular_interno(BIGINT, BIGINT)
    IS 'INTERNO: desvincula la actividad sin permisos. La usan fn_unidad_actividad_desvincular y fn_actividad_actualizar_interno.';
COMMENT ON FUNCTION academico_test.fn_unidad_actividad_ponderacion_set_interno(BIGINT, BIGINT, NUMERIC)
    IS 'INTERNO: fija el peso de la actividad sin permisos. La usan fn_unidad_actividad_ponderacion_set y fn_actividad_actualizar_interno.';
