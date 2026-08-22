-- fn_escala_guardar_bulk y fn_escala_listar resuelven el rango del formato
-- de calificacion contra TLISTA_VALOR.VALOR (categoria FORMATO_CALIFICACION),
-- pero comparaban ese VALOR contra el texto humano completo
-- ('DE CERO A CINCO', 'DE CERO A DIEZ') -- el VALOR real es un codigo corto
-- (confirmado: PK 51857 NOMBRE='DE CERO A CINCO' pero VALOR='CINCO'; PK 51882
-- NOMBRE='DE CERO A DIEZ' VALOR='DIEZ'; PK 51889 NOMBRE='DE CERO A CIEN'
-- VALOR='CIEN'). La comparacion nunca matcheaba 'CINCO'/'DIEZ' contra el
-- texto largo, asi que el rango caia siempre al ELSE 100 sin importar el
-- formato real del periodo.
--
-- Efecto del bug: una banda creada con formato "DE CERO A CINCO" mandando
-- notaMaxima=5 se guardaba con LIMITE_SUPERIOR = (5-0)/(100-0)*100 = 5 en vez
-- de (5-0)/(5-0)*100 = 100. Al leer, la misma banda se reconvertia con el
-- mismo ELSE 100 (round(5/100*100,2) = 5) -- guardado y lectura se
-- compensaban entre si MIENTRAS el formato real fuera "DE CERO A CIEN"
-- (donde el ELSE 100 es coincidencialmente correcto). En cuanto el formato
-- del periodo cambiaba a "DE CERO A CINCO"/"DE CERO A DIEZ", la lectura
-- seguia cayendo en ELSE 100 (el bug no se corrige solo), y una banda vieja
-- guardada como 20 (bajo el formato anterior 0-100) se seguia mostrando "20"
-- en vez de re-escalarse a "1" -- exactamente el sintoma reportado.
--
-- Fix: los literales del CASE pasan a ser los codigos reales de VALOR
-- ('CINCO'/'DIEZ'), no el texto de NOMBRE.

CREATE OR REPLACE FUNCTION academico_test.fn_escala_guardar_bulk(
    p_academic_period_id BIGINT,
    p_teaching_level_ids BIGINT[],
    p_scales jsonb,
    p_pk_usuario_solicitante BIGINT
)
RETURNS INTEGER LANGUAGE plpgsql AS $$
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
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, academico_test.fn_periodo_establecimiento(p_academic_period_id));

    -- Rango del formato de calificacion del periodo (para % ). El rango base es
    -- 0-100; solo "CINCO"/"DIEZ" (VALOR) cambian el maximo. El resto (CIEN,
    -- CARITA, SIMBOLO, LITERAL, ...) es 0-100.
    SELECT lv.VALOR INTO v_fmt
      FROM academico_test.TCRITERIO_EVALUACION ce
      JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = ce.FK_TLV_FORMATO_CALIFICACION
     WHERE ce.PK_TCRITERIO_EVALUACION = p_academic_period_id;
    v_min := 0;
    v_max := CASE UPPER(TRIM(COALESCE(v_fmt, '')))
               WHEN 'CINCO' THEN 5
               WHEN 'DIEZ'  THEN 10
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

DROP FUNCTION IF EXISTS academico_test.fn_escala_listar(BIGINT, TEXT, BIGINT, BIGINT, TEXT, TEXT);
CREATE OR REPLACE FUNCTION academico_test.fn_escala_listar(
    p_academic_period_id BIGINT, p_filtro TEXT DEFAULT NULL,
    p_pk_usuario BIGINT DEFAULT NULL,
    p_teaching_level_id BIGINT DEFAULT NULL,
    p_sort_by TEXT DEFAULT NULL,
    p_sort_dir TEXT DEFAULT NULL
)
RETURNS TABLE (
    id BIGINT, nombre VARCHAR, abreviacion VARCHAR, tipo VARCHAR, tipo_name VARCHAR, iconografia VARCHAR,
    teaching_level_id BIGINT, teaching_level_name VARCHAR,
    nota_minima NUMERIC, nota_maxima NUMERIC, nota_equivalente NUMERIC
)
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

    RETURN QUERY EXECUTE format($q$
        WITH fmt AS (
            SELECT 0::numeric AS mn,
                   CASE UPPER(TRIM(lv.VALOR))
                     WHEN 'CINCO' THEN 5
                     WHEN 'DIEZ'  THEN 10
                     ELSE 100
                   END::numeric AS mx
              FROM academico_test.TCRITERIO_EVALUACION ce
              JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = ce.FK_TLV_FORMATO_CALIFICACION
             WHERE ce.PK_TCRITERIO_EVALUACION = $1
        )
        SELECT ev.PK_TESCALA_VALORACION, v.NOMBRE, v.CODIGO, tv.VALOR, tv.NOMBRE,
               COALESCE(v.GRAFICA_CARITAS, v.GRAFICA_SIMBOLO),
               ne.FK_TNIVEL_ENSENANZA, nen.NOMBRE,
               round(ev.LIMITE_INFERIOR / 100 * (fmt.mx - fmt.mn) + fmt.mn, 2) AS nota_minima,
               round(ev.LIMITE_SUPERIOR / 100 * (fmt.mx - fmt.mn) + fmt.mn, 2) AS nota_maxima,
               round(ev.LIMITE_PROMEDIO / 100 * (fmt.mx - fmt.mn) + fmt.mn, 2) AS nota_equivalente
          FROM academico_test.TESCALA_VALORACION ev
          JOIN academico_test.TVALORACION v    ON v.PK_TVALORACION = ev.FK_TVALORACION
          JOIN academico_test.TLISTA_VALOR tv  ON tv.PK_LISTA_VALOR = ev.FK_TVL_TIPO_VALORACION
          JOIN academico_test.TNIVEL_ESCALA ne ON ne.FK_TESCALA = ev.FK_TESCALA
          JOIN academico_test.TNIVEL_ENSENANZA nen ON nen.PK_NIVEL_ENSENANZA = ne.FK_TNIVEL_ENSENANZA
          CROSS JOIN fmt
         WHERE ne.FK_PERIODO_ACADEMICO = $1 AND ev.ACTIVE = TRUE
           AND ($4 IS NULL OR ne.FK_TNIVEL_ENSENANZA = $4)
           AND academico_test.fn_periodo_usuario_puede_ver($3, $1)
           AND ($2 IS NULL OR v.NOMBRE ILIKE '%%' || $2 || '%%' OR v.CODIGO ILIKE '%%' || $2 || '%%')
         ORDER BY %s %s, ev.ORDEN
    $q$, v_col, v_dir)
    USING p_academic_period_id, NULLIF(TRIM(p_filtro),''), p_pk_usuario, p_teaching_level_id;
END;
$$;
