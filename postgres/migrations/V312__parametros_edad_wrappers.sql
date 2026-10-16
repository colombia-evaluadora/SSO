-- V312 - Parámetros de edad, capa 4 de 5: wrappers con gate.
-- Gate sobre el menú PARAMETROS_EDAD (solo Superadministrador). Guardar pide
-- EDITAR aunque cree la fila: la vista no distingue alta de modificación.
-- Depende de: V311 (núcleos), V310 (validaciones), V29
-- (fn_assert_permiso_seccion), V66 (fn_audit_declarar).

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_parametroedad_listar(p_pk_usuario_solicitante BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(p_pk_usuario_solicitante, 'PARAMETROS_EDAD', 'VER');
    RETURN academico_test.fn_parametroedad_listar_interno();
END;
$$;

COMMENT ON FUNCTION academico_test.fn_parametroedad_listar(BIGINT)
    IS 'GET /parametros-edad: edades recomendadas por grado y fechas de corte por calendario (fn_parametroedad_listar_interno). Errores: 403 (42501) sin VER sobre PARAMETROS_EDAD.';

CREATE OR REPLACE FUNCTION academico_test.fn_parametroedad_grado_guardar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tlv_grado           BIGINT,
    p_edad                   INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_parametroedad_validar_valor_lista(p_fk_tlv_grado, 'GRADOS', 'grado');
    PERFORM academico_test.fn_assert_permiso_seccion(p_pk_usuario_solicitante, 'PARAMETROS_EDAD', 'EDITAR');
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Parámetros de edad: edad recomendada de %s', academico_test.fn_listavalor_etiqueta(p_fk_tlv_grado)));
    RETURN academico_test.fn_parametroedad_grado_guardar_interno(p_pk_usuario_solicitante, p_fk_tlv_grado, p_edad);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_parametroedad_grado_guardar(BIGINT, BIGINT, INTEGER)
    IS 'PUT /parametros-edad/grados/:GRADO: crea o modifica la edad recomendada del grado. Orden: 404 (P0002) grado → 403 (42501) sin EDITAR sobre PARAMETROS_EDAD → 400 (22023) edad fuera de 2-25.';

CREATE OR REPLACE FUNCTION academico_test.fn_parametroedad_calendario_guardar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tlv_calendario      BIGINT,
    p_mes                    INTEGER,
    p_dia                    INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_parametroedad_validar_valor_lista(p_fk_tlv_calendario, 'CALENDARIO', 'calendario');
    PERFORM academico_test.fn_assert_permiso_seccion(p_pk_usuario_solicitante, 'PARAMETROS_EDAD', 'EDITAR');
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Parámetros de edad: fecha de corte de %s', academico_test.fn_listavalor_etiqueta(p_fk_tlv_calendario)));
    RETURN academico_test.fn_parametroedad_calendario_guardar_interno(
        p_pk_usuario_solicitante, p_fk_tlv_calendario, p_mes, p_dia);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_parametroedad_calendario_guardar(BIGINT, BIGINT, INTEGER, INTEGER)
    IS 'PUT /parametros-edad/calendarios/:CALENDARIO: crea o modifica la fecha de corte del calendario. Orden: 404 (P0002) calendario → 403 (42501) sin EDITAR sobre PARAMETROS_EDAD → 400 (22023) mes, día inexistente o 29 de febrero.';

CREATE OR REPLACE FUNCTION academico_test.fn_parametroedad_grado_eliminar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tlv_grado           BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_parametroedad_validar_valor_lista(p_fk_tlv_grado, 'GRADOS', 'grado');
    PERFORM academico_test.fn_assert_permiso_seccion(p_pk_usuario_solicitante, 'PARAMETROS_EDAD', 'ELIMINAR');
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Parámetros de edad: quitar la edad recomendada de %s', academico_test.fn_listavalor_etiqueta(p_fk_tlv_grado)));
    RETURN academico_test.fn_parametroedad_grado_eliminar_interno(p_fk_tlv_grado);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_parametroedad_grado_eliminar(BIGINT, BIGINT)
    IS 'PUT /parametros-edad/grados/:GRADO/eliminar: quita la edad recomendada del grado. Orden: 404 (P0002) grado inexistente → 403 (42501) sin ELIMINAR sobre PARAMETROS_EDAD → 404 (P0002) el grado no tenía edad.';

CREATE OR REPLACE FUNCTION academico_test.fn_parametroedad_calendario_eliminar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tlv_calendario      BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_parametroedad_validar_valor_lista(p_fk_tlv_calendario, 'CALENDARIO', 'calendario');
    PERFORM academico_test.fn_assert_permiso_seccion(p_pk_usuario_solicitante, 'PARAMETROS_EDAD', 'ELIMINAR');
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Parámetros de edad: quitar la fecha de corte de %s', academico_test.fn_listavalor_etiqueta(p_fk_tlv_calendario)));
    RETURN academico_test.fn_parametroedad_calendario_eliminar_interno(p_fk_tlv_calendario);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_parametroedad_calendario_eliminar(BIGINT, BIGINT)
    IS 'PUT /parametros-edad/calendarios/:CALENDARIO/eliminar: quita la fecha de corte del calendario. Orden: 404 (P0002) calendario inexistente → 403 (42501) sin ELIMINAR sobre PARAMETROS_EDAD → 404 (P0002) el calendario no tenía fecha de corte.';
