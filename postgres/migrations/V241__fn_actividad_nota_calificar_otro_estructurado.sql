-- V241 - fn_actividad_otro_metodo_valoracion: método de valoración (rúbrica,
-- lista de cotejo o escala) configurado para el instrumento Otro de una
-- actividad. Calificar y leer la nota viven hoy en V496.6/V496.7.
-- Depende de: V240 (TACTIVIDAD_OTRO).

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_otro_metodo_valoracion(
    p_pk_tactividad BIGINT
)
RETURNS VARCHAR
LANGUAGE sql
STABLE
AS $$
    SELECT lvm.VALOR
      FROM academico_test.TACTIVIDAD_OTRO o
      JOIN academico_test.TLISTA_VALOR lvm ON lvm.PK_LISTA_VALOR = o.FK_TLV_METODO_VALORACION
     WHERE o.FK_TACTIVIDAD = p_pk_tactividad
       AND o.ACTIVE = TRUE;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_otro_metodo_valoracion(BIGINT)
    IS 'VALOR (RUBRICA | LISTA_COTEJO | ESCALA_VALORACION) del metodo de valoracion configurado para el instrumento OTRO de una actividad, via TACTIVIDAD_OTRO.FK_TLV_METODO_VALORACION (V240). NULL si la actividad no tiene fila ACTIVA en TACTIVIDAD_OTRO (instrumento distinto de OTRO, o OTRO sin fn_actividad_otro_definir todavia). Helper compartido por fn_actividad_nota_calificar (fachada) y fn_actividad_nota_obtener, evita repetir el JOIN TACTIVIDAD_OTRO->TLISTA_VALOR. V241.';
