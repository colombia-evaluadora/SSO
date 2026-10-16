-- V316 - Catálogo de Áreas oficiales, capa 3 de 4: wrappers con gate.
-- Menú AREAS_OFICIALES (V317), solo del Superadministrador y sin alcance: el
-- catálogo es global (Regla 5). Cada escritura declara su etiqueta de
-- auditoría antes de delegar en el núcleo de V315.
-- Depende de: V315 (núcleos), V29 (fn_assert_permiso_seccion), V66 (fn_audit_declarar).

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_areaoficial_listar(
    p_pk_usuario_solicitante BIGINT,
    p_buscar                 VARCHAR DEFAULT NULL,
    p_nivel                  BIGINT  DEFAULT NULL,
    p_habilitada             BOOLEAN DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(p_pk_usuario_solicitante, 'AREAS_OFICIALES', 'VER');
    RETURN academico_test.fn_areaoficial_listar_interno(p_buscar, p_nivel, p_habilitada);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_areaoficial_listar(BIGINT, VARCHAR, BIGINT, BOOLEAN)
    IS 'GET /areas-oficiales?BUSCAR=&NIVEL=&HABILITADA=: áreas oficiales no eliminadas (fn_areaoficial_listar_interno). Gate VER sobre AREAS_OFICIALES.';

CREATE OR REPLACE FUNCTION academico_test.fn_areaoficial_detalle(
    p_pk_usuario_solicitante BIGINT,
    p_pk_area                BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(p_pk_usuario_solicitante, 'AREAS_OFICIALES', 'VER');
    PERFORM academico_test.fn_areaoficial_validar_existente(p_pk_area);
    RETURN academico_test.fn_areaoficial_json_interno(p_pk_area);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_areaoficial_detalle(BIGINT, BIGINT)
    IS 'GET /areas-oficiales/:ID: un área oficial con sus niveles y usos. Gate VER sobre AREAS_OFICIALES; P0002 si no existe.';

CREATE OR REPLACE FUNCTION academico_test.fn_areaoficial_crear(
    p_pk_usuario_solicitante BIGINT,
    p_nombre                 VARCHAR,
    p_niveles                BIGINT[]
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(p_pk_usuario_solicitante, 'AREAS_OFICIALES', 'CREAR');
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Áreas oficiales: crear el área %s', TRIM(p_nombre)));
    RETURN academico_test.fn_areaoficial_crear_interno(p_pk_usuario_solicitante, p_nombre, p_niveles);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_areaoficial_crear(BIGINT, VARCHAR, BIGINT[])
    IS 'POST /areas-oficiales: crea un área oficial (fn_areaoficial_crear_interno). Gate CREAR sobre AREAS_OFICIALES.';

CREATE OR REPLACE FUNCTION academico_test.fn_areaoficial_actualizar(
    p_pk_usuario_solicitante BIGINT,
    p_pk_area                BIGINT,
    p_nombre                 VARCHAR,
    p_niveles                BIGINT[]
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(p_pk_usuario_solicitante, 'AREAS_OFICIALES', 'EDITAR');
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Áreas oficiales: modificar el área %s', TRIM(p_nombre)));
    RETURN academico_test.fn_areaoficial_actualizar_interno(p_pk_usuario_solicitante, p_pk_area, p_nombre, p_niveles);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_areaoficial_actualizar(BIGINT, BIGINT, VARCHAR, BIGINT[])
    IS 'PUT /areas-oficiales/:ID: nombre y niveles (fn_areaoficial_actualizar_interno). Gate EDITAR sobre AREAS_OFICIALES.';

CREATE OR REPLACE FUNCTION academico_test.fn_areaoficial_estado(
    p_pk_usuario_solicitante BIGINT,
    p_pk_area                BIGINT,
    p_habilitada             BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(p_pk_usuario_solicitante, 'AREAS_OFICIALES', 'EDITAR');
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Áreas oficiales: %s el área %s',
               CASE WHEN p_habilitada THEN 'activar' ELSE 'inactivar' END,
               (SELECT NOMBRE FROM academico_test.TAREA_ASIGNATURA WHERE PK_TAREA_ASIGNATURA = p_pk_area)));
    RETURN academico_test.fn_areaoficial_estado_interno(p_pk_usuario_solicitante, p_pk_area, p_habilitada);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_areaoficial_estado(BIGINT, BIGINT, BOOLEAN)
    IS 'PUT /areas-oficiales/:ID/estado: activa o inactiva (fn_areaoficial_estado_interno). Gate EDITAR sobre AREAS_OFICIALES.';

CREATE OR REPLACE FUNCTION academico_test.fn_areaoficial_eliminar(
    p_pk_usuario_solicitante BIGINT,
    p_pk_area                BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(p_pk_usuario_solicitante, 'AREAS_OFICIALES', 'ELIMINAR');
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Áreas oficiales: eliminar el área %s',
               (SELECT NOMBRE FROM academico_test.TAREA_ASIGNATURA WHERE PK_TAREA_ASIGNATURA = p_pk_area)));
    RETURN academico_test.fn_areaoficial_eliminar_interno(p_pk_usuario_solicitante, p_pk_area);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_areaoficial_eliminar(BIGINT, BIGINT)
    IS 'PUT /areas-oficiales/:ID/eliminar: baja lógica de un área nunca usada (fn_areaoficial_eliminar_interno). Gate ELIMINAR sobre AREAS_OFICIALES.';
