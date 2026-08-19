-- V67 — funciones fn_* que no tenian ninguna definicion previa en este repo:
-- se traen desde produccion (172.233.184.248) con fn_audit_declarar ya
-- incluida desde su primera definicion aqui (no hay nada que "redefinir",
-- esta ES su definicion oficial). Ver docs/etiqueta-cambios-por-funcion.md
-- para el detalle de posicion del PERFORM y formato de cada etiqueta.
--
-- fn_enfasis_actualizar (2 sobrecargas) y fn_enfasis_soft_delete: existian
-- en produccion pero nunca en la base local (origin/dev) -- portadas tal
-- cual, ya tenian etiqueta propuesta en el catalogo original que nunca se
-- pudo adoptar por esta misma razon.
--
-- fn_fun_baja_establecimiento: idem, el inverso de
-- fn_fun_enlazar_establecimiento (desvincula un funcionario de su
-- establecimiento).
--
-- fn_fun_enlazar_establecimiento: funcion nueva creada como parte de esta
-- iniciativa (no existia en produccion tampoco bajo este nombre al momento
-- de escribirla) para vincular un funcionario pendiente a un
-- establecimiento -- el complemento de baja de arriba.

-- ===== fn_enfasis_actualizar =====
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

-- ===== fn_enfasis_actualizar =====
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

-- ===== fn_fun_enlazar_establecimiento =====
CREATE OR REPLACE FUNCTION academico_test.fn_fun_enlazar_establecimiento(p_pk_usuario_solicitante bigint, p_pk_funcionario bigint, p_fk_establecimiento bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_pk_funcionario      BIGINT;
    v_fk_establecimiento  BIGINT := COALESCE(
        p_fk_establecimiento,
        academico_test.fn_resolver_establecimiento_unico(p_pk_usuario_solicitante)
    );
    v_est_nombre VARCHAR(130); v_func_nombre TEXT;
BEGIN
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;
    IF p_pk_funcionario IS NULL OR p_pk_funcionario <= 0 THEN
        RAISE EXCEPTION 'p_pk_funcionario es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;
    IF v_fk_establecimiento IS NULL THEN
        RAISE EXCEPTION 'p_fk_establecimiento es obligatorio y no se pudo resolver automaticamente (el solicitante no esta ligado a exactamente un EE como rector/secretaria/jefe de sistema)'
            USING ERRCODE = '22023';
    END IF;

    SELECT NOMBRE INTO v_est_nombre FROM academico_test.TESTABLECIMIENTO
     WHERE PK_ESTABLECIMIENTO = v_fk_establecimiento AND ACTIVE = TRUE;
    IF v_est_nombre IS NULL THEN
        RAISE EXCEPTION 'No existe un TESTABLECIMIENTO activo con PK %', v_fk_establecimiento
            USING ERRCODE = '22023';
    END IF;

    IF academico_test.fn_puede_afectar_establecimiento(p_pk_usuario_solicitante) THEN
        NULL;
    ELSIF EXISTS (
        SELECT 1
          FROM academico_test.TFUNCIONARIO f
          JOIN academico_test.TESTABLECIMIENTO e ON e.FK_TFUNCIONARIO_RECTOR = f.PK_TFUNCIONARIO
         WHERE e.PK_ESTABLECIMIENTO = v_fk_establecimiento
           AND e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
    ) THEN
        NULL;
    ELSIF EXISTS (
        SELECT 1
          FROM academico_test.TFUNCIONARIO f
          JOIN academico_test.TESTABLECIMIENTO e ON e.FK_TFUNCIONARIO_SECRETARIA = f.PK_TFUNCIONARIO
         WHERE e.PK_ESTABLECIMIENTO = v_fk_establecimiento
           AND e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
    ) THEN
        NULL;
    ELSIF EXISTS (
        SELECT 1
          FROM academico_test.TSEDE_USUARIO su
          JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
         WHERE s.FK_TESTABLECIMIENTO = v_fk_establecimiento
           AND s.ACTIVE = TRUE AND su.ACTIVE = TRUE AND su.FK_TROL = 8
           AND su.FK_TUSUARIO = p_pk_usuario_solicitante
    ) THEN
        NULL;
    ELSE
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    -- REV3: recibe el PK_TFUNCIONARIO exacto devuelto por /register/funcionario
    -- (antes lo buscaba por FK_TUSUARIO + FK_ESTABLECIMIENTO IS NULL LIMIT 1,
    -- ambiguo si llegara a haber mas de un TFUNCIONARIO pendiente a la vez
    -- para el mismo usuario). El IS NULL se mantiene como chequeo de
    -- seguridad: no permite re-enlazar un TFUNCIONARIO que ya tiene EE.
    SELECT f.PK_TFUNCIONARIO, TRIM(concat_ws(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE, u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO))
      INTO v_pk_funcionario, v_func_nombre
      FROM academico_test.TFUNCIONARIO f
      JOIN academico_test.TUSUARIO u ON u.PK_TUSUARIO = f.FK_TUSUARIO
     WHERE f.PK_TFUNCIONARIO = p_pk_funcionario
       AND f.FK_ESTABLECIMIENTO IS NULL
       AND f.ACTIVE = TRUE;

    IF v_pk_funcionario IS NULL THEN
        RAISE EXCEPTION 'No existe un TFUNCIONARIO pendiente de enlazar (activo, sin FK_ESTABLECIMIENTO) con PK %', p_pk_funcionario
            USING ERRCODE = 'P0002';
    END IF;

    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        format('Vinculación del funcionario %s al establecimiento %s', COALESCE(v_func_nombre, p_pk_funcionario::TEXT), v_est_nombre),
        v_fk_establecimiento);

    UPDATE academico_test.TFUNCIONARIO
       SET FK_ESTABLECIMIENTO = v_fk_establecimiento,
           MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TFUNCIONARIO = v_pk_funcionario;

    RETURN v_pk_funcionario;
END;
$function$;
