-- ===========================================================================
-- V303 - fn_usuario_permisos_menu: capabilities por menu para el front
-- (GET /usuarios/permisos-menu) y base del gate fn_usuario_puede_en_menu.
--
-- El super admin del SSO (fn_es_super_admin_sso) obtiene todos los menus
-- activos con los cuatro permisos, igual que el bypass de nivel 0 del gate.
-- El CODIGO sale en forma canonica: el front compara el texto exacto y un menu
-- creado como MATRÍCULA debe llegarle como MATRICULA.
--
-- Depende de: V29 (fn_menu_codigo_canonico), V302 (fn_es_super_admin_sso),
-- V99 (TROL_MENU.SOLO_LECTURA).
-- ===========================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_usuario_permisos_menu(p_pk_tusuario BIGINT)
RETURNS TABLE(
    pk_tmenu        BIGINT,
    codigo          CHARACTER VARYING,
    nombre          CHARACTER VARYING,
    path            CHARACTER VARYING,
    puede_crear     BOOLEAN,
    puede_editar    BOOLEAN,
    puede_eliminar  BOOLEAN,
    puede_ver       BOOLEAN
)
LANGUAGE plpgsql
STABLE
AS $function$
BEGIN
    -- ---------------------------------------------------------------------
    -- Super admin del SSO: todos los menus activos, los cuatro
    -- permisos. Es la traduccion a capabilities del mismo nivel 0 que
    -- fn_assert_permiso_seccion aplica en su paso 0 (ver cabecera).
    -- ---------------------------------------------------------------------
    IF academico_test.fn_es_super_admin_sso(p_pk_tusuario) THEN
        RETURN QUERY
        SELECT m.PK_TMENU,
               academico_test.fn_menu_codigo_canonico(m.CODIGO),
               m.NOMBRE,
               m.URL,
               TRUE, TRUE, TRUE, TRUE
          FROM academico_test.TMENU m
         WHERE m.ACTIVE = TRUE
         ORDER BY m.NOMBRE ASC, m.PK_TMENU ASC;
        RETURN;
    END IF;

    -- ---------------------------------------------------------------------
    -- Rama normal.
    -- ---------------------------------------------------------------------
    RETURN QUERY
    WITH roles_activos AS (
        -- Roles que el usuario tiene HOY, en cualquier sede.
        SELECT DISTINCT su.FK_TROL AS pk_trol
          FROM academico_test.TSEDE_USUARIO su
         WHERE su.FK_TUSUARIO = p_pk_tusuario
           AND su.ACTIVE = TRUE
    ),
    menus_del_rol AS (
        -- Cada combinacion (rol, menu) concedida -- puede haber mas de una
        -- fila por PK_TMENU si varios roles del usuario lo conceden.
        -- rm.SOLO_LECTURA (columna agregada por V99, escrita por
        -- fn_associate_menus_to_rol de V123) define la CONCESION base del
        -- rol para ese menu:
        --   'SI'            -> solo ver (crear/editar/eliminar FALSE).
        --   NULL / distinto -> los 4 permisos (comportamiento historico).
        SELECT rm.PK_TROL_MENU, m.PK_TMENU, m.CODIGO, m.NOMBRE, m.URL,
               (rm.SOLO_LECTURA IS DISTINCT FROM 'SI') AS base_puede_editar_like
          FROM roles_activos ra
          JOIN academico_test.TROL_MENU rm
            ON rm.FK_TROL = ra.pk_trol AND rm.ACTIVE = TRUE
          JOIN academico_test.TMENU m
            ON m.PK_TMENU = rm.FK_TMENU AND m.ACTIVE = TRUE
    ),
    bloqueos AS (
        -- Recorte del usuario por TROL_MENU. CU-86e2w4xdt: SOLO recorta una
        -- fila activa con SOLO_LECTURA = 'SI'. Con SOLO_LECTURA desactivado
        -- ('NO' / NULL) la fila no aparece aqui y no recorta nada.
        SELECT DISTINCT p.FK_TROL_MENU
          FROM academico_test.TUSUARIO_ROL_PERMISO p
         WHERE p.FK_TUSUARIO = p_pk_tusuario
           AND p.ACTIVE = TRUE
           AND p.SOLO_LECTURA = 'SI'
    ),
    permisos_por_combo AS (
        -- Permisos por CADA combinacion (rol, menu) concedida, antes de
        -- colapsar por PK_TMENU: base del rol (rm.SOLO_LECTURA) menos el
        -- recorte del usuario. El recorte (SOLO_LECTURA='SI') solo baja
        -- crear/editar/eliminar; VER se conserva SIEMPRE en un menu concedido.
        SELECT mr.PK_TMENU, mr.CODIGO, mr.NOMBRE, mr.URL,
               mr.base_puede_editar_like AND (b.FK_TROL_MENU IS NULL) AS puede_editar_like,
               TRUE                                                   AS puede_ver_combo
          FROM menus_del_rol mr
          LEFT JOIN bloqueos b ON b.FK_TROL_MENU = mr.PK_TROL_MENU
    )
    -- Los MIN() se castean a VARCHAR a proposito: devuelven TEXT, y
    -- RETURN QUERY de plpgsql compara los tipos de forma estricta, mientras
    -- que el LANGUAGE sql anterior los coercionaba solo. Sin el cast, esta
    -- rama revienta con "Returned type text does not match expected type
    -- character varying in column 2" para TODO usuario no super admin.
    SELECT pc.PK_TMENU,
           academico_test.fn_menu_codigo_canonico(MIN(pc.CODIGO)::CHARACTER VARYING),
           MIN(pc.NOMBRE)::CHARACTER VARYING,
           MIN(pc.URL)::CHARACTER VARYING,
           bool_or(pc.puede_editar_like) AS puede_crear,
           bool_or(pc.puede_editar_like) AS puede_editar,
           bool_or(pc.puede_editar_like) AS puede_eliminar,
           bool_or(pc.puede_ver_combo)   AS puede_ver
      FROM permisos_por_combo pc
     GROUP BY pc.PK_TMENU
     ORDER BY MIN(pc.NOMBRE) ASC, pc.PK_TMENU ASC;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_usuario_permisos_menu(BIGINT) IS
    'Capabilities por menu para el front (GET /usuarios/permisos-menu); CODIGO en forma canonica (fn_menu_codigo_canonico). El super admin del SSO (fn_es_super_admin_sso) obtiene todos los menus activos con los cuatro permisos, en linea con el bypass de nivel 0 de fn_assert_permiso_seccion.';
