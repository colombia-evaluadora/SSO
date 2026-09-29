-- ===========================================================================
-- V458 - Configuracion del formulario de actividad: ES_SUMATIVO reemplaza a
-- ES_EVALUATIVA. Quedan los helpers que siguen vivos: campos de OTRO, de
-- instrumentos y de ponderacion (fn_actividad_*_campos_disponibles).
-- Lo demas lo reescribieron despues: recuperacion_campos_disponibles (V459),
-- campos_disponibles (V479), unidad_configuracion_actividad y
-- configuracion_contexto (V496); las filas de public.query, V459 y V496.
-- Depende de: V440 (firmas), V453 (helper + variantes), V240 (TACTIVIDAD_OTRO).
-- ===========================================================================


SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_otro_campos_disponibles(
    p_tipo_evaluacion VARCHAR
) RETURNS JSONB
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'tipoEvidencia', jsonb_build_object(
            'requerido', TRUE,
            'catalogo', COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                           'pk', lv.PK_LISTA_VALOR, 'valor', lv.VALOR, 'nombre', lv.NOMBRE)
                           ORDER BY lv.NOMBRE)
                  FROM academico_test.TLISTA_VALOR lv
                 WHERE lv.CATEGORIA = 'TIPO_EVIDENCIA_OTRO'
                   AND lv.ACTIVE = TRUE), '[]'::jsonb),
            'motivo', 'Tipo de evidencia esperada del instrumento personalizado'),
        'metodoValoracion', jsonb_build_object(
            'requerido', TRUE,
            'catalogo', COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                           'pk',        lv.PK_LISTA_VALOR,
                           'valor',     lv.VALOR,
                           'nombre',    lv.NOMBRE,
                           'variantes', CASE WHEN lv.VALOR = 'ESCALA_VALORACION'
                                             THEN academico_test.fn_escala_variantes_permitidas(p_tipo_evaluacion)
                                             ELSE '[]'::jsonb END)
                           ORDER BY lv.NOMBRE)
                  FROM academico_test.TLISTA_VALOR lv
                 WHERE lv.CATEGORIA = 'INSTRUMENTO_EVALUACION'
                   AND lv.ACTIVE = TRUE
                   AND lv.VALOR <> 'OTRO'
                   AND academico_test.fn_instrumento_permitido_por_tipo_evaluacion(lv.VALOR, p_tipo_evaluacion)),
                '[]'::jsonb),
            'motivo', 'Instrumento con el que se califica el personalizado; se ofrecen los que admite el tipo de evaluacion del referente'),
        'definicion', jsonb_build_object(
            'requerido', TRUE,
            'formaPorMetodo', jsonb_build_object(
                'RUBRICA',           '[{nombre, descripcion?, niveles:[{etiqueta?, descripcion, ponderacion}]}]',
                'LISTA_COTEJO',      '[{descripcion, ponderacion?}]',
                'ESCALA_VALORACION', '{tipoEscala, criteriosGenerales?, interpretacionRangos?, valorMin?, valorMax?, niveles?}'),
            'motivo', 'Misma forma que el metodoValoracion elegido; se envia en PUT /planeador/actividades/:ID/instrumento como {tipoEvidencia, metodoValoracion, definicion}'),
        'descripcionInstrumento', jsonb_build_object(
            'requerido', FALSE, 'campo', 'DESCRIPCION_INSTRUMENTO', 'maxLength', 4000,
            'motivo', 'Descripcion libre del instrumento; va en el POST/PATCH de la actividad'),
        'requiereArchivo', jsonb_build_object(
            'requerido', FALSE, 'campo', 'REQUIERE_ARCHIVO', 'valores', jsonb_build_array('S', 'N'), 'default', 'N',
            'motivo', 'Si el estudiante debe adjuntar un archivo'),
        'requiereTexto', jsonb_build_object(
            'requerido', FALSE, 'campo', 'REQUIERE_TEXTO', 'valores', jsonb_build_array('S', 'N'), 'default', 'N',
            'motivo', 'Si el estudiante debe escribir una respuesta en texto'));
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_otro_campos_disponibles(VARCHAR)
    IS 'Bloque `campos` de la entrada OTRO de instrumentosPermitidos: lo que pide el instrumento "Otro (personalizado)" (TACTIVIDAD_OTRO + campos libres de TACTIVIDAD). tipoEvidencia: catalogo TIPO_EVIDENCIA_OTRO. metodoValoracion: los INSTRUMENTO_EVALUACION distintos de OTRO que fn_instrumento_permitido_por_tipo_evaluacion admite para el TIPO_EVALUACION del referente, con `variantes` de escala (fn_escala_variantes_permitidas); es la misma regla que fn_actividad_otro_definir hace cumplir al delegar en fn_actividad_*_definir. definicion: la forma segun el metodo. descripcionInstrumento / requiereArchivo / requiereTexto: columnas de TACTIVIDAD que captura el POST/PATCH. El front decide por VALOR: los pk no son estables entre entornos.';

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
                                     ELSE '[]'::jsonb END,
                   'campos',    CASE WHEN lv.VALOR = 'OTRO'
                                     THEN academico_test.fn_actividad_otro_campos_disponibles(p_tipo_evaluacion)
                                     ELSE NULL END)
                   ORDER BY lv.NOMBRE)
          FROM academico_test.TLISTA_VALOR lv
         WHERE lv.CATEGORIA = 'INSTRUMENTO_EVALUACION'
           AND lv.ACTIVE = TRUE
           AND academico_test.fn_instrumento_permitido_por_tipo_evaluacion(lv.VALOR, p_tipo_evaluacion)
    ), '[]'::jsonb);
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_instrumentos_campos_disponibles(VARCHAR)
    IS 'instrumentosPermitidos de campos_disponibles.evaluacion, unico para las tres configuraciones (por actividad, por unidad y por contexto): los INSTRUMENTO_EVALUACION que fn_instrumento_permitido_por_tipo_evaluacion admite para el TIPO_EVALUACION, como [{pk, valor, etiqueta, nombre, variantes, campos}] ordenados por nombre. variantes: para ESCALA_VALORACION, las de TIPO_ESCALA que ese tipo admite; [] en los demas. campos: solo en OTRO, lo que pide el instrumento personalizado (fn_actividad_otro_campos_disponibles); NULL en los demas. El front debe decidir por VALOR.';

DROP FUNCTION IF EXISTS academico_test.fn_actividad_recuperacion_campos_disponibles(BOOLEAN, VARCHAR);

DROP FUNCTION IF EXISTS academico_test.fn_actividad_ponderacion_campos_disponibles(VARCHAR, BOOLEAN, VARCHAR);

CREATE FUNCTION academico_test.fn_actividad_ponderacion_campos_disponibles(
    p_es_sumativo  VARCHAR,
    p_tiene_unidad BOOLEAN,
    p_modo_calculo VARCHAR
) RETURNS JSONB
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN UPPER(TRIM(COALESCE(p_es_sumativo, 'S'))) = 'N' THEN jsonb_build_object(
            'visible', FALSE, 'requerido', FALSE, 'modo', NULL, 'valor', 0,
            'motivo', 'La actividad no es sumativa: pesa 0 frente a la unidad; no enviar PONDERACION ni NOTA_MAXIMA')
        WHEN NOT COALESCE(p_tiene_unidad, FALSE) THEN jsonb_build_object(
            'visible', FALSE, 'requerido', FALSE, 'modo', NULL,
            'motivo', 'La actividad aun no pertenece a una unidad; la ponderacion la define el metodo de calculo de la unidad')
        WHEN p_modo_calculo = 'PONDERAR' THEN jsonb_build_object(
            'visible', TRUE, 'requerido', TRUE, 'modo', 'PORCENTAJE',
            'campo', 'PONDERACION', 'autocalculado', FALSE,
            'motivo', 'la unidad pondera sus actividades')
        WHEN p_modo_calculo = 'SUMATORIA' THEN jsonb_build_object(
            'visible', TRUE, 'requerido', TRUE, 'modo', 'PUNTAJE',
            'campo', 'NOTA_MAXIMA', 'autocalculado', TRUE,
            'motivo', 'la unidad suma puntajes; el % lo calcula el sistema')
        WHEN p_modo_calculo = 'PROMEDIAR' THEN jsonb_build_object(
            'visible', FALSE, 'requerido', FALSE, 'modo', NULL,
            'motivo', 'la unidad promedia, la ponderacion no aplica')
        ELSE jsonb_build_object(
            'visible', FALSE, 'requerido', FALSE, 'modo', NULL,
            'motivo', 'la unidad aun no tiene metodo de calculo elegido')
    END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_ponderacion_campos_disponibles(VARCHAR, BOOLEAN, VARCHAR)
    IS 'Bloque ponderacion del formulario de actividad, por metodo de calculo de la unidad (fn_unidad_calculo_definitiva_modo): PONDERAR -> PORCENTAJE sobre PONDERACION; SUMATORIA -> PUNTAJE sobre NOTA_MAXIMA con autocalculado; PROMEDIAR o sin metodo -> no visible. Con ES_SUMATIVO = N no aplica y se informa valor 0 (la actividad pesa cero frente a su unidad): fn_actividad_crear/_actualizar rechazan PONDERACION cuando ES_EVALUATIVA = N, asi que el front no la envia.';

DROP FUNCTION IF EXISTS academico_test.fn_unidad_configuracion_actividad(BIGINT, BIGINT, VARCHAR);

DROP FUNCTION IF EXISTS academico_test.fn_actividad_configuracion_contexto(BIGINT, BIGINT, BIGINT, BIGINT, VARCHAR);
