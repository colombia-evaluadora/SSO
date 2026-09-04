-- Modulo "grado" (agrupa tambien "grupo", que vive en el mismo dominio
-- front/back que grado). fn_grado_crear ya habia sido corregida en un intento
-- previo de esta misma tarea (confirmado en vivo via pg_get_functiondef: ya
-- resuelve v_nombre del catalogo GRADOS antes del INSERT), asi que aqui NO se
-- vuelve a tocar esa funcion salvo por los RAISE EXCEPTION que seguian
-- exponiendo IDs crudos y que ese intento previo no cubria (periodo, nivel de
-- ensenanza, grado siguiente).
--
-- Cuerpo base de todas las funciones tomado de pg_get_functiondef en vivo
-- (confirmado 2026-08-19), no de los volcados estaticos del scratchpad.
--
-- Funciones tocadas y motivo:
--   fn_grado_crear       -> "El periodo academico %"/"El nivel de ensenanza %"
--                            no existe o esta inactivo (regla 4: lookup
--                            ignorando ACTIVE); "El grado siguiente % no es
--                            valido" (regla 4, mismo patron: es una FK de
--                            catalogo que el usuario paso y no se encontro).
--   fn_grado_actualizar  -> "No existe un grado activo con PK %" (regla 5);
--                            "El nivel de ensenanza %" (regla 4); "El grado
--                            siguiente %" (regla 4).
--   fn_grado_soft_delete -> los 4 mensajes "No se puede eliminar el grado %:
--                            ..." (regla 3: p_pk ya fue resuelto por el gate
--                            de autorizacion previo, que ya requiere que el
--                            grado exista; se agrega un SELECT NOMBRE simple
--                            justo despues del gate para reusarlo en los 4
--                            mensajes); "No existe un grado activo con PK %"
--                            al final (regla 5).
--   fn_grupo_crear       -> "El grado %"/"El director %" no existe/habilitado
--                            (regla 4); "El director % no pertenece a la sede
--                            de este grado" (regla 3: el director ya fue
--                            confirmado activo por el chequeo anterior).
--   fn_grupo_actualizar  -> "No existe un grupo activo con PK %" (regla 5);
--                            "El director %" no existe/habilitado (regla 4);
--                            "El director % no pertenece..." (regla 3).
--   fn_grupo_soft_delete -> los 4 mensajes "No se puede eliminar el grupo %:
--                            ..." (regla 3, mismo patron que grado); "No
--                            existe un grupo activo con PK %" (regla 5).
--   fn_grado_bulk_delete -> NO se toca: solo orquesta fn_grado_soft_delete via
--                            PERFORM/EXCEPTION WHEN OTHERS y reenvia su
--                            SQLSTATE/mensaje, hereda el fix automaticamente.
--
-- El nombre del director/funcionario se resuelve via TFUNCIONARIO.FK_TUSUARIO
-- -> TUSUARIO.PRIMER_NOMBRE || ' ' || PRIMER_APELLIDO (TFUNCIONARIO no tiene
-- columna de nombre propia).
--
-- Firmas, DEFAULTs, ERRCODEs y logica de negocio se preservan intactos.

CREATE OR REPLACE FUNCTION academico_test.fn_grado_crear(
    p_fk_periodo BIGINT,
    p_fk_nivel BIGINT,
    p_nombre VARCHAR,
    p_fk_grado_siguiente BIGINT DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_id BIGINT;
    v_codigo VARCHAR(30);
    v_nombre VARCHAR(130);
    v_tmp_nombre VARCHAR(130);
    v_nombre_sede VARCHAR(130);
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante,
        academico_test.fn_periodo_establecimiento(p_fk_periodo)
    );

    -- Nombre de la sede del periodo, para que la etiqueta de auditoria de
    -- abajo diga a que sede va dirigida la accion (no solo el establecimiento,
    -- que ya viaja aparte como contexto estructurado de fn_audit_declarar).
    SELECT s.NOMBRE INTO v_nombre_sede
      FROM academico_test.TPERIODO_ACADEMICO pa
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE pa.PK_TPERIODO_ACADEMICO = p_fk_periodo;

    IF p_fk_periodo IS NULL
       OR p_fk_nivel IS NULL
       OR NULLIF(TRIM(p_nombre), '') IS NULL THEN
        RAISE EXCEPTION 'Faltan campos obligatorios del grado'
            USING ERRCODE = '22023';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM academico_test.TPERIODO_ACADEMICO
        WHERE PK_TPERIODO_ACADEMICO = p_fk_periodo
          AND ACTIVE = TRUE
    ) THEN
        SELECT NOMBRE INTO v_tmp_nombre
          FROM academico_test.TPERIODO_ACADEMICO
         WHERE PK_TPERIODO_ACADEMICO = p_fk_periodo;
        IF v_tmp_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'El periodo academico "%" existe pero esta inactivo', v_tmp_nombre
                USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'El periodo academico seleccionado no existe'
                USING ERRCODE = '23503';
        END IF;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM academico_test.TNIVEL_ENSENANZA
        WHERE PK_NIVEL_ENSENANZA = p_fk_nivel
          AND ACTIVE = TRUE
    ) THEN
        SELECT NOMBRE INTO v_tmp_nombre
          FROM academico_test.TNIVEL_ENSENANZA
         WHERE PK_NIVEL_ENSENANZA = p_fk_nivel;
        IF v_tmp_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'El nivel de ensenanza "%" existe pero esta inactivo', v_tmp_nombre
                USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'El nivel de ensenanza seleccionado no existe'
                USING ERRCODE = '23503';
        END IF;
    END IF;

    /*
     * El front puede enviar el NOMBRE o el VALOR del catálogo GRADOS.
     *
     * Ejemplo:
     *   NOMBRE = 'Octavo'
     *   VALOR  = '8'
     *
     * Si recibe '8' → guarda CODIGO='8', NOMBRE='Octavo'
     * Si recibe 'Octavo' → guarda CODIGO='8', NOMBRE='Octavo'
     */
    SELECT
        VALOR,
        NOMBRE
    INTO
        v_codigo,
        v_nombre
    FROM academico_test.TLISTA_VALOR
    WHERE CATEGORIA = 'GRADOS'
      AND ACTIVE = TRUE
      AND (
          UPPER(TRIM(NOMBRE)) = UPPER(TRIM(p_nombre))
          OR TRIM(VALOR) = TRIM(p_nombre)
      )
    LIMIT 1;

    IF v_codigo IS NULL THEN
        RAISE EXCEPTION 'El grado "%" no existe en el catalogo GRADOS',
            p_nombre
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_grado_siguiente IS NOT NULL
       AND NOT EXISTS (
           SELECT 1
           FROM academico_test.TLISTA_VALOR
           WHERE PK_LISTA_VALOR = p_fk_grado_siguiente
             AND ACTIVE = TRUE
             AND CATEGORIA = 'GRADOS'
       )
    THEN
        SELECT NOMBRE INTO v_tmp_nombre
          FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_fk_grado_siguiente AND CATEGORIA = 'GRADOS';
        IF v_tmp_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'El grado siguiente "%" existe pero esta inactivo', v_tmp_nombre
                USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'El grado siguiente seleccionado no es valido (debe ser de la categoria GRADOS)'
                USING ERRCODE = '23503';
        END IF;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM academico_test.TGRADO
        WHERE FK_TPERIODO_ACADEMICO = p_fk_periodo
          AND ACTIVE = TRUE
          AND UPPER(TRIM(NOMBRE)) = UPPER(TRIM(v_nombre))
    ) THEN
        RAISE EXCEPTION
            'Ya existe un grado con el nombre % en este periodo',
            v_nombre
            USING ERRCODE = '23505';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM academico_test.TGRADO
        WHERE FK_TPERIODO_ACADEMICO = p_fk_periodo
          AND ACTIVE = TRUE
          AND UPPER(TRIM(CODIGO)) = UPPER(TRIM(v_codigo))
    ) THEN
        RAISE EXCEPTION
            'Ya existe un grado con el codigo % en este periodo',
            v_codigo
            USING ERRCODE = '23505';
    END IF;

    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        format('Creación del grado %s en la sede %s', v_nombre, v_nombre_sede),
        academico_test.fn_periodo_establecimiento(p_fk_periodo)
    );

    INSERT INTO academico_test.TGRADO (
        CODIGO,
        NOMBRE,
        FK_TPERIODO_ACADEMICO,
        FK_TNIVEL_ENSENANZA,
        FK_TLV_GRADO_SIGUIENTE,
        TIENE_GRADO_SIGUIENTE,
        CREATED_BY
    )
    VALUES (
        v_codigo,
        v_nombre,
        p_fk_periodo,
        p_fk_nivel,
        p_fk_grado_siguiente,
        CASE
            WHEN p_fk_grado_siguiente IS NULL THEN 'N'
            ELSE 'S'
        END::academico_test.bool_sn,
        v_audit
    )
    RETURNING PK_TGRADO INTO v_id;

    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_grado_actualizar(
    p_pk BIGINT,
    p_fk_nivel BIGINT DEFAULT NULL,
    p_nombre VARCHAR DEFAULT NULL,
    p_fk_grado_siguiente BIGINT DEFAULT NULL,
    p_tiene_grado_siguiente BOOLEAN DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    r academico_test.TGRADO;
    v_nombre VARCHAR(130); v_fk_sig BIGINT; v_tmp_nombre VARCHAR(130);
    v_nombre_sede VARCHAR(130);
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, (
        SELECT academico_test.fn_periodo_establecimiento(g.FK_TPERIODO_ACADEMICO)
          FROM academico_test.TGRADO g WHERE g.PK_TGRADO = p_pk));
    SELECT * INTO r FROM academico_test.TGRADO WHERE PK_TGRADO = p_pk AND ACTIVE = TRUE;
    IF NOT FOUND THEN
        SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TGRADO WHERE PK_TGRADO = p_pk;
        IF v_tmp_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'El grado "%" existe pero esta inactivo', v_tmp_nombre USING ERRCODE = 'P0002';
        ELSE
            RAISE EXCEPTION 'El grado seleccionado no existe' USING ERRCODE = 'P0002';
        END IF;
    END IF;
    IF p_nombre IS NOT NULL AND NULLIF(TRIM(p_nombre),'') IS NULL THEN
        RAISE EXCEPTION 'El nombre del grado no puede ser vacio' USING ERRCODE = '22023';
    END IF;
    IF p_fk_nivel IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TNIVEL_ENSENANZA WHERE PK_NIVEL_ENSENANZA = p_fk_nivel AND ACTIVE = TRUE
    ) THEN
        SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TNIVEL_ENSENANZA WHERE PK_NIVEL_ENSENANZA = p_fk_nivel;
        IF v_tmp_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'El nivel de ensenanza "%" existe pero esta inactivo', v_tmp_nombre USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'El nivel de ensenanza seleccionado no existe' USING ERRCODE = '23503';
        END IF;
    END IF;
    v_nombre := COALESCE(p_nombre, r.NOMBRE);
    -- Nombre de la sede del periodo, para la etiqueta de auditoria de abajo.
    SELECT s.NOMBRE INTO v_nombre_sede
      FROM academico_test.TPERIODO_ACADEMICO pa
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE pa.PK_TPERIODO_ACADEMICO = r.FK_TPERIODO_ACADEMICO;
    -- El codigo NO se cambia en edicion (queda el derivado del catalogo al crear).
    -- Si p_tiene_grado_siguiente = FALSE, se limpia el FK; si TRUE o NULL, se
    -- usa p_fk_grado_siguiente (COALESCE con el actual cuando llega NULL).
    v_fk_sig := CASE WHEN p_tiene_grado_siguiente = FALSE THEN NULL
                     ELSE COALESCE(p_fk_grado_siguiente, r.FK_TLV_GRADO_SIGUIENTE) END;
    IF v_fk_sig IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = v_fk_sig AND ACTIVE = TRUE AND CATEGORIA = 'GRADOS'
    ) THEN
        SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = v_fk_sig AND CATEGORIA = 'GRADOS';
        IF v_tmp_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'El grado siguiente "%" existe pero esta inactivo', v_tmp_nombre USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'El grado siguiente seleccionado no es valido (debe ser de la categoria GRADOS)'
                USING ERRCODE = '23503';
        END IF;
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.TGRADO
         WHERE FK_TPERIODO_ACADEMICO = r.FK_TPERIODO_ACADEMICO AND ACTIVE = TRUE AND PK_TGRADO <> p_pk
           AND UPPER(TRIM(NOMBRE)) = UPPER(TRIM(v_nombre))
    ) THEN
        RAISE EXCEPTION 'Ya existe un grado con el nombre % en este periodo', v_nombre USING ERRCODE = '23505';
    END IF;
    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        format('Actualización del grado %s en la sede %s', v_nombre, v_nombre_sede),
        academico_test.fn_periodo_establecimiento(r.FK_TPERIODO_ACADEMICO)
    );

    UPDATE academico_test.TGRADO SET
        FK_TNIVEL_ENSENANZA = COALESCE(p_fk_nivel, FK_TNIVEL_ENSENANZA),
        NOMBRE = v_nombre,
        FK_TLV_GRADO_SIGUIENTE = v_fk_sig,
        TIENE_GRADO_SIGUIENTE = CASE WHEN v_fk_sig IS NULL THEN 'N' ELSE 'S' END::academico_test.bool_sn,
        MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TGRADO = p_pk;
    RETURN p_pk;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_grado_soft_delete(p_pk BIGINT, p_pk_usuario_solicitante BIGINT)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_n INT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_nombre_grado VARCHAR(130);
    v_nombre_sede VARCHAR(130);
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, (
        SELECT academico_test.fn_periodo_establecimiento(g.FK_TPERIODO_ACADEMICO)
          FROM academico_test.TGRADO g WHERE g.PK_TGRADO = p_pk));
    -- Nombre del grado (si el pk no corresponde a ninguna fila, queda NULL y
    -- los mensajes de bloqueo de abajo caen al texto generico via COALESCE).
    -- Nombre de la sede, para la etiqueta de auditoria de abajo.
    SELECT g.NOMBRE, s.NOMBRE INTO v_nombre_grado, v_nombre_sede
      FROM academico_test.TGRADO g
      JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE g.PK_TGRADO = p_pk;
    -- Bloqueo por dependencias (solo filas activas), de lo mas especifico a lo general.
    IF EXISTS (
        SELECT 1 FROM academico_test.TMATRICULA m
          JOIN academico_test.TGRUPO g ON g.PK_TGRUPO = m.FK_TGRUPO AND g.ACTIVE = TRUE
         WHERE g.FK_TGRADO = p_pk AND m.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el grado "%": existen estudiantes matriculados',
            COALESCE(v_nombre_grado, p_pk::TEXT) USING ERRCODE = '23503';
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.THORARIO h
          JOIN academico_test.TGRUPO g ON g.PK_TGRUPO = h.FK_TGRUPO AND g.ACTIVE = TRUE
         WHERE g.FK_TGRADO = p_pk AND h.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el grado "%": existen horarios configurados',
            COALESCE(v_nombre_grado, p_pk::TEXT) USING ERRCODE = '23503';
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.TPLAN pl WHERE pl.FK_TGRADO = p_pk AND pl.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el grado "%": existe un plan de estudio asociado',
            COALESCE(v_nombre_grado, p_pk::TEXT) USING ERRCODE = '23503';
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.TGRUPO g WHERE g.FK_TGRADO = p_pk AND g.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el grado "%": existen grupos activos',
            COALESCE(v_nombre_grado, p_pk::TEXT) USING ERRCODE = '23503';
    END IF;
    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        format('Eliminación del grado %s en la sede %s',
            COALESCE(v_nombre_grado, p_pk::TEXT), COALESCE(v_nombre_sede, 'desconocida')),
        academico_test.fn_periodo_establecimiento((
            SELECT FK_TPERIODO_ACADEMICO FROM academico_test.TGRADO WHERE PK_TGRADO = p_pk))
    );

    -- Cascade: el criterio de promocion override del grado (POR_DEFECTO='N') y sus
    -- obligatorias son propiedad del grado, se dan de baja con el.
    UPDATE academico_test.TCRITERIO_PROMOCION_ASIGNATURA_OBLIGATORIA
       SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE ACTIVE = TRUE AND FK_TCRITERIO_PROMOCION IN (
         SELECT PK_TCRITERIO_PROMOCION FROM academico_test.TCRITERIO_PROMOCION
          WHERE FK_TGRADO = p_pk AND ACTIVE = TRUE
     );
    UPDATE academico_test.TCRITERIO_PROMOCION SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TGRADO = p_pk AND ACTIVE = TRUE;
    UPDATE academico_test.TGRADO SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TGRADO = p_pk AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN
        IF v_nombre_grado IS NOT NULL THEN
            RAISE EXCEPTION 'El grado "%" ya esta inactivo', v_nombre_grado USING ERRCODE = 'P0002';
        ELSE
            RAISE EXCEPTION 'El grado seleccionado no existe' USING ERRCODE = 'P0002';
        END IF;
    END IF;
    RETURN p_pk;
END;
$$;

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
    v_tmp_nombre VARCHAR(130); v_nombre_director VARCHAR(200); v_nombre_sede VARCHAR(130);
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, (
        SELECT academico_test.fn_periodo_establecimiento(g.FK_TPERIODO_ACADEMICO)
          FROM academico_test.TGRADO g WHERE g.PK_TGRADO = p_fk_grado));
    IF p_fk_grado IS NULL OR NULLIF(TRIM(p_nombre),'') IS NULL OR p_fk_modelo_pedagogico IS NULL
       OR p_capacidad IS NULL THEN
        RAISE EXCEPTION 'Faltan campos obligatorios del grupo' USING ERRCODE = '22023';
    END IF;
    IF p_capacidad <= 0 THEN
        RAISE EXCEPTION 'La capacidad del grupo debe ser mayor a 0' USING ERRCODE = '22023';
    END IF;
    -- Jornada y sede desde el periodo del grado (el grado debe estar activo).
    -- v_nombre_sede alimenta la etiqueta de auditoria de mas abajo.
    SELECT pa.FK_TLV_JORNADA, pa.FK_TSEDE, s.NOMBRE INTO v_jornada, v_sede, v_nombre_sede
      FROM academico_test.TGRADO g
      JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE g.PK_TGRADO = p_fk_grado AND g.ACTIVE = TRUE;
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
    RETURN v_id;
END;
$$;

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
    v_tmp_nombre VARCHAR(130); v_nombre_director VARCHAR(200); v_nombre_sede VARCHAR(130);
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, (
        SELECT academico_test.fn_periodo_establecimiento(g.FK_TPERIODO_ACADEMICO)
          FROM academico_test.TGRUPO gr JOIN academico_test.TGRADO g ON g.PK_TGRADO = gr.FK_TGRADO
         WHERE gr.PK_TGRUPO = p_pk));
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
    -- Nombre de la sede del grado, para la etiqueta de auditoria de abajo.
    SELECT s.NOMBRE INTO v_nombre_sede
      FROM academico_test.TGRADO g
      JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE g.PK_TGRADO = r.FK_TGRADO;
    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        format('Actualización del grupo %s en la sede %s', v_nombre, v_nombre_sede),
        academico_test.fn_periodo_establecimiento((
            SELECT g.FK_TPERIODO_ACADEMICO FROM academico_test.TGRADO g WHERE g.PK_TGRADO = r.FK_TGRADO))
    );

    UPDATE academico_test.TGRUPO SET
        NOMBRE = v_nombre,
        FK_TLV_MODELO_PEDAGOGICO = COALESCE(p_fk_modelo_pedagogico, FK_TLV_MODELO_PEDAGOGICO),
        CAPACIDAD = COALESCE(p_capacidad, CAPACIDAD),
        FK_TFUNCIONARIO = COALESCE(p_fk_funcionario, FK_TFUNCIONARIO),
        MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TGRUPO = p_pk;
    RETURN p_pk;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_grupo_soft_delete(p_pk BIGINT, p_pk_usuario_solicitante BIGINT)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_n INT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_nombre_grupo VARCHAR(130);
    v_nombre_sede VARCHAR(130);
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, (
        SELECT academico_test.fn_periodo_establecimiento(g.FK_TPERIODO_ACADEMICO)
          FROM academico_test.TGRUPO gr JOIN academico_test.TGRADO g ON g.PK_TGRADO = gr.FK_TGRADO
         WHERE gr.PK_TGRUPO = p_pk));
    -- Nombre de la sede, para la etiqueta de auditoria de abajo.
    SELECT gr.NOMBRE, s.NOMBRE INTO v_nombre_grupo, v_nombre_sede
      FROM academico_test.TGRUPO gr
      JOIN academico_test.TGRADO g ON g.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE gr.PK_TGRUPO = p_pk;
    -- Bloqueo por dependencias (solo filas activas).
    IF EXISTS (
        SELECT 1 FROM academico_test.TMATRICULA m WHERE m.FK_TGRUPO = p_pk AND m.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el grupo "%": existen estudiantes matriculados',
            COALESCE(v_nombre_grupo, p_pk::TEXT) USING ERRCODE = '23503';
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.TDOCENTE_ASIGNATURA da WHERE da.FK_TGRUPO = p_pk AND da.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el grupo "%": existen asignaciones academicas asociadas',
            COALESCE(v_nombre_grupo, p_pk::TEXT) USING ERRCODE = '23503';
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.THORARIO h WHERE h.FK_TGRUPO = p_pk AND h.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el grupo "%": existen horarios configurados',
            COALESCE(v_nombre_grupo, p_pk::TEXT) USING ERRCODE = '23503';
    END IF;
    -- Asistencia registrada: protege informacion historica (no se limita a
    -- matriculas activas, la asistencia queda como registro aunque el estudiante
    -- ya no este matriculado en el grupo).
    IF EXISTS (
        SELECT 1 FROM academico_test.TASISTENCIA ta
          JOIN academico_test.TMATRICULA m ON m.PK_TMATRICULA = ta.FK_TMATRICULA
         WHERE m.FK_TGRUPO = p_pk AND ta.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el grupo "%": existen registros de asistencia asociados',
            COALESCE(v_nombre_grupo, p_pk::TEXT) USING ERRCODE = '23503';
    END IF;
    -- Procesos academicos activos: calificaciones ya registradas para estudiantes del grupo.
    IF EXISTS (
        SELECT 1 FROM academico_test.TASIGNATURA_NOTA an
          JOIN academico_test.TMATRICULA m ON m.PK_TMATRICULA = an.FK_TMATRICULA
         WHERE m.FK_TGRUPO = p_pk AND an.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el grupo "%": existen calificaciones registradas para sus estudiantes',
            COALESCE(v_nombre_grupo, p_pk::TEXT) USING ERRCODE = '23503';
    END IF;
    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        format('Eliminación del grupo %s en la sede %s',
            COALESCE(v_nombre_grupo, p_pk::TEXT), COALESCE(v_nombre_sede, 'desconocida')),
        academico_test.fn_periodo_establecimiento((
            SELECT g.FK_TPERIODO_ACADEMICO FROM academico_test.TGRUPO gr
              JOIN academico_test.TGRADO g ON g.PK_TGRADO = gr.FK_TGRADO
             WHERE gr.PK_TGRUPO = p_pk))
    );

    UPDATE academico_test.TGRUPO SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TGRUPO = p_pk AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN
        IF v_nombre_grupo IS NOT NULL THEN
            RAISE EXCEPTION 'El grupo "%" ya esta inactivo', v_nombre_grupo USING ERRCODE = 'P0002';
        ELSE
            RAISE EXCEPTION 'El grupo seleccionado no existe' USING ERRCODE = 'P0002';
        END IF;
    END IF;
    RETURN p_pk;
END;
$$;

-- ===========================================================================
-- fn_grado_listar: consolidada aqui para dejar el modulo autocontenido.
-- No tiene RAISE EXCEPTION (no le tocaba nada a este archivo por su nombre),
-- pero SI cambio de firma/cuerpo entre la creacion del modulo (V43, sin
-- paginacion) y V99: V78__fix_grade_module.sql le agrego p_pk_usuario
-- (visibilidad via fn_periodo_usuario_puede_ver) y despues, en el mismo V78,
-- p_sort_by/p_sort_dir (whitelist de columna ordenable + direccion, mismo
-- patron que fn_periodo_listar). No hay ninguna migracion posterior a V78 y
-- anterior a V100 que la vuelva a tocar, asi que este es su estado vigente
-- justo antes de V100. Se copia tal cual de V78 (DROP FUNCTION IF EXISTS de
-- las firmas previas incluido, porque la firma si cambio).
-- ===========================================================================

DROP FUNCTION IF EXISTS academico_test.fn_grado_listar(BIGINT, TEXT, INT, INT);
DROP FUNCTION IF EXISTS academico_test.fn_grado_listar(BIGINT, TEXT, INT, INT, BIGINT);
DROP FUNCTION IF EXISTS academico_test.fn_grado_listar(BIGINT, TEXT, INT, INT, BIGINT, TEXT, TEXT);

CREATE OR REPLACE FUNCTION academico_test.fn_grado_listar(
    p_fk_periodo BIGINT,
    p_filtro     TEXT DEFAULT NULL,
    p_page_index INT  DEFAULT 0,
    p_page_size  INT  DEFAULT 10,
    p_pk_usuario BIGINT DEFAULT NULL,
    p_sort_by    TEXT DEFAULT NULL,
    p_sort_dir   TEXT DEFAULT NULL
)
RETURNS TABLE (
    id BIGINT,
    nombre VARCHAR,
    grado VARCHAR,
    teaching_level_id BIGINT,
    teaching_level_name VARCHAR,
    grado_siguiente VARCHAR,
    grado_siguiente_name VARCHAR,
    tiene_grado_siguiente BOOLEAN,
    total_count BIGINT,
    -- Antes solo exponia NOMBRE (duplicado en nombre/grado) — el select de
    -- Grado del alta de matricula (Sede -> Jornada -> Grado -> Grupo)
    -- necesita el codigo numerico para pasarlo a fn_matricula_listar(p_grade),
    -- que filtra por g.CODIGO::INT (ver fn_matricula_listar). Aditivo, al
    -- final del RETURNS TABLE (mismo criterio que fn_periodo_eval_listar).
    codigo INT
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_col TEXT;
    v_dir TEXT;
BEGIN
    v_col := CASE lower(coalesce(p_sort_by, ''))
        WHEN 'nombre'             THEN 'g.NOMBRE'
        WHEN 'grado'              THEN 'g.NOMBRE'
        WHEN 'teachinglevelname'  THEN 'ne.NOMBRE'
        WHEN 'gradosiguientename' THEN 'gs.NOMBRE'
        ELSE 'g.NOMBRE'
    END;

    v_dir := CASE
        WHEN lower(coalesce(p_sort_dir, '')) = 'desc'
        THEN 'DESC'
        ELSE 'ASC'
    END;

    RETURN QUERY EXECUTE format($q$
        SELECT
            g.PK_TGRADO,
            g.NOMBRE,
            g.NOMBRE,
            g.FK_TNIVEL_ENSENANZA,
            ne.NOMBRE,
            gs.VALOR,
            gs.NOMBRE,
            (g.TIENE_GRADO_SIGUIENTE = 'S'),
            count(*) OVER()::BIGINT AS total_count,
            NULLIF(g.CODIGO,'')::INT

        FROM academico_test.TGRADO g

        JOIN academico_test.TNIVEL_ENSENANZA ne
            ON ne.PK_NIVEL_ENSENANZA = g.FK_TNIVEL_ENSENANZA

        LEFT JOIN academico_test.TLISTA_VALOR gs
            ON gs.PK_LISTA_VALOR = g.FK_TLV_GRADO_SIGUIENTE

        WHERE g.FK_TPERIODO_ACADEMICO = $1
          AND g.ACTIVE = TRUE
          AND academico_test.fn_periodo_usuario_puede_ver($5, $1)
          AND ($2 IS NULL OR g.NOMBRE ILIKE '%%' || $2 || '%%')

        ORDER BY %s %s, g.PK_TGRADO

        LIMIT NULLIF($4, 0)
        OFFSET COALESCE($3, 0) * COALESCE(NULLIF($4, 0), 0)

    $q$, v_col, v_dir)
    USING
        p_fk_periodo,
        NULLIF(TRIM(p_filtro), ''),
        p_page_index,
        p_page_size,
        p_pk_usuario;
END;
$$;

-- Consolidado desde V113 (fn_grupo_bulk_delete.sql): nueva capacidad,
-- eliminar varios grupos (TGRUPO) de un grado en un solo lote. Mismo patron
-- que fn_periodo_bulk_delete/fn_escala_valoracion_bulk_delete: delega en
-- fn_grupo_soft_delete por fila (que ya trae toda la validacion de permisos,
-- existencia y bloqueo por matriculas/horarios/asignaciones/calificaciones) y
-- captura la excepcion para un resultado parcial.
CREATE OR REPLACE FUNCTION academico_test.fn_grupo_bulk_delete(
    p_ids bigint[],
    p_pk_usuario_solicitante bigint
)
RETURNS TABLE(id bigint, eliminado boolean, error_code text, error_mensaje text)
LANGUAGE plpgsql AS $$
DECLARE v_id BIGINT; v_state TEXT; v_msg TEXT;
BEGIN
    IF p_ids IS NULL THEN RETURN; END IF;
    FOREACH v_id IN ARRAY p_ids LOOP
        BEGIN
            PERFORM academico_test.fn_grupo_soft_delete(v_id, p_pk_usuario_solicitante);
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
$$;
