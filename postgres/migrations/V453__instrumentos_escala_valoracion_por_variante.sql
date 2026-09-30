-- V453 - Variantes de la escala de valoración por tipo de evaluación del
-- referente: fn_escala_variantes_permitidas y
-- fn_instrumento_permitido_por_tipo_evaluacion. Los campos disponibles del
-- instrumento viven hoy en V458.


SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_instrumento_permitido_por_tipo_evaluacion(
    p_instrumento     VARCHAR,
    p_tipo_evaluacion VARCHAR
)
RETURNS BOOLEAN
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE
        WHEN p_instrumento = 'OTRO'                         THEN TRUE
        WHEN p_tipo_evaluacion IS NULL                      THEN TRUE
        WHEN p_tipo_evaluacion = 'CUANTITATIVA_CUALITATIVA' THEN TRUE
        WHEN p_tipo_evaluacion = 'CUALITATIVA'              THEN p_instrumento IN ('RUBRICA', 'LISTA_COTEJO', 'ESCALA_VALORACION')
        WHEN p_tipo_evaluacion = 'CUANTITATIVA'             THEN p_instrumento = 'ESCALA_VALORACION'
        ELSE TRUE
    END;
$$;

COMMENT ON FUNCTION academico_test.fn_instrumento_permitido_por_tipo_evaluacion(VARCHAR, VARCHAR)
    IS 'Si un instrumento (VALOR de INSTRUMENTO_EVALUACION) aplica a un TIPO_EVALUACION del referente. OTRO siempre; sin tipo o CUANTITATIVA_CUALITATIVA, todos; CUALITATIVA -> RUBRICA, LISTA_COTEJO y ESCALA_VALORACION; CUANTITATIVA -> solo ESCALA_VALORACION. La escala entra en los dos porque tiene dos variantes (TIPO_ESCALA: CUALITATIVA y NUMERICA) y el tipo de evaluacion apaga UNA, no el instrumento: que variante se admite lo dice fn_escala_variantes_permitidas, la misma regla que hace cumplir fn_actividad_escala_definir al definirla. Antes la rama CUALITATIVA excluia la escala entera y la configuracion contradecia a la escritura.';

CREATE OR REPLACE FUNCTION academico_test.fn_escala_variantes_permitidas(
    p_tipo_evaluacion VARCHAR
)
RETURNS JSONB
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
                   'pk',     lv.PK_LISTA_VALOR,
                   'valor',  lv.VALOR,
                   'nombre', lv.NOMBRE)
                   ORDER BY lv.VALOR)
          FROM academico_test.TLISTA_VALOR lv
         WHERE lv.CATEGORIA = 'TIPO_ESCALA'
           AND lv.ACTIVE = TRUE
           AND CASE p_tipo_evaluacion
                   WHEN 'CUALITATIVA'  THEN lv.VALOR = 'CUALITATIVA'
                   WHEN 'CUANTITATIVA' THEN lv.VALOR = 'NUMERICA'
                   ELSE TRUE
               END
    ), '[]'::jsonb);
$$;

COMMENT ON FUNCTION academico_test.fn_escala_variantes_permitidas(VARCHAR)
    IS 'Las variantes de ESCALA_VALORACION (catalogo TIPO_ESCALA) que admite un TIPO_EVALUACION del referente, como [{pk, valor, nombre}]: CUALITATIVA -> solo la cualitativa; CUANTITATIVA -> solo la NUMERICA; CUANTITATIVA_CUALITATIVA o sin tipo -> las dos. Es la MISMA regla que fn_actividad_escala_definir (V226) hace cumplir al guardar; aqui se expone para que el formulario ofrezca solo la variante valida en vez de descubrirlo con un 22023. El front decide por VALOR: los pk no son estables entre entornos.';
