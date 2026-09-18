-- ===========================================================================
-- V453 — la ESCALA DE VALORACION tiene dos variantes (TIPO_ESCALA: CUALITATIVA
-- y NUMERICA) y el tipo de evaluacion del referente apaga UNA, no las dos.
--
-- Que hace: fn_instrumento_permitido_por_tipo_evaluacion dejaba fuera la
-- escala entera con referente CUALITATIVA, aunque fn_actividad_escala_definir
-- (V226) ya acepta la variante cualitativa y solo prohibe la numerica. La
-- configuracion y la escritura se contradecian. Ahora la escala se ofrece
-- siempre y cada instrumento trae `variantes`: las de TIPO_ESCALA que ese
-- referente admite (CUALITATIVA -> cualitativa, CUANTITATIVA -> numerica,
-- mixto o sin tipo -> las dos). La regla de V226 no cambia: es la misma.
-- Depende de: V214.2 (firma), V226 (regla de la escala), V440 (helper).
-- ===========================================================================

SET search_path TO academico_test, public;

-- Misma firma que V214.2: CREATE OR REPLACE. Solo cambia la rama CUALITATIVA.
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

-- Variantes de escala que admite un tipo de evaluacion, como catalogo listo
-- para el front. Misma regla que V226 impone al definir.
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

-- El helper de V440 gana `variantes` por instrumento: las de la escala segun
-- el tipo de evaluacion, [] en los demas. Aditivo.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_instrumentos_campos_disponibles(
    p_tipo_evaluacion VARCHAR
) RETURNS JSONB
LANGUAGE sql STABLE AS $$
    SELECT COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
                   'pk',        lv.PK_LISTA_VALOR,
                   'valor',     lv.VALOR,
                   'etiqueta',  lv.NOMBRE,
                   'nombre',    lv.NOMBRE,
                   'variantes', CASE WHEN lv.VALOR = 'ESCALA_VALORACION'
                                     THEN academico_test.fn_escala_variantes_permitidas(p_tipo_evaluacion)
                                     ELSE '[]'::jsonb END)
                   ORDER BY lv.NOMBRE)
          FROM academico_test.TLISTA_VALOR lv
         WHERE lv.CATEGORIA = 'INSTRUMENTO_EVALUACION'
           AND lv.ACTIVE = TRUE
           AND academico_test.fn_instrumento_permitido_por_tipo_evaluacion(lv.VALOR, p_tipo_evaluacion)
    ), '[]'::jsonb);
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_instrumentos_campos_disponibles(VARCHAR)
    IS 'instrumentosPermitidos de campos_disponibles.evaluacion, unico para las tres configuraciones (por actividad V214.2, por unidad V282, por contexto V422): los INSTRUMENTO_EVALUACION que fn_instrumento_permitido_por_tipo_evaluacion admite para el TIPO_EVALUACION, como [{pk, valor, etiqueta, nombre, variantes}] ordenados por nombre (etiqueta y nombre llevan el mismo texto, por compatibilidad con los dos consumidores). variantes: para ESCALA_VALORACION, las de TIPO_ESCALA que ese tipo de evaluacion admite (fn_escala_variantes_permitidas); [] en los demas instrumentos. El front debe decidir por VALOR.';
