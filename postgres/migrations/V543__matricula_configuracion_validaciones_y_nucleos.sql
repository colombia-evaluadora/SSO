-- V543 — Configuración de matrícula por capas (1 de 3): validaciones y núcleos.
--
-- Qué hace: saca de fn_matricula_config_obtener / _editar_campo la lógica que
-- no depende del usuario: armar la configuración de UN establecimiento y
-- escribir un campo en ella. Antes las dos deducían el establecimiento del
-- usuario y fallaban (22023) con un rector de dos o más colegios; ahora el
-- establecimiento lo resuelve el wrapper (V544) y llega aquí ya decidido.
-- Por qué aquí: módulo de configuración de matrícula, que no estaba por capas
-- (V159, V180-V182); un cambio futuro edita esta migración.
-- Depende de: V159 (fn_matricula_config_crear_interno, tablas), V180.

-- ============================================================ validaciones
CREATE OR REPLACE FUNCTION academico_test.fn_matricula_config_validar_establecimiento(
    p_fk_establecimiento BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $function$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM academico_test.TESTABLECIMIENTO
                    WHERE PK_ESTABLECIMIENTO = p_fk_establecimiento AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'No se encontro el establecimiento solicitado'
            USING ERRCODE = 'P0002';
    END IF;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_matricula_config_validar_establecimiento(BIGINT)
    IS 'Valida que el establecimiento exista y este activo (P0002). Sin gate. La usa fn_matricula_config_establecimiento cuando el establecimiento llega explicito.';

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_config_validar_cambio(
    p_requerido academico_test.bool_sn,
    p_visible   academico_test.bool_sn
)
RETURNS VOID
LANGUAGE plpgsql
IMMUTABLE
AS $function$
BEGIN
    IF p_requerido IS NULL AND p_visible IS NULL THEN
        RAISE EXCEPTION 'Debe indicar si el campo es requerido, visible o ambos'
            USING ERRCODE = '22023';
    END IF;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_matricula_config_validar_cambio(academico_test.bool_sn, academico_test.bool_sn)
    IS 'Valida que un cambio de configuracion de matricula traiga al menos requerido o visible (22023). Sin gate.';

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_config_validar_campo_editable(
    p_fk_campo BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_editable academico_test.bool_sn;
    v_nombre   VARCHAR;
BEGIN
    IF p_fk_campo IS NULL OR p_fk_campo <= 0 THEN
        RAISE EXCEPTION 'Debe indicar el campo de matricula a configurar'
            USING ERRCODE = '22023';
    END IF;

    SELECT EDITABLE, NOMBRE
      INTO v_editable, v_nombre
      FROM academico_test.TMATRICULA_CAMPO
     WHERE PK_MATRICULA_CAMPO = p_fk_campo
       AND ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El campo de matricula indicado no existe o no esta activo'
            USING ERRCODE = '23503';
    END IF;

    IF v_editable = 'N' THEN
        RAISE EXCEPTION 'El campo "%" no es editable; su configuracion (requerido/visible) es fija', v_nombre
            USING ERRCODE = '42501',
                  HINT    = 'Solo los campos con editable=true pueden cambiar de requerido/visible';
    END IF;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_matricula_config_validar_campo_editable(BIGINT)
    IS 'Valida que el campo del catalogo TMATRICULA_CAMPO exista y este activo (23503) y que su configuracion se pueda cambiar (EDITABLE = S; si no, 42501 con el nombre del campo). Sin gate. La usa fn_matricula_config_editar_campo.';

-- ============================================================ núcleos
CREATE OR REPLACE FUNCTION academico_test.fn_matricula_config_obtener_interno(
    p_fk_establecimiento BIGINT,
    p_actor              VARCHAR
)
RETURNS JSONB
LANGUAGE plpgsql
AS $function$
DECLARE
    v_pk_config BIGINT;
    v_result    JSONB;
BEGIN
    -- Un establecimiento sin configuracion la recibe con los valores por
    -- defecto del catalogo la primera vez que alguien la pide.
    v_pk_config := academico_test.fn_matricula_config_crear_interno(p_fk_establecimiento, p_actor);

    SELECT jsonb_build_object(
               'fk_establecimiento',  p_fk_establecimiento,
               'establecimiento',     (SELECT NOMBRE FROM academico_test.TESTABLECIMIENTO
                                        WHERE PK_ESTABLECIMIENTO = p_fk_establecimiento),
               'pk_matricula_config', v_pk_config,
               'secciones', COALESCE((
                   SELECT jsonb_agg(s.seccion_obj ORDER BY s.orden, s.seccion)
                     FROM (
                         SELECT COALESCE(mc.SECCION, 'Otros') AS seccion,
                                MIN(COALESCE(mc.SECCION_ORDEN, 32767)) AS orden,
                                jsonb_build_object(
                                    'seccion', COALESCE(mc.SECCION, 'Otros'),
                                    'campos',  jsonb_agg(jsonb_build_object(
                                                   'fk_campo',  mc.PK_MATRICULA_CAMPO,
                                                   'nombre',    mc.NOMBRE,
                                                   'editable',  (mc.EDITABLE  = 'S'),
                                                   'requerido', (mv.REQUERIDO = 'S'),
                                                   'visible',   (mv.VISIBLE   = 'S')
                                               ) ORDER BY mc.PK_MATRICULA_CAMPO)
                                ) AS seccion_obj
                           FROM academico_test.TMATRICULA_VALOR mv
                           JOIN academico_test.TMATRICULA_CAMPO mc
                             ON mc.PK_MATRICULA_CAMPO = mv.FK_TMATRICULA_CAMPO
                          WHERE mv.FK_TMATRICULA_CONFIG = v_pk_config
                            AND mc.ACTIVE = TRUE
                          GROUP BY COALESCE(mc.SECCION, 'Otros')
                     ) s
               ), '[]'::jsonb)
           )
      INTO v_result;

    RETURN v_result;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_matricula_config_obtener_interno(BIGINT, VARCHAR)
    IS 'INTERNO: la configuracion de matricula de UN establecimiento -- { fk_establecimiento, establecimiento, pk_matricula_config, secciones: [{ seccion, campos: [{ fk_campo, nombre, editable, requerido, visible }] }] } --, creandola con los valores por defecto del catalogo si aun no existe (p_actor queda como su autor). Sin gate. La usan fn_matricula_config_obtener y fn_matricula_config_editar_campo_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_config_editar_campo_interno(
    p_fk_establecimiento BIGINT,
    p_fk_campo           BIGINT,
    p_requerido          academico_test.bool_sn,
    p_visible            academico_test.bool_sn,
    p_actor              VARCHAR
)
RETURNS JSONB
LANGUAGE plpgsql
AS $function$
DECLARE
    v_pk_config BIGINT;
BEGIN
    v_pk_config := academico_test.fn_matricula_config_crear_interno(p_fk_establecimiento, p_actor);

    INSERT INTO academico_test.TMATRICULA_VALOR AS mv (
        REQUERIDO, VISIBLE, FK_TMATRICULA_CONFIG, FK_TMATRICULA_CAMPO, CREATED_BY
    )
    VALUES (
        COALESCE(p_requerido, 'N'),
        COALESCE(p_visible,   'S'),
        v_pk_config, p_fk_campo, p_actor
    )
    ON CONFLICT (FK_TMATRICULA_CONFIG, FK_TMATRICULA_CAMPO) DO UPDATE
       SET REQUERIDO   = COALESCE(p_requerido, mv.REQUERIDO),
           VISIBLE     = COALESCE(p_visible,   mv.VISIBLE),
           MODIFIED_BY = p_actor,
           MODIFIED_AT = CURRENT_TIMESTAMP;

    UPDATE academico_test.TMATRICULA_CONFIG
       SET MODIFIED_BY = p_actor,
           MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_MATRICULA_CONFIG = v_pk_config;

    RETURN academico_test.fn_matricula_config_obtener_interno(p_fk_establecimiento, p_actor);
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_matricula_config_editar_campo_interno(BIGINT, BIGINT, academico_test.bool_sn, academico_test.bool_sn, VARCHAR)
    IS 'INTERNO: cambia requerido y/o visible (NULL = sin cambio) de un campo en la configuracion de matricula de UN establecimiento y devuelve esa configuracion completa (fn_matricula_config_obtener_interno). Sin gate, sin validaciones ni etiqueta de auditoria: las aplica fn_matricula_config_editar_campo antes de llamarlo.';
