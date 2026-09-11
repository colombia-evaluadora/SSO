-- ===========================================================================
-- V303 - fn_usuario_permisos_menu: el super admin del SSO tambien aqui.
--        Cierra el hueco que dejo V302 entre lo que el backend autoriza y
--        lo que el front cree que puede hacer.
--
-- POR QUE ESTA MIGRACION EXISTE
--   V302 le devolvio al super admin del SSO (CEVAL-SUPER_ADMINISTRADOR en
--   public.role_users) el acceso a los gates de ESCRITURA, por dos puntos:
--
--     fn_usuario_categoria_rol_nivel   -> nivel 0 -> bypass del paso 0 de
--                                         fn_assert_permiso_seccion.
--     fn_puede_afectar_establecimiento -> los listados dejan de filtrar.
--
--   Pero el front no pregunta por esos gates. Pregunta por
--   GET /usuarios/permisos-menu, que responde con fn_usuario_permisos_menu:
--   la lista de menus con sus cuatro banderas (crear/editar/eliminar/ver).
--   Y esa funcion arranca de un CTE que sigue leyendo solo TSEDE_USUARIO:
--
--       roles_activos AS (
--           SELECT DISTINCT su.FK_TROL
--             FROM academico_test.TSEDE_USUARIO su
--            WHERE su.FK_TUSUARIO = p_pk_tusuario AND su.ACTIVE = TRUE)
--
--   Sin filas activas ese CTE queda vacio y arrastra a todos los demas, asi
--   que la funcion devuelve CERO filas y el endpoint responde {"rows":[]}.
--
--   El resultado es el peor desenlace posible: el backend SI autoriza
--   -- fn_assert_permiso_seccion(179, 'ESTABLECIMIENTO', 'CREAR') pasa
--   limpio -- pero el front recibe una lista vacia de capabilities y
--   esconde o bloquea las acciones. El usuario ve "sin permisos para crear
--   establecimientos" en una pantalla donde la configuracion de roles le
--   muestra el menu Establecimiento Educativo perfectamente asignado a su
--   rol Super Administrador.
--
--   La incoherencia se nota especialmente porque el SIDEBAR si funciona:
--   fn_list_my_menus resuelve por public.role_users, de modo que los menus
--   aparecen listados mientras sus permisos vienen todos vacios.
--
-- UN SOLO PUNTO
--   fn_usuario_puede_en_menu no necesita tocarse: delega en
--   fn_usuario_permisos_menu, asi que hereda el arreglo. Ese es tambien el
--   camino del paso 1 (capability) de fn_assert_permiso_seccion, que hoy no
--   se alcanza para nivel 0 porque el paso 0 corta antes -- pero queda
--   coherente en vez de depender de ese orden.
--
-- QUE DEVUELVE EL SUPER ADMIN
--   Todos los menus activos de TMENU con las cuatro banderas en TRUE, que
--   es exactamente lo que significa el nivel 0: ni capability ni scope.
--
--   Se ignoran a proposito los recortes de TUSUARIO_ROL_PERMISO
--   (SOLO_LECTURA = 'SI'). No es un descuido: el bypass del paso 0 de
--   fn_assert_permiso_seccion ya los ignora, de modo que respetarlos aqui
--   volveria a abrir la misma grieta entre front y backend que esta
--   migracion cierra -- el front ocultaria un boton que el backend acepta.
--
-- QUE NO CAMBIA
--   La rama normal es identica a la vigente, literal. Quien no sea super
--   admin del SSO obtiene exactamente los mismos permisos que antes.
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
    -- V303 - Super admin del SSO: todos los menus activos, los cuatro
    -- permisos. Es la traduccion a capabilities del mismo nivel 0 que
    -- fn_assert_permiso_seccion aplica en su paso 0 (ver cabecera).
    -- ---------------------------------------------------------------------
    IF academico_test.fn_es_super_admin_sso(p_pk_tusuario) THEN
        RETURN QUERY
        SELECT m.PK_TMENU,
               m.CODIGO,
               m.NOMBRE,
               m.URL,
               TRUE, TRUE, TRUE, TRUE
          FROM academico_test.TMENU m
         WHERE m.ACTIVE = TRUE
         ORDER BY m.NOMBRE ASC, m.PK_TMENU ASC;
        RETURN;
    END IF;

    -- ---------------------------------------------------------------------
    -- Rama normal -- identica a la vigente antes de V303.
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
           MIN(pc.CODIGO)::CHARACTER VARYING,
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
    'V303 - capabilities por menu para el front (GET /usuarios/permisos-menu). El super admin del SSO (fn_es_super_admin_sso) obtiene todos los menus activos con los cuatro permisos, en linea con el bypass de nivel 0 de fn_assert_permiso_seccion.';
