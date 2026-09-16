-- Grado/Grupo — funciones consolidadas (última versión)
SET search_path TO academico_test, public;

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
        academico_test.fn_periodo_establecimiento(p_fk_periodo),
        academico_test.fn_periodo_sede(p_fk_periodo),
        academico_test.fn_periodo_jornada(p_fk_periodo), 'CREAR'
    );

    -- Nombre de sede para la etiqueta de auditoria (el EE ya viaja aparte como contexto de fn_audit_declarar).
    SELECT s.NOMBRE INTO v_nombre_sede
      FROM academico_test.TSEDE s
     WHERE s.PK_TSEDE = academico_test.fn_periodo_sede(p_fk_periodo);

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
    v_periodo_id BIGINT;
BEGIN
    SELECT g.FK_TPERIODO_ACADEMICO INTO v_periodo_id
      FROM academico_test.TGRADO g WHERE g.PK_TGRADO = p_pk;
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante,
        academico_test.fn_periodo_establecimiento(v_periodo_id),
        academico_test.fn_periodo_sede(v_periodo_id),
        academico_test.fn_periodo_jornada(v_periodo_id), 'EDITAR');

    -- Nombre de sede para la etiqueta de auditoria (el EE ya viaja aparte como contexto de fn_audit_declarar).
    SELECT s.NOMBRE INTO v_nombre_sede
      FROM academico_test.TSEDE s
     WHERE s.PK_TSEDE = academico_test.fn_periodo_sede(v_periodo_id);

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
    -- El codigo no se cambia en edicion (queda el derivado del catalogo al crear).
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
    v_periodo_id BIGINT;
BEGIN
    SELECT g.FK_TPERIODO_ACADEMICO INTO v_periodo_id
      FROM academico_test.TGRADO g WHERE g.PK_TGRADO = p_pk;
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante,
        academico_test.fn_periodo_establecimiento(v_periodo_id),
        academico_test.fn_periodo_sede(v_periodo_id),
        academico_test.fn_periodo_jornada(v_periodo_id), 'ELIMINAR');
    -- Si el pk no existe queda NULL, y los mensajes de bloqueo de abajo caen al texto generico via COALESCE.
    SELECT NOMBRE INTO v_nombre_grado FROM academico_test.TGRADO WHERE PK_TGRADO = p_pk;
    SELECT s.NOMBRE INTO v_nombre_sede
      FROM academico_test.TSEDE s
     WHERE s.PK_TSEDE = academico_test.fn_periodo_sede(v_periodo_id);
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

    -- El criterio de promocion override del grado (POR_DEFECTO='N') y sus obligatorias son
    -- propiedad del grado: se dan de baja con el.
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
    -- Aditivo al final: el select de Grado del alta de matricula necesita el codigo
    -- numerico para pasarlo a fn_matricula_listar(p_grade), que filtra por g.CODIGO::INT.
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
          AND academico_test.fn_periodo_puede_ver($5, $1)
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

CREATE OR REPLACE FUNCTION academico_test.fn_grado_obtener(
    p_fk_grado BIGINT, p_pk_usuario BIGINT DEFAULT NULL
)
RETURNS TABLE (id BIGINT, nombre VARCHAR, grado VARCHAR, teaching_level_id BIGINT,
               teaching_level_name VARCHAR, grado_siguiente VARCHAR, grado_siguiente_name VARCHAR,
               tiene_grado_siguiente BOOLEAN)
LANGUAGE sql STABLE AS $$
    SELECT g.PK_TGRADO, g.NOMBRE, g.CODIGO, g.FK_TNIVEL_ENSENANZA, ne.NOMBRE,
           gs.VALOR, gs.NOMBRE, (g.TIENE_GRADO_SIGUIENTE = 'S')
      FROM academico_test.TGRADO g
      JOIN academico_test.TNIVEL_ENSENANZA ne ON ne.PK_NIVEL_ENSENANZA = g.FK_TNIVEL_ENSENANZA
      LEFT JOIN academico_test.TLISTA_VALOR gs ON gs.PK_LISTA_VALOR = g.FK_TLV_GRADO_SIGUIENTE
     WHERE g.PK_TGRADO = p_fk_grado AND g.ACTIVE = TRUE
       AND academico_test.fn_periodo_puede_ver(p_pk_usuario, g.FK_TPERIODO_ACADEMICO);
$$;

-- Cada id se procesa en su propio bloque BEGIN/EXCEPTION: un fallo no revierte al resto.
DROP FUNCTION IF EXISTS academico_test.fn_grado_bulk_delete(BIGINT[], BIGINT);
CREATE OR REPLACE FUNCTION academico_test.fn_grado_bulk_delete(
    p_ids BIGINT[], p_pk_usuario_solicitante BIGINT
)
RETURNS TABLE (id BIGINT, eliminado BOOLEAN, error_code TEXT, error_mensaje TEXT)
LANGUAGE plpgsql AS $$
DECLARE v_id BIGINT; v_state TEXT; v_msg TEXT;
BEGIN
    -- Gate grueso; el fino por establecimiento lo aplica fn_grado_soft_delete.
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, NULL);
    IF p_ids IS NULL THEN RETURN; END IF;
    FOREACH v_id IN ARRAY p_ids LOOP
        BEGIN
            PERFORM academico_test.fn_grado_soft_delete(v_id, p_pk_usuario_solicitante);
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
    -- Se resuelven antes del gate porque el scope por sede+jornada los necesita.
    SELECT pa.PK_TPERIODO_ACADEMICO, pa.FK_TLV_JORNADA, pa.FK_TSEDE
      INTO v_periodo_id, v_jornada, v_sede
      FROM academico_test.TGRADO g JOIN academico_test.TPERIODO_ACADEMICO pa
        ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
     WHERE g.PK_TGRADO = p_fk_grado AND g.ACTIVE = TRUE;
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante,
        academico_test.fn_periodo_establecimiento(v_periodo_id),
        v_sede, v_jornada, 'CREAR');

    -- Nombre de sede para la etiqueta de auditoria (el EE ya viaja aparte como contexto de fn_audit_declarar).
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
    v_tmp_nombre VARCHAR(130); v_nombre_director VARCHAR(200);
    v_nombre_sede VARCHAR(130);
    v_periodo_id BIGINT; v_jornada_grupo BIGINT;
BEGIN
    -- La jornada propia del grupo es la autoritativa para el gate, no la del periodo.
    SELECT g.FK_TPERIODO_ACADEMICO, gr.FK_TLV_JORNADA
      INTO v_periodo_id, v_jornada_grupo
      FROM academico_test.TGRUPO gr JOIN academico_test.TGRADO g ON g.PK_TGRADO = gr.FK_TGRADO
     WHERE gr.PK_TGRUPO = p_pk;
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante,
        academico_test.fn_periodo_establecimiento(v_periodo_id),
        academico_test.fn_periodo_sede(v_periodo_id),
        v_jornada_grupo, 'EDITAR');

    -- Nombre de sede para la etiqueta de auditoria (el EE ya viaja aparte como contexto de fn_audit_declarar).
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
    v_periodo_id BIGINT; v_jornada_grupo BIGINT;
BEGIN
    -- Jornada propia del grupo, no la del periodo.
    SELECT g.FK_TPERIODO_ACADEMICO, gr.FK_TLV_JORNADA
      INTO v_periodo_id, v_jornada_grupo
      FROM academico_test.TGRUPO gr JOIN academico_test.TGRADO g ON g.PK_TGRADO = gr.FK_TGRADO
     WHERE gr.PK_TGRUPO = p_pk;
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante,
        academico_test.fn_periodo_establecimiento(v_periodo_id),
        academico_test.fn_periodo_sede(v_periodo_id),
        v_jornada_grupo, 'ELIMINAR');
    SELECT NOMBRE INTO v_nombre_grupo FROM academico_test.TGRUPO WHERE PK_TGRUPO = p_pk;

    -- Nombre de sede para la etiqueta de auditoria (el EE ya viaja aparte como contexto de fn_audit_declarar).
    SELECT s.NOMBRE INTO v_nombre_sede
      FROM academico_test.TSEDE s
     WHERE s.PK_TSEDE = academico_test.fn_periodo_sede(v_periodo_id);
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
    -- No se limita a matriculas activas: la asistencia queda como registro historico
    -- aunque el estudiante ya no este matriculado en el grupo.
    IF EXISTS (
        SELECT 1 FROM academico_test.TASISTENCIA ta
          JOIN academico_test.TMATRICULA m ON m.PK_TMATRICULA = ta.FK_TMATRICULA
         WHERE m.FK_TGRUPO = p_pk AND ta.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el grupo "%": existen registros de asistencia asociados',
            COALESCE(v_nombre_grupo, p_pk::TEXT) USING ERRCODE = '23503';
    END IF;
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

-- Incluye modelo pedagogico y el rol del director en la sede, para reconstruir el formulario.
DROP FUNCTION IF EXISTS academico_test.fn_grupo_obtener(BIGINT);
CREATE OR REPLACE FUNCTION academico_test.fn_grupo_obtener(
    p_pk BIGINT, p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS TABLE (id BIGINT, codigo VARCHAR, jornada VARCHAR, jornada_name VARCHAR,
               director_id BIGINT, director_name TEXT, director_rol_id BIGINT,
               metodologia_id BIGINT, metodologia VARCHAR, metodologia_name VARCHAR,
               cupo NUMERIC, grado_id BIGINT)
LANGUAGE sql STABLE AS $$
    SELECT gr.PK_TGRUPO, gr.NOMBRE, jor.VALOR, jor.NOMBRE,
           gr.FK_TFUNCIONARIO,
           TRIM(regexp_replace(
               concat_ws(' ', du.PRIMER_NOMBRE, du.SEGUNDO_NOMBRE, du.PRIMER_APELLIDO, du.SEGUNDO_APELLIDO),
               '\s+', ' ', 'g')),
           (SELECT su.FK_TROL FROM academico_test.TSEDE_USUARIO su
             JOIN academico_test.TGRADO g2 ON g2.PK_TGRADO = gr.FK_TGRADO
             JOIN academico_test.TPERIODO_ACADEMICO pa2 ON pa2.PK_TPERIODO_ACADEMICO = g2.FK_TPERIODO_ACADEMICO
            WHERE su.FK_TUSUARIO = df.FK_TUSUARIO AND su.FK_TSEDE = pa2.FK_TSEDE
              AND su.ACTIVE = TRUE AND su.TLV_ESTADO = 'ACTIVO'
            LIMIT 1),
           gr.FK_TLV_MODELO_PEDAGOGICO, met.VALOR, met.NOMBRE, gr.CAPACIDAD, gr.FK_TGRADO
      FROM academico_test.TGRUPO gr
      JOIN academico_test.TLISTA_VALOR jor      ON jor.PK_LISTA_VALOR = gr.FK_TLV_JORNADA
      LEFT JOIN academico_test.TLISTA_VALOR met ON met.PK_LISTA_VALOR = gr.FK_TLV_MODELO_PEDAGOGICO
      LEFT JOIN academico_test.TFUNCIONARIO df  ON df.PK_TFUNCIONARIO = gr.FK_TFUNCIONARIO
      LEFT JOIN academico_test.TUSUARIO du      ON du.PK_TUSUARIO = df.FK_TUSUARIO
     WHERE gr.PK_TGRUPO = p_pk AND gr.ACTIVE = TRUE
       AND academico_test.fn_periodo_puede_ver(p_pk_usuario_solicitante,
             (SELECT g2.FK_TPERIODO_ACADEMICO FROM academico_test.TGRADO g2 WHERE g2.PK_TGRADO = gr.FK_TGRADO));
$$;

-- Delega en fn_grupo_soft_delete por fila y captura la excepcion para devolver resultado parcial.
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

DROP FUNCTION IF EXISTS academico_test.fn_grupo_listar(BIGINT, TEXT, INT, INT);
DROP FUNCTION IF EXISTS academico_test.fn_grupo_listar(BIGINT, TEXT, INT, INT, BIGINT);
DROP FUNCTION IF EXISTS academico_test.fn_grupo_listar(BIGINT, TEXT, INT, INT, BIGINT, TEXT, TEXT);
CREATE OR REPLACE FUNCTION academico_test.fn_grupo_listar(
    p_fk_grado BIGINT, p_filtro TEXT DEFAULT NULL,
    p_page_index INT DEFAULT 0, p_page_size INT DEFAULT 10,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL,
    -- Columna del front (id) + direccion ('asc'/'desc').
    p_sort_by TEXT DEFAULT NULL,
    p_sort_dir TEXT DEFAULT NULL
)
RETURNS TABLE (id BIGINT, codigo VARCHAR, jornada VARCHAR, jornada_name VARCHAR, director_id BIGINT,
               director_name TEXT, metodologia VARCHAR, metodologia_name VARCHAR, cupo NUMERIC, total_count BIGINT)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_col TEXT;
    v_dir TEXT;
BEGIN
    v_col := CASE lower(coalesce(p_sort_by, ''))
        WHEN 'codigo'          THEN 'gr.NOMBRE'
        WHEN 'jornadaname'     THEN 'jor.NOMBRE'
        WHEN 'directorname'    THEN 'director_name'
        WHEN 'metodologianame' THEN 'met.NOMBRE'
        WHEN 'cupo'            THEN 'gr.CAPACIDAD'
        ELSE 'gr.NOMBRE'
    END;
    v_dir := CASE WHEN lower(coalesce(p_sort_dir, '')) = 'desc' THEN 'DESC' ELSE 'ASC' END;

    RETURN QUERY EXECUTE format($q$
        SELECT gr.PK_TGRUPO, gr.NOMBRE, jor.VALOR, jor.NOMBRE, gr.FK_TFUNCIONARIO,
               TRIM(regexp_replace(
                   concat_ws(' ', du.PRIMER_NOMBRE, du.SEGUNDO_NOMBRE, du.PRIMER_APELLIDO, du.SEGUNDO_APELLIDO),
                   '\s+', ' ', 'g')) AS director_name,
               met.VALOR, met.NOMBRE, gr.CAPACIDAD,
               count(*) OVER()::BIGINT
          FROM academico_test.TGRUPO gr
          JOIN academico_test.TLISTA_VALOR jor      ON jor.PK_LISTA_VALOR = gr.FK_TLV_JORNADA
          LEFT JOIN academico_test.TLISTA_VALOR met ON met.PK_LISTA_VALOR = gr.FK_TLV_MODELO_PEDAGOGICO
          LEFT JOIN academico_test.TFUNCIONARIO df  ON df.PK_TFUNCIONARIO = gr.FK_TFUNCIONARIO
          LEFT JOIN academico_test.TUSUARIO du      ON du.PK_TUSUARIO = df.FK_TUSUARIO
         WHERE gr.FK_TGRADO = $1 AND gr.ACTIVE = TRUE
           AND academico_test.fn_periodo_puede_ver($5,
                 (SELECT g.FK_TPERIODO_ACADEMICO FROM academico_test.TGRADO g WHERE g.PK_TGRADO = $1))
           AND ($2 IS NULL OR gr.NOMBRE ILIKE '%%' || $2 || '%%')
         ORDER BY %s %s, gr.PK_TGRUPO
         LIMIT NULLIF($4, 0)
        OFFSET COALESCE($3, 0) * COALESCE(NULLIF($4, 0), 0)
    $q$, v_col, v_dir)
    USING p_fk_grado, NULLIF(TRIM(p_filtro),''), p_page_index, p_page_size, p_pk_usuario_solicitante;
END;
$$;

DROP FUNCTION IF EXISTS academico_test.fn_nivel_ensenanza_listar();
CREATE OR REPLACE FUNCTION academico_test.fn_nivel_ensenanza_listar(
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS TABLE (id BIGINT, codigo VARCHAR, nombre VARCHAR)
LANGUAGE sql STABLE AS $$
    SELECT PK_NIVEL_ENSENANZA, CODIGO, NOMBRE
      FROM academico_test.TNIVEL_ENSENANZA
     WHERE ACTIVE = TRUE
     ORDER BY NOMBRE;
$$;

-- DISTINCT porque un usuario puede tener varias filas en TSEDE_USUARIO (por rol/jornada).
-- DROP de firmas previas (con p_fk_rol y sin p_pk_usuario) por si quedaron aplicadas.
DROP FUNCTION IF EXISTS academico_test.fn_funcionario_sede_listar(BIGINT, BIGINT, TEXT);
DROP FUNCTION IF EXISTS academico_test.fn_funcionario_sede_listar(BIGINT, TEXT);
CREATE OR REPLACE FUNCTION academico_test.fn_funcionario_sede_listar(
    p_fk_sede BIGINT, p_filtro TEXT DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS TABLE (id BIGINT, nombre TEXT, identificacion VARCHAR)
LANGUAGE sql STABLE AS $$
    SELECT DISTINCT f.PK_TFUNCIONARIO,
           TRIM(regexp_replace(
               concat_ws(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE, u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO),
               '\s+', ' ', 'g')) AS nombre,
           u.IDENTIFICACION
      FROM academico_test.TFUNCIONARIO f
      JOIN academico_test.TUSUARIO u ON u.PK_TUSUARIO = f.FK_TUSUARIO
      JOIN academico_test.TSEDE_USUARIO su ON su.FK_TUSUARIO = f.FK_TUSUARIO
     WHERE su.FK_TSEDE = p_fk_sede
       AND su.ACTIVE = TRUE AND su.TLV_ESTADO = 'ACTIVO'
       AND f.ACTIVE = TRUE
       AND (NULLIF(TRIM(p_filtro),'') IS NULL
            OR u.PRIMER_NOMBRE   ILIKE '%' || p_filtro || '%'
            OR u.PRIMER_APELLIDO ILIKE '%' || p_filtro || '%'
            OR u.SEGUNDO_APELLIDO ILIKE '%' || p_filtro || '%'
            OR u.IDENTIFICACION  ILIKE '%' || p_filtro || '%')
     ORDER BY nombre;
$$;

-- Devuelve { schedule: { entries: [...] }, promotionCriteria: {...} }.
DROP FUNCTION IF EXISTS academico_test.fn_grade_config_obtener(BIGINT);
CREATE OR REPLACE FUNCTION academico_test.fn_grade_config_obtener(
    p_fk_grado BIGINT, p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE v_periodo BIGINT; v_entries jsonb; v_prom jsonb; v_req jsonb; c RECORD;
BEGIN
    SELECT FK_TPERIODO_ACADEMICO INTO v_periodo FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_grado;
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'grupoId', h.grupo_id, 'planItemId', h.plan_item_id,
             'diaId', h.dia_id, 'bloque', h.bloque)), '[]'::jsonb)
      INTO v_entries FROM academico_test.fn_horario_listar(p_fk_grado, NULL, p_pk_usuario_solicitante) h;
    -- fn_criterio_prom_obtener resuelve el override del grado o el default del periodo.
    SELECT * INTO c FROM academico_test.fn_criterio_prom_obtener(v_periodo, p_fk_grado, p_pk_usuario_solicitante) LIMIT 1;
    IF c.id IS NOT NULL THEN
        SELECT COALESCE(jsonb_agg(COALESCE(a.subject_id, a.area_id)::text), '[]'::jsonb)
          INTO v_req FROM academico_test.fn_criterio_prom_asig_listar(c.id) a;
        v_prom := jsonb_build_object(
            'curriculumNode', c.curriculum_node,
            'maxFailedRecovery', c.max_failed_recovery,
            'absencePercentage', c.absence_percentage,
            'maxLeveledSubjects', c.max_leveled_subjects,
            'applyAverageApproval', (c.apply_average_approval = 'S'),
            'basePercentage', c.base_percentage,
            'minimumSubjectPercentage', c.minimum_subject_percentage,
            'maxFailedForAverage', c.max_failed_for_average,
            'requiredSubjects', v_req
        );
    END IF;
    RETURN jsonb_build_object(
        'schedule', jsonb_build_object('entries', v_entries),
        'promotionCriteria', v_prom
    );
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_grade_config_guardar(
    p_fk_grado  BIGINT,
    p_schedule  jsonb DEFAULT NULL,
    p_promotion jsonb DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_periodo BIGINT; v_oblig jsonb;
BEGIN
    IF p_schedule IS NOT NULL AND p_schedule ? 'entries' THEN
        PERFORM academico_test.fn_horario_guardar(p_fk_grado, p_schedule->'entries', p_pk_usuario_solicitante);
    END IF;
    IF p_promotion IS NOT NULL THEN
        SELECT FK_TPERIODO_ACADEMICO INTO v_periodo FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_grado;
        -- requiredSubjects llega como array de ids; se remapea a [{asignaturaId}].
        IF p_promotion ? 'requiredSubjects' THEN
            SELECT COALESCE(jsonb_agg(jsonb_build_object('asignaturaId', (x)::bigint)), '[]'::jsonb)
              INTO v_oblig
              FROM jsonb_array_elements_text(p_promotion->'requiredSubjects') x
             WHERE NULLIF(TRIM(x),'') IS NOT NULL;
        END IF;
        PERFORM academico_test.fn_criterio_prom_guardar(
            v_periodo, p_fk_grado,
            NULLIF(TRIM(p_promotion->>'curriculumNode'),'')::academico_test.nodo_curricular,
            NULLIF(p_promotion->>'maxFailedRecovery','')::numeric,
            NULL,  -- p_asignatura_obligatoria (no lo maneja el front)
            CASE lower(p_promotion->>'applyAverageApproval')
                 WHEN 'true' THEN 'S' WHEN 'false' THEN 'N' ELSE NULL END::academico_test.bool_sn,
            NULLIF(p_promotion->>'basePercentage','')::numeric,
            NULLIF(p_promotion->>'minimumSubjectPercentage','')::numeric,
            NULLIF(p_promotion->>'maxFailedForAverage','')::numeric,
            NULLIF(p_promotion->>'absencePercentage','')::numeric,
            NULLIF(p_promotion->>'maxLeveledSubjects','')::numeric,
            v_oblig,
            p_pk_usuario_solicitante
        );
    END IF;
    RETURN p_fk_grado;
END;
$$;

-- Reporte "Grados y grupos" (RN-06/RN-07/RN-10): a diferencia de la pantalla de edicion
-- (fn_grado_listar + fn_grupo_listar por separado), esta funcion exporta ambos niveles
-- juntos para TODOS los grados del periodo. LEFT JOIN a TGRUPO para que un grado sin
-- grupos todavia siga apareciendo (RN-06: estructura vigente del periodo).
CREATE OR REPLACE FUNCTION academico_test.fn_grado_grupo_reporte_listar(
    p_fk_periodo BIGINT,
    p_fk_grado   BIGINT[] DEFAULT NULL,
    p_pk_usuario BIGINT   DEFAULT NULL,
    p_page_index INT      DEFAULT 0,
    p_page_size  INT      DEFAULT 10
)
RETURNS TABLE (
    grado_id BIGINT, grado_name VARCHAR, grado_codigo VARCHAR,
    teaching_level_id BIGINT, teaching_level_name VARCHAR,
    grupo_id BIGINT, grupo_name VARCHAR,
    jornada_id BIGINT, jornada_name VARCHAR,
    director_id BIGINT, director_name TEXT,
    plan_estudio_name VARCHAR, total_count BIGINT
)
LANGUAGE sql STABLE AS $$
    SELECT g.PK_TGRADO, g.NOMBRE, g.CODIGO,
           g.FK_TNIVEL_ENSENANZA, ne.NOMBRE,
           gr.PK_TGRUPO, gr.NOMBRE,
           jor.PK_LISTA_VALOR, jor.NOMBRE,
           df.PK_TFUNCIONARIO,
           NULLIF(TRIM(regexp_replace(
               concat_ws(' ', du.PRIMER_NOMBRE, du.SEGUNDO_NOMBRE, du.PRIMER_APELLIDO, du.SEGUNDO_APELLIDO),
               '\s+', ' ', 'g')), ''),
           plan.NOMBRE,
           count(*) OVER()::BIGINT
      FROM academico_test.TGRADO g
      JOIN academico_test.TNIVEL_ENSENANZA ne ON ne.PK_NIVEL_ENSENANZA = g.FK_TNIVEL_ENSENANZA
 LEFT JOIN academico_test.TGRUPO gr            ON gr.FK_TGRADO = g.PK_TGRADO AND gr.ACTIVE = TRUE
 LEFT JOIN academico_test.TLISTA_VALOR jor     ON jor.PK_LISTA_VALOR = gr.FK_TLV_JORNADA
 LEFT JOIN academico_test.TFUNCIONARIO df      ON df.PK_TFUNCIONARIO = gr.FK_TFUNCIONARIO
 LEFT JOIN academico_test.TUSUARIO du          ON du.PK_TUSUARIO = df.FK_TUSUARIO
 LEFT JOIN LATERAL (
       SELECT p.NOMBRE
         FROM academico_test.TPLAN p
        WHERE p.FK_TGRADO = g.PK_TGRADO AND p.ACTIVE = TRUE
        ORDER BY p.PK_TPLAN
        LIMIT 1
 ) plan ON TRUE
     WHERE g.FK_TPERIODO_ACADEMICO = p_fk_periodo AND g.ACTIVE = TRUE
       AND academico_test.fn_periodo_puede_ver(p_pk_usuario, p_fk_periodo)
       AND (p_fk_grado IS NULL OR CARDINALITY(p_fk_grado) = 0 OR g.PK_TGRADO = ANY(p_fk_grado))
     ORDER BY g.NOMBRE, gr.NOMBRE
     LIMIT NULLIF(p_page_size, 0)
    OFFSET COALESCE(p_page_index, 0) * COALESCE(NULLIF(p_page_size, 0), 0);
$$;
