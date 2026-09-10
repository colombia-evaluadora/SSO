-- ===========================================================================
--  Cobertura Matricula (CU-86e2z8aff) -- consumo/edicion de la configuracion
--  de matricula por el usuario administrativo del establecimiento.
--
--  Roles habilitados: rector, secretaria o jefe de sistema de UN
--  establecimiento -- la misma triada que resuelve fn_resolver_
--  establecimiento_unico (V50):
--    * rector     -> TESTABLECIMIENTO.FK_TFUNCIONARIO_RECTOR
--    * secretaria -> TESTABLECIMIENTO.FK_TFUNCIONARIO_SECRETARIA
--    * jefe sist. -> TSEDE_USUARIO.FK_TROL = 8 en alguna sede del EE
--  (el super-admin usa fn_matricula_config_actualizar de V159, con el EE
--   explicito -- no entra aqui.)
--
--  CU-86e2w4xdt -- Permisos segun rol: fn_matricula_config_ee_solicitante
--  sigue resolviendo QUE establecimiento administra el usuario, pero
--  fn_matricula_config_obtener / _editar_campo aplican ademas
--  fn_assert_permiso_seccion(usuario, 'MATRICULA', 'VER'|'EDITAR', ee):
--  la capability es dinamica y la define el super admin por rol (TROL_MENU)
--  y por usuario (TUSUARIO_ROL_PERMISO, solo recorta) -- ver
--  docs/gate-permisos-por-menu-analysis.md. Un usuario de la triada al que
--  el super admin le haya quitado el menu MATRICULA (o degradado a solo
--  lectura) recibe 42501 aunque siga siendo rector/secretaria/jefe.
--
--   1. fn_matricula_config_ee_solicitante(usuario) -> BIGINT
--        Helper interno: resuelve el EE del solicitante por esos 3 roles.
--        42501 si no tiene ninguno; 22023 si administra 2+ (ambiguo).
--   2. fn_matricula_config_obtener(usuario) -> JSONB
--        Devuelve la configuracion actual del EE del solicitante en un
--        formato comodo de consumo (un objeto con la lista de campos y sus
--        flags como booleanos).
--   3. fn_matricula_config_editar_campo(usuario, fk_campo, requerido, visible)
--        -> JSONB
--        Edita REQUERIDO/VISIBLE de UN campo de esa configuracion. Falla
--        42501 si el campo no es editable (EDITABLE='N'). Devuelve la
--        configuracion completa ya actualizada.
--
--  Codigos de error: 22023 parametro invalido, 42501 sin permiso / campo
--  no editable, 23503 campo inexistente/inactivo.
-- ===========================================================================

SET client_min_messages TO WARNING;
SET search_path TO academico_test, public;

-- ---------------------------------------------------------------------------
-- 1) Helper: EE del solicitante por rol rector / secretaria / jefe de sistema.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_matricula_config_ee_solicitante(
    p_pk_usuario BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_n       INT;
    v_fk_est  BIGINT;
BEGIN
    IF p_pk_usuario IS NULL OR p_pk_usuario <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    SELECT COUNT(*), MIN(pk_establecimiento)
      INTO v_n, v_fk_est
      FROM (
            SELECT e.PK_ESTABLECIMIENTO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_RECTOR
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario
            UNION
            SELECT e.PK_ESTABLECIMIENTO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_SECRETARIA
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario
            UNION
            SELECT DISTINCT s.FK_TESTABLECIMIENTO
              FROM academico_test.TSEDE_USUARIO su
              JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
             WHERE s.ACTIVE = TRUE AND su.ACTIVE = TRUE
               AND su.FK_TROL = 8 AND su.FK_TUSUARIO = p_pk_usuario
      ) ee;

    IF v_n = 0 THEN
        RAISE EXCEPTION 'El usuario no es rector, secretaria ni jefe de sistema de ningun establecimiento'
            USING ERRCODE = '42501';
    END IF;

    IF v_n > 1 THEN
        RAISE EXCEPTION 'El usuario administra % establecimientos; no se puede resolver una configuracion unica', v_n
            USING ERRCODE = '22023';
    END IF;

    RETURN v_fk_est;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_matricula_config_ee_solicitante(BIGINT) IS
    'Helper: resuelve el PK_ESTABLECIMIENTO del que el usuario es rector (FK_TFUNCIONARIO_RECTOR), secretaria (FK_TFUNCIONARIO_SECRETARIA) o jefe de sistema (TSEDE_USUARIO.FK_TROL=8 en alguna sede). RAISE 42501 si no tiene ninguno de esos roles; RAISE 22023 si administra 2+ (ambiguo). Misma triada que fn_resolver_establecimiento_unico (V50).';

-- ---------------------------------------------------------------------------
-- 2) fn_matricula_config_obtener -- configuracion actual, formato de consumo.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_matricula_config_obtener(
    p_pk_usuario_solicitante BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_fk_est    BIGINT;
    v_pk_config BIGINT;
    v_result    JSONB;
BEGIN
    v_fk_est    := academico_test.fn_matricula_config_ee_solicitante(p_pk_usuario_solicitante);

    -- Autorizacion (CU-86e2w4xdt): capability 'VER' sobre el menu MATRICULA
    -- + scope a nivel establecimiento. fn_matricula_config_ee_solicitante
    -- resuelve QUE EE administra el usuario (rector/secretaria/jefe de
    -- sistema); este assert aplica ademas la config granular del super admin
    -- (TROL_MENU concede / TUSUARIO_ROL_PERMISO recorta) y valida el scope.
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'MATRICULA', 'VER', v_fk_est);

    -- get-or-create: el trigger de V159 garantiza que exista, esto es defensivo.
    v_pk_config := academico_test.fn_matricula_config_crear_interno(
                       v_fk_est, p_pk_usuario_solicitante::VARCHAR);

    SELECT jsonb_build_object(
               'fk_establecimiento',  v_fk_est,
               'establecimiento',     (SELECT NOMBRE FROM academico_test.TESTABLECIMIENTO
                                        WHERE PK_ESTABLECIMIENTO = v_fk_est),
               'pk_matricula_config', v_pk_config,
               'campos', COALESCE((
                   SELECT jsonb_agg(jsonb_build_object(
                              'fk_campo',  mc.PK_MATRICULA_CAMPO,
                              'nombre',    mc.NOMBRE,
                              'editable',  (mc.EDITABLE  = 'S'),
                              'requerido', (mv.REQUERIDO = 'S'),
                              'visible',   (mv.VISIBLE   = 'S')
                          ) ORDER BY mc.PK_MATRICULA_CAMPO)
                     FROM academico_test.TMATRICULA_VALOR mv
                     JOIN academico_test.TMATRICULA_CAMPO mc
                       ON mc.PK_MATRICULA_CAMPO = mv.FK_TMATRICULA_CAMPO
                    WHERE mv.FK_TMATRICULA_CONFIG = v_pk_config
                      AND mc.ACTIVE = TRUE
               ), '[]'::jsonb)
           )
      INTO v_result;

    RETURN v_result;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_matricula_config_obtener(BIGINT) IS
    'Devuelve, para el establecimiento del que el solicitante es rector/secretaria/jefe de sistema (fn_matricula_config_ee_solicitante), su configuracion de matricula actual como JSONB: { fk_establecimiento, establecimiento, pk_matricula_config, campos: [{ fk_campo, nombre, editable, requerido, visible }] } con los flags ya como booleanos y los campos en orden de catalogo. 42501 sin rol, 22023 si administra 2+ EE.';

-- ---------------------------------------------------------------------------
-- 3) fn_matricula_config_editar_campo -- edita UN campo, valida editable.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_matricula_config_editar_campo(
    p_pk_usuario_solicitante BIGINT,
    p_fk_campo               BIGINT,
    p_requerido              academico_test.bool_sn DEFAULT NULL,
    p_visible                academico_test.bool_sn DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_fk_est     BIGINT;
    v_pk_config  BIGINT;
    v_editable   academico_test.bool_sn;
    v_nombre     VARCHAR;
    v_actor      VARCHAR := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    v_fk_est := academico_test.fn_matricula_config_ee_solicitante(p_pk_usuario_solicitante);

    -- Autorizacion (CU-86e2w4xdt): capability 'EDITAR' sobre el menu
    -- MATRICULA + scope a nivel establecimiento (ver fn_matricula_config_obtener).
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'MATRICULA', 'EDITAR', v_fk_est);

    IF p_fk_campo IS NULL OR p_fk_campo <= 0 THEN
        RAISE EXCEPTION 'p_fk_campo es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    IF p_requerido IS NULL AND p_visible IS NULL THEN
        RAISE EXCEPTION 'Debe enviar al menos uno de p_requerido / p_visible'
            USING ERRCODE = '22023';
    END IF;

    SELECT EDITABLE, NOMBRE
      INTO v_editable, v_nombre
      FROM academico_test.TMATRICULA_CAMPO
     WHERE PK_MATRICULA_CAMPO = p_fk_campo
       AND ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El campo de matricula % no existe o no esta activo', p_fk_campo
            USING ERRCODE = '23503';
    END IF;

    IF v_editable = 'N' THEN
        RAISE EXCEPTION 'El campo "%" no es editable; su configuracion (requerido/visible) es fija', v_nombre
            USING ERRCODE = '42501',
                  HINT    = 'Solo los campos con editable=true pueden cambiar de requerido/visible';
    END IF;

    v_pk_config := academico_test.fn_matricula_config_crear_interno(v_fk_est, v_actor);

    INSERT INTO academico_test.TMATRICULA_VALOR AS mv (
        REQUERIDO, VISIBLE, FK_TMATRICULA_CONFIG, FK_TMATRICULA_CAMPO, CREATED_BY
    )
    VALUES (
        COALESCE(p_requerido, 'N'),
        COALESCE(p_visible,   'S'),
        v_pk_config, p_fk_campo, v_actor
    )
    ON CONFLICT (FK_TMATRICULA_CONFIG, FK_TMATRICULA_CAMPO) DO UPDATE
       SET REQUERIDO   = COALESCE(p_requerido, mv.REQUERIDO),
           VISIBLE     = COALESCE(p_visible,   mv.VISIBLE),
           MODIFIED_BY = v_actor,
           MODIFIED_AT = CURRENT_TIMESTAMP;

    UPDATE academico_test.TMATRICULA_CONFIG
       SET MODIFIED_BY = v_actor,
           MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_MATRICULA_CONFIG = v_pk_config;

    RETURN academico_test.fn_matricula_config_obtener(p_pk_usuario_solicitante);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_matricula_config_editar_campo(BIGINT, BIGINT, academico_test.bool_sn, academico_test.bool_sn) IS
    'Edita REQUERIDO/VISIBLE (S/N, al menos uno; el que va NULL no se toca) de UN campo en la configuracion de matricula del establecimiento del solicitante (rector/secretaria/jefe de sistema, via fn_matricula_config_ee_solicitante). Errores: 22023 parametros invalidos, 23503 campo inexistente/inactivo, 42501 sin rol o campo no editable (EDITABLE=''N''). Upsert por U_TMATRICULA_VALOR_1. Devuelve la configuracion completa ya actualizada (mismo shape que fn_matricula_config_obtener).';
