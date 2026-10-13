-- ===========================================================================
-- V42.1 -- Escalas de valoracion: validaciones
-- ===========================================================================
-- QUE HACE: una fn_escala_validar_<regla> por regla (RETURNS VOID, lanza o
-- nada) y fn_escala_validar_lote, que compone las del lote de POST /escalas.
-- POR QUE AQUI: capa 1 del modulo (V42.1 validaciones / V42.2 nucleos /
-- V42.3 wrappers); los endpoints siguen en V78 porque necesitan eval-col.
-- DEPENDE DE: V22 (TESCALA, TESCALA_VALORACION, TNIVEL_ESCALA, TVALORACION,
-- TNIVEL_CRITERIO_UNIDAD, TCRITERIO_EVALUACION, TLISTA_VALOR).
-- ===========================================================================

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_escala_validar_nombres_unicos(p_scales JSONB)
RETURNS VOID LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF (SELECT count(*) FROM jsonb_array_elements(p_scales))
       <> (SELECT count(DISTINCT s->>'nombre') FROM jsonb_array_elements(p_scales) s) THEN
        RAISE EXCEPTION 'El lote trae valoraciones con nombre repetido' USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_escala_validar_minima_maxima(
    p_nombre TEXT, p_nmin NUMERIC, p_nmax NUMERIC
)
RETURNS VOID LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_nmin > p_nmax THEN
        RAISE EXCEPTION 'Valoracion "%": nota minima > maxima', p_nombre USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_escala_validar_equivalente(
    p_nombre TEXT, p_nmin NUMERIC, p_nmax NUMERIC, p_neq NUMERIC
)
RETURNS VOID LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_neq < p_nmin OR p_neq > p_nmax THEN
        RAISE EXCEPTION 'Valoracion "%": equivalente fuera de rango', p_nombre USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_escala_validar_formato(
    p_nombre TEXT, p_nmin NUMERIC, p_nmax NUMERIC, p_min NUMERIC, p_max NUMERIC
)
RETURNS VOID LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_nmin < p_min OR p_nmax > p_max THEN
        RAISE EXCEPTION 'Valoracion "%": notas fuera del formato (% a %)', p_nombre, p_min, p_max
            USING ERRCODE = '22023';
    END IF;
END;
$$;

-- El orden es contrato: nombres unicos del lote y, por valoracion, minima/maxima, equivalente, formato.
CREATE OR REPLACE FUNCTION academico_test.fn_escala_validar_lote(
    p_scales JSONB, p_min NUMERIC, p_max NUMERIC
)
RETURNS VOID LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    scale  JSONB;
    v_nmin NUMERIC; v_nmax NUMERIC; v_neq NUMERIC;
BEGIN
    PERFORM academico_test.fn_escala_validar_nombres_unicos(p_scales);
    FOR scale IN SELECT * FROM jsonb_array_elements(p_scales) LOOP
        v_nmin := (scale->>'notaMinima')::NUMERIC;
        v_nmax := (scale->>'notaMaxima')::NUMERIC;
        v_neq  := (scale->>'notaEquivalente')::NUMERIC;
        PERFORM academico_test.fn_escala_validar_minima_maxima(scale->>'nombre', v_nmin, v_nmax);
        PERFORM academico_test.fn_escala_validar_equivalente(scale->>'nombre', v_nmin, v_nmax, v_neq);
        PERFORM academico_test.fn_escala_validar_formato(scale->>'nombre', v_nmin, v_nmax, p_min, p_max);
    END LOOP;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_escala_validar_lote(JSONB, NUMERIC, NUMERIC)
    IS 'Compone las fn_escala_validar_* del lote de valoraciones de POST /escalas. p_min/p_max = rango del formato de calificacion.';

CREATE OR REPLACE FUNCTION academico_test.fn_escala_validar_nivel_existe(p_nivel BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM academico_test.TNIVEL_ENSENANZA WHERE PK_NIVEL_ENSENANZA = p_nivel) THEN
        RAISE EXCEPTION 'El nivel de enseñanza % no existe', p_nivel USING ERRCODE = '23503';
    END IF;
END;
$$;

-- TIPO_VALORACION = Fortaleza/Debilidad; el front manda el PK_LISTA_VALOR.
CREATE OR REPLACE FUNCTION academico_test.fn_escala_validar_tipo_valoracion(p_tipo_id BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_nombre TEXT;
BEGIN
    IF p_tipo_id IS NOT NULL AND EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_tipo_id AND CATEGORIA = 'TIPO_VALORACION' AND ACTIVE = TRUE
    ) THEN
        RETURN;
    END IF;
    IF p_tipo_id IS NOT NULL THEN
        SELECT NOMBRE INTO v_nombre
          FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_tipo_id AND CATEGORIA = 'TIPO_VALORACION';
    END IF;
    IF v_nombre IS NOT NULL THEN
        RAISE EXCEPTION 'El tipo de valoracion "%" existe pero esta inactivo', v_nombre USING ERRCODE = '23503';
    END IF;
    RAISE EXCEPTION 'El tipo de valoracion indicado no existe o no es valido' USING ERRCODE = '23503';
END;
$$;

-- Sin icono no hay nada que validar; con icono, la categoria es GRAFICA_CARITA o GRAFICA_SIMBOLO.
CREATE OR REPLACE FUNCTION academico_test.fn_escala_validar_icono(p_icono_id BIGINT, p_icono_cat TEXT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_nombre TEXT;
BEGIN
    IF p_icono_id IS NULL OR EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR lv
         WHERE lv.PK_LISTA_VALOR = p_icono_id AND lv.CATEGORIA = p_icono_cat
           AND lv.CATEGORIA IN ('GRAFICA_CARITA', 'GRAFICA_SIMBOLO')
           AND lv.ACTIVE = TRUE AND lv.VALOR IS NOT NULL
    ) THEN
        RETURN;
    END IF;
    SELECT NOMBRE INTO v_nombre
      FROM academico_test.TLISTA_VALOR
     WHERE PK_LISTA_VALOR = p_icono_id AND CATEGORIA = p_icono_cat;
    IF v_nombre IS NOT NULL THEN
        RAISE EXCEPTION 'El icono "%" existe pero esta inactivo o no es una grafica valida', v_nombre
            USING ERRCODE = '23503';
    END IF;
    RAISE EXCEPTION 'El icono indicado no existe o no es una grafica valida' USING ERRCODE = '23503';
END;
$$;

-- Banda = fila de TESCALA_VALORACION.
CREATE OR REPLACE FUNCTION academico_test.fn_escala_valoracion_validar_existe(p_pk BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM academico_test.TESCALA_VALORACION WHERE PK_TESCALA_VALORACION = p_pk) THEN
        RAISE EXCEPTION 'No existe una banda con el identificador indicado' USING ERRCODE = 'P0002';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_escala_valoracion_validar_activa(p_pk BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_nombre VARCHAR(130);
BEGIN
    SELECT tv.NOMBRE INTO v_nombre
      FROM academico_test.TESCALA_VALORACION ev
      JOIN academico_test.TVALORACION tv ON tv.PK_TVALORACION = ev.FK_TVALORACION
     WHERE ev.PK_TESCALA_VALORACION = p_pk AND ev.ACTIVE = FALSE;
    IF FOUND THEN
        RAISE EXCEPTION 'La banda "%" existe pero esta inactiva', v_nombre USING ERRCODE = 'P0002';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_escala_valoracion_validar_sin_uso(p_pk BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_nombre VARCHAR(130);
BEGIN
    IF EXISTS (
        SELECT 1 FROM academico_test.TNIVEL_CRITERIO_UNIDAD ncu
         WHERE ncu.FK_TESCALA_VALORACION = p_pk AND ncu.ACTIVE = TRUE
    ) THEN
        SELECT tv.NOMBRE INTO v_nombre
          FROM academico_test.TESCALA_VALORACION ev
          JOIN academico_test.TVALORACION tv ON tv.PK_TVALORACION = ev.FK_TVALORACION
         WHERE ev.PK_TESCALA_VALORACION = p_pk;
        RAISE EXCEPTION 'No se puede eliminar la banda "%": esta en uso por criterios de unidad',
            COALESCE(v_nombre, p_pk::TEXT) USING ERRCODE = '23503';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_escala_validar_existe(p_escala BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM academico_test.TESCALA WHERE PK_TESCALA = p_escala) THEN
        RAISE EXCEPTION 'No existe una escala con el identificador indicado' USING ERRCODE = 'P0002';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_escala_validar_activa(p_escala BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_nombre VARCHAR(130);
BEGIN
    SELECT NOMBRE INTO v_nombre FROM academico_test.TESCALA WHERE PK_TESCALA = p_escala AND ACTIVE = FALSE;
    IF FOUND THEN
        RAISE EXCEPTION 'La escala "%" existe pero esta inactiva', v_nombre USING ERRCODE = 'P0002';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_escala_validar_nivel_tiene_escala(p_periodo BIGINT, p_nivel BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_nivel_nombre VARCHAR(130);
BEGIN
    IF EXISTS (
        SELECT 1 FROM academico_test.TNIVEL_ESCALA ne
         WHERE ne.FK_PERIODO_ACADEMICO = p_periodo AND ne.FK_TNIVEL_ENSENANZA = p_nivel AND ne.ACTIVE = TRUE
    ) THEN
        RETURN;
    END IF;
    SELECT NOMBRE INTO v_nivel_nombre FROM academico_test.TNIVEL_ENSENANZA WHERE PK_NIVEL_ENSENANZA = p_nivel;
    IF v_nivel_nombre IS NOT NULL THEN
        RAISE EXCEPTION 'No existe una escala activa para el nivel "%" en este periodo', v_nivel_nombre
            USING ERRCODE = 'P0002';
    END IF;
    RAISE EXCEPTION 'No existe una escala activa para el nivel indicado en este periodo' USING ERRCODE = 'P0002';
END;
$$;

-- Como se nombra la escala en los mensajes: por su nivel si se borra desde el nivel, si no por su nombre.
CREATE OR REPLACE FUNCTION academico_test.fn_escala_descripcion(p_escala BIGINT, p_nivel BIGINT DEFAULT NULL)
RETURNS TEXT LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN p_nivel IS NULL
                THEN format('la escala "%s"', (SELECT NOMBRE FROM academico_test.TESCALA WHERE PK_TESCALA = p_escala))
                ELSE format('la escala del nivel "%s"', COALESCE(
                    (SELECT NOMBRE FROM academico_test.TNIVEL_ENSENANZA WHERE PK_NIVEL_ENSENANZA = p_nivel),
                    p_nivel::TEXT))
           END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_escala_validar_sin_bandas_en_uso(
    p_escala BIGINT, p_nivel BIGINT DEFAULT NULL
)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM academico_test.TNIVEL_CRITERIO_UNIDAD ncu
          JOIN academico_test.TESCALA_VALORACION ev ON ev.PK_TESCALA_VALORACION = ncu.FK_TESCALA_VALORACION
         WHERE ev.FK_TESCALA = p_escala AND ncu.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar %: hay bandas en uso por criterios de unidad',
            academico_test.fn_escala_descripcion(p_escala, p_nivel) USING ERRCODE = '23503';
    END IF;
END;
$$;

-- La escala maestra la referencia TCRITERIO_EVALUACION.FK_TESCALA; las de nivel se propagan desde ella.
CREATE OR REPLACE FUNCTION academico_test.fn_escala_validar_no_es_maestra(
    p_escala BIGINT, p_nivel BIGINT DEFAULT NULL
)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_nombre_periodo VARCHAR(130);
BEGIN
    SELECT p.NOMBRE INTO v_nombre_periodo
      FROM academico_test.TCRITERIO_EVALUACION ce
      JOIN academico_test.TPERIODO_ACADEMICO p ON p.PK_TPERIODO_ACADEMICO = ce.PK_TCRITERIO_EVALUACION
     WHERE ce.FK_TESCALA = p_escala AND ce.ACTIVE = TRUE
     LIMIT 1;
    IF v_nombre_periodo IS NOT NULL THEN
        RAISE EXCEPTION 'No se puede eliminar %: es la escala maestra del criterio de evaluacion del periodo "%"',
            academico_test.fn_escala_descripcion(p_escala, p_nivel), v_nombre_periodo USING ERRCODE = '23503';
    END IF;
END;
$$;
