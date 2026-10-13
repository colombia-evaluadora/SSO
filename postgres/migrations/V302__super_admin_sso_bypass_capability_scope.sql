-- V302 -- El super admin del SSO (CEVAL-SUPER_ADMINISTRADOR en public.role_users)
-- llega al nivel 0 sin depender de TSEDE_USUARIO: derivado de filas por sede, se
-- perdia al borrar sedes y en una instalacion vacia nadie podia crear el primer
-- establecimiento. El bypass sigue siendo el paso 0 de fn_assert_permiso_seccion;
-- aqui solo cambia la fuente (fn_usuario_categoria_rol_nivel y
-- fn_puede_afectar_establecimiento), y el resync deja de retirar ese rol.
-- Seguridad: una fila CEVAL-SUPER_ADMINISTRADOR en public.role_users da poder
-- total sin respaldo academico; auditar periodicamente quien la tiene.

-- 1. TUSUARIO <-> users por cuenta/email, como fn_sincronizar_rol_publico.
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

-- El alcance de los listados la llama por fila: sin indice, UPPER(email)
-- recorria public.users entera en cada llamada.
CREATE INDEX IF NOT EXISTS idx_users_email_upper ON public.users (UPPER(email));

-- 2. Nivel 0 directo para el super admin del SSO.
CREATE OR REPLACE FUNCTION academico_test.fn_usuario_categoria_rol_nivel(p_pk_tusuario BIGINT)
RETURNS INTEGER
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_nivel  INT;
BEGIN
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

-- 3. Segunda puerta (listados): misma fuente; la via por TSEDE_USUARIO sigue.
CREATE OR REPLACE FUNCTION academico_test.fn_puede_afectar_establecimiento(p_pk_usuario BIGINT)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $function$
    SELECT CASE
             WHEN p_pk_usuario IS NULL THEN FALSE
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

-- 4. CEVAL-SUPER_ADMINISTRADOR entre los roles que el resync no toca: sin
--    respaldo academico, la primera escritura en TSEDE_USUARIO (trigger de
--    V301) se lo quitaria, y con el el acceso al gateway.
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
            SELECT prefix, 'JEFE_SISTEMA_ESTABLECIMIENTO'
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
                    SELECT prefix, 'JEFE_SISTEMA_ESTABLECIMIENTO'
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

    PERFORM public.fn_sync_app_users(v_id_user);
END;

$function$;
