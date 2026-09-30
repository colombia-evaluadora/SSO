-- V496.5 - Instrumentos y calificación de actividades: validaciones (una por
-- regla), los validadores centrales de definición y de calificación, y el
-- assert de propiedad de resultados (Regla 54). Mensajes con nombres, nunca
-- con pk. Sustituye a fn_actividad_instrumento_assert (V240) y
-- fn_actividad_nota_asistencia_assert (V227).
-- Depende de: V496.1 (etiquetas, validar_existente/activa, catálogo,
-- propietario), V479 (tipo de evaluación), V458 (instrumento permitido),
-- V241 (método de Otro), V475 (es_formativa), V450 (asistencia válida).

SET search_path TO academico_test, public;

DROP FUNCTION IF EXISTS academico_test.fn_actividad_instrumento_assert(BIGINT, VARCHAR);
DROP FUNCTION IF EXISTS academico_test.fn_actividad_nota_asistencia_assert(BIGINT, DATE);

-- ---------------------------------------------------------------------------
-- Lecturas de apoyo
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_instrumento_nombre_de(p_valor VARCHAR)
RETURNS VARCHAR
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(
        (SELECT NOMBRE FROM academico_test.TLISTA_VALOR
          WHERE CATEGORIA = 'INSTRUMENTO_EVALUACION' AND VALOR = p_valor
          ORDER BY ACTIVE DESC LIMIT 1),
        p_valor);
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_instrumento_efectivo(p_pk_tactividad BIGINT)
RETURNS VARCHAR
LANGUAGE sql
STABLE
AS $$
    -- Otro con método configurado se define y califica como ese método.
    SELECT CASE WHEN lv.VALOR = 'OTRO'
                THEN COALESCE(academico_test.fn_actividad_otro_metodo_valoracion(a.PK_TACTIVIDAD), 'OTRO')
                ELSE lv.VALOR END
      FROM academico_test.TACTIVIDAD a
      LEFT JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = a.FK_TLV_INSTRUMENTO_EVALUACION
     WHERE a.PK_TACTIVIDAD = p_pk_tactividad;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_escala_criterios_cantidad(p_pk_tactividad BIGINT)
RETURNS INT
LANGUAGE sql
STABLE
AS $$
    SELECT GREATEST(COALESCE(array_length(string_to_array(NULLIF(TRIM(e.CRITERIOS_GENERALES), ''), ','), 1), 1), 1)
      FROM academico_test.TACTIVIDAD_ESCALA e
     WHERE e.FK_TACTIVIDAD = p_pk_tactividad AND e.ACTIVE = TRUE;
$$;

-- ---------------------------------------------------------------------------
-- Instrumento de la actividad
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_instrumento(
    p_pk_tactividad BIGINT,
    p_esperado      VARCHAR
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_valor VARCHAR;
BEGIN
    PERFORM academico_test.fn_actividad_validar_existente(p_pk_tactividad);
    PERFORM academico_test.fn_actividad_validar_activa(p_pk_tactividad);
    SELECT lv.VALOR INTO v_valor
      FROM academico_test.TACTIVIDAD a
      LEFT JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = a.FK_TLV_INSTRUMENTO_EVALUACION
     WHERE a.PK_TACTIVIDAD = p_pk_tactividad;
    IF v_valor IS NULL THEN
        RAISE EXCEPTION '% no tiene instrumento de evaluación: elíjalo primero en su formulario',
            academico_test.fn_actividad_etiqueta(p_pk_tactividad) USING ERRCODE = '22023';
    END IF;
    IF v_valor = p_esperado
       OR (v_valor = 'OTRO' AND academico_test.fn_actividad_instrumento_efectivo(p_pk_tactividad) = p_esperado) THEN
        RETURN;
    END IF;
    RAISE EXCEPTION '% se evalúa con %, no con %',
        academico_test.fn_actividad_etiqueta(p_pk_tactividad),
        academico_test.fn_actividad_instrumento_nombre_de(academico_test.fn_actividad_instrumento_efectivo(p_pk_tactividad)),
        academico_test.fn_actividad_instrumento_nombre_de(p_esperado)
        USING ERRCODE = '22023';
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_instrumento_permitido(
    p_pk_tactividad BIGINT,
    p_instrumento   VARCHAR
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_tipo VARCHAR := academico_test.fn_actividad_referente_tipo_evaluacion(p_pk_tactividad);
BEGIN
    IF NOT academico_test.fn_instrumento_permitido_por_tipo_evaluacion(p_instrumento, v_tipo) THEN
        RAISE EXCEPTION 'El referente curricular de % evalúa de forma %: no admite %',
            academico_test.fn_actividad_etiqueta(p_pk_tactividad),
            lower(COALESCE((SELECT NOMBRE FROM academico_test.TLISTA_VALOR
                             WHERE CATEGORIA = 'TIPO_EVALUACION' AND VALOR = v_tipo LIMIT 1), v_tipo)),
            lower(academico_test.fn_actividad_instrumento_nombre_de(p_instrumento))
            USING ERRCODE = '22023',
                  HINT = 'Use una escala de valoración numérica';
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Definición de cada instrumento (Bloque 5, Reglas 40-42)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_rubrica_definicion(
    p_criterios JSONB,
    p_etiqueta  VARCHAR
)
RETURNS VOID
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_c       RECORD;
    v_nombre  VARCHAR;
    v_niveles JSONB;
BEGIN
    IF p_criterios IS NULL OR jsonb_typeof(p_criterios) <> 'array' OR jsonb_array_length(p_criterios) = 0 THEN
        RAISE EXCEPTION 'La rúbrica de % necesita al menos un criterio', p_etiqueta USING ERRCODE = '22023';
    END IF;
    FOR v_c IN SELECT e AS j, ord FROM jsonb_array_elements(p_criterios) WITH ORDINALITY AS t(e, ord) LOOP
        v_nombre := NULLIF(TRIM(v_c.j->>'nombre'), '');
        IF v_nombre IS NULL THEN
            RAISE EXCEPTION 'El criterio % de la rúbrica de % no tiene nombre', v_c.ord, p_etiqueta
                USING ERRCODE = '22023';
        END IF;
        v_niveles := v_c.j->'niveles';
        IF v_niveles IS NULL OR jsonb_typeof(v_niveles) <> 'array' OR jsonb_array_length(v_niveles) = 0 THEN
            RAISE EXCEPTION 'El criterio "%" de la rúbrica necesita al menos un nivel de desempeño', v_nombre
                USING ERRCODE = '22023';
        END IF;
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_niveles) n
                    WHERE (n->>'ponderacion') IS NULL
                       OR (n->>'ponderacion') !~ '^\d{1,3}(\.\d+)?$'
                       OR (n->>'ponderacion')::NUMERIC > 100) THEN
            RAISE EXCEPTION 'Cada nivel del criterio "%" necesita un puntaje entre 0 y 100', v_nombre
                USING ERRCODE = '22023';
        END IF;
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_niveles) n WHERE NULLIF(TRIM(n->>'descripcion'), '') IS NULL) THEN
            RAISE EXCEPTION 'Cada nivel del criterio "%" necesita su descripción o juicio de valor', v_nombre
                USING ERRCODE = '22023';
        END IF;
        IF (SELECT COUNT(*) <> COUNT(DISTINCT (n->>'ponderacion')::NUMERIC) FROM jsonb_array_elements(v_niveles) n) THEN
            RAISE EXCEPTION 'El criterio "%" tiene dos niveles con el mismo puntaje', v_nombre USING ERRCODE = '22023';
        END IF;
        -- Con el máximo en 0 el criterio no aporta nada y la nota quedaría indefinida.
        IF (SELECT MAX((n->>'ponderacion')::NUMERIC) FROM jsonb_array_elements(v_niveles) n) = 0 THEN
            RAISE EXCEPTION 'El criterio "%" necesita al menos un nivel con puntaje mayor que 0', v_nombre
                USING ERRCODE = '22023';
        END IF;
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_cotejo_definicion(
    p_items    JSONB,
    p_etiqueta VARCHAR
)
RETURNS VOID
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'La lista de cotejo de % necesita al menos un elemento de verificación', p_etiqueta
            USING ERRCODE = '22023';
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_items) e WHERE NULLIF(TRIM(e->>'descripcion'), '') IS NULL) THEN
        RAISE EXCEPTION 'Cada elemento de la lista de cotejo de % necesita su descripción', p_etiqueta
            USING ERRCODE = '22023';
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_items) e
                WHERE NULLIF(e->>'ponderacion', '') IS NOT NULL
                  AND ((e->>'ponderacion') !~ '^\d{1,3}(\.\d+)?$' OR (e->>'ponderacion')::NUMERIC > 100)) THEN
        RAISE EXCEPTION 'El puntaje de cada elemento de la lista de cotejo de % debe estar entre 0 y 100', p_etiqueta
            USING ERRCODE = '22023';
    END IF;
    -- Un elemento sin puntaje pesa 1: solo falla si todos traen 0 explícito.
    IF (SELECT SUM(COALESCE(NULLIF(e->>'ponderacion', '')::NUMERIC, 1)) FROM jsonb_array_elements(p_items) e) = 0 THEN
        RAISE EXCEPTION 'Todos los elementos de la lista de cotejo de % tienen puntaje 0: el total posible no puede ser 0', p_etiqueta
            USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_escala_definicion(
    p_config    JSONB,
    p_tipo_eval VARCHAR,
    p_etiqueta  VARCHAR
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_tipo    VARCHAR;
    v_niveles JSONB := p_config->'niveles';
    v_min     TEXT  := NULLIF(TRIM(p_config->>'valorMin'), '');
    v_max     TEXT  := NULLIF(TRIM(p_config->>'valorMax'), '');
BEGIN
    IF p_config IS NULL OR jsonb_typeof(p_config) <> 'object' THEN
        RAISE EXCEPTION 'La escala de valoración de % no tiene el formato esperado', p_etiqueta USING ERRCODE = '22023';
    END IF;
    IF (p_config->>'tipoEscala') IS NULL THEN
        RAISE EXCEPTION 'Indique si la escala de valoración de % es numérica o cualitativa', p_etiqueta
            USING ERRCODE = '22023';
    END IF;
    PERFORM academico_test.fn_actividad_validar_catalogo((p_config->>'tipoEscala')::BIGINT, 'TIPO_ESCALA', 'Tipo de escala');
    SELECT VALOR INTO v_tipo FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = (p_config->>'tipoEscala')::BIGINT;

    -- El tipo de evaluación del referente apaga una de las dos variantes.
    IF v_tipo = 'NUMERICA' AND p_tipo_eval = 'CUALITATIVA' THEN
        RAISE EXCEPTION 'El referente curricular de % evalúa de forma cualitativa: la escala debe ser cualitativa, no numérica', p_etiqueta
            USING ERRCODE = '22023';
    END IF;
    IF v_tipo = 'CUALITATIVA' AND p_tipo_eval = 'CUANTITATIVA' THEN
        RAISE EXCEPTION 'El referente curricular de % evalúa de forma cuantitativa: la escala debe ser numérica, no cualitativa', p_etiqueta
            USING ERRCODE = '22023';
    END IF;
    PERFORM academico_test.fn_actividad_validar_texto(p_config->>'criteriosGenerales', 'Los criterios de la escala de ' || p_etiqueta, 1000);

    IF v_tipo = 'NUMERICA' THEN
        IF v_min IS NULL OR v_max IS NULL THEN
            RAISE EXCEPTION 'La escala numérica de % necesita valor mínimo y valor máximo', p_etiqueta USING ERRCODE = '22023';
        END IF;
        IF v_min !~ '^-?\d{1,3}(\.\d+)?$' OR v_max !~ '^-?\d{1,3}(\.\d+)?$' THEN
            RAISE EXCEPTION 'Los valores mínimo y máximo de la escala de % deben ser números de hasta tres cifras', p_etiqueta
                USING ERRCODE = '22023';
        END IF;
        IF v_min::NUMERIC >= v_max::NUMERIC THEN
            RAISE EXCEPTION 'En la escala de % el valor mínimo (%) debe ser menor que el máximo (%)', p_etiqueta, v_min, v_max
                USING ERRCODE = '22023';
        END IF;
        IF jsonb_typeof(v_niveles) = 'array' AND jsonb_array_length(v_niveles) > 0 THEN
            RAISE EXCEPTION 'La escala numérica de % se define con valor mínimo y máximo: no lleva niveles', p_etiqueta
                USING ERRCODE = '22023';
        END IF;
    ELSE
        IF v_min IS NOT NULL OR v_max IS NOT NULL THEN
            RAISE EXCEPTION 'La escala cualitativa de % se define con niveles: no lleva valor mínimo ni máximo', p_etiqueta
                USING ERRCODE = '22023';
        END IF;
        IF v_niveles IS NULL OR jsonb_typeof(v_niveles) <> 'array' OR jsonb_array_length(v_niveles) = 0 THEN
            RAISE EXCEPTION 'La escala cualitativa de % necesita al menos un nivel', p_etiqueta USING ERRCODE = '22023';
        END IF;
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_niveles) n
                    WHERE (n->>'ponderacion') IS NULL
                       OR (n->>'ponderacion') !~ '^\d{1,3}(\.\d+)?$'
                       OR (n->>'ponderacion')::NUMERIC > 100) THEN
            RAISE EXCEPTION 'Cada nivel de la escala de % necesita un puntaje entre 0 y 100', p_etiqueta USING ERRCODE = '22023';
        END IF;
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_niveles) n WHERE NULLIF(TRIM(n->>'descripcion'), '') IS NULL) THEN
            RAISE EXCEPTION 'Cada nivel de la escala de % necesita su descriptor', p_etiqueta USING ERRCODE = '22023';
        END IF;
        IF (SELECT COUNT(*) <> COUNT(DISTINCT (n->>'ponderacion')::NUMERIC) FROM jsonb_array_elements(v_niveles) n) THEN
            RAISE EXCEPTION 'La escala de % tiene dos niveles con el mismo puntaje', p_etiqueta USING ERRCODE = '22023';
        END IF;
        IF (SELECT MAX((n->>'ponderacion')::NUMERIC) FROM jsonb_array_elements(v_niveles) n) = 0 THEN
            RAISE EXCEPTION 'La escala de % necesita al menos un nivel con puntaje mayor que 0', p_etiqueta USING ERRCODE = '22023';
        END IF;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_otro_definicion(
    p_config   JSONB,
    p_etiqueta VARCHAR
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_metodo VARCHAR;
BEGIN
    IF p_config IS NULL OR jsonb_typeof(p_config) <> 'object' THEN
        RAISE EXCEPTION 'El instrumento personalizado de % no tiene el formato esperado', p_etiqueta USING ERRCODE = '22023';
    END IF;
    IF NULLIF(p_config->>'tipoEvidencia', '') IS NULL THEN
        RAISE EXCEPTION 'Indique el tipo de evidencia esperada del instrumento de %', p_etiqueta USING ERRCODE = '22023';
    END IF;
    IF NULLIF(p_config->>'metodoValoracion', '') IS NULL THEN
        RAISE EXCEPTION 'Indique el método de valoración del instrumento de % (rúbrica, lista de cotejo o escala de valoración)', p_etiqueta
            USING ERRCODE = '22023';
    END IF;
    PERFORM academico_test.fn_actividad_validar_catalogo((p_config->>'tipoEvidencia')::BIGINT, 'TIPO_EVIDENCIA_OTRO', 'Tipo de evidencia esperada');
    PERFORM academico_test.fn_actividad_validar_catalogo((p_config->>'metodoValoracion')::BIGINT, 'INSTRUMENTO_EVALUACION', 'Método de valoración');
    SELECT VALOR INTO v_metodo FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = (p_config->>'metodoValoracion')::BIGINT;
    IF v_metodo NOT IN ('RUBRICA', 'LISTA_COTEJO', 'ESCALA_VALORACION') THEN
        RAISE EXCEPTION 'El método de valoración del instrumento de % debe ser rúbrica, lista de cotejo o escala de valoración', p_etiqueta
            USING ERRCODE = '22023';
    END IF;
    IF p_config->'definicion' IS NULL OR jsonb_typeof(p_config->'definicion') = 'null' THEN
        RAISE EXCEPTION 'Configure la % del instrumento de %', lower(academico_test.fn_actividad_instrumento_nombre_de(v_metodo)), p_etiqueta
            USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_instrumento_definicion(
    p_pk_tactividad BIGINT,
    p_definicion    JSONB
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_etiqueta VARCHAR := academico_test.fn_actividad_etiqueta(p_pk_tactividad);
    v_valor    VARCHAR;
    v_def      JSONB   := p_definicion;
BEGIN
    SELECT lv.VALOR INTO v_valor
      FROM academico_test.TACTIVIDAD a
      LEFT JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = a.FK_TLV_INSTRUMENTO_EVALUACION
     WHERE a.PK_TACTIVIDAD = p_pk_tactividad;
    IF v_valor IS NULL OR v_valor NOT IN ('RUBRICA', 'LISTA_COTEJO', 'ESCALA_VALORACION', 'OTRO') THEN
        RAISE EXCEPTION '% no tiene un instrumento de evaluación que se pueda configurar: elíjalo primero en su formulario', v_etiqueta
            USING ERRCODE = '22023';
    END IF;
    IF v_valor = 'OTRO' THEN
        PERFORM academico_test.fn_actividad_validar_otro_definicion(p_definicion, v_etiqueta);
        v_def := p_definicion->'definicion';
        SELECT VALOR INTO v_valor FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = (p_definicion->>'metodoValoracion')::BIGINT;
    END IF;
    PERFORM academico_test.fn_actividad_validar_instrumento_permitido(p_pk_tactividad, v_valor);
    CASE v_valor
        WHEN 'RUBRICA'      THEN PERFORM academico_test.fn_actividad_validar_rubrica_definicion(v_def, v_etiqueta);
        WHEN 'LISTA_COTEJO' THEN PERFORM academico_test.fn_actividad_validar_cotejo_definicion(v_def, v_etiqueta);
        ELSE PERFORM academico_test.fn_actividad_validar_escala_definicion(
                 v_def, academico_test.fn_actividad_referente_tipo_evaluacion(p_pk_tactividad), v_etiqueta);
    END CASE;
END;
$$;

-- ---------------------------------------------------------------------------
-- Registro de resultados (Sección 6, Reglas 52-56)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_estudiante_de(
    p_pk_tactividad_estudiante BIGINT,
    p_pk_tactividad            BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_ae RECORD;
BEGIN
    SELECT FK_TACTIVIDAD, FK_TMATRICULA, ACTIVE INTO v_ae
      FROM academico_test.TACTIVIDAD_ESTUDIANTE WHERE PK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante;
    IF NOT FOUND OR NOT v_ae.ACTIVE OR v_ae.FK_TACTIVIDAD IS DISTINCT FROM p_pk_tactividad THEN
        RAISE EXCEPTION '% no está entre los estudiantes de %',
            COALESCE(academico_test.fn_actividad_estudiante_nombre(v_ae.FK_TMATRICULA), 'Uno de los estudiantes enviados'),
            academico_test.fn_actividad_etiqueta(p_pk_tactividad)
            USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_estudiantes_lote(
    p_pk_tactividad BIGINT,
    p_estudiantes   BIGINT[]
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_ae BIGINT;
BEGIN
    IF COALESCE(array_length(p_estudiantes, 1), 0) = 0 THEN
        RAISE EXCEPTION 'Seleccione al menos un estudiante de % para calificar',
            academico_test.fn_actividad_etiqueta(p_pk_tactividad) USING ERRCODE = '22023';
    END IF;
    FOREACH v_ae IN ARRAY p_estudiantes LOOP
        PERFORM academico_test.fn_actividad_validar_estudiante_de(v_ae, p_pk_tactividad);
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_calificable(p_pk_tactividad BIGINT)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_actividad_validar_activa(p_pk_tactividad);
    -- Regla 52: con referente formativo el resultado es el registro narrativo.
    IF academico_test.fn_actividad_es_formativa(p_pk_tactividad) THEN
        RAISE EXCEPTION '% se valora con observaciones (referente formativo): registre una observación en lugar de una nota',
            academico_test.fn_actividad_etiqueta(p_pk_tactividad) USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM academico_test.TACTIVIDAD
                    WHERE PK_TACTIVIDAD = p_pk_tactividad AND FK_TLV_INSTRUMENTO_EVALUACION IS NOT NULL) THEN
        RAISE EXCEPTION '% no tiene instrumento de evaluación: elíjalo y configúrelo antes de calificar',
            academico_test.fn_actividad_etiqueta(p_pk_tactividad) USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_asistencia_calificar(
    p_pk_tactividad_estudiante BIGINT,
    p_fecha                    DATE
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_matricula  BIGINT;
    v_asignatura BIGINT;
    v_tipo       BIGINT;
BEGIN
    SELECT ae.FK_TMATRICULA, a.FK_TASIGNATURA INTO v_matricula, v_asignatura
      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
      JOIN academico_test.TACTIVIDAD a ON a.PK_TACTIVIDAD = ae.FK_TACTIVIDAD
     WHERE ae.PK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante;

    SELECT s.FK_TLV_TIPO_ASISTENCIA INTO v_tipo
      FROM academico_test.TASISTENCIA s
     WHERE s.FK_TMATRICULA = v_matricula AND s.FK_TASIGNATURA = v_asignatura
       AND s.FECHA = p_fecha AND s.ACTIVE = TRUE
     LIMIT 1;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se puede calificar a %: no hay asistencia registrada en la asignatura el %',
            COALESCE(academico_test.fn_actividad_estudiante_nombre(v_matricula), 'el estudiante'),
            to_char(p_fecha, 'DD/MM/YYYY') USING ERRCODE = '22023';
    END IF;
    -- Solo la inasistencia injustificada bloquea; la justificada deja calificar.
    IF v_tipo = academico_test.fn_asistencia_tipo_pk(2) THEN
        RAISE EXCEPTION 'No se puede calificar a %: tiene una inasistencia injustificada el %',
            COALESCE(academico_test.fn_actividad_estudiante_nombre(v_matricula), 'el estudiante'),
            to_char(p_fecha, 'DD/MM/YYYY') USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_rubrica_nivel(
    p_pk_tactividad BIGINT,
    p_pk_criterio   BIGINT,
    p_pk_nivel      BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_criterio VARCHAR;
BEGIN
    SELECT NOMBRE INTO v_criterio FROM academico_test.TACTIVIDAD_RUBRICA_CRITERIO
     WHERE PK_TACTIVIDAD_RUBRICA_CRITERIO = p_pk_criterio AND FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Uno de los criterios enviados no pertenece a la rúbrica de %',
            academico_test.fn_actividad_etiqueta(p_pk_tactividad) USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM academico_test.TACTIVIDAD_RUBRICA_NIVEL
                    WHERE PK_TACTIVIDAD_RUBRICA_NIVEL = p_pk_nivel
                      AND FK_TACTIVIDAD_RUBRICA_CRITERIO = p_pk_criterio AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'El nivel elegido no es uno de los niveles del criterio "%"', v_criterio USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_rubrica_captura(
    p_pk_tactividad BIGINT,
    p_niveles       JSONB
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_e       JSONB;
    v_falta   VARCHAR;
BEGIN
    IF p_niveles IS NULL OR jsonb_typeof(p_niveles) <> 'array' OR jsonb_array_length(p_niveles) = 0 THEN
        RAISE EXCEPTION 'Elija un nivel en cada criterio de la rúbrica de %',
            academico_test.fn_actividad_etiqueta(p_pk_tactividad) USING ERRCODE = '22023';
    END IF;
    IF (SELECT COUNT(*) <> COUNT(DISTINCT e->>'pkCriterio') FROM jsonb_array_elements(p_niveles) e) THEN
        RAISE EXCEPTION 'Se envió más de un nivel para el mismo criterio de la rúbrica de %',
            academico_test.fn_actividad_etiqueta(p_pk_tactividad) USING ERRCODE = '22023';
    END IF;
    FOR v_e IN SELECT * FROM jsonb_array_elements(p_niveles) LOOP
        PERFORM academico_test.fn_actividad_validar_rubrica_nivel(
            p_pk_tactividad, (v_e->>'pkCriterio')::BIGINT, (v_e->>'pkNivel')::BIGINT);
    END LOOP;
    SELECT string_agg('"' || c.NOMBRE || '"', ', ' ORDER BY c.ORDEN) INTO v_falta
      FROM academico_test.TACTIVIDAD_RUBRICA_CRITERIO c
     WHERE c.FK_TACTIVIDAD = p_pk_tactividad AND c.ACTIVE = TRUE
       AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_niveles) e
                        WHERE (e->>'pkCriterio')::BIGINT = c.PK_TACTIVIDAD_RUBRICA_CRITERIO);
    IF v_falta IS NOT NULL THEN
        RAISE EXCEPTION 'Falta elegir el nivel de los criterios % de la rúbrica', v_falta USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_cotejo_item(
    p_pk_tactividad BIGINT,
    p_pk_item       BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM academico_test.TACTIVIDAD_COTEJO_ITEM
                    WHERE PK_TACTIVIDAD_COTEJO_ITEM = p_pk_item AND FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'Uno de los elementos enviados no pertenece a la lista de cotejo de %',
            academico_test.fn_actividad_etiqueta(p_pk_tactividad) USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_cotejo_captura(
    p_pk_tactividad BIGINT,
    p_items         BIGINT[]
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_item BIGINT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM academico_test.TACTIVIDAD_COTEJO_ITEM
                    WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'La lista de cotejo de % no tiene elementos: configúrela antes de calificar',
            academico_test.fn_actividad_etiqueta(p_pk_tactividad) USING ERRCODE = '22023';
    END IF;
    FOREACH v_item IN ARRAY COALESCE(p_items, ARRAY[]::BIGINT[]) LOOP
        PERFORM academico_test.fn_actividad_validar_cotejo_item(p_pk_tactividad, v_item);
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_cumplido(p_cumplido VARCHAR)
RETURNS VOID
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_cumplido IS NULL OR p_cumplido NOT IN ('S', 'N') THEN
        RAISE EXCEPTION 'Indique si el elemento se cumple (S) o no se cumple (N)' USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_escala_valor(
    p_pk_tactividad BIGINT,
    p_pk_nivel      BIGINT,
    p_valor         NUMERIC,
    p_que           VARCHAR
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_e RECORD;
BEGIN
    SELECT e.PK_TACTIVIDAD_ESCALA, lv.VALOR AS tipo, e.VALOR_MIN, e.VALOR_MAX INTO v_e
      FROM academico_test.TACTIVIDAD_ESCALA e
      JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = e.FK_TLV_TIPO_ESCALA
     WHERE e.FK_TACTIVIDAD = p_pk_tactividad AND e.ACTIVE = TRUE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La escala de valoración de % no está configurada: defínala antes de calificar',
            academico_test.fn_actividad_etiqueta(p_pk_tactividad) USING ERRCODE = '22023';
    END IF;
    IF (p_pk_nivel IS NOT NULL) = (p_valor IS NOT NULL) THEN
        RAISE EXCEPTION 'En % indique un nivel (escala cualitativa) o un valor (escala numérica), uno de los dos', p_que
            USING ERRCODE = '22023';
    END IF;
    IF v_e.tipo = 'CUALITATIVA' THEN
        IF p_pk_nivel IS NULL THEN
            RAISE EXCEPTION 'La escala de % es cualitativa: en % elija un nivel',
                academico_test.fn_actividad_etiqueta(p_pk_tactividad), p_que USING ERRCODE = '22023';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM academico_test.TACTIVIDAD_ESCALA_NIVEL
                        WHERE PK_TACTIVIDAD_ESCALA_NIVEL = p_pk_nivel
                          AND FK_TACTIVIDAD_ESCALA = v_e.PK_TACTIVIDAD_ESCALA AND ACTIVE = TRUE) THEN
            RAISE EXCEPTION 'El nivel elegido en % no es uno de los niveles de la escala', p_que USING ERRCODE = '22023';
        END IF;
    ELSE
        IF p_valor IS NULL THEN
            RAISE EXCEPTION 'La escala de % es numérica: en % escriba un valor',
                academico_test.fn_actividad_etiqueta(p_pk_tactividad), p_que USING ERRCODE = '22023';
        END IF;
        IF p_valor < v_e.VALOR_MIN OR p_valor > v_e.VALOR_MAX THEN
            RAISE EXCEPTION 'En % el valor (%) debe estar entre % y %', p_que,
                academico_test.fn_numero_corto(p_valor), academico_test.fn_numero_corto(v_e.VALOR_MIN),
                academico_test.fn_numero_corto(v_e.VALOR_MAX) USING ERRCODE = '22023';
        END IF;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_escala_criterios(
    p_pk_tactividad BIGINT,
    p_criterios     JSONB
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_n      INT := academico_test.fn_actividad_escala_criterios_cantidad(p_pk_tactividad);
    v_nombre TEXT[];
    v_e      JSONB;
    v_idx    INT;
BEGIN
    IF v_n IS NULL THEN
        PERFORM academico_test.fn_actividad_validar_escala_valor(p_pk_tactividad, NULL, NULL, 'la calificación');
    END IF;
    IF p_criterios IS NULL OR jsonb_typeof(p_criterios) <> 'array' OR jsonb_array_length(p_criterios) <> v_n THEN
        RAISE EXCEPTION 'La escala de % tiene % criterio(s): califique cada uno una sola vez',
            academico_test.fn_actividad_etiqueta(p_pk_tactividad), v_n USING ERRCODE = '22023';
    END IF;
    IF (SELECT COUNT(*) <> COUNT(DISTINCT e->>'criterioIndex') FROM jsonb_array_elements(p_criterios) e) THEN
        RAISE EXCEPTION 'Se calificó dos veces el mismo criterio de la escala de %',
            academico_test.fn_actividad_etiqueta(p_pk_tactividad) USING ERRCODE = '22023';
    END IF;
    SELECT string_to_array(e.CRITERIOS_GENERALES, ',') INTO v_nombre
      FROM academico_test.TACTIVIDAD_ESCALA e WHERE e.FK_TACTIVIDAD = p_pk_tactividad AND e.ACTIVE = TRUE;
    FOR v_e IN SELECT * FROM jsonb_array_elements(p_criterios) LOOP
        v_idx := (v_e->>'criterioIndex')::INT;
        IF v_idx IS NULL OR v_idx < 0 OR v_idx >= v_n THEN
            RAISE EXCEPTION 'Uno de los criterios enviados no pertenece a la escala de %',
                academico_test.fn_actividad_etiqueta(p_pk_tactividad) USING ERRCODE = '22023';
        END IF;
        PERFORM academico_test.fn_actividad_validar_escala_valor(
            p_pk_tactividad, (v_e->>'pkNivel')::BIGINT, (v_e->>'valorNumerico')::NUMERIC,
            COALESCE('el criterio "' || NULLIF(TRIM(v_nombre[v_idx + 1]), '') || '"', 'la calificación'));
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_porcentaje(p_porcentaje NUMERIC, p_que VARCHAR)
RETURNS VOID
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_porcentaje IS NULL OR p_porcentaje < 0 OR p_porcentaje > 100 THEN
        RAISE EXCEPTION 'El porcentaje de % debe estar entre 0 y 100', p_que USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_calificacion(
    p_pk_tactividad_estudiante BIGINT,
    p_fecha                    DATE
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_pk BIGINT := academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante);
BEGIN
    PERFORM academico_test.fn_actividad_validar_calificable(v_pk);
    PERFORM academico_test.fn_actividad_validar_asistencia_calificar(p_pk_tactividad_estudiante, p_fecha);
END;
$$;

-- ---------------------------------------------------------------------------
-- Permiso: Regla 54
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_assert_propietario_resultados(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_autor VARCHAR;
BEGIN
    IF NOT academico_test.fn_usuario_es_docente_puro(p_pk_usuario_solicitante) THEN
        RETURN;
    END IF;
    SELECT CREATED_BY INTO v_autor FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_pk_tactividad;
    IF v_autor IS DISTINCT FROM p_pk_usuario_solicitante::VARCHAR THEN
        RAISE EXCEPTION '% la creó %: solo su autor puede ver y registrar los resultados de sus estudiantes',
            academico_test.fn_actividad_etiqueta(p_pk_tactividad),
            COALESCE(academico_test.fn_resolver_actor(NULLIF(regexp_replace(v_autor, '\D', '', 'g'), '')::BIGINT), 'otro docente')
            USING ERRCODE = '42501';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_instrumento_efectivo(BIGINT)
    IS 'VALOR del instrumento con que se define y califica la actividad: el propio, u Otro resuelto a su método de valoración si ya lo tiene. Lo usan las validaciones y los _interno de instrumento y calificación.';
COMMENT ON FUNCTION academico_test.fn_actividad_validar_instrumento(BIGINT, VARCHAR)
    IS 'P0002/22023 si la actividad no existe, está eliminada, no tiene instrumento o se evalúa con otro distinto de p_esperado (Otro vale como su método). Mensajes con la etiqueta y los nombres de los instrumentos.';
COMMENT ON FUNCTION academico_test.fn_actividad_validar_instrumento_permitido(BIGINT, VARCHAR)
    IS 'Reglas 40/41: 22023 si el tipo de evaluación del referente de la actividad no admite el instrumento (fn_instrumento_permitido_por_tipo_evaluacion).';
COMMENT ON FUNCTION academico_test.fn_actividad_validar_instrumento_definicion(BIGINT, JSONB)
    IS 'Validador central de PUT /planeador/actividades/:ID/instrumento: instrumento configurable, permitido por el referente y definición válida según su tipo (en Otro, su propia configuración y la del método elegido). Lo usa fn_actividad_instrumento_definir_interno.';
COMMENT ON FUNCTION academico_test.fn_actividad_validar_calificable(BIGINT)
    IS 'Regla 52: 22023 si la actividad está eliminada, es formativa (se registra con observación) o no tiene instrumento.';
COMMENT ON FUNCTION academico_test.fn_actividad_validar_asistencia_calificar(BIGINT, DATE)
    IS '22023 si el estudiante no tiene asistencia en la asignatura de la actividad ese día, o si es inasistencia injustificada. La justificada deja calificar.';
COMMENT ON FUNCTION academico_test.fn_actividad_validar_calificacion(BIGINT, DATE)
    IS 'Validador central de una calificación: la asignación existe (P0002), la actividad es calificable y hay asistencia válida en la fecha. Lo usan fn_actividad_nota_calificar_interno y los _bulk_interno.';
COMMENT ON FUNCTION academico_test.fn_actividad_assert_propietario_resultados(BIGINT, BIGINT)
    IS 'Regla 54: 42501 si un docente de aula ve o registra resultados de una actividad que no creó. Coordinación, rectoría y super admin pasan. Lo usan los wrappers de calificación y de lectura de notas.';
