-- V310 - Parámetros de edad, capa 2 de 5: validaciones.
-- Depende de: V22 (TLISTA_VALOR).

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_parametroedad_validar_valor_lista(
    p_pk_lista_valor BIGINT,
    p_categoria      VARCHAR,
    p_nombre         VARCHAR
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM academico_test.TLISTA_VALOR
                    WHERE PK_LISTA_VALOR = p_pk_lista_valor
                      AND CATEGORIA = p_categoria
                      AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'No existe el % %', p_nombre, p_pk_lista_valor
            USING ERRCODE = 'P0002';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_parametroedad_validar_valor_lista(BIGINT, VARCHAR, VARCHAR)
    IS 'P0002 si el pk no es un valor no eliminado de la lista p_categoria (GRADOS o CALENDARIO).';

CREATE OR REPLACE FUNCTION academico_test.fn_parametroedad_validar_edad(p_edad INTEGER)
RETURNS VOID
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_edad IS NULL OR p_edad NOT BETWEEN 2 AND 25 THEN
        RAISE EXCEPTION 'La edad recomendada debe estar entre 2 y 25 años'
            USING ERRCODE = '22023';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_parametroedad_validar_edad(INTEGER)
    IS '22023 si la edad recomendada falta o no está entre 2 y 25.';

CREATE OR REPLACE FUNCTION academico_test.fn_parametroedad_validar_fecha_corte(p_mes INTEGER, p_dia INTEGER)
RETURNS VOID
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_mes IS NULL OR p_mes NOT BETWEEN 1 AND 12 THEN
        RAISE EXCEPTION 'El mes de la fecha de corte debe estar entre 1 y 12'
            USING ERRCODE = '22023';
    END IF;
    IF p_mes = 2 AND p_dia = 29 THEN
        RAISE EXCEPTION 'La fecha de corte no puede ser el 29 de febrero'
            USING ERRCODE = '22023';
    END IF;
    IF p_dia IS NULL OR p_dia NOT BETWEEN 1
       AND EXTRACT(DAY FROM (make_date(2023, p_mes, 1) + INTERVAL '1 month - 1 day'))::INT THEN
        RAISE EXCEPTION 'El día % no existe en el mes %', COALESCE(p_dia::TEXT, ''), p_mes
            USING ERRCODE = '22023';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_parametroedad_validar_fecha_corte(INTEGER, INTEGER)
    IS '22023 si el mes no es 1-12, es el 29 de febrero o el día no existe en el mes.';
