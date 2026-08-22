-- fn_asignacion_guardar respondia varios RAISE EXCEPTION con PKs crudos en
-- lugar del nombre legible de la entidad -- mismo patron ya corregido en
-- V99-V102 para periodo/criterio-promocion. Se revisaron las 4 funciones del
-- modulo "asignacion academica" (fn_asignacion_guardar, fn_asignacion_docente,
-- fn_asignacion_pool, fn_asignacion_docente_listar); solo fn_asignacion_guardar
-- tiene RAISE EXCEPTION (las otras 3 son SELECT/consulta pura, sin errores).
--
-- Cambios dentro de fn_asignacion_guardar:
--   1) "El periodo academico % no existe o no esta activo" -- p_academic_period_id
--      es una FK que el usuario manda. Se agrega lookup del NOMBRE del periodo
--      IGNORANDO ACTIVE: si existe pero inactivo -> nombre + "existe pero esta
--      inactivo"; si no existe -> mensaje generico sin id. Mismo ERRCODE (23503).
--   2) "No existe un funcionario con id %" -- mismo patron que (1): lookup del
--      nombre completo del funcionario (via TUSUARIO) ignorando ACTIVE. Mismo
--      ERRCODE (23503).
--   3) "La asignatura % en el grupo % ya esta asignada a otro docente en el
--      periodo" -- en este punto asignatura y grupo YA fueron confirmados
--      activos por el chequeo de pool inmediatamente anterior (linea "El par
--      debe ser una combinacion valida del pool"), asi que se resuelven sus
--      nombres sin volver a filtrar por ACTIVE. Mismo ERRCODE (23505).
--   4) "La asignatura % en el grupo % esta duplicada en la asignacion" --
--      mismo caso que (3), reutiliza el mismo lookup de nombres.
--
-- NO tocados (y por que):
--   - "Identificador de asignacion invalido: %" (v_pair) -- ya es el string
--     crudo ingresado por el usuario, no un PK de una entidad (regla 1).
--   - "La asignatura % no corresponde al grupo % en el plan del periodo" --
--     ambiguo: se dispara precisamente cuando el JOIN (grupo activo + plan +
--     asignatura activa + asignatura_plan) NO encuentra fila, con lo cual no
--     sabemos si asignatura/grupo no existen, estan inactivos, o simplemente
--     no pertenecen al plan de ese grado/periodo. No es un lookup de una sola
--     FK tipo regla 4/5 ni una entidad confirmada activa tipo regla 3 -- es
--     una validacion de combinacion invalida entre dos ids no confirmados. Se
--     deja intacto; si se quiere mejorar requeriria decidir un mensaje para
--     cada una de las 3+ causas posibles por separado (fuera del alcance de
--     este parche mecanico).
--   - fn_asignacion_docente, fn_asignacion_pool, fn_asignacion_docente_listar:
--     no tienen RAISE EXCEPTION (son SELECT/plpgsql de solo lectura).
--
-- Firma, tipos, DEFAULTs, ERRCODEs y logica de negocio quedan intactos; solo
-- se agregan variables DECLARE y SELECTs de lookup antes de los RAISE.

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
        p_pk_usuario_solicitante, academico_test.fn_periodo_establecimiento(p_academic_period_id));

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

            -- A partir de aqui asignatura y grupo estan confirmados activos por el
            -- chequeo anterior; se resuelven sus nombres para los mensajes de
            -- conflicto/duplicado de abajo.
            SELECT s2.NOMBRE, g2.NOMBRE || ' ' || gr2.NOMBRE
              INTO v_nombre_asig, v_nombre_grupo
              FROM academico_test.TASIGNATURA s2
              JOIN academico_test.TGRUPO gr2 ON gr2.PK_TGRUPO = v_grupo
              JOIN academico_test.TGRADO g2 ON g2.PK_TGRADO = gr2.FK_TGRADO
             WHERE s2.PK_TASIGNATURA = v_asig;

            -- Conflicto: la materia-grupo ya esta asignada a OTRO docente en el periodo.
            IF EXISTS (
                SELECT 1 FROM academico_test.TDOCENTE_ASIGNATURA
                 WHERE FK_TGRUPO = v_grupo AND FK_TASIGNATURA = v_asig
                   AND FK_TPERIODO_ACADEMICO = p_academic_period_id AND ACTIVE = TRUE
                   AND FK_TFUNCIONARIO <> v_func
            ) THEN
                RAISE EXCEPTION 'La asignatura "%" en el grupo "%" ya esta asignada a otro docente en el periodo',
                    v_nombre_asig, v_nombre_grupo USING ERRCODE = '23505';
            END IF;

            -- Duplicado dentro del mismo guardado (ya insertado en este loop).
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
$function$
