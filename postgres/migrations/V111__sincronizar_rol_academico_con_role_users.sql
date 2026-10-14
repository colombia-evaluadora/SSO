-- V111 - sincroniza los roles academicos (TSEDE_USUARIO y rector/secretaria
-- de TESTABLECIMIENTO) con public.role_users para que lleguen al JWT.
-- fn_sincronizar_rol_publico recalcula el set completo de roles CEVAL-*;
-- la secretaria de TESTABLECIMIENTO mapea a CEVAL-AUXILIAR_ADMINISTRATIVO.
-- fn_est_crear y fn_est_actualizar viven en V414 y V399.
-- Depende de: V29 (gate por menu), V51.

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
            SELECT tr.CODIGO
              FROM academico_test.TSEDE_USUARIO su
              JOIN academico_test.TROL tr ON tr.PK_TROL = su.FK_TROL
             WHERE su.FK_TUSUARIO = p_pk_tusuario
               AND su.ACTIVE      = TRUE
            UNION
            SELECT 'RECTOR'
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
            SELECT 'AUXILIAR_ADMINISTRATIVO'
             WHERE EXISTS (
                    SELECT 1
                      FROM academico_test.TESTABLECIMIENTO e
                      JOIN academico_test.TFUNCIONARIO f
                        ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_SECRETARIA
                     WHERE f.FK_TUSUARIO = p_pk_tusuario
                       AND f.ACTIVE       = TRUE
                       AND e.ACTIVE       = TRUE
                  )
           ) deseados(CODIGO)
      JOIN public.role r ON r.name = 'CEVAL-' || deseados.CODIGO
     WHERE NOT EXISTS (
            SELECT 1 FROM public.role_users ru
             WHERE ru.user_id = v_id_user AND ru.role_id = r.id_role
           );

    DELETE FROM public.role_users ru
     USING public.role r
     WHERE ru.user_id = v_id_user
       AND ru.role_id = r.id_role
       AND r.name LIKE 'CEVAL-%'
       AND NOT EXISTS (
            SELECT 1
              FROM (
                    SELECT tr.CODIGO
                      FROM academico_test.TSEDE_USUARIO su
                      JOIN academico_test.TROL tr ON tr.PK_TROL = su.FK_TROL
                     WHERE su.FK_TUSUARIO = p_pk_tusuario
                       AND su.ACTIVE      = TRUE
                    UNION
                    SELECT 'RECTOR'
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
                    SELECT 'AUXILIAR_ADMINISTRATIVO'
                     WHERE EXISTS (
                            SELECT 1
                              FROM academico_test.TESTABLECIMIENTO e
                              JOIN academico_test.TFUNCIONARIO f
                                ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_SECRETARIA
                             WHERE f.FK_TUSUARIO = p_pk_tusuario
                               AND f.ACTIVE       = TRUE
                               AND e.ACTIVE       = TRUE
                          )
                   ) deseados(CODIGO)
             WHERE 'CEVAL-' || deseados.CODIGO = r.name
           );
END;
$function$
;

CREATE OR REPLACE FUNCTION academico_test.fn_sede_usuario_crear(p_pk_usuario_solicitante bigint, p_fk_sede bigint, p_fk_rol bigint, p_fk_usuario bigint, p_orden numeric DEFAULT NULL::numeric, p_fk_tlv_jornada bigint DEFAULT NULL::bigint, p_tlv_estado character varying DEFAULT 'ACTIVO'::character varying, p_predeterminado numeric DEFAULT 0)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_pk_sede_usuario  BIGINT;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'FUNCIONARIOS', 'EDITAR',
        NULL, p_fk_sede, p_fk_tlv_jornada
    );

    IF p_fk_sede IS NULL THEN
        RAISE EXCEPTION 'sede (fk_sede) es obligatoria' USING ERRCODE = '23502';
    END IF;
    IF p_fk_rol IS NULL THEN
        RAISE EXCEPTION 'rol (fk_rol) es obligatorio' USING ERRCODE = '23502';
    END IF;
    IF p_fk_usuario IS NULL THEN
        RAISE EXCEPTION 'usuario (fk_usuario) es obligatorio' USING ERRCODE = '23502';
    END IF;
    IF p_orden IS NULL THEN
        RAISE EXCEPTION 'orden es obligatorio' USING ERRCODE = '23502';
    END IF;
    IF p_fk_tlv_jornada IS NULL THEN
        RAISE EXCEPTION 'jornada (fk_tlv_jornada) es obligatoria' USING ERRCODE = '23502';
    END IF;

    IF p_tlv_estado NOT IN ('ACTIVO', 'INACTIVO') THEN
        RAISE EXCEPTION 'TLV_ESTADO (%) no es valido; se esperaba ACTIVO o INACTIVO',
            p_tlv_estado
            USING ERRCODE = '22023';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TSEDE
         WHERE PK_TSEDE = p_fk_sede
           AND ACTIVE   = TRUE
    ) THEN
        RAISE EXCEPTION 'La sede indicada no existe o no esta activa'
            USING ERRCODE = '23503';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TROL
         WHERE PK_TROL = p_fk_rol
           AND ACTIVE  = TRUE
    ) THEN
        RAISE EXCEPTION 'TROL (%) no existe o no esta activo', p_fk_rol
            USING ERRCODE = '23503';
    END IF;

    PERFORM academico_test.fn_assert_rango_rol_otorgable(
        p_pk_usuario_solicitante, p_fk_rol
    );

    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TUSUARIO
         WHERE PK_TUSUARIO = p_fk_usuario
           AND ACTIVE       = TRUE
    ) THEN
        RAISE EXCEPTION 'TUSUARIO (%) no existe o no esta activo', p_fk_usuario
            USING ERRCODE = '23503';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_fk_tlv_jornada
           AND ACTIVE         = TRUE
    ) THEN
        RAISE EXCEPTION 'jornada/TLV (%) no existe o no esta activa en TLISTA_VALOR',
            p_fk_tlv_jornada
            USING ERRCODE = '23503';
    END IF;

    IF EXISTS (
        SELECT 1 FROM academico_test.TSEDE_USUARIO
         WHERE FK_TSEDE       = p_fk_sede
           AND FK_TROL        = p_fk_rol
           AND FK_TUSUARIO    = p_fk_usuario
           AND FK_TLV_JORNADA = p_fk_tlv_jornada
           AND ACTIVE         = TRUE
    ) THEN
        RAISE EXCEPTION 'ya existe un TSEDE_USUARIO activo para (sede=%, rol=%, usuario=%, jornada=%)',
            p_fk_sede, p_fk_rol, p_fk_usuario, p_fk_tlv_jornada
            USING ERRCODE = '23505';
    END IF;

    IF EXISTS (
        SELECT 1 FROM academico_test.TSEDE_USUARIO
         WHERE FK_TSEDE    = p_fk_sede
           AND FK_TROL     = p_fk_rol
           AND FK_TUSUARIO = p_fk_usuario
           AND ORDEN       = p_orden
           AND ACTIVE      = TRUE
    ) THEN
        RAISE EXCEPTION 'ya existe un TSEDE_USUARIO activo para (sede=%, rol=%, usuario=%, orden=%)',
            p_fk_sede, p_fk_rol, p_fk_usuario, p_orden
            USING ERRCODE = '23505';
    END IF;

    INSERT INTO academico_test.TSEDE_USUARIO (
        FK_TSEDE, FK_TROL, FK_TUSUARIO,
        FK_TLV_JORNADA, ORDEN,
        TLV_ESTADO, PREDETERMINADO,
        CREATED_BY, CREATED_AT, ACTIVE
    )
    VALUES (
        p_fk_sede, p_fk_rol, p_fk_usuario,
        p_fk_tlv_jornada, p_orden,
        p_tlv_estado, p_predeterminado,
        p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
    )
    RETURNING PK_TSEDE_USUARIO INTO v_pk_sede_usuario;

    PERFORM academico_test.fn_sincronizar_rol_publico(p_fk_usuario);

    RETURN v_pk_sede_usuario;
END;
$function$
;

CREATE OR REPLACE FUNCTION academico_test.fn_sede_usuario_soft_delete(p_pk_sede_usuario bigint, p_pk_usuario_solicitante bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_active       BOOLEAN;
    v_pk_tusuario  BIGINT;
    v_fk_sede      BIGINT;
    v_fk_rol       BIGINT;
    v_fk_jornada   BIGINT;
BEGIN
    SELECT su.ACTIVE, su.FK_TUSUARIO, su.FK_TSEDE, su.FK_TROL, su.FK_TLV_JORNADA
      INTO v_active, v_pk_tusuario, v_fk_sede, v_fk_rol, v_fk_jornada
      FROM academico_test.TSEDE_USUARIO su
     WHERE su.PK_TSEDE_USUARIO = p_pk_sede_usuario;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el permiso solicitado'
            USING ERRCODE = 'P0002';
    END IF;

    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'FUNCIONARIOS', 'EDITAR',
        NULL, v_fk_sede, v_fk_jornada
    );

    IF v_active = FALSE THEN
        RETURN p_pk_sede_usuario;
    END IF;

    UPDATE academico_test.TSEDE_USUARIO
       SET ACTIVE      = FALSE,
           MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TSEDE_USUARIO = p_pk_sede_usuario;

    PERFORM academico_test.fn_sincronizar_rol_publico(v_pk_tusuario);

    RETURN p_pk_sede_usuario;
END;
$function$
;

DO $$
DECLARE
    v_sig  TEXT;
    r      RECORD;
BEGIN
    FOR r IN
        SELECT * FROM (VALUES
            ('fn_sede_usuario_crear',
             'Crea una fila TSEDE_USUARIO (rol de un funcionario en una sede/jornada) y sincroniza public.role_users via fn_sincronizar_rol_publico para que el rol llegue al JWT sin esperar al siguiente login. GATE (CU-86e2w4xdt, helpers de V29): (1) PERFORM fn_assert_permiso_seccion(solicitante, ''FUNCIONARIOS'', ''EDITAR'', NULL, p_fk_sede, p_fk_tlv_jornada) -- bypass del SUPER_ADMIN, capability configurable por TROL_MENU/TUSUARIO_ROL_PERMISO y scope sobre la sede objetivo (todos los EE para el nivel territorial, fn_usuario_ee_accesibles para el nivel establecimiento, el par (sede, jornada) para el nivel sedes); (2) PERFORM fn_assert_rango_rol_otorgable(solicitante, p_fk_rol) tras validar el rol -- nadie otorga un rol de categoria igual o superior a la propia (p.ej. un Rector puede otorgar Coordinador, pero no Rector ni un rol territorial). Sustituye al gate anterior por lista fija (fn_puede_afectar_usuarios O rol 11 de la sede limitado a roles 9-14). El resto del cuerpo (obligatorios 23502, FKs 23503, unicidad 23505) no cambia.'),
            ('fn_sede_usuario_soft_delete',
             'Baja logica (ACTIVE=FALSE) de una fila TSEDE_USUARIO y resincronizacion de public.role_users via fn_sincronizar_rol_publico (full-resync: si al usuario le queda otra sede con el mismo rol, conserva el CEVAL-<codigo>). Idempotente: si la fila ya estaba inactiva devuelve el PK sin error. GATE (CU-86e2w4xdt): PERFORM fn_assert_permiso_seccion(solicitante, ''FUNCIONARIOS'', ''EDITAR'', NULL, FK_TSEDE, FK_TLV_JORNADA de la fila objetivo, leidas antes de darla de baja) -- capability por menu + scope por sede/jornada de V29, en lugar del gate anterior por lista fija de FK_TROL. La existencia se valida ANTES del gate (P0002) porque el gate necesita la sede/jornada de la fila.')
        ) AS t(proname, descripcion)
    LOOP
        SELECT p.oid::REGPROCEDURE::TEXT
          INTO v_sig
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'academico_test'
           AND p.proname = r.proname
         LIMIT 1;

        IF v_sig IS NOT NULL THEN
            EXECUTE format('COMMENT ON FUNCTION %s IS %L', v_sig, r.descripcion);
        END IF;
    END LOOP;
END;
$$;

DO $$
DECLARE
    v_pk_tusuario BIGINT;
BEGIN
    FOR v_pk_tusuario IN
        SELECT DISTINCT FK_TUSUARIO
          FROM academico_test.TSEDE_USUARIO
         WHERE ACTIVE = TRUE
        UNION
        SELECT DISTINCT f.FK_TUSUARIO
          FROM academico_test.TESTABLECIMIENTO e
          JOIN academico_test.TFUNCIONARIO f
            ON f.PK_TFUNCIONARIO IN (e.FK_TFUNCIONARIO_RECTOR, e.FK_TFUNCIONARIO_SECRETARIA)
         WHERE e.ACTIVE = TRUE
           AND f.ACTIVE = TRUE
    LOOP
        PERFORM academico_test.fn_sincronizar_rol_publico(v_pk_tusuario);
    END LOOP;
END;
$$;
