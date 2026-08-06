-- ===========================================================================
-- V45 — Modulo de Horario (THORARIO).
-- Guardar = reescribe el horario del grado (baja logica de lo vigente de sus
-- grupos + inserta las celdas nuevas). NUMERO_BLOQUE 0-based (0..BLOQUES-1 del
-- periodo). El front manda entries con ids resueltos y el planItemId
-- (subjectId de la grilla = PK_TASIGNATURA_PLAN); la funcion resuelve la
-- asignatura. Payload entries jsonb: [{grupoId, planItemId, diaId, bloque}].
-- ===========================================================================

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_horario_guardar(
    p_fk_grado  BIGINT,
    p_entries   jsonb,
    p_pk_usuario_solicitante BIGINT
)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_max_bloques BIGINT; v_count INT := 0;
    v_bloque INT; v_grupo BIGINT; v_asig BIGINT; v_dia BIGINT; v_planitem BIGINT;
    entry jsonb;
BEGIN
    IF NOT academico_test.fn_es_super_admin(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    SELECT pa.BLOQUES_POR_DEFECTO INTO v_max_bloques
      FROM academico_test.TGRADO g JOIN academico_test.TPERIODO_ACADEMICO pa
        ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
     WHERE g.PK_TGRADO = p_fk_grado AND g.ACTIVE = TRUE;
    IF v_max_bloques IS NULL THEN
        RAISE EXCEPTION 'El grado % no existe o esta inactivo', p_fk_grado USING ERRCODE = '23503';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext('horario:' || p_fk_grado::text));

    UPDATE academico_test.THORARIO h
       SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE h.ACTIVE = TRUE
       AND h.FK_TGRUPO IN (SELECT PK_TGRUPO FROM academico_test.TGRUPO WHERE FK_TGRADO = p_fk_grado);

    FOR entry IN SELECT * FROM jsonb_array_elements(COALESCE(p_entries, '[]'::jsonb))
    LOOP
        v_bloque   := (entry->>'bloque')::INT;
        v_grupo    := (entry->>'grupoId')::BIGINT;
        v_dia      := (entry->>'diaId')::BIGINT;
        v_planitem := (entry->>'planItemId')::BIGINT;
        -- Campos obligatorios de la celda.
        IF v_bloque IS NULL OR v_grupo IS NULL OR v_dia IS NULL OR v_planitem IS NULL THEN
            RAISE EXCEPTION 'Cada celda requiere grupoId, planItemId, diaId y bloque' USING ERRCODE = '22023';
        END IF;
        IF v_bloque < 0 OR v_bloque >= v_max_bloques THEN
            RAISE EXCEPTION 'Bloque % fuera de rango (0 a %)', v_bloque, v_max_bloques - 1 USING ERRCODE = '22023';
        END IF;
        -- El grupo pertenece al grado y esta activo.
        IF NOT EXISTS (
            SELECT 1 FROM academico_test.TGRUPO
             WHERE PK_TGRUPO = v_grupo AND FK_TGRADO = p_fk_grado AND ACTIVE = TRUE
        ) THEN
            RAISE EXCEPTION 'El grupo % no pertenece al grado % o esta inactivo', v_grupo, p_fk_grado USING ERRCODE = '22023';
        END IF;
        -- El dia debe ser del catalogo DIA_SEMANA.
        IF NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = v_dia AND ACTIVE = TRUE AND CATEGORIA = 'DIA_SEMANA'
        ) THEN
            RAISE EXCEPTION 'El dia % no es valido (debe ser de la categoria DIA_SEMANA)', v_dia USING ERRCODE = '23503';
        END IF;
        -- El renglon de plan debe existir, estar activo y pertenecer al plan del grado.
        SELECT ap.FK_TASIGNATURA INTO v_asig
          FROM academico_test.TASIGNATURA_PLAN ap
          JOIN academico_test.TPLAN pl ON pl.PK_TPLAN = ap.FK_TPLAN AND pl.ACTIVE = TRUE
         WHERE ap.PK_TASIGNATURA_PLAN = v_planitem AND ap.ACTIVE = TRUE
           AND pl.FK_TGRADO = p_fk_grado;
        IF v_asig IS NULL THEN
            RAISE EXCEPTION 'El renglon de plan % no existe, esta inactivo o no pertenece al grado %',
                v_planitem, p_fk_grado USING ERRCODE = '23503';
        END IF;
        -- Sin dos asignaturas en la misma casilla (grupo + dia + bloque). Como lo
        -- vigente ya se desactivo, cualquier ACTIVE=TRUE es de este mismo payload.
        IF EXISTS (
            SELECT 1 FROM academico_test.THORARIO
             WHERE FK_TGRUPO = v_grupo AND FK_TLV_DIA_SEMANA = v_dia
               AND NUMERO_BLOQUE = v_bloque AND ACTIVE = TRUE
        ) THEN
            RAISE EXCEPTION 'Celda duplicada: grupo %, dia %, bloque %', v_grupo, v_dia, v_bloque USING ERRCODE = '22023';
        END IF;
        INSERT INTO academico_test.THORARIO (NUMERO_BLOQUE, FK_TLV_DIA_SEMANA, FK_TGRUPO, FK_TASIGNATURA, CREATED_BY)
        VALUES (v_bloque, v_dia, v_grupo, v_asig, v_audit);
        v_count := v_count + 1;
    END LOOP;

    RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_horario_listar(p_fk_grado BIGINT)
RETURNS TABLE (id BIGINT, grupo_id BIGINT, plan_item_id BIGINT, asignatura_id BIGINT,
               dia_id BIGINT, dia VARCHAR, bloque NUMERIC)
LANGUAGE sql STABLE AS $$
    SELECT h.PK_THORARIO, h.FK_TGRUPO, ap.PK_TASIGNATURA_PLAN, h.FK_TASIGNATURA,
           h.FK_TLV_DIA_SEMANA, dia.VALOR, h.NUMERO_BLOQUE
      FROM academico_test.THORARIO h
      JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = h.FK_TGRUPO AND gr.ACTIVE = TRUE
      LEFT JOIN academico_test.TLISTA_VALOR dia ON dia.PK_LISTA_VALOR = h.FK_TLV_DIA_SEMANA
      LEFT JOIN academico_test.TPLAN pl ON pl.FK_TGRADO = gr.FK_TGRADO AND pl.ACTIVE = TRUE
      LEFT JOIN academico_test.TASIGNATURA_PLAN ap ON ap.FK_TPLAN = pl.PK_TPLAN
           AND ap.FK_TASIGNATURA = h.FK_TASIGNATURA AND ap.ACTIVE = TRUE
     WHERE gr.FK_TGRADO = p_fk_grado AND h.ACTIVE = TRUE
     ORDER BY h.FK_TGRUPO, h.FK_TLV_DIA_SEMANA, h.NUMERO_BLOQUE;
$$;

-- Asignaturas del plan del grado (para las "fichas" arrastrables del horario).
-- plan_item_id = PK_TASIGNATURA_PLAN (el subjectId de la grilla). bloques = la
-- intensidad horaria (cuantos bloques colocar).
CREATE OR REPLACE FUNCTION academico_test.fn_horario_asignaturas(p_fk_grado BIGINT)
RETURNS TABLE (plan_item_id BIGINT, nombre VARCHAR, bloques NUMERIC, color VARCHAR)
LANGUAGE sql STABLE AS $$
    SELECT ap.PK_TASIGNATURA_PLAN, s.NOMBRE, ap.NUMERO_HORA, s.COLOR
      FROM academico_test.TASIGNATURA_PLAN ap
      JOIN academico_test.TPLAN pl       ON pl.PK_TPLAN = ap.FK_TPLAN AND pl.ACTIVE = TRUE
      JOIN academico_test.TASIGNATURA s  ON s.PK_TASIGNATURA = ap.FK_TASIGNATURA AND s.ACTIVE = TRUE
     WHERE pl.FK_TGRADO = p_fk_grado AND ap.ACTIVE = TRUE
     ORDER BY s.NOMBRE;
$$;
