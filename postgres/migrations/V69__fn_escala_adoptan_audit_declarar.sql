-- V69 — adopta fn_audit_declarar en las funciones de escritura de escalas
-- de valoración (docs/etiqueta-catalogo-funciones-fn.md §10) que son puntos
-- de entrada reales (llaman su propio fn_periodo_gate_escritura con
-- p_pk_usuario_solicitante).
--
-- fn_enfasis_desde_seleccion, fn_enfasis_resolver y fn_escala_propagar se
-- excluyen a propósito — son funciones internas llamadas DESDE otras (p.ej.
-- fn_subject_crear/fn_subject_guardar_bulk), y como set_config(...,true) es
-- local a la transacción, si ellas también declararan su propia etiqueta
-- pisarían la del caller que ya la declaró (última llamada gana) — ver
-- docs/etiqueta-auditoria-cdc-analisis.md §6.2 nota de merge-safety y el
-- catálogo §20 ("solo la función de entrada declara la etiqueta").

CREATE OR REPLACE FUNCTION academico_test.fn_escala_eliminar(p_pk bigint, p_pk_usuario_solicitante bigint)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_n INT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_establecimiento_id BIGINT; v_nombre VARCHAR(130);
BEGIN
    SELECT academico_test.fn_periodo_establecimiento(ne.FK_PERIODO_ACADEMICO), val.NOMBRE
      INTO v_establecimiento_id, v_nombre
      FROM academico_test.TESCALA_VALORACION ev
      JOIN academico_test.TNIVEL_ESCALA ne ON ne.FK_TESCALA = ev.FK_TESCALA AND ne.ACTIVE = TRUE
      LEFT JOIN academico_test.TVALORACION val ON val.PK_TVALORACION = ev.FK_TVALORACION
     WHERE ev.PK_TESCALA_VALORACION = p_pk;
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, v_establecimiento_id);

    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante, format('Eliminación de la banda de valoración %s', COALESCE(v_nombre, p_pk::TEXT)),
        v_establecimiento_id);

    UPDATE academico_test.TESCALA_VALORACION SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TESCALA_VALORACION = p_pk AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN RAISE EXCEPTION 'No existe una banda activa con PK %', p_pk USING ERRCODE = 'P0002'; END IF;
    RETURN p_pk;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_escala_guardar_bulk(
    p_academic_period_id bigint, p_teaching_level_ids bigint[], p_scales jsonb, p_pk_usuario_solicitante bigint
) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_fmt TEXT; v_min NUMERIC; v_max NUMERIC;
    v_nivel BIGINT; v_nivel_nom TEXT; v_escala_id BIGINT; v_val_id BIGINT;
    v_tipo_id BIGINT; v_orden INT; v_count INT := 0;
    v_nmin NUMERIC; v_nmax NUMERIC; v_neq NUMERIC;
    v_niveles BIGINT[];
    v_icono_id BIGINT; v_icono_cat TEXT; v_icono_url TEXT;
    v_carita TEXT; v_simbolo TEXT;
    scale jsonb;
    v_establecimiento_id BIGINT := academico_test.fn_periodo_establecimiento(p_academic_period_id);
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, v_establecimiento_id);

    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante, 'Configuración masiva de escalas de valoración', v_establecimiento_id);

    -- Rango del formato de calificacion del periodo (para % ). El rango base es
    -- 0-100; solo "DE CERO A CINCO"/"DE CERO A DIEZ" cambian el maximo. El resto
    -- (DE CERO A CIEN, Caritas, Simbolos, Valoraciones, ...) es 0-100.
    SELECT lv.VALOR INTO v_fmt
      FROM academico_test.TCRITERIO_EVALUACION ce
      JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = ce.FK_TLV_FORMATO_CALIFICACION
     WHERE ce.PK_TCRITERIO_EVALUACION = p_academic_period_id;
    v_min := 0;
    v_max := CASE UPPER(TRIM(COALESCE(v_fmt, '')))
               WHEN 'DE CERO A CINCO' THEN 5
               WHEN 'DE CERO A DIEZ'  THEN 10
               ELSE 100
             END;

    -- Validaciones del lote.
    IF (SELECT count(*) FROM jsonb_array_elements(p_scales))
       <> (SELECT count(DISTINCT s->>'nombre') FROM jsonb_array_elements(p_scales) s) THEN
        RAISE EXCEPTION 'El lote trae valoraciones con nombre repetido' USING ERRCODE = '22023';
    END IF;
    FOR scale IN SELECT * FROM jsonb_array_elements(p_scales) LOOP
        v_nmin := (scale->>'notaMinima')::NUMERIC; v_nmax := (scale->>'notaMaxima')::NUMERIC;
        v_neq := (scale->>'notaEquivalente')::NUMERIC;
        IF v_nmin > v_nmax THEN
            RAISE EXCEPTION 'Valoracion "%": nota minima > maxima', scale->>'nombre' USING ERRCODE = '22023';
        END IF;
        IF v_neq < v_nmin OR v_neq > v_nmax THEN
            RAISE EXCEPTION 'Valoracion "%": equivalente fuera de rango', scale->>'nombre' USING ERRCODE = '22023';
        END IF;
        IF v_nmin < v_min OR v_nmax > v_max THEN
            RAISE EXCEPTION 'Valoracion "%": notas fuera del formato (% a %)', scale->>'nombre', v_min, v_max
                USING ERRCODE = '22023';
        END IF;
    END LOOP;

    -- Por cada nivel (sin repetir).
    v_niveles := ARRAY(SELECT DISTINCT unnest(p_teaching_level_ids));
    FOREACH v_nivel IN ARRAY v_niveles
    LOOP
        SELECT NOMBRE INTO v_nivel_nom FROM academico_test.TNIVEL_ENSENANZA WHERE PK_NIVEL_ENSENANZA = v_nivel;
        IF v_nivel_nom IS NULL THEN
            RAISE EXCEPTION 'El nivel de enseñanza % no existe', v_nivel USING ERRCODE = '23503';
        END IF;

        PERFORM pg_advisory_xact_lock(hashtext(p_academic_period_id::text || ':' || v_nivel::text));

        SELECT ne.FK_TESCALA INTO v_escala_id FROM academico_test.TNIVEL_ESCALA ne
         WHERE ne.FK_TNIVEL_ENSENANZA = v_nivel AND ne.FK_PERIODO_ACADEMICO = p_academic_period_id
           AND ne.ACTIVE = TRUE;
        IF v_escala_id IS NULL THEN
            INSERT INTO academico_test.TESCALA (CODIGO, NOMBRE, CREATED_BY)
            VALUES (LEFT(v_nivel_nom, 30), v_nivel_nom, v_audit) RETURNING PK_TESCALA INTO v_escala_id;
            INSERT INTO academico_test.TNIVEL_ESCALA (FK_TNIVEL_ENSENANZA, FK_TESCALA, FK_PERIODO_ACADEMICO, CREATED_BY)
            VALUES (v_nivel, v_escala_id, p_academic_period_id, v_audit);
        END IF;

        SELECT COALESCE(MAX(ORDEN), 0) INTO v_orden FROM academico_test.TESCALA_VALORACION WHERE FK_TESCALA = v_escala_id;

        FOR scale IN SELECT * FROM jsonb_array_elements(p_scales) LOOP
            -- Tipo de valoracion: el front manda el id de TLISTA_VALOR
            -- (categoria 'TIPO_VALORACION', p. ej. Fortaleza/Debilidad).
            v_tipo_id := NULLIF(scale->>'tipoId', '')::BIGINT;
            IF v_tipo_id IS NULL OR NOT EXISTS (
                SELECT 1 FROM academico_test.TLISTA_VALOR
                 WHERE PK_LISTA_VALOR = v_tipo_id AND CATEGORIA = 'TIPO_VALORACION' AND ACTIVE = TRUE
            ) THEN
                RAISE EXCEPTION 'El tipo de valoracion % no existe o no es valido', v_tipo_id USING ERRCODE = '23503';
            END IF;
            -- Icono: el front manda el id de TLISTA_VALOR y su categoria
            -- ('GRAFICA_CARITA' o 'GRAFICA_SIMBOLO'). Resolvemos la URL (VALOR) y
            -- la guardamos en GRAFICA_CARITAS o GRAFICA_SIMBOLO segun corresponda.
            v_icono_id  := NULLIF(scale->>'iconoId', '')::BIGINT;
            v_icono_cat := NULLIF(TRIM(scale->>'iconoCategoria'), '');
            v_carita := NULL; v_simbolo := NULL;
            IF v_icono_id IS NOT NULL THEN
                SELECT lv.VALOR INTO v_icono_url
                  FROM academico_test.TLISTA_VALOR lv
                 WHERE lv.PK_LISTA_VALOR = v_icono_id
                   AND lv.CATEGORIA = v_icono_cat
                   AND lv.CATEGORIA IN ('GRAFICA_CARITA', 'GRAFICA_SIMBOLO')
                   AND lv.ACTIVE = TRUE;
                IF v_icono_url IS NULL THEN
                    RAISE EXCEPTION 'El icono % (categoria %) no existe o no es una grafica valida', v_icono_id, v_icono_cat
                        USING ERRCODE = '23503';
                END IF;
                IF v_icono_cat = 'GRAFICA_CARITA' THEN v_carita := v_icono_url; ELSE v_simbolo := v_icono_url; END IF;
            END IF;
            INSERT INTO academico_test.TVALORACION
                (CODIGO, NOMBRE, FK_TVL_TIPO_VALORACION, GRAFICA_CARITAS, GRAFICA_SIMBOLO, CREATED_BY)
            VALUES (scale->>'abreviacion', scale->>'nombre', v_tipo_id, v_carita, v_simbolo, v_audit)
            RETURNING PK_TVALORACION INTO v_val_id;
            v_orden := v_orden + 1;
            INSERT INTO academico_test.TESCALA_VALORACION
                (FK_TESCALA, FK_TVALORACION, FK_TVL_TIPO_VALORACION, ORDEN,
                 LIMITE_INFERIOR, LIMITE_SUPERIOR, LIMITE_PROMEDIO, CREATED_BY)
            VALUES (v_escala_id, v_val_id, v_tipo_id, v_orden,
                ((scale->>'notaMinima')::NUMERIC - v_min) / (v_max - v_min) * 100,
                ((scale->>'notaMaxima')::NUMERIC - v_min) / (v_max - v_min) * 100,
                ((scale->>'notaEquivalente')::NUMERIC - v_min) / (v_max - v_min) * 100, v_audit);
            v_count := v_count + 1;
        END LOOP;
    END LOOP;

    RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_escala_nivel_soft_delete(
    p_academic_period_id bigint, p_teaching_level_id bigint, p_pk_usuario_solicitante bigint
) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_escala BIGINT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_establecimiento_id BIGINT := academico_test.fn_periodo_establecimiento(p_academic_period_id);
    v_nivel_nombre VARCHAR(130);
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, v_establecimiento_id);
    SELECT ne.FK_TESCALA INTO v_escala FROM academico_test.TNIVEL_ESCALA ne
     WHERE ne.FK_PERIODO_ACADEMICO = p_academic_period_id
       AND ne.FK_TNIVEL_ENSENANZA = p_teaching_level_id AND ne.ACTIVE = TRUE;
    IF v_escala IS NULL THEN
        RAISE EXCEPTION 'No existe una escala activa para el periodo % y nivel %', p_academic_period_id, p_teaching_level_id
            USING ERRCODE = 'P0002';
    END IF;
    SELECT NOMBRE INTO v_nivel_nombre FROM academico_test.TNIVEL_ENSENANZA WHERE PK_NIVEL_ENSENANZA = p_teaching_level_id;
    -- Bloqueo: bandas en uso por criterios de unidad.
    IF EXISTS (
        SELECT 1 FROM academico_test.TNIVEL_CRITERIO_UNIDAD ncu
          JOIN academico_test.TESCALA_VALORACION ev ON ev.PK_TESCALA_VALORACION = ncu.FK_TESCALA_VALORACION
         WHERE ev.FK_TESCALA = v_escala AND ncu.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar la escala del nivel %: hay bandas en uso por criterios de unidad', p_teaching_level_id
            USING ERRCODE = '23503';
    END IF;

    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        format('Eliminación de la escala de valoración del nivel %s', COALESCE(v_nivel_nombre, p_teaching_level_id::TEXT)),
        v_establecimiento_id);

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
