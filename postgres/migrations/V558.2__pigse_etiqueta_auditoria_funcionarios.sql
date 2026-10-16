-- V558.2 -- etiqueta de auditoria (app.etiqueta) en tres escrituras de
-- funcionarios PIGSE: baja masiva, asignacion de rol y permisos.
-- Por que aqui y no en su migracion duena (V366/V369/V390): esos ficheros
-- tambien definen objetos que una version posterior redefine, y editarlos
-- revive esas definiciones viejas al re-aplicar (gate `migration-analysis
-- orden`). Solo agrega PERFORM pigse.fn_audit_declarar (V362); el cuerpo es
-- el vigente. Depende de V362, V366, V369, V390.

CREATE OR REPLACE FUNCTION pigse.fn_fun_baja_bulk(p_pk_usuario_solicitante bigint, p_pks bigint[])
 RETURNS TABLE(pk_funcionario character varying, status character varying)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pigse', 'academico_test', 'public'
AS $function$
DECLARE
    v_pk BIGINT;
BEGIN
    IF NOT pigse.fn_usuario_tiene_rol(p_pk_usuario_solicitante,
            ARRAY['PIGSE-ADMINISTRADOR', 'PIGSE-SECRETARIA_TERRITORIAL']::VARCHAR[]) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    PERFORM pigse.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Baja masiva de %s funcionarios', COALESCE(CARDINALITY(p_pks), 0)));

    FOREACH v_pk IN ARRAY COALESCE(p_pks, ARRAY[]::BIGINT[])
    LOOP
        IF NOT EXISTS (SELECT 1 FROM pigse.TFUNCIONARIO f WHERE f.PK_TFUNCIONARIO = v_pk AND f.ACTIVE = TRUE) THEN
            RETURN QUERY SELECT v_pk::VARCHAR, 'error:no_encontrado'::VARCHAR;
            CONTINUE;
        END IF;

        -- Un funcionario que sea rector/secretaria vigente de un EE no se
        -- puede dar de baja por este camino -- mismo principio que
        -- fn_fun_cancelar_pendiente (V360): primero hay que reasignar el EE.
        IF EXISTS (
            SELECT 1 FROM pigse.TESTABLECIMIENTO e
             WHERE e.FK_TFUNCIONARIO_RECTOR = v_pk OR e.FK_TFUNCIONARIO_SECRETARIA = v_pk
        ) THEN
            RETURN QUERY SELECT v_pk::VARCHAR, 'error:es_rector_o_secretaria'::VARCHAR;
            CONTINUE;
        END IF;

        UPDATE pigse.TFUNCIONARIO
           SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TFUNCIONARIO = v_pk;

        RETURN QUERY SELECT v_pk::VARCHAR, 'eliminado'::VARCHAR;
    END LOOP;
END;
$function$

;

CREATE OR REPLACE FUNCTION pigse.fn_fun_asignar_rol(p_pk_usuario_solicitante bigint, p_pk_funcionario bigint, p_fk_id_role bigint)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pigse', 'academico_test', 'public'
AS $function$
DECLARE
    v_pk_usuario         BIGINT;
    v_fk_establecimiento BIGINT;
    v_active             BOOLEAN;
    v_old_role           BIGINT;
BEGIN
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    IF NOT pigse.fn_usuario_tiene_rol(p_pk_usuario_solicitante,
            ARRAY['PIGSE-ADMINISTRADOR', 'PIGSE-SECRETARIA_TERRITORIAL']::VARCHAR[]) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    IF p_fk_id_role IS NULL THEN
        RAISE EXCEPTION 'El rol es obligatorio' USING ERRCODE = '23502';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.role r WHERE r.id_role = p_fk_id_role) THEN
        RAISE EXCEPTION 'El rol (%) no existe en public.role', p_fk_id_role USING ERRCODE = '23503';
    END IF;

    SELECT f.FK_TUSUARIO, f.FK_TESTABLECIMIENTO, f.ACTIVE
      INTO v_pk_usuario, v_fk_establecimiento, v_active
      FROM pigse.TFUNCIONARIO f
     WHERE f.PK_TFUNCIONARIO = p_pk_funcionario;

    IF NOT FOUND OR v_active = FALSE THEN
        RAISE EXCEPTION 'No se encontro el funcionario solicitado (%)', p_pk_funcionario
            USING ERRCODE = 'P0002';
    END IF;

    IF v_fk_establecimiento IS NULL THEN
        RAISE EXCEPTION 'El funcionario (%) todavia no tiene establecimiento -- asignalo primero (PUT /funcionarios/%)', p_pk_funcionario, p_pk_funcionario
            USING ERRCODE = '22023';
    END IF;

    PERFORM pigse.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Asignación del rol %s al funcionario %s',
               (SELECT r.name FROM public.role r WHERE r.id_role = p_fk_id_role),
               COALESCE(pigse.fn_resolver_actor(v_pk_usuario), p_pk_funcionario::TEXT)),
        v_fk_establecimiento);

    -- Desactiva cualquier OTRO rol que ya tuviera en ESTE establecimiento
    -- (un funcionario tiene un solo rol por EE en el front actual) y limpia
    -- public.role_users si ese rol no le queda vigente por ningún otro
    -- establecimiento/ente -- sin esto, quitarle "Rector" en el EE A dejaria
    -- el claim de rol en el JWT aunque ya no aplique en ningun lado.
    FOR v_old_role IN
        SELECT DISTINCT eu.FK_ID_ROLE
          FROM pigse.TESTABLECIMIENTO_USUARIO eu
         WHERE eu.FK_TUSUARIO = v_pk_usuario
           AND eu.FK_TESTABLECIMIENTO = v_fk_establecimiento
           AND eu.ACTIVE = TRUE
           AND eu.FK_ID_ROLE <> p_fk_id_role
    LOOP
        UPDATE pigse.TESTABLECIMIENTO_USUARIO
           SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TUSUARIO = v_pk_usuario
           AND FK_TESTABLECIMIENTO = v_fk_establecimiento
           AND FK_ID_ROLE = v_old_role
           AND ACTIVE = TRUE;

        IF NOT EXISTS (
            SELECT 1 FROM pigse.TESTABLECIMIENTO_USUARIO eu
             WHERE eu.FK_TUSUARIO = v_pk_usuario AND eu.FK_ID_ROLE = v_old_role AND eu.ACTIVE = TRUE
             UNION ALL
            SELECT 1 FROM pigse.TENTE_USUARIO eu
             WHERE eu.FK_TUSUARIO = v_pk_usuario AND eu.FK_ID_ROLE = v_old_role AND eu.ACTIVE = TRUE
        ) THEN
            DELETE FROM public.role_users ru
             WHERE ru.role_id = v_old_role
               AND ru.user_id = (SELECT u.FK_ID_USER FROM pigse.TUSUARIO u WHERE u.PK_TUSUARIO = v_pk_usuario);
        END IF;
    END LOOP;

    PERFORM pigse.fn_est_usuario_crear(
        p_pk_usuario_solicitante, v_pk_usuario, v_fk_establecimiento, p_fk_id_role
    );

    RETURN TRUE;
END;
$function$

;

CREATE OR REPLACE FUNCTION pigse.fn_fun_permisos_actualizar(p_pk_usuario_solicitante bigint, p_pk_funcionario bigint, p_permisos jsonb)
 RETURNS TABLE(accion character varying, id bigint, status character varying)
 LANGUAGE plpgsql
 SET search_path TO 'pigse', 'public'
AS $function$
DECLARE
    v_pk_usuario    BIGINT;
    v_active_fun    BOOLEAN;
    v_es_super      BOOLEAN;
    v_sedes_plenas  BIGINT[];
    v_sedes_coord   BIGINT[];
    v_perm          RECORD;
    v_fk_sede_op    BIGINT;
    v_fk_rol_op     BIGINT;
BEGIN
    SELECT f.ACTIVE, f.FK_TUSUARIO INTO v_active_fun, v_pk_usuario
      FROM pigse.TFUNCIONARIO f WHERE f.PK_TFUNCIONARIO = p_pk_funcionario;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el funcionario solicitado' USING ERRCODE = 'P0002';
    END IF;
    IF v_active_fun = FALSE THEN
        RAISE EXCEPTION 'El funcionario esta inactivo; no se puede actualizar' USING ERRCODE = '22023';
    END IF;

    PERFORM pigse.fn_assert_permiso_funcionario(p_pk_usuario_solicitante, 'EDITAR', p_pk_funcionario);

    v_es_super := (pigse.fn_usuario_categoria_rol_nivel(p_pk_usuario_solicitante) <= 1);

    IF p_permisos IS NULL OR jsonb_typeof(p_permisos) <> 'array' THEN
        RAISE EXCEPTION 'p_permisos debe ser un JSON array' USING ERRCODE = '22023';
    END IF;

    IF NOT v_es_super THEN
        SELECT ARRAY(
            SELECT s.PK_TSEDE FROM pigse.TSEDE s
             WHERE s.ACTIVE = TRUE
               AND s.FK_TESTABLECIMIENTO IN (SELECT establecimiento_id FROM pigse.fn_usuario_ee_accesibles(p_pk_usuario_solicitante))
        ) INTO v_sedes_plenas;

        SELECT ARRAY(SELECT DISTINCT sede_id FROM pigse.fn_usuario_sedes_jornadas_accesibles(p_pk_usuario_solicitante))
          INTO v_sedes_coord;
    END IF;

    PERFORM pigse.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Actualización de permisos del funcionario %s', COALESCE(pigse.fn_resolver_actor(v_pk_usuario), p_pk_funcionario::TEXT)));

    FOR v_perm IN
        SELECT
            NULLIF(TRIM(elem->>'accion'), '')                       AS accion,
            (elem->>'id')::BIGINT                                    AS id,
            NULLIF(TRIM(elem->>'orden'), '')::NUMERIC(4)             AS orden,
            NULLIF(TRIM(elem->>'fk_rol'), '')::BIGINT                AS fk_rol,
            NULLIF(TRIM(elem->>'fk_sede'), '')::BIGINT               AS fk_sede,
            NULLIF(TRIM(elem->>'fk_jornada'), '')::BIGINT            AS fk_jornada,
            COALESCE(NULLIF(TRIM(elem->>'fk_estado'), ''), 'ACTIVO') AS fk_estado,
            COALESCE(NULLIF(TRIM(elem->>'predeterminado'), '')::NUMERIC(6), 0) AS predeterminado
          FROM jsonb_array_elements(p_permisos) AS elem
    LOOP
        accion := v_perm.accion; id := v_perm.id; status := NULL;

        IF v_perm.accion = 'crear' THEN
            IF v_perm.orden IS NULL OR v_perm.fk_rol IS NULL OR v_perm.fk_sede IS NULL OR v_perm.fk_jornada IS NULL THEN
                status := 'error:faltan_campos_obligatorios'; RETURN NEXT; CONTINUE;
            END IF;

            PERFORM pigse.fn_assert_rango_rol_otorgable(p_pk_usuario_solicitante, v_perm.fk_rol);

            IF NOT v_es_super
               AND NOT (v_perm.fk_sede = ANY(v_sedes_plenas))
               AND NOT (v_perm.fk_sede = ANY(v_sedes_coord) AND pigse.fn_rol_categoria_nivel(v_perm.fk_rol) = 3)
            THEN
                status := 'error:sin_permiso_en_sede'; RETURN NEXT; CONTINUE;
            END IF;

            id := pigse.fn_sede_usuario_crear(
                p_pk_usuario_solicitante, v_perm.fk_sede, v_perm.fk_rol, v_pk_usuario,
                v_perm.orden, v_perm.fk_jornada, v_perm.fk_estado, v_perm.predeterminado
            );

            -- V390: el establecimiento ya no se pide a mano en el
            -- formulario -- se deriva de la sede recien asignada, igual
            -- que CEVAL (que tiene la misma columna pero tampoco la pide).
            UPDATE pigse.TFUNCIONARIO tf
               SET FK_TESTABLECIMIENTO = s.FK_TESTABLECIMIENTO,
                   MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
              FROM pigse.TSEDE s
             WHERE s.PK_TSEDE = v_perm.fk_sede
               AND tf.PK_TFUNCIONARIO = p_pk_funcionario;

            status := 'creado'; RETURN NEXT;

        ELSIF v_perm.accion = 'eliminar' THEN
            IF v_perm.id IS NULL THEN
                status := 'error:falta_id'; RETURN NEXT; CONTINUE;
            END IF;

            SELECT FK_TSEDE, FK_ID_ROLE INTO v_fk_sede_op, v_fk_rol_op
              FROM pigse.TSEDE_USUARIO WHERE PK_TSEDE_USUARIO = v_perm.id;

            IF FOUND AND NOT v_es_super
               AND NOT (v_fk_sede_op = ANY(v_sedes_plenas))
               AND NOT (v_fk_sede_op = ANY(v_sedes_coord) AND pigse.fn_rol_categoria_nivel(v_fk_rol_op) = 3)
            THEN
                status := 'error:sin_permiso_en_sede'; RETURN NEXT; CONTINUE;
            END IF;

            PERFORM pigse.fn_sede_usuario_soft_delete(v_perm.id, p_pk_usuario_solicitante);
            status := 'eliminado'; RETURN NEXT;
        ELSE
            status := 'sin_cambios'; RETURN NEXT;
        END IF;
    END LOOP;
END;
$function$

;

