-- V558.2 -- etiqueta de auditoria (app.etiqueta) en escrituras cuya migracion
-- duena no se puede editar sin efectos: PIGSE baja masiva, rol y permisos de
-- funcionarios (V366/V369/V390) y CE fn_usu_actualizar (V179).
-- Por que aqui: esos ficheros tambien definen objetos que una version
-- posterior redefine (gate `migration-analysis orden`) o filas de
-- public.query que re-aplicarlos dejaria viejas (V179). Solo agrega el
-- PERFORM fn_audit_declarar (V66/V362); el cuerpo es el vigente.

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

CREATE OR REPLACE FUNCTION academico_test.fn_usu_actualizar(p_pk_usuario_solicitante bigint, p_pk_tusuario bigint, p_fk_tlv_tipo_documento bigint DEFAULT NULL::bigint, p_identificacion character varying DEFAULT NULL::character varying, p_primer_nombre character varying DEFAULT NULL::character varying, p_segundo_nombre character varying DEFAULT NULL::character varying, p_primer_apellido character varying DEFAULT NULL::character varying, p_segundo_apellido character varying DEFAULT NULL::character varying, p_fecha_nacimiento date DEFAULT NULL::date, p_fk_tlv_genero bigint DEFAULT NULL::bigint, p_fk_tlv_tipo_sangre bigint DEFAULT NULL::bigint, p_telefono character varying DEFAULT NULL::character varying, p_correo_electronico character varying DEFAULT NULL::character varying, p_fk_tmunicipio_nacimiento bigint DEFAULT NULL::bigint, p_fk_tlv_zona_residencia bigint DEFAULT NULL::bigint, p_localidad_residencia character varying DEFAULT NULL::character varying, p_comuna_residencia character varying DEFAULT NULL::character varying, p_barrio_residencia character varying DEFAULT NULL::character varying, p_fk_tarchivo bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_tipo_actual  BIGINT;
    v_ident_actual VARCHAR;
    v_tipo_nuevo   BIGINT;
    v_ident_nueva  VARCHAR;
    v_tiene_sede   BOOLEAN;
    v_nivel        INT;
BEGIN
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Actualización de los datos del usuario %s', COALESCE(academico_test.fn_resolver_actor(p_pk_tusuario), p_pk_tusuario::TEXT)));
    -- -----------------------------------------------------------------
    -- 1. La persona debe existir y estar activa.
    -- -----------------------------------------------------------------
    SELECT FK_TLV_TIPO_DOCUMENTO, IDENTIFICACION
      INTO v_tipo_actual, v_ident_actual
      FROM academico_test.TUSUARIO
     WHERE PK_TUSUARIO = p_pk_tusuario AND ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro un usuario activo con el identificador %',
            p_pk_tusuario
            USING ERRCODE = '23503';
    END IF;

    -- -----------------------------------------------------------------
    -- 2. Gate -- REV: modelo dinamico (CU-86e2zenhr).
    --
    -- Antes esto colgaba de fn_matricula_puede_cambiar_estado, que es el
    -- gate de MATRICULA. Era un error mio y tenia una consecuencia visible:
    -- ese gate excluye al super-admin a proposito (decision de negocio del
    -- modulo de matricula), asi que el super-admin NO podia editar los
    -- datos de una persona. Medido antes del cambio: denegado para el
    -- super-admin, para el jefe de sistema del ente territorial y para un
    -- rector sin TSEDE_USUARIO. Editar una persona pertenece a
    -- FUNCIONARIOS, no a MATRICULA, y aqui no aplica esa exclusion.
    --
    -- Se mantiene la forma en dos ramas: si la persona tiene sedes, el
    -- alcance se comprueba contra ellas; si no tiene ninguna, gate amplio
    -- con el mismo criterio que el autocompletado del alta.
    -- -----------------------------------------------------------------
    v_nivel := academico_test.fn_usuario_categoria_rol_nivel(p_pk_usuario_solicitante);

    SELECT EXISTS (
        SELECT 1 FROM academico_test.TSEDE_USUARIO su
          JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
         WHERE su.FK_TUSUARIO = p_pk_tusuario AND su.ACTIVE = TRUE AND s.ACTIVE = TRUE
    ) INTO v_tiene_sede;

    IF v_tiene_sede THEN
        IF v_nivel IS DISTINCT FROM 0
           AND NOT (
                (
                    academico_test.fn_usuario_puede_en_menu(
                        p_pk_usuario_solicitante, 'FUNCIONARIOS', 'EDITAR')
                    AND (
                        -- Los territoriales (nivel 0 y 1) alcanzan a
                        -- cualquiera; el resto, solo a las personas de un
                        -- establecimiento que tengan a su alcance.
                        COALESCE(v_nivel <= 1, FALSE)
                        OR EXISTS (
                            SELECT 1
                              FROM academico_test.TSEDE_USUARIO su
                              JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
                              JOIN academico_test.fn_usuario_ee_accesibles(p_pk_usuario_solicitante) ee
                                ON ee.establecimiento_id = s.FK_TESTABLECIMIENTO
                             WHERE su.FK_TUSUARIO = p_pk_tusuario
                               AND su.ACTIVE = TRUE AND s.ACTIVE = TRUE
                        )
                    )
                )
                OR
                (
                    -- Fallback de rector/secretaria, igual que en el alta:
                    -- sin TSEDE_USUARIO el nivel sale NULL.
                    EXISTS (
                        SELECT 1
                          FROM academico_test.TESTABLECIMIENTO e
                          JOIN academico_test.TFUNCIONARIO f
                            ON f.PK_TFUNCIONARIO IN (e.FK_TFUNCIONARIO_RECTOR, e.FK_TFUNCIONARIO_SECRETARIA)
                          JOIN academico_test.TSEDE s2
                            ON s2.FK_TESTABLECIMIENTO = e.PK_ESTABLECIMIENTO AND s2.ACTIVE = TRUE
                          JOIN academico_test.TSEDE_USUARIO su2
                            ON su2.FK_TSEDE = s2.PK_TSEDE AND su2.ACTIVE = TRUE
                         WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE
                           AND f.FK_TUSUARIO = p_pk_usuario_solicitante
                           AND su2.FK_TUSUARIO = p_pk_tusuario
                    )
                )
           ) THEN
            RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para editar los datos de esta persona'
                USING ERRCODE = '42501',
                      HINT    = 'Hace falta permiso en el modulo FUNCIONARIOS y alcance sobre un establecimiento al que la persona pertenezca';
        END IF;
    ELSE
        -- Sin vinculos: gate amplio, mismo criterio que el alta.
        IF v_nivel IS DISTINCT FROM 0
           AND NOT (
                (
                    COALESCE(v_nivel <= 2, FALSE)
                    AND academico_test.fn_usuario_puede_en_menu(
                            p_pk_usuario_solicitante, 'FUNCIONARIOS', 'EDITAR')
                )
                OR EXISTS (
                    SELECT 1
                      FROM academico_test.TESTABLECIMIENTO e
                      JOIN academico_test.TFUNCIONARIO f
                        ON f.PK_TFUNCIONARIO IN (e.FK_TFUNCIONARIO_RECTOR, e.FK_TFUNCIONARIO_SECRETARIA)
                     WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE
                       AND f.FK_TUSUARIO = p_pk_usuario_solicitante
                )
           ) THEN
            RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para editar los datos de esta persona'
                USING ERRCODE = '42501';
        END IF;
    END IF;

    -- -----------------------------------------------------------------
    -- 3. Documento: si cambia, no puede chocar con otra persona activa.
    --    Existe el indice unico u_tusuario_2 (fk_tlv_tipo_documento,
    --    identificacion) WHERE active; se valida antes para dar un error
    --    legible en vez del de la base.
    -- -----------------------------------------------------------------
    v_tipo_nuevo  := COALESCE(p_fk_tlv_tipo_documento, v_tipo_actual);
    v_ident_nueva := COALESCE(NULLIF(TRIM(p_identificacion), ''), v_ident_actual);

    IF v_tipo_nuevo IS DISTINCT FROM v_tipo_actual
       OR v_ident_nueva IS DISTINCT FROM v_ident_actual THEN
        IF EXISTS (
            SELECT 1 FROM academico_test.TUSUARIO
             WHERE FK_TLV_TIPO_DOCUMENTO = v_tipo_nuevo
               AND IDENTIFICACION        = v_ident_nueva
               AND ACTIVE                = TRUE
               AND PK_TUSUARIO          <> p_pk_tusuario
        ) THEN
            RAISE EXCEPTION 'Ya existe otra persona activa con ese tipo y numero de documento'
                USING ERRCODE = '23505',
                      HINT    = 'Verifique el documento: no puede repetirse entre usuarios activos';
        END IF;
    END IF;

    -- -----------------------------------------------------------------
    -- 4. Guardar.
    -- -----------------------------------------------------------------
    UPDATE academico_test.TUSUARIO
       SET FK_TLV_TIPO_DOCUMENTO    = v_tipo_nuevo,
           IDENTIFICACION           = v_ident_nueva,
           PRIMER_NOMBRE            = COALESCE(NULLIF(TRIM(p_primer_nombre), ''), PRIMER_NOMBRE),
           SEGUNDO_NOMBRE           = COALESCE(NULLIF(TRIM(p_segundo_nombre), ''), SEGUNDO_NOMBRE),
           PRIMER_APELLIDO          = COALESCE(NULLIF(TRIM(p_primer_apellido), ''), PRIMER_APELLIDO),
           SEGUNDO_APELLIDO         = COALESCE(NULLIF(TRIM(p_segundo_apellido), ''), SEGUNDO_APELLIDO),
           FECHA_NACIMIENTO         = COALESCE(p_fecha_nacimiento, FECHA_NACIMIENTO),
           FK_TLV_GENERO            = COALESCE(p_fk_tlv_genero, FK_TLV_GENERO),
           FK_TLV_TIPO_SANGRE       = COALESCE(p_fk_tlv_tipo_sangre, FK_TLV_TIPO_SANGRE),
           TELEFONO                 = COALESCE(NULLIF(TRIM(p_telefono), ''), TELEFONO),
           CORREO_ELECTRONICO       = COALESCE(NULLIF(TRIM(p_correo_electronico), ''), CORREO_ELECTRONICO),
           FK_TMUNICIPIO_NACIMIENTO = COALESCE(p_fk_tmunicipio_nacimiento, FK_TMUNICIPIO_NACIMIENTO),
           FK_TLV_ZONA_RESIDENCIA   = COALESCE(p_fk_tlv_zona_residencia, FK_TLV_ZONA_RESIDENCIA),
           LOCALIDAD_RESIDENCIA     = COALESCE(NULLIF(TRIM(p_localidad_residencia), ''), LOCALIDAD_RESIDENCIA),
           COMUNA_RESIDENCIA        = COALESCE(NULLIF(TRIM(p_comuna_residencia), ''), COMUNA_RESIDENCIA),
           BARRIO_RESIDENCIA        = COALESCE(NULLIF(TRIM(p_barrio_residencia), ''), BARRIO_RESIDENCIA),
           FK_TARCHIVO              = COALESCE(p_fk_tarchivo, FK_TARCHIVO),
           MODIFIED_BY              = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT              = CURRENT_TIMESTAMP
     WHERE PK_TUSUARIO = p_pk_tusuario;

    RETURN jsonb_build_object(
        'mensaje',      'Datos de la persona actualizados',
        'pkTusuario',   p_pk_tusuario,
        'documento',    v_ident_nueva,
        'responsable',  p_pk_usuario_solicitante
    );
END;
$function$

;
