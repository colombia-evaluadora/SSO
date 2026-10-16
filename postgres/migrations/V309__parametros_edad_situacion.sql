-- V309 - Parámetros de edad, capa 1 de 5: cálculo de la situación de edad.
-- La usarán inscripción, matrícula y sus informes: la situación no se guarda,
-- se recalcula con los parámetros vigentes.
-- Depende de: V308 (tablas).

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_situacion_edad(
    p_fecha_nacimiento DATE,
    p_fk_tlv_grado     BIGINT,
    p_fk_tlv_calendario BIGINT,
    p_anio_lectivo     INTEGER
)
RETURNS VARCHAR
LANGUAGE sql
STABLE
AS $$
    SELECT CASE
             WHEN e.EDAD IS NULL OR c.MES IS NULL OR p_fecha_nacimiento IS NULL OR p_anio_lectivo IS NULL
               THEN 'SIN_CALCULAR'
             WHEN d.diferencia >= 2  THEN 'EXTRAEDAD'
             WHEN d.diferencia <= -2 THEN 'BAJA_EDAD'
             ELSE 'EN_EDAD'
           END
      FROM (SELECT 1) x
      LEFT JOIN academico_test.TEDAD_RECOMENDADA_GRADO e ON e.FK_TLV_GRADO = p_fk_tlv_grado
      LEFT JOIN academico_test.TFECHA_CORTE_CALENDARIO c ON c.FK_TLV_CALENDARIO = p_fk_tlv_calendario
      LEFT JOIN LATERAL (
          SELECT EXTRACT(YEAR FROM age(make_date(p_anio_lectivo, c.MES, c.DIA), p_fecha_nacimiento))::INT
                 - e.EDAD AS diferencia
           WHERE e.EDAD IS NOT NULL AND c.MES IS NOT NULL
      ) d ON TRUE;
$$;

COMMENT ON FUNCTION academico_test.fn_situacion_edad(DATE, BIGINT, BIGINT, INTEGER)
    IS 'Situación de edad: años cumplidos a la fecha de corte del calendario en el año lectivo, menos la edad recomendada del grado. EN_EDAD (-1 a +1), EXTRAEDAD (+2 o más), BAJA_EDAD (-2 o menos), SIN_CALCULAR (falta un parámetro o la fecha de nacimiento).';

