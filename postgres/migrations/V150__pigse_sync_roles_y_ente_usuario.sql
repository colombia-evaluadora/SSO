-- Cierra el círculo de PIGSE del lado de creación de usuarios:
--
--   1. fn_sincronizar_rol_publico (V111) sólo otorgaba CEVAL-<codigo>.
--      Se extiende para otorgar TAMBIÉN PIGSE-<codigo> por la misma
--      fuente académica (TSEDE_USUARIO/TROL, rector/secretaria de
--      TESTABLECIMIENTO) -- sin tocar ningún dato ni firma existente,
--      los mismos 4 puntos de escritura (fn_sede_usuario_crear/
--      soft_delete, fn_est_crear/actualizar) siguen disparándola igual.
--
--   2. academico_test.TENTE_USUARIO existía desde antes (fk_tente +
--      fk_trol + fk_tusuario) pero ninguna función la usaba (V111 lo
--      documentaba explícitamente) -- por eso hoy no hay forma de dar
--      de alta un usuario de Ente Territorial (Director, Jefe de
--      Sistema, Jefe de Área...). fn_ente_usuario_crear/soft_delete
--      son el espejo exacto de fn_sede_usuario_crear/soft_delete
--      (mismo gate, misma sincronización), sin jornada/orden porque
--      TENTE_USUARIO no los tiene.
--
-- El catálogo TROL YA tiene los 5 códigos de "Ente Territorial" y los
-- 3 de establecimiento que hoy no se derivaban (RECTOR/AUXILIAR_
-- ADMINISTRATIVO ya se derivaban por CEVAL-; ahora también por PIGSE-).
-- PIGSE-ADMINISTRADOR y PIGSE-SECRETARIA_TERRITORIAL (V149) quedan
-- FUERA de este sync a propósito: no tienen ningún TROL/fuente
-- académica detrás (son roles de supervisión global, no un cargo de
-- EE ni de ente) -- incluirlos en el resync los dejaría vulnerables a
-- que un fn_sincronizar_rol_publico posterior (disparado por CUALQUIER
-- cambio de TSEDE_USUARIO/TENTE_USUARIO de ese mismo usuario) se los
-- quitara, porque nunca aparecerían en el set "deseados".
--
-- PIGSE-SECRETARIO (V149) SÍ se deriva -- de la misma FK
-- TESTABLECIMIENTO.FK_TFUNCIONARIO_SECRETARIA que ya alimentaba
-- CEVAL-AUXILIAR_ADMINISTRATIVO (V111): ese cargo otorga los DOS roles
-- ahora, uno por catálogo.

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

    -- 1. Agregar los CEVAL-<codigo>/PIGSE-<codigo> que falten. El set
    --    deseado es la UNION de (prefix, codigo):
    --      (a) un par por cada TROL con TSEDE_USUARIO activa
    --          (establecimiento) -- ambos prefijos, mismo codigo.
    --      (b) un par por cada TROL con TENTE_USUARIO activa
    --          (ente territorial) -- ambos prefijos, mismo codigo.
    --      (c) 'RECTOR' (ambos prefijos) si es rector activo de un EE
    --          activo.
    --      (d) 'AUXILIAR_ADMINISTRATIVO' (ambos prefijos) más
    --          'PIGSE-SECRETARIO' si es "secretaria" activo de un EE
    --          activo -- misma fuente, tres roles.
    --    JOIN contra public.role: un (prefix, codigo) sin fila
    --    correspondiente (p.ej. PIGSE-DOCENTE no existe) simplemente no
    --    produce match -- no es un error, sólo no hay nada que otorgar.
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

    -- 2. Quitar los CEVAL-*/PIGSE-* que ya no tengan ninguna fuente
    --    detrás -- mismo full-resync que V111, ahora con las mismas
    --    seis ramas de "deseados" del paso 1. PIGSE-ADMINISTRADOR y
    --    PIGSE-SECRETARIA_TERRITORIAL quedan explícitamente fuera del
    --    filtro: no los otorga este sync, tampoco los tiene que poder
    --    quitar (ver comentario de cabecera).
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
END;
$function$;

-- fn_ente_usuario_crear -- espejo de fn_sede_usuario_crear (V111/V51),
-- misma gate, misma sincronización, sin jornada/orden (TENTE_USUARIO
-- no los tiene -- su PK es sólo fk_tente+fk_trol+fk_tusuario).
CREATE OR REPLACE FUNCTION academico_test.fn_ente_usuario_crear(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tente               BIGINT,
    p_fk_rol                 BIGINT,
    p_fk_usuario              BIGINT,
    p_tlv_estado             VARCHAR DEFAULT 'ACTIVO',
    p_predeterminado         NUMERIC DEFAULT 0
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $function$
BEGIN
    -- 0. Gate de autorizacion: mismo permiso que TSEDE_USUARIO -- dar de
    --    alta un rol de ente territorial es la misma clase de operación
    --    (asignar un cargo académico a un usuario) que dar de alta uno
    --    de establecimiento.
    IF NOT academico_test.fn_puede_afectar_usuarios(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    -- 1. Validaciones de obligatoriedad.
    IF p_fk_tente IS NULL THEN
        RAISE EXCEPTION 'ente (fk_tente) es obligatorio' USING ERRCODE = '23502';
    END IF;
    IF p_fk_rol IS NULL THEN
        RAISE EXCEPTION 'rol (fk_rol) es obligatorio' USING ERRCODE = '23502';
    END IF;
    IF p_fk_usuario IS NULL THEN
        RAISE EXCEPTION 'usuario (fk_usuario) es obligatorio' USING ERRCODE = '23502';
    END IF;
    IF p_tlv_estado NOT IN ('ACTIVO', 'INACTIVO') THEN
        RAISE EXCEPTION 'TLV_ESTADO (%) no es valido; se esperaba ACTIVO o INACTIVO',
            p_tlv_estado
            USING ERRCODE = '22023';
    END IF;

    -- 2. Validacion de FKs.
    IF NOT EXISTS (SELECT 1 FROM academico_test.TENTE WHERE PK_ENTE = p_fk_tente AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'TENTE (%) no existe o no esta activo', p_fk_tente
            USING ERRCODE = '23503';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM academico_test.TROL WHERE PK_TROL = p_fk_rol AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'TROL (%) no existe o no esta activo', p_fk_rol
            USING ERRCODE = '23503';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM academico_test.TUSUARIO WHERE PK_TUSUARIO = p_fk_usuario AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'TUSUARIO (%) no existe o no esta activo', p_fk_usuario
            USING ERRCODE = '23503';
    END IF;

    -- 3. Idempotencia: reactivar si ya existe (inactivo) en vez de
    --    duplicar -- la PK es (fk_tente, fk_trol, fk_tusuario), sin
    --    columna ORDEN que permita convivir con una fila inactiva como
    --    sí hace TSEDE_USUARIO.
    IF EXISTS (
        SELECT 1 FROM academico_test.TENTE_USUARIO
         WHERE FK_TENTE = p_fk_tente AND FK_TROL = p_fk_rol AND FK_TUSUARIO = p_fk_usuario AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'ya existe un TENTE_USUARIO activo para (ente=%, rol=%, usuario=%)',
            p_fk_tente, p_fk_rol, p_fk_usuario
            USING ERRCODE = '23505';
    END IF;

    INSERT INTO academico_test.TENTE_USUARIO (
        FK_TENTE, FK_TROL, FK_TUSUARIO, TLV_ESTADO, PREDETERMINADO,
        CREATED_BY, CREATED_AT, ACTIVE
    )
    VALUES (
        p_fk_tente, p_fk_rol, p_fk_usuario, p_tlv_estado, p_predeterminado,
        p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
    )
    ON CONFLICT (FK_TENTE, FK_TROL, FK_TUSUARIO)
    DO UPDATE SET ACTIVE = TRUE, TLV_ESTADO = EXCLUDED.TLV_ESTADO,
                  MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP;

    PERFORM academico_test.fn_sincronizar_rol_publico(p_fk_usuario);

    RETURN TRUE;
END;
$function$;

CREATE OR REPLACE FUNCTION academico_test.fn_ente_usuario_soft_delete(
    p_fk_tente               BIGINT,
    p_fk_rol                 BIGINT,
    p_fk_usuario             BIGINT,
    p_pk_usuario_solicitante BIGINT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $function$
DECLARE
    v_active BOOLEAN;
BEGIN
    IF NOT academico_test.fn_puede_afectar_usuarios(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    SELECT ACTIVE INTO v_active
      FROM academico_test.TENTE_USUARIO
     WHERE FK_TENTE = p_fk_tente AND FK_TROL = p_fk_rol AND FK_TUSUARIO = p_fk_usuario;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'no existe TENTE_USUARIO para (ente=%, rol=%, usuario=%)',
            p_fk_tente, p_fk_rol, p_fk_usuario
            USING ERRCODE = 'P0002';
    END IF;

    IF v_active = FALSE THEN
        RETURN TRUE; -- idempotente
    END IF;

    UPDATE academico_test.TENTE_USUARIO
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TENTE = p_fk_tente AND FK_TROL = p_fk_rol AND FK_TUSUARIO = p_fk_usuario;

    PERFORM academico_test.fn_sincronizar_rol_publico(p_fk_usuario);

    RETURN TRUE;
END;
$function$;

-- Backfill: re-sincroniza todo TUSUARIO con una TENTE_USUARIO activa
-- hoy (nadie tenía ninguna, ver comentario de cabecera -- inerte en la
-- práctica) más todo el universo que V111 ya cubría (TSEDE_USUARIO,
-- rector/secretaria), para que los PIGSE-* nuevos lleguen a los
-- usuarios que YA tenían el CEVAL- equivalente, sin esperar a que
-- alguien vuelva a tocar su TSEDE_USUARIO/TENTE_USUARIO.
DO $$
DECLARE
    v_pk BIGINT;
BEGIN
    FOR v_pk IN
        SELECT DISTINCT pk_tusuario FROM (
            SELECT FK_TUSUARIO AS pk_tusuario FROM academico_test.TSEDE_USUARIO WHERE ACTIVE = TRUE
            UNION
            SELECT FK_TUSUARIO FROM academico_test.TENTE_USUARIO WHERE ACTIVE = TRUE
            UNION
            SELECT f.FK_TUSUARIO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_RECTOR
             WHERE f.ACTIVE = TRUE AND e.ACTIVE = TRUE
            UNION
            SELECT f.FK_TUSUARIO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_SECRETARIA
             WHERE f.ACTIVE = TRUE AND e.ACTIVE = TRUE
        ) universo
    LOOP
        PERFORM academico_test.fn_sincronizar_rol_publico(v_pk);
    END LOOP;
END;
$$;
