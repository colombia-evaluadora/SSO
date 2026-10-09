-- V544 — Configuración de matrícula por capas (2 de 3): wrappers con gate.
--
-- Qué hace: obtener y editar un campo reciben un establecimiento OPCIONAL.
-- Sin él responden como antes (el único que el usuario administra, o 22023 si
-- administra varios); con él, validan que exista y piden el permiso de
-- MATRICULA sobre ESE establecimiento. Así un rector de dos colegios elige
-- cuál configurar, y el alta pide la del colegio de la sede elegida.
-- Editar un campo declara ahora su etiqueta de auditoría.
-- Por qué aquí: módulo de configuración de matrícula por capas.
-- Depende de: V543 (núcleos), V180 (fn_matricula_config_ee_solicitante).

-- Cambian de aridad: sin el DROP quedarian dos firmas vivas.
DROP FUNCTION IF EXISTS academico_test.fn_matricula_config_obtener(BIGINT);
DROP FUNCTION IF EXISTS academico_test.fn_matricula_config_editar_campo(BIGINT, BIGINT, academico_test.bool_sn, academico_test.bool_sn);

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_config_establecimiento(
    p_pk_usuario_solicitante BIGINT,
    p_fk_establecimiento     BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
STABLE
AS $function$
BEGIN
    IF p_fk_establecimiento IS NULL THEN
        RETURN academico_test.fn_matricula_config_ee_solicitante(p_pk_usuario_solicitante);
    END IF;

    PERFORM academico_test.fn_matricula_config_validar_establecimiento(p_fk_establecimiento);
    RETURN p_fk_establecimiento;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_matricula_config_establecimiento(BIGINT, BIGINT)
    IS 'De que establecimiento es la configuracion de matricula que se pide. Con p_fk_establecimiento lo valida (P0002) y lo devuelve; el permiso sobre el lo pide quien llama. Sin el, el unico que el usuario administra (fn_matricula_config_ee_solicitante: 42501 si ninguno, 22023 si varios), como antes. La usan fn_matricula_config_obtener y fn_matricula_config_editar_campo.';

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_config_obtener(
    p_pk_usuario_solicitante BIGINT,
    p_fk_establecimiento     BIGINT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
AS $function$
DECLARE
    v_fk_est BIGINT;
BEGIN
    v_fk_est := academico_test.fn_matricula_config_establecimiento(
                    p_pk_usuario_solicitante, p_fk_establecimiento);

    -- Sin establecimiento explicito el resolutor ya exige ser rector,
    -- secretaria o jefe de sistema de ese colegio. Con el, cualquiera puede
    -- nombrar uno, asi que el alcance se pide aqui.
    IF p_fk_establecimiento IS NOT NULL THEN
        PERFORM academico_test.fn_assert_permiso_seccion(
            p_pk_usuario_solicitante, 'MATRICULA', 'VER', v_fk_est);
    END IF;

    RETURN academico_test.fn_matricula_config_obtener_interno(
               v_fk_est, p_pk_usuario_solicitante::VARCHAR);
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_matricula_config_obtener(BIGINT, BIGINT)
    IS 'GET /matricula/configuracion: la configuracion de campos de matricula (que es visible y que es obligatorio) de un establecimiento. QUERY.FK_ESTABLECIMIENTO es opcional: sin el, la del unico establecimiento que el usuario administra (22023 si administra varios); con el, la de ese establecimiento, pidiendo MATRICULA/VER sobre el. Delega en fn_matricula_config_obtener_interno, donde esta la forma de la respuesta.';

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_config_editar_campo(
    p_pk_usuario_solicitante BIGINT,
    p_fk_campo               BIGINT,
    p_requerido              academico_test.bool_sn DEFAULT NULL,
    p_visible                academico_test.bool_sn DEFAULT NULL,
    p_fk_establecimiento     BIGINT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
AS $function$
DECLARE
    v_fk_est BIGINT;
BEGIN
    v_fk_est := academico_test.fn_matricula_config_establecimiento(
                    p_pk_usuario_solicitante, p_fk_establecimiento);

    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'MATRICULA', 'EDITAR', v_fk_est);

    PERFORM academico_test.fn_matricula_config_validar_cambio(p_requerido, p_visible);
    PERFORM academico_test.fn_matricula_config_validar_campo_editable(p_fk_campo);

    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        format('Configuracion de matricula de %s: campo %s',
               (SELECT NOMBRE FROM academico_test.TESTABLECIMIENTO WHERE PK_ESTABLECIMIENTO = v_fk_est),
               (SELECT NOMBRE FROM academico_test.TMATRICULA_CAMPO WHERE PK_MATRICULA_CAMPO = p_fk_campo)),
        v_fk_est, NULL);

    RETURN academico_test.fn_matricula_config_editar_campo_interno(
               v_fk_est, p_fk_campo, p_requerido, p_visible, p_pk_usuario_solicitante::VARCHAR);
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_matricula_config_editar_campo(BIGINT, BIGINT, academico_test.bool_sn, academico_test.bool_sn, BIGINT)
    IS 'PUT /matricula/configuracion/campo/:ID: cambia requerido y/o visible de un campo en la configuracion de matricula y devuelve la configuracion completa de ese establecimiento. BODY.FK_ESTABLECIMIENTO es opcional: sin el, el unico establecimiento que el usuario administra (22023 si administra varios). Pide MATRICULA/EDITAR sobre el establecimiento, valida el cambio y que el campo sea editable, declara la etiqueta de auditoria y delega en fn_matricula_config_editar_campo_interno.';
