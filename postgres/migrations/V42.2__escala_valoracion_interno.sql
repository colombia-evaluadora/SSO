-- ===========================================================================
-- V42.2 -- Escalas de valoracion: nucleos _interno
-- ===========================================================================
-- QUE HACE: guardar el lote de valoraciones, listar, dar de baja una banda o
-- una escala completa, y propagar la escala maestra, sin permisos. Validan
-- con V42.1 antes de escribir; el gate y la auditoria van en V42.3.
-- POR QUE AQUI: capa 2 del modulo (V42.1 / V42.2 / V42.3).
-- DEPENDE DE: V22, V42.1.
-- ===========================================================================

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_escala_guardar_bulk_interno(
    p_academic_period_id BIGINT,
    p_teaching_level_ids BIGINT[],
    p_scales             JSONB,
    p_audit              VARCHAR
)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_fmt TEXT; v_min NUMERIC; v_max NUMERIC;
    v_nivel BIGINT; v_nivel_nom TEXT; v_escala_id BIGINT; v_val_id BIGINT;
    v_tipo_id BIGINT; v_orden INT; v_count INT := 0;
    v_icono_id BIGINT; v_icono_cat TEXT; v_icono_url TEXT;
    v_carita TEXT; v_simbolo TEXT;
    scale JSONB;
BEGIN
    -- Solo CINCO/DIEZ cambian el maximo de la escala; el resto de formatos es 0-100.
    SELECT lv.VALOR INTO v_fmt
      FROM academico_test.TCRITERIO_EVALUACION ce
      JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = ce.FK_TLV_FORMATO_CALIFICACION
     WHERE ce.PK_TCRITERIO_EVALUACION = p_academic_period_id;
    v_min := 0;
    v_max := CASE UPPER(TRIM(COALESCE(v_fmt, ''))) WHEN 'CINCO' THEN 5 WHEN 'DIEZ' THEN 10 ELSE 100 END;

    PERFORM academico_test.fn_escala_validar_lote(p_scales, v_min, v_max);

    FOREACH v_nivel IN ARRAY ARRAY(SELECT DISTINCT unnest(p_teaching_level_ids)) LOOP
        PERFORM academico_test.fn_escala_validar_nivel_existe(v_nivel);
        SELECT NOMBRE INTO v_nivel_nom FROM academico_test.TNIVEL_ENSENANZA WHERE PK_NIVEL_ENSENANZA = v_nivel;

        PERFORM pg_advisory_xact_lock(hashtext(p_academic_period_id::text || ':' || v_nivel::text));

        SELECT ne.FK_TESCALA INTO v_escala_id FROM academico_test.TNIVEL_ESCALA ne
         WHERE ne.FK_TNIVEL_ENSENANZA = v_nivel AND ne.FK_PERIODO_ACADEMICO = p_academic_period_id
           AND ne.ACTIVE = TRUE;
        IF v_escala_id IS NULL THEN
            INSERT INTO academico_test.TESCALA (CODIGO, NOMBRE, CREATED_BY)
            VALUES (LEFT(v_nivel_nom, 30), v_nivel_nom, p_audit) RETURNING PK_TESCALA INTO v_escala_id;
            INSERT INTO academico_test.TNIVEL_ESCALA (FK_TNIVEL_ENSENANZA, FK_TESCALA, FK_PERIODO_ACADEMICO, CREATED_BY)
            VALUES (v_nivel, v_escala_id, p_academic_period_id, p_audit);
        END IF;

        SELECT COALESCE(MAX(ORDEN), 0) INTO v_orden FROM academico_test.TESCALA_VALORACION WHERE FK_TESCALA = v_escala_id;

        FOR scale IN SELECT * FROM jsonb_array_elements(p_scales) LOOP
            v_tipo_id := NULLIF(scale->>'tipoId', '')::BIGINT;
            PERFORM academico_test.fn_escala_validar_tipo_valoracion(v_tipo_id);
            -- El icono llega como id + categoria; se guarda su URL (VALOR) en la columna de esa categoria.
            v_icono_id  := NULLIF(scale->>'iconoId', '')::BIGINT;
            v_icono_cat := NULLIF(TRIM(scale->>'iconoCategoria'), '');
            v_carita := NULL; v_simbolo := NULL;
            IF v_icono_id IS NOT NULL THEN
                PERFORM academico_test.fn_escala_validar_icono(v_icono_id, v_icono_cat);
                SELECT lv.VALOR INTO v_icono_url
                  FROM academico_test.TLISTA_VALOR lv
                 WHERE lv.PK_LISTA_VALOR = v_icono_id AND lv.CATEGORIA = v_icono_cat;
                IF v_icono_cat = 'GRAFICA_CARITA' THEN v_carita := v_icono_url; ELSE v_simbolo := v_icono_url; END IF;
            END IF;
            INSERT INTO academico_test.TVALORACION
                (CODIGO, NOMBRE, FK_TVL_TIPO_VALORACION, GRAFICA_CARITAS, GRAFICA_SIMBOLO, CREATED_BY)
            VALUES (scale->>'abreviacion', scale->>'nombre', v_tipo_id, v_carita, v_simbolo, p_audit)
            RETURNING PK_TVALORACION INTO v_val_id;
            v_orden := v_orden + 1;
            -- Los limites se guardan en porcentaje 0-100, sea cual sea el formato.
            INSERT INTO academico_test.TESCALA_VALORACION
                (FK_TESCALA, FK_TVALORACION, FK_TVL_TIPO_VALORACION, ORDEN,
                 LIMITE_INFERIOR, LIMITE_SUPERIOR, LIMITE_PROMEDIO, CREATED_BY)
            VALUES (v_escala_id, v_val_id, v_tipo_id, v_orden,
                ((scale->>'notaMinima')::NUMERIC - v_min) / (v_max - v_min) * 100,
                ((scale->>'notaMaxima')::NUMERIC - v_min) / (v_max - v_min) * 100,
                ((scale->>'notaEquivalente')::NUMERIC - v_min) / (v_max - v_min) * 100, p_audit);
            v_count := v_count + 1;
        END LOOP;
    END LOOP;

    RETURN v_count;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_escala_guardar_bulk_interno(BIGINT, BIGINT[], JSONB, VARCHAR)
    IS 'INTERNO: valida el lote y anade sus valoraciones a la escala de cada nivel del periodo (la crea si no existe). Devuelve las bandas insertadas. Lo usa fn_escala_guardar_bulk.';

CREATE OR REPLACE FUNCTION academico_test.fn_escala_listar_interno(
    p_academic_period_id BIGINT,
    p_filtro             TEXT DEFAULT NULL,
    p_teaching_level_id  BIGINT DEFAULT NULL,
    p_sort_by            TEXT DEFAULT NULL,
    p_sort_dir           TEXT DEFAULT NULL,
    p_tipo               TEXT DEFAULT NULL
)
RETURNS TABLE(id bigint, nombre character varying, abreviacion character varying, tipo character varying, tipo_name character varying, iconografia character varying, teaching_level_id bigint, teaching_level_name character varying, nota_minima numeric, nota_maxima numeric, nota_equivalente numeric, escala_id bigint)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_col TEXT;
    v_dir TEXT;
BEGIN
    v_col := CASE lower(coalesce(p_sort_by, ''))
        WHEN 'nombre'            THEN 'v.NOMBRE'
        WHEN 'abreviacion'       THEN 'v.CODIGO'
        WHEN 'tipo'              THEN 'tv.VALOR'
        WHEN 'teachinglevelname' THEN 'nen.NOMBRE'
        WHEN 'notaminima'        THEN 'nota_minima'
        WHEN 'notamaxima'        THEN 'nota_maxima'
        WHEN 'notaequivalente'   THEN 'nota_equivalente'
        ELSE 'ne.FK_TNIVEL_ENSENANZA'
    END;
    v_dir := CASE WHEN lower(coalesce(p_sort_dir, '')) = 'desc' THEN 'DESC' ELSE 'ASC' END;

    -- Sin criterio de evaluacion no hay formato y fmt queda vacio: el listado sale vacio.
    RETURN QUERY EXECUTE format($q$
        WITH fmt AS (
            SELECT 0::numeric AS mn,
                   CASE UPPER(TRIM(lv.VALOR)) WHEN 'CINCO' THEN 5 WHEN 'DIEZ' THEN 10 ELSE 100 END::numeric AS mx
              FROM academico_test.TCRITERIO_EVALUACION ce
              JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = ce.FK_TLV_FORMATO_CALIFICACION
             WHERE ce.PK_TCRITERIO_EVALUACION = $1
        )
        SELECT ev.PK_TESCALA_VALORACION, v.NOMBRE, v.CODIGO, tv.VALOR, tv.NOMBRE,
               COALESCE(v.GRAFICA_CARITAS, v.GRAFICA_SIMBOLO),
               ne.FK_TNIVEL_ENSENANZA, nen.NOMBRE,
               round(ev.LIMITE_INFERIOR / 100 * (fmt.mx - fmt.mn) + fmt.mn, 2) AS nota_minima,
               round(ev.LIMITE_SUPERIOR / 100 * (fmt.mx - fmt.mn) + fmt.mn, 2) AS nota_maxima,
               round(ev.LIMITE_PROMEDIO / 100 * (fmt.mx - fmt.mn) + fmt.mn, 2) AS nota_equivalente,
               ev.FK_TESCALA
          FROM academico_test.TESCALA_VALORACION ev
          JOIN academico_test.TVALORACION v    ON v.PK_TVALORACION = ev.FK_TVALORACION
          JOIN academico_test.TLISTA_VALOR tv  ON tv.PK_LISTA_VALOR = ev.FK_TVL_TIPO_VALORACION
          JOIN academico_test.TNIVEL_ESCALA ne ON ne.FK_TESCALA = ev.FK_TESCALA
          JOIN academico_test.TNIVEL_ENSENANZA nen ON nen.PK_NIVEL_ENSENANZA = ne.FK_TNIVEL_ENSENANZA
          CROSS JOIN fmt
         WHERE ne.FK_PERIODO_ACADEMICO = $1 AND ev.ACTIVE = TRUE
           AND ($3 IS NULL OR ne.FK_TNIVEL_ENSENANZA = $3)
           AND ($4 IS NULL OR tv.VALOR = $4)
           AND ($2 IS NULL OR v.NOMBRE ILIKE '%%' || $2 || '%%' OR v.CODIGO ILIKE '%%' || $2 || '%%')
         ORDER BY %s %s, ev.ORDEN
    $q$, v_col, v_dir)
    USING p_academic_period_id, NULLIF(TRIM(p_filtro),''), p_teaching_level_id, NULLIF(TRIM(p_tipo),'');
END;
$$;

COMMENT ON FUNCTION academico_test.fn_escala_listar_interno(BIGINT, TEXT, BIGINT, TEXT, TEXT, TEXT)
    IS 'INTERNO: bandas activas de las escalas de nivel de un periodo academico, con las notas en el formato del criterio de evaluacion, sin alcance. Lo usa fn_escala_listar (pantalla y reporte).';

-- El wrapper ya comprobo existencia y estado.
CREATE OR REPLACE FUNCTION academico_test.fn_escala_valoracion_eliminar_interno(p_pk BIGINT, p_audit VARCHAR)
RETURNS BIGINT LANGUAGE plpgsql AS $$
BEGIN
    PERFORM academico_test.fn_escala_valoracion_validar_sin_uso(p_pk);
    UPDATE academico_test.TESCALA_VALORACION
       SET ACTIVE = FALSE, MODIFIED_BY = p_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TESCALA_VALORACION = p_pk AND ACTIVE = TRUE;
    RETURN p_pk;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_escala_valoracion_eliminar_interno(BIGINT, VARCHAR)
    IS 'INTERNO: baja logica de una banda; 23503 si la usan criterios de unidad. Lo usa fn_escala_eliminar.';

-- Con p_fk_periodo + p_fk_nivel solo se da de baja ese vinculo nivel-escala (y los mensajes nombran el nivel).
CREATE OR REPLACE FUNCTION academico_test.fn_escala_cascada_eliminar_interno(
    p_escala     BIGINT,
    p_audit      VARCHAR,
    p_fk_periodo BIGINT DEFAULT NULL,
    p_fk_nivel   BIGINT DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
BEGIN
    PERFORM academico_test.fn_escala_validar_sin_bandas_en_uso(p_escala, p_fk_nivel);
    PERFORM academico_test.fn_escala_validar_no_es_maestra(p_escala, p_fk_nivel);

    UPDATE academico_test.TVALORACION
       SET ACTIVE = FALSE, MODIFIED_BY = p_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TVALORACION IN (
         SELECT FK_TVALORACION FROM academico_test.TESCALA_VALORACION
          WHERE FK_TESCALA = p_escala AND ACTIVE = TRUE
     );
    UPDATE academico_test.TESCALA_VALORACION
       SET ACTIVE = FALSE, MODIFIED_BY = p_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TESCALA = p_escala AND ACTIVE = TRUE;
    UPDATE academico_test.TNIVEL_ESCALA
       SET ACTIVE = FALSE, MODIFIED_BY = p_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TESCALA = p_escala AND ACTIVE = TRUE
       AND (p_fk_periodo IS NULL OR FK_PERIODO_ACADEMICO = p_fk_periodo)
       AND (p_fk_nivel IS NULL OR FK_TNIVEL_ENSENANZA = p_fk_nivel);
    UPDATE academico_test.TESCALA
       SET ACTIVE = FALSE, MODIFIED_BY = p_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TESCALA = p_escala AND ACTIVE = TRUE;
    RETURN p_escala;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_escala_cascada_eliminar_interno(BIGINT, VARCHAR, BIGINT, BIGINT)
    IS 'INTERNO: baja logica de una escala con sus valoraciones, bandas y vinculos de nivel; 23503 si tiene bandas en uso o es la maestra de un criterio. Lo usan fn_escala_bulk_delete y fn_escala_nivel_soft_delete.';

CREATE OR REPLACE FUNCTION academico_test.fn_escala_propagar(
    p_pk_periodo BIGINT, p_fk_escala_source BIGINT, p_audit VARCHAR
)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_target BIGINT; v_orden INT; v_new_val BIGINT; sb RECORD;
BEGIN
    -- Sin bandas activas en el maestro no se propaga, para no vaciar las demas escalas.
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TESCALA_VALORACION
         WHERE FK_TESCALA = p_fk_escala_source AND ACTIVE = TRUE
    ) THEN
        RETURN;
    END IF;

    FOR v_target IN
        SELECT DISTINCT ne.FK_TESCALA FROM academico_test.TNIVEL_ESCALA ne
         WHERE ne.FK_PERIODO_ACADEMICO = p_pk_periodo AND ne.ACTIVE = TRUE
           AND ne.FK_TESCALA <> p_fk_escala_source
    LOOP
        -- Bandas ya en uso por criterios de unidad no se tocan: darlas de baja dejaria
        -- el descriptor apuntando a una banda inactiva sobre datos ya calificados.
        IF EXISTS (
            SELECT 1 FROM academico_test.TNIVEL_CRITERIO_UNIDAD ncu
              JOIN academico_test.TESCALA_VALORACION ev2
                ON ev2.PK_TESCALA_VALORACION = ncu.FK_TESCALA_VALORACION
             WHERE ev2.FK_TESCALA = v_target
        ) THEN
            CONTINUE;
        END IF;
        UPDATE academico_test.TVALORACION
           SET ACTIVE = FALSE, MODIFIED_BY = p_audit, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TVALORACION IN (
             SELECT FK_TVALORACION FROM academico_test.TESCALA_VALORACION
              WHERE FK_TESCALA = v_target AND ACTIVE = TRUE
         );
        UPDATE academico_test.TESCALA_VALORACION
           SET ACTIVE = FALSE, MODIFIED_BY = p_audit, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TESCALA = v_target AND ACTIVE = TRUE;
        -- Incluye inactivas para no reusar valores de ORDEN y chocar con U_TESCALA_VALORACION_2.
        SELECT COALESCE(MAX(ORDEN), 0) INTO v_orden
          FROM academico_test.TESCALA_VALORACION WHERE FK_TESCALA = v_target;
        FOR sb IN
            SELECT ev.FK_TVL_TIPO_VALORACION AS tipo, ev.LIMITE_INFERIOR AS li,
                   ev.LIMITE_SUPERIOR AS ls, ev.LIMITE_PROMEDIO AS lp,
                   v.NOMBRE, v.CODIGO, v.GRAFICA_CARITAS, v.GRAFICA_SIMBOLO
              FROM academico_test.TESCALA_VALORACION ev
              JOIN academico_test.TVALORACION v ON v.PK_TVALORACION = ev.FK_TVALORACION
             WHERE ev.FK_TESCALA = p_fk_escala_source AND ev.ACTIVE = TRUE
             ORDER BY ev.ORDEN
        LOOP
            INSERT INTO academico_test.TVALORACION
                (CODIGO, NOMBRE, FK_TVL_TIPO_VALORACION, GRAFICA_CARITAS, GRAFICA_SIMBOLO, CREATED_BY)
            VALUES (sb.CODIGO, sb.NOMBRE, sb.tipo, sb.GRAFICA_CARITAS, sb.GRAFICA_SIMBOLO, p_audit)
            RETURNING PK_TVALORACION INTO v_new_val;
            v_orden := v_orden + 1;
            INSERT INTO academico_test.TESCALA_VALORACION
                (FK_TESCALA, FK_TVALORACION, FK_TVL_TIPO_VALORACION, ORDEN,
                 LIMITE_INFERIOR, LIMITE_SUPERIOR, LIMITE_PROMEDIO, CREATED_BY)
            VALUES (v_target, v_new_val, sb.tipo, v_orden, sb.li, sb.ls, sb.lp, p_audit);
        END LOOP;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_escala_propagar(BIGINT, BIGINT, VARCHAR)
    IS 'INTERNO: copia las bandas activas de la escala maestra a las demas escalas de nivel del periodo, salvo las que tienen bandas en uso. No declara etiqueta de auditoria: la pone quien la llama. La usa fn_criterio_eval_actualizar_interno.';
