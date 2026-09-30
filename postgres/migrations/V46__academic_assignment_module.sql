-- ===========================================================================
-- V46 - Asignacion academica: fn_asignacion_guardar y fn_asignacion_docente.
-- fn_asignacion_docente_listar vive en V264; fn_asignacion_reporte_listar en V190.
-- ===========================================================================


SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_asignacion_guardar(p_academic_period_id bigint, p_fk_funcionario bigint, p_subject_ids text[], p_pk_usuario_solicitante bigint)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_func BIGINT; v_count INT := 0; v_pair TEXT; v_grupo BIGINT; v_asig BIGINT;
    v_nombre_periodo TEXT;
    v_nombre_funcionario TEXT;
    v_nombre_asig TEXT;
    v_nombre_grupo TEXT;
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante,
        academico_test.fn_periodo_establecimiento(p_academic_period_id),
        academico_test.fn_periodo_sede(p_academic_period_id),
        academico_test.fn_periodo_jornada(p_academic_period_id), 'EDITAR');

    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TPERIODO_ACADEMICO
         WHERE PK_TPERIODO_ACADEMICO = p_academic_period_id AND ACTIVE = TRUE
    ) THEN
        SELECT NOMBRE INTO v_nombre_periodo
          FROM academico_test.TPERIODO_ACADEMICO
         WHERE PK_TPERIODO_ACADEMICO = p_academic_period_id;
        IF v_nombre_periodo IS NOT NULL THEN
            RAISE EXCEPTION 'El periodo academico "%" existe pero esta inactivo', v_nombre_periodo
                USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'El periodo academico no existe' USING ERRCODE = '23503';
        END IF;
    END IF;

    SELECT f.PK_TFUNCIONARIO INTO v_func
      FROM academico_test.TFUNCIONARIO f
     WHERE f.PK_TFUNCIONARIO = p_fk_funcionario AND f.ACTIVE = TRUE;
    IF v_func IS NULL THEN
        SELECT TRIM(concat_ws(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE, u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO))
          INTO v_nombre_funcionario
          FROM academico_test.TFUNCIONARIO f
          JOIN academico_test.TUSUARIO u ON u.PK_TUSUARIO = f.FK_TUSUARIO
         WHERE f.PK_TFUNCIONARIO = p_fk_funcionario;
        IF v_nombre_funcionario IS NOT NULL THEN
            RAISE EXCEPTION 'El funcionario "%" existe pero esta inactivo', v_nombre_funcionario
                USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'No existe un funcionario con el id proporcionado' USING ERRCODE = '23503';
        END IF;
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext('docasig:' || p_academic_period_id::text || ':' || v_func::text));

    -- Camino exitoso: estos nombres solo se resolvian en las ramas de error de arriba,
    -- pero hacen falta aca para la etiqueta de auditoria.
    SELECT NOMBRE INTO v_nombre_periodo
      FROM academico_test.TPERIODO_ACADEMICO WHERE PK_TPERIODO_ACADEMICO = p_academic_period_id;
    SELECT TRIM(concat_ws(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE, u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO))
      INTO v_nombre_funcionario
      FROM academico_test.TFUNCIONARIO f
      JOIN academico_test.TUSUARIO u ON u.PK_TUSUARIO = f.FK_TUSUARIO
     WHERE f.PK_TFUNCIONARIO = v_func;

    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        format('Asignación académica del docente %s para el periodo %s', v_nombre_funcionario, v_nombre_periodo),
        academico_test.fn_periodo_establecimiento(p_academic_period_id)
    );

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

            -- Ya confirmados activos por el chequeo anterior; se resuelven los nombres
            -- para los mensajes de conflicto/duplicado de abajo.
            SELECT s2.NOMBRE, g2.NOMBRE || ' ' || gr2.NOMBRE
              INTO v_nombre_asig, v_nombre_grupo
              FROM academico_test.TASIGNATURA s2
              JOIN academico_test.TGRUPO gr2 ON gr2.PK_TGRUPO = v_grupo
              JOIN academico_test.TGRADO g2 ON g2.PK_TGRADO = gr2.FK_TGRADO
             WHERE s2.PK_TASIGNATURA = v_asig;

            IF EXISTS (
                SELECT 1 FROM academico_test.TDOCENTE_ASIGNATURA
                 WHERE FK_TGRUPO = v_grupo AND FK_TASIGNATURA = v_asig
                   AND FK_TPERIODO_ACADEMICO = p_academic_period_id AND ACTIVE = TRUE
                   AND FK_TFUNCIONARIO <> v_func
            ) THEN
                RAISE EXCEPTION 'La asignatura "%" en el grupo "%" ya esta asignada a otro docente en el periodo',
                    v_nombre_asig, v_nombre_grupo USING ERRCODE = '23505';
            END IF;

            -- Detecta duplicados agregados por una vuelta anterior de este mismo loop.
            IF EXISTS (
                SELECT 1 FROM academico_test.TDOCENTE_ASIGNATURA
                 WHERE FK_TGRUPO = v_grupo AND FK_TASIGNATURA = v_asig
                   AND FK_TPERIODO_ACADEMICO = p_academic_period_id AND ACTIVE = TRUE
                   AND FK_TFUNCIONARIO = v_func
            ) THEN
                RAISE EXCEPTION 'La asignatura "%" en el grupo "%" esta duplicada en la asignacion',
                    v_nombre_asig, v_nombre_grupo USING ERRCODE = '23505';
            END IF;

            INSERT INTO academico_test.TDOCENTE_ASIGNATURA
                (FK_TGRUPO, FK_TFUNCIONARIO, FK_TASIGNATURA, FK_TPERIODO_ACADEMICO, CREATED_BY)
            VALUES (v_grupo, v_func, v_asig, p_academic_period_id, v_audit);
            v_count := v_count + 1;
        END LOOP;
    END IF;

    RETURN v_count;
END;
$function$;

CREATE OR REPLACE FUNCTION academico_test.fn_asignacion_docente(
    p_academic_period_id BIGINT, p_fk_funcionario BIGINT,
    p_pk_usuario BIGINT DEFAULT NULL  
)
RETURNS TABLE (assignment_id TEXT)
LANGUAGE sql STABLE AS $$
    SELECT da.FK_TGRUPO || ':' || da.FK_TASIGNATURA
      FROM academico_test.TDOCENTE_ASIGNATURA da
     WHERE da.FK_TPERIODO_ACADEMICO = p_academic_period_id
       AND da.FK_TFUNCIONARIO = p_fk_funcionario AND da.ACTIVE = TRUE
       AND academico_test.fn_periodo_puede_ver(p_pk_usuario, p_academic_period_id);
$$;
