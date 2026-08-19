-- V78 — sincroniza 8 funciones de escritura desde produccion (172.233.184.248)
-- y les agrega fn_audit_declarar. Ver docs/etiqueta-cambios-por-funcion.md,
-- seccion "Verificacion contra el servidor", para el detalle completo de
-- cada hallazgo que motiva este cambio.
--
-- Puertos desde cero (no existian en local, tenian etiqueta propuesta desde
-- el catalogo original pero nunca se pudieron adoptar):
--   fn_enfasis_actualizar (2 sobrecargas), fn_enfasis_soft_delete,
--   fn_fun_baja_establecimiento
--
-- Reemplazo de implementacion (existia en ambos lados pero eran funciones
-- distintas -- prioridad al servidor por decision explicita del usuario):
--   fn_escala_bulk_delete (local delegaba en un loop a fn_escala_eliminar;
--   se reemplaza por el cascade inline de 4 UPDATE que tiene produccion)
--
-- Reversion de firma a la version de produccion (local habia divergido —
-- prioridad al servidor por decision explicita del usuario):
--   fn_fun_actualizar (ultimo parametro vuelve a ser p_direccion en vez de
--     p_lista_permisos jsonb)
--   fn_periodo_actualizar (recupera p_descanso_inicio/p_descanso_fin)
--   fn_est_crear (quita p_fk_lv_estado_establecimiento; trae el REV4
--     completo -- sede + permisos de rector/secretaria por defecto -- con
--     la salvedad de que las dos llamadas a fn_sincronizar_rol_publico
--     quedan COMENTADAS porque esa funcion no existe en local, ver abajo)

-- Las 3 firmas que cambian de verdad necesitan DROP explicito antes del
-- CREATE OR REPLACE (distinto numero/tipo de parametros).
DROP FUNCTION academico_test.fn_est_crear(p_pk_usuario_solicitante bigint, p_nombre character varying, p_nit character varying, p_fk_municipio bigint, p_fk_propiedad_juridica bigint, p_codigo character varying, p_localidad character varying, p_comuna character varying, p_barrio character varying, p_direccion character varying, p_correo_electronico character varying, p_telefono character varying, p_fax character varying, p_idecol character varying, p_pagina_web character varying, p_fk_lista_valor_zona bigint, p_resolucion_aprobacion character varying, p_licencia_funcionamiento character varying, p_fecha_licencia date, p_fk_lv_calendario bigint, p_fk_lv_idioma bigint, p_fk_lv_genero_est bigint, p_fk_discapacidad bigint, p_talento academico_test.bool_sn, p_etnias academico_test.bool_sn, p_fk_tfuncionario_rector bigint, p_fk_tfuncionario_secretaria bigint, p_subsidio academico_test.bool_sn, p_fk_lv_regimen_catcosto bigint, p_fk_lv_rango_tarifa bigint, p_fk_lv_asociacion_nacional bigint, p_fk_lv_estado_establecimiento bigint, p_fk_archivo bigint);
DROP FUNCTION academico_test.fn_fun_actualizar(p_pk_funcionario bigint, p_pk_usuario_solicitante bigint, p_correo_electronico character varying, p_contrasena_hasheada character varying, p_visado character varying, p_identificacion character varying, p_fk_tlv_tipo_documento bigint, p_primer_nombre character varying, p_segundo_nombre character varying, p_primer_apellido character varying, p_segundo_apellido character varying, p_fecha_nacimiento date, p_fk_tlv_genero bigint, p_telefono character varying, p_estado character varying, p_fk_tarchivo_foto bigint, p_fk_tmunicipio_expedicion bigint, p_fk_tlv_clase_funcionario bigint, p_fk_tlv_nivel_esenanza bigint, p_fk_tlv_grado_escalafon bigint, p_fk_tlv_nivel_educativo bigint, p_fk_tlv_fuente_recurso bigint, p_fk_tlv_cargo bigint, p_fk_tlv_tipo_vinculacion bigint, p_telefonos character varying, p_fecha_vinculacion date, p_fecha_amenazado date, p_amenazado academico_test.bool_sn, p_fk_tlv_area_ensenanza bigint, p_fk_tlv_area_tecnica bigint, p_descripcion_otra_area character varying, p_fk_tlv_etnoeducador bigint, p_fk_tlv_sobresueldo bigint, p_fk_tlv_carrera_administrativa bigint, p_fk_tlv_funcionario_comision bigint, p_fk_tlv_nivel_jerarquico bigint, p_asignacion_basica numeric, p_fk_tlv_tiempo_asignado bigint, p_fk_tdenominacion bigint, p_fk_tlv_especialidad_docente bigint, p_fk_tarchivo bigint, p_lista_permisos jsonb);
DROP FUNCTION academico_test.fn_periodo_actualizar(p_pk_periodo bigint, p_fk_estado bigint, p_fk_sede bigint, p_fecha_inicio date, p_fecha_fin date, p_fecha_limite_matricula date, p_fk_jornada bigint, p_reserva academico_test.bool_sn, p_bloques_por_defecto bigint, p_fk_periodo_anterior bigint, p_hora_inicio time without time zone, p_hora_fin time without time zone, p_pk_usuario_solicitante bigint);
-- fn_escala_bulk_delete: mismo numero/tipo de parametros que la version
-- local, pero Postgres tambien exige DROP si cambia el NOMBRE de un
-- parametro (p_ids -> p_escala_ids, el nombre que usa produccion).
DROP FUNCTION academico_test.fn_escala_bulk_delete(bigint[], bigint);

-- ===== fn_enfasis_soft_delete =====
CREATE OR REPLACE FUNCTION academico_test.fn_enfasis_soft_delete(p_pk bigint, p_pk_usuario_solicitante bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_est BIGINT; v_n INT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_nombre VARCHAR(130);
    v_nombre_pk VARCHAR(130);
BEGIN
    SELECT FK_TESTABLECIMIENTO, NOMBRE INTO v_est, v_nombre FROM academico_test.TENFASIS
     WHERE PK_TENFASIS = p_pk AND ACTIVE = TRUE;
    IF v_est IS NULL THEN
        SELECT NOMBRE INTO v_nombre_pk FROM academico_test.TENFASIS WHERE PK_TENFASIS = p_pk;
        IF v_nombre_pk IS NOT NULL THEN
            RAISE EXCEPTION 'El enfasis % existe pero esta inactivo', v_nombre_pk USING ERRCODE = 'P0002';
        ELSE
            RAISE EXCEPTION 'No existe un enfasis activo con el PK indicado' USING ERRCODE = 'P0002';
        END IF;
    END IF;
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, v_est);
    IF EXISTS (
        SELECT 1 FROM academico_test.TASIGNATURA s WHERE s.FK_TENFASIS = p_pk AND s.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el enfasis %: existen asignaturas asociadas', v_nombre
            USING ERRCODE = '23503';
    END IF;
    -- V78: portada desde produccion (no existia en local) + fn_audit_declarar
    -- agregada antes del UPDATE, tras la ultima validacion.
    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante, format('Eliminación del énfasis %s', v_nombre), v_est);

    UPDATE academico_test.TENFASIS SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TENFASIS = p_pk AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN
        RAISE EXCEPTION 'El enfasis % existe pero esta inactivo', v_nombre USING ERRCODE = 'P0002';
    END IF;
    RETURN p_pk;
END;
$function$;

-- ===== fn_enfasis_actualizar_3 =====
CREATE OR REPLACE FUNCTION academico_test.fn_enfasis_actualizar(p_pk bigint, p_nombre character varying DEFAULT NULL::character varying, p_pk_usuario_solicitante bigint DEFAULT NULL::bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    r academico_test.TENFASIS;
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_nombre_pk VARCHAR(130);
BEGIN
    SELECT *
    INTO r
    FROM academico_test.TENFASIS
    WHERE PK_TENFASIS = p_pk
      AND ACTIVE = TRUE;

    IF NOT FOUND THEN
        SELECT NOMBRE INTO v_nombre_pk FROM academico_test.TENFASIS WHERE PK_TENFASIS = p_pk;
        IF v_nombre_pk IS NOT NULL THEN
            RAISE EXCEPTION 'El enfasis % existe pero esta inactivo', v_nombre_pk
                USING ERRCODE = 'P0002';
        ELSE
            RAISE EXCEPTION 'No existe un enfasis activo con el PK indicado'
                USING ERRCODE = 'P0002';
        END IF;
    END IF;

    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante,
        r.FK_TESTABLECIMIENTO
    );

    IF p_nombre IS NOT NULL
       AND NULLIF(TRIM(p_nombre), '') IS NULL THEN
        RAISE EXCEPTION 'El nombre del enfasis no puede ser vacio'
            USING ERRCODE = '22023';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM academico_test.TENFASIS
        WHERE FK_TESTABLECIMIENTO = r.FK_TESTABLECIMIENTO
          AND ACTIVE = TRUE
          AND PK_TENFASIS <> p_pk
          AND UPPER(TRIM(NOMBRE)) = UPPER(TRIM(p_nombre))
    ) THEN
        RAISE EXCEPTION
            'Ya existe un enfasis con el nombre % en este establecimiento',
            p_nombre
            USING ERRCODE = '23505';
    END IF;

    -- V78: portada desde produccion (no existia en local) + fn_audit_declarar
    -- agregada antes del UPDATE, tras validar duplicado de nombre.
    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante, format('Actualización del énfasis %s', COALESCE(p_nombre, r.NOMBRE)), r.FK_TESTABLECIMIENTO);

    UPDATE academico_test.TENFASIS
    SET
        NOMBRE = p_nombre,
        MODIFIED_BY = v_audit,
        MODIFIED_AT = CURRENT_TIMESTAMP
    WHERE PK_TENFASIS = p_pk;

    RETURN p_pk;
END;
$function$;

-- ===== fn_enfasis_actualizar_5 =====
CREATE OR REPLACE FUNCTION academico_test.fn_enfasis_actualizar(p_pk bigint, p_nombre character varying DEFAULT NULL::character varying, p_codigo character varying DEFAULT NULL::character varying, p_fk_especialidad bigint DEFAULT NULL::bigint, p_pk_usuario_solicitante bigint DEFAULT NULL::bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    r academico_test.TENFASIS;
    v_nombre VARCHAR(130); v_codigo VARCHAR(30);
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_nombre_pk VARCHAR(130);
    v_nombre_esp VARCHAR(130);
BEGIN
    SELECT * INTO r FROM academico_test.TENFASIS WHERE PK_TENFASIS = p_pk AND ACTIVE = TRUE;
    IF NOT FOUND THEN
        SELECT NOMBRE INTO v_nombre_pk FROM academico_test.TENFASIS WHERE PK_TENFASIS = p_pk;
        IF v_nombre_pk IS NOT NULL THEN
            RAISE EXCEPTION 'El enfasis % existe pero esta inactivo', v_nombre_pk USING ERRCODE = 'P0002';
        ELSE
            RAISE EXCEPTION 'No existe un enfasis activo con el PK indicado' USING ERRCODE = 'P0002';
        END IF;
    END IF;
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, r.FK_TESTABLECIMIENTO);
    IF p_nombre IS NOT NULL AND NULLIF(TRIM(p_nombre),'') IS NULL THEN
        RAISE EXCEPTION 'El nombre del enfasis no puede ser vacio' USING ERRCODE = '22023';
    END IF;
    IF p_codigo IS NOT NULL AND NULLIF(TRIM(p_codigo),'') IS NULL THEN
        RAISE EXCEPTION 'El codigo del enfasis no puede ser vacio' USING ERRCODE = '22023';
    END IF;
    IF p_fk_especialidad IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TESPECIALIDAD WHERE PK_ESPECIALIDAD = p_fk_especialidad AND ACTIVE = TRUE
    ) THEN
        SELECT NOMBRE INTO v_nombre_esp FROM academico_test.TESPECIALIDAD WHERE PK_ESPECIALIDAD = p_fk_especialidad;
        IF v_nombre_esp IS NOT NULL THEN
            RAISE EXCEPTION 'La especialidad % ya existe pero esta inactiva', v_nombre_esp USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'La especialidad seleccionada no existe' USING ERRCODE = '23503';
        END IF;
    END IF;
    v_nombre := COALESCE(p_nombre, r.NOMBRE);
    v_codigo := COALESCE(p_codigo, r.CODIGO);
    IF EXISTS (
        SELECT 1 FROM academico_test.TENFASIS
         WHERE FK_TESTABLECIMIENTO = r.FK_TESTABLECIMIENTO AND ACTIVE = TRUE AND PK_TENFASIS <> p_pk
           AND UPPER(TRIM(NOMBRE)) = UPPER(TRIM(v_nombre))
    ) THEN
        RAISE EXCEPTION 'Ya existe un enfasis con el nombre % en este establecimiento', v_nombre
            USING ERRCODE = '23505';
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.TENFASIS
         WHERE FK_TESTABLECIMIENTO = r.FK_TESTABLECIMIENTO AND ACTIVE = TRUE AND PK_TENFASIS <> p_pk
           AND UPPER(TRIM(CODIGO)) = UPPER(TRIM(v_codigo))
    ) THEN
        RAISE EXCEPTION 'Ya existe un enfasis con el codigo % en este establecimiento', v_codigo
            USING ERRCODE = '23505';
    END IF;
    -- V78: portada desde produccion (no existia en local) + fn_audit_declarar
    -- agregada antes del UPDATE, tras validar duplicados de nombre y codigo.
    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante, format('Actualización del énfasis %s', v_nombre), r.FK_TESTABLECIMIENTO);

    UPDATE academico_test.TENFASIS SET
        NOMBRE = v_nombre,
        CODIGO = v_codigo,
        FK_TESPECIALIDAD = COALESCE(p_fk_especialidad, FK_TESPECIALIDAD),
        MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TENFASIS = p_pk;
    RETURN p_pk;
END;
$function$;

-- ===== fn_fun_baja_establecimiento =====
CREATE OR REPLACE FUNCTION academico_test.fn_fun_baja_establecimiento(p_pk_usuario_solicitante bigint, p_pk_funcionario bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_pk_usuario  BIGINT;
    v_fk_ee       BIGINT;
    v_active      BOOLEAN;
    v_pk_rector   BIGINT;
    v_pk_secre    BIGINT;
    v_cascada     INT := 0;
    v_func_nombre TEXT;
BEGIN
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;
    IF p_pk_funcionario IS NULL OR p_pk_funcionario <= 0 THEN
        RAISE EXCEPTION 'p_pk_funcionario es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    SELECT f.FK_TUSUARIO, f.FK_ESTABLECIMIENTO, f.ACTIVE
      INTO v_pk_usuario, v_fk_ee, v_active
      FROM academico_test.TFUNCIONARIO f
     WHERE f.PK_TFUNCIONARIO = p_pk_funcionario;

    IF NOT FOUND OR v_active = FALSE THEN
        RAISE EXCEPTION 'No existe TFUNCIONARIO activo con PK_TFUNCIONARIO = %', p_pk_funcionario
            USING ERRCODE = 'P0002';
    END IF;

    IF v_fk_ee IS NULL THEN
        RAISE EXCEPTION 'TFUNCIONARIO % no esta enlazado a ningun establecimiento (pendiente)', p_pk_funcionario
            USING ERRCODE = '22023',
                  HINT    = 'Un funcionario pendiente de enlazar no tiene baja por establecimiento';
    END IF;

    -- Gate compuesto (mismo patron que fn_sed_soft_delete / fn_fun_enlazar_establecimiento).
    IF academico_test.fn_puede_afectar_establecimiento(p_pk_usuario_solicitante) THEN
        NULL;
    ELSIF EXISTS (
        SELECT 1
          FROM academico_test.TFUNCIONARIO frec
          JOIN academico_test.TESTABLECIMIENTO e ON e.FK_TFUNCIONARIO_RECTOR = frec.PK_TFUNCIONARIO
         WHERE e.PK_ESTABLECIMIENTO = v_fk_ee
           AND e.ACTIVE = TRUE AND frec.ACTIVE = TRUE AND frec.FK_TUSUARIO = p_pk_usuario_solicitante
    ) THEN
        NULL;
    ELSIF EXISTS (
        SELECT 1
          FROM academico_test.TFUNCIONARIO fsec
          JOIN academico_test.TESTABLECIMIENTO e ON e.FK_TFUNCIONARIO_SECRETARIA = fsec.PK_TFUNCIONARIO
         WHERE e.PK_ESTABLECIMIENTO = v_fk_ee
           AND e.ACTIVE = TRUE AND fsec.ACTIVE = TRUE AND fsec.FK_TUSUARIO = p_pk_usuario_solicitante
    ) THEN
        NULL;
    ELSIF EXISTS (
        SELECT 1
          FROM academico_test.TSEDE_USUARIO su
          JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
         WHERE s.FK_TESTABLECIMIENTO = v_fk_ee
           AND s.ACTIVE = TRUE AND su.ACTIVE = TRUE AND su.FK_TROL = 8
           AND su.FK_TUSUARIO = p_pk_usuario_solicitante
    ) THEN
        NULL;
    ELSE
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    -- 1. Bloqueo si es el rector del EE.
    SELECT FK_TFUNCIONARIO_RECTOR, FK_TFUNCIONARIO_SECRETARIA
      INTO v_pk_rector, v_pk_secre
      FROM academico_test.TESTABLECIMIENTO
     WHERE PK_ESTABLECIMIENTO = v_fk_ee;

    IF v_pk_rector = p_pk_funcionario THEN
        RAISE EXCEPTION 'TFUNCIONARIO % es el rector del establecimiento %; no se puede dar de baja desde aqui', p_pk_funcionario, v_fk_ee
            USING ERRCODE = '22023',
                  HINT    = 'El rector no puede eliminarse por este medio; requiere un proceso aparte (pendiente de definir con el equipo)';
    END IF;

    -- V78: portada desde produccion (no existia en local). Resuelve el
    -- nombre para la etiqueta (mismo patron que fn_fun_enlazar_establecimiento,
    -- su inverso) y declara fn_audit_declarar antes del primer UPDATE.
    SELECT TRIM(concat_ws(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE, u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO))
      INTO v_func_nombre
      FROM academico_test.TUSUARIO u WHERE u.PK_TUSUARIO = v_pk_usuario;
    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        format('Desvinculación del funcionario %s del establecimiento', COALESCE(v_func_nombre, p_pk_funcionario::TEXT)),
        v_fk_ee);

    -- 2. Soft delete del TFUNCIONARIO.
    UPDATE academico_test.TFUNCIONARIO
       SET ACTIVE       = FALSE,
           MODIFIED_BY  = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT  = CURRENT_TIMESTAMP
     WHERE PK_TFUNCIONARIO = p_pk_funcionario;

    -- 3. Cascade: TSEDE_USUARIO activos del usuario en sedes de ESTE EE.
    UPDATE academico_test.TSEDE_USUARIO su
       SET ACTIVE       = FALSE,
           MODIFIED_BY  = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT  = CURRENT_TIMESTAMP
      FROM academico_test.TSEDE s
     WHERE s.PK_TSEDE          = su.FK_TSEDE
       AND s.FK_TESTABLECIMIENTO = v_fk_ee
       AND su.FK_TUSUARIO       = v_pk_usuario
       AND su.ACTIVE            = TRUE;

    GET DIAGNOSTICS v_cascada = ROW_COUNT;

    -- 4. Si era la secretaria del EE, se limpia la FK.
    IF v_pk_secre = p_pk_funcionario THEN
        UPDATE academico_test.TESTABLECIMIENTO
           SET FK_TFUNCIONARIO_SECRETARIA = NULL,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_ESTABLECIMIENTO = v_fk_ee;
    END IF;

    RAISE NOTICE 'Baja TFUNCIONARIO=% (EE=%): permisos desactivados=%, secretaria limpiada=%',
        p_pk_funcionario, v_fk_ee, v_cascada, (v_pk_secre = p_pk_funcionario);

    RETURN p_pk_funcionario;
END;
$function$;

-- ===== fn_escala_bulk_delete =====
CREATE OR REPLACE FUNCTION academico_test.fn_escala_bulk_delete(p_escala_ids bigint[], p_pk_usuario_solicitante bigint)
 RETURNS TABLE(id bigint, eliminado boolean, error_code text, error_mensaje text)
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_id             BIGINT;
    v_est            BIGINT;
    v_state          TEXT;
    v_msg            TEXT;
    v_audit          VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_nombre_escala  VARCHAR(130);
BEGIN
    IF p_escala_ids IS NULL THEN RETURN; END IF;
    FOREACH v_id IN ARRAY p_escala_ids LOOP
        BEGIN
            -- Gate grueso + fino: el establecimiento viene del periodo de la
            -- primera TNIVEL_ESCALA activa de la escala (todas comparten el
            -- mismo periodo para una misma escala).
            SELECT academico_test.fn_periodo_establecimiento(ne.FK_PERIODO_ACADEMICO)
              INTO v_est
              FROM academico_test.TNIVEL_ESCALA ne
             WHERE ne.FK_TESCALA = v_id AND ne.ACTIVE = TRUE
             LIMIT 1;
            PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, v_est);

            -- La escala debe existir y estar activa. Si no, se intenta resolver
            -- su nombre ignorando ACTIVE=TRUE para un mensaje legible.
            SELECT NOMBRE INTO v_nombre_escala
              FROM academico_test.TESCALA
             WHERE PK_TESCALA = v_id AND ACTIVE = TRUE;
            IF v_nombre_escala IS NULL THEN
                SELECT NOMBRE INTO v_nombre_escala
                  FROM academico_test.TESCALA WHERE PK_TESCALA = v_id;
                IF v_nombre_escala IS NOT NULL THEN
                    RAISE EXCEPTION 'La escala "%" existe pero esta inactiva', v_nombre_escala
                        USING ERRCODE = 'P0002';
                ELSE
                    RAISE EXCEPTION 'No existe una escala con el identificador indicado'
                        USING ERRCODE = 'P0002';
                END IF;
            END IF;

            -- Bloqueo: bandas en uso por criterios de unidad.
            IF EXISTS (
                SELECT 1 FROM academico_test.TNIVEL_CRITERIO_UNIDAD ncu
                  JOIN academico_test.TESCALA_VALORACION ev
                    ON ev.PK_TESCALA_VALORACION = ncu.FK_TESCALA_VALORACION
                 WHERE ev.FK_TESCALA = v_id AND ncu.ACTIVE = TRUE
            ) THEN
                RAISE EXCEPTION 'No se puede eliminar la escala "%": hay bandas en uso por criterios de unidad',
                    v_nombre_escala USING ERRCODE = '23503';
            END IF;

            -- V78: fn_audit_declarar agregada antes de la cascada, tras la
            -- ultima validacion (bandas en uso). Reemplaza la version local
            -- (que delegaba en fn_escala_eliminar) por esta de produccion,
            -- que hace su propio cascade -- ver docs/etiqueta-cambios-por-funcion.md.
            PERFORM academico_test.fn_audit_declarar(
                p_pk_usuario_solicitante, format('Eliminación de la escala %s', v_nombre_escala), v_est);

            -- Cascada: TVALORACION -> TESCALA_VALORACION -> TNIVEL_ESCALA -> TESCALA.
            UPDATE academico_test.TVALORACION
               SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
             WHERE PK_TVALORACION IN (
                 SELECT FK_TVALORACION FROM academico_test.TESCALA_VALORACION
                  WHERE FK_TESCALA = v_id AND ACTIVE = TRUE
             );
            UPDATE academico_test.TESCALA_VALORACION
               SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
             WHERE FK_TESCALA = v_id AND ACTIVE = TRUE;
            UPDATE academico_test.TNIVEL_ESCALA
               SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
             WHERE FK_TESCALA = v_id AND ACTIVE = TRUE;
            UPDATE academico_test.TESCALA
               SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
             WHERE PK_TESCALA = v_id AND ACTIVE = TRUE;

            id := v_id; eliminado := TRUE; error_code := NULL; error_mensaje := NULL;
            RETURN NEXT;
        EXCEPTION WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
            id := v_id; eliminado := FALSE; error_code := v_state; error_mensaje := v_msg;
            RETURN NEXT;
        END;
    END LOOP;
    RETURN;
END;
$function$;

-- ===== fn_fun_actualizar =====
CREATE OR REPLACE FUNCTION academico_test.fn_fun_actualizar(p_pk_funcionario bigint, p_pk_usuario_solicitante bigint, p_correo_electronico character varying DEFAULT NULL::character varying, p_contrasena_hasheada character varying DEFAULT NULL::character varying, p_visado character varying DEFAULT NULL::character varying, p_identificacion character varying DEFAULT NULL::character varying, p_fk_tlv_tipo_documento bigint DEFAULT NULL::bigint, p_primer_nombre character varying DEFAULT NULL::character varying, p_segundo_nombre character varying DEFAULT NULL::character varying, p_primer_apellido character varying DEFAULT NULL::character varying, p_segundo_apellido character varying DEFAULT NULL::character varying, p_fecha_nacimiento date DEFAULT NULL::date, p_fk_tlv_genero bigint DEFAULT NULL::bigint, p_telefono character varying DEFAULT NULL::character varying, p_estado character varying DEFAULT NULL::character varying, p_fk_tarchivo_foto bigint DEFAULT NULL::bigint, p_fk_tmunicipio_expedicion bigint DEFAULT NULL::bigint, p_fk_tlv_clase_funcionario bigint DEFAULT NULL::bigint, p_fk_tlv_nivel_esenanza bigint DEFAULT NULL::bigint, p_fk_tlv_grado_escalafon bigint DEFAULT NULL::bigint, p_fk_tlv_nivel_educativo bigint DEFAULT NULL::bigint, p_fk_tlv_fuente_recurso bigint DEFAULT NULL::bigint, p_fk_tlv_cargo bigint DEFAULT NULL::bigint, p_fk_tlv_tipo_vinculacion bigint DEFAULT NULL::bigint, p_telefonos character varying DEFAULT NULL::character varying, p_fecha_vinculacion date DEFAULT NULL::date, p_fecha_amenazado date DEFAULT NULL::date, p_amenazado academico_test.bool_sn DEFAULT NULL::character varying, p_fk_tlv_area_ensenanza bigint DEFAULT NULL::bigint, p_fk_tlv_area_tecnica bigint DEFAULT NULL::bigint, p_descripcion_otra_area character varying DEFAULT NULL::character varying, p_fk_tlv_etnoeducador bigint DEFAULT NULL::bigint, p_fk_tlv_sobresueldo bigint DEFAULT NULL::bigint, p_fk_tlv_carrera_administrativa bigint DEFAULT NULL::bigint, p_fk_tlv_funcionario_comision bigint DEFAULT NULL::bigint, p_fk_tlv_nivel_jerarquico bigint DEFAULT NULL::bigint, p_asignacion_basica numeric DEFAULT NULL::numeric, p_fk_tlv_tiempo_asignado bigint DEFAULT NULL::bigint, p_fk_tdenominacion bigint DEFAULT NULL::bigint, p_fk_tlv_especialidad_docente bigint DEFAULT NULL::bigint, p_fk_tarchivo bigint DEFAULT NULL::bigint, p_direccion character varying DEFAULT NULL::character varying)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_pk_usuario      BIGINT;
    v_active_fun      BOOLEAN;
    v_pnombre_actual  VARCHAR(40); v_snombre_actual VARCHAR(40);
    v_papellido_actual VARCHAR(40); v_sapellido_actual VARCHAR(40);
BEGIN
    -- =====================================================================
    -- 0. Gate de autorizacion.
    -- =====================================================================
    IF NOT academico_test.fn_puede_afectar_usuarios(p_pk_usuario_solicitante) THEN
        -- Fallback: rector o secretaria de CUALQUIER EE activo, via
        -- TESTABLECIMIENTO.FK_TFUNCIONARIO_RECTOR/SECRETARIA -- esta
        -- funcion no conoce el EE objetivo (el enlace real ocurre despues,
        -- via fn_fun_enlazar_establecimiento), asi que no se puede acotar
        -- a un EE concreto como hacen fn_est_actualizar o fn_fun_enlazar_
        -- establecimiento. fn_puede_afectar_usuarios (-> fn_puede_afectar_
        -- sede -> fn_puede_afectar_establecimiento) SOLO reconoce el rol
        -- via TSEDE_USUARIO (FK_TROL 1-3/7-8/9): un rector/secretaria recien
        -- asignado, sin ningun TSEDE_USUARIO todavia (caso normal antes de
        -- que se decida si se liga a todas las sedes o no), quedaba sin
        -- poder registrar/editar funcionarios de su propio EE.
        IF NOT EXISTS (
            SELECT 1
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f
                ON f.PK_TFUNCIONARIO IN (e.FK_TFUNCIONARIO_RECTOR, e.FK_TFUNCIONARIO_SECRETARIA)
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
        ) THEN
            RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
                USING ERRCODE = '42501';
        END IF;
    END IF;

    -- =====================================================================
    -- 1. Validar existencia y estado del TFUNCIONARIO. Resolver PK_TUSUARIO
    --    asociado. (FK_TUSUARIO es UNIQUE en TFUNCIONARIO, U_TFUNCIONARIO_2.)
    -- =====================================================================
    SELECT ACTIVE, FK_TUSUARIO
      INTO v_active_fun, v_pk_usuario
      FROM academico_test.TFUNCIONARIO
     WHERE PK_TFUNCIONARIO = p_pk_funcionario;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'no existe TFUNCIONARIO con PK %', p_pk_funcionario
            USING ERRCODE = 'P0002';
    END IF;

    IF v_active_fun = FALSE THEN
        RAISE EXCEPTION 'TFUNCIONARIO % esta inactivo; no se puede actualizar', p_pk_funcionario
            USING ERRCODE = '22023';
    END IF;

    -- =====================================================================
    -- 2. Validaciones de valor (campos no-NULL que si llegan vacios => RAISE).
    -- =====================================================================
    IF p_correo_electronico IS NOT NULL AND NULLIF(TRIM(p_correo_electronico), '') IS NULL THEN
        RAISE EXCEPTION 'correo_electronico no puede ser vacio si se envia'
            USING ERRCODE = '22023';
    END IF;
    IF p_contrasena_hasheada IS NOT NULL AND NULLIF(TRIM(p_contrasena_hasheada), '') IS NULL THEN
        RAISE EXCEPTION 'contrasena_hasheada no puede ser vacia si se envia'
            USING ERRCODE = '22023';
    END IF;
    IF p_identificacion IS NOT NULL AND NULLIF(TRIM(p_identificacion), '') IS NULL THEN
        RAISE EXCEPTION 'identificacion no puede ser vacia si se envia'
            USING ERRCODE = '22023';
    END IF;
    IF p_primer_nombre IS NOT NULL AND NULLIF(TRIM(p_primer_nombre), '') IS NULL THEN
        RAISE EXCEPTION 'primer_nombre no puede ser vacio si se envia'
            USING ERRCODE = '22023';
    END IF;
    IF p_primer_apellido IS NOT NULL AND NULLIF(TRIM(p_primer_apellido), '') IS NULL THEN
        RAISE EXCEPTION 'primer_apellido no puede ser vacio si se envia'
            USING ERRCODE = '22023';
    END IF;
    IF p_telefonos IS NOT NULL AND NULLIF(TRIM(p_telefonos), '') IS NULL THEN
        RAISE EXCEPTION 'telefonos no puede ser vacio si se envia'
            USING ERRCODE = '22023';
    END IF;
    IF p_estado IS NOT NULL AND p_estado NOT IN ('A', 'I') THEN
        RAISE EXCEPTION 'estado (%) no es valido; se esperaba ''A'' o ''I''', p_estado
            USING ERRCODE = '22023';
    END IF;
    IF p_descripcion_otra_area IS NOT NULL AND LENGTH(p_descripcion_otra_area) > 24 THEN
        RAISE EXCEPTION 'descripcion_otra_area excede el limite de 24 caracteres del DDL'
            USING ERRCODE = '22023';
    END IF;

    -- =====================================================================
    -- 3. Validacion de FKs opcionales. Solo si llegaron con valor.
    -- =====================================================================
    IF p_fk_tlv_tipo_documento IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_tlv_tipo_documento
               AND ACTIVE         = TRUE
          )
    THEN
        RAISE EXCEPTION 'tipo de documento (%) no existe o no esta activo', p_fk_tlv_tipo_documento
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlv_genero IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_tlv_genero
               AND ACTIVE         = TRUE
          )
    THEN
        RAISE EXCEPTION 'genero (%) no existe o no esta activo', p_fk_tlv_genero
            USING ERRCODE = '23503';
    END IF;

    -- V69 — sin "AND ACTIVE = TRUE": ver comentario de cabecera.
    IF p_fk_tarchivo_foto IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TARCHIVO
             WHERE PK_TARCHIVO = p_fk_tarchivo_foto
          )
    THEN
        RAISE EXCEPTION 'archivo de foto (%) no existe en TARCHIVO', p_fk_tarchivo_foto
            USING ERRCODE = '23503';
    END IF;

    -- TFUNCIONARIO: municipio de expedicion.
    IF p_fk_tmunicipio_expedicion IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TMUNICIPIO
             WHERE PK_TMUNICIPIO = p_fk_tmunicipio_expedicion
          )
    THEN
        RAISE EXCEPTION 'municipio de expedicion (%) no existe en TMUNICIPIO',
            p_fk_tmunicipio_expedicion
            USING ERRCODE = '23503';
    END IF;

    -- TFUNCIONARIO: 7 FKs TLV_* del bloque nuevo.
    IF p_fk_tlv_clase_funcionario IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_tlv_clase_funcionario
               AND ACTIVE         = TRUE
          )
    THEN
        RAISE EXCEPTION 'clase_funcionario/TLV (%) no existe o no esta activa',
            p_fk_tlv_clase_funcionario
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlv_nivel_esenanza IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_tlv_nivel_esenanza
               AND ACTIVE         = TRUE
          )
    THEN
        RAISE EXCEPTION 'nivel_esenanza/TLV (%) no existe o no esta activa',
            p_fk_tlv_nivel_esenanza
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlv_grado_escalafon IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_tlv_grado_escalafon
               AND ACTIVE         = TRUE
          )
    THEN
        RAISE EXCEPTION 'grado_escalafon/TLV (%) no existe o no esta activo',
            p_fk_tlv_grado_escalafon
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlv_nivel_educativo IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_tlv_nivel_educativo
               AND ACTIVE         = TRUE
          )
    THEN
        RAISE EXCEPTION 'nivel_educativo/TLV (%) no existe o no esta activo',
            p_fk_tlv_nivel_educativo
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlv_fuente_recurso IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_tlv_fuente_recurso
               AND ACTIVE         = TRUE
          )
    THEN
        RAISE EXCEPTION 'fuente_recurso/TLV (%) no existe o no esta activa',
            p_fk_tlv_fuente_recurso
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlv_cargo IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_tlv_cargo
               AND ACTIVE         = TRUE
          )
    THEN
        RAISE EXCEPTION 'cargo/TLV (%) no existe o no esta activo',
            p_fk_tlv_cargo
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlv_tipo_vinculacion IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_tlv_tipo_vinculacion
               AND ACTIVE         = TRUE
          )
    THEN
        RAISE EXCEPTION 'tipo_vinculacion/TLV (%) no existe o no esta activo',
            p_fk_tlv_tipo_vinculacion
            USING ERRCODE = '23503';
    END IF;

    -- TFUNCIONARIO: FKs TLV_* adicionales (areas, etnoeducador, etc.).
    IF p_fk_tlv_area_ensenanza IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_tlv_area_ensenanza
               AND ACTIVE         = TRUE
          )
    THEN
        RAISE EXCEPTION 'area_ensenanza/TLV (%) no existe o no esta activa',
            p_fk_tlv_area_ensenanza
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlv_area_tecnica IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_tlv_area_tecnica
               AND ACTIVE         = TRUE
          )
    THEN
        RAISE EXCEPTION 'area_tecnica/TLV (%) no existe o no esta activa',
            p_fk_tlv_area_tecnica
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlv_etnoeducador IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_tlv_etnoeducador
               AND ACTIVE         = TRUE
          )
    THEN
        RAISE EXCEPTION 'etnoeducador/TLV (%) no existe o no esta activo',
            p_fk_tlv_etnoeducador
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlv_sobresueldo IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_tlv_sobresueldo
               AND ACTIVE         = TRUE
          )
    THEN
        RAISE EXCEPTION 'sobresueldo/TLV (%) no existe o no esta activo',
            p_fk_tlv_sobresueldo
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlv_carrera_administrativa IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_tlv_carrera_administrativa
               AND ACTIVE         = TRUE
          )
    THEN
        RAISE EXCEPTION 'carrera_administrativa/TLV (%) no existe o no esta activa',
            p_fk_tlv_carrera_administrativa
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlv_funcionario_comision IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_tlv_funcionario_comision
               AND ACTIVE         = TRUE
          )
    THEN
        RAISE EXCEPTION 'funcionario_comision/TLV (%) no existe o no esta activo',
            p_fk_tlv_funcionario_comision
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlv_nivel_jerarquico IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_tlv_nivel_jerarquico
               AND ACTIVE         = TRUE
          )
    THEN
        RAISE EXCEPTION 'nivel_jerarquico/TLV (%) no existe o no esta activo',
            p_fk_tlv_nivel_jerarquico
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlv_tiempo_asignado IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_tlv_tiempo_asignado
               AND ACTIVE         = TRUE
          )
    THEN
        RAISE EXCEPTION 'tiempo_asignado/TLV (%) no existe o no esta activo',
            p_fk_tlv_tiempo_asignado
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlv_especialidad_docente IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_tlv_especialidad_docente
               AND ACTIVE         = TRUE
          )
    THEN
        RAISE EXCEPTION 'especialidad_docente/TLV (%) no existe o no esta activa',
            p_fk_tlv_especialidad_docente
            USING ERRCODE = '23503';
    END IF;

    -- TFUNCIONARIO: TDENOMINACION y TARCHIVO (foto/archivo del funcionario).
    IF p_fk_tdenominacion IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TDENOMINACION
             WHERE PK_TDENOMINACION = p_fk_tdenominacion
               AND ACTIVE           = TRUE
          )
    THEN
        RAISE EXCEPTION 'denominacion (%) no existe o no esta activa', p_fk_tdenominacion
            USING ERRCODE = '23503';
    END IF;

    -- V69 — sin "AND ACTIVE = TRUE": ver comentario de cabecera.
    IF p_fk_tarchivo IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TARCHIVO
             WHERE PK_TARCHIVO = p_fk_tarchivo
          )
    THEN
        RAISE EXCEPTION 'archivo (%) no existe en TARCHIVO', p_fk_tarchivo
            USING ERRCODE = '23503';
    END IF;

    -- =====================================================================
    -- 4. Validacion de unicidad (TUSUARIO) — excluyendo el propio PK.
    -- =====================================================================
    IF p_correo_electronico IS NOT NULL
       AND EXISTS (
            SELECT 1 FROM academico_test.TUSUARIO
             WHERE UPPER(CUENTA) = UPPER(p_correo_electronico)
               AND ACTIVE        = TRUE
               AND PK_TUSUARIO  <> v_pk_usuario
          )
    THEN
        RAISE EXCEPTION 'cuenta/correo (%) ya esta registrada por otro usuario activo',
            p_correo_electronico
            USING ERRCODE = '23505';
    END IF;

    IF (p_fk_tlv_tipo_documento IS NOT NULL OR p_identificacion IS NOT NULL)
       AND EXISTS (
            SELECT 1 FROM academico_test.TUSUARIO
             WHERE FK_TLV_TIPO_DOCUMENTO =
                   COALESCE(p_fk_tlv_tipo_documento, FK_TLV_TIPO_DOCUMENTO)
               AND IDENTIFICACION         =
                   COALESCE(p_identificacion,        IDENTIFICACION)
               AND ACTIVE                  = TRUE
               AND PK_TUSUARIO            <> v_pk_usuario
          )
    THEN
        RAISE EXCEPTION 'ya existe otro usuario activo con tipo_documento y/o identificacion enviados'
            USING ERRCODE = '23505',
                  HINT    = 'Cambie el tipo de documento y/o la identificacion para evitar colision';
    END IF;

    -- V78: revierte la firma a la version de produccion (el ultimo parametro
    -- vuelve a ser p_direccion en vez de p_lista_permisos jsonb -- ver
    -- docs/etiqueta-cambios-por-funcion.md, seccion de verificacion contra
    -- el servidor). fn_audit_declarar agregada antes del primer UPDATE (a
    -- TUSUARIO), tras la ultima validacion -- mismo texto de etiqueta que
    -- ya tenia la version local (V76).
    SELECT PRIMER_NOMBRE, SEGUNDO_NOMBRE, PRIMER_APELLIDO, SEGUNDO_APELLIDO
      INTO v_pnombre_actual, v_snombre_actual, v_papellido_actual, v_sapellido_actual
      FROM academico_test.TUSUARIO WHERE PK_TUSUARIO = v_pk_usuario;
    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        format('Actualización de datos del funcionario %s', TRIM(concat_ws(' ',
            COALESCE(p_primer_nombre, v_pnombre_actual), COALESCE(p_segundo_nombre, v_snombre_actual),
            COALESCE(p_primer_apellido, v_papellido_actual), COALESCE(p_segundo_apellido, v_sapellido_actual)))));

    -- =====================================================================
    -- 5. PATCH de TUSUARIO (un solo UPDATE con deteccion de cambios).
    --    Solo campos propios del usuario (los del esquema). Los campos
    --    de TFUNCIONARIO van en el UPDATE de abajo.
    -- =====================================================================
    WITH current_row AS (
        SELECT CORREO_ELECTRONICO, CONTRASENA, VISADO,
               IDENTIFICACION, FK_TLV_TIPO_DOCUMENTO,
               PRIMER_NOMBRE, SEGUNDO_NOMBRE,
               PRIMER_APELLIDO, SEGUNDO_APELLIDO,
               FECHA_NACIMIENTO, FK_TLV_GENERO,
               TELEFONO, ESTADO, FK_TARCHIVO
          FROM academico_test.TUSUARIO
         WHERE PK_TUSUARIO = v_pk_usuario
    ),
    cambios AS (
        SELECT
            (p_correo_electronico    IS NOT NULL AND p_correo_electronico    IS DISTINCT FROM current_row.CORREO_ELECTRONICO) AS chg_correo,
            (p_contrasena_hasheada   IS NOT NULL AND p_contrasena_hasheada   IS DISTINCT FROM current_row.CONTRASENA)        AS chg_pass,
            (p_visado                IS NOT NULL AND p_visado                IS DISTINCT FROM current_row.VISADO)             AS chg_visado,
            (p_identificacion        IS NOT NULL AND p_identificacion        IS DISTINCT FROM current_row.IDENTIFICACION)     AS chg_identificacion,
            (p_fk_tlv_tipo_documento IS NOT NULL AND p_fk_tlv_tipo_documento IS DISTINCT FROM current_row.FK_TLV_TIPO_DOCUMENTO) AS chg_tipo_doc,
            (p_primer_nombre         IS NOT NULL AND p_primer_nombre         IS DISTINCT FROM current_row.PRIMER_NOMBRE)      AS chg_pnombre,
            (p_segundo_nombre        IS NOT NULL AND p_segundo_nombre        IS DISTINCT FROM current_row.SEGUNDO_NOMBRE)     AS chg_snombre,
            (p_primer_apellido       IS NOT NULL AND p_primer_apellido       IS DISTINCT FROM current_row.PRIMER_APELLIDO)    AS chg_papellido,
            (p_segundo_apellido      IS NOT NULL AND p_segundo_apellido      IS DISTINCT FROM current_row.SEGUNDO_APELLIDO)   AS chg_sapellido,
            (p_fecha_nacimiento      IS NOT NULL AND p_fecha_nacimiento      IS DISTINCT FROM current_row.FECHA_NACIMIENTO)   AS chg_fecha_nac,
            (p_fk_tlv_genero         IS NOT NULL AND p_fk_tlv_genero         IS DISTINCT FROM current_row.FK_TLV_GENERO)      AS chg_genero,
            (p_telefono              IS NOT NULL AND p_telefono              IS DISTINCT FROM current_row.TELEFONO)           AS chg_telefono,
            (p_estado                IS NOT NULL AND p_estado                IS DISTINCT FROM current_row.ESTADO)             AS chg_estado,
            (p_fk_tarchivo_foto      IS NOT NULL AND p_fk_tarchivo_foto      IS DISTINCT FROM current_row.FK_TARCHIVO)        AS chg_foto
        FROM current_row
    )
    UPDATE academico_test.TUSUARIO t
       SET CORREO_ELECTRONICO    = COALESCE(p_correo_electronico,    t.CORREO_ELECTRONICO),
           CONTRASENA            = COALESCE(p_contrasena_hasheada,   t.CONTRASENA),
           VISADO                = COALESCE(p_visado,                t.VISADO),
           IDENTIFICACION        = COALESCE(p_identificacion,        t.IDENTIFICACION),
           FK_TLV_TIPO_DOCUMENTO = COALESCE(p_fk_tlv_tipo_documento, t.FK_TLV_TIPO_DOCUMENTO),
           PRIMER_NOMBRE         = COALESCE(p_primer_nombre,         t.PRIMER_NOMBRE),
           SEGUNDO_NOMBRE        = COALESCE(p_segundo_nombre,        t.SEGUNDO_NOMBRE),
           PRIMER_APELLIDO       = COALESCE(p_primer_apellido,       t.PRIMER_APELLIDO),
           SEGUNDO_APELLIDO      = COALESCE(p_segundo_apellido,      t.SEGUNDO_APELLIDO),
           FECHA_NACIMIENTO      = COALESCE(p_fecha_nacimiento,      t.FECHA_NACIMIENTO),
           FK_TLV_GENERO         = COALESCE(p_fk_tlv_genero,         t.FK_TLV_GENERO),
           TELEFONO              = COALESCE(p_telefono,              t.TELEFONO),
           ESTADO                = COALESCE(p_estado,                t.ESTADO),
           FK_TARCHIVO           = COALESCE(p_fk_tarchivo_foto,      t.FK_TARCHIVO),
           MODIFIED_BY = CASE
                            WHEN (SELECT c.chg_correo OR c.chg_pass OR c.chg_visado OR c.chg_identificacion
                                       OR c.chg_tipo_doc OR c.chg_pnombre OR c.chg_snombre
                                       OR c.chg_papellido OR c.chg_sapellido OR c.chg_fecha_nac
                                       OR c.chg_genero OR c.chg_telefono OR c.chg_estado OR c.chg_foto
                                  FROM cambios c)
                            THEN p_pk_usuario_solicitante::VARCHAR
                            ELSE t.MODIFIED_BY
                          END,
           MODIFIED_AT = CASE
                            WHEN (SELECT c.chg_correo OR c.chg_pass OR c.chg_visado OR c.chg_identificacion
                                       OR c.chg_tipo_doc OR c.chg_pnombre OR c.chg_snombre
                                       OR c.chg_papellido OR c.chg_sapellido OR c.chg_fecha_nac
                                       OR c.chg_genero OR c.chg_telefono OR c.chg_estado OR c.chg_foto
                                  FROM cambios c)
                            THEN CURRENT_TIMESTAMP
                            ELSE t.MODIFIED_AT
                          END
      FROM cambios c
     WHERE t.PK_TUSUARIO = v_pk_usuario
       AND t.ACTIVE      = TRUE;

    -- =====================================================================
    -- 6. PATCH de TFUNCIONARIO (un solo UPDATE con deteccion de cambios).
    --    Todos los campos que llegaron con valor; los demas quedan intactos.
    -- =====================================================================
    WITH current_row AS (
        SELECT FK_TMUNICIPIO_EXPEDICION,
               FK_TLV_CLASE_FUNCIONARIO, FK_TLV_NIVEL_ESENANZA, FK_TLV_GRADO_ESCALAFON,
               FK_TLV_NIVEL_EDUCATIVO, FK_TLV_FUENTE_RECURSO, FK_TLV_CARGO,
               FK_TLV_TIPO_VINCULACION,
               TELEFONOS, FECHA_VINCULACION, FECHA_AMENAZADO, AMENAZADO,
               FK_TLV_AREA_ENSENANZA, FK_TLV_AREA_TECNICA, DESCRIPCION_OTRA_AREA,
               FK_TLV_ETNOEDUCADOR, FK_TLV_SOBRESUELDO, FK_TLV_CARRERA_ADMINISTRATIVA,
               FK_TLV_FUNCIONARIO_COMISION, FK_TLV_NIVEL_JERARQUICO,
               ASIGNACION_BASICA, FK_TLV_TIEMPO_ASIGNADO, FK_TDENOMINACION,
               FK_TLV_ESPECIALIDAD_DOCENTE, FK_TARCHIVO, DIRECCION
          FROM academico_test.TFUNCIONARIO
         WHERE PK_TFUNCIONARIO = p_pk_funcionario
    ),
    cambios AS (
        SELECT
            (p_fk_tmunicipio_expedicion      IS NOT NULL AND p_fk_tmunicipio_expedicion      IS DISTINCT FROM current_row.FK_TMUNICIPIO_EXPEDICION)   AS chg_muni_exp,
            (p_direccion                     IS NOT NULL AND p_direccion                     IS DISTINCT FROM current_row.DIRECCION)                  AS chg_direccion,
            (p_fk_tlv_clase_funcionario      IS NOT NULL AND p_fk_tlv_clase_funcionario      IS DISTINCT FROM current_row.FK_TLV_CLASE_FUNCIONARIO)   AS chg_clase,
            (p_fk_tlv_nivel_esenanza         IS NOT NULL AND p_fk_tlv_nivel_esenanza         IS DISTINCT FROM current_row.FK_TLV_NIVEL_ESENANZA)      AS chg_nivel_e,
            (p_fk_tlv_grado_escalafon        IS NOT NULL AND p_fk_tlv_grado_escalafon        IS DISTINCT FROM current_row.FK_TLV_GRADO_ESCALAFON)     AS chg_grado,
            (p_fk_tlv_nivel_educativo        IS NOT NULL AND p_fk_tlv_nivel_educativo        IS DISTINCT FROM current_row.FK_TLV_NIVEL_EDUCATIVO)     AS chg_nivel_ed,
            (p_fk_tlv_fuente_recurso         IS NOT NULL AND p_fk_tlv_fuente_recurso         IS DISTINCT FROM current_row.FK_TLV_FUENTE_RECURSO)      AS chg_fuente,
            (p_fk_tlv_cargo                  IS NOT NULL AND p_fk_tlv_cargo                  IS DISTINCT FROM current_row.FK_TLV_CARGO)               AS chg_cargo,
            (p_fk_tlv_tipo_vinculacion       IS NOT NULL AND p_fk_tlv_tipo_vinculacion       IS DISTINCT FROM current_row.FK_TLV_TIPO_VINCULACION)    AS chg_tipo_vinc,
            (p_telefonos                     IS NOT NULL AND p_telefonos                     IS DISTINCT FROM current_row.TELEFONOS)                  AS chg_telefonos,
            (p_fecha_vinculacion             IS NOT NULL AND p_fecha_vinculacion             IS DISTINCT FROM current_row.FECHA_VINCULACION)          AS chg_fvinc,
            (p_fecha_amenazado               IS NOT NULL AND p_fecha_amenazado               IS DISTINCT FROM current_row.FECHA_AMENAZADO)            AS chg_famen,
            (p_amenazado                     IS NOT NULL AND p_amenazado                     IS DISTINCT FROM current_row.AMENAZADO)                  AS chg_amen,
            (p_fk_tlv_area_ensenanza         IS NOT NULL AND p_fk_tlv_area_ensenanza         IS DISTINCT FROM current_row.FK_TLV_AREA_ENSENANZA)      AS chg_area_e,
            (p_fk_tlv_area_tecnica           IS NOT NULL AND p_fk_tlv_area_tecnica           IS DISTINCT FROM current_row.FK_TLV_AREA_TECNICA)        AS chg_area_t,
            (p_descripcion_otra_area         IS NOT NULL AND p_descripcion_otra_area         IS DISTINCT FROM current_row.DESCRIPCION_OTRA_AREA)      AS chg_desc_area,
            (p_fk_tlv_etnoeducador           IS NOT NULL AND p_fk_tlv_etnoeducador           IS DISTINCT FROM current_row.FK_TLV_ETNOEDUCADOR)        AS chg_etno,
            (p_fk_tlv_sobresueldo            IS NOT NULL AND p_fk_tlv_sobresueldo            IS DISTINCT FROM current_row.FK_TLV_SOBRESUELDO)         AS chg_sobre,
            (p_fk_tlv_carrera_administrativa IS NOT NULL AND p_fk_tlv_carrera_administrativa IS DISTINCT FROM current_row.FK_TLV_CARRERA_ADMINISTRATIVA) AS chg_carrera,
            (p_fk_tlv_funcionario_comision   IS NOT NULL AND p_fk_tlv_funcionario_comision   IS DISTINCT FROM current_row.FK_TLV_FUNCIONARIO_COMISION) AS chg_comision,
            (p_fk_tlv_nivel_jerarquico       IS NOT NULL AND p_fk_tlv_nivel_jerarquico       IS DISTINCT FROM current_row.FK_TLV_NIVEL_JERARQUICO)    AS chg_nivel_j,
            (p_asignacion_basica             IS NOT NULL AND p_asignacion_basica             IS DISTINCT FROM current_row.ASIGNACION_BASICA)          AS chg_asig,
            (p_fk_tlv_tiempo_asignado        IS NOT NULL AND p_fk_tlv_tiempo_asignado        IS DISTINCT FROM current_row.FK_TLV_TIEMPO_ASIGNADO)     AS chg_tiempo,
            (p_fk_tdenominacion              IS NOT NULL AND p_fk_tdenominacion              IS DISTINCT FROM current_row.FK_TDENOMINACION)           AS chg_denom,
            (p_fk_tlv_especialidad_docente   IS NOT NULL AND p_fk_tlv_especialidad_docente   IS DISTINCT FROM current_row.FK_TLV_ESPECIALIDAD_DOCENTE) AS chg_esp_doc,
            (p_fk_tarchivo                   IS NOT NULL AND p_fk_tarchivo                   IS DISTINCT FROM current_row.FK_TARCHIVO)                AS chg_archivo
        FROM current_row
    )
    UPDATE academico_test.TFUNCIONARIO t
       SET FK_TMUNICIPIO_EXPEDICION        = COALESCE(p_fk_tmunicipio_expedicion,      t.FK_TMUNICIPIO_EXPEDICION),
           FK_TLV_CLASE_FUNCIONARIO        = COALESCE(p_fk_tlv_clase_funcionario,      t.FK_TLV_CLASE_FUNCIONARIO),
           FK_TLV_NIVEL_ESENANZA           = COALESCE(p_fk_tlv_nivel_esenanza,         t.FK_TLV_NIVEL_ESENANZA),
           FK_TLV_GRADO_ESCALAFON          = COALESCE(p_fk_tlv_grado_escalafon,        t.FK_TLV_GRADO_ESCALAFON),
           FK_TLV_NIVEL_EDUCATIVO          = COALESCE(p_fk_tlv_nivel_educativo,        t.FK_TLV_NIVEL_EDUCATIVO),
           FK_TLV_FUENTE_RECURSO           = COALESCE(p_fk_tlv_fuente_recurso,         t.FK_TLV_FUENTE_RECURSO),
           FK_TLV_CARGO                    = COALESCE(p_fk_tlv_cargo,                  t.FK_TLV_CARGO),
           FK_TLV_TIPO_VINCULACION         = COALESCE(p_fk_tlv_tipo_vinculacion,       t.FK_TLV_TIPO_VINCULACION),
           TELEFONOS                       = COALESCE(p_telefonos,                     t.TELEFONOS),
           FECHA_VINCULACION               = COALESCE(p_fecha_vinculacion,             t.FECHA_VINCULACION),
           FECHA_AMENAZADO                 = COALESCE(p_fecha_amenazado,               t.FECHA_AMENAZADO),
           AMENAZADO                       = COALESCE(p_amenazado,                     t.AMENAZADO),
           FK_TLV_AREA_ENSENANZA           = COALESCE(p_fk_tlv_area_ensenanza,         t.FK_TLV_AREA_ENSENANZA),
           FK_TLV_AREA_TECNICA             = COALESCE(p_fk_tlv_area_tecnica,           t.FK_TLV_AREA_TECNICA),
           DESCRIPCION_OTRA_AREA           = COALESCE(p_descripcion_otra_area,         t.DESCRIPCION_OTRA_AREA),
           FK_TLV_ETNOEDUCADOR             = COALESCE(p_fk_tlv_etnoeducador,           t.FK_TLV_ETNOEDUCADOR),
           FK_TLV_SOBRESUELDO              = COALESCE(p_fk_tlv_sobresueldo,            t.FK_TLV_SOBRESUELDO),
           FK_TLV_CARRERA_ADMINISTRATIVA   = COALESCE(p_fk_tlv_carrera_administrativa, t.FK_TLV_CARRERA_ADMINISTRATIVA),
           FK_TLV_FUNCIONARIO_COMISION     = COALESCE(p_fk_tlv_funcionario_comision,   t.FK_TLV_FUNCIONARIO_COMISION),
           FK_TLV_NIVEL_JERARQUICO         = COALESCE(p_fk_tlv_nivel_jerarquico,       t.FK_TLV_NIVEL_JERARQUICO),
           ASIGNACION_BASICA               = COALESCE(p_asignacion_basica,             t.ASIGNACION_BASICA),
           FK_TLV_TIEMPO_ASIGNADO          = COALESCE(p_fk_tlv_tiempo_asignado,        t.FK_TLV_TIEMPO_ASIGNADO),
           FK_TDENOMINACION                = COALESCE(p_fk_tdenominacion,              t.FK_TDENOMINACION),
           FK_TLV_ESPECIALIDAD_DOCENTE     = COALESCE(p_fk_tlv_especialidad_docente,   t.FK_TLV_ESPECIALIDAD_DOCENTE),
           FK_TARCHIVO                     = COALESCE(p_fk_tarchivo,                   t.FK_TARCHIVO),
           DIRECCION                       = COALESCE(p_direccion,                     t.DIRECCION),
           MODIFIED_BY = CASE
                            WHEN (SELECT c.chg_muni_exp OR c.chg_direccion OR c.chg_clase OR c.chg_nivel_e OR c.chg_grado
                                       OR c.chg_nivel_ed OR c.chg_fuente OR c.chg_cargo OR c.chg_tipo_vinc
                                       OR c.chg_telefonos OR c.chg_fvinc OR c.chg_famen OR c.chg_amen
                                       OR c.chg_area_e OR c.chg_area_t OR c.chg_desc_area OR c.chg_etno
                                       OR c.chg_sobre OR c.chg_carrera OR c.chg_comision OR c.chg_nivel_j
                                       OR c.chg_asig OR c.chg_tiempo OR c.chg_denom OR c.chg_esp_doc
                                       OR c.chg_archivo
                                  FROM cambios c)
                            THEN p_pk_usuario_solicitante::VARCHAR
                            ELSE t.MODIFIED_BY
                          END,
           MODIFIED_AT = CASE
                            WHEN (SELECT c.chg_muni_exp OR c.chg_direccion OR c.chg_clase OR c.chg_nivel_e OR c.chg_grado
                                       OR c.chg_nivel_ed OR c.chg_fuente OR c.chg_cargo OR c.chg_tipo_vinc
                                       OR c.chg_telefonos OR c.chg_fvinc OR c.chg_famen OR c.chg_amen
                                       OR c.chg_area_e OR c.chg_area_t OR c.chg_desc_area OR c.chg_etno
                                       OR c.chg_sobre OR c.chg_carrera OR c.chg_comision OR c.chg_nivel_j
                                       OR c.chg_asig OR c.chg_tiempo OR c.chg_denom OR c.chg_esp_doc
                                       OR c.chg_archivo
                                  FROM cambios c)
                            THEN CURRENT_TIMESTAMP
                            ELSE t.MODIFIED_AT
                          END
      FROM cambios c
     WHERE t.PK_TFUNCIONARIO = p_pk_funcionario
       AND t.ACTIVE          = TRUE;

    RETURN p_pk_funcionario;
END;
$function$;

-- ===== fn_periodo_actualizar =====
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_actualizar(p_pk_periodo bigint, p_fk_estado bigint DEFAULT NULL::bigint, p_fk_sede bigint DEFAULT NULL::bigint, p_fecha_inicio date DEFAULT NULL::date, p_fecha_fin date DEFAULT NULL::date, p_fecha_limite_matricula date DEFAULT NULL::date, p_fk_jornada bigint DEFAULT NULL::bigint, p_reserva academico_test.bool_sn DEFAULT NULL::character varying, p_bloques_por_defecto bigint DEFAULT NULL::bigint, p_fk_periodo_anterior bigint DEFAULT NULL::bigint, p_hora_inicio time without time zone DEFAULT NULL::time without time zone, p_hora_fin time without time zone DEFAULT NULL::time without time zone, p_descanso_inicio time without time zone[] DEFAULT NULL::time without time zone[], p_descanso_fin time without time zone[] DEFAULT NULL::time without time zone[], p_pk_usuario_solicitante bigint DEFAULT NULL::bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    r                 academico_test.TPERIODO_ACADEMICO;
    v_sede            BIGINT;
    v_nombre_sede     VARCHAR(130);
    v_inicio          DATE;
    v_fin             DATE;
    v_limite          DATE;
    v_jornada         BIGINT;
    v_estado          BIGINT;
    v_est_old         BIGINT;
    v_est_new         BIGINT;
    v_hi              TIME;
    v_hf              TIME;
    v_nombre_ano      VARCHAR(50);
    v_nombre_jornada  TEXT;
    v_nombre_estado   TEXT;
    v_categoria_jornada VARCHAR(30);
    v_categoria_estado  VARCHAR(30);
    v_ano_id          BIGINT;
    v_tmp_nombre      TEXT;
    v_audit           VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    i                 INT;
    j                 INT;
BEGIN
    IF NOT academico_test.fn_periodo_usuario_puede_gestionar(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    SELECT * INTO r FROM academico_test.TPERIODO_ACADEMICO WHERE PK_TPERIODO_ACADEMICO = p_pk_periodo;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe el periodo academico' USING ERRCODE = 'P0002';
    END IF;
    IF r.ACTIVE = FALSE THEN
        RAISE EXCEPTION 'El periodo academico "%" esta inactivo; no se puede actualizar', r.NOMBRE
            USING ERRCODE = '22023';
    END IF;
    -- Autorizacion fina: el establecimiento del periodo debe estar en su alcance.
    IF NOT academico_test.fn_periodo_usuario_puede_escribir(
             p_pk_usuario_solicitante,
             (SELECT FK_TESTABLECIMIENTO FROM academico_test.TSEDE WHERE PK_TSEDE = r.FK_TSEDE)) THEN
        RAISE EXCEPTION 'El usuario no puede gestionar periodos de este establecimiento'
            USING ERRCODE = '42501';
    END IF;

    -- Valores efectivos (COALESCE param o actual).
    v_sede    := COALESCE(p_fk_sede, r.FK_TSEDE);
    v_inicio  := COALESCE(p_fecha_inicio, r.FECHA_INICIO);
    v_fin     := COALESCE(p_fecha_fin, r.FECHA_FIN);
    v_limite  := COALESCE(p_fecha_limite_matricula, r.FECHA_LIMITE_MATRICULA);
    v_jornada := COALESCE(p_fk_jornada, r.FK_TLV_JORNADA);
    v_estado  := COALESCE(p_fk_estado, r.FK_TLV_ESTADO);
    v_hi      := COALESCE(p_hora_inicio, r.HORA_INICIO);
    v_hf      := COALESCE(p_hora_fin, r.HORA_FIN);

    -- V78: revierte la firma a la version de produccion (recupera
    -- p_descanso_inicio/p_descanso_fin, que la version local habia quitado
    -- al separar los descansos a fn_descanso_agregar/eliminar -- ver
    -- docs/etiqueta-cambios-por-funcion.md). fn_audit_declarar agregada lo
    -- mas temprano posible: ANTES de cualquier DML de esta funcion (la
    -- reconciliacion de descansos y el INSERT en TANO_LECTIVO, mas abajo,
    -- son statements independientes -- mismo problema que V77 encontro en
    -- fn_plan_agregar si se declarara despues). Usa el establecimiento
    -- ACTUAL de la sede (el cambio de sede a otro establecimiento ya esta
    -- bloqueado mas abajo, asi que siempre es el correcto) y el nombre de
    -- jornada resuelto con los mismos valores efectivos ya calculados.
    SELECT s.FK_TESTABLECIMIENTO INTO v_est_new FROM academico_test.TSEDE s WHERE s.PK_TSEDE = v_sede;
    SELECT lv.VALOR INTO v_nombre_jornada FROM academico_test.TLISTA_VALOR lv WHERE lv.PK_LISTA_VALOR = v_jornada;
    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        format('Actualización del periodo académico %s - %s', to_char(v_inicio, 'YYYY'), COALESCE(v_nombre_jornada, v_jornada::TEXT)),
        v_est_new);

    -- No cambiar de establecimiento (rompe el año lectivo).
    IF v_sede <> r.FK_TSEDE THEN
        SELECT FK_TESTABLECIMIENTO INTO v_est_old FROM academico_test.TSEDE WHERE PK_TSEDE = r.FK_TSEDE;
        SELECT FK_TESTABLECIMIENTO, NOMBRE INTO v_est_new, v_nombre_sede
          FROM academico_test.TSEDE WHERE PK_TSEDE = v_sede AND ACTIVE = TRUE;
        IF v_est_new IS NULL THEN
            SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TSEDE WHERE PK_TSEDE = v_sede;
            IF v_tmp_nombre IS NOT NULL THEN
                RAISE EXCEPTION 'La sede "%" existe pero esta inactiva', v_tmp_nombre USING ERRCODE = '23503';
            ELSE
                RAISE EXCEPTION 'La sede seleccionada no existe' USING ERRCODE = '23503';
            END IF;
        END IF;
        IF v_est_new <> v_est_old THEN
            RAISE EXCEPTION 'No se puede mover el periodo a una sede de otro establecimiento'
                USING ERRCODE = '22023';
        END IF;
    END IF;

    -- Reglas de fecha/hora.
    IF v_fin <= v_inicio THEN
        RAISE EXCEPTION 'La fecha fin (%) debe ser posterior a la fecha inicio (%)', v_fin, v_inicio
            USING ERRCODE = '22023';
    END IF;
    IF v_limite < v_inicio OR v_limite > v_fin THEN
        RAISE EXCEPTION 'La fecha limite de matricula (%) debe estar entre inicio (%) y fin (%)',
            v_limite, v_inicio, v_fin USING ERRCODE = '22023';
    END IF;
    IF v_hf < v_hi THEN
        RAISE EXCEPTION 'La hora fin (%) no puede ser anterior a la hora inicio (%)', v_hf, v_hi
            USING ERRCODE = '22023';
    END IF;
    -- Reconciliacion de descansos.
    --   p_descanso_inicio IS NULL → no se tocan; se conserva el guard: los
    --     descansos existentes deben seguir dentro del nuevo horario.
    --   arreglo provisto (incluso vacio) → reemplazo total: se validan contra el
    --     nuevo horario/entre si, se da de baja el set activo y se inserta el nuevo.
    IF p_descanso_inicio IS NULL THEN
        IF EXISTS (
            SELECT 1 FROM academico_test.TDESCANSOS
             WHERE FK_TPERIODO_ACADEMICO = p_pk_periodo AND ACTIVE = TRUE
               AND (HORA_INICIO < v_hi OR HORA_FIN > v_hf)
        ) THEN
            RAISE EXCEPTION 'El nuevo horario (% a %) deja descansos existentes fuera de rango; ajustelos primero',
                v_hi, v_hf USING ERRCODE = '22023';
        END IF;
    ELSE
        IF p_descanso_fin IS NULL
           OR COALESCE(array_length(p_descanso_inicio, 1), 0) <> COALESCE(array_length(p_descanso_fin, 1), 0) THEN
            RAISE EXCEPTION 'Los arreglos de inicio/fin de descansos deben tener la misma longitud'
                USING ERRCODE = '22023';
        END IF;
        -- Validacion (misma que fn_periodo_crear, pero contra el horario efectivo).
        IF array_length(p_descanso_inicio, 1) IS NOT NULL THEN
            FOR i IN 1 .. array_length(p_descanso_inicio, 1) LOOP
                IF p_descanso_fin[i] < p_descanso_inicio[i] THEN
                    RAISE EXCEPTION 'Descanso %: hora fin anterior a inicio', i USING ERRCODE = '22023';
                END IF;
                IF p_descanso_inicio[i] < v_hi OR p_descanso_fin[i] > v_hf THEN
                    RAISE EXCEPTION 'Descanso % (% a %) fuera del horario del periodo (% a %)',
                        i, p_descanso_inicio[i], p_descanso_fin[i], v_hi, v_hf USING ERRCODE = '22023';
                END IF;
                FOR j IN 1 .. i - 1 LOOP
                    IF p_descanso_inicio[i] < p_descanso_fin[j] AND p_descanso_fin[i] > p_descanso_inicio[j] THEN
                        RAISE EXCEPTION 'Los descansos % y % se traslapan', j, i USING ERRCODE = '22023';
                    END IF;
                END LOOP;
            END LOOP;
        END IF;
        -- Reconciliacion por diff (evita churn de PKs): se comparan los activos
        -- contra el set provisto por (HORA_INICIO, HORA_FIN).
        --   1) baja los activos que ya NO estan en el set provisto,
        --   2) inserta los provistos que aun NO existen activos,
        --   3) los que coinciden quedan intactos (conservan su PK).
        -- Set vacio ('{}') → el paso 1 los baja a todos y el 2 no inserta nada.
        UPDATE academico_test.TDESCANSOS d
           SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE d.FK_TPERIODO_ACADEMICO = p_pk_periodo AND d.ACTIVE = TRUE
           AND NOT EXISTS (
               SELECT 1
                 FROM unnest(p_descanso_inicio, p_descanso_fin) AS nuevo(hi, hf)
                WHERE nuevo.hi = d.HORA_INICIO AND nuevo.hf = d.HORA_FIN
           );

        INSERT INTO academico_test.TDESCANSOS (FK_TPERIODO_ACADEMICO, HORA_INICIO, HORA_FIN, CREATED_BY)
        SELECT p_pk_periodo, nuevo.hi, nuevo.hf, v_audit
          FROM unnest(p_descanso_inicio, p_descanso_fin) AS nuevo(hi, hf)
         WHERE NOT EXISTS (
               SELECT 1 FROM academico_test.TDESCANSOS d
                WHERE d.FK_TPERIODO_ACADEMICO = p_pk_periodo AND d.ACTIVE = TRUE
                  AND d.HORA_INICIO = nuevo.hi AND d.HORA_FIN = nuevo.hf
           );
    END IF;

    -- Re-resolver año lectivo (por si cambio la fecha de inicio) y el nombre
    -- de la sede efectiva (para el mensaje de conflicto de abajo, si aplica).
    SELECT FK_TESTABLECIMIENTO, NOMBRE INTO v_est_new, v_nombre_sede
      FROM academico_test.TSEDE WHERE PK_TSEDE = v_sede;

    -- Periodo anterior (opcional): existe, activo, mismo establecimiento y no a si mismo.
    IF p_fk_periodo_anterior IS NOT NULL THEN
        IF p_fk_periodo_anterior = p_pk_periodo THEN
            RAISE EXCEPTION 'Un periodo academico no puede ser su propio periodo anterior'
                USING ERRCODE = '22023';
        END IF;
        PERFORM 1
          FROM academico_test.TPERIODO_ACADEMICO pa
          JOIN academico_test.TSEDE se ON se.PK_TSEDE = pa.FK_TSEDE
         WHERE pa.PK_TPERIODO_ACADEMICO = p_fk_periodo_anterior
           AND pa.ACTIVE = TRUE
           AND se.FK_TESTABLECIMIENTO = v_est_new;
        IF NOT FOUND THEN
            SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TPERIODO_ACADEMICO
             WHERE PK_TPERIODO_ACADEMICO = p_fk_periodo_anterior;
            IF v_tmp_nombre IS NOT NULL THEN
                RAISE EXCEPTION 'El periodo academico anterior "%" existe pero esta inactivo o pertenece a otro establecimiento',
                    v_tmp_nombre USING ERRCODE = '22023';
            ELSE
                RAISE EXCEPTION 'El periodo academico anterior seleccionado no existe' USING ERRCODE = '22023';
            END IF;
        END IF;
    END IF;

    v_nombre_ano := to_char(v_inicio, 'YYYY');
    -- V78: ON CONFLICT ajustado con el WHERE del indice PARCIAL local
    -- (u_tano_lectivo_1, WHERE active = true -- V65/PR#71); en produccion
    -- es un UNIQUE CONSTRAINT normal, sin WHERE, asi que alli el original
    -- sin predicado tambien es correcto.
    INSERT INTO academico_test.TANO_LECTIVO (NOMBRE, FK_TESTABLECIMIENTO, CREATED_BY)
    VALUES (v_nombre_ano, v_est_new, v_audit)
    ON CONFLICT (FK_TESTABLECIMIENTO, NOMBRE) WHERE active = true DO NOTHING
    RETURNING PK_ANO_LECTIVO INTO v_ano_id;
    IF v_ano_id IS NULL THEN
        SELECT PK_ANO_LECTIVO INTO v_ano_id FROM academico_test.TANO_LECTIVO
         WHERE FK_TESTABLECIMIENTO = v_est_new AND NOMBRE = v_nombre_ano;
    END IF;

    -- Un solo periodo activo por (año, sede) — excluyendose a si mismo.
    IF EXISTS (
        SELECT 1 FROM academico_test.TPERIODO_ACADEMICO
         WHERE FK_TANO_LECTIVO = v_ano_id AND FK_TSEDE = v_sede AND ACTIVE = TRUE
           AND PK_TPERIODO_ACADEMICO <> p_pk_periodo
    ) THEN
        RAISE EXCEPTION 'La sede "%" ya tiene un periodo academico activo para el año lectivo %',
            v_nombre_sede, v_nombre_ano USING ERRCODE = '23505';
    END IF;

    -- Validar FK_TLV_ESTADO efectivo — debe existir y pertenecer a la categoria
    -- ESTADOPERIODO en TLISTA_VALOR.
    SELECT VALOR, CATEGORIA INTO v_nombre_estado, v_categoria_estado
      FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = v_estado;
    IF v_categoria_estado IS NULL THEN
        RAISE EXCEPTION 'El estado seleccionado no existe' USING ERRCODE = '23503';
    END IF;
    IF v_categoria_estado <> 'ESTADOPERIODO' THEN
        RAISE EXCEPTION 'El estado "%" no pertenece a la categoria ESTADOPERIODO (es %)',
            v_nombre_estado, v_categoria_estado USING ERRCODE = '22023';
    END IF;

    -- Nombre derivado de la jornada — debe existir y pertenecer a la categoria
    -- JORNADA en TLISTA_VALOR.
    SELECT VALOR, CATEGORIA INTO v_nombre_jornada, v_categoria_jornada
      FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = v_jornada;
    IF v_nombre_jornada IS NULL THEN
        RAISE EXCEPTION 'La jornada seleccionada no existe' USING ERRCODE = '23503';
    END IF;
    IF v_categoria_jornada <> 'JORNADA' THEN
        RAISE EXCEPTION 'La jornada "%" no pertenece a la categoria JORNADA (es %)',
            v_nombre_jornada, v_categoria_jornada USING ERRCODE = '22023';
    END IF;

    UPDATE academico_test.TPERIODO_ACADEMICO SET
        FK_TLV_ESTADO          = COALESCE(p_fk_estado, FK_TLV_ESTADO),
        FK_TSEDE               = v_sede,
        FECHA_INICIO           = v_inicio,
        FECHA_FIN              = v_fin,
        FECHA_LIMITE_MATRICULA = v_limite,
        FK_TLV_JORNADA         = v_jornada,
        FK_TANO_LECTIVO        = v_ano_id,
        RESERVA                = COALESCE(p_reserva, RESERVA),
        BLOQUES_POR_DEFECTO    = COALESCE(p_bloques_por_defecto, BLOQUES_POR_DEFECTO),
        FK_TPERIODO_ACADEMICO  = COALESCE(p_fk_periodo_anterior, FK_TPERIODO_ACADEMICO),
        HORA_INICIO            = COALESCE(p_hora_inicio, HORA_INICIO),
        HORA_FIN               = COALESCE(p_hora_fin, HORA_FIN),
        NOMBRE                 = v_nombre_ano || ' - ' || v_nombre_jornada,
        MODIFIED_BY            = v_audit,
        MODIFIED_AT            = CURRENT_TIMESTAMP
     WHERE PK_TPERIODO_ACADEMICO = p_pk_periodo;

    RETURN p_pk_periodo;
END;
$function$;

-- ===== fn_est_crear =====
CREATE OR REPLACE FUNCTION academico_test.fn_est_crear(p_pk_usuario_solicitante bigint, p_nombre character varying, p_nit character varying, p_fk_municipio bigint, p_fk_propiedad_juridica bigint, p_codigo character varying, p_localidad character varying DEFAULT NULL::character varying, p_comuna character varying DEFAULT NULL::character varying, p_barrio character varying DEFAULT NULL::character varying, p_direccion character varying DEFAULT NULL::character varying, p_correo_electronico character varying DEFAULT NULL::character varying, p_telefono character varying DEFAULT NULL::character varying, p_fax character varying DEFAULT NULL::character varying, p_idecol character varying DEFAULT NULL::character varying, p_pagina_web character varying DEFAULT NULL::character varying, p_fk_lista_valor_zona bigint DEFAULT NULL::bigint, p_resolucion_aprobacion character varying DEFAULT NULL::character varying, p_licencia_funcionamiento character varying DEFAULT NULL::character varying, p_fecha_licencia date DEFAULT NULL::date, p_fk_lv_calendario bigint DEFAULT NULL::bigint, p_fk_lv_idioma bigint DEFAULT NULL::bigint, p_fk_lv_genero_est bigint DEFAULT NULL::bigint, p_fk_discapacidad bigint DEFAULT NULL::bigint, p_talento academico_test.bool_sn DEFAULT NULL::character varying, p_etnias academico_test.bool_sn DEFAULT NULL::character varying, p_fk_tfuncionario_rector bigint DEFAULT NULL::bigint, p_fk_tfuncionario_secretaria bigint DEFAULT NULL::bigint, p_subsidio academico_test.bool_sn DEFAULT NULL::character varying, p_fk_lv_regimen_catcosto bigint DEFAULT NULL::bigint, p_fk_lv_rango_tarifa bigint DEFAULT NULL::bigint, p_fk_lv_asociacion_nacional bigint DEFAULT NULL::bigint, p_fk_archivo bigint DEFAULT NULL::bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_id_creado BIGINT;
    -- Estado "Activo" del catalogo de estados de establecimiento. Ya no se
    -- recibe por parametro: toda alta arranca activa.
    c_fk_lv_estado_activo CONSTANT BIGINT := 533;
    -- REV4 -- sede por defecto (mismo CODIGO/NOMBRE que el EE) + permiso
    -- de rector/secretaria en ella. "Urbana y Rural" (216): zona por
    -- defecto pedida para esta sede -- no hay info real de zona todavia
    -- al momento de crear el EE. "Completa" (51900): jornada por defecto
    -- para el permiso de rector/secretaria -- son cargos administrativos,
    -- no atados a una jornada de aula; ajustar si el negocio prefiere otra.
    c_fk_tlv_zona_defecto    CONSTANT BIGINT := 216;
    c_fk_tlv_jornada_defecto CONSTANT BIGINT := 51900;
    c_fk_trol_rector         CONSTANT BIGINT := 7;
    c_fk_trol_secretaria     CONSTANT BIGINT := 9;
    v_pk_sede_creada         BIGINT;
    v_perm_result            RECORD;
BEGIN
    -- -----------------------------------------------------------------
    -- 0. Gate de autorizacion: solo roles con permiso de establecimiento (1-3).
    --    p_pk_usuario_solicitante es obligatorio por firma (sin DEFAULT).
    -- -----------------------------------------------------------------
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    IF NOT academico_test.fn_puede_afectar_establecimiento(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    -- -----------------------------------------------------------------
    -- 1. Validaciones de obligatoriedad (DDL NOT NULL + NIT funcional)
    -- -----------------------------------------------------------------
    IF NULLIF(TRIM(p_nombre), '') IS NULL THEN
        RAISE EXCEPTION 'Nombre del establecimiento es obligatorio'
            USING ERRCODE = '22023', HINT = 'p_nombre no puede ser NULL ni vacio';
    END IF;

    IF NULLIF(TRIM(p_nit), '') IS NULL THEN
        RAISE EXCEPTION 'NIT del establecimiento es obligatorio'
            USING ERRCODE = '22023', HINT = 'p_nit no puede ser NULL ni vacio';
    END IF;

    IF NULLIF(TRIM(p_codigo), '') IS NULL THEN
        RAISE EXCEPTION 'Codigo del establecimiento es obligatorio'
            USING ERRCODE = '22023', HINT = 'p_codigo no puede ser NULL ni vacio';
    END IF;

    IF p_fk_municipio IS NULL THEN
        RAISE EXCEPTION 'Municipio (FK_TMUNICIPIO) es obligatorio'
            USING ERRCODE = '22023', HINT = 'p_fk_municipio no puede ser NULL';
    END IF;

    IF p_fk_propiedad_juridica IS NULL THEN
        RAISE EXCEPTION 'Propiedad juridica (FK_TPROPIEDAD_JURIDICA) es obligatoria'
            USING ERRCODE = '22023', HINT = 'p_fk_propiedad_juridica no puede ser NULL';
    END IF;

    -- -----------------------------------------------------------------
    -- 2. Validacion de unicidad por NIT (solo activos)
    --    CODIGO ya tiene UNIQUE constraint en el DDL (U_TESTABLECIMIENTO_1).
    -- -----------------------------------------------------------------
    IF EXISTS (
        SELECT 1 FROM academico_test.TESTABLECIMIENTO
        WHERE NIT = p_nit AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'Ya existe un TESTABLECIMIENTO activo con NIT %', p_nit
            USING ERRCODE = '23505',
                  HINT    = 'Use fn_est_buscar_por_nit('') para obtener el registro existente';
    END IF;

    -- Validacion de CODIGO solo entre activos: la UNIQUE constraint
    -- U_TESTABLECIMIENTO_1 cubre TODOS los CODIGO (incluyendo inactivos).
    -- Aqui forzamos la misma semantica que NIT: un CODIGO inactivo puede
    -- reutilizarse, uno activo no.
    IF EXISTS (
        SELECT 1 FROM academico_test.TESTABLECIMIENTO
        WHERE CODIGO = p_codigo AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'Ya existe un TESTABLECIMIENTO activo con CODIGO %', p_codigo
            USING ERRCODE = '23505',
                  HINT    = 'Use fn_est_buscar_por_nit('') o un SELECT directo para localizarlo';
    END IF;

    -- -----------------------------------------------------------------
    -- 2a. Validacion de FKs obligatorias (no se delega al INSERT para
    --     dar un mensaje claro al caller en vez del SQLSTATE '23503'
    --     generico del DDL).
    -- -----------------------------------------------------------------
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TMUNICIPIO
         WHERE PK_TMUNICIPIO = p_fk_municipio
    ) THEN
        RAISE EXCEPTION 'FK_TMUNICIPIO (%) no existe en TMUNICIPIO', p_fk_municipio
            USING ERRCODE = '23503';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TPROPIEDAD_JURIDICA
         WHERE PK_PROPIEDAD_JURIDICA = p_fk_propiedad_juridica
           AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'FK_TPROPIEDAD_JURIDICA (%) no existe o no esta activa en TPROPIEDAD_JURIDICA',
            p_fk_propiedad_juridica
            USING ERRCODE = '23503';
    END IF;

    -- -----------------------------------------------------------------
    -- 2b. Validacion de FKs opcionales contra TLISTA_VALOR.
    --     Solo se validan las que llegaron con valor (no NULL).
    --     Se valida existencia + ACTIVE=TRUE para mantener consistencia
    --     con el resto de las funciones del modulo academico.
    -- -----------------------------------------------------------------
    IF p_fk_lista_valor_zona IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_lista_valor_zona
               AND ACTIVE = TRUE
          )
    THEN
        RAISE EXCEPTION 'FK_TLISTA_VALOR_ZONA (%) no existe o no esta activa en TLISTA_VALOR',
            p_fk_lista_valor_zona
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_lv_calendario IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_lv_calendario
               AND ACTIVE = TRUE
          )
    THEN
        RAISE EXCEPTION 'FK_TLV_CALENDARIO (%) no existe o no esta activa en TLISTA_VALOR',
            p_fk_lv_calendario
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_lv_idioma IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_lv_idioma
               AND ACTIVE = TRUE
          )
    THEN
        RAISE EXCEPTION 'FK_TLV_IDIOMA (%) no existe o no esta activa en TLISTA_VALOR',
            p_fk_lv_idioma
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_lv_genero_est IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_lv_genero_est
               AND ACTIVE = TRUE
          )
    THEN
        RAISE EXCEPTION 'FK_TLV_GENERO_EST (%) no existe o no esta activa en TLISTA_VALOR',
            p_fk_lv_genero_est
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_lv_regimen_catcosto IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_lv_regimen_catcosto
               AND ACTIVE = TRUE
          )
    THEN
        RAISE EXCEPTION 'FK_TLV_REGIMEN_CATCOSTO (%) no existe o no esta activa en TLISTA_VALOR',
            p_fk_lv_regimen_catcosto
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_lv_rango_tarifa IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_lv_rango_tarifa
               AND ACTIVE = TRUE
          )
    THEN
        RAISE EXCEPTION 'FK_TLV_RANGO_TARIFA (%) no existe o no esta activa en TLISTA_VALOR',
            p_fk_lv_rango_tarifa
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_lv_asociacion_nacional IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_lv_asociacion_nacional
               AND ACTIVE = TRUE
          )
    THEN
        RAISE EXCEPTION 'FK_TLV_ASOCIACION_NACIONAL (%) no existe o no esta activa en TLISTA_VALOR',
            p_fk_lv_asociacion_nacional
            USING ERRCODE = '23503';
    END IF;

    -- -----------------------------------------------------------------
    -- 2c. Validacion de FK_TDISCAPACIDAD opcional.
    -- -----------------------------------------------------------------
    IF p_fk_discapacidad IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TDISCAPACIDAD
             WHERE PK_DISCAPACIDAD = p_fk_discapacidad
               AND ACTIVE = TRUE
          )
    THEN
        RAISE EXCEPTION 'FK_TDISCAPACIDAD (%) no existe o no esta activa en TDISCAPACIDAD',
            p_fk_discapacidad
            USING ERRCODE = '23503';
    END IF;

    -- -----------------------------------------------------------------
    -- 2d. Validacion de FK_TFUNCIONARIO_RECTOR / SECRETARIA opcionales.
    --     Ambos deben ser funcionarios activos.
    -- -----------------------------------------------------------------
    IF p_fk_tfuncionario_rector IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TFUNCIONARIO
             WHERE PK_TFUNCIONARIO = p_fk_tfuncionario_rector
               AND ACTIVE = TRUE
          )
    THEN
        RAISE EXCEPTION 'FK_TFUNCIONARIO_RECTOR (%) no existe o no esta activo en TFUNCIONARIO',
            p_fk_tfuncionario_rector
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_tfuncionario_secretaria IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TFUNCIONARIO
             WHERE PK_TFUNCIONARIO = p_fk_tfuncionario_secretaria
               AND ACTIVE = TRUE
          )
    THEN
        RAISE EXCEPTION 'FK_TFUNCIONARIO_SECRETARIA (%) no existe o no esta activo en TFUNCIONARIO',
            p_fk_tfuncionario_secretaria
            USING ERRCODE = '23503';
    END IF;

    -- -----------------------------------------------------------------
    -- 2e. Validacion de FK_TARCHIVO opcional.
    -- -----------------------------------------------------------------
    IF p_fk_archivo IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TARCHIVO
             WHERE PK_TARCHIVO = p_fk_archivo
          )
    THEN
        RAISE EXCEPTION 'FK_TARCHIVO (%) no existe en TARCHIVO', p_fk_archivo
            USING ERRCODE = '23503';
    END IF;

    -- V78: revierte la firma a la version de produccion (quita
    -- p_fk_lv_estado_establecimiento, que la version local habia agregado --
    -- ver docs/etiqueta-cambios-por-funcion.md) y trae el REV4 completo
    -- (sede + permisos de rector/secretaria por defecto). fn_audit_declarar
    -- agregada antes del INSERT, tras la ultima validacion. No pasa
    -- establecimiento_id: el establecimiento se esta creando en esta misma
    -- llamada, no tiene PK todavia en este punto.
    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante, format('Creación del establecimiento %s', p_nombre));

    -- -----------------------------------------------------------------
    -- 3. INSERT. Las FKs no validadas explicitamente aqui: si alguna no
    --    existe, el INSERT fallara con SQLSTATE '23503' (FK violation)
    --    y ese mensaje sera suficientemente claro para el caller.
    --    FK_TLV_ESTADO_ESTABLECIMIENTO ya no llega por parametro: todo
    --    alta se crea con c_fk_lv_estado_activo (533, "Activo").
    -- -----------------------------------------------------------------
    INSERT INTO academico_test.TESTABLECIMIENTO (
        CODIGO, NOMBRE, NIT,
        FK_TMUNICIPIO, FK_TLISTA_VALOR_ZONA,
        LOCALIDAD, COMUNA, BARRIO, DIRECCION,
        CORREO_ELECTRONICO, TELEFONO, FAX, IDECOL, PAGINA_WEB,
        RESOLUCION_APROBACION, LICENCIA_FUNCIONAMIENTO, FECHA_LICENCIA,
        FK_TPROPIEDAD_JURIDICA,
        FK_TLV_CALENDARIO, FK_TLV_IDIOMA, FK_TLV_GENERO_EST, FK_TDISCAPACIDAD,
        TALENTO, ETNIAS,
        FK_TFUNCIONARIO_RECTOR, FK_TFUNCIONARIO_SECRETARIA, SUBSIDIO,
        FK_TLV_REGIMEN_CATCOSTO, FK_TLV_RANGO_TARIFA,
        FK_TLV_ASOCIACION_NACIONAL, FK_TLV_ESTADO_ESTABLECIMIENTO,
        FK_TARCHIVO,
        CREATED_BY, CREATED_AT, MODIFIED_BY, MODIFIED_AT, ACTIVE
    ) VALUES (
        p_codigo, p_nombre, p_nit,
        p_fk_municipio, p_fk_lista_valor_zona,
        p_localidad, p_comuna, p_barrio, p_direccion,
        p_correo_electronico, p_telefono, p_fax, p_idecol, p_pagina_web,
        p_resolucion_aprobacion, p_licencia_funcionamiento, p_fecha_licencia,
        p_fk_propiedad_juridica,
        p_fk_lv_calendario, p_fk_lv_idioma, p_fk_lv_genero_est, p_fk_discapacidad,
        p_talento, p_etnias,
        p_fk_tfuncionario_rector, p_fk_tfuncionario_secretaria, p_subsidio,
        p_fk_lv_regimen_catcosto, p_fk_lv_rango_tarifa,
        p_fk_lv_asociacion_nacional, c_fk_lv_estado_activo,
        p_fk_archivo,
        p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP,
        NULL, NULL,
        TRUE
    )
    RETURNING PK_ESTABLECIMIENTO INTO v_id_creado;

    -- -----------------------------------------------------------------
    -- 4. REV4 -- Sede por defecto: mismo CODIGO/NOMBRE que el EE recien
    --    creado, zona c_fk_tlv_zona_defecto ("Urbana y Rural"). Se delega
    --    en fn_sed_crear (mismas validaciones/consecutivo/auditoria que
    --    una sede creada a mano) en vez de duplicar el INSERT -- el gate
    --    de fn_sed_crear siempre deja pasar a quien ya paso el gate de
    --    este mismo fn_est_crear (solo super-admin llega hasta aca).
    -- -----------------------------------------------------------------
    v_pk_sede_creada := academico_test.fn_sed_crear(
        p_pk_usuario_solicitante => p_pk_usuario_solicitante,
        p_codigo                 => p_codigo,
        p_nombre                 => p_nombre,
        p_fk_lista_valor_zona    => c_fk_tlv_zona_defecto,
        p_fk_establecimiento     => v_id_creado
    );

    -- -----------------------------------------------------------------
    -- 5. REV4 -- Permiso por defecto del rector (rol 7) y de la
    --    secretaria (rol 9, Auxiliar administrativo) en la sede recien
    --    creada. Antes quedaban sin ningun TSEDE_USUARIO hasta que
    --    alguien se lo asignara a mano -- por eso el listado de
    --    funcionarios necesito un tag sintetico para mostrar su rol (ver
    --    fn_usu_empleados_listar). Se usa fn_fun_permisos_actualizar (la
    --    misma funcion que ya usa el front para sincronizar permisos) en
    --    vez de insertar TSEDE_USUARIO a mano.
    --
    --    fn_fun_permisos_actualizar NO lanza excepcion si el permiso no
    --    se pudo crear (devuelve status='error:...' por fila) -- se
    --    captura el resultado y se relanza como excepcion real para que
    --    un problema acá no quede en silencio.
    -- -----------------------------------------------------------------
    IF p_fk_tfuncionario_rector IS NOT NULL THEN
        SELECT * INTO v_perm_result
          FROM academico_test.fn_fun_permisos_actualizar(
              p_pk_usuario_solicitante,
              p_fk_tfuncionario_rector,
              jsonb_build_array(jsonb_build_object(
                  'accion', 'crear',
                  'orden', 1,
                  'fk_rol', c_fk_trol_rector,
                  'fk_sede', v_pk_sede_creada,
                  'fk_jornada', c_fk_tlv_jornada_defecto,
                  'predeterminado', 1
              ))
          );
        IF v_perm_result.status IS DISTINCT FROM 'creado' THEN
            RAISE EXCEPTION 'No se pudo crear el permiso por defecto del rector (TFUNCIONARIO %) en la sede %: %',
                p_fk_tfuncionario_rector, v_pk_sede_creada, v_perm_result.status;
        END IF;
    END IF;

    IF p_fk_tfuncionario_secretaria IS NOT NULL THEN
        SELECT * INTO v_perm_result
          FROM academico_test.fn_fun_permisos_actualizar(
              p_pk_usuario_solicitante,
              p_fk_tfuncionario_secretaria,
              jsonb_build_array(jsonb_build_object(
                  'accion', 'crear',
                  'orden', 1,
                  'fk_rol', c_fk_trol_secretaria,
                  'fk_sede', v_pk_sede_creada,
                  'fk_jornada', c_fk_tlv_jornada_defecto,
                  'predeterminado', 1
              ))
          );
        IF v_perm_result.status IS DISTINCT FROM 'creado' THEN
            RAISE EXCEPTION 'No se pudo crear el permiso por defecto de la secretaria (TFUNCIONARIO %) en la sede %: %',
                p_fk_tfuncionario_secretaria, v_pk_sede_creada, v_perm_result.status;
        END IF;
    END IF;

    -- V70 — refleja al rector/secretaria recien asignado en
    -- public.role_users. Van por FK_TUSUARIO del TFUNCIONARIO, no por
    -- el PK del establecimiento.
    --
    -- V78 -- COMENTADO: fn_sincronizar_rol_publico no existe en la base
    -- local (es parte del grupo legacy de menus/roles ya excluido de esta
    -- iniciativa -- ver docs/etiqueta-cambios-por-funcion.md, seccion de
    -- verificacion contra el servidor, y la memoria "V59 server drift
    -- cleanup pending"). El establecimiento, la sede y los permisos de
    -- TSEDE_USUARIO SI quedan creados correctamente arriba; solo el
    -- espejo a public.role_users queda pendiente hasta que se decida que
    -- hacer con esa funcion (portarla, o resolver el drift de V59).
    -- IF p_fk_tfuncionario_rector IS NOT NULL THEN
    --     PERFORM academico_test.fn_sincronizar_rol_publico(
    --         (SELECT FK_TUSUARIO FROM academico_test.TFUNCIONARIO
    --           WHERE PK_TFUNCIONARIO = p_fk_tfuncionario_rector)
    --     );
    -- END IF;
    -- IF p_fk_tfuncionario_secretaria IS NOT NULL THEN
    --     PERFORM academico_test.fn_sincronizar_rol_publico(
    --         (SELECT FK_TUSUARIO FROM academico_test.TFUNCIONARIO
    --           WHERE PK_TFUNCIONARIO = p_fk_tfuncionario_secretaria)
    --     );
    -- END IF;

    RETURN v_id_creado;
END;
$function$;
