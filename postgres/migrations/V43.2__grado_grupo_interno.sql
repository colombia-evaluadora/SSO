-- ===========================================================================
-- V43.2 -- Grados y grupos: nucleos _interno
-- ===========================================================================
-- QUE HACE: crear/actualizar/eliminar/listar/obtener de TGRADO y TGRUPO sin
-- permisos. Validan con V43.1 antes de escribir; el gate, el alcance y la
-- auditoria van en V43.3. Al guardar un grupo sincronizan el rol de director
-- y, en preescolar, sus asignaciones (helpers al final, antes en V285).
-- POR QUE AQUI: capa 2 del modulo (V43.1 / V43.2 / V43.3).
-- DEPENDE DE: V22, V43.1; en ejecucion TROL (DIRECTOR_GRUPO, por codigo).
-- ===========================================================================

SET search_path TO academico_test, public;

-- ---------------------------------------------------------------- grado

CREATE OR REPLACE FUNCTION academico_test.fn_grado_crear_interno(
    p_fk_periodo         BIGINT,
    p_fk_nivel           BIGINT,
    p_nombre             VARCHAR,
    p_fk_grado_siguiente BIGINT,
    p_audit              VARCHAR
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_id BIGINT; v_codigo VARCHAR(30); v_nombre VARCHAR(130);
BEGIN
    PERFORM academico_test.fn_grado_validar_campos(p_fk_periodo, p_fk_nivel, p_nombre);
    PERFORM academico_test.fn_grado_validar_periodo(p_fk_periodo);
    PERFORM academico_test.fn_grado_validar_nivel(p_fk_nivel);
    PERFORM academico_test.fn_grado_validar_catalogo(p_nombre);
    PERFORM academico_test.fn_grado_validar_grado_siguiente(p_fk_grado_siguiente);
    SELECT r.codigo, r.nombre INTO v_codigo, v_nombre FROM academico_test.fn_grado_catalogo_resolver(p_nombre) r;
    PERFORM academico_test.fn_grado_validar_unico(p_fk_periodo, 'NOMBRE', v_nombre);
    PERFORM academico_test.fn_grado_validar_unico(p_fk_periodo, 'CODIGO', v_codigo);

    INSERT INTO academico_test.TGRADO (
        CODIGO, NOMBRE, FK_TPERIODO_ACADEMICO, FK_TNIVEL_ENSENANZA,
        FK_TLV_GRADO_SIGUIENTE, TIENE_GRADO_SIGUIENTE, CREATED_BY
    ) VALUES (
        v_codigo, v_nombre, p_fk_periodo, p_fk_nivel, p_fk_grado_siguiente,
        CASE WHEN p_fk_grado_siguiente IS NULL THEN 'N' ELSE 'S' END::academico_test.bool_sn,
        p_audit
    )
    RETURNING PK_TGRADO INTO v_id;
    RETURN v_id;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_grado_crear_interno(BIGINT, BIGINT, VARCHAR, BIGINT, VARCHAR)
    IS 'INTERNO: valida e inserta un grado; CODIGO y NOMBRE salen del catalogo GRADOS. Lo usa fn_grado_crear.';

-- Los NULL conservan el valor actual; el CODIGO no se edita (queda el del catalogo al crear).
CREATE OR REPLACE FUNCTION academico_test.fn_grado_actualizar_interno(
    p_pk                    BIGINT,
    p_fk_nivel              BIGINT,
    p_nombre                VARCHAR,
    p_fk_grado_siguiente    BIGINT,
    p_tiene_grado_siguiente BOOLEAN,
    p_audit                 VARCHAR
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE r academico_test.TGRADO; v_nombre VARCHAR(130); v_fk_sig BIGINT;
BEGIN
    SELECT * INTO r FROM academico_test.TGRADO WHERE PK_TGRADO = p_pk;
    PERFORM academico_test.fn_grado_validar_nombre_no_vacio(p_nombre);
    PERFORM academico_test.fn_grado_validar_nivel(p_fk_nivel);
    v_nombre := COALESCE(p_nombre, r.NOMBRE);
    -- p_tiene_grado_siguiente = FALSE quita el siguiente aunque venga p_fk_grado_siguiente.
    v_fk_sig := CASE WHEN p_tiene_grado_siguiente = FALSE THEN NULL
                     ELSE COALESCE(p_fk_grado_siguiente, r.FK_TLV_GRADO_SIGUIENTE) END;
    PERFORM academico_test.fn_grado_validar_grado_siguiente(v_fk_sig);
    PERFORM academico_test.fn_grado_validar_unico(r.FK_TPERIODO_ACADEMICO, 'NOMBRE', v_nombre, p_pk);

    UPDATE academico_test.TGRADO SET
        FK_TNIVEL_ENSENANZA = COALESCE(p_fk_nivel, FK_TNIVEL_ENSENANZA),
        NOMBRE = v_nombre,
        FK_TLV_GRADO_SIGUIENTE = v_fk_sig,
        TIENE_GRADO_SIGUIENTE = CASE WHEN v_fk_sig IS NULL THEN 'N' ELSE 'S' END::academico_test.bool_sn,
        MODIFIED_BY = p_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TGRADO = p_pk;
    RETURN p_pk;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_grado_actualizar_interno(BIGINT, BIGINT, VARCHAR, BIGINT, BOOLEAN, VARCHAR)
    IS 'INTERNO: valida y actualiza un grado existente y activo. Lo usa fn_grado_actualizar.';

CREATE OR REPLACE FUNCTION academico_test.fn_grado_eliminar_interno(p_pk BIGINT, p_audit VARCHAR)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_nombre VARCHAR(130);
BEGIN
    PERFORM academico_test.fn_grado_validar_eliminable(p_pk);

    -- El criterio de promocion propio del grado (POR_DEFECTO='N') y sus obligatorias se van con el.
    UPDATE academico_test.TCRITERIO_PROMOCION_ASIGNATURA_OBLIGATORIA
       SET ACTIVE = FALSE, MODIFIED_BY = p_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE ACTIVE = TRUE AND FK_TCRITERIO_PROMOCION IN (
         SELECT PK_TCRITERIO_PROMOCION FROM academico_test.TCRITERIO_PROMOCION
          WHERE FK_TGRADO = p_pk AND ACTIVE = TRUE
     );
    UPDATE academico_test.TCRITERIO_PROMOCION SET ACTIVE = FALSE, MODIFIED_BY = p_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TGRADO = p_pk AND ACTIVE = TRUE;
    UPDATE academico_test.TGRADO SET ACTIVE = FALSE, MODIFIED_BY = p_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TGRADO = p_pk AND ACTIVE = TRUE;
    IF NOT FOUND THEN
        SELECT NOMBRE INTO v_nombre FROM academico_test.TGRADO WHERE PK_TGRADO = p_pk;
        IF v_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'El grado "%" ya esta inactivo', v_nombre USING ERRCODE = 'P0002';
        END IF;
        RAISE EXCEPTION 'El grado seleccionado no existe' USING ERRCODE = 'P0002';
    END IF;
    RETURN p_pk;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_grado_eliminar_interno(BIGINT, VARCHAR)
    IS 'INTERNO: baja logica del grado y de su criterio de promocion propio; 23503 si tiene matriculas, horarios, plan o grupos, P0002 si ya estaba inactivo. Lo usa fn_grado_soft_delete.';

CREATE OR REPLACE FUNCTION academico_test.fn_grado_listar_interno(
    p_fk_periodo BIGINT,
    p_filtro     TEXT DEFAULT NULL,
    p_page_index INT  DEFAULT 0,
    p_page_size  INT  DEFAULT 10,
    p_sort_by    TEXT DEFAULT NULL,
    p_sort_dir   TEXT DEFAULT NULL
)
RETURNS TABLE (
    id BIGINT, nombre VARCHAR, grado VARCHAR, teaching_level_id BIGINT, teaching_level_name VARCHAR,
    grado_siguiente VARCHAR, grado_siguiente_name VARCHAR, tiene_grado_siguiente BOOLEAN,
    total_count BIGINT, codigo INT, codigo_texto VARCHAR
)
LANGUAGE plpgsql STABLE AS $$
DECLARE v_col TEXT; v_dir TEXT;
BEGIN
    v_col := CASE lower(coalesce(p_sort_by, ''))
        WHEN 'nombre'             THEN 'g.NOMBRE'
        WHEN 'grado'              THEN 'g.NOMBRE'
        WHEN 'teachinglevelname'  THEN 'ne.NOMBRE'
        WHEN 'gradosiguientename' THEN 'gs.NOMBRE'
        ELSE 'g.NOMBRE'
    END;
    v_dir := CASE WHEN lower(coalesce(p_sort_dir, '')) = 'desc' THEN 'DESC' ELSE 'ASC' END;

    -- p_page_size 0/NULL = sin limite.
    RETURN QUERY EXECUTE format($q$
        SELECT g.PK_TGRADO, g.NOMBRE, g.NOMBRE, g.FK_TNIVEL_ENSENANZA, ne.NOMBRE,
               gs.VALOR, gs.NOMBRE, (g.TIENE_GRADO_SIGUIENTE = 'S'),
               count(*) OVER()::BIGINT, NULLIF(g.CODIGO,'')::INT, g.CODIGO
          FROM academico_test.TGRADO g
          JOIN academico_test.TNIVEL_ENSENANZA ne ON ne.PK_NIVEL_ENSENANZA = g.FK_TNIVEL_ENSENANZA
          LEFT JOIN academico_test.TLISTA_VALOR gs ON gs.PK_LISTA_VALOR = g.FK_TLV_GRADO_SIGUIENTE
         WHERE g.FK_TPERIODO_ACADEMICO = $1 AND g.ACTIVE = TRUE
           AND ($2 IS NULL OR g.NOMBRE ILIKE '%%' || $2 || '%%')
         ORDER BY %s %s, g.PK_TGRADO
         LIMIT NULLIF($4, 0)
        OFFSET COALESCE($3, 0) * COALESCE(NULLIF($4, 0), 0)
    $q$, v_col, v_dir)
    USING p_fk_periodo, NULLIF(TRIM(p_filtro), ''), p_page_index, p_page_size;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_grado_listar_interno(BIGINT, TEXT, INT, INT, TEXT, TEXT)
    IS 'INTERNO: grados activos de un periodo academico, paginados y ordenados, sin alcance. Lo usan fn_grado_listar y fn_grado_grupo_reporte_listar.';

CREATE OR REPLACE FUNCTION academico_test.fn_grado_obtener_interno(p_fk_grado BIGINT)
RETURNS TABLE (id BIGINT, nombre VARCHAR, grado VARCHAR, teaching_level_id BIGINT,
               teaching_level_name VARCHAR, grado_siguiente VARCHAR, grado_siguiente_name VARCHAR,
               tiene_grado_siguiente BOOLEAN, academic_period_id BIGINT)
LANGUAGE sql STABLE AS $$
    SELECT g.PK_TGRADO, g.NOMBRE, g.CODIGO, g.FK_TNIVEL_ENSENANZA, ne.NOMBRE,
           gs.VALOR, gs.NOMBRE, (g.TIENE_GRADO_SIGUIENTE = 'S'), g.FK_TPERIODO_ACADEMICO
      FROM academico_test.TGRADO g
      JOIN academico_test.TNIVEL_ENSENANZA ne ON ne.PK_NIVEL_ENSENANZA = g.FK_TNIVEL_ENSENANZA
      LEFT JOIN academico_test.TLISTA_VALOR gs ON gs.PK_LISTA_VALOR = g.FK_TLV_GRADO_SIGUIENTE
     WHERE g.PK_TGRADO = p_fk_grado AND g.ACTIVE = TRUE;
$$;

COMMENT ON FUNCTION academico_test.fn_grado_obtener_interno(BIGINT)
    IS 'INTERNO: un grado activo con su periodo academico, sin alcance. Lo usa fn_grado_obtener.';

-- ---------------------------------------------------------------- grupo

-- La jornada del grupo es la del periodo academico del grado.
CREATE OR REPLACE FUNCTION academico_test.fn_grupo_crear_interno(
    p_fk_grado             BIGINT,
    p_nombre               VARCHAR,
    p_fk_modelo_pedagogico BIGINT,
    p_capacidad            NUMERIC,
    p_fk_funcionario       BIGINT,
    p_audit                VARCHAR
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_id BIGINT; v_periodo BIGINT; v_jornada BIGINT; v_sede BIGINT;
    v_usuario BIGINT := CASE WHEN p_audit ~ '^[0-9]+$' THEN p_audit::BIGINT END;
BEGIN
    SELECT pa.PK_TPERIODO_ACADEMICO, pa.FK_TLV_JORNADA, pa.FK_TSEDE
      INTO v_periodo, v_jornada, v_sede
      FROM academico_test.TGRADO g
      JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
     WHERE g.PK_TGRADO = p_fk_grado AND g.ACTIVE = TRUE;
    PERFORM academico_test.fn_grupo_validar_campos(p_fk_grado, p_nombre, p_fk_modelo_pedagogico, p_capacidad);
    PERFORM academico_test.fn_grupo_validar_capacidad(p_capacidad);
    PERFORM academico_test.fn_grupo_validar_grado(p_fk_grado);
    PERFORM academico_test.fn_grupo_validar_director_asignable(p_fk_funcionario, v_sede);
    PERFORM academico_test.fn_grupo_validar_nombre_unico(p_fk_grado, v_jornada, p_nombre);

    INSERT INTO academico_test.TGRUPO
        (NOMBRE, FK_TGRADO, FK_TLV_JORNADA, FK_TLV_MODELO_PEDAGOGICO, CAPACIDAD, FK_TFUNCIONARIO, CREATED_BY)
    VALUES (p_nombre, p_fk_grado, v_jornada, p_fk_modelo_pedagogico, p_capacidad, p_fk_funcionario, p_audit)
    RETURNING PK_TGRUPO INTO v_id;

    -- El director recibe el rol DIRECTOR_GRUPO ademas de los que ya tenga (p.ej. DOCENTE).
    PERFORM academico_test.fn_grupo_director_rol_sync_interno(NULL, p_fk_funcionario, v_sede, v_jornada, v_usuario);
    IF p_fk_funcionario IS NOT NULL AND academico_test.fn_grado_es_preescolar(p_fk_grado) THEN
        PERFORM academico_test.fn_docente_director_grupo_sync(p_fk_funcionario, v_periodo, NULL, v_usuario);
    END IF;
    RETURN v_id;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_grupo_crear_interno(BIGINT, VARCHAR, BIGINT, NUMERIC, BIGINT, VARCHAR)
    IS 'INTERNO: valida e inserta un grupo, da el rol DIRECTOR_GRUPO a su director y, en preescolar, le sincroniza las asignaturas del grado. Lo usa fn_grupo_crear.';

-- Los NULL conservan el valor actual; el director no se puede quitar desde aqui.
CREATE OR REPLACE FUNCTION academico_test.fn_grupo_actualizar_interno(
    p_pk                   BIGINT,
    p_nombre               VARCHAR,
    p_fk_modelo_pedagogico BIGINT,
    p_capacidad            NUMERIC,
    p_fk_funcionario       BIGINT,
    p_audit                VARCHAR
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    r academico_test.TGRUPO; v_nombre VARCHAR(130); v_periodo BIGINT; v_sede BIGINT;
    v_fk_funcionario_final BIGINT;
    v_usuario BIGINT := CASE WHEN p_audit ~ '^[0-9]+$' THEN p_audit::BIGINT END;
BEGIN
    SELECT * INTO r FROM academico_test.TGRUPO WHERE PK_TGRUPO = p_pk;
    SELECT FK_TPERIODO_ACADEMICO INTO v_periodo FROM academico_test.TGRADO WHERE PK_TGRADO = r.FK_TGRADO;
    v_sede := academico_test.fn_periodo_sede(v_periodo);
    PERFORM academico_test.fn_grupo_validar_nombre_no_vacio(p_nombre);
    PERFORM academico_test.fn_grupo_validar_director_asignable(p_fk_funcionario, v_sede);
    PERFORM academico_test.fn_grupo_validar_capacidad(p_capacidad);
    v_nombre := COALESCE(p_nombre, r.NOMBRE);
    PERFORM academico_test.fn_grupo_validar_nombre_unico(r.FK_TGRADO, r.FK_TLV_JORNADA, v_nombre, p_pk);
    -- Null quita el director del grupo.
    v_fk_funcionario_final := p_fk_funcionario;

    UPDATE academico_test.TGRUPO SET
        NOMBRE = v_nombre,
        FK_TLV_MODELO_PEDAGOGICO = COALESCE(p_fk_modelo_pedagogico, FK_TLV_MODELO_PEDAGOGICO),
        CAPACIDAD = COALESCE(p_capacidad, CAPACIDAD),
        FK_TFUNCIONARIO = v_fk_funcionario_final,
        MODIFIED_BY = p_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TGRUPO = p_pk;

    PERFORM academico_test.fn_grupo_director_rol_sync_interno(
        r.FK_TFUNCIONARIO, v_fk_funcionario_final, v_sede, r.FK_TLV_JORNADA, v_usuario);
    -- En preescolar se resincronizan el director saliente y el entrante.
    IF academico_test.fn_grado_es_preescolar(r.FK_TGRADO) THEN
        IF r.FK_TFUNCIONARIO IS NOT NULL THEN
            PERFORM academico_test.fn_docente_director_grupo_sync(r.FK_TFUNCIONARIO, v_periodo, NULL, v_usuario);
        END IF;
        IF v_fk_funcionario_final IS NOT NULL AND v_fk_funcionario_final IS DISTINCT FROM r.FK_TFUNCIONARIO THEN
            PERFORM academico_test.fn_docente_director_grupo_sync(v_fk_funcionario_final, v_periodo, NULL, v_usuario);
        END IF;
    END IF;
    RETURN p_pk;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_grupo_actualizar_interno(BIGINT, VARCHAR, BIGINT, NUMERIC, BIGINT, VARCHAR)
    IS 'INTERNO: valida y actualiza un grupo existente y activo, y sincroniza el rol y (en preescolar) las asignaturas de los directores. Lo usa fn_grupo_actualizar.';

CREATE OR REPLACE FUNCTION academico_test.fn_grupo_eliminar_interno(p_pk BIGINT, p_audit VARCHAR)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_nombre VARCHAR(130);
BEGIN
    PERFORM academico_test.fn_grupo_validar_eliminable(p_pk);

    UPDATE academico_test.TGRUPO SET ACTIVE = FALSE, MODIFIED_BY = p_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TGRUPO = p_pk AND ACTIVE = TRUE;
    IF NOT FOUND THEN
        SELECT NOMBRE INTO v_nombre FROM academico_test.TGRUPO WHERE PK_TGRUPO = p_pk;
        IF v_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'El grupo "%" ya esta inactivo', v_nombre USING ERRCODE = 'P0002';
        END IF;
        RAISE EXCEPTION 'El grupo seleccionado no existe' USING ERRCODE = 'P0002';
    END IF;
    RETURN p_pk;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_grupo_eliminar_interno(BIGINT, VARCHAR)
    IS 'INTERNO: baja logica de un grupo; 23503 si tiene matriculas, asignaciones, horarios, asistencia o notas, P0002 si ya estaba inactivo. Lo usa fn_grupo_soft_delete.';

CREATE OR REPLACE FUNCTION academico_test.fn_grupo_listar_interno(
    p_fk_grado   BIGINT,
    p_filtro     TEXT DEFAULT NULL,
    p_page_index INT  DEFAULT 0,
    p_page_size  INT  DEFAULT 10,
    p_sort_by    TEXT DEFAULT NULL,
    p_sort_dir   TEXT DEFAULT NULL
)
RETURNS TABLE (id BIGINT, codigo VARCHAR, jornada VARCHAR, jornada_name VARCHAR, director_id BIGINT,
               director_name TEXT, metodologia VARCHAR, metodologia_name VARCHAR, cupo NUMERIC, total_count BIGINT,
               jornada_id BIGINT)
LANGUAGE plpgsql STABLE AS $$
DECLARE v_col TEXT; v_dir TEXT;
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
               count(*) OVER()::BIGINT, gr.FK_TLV_JORNADA
          FROM academico_test.TGRUPO gr
          JOIN academico_test.TLISTA_VALOR jor      ON jor.PK_LISTA_VALOR = gr.FK_TLV_JORNADA
          LEFT JOIN academico_test.TLISTA_VALOR met ON met.PK_LISTA_VALOR = gr.FK_TLV_MODELO_PEDAGOGICO
          LEFT JOIN academico_test.TFUNCIONARIO df  ON df.PK_TFUNCIONARIO = gr.FK_TFUNCIONARIO
          LEFT JOIN academico_test.TUSUARIO du      ON du.PK_TUSUARIO = df.FK_TUSUARIO
         WHERE gr.FK_TGRADO = $1 AND gr.ACTIVE = TRUE
           AND ($2 IS NULL OR gr.NOMBRE ILIKE '%%' || $2 || '%%')
         ORDER BY %s %s, gr.PK_TGRUPO
         LIMIT NULLIF($4, 0)
        OFFSET COALESCE($3, 0) * COALESCE(NULLIF($4, 0), 0)
    $q$, v_col, v_dir)
    USING p_fk_grado, NULLIF(TRIM(p_filtro),''), p_page_index, p_page_size;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_grupo_listar_interno(BIGINT, TEXT, INT, INT, TEXT, TEXT)
    IS 'INTERNO: grupos activos de un grado, paginados y ordenados, sin alcance. Lo usan fn_grupo_listar y fn_grado_grupo_reporte_listar.';

CREATE OR REPLACE FUNCTION academico_test.fn_grupo_obtener_interno(p_pk BIGINT)
RETURNS TABLE (id BIGINT, codigo VARCHAR, jornada VARCHAR, jornada_name VARCHAR,
               director_id BIGINT, director_name TEXT, director_rol_id BIGINT,
               metodologia_id BIGINT, metodologia VARCHAR, metodologia_name VARCHAR,
               cupo NUMERIC, grado_id BIGINT, academic_period_id BIGINT)
LANGUAGE sql STABLE AS $$
    SELECT gr.PK_TGRUPO, gr.NOMBRE, jor.VALOR, jor.NOMBRE,
           gr.FK_TFUNCIONARIO,
           TRIM(regexp_replace(
               concat_ws(' ', du.PRIMER_NOMBRE, du.SEGUNDO_NOMBRE, du.PRIMER_APELLIDO, du.SEGUNDO_APELLIDO),
               '\s+', ' ', 'g')),
           (SELECT su.FK_TROL FROM academico_test.TSEDE_USUARIO su
             JOIN academico_test.TPERIODO_ACADEMICO pa2 ON pa2.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
            WHERE su.FK_TUSUARIO = df.FK_TUSUARIO AND su.FK_TSEDE = pa2.FK_TSEDE
              AND su.ACTIVE = TRUE AND su.TLV_ESTADO = 'ACTIVO'
            LIMIT 1),
           gr.FK_TLV_MODELO_PEDAGOGICO, met.VALOR, met.NOMBRE, gr.CAPACIDAD, gr.FK_TGRADO,
           g.FK_TPERIODO_ACADEMICO
      FROM academico_test.TGRUPO gr
      LEFT JOIN academico_test.TGRADO g         ON g.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TLISTA_VALOR jor      ON jor.PK_LISTA_VALOR = gr.FK_TLV_JORNADA
      LEFT JOIN academico_test.TLISTA_VALOR met ON met.PK_LISTA_VALOR = gr.FK_TLV_MODELO_PEDAGOGICO
      LEFT JOIN academico_test.TFUNCIONARIO df  ON df.PK_TFUNCIONARIO = gr.FK_TFUNCIONARIO
      LEFT JOIN academico_test.TUSUARIO du      ON du.PK_TUSUARIO = df.FK_TUSUARIO
     WHERE gr.PK_TGRUPO = p_pk AND gr.ACTIVE = TRUE;
$$;

COMMENT ON FUNCTION academico_test.fn_grupo_obtener_interno(BIGINT)
    IS 'INTERNO: un grupo activo con su director, su rol en la sede y su periodo academico, sin alcance. Lo usa fn_grupo_obtener.';

-- ------------------------------------- director de grupo (antes V285)
-- Preescolar: el director de grupo dicta todas las asignaturas del plan.

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

-- ---------------------------------------------------------------------------
-- fn_grupo_director_rol_sync_interno: nucleo sin gate (lo llaman fn_grupo_
-- crear_interno / fn_grupo_actualizar_interno, V43.2; el gate va en sus wrappers). Da de alta
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
    'INTERNO: llamado por fn_grupo_crear_interno y fn_grupo_actualizar_interno. Sincroniza el rol DIRECTOR_GRUPO (TSEDE_USUARIO) del funcionario asignado/desasignado como director de un grupo. Sin gate propio -- lo aplican los wrappers fn_grupo_crear/fn_grupo_actualizar.';
