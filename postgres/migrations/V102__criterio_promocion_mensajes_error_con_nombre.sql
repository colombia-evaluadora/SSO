-- fn_criterio_prom_guardar respondia con el PK crudo de TASIGNATURA/TAREA en
-- tres mensajes distintos:
--   - "La asignatura % no existe, esta inactiva o no pertenece al periodo"
--   - "El area % no existe, esta inactiva o no pertenece al periodo"
--   - "Obligatoria duplicada (asignatura % / area %)"
-- En los dos primeros el id viene del arreglo p_obligatorias (FK pasada por
-- el usuario para el bloque de "obligatorias"); se sigue el patron de la
-- regla 4: se intenta resolver el NOMBRE ignorando ACTIVE/periodo justo
-- antes del RAISE -- si existe (aunque inactiva o de otro periodo) se
-- muestra su nombre, si no existe en absoluto el mensaje queda generico sin
-- id. En el tercero (regla 3) el id ya fue confirmado activo y del periodo
-- por el chequeo EXISTS inmediatamente anterior, asi que se resuelve el
-- nombre directo sin condicional.
--
-- fn_criterio_prom_obtener se reviso y NO tiene ningun RAISE EXCEPTION
-- aplicable (es LANGUAGE sql, sin manejo de errores propio), por lo que no
-- se toca.
--
-- Firma, tipos, DEFAULTs, ERRCODEs y logica se preservan tal cual; solo se
-- agregan variables DECLARE (v_nombre_asig, v_nombre_area) y los SELECT de
-- lookup antes de cada RAISE afectado.

CREATE OR REPLACE FUNCTION academico_test.fn_criterio_prom_guardar(p_fk_periodo bigint, p_fk_grado bigint DEFAULT NULL::bigint, p_nodo_curricular academico_test.nodo_curricular DEFAULT NULL::character varying, p_cantidad_nivelar numeric DEFAULT NULL::numeric, p_asignatura_obligatoria academico_test.bool_sn DEFAULT NULL::character varying, p_aprobacion_promedio academico_test.bool_sn DEFAULT NULL::character varying, p_desempenho_min_general numeric DEFAULT NULL::numeric, p_desempenho_minimo numeric DEFAULT NULL::numeric, p_max_asig_promedio numeric DEFAULT NULL::numeric, p_minimo_inasistencias numeric DEFAULT NULL::numeric, p_max_asig_nivelar_prom numeric DEFAULT NULL::numeric, p_obligatorias bigint[] DEFAULT NULL::bigint[], p_pk_usuario_solicitante bigint DEFAULT NULL::bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_id BIGINT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    d academico_test.TCRITERIO_PROMOCION;
    v_pk BIGINT; v_asig BIGINT; v_area BIGINT;
    v_nombre_asig VARCHAR(130); v_nombre_area VARCHAR(130);
    v_nombre_grado VARCHAR(130); v_establecimiento_id BIGINT;
BEGIN
    -- Autorizacion (CU-86e2w4xdt): capability fail-fast + scope por (EE, sede,
    -- jornada) del periodo academico. Wrapper sobre fn_assert_permiso_seccion (V29).
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, NULL, NULL, NULL, 'EDITAR');
    IF p_fk_periodo IS NULL THEN
        RAISE EXCEPTION 'El periodo academico es obligatorio' USING ERRCODE = '22023';
    END IF;
    SELECT s.FK_TESTABLECIMIENTO INTO v_establecimiento_id
      FROM academico_test.TPERIODO_ACADEMICO pa
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE pa.PK_TPERIODO_ACADEMICO = p_fk_periodo;
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_establecimiento_id,
        academico_test.fn_periodo_sede(p_fk_periodo),
        academico_test.fn_periodo_jornada(p_fk_periodo), 'EDITAR');
    -- Ningun valor numerico puede ser negativo.
    IF p_cantidad_nivelar < 0 OR p_desempenho_min_general < 0 OR p_desempenho_minimo < 0
       OR p_max_asig_promedio < 0 OR p_minimo_inasistencias < 0 OR p_max_asig_nivelar_prom < 0 THEN
        RAISE EXCEPTION 'Los valores numericos del criterio de promocion no pueden ser negativos'
            USING ERRCODE = '22023';
    END IF;

    -- Buscar la fila existente (default del periodo o override del grado).
    IF p_fk_grado IS NULL THEN
        SELECT PK_TCRITERIO_PROMOCION INTO v_id FROM academico_test.TCRITERIO_PROMOCION
         WHERE FK_TPERIODO_ACADEMICO = p_fk_periodo AND FK_TGRADO IS NULL AND ACTIVE = TRUE;
    ELSE
        SELECT PK_TCRITERIO_PROMOCION INTO v_id FROM academico_test.TCRITERIO_PROMOCION
         WHERE FK_TGRADO = p_fk_grado AND ACTIVE = TRUE;
    END IF;

    IF p_fk_grado IS NOT NULL THEN
        SELECT NOMBRE INTO v_nombre_grado FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_grado;
    END IF;
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        CASE WHEN p_fk_grado IS NULL
             THEN 'Configuración del criterio de promoción general del periodo'
             ELSE format('Configuración del criterio de promoción del grado %s', v_nombre_grado)
        END,
        v_establecimiento_id);

    IF v_id IS NULL THEN
        -- Override de un grado: hereda del criterio por defecto del periodo lo que
        -- no venga en los parametros (red de seguridad ante un guardado parcial).
        -- Para el default (p_fk_grado NULL), d queda vacio (NULLs) y no altera nada.
        IF p_fk_grado IS NOT NULL THEN
            SELECT * INTO d FROM academico_test.TCRITERIO_PROMOCION
             WHERE FK_TPERIODO_ACADEMICO = p_fk_periodo AND FK_TGRADO IS NULL AND ACTIVE = TRUE;
        END IF;
        INSERT INTO academico_test.TCRITERIO_PROMOCION (
            FK_TPERIODO_ACADEMICO, FK_TGRADO, NODO_CURRICULAR, CANTIDAD_NIVELAR,
            ASIGNATURA_OBLIGATORIA, APROBACION_PROMEDIO, DESEMPENHO_MINIMO_GENERAL,
            DESEMPENHO_MINIMO, MAX_ASIG_PROMEDIO, MINIMO_INASISTENCIAS,
            MAX_ASIG_NIVELAR_PROMOVIDO, POR_DEFECTO, CREATED_BY
        ) VALUES (
            p_fk_periodo, p_fk_grado,
            COALESCE(p_nodo_curricular, d.NODO_CURRICULAR),
            COALESCE(p_cantidad_nivelar, d.CANTIDAD_NIVELAR, 0),
            COALESCE(p_asignatura_obligatoria, d.ASIGNATURA_OBLIGATORIA),
            COALESCE(p_aprobacion_promedio, d.APROBACION_PROMEDIO),
            COALESCE(p_desempenho_min_general, d.DESEMPENHO_MINIMO_GENERAL),
            COALESCE(p_desempenho_minimo, d.DESEMPENHO_MINIMO),
            COALESCE(p_max_asig_promedio, d.MAX_ASIG_PROMEDIO),
            COALESCE(p_minimo_inasistencias, d.MINIMO_INASISTENCIAS),
            COALESCE(p_max_asig_nivelar_prom, d.MAX_ASIG_NIVELAR_PROMOVIDO),
            CASE WHEN p_fk_grado IS NULL THEN 'S' ELSE 'N' END::academico_test.bool_sn, v_audit
        )
        RETURNING PK_TCRITERIO_PROMOCION INTO v_id;
    ELSE
        UPDATE academico_test.TCRITERIO_PROMOCION SET
            NODO_CURRICULAR = COALESCE(p_nodo_curricular, NODO_CURRICULAR),
            CANTIDAD_NIVELAR = COALESCE(p_cantidad_nivelar, CANTIDAD_NIVELAR),
            ASIGNATURA_OBLIGATORIA = COALESCE(p_asignatura_obligatoria, ASIGNATURA_OBLIGATORIA),
            APROBACION_PROMEDIO = COALESCE(p_aprobacion_promedio, APROBACION_PROMEDIO),
            DESEMPENHO_MINIMO_GENERAL = COALESCE(p_desempenho_min_general, DESEMPENHO_MINIMO_GENERAL),
            DESEMPENHO_MINIMO = COALESCE(p_desempenho_minimo, DESEMPENHO_MINIMO),
            MAX_ASIG_PROMEDIO = COALESCE(p_max_asig_promedio, MAX_ASIG_PROMEDIO),
            MINIMO_INASISTENCIAS = COALESCE(p_minimo_inasistencias, MINIMO_INASISTENCIAS),
            MAX_ASIG_NIVELAR_PROMOVIDO = COALESCE(p_max_asig_nivelar_prom, MAX_ASIG_NIVELAR_PROMOVIDO),
            MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TCRITERIO_PROMOCION = v_id;
    END IF;

    -- Areas/asignaturas obligatorias. Reescribe el set del criterio.
    -- p_nodo_curricular decide si los ids de p_obligatorias son de
    -- TASIGNATURA ('AS') o de TAREA ('AR') -- el lote es de un solo tipo,
    -- nunca mixto (asi lo arma el front, ver resolve-required-subjects.ts).
    IF p_obligatorias IS NOT NULL THEN
        UPDATE academico_test.TCRITERIO_PROMOCION_ASIGNATURA_OBLIGATORIA
           SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TCRITERIO_PROMOCION = v_id AND ACTIVE = TRUE;

        FOREACH v_pk IN ARRAY p_obligatorias
        LOOP
            v_asig := NULL; v_area := NULL;
            IF p_nodo_curricular = 'AS' THEN
                v_asig := v_pk;
                IF NOT EXISTS (
                    SELECT 1 FROM academico_test.TASIGNATURA s
                      JOIN academico_test.TAREA a ON a.PK_TAREA = s.FK_TAREA
                     WHERE s.PK_TASIGNATURA = v_asig AND s.ACTIVE = TRUE
                       AND a.FK_TPERIODO_ACADEMICO = p_fk_periodo
                ) THEN
                    SELECT s.NOMBRE INTO v_nombre_asig
                      FROM academico_test.TASIGNATURA s WHERE s.PK_TASIGNATURA = v_asig;
                    IF v_nombre_asig IS NOT NULL THEN
                        RAISE EXCEPTION 'La asignatura "%" no esta activa o no pertenece al periodo', v_nombre_asig
                            USING ERRCODE = '23503';
                    ELSE
                        RAISE EXCEPTION 'La asignatura no existe' USING ERRCODE = '23503';
                    END IF;
                END IF;
            ELSIF p_nodo_curricular = 'AR' THEN
                v_area := v_pk;
                IF NOT EXISTS (
                    SELECT 1 FROM academico_test.TAREA
                     WHERE PK_TAREA = v_area AND ACTIVE = TRUE
                       AND FK_TPERIODO_ACADEMICO = p_fk_periodo
                ) THEN
                    SELECT NOMBRE INTO v_nombre_area FROM academico_test.TAREA WHERE PK_TAREA = v_area;
                    IF v_nombre_area IS NOT NULL THEN
                        RAISE EXCEPTION 'El area "%" no esta activa o no pertenece al periodo', v_nombre_area
                            USING ERRCODE = '23503';
                    ELSE
                        RAISE EXCEPTION 'El area no existe' USING ERRCODE = '23503';
                    END IF;
                END IF;
            ELSE
                RAISE EXCEPTION 'nodo_curricular debe ser AS o AR para guardar obligatorias'
                    USING ERRCODE = '22023';
            END IF;
            -- Sin duplicados dentro del set.
            IF EXISTS (
                SELECT 1 FROM academico_test.TCRITERIO_PROMOCION_ASIGNATURA_OBLIGATORIA
                 WHERE FK_TCRITERIO_PROMOCION = v_id AND ACTIVE = TRUE
                   AND FK_TASIGNATURA IS NOT DISTINCT FROM v_asig
                   AND FK_TAREA IS NOT DISTINCT FROM v_area
            ) THEN
                IF v_asig IS NOT NULL THEN
                    SELECT NOMBRE INTO v_nombre_asig FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = v_asig;
                    RAISE EXCEPTION 'La asignatura "%" ya esta en la lista de obligatorias', v_nombre_asig
                        USING ERRCODE = '23505';
                ELSE
                    SELECT NOMBRE INTO v_nombre_area FROM academico_test.TAREA WHERE PK_TAREA = v_area;
                    RAISE EXCEPTION 'El area "%" ya esta en la lista de obligatorias', v_nombre_area
                        USING ERRCODE = '23505';
                END IF;
            END IF;
            INSERT INTO academico_test.TCRITERIO_PROMOCION_ASIGNATURA_OBLIGATORIA
                (FK_TCRITERIO_PROMOCION, FK_TASIGNATURA, FK_TAREA, CREATED_BY)
            VALUES (v_id, v_asig, v_area, v_audit);
        END LOOP;
    END IF;

    RETURN v_id;
END;
$function$
;
