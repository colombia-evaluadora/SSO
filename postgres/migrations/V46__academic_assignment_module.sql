-- ===========================================================================
-- V46 — Modulo de Asignaciones Academicas (TDOCENTE_ASIGNATURA).
-- Una asignacion = (grupo, docente, asignatura, periodo).
-- El docente se identifica por su id (PK_TFUNCIONARIO). Guardar = reescribe el
-- set del docente en el periodo. El id de cada "subject" es el par
-- "grupoId:asignaturaId".
-- ===========================================================================

SET search_path TO academico_test, public;

DROP FUNCTION IF EXISTS academico_test.fn_asignacion_guardar(BIGINT, VARCHAR, TEXT[], BIGINT);
CREATE OR REPLACE FUNCTION academico_test.fn_asignacion_guardar(
    p_academic_period_id BIGINT,
    p_fk_funcionario     BIGINT,           -- id del docente (PK_TFUNCIONARIO)
    p_subject_ids        TEXT[],           -- ["grupoId:asignaturaId", ...]
    p_pk_usuario_solicitante BIGINT
)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_func BIGINT; v_count INT := 0; v_pair TEXT; v_grupo BIGINT; v_asig BIGINT;
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, academico_test.fn_periodo_establecimiento(p_academic_period_id));

    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TPERIODO_ACADEMICO
         WHERE PK_TPERIODO_ACADEMICO = p_academic_period_id AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'El periodo academico % no existe o no esta activo', p_academic_period_id USING ERRCODE = '23503';
    END IF;

    SELECT f.PK_TFUNCIONARIO INTO v_func
      FROM academico_test.TFUNCIONARIO f
     WHERE f.PK_TFUNCIONARIO = p_fk_funcionario AND f.ACTIVE = TRUE;
    IF v_func IS NULL THEN
        RAISE EXCEPTION 'No existe un funcionario con id %', p_fk_funcionario USING ERRCODE = '23503';
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
-- p_filtro         = busqueda libre (asignatura, grado, grupo o jornada).
-- p_solo_sin_docente = TRUE -> solo materias-grupo aun no asignadas a un docente.
DROP FUNCTION IF EXISTS academico_test.fn_asignacion_pool(BIGINT, TEXT, BOOLEAN);
DROP FUNCTION IF EXISTS academico_test.fn_asignacion_pool(BIGINT, TEXT, BOOLEAN, BIGINT);
CREATE OR REPLACE FUNCTION academico_test.fn_asignacion_pool(
    p_academic_period_id BIGINT,
    p_filtro             TEXT    DEFAULT NULL,
    p_solo_sin_docente   BOOLEAN DEFAULT FALSE,
    p_pk_usuario         BIGINT  DEFAULT NULL   -- alcance (global / establecimiento)
)
RETURNS TABLE (id TEXT, nombre VARCHAR, grado_grupo TEXT, jornada VARCHAR, jornada_name VARCHAR)
LANGUAGE sql STABLE AS $$
    SELECT gr.PK_TGRUPO || ':' || s.PK_TASIGNATURA, s.NOMBRE,
           g.NOMBRE || ' ' || gr.NOMBRE, jor.VALOR, jor.NOMBRE
      FROM academico_test.TGRADO g
      JOIN academico_test.TGRUPO gr            ON gr.FK_TGRADO = g.PK_TGRADO AND gr.ACTIVE = TRUE
      JOIN academico_test.TPLAN p              ON p.FK_TGRADO = g.PK_TGRADO AND p.ACTIVE = TRUE
      JOIN academico_test.TASIGNATURA_PLAN ap  ON ap.FK_TPLAN = p.PK_TPLAN AND ap.ACTIVE = TRUE
      JOIN academico_test.TASIGNATURA s        ON s.PK_TASIGNATURA = ap.FK_TASIGNATURA AND s.ACTIVE = TRUE
      LEFT JOIN academico_test.TLISTA_VALOR jor ON jor.PK_LISTA_VALOR = gr.FK_TLV_JORNADA
     WHERE g.FK_TPERIODO_ACADEMICO = p_academic_period_id AND g.ACTIVE = TRUE
       AND academico_test.fn_periodo_usuario_puede_ver(p_pk_usuario, p_academic_period_id)
       AND (NULLIF(TRIM(p_filtro),'') IS NULL
            OR s.NOMBRE  ILIKE '%' || p_filtro || '%'
            OR g.NOMBRE  ILIKE '%' || p_filtro || '%'
            OR gr.NOMBRE ILIKE '%' || p_filtro || '%'
            OR jor.VALOR ILIKE '%' || p_filtro || '%')
       AND (NOT p_solo_sin_docente OR NOT EXISTS (
                SELECT 1 FROM academico_test.TDOCENTE_ASIGNATURA da
                 WHERE da.FK_TGRUPO = gr.PK_TGRUPO AND da.FK_TASIGNATURA = s.PK_TASIGNATURA
                   AND da.FK_TPERIODO_ACADEMICO = p_academic_period_id AND da.ACTIVE = TRUE))
     ORDER BY g.NOMBRE, gr.NOMBRE, s.NOMBRE;
$$;

-- Asignaciones vigentes de un docente (por documento) en el periodo.
DROP FUNCTION IF EXISTS academico_test.fn_asignacion_docente(BIGINT, VARCHAR);
CREATE OR REPLACE FUNCTION academico_test.fn_asignacion_docente(
    p_academic_period_id BIGINT, p_fk_funcionario BIGINT,
    p_pk_usuario BIGINT DEFAULT NULL  -- alcance (global / establecimiento)
)
RETURNS TABLE (assignment_id TEXT)
LANGUAGE sql STABLE AS $$
    SELECT da.FK_TGRUPO || ':' || da.FK_TASIGNATURA
      FROM academico_test.TDOCENTE_ASIGNATURA da
     WHERE da.FK_TPERIODO_ACADEMICO = p_academic_period_id
       AND da.FK_TFUNCIONARIO = p_fk_funcionario AND da.ACTIVE = TRUE
       AND academico_test.fn_periodo_usuario_puede_ver(p_pk_usuario, p_academic_period_id);
$$;

-- Docentes disponibles para asignar en el periodo (funcionarios del
-- establecimiento del periodo). Filtros: estado (TUSUARIO.ESTADO) y busqueda
-- libre por documento o nombre.
DROP FUNCTION IF EXISTS academico_test.fn_asignacion_docente_listar(BIGINT, TEXT, TEXT);
DROP FUNCTION IF EXISTS academico_test.fn_asignacion_docente_listar(BIGINT, TEXT, TEXT, BIGINT);
CREATE OR REPLACE FUNCTION academico_test.fn_asignacion_docente_listar(
    p_academic_period_id BIGINT,
    p_estado             TEXT DEFAULT NULL,   -- valor de TUSUARIO.ESTADO
    p_filtro             TEXT DEFAULT NULL,
    p_pk_usuario         BIGINT DEFAULT NULL  -- alcance (global / establecimiento)
)
RETURNS TABLE (funcionario_id BIGINT, document_number VARCHAR, nombre_completo TEXT, estado TEXT)
LANGUAGE sql STABLE AS $$
    SELECT DISTINCT f.PK_TFUNCIONARIO, u.IDENTIFICACION,
           TRIM(concat_ws(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE, u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO)),
           u.ESTADO::text
      FROM academico_test.TPERIODO_ACADEMICO pa
      JOIN academico_test.TSEDE_USUARIO su ON su.FK_TSEDE = pa.FK_TSEDE AND su.ACTIVE = TRUE
                                          AND su.FK_TROL = 14  -- rol Docente
      JOIN academico_test.TUSUARIO u      ON u.PK_TUSUARIO = su.FK_TUSUARIO AND u.ACTIVE = TRUE
      JOIN academico_test.TFUNCIONARIO f  ON f.FK_TUSUARIO = u.PK_TUSUARIO AND f.ACTIVE = TRUE
     WHERE pa.PK_TPERIODO_ACADEMICO = p_academic_period_id
       AND academico_test.fn_periodo_usuario_puede_ver(p_pk_usuario, p_academic_period_id)
       AND (NULLIF(TRIM(p_estado),'') IS NULL OR u.ESTADO::text = p_estado)
       AND (NULLIF(TRIM(p_filtro),'') IS NULL
            OR u.IDENTIFICACION ILIKE '%' || p_filtro || '%'
            OR TRIM(concat_ws(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE, u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO))
               ILIKE '%' || p_filtro || '%')
     ORDER BY 3;
$$;
