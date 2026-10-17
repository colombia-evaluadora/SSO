-- V320 - Criterios de prioridad, capa 3 de 4: wrappers con gate.
-- Menú CRITERIOS_PRIORIDAD (V321), solo del Superadministrador y sin alcance:
-- los criterios son globales (Regla 7). Cada escritura declara su etiqueta de
-- auditoría antes de delegar en el núcleo de V319. La evaluación para Cobertura
-- no tiene gate de menú: la acotan los roles del endpoint, como la matrícula.
-- Depende de: V319 (núcleos), V29 (fn_assert_permiso_seccion), V66 (fn_audit_declarar).

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_criterioprio_listar(p_pk_usuario_solicitante BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(p_pk_usuario_solicitante, 'CRITERIOS_PRIORIDAD', 'VER');
    RETURN academico_test.fn_criterioprio_listar_interno();
END;
$$;

COMMENT ON FUNCTION academico_test.fn_criterioprio_listar(BIGINT)
    IS 'GET /criterios-prioridad: criterios no eliminados (fn_criterioprio_listar_interno). Gate VER sobre CRITERIOS_PRIORIDAD.';

CREATE OR REPLACE FUNCTION academico_test.fn_criterioprio_detalle(
    p_pk_usuario_solicitante BIGINT,
    p_pk_criterio            BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(p_pk_usuario_solicitante, 'CRITERIOS_PRIORIDAD', 'VER');
    PERFORM academico_test.fn_criterioprio_validar_existente(p_pk_criterio);
    RETURN academico_test.fn_criterioprio_json_interno(p_pk_criterio);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_criterioprio_detalle(BIGINT, BIGINT)
    IS 'GET /criterios-prioridad/:ID. Gate VER sobre CRITERIOS_PRIORIDAD; P0002 si no existe.';

CREATE OR REPLACE FUNCTION academico_test.fn_criterioprio_campos(p_pk_usuario_solicitante BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(p_pk_usuario_solicitante, 'CRITERIOS_PRIORIDAD', 'VER');
    RETURN academico_test.fn_criterioprio_campos_interno();
END;
$$;

COMMENT ON FUNCTION academico_test.fn_criterioprio_campos(BIGINT)
    IS 'GET /catalogos/criterios-prioridad/campos: bloques y campos evaluables con sus reglas (fn_criterioprio_campos_interno). Gate VER sobre CRITERIOS_PRIORIDAD.';

CREATE OR REPLACE FUNCTION academico_test.fn_criterioprio_crear(
    p_pk_usuario_solicitante BIGINT,
    p_nombre                 VARCHAR,
    p_descripcion            VARCHAR,
    p_pk_campo               BIGINT,
    p_pk_regla               BIGINT,
    p_valores                BIGINT[] DEFAULT NULL,
    p_habilitado             BOOLEAN  DEFAULT TRUE
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(p_pk_usuario_solicitante, 'CRITERIOS_PRIORIDAD', 'CREAR');
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Criterios de prioridad: crear el criterio %s', TRIM(p_nombre)));
    RETURN academico_test.fn_criterioprio_crear_interno(p_pk_usuario_solicitante, p_nombre, p_descripcion,
                                                        p_pk_campo, p_pk_regla, p_valores, p_habilitado);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_criterioprio_crear(BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT[], BOOLEAN)
    IS 'POST /criterios-prioridad (fn_criterioprio_crear_interno). Gate CREAR sobre CRITERIOS_PRIORIDAD.';

CREATE OR REPLACE FUNCTION academico_test.fn_criterioprio_actualizar(
    p_pk_usuario_solicitante BIGINT,
    p_pk_criterio            BIGINT,
    p_nombre                 VARCHAR,
    p_descripcion            VARCHAR,
    p_pk_campo               BIGINT,
    p_pk_regla               BIGINT,
    p_valores                BIGINT[] DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(p_pk_usuario_solicitante, 'CRITERIOS_PRIORIDAD', 'EDITAR');
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Criterios de prioridad: modificar el criterio %s', TRIM(p_nombre)));
    RETURN academico_test.fn_criterioprio_actualizar_interno(p_pk_usuario_solicitante, p_pk_criterio, p_nombre,
                                                             p_descripcion, p_pk_campo, p_pk_regla, p_valores);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_criterioprio_actualizar(BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT[])
    IS 'PUT /criterios-prioridad/:ID (fn_criterioprio_actualizar_interno). Gate EDITAR sobre CRITERIOS_PRIORIDAD.';

CREATE OR REPLACE FUNCTION academico_test.fn_criterioprio_estado(
    p_pk_usuario_solicitante BIGINT,
    p_pk_criterio            BIGINT,
    p_habilitado             BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(p_pk_usuario_solicitante, 'CRITERIOS_PRIORIDAD', 'EDITAR');
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Criterios de prioridad: %s el criterio %s',
               CASE WHEN p_habilitado THEN 'activar' ELSE 'desactivar' END,
               (SELECT NOMBRE FROM academico_test.TCRITERIO_PRIORIDAD WHERE PK_TCRITERIO_PRIORIDAD = p_pk_criterio)));
    RETURN academico_test.fn_criterioprio_estado_interno(p_pk_usuario_solicitante, p_pk_criterio, p_habilitado);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_criterioprio_estado(BIGINT, BIGINT, BOOLEAN)
    IS 'PUT /criterios-prioridad/:ID/estado (fn_criterioprio_estado_interno). Gate EDITAR sobre CRITERIOS_PRIORIDAD.';

CREATE OR REPLACE FUNCTION academico_test.fn_criterioprio_eliminar(
    p_pk_usuario_solicitante BIGINT,
    p_pk_criterio            BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(p_pk_usuario_solicitante, 'CRITERIOS_PRIORIDAD', 'ELIMINAR');
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Criterios de prioridad: eliminar el criterio %s',
               (SELECT NOMBRE FROM academico_test.TCRITERIO_PRIORIDAD WHERE PK_TCRITERIO_PRIORIDAD = p_pk_criterio)));
    RETURN academico_test.fn_criterioprio_eliminar_interno(p_pk_usuario_solicitante, p_pk_criterio);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_criterioprio_eliminar(BIGINT, BIGINT)
    IS 'PUT /criterios-prioridad/:ID/eliminar (fn_criterioprio_eliminar_interno). Gate ELIMINAR sobre CRITERIOS_PRIORIDAD.';
