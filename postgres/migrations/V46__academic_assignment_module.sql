-- ===========================================================================
-- V46 — Modulo de Asignaciones Academicas (TDOCENTE_ASIGNATURA).
-- Una asignacion = (grupo, docente, asignatura, periodo).
-- El docente se identifica por numero de documento (TUSUARIO.IDENTIFICACION ->
-- TFUNCIONARIO). Guardar = reescribe el set del docente en el periodo. El id
-- de cada "subject" es el par "grupoId:asignaturaId".
-- ===========================================================================

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_asignacion_guardar(
    p_academic_period_id BIGINT,
    p_document_number    VARCHAR(30),
    p_subject_ids        TEXT[],           -- ["grupoId:asignaturaId", ...]
    p_pk_usuario_solicitante BIGINT
)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_func BIGINT; v_count INT := 0; v_pair TEXT; v_grupo BIGINT; v_asig BIGINT;
BEGIN
    IF NOT academico_test.fn_es_super_admin(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TPERIODO_ACADEMICO
         WHERE PK_TPERIODO_ACADEMICO = p_academic_period_id AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'El periodo academico % no existe o no esta activo', p_academic_period_id USING ERRCODE = '23503';
    END IF;

    SELECT f.PK_TFUNCIONARIO INTO v_func
      FROM academico_test.TFUNCIONARIO f
      JOIN academico_test.TUSUARIO u ON u.PK_TUSUARIO = f.FK_TUSUARIO
     WHERE u.IDENTIFICACION = p_document_number AND f.ACTIVE = TRUE
     ORDER BY f.PK_TFUNCIONARIO LIMIT 1;
    IF v_func IS NULL THEN
        RAISE EXCEPTION 'No existe un funcionario con documento %', p_document_number USING ERRCODE = '23503';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext('docasig:' || p_academic_period_id::text || ':' || v_func::text));

    UPDATE academico_test.TDOCENTE_ASIGNATURA
       SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TFUNCIONARIO = v_func AND FK_TPERIODO_ACADEMICO = p_academic_period_id AND ACTIVE = TRUE;

    IF p_subject_ids IS NOT NULL THEN
        FOREACH v_pair IN ARRAY p_subject_ids
        LOOP
            -- Formato "grupoId:asignaturaId" (ambos numericos).
            IF v_pair !~ '^[0-9]+:[0-9]+$' THEN
                RAISE EXCEPTION 'Identificador de asignacion invalido: %', v_pair USING ERRCODE = '22023';
            END IF;
            v_grupo := split_part(v_pair, ':', 1)::BIGINT;
            v_asig  := split_part(v_pair, ':', 2)::BIGINT;

            -- El par debe ser una combinacion valida del pool: grupo activo del
            -- periodo, y asignatura activa presente en el plan del grado del grupo.
            IF NOT EXISTS (
                SELECT 1
                  FROM academico_test.TGRUPO gr
                  JOIN academico_test.TGRADO g ON g.PK_TGRADO = gr.FK_TGRADO AND g.ACTIVE = TRUE
                       AND g.FK_TPERIODO_ACADEMICO = p_academic_period_id
                  JOIN academico_test.TPLAN pl ON pl.FK_TGRADO = g.PK_TGRADO AND pl.ACTIVE = TRUE
                  JOIN academico_test.TASIGNATURA_PLAN ap ON ap.FK_TPLAN = pl.PK_TPLAN
                       AND ap.FK_TASIGNATURA = v_asig AND ap.ACTIVE = TRUE
                  JOIN academico_test.TASIGNATURA s ON s.PK_TASIGNATURA = v_asig AND s.ACTIVE = TRUE
                 WHERE gr.PK_TGRUPO = v_grupo AND gr.ACTIVE = TRUE
            ) THEN
                RAISE EXCEPTION 'La asignatura % no corresponde al grupo % en el plan del periodo', v_asig, v_grupo
                    USING ERRCODE = '22023';
            END IF;

            -- Conflicto: la materia-grupo ya esta asignada a OTRO docente en el periodo.
            IF EXISTS (
                SELECT 1 FROM academico_test.TDOCENTE_ASIGNATURA
                 WHERE FK_TGRUPO = v_grupo AND FK_TASIGNATURA = v_asig
                   AND FK_TPERIODO_ACADEMICO = p_academic_period_id AND ACTIVE = TRUE
                   AND FK_TFUNCIONARIO <> v_func
            ) THEN
                RAISE EXCEPTION 'La asignatura % en el grupo % ya esta asignada a otro docente en el periodo', v_asig, v_grupo
                    USING ERRCODE = '23505';
            END IF;

            -- Duplicado dentro del mismo guardado (ya insertado en este loop).
            IF EXISTS (
                SELECT 1 FROM academico_test.TDOCENTE_ASIGNATURA
                 WHERE FK_TGRUPO = v_grupo AND FK_TASIGNATURA = v_asig
                   AND FK_TPERIODO_ACADEMICO = p_academic_period_id AND ACTIVE = TRUE
                   AND FK_TFUNCIONARIO = v_func
            ) THEN
                RAISE EXCEPTION 'La asignatura % en el grupo % esta duplicada en la asignacion', v_asig, v_grupo
                    USING ERRCODE = '23505';
            END IF;

            INSERT INTO academico_test.TDOCENTE_ASIGNATURA
                (FK_TGRUPO, FK_TFUNCIONARIO, FK_TASIGNATURA, FK_TPERIODO_ACADEMICO, CREATED_BY)
            VALUES (v_grupo, v_func, v_asig, p_academic_period_id, v_audit);
            v_count := v_count + 1;
        END LOOP;
    END IF;

    RETURN v_count;
END;
$$;

-- Pool asignable: grado x grupo x plan de estudio del periodo.
CREATE OR REPLACE FUNCTION academico_test.fn_asignacion_pool(p_academic_period_id BIGINT)
RETURNS TABLE (id TEXT, nombre VARCHAR, grado_grupo TEXT, jornada VARCHAR)
LANGUAGE sql STABLE AS $$
    SELECT gr.PK_TGRUPO || ':' || s.PK_TASIGNATURA, s.NOMBRE,
           g.NOMBRE || ' ' || gr.NOMBRE, jor.VALOR
      FROM academico_test.TGRUPO gr
      JOIN academico_test.TGRADO g            ON g.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPLAN p             ON p.FK_TGRADO = g.PK_TGRADO AND p.ACTIVE = TRUE
      JOIN academico_test.TASIGNATURA_PLAN ap ON ap.FK_TPLAN = p.PK_TPLAN AND ap.ACTIVE = TRUE
      JOIN academico_test.TASIGNATURA s       ON s.PK_TASIGNATURA = ap.FK_TASIGNATURA AND s.ACTIVE = TRUE
      LEFT JOIN academico_test.TLISTA_VALOR jor ON jor.PK_LISTA_VALOR = gr.FK_TLV_JORNADA
     WHERE g.FK_TPERIODO_ACADEMICO = p_academic_period_id AND gr.ACTIVE = TRUE AND g.ACTIVE = TRUE
     ORDER BY g.NOMBRE, gr.NOMBRE, s.NOMBRE;
$$;

-- Asignaciones vigentes de un docente (por documento) en el periodo.
CREATE OR REPLACE FUNCTION academico_test.fn_asignacion_docente(
    p_academic_period_id BIGINT, p_document_number VARCHAR(30)
)
RETURNS TABLE (assignment_id TEXT)
LANGUAGE sql STABLE AS $$
    SELECT da.FK_TGRUPO || ':' || da.FK_TASIGNATURA
      FROM academico_test.TDOCENTE_ASIGNATURA da
      JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = da.FK_TFUNCIONARIO
      JOIN academico_test.TUSUARIO u     ON u.PK_TUSUARIO = f.FK_TUSUARIO
     WHERE da.FK_TPERIODO_ACADEMICO = p_academic_period_id
       AND u.IDENTIFICACION = p_document_number AND da.ACTIVE = TRUE;
$$;
