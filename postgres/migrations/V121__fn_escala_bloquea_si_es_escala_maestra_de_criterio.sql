-- Bug: ni fn_escala_bulk_delete ni fn_escala_nivel_soft_delete chequeaban si
-- la escala que se va a borrar es la FK_TESCALA activa de algun
-- TCRITERIO_EVALUACION (la "escala maestra" que un periodo tiene
-- seleccionada) — se podia borrar una escala en uso, dejando el criterio de
-- evaluacion del periodo apuntando a una escala inactiva.
CREATE OR REPLACE FUNCTION academico_test.fn_escala_bulk_delete(p_escala_ids bigint[], p_pk_usuario_solicitante bigint)
 RETURNS TABLE(id bigint, eliminado boolean, error_code text, error_mensaje text)
 LANGUAGE plpgsql
AS $$
DECLARE
    v_id             BIGINT;
    v_est            BIGINT;
    v_state          TEXT;
    v_msg            TEXT;
    v_audit          VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_nombre_escala  VARCHAR(130);
    v_nombre_periodo VARCHAR(130);
BEGIN
    IF p_escala_ids IS NULL THEN RETURN; END IF;
    FOREACH v_id IN ARRAY p_escala_ids LOOP
        BEGIN
            -- Gate grueso + fino: el establecimiento viene del periodo de la
            -- primera TNIVEL_ESCALA activa de la escala (todas comparten el
            -- mismo periodo para una misma escala).
            SELECT academico_test.fn_periodo_establecimiento(ne.FK_PERIODO_ACADEMICO)
              INTO v_est
              FROM academico_test.TNIVEL_ESCALA ne
             WHERE ne.FK_TESCALA = v_id AND ne.ACTIVE = TRUE
             LIMIT 1;
            PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, v_est);

            -- La escala debe existir y estar activa. Si no, se intenta resolver
            -- su nombre ignorando ACTIVE=TRUE para un mensaje legible.
            SELECT NOMBRE INTO v_nombre_escala
              FROM academico_test.TESCALA
             WHERE PK_TESCALA = v_id AND ACTIVE = TRUE;
            IF v_nombre_escala IS NULL THEN
                SELECT NOMBRE INTO v_nombre_escala
                  FROM academico_test.TESCALA WHERE PK_TESCALA = v_id;
                IF v_nombre_escala IS NOT NULL THEN
                    RAISE EXCEPTION 'La escala "%" existe pero esta inactiva', v_nombre_escala
                        USING ERRCODE = 'P0002';
                ELSE
                    RAISE EXCEPTION 'No existe una escala con el identificador indicado'
                        USING ERRCODE = 'P0002';
                END IF;
            END IF;

            -- Bloqueo: bandas en uso por criterios de unidad.
            IF EXISTS (
                SELECT 1 FROM academico_test.TNIVEL_CRITERIO_UNIDAD ncu
                  JOIN academico_test.TESCALA_VALORACION ev
                    ON ev.PK_TESCALA_VALORACION = ncu.FK_TESCALA_VALORACION
                 WHERE ev.FK_TESCALA = v_id AND ncu.ACTIVE = TRUE
            ) THEN
                RAISE EXCEPTION 'No se puede eliminar la escala "%": hay bandas en uso por criterios de unidad',
                    v_nombre_escala USING ERRCODE = '23503';
            END IF;

            -- Bloqueo: es la escala maestra activa de algun criterio de evaluacion.
            SELECT p.NOMBRE INTO v_nombre_periodo
              FROM academico_test.TCRITERIO_EVALUACION ce
              JOIN academico_test.TPERIODO_ACADEMICO p ON p.PK_TPERIODO_ACADEMICO = ce.PK_TCRITERIO_EVALUACION
             WHERE ce.FK_TESCALA = v_id AND ce.ACTIVE = TRUE
             LIMIT 1;
            IF v_nombre_periodo IS NOT NULL THEN
                RAISE EXCEPTION 'No se puede eliminar la escala "%": es la escala maestra del criterio de evaluacion del periodo "%"',
                    v_nombre_escala, v_nombre_periodo USING ERRCODE = '23503';
            END IF;

            -- Cascada: TVALORACION -> TESCALA_VALORACION -> TNIVEL_ESCALA -> TESCALA.
            UPDATE academico_test.TVALORACION
               SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
             WHERE PK_TVALORACION IN (
                 SELECT FK_TVALORACION FROM academico_test.TESCALA_VALORACION
                  WHERE FK_TESCALA = v_id AND ACTIVE = TRUE
             );
            UPDATE academico_test.TESCALA_VALORACION
               SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
             WHERE FK_TESCALA = v_id AND ACTIVE = TRUE;
            UPDATE academico_test.TNIVEL_ESCALA
               SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
             WHERE FK_TESCALA = v_id AND ACTIVE = TRUE;
            UPDATE academico_test.TESCALA
               SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
             WHERE PK_TESCALA = v_id AND ACTIVE = TRUE;

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

CREATE OR REPLACE FUNCTION academico_test.fn_escala_nivel_soft_delete(p_academic_period_id bigint, p_teaching_level_id bigint, p_pk_usuario_solicitante bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $$
DECLARE
    v_escala       BIGINT;
    v_audit        VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_nivel_nombre VARCHAR(130);
    v_nombre_periodo VARCHAR(130);
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, academico_test.fn_periodo_establecimiento(p_academic_period_id));
    SELECT ne.FK_TESCALA INTO v_escala FROM academico_test.TNIVEL_ESCALA ne
     WHERE ne.FK_PERIODO_ACADEMICO = p_academic_period_id
       AND ne.FK_TNIVEL_ENSENANZA = p_teaching_level_id AND ne.ACTIVE = TRUE;
    IF v_escala IS NULL THEN
        -- Nombre del nivel de ensenanza (sin filtro ACTIVE, igual que el
        -- SELECT original) para un mensaje legible en vez de los dos ids.
        SELECT nen.NOMBRE INTO v_nivel_nombre
          FROM academico_test.TNIVEL_ENSENANZA nen WHERE nen.PK_NIVEL_ENSENANZA = p_teaching_level_id;
        IF v_nivel_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'No existe una escala activa para el nivel "%" en este periodo', v_nivel_nombre
                USING ERRCODE = 'P0002';
        ELSE
            RAISE EXCEPTION 'No existe una escala activa para el nivel indicado en este periodo'
                USING ERRCODE = 'P0002';
        END IF;
    END IF;
    -- Nombre del nivel (para el mensaje de bloqueo de abajo, si aplica).
    SELECT nen.NOMBRE INTO v_nivel_nombre
      FROM academico_test.TNIVEL_ENSENANZA nen WHERE nen.PK_NIVEL_ENSENANZA = p_teaching_level_id;
    -- Bloqueo: bandas en uso por criterios de unidad.
    IF EXISTS (
        SELECT 1 FROM academico_test.TNIVEL_CRITERIO_UNIDAD ncu
          JOIN academico_test.TESCALA_VALORACION ev ON ev.PK_TESCALA_VALORACION = ncu.FK_TESCALA_VALORACION
         WHERE ev.FK_TESCALA = v_escala AND ncu.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar la escala del nivel "%": hay bandas en uso por criterios de unidad',
            COALESCE(v_nivel_nombre, p_teaching_level_id::TEXT) USING ERRCODE = '23503';
    END IF;
    -- Bloqueo: es la escala maestra activa de algun criterio de evaluacion.
    SELECT p.NOMBRE INTO v_nombre_periodo
      FROM academico_test.TCRITERIO_EVALUACION ce
      JOIN academico_test.TPERIODO_ACADEMICO p ON p.PK_TPERIODO_ACADEMICO = ce.PK_TCRITERIO_EVALUACION
     WHERE ce.FK_TESCALA = v_escala AND ce.ACTIVE = TRUE
     LIMIT 1;
    IF v_nombre_periodo IS NOT NULL THEN
        RAISE EXCEPTION 'No se puede eliminar la escala del nivel "%": es la escala maestra del criterio de evaluacion del periodo "%"',
            COALESCE(v_nivel_nombre, p_teaching_level_id::TEXT), v_nombre_periodo USING ERRCODE = '23503';
    END IF;
    -- Valoraciones de las bandas.
    UPDATE academico_test.TVALORACION SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TVALORACION IN (
         SELECT FK_TVALORACION FROM academico_test.TESCALA_VALORACION
          WHERE FK_TESCALA = v_escala AND ACTIVE = TRUE
     );
    -- Bandas.
    UPDATE academico_test.TESCALA_VALORACION SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TESCALA = v_escala AND ACTIVE = TRUE;
    -- Vinculo nivel-escala-periodo.
    UPDATE academico_test.TNIVEL_ESCALA SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TESCALA = v_escala AND FK_PERIODO_ACADEMICO = p_academic_period_id
       AND FK_TNIVEL_ENSENANZA = p_teaching_level_id AND ACTIVE = TRUE;
    -- Contenedor TESCALA.
    UPDATE academico_test.TESCALA SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TESCALA = v_escala AND ACTIVE = TRUE;
    RETURN v_escala;
END;
$$;
