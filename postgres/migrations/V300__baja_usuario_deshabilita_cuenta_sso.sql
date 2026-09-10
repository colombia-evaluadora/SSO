-- ===========================================================================
-- V300 - fn_fun_baja_establecimiento: cuando la baja desactiva el USUARIO,
--        desactivar tambien su cuenta de login en public.users.
--
-- POR QUE ESTA MIGRACION EXISTE
--   Dar de baja un funcionario no toca su cuenta del SSO. El esquema
--   academico se queda con el TUSUARIO en ACTIVE = FALSE y public.users
--   sigue con la fila `enabled = true, active = true`, o sea con el login
--   utilizable y con el correo reservado.
--
--   Eso se manifiesta como un 409 DUPLICATE_EMAIL al dar de alta a otra
--   persona con ese correo. El arreglo de auth-center
--   (FuncionarioRegistrationService) hace que una cuenta NO usable libere el
--   correo, pero no puede hacer nada si nadie la marco como no usable. Los
--   dos cambios son el mismo arreglo por los dos lados.
--
--   Medido en el servidor de test: 9 funcionarios con TUSUARIO inactivo y
--   login plenamente usable. Los pocos casos que si estaban deshabilitados
--   lo estaban porque alguien lo hizo a mano desde el SSO admin.
--
--   El modulo de matricula YA lo hace bien, y de ahi se copia la forma:
--   fn_estudiante_soft_delete y fn_padre_soft_delete desactivan el TUSUARIO
--   solo si no cumple ningun otro papel y acto seguido hacen
--   `UPDATE public.users SET active = FALSE, enabled = FALSE WHERE
--   UPPER(email) = UPPER(cuenta)`. Por eso hay 0 estudiantes y 0 acudientes
--   en esa incoherencia, frente a los 9 funcionarios.
--
-- SOLO CUANDO SE DA DE BAJA EL USUARIO, NO EL FUNCIONARIO
--   La distincion importa y ya estaba resuelta en esta funcion: dar de baja
--   un funcionario NO implica dar de baja al usuario. El TUSUARIO solo se
--   desactiva si (a) al funcionario no le queda ningun TSEDE_USUARIO activo
--   -- v_le_queda_algo -- y (b) el usuario no cumple ningun otro papel en el
--   sistema, que es lo que responde fn_usu_tiene_otros_vinculos (16 tablas:
--   estudiante, padre, ente, inscripcion, reserva de cupo, permisos
--   explicitos, mensajes, noticias, videos, encuestas, carnet).
--
--   La propagacion cuelga exactamente de esa decision, no de la baja del
--   funcionario: se hace si y solo si v_tusuario_desactivado quedo en TRUE.
--   Un funcionario que se va de un establecimiento pero sigue siendo
--   acudiente, o que conserva un permiso en otra sede, mantiene su login
--   intacto.
--
-- QUE CAMBIA
--   Un bloque nuevo justo antes de la sincronizacion de roles. Se resuelve
--   la CUENTA del usuario ya desactivado y, si existe, se deshabilita su
--   fila de public.users. Se enlaza por email = CUENTA, que es la identidad
--   de login -- el camino inverso del que hace
--   public.fn_get_academico_usuario_id. No se usa CORREO_ELECTRONICO a
--   proposito: es un dato de negocio y esta duplicado (39.488 usuarios
--   comparten 'notiene@hotmail.com'), asi que casar por ahi deshabilitaria
--   cuentas ajenas.
--
--   La fila puede no existir -- hay TUSUARIO migrados que nunca tuvieron
--   login -- y no se exige que exista, igual que en matricula.
--
--   Nada mas cambia: mismas dos ramas de baja, mismos guardas, mismo
--   RAISE NOTICE, mismo retorno. fn_fun_baja_establecimiento_bulk delega en
--   esta funcion, asi que hereda el arreglo.
--
-- Idempotente: CREATE OR REPLACE, misma firma. El UPDATE es idempotente por
-- naturaleza (deja los dos flags en FALSE, ya lo estuvieran o no).
-- ===========================================================================


CREATE OR REPLACE FUNCTION academico_test.fn_fun_baja_establecimiento(p_pk_usuario_solicitante bigint, p_pk_funcionario bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_pk_usuario          BIGINT;
    v_active              BOOLEAN;
    v_es_super            BOOLEAN;
    v_es_rector           BOOLEAN;
    v_es_secretaria       BOOLEAN;
    v_tiene_vinculos_academicos BOOLEAN;
    v_le_queda_algo       BOOLEAN;
    v_tusuario_desactivado BOOLEAN := FALSE;
    -- V300 -- la CUENTA del usuario, para propagar la baja a public.users.
    v_cuenta              VARCHAR(200);
BEGIN
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;
    IF p_pk_funcionario IS NULL OR p_pk_funcionario <= 0 THEN
        RAISE EXCEPTION 'p_pk_funcionario es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    SELECT f.FK_TUSUARIO, f.ACTIVE
      INTO v_pk_usuario, v_active
      FROM academico_test.TFUNCIONARIO f
     WHERE f.PK_TFUNCIONARIO = p_pk_funcionario;

    IF NOT FOUND OR v_active = FALSE THEN
        RAISE EXCEPTION 'No se encontro un funcionario activo con ese identificador'
            USING ERRCODE = 'P0002';
    END IF;

    -- -----------------------------------------------------------------
    -- Gate de autorizacion (CU-86e2w4xdt) -- ver nota del header. Una sola
    -- llamada reemplaza el bloque "union de EE accesibles" + coordinador de
    -- sede que estaba copiado inline aqui.
    -- -----------------------------------------------------------------
    PERFORM academico_test.fn_assert_permiso_funcionario(
        p_pk_usuario_solicitante, 'ELIMINAR', p_pk_funcionario);

    -- v_es_super NO es parte del gate: decide, mas abajo, si la baja es
    -- INTEGRAL o PARCIAL (solo los TSEDE_USUARIO en los EE que el
    -- solicitante administra). CU-86e2w4xdt: se resuelve por CATEGORIA_ROL
    -- (nivel 0 SUPER_ADMIN o nivel 1 ADMINISTRATIVOS_TERRITORIALES => baja
    -- INTEGRAL) en vez de la lista fija fn_puede_afectar_establecimiento
    -- (FK_TROL IN (1,2,3)).
    v_es_super := (academico_test.fn_usuario_categoria_rol_nivel(p_pk_usuario_solicitante) <= 1);

    -- -----------------------------------------------------------------
    -- REV3 -- Bloqueos previos a cualquier cambio (fail-fast: si algo de
    -- esto aplica, la baja NO procede -- ni se le quitan permisos, ni se
    -- toca su FK de rector/secretaria, ni nada). Antes el bloqueo de
    -- rector solo aplicaba a no-super-admin, y un super-admin SI podia
    -- dar de baja al rector (lo que dejaba al establecimiento sin rector,
    -- vaciando FK_TFUNCIONARIO_RECTOR). Decision de negocio: rector y
    -- secretaria son relaciones demasiado importantes para vaciarlas
    -- mediante una baja -- se deben reasignar explicitamente desde el
    -- establecimiento primero, sin excepcion de rol.
    -- -----------------------------------------------------------------
    SELECT EXISTS (
        SELECT 1 FROM academico_test.TESTABLECIMIENTO e
         WHERE e.ACTIVE = TRUE AND e.FK_TFUNCIONARIO_RECTOR = p_pk_funcionario
    ) INTO v_es_rector;

    IF v_es_rector THEN
        RAISE EXCEPTION 'Este funcionario esta asignado como rector de un establecimiento activo; reasigne el rector antes de darlo de baja'
            USING ERRCODE = '22023',
                  HINT    = 'Reasigne el rector desde el establecimiento antes de continuar';
    END IF;

    SELECT EXISTS (
        SELECT 1 FROM academico_test.TESTABLECIMIENTO e
         WHERE e.ACTIVE = TRUE AND e.FK_TFUNCIONARIO_SECRETARIA = p_pk_funcionario
    ) INTO v_es_secretaria;

    IF v_es_secretaria THEN
        RAISE EXCEPTION 'Este funcionario esta asignado como secretaria de un establecimiento activo; reasigne la secretaria antes de darlo de baja'
            USING ERRCODE = '22023',
                  HINT    = 'Reasigne la secretaria desde el establecimiento antes de continuar';
    END IF;

    -- REV3 -- Responsabilidades academicas vigentes: grupos que lidera,
    -- asignaturas que dicta, unidades a cargo, traslados de estudiante en
    -- curso, o permisos de periodo activos. No se incluyen tablas de
    -- registro historico (actas de grado firmadas, evaluaciones pasadas,
    -- comportamiento calificado, archivos adjuntos): esas son datos de
    -- algo que ya ocurrio, no trabajo pendiente, y bloquear por ellas
    -- volveria la baja practicamente inalcanzable para cualquier docente
    -- con historial.
    SELECT EXISTS (
        SELECT 1 FROM academico_test.TGRUPO t WHERE t.FK_TFUNCIONARIO = p_pk_funcionario AND t.ACTIVE = TRUE
        UNION ALL
        SELECT 1 FROM academico_test.TDOCENTE_ASIGNATURA t WHERE t.FK_TFUNCIONARIO = p_pk_funcionario AND t.ACTIVE = TRUE
        UNION ALL
        SELECT 1 FROM academico_test.TUNIDAD t WHERE t.FK_TFUNCIONARIO = p_pk_funcionario AND t.ACTIVE = TRUE
        UNION ALL
        SELECT 1 FROM academico_test.TTRASLADO_ESTUDIANTE t WHERE t.FK_TFUNCIONARIO = p_pk_funcionario AND t.ACTIVE = TRUE
        UNION ALL
        SELECT 1 FROM academico_test.TPERIODO_PERMISO t WHERE t.FK_FUNCIONARIO = p_pk_funcionario AND t.ACTIVE = TRUE
    ) INTO v_tiene_vinculos_academicos;

    IF v_tiene_vinculos_academicos THEN
        RAISE EXCEPTION 'Este funcionario tiene responsabilidades academicas activas (grupos, asignaturas u otros registros vigentes); debe desvincularlo de esos registros antes de darlo de baja'
            USING ERRCODE = '22023';
    END IF;

    IF v_es_super THEN
        -- -------------------------------------------------------------
        -- Camino super-admin: baja INTEGRAL. Rector/secretaria ya se
        -- descartaron arriba (bloquean, no se llega aca si aplica).
        -- Desactiva TODOS sus TSEDE_USUARIO, desactiva el TFUNCIONARIO,
        -- y si el TUSUARIO no cumple ningun otro rol en la plataforma
        -- (fn_usu_tiene_otros_vinculos), lo desactiva tambien.
        -- -------------------------------------------------------------
        UPDATE academico_test.TSEDE_USUARIO
           SET ACTIVE = FALSE,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TUSUARIO = v_pk_usuario AND ACTIVE = TRUE;

        UPDATE academico_test.TFUNCIONARIO
           SET ACTIVE = FALSE,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TFUNCIONARIO = p_pk_funcionario;

        IF NOT academico_test.fn_usu_tiene_otros_vinculos(v_pk_usuario) THEN
            UPDATE academico_test.TUSUARIO
               SET ACTIVE = FALSE,
                   MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
                   MODIFIED_AT = CURRENT_TIMESTAMP
             WHERE PK_TUSUARIO = v_pk_usuario;
            v_tusuario_desactivado := TRUE;
        END IF;
    ELSE
        -- -------------------------------------------------------------
        -- Camino no-super-admin: rector/secretaria ya se descartaron
        -- arriba. Solo quita lo que le corresponde a SUS propios EE
        -- (rector/secretaria/jefe de sistema) -- los permisos
        -- (TSEDE_USUARIO) del funcionario en sedes de esos EE. Si
        -- despues de eso el funcionario sigue ligado a permisos en OTRO
        -- establecimiento (uno que no administra este solicitante), se
        -- deja el TFUNCIONARIO activo -- solo perdio esos permisos
        -- puntuales. Si no le queda nada en ningun lado, se desactiva el
        -- TFUNCIONARIO completo (y, si aplica, el TUSUARIO -- mismo
        -- criterio que el camino super-admin).
        -- -------------------------------------------------------------
        UPDATE academico_test.TSEDE_USUARIO su
           SET ACTIVE = FALSE,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
          FROM academico_test.TSEDE s
         WHERE s.PK_TSEDE = su.FK_TSEDE
           AND su.FK_TUSUARIO = v_pk_usuario
           AND su.ACTIVE      = TRUE
           AND (
                -- CU-86e2w4xdt: los EE que el solicitante administra por su
                -- categoria (rector/secretaria por puntero + roles de
                -- categoria ADMINISTRATIVOS_ESTABLECIMIENTO por TSEDE_USUARIO)
                -- salen de fn_usuario_ee_accesibles, no de la union inline
                -- por FK_TROL.
                s.FK_TESTABLECIMIENTO IN (
                    SELECT establecimiento_id
                      FROM academico_test.fn_usuario_ee_accesibles(p_pk_usuario_solicitante)
                )
                -- Coordinador (categoria ADMINISTRATIVOS_SEDES, nivel 3):
                -- solo en las sedes de su scope (fn_usuario_sedes_jornadas_
                -- accesibles) y solo permisos de rol de categoria nivel 3
                -- (pares o inferiores dentro de sede; nunca establecimiento/
                -- territorial/super, ni estudiante/acudiente que son nivel 4).
                OR (
                    su.FK_TSEDE IN (
                        SELECT sede_id
                          FROM academico_test.fn_usuario_sedes_jornadas_accesibles(p_pk_usuario_solicitante)
                    )
                    AND academico_test.fn_rol_categoria_nivel(su.FK_TROL) = 3
                )
           );

        SELECT EXISTS (
            SELECT 1 FROM academico_test.TSEDE_USUARIO su
             WHERE su.FK_TUSUARIO = v_pk_usuario AND su.ACTIVE = TRUE
        ) INTO v_le_queda_algo;

        IF NOT v_le_queda_algo THEN
            UPDATE academico_test.TFUNCIONARIO
               SET ACTIVE = FALSE,
                   MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
                   MODIFIED_AT = CURRENT_TIMESTAMP
             WHERE PK_TFUNCIONARIO = p_pk_funcionario;

            IF NOT academico_test.fn_usu_tiene_otros_vinculos(v_pk_usuario) THEN
                UPDATE academico_test.TUSUARIO
                   SET ACTIVE = FALSE,
                       MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
                       MODIFIED_AT = CURRENT_TIMESTAMP
                 WHERE PK_TUSUARIO = v_pk_usuario;
                v_tusuario_desactivado := TRUE;
            END IF;
        END IF;
    END IF;

    -- V300 -- si la baja llego a desactivar el USUARIO (no solo el
    -- funcionario), su cuenta de login del SSO se deshabilita tambien. La
    -- condicion es v_tusuario_desactivado, asi que cuelga de las mismas dos
    -- guardas de arriba: que al funcionario no le quede ningun TSEDE_USUARIO
    -- activo y que el usuario no cumpla ningun otro papel
    -- (fn_usu_tiene_otros_vinculos). Quien se va de un establecimiento pero
    -- sigue siendo acudiente, o conserva un permiso en otra sede, mantiene
    -- su login.
    --
    -- Se enlaza por email = CUENTA, la identidad de login -- el camino
    -- inverso de public.fn_get_academico_usuario_id. NO por
    -- CORREO_ELECTRONICO, que es dato de negocio y esta duplicado (39.488
    -- usuarios comparten 'notiene@hotmail.com'). Misma forma que
    -- fn_estudiante_soft_delete / fn_padre_soft_delete en matricula.
    --
    -- La fila puede no existir: hay TUSUARIO migrados que nunca tuvieron
    -- login, asi que no se exige.
    IF v_tusuario_desactivado THEN
        SELECT CUENTA
          INTO v_cuenta
          FROM academico_test.TUSUARIO
         WHERE PK_TUSUARIO = v_pk_usuario;

        IF v_cuenta IS NOT NULL THEN
            UPDATE public.users
               SET active  = FALSE,
                   enabled = FALSE
             WHERE UPPER(email) = UPPER(v_cuenta);
        END IF;
    END IF;

    -- V70 -- si perdio rol de rector/secretaria o algun TSEDE_USUARIO,
    -- refleja el cambio en public.role_users.
    PERFORM academico_test.fn_sincronizar_rol_publico(v_pk_usuario);

    RAISE NOTICE 'Baja TFUNCIONARIO=% (autor=%, super_admin=%): tusuario_desactivado=%',
        p_pk_funcionario, p_pk_usuario_solicitante, v_es_super, v_tusuario_desactivado;

    RETURN p_pk_funcionario;
END;
$function$
