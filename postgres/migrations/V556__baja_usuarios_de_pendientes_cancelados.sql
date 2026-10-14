-- V556 — Da de baja a las personas que quedaron activas sin cumplir ninguna
-- función en la app, para que su correo se pueda volver a usar en un alta
-- como persona nueva. Dos casos: (1) TUSUARIO activo cuyo único papel fue un
-- funcionario ya inactivo (pendiente cancelado antes de que
-- fn_fun_cancelar_pendiente, V51, diera de baja también al usuario): se
-- desactiva el TUSUARIO, su cuenta de public.users y sus roles; (2) cuenta
-- de public.users habilitada cuya identidad académica ya está toda inactiva.
-- No se toca a nadie con otro funcionario activo, permisos de sede, puntero
-- de rector/secretaria, otro vínculo (fn_usu_tiene_otros_vinculos), roles
-- (caso 2) ni una cuenta usada por un funcionario activo de PIGSE.
-- Idempotente; en una base limpia no encuentra a nadie.

DO $$
DECLARE
    v_pk BIGINT;
BEGIN
    PERFORM set_config('app.etiqueta',
        'Baja de usuarios sin función (pendientes de funcionario cancelados)', true);

    DROP TABLE IF EXISTS tmp_sin_funcion;
    CREATE TEMP TABLE tmp_sin_funcion ON COMMIT DROP AS
    SELECT t.PK_TUSUARIO AS pk_tusuario, t.CUENTA AS cuenta
      FROM academico_test.TUSUARIO t
     WHERE t.ACTIVE = TRUE
       AND EXISTS (SELECT 1 FROM academico_test.TFUNCIONARIO f
                    WHERE f.FK_TUSUARIO = t.PK_TUSUARIO)
       AND NOT EXISTS (SELECT 1 FROM academico_test.TFUNCIONARIO f
                        WHERE f.FK_TUSUARIO = t.PK_TUSUARIO AND f.ACTIVE = TRUE)
       AND NOT EXISTS (SELECT 1 FROM academico_test.TSEDE_USUARIO su
                        WHERE su.FK_TUSUARIO = t.PK_TUSUARIO AND su.ACTIVE = TRUE)
       AND NOT EXISTS (SELECT 1
                         FROM academico_test.TESTABLECIMIENTO e
                         JOIN academico_test.TFUNCIONARIO f
                           ON f.PK_TFUNCIONARIO IN (e.FK_TFUNCIONARIO_RECTOR, e.FK_TFUNCIONARIO_SECRETARIA)
                        WHERE e.ACTIVE = TRUE AND f.FK_TUSUARIO = t.PK_TUSUARIO)
       AND NOT academico_test.fn_usu_tiene_otros_vinculos(t.PK_TUSUARIO)
       AND NOT EXISTS (SELECT 1 FROM pigse.TUSUARIO p
                        WHERE p.ACTIVE = TRUE AND UPPER(p.CORREO_ELECTRONICO) = UPPER(t.CUENTA));

    -- (1) Usuario y cuenta; los roles al final, cuando ya no le queda nada.
    UPDATE academico_test.TUSUARIO t
       SET ACTIVE = FALSE, MODIFIED_BY = 'V556', MODIFIED_AT = CURRENT_TIMESTAMP
      FROM tmp_sin_funcion s
     WHERE t.PK_TUSUARIO = s.pk_tusuario;

    UPDATE public.users u
       SET active = FALSE, enabled = FALSE
      FROM tmp_sin_funcion s
     WHERE UPPER(u.email) = UPPER(s.cuenta)
       AND (u.active OR u.enabled);

    FOR v_pk IN SELECT pk_tusuario FROM tmp_sin_funcion LOOP
        PERFORM academico_test.fn_sincronizar_rol_publico(v_pk);
    END LOOP;

    -- (2) Cuentas habilitadas cuya identidad académica ya está inactiva.
    UPDATE public.users u
       SET active = FALSE, enabled = FALSE
     WHERE (u.active OR u.enabled)
       AND EXISTS (SELECT 1 FROM academico_test.TUSUARIO t
                    WHERE UPPER(t.CUENTA) = UPPER(u.email))
       AND NOT EXISTS (SELECT 1 FROM academico_test.TUSUARIO t
                        WHERE UPPER(t.CUENTA) = UPPER(u.email) AND t.ACTIVE = TRUE)
       AND NOT EXISTS (SELECT 1 FROM pigse.TUSUARIO p
                        WHERE p.ACTIVE = TRUE AND UPPER(p.CORREO_ELECTRONICO) = UPPER(u.email))
       AND NOT EXISTS (SELECT 1 FROM public.role_users ru WHERE ru.user_id = u.id_user);
END;
$$;
