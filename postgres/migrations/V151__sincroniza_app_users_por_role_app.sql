-- app_users (el roster "Users · N" que se ve en la pantalla de Apps del
-- admin-ui) nunca se sincronizaba automáticamente -- un usuario que
-- ganaba un rol bindeado a un app (role_app) no aparecía ahí hasta que
-- alguien lo agregara a mano. Con los roles PIGSE ahora otorgándose
-- automáticamente (V150), ese roster habría quedado sistemáticamente
-- desactualizado.
--
-- public.fn_sync_app_users(p_user_id) es GENÉRICA (no específica de
-- PIGSE): recalcula el roster completo de apps de un usuario a partir
-- de sus role_users actuales x role_app -- mismo principio de
-- full-resync que fn_sincronizar_rol_publico usa para role_users. Se
-- llama desde dos puntos:
--   1. academico_test.fn_sincronizar_rol_publico (V111/V150) -- cubre
--      el camino académico (TSEDE_USUARIO/TENTE_USUARIO/rector/secretaria).
--   2. UserAdminService.bindUserRole/unbindUserRole (Java) -- cubre el
--      camino manual/administrativo (p.ej. PIGSE-ADMINISTRADOR,
--      PIGSE-SECRETARIA_TERRITORIAL, que V150 deja fuera del sync
--      académico a propósito).

CREATE OR REPLACE FUNCTION public.fn_sync_app_users(p_user_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_user_id IS NULL THEN
        RETURN;
    END IF;

    -- Agregar los apps que ahora corresponden (algún rol actual con
    -- role_app hacia ese app) y todavía no están en el roster.
    INSERT INTO public.app_users (id_app, id_user)
    SELECT DISTINCT ra.id_app, p_user_id
      FROM public.role_users ru
      JOIN public.role_app ra ON ra.id_role = ru.role_id
     WHERE ru.user_id = p_user_id
    ON CONFLICT DO NOTHING;

    -- Quitar los apps que ya no corresponden a ningún rol actual.
    DELETE FROM public.app_users au
     WHERE au.id_user = p_user_id
       AND NOT EXISTS (
            SELECT 1
              FROM public.role_users ru
              JOIN public.role_app ra ON ra.id_role = ru.role_id
             WHERE ru.user_id = p_user_id AND ra.id_app = au.id_app
           );
END;
$$;

COMMENT ON FUNCTION public.fn_sync_app_users(BIGINT) IS
    'Recalcula app_users de un usuario a partir de sus role_users x role_app actuales -- full-resync, no incremental. Llamada desde fn_sincronizar_rol_publico (academico_test) y desde UserAdminService.bindUserRole/unbindUserRole (sso-admin).';

-- Enganche en el sync académico -- después de que role_users ya quedó
-- resuelto para este usuario (pasos 1 y 2 de la función).
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
       AND r.name NOT IN ('PIGSE-ADMINISTRADOR', 'PIGSE-SECRETARIA_TERRITORIAL')
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

-- Backfill SÓLO-AGREGAR (nunca borra) -- agrega la membresía que falte
-- para quien YA tiene un rol bindeado a un app, sin tocar filas
-- existentes. A propósito no se corre la versión completa
-- (agregar+borrar) de fn_sync_app_users acá: confirmado contra el
-- servidor que 2 filas reales de app_users (COLOMBIA-EVALUADORA) no
-- tienen ningún role_app detrás hoy -- no hay forma de distinguir
-- desde acá "membresía manual legítima" de "dato desactualizado", así
-- que esas quedan intactas hasta una decisión explícita.
INSERT INTO public.app_users (id_app, id_user)
SELECT DISTINCT ra.id_app, ru.user_id
  FROM public.role_users ru
  JOIN public.role_app ra ON ra.id_role = ru.role_id
 WHERE NOT EXISTS (
        SELECT 1 FROM public.app_users au
         WHERE au.id_app = ra.id_app AND au.id_user = ru.user_id
       );
