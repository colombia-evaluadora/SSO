-- ===========================================================================
-- V302 - CEVAL-SUPER_ADMINISTRADOR: el super admin del SSO entra por
--        public.role_users, sin depender de TSEDE_USUARIO.
--
-- POR QUE ESTA MIGRACION EXISTE
--   El modelo de permisos (CU-86e2w4xdt) ya contempla al super admin: el
--   paso 0 de fn_assert_permiso_seccion es un bypass limpio -- nivel 0, ni
--   capability ni scope -- y las funciones de listado ramifican por
--   fn_puede_afectar_establecimiento para no filtrar por establecimiento.
--
--   El problema no es el bypass sino como se ALCANZA. Las dos puertas leen
--   exclusivamente TSEDE_USUARIO:
--
--     fn_usuario_categoria_rol_nivel  -> MIN(nivel) de sus TSEDE_USUARIO
--                                        ACTIVE = TRUE; NULL si no tiene
--                                        ninguna fila.
--     fn_puede_afectar_establecimiento -> EXISTS de una fila ACTIVE = TRUE
--                                        con FK_TROL IN (1, 2, 3).
--
--   Es decir, un rol GLOBAL se estaba derivando de filas POR SEDE. Si esas
--   filas desaparecen -- o si la instalacion todavia no tiene ninguna -- el
--   super admin deja de serlo: el nivel queda NULL, el bypass del paso 0 no
--   dispara y todo gate responde 42501.
--
--   Dos consecuencias concretas, ambas observadas en produccion:
--
--     (a) Bloqueo por cascada. Un borrado masivo de sedes apago los
--         TSEDE_USUARIO del super admin y lo dejo sin poder listar
--         funcionarios ni crear establecimientos, pese a conservar
--         CEVAL-SUPER_ADMINISTRADOR en public.role_users y en su JWT.
--
--     (b) Arranque en frio. Con TESTABLECIMIENTO y TSEDE vacias -- una
--         instalacion nueva, o un entorno recien restaurado -- NADIE puede
--         crear el primer establecimiento, porque para crearlo hace falta un
--         permiso que solo se obtiene teniendo ya una sede. El sistema no
--         tiene forma de arrancarse a si mismo.
--
-- QUE CAMBIA
--   Se reconoce public.role_users como fuente valida del rol de super admin,
--   que es donde vive el rol global del SSO y de donde sale el claim del JWT.
--   El bypass NO se reescribe: sigue siendo el paso 0 de
--   fn_assert_permiso_seccion, con su capability y su scope. Lo unico que
--   cambia es que ahora el super admin llega hasta el.
--
--     1. fn_es_super_admin_sso(pk_tusuario) -- nueva. TRUE si el usuario
--        tiene CEVAL-SUPER_ADMINISTRADOR en public.role_users, con la cuenta
--        activa y habilitada.
--
--     2. fn_usuario_categoria_rol_nivel -- devuelve 0 en cuanto
--        fn_es_super_admin_sso es TRUE, sin mirar TSEDE_USUARIO. Este es el
--        cambio que propaga el arreglo: TODO gate que pase por
--        fn_assert_permiso_seccion (capability y scope) hereda el bypass sin
--        tocar ni una funcion mas.
--
--     3. fn_puede_afectar_establecimiento -- segunda puerta, independiente
--        de la anterior y usada por los listados (fn_usu_empleados_contar,
--        fn_est_listar y companeras) para decidir si filtran por
--        establecimiento. Se le anade la misma fuente.
--
--     4. fn_sincronizar_rol_publico -- CEVAL-SUPER_ADMINISTRADOR se suma a
--        la lista de roles que el resync no otorga y, por tanto, tampoco
--        puede quitar (donde ya estaban PIGSE-ADMINISTRADOR y
--        PIGSE-SECRETARIA_TERRITORIAL).
--
--        Este punto NO es cosmetico: sin el, el arreglo se anula solo. El
--        resync borra todo CEVAL-* que no tenga respaldo academico, y un
--        super admin que se apoya en el bypass justamente no lo tiene. La
--        primera escritura sobre TSEDE_USUARIO le quitaria el rol de
--        public.role_users y con el su acceso -- incluido el del gateway,
--        que hoy es lo unico que lo mantiene dentro. Con V301 (trigger de
--        resync sobre TSEDE_USUARIO) eso pasaria a la primera.
--
--        El criterio es el que ya aplicaba a los roles PIGSE: un rol que se
--        administra desde el SSO no se gobierna desde el catalogo academico.
--
-- QUE NO CAMBIA
--   * Nadie gana permisos: quien no tuviera ya CEVAL-SUPER_ADMINISTRADOR en
--     public.role_users no se ve afectado. En produccion son 2 cuentas.
--   * El super admin por TSEDE_USUARIO (FK_TROL = 1) sigue funcionando
--     igual; la fuente nueva se SUMA, no sustituye.
--   * fn_usuario_ee_accesibles y fn_usuario_sedes_jornadas_accesibles se
--     dejan intactas a proposito: responden "de que EE/sedes forma parte
--     este usuario", que para un super admin global es legitimamente vacio.
--     Los consumidores no lo consultan porque ramifican antes por el bypass.
--
-- NOTA DE SEGURIDAD
--   Esto convierte a public.role_users en fuente autoritativa para el
--   permiso mas alto del sistema. Es coherente -- es la tabla que alimenta
--   el JWT -- pero implica que una fila CEVAL-SUPER_ADMINISTRADOR concede
--   poder total sin respaldo academico. Conviene auditar periodicamente
--   quien la tiene:
--
--     SELECT u.id_user, u.email
--       FROM public.role_users ru
--       JOIN public.role r ON r.id_role = ru.role_id
--       JOIN public.users u ON u.id_user = ru.user_id
--      WHERE r.name = 'CEVAL-SUPER_ADMINISTRADOR';
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. fn_es_super_admin_sso -- el rol global, leido de public.role_users.
--    El emparejamiento TUSUARIO <-> users es por cuenta/email, el mismo que
--    usa fn_sincronizar_rol_publico.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_es_super_admin_sso(p_pk_tusuario BIGINT)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $function$
    SELECT CASE
             WHEN p_pk_tusuario IS NULL THEN FALSE
             ELSE EXISTS (
                 SELECT 1
                   FROM academico_test.TUSUARIO t
                   JOIN public.users u
                     ON UPPER(u.email) = UPPER(t.CUENTA)
                   JOIN public.role_users ru ON ru.user_id = u.id_user
                   JOIN public.role r        ON r.id_role  = ru.role_id
                  WHERE t.PK_TUSUARIO = p_pk_tusuario
                    AND r.name        = 'CEVAL-SUPER_ADMINISTRADOR'
                    AND u.active      = TRUE
                    AND u.enabled     = TRUE
             )
           END;
$function$;

COMMENT ON FUNCTION academico_test.fn_es_super_admin_sso(BIGINT) IS
    'V302 - TRUE si el usuario tiene CEVAL-SUPER_ADMINISTRADOR en public.role_users. Fuente del rol global de super admin, independiente de TSEDE_USUARIO.';


-- ---------------------------------------------------------------------------
-- 2. fn_usuario_categoria_rol_nivel -- nivel 0 directo para el super admin
--    del SSO. Con esto el paso 0 de fn_assert_permiso_seccion (bypass de
--    capability y scope) vuelve a ser alcanzable sin TSEDE_USUARIO.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_usuario_categoria_rol_nivel(p_pk_tusuario BIGINT)
RETURNS INTEGER
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_nivel  INT;
BEGIN
    -- V302 - super admin del SSO: nivel 0 sin pasar por TSEDE_USUARIO. Un
    -- rol global no puede depender de filas por sede (ver cabecera).
    IF academico_test.fn_es_super_admin_sso(p_pk_tusuario) THEN
        RETURN 0;
    END IF;

    SELECT MIN(academico_test.fn_rol_categoria_nivel(su.FK_TROL))
      INTO v_nivel
      FROM academico_test.TSEDE_USUARIO su
     WHERE su.FK_TUSUARIO = p_pk_tusuario
       AND su.ACTIVE      = TRUE;

    -- NULL si el usuario no tiene ningun rol activo (MIN sobre 0 filas).
    RETURN v_nivel;
END;
$function$;


-- ---------------------------------------------------------------------------
-- 3. fn_puede_afectar_establecimiento -- segunda puerta (listados). Misma
--    fuente adicional; la via por TSEDE_USUARIO se conserva intacta.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_puede_afectar_establecimiento(p_pk_usuario BIGINT)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $function$
    SELECT CASE
             WHEN p_pk_usuario IS NULL THEN FALSE
             -- V302 - super admin del SSO, sin respaldo en TSEDE_USUARIO.
             WHEN academico_test.fn_es_super_admin_sso(p_pk_usuario) THEN TRUE
             ELSE EXISTS (
                 SELECT 1
                   FROM academico_test.TSEDE_USUARIO
                  WHERE FK_TUSUARIO = p_pk_usuario
                    AND FK_TROL     IN (1, 2, 3)
                    AND ACTIVE       = TRUE
             )
           END;
$function$;


-- ---------------------------------------------------------------------------
-- 4. fn_sincronizar_rol_publico -- CEVAL-SUPER_ADMINISTRADOR pasa a la lista
--    de roles intocables del resync. Cuerpo identico al vigente (V150 + el
--    fn_sync_app_users de V151); el unico cambio es esa lista.
--
--    Sin esto el resync -- y con V301 el trigger, a la primera escritura --
--    le retirarian el rol al super admin que se apoya en el bypass, dejandolo
--    fuera tambien del gateway.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_sincronizar_rol_publico(p_pk_tusuario BIGINT)
RETURNS VOID
LANGUAGE plpgsql
AS $function$

DECLARE
    v_id_user BIGINT;
BEGIN
    IF p_pk_tusuario IS NULL THEN
        RETURN;
    END IF;

    SELECT u.id_user
      INTO v_id_user
      FROM academico_test.TUSUARIO t
      JOIN public.users u ON UPPER(u.email) = UPPER(t.CUENTA)
     WHERE t.PK_TUSUARIO = p_pk_tusuario
     LIMIT 1;

    IF v_id_user IS NULL THEN
        RETURN;
    END IF;

    INSERT INTO public.role_users (user_id, role_id)
    SELECT v_id_user, r.id_role
      FROM (
            SELECT 'CEVAL' AS prefix, tr.CODIGO AS codigo
              FROM academico_test.TSEDE_USUARIO su
              JOIN academico_test.TROL tr ON tr.PK_TROL = su.FK_TROL
             WHERE su.FK_TUSUARIO = p_pk_tusuario AND su.ACTIVE = TRUE
            UNION
            SELECT 'PIGSE', tr.CODIGO
              FROM academico_test.TSEDE_USUARIO su
              JOIN academico_test.TROL tr ON tr.PK_TROL = su.FK_TROL
             WHERE su.FK_TUSUARIO = p_pk_tusuario AND su.ACTIVE = TRUE
            UNION
            SELECT 'CEVAL', tr.CODIGO
              FROM academico_test.TENTE_USUARIO tu
              JOIN academico_test.TROL tr ON tr.PK_TROL = tu.FK_TROL
             WHERE tu.FK_TUSUARIO = p_pk_tusuario AND tu.ACTIVE = TRUE
            UNION
            SELECT 'PIGSE', tr.CODIGO
              FROM academico_test.TENTE_USUARIO tu
              JOIN academico_test.TROL tr ON tr.PK_TROL = tu.FK_TROL
             WHERE tu.FK_TUSUARIO = p_pk_tusuario AND tu.ACTIVE = TRUE
            UNION
            SELECT prefix, 'RECTOR'
              FROM (VALUES ('CEVAL'), ('PIGSE')) AS pr(prefix)
             WHERE EXISTS (
                    SELECT 1
                      FROM academico_test.TESTABLECIMIENTO e
                      JOIN academico_test.TFUNCIONARIO f
                        ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_RECTOR
                     WHERE f.FK_TUSUARIO = p_pk_tusuario
                       AND f.ACTIVE       = TRUE
                       AND e.ACTIVE       = TRUE
                  )
            UNION
            SELECT prefix, 'AUXILIAR_ADMINISTRATIVO'
              FROM (VALUES ('CEVAL'), ('PIGSE')) AS pr(prefix)
             WHERE EXISTS (
                    SELECT 1
                      FROM academico_test.TESTABLECIMIENTO e
                      JOIN academico_test.TFUNCIONARIO f
                        ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_SECRETARIA
                     WHERE f.FK_TUSUARIO = p_pk_tusuario
                       AND f.ACTIVE       = TRUE
                       AND e.ACTIVE       = TRUE
                  )
            UNION
            SELECT 'PIGSE', 'SECRETARIO'
             WHERE EXISTS (
                    SELECT 1
                      FROM academico_test.TESTABLECIMIENTO e
                      JOIN academico_test.TFUNCIONARIO f
                        ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_SECRETARIA
                     WHERE f.FK_TUSUARIO = p_pk_tusuario
                       AND f.ACTIVE       = TRUE
                       AND e.ACTIVE       = TRUE
                  )
           ) deseados(prefix, codigo)
      JOIN public.role r ON r.name = deseados.prefix || '-' || deseados.codigo
     WHERE NOT EXISTS (
            SELECT 1 FROM public.role_users ru
             WHERE ru.user_id = v_id_user AND ru.role_id = r.id_role
           );

    DELETE FROM public.role_users ru
     USING public.role r
     WHERE ru.user_id = v_id_user
       AND ru.role_id = r.id_role
       AND (r.name LIKE 'CEVAL-%' OR r.name LIKE 'PIGSE-%')
       AND r.name NOT IN ('PIGSE-ADMINISTRADOR', 'PIGSE-SECRETARIA_TERRITORIAL',
                          'CEVAL-SUPER_ADMINISTRADOR')
       AND NOT EXISTS (
            SELECT 1
              FROM (
                    SELECT 'CEVAL' AS prefix, tr.CODIGO AS codigo
                      FROM academico_test.TSEDE_USUARIO su
                      JOIN academico_test.TROL tr ON tr.PK_TROL = su.FK_TROL
                     WHERE su.FK_TUSUARIO = p_pk_tusuario AND su.ACTIVE = TRUE
                    UNION
                    SELECT 'PIGSE', tr.CODIGO
                      FROM academico_test.TSEDE_USUARIO su
                      JOIN academico_test.TROL tr ON tr.PK_TROL = su.FK_TROL
                     WHERE su.FK_TUSUARIO = p_pk_tusuario AND su.ACTIVE = TRUE
                    UNION
                    SELECT 'CEVAL', tr.CODIGO
                      FROM academico_test.TENTE_USUARIO tu
                      JOIN academico_test.TROL tr ON tr.PK_TROL = tu.FK_TROL
                     WHERE tu.FK_TUSUARIO = p_pk_tusuario AND tu.ACTIVE = TRUE
                    UNION
                    SELECT 'PIGSE', tr.CODIGO
                      FROM academico_test.TENTE_USUARIO tu
                      JOIN academico_test.TROL tr ON tr.PK_TROL = tu.FK_TROL
                     WHERE tu.FK_TUSUARIO = p_pk_tusuario AND tu.ACTIVE = TRUE
                    UNION
                    SELECT prefix, 'RECTOR'
                      FROM (VALUES ('CEVAL'), ('PIGSE')) AS pr(prefix)
                     WHERE EXISTS (
                            SELECT 1
                              FROM academico_test.TESTABLECIMIENTO e
                              JOIN academico_test.TFUNCIONARIO f
                                ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_RECTOR
                             WHERE f.FK_TUSUARIO = p_pk_tusuario
                               AND f.ACTIVE       = TRUE
                               AND e.ACTIVE       = TRUE
                          )
                    UNION
                    SELECT prefix, 'AUXILIAR_ADMINISTRATIVO'
                      FROM (VALUES ('CEVAL'), ('PIGSE')) AS pr(prefix)
                     WHERE EXISTS (
                            SELECT 1
                              FROM academico_test.TESTABLECIMIENTO e
                              JOIN academico_test.TFUNCIONARIO f
                                ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_SECRETARIA
                             WHERE f.FK_TUSUARIO = p_pk_tusuario
                               AND f.ACTIVE       = TRUE
                               AND e.ACTIVE       = TRUE
                          )
                    UNION
                    SELECT 'PIGSE', 'SECRETARIO'
                     WHERE EXISTS (
                            SELECT 1
                              FROM academico_test.TESTABLECIMIENTO e
                              JOIN academico_test.TFUNCIONARIO f
                                ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_SECRETARIA
                             WHERE f.FK_TUSUARIO = p_pk_tusuario
                               AND f.ACTIVE       = TRUE
                               AND e.ACTIVE       = TRUE
                          )
                   ) deseados(prefix, codigo)
             WHERE deseados.prefix || '-' || deseados.codigo = r.name
           );

    -- V151 -- app_users al día con el role_users que acaba de quedar
    -- resuelto arriba.
    PERFORM public.fn_sync_app_users(v_id_user);
END;

$function$;
