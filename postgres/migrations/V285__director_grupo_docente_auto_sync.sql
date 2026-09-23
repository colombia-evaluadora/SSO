CREATE OR REPLACE FUNCTION academico_test.fn_grado_es_preescolar(p_fk_grado BIGINT)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1
          FROM academico_test.TGRADO g
          JOIN academico_test.TNIVEL_ENSENANZA ne ON ne.PK_NIVEL_ENSENANZA = g.FK_TNIVEL_ENSENANZA
         WHERE g.PK_TGRADO = p_fk_grado AND ne.NOMBRE ILIKE '%preescolar%'
    );
$$;

COMMENT ON FUNCTION academico_test.fn_grado_es_preescolar IS
    'TRUE si el nivel de ensenanza del grado contiene "preescolar" (case-insensitive). '
    'Gate para la auto-sincronizacion director de grupo -> docente (V301).';

CREATE OR REPLACE FUNCTION academico_test.fn_docente_director_grupo_sync(
    p_fk_funcionario BIGINT,
    p_academic_period_id BIGINT,
    p_excluir_asignatura BIGINT DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_skipped INT := 0;
    v_grupo BIGINT; v_asig BIGINT;
BEGIN
    IF p_fk_funcionario IS NULL OR p_academic_period_id IS NULL THEN
        RETURN 0;
    END IF;

    UPDATE academico_test.TDOCENTE_ASIGNATURA
       SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TFUNCIONARIO = p_fk_funcionario
       AND FK_TPERIODO_ACADEMICO = p_academic_period_id
       AND ACTIVE = TRUE;

    FOR v_grupo, v_asig IN
        SELECT gr.PK_TGRUPO, ap.FK_TASIGNATURA
          FROM academico_test.TGRUPO gr
          JOIN academico_test.TGRADO g ON g.PK_TGRADO = gr.FK_TGRADO AND g.ACTIVE = TRUE
               AND g.FK_TPERIODO_ACADEMICO = p_academic_period_id
          JOIN academico_test.TPLAN pl ON pl.FK_TGRADO = g.PK_TGRADO AND pl.ACTIVE = TRUE
          JOIN academico_test.TASIGNATURA_PLAN ap ON ap.FK_TPLAN = pl.PK_TPLAN AND ap.ACTIVE = TRUE
          JOIN academico_test.TASIGNATURA s ON s.PK_TASIGNATURA = ap.FK_TASIGNATURA AND s.ACTIVE = TRUE
         WHERE gr.FK_TFUNCIONARIO = p_fk_funcionario AND gr.ACTIVE = TRUE
           AND (p_excluir_asignatura IS NULL OR ap.FK_TASIGNATURA <> p_excluir_asignatura)
    LOOP
        -- Conflicto: la pareja grupo+asignatura ya esta activa para OTRO
        -- funcionario en el periodo (asignacion manual previa). No se
        -- pisa: se omite y se sigue con el resto.
        IF EXISTS (
            SELECT 1 FROM academico_test.TDOCENTE_ASIGNATURA
             WHERE FK_TGRUPO = v_grupo AND FK_TASIGNATURA = v_asig
               AND FK_TPERIODO_ACADEMICO = p_academic_period_id AND ACTIVE = TRUE
               AND FK_TFUNCIONARIO <> p_fk_funcionario
        ) THEN
            v_skipped := v_skipped + 1;
            CONTINUE;
        END IF;

        INSERT INTO academico_test.TDOCENTE_ASIGNATURA
            (FK_TGRUPO, FK_TFUNCIONARIO, FK_TASIGNATURA, FK_TPERIODO_ACADEMICO, CREATED_BY)
        VALUES (v_grupo, p_fk_funcionario, v_asig, p_academic_period_id, v_audit);
    END LOOP;

    RETURN v_skipped;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_docente_director_grupo_sync IS
    'Recalcula el conjunto completo de TDOCENTE_ASIGNATURA de un funcionario '
    '(director de grupo) en todo el periodo, a partir de los grupos que dirige. '
    'No bloquea por conflicto con un docente manual distinto: omite esa pareja '
    'y devuelve cuantas se omitieron. Ver V301.';

-- Version "por grado": sincroniza a todos los directores distintos que
-- tengan al menos un grupo activo en p_fk_grado. Usada por fn_plan_agregar /
-- fn_plan_actualizar / fn_plan_eliminar, que no saben de antemano cuantos
-- directores distintos hay en el grado.
CREATE OR REPLACE FUNCTION academico_test.fn_docente_grado_directores_sync(
    p_fk_grado BIGINT,
    p_excluir_asignatura BIGINT DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE
    v_periodo BIGINT;
    v_func BIGINT;
    v_skipped INT := 0;
BEGIN
    SELECT FK_TPERIODO_ACADEMICO INTO v_periodo
      FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_grado;
    IF v_periodo IS NULL THEN
        RETURN 0;
    END IF;

    FOR v_func IN
        SELECT DISTINCT FK_TFUNCIONARIO
          FROM academico_test.TGRUPO
         WHERE FK_TGRADO = p_fk_grado AND ACTIVE = TRUE AND FK_TFUNCIONARIO IS NOT NULL
    LOOP
        v_skipped := v_skipped + academico_test.fn_docente_director_grupo_sync(
            v_func, v_periodo, p_excluir_asignatura, p_pk_usuario_solicitante);
    END LOOP;

    RETURN v_skipped;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_docente_grado_directores_sync IS
    'Sincroniza (fn_docente_director_grupo_sync) a cada director distinto con '
    'grupo activo en un grado. Ver V301.';

-- ---------------------------------------------------------------------------
-- fn_grupo_director_rol_sync_interno: nucleo sin gate (lo llaman fn_grupo_
-- crear / fn_grupo_actualizar, que ya gatearon GRUPOS mas arriba). Da de alta
-- el rol DIRECTOR_GRUPO (TSEDE_USUARIO) al funcionario recien asignado como
-- director si aun no lo tiene activo en esa sede+jornada, y se lo quita al
-- director anterior SOLO si ya no dirige ningun otro grupo activo (puede
-- dirigir varios). No usa fn_sede_usuario_crear/_soft_delete: esas llevan su
-- propio gate de FUNCIONARIOS-EDITAR (V111), que un COORDINADOR gestionando
-- grupos no tiene por que tener -- el INSERT/UPDATE de TSEDE_USUARIO ya
-- dispara el trigger de V301 que resincroniza public.role_users solo.
-- Resuelve el rol por CODIGO, no por PK (V120.1: TROL llega por dump base).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_grupo_director_rol_sync_interno(
    p_fk_funcionario_anterior BIGINT,
    p_fk_funcionario_nuevo BIGINT,
    p_fk_sede BIGINT,
    p_fk_jornada BIGINT,
    p_pk_usuario_solicitante BIGINT
)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_pk_trol BIGINT;
    v_pk_tusuario BIGINT;
    v_pk_tsede_usuario BIGINT;
    v_orden NUMERIC;
BEGIN
    IF p_fk_funcionario_nuevo IS NOT DISTINCT FROM p_fk_funcionario_anterior THEN
        RETURN;
    END IF;

    SELECT PK_TROL INTO v_pk_trol
      FROM academico_test.TROL
     WHERE UPPER(TRIM(CODIGO)) = 'DIRECTOR_GRUPO' AND ACTIVE = TRUE;
    IF v_pk_trol IS NULL THEN
        RETURN; -- catalogo no sembrado en este entorno: no bloquea el guardado del grupo
    END IF;

    -- Alta: el nuevo director recibe el rol si no lo tiene ya activo aqui.
    IF p_fk_funcionario_nuevo IS NOT NULL THEN
        SELECT FK_TUSUARIO INTO v_pk_tusuario
          FROM academico_test.TFUNCIONARIO WHERE PK_TFUNCIONARIO = p_fk_funcionario_nuevo;
        IF v_pk_tusuario IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM academico_test.TSEDE_USUARIO
             WHERE FK_TUSUARIO = v_pk_tusuario AND FK_TROL = v_pk_trol
               AND FK_TSEDE = p_fk_sede AND FK_TLV_JORNADA = p_fk_jornada AND ACTIVE = TRUE
        ) THEN
            -- UK_TSEDE_USUARIO_2 (sede, rol, usuario, orden) cubre tambien
            -- los inactivos: MAX sin filtrar por ACTIVE evita chocar con uno
            -- dado de baja antes.
            SELECT COALESCE(MAX(ORDEN), 0) + 1 INTO v_orden
              FROM academico_test.TSEDE_USUARIO WHERE FK_TUSUARIO = v_pk_tusuario;
            INSERT INTO academico_test.TSEDE_USUARIO (
                FK_TSEDE, FK_TROL, FK_TUSUARIO, FK_TLV_JORNADA, ORDEN,
                TLV_ESTADO, PREDETERMINADO, CREATED_BY, CREATED_AT, ACTIVE
            ) VALUES (
                p_fk_sede, v_pk_trol, v_pk_tusuario, p_fk_jornada, v_orden,
                'ACTIVO', 0, p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
            );
        END IF;
    END IF;

    -- Baja: al anterior se le quita el rol solo si ya no dirige otro grupo.
    IF p_fk_funcionario_anterior IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TGRUPO
         WHERE FK_TFUNCIONARIO = p_fk_funcionario_anterior AND ACTIVE = TRUE
    ) THEN
        SELECT FK_TUSUARIO INTO v_pk_tusuario
          FROM academico_test.TFUNCIONARIO WHERE PK_TFUNCIONARIO = p_fk_funcionario_anterior;
        IF v_pk_tusuario IS NOT NULL THEN
            SELECT PK_TSEDE_USUARIO INTO v_pk_tsede_usuario
              FROM academico_test.TSEDE_USUARIO
             WHERE FK_TUSUARIO = v_pk_tusuario AND FK_TROL = v_pk_trol
               AND FK_TSEDE = p_fk_sede AND FK_TLV_JORNADA = p_fk_jornada AND ACTIVE = TRUE
             LIMIT 1;
            IF v_pk_tsede_usuario IS NOT NULL THEN
                UPDATE academico_test.TSEDE_USUARIO
                   SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
                       MODIFIED_AT = CURRENT_TIMESTAMP
                 WHERE PK_TSEDE_USUARIO = v_pk_tsede_usuario;
            END IF;
        END IF;
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_grupo_director_rol_sync_interno IS
    'INTERNO: llamado por fn_grupo_crear y fn_grupo_actualizar. Sincroniza el rol DIRECTOR_GRUPO (TSEDE_USUARIO) del funcionario asignado/desasignado como director de un grupo. Sin gate propio -- el caller ya valida GRUPOS.';

-- ---------------------------------------------------------------------------
-- fn_grupo_crear: hook al final, justo antes del RETURN. Mismo cuerpo que
-- V43, solo agrega el PERFORM del sync cuando el grado es preescolar y el
-- grupo nace con director asignado.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_grupo_crear(
    p_fk_grado BIGINT,
    p_nombre VARCHAR,
    p_fk_modelo_pedagogico BIGINT,
    p_capacidad NUMERIC,
    p_fk_funcionario BIGINT DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_id BIGINT; v_jornada BIGINT; v_sede BIGINT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_tmp_nombre VARCHAR(130); v_nombre_director VARCHAR(200);
    v_nombre_sede VARCHAR(130);
    v_periodo_id BIGINT;
BEGIN
    -- Jornada, sede y periodo desde el grado (el grado debe estar activo);
    -- se resuelven antes del gate porque el scope de nivel sede+jornada
    -- (CU-86e2w4xdt) los necesita.
    SELECT pa.PK_TPERIODO_ACADEMICO, pa.FK_TLV_JORNADA, pa.FK_TSEDE
      INTO v_periodo_id, v_jornada, v_sede
      FROM academico_test.TGRADO g JOIN academico_test.TPERIODO_ACADEMICO pa
        ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
     WHERE g.PK_TGRADO = p_fk_grado AND g.ACTIVE = TRUE;
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante,
        academico_test.fn_periodo_establecimiento(v_periodo_id),
        v_sede, v_jornada, 'CREAR');

    -- Nombre de la sede del periodo, para que la etiqueta de auditoria diga a
    -- que sede va dirigida la accion (el EE ya viaja aparte como contexto
    -- estructurado de fn_audit_declarar). Portado de V107 (antes V106).
    SELECT s.NOMBRE INTO v_nombre_sede FROM academico_test.TSEDE s WHERE s.PK_TSEDE = v_sede;
    IF p_fk_grado IS NULL OR NULLIF(TRIM(p_nombre),'') IS NULL OR p_fk_modelo_pedagogico IS NULL
       OR p_capacidad IS NULL THEN
        RAISE EXCEPTION 'Faltan campos obligatorios del grupo' USING ERRCODE = '22023';
    END IF;
    IF p_capacidad <= 0 THEN
        RAISE EXCEPTION 'La capacidad del grupo debe ser mayor a 0' USING ERRCODE = '22023';
    END IF;
    IF v_jornada IS NULL THEN
        SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_grado;
        IF v_tmp_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'El grado "%" existe pero esta inactivo', v_tmp_nombre USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'El grado seleccionado no existe' USING ERRCODE = '23503';
        END IF;
    END IF;
    IF p_fk_funcionario IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TFUNCIONARIO WHERE PK_TFUNCIONARIO = p_fk_funcionario AND ACTIVE = TRUE
    ) THEN
        SELECT TRIM(u.PRIMER_NOMBRE || ' ' || u.PRIMER_APELLIDO) INTO v_tmp_nombre
          FROM academico_test.TFUNCIONARIO f JOIN academico_test.TUSUARIO u ON u.PK_TUSUARIO = f.FK_TUSUARIO
         WHERE f.PK_TFUNCIONARIO = p_fk_funcionario;
        IF v_tmp_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'El director "%" existe pero no esta habilitado', v_tmp_nombre USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'El director seleccionado no existe' USING ERRCODE = '23503';
        END IF;
    END IF;
    -- El director debe pertenecer a la sede del grado (via su usuario en TSEDE_USUARIO).
    IF p_fk_funcionario IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TFUNCIONARIO f
          JOIN academico_test.TSEDE_USUARIO su ON su.FK_TUSUARIO = f.FK_TUSUARIO
         WHERE f.PK_TFUNCIONARIO = p_fk_funcionario
           AND su.FK_TSEDE = v_sede AND su.ACTIVE = TRUE AND su.TLV_ESTADO = 'ACTIVO'
    ) THEN
        SELECT TRIM(u.PRIMER_NOMBRE || ' ' || u.PRIMER_APELLIDO) INTO v_nombre_director
          FROM academico_test.TFUNCIONARIO f JOIN academico_test.TUSUARIO u ON u.PK_TUSUARIO = f.FK_TUSUARIO
         WHERE f.PK_TFUNCIONARIO = p_fk_funcionario;
        RAISE EXCEPTION 'El director "%" no pertenece a la sede de este grado', v_nombre_director
            USING ERRCODE = '23503';
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.TGRUPO
         WHERE FK_TGRADO = p_fk_grado AND FK_TLV_JORNADA = v_jornada AND ACTIVE = TRUE
           AND UPPER(TRIM(NOMBRE)) = UPPER(TRIM(p_nombre))
    ) THEN
        RAISE EXCEPTION 'Ya existe un grupo con el nombre % en este grado y jornada', p_nombre USING ERRCODE = '23505';
    END IF;
    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        format('Creación del grupo %s en la sede %s', p_nombre, v_nombre_sede),
        academico_test.fn_periodo_establecimiento((
            SELECT FK_TPERIODO_ACADEMICO FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_grado))
    );

    INSERT INTO academico_test.TGRUPO
        (NOMBRE, FK_TGRADO, FK_TLV_JORNADA, FK_TLV_MODELO_PEDAGOGICO, CAPACIDAD, FK_TFUNCIONARIO, CREATED_BY)
    VALUES (p_nombre, p_fk_grado, v_jornada, p_fk_modelo_pedagogico, p_capacidad, p_fk_funcionario, v_audit)
    RETURNING PK_TGRUPO INTO v_id;

    -- El director recien asignado recibe el rol DIRECTOR_GRUPO (TSEDE_USUARIO),
    -- ademas del/los rol(es) que ya tenga (p.ej. DOCENTE). Sin director previo
    -- que sincronizar: el grupo nace.
    PERFORM academico_test.fn_grupo_director_rol_sync_interno(
        NULL, p_fk_funcionario, v_sede, v_jornada, p_pk_usuario_solicitante);

    IF p_fk_funcionario IS NOT NULL AND academico_test.fn_grado_es_preescolar(p_fk_grado) THEN
        PERFORM academico_test.fn_docente_director_grupo_sync(
            p_fk_funcionario, v_periodo_id, NULL, p_pk_usuario_solicitante);
    END IF;

    RETURN v_id;
END;
$$;


DROP FUNCTION IF EXISTS academico_test.fn_grupo_actualizar(BIGINT, VARCHAR, BIGINT, NUMERIC, BIGINT, BIGINT, BOOLEAN);

CREATE OR REPLACE FUNCTION academico_test.fn_grupo_actualizar(
    p_pk BIGINT,
    p_nombre VARCHAR DEFAULT NULL,
    p_fk_modelo_pedagogico BIGINT DEFAULT NULL,
    p_capacidad NUMERIC DEFAULT NULL,
    p_fk_funcionario BIGINT DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    r academico_test.TGRUPO; v_nombre VARCHAR(130);
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_tmp_nombre VARCHAR(130); v_nombre_director VARCHAR(200);
    v_nombre_sede VARCHAR(130);
    v_periodo_id BIGINT; v_jornada_grupo BIGINT;
    v_fk_funcionario_final BIGINT; v_fk_sede_grupo BIGINT;
BEGIN
    SELECT g.FK_TPERIODO_ACADEMICO, gr.FK_TLV_JORNADA
      INTO v_periodo_id, v_jornada_grupo
      FROM academico_test.TGRUPO gr JOIN academico_test.TGRADO g ON g.PK_TGRADO = gr.FK_TGRADO
     WHERE gr.PK_TGRUPO = p_pk;
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante,
        academico_test.fn_periodo_establecimiento(v_periodo_id),
        academico_test.fn_periodo_sede(v_periodo_id),
        v_jornada_grupo, 'EDITAR');

    SELECT s.NOMBRE INTO v_nombre_sede
      FROM academico_test.TSEDE s
     WHERE s.PK_TSEDE = academico_test.fn_periodo_sede(v_periodo_id);

    SELECT * INTO r FROM academico_test.TGRUPO WHERE PK_TGRUPO = p_pk AND ACTIVE = TRUE;
    IF NOT FOUND THEN
        SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TGRUPO WHERE PK_TGRUPO = p_pk;
        IF v_tmp_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'El grupo "%" existe pero esta inactivo', v_tmp_nombre USING ERRCODE = 'P0002';
        ELSE
            RAISE EXCEPTION 'El grupo seleccionado no existe' USING ERRCODE = 'P0002';
        END IF;
    END IF;
    IF p_nombre IS NOT NULL AND NULLIF(TRIM(p_nombre),'') IS NULL THEN
        RAISE EXCEPTION 'El nombre del grupo no puede ser vacio' USING ERRCODE = '22023';
    END IF;
    IF p_fk_funcionario IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TFUNCIONARIO WHERE PK_TFUNCIONARIO = p_fk_funcionario AND ACTIVE = TRUE
    ) THEN
        SELECT TRIM(u.PRIMER_NOMBRE || ' ' || u.PRIMER_APELLIDO) INTO v_tmp_nombre
          FROM academico_test.TFUNCIONARIO f JOIN academico_test.TUSUARIO u ON u.PK_TUSUARIO = f.FK_TUSUARIO
         WHERE f.PK_TFUNCIONARIO = p_fk_funcionario;
        IF v_tmp_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'El director "%" existe pero no esta habilitado', v_tmp_nombre USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'El director seleccionado no existe' USING ERRCODE = '23503';
        END IF;
    END IF;
    -- El director debe pertenecer a la sede del grado del grupo (via TSEDE_USUARIO).
    IF p_fk_funcionario IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TFUNCIONARIO f
          JOIN academico_test.TSEDE_USUARIO su ON su.FK_TUSUARIO = f.FK_TUSUARIO
          JOIN academico_test.TGRADO g ON g.PK_TGRADO = r.FK_TGRADO
          JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
         WHERE f.PK_TFUNCIONARIO = p_fk_funcionario
           AND su.FK_TSEDE = pa.FK_TSEDE
           AND su.ACTIVE = TRUE AND su.TLV_ESTADO = 'ACTIVO'
    ) THEN
        SELECT TRIM(u.PRIMER_NOMBRE || ' ' || u.PRIMER_APELLIDO) INTO v_nombre_director
          FROM academico_test.TFUNCIONARIO f JOIN academico_test.TUSUARIO u ON u.PK_TUSUARIO = f.FK_TUSUARIO
         WHERE f.PK_TFUNCIONARIO = p_fk_funcionario;
        RAISE EXCEPTION 'El director "%" no pertenece a la sede de este grado', v_nombre_director
            USING ERRCODE = '23503';
    END IF;
    IF p_capacidad IS NOT NULL AND p_capacidad <= 0 THEN
        RAISE EXCEPTION 'La capacidad del grupo debe ser mayor a 0' USING ERRCODE = '22023';
    END IF;
    v_nombre := COALESCE(p_nombre, r.NOMBRE);
    IF EXISTS (
        SELECT 1 FROM academico_test.TGRUPO
         WHERE FK_TGRADO = r.FK_TGRADO AND FK_TLV_JORNADA = r.FK_TLV_JORNADA AND ACTIVE = TRUE
           AND PK_TGRUPO <> p_pk AND UPPER(TRIM(NOMBRE)) = UPPER(TRIM(v_nombre))
    ) THEN
        RAISE EXCEPTION 'Ya existe un grupo con el nombre % en este grado y jornada', v_nombre USING ERRCODE = '23505';
    END IF;
    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        format('Actualización del grupo %s en la sede %s', v_nombre, v_nombre_sede),
        academico_test.fn_periodo_establecimiento((
            SELECT g.FK_TPERIODO_ACADEMICO FROM academico_test.TGRADO g WHERE g.PK_TGRADO = r.FK_TGRADO))
    );

    v_fk_funcionario_final := COALESCE(p_fk_funcionario, r.FK_TFUNCIONARIO);

    UPDATE academico_test.TGRUPO SET
        NOMBRE = v_nombre,
        FK_TLV_MODELO_PEDAGOGICO = COALESCE(p_fk_modelo_pedagogico, FK_TLV_MODELO_PEDAGOGICO),
        CAPACIDAD = COALESCE(p_capacidad, CAPACIDAD),
        FK_TFUNCIONARIO = v_fk_funcionario_final,
        MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TGRUPO = p_pk;

    v_fk_sede_grupo := academico_test.fn_periodo_sede(v_periodo_id);
    PERFORM academico_test.fn_grupo_director_rol_sync_interno(
        r.FK_TFUNCIONARIO, v_fk_funcionario_final, v_fk_sede_grupo, v_jornada_grupo, p_pk_usuario_solicitante);

    IF academico_test.fn_grado_es_preescolar(r.FK_TGRADO) THEN
        IF r.FK_TFUNCIONARIO IS NOT NULL THEN
            PERFORM academico_test.fn_docente_director_grupo_sync(
                r.FK_TFUNCIONARIO, v_periodo_id, NULL, p_pk_usuario_solicitante);
        END IF;
        IF v_fk_funcionario_final IS NOT NULL AND v_fk_funcionario_final IS DISTINCT FROM r.FK_TFUNCIONARIO THEN
            PERFORM academico_test.fn_docente_director_grupo_sync(
                v_fk_funcionario_final, v_periodo_id, NULL, p_pk_usuario_solicitante);
        END IF;
    END IF;

    RETURN p_pk;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_plan_agregar(
    p_fk_grado             BIGINT,
    p_fk_asignatura        BIGINT,
    p_numero_hora          NUMERIC,
    p_influencia_area      NUMERIC,
    p_numero_credito       BIGINT,
    p_influye_desempeno    BOOLEAN,
    p_matricula_obligatoria BOOLEAN,
    p_aprobacion_obligatoria BOOLEAN,
    p_fk_formato_calif     BIGINT DEFAULT NULL,
    p_fk_criterio_nota     BIGINT DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_grado_nom TEXT; v_plan_id BIGINT; v_id BIGINT; v_periodo BIGINT;
    v_asignatura_nom TEXT; v_lookup TEXT;
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    -- CU-86e2w4xdt: gate por (EE, sede, jornada) del periodo del grado.
    SELECT g.FK_TPERIODO_ACADEMICO INTO v_periodo
      FROM academico_test.TGRADO g WHERE g.PK_TGRADO = p_fk_grado;
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante,
        academico_test.fn_periodo_establecimiento(v_periodo),
        academico_test.fn_periodo_sede(v_periodo),
        academico_test.fn_periodo_jornada(v_periodo), 'CREAR');
    IF p_fk_grado IS NULL OR p_fk_asignatura IS NULL THEN
        RAISE EXCEPTION 'Grado y asignatura son obligatorios' USING ERRCODE = '22023';
    END IF;
    -- Validaciones numericas.
    IF p_numero_hora IS NOT NULL AND p_numero_hora <= 0 THEN
        RAISE EXCEPTION 'La intensidad horaria debe ser mayor a 0' USING ERRCODE = '22023';
    END IF;
    IF p_influencia_area IS NOT NULL AND (p_influencia_area < 0 OR p_influencia_area > 100) THEN
        RAISE EXCEPTION 'La influencia en el area (%%) debe estar entre 0 y 100' USING ERRCODE = '22023';
    END IF;
    IF p_numero_credito IS NOT NULL AND p_numero_credito < 0 THEN
        RAISE EXCEPTION 'El numero de creditos no puede ser negativo' USING ERRCODE = '22023';
    END IF;

    SELECT NOMBRE INTO v_grado_nom FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_grado AND ACTIVE = TRUE;
    IF v_grado_nom IS NULL THEN
        SELECT NOMBRE INTO v_lookup FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_grado;
        IF v_lookup IS NOT NULL THEN
            RAISE EXCEPTION 'El grado "%" existe pero esta inactivo', v_lookup USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'El grado indicado no existe' USING ERRCODE = '23503';
        END IF;
    END IF;

    SELECT NOMBRE INTO v_asignatura_nom FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_fk_asignatura AND ACTIVE = TRUE;
    IF v_asignatura_nom IS NULL THEN
        SELECT NOMBRE INTO v_lookup FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_fk_asignatura;
        IF v_lookup IS NOT NULL THEN
            RAISE EXCEPTION 'La asignatura "%" existe pero esta inactiva', v_lookup USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'La asignatura indicada no existe' USING ERRCODE = '23503';
        END IF;
    END IF;
    IF p_fk_formato_calif IS NOT NULL THEN
        SELECT VALOR INTO v_lookup FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_fk_formato_calif AND ACTIVE = TRUE AND CATEGORIA = 'FORMATO_CALIFICACION';
        IF v_lookup IS NULL THEN
            SELECT VALOR INTO v_lookup FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_fk_formato_calif;
            IF v_lookup IS NOT NULL THEN
                RAISE EXCEPTION 'El formato de calificacion "%" existe pero esta inactivo o no pertenece a la categoria correspondiente', v_lookup
                    USING ERRCODE = '23503';
            ELSE
                RAISE EXCEPTION 'El formato de calificacion indicado no existe' USING ERRCODE = '23503';
            END IF;
        END IF;
    END IF;
    IF p_fk_criterio_nota IS NOT NULL THEN
        SELECT VALOR INTO v_lookup FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_fk_criterio_nota AND ACTIVE = TRUE AND CATEGORIA = 'TIPO_CALCULO';
        IF v_lookup IS NULL THEN
            SELECT VALOR INTO v_lookup FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_fk_criterio_nota;
            IF v_lookup IS NOT NULL THEN
                RAISE EXCEPTION 'El criterio de calculo de nota "%" existe pero esta inactivo o no pertenece a la categoria correspondiente', v_lookup
                    USING ERRCODE = '23503';
            ELSE
                RAISE EXCEPTION 'El criterio de calculo de nota indicado no existe' USING ERRCODE = '23503';
            END IF;
        END IF;
    END IF;

    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        format('Asignación de %s al plan de estudio del grado %s', v_asignatura_nom, v_grado_nom),
        academico_test.fn_periodo_establecimiento((
            SELECT g.FK_TPERIODO_ACADEMICO FROM academico_test.TGRADO g WHERE g.PK_TGRADO = p_fk_grado))
    );

    PERFORM pg_advisory_xact_lock(hashtext('plan:' || p_fk_grado::text));
    SELECT PK_TPLAN INTO v_plan_id FROM academico_test.TPLAN WHERE FK_TGRADO = p_fk_grado AND ACTIVE = TRUE;
    IF v_plan_id IS NULL THEN
        INSERT INTO academico_test.TPLAN (CODIGO, NOMBRE, FK_TGRADO, CREATED_BY)
        VALUES (LEFT(v_grado_nom, 30), 'Plan ' || v_grado_nom, p_fk_grado, v_audit)
        RETURNING PK_TPLAN INTO v_plan_id;
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.TASIGNATURA_PLAN
         WHERE FK_TPLAN = v_plan_id AND FK_TASIGNATURA = p_fk_asignatura AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'La asignatura "%" ya esta en el plan de estudio de este grado', v_asignatura_nom
            USING ERRCODE = '23505';
    END IF;

    INSERT INTO academico_test.TASIGNATURA_PLAN (
        FK_TPLAN, FK_TASIGNATURA, NUMERO_HORA, INFLUENCIA_AREA, NUMERO_CREDITO,
        INFLUYE_DESEMPLENO_ACADEMICO, MATRICULA_OBLIGATORIA, APROBACION_OBLIGATORIA,
        FK_TLV_FORMATO_CALIFICACION_DEF, FK_TLV_CALCULO_DEFINITIVA, CREATED_BY
    ) VALUES (
        v_plan_id, p_fk_asignatura, p_numero_hora, p_influencia_area, p_numero_credito,
        CASE WHEN p_influye_desempeno THEN 'S' ELSE 'N' END::academico_test.bool_sn,
        CASE WHEN p_matricula_obligatoria THEN 'S' ELSE 'N' END::academico_test.bool_sn,
        CASE WHEN p_aprobacion_obligatoria THEN 'S' ELSE 'N' END,
        p_fk_formato_calif, p_fk_criterio_nota, v_audit
    )
    RETURNING PK_TASIGNATURA_PLAN INTO v_id;

    SELECT FK_TPERIODO_ACADEMICO INTO v_periodo FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_grado;
    IF EXISTS (
        SELECT 1 FROM academico_test.TCRITERIO_EVALUACION
         WHERE PK_TCRITERIO_EVALUACION = v_periodo AND ACTIVE = TRUE
    ) THEN
        INSERT INTO academico_test.TCRITERIO_EVALUACION_ASIGNATURA_PLAN
            (FK_TCRITERIO_EVALUACION, FK_TASIGNATURA_PLAN, FK_TGRADO, POR_DEFECTO, CREATED_BY)
        VALUES (v_periodo, v_id, NULL, 'S', v_audit);
    END IF;

    IF academico_test.fn_grado_es_preescolar(p_fk_grado) THEN
        PERFORM academico_test.fn_docente_grado_directores_sync(
            p_fk_grado, NULL, p_pk_usuario_solicitante);
    END IF;

    RETURN v_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- fn_plan_actualizar: hook antes del RETURN, tras el UPDATE exitoso. Se
-- resuelve v_grado_id (nuevo, la version original no lo necesitaba) para
-- poder llamar al sync por grado.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_plan_actualizar(
    p_pk                   BIGINT,
    p_fk_asignatura        BIGINT  DEFAULT NULL,
    p_numero_hora          NUMERIC DEFAULT NULL,
    p_influencia_area      NUMERIC DEFAULT NULL,
    p_numero_credito       BIGINT  DEFAULT NULL,
    p_influye_desempeno    BOOLEAN DEFAULT NULL,
    p_matricula_obligatoria BOOLEAN DEFAULT NULL,
    p_aprobacion_obligatoria BOOLEAN DEFAULT NULL,
    p_fk_formato_calif     BIGINT  DEFAULT NULL,
    p_fk_criterio_nota     BIGINT  DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_n INT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_asignatura_nom TEXT; v_grado_nom TEXT; v_lookup TEXT;
    v_periodo_id BIGINT; v_grado_id BIGINT;
BEGIN
    -- CU-86e2w4xdt: gate por (EE, sede, jornada) del periodo del plan.
    SELECT g.FK_TPERIODO_ACADEMICO, g.PK_TGRADO INTO v_periodo_id, v_grado_id
      FROM academico_test.TASIGNATURA_PLAN ap
      JOIN academico_test.TPLAN pl ON pl.PK_TPLAN = ap.FK_TPLAN
      JOIN academico_test.TGRADO g ON g.PK_TGRADO = pl.FK_TGRADO
     WHERE ap.PK_TASIGNATURA_PLAN = p_pk;
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante,
        academico_test.fn_periodo_establecimiento(v_periodo_id),
        academico_test.fn_periodo_sede(v_periodo_id),
        academico_test.fn_periodo_jornada(v_periodo_id), 'EDITAR');
    -- Validaciones numericas (solo si vienen).
    IF p_numero_hora IS NOT NULL AND p_numero_hora <= 0 THEN
        RAISE EXCEPTION 'La intensidad horaria debe ser mayor a 0' USING ERRCODE = '22023';
    END IF;
    IF p_influencia_area IS NOT NULL AND (p_influencia_area < 0 OR p_influencia_area > 100) THEN
        RAISE EXCEPTION 'La influencia en el area (%%) debe estar entre 0 y 100' USING ERRCODE = '22023';
    END IF;
    IF p_numero_credito IS NOT NULL AND p_numero_credito < 0 THEN
        RAISE EXCEPTION 'El numero de creditos no puede ser negativo' USING ERRCODE = '22023';
    END IF;
    -- Si se cambia la asignatura: debe existir/activa y no duplicar en el plan.
    IF p_fk_asignatura IS NOT NULL THEN
        SELECT NOMBRE INTO v_asignatura_nom FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_fk_asignatura AND ACTIVE = TRUE;
        IF v_asignatura_nom IS NULL THEN
            SELECT NOMBRE INTO v_lookup FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_fk_asignatura;
            IF v_lookup IS NOT NULL THEN
                RAISE EXCEPTION 'La asignatura "%" existe pero esta inactiva', v_lookup USING ERRCODE = '23503';
            ELSE
                RAISE EXCEPTION 'La asignatura indicada no existe' USING ERRCODE = '23503';
            END IF;
        END IF;
        IF EXISTS (
            SELECT 1 FROM academico_test.TASIGNATURA_PLAN x
              JOIN academico_test.TASIGNATURA_PLAN cur ON cur.PK_TASIGNATURA_PLAN = p_pk
             WHERE x.FK_TPLAN = cur.FK_TPLAN AND x.PK_TASIGNATURA_PLAN <> p_pk
               AND x.FK_TASIGNATURA = p_fk_asignatura AND x.ACTIVE = TRUE
        ) THEN
            RAISE EXCEPTION 'La asignatura "%" ya esta en el plan de estudio de este grado', v_asignatura_nom
                USING ERRCODE = '23505';
        END IF;
    END IF;
    -- Formato de calificacion / criterio de nota: mismos checks que en
    -- fn_plan_agregar (NULL = vuelve a heredar del criterio de evaluacion).
    IF p_fk_formato_calif IS NOT NULL THEN
        SELECT VALOR INTO v_lookup FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_fk_formato_calif AND ACTIVE = TRUE AND CATEGORIA = 'FORMATO_CALIFICACION';
        IF v_lookup IS NULL THEN
            SELECT VALOR INTO v_lookup FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_fk_formato_calif;
            IF v_lookup IS NOT NULL THEN
                RAISE EXCEPTION 'El formato de calificacion "%" existe pero esta inactivo o no pertenece a la categoria correspondiente', v_lookup
                    USING ERRCODE = '23503';
            ELSE
                RAISE EXCEPTION 'El formato de calificacion indicado no existe' USING ERRCODE = '23503';
            END IF;
        END IF;
    END IF;
    IF p_fk_criterio_nota IS NOT NULL THEN
        SELECT VALOR INTO v_lookup FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_fk_criterio_nota AND ACTIVE = TRUE AND CATEGORIA = 'TIPO_CALCULO';
        IF v_lookup IS NULL THEN
            SELECT VALOR INTO v_lookup FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_fk_criterio_nota;
            IF v_lookup IS NOT NULL THEN
                RAISE EXCEPTION 'El criterio de calculo de nota "%" existe pero esta inactivo o no pertenece a la categoria correspondiente', v_lookup
                    USING ERRCODE = '23503';
            ELSE
                RAISE EXCEPTION 'El criterio de calculo de nota indicado no existe' USING ERRCODE = '23503';
            END IF;
        END IF;
    END IF;
    -- v_grado_nom (y v_asignatura_nom si no vino en el patch) no estaban
    -- resueltos en este punto -- se agrega este lookup solo para la etiqueta,
    -- mismo patron que ya usa mas abajo el branch de "renglon no encontrado".
    IF v_asignatura_nom IS NULL THEN
        SELECT ta.NOMBRE INTO v_asignatura_nom
          FROM academico_test.TASIGNATURA_PLAN ap
          JOIN academico_test.TASIGNATURA ta ON ta.PK_TASIGNATURA = ap.FK_TASIGNATURA
         WHERE ap.PK_TASIGNATURA_PLAN = p_pk;
    END IF;
    SELECT tg.NOMBRE INTO v_grado_nom
      FROM academico_test.TASIGNATURA_PLAN ap
      JOIN academico_test.TPLAN pl ON pl.PK_TPLAN = ap.FK_TPLAN
      JOIN academico_test.TGRADO tg ON tg.PK_TGRADO = pl.FK_TGRADO
     WHERE ap.PK_TASIGNATURA_PLAN = p_pk;

    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        format('Actualización del plan de estudio: %s en %s', v_asignatura_nom, v_grado_nom),
        academico_test.fn_periodo_establecimiento((
            SELECT g.FK_TPERIODO_ACADEMICO FROM academico_test.TASIGNATURA_PLAN ap
              JOIN academico_test.TPLAN pl ON pl.PK_TPLAN = ap.FK_TPLAN
              JOIN academico_test.TGRADO g ON g.PK_TGRADO = pl.FK_TGRADO
             WHERE ap.PK_TASIGNATURA_PLAN = p_pk))
    );

    -- formato/criterio se setean SIEMPRE (permiten volver a NULL = heredar).
    UPDATE academico_test.TASIGNATURA_PLAN SET
        FK_TASIGNATURA = COALESCE(p_fk_asignatura, FK_TASIGNATURA),
        NUMERO_HORA = COALESCE(p_numero_hora, NUMERO_HORA),
        INFLUENCIA_AREA = COALESCE(p_influencia_area, INFLUENCIA_AREA),
        NUMERO_CREDITO = COALESCE(p_numero_credito, NUMERO_CREDITO),
        INFLUYE_DESEMPLENO_ACADEMICO = CASE WHEN p_influye_desempeno IS NULL THEN INFLUYE_DESEMPLENO_ACADEMICO
                                            WHEN p_influye_desempeno THEN 'S' ELSE 'N' END::academico_test.bool_sn,
        MATRICULA_OBLIGATORIA = CASE WHEN p_matricula_obligatoria IS NULL THEN MATRICULA_OBLIGATORIA
                                     WHEN p_matricula_obligatoria THEN 'S' ELSE 'N' END::academico_test.bool_sn,
        APROBACION_OBLIGATORIA = CASE WHEN p_aprobacion_obligatoria IS NULL THEN APROBACION_OBLIGATORIA
                                      WHEN p_aprobacion_obligatoria THEN 'S' ELSE 'N' END,
        FK_TLV_FORMATO_CALIFICACION_DEF = p_fk_formato_calif,
        FK_TLV_CALCULO_DEFINITIVA = p_fk_criterio_nota,
        MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TASIGNATURA_PLAN = p_pk AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN
        SELECT ta.NOMBRE, tg.NOMBRE INTO v_asignatura_nom, v_grado_nom
          FROM academico_test.TASIGNATURA_PLAN ap
          JOIN academico_test.TASIGNATURA ta ON ta.PK_TASIGNATURA = ap.FK_TASIGNATURA
          JOIN academico_test.TPLAN pl ON pl.PK_TPLAN = ap.FK_TPLAN
          JOIN academico_test.TGRADO tg ON tg.PK_TGRADO = pl.FK_TGRADO
         WHERE ap.PK_TASIGNATURA_PLAN = p_pk;
        IF v_asignatura_nom IS NOT NULL THEN
            RAISE EXCEPTION 'El renglon de plan para la asignatura "%" del grado "%" existe pero esta inactivo', v_asignatura_nom, v_grado_nom
                USING ERRCODE = 'P0002';
        ELSE
            RAISE EXCEPTION 'No existe un renglon de plan activo con el identificador indicado' USING ERRCODE = 'P0002';
        END IF;
    END IF;

    -- V301: preescolar -- si cambio la asignatura del renglon (o cualquier
    -- otro campo), el conjunto de asignaturas del grado pudo cambiar;
    -- resincroniza a todos los directores del grado.
    IF academico_test.fn_grado_es_preescolar(v_grado_id) THEN
        PERFORM academico_test.fn_docente_grado_directores_sync(
            v_grado_id, NULL, p_pk_usuario_solicitante);
    END IF;

    RETURN p_pk;
END;
$$;

-- ---------------------------------------------------------------------------
-- fn_plan_eliminar: el sync corre ANTES de los dos chequeos de bloqueo
-- existentes (TDOCENTE_ASIGNATURA / THORARIO), excluyendo la asignatura que
-- se esta quitando -- asi, si el unico "docente" de esa pareja era el
-- director auto-asignado, deja de existir esa fila y el chequeo deja de
-- bloquear. Resto del cuerpo sin cambios respecto a V44 (consolidado).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_plan_eliminar(p_pk bigint, p_pk_usuario_solicitante bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $$
DECLARE
    v_n INT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_asignatura_nom TEXT; v_grado_nom TEXT;
    v_plan_id BIGINT;
    v_periodo_id BIGINT;
    v_grado_id BIGINT; v_asignatura_id BIGINT;
BEGIN
    -- CU-86e2w4xdt: gate por (EE, sede, jornada) del periodo del plan.
    SELECT g.FK_TPERIODO_ACADEMICO, g.PK_TGRADO, ap.FK_TASIGNATURA
      INTO v_periodo_id, v_grado_id, v_asignatura_id
      FROM academico_test.TASIGNATURA_PLAN ap
      JOIN academico_test.TPLAN pl ON pl.PK_TPLAN = ap.FK_TPLAN
      JOIN academico_test.TGRADO g ON g.PK_TGRADO = pl.FK_TGRADO
     WHERE ap.PK_TASIGNATURA_PLAN = p_pk;
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante,
        academico_test.fn_periodo_establecimiento(v_periodo_id),
        academico_test.fn_periodo_sede(v_periodo_id),
        academico_test.fn_periodo_jornada(v_periodo_id), 'ELIMINAR');

    IF academico_test.fn_grado_es_preescolar(v_grado_id) THEN
        PERFORM academico_test.fn_docente_grado_directores_sync(
            v_grado_id, v_asignatura_id, p_pk_usuario_solicitante);
    END IF;

    IF EXISTS (
        SELECT 1
          FROM academico_test.TASIGNATURA_PLAN ap
          JOIN academico_test.TPLAN pl ON pl.PK_TPLAN = ap.FK_TPLAN
          JOIN academico_test.TGRUPO g ON g.FK_TGRADO = pl.FK_TGRADO AND g.ACTIVE = TRUE
          JOIN academico_test.TDOCENTE_ASIGNATURA da ON da.FK_TGRUPO = g.PK_TGRUPO
               AND da.FK_TASIGNATURA = ap.FK_TASIGNATURA AND da.ACTIVE = TRUE
         WHERE ap.PK_TASIGNATURA_PLAN = p_pk AND ap.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar: la asignatura tiene asignaciones academicas (docentes) en grupos del grado'
            USING ERRCODE = '23503';
    END IF;
    IF EXISTS (
        SELECT 1
          FROM academico_test.TASIGNATURA_PLAN ap
          JOIN academico_test.TPLAN pl ON pl.PK_TPLAN = ap.FK_TPLAN
          JOIN academico_test.TGRUPO g ON g.FK_TGRADO = pl.FK_TGRADO AND g.ACTIVE = TRUE
          JOIN academico_test.THORARIO h ON h.FK_TGRUPO = g.PK_TGRUPO
               AND h.FK_TASIGNATURA = ap.FK_TASIGNATURA AND h.ACTIVE = TRUE
         WHERE ap.PK_TASIGNATURA_PLAN = p_pk AND ap.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar: la asignatura tiene bloques de horario configurados en grupos del grado'
            USING ERRCODE = '23503';
    END IF;
    SELECT FK_TPLAN INTO v_plan_id FROM academico_test.TASIGNATURA_PLAN WHERE PK_TASIGNATURA_PLAN = p_pk;
    SELECT ta.NOMBRE, tg.NOMBRE INTO v_asignatura_nom, v_grado_nom
      FROM academico_test.TASIGNATURA_PLAN ap
      JOIN academico_test.TASIGNATURA ta ON ta.PK_TASIGNATURA = ap.FK_TASIGNATURA
      JOIN academico_test.TPLAN pl ON pl.PK_TPLAN = ap.FK_TPLAN
      JOIN academico_test.TGRADO tg ON tg.PK_TGRADO = pl.FK_TGRADO
     WHERE ap.PK_TASIGNATURA_PLAN = p_pk;
    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        format('Eliminación de %s del plan de estudio de %s', v_asignatura_nom, v_grado_nom),
        academico_test.fn_periodo_establecimiento((
            SELECT g.FK_TPERIODO_ACADEMICO FROM academico_test.TASIGNATURA_PLAN ap
              JOIN academico_test.TPLAN pl ON pl.PK_TPLAN = ap.FK_TPLAN
              JOIN academico_test.TGRADO g ON g.PK_TGRADO = pl.FK_TGRADO
             WHERE ap.PK_TASIGNATURA_PLAN = p_pk))
    );
    UPDATE academico_test.TASIGNATURA_PLAN SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TASIGNATURA_PLAN = p_pk AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN
        SELECT ta.NOMBRE, tg.NOMBRE INTO v_asignatura_nom, v_grado_nom
          FROM academico_test.TASIGNATURA_PLAN ap
          JOIN academico_test.TASIGNATURA ta ON ta.PK_TASIGNATURA = ap.FK_TASIGNATURA
          JOIN academico_test.TPLAN pl ON pl.PK_TPLAN = ap.FK_TPLAN
          JOIN academico_test.TGRADO tg ON tg.PK_TGRADO = pl.FK_TGRADO
         WHERE ap.PK_TASIGNATURA_PLAN = p_pk;
        IF v_asignatura_nom IS NOT NULL THEN
            RAISE EXCEPTION 'El renglon de plan para la asignatura "%" del grado "%" existe pero esta inactivo', v_asignatura_nom, v_grado_nom
                USING ERRCODE = 'P0002';
        ELSE
            RAISE EXCEPTION 'No existe un renglon de plan activo con el identificador indicado' USING ERRCODE = 'P0002';
        END IF;
    END IF;
    UPDATE academico_test.TCRITERIO_EVALUACION_ASIGNATURA_PLAN
       SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TASIGNATURA_PLAN = p_pk AND ACTIVE = TRUE;
    IF v_plan_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TASIGNATURA_PLAN
         WHERE FK_TPLAN = v_plan_id AND ACTIVE = TRUE
    ) THEN
        UPDATE academico_test.TPLAN
           SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TPLAN = v_plan_id AND ACTIVE = TRUE;
    END IF;
    RETURN p_pk;
END;
$$;
