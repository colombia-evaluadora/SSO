-- ===========================================================================
-- V222 — Planeador educativo: CRUD de los criterios de la rubrica de una
-- unidad (listar / actualizar / eliminar) + asegurar la rubrica
-- (CU-86e311xxp — G. Academico Back Planeador educativo).
--
-- Complementa V216, que ya trae:
--   * fn_unidad_criterio_agregar — crea un criterio (get-or-create de
--     TRUBRICA_UNIDAD) con un indicador por cada valoracion de la escala.
--
-- Pantalla "Criterios de la unidad" (CRITERIO | BAJO | BASICO | ALTO |
-- SUPERIOR | ... + acciones editar / eliminar). Las columnas de nivel NO
-- son fijas: son las valoraciones de la ESCALA definida como general en el
-- criterio de evaluacion del periodo academico del grado de la unidad
-- (TGRADO.FK_TPERIODO_ACADEMICO -> TCRITERIO_EVALUACION.FK_TESCALA ->
-- TESCALA_VALORACION -> TVALORACION). Cada fila de nivel vive en
-- TNIVEL_CRITERIO_UNIDAD (V22), 1 por (criterio, valoracion).
--
-- Depende de (orden de version de Flyway):
--   * V22  — TRUBRICA_UNIDAD, TCRITERIO_UNIDAD, TNIVEL_CRITERIO_UNIDAD,
--            TESCALA_VALORACION, TVALORACION.
--   * V216 — menu 'PLANEADOR' + gate + fn_unidad_criterio_agregar.
--   * V218 — TUNIDAD sin FK_TPERIODO_EVALUACION (escala via el grado).
--   * V29/V185/V213 — fn_assert_permiso_seccion.
--
-- Estilo: sigue V213/V216 (gate fn_assert_permiso_seccion, 22023/23503/
-- P0002, PATCH parcial con COALESCE, soft delete en cascada, agregacion
-- JSONB, COMMENT ON FUNCTION).
-- ===========================================================================

SET search_path TO academico_test, public;

-- ===========================================================================
-- fn_unidad_rubrica_asegurar — get-or-create de TRUBRICA_UNIDAD (1:1).
-- Deja lista la rubrica de la unidad aunque todavia no tenga criterios.
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_rubrica_asegurar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tunidad               BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_unidad_active BOOLEAN;
    v_pk_rubrica    BIGINT;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'EDITAR'
    );

    SELECT ACTIVE INTO v_unidad_active
      FROM academico_test.TUNIDAD WHERE PK_TUNIDAD = p_pk_tunidad;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la unidad tematica solicitada' USING ERRCODE = 'P0002';
    END IF;
    IF v_unidad_active = FALSE THEN
        RAISE EXCEPTION 'La unidad esta inactiva; no se le puede crear la rubrica' USING ERRCODE = '22023';
    END IF;

    SELECT PK_TRUBRICA_UNIDAD INTO v_pk_rubrica
      FROM academico_test.TRUBRICA_UNIDAD
     WHERE FK_TUNIDAD = p_pk_tunidad AND ACTIVE = TRUE;

    IF NOT FOUND THEN
        UPDATE academico_test.TRUBRICA_UNIDAD
           SET ACTIVE = TRUE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TUNIDAD = p_pk_tunidad
        RETURNING PK_TRUBRICA_UNIDAD INTO v_pk_rubrica;

        IF v_pk_rubrica IS NULL THEN
            INSERT INTO academico_test.TRUBRICA_UNIDAD (FK_TUNIDAD, CREATED_BY, CREATED_AT, ACTIVE)
            VALUES (p_pk_tunidad, p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE)
            RETURNING PK_TRUBRICA_UNIDAD INTO v_pk_rubrica;
        END IF;
    END IF;

    RETURN v_pk_rubrica;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_rubrica_asegurar(BIGINT, BIGINT)
    IS 'Get-or-create de la rubrica de la unidad (TRUBRICA_UNIDAD, 1:1 con TUNIDAD; reactiva una inactiva). Gate EDITAR sobre PLANEADOR. Retorna PK_TRUBRICA_UNIDAD.';

-- ===========================================================================
-- fn_unidad_criterio_listar — criterios de la rubrica de la unidad con sus
-- niveles (uno por valoracion de la escala) agregados como JSONB ordenado.
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_criterio_listar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tunidad               BIGINT,
    p_incluir_inactivos        BOOLEAN DEFAULT FALSE
)
RETURNS TABLE (
    pk_tcriterio_unidad   BIGINT,
    orden                 NUMERIC,
    descripcion           VARCHAR,
    publico               VARCHAR,
    codigo                VARCHAR,
    descriptor_prom       VARCHAR,
    niveles               JSONB,
    active                BOOLEAN
)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    IF NOT EXISTS (SELECT 1 FROM academico_test.TUNIDAD WHERE PK_TUNIDAD = p_pk_tunidad) THEN
        RAISE EXCEPTION 'No se encontro la unidad tematica solicitada' USING ERRCODE = 'P0002';
    END IF;

    RETURN QUERY
    SELECT cu.PK_TCRITERIO_UNIDAD,
           cu.ORDEN,
           cu.DESCRIPCION,
           cu.PUBLICO,
           cu.CODIGO,
           cu.DESCRIPTOR_PROM,
           COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                          'pk',                  ncu.PK_TNIVEL_CRITERIO_UNIDAD,
                          'fkTescalaValoracion', ncu.FK_TESCALA_VALORACION,
                          'valoracion',          val.NOMBRE,
                          'orden',               ev.ORDEN,
                          'indicador',           ncu.INDICADOR,
                          'recomendacion',       ncu.RECOMENDACION,
                          'tarea',               ncu.TAREA)
                          ORDER BY ev.ORDEN)
                 FROM academico_test.TNIVEL_CRITERIO_UNIDAD ncu
                 JOIN academico_test.TESCALA_VALORACION ev ON ev.PK_TESCALA_VALORACION = ncu.FK_TESCALA_VALORACION
                 JOIN academico_test.TVALORACION val       ON val.PK_TVALORACION = ev.FK_TVALORACION
                WHERE ncu.FK_TCRITERIO_UNIDAD = cu.PK_TCRITERIO_UNIDAD
                  AND ncu.ACTIVE = TRUE
           ), '[]'::jsonb),
           cu.ACTIVE
      FROM academico_test.TCRITERIO_UNIDAD cu
      JOIN academico_test.TRUBRICA_UNIDAD ru ON ru.PK_TRUBRICA_UNIDAD = cu.FK_TRUBRICA_UNIDAD
     WHERE ru.FK_TUNIDAD = p_pk_tunidad
       AND (p_incluir_inactivos OR (cu.ACTIVE = TRUE AND ru.ACTIVE = TRUE))
     ORDER BY cu.ORDEN;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_criterio_listar(BIGINT, BIGINT, BOOLEAN)
    IS 'Criterios de la rubrica de la unidad (TCRITERIO_UNIDAD) ordenados por ORDEN, con sus niveles (TNIVEL_CRITERIO_UNIDAD) agregados en JSONB ordenado por la ORDEN de la valoracion en la escala: [{pk, fkTescalaValoracion, valoracion, orden, indicador, recomendacion, tarea}]. Gate VER sobre PLANEADOR. p_incluir_inactivos=FALSE por defecto.';

-- ===========================================================================
-- fn_unidad_criterio_actualizar — PATCH parcial de un criterio y de los
-- textos de sus niveles ya existentes.
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_criterio_actualizar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tcriterio_unidad      BIGINT,
    p_descripcion              VARCHAR(4000) DEFAULT NULL,
    p_publico                  VARCHAR(1)    DEFAULT NULL,
    p_codigo                   VARCHAR(6)    DEFAULT NULL,
    p_limpiar_codigo           BOOLEAN       DEFAULT FALSE,
    p_descriptor_prom          VARCHAR(1)    DEFAULT NULL,
    -- NULL = no tocar niveles. Array: por cada elemento
    -- {fkTescalaValoracion, indicador?, recomendacion?, tarea?} se actualiza
    -- la fila TNIVEL_CRITERIO_UNIDAD ya existente de ese criterio/valoracion
    -- (los campos ausentes u omitidos como NULL se preservan; ''
    -- vacia recomendacion/tarea). No crea niveles nuevos: para eso se
    -- recrea el criterio con fn_unidad_criterio_agregar (V216).
    p_niveles                  JSONB         DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_active BOOLEAN;
BEGIN
    SELECT cu.ACTIVE INTO v_active
      FROM academico_test.TCRITERIO_UNIDAD cu
     WHERE cu.PK_TCRITERIO_UNIDAD = p_pk_tcriterio_unidad;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el criterio de rubrica solicitado' USING ERRCODE = 'P0002';
    END IF;

    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'EDITAR'
    );

    IF v_active = FALSE THEN
        RAISE EXCEPTION 'El criterio esta inactivo; no se puede editar' USING ERRCODE = '22023';
    END IF;

    IF p_descripcion IS NOT NULL AND NULLIF(TRIM(p_descripcion), '') IS NULL THEN
        RAISE EXCEPTION 'El texto del criterio no puede quedar vacio' USING ERRCODE = '22023';
    END IF;
    IF p_publico IS NOT NULL AND UPPER(TRIM(p_publico)) NOT IN ('S', 'N') THEN
        RAISE EXCEPTION 'PUBLICO invalido: % (use ''S'' o ''N'')', p_publico USING ERRCODE = '22023';
    END IF;
    IF p_descriptor_prom IS NOT NULL AND UPPER(TRIM(p_descriptor_prom)) NOT IN ('S', 'N') THEN
        RAISE EXCEPTION 'DESCRIPTOR_PROM invalido: % (use ''S'' o ''N'')', p_descriptor_prom USING ERRCODE = '22023';
    END IF;

    IF p_niveles IS NOT NULL THEN
        IF jsonb_typeof(p_niveles) <> 'array' THEN
            RAISE EXCEPTION 'p_niveles debe ser un arreglo JSON' USING ERRCODE = '22023';
        END IF;
        -- Toda valoracion enviada debe corresponder a un nivel existente del criterio.
        IF EXISTS (
            SELECT 1 FROM jsonb_array_elements(p_niveles) e
             WHERE (e->>'fkTescalaValoracion') IS NULL
                OR NOT EXISTS (
                    SELECT 1 FROM academico_test.TNIVEL_CRITERIO_UNIDAD ncu
                     WHERE ncu.FK_TCRITERIO_UNIDAD = p_pk_tcriterio_unidad
                       AND ncu.FK_TESCALA_VALORACION = (e->>'fkTescalaValoracion')::BIGINT
                       AND ncu.ACTIVE = TRUE
                )
        ) THEN
            RAISE EXCEPTION 'Un nivel referencia una valoracion que no pertenece a este criterio (fkTescalaValoracion invalido o inactivo)'
                USING ERRCODE = '22023';
        END IF;
        IF EXISTS (
            SELECT 1 FROM jsonb_array_elements(p_niveles) e
             WHERE (e ? 'indicador') AND NULLIF(TRIM(e->>'indicador'), '') IS NULL
        ) THEN
            RAISE EXCEPTION 'El indicador de un nivel no puede quedar vacio' USING ERRCODE = '22023';
        END IF;
    END IF;

    UPDATE academico_test.TCRITERIO_UNIDAD
       SET DESCRIPCION     = COALESCE(NULLIF(TRIM(p_descripcion), ''), DESCRIPCION),
           PUBLICO         = COALESCE(UPPER(TRIM(p_publico)), PUBLICO),
           CODIGO          = CASE WHEN p_limpiar_codigo THEN NULL
                                  ELSE COALESCE(NULLIF(TRIM(p_codigo), ''), CODIGO) END,
           DESCRIPTOR_PROM = COALESCE(UPPER(TRIM(p_descriptor_prom)), DESCRIPTOR_PROM),
           MODIFIED_BY     = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT     = CURRENT_TIMESTAMP
     WHERE PK_TCRITERIO_UNIDAD = p_pk_tcriterio_unidad;

    IF p_niveles IS NOT NULL THEN
        UPDATE academico_test.TNIVEL_CRITERIO_UNIDAD ncu
           SET INDICADOR     = COALESCE(NULLIF(TRIM(e.j->>'indicador'), ''), ncu.INDICADOR),
               RECOMENDACION = CASE WHEN e.j ? 'recomendacion' THEN NULLIF(TRIM(e.j->>'recomendacion'), '') ELSE ncu.RECOMENDACION END,
               TAREA         = CASE WHEN e.j ? 'tarea' THEN NULLIF(TRIM(e.j->>'tarea'), '') ELSE ncu.TAREA END,
               MODIFIED_BY   = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT   = CURRENT_TIMESTAMP
          FROM (SELECT elem AS j FROM jsonb_array_elements(p_niveles) elem) e
         WHERE ncu.FK_TCRITERIO_UNIDAD = p_pk_tcriterio_unidad
           AND ncu.FK_TESCALA_VALORACION = (e.j->>'fkTescalaValoracion')::BIGINT
           AND ncu.ACTIVE = TRUE;
    END IF;

    RETURN p_pk_tcriterio_unidad;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_criterio_actualizar(BIGINT, BIGINT, VARCHAR, VARCHAR, VARCHAR, BOOLEAN, VARCHAR, JSONB)
    IS 'PATCH parcial de un criterio de la rubrica de la unidad (gate EDITAR): DESCRIPCION/PUBLICO/CODIGO/DESCRIPTOR_PROM NULL = preservar; p_limpiar_codigo=TRUE fuerza CODIGO a NULL. p_niveles NULL = no tocar; array [{fkTescalaValoracion, indicador?, recomendacion?, tarea?}] actualiza los textos de las filas TNIVEL_CRITERIO_UNIDAD ya existentes de ese criterio (no crea niveles: para cambiar el set de valoraciones se recrea con fn_unidad_criterio_agregar). Retorna PK_TCRITERIO_UNIDAD.';

-- ===========================================================================
-- fn_unidad_criterio_eliminar — soft delete del criterio y sus niveles.
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_criterio_eliminar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tcriterio_unidad      BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_active     BOOLEAN;
    v_niveles    BIGINT := 0;
BEGIN
    SELECT ACTIVE INTO v_active
      FROM academico_test.TCRITERIO_UNIDAD
     WHERE PK_TCRITERIO_UNIDAD = p_pk_tcriterio_unidad;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el criterio de rubrica solicitado' USING ERRCODE = 'P0002';
    END IF;

    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'ELIMINAR'
    );

    IF v_active = FALSE THEN
        RAISE EXCEPTION 'El criterio ya se encuentra inactivo' USING ERRCODE = '22023';
    END IF;

    UPDATE academico_test.TNIVEL_CRITERIO_UNIDAD
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TCRITERIO_UNIDAD = p_pk_tcriterio_unidad AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_niveles = ROW_COUNT;

    UPDATE academico_test.TCRITERIO_UNIDAD
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TCRITERIO_UNIDAD = p_pk_tcriterio_unidad;

    RAISE NOTICE 'Soft delete TCRITERIO_UNIDAD=% (autor: %): niveles=%',
        p_pk_tcriterio_unidad, p_pk_usuario_solicitante, v_niveles;

    RETURN p_pk_tcriterio_unidad;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_criterio_eliminar(BIGINT, BIGINT)
    IS 'Soft delete (ACTIVE=FALSE) de un criterio de la rubrica de la unidad y de sus niveles (TNIVEL_CRITERIO_UNIDAD). Gate ELIMINAR sobre PLANEADOR. No renumera el ORDEN de los criterios restantes. Retorna PK_TCRITERIO_UNIDAD.';
