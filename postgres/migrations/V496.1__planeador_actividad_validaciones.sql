-- V496.1 — Planeador, actividad: capa de validaciones (1 de 4).
--
-- Qué hace: una función por regla de la actividad y de lo que cuelga de ella
-- (evidencias de la unidad, criterios de su rúbrica, estudiantes, materiales,
-- adaptaciones, recuperación), más las centrales fn_actividad_validar_campos
-- (formato de lo que llega) y fn_actividad_validar_coherencia (el estado que
-- va a quedar). Las usan los _interno de V496.2; los assert_ de propiedad
-- (Regla 25) y de edición (Regla 37) los usa el wrapper de V496.3.
-- Mensajes con nombres (nunca PKs ni columnas).
-- Depende de: V492.1 (validaciones de unidad y rótulos), V482 (bloqueos de
-- borrado), V479 (contexto evaluativo), V460 (programación), V224 (tablas).

SET search_path TO academico_test, public;

-- Sustituida por fn_actividad_validar_asignatura/_grupo/_unidad, con nombres.
DROP FUNCTION IF EXISTS academico_test.fn_actividad_validar_referencias_activas(BIGINT, BIGINT, BIGINT);

-- ---------------------------------------------------------------------------
-- Nombres legibles para los mensajes
-- ---------------------------------------------------------------------------

-- Regla 13: el nombre que el referente le da a la actividad (Rótulo de
-- Ejecución). Con unidad manda el referente de la unidad; sin ella, el que le
-- aplica al grado del grupo y la asignatura (la misma regla de V511).
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_rotulo(
    p_fk_tgrupo      BIGINT,
    p_fk_tasignatura BIGINT,
    p_fk_tunidad     BIGINT
)
RETURNS VARCHAR
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(
        (SELECT NULLIF(TRIM(rc.ROTULO_EJECUCION), '')
           FROM academico_test.TUNIDAD u
           JOIN academico_test.TREFERENTE_CURRICULAR rc ON rc.PK_REFERENTE_CURRICULAR = u.FK_REFERENTE_CURRICULAR
          WHERE u.PK_TUNIDAD = p_fk_tunidad),
        (SELECT NULLIF(TRIM(rc.ROTULO_EJECUCION), '')
           FROM academico_test.TGRUPO g
           JOIN academico_test.TREFERENTE_CURRICULAR rc
             ON rc.PK_REFERENTE_CURRICULAR = academico_test.fn_unidad_referente_aplicable(g.FK_TGRADO, p_fk_tasignatura, NULL)
          WHERE g.PK_TGRUPO = p_fk_tgrupo),
        'Actividad')::VARCHAR;
$$;

-- 'Taller "Fracciones"': rótulo + título, el sujeto de los mensajes.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_etiqueta_de(
    p_titulo         VARCHAR,
    p_fk_tgrupo      BIGINT,
    p_fk_tasignatura BIGINT,
    p_fk_tunidad     BIGINT
)
RETURNS VARCHAR
LANGUAGE sql
STABLE
AS $$
    SELECT format('%s "%s"', academico_test.fn_actividad_rotulo(p_fk_tgrupo, p_fk_tasignatura, p_fk_tunidad), TRIM(p_titulo))::VARCHAR;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_etiqueta(p_pk_tactividad BIGINT)
RETURNS VARCHAR
LANGUAGE sql
STABLE
AS $$
    SELECT academico_test.fn_actividad_etiqueta_de(TITULO, FK_TGRUPO, FK_TASIGNATURA, FK_TUNIDAD)
      FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_pk_tactividad;
$$;

-- "el grupo 803M de Octavo"
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_grupo_etiqueta(p_pk_tgrupo BIGINT)
RETURNS VARCHAR
LANGUAGE sql
STABLE
AS $$
    SELECT format('el grupo %s de %s', gr.NOMBRE, g.NOMBRE)
      FROM academico_test.TGRUPO gr
      JOIN academico_test.TGRADO g ON g.PK_TGRADO = gr.FK_TGRADO
     WHERE gr.PK_TGRUPO = p_pk_tgrupo;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_estudiante_nombre(p_pk_tmatricula BIGINT)
RETURNS VARCHAR
LANGUAGE sql
STABLE
AS $$
    SELECT NULLIF(TRIM(CONCAT_WS(' ', us.PRIMER_NOMBRE, us.SEGUNDO_NOMBRE,
                                      us.PRIMER_APELLIDO, us.SEGUNDO_APELLIDO)), '')
      FROM academico_test.TMATRICULA m
      JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
      JOIN academico_test.TUSUARIO us    ON us.PK_TUSUARIO = es.FK_TUSUARIO
     WHERE m.PK_TMATRICULA = p_pk_tmatricula;
$$;

-- ---------------------------------------------------------------------------
-- Actividad: existencia, estado y formato de los campos
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_existente(p_pk_tactividad BIGINT)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_pk_tactividad IS NULL OR NOT EXISTS (
        SELECT 1 FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_pk_tactividad
    ) THEN
        RAISE EXCEPTION 'No se encontró la actividad solicitada' USING ERRCODE = 'P0002';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_activa(p_pk_tactividad BIGINT)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM academico_test.TACTIVIDAD
                WHERE PK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = FALSE) THEN
        RAISE EXCEPTION '% ya fue eliminada y no admite cambios',
            academico_test.fn_actividad_etiqueta(p_pk_tactividad)
            USING ERRCODE = '22023';
    END IF;
END;
$$;

-- Bloque 2: nombre obligatorio de hasta 150 caracteres.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_titulo(p_titulo VARCHAR, p_obligatorio BOOLEAN)
RETURNS VOID
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_titulo IS NULL AND NOT p_obligatorio THEN
        RETURN;
    END IF;
    IF NULLIF(TRIM(p_titulo), '') IS NULL THEN
        RAISE EXCEPTION 'Escriba el nombre de la actividad' USING ERRCODE = '22023';
    END IF;
    IF length(TRIM(p_titulo)) > 150 THEN
        RAISE EXCEPTION 'El nombre de la actividad no puede pasar de 150 caracteres (tiene %)',
            length(TRIM(p_titulo)) USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_texto(p_valor VARCHAR, p_campo VARCHAR, p_maximo INT)
RETURNS VOID
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF length(TRIM(p_valor)) > p_maximo THEN
        RAISE EXCEPTION '% no puede pasar de % caracteres (tiene %)', p_campo, p_maximo, length(TRIM(p_valor))
            USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_requerido(p_valor BIGINT, p_mensaje VARCHAR)
RETURNS VOID
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_valor IS NULL THEN
        RAISE EXCEPTION '%', p_mensaje USING ERRCODE = '22023';
    END IF;
END;
$$;

-- Catálogo TLISTA_VALOR: el mensaje nombra el campo, nunca la pk ni la tabla.
-- La categoría se exige solo si está sembrada (entornos donde el seed es no-op).
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_catalogo(
    p_fk        BIGINT,
    p_categoria VARCHAR,
    p_campo     VARCHAR
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_nombre    VARCHAR;
    v_categoria VARCHAR;
BEGIN
    IF p_fk IS NULL THEN
        RETURN;
    END IF;
    SELECT NOMBRE, CATEGORIA INTO v_nombre, v_categoria
      FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_fk AND ACTIVE = TRUE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La opción elegida en "%" ya no existe o fue desactivada; elija otra', p_campo
            USING ERRCODE = '23503';
    END IF;
    IF v_categoria IS DISTINCT FROM p_categoria
       AND EXISTS (SELECT 1 FROM academico_test.TLISTA_VALOR WHERE CATEGORIA = p_categoria AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION '"%" no es una opción válida para "%"', v_nombre, p_campo
            USING ERRCODE = '23503';
    END IF;
END;
$$;

-- Firma histórica que usan V226 y V469: se conserva y traduce la
-- etiqueta técnica (FK_TLV_TIPO_ACTIVIDAD, tipoRecurso...) al nombre del campo.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_lv_assert(
    p_fk         BIGINT,
    p_categoria  VARCHAR,
    p_etiqueta   VARCHAR
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_actividad_validar_catalogo(p_fk, p_categoria,
        CASE p_categoria
            WHEN 'TIPO_ACTIVIDAD'               THEN 'Tipo de actividad'
            WHEN 'TIPO_JERARQUIA_ACTIVIDAD'     THEN 'Jerarquía'
            WHEN 'MODALIDAD'                    THEN 'Modalidad'
            WHEN 'INSTRUMENTO_EVALUACION'       THEN 'Instrumento de evaluación'
            WHEN 'TIPO_EVIDENCIA'               THEN 'Tipo de evidencia esperada'
            WHEN 'TIPO_EVIDENCIA_OTRO'          THEN 'Tipo de evidencia esperada'
            WHEN 'METODO_VALORACION'            THEN 'Método de valoración'
            WHEN 'TIPO_CALCULO'                 THEN 'Tipo de cálculo'
            WHEN 'TIPO_RECURSO'                 THEN 'Tipo - Fuente del material'
            WHEN 'TIPO_ADAPTACION'              THEN 'Tipo de adaptación'
            WHEN 'FORMATO_ADAPTACION'           THEN 'Versión modificada del instrumento'
            WHEN 'APLICA_A'                     THEN '¿A quién se aplica?'
            WHEN 'DESTINO_RECUPERACION'         THEN '¿Qué desea recuperar?'
            WHEN 'TIPO_APLICACION_RECUPERACION' THEN '¿Cómo se aplicará la nota?'
            WHEN 'TIPO_CALCULO_RECUPERACION'    THEN 'Tipo de cálculo de la recuperación'
            WHEN 'TIPO_ESCALA'                  THEN 'Tipo de escala'
            ELSE initcap(replace(lower(regexp_replace(p_etiqueta, '^FK_TLV_', '')), '_', ' '))
        END);
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_asignatura(p_fk_tasignatura BIGINT)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_nombre VARCHAR;
    v_active BOOLEAN;
BEGIN
    IF p_fk_tasignatura IS NULL THEN
        RETURN;
    END IF;
    SELECT NOMBRE, ACTIVE INTO v_nombre, v_active
      FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_fk_tasignatura;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La asignatura seleccionada no existe' USING ERRCODE = '23503';
    END IF;
    IF NOT v_active THEN
        RAISE EXCEPTION 'La asignatura "%" ya no está activa; elija otra', v_nombre USING ERRCODE = '23503';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_grupo(p_fk_tgrupo BIGINT)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_active BOOLEAN;
BEGIN
    IF p_fk_tgrupo IS NULL THEN
        RETURN;
    END IF;
    SELECT ACTIVE INTO v_active FROM academico_test.TGRUPO WHERE PK_TGRUPO = p_fk_tgrupo;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El grupo seleccionado no existe' USING ERRCODE = '23503';
    END IF;
    IF NOT v_active THEN
        RAISE EXCEPTION 'No se puede usar %: ya no está activo',
            academico_test.fn_actividad_grupo_etiqueta(p_fk_tgrupo) USING ERRCODE = '23503';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_unidad(p_fk_tunidad BIGINT)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_fk_tunidad IS NULL THEN
        RETURN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM academico_test.TUNIDAD WHERE PK_TUNIDAD = p_fk_tunidad) THEN
        RAISE EXCEPTION 'La unidad seleccionada no existe' USING ERRCODE = '23503';
    END IF;
    IF EXISTS (SELECT 1 FROM academico_test.TUNIDAD WHERE PK_TUNIDAD = p_fk_tunidad AND ACTIVE = FALSE) THEN
        RAISE EXCEPTION 'No se puede usar %: ya fue eliminada',
            academico_test.fn_unidad_etiqueta(p_fk_tunidad) USING ERRCODE = '23503';
    END IF;
END;
$$;

-- Bloque 4: el cierre no puede ser anterior al inicio.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_fechas_orden(
    p_fecha_inicio DATE,
    p_fecha_cierre DATE
)
RETURNS VOID
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_fecha_inicio IS NOT NULL AND p_fecha_cierre IS NOT NULL
       AND p_fecha_cierre < p_fecha_inicio THEN
        RAISE EXCEPTION 'La fecha de cierre (%) no puede ser anterior a la de inicio (%)',
            to_char(p_fecha_cierre, 'DD/MM/YYYY'), to_char(p_fecha_inicio, 'DD/MM/YYYY')
            USING ERRCODE = '22023';
    END IF;
END;
$$;

-- La nota de una actividad se imputa a un solo periodo de evaluación
-- (fn_actividad_periodo_evaluacion): no puede repartirse entre dos. Se cuentan
-- los periodos que SOLAPAN el rango, no los que contienen sus extremos: un
-- cierre en el hueco entre dos cortes también sale del periodo en que empezó.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_periodo_evaluacion_unico(
    p_fk_tgrupo    BIGINT,
    p_fk_tunidad   BIGINT,
    p_fecha_inicio DATE,
    p_fecha_cierre DATE
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_total    INT;
    v_periodos TEXT;
    v_primero  RECORD;
BEGIN
    IF p_fecha_inicio IS NULL OR p_fecha_cierre IS NULL THEN
        RETURN;
    END IF;

    SELECT count(*),
           string_agg(format('%s (%s a %s)', pe.NOMBRE, to_char(pe.FECHA_INICIO, 'DD/MM/YYYY'),
                             to_char(pe.FECHA_FIN, 'DD/MM/YYYY')), ', ' ORDER BY pe.FECHA_INICIO)
      INTO v_total, v_periodos
      FROM academico_test.TGRADO g
      JOIN academico_test.TPERIODO_EVALUACION pe
        ON pe.FK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO AND pe.ACTIVE = TRUE
     WHERE g.PK_TGRADO = academico_test.fn_actividad_grado(p_fk_tgrupo, p_fk_tunidad)
       AND pe.FECHA_INICIO <= p_fecha_cierre
       AND pe.FECHA_FIN    >= p_fecha_inicio;

    IF v_total > 1 THEN
        SELECT pe.NOMBRE, pe.FECHA_FIN INTO v_primero
          FROM academico_test.TGRADO g
          JOIN academico_test.TPERIODO_EVALUACION pe
            ON pe.FK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO AND pe.ACTIVE = TRUE
         WHERE g.PK_TGRADO = academico_test.fn_actividad_grado(p_fk_tgrupo, p_fk_tunidad)
           AND pe.FECHA_INICIO <= p_fecha_cierre
           AND pe.FECHA_FIN    >= p_fecha_inicio
         ORDER BY pe.FECHA_INICIO
         LIMIT 1;

        RAISE EXCEPTION 'La actividad no puede abarcar varios periodos de evaluación: del % al % pasa por %',
            to_char(p_fecha_inicio, 'DD/MM/YYYY'), to_char(p_fecha_cierre, 'DD/MM/YYYY'), v_periodos
            USING ERRCODE = '22023',
                  HINT    = format('Si empieza en %s, la fecha de cierre debe ser a más tardar el %s',
                                   v_primero.NOMBRE, to_char(v_primero.FECHA_FIN, 'DD/MM/YYYY'));
    END IF;
END;
$$;

-- Regla 24: la unidad es "compatible" si es de la misma asignatura y del grado
-- del grupo. Aplica al crear o editar con unidad, no solo al vincular.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_unidad_compatible(
    p_fk_tasignatura BIGINT,
    p_fk_tgrupo      BIGINT,
    p_fk_tunidad     BIGINT,
    p_titulo         VARCHAR
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_asig_uni  BIGINT;
    v_grado_uni BIGINT;
    v_grado_gr  BIGINT;
BEGIN
    IF p_fk_tunidad IS NULL THEN
        RETURN;
    END IF;
    SELECT FK_TASIGNATURA, FK_TGRADO INTO v_asig_uni, v_grado_uni
      FROM academico_test.TUNIDAD WHERE PK_TUNIDAD = p_fk_tunidad;
    IF p_fk_tasignatura IS NOT NULL AND p_fk_tasignatura IS DISTINCT FROM v_asig_uni THEN
        RAISE EXCEPTION '% es de "%" y % es de "%": elija una unidad de la misma asignatura',
            p_titulo,
            (SELECT NOMBRE FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_fk_tasignatura),
            academico_test.fn_unidad_etiqueta(p_fk_tunidad),
            (SELECT NOMBRE FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = v_asig_uni)
            USING ERRCODE = '22023';
    END IF;
    SELECT FK_TGRADO INTO v_grado_gr FROM academico_test.TGRUPO WHERE PK_TGRUPO = p_fk_tgrupo;
    IF v_grado_gr IS NOT NULL AND v_grado_gr IS DISTINCT FROM v_grado_uni THEN
        RAISE EXCEPTION '% es de "%" y % es para %',
            academico_test.fn_unidad_etiqueta(p_fk_tunidad),
            (SELECT NOMBRE FROM academico_test.TGRADO WHERE PK_TGRADO = v_grado_uni),
            p_titulo, academico_test.fn_actividad_grupo_etiqueta(p_fk_tgrupo)
            USING ERRCODE = '22023';
    END IF;
END;
$$;

-- Evaluativa en contexto Formativo: el enfoque valora con observaciones, y un
-- 'S' dejaba la actividad calificable contra su referente.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_evaluativa_contexto(
    p_es_evaluativa  academico_test.bool_sn,
    p_ctx_evaluativo BOOLEAN,
    p_fk_tunidad     BIGINT,
    p_titulo         VARCHAR
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_es_evaluativa = 'S' AND NOT p_ctx_evaluativo THEN
        IF p_fk_tunidad IS NOT NULL THEN
            RAISE EXCEPTION '% no puede ser sumativa: % se rige por un referente curricular Formativo, que valora el aprendizaje con observaciones y no con nota',
                p_titulo, academico_test.fn_unidad_etiqueta(p_fk_tunidad)
                USING ERRCODE = '22023';
        END IF;
        RAISE EXCEPTION '% no puede ser sumativa: el referente curricular de su grado y asignatura es Formativo, y valora el aprendizaje con observaciones y no con nota',
            p_titulo USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_recuperacion_sumativa(
    p_es_recuperacion BOOLEAN,
    p_es_evaluativa   academico_test.bool_sn,
    p_titulo          VARCHAR
)
RETURNS VOID
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_es_recuperacion AND p_es_evaluativa = 'N' THEN
        RAISE EXCEPTION '% es de recuperación y debe ser sumativa: la recuperación reemplaza o combina una nota',
            p_titulo USING ERRCODE = '22023';
    END IF;
END;
$$;

-- Bloque 5: el método de cálculo de la unidad decide si el % se captura a mano
-- (Ponderar), no aplica (Promediar) o sale del puntaje (Sumatoria).
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_ponderacion(
    p_ponderacion   NUMERIC,
    p_fk_tunidad    BIGINT,
    p_es_evaluativa academico_test.bool_sn,
    p_titulo        VARCHAR
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_ponderacion IS NULL THEN
        RETURN;
    END IF;
    IF p_ponderacion < 0 OR p_ponderacion > 100 THEN
        RAISE EXCEPTION 'El peso de la actividad (%%) debe estar entre 0 y 100; llegó %', p_ponderacion
            USING ERRCODE = '22023';
    END IF;
    IF p_fk_tunidad IS NULL THEN
        RAISE EXCEPTION 'El peso (%%) de % solo aplica cuando está vinculada a una unidad', p_titulo
            USING ERRCODE = '22023';
    END IF;
    IF p_es_evaluativa = 'N' THEN
        RAISE EXCEPTION '% no es sumativa: no lleva peso (%%) en la unidad', p_titulo
            USING ERRCODE = '22023';
    END IF;
    PERFORM academico_test.fn_unidad_validar_ponderacion_actividad_manual(p_fk_tunidad);
END;
$$;

-- Sumatoria: el puntaje de la actividad es un número positivo.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_nota_maxima(p_nota_maxima NUMERIC)
RETURNS VOID
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_nota_maxima IS NOT NULL AND p_nota_maxima <= 0 THEN
        RAISE EXCEPTION 'El puntaje de la actividad debe ser un número positivo; llegó %', p_nota_maxima
            USING ERRCODE = '22023';
    END IF;
END;
$$;

-- Regla 24: con unidad y sumativa, Ponderar exige el peso y Sumatoria el
-- puntaje; Promediar no pide nada.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_peso_requerido(
    p_fk_tunidad    BIGINT,
    p_es_evaluativa academico_test.bool_sn,
    p_ponderacion   NUMERIC,
    p_nota_maxima   NUMERIC,
    p_titulo        VARCHAR
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_fk_tunidad IS NULL OR p_es_evaluativa IS DISTINCT FROM 'S' THEN
        RETURN;
    END IF;
    CASE academico_test.fn_unidad_calculo_definitiva_modo(p_fk_tunidad)
        WHEN 'PONDERAR' THEN
            IF p_ponderacion IS NULL THEN
                RAISE EXCEPTION '% pondera sus actividades: indique el peso (%%) de %',
                    academico_test.fn_unidad_etiqueta(p_fk_tunidad), p_titulo USING ERRCODE = '22023';
            END IF;
        WHEN 'SUMATORIA' THEN
            IF p_nota_maxima IS NULL THEN
                RAISE EXCEPTION '% suma los puntajes de sus actividades: indique el puntaje de %',
                    academico_test.fn_unidad_etiqueta(p_fk_tunidad), p_titulo USING ERRCODE = '22023';
            END IF;
        ELSE NULL;
    END CASE;
END;
$$;

-- Backstop de U_TACTIVIDAD_1: con unidad o grupo NULL el UNIQUE no garantiza
-- nada (NULL nunca colisiona).
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_titulo_unico(
    p_titulo           VARCHAR,
    p_fk_tunidad       BIGINT,
    p_fk_tgrupo        BIGINT,
    p_fk_tlv_jerarquia BIGINT,
    p_excluir_pk       BIGINT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM academico_test.TACTIVIDAD
         WHERE UPPER(TRIM(TITULO)) = UPPER(TRIM(p_titulo))
           AND FK_TUNIDAD       IS NOT DISTINCT FROM p_fk_tunidad
           AND FK_TGRUPO        IS NOT DISTINCT FROM p_fk_tgrupo
           AND FK_TLV_JERARQUIA = p_fk_tlv_jerarquia
           AND ACTIVE = TRUE
           AND PK_TACTIVIDAD IS DISTINCT FROM p_excluir_pk
    ) THEN
        RAISE EXCEPTION 'Ya existe "%" en % para %: elija otro nombre',
            TRIM(p_titulo),
            COALESCE(academico_test.fn_unidad_etiqueta(p_fk_tunidad), 'las actividades sin unidad'),
            COALESCE(academico_test.fn_actividad_grupo_etiqueta(p_fk_tgrupo), 'las actividades sin grupo')
            USING ERRCODE = '23505';
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Evidencias (Bloque 2) y criterios de la rúbrica de la unidad
-- ---------------------------------------------------------------------------

-- Las evidencias salen de la unidad: sin unidad no hay de dónde escogerlas.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_tiene_unidad(p_fk_tunidad BIGINT, p_titulo VARCHAR, p_que VARCHAR)
RETURNS VOID
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_fk_tunidad IS NULL THEN
        RAISE EXCEPTION '% no está vinculada a ninguna unidad: vincúlela primero para seleccionar %',
            p_titulo, p_que USING ERRCODE = '22023';
    END IF;
END;
$$;

-- Una evidencia es un elemento de segundo nivel de un enunciado que la unidad
-- seleccionó, del referente de la unidad y de su grado (Reglas 12, 16, 17).
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_evidencia(
    p_fk_tunidad             BIGINT,
    p_titulo                 VARCHAR,
    p_fk_referente_enunciado BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_padre  BIGINT;
    v_active BOOLEAN;
    v_estado VARCHAR;
BEGIN
    IF p_fk_referente_enunciado IS NULL THEN
        RAISE EXCEPTION 'Seleccione la evidencia que cubre %', p_titulo USING ERRCODE = '22023';
    END IF;
    PERFORM academico_test.fn_actividad_validar_tiene_unidad(p_fk_tunidad, p_titulo, 'sus evidencias');

    SELECT FK_PADRE, ACTIVE, ESTADO INTO v_padre, v_active, v_estado
      FROM academico_test.TREFERENTE_ENUNCIADO WHERE PK_REFERENTE_ENUNCIADO = p_fk_referente_enunciado;
    IF NOT FOUND OR NOT v_active THEN
        RAISE EXCEPTION 'Una de las evidencias seleccionadas para % ya no existe en el referente curricular',
            p_titulo USING ERRCODE = '23503';
    END IF;
    IF v_estado IS DISTINCT FROM 'A' THEN
        RAISE EXCEPTION '% está inactiva en el referente curricular y no se puede seleccionar',
            academico_test.fn_unidad_enunciado_etiqueta(p_fk_referente_enunciado) USING ERRCODE = '23503';
    END IF;
    IF v_padre IS NULL THEN
        RAISE EXCEPTION '% es un elemento de primer nivel: en la actividad se marcan sus evidencias',
            academico_test.fn_unidad_enunciado_etiqueta(p_fk_referente_enunciado) USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM academico_test.TUNIDAD_ENUNCIADO
                    WHERE FK_TUNIDAD = p_fk_tunidad AND FK_REFERENTE_ENUNCIADO = v_padre AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION '% pertenece a %, que no está seleccionado en %',
            academico_test.fn_unidad_enunciado_etiqueta(p_fk_referente_enunciado),
            academico_test.fn_unidad_enunciado_etiqueta(v_padre),
            academico_test.fn_unidad_etiqueta(p_fk_tunidad)
            USING ERRCODE = '22023';
    END IF;
    PERFORM academico_test.fn_unidad_validar_enunciado_referente(p_fk_tunidad, p_fk_referente_enunciado);
    PERFORM academico_test.fn_unidad_validar_enunciado_grado(p_fk_tunidad, p_fk_referente_enunciado);
END;
$$;

-- Regla 43: con unidad, al menos una evidencia, siempre que la unidad ofrezca alguna.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_evidencias_minimo(
    p_fk_tunidad BIGINT,
    p_titulo     VARCHAR,
    p_evidencias BIGINT[]
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_etq_1 VARCHAR;
    v_etq_2 VARCHAR;
BEGIN
    IF p_fk_tunidad IS NULL
       OR EXISTS (SELECT 1 FROM unnest(p_evidencias) x WHERE x IS NOT NULL)
       OR NOT EXISTS (SELECT 1
                        FROM academico_test.TUNIDAD_ENUNCIADO ue
                        JOIN academico_test.TREFERENTE_ENUNCIADO ev
                          ON ev.FK_PADRE = ue.FK_REFERENTE_ENUNCIADO AND ev.ACTIVE = TRUE
                       WHERE ue.FK_TUNIDAD = p_fk_tunidad AND ue.ACTIVE = TRUE) THEN
        RETURN;
    END IF;
    SELECT LOWER(rc.NIVEL_1_ETIQUETA), LOWER(rc.NIVEL_2_ETIQUETA) INTO v_etq_1, v_etq_2
      FROM academico_test.TUNIDAD u
      JOIN academico_test.TREFERENTE_CURRICULAR rc ON rc.PK_REFERENTE_CURRICULAR = u.FK_REFERENTE_CURRICULAR
     WHERE u.PK_TUNIDAD = p_fk_tunidad;
    RAISE EXCEPTION 'Marque al menos una % de algún % de % que cubre %',
        COALESCE(v_etq_2, 'evidencia'), COALESCE(v_etq_1, 'enunciado'),
        academico_test.fn_unidad_etiqueta(p_fk_tunidad), p_titulo
        USING ERRCODE = '22023';
END;
$$;

-- El criterio debe ser de la rúbrica (activa) de la misma unidad de la actividad.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_criterio(
    p_fk_tunidad          BIGINT,
    p_titulo              VARCHAR,
    p_fk_tcriterio_unidad BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_desc       VARCHAR;
    v_unidad     BIGINT;
    v_active     BOOLEAN;
    v_rub_active BOOLEAN;
BEGIN
    IF p_fk_tcriterio_unidad IS NULL THEN
        RAISE EXCEPTION 'Seleccione el criterio de la rúbrica que evalúa %', p_titulo
            USING ERRCODE = '22023';
    END IF;
    PERFORM academico_test.fn_actividad_validar_tiene_unidad(p_fk_tunidad, p_titulo, 'criterios de su rúbrica');

    SELECT cu.DESCRIPCION, ru.FK_TUNIDAD, cu.ACTIVE, ru.ACTIVE
      INTO v_desc, v_unidad, v_active, v_rub_active
      FROM academico_test.TCRITERIO_UNIDAD cu
      JOIN academico_test.TRUBRICA_UNIDAD ru ON ru.PK_TRUBRICA_UNIDAD = cu.FK_TRUBRICA_UNIDAD
     WHERE cu.PK_TCRITERIO_UNIDAD = p_fk_tcriterio_unidad;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Uno de los criterios seleccionados para % no existe', p_titulo
            USING ERRCODE = '23503';
    END IF;
    IF NOT v_active OR NOT v_rub_active THEN
        RAISE EXCEPTION 'El criterio "%" fue eliminado de la rúbrica de % y no se puede seleccionar',
            v_desc, academico_test.fn_unidad_etiqueta(v_unidad) USING ERRCODE = '23503';
    END IF;
    IF v_unidad IS DISTINCT FROM p_fk_tunidad THEN
        RAISE EXCEPTION 'El criterio "%" es de la rúbrica de % y % está en %',
            v_desc, academico_test.fn_unidad_etiqueta(v_unidad), p_titulo,
            academico_test.fn_unidad_etiqueta(p_fk_tunidad)
            USING ERRCODE = '22023';
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Estudiantes (Bloque 1)
-- ---------------------------------------------------------------------------

-- Las matrículas deben ser activas y del grupo de la actividad; sin grupo no
-- hay roster del que escoger (antes se aceptaba cualquier matrícula del sistema).
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_matriculas(
    p_fk_tgrupo      BIGINT,
    p_titulo         VARCHAR,
    p_fk_tmatriculas BIGINT[],
    p_todo_el_grupo  BOOLEAN
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_ajena BIGINT;
BEGIN
    IF p_fk_tgrupo IS NULL
       AND (COALESCE(p_todo_el_grupo, FALSE) OR COALESCE(array_length(p_fk_tmatriculas, 1), 0) > 0) THEN
        RAISE EXCEPTION '% no tiene grupo: asígnele un grupo antes de escoger sus estudiantes', p_titulo
            USING ERRCODE = '22023';
    END IF;
    SELECT mid INTO v_ajena
      FROM unnest(p_fk_tmatriculas) mid
     WHERE mid IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM academico_test.TMATRICULA m
                        WHERE m.PK_TMATRICULA = mid AND m.ACTIVE = TRUE AND m.FK_TGRUPO = p_fk_tgrupo)
     LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION '% no tiene una matrícula activa en %: no se puede incluir en %',
            COALESCE(academico_test.fn_actividad_estudiante_nombre(v_ajena), 'Uno de los estudiantes seleccionados'),
            academico_test.fn_actividad_grupo_etiqueta(p_fk_tgrupo), p_titulo
            USING ERRCODE = '23503';
    END IF;
END;
$$;

-- Bloque 1: mínimo un estudiante, cuando el grupo tiene a quién asignar.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_estudiantes_minimo(
    p_pk_tactividad BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_grupo BIGINT;
BEGIN
    SELECT FK_TGRUPO INTO v_grupo FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_pk_tactividad;
    IF v_grupo IS NULL
       OR EXISTS (SELECT 1 FROM academico_test.TACTIVIDAD_ESTUDIANTE
                   WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE)
       OR NOT EXISTS (SELECT 1 FROM academico_test.TMATRICULA WHERE FK_TGRUPO = v_grupo AND ACTIVE = TRUE) THEN
        RETURN;
    END IF;
    RAISE EXCEPTION '% debe tener al menos un estudiante %',
        academico_test.fn_actividad_etiqueta(p_pk_tactividad),
        regexp_replace(academico_test.fn_actividad_grupo_etiqueta(v_grupo), '^el grupo', 'del grupo')
        USING ERRCODE = '22023';
END;
$$;

-- ---------------------------------------------------------------------------
-- Materiales de apoyo (Bloque 3, Regla 82) y adaptaciones (Bloque 6)
-- ---------------------------------------------------------------------------

-- Toda URL guardada se abre en el navegador del estudiante: solo http(s).
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_url(p_url VARCHAR, p_que VARCHAR)
RETURNS VOID
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF NULLIF(TRIM(p_url), '') IS NOT NULL AND TRIM(p_url) !~* '^https?://[^\s/$.?#][^\s]*$' THEN
        RAISE EXCEPTION 'El enlace indicado en % no es una dirección web válida: debe empezar por http:// o https://',
            p_que USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_archivo_existente(p_fk_tarchivo BIGINT, p_que VARCHAR)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    -- Sin ACTIVE a propósito: file-service crea TARCHIVO inactivo y lo activa
    -- solo después de que la llamada que lo registra responde 2xx.
    IF p_fk_tarchivo IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM academico_test.TARCHIVO WHERE PK_TARCHIVO = p_fk_tarchivo) THEN
        RAISE EXCEPTION 'El archivo adjunto en % no se encontró; vuelva a cargarlo', p_que USING ERRCODE = '23503';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_materiales(p_materiales JSONB)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_m   RECORD;
    v_que VARCHAR;
BEGIN
    IF p_materiales IS NULL THEN
        RETURN;
    END IF;
    IF jsonb_typeof(p_materiales) <> 'array' THEN
        RAISE EXCEPTION 'Los materiales de apoyo deben enviarse como una lista' USING ERRCODE = '22023';
    END IF;
    IF jsonb_array_length(p_materiales) > 10 THEN
        RAISE EXCEPTION 'Una actividad admite máximo 10 materiales de apoyo; llegaron %',
            jsonb_array_length(p_materiales) USING ERRCODE = '22023';
    END IF;
    FOR v_m IN SELECT e AS j, ord FROM jsonb_array_elements(p_materiales) WITH ORDINALITY AS t(e, ord) LOOP
        v_que := format('el material de apoyo %s', v_m.ord);
        IF (v_m.j->>'tipoRecurso') IS NULL THEN
            RAISE EXCEPTION 'Indique el tipo - fuente en %', v_que USING ERRCODE = '22023';
        END IF;
        IF (NULLIF(TRIM(v_m.j->>'url'), '') IS NULL) = ((v_m.j->>'fkTarchivo') IS NULL) THEN
            RAISE EXCEPTION 'Adjunte un archivo o escriba un enlace en % (uno de los dos)', v_que
                USING ERRCODE = '22023';
        END IF;
        PERFORM academico_test.fn_actividad_validar_catalogo(
            (v_m.j->>'tipoRecurso')::BIGINT, 'TIPO_RECURSO', 'Tipo - Fuente del material');
        PERFORM academico_test.fn_actividad_validar_texto(v_m.j->>'descripcion', 'El nombre indicado en ' || v_que, 100);
        PERFORM academico_test.fn_actividad_validar_url(v_m.j->>'url', v_que);
        PERFORM academico_test.fn_actividad_validar_archivo_existente((v_m.j->>'fkTarchivo')::BIGINT, v_que);
    END LOOP;
END;
$$;

-- Formato de cada adaptación. Que sus estudiantes estén en la actividad lo
-- valida fn_actividad_validar_adaptacion_estudiantes, que necesita la actividad.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_adaptaciones(p_adaptaciones JSONB)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_a       RECORD;
    v_que     VARCHAR;
    v_usa     VARCHAR;
    v_formato VARCHAR;
    v_aplica  VARCHAR;
BEGIN
    IF p_adaptaciones IS NULL THEN
        RETURN;
    END IF;
    IF jsonb_typeof(p_adaptaciones) <> 'array' THEN
        RAISE EXCEPTION 'Las adaptaciones curriculares deben enviarse como una lista' USING ERRCODE = '22023';
    END IF;
    FOR v_a IN SELECT e AS j, ord FROM jsonb_array_elements(p_adaptaciones) WITH ORDINALITY AS t(e, ord) LOOP
        v_que := format('la adaptación %s', v_a.ord);
        IF (v_a.j->>'tipoAdaptacion') IS NULL THEN
            RAISE EXCEPTION 'Indique el tipo de adaptación en %', v_que USING ERRCODE = '22023';
        END IF;
        IF NULLIF(TRIM(v_a.j->>'descripcion'), '') IS NULL THEN
            RAISE EXCEPTION 'Describa qué se va a hacer en %', v_que USING ERRCODE = '22023';
        END IF;
        PERFORM academico_test.fn_actividad_validar_texto(v_a.j->>'descripcion', 'La descripción de ' || v_que, 500);
        PERFORM academico_test.fn_actividad_validar_catalogo((v_a.j->>'tipoAdaptacion')::BIGINT,    'TIPO_ADAPTACION',    'Tipo de adaptación');
        PERFORM academico_test.fn_actividad_validar_catalogo((v_a.j->>'formatoAdaptacion')::BIGINT, 'FORMATO_ADAPTACION', 'Versión modificada del instrumento');
        PERFORM academico_test.fn_actividad_validar_catalogo((v_a.j->>'aplicaA')::BIGINT,           'APLICA_A',           '¿A quién se aplica?');

        v_usa := UPPER(TRIM(COALESCE(v_a.j->>'usaVersionModificada', 'N')));
        IF v_usa NOT IN ('S', 'N') THEN
            RAISE EXCEPTION 'Indique si % usa una versión modificada del instrumento (Sí o No)', v_que
                USING ERRCODE = '22023';
        END IF;
        SELECT VALOR INTO v_formato FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = (v_a.j->>'formatoAdaptacion')::BIGINT;
        SELECT VALOR INTO v_aplica FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = (v_a.j->>'aplicaA')::BIGINT;

        IF v_usa = 'S' THEN
            IF v_formato IS NULL THEN
                RAISE EXCEPTION 'Indique cómo se entrega la versión modificada de % (archivo, enlace o biblioteca)', v_que
                    USING ERRCODE = '22023';
            END IF;
            IF v_formato IN ('ARCHIVO', 'BIBLIOTECA') AND (v_a.j->>'fkTarchivo') IS NULL THEN
                RAISE EXCEPTION 'Adjunte o elija de la biblioteca el archivo de %', v_que USING ERRCODE = '22023';
            END IF;
            IF v_formato = 'ENLACE' AND NULLIF(TRIM(v_a.j->>'url'), '') IS NULL THEN
                RAISE EXCEPTION 'Escriba el enlace de la versión modificada de %', v_que USING ERRCODE = '22023';
            END IF;
        ELSIF v_formato IS NOT NULL THEN
            RAISE EXCEPTION '% no usa versión modificada del instrumento: quite el archivo o enlace', v_que
                USING ERRCODE = '22023';
        END IF;
        PERFORM academico_test.fn_actividad_validar_url(v_a.j->>'url', v_que);
        PERFORM academico_test.fn_actividad_validar_archivo_existente((v_a.j->>'fkTarchivo')::BIGINT, v_que);

        IF v_aplica = 'ESTUDIANTES_SELECCIONADOS'
           AND (jsonb_typeof(v_a.j->'estudiantes') IS DISTINCT FROM 'array'
                OR jsonb_array_length(v_a.j->'estudiantes') = 0) THEN
            RAISE EXCEPTION 'Seleccione al menos un estudiante para % ("Estudiantes específicos")', v_que
                USING ERRCODE = '22023';
        END IF;
        IF v_aplica IS DISTINCT FROM 'ESTUDIANTES_SELECCIONADOS'
           AND jsonb_typeof(v_a.j->'estudiantes') = 'array'
           AND jsonb_array_length(v_a.j->'estudiantes') > 0 THEN
            RAISE EXCEPTION '% aplica a todo el grupo: no se le escogen estudiantes', v_que USING ERRCODE = '22023';
        END IF;
    END LOOP;
END;
$$;

-- Regla 47 / Bloque 6: los estudiantes de una adaptación salen de los de la
-- actividad, nunca del roster completo del grupo.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_adaptacion_estudiantes(
    p_pk_tactividad BIGINT,
    p_estudiantes   JSONB
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_ajena BIGINT;
BEGIN
    SELECT mid::BIGINT INTO v_ajena
      FROM jsonb_array_elements_text(COALESCE(p_estudiantes, '[]'::jsonb)) mid
     WHERE NOT EXISTS (SELECT 1 FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
                        WHERE ae.FK_TACTIVIDAD = p_pk_tactividad
                          AND ae.FK_TMATRICULA = mid::BIGINT AND ae.ACTIVE = TRUE)
     LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION '% no está entre los estudiantes de %: inclúyalo antes de asignarle la adaptación',
            COALESCE(academico_test.fn_actividad_estudiante_nombre(v_ajena), 'Uno de los estudiantes de la adaptación'),
            academico_test.fn_actividad_etiqueta(p_pk_tactividad)
            USING ERRCODE = '23503';
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Recuperación (Bloque 0, Reglas 63-67)
-- ---------------------------------------------------------------------------

-- Regla 64: solo se recupera una actividad normal, sumativa, activa, de la
-- misma asignatura y con al menos un resultado registrado. La comparten el
-- selector ("¿Qué desea recuperar?") y la escritura.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_recuperable(
    p_fk_tactividad_recuperar BIGINT,
    p_pk_tactividad_actual    BIGINT,
    p_fk_tasignatura          BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_o RECORD;
BEGIN
    SELECT TITULO, ACTIVE, FK_TASIGNATURA,
           COALESCE(ES_EVALUATIVA::VARCHAR, 'S') AS sumativa,
           COALESCE(ES_RECUPERACION::VARCHAR, 'N') AS recuperacion
      INTO v_o
      FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_fk_tactividad_recuperar;
    IF NOT FOUND OR NOT v_o.ACTIVE THEN
        RAISE EXCEPTION 'No se encontró la actividad que se quiere recuperar' USING ERRCODE = 'P0002';
    END IF;
    IF p_fk_tactividad_recuperar = p_pk_tactividad_actual THEN
        RAISE EXCEPTION '% no puede recuperarse a sí misma', academico_test.fn_actividad_etiqueta(p_fk_tactividad_recuperar) USING ERRCODE = '22023';
    END IF;
    IF v_o.sumativa = 'N' THEN
        RAISE EXCEPTION '% no es sumativa: no afecta la nota y no se puede recuperar', academico_test.fn_actividad_etiqueta(p_fk_tactividad_recuperar)
            USING ERRCODE = '22023';
    END IF;
    IF v_o.recuperacion = 'S' THEN
        RAISE EXCEPTION '% ya es una recuperación: no se puede recuperar una recuperación', academico_test.fn_actividad_etiqueta(p_fk_tactividad_recuperar)
            USING ERRCODE = '22023';
    END IF;
    IF p_fk_tasignatura IS NOT NULL AND v_o.FK_TASIGNATURA IS DISTINCT FROM p_fk_tasignatura THEN
        RAISE EXCEPTION '% es de "%": la recuperación debe ser de la misma asignatura',
            academico_test.fn_actividad_etiqueta(p_fk_tactividad_recuperar), (SELECT NOMBRE FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = v_o.FK_TASIGNATURA)
            USING ERRCODE = '22023';
    END IF;
    IF academico_test.fn_actividad_estudiantes_con_resultado(p_fk_tactividad_recuperar) = 0 THEN
        RAISE EXCEPTION '% aún no tiene resultados registrados: no hay nota que recuperar', academico_test.fn_actividad_etiqueta(p_fk_tactividad_recuperar)
            USING ERRCODE = '22023';
    END IF;
END;
$$;

-- Formato del objeto de recuperación {destino, tipoAplicacion, tipoCalculo?,
-- valorPonderacion?, fkActividadRecuperar?}.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_recuperacion_config(p_config JSONB)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_destino VARCHAR;
    v_aplic   VARCHAR;
    v_calculo VARCHAR;
    v_valor   TEXT := NULLIF(TRIM(p_config->>'valorPonderacion'), '');
BEGIN
    IF p_config IS NULL THEN
        RETURN;
    END IF;
    IF jsonb_typeof(p_config) <> 'object' THEN
        RAISE EXCEPTION 'La configuración de la recuperación no tiene el formato esperado' USING ERRCODE = '22023';
    END IF;
    IF (p_config->>'destino') IS NULL THEN
        RAISE EXCEPTION 'Indique qué desea recuperar: una actividad o la nota final' USING ERRCODE = '22023';
    END IF;
    IF (p_config->>'tipoAplicacion') IS NULL THEN
        RAISE EXCEPTION 'Indique cómo se aplicará la nota de la recuperación' USING ERRCODE = '22023';
    END IF;
    PERFORM academico_test.fn_actividad_validar_catalogo((p_config->>'destino')::BIGINT,        'DESTINO_RECUPERACION',         '¿Qué desea recuperar?');
    PERFORM academico_test.fn_actividad_validar_catalogo((p_config->>'tipoAplicacion')::BIGINT, 'TIPO_APLICACION_RECUPERACION', '¿Cómo se aplicará la nota?');
    PERFORM academico_test.fn_actividad_validar_catalogo(NULLIF(p_config->>'tipoCalculo', '')::BIGINT, 'TIPO_CALCULO_RECUPERACION', 'Tipo de cálculo de la recuperación');

    SELECT VALOR INTO v_destino FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = (p_config->>'destino')::BIGINT;
    SELECT VALOR INTO v_aplic   FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = (p_config->>'tipoAplicacion')::BIGINT;
    SELECT VALOR INTO v_calculo FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = NULLIF(p_config->>'tipoCalculo', '')::BIGINT;

    -- Antes del rango: un valor enorme rompería el cast a NUMERIC(5,2) con 22003.
    IF v_valor IS NOT NULL AND (v_valor !~ '^\d{1,3}(\.\d+)?$' OR v_valor::NUMERIC > 100) THEN
        RAISE EXCEPTION 'El porcentaje de la recuperación debe estar entre 0 y 100; llegó %', v_valor
            USING ERRCODE = '22023';
    END IF;
    IF v_aplic = 'REEMPLAZAR' THEN
        IF v_valor IS NOT NULL THEN
            RAISE EXCEPTION 'Con "Usar nota de recuperación" la nota nueva reemplaza a la anterior: no lleva porcentaje'
                USING ERRCODE = '22023';
        END IF;
    ELSE
        IF v_calculo IS NULL THEN
            RAISE EXCEPTION 'Indique si la nota de la recuperación se promedia o se pondera con la original'
                USING ERRCODE = '22023';
        END IF;
        IF v_calculo = 'PONDERADO' AND v_valor IS NULL THEN
            RAISE EXCEPTION 'Indique el porcentaje (0 a 100) con que pondera la nota de la recuperación'
                USING ERRCODE = '22023';
        END IF;
        IF v_calculo IS DISTINCT FROM 'PONDERADO' AND v_valor IS NOT NULL THEN
            RAISE EXCEPTION 'El porcentaje solo aplica cuando la recuperación se pondera con la nota original'
                USING ERRCODE = '22023';
        END IF;
    END IF;
    IF v_destino = 'ACTIVIDAD' AND (p_config->>'fkActividadRecuperar') IS NULL THEN
        RAISE EXCEPTION 'Seleccione la actividad que se va a recuperar' USING ERRCODE = '22023';
    END IF;
    IF v_destino IS DISTINCT FROM 'ACTIVIDAD' AND (p_config->>'fkActividadRecuperar') IS NOT NULL THEN
        RAISE EXCEPTION 'Una recuperación de la nota final no se amarra a una actividad' USING ERRCODE = '22023';
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Estado de la actividad: resultados, edición (Regla 37), borrado (Regla 38)
-- ---------------------------------------------------------------------------

-- Cuenta como resultado lo mismo que cuenta como "evaluado": nota, observación
-- o cualquier captura de instrumento. Única definición: la usan edición,
-- borrado y la recuperación (Regla 64).
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_estudiantes_con_resultado(p_pk_tactividad BIGINT)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT COUNT(DISTINCT ae.PK_TACTIVIDAD_ESTUDIANTE)
      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
     WHERE ae.FK_TACTIVIDAD = p_pk_tactividad
       AND ae.ACTIVE = TRUE
       AND (EXISTS (SELECT 1 FROM academico_test.TACTIVIDAD_NOTA n
                     WHERE n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                       AND n.ACTIVE = TRUE
                       AND (COALESCE(n.DEFINITIVA, n.CALIFICACION) IS NOT NULL
                            OR NULLIF(TRIM(n.OBSERVACION), '') IS NOT NULL))
         OR EXISTS (SELECT 1 FROM academico_test.TACTIVIDAD_RUBRICA_EVALUACION re
                     WHERE re.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE AND re.ACTIVE = TRUE)
         OR EXISTS (SELECT 1 FROM academico_test.TACTIVIDAD_COTEJO_EVALUACION ce
                     WHERE ce.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE AND ce.ACTIVE = TRUE)
         OR EXISTS (SELECT 1 FROM academico_test.TACTIVIDAD_ESCALA_EVALUACION ee
                     WHERE ee.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE AND ee.ACTIVE = TRUE));
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_sin_notas(p_pk_tactividad BIGINT)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_estudiantes BIGINT := academico_test.fn_actividad_estudiantes_con_resultado(p_pk_tactividad);
BEGIN
    IF v_estudiantes > 0 THEN
        RAISE EXCEPTION '% ya tiene resultados registrados para % estudiante(s); no se puede eliminar',
            academico_test.fn_actividad_etiqueta(p_pk_tactividad), v_estudiantes
            USING ERRCODE = '23503',
                  HINT = 'Por normativa de conservación de datos, una actividad con resultados no se elimina';
    END IF;
END;
$$;

-- Regla 37: con un resultado capturado, o siendo origen de un refuerzo, la
-- actividad queda bloqueada para edición; para cambiarla se crea otra.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_editable(p_pk_tactividad BIGINT)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_estudiantes BIGINT := academico_test.fn_actividad_estudiantes_con_resultado(p_pk_tactividad);
    v_refuerzo    VARCHAR;
BEGIN
    IF v_estudiantes > 0 THEN
        RAISE EXCEPTION '% ya tiene resultados registrados para % estudiante(s) y no se puede modificar',
            academico_test.fn_actividad_etiqueta(p_pk_tactividad), v_estudiantes
            USING ERRCODE = '23503',
                  HINT = 'Para cambiarla, cree una actividad nueva';
    END IF;
    SELECT a.TITULO INTO v_refuerzo
      FROM academico_test.TACTIVIDAD_RECUPERACION r
      JOIN academico_test.TACTIVIDAD a ON a.PK_TACTIVIDAD = r.FK_TACTIVIDAD AND a.ACTIVE = TRUE
     WHERE r.FK_TACTIVIDAD_RECUPERAR = p_pk_tactividad AND r.ACTIVE = TRUE
     LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION '% es la actividad original de la recuperación "%" y no se puede modificar',
            academico_test.fn_actividad_etiqueta(p_pk_tactividad), v_refuerzo
            USING ERRCODE = '23503',
                  HINT = 'Para cambiarla, cree una actividad nueva';
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Validaciones centrales
-- ---------------------------------------------------------------------------

-- Formato de lo que llega en el formulario, antes de mirar el contexto. En el
-- alta los obligatorios se exigen; en el PATCH solo se valida lo que viene.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_campos(
    p_es_alta                       BOOLEAN,
    p_titulo                        VARCHAR,
    p_fk_tasignatura                BIGINT,
    p_fk_tlv_tipo_actividad         BIGINT,
    p_fk_tlv_jerarquia              BIGINT,
    p_descripcion                   VARCHAR,
    p_material_requerido            VARCHAR,
    p_descripcion_instrumento       VARCHAR,
    p_fk_tlv_modalidad              BIGINT,
    p_fk_tlv_instrumento_evaluacion BIGINT,
    p_fk_tlv_tipo_evidencia         BIGINT,
    p_fk_tlv_metodo_valoracion      BIGINT,
    p_fk_tlv_tipo_calculo           BIGINT,
    p_nota_maxima                   NUMERIC,
    p_materiales                    JSONB,
    p_adaptaciones                  JSONB,
    p_recuperacion                  JSONB
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_actividad_validar_titulo(p_titulo, p_es_alta);
    IF p_es_alta THEN
        PERFORM academico_test.fn_actividad_validar_requerido(p_fk_tasignatura,        'Seleccione la asignatura de la actividad');
        PERFORM academico_test.fn_actividad_validar_requerido(p_fk_tlv_tipo_actividad, 'Seleccione el tipo de actividad');
        PERFORM academico_test.fn_actividad_validar_requerido(p_fk_tlv_jerarquia,      'Seleccione la jerarquía de la actividad');
    END IF;
    PERFORM academico_test.fn_actividad_validar_texto(p_descripcion,             'La descripción de la actividad', 500);
    PERFORM academico_test.fn_actividad_validar_texto(p_material_requerido,      'Los materiales requeridos', 500);
    PERFORM academico_test.fn_actividad_validar_texto(p_descripcion_instrumento, 'La descripción del instrumento', 200);
    PERFORM academico_test.fn_actividad_validar_catalogo(p_fk_tlv_tipo_actividad,         'TIPO_ACTIVIDAD',           'Tipo de actividad');
    PERFORM academico_test.fn_actividad_validar_catalogo(p_fk_tlv_jerarquia,              'TIPO_JERARQUIA_ACTIVIDAD', 'Jerarquía');
    PERFORM academico_test.fn_actividad_validar_catalogo(p_fk_tlv_modalidad,              'MODALIDAD',                'Modalidad');
    PERFORM academico_test.fn_actividad_validar_catalogo(p_fk_tlv_instrumento_evaluacion, 'INSTRUMENTO_EVALUACION',   'Instrumento de evaluación');
    PERFORM academico_test.fn_actividad_validar_catalogo(p_fk_tlv_tipo_evidencia,         'TIPO_EVIDENCIA',           'Tipo de evidencia esperada');
    PERFORM academico_test.fn_actividad_validar_catalogo(p_fk_tlv_metodo_valoracion,      'METODO_VALORACION',        'Método de valoración');
    PERFORM academico_test.fn_actividad_validar_catalogo(p_fk_tlv_tipo_calculo,           'TIPO_CALCULO',             'Tipo de cálculo');
    PERFORM academico_test.fn_actividad_validar_nota_maxima(p_nota_maxima);
    PERFORM academico_test.fn_actividad_validar_materiales(p_materiales);
    PERFORM academico_test.fn_actividad_validar_adaptaciones(p_adaptaciones);
    PERFORM academico_test.fn_actividad_validar_recuperacion_config(p_recuperacion);
END;
$$;

-- El estado que va a quedar, en el orden en que responde al cliente. Alta y
-- PATCH le pasan los valores RESULTANTES. p_exigir_minimos apaga los mínimos
-- del formulario (peso requerido, evidencias) para la importación masiva.
DROP FUNCTION IF EXISTS academico_test.fn_actividad_validar_coherencia(
    VARCHAR, BIGINT, BIGINT, BIGINT, NUMERIC, academico_test.bool_sn, BOOLEAN, BOOLEAN, DATE, DATE, NUMERIC, VARCHAR);

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_coherencia(
    p_titulo            VARCHAR,
    p_fk_tasignatura    BIGINT,
    p_fk_tgrupo         BIGINT,
    p_fk_tunidad        BIGINT,
    p_ponderacion       NUMERIC,
    p_nota_maxima       NUMERIC,
    p_es_evaluativa     academico_test.bool_sn,
    p_ctx_evaluativo    BOOLEAN,
    p_es_recuperacion   BOOLEAN,
    p_fk_tlv_instrumento BIGINT,
    p_fecha_inicio      DATE,
    p_fecha_cierre      DATE,
    p_duracion_estimada NUMERIC,
    p_semana_cronograma VARCHAR,
    p_evidencias        BIGINT[],
    p_validar_evidencias BOOLEAN,
    p_exigir_minimos    BOOLEAN
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_actividad_validar_asignatura(p_fk_tasignatura);
    PERFORM academico_test.fn_actividad_validar_grupo(p_fk_tgrupo);
    PERFORM academico_test.fn_actividad_validar_unidad(p_fk_tunidad);
    PERFORM academico_test.fn_actividad_validar_unidad_compatible(p_fk_tasignatura, p_fk_tgrupo, p_fk_tunidad, p_titulo);
    PERFORM academico_test.fn_actividad_validar_fechas_orden(p_fecha_inicio, p_fecha_cierre);
    PERFORM academico_test.fn_actividad_programacion_assert(
        p_fk_tgrupo, p_fk_tasignatura, p_fecha_inicio, p_fecha_cierre, p_duracion_estimada, p_semana_cronograma);
    PERFORM academico_test.fn_actividad_validar_periodo_evaluacion_unico(
        p_fk_tgrupo, p_fk_tunidad, p_fecha_inicio, p_fecha_cierre);
    PERFORM academico_test.fn_actividad_validar_evaluativa_contexto(
        p_es_evaluativa, p_ctx_evaluativo, p_fk_tunidad, p_titulo);
    PERFORM academico_test.fn_actividad_instrumento_contexto_assert(
        p_fk_tlv_instrumento, p_fk_tgrupo, p_fk_tasignatura, p_fk_tunidad, p_titulo);
    PERFORM academico_test.fn_actividad_validar_recuperacion_sumativa(p_es_recuperacion, p_es_evaluativa, p_titulo);
    PERFORM academico_test.fn_actividad_validar_ponderacion(p_ponderacion, p_fk_tunidad, p_es_evaluativa, p_titulo);
    IF p_exigir_minimos THEN
        PERFORM academico_test.fn_actividad_validar_peso_requerido(
            p_fk_tunidad, p_es_evaluativa, p_ponderacion, p_nota_maxima, p_titulo);
    END IF;
    IF p_validar_evidencias THEN
        PERFORM academico_test.fn_actividad_validar_evidencia(p_fk_tunidad, p_titulo, ev)
           FROM unnest(p_evidencias) ev WHERE ev IS NOT NULL;
        IF p_exigir_minimos THEN
            PERFORM academico_test.fn_actividad_validar_evidencias_minimo(p_fk_tunidad, p_titulo, p_evidencias);
        END IF;
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Permisos sobre la fila (los usa el wrapper, no el núcleo)
-- ---------------------------------------------------------------------------

-- Reglas 25 y 54: un docente de aula gestiona solo las actividades que creó;
-- coordinación, rectoría y el super admin, todas las de su alcance.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_assert_propietario(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_autor  VARCHAR;
    v_titulo VARCHAR;
BEGIN
    IF NOT academico_test.fn_usuario_es_docente_puro(p_pk_usuario_solicitante) THEN
        RETURN;
    END IF;
    SELECT CREATED_BY, TITULO INTO v_autor, v_titulo
      FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_pk_tactividad;
    IF v_autor IS DISTINCT FROM p_pk_usuario_solicitante::VARCHAR THEN
        RAISE EXCEPTION '% la creó %: solo su autor puede modificarla o eliminarla',
            academico_test.fn_actividad_etiqueta(p_pk_tactividad),
            COALESCE(academico_test.fn_resolver_actor(NULLIF(regexp_replace(v_autor, '\D', '', 'g'), '')::BIGINT), 'otro docente')
            USING ERRCODE = '42501';
    END IF;
END;
$$;

-- Bloque 1: un docente de aula solo planea sobre su carga académica
-- (TDOCENTE_ASIGNATURA), la misma regla con que el listado le filtra lo que ve.
-- Sin grupo basta con que dicte la asignatura, en el grado de la unidad si la hay.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_assert_carga_docente(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tgrupo              BIGINT,
    p_fk_tasignatura         BIGINT,
    p_fk_tunidad             BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_funcionario BIGINT;
    v_grado       BIGINT;
BEGIN
    -- Referencias inexistentes las rechaza fn_actividad_validar_coherencia con nombre.
    IF p_fk_tasignatura IS NULL
       OR NOT EXISTS (SELECT 1 FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_fk_tasignatura)
       OR (p_fk_tgrupo IS NOT NULL AND NOT EXISTS (SELECT 1 FROM academico_test.TGRUPO WHERE PK_TGRUPO = p_fk_tgrupo))
       OR NOT academico_test.fn_usuario_es_docente_puro(p_pk_usuario_solicitante) THEN
        RETURN;
    END IF;
    v_funcionario := academico_test.fn_funcionario_actual(p_pk_usuario_solicitante);
    IF p_fk_tgrupo IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM academico_test.TDOCENTE_ASIGNATURA
                        WHERE FK_TFUNCIONARIO = v_funcionario AND FK_TGRUPO = p_fk_tgrupo
                          AND FK_TASIGNATURA = p_fk_tasignatura AND ACTIVE = TRUE) THEN
            RAISE EXCEPTION 'No tiene asignada "%" en %: solo puede planear actividades de su carga académica',
                (SELECT NOMBRE FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_fk_tasignatura),
                academico_test.fn_actividad_grupo_etiqueta(p_fk_tgrupo)
                USING ERRCODE = '42501';
        END IF;
        RETURN;
    END IF;
    v_grado := (SELECT FK_TGRADO FROM academico_test.TUNIDAD WHERE PK_TUNIDAD = p_fk_tunidad);
    IF NOT EXISTS (SELECT 1 FROM academico_test.TDOCENTE_ASIGNATURA da
                     JOIN academico_test.TGRUPO g ON g.PK_TGRUPO = da.FK_TGRUPO
                    WHERE da.FK_TFUNCIONARIO = v_funcionario AND da.FK_TASIGNATURA = p_fk_tasignatura
                      AND da.ACTIVE = TRUE AND (v_grado IS NULL OR g.FK_TGRADO = v_grado)) THEN
        RAISE EXCEPTION 'No dicta "%"%: solo puede planear actividades de su carga académica',
            (SELECT NOMBRE FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_fk_tasignatura),
            COALESCE(' en ' || (SELECT NOMBRE FROM academico_test.TGRADO WHERE PK_TGRADO = v_grado), '')
            USING ERRCODE = '42501';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_validar_coherencia(VARCHAR, BIGINT, BIGINT, BIGINT, NUMERIC, NUMERIC, academico_test.bool_sn, BOOLEAN, BOOLEAN, BIGINT, DATE, DATE, NUMERIC, VARCHAR, BIGINT[], BOOLEAN, BOOLEAN)
    IS 'INTERNO: reglas de coherencia de una actividad sobre sus valores RESULTANTES (referencias activas, unidad compatible, programación, un solo periodo de evaluación, enfoque del referente, instrumento, recuperación sumativa, peso y evidencias de la unidad). La comparten fn_actividad_crear_interno y fn_actividad_actualizar_interno; una regla nueva se agrega aquí y aplica a las dos.';
COMMENT ON FUNCTION academico_test.fn_actividad_assert_propietario(BIGINT, BIGINT)
    IS 'Reglas 25/54: 42501 si un docente de aula intenta modificar o eliminar una actividad que no creó. Coordinación, rectoría y super admin pasan. Lo usan los wrappers de escritura de actividad.';
COMMENT ON FUNCTION academico_test.fn_actividad_validar_editable(BIGINT)
    IS 'Regla 37: 23503 si la actividad ya tiene resultados capturados o es la original de una recuperación activa. La usan los _interno que cambian la definición de la actividad.';
COMMENT ON FUNCTION academico_test.fn_actividad_lv_assert(BIGINT, VARCHAR, VARCHAR)
    IS 'Valida una FK a TLISTA_VALOR: NULL pasa, si viene debe existir, estar activa y ser de p_categoria (si la categoría está sembrada). Mensaje con el nombre del campo, nunca la pk; delega en fn_actividad_validar_catalogo. La usan las definiciones de instrumento, recuperación y calificación.';
COMMENT ON FUNCTION academico_test.fn_actividad_validar_periodo_evaluacion_unico(BIGINT, BIGINT, DATE, DATE)
    IS 'INTERNO: 22023 si [fecha_inicio, fecha_cierre] solapa más de un periodo de evaluación activo del periodo académico del grado de la actividad: la nota se imputa a un solo periodo. Sin fechas o sin ancla no aplica. La usa fn_actividad_validar_coherencia.';
COMMENT ON FUNCTION academico_test.fn_actividad_validar_sin_notas(BIGINT)
    IS 'INTERNO: 23503 si algún estudiante activo de la actividad tiene resultado (nota, observación o captura de instrumento; fn_actividad_estudiantes_con_resultado). Lo usa fn_actividad_validar_eliminable.';
COMMENT ON FUNCTION academico_test.fn_actividad_assert_carga_docente(BIGINT, BIGINT, BIGINT, BIGINT)
    IS 'Bloque 1: 42501 si un docente de aula planea sobre un (grupo, asignatura) que no tiene en TDOCENTE_ASIGNATURA; sin grupo, si no dicta la asignatura (en el grado de la unidad). Coordinación, rectoría y super admin pasan. La usan los wrappers de crear y actualizar actividad.';
COMMENT ON FUNCTION academico_test.fn_actividad_rotulo(BIGINT, BIGINT, BIGINT)
    IS 'Regla 13: Rótulo de Ejecución del referente que gobierna la actividad (el de su unidad o, sin ella, fn_unidad_referente_aplicable del grado del grupo y la asignatura); "Actividad" si no hay. Lo usan los mensajes y la bitácora.';
