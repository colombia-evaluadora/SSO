-- V496.6 - Instrumentos y calificación de actividades: núcleos _interno sin
-- permisos. Definen rúbrica, lista de cotejo, escala y Otro (Regla 41: la
-- casilla de entrega que dicta el tipo de evidencia queda siempre marcada),
-- califican individual y en bloque, y leen la nota y el listado de
-- calificaciones. La rúbrica suma puntajes sobre la suma de máximos (Regla 42).
-- Reemplaza a las funciones con el permiso dentro de V226, V227, V469 y V472.
-- Depende de: V496.5 (validaciones), V227 (get_or_create, ajuste por
-- criterio), V226 (reset), V408 (recuperación), V477 (resultado del
-- instrumento), V428 (homologación), V450 (fecha de asistencia).

SET search_path TO academico_test, public;

DROP FUNCTION IF EXISTS academico_test.fn_actividad_rubrica_definir(BIGINT, BIGINT, JSONB);
DROP FUNCTION IF EXISTS academico_test.fn_actividad_cotejo_definir(BIGINT, BIGINT, JSONB);
DROP FUNCTION IF EXISTS academico_test.fn_actividad_escala_definir(BIGINT, BIGINT, JSONB);
DROP FUNCTION IF EXISTS academico_test.fn_actividad_otro_definir(BIGINT, BIGINT, JSONB);
DROP FUNCTION IF EXISTS academico_test.fn_actividad_nota_calificar_rubrica(BIGINT, BIGINT, JSONB, DATE);
DROP FUNCTION IF EXISTS academico_test.fn_actividad_nota_calificar_cotejo(BIGINT, BIGINT, BIGINT[], DATE);
DROP FUNCTION IF EXISTS academico_test.fn_actividad_nota_calificar_escala(BIGINT, BIGINT, BIGINT, NUMERIC, DATE);
DROP FUNCTION IF EXISTS academico_test.fn_actividad_nota_calificar_escala_criterios(BIGINT, BIGINT, JSONB, DATE);
DROP FUNCTION IF EXISTS academico_test.fn_actividad_nota_calificar_otro(BIGINT, BIGINT, NUMERIC, DATE);

-- ---------------------------------------------------------------------------
-- Definición del instrumento
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_rubrica_definir_interno(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT,
    p_criterios              JSONB
)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_c   RECORD;
    v_pk  BIGINT;
    v_por VARCHAR := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    PERFORM academico_test.fn_actividad_instrumento_reset(p_pk_usuario_solicitante, p_pk_tactividad, NULL);
    FOR v_c IN SELECT e AS j, ord FROM jsonb_array_elements(p_criterios) WITH ORDINALITY AS t(e, ord) LOOP
        INSERT INTO academico_test.TACTIVIDAD_RUBRICA_CRITERIO (FK_TACTIVIDAD, ORDEN, NOMBRE, DESCRIPCION, CREATED_BY, CREATED_AT, ACTIVE)
        VALUES (p_pk_tactividad, v_c.ord, TRIM(v_c.j->>'nombre'), NULLIF(TRIM(v_c.j->>'descripcion'), ''), v_por, CURRENT_TIMESTAMP, TRUE)
        RETURNING PK_TACTIVIDAD_RUBRICA_CRITERIO INTO v_pk;
        INSERT INTO academico_test.TACTIVIDAD_RUBRICA_NIVEL (
            FK_TACTIVIDAD_RUBRICA_CRITERIO, ETIQUETA, DESCRIPCION, PONDERACION, CREATED_BY, CREATED_AT, ACTIVE)
        SELECT v_pk, NULLIF(TRIM(n->>'etiqueta'), ''), TRIM(n->>'descripcion'), (n->>'ponderacion')::NUMERIC,
               v_por, CURRENT_TIMESTAMP, TRUE
          FROM jsonb_array_elements(v_c.j->'niveles') n;
    END LOOP;
    RETURN jsonb_array_length(p_criterios);
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_cotejo_definir_interno(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT,
    p_items                  JSONB
)
RETURNS INT
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_actividad_instrumento_reset(p_pk_usuario_solicitante, p_pk_tactividad, NULL);
    INSERT INTO academico_test.TACTIVIDAD_COTEJO_ITEM (FK_TACTIVIDAD, ORDEN, DESCRIPCION, PONDERACION, CREATED_BY, CREATED_AT, ACTIVE)
    SELECT p_pk_tactividad, t.ord, TRIM(t.e->>'descripcion'), NULLIF(t.e->>'ponderacion', '')::NUMERIC,
           p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
      FROM jsonb_array_elements(p_items) WITH ORDINALITY AS t(e, ord);
    RETURN jsonb_array_length(p_items);
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_escala_definir_interno(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT,
    p_config                 JSONB
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_por  VARCHAR := p_pk_usuario_solicitante::VARCHAR;
    v_tipo VARCHAR;
    v_pk   BIGINT;
BEGIN
    SELECT VALOR INTO v_tipo FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = (p_config->>'tipoEscala')::BIGINT;
    PERFORM academico_test.fn_actividad_instrumento_reset(p_pk_usuario_solicitante, p_pk_tactividad, 'ESCALA_VALORACION');

    -- UN_TAC_ESCALA_1 es UNIQUE(FK_TACTIVIDAD) sin filtro por ACTIVE: se reusa la fila.
    SELECT PK_TACTIVIDAD_ESCALA INTO v_pk FROM academico_test.TACTIVIDAD_ESCALA WHERE FK_TACTIVIDAD = p_pk_tactividad;
    IF v_pk IS NULL THEN
        INSERT INTO academico_test.TACTIVIDAD_ESCALA (
            FK_TACTIVIDAD, CRITERIOS_GENERALES, FK_TLV_TIPO_ESCALA, VALOR_MIN, VALOR_MAX, INTERPRETACION_RANGOS,
            CREATED_BY, CREATED_AT, ACTIVE)
        VALUES (p_pk_tactividad, NULLIF(TRIM(p_config->>'criteriosGenerales'), ''), (p_config->>'tipoEscala')::BIGINT,
                NULLIF(p_config->>'valorMin', '')::NUMERIC, NULLIF(p_config->>'valorMax', '')::NUMERIC,
                NULLIF(TRIM(p_config->>'interpretacionRangos'), ''), v_por, CURRENT_TIMESTAMP, TRUE)
        RETURNING PK_TACTIVIDAD_ESCALA INTO v_pk;
    ELSE
        UPDATE academico_test.TACTIVIDAD_ESCALA
           SET CRITERIOS_GENERALES   = NULLIF(TRIM(p_config->>'criteriosGenerales'), ''),
               FK_TLV_TIPO_ESCALA    = (p_config->>'tipoEscala')::BIGINT,
               VALOR_MIN             = NULLIF(p_config->>'valorMin', '')::NUMERIC,
               VALOR_MAX             = NULLIF(p_config->>'valorMax', '')::NUMERIC,
               INTERPRETACION_RANGOS = NULLIF(TRIM(p_config->>'interpretacionRangos'), ''),
               ACTIVE = TRUE, MODIFIED_BY = v_por, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TACTIVIDAD_ESCALA = v_pk;
        UPDATE academico_test.TACTIVIDAD_ESCALA_NIVEL
           SET ACTIVE = FALSE, MODIFIED_BY = v_por, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TACTIVIDAD_ESCALA = v_pk AND ACTIVE = TRUE;
    END IF;

    IF v_tipo = 'CUALITATIVA' THEN
        INSERT INTO academico_test.TACTIVIDAD_ESCALA_NIVEL (
            FK_TACTIVIDAD_ESCALA, ORDEN, ETIQUETA, DESCRIPCION, PONDERACION, CREATED_BY, CREATED_AT, ACTIVE)
        SELECT v_pk, t.ord, NULLIF(TRIM(t.e->>'etiqueta'), ''), TRIM(t.e->>'descripcion'), (t.e->>'ponderacion')::NUMERIC,
               v_por, CURRENT_TIMESTAMP, TRUE
          FROM jsonb_array_elements(p_config->'niveles') WITH ORDINALITY AS t(e, ord);
    END IF;
    RETURN v_pk;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_otro_definir_interno(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT,
    p_config                 JSONB
)
RETURNS VARCHAR
LANGUAGE plpgsql
AS $$
DECLARE
    v_por       VARCHAR := p_pk_usuario_solicitante::VARCHAR;
    v_evidencia VARCHAR;
    v_metodo    VARCHAR;
    v_archivo   academico_test.bool_sn := academico_test.fn_actividad_otro_sn(p_config->'requiereArchivo');
    v_texto     academico_test.bool_sn := academico_test.fn_actividad_otro_sn(p_config->'requiereTexto');
BEGIN
    SELECT VALOR INTO v_evidencia FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = (p_config->>'tipoEvidencia')::BIGINT;
    SELECT VALOR INTO v_metodo    FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = (p_config->>'metodoValoracion')::BIGINT;

    -- Antes de definir el método: fn_actividad_instrumento_efectivo lo lee de aquí.
    UPDATE academico_test.TACTIVIDAD_OTRO
       SET FK_TLV_TIPO_EVIDENCIA_OTRO = (p_config->>'tipoEvidencia')::BIGINT,
           FK_TLV_METODO_VALORACION   = (p_config->>'metodoValoracion')::BIGINT,
           ACTIVE = TRUE, MODIFIED_BY = v_por, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TACTIVIDAD = p_pk_tactividad;
    IF NOT FOUND THEN
        INSERT INTO academico_test.TACTIVIDAD_OTRO (
            FK_TACTIVIDAD, FK_TLV_TIPO_EVIDENCIA_OTRO, FK_TLV_METODO_VALORACION, CREATED_BY, CREATED_AT, ACTIVE)
        VALUES (p_pk_tactividad, (p_config->>'tipoEvidencia')::BIGINT, (p_config->>'metodoValoracion')::BIGINT,
                v_por, CURRENT_TIMESTAMP, TRUE);
    END IF;

    CASE v_metodo
        WHEN 'RUBRICA'      THEN PERFORM academico_test.fn_actividad_rubrica_definir_interno(p_pk_usuario_solicitante, p_pk_tactividad, p_config->'definicion');
        WHEN 'LISTA_COTEJO' THEN PERFORM academico_test.fn_actividad_cotejo_definir_interno(p_pk_usuario_solicitante, p_pk_tactividad, p_config->'definicion');
        ELSE PERFORM academico_test.fn_actividad_escala_definir_interno(p_pk_usuario_solicitante, p_pk_tactividad, p_config->'definicion');
    END CASE;

    -- Regla 41: Archivo exige adjuntar archivo; Enlace, Observación directa y
    -- Registro en campo exigen respuesta en texto. La otra casilla es opcional.
    UPDATE academico_test.TACTIVIDAD
       SET REQUIERE_ARCHIVO = CASE WHEN v_evidencia = 'ARCHIVO' THEN 'S' ELSE COALESCE(v_archivo, REQUIERE_ARCHIVO, 'N') END,
           REQUIERE_TEXTO   = CASE WHEN v_evidencia = 'ARCHIVO' THEN COALESCE(v_texto, REQUIERE_TEXTO, 'N') ELSE 'S' END,
           MODIFIED_BY = v_por, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TACTIVIDAD = p_pk_tactividad;
    RETURN v_metodo;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_instrumento_definir_interno(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT,
    p_definicion             JSONB
)
RETURNS VARCHAR
LANGUAGE plpgsql
AS $$
DECLARE
    v_valor VARCHAR;
BEGIN
    PERFORM academico_test.fn_actividad_validar_instrumento_definicion(p_pk_tactividad, p_definicion);
    SELECT lv.VALOR INTO v_valor
      FROM academico_test.TACTIVIDAD a
      JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = a.FK_TLV_INSTRUMENTO_EVALUACION
     WHERE a.PK_TACTIVIDAD = p_pk_tactividad;
    CASE v_valor
        WHEN 'RUBRICA'      THEN PERFORM academico_test.fn_actividad_rubrica_definir_interno(p_pk_usuario_solicitante, p_pk_tactividad, p_definicion);
        WHEN 'LISTA_COTEJO' THEN PERFORM academico_test.fn_actividad_cotejo_definir_interno(p_pk_usuario_solicitante, p_pk_tactividad, p_definicion);
        WHEN 'ESCALA_VALORACION' THEN PERFORM academico_test.fn_actividad_escala_definir_interno(p_pk_usuario_solicitante, p_pk_tactividad, p_definicion);
        ELSE PERFORM academico_test.fn_actividad_otro_definir_interno(p_pk_usuario_solicitante, p_pk_tactividad, p_definicion);
    END CASE;
    RETURN v_valor;
END;
$$;

-- ---------------------------------------------------------------------------
-- Cálculo de la nota (porcentaje 0-100) a partir de lo capturado
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_rubrica_recalcular(p_pk_tactividad_estudiante BIGINT)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_pk        BIGINT := academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante);
    v_total     INT;
    v_cubiertos INT;
    v_obtenido  NUMERIC;
    v_maximo    NUMERIC;
BEGIN
    SELECT COUNT(*) INTO v_total FROM academico_test.TACTIVIDAD_RUBRICA_CRITERIO
     WHERE FK_TACTIVIDAD = v_pk AND ACTIVE = TRUE;
    IF v_total = 0 THEN
        RETURN NULL;
    END IF;
    -- Regla 42: suma de los puntajes obtenidos sobre la suma de los máximos de
    -- cada criterio; el máximo de un criterio es su nivel más alto.
    SELECT COUNT(*), SUM(re.PONDERACION), SUM(mx.maximo)
      INTO v_cubiertos, v_obtenido, v_maximo
      FROM academico_test.TACTIVIDAD_RUBRICA_EVALUACION re
      JOIN academico_test.TACTIVIDAD_RUBRICA_CRITERIO c
        ON c.PK_TACTIVIDAD_RUBRICA_CRITERIO = re.FK_TACTIVIDAD_RUBRICA_CRITERIO
       AND c.FK_TACTIVIDAD = v_pk AND c.ACTIVE = TRUE
      JOIN LATERAL (SELECT MAX(n.PONDERACION) AS maximo FROM academico_test.TACTIVIDAD_RUBRICA_NIVEL n
                     WHERE n.FK_TACTIVIDAD_RUBRICA_CRITERIO = c.PK_TACTIVIDAD_RUBRICA_CRITERIO AND n.ACTIVE = TRUE) mx ON TRUE
     WHERE re.FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante AND re.ACTIVE = TRUE;
    IF v_cubiertos < v_total OR COALESCE(v_maximo, 0) = 0 THEN
        RETURN NULL;
    END IF;
    RETURN academico_test.fn_actividad_nota_ajustar_por_criterio(v_pk, ROUND(v_obtenido / v_maximo * 100, 2));
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_cotejo_recalcular(p_pk_tactividad_estudiante BIGINT)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_pk       BIGINT := academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante);
    v_total    NUMERIC;
    v_cumplido NUMERIC;
BEGIN
    -- Un elemento sin puntaje pesa 1; uno sin captura cuenta como no cumplido.
    SELECT SUM(COALESCE(i.PONDERACION, 1)),
           SUM(CASE WHEN ce.CUMPLIDO = 'S' THEN COALESCE(i.PONDERACION, 1) ELSE 0 END)
      INTO v_total, v_cumplido
      FROM academico_test.TACTIVIDAD_COTEJO_ITEM i
      LEFT JOIN academico_test.TACTIVIDAD_COTEJO_EVALUACION ce
             ON ce.FK_TACTIVIDAD_COTEJO_ITEM = i.PK_TACTIVIDAD_COTEJO_ITEM
            AND ce.FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante AND ce.ACTIVE = TRUE
     WHERE i.FK_TACTIVIDAD = v_pk AND i.ACTIVE = TRUE;
    IF COALESCE(v_total, 0) = 0 THEN
        RETURN NULL;
    END IF;
    RETURN academico_test.fn_actividad_nota_ajustar_por_criterio(v_pk, ROUND(COALESCE(v_cumplido, 0) / v_total * 100, 2));
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_escala_porcentaje(
    p_pk_tactividad BIGINT,
    p_pk_nivel      BIGINT,
    p_valor         NUMERIC
)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    -- Cualitativa: puntaje del nivel sobre el mayor puntaje; numérica: valor sobre el máximo.
    SELECT ROUND(CASE WHEN p_pk_nivel IS NOT NULL
                      THEN (SELECT n.PONDERACION FROM academico_test.TACTIVIDAD_ESCALA_NIVEL n WHERE n.PK_TACTIVIDAD_ESCALA_NIVEL = p_pk_nivel)
                           / NULLIF((SELECT MAX(n.PONDERACION) FROM academico_test.TACTIVIDAD_ESCALA_NIVEL n
                                      WHERE n.FK_TACTIVIDAD_ESCALA = e.PK_TACTIVIDAD_ESCALA AND n.ACTIVE = TRUE), 0)
                      ELSE p_valor / NULLIF(e.VALOR_MAX, 0) END * 100, 2)
      FROM academico_test.TACTIVIDAD_ESCALA e
     WHERE e.FK_TACTIVIDAD = p_pk_tactividad AND e.ACTIVE = TRUE;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_guardar_interno(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad_estudiante BIGINT,
    p_porcentaje               NUMERIC
)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk_nota BIGINT := academico_test.fn_actividad_nota_get_or_create(p_pk_usuario_solicitante, p_pk_tactividad_estudiante);
BEGIN
    -- NULL = captura aún incompleta: se guarda lo marcado pero no se toca la nota.
    IF p_porcentaje IS NOT NULL THEN
        UPDATE academico_test.TACTIVIDAD_NOTA
           SET CALIFICACION = p_porcentaje, CALIFICABLE = 'S',
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TACTIVIDAD_NOTA = v_pk_nota;
        PERFORM academico_test.fn_actividad_recuperacion_aplicar(p_pk_usuario_solicitante, p_pk_tactividad_estudiante);
    END IF;
    RETURN p_porcentaje;
END;
$$;

-- ---------------------------------------------------------------------------
-- Captura por instrumento (un estudiante)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_rubrica_captura_guardar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad_estudiante BIGINT,
    p_pk_criterio              BIGINT,
    p_pk_nivel                 BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_por VARCHAR := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    -- UN_TAC_RUBRICA_EVAL_1 es DEFERRABLE: no sirve de árbitro para ON CONFLICT.
    UPDATE academico_test.TACTIVIDAD_RUBRICA_EVALUACION re
       SET FK_TACTIVIDAD_RUBRICA_NIVEL = p_pk_nivel, PONDERACION = n.PONDERACION,
           ACTIVE = TRUE, MODIFIED_BY = v_por, MODIFIED_AT = CURRENT_TIMESTAMP
      FROM academico_test.TACTIVIDAD_RUBRICA_NIVEL n
     WHERE n.PK_TACTIVIDAD_RUBRICA_NIVEL = p_pk_nivel
       AND re.FK_TACTIVIDAD_RUBRICA_CRITERIO = p_pk_criterio
       AND re.FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante;
    IF NOT FOUND THEN
        INSERT INTO academico_test.TACTIVIDAD_RUBRICA_EVALUACION (
            FK_TACTIVIDAD_RUBRICA_CRITERIO, FK_TACTIVIDAD_ESTUDIANTE, FK_TACTIVIDAD_RUBRICA_NIVEL, PONDERACION,
            CREATED_BY, CREATED_AT, ACTIVE)
        SELECT p_pk_criterio, p_pk_tactividad_estudiante, p_pk_nivel, n.PONDERACION, v_por, CURRENT_TIMESTAMP, TRUE
          FROM academico_test.TACTIVIDAD_RUBRICA_NIVEL n WHERE n.PK_TACTIVIDAD_RUBRICA_NIVEL = p_pk_nivel;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_calificar_rubrica_interno(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad_estudiante BIGINT,
    p_niveles                  JSONB
)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk BIGINT := academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante);
    v_e  JSONB;
BEGIN
    PERFORM academico_test.fn_actividad_validar_instrumento(v_pk, 'RUBRICA');
    PERFORM academico_test.fn_actividad_validar_rubrica_captura(v_pk, p_niveles);
    FOR v_e IN SELECT * FROM jsonb_array_elements(p_niveles) LOOP
        PERFORM academico_test.fn_actividad_rubrica_captura_guardar(p_pk_usuario_solicitante, p_pk_tactividad_estudiante,
            (v_e->>'pkCriterio')::BIGINT, (v_e->>'pkNivel')::BIGINT);
    END LOOP;
    RETURN academico_test.fn_actividad_nota_guardar_interno(p_pk_usuario_solicitante, p_pk_tactividad_estudiante,
        academico_test.fn_actividad_nota_rubrica_recalcular(p_pk_tactividad_estudiante));
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_cotejo_captura_guardar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad_estudiante BIGINT,
    p_pk_item                  BIGINT,
    p_cumplido                 VARCHAR
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE academico_test.TACTIVIDAD_COTEJO_EVALUACION
       SET CUMPLIDO = p_cumplido, ACTIVE = TRUE,
           MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TACTIVIDAD_COTEJO_ITEM = p_pk_item AND FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante;
    IF NOT FOUND THEN
        INSERT INTO academico_test.TACTIVIDAD_COTEJO_EVALUACION (
            FK_TACTIVIDAD_COTEJO_ITEM, FK_TACTIVIDAD_ESTUDIANTE, CUMPLIDO, CREATED_BY, CREATED_AT, ACTIVE)
        VALUES (p_pk_item, p_pk_tactividad_estudiante, p_cumplido, p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE);
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_calificar_cotejo_interno(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad_estudiante BIGINT,
    p_items_marcados           BIGINT[]
)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk   BIGINT := academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante);
    v_item RECORD;
BEGIN
    PERFORM academico_test.fn_actividad_validar_instrumento(v_pk, 'LISTA_COTEJO');
    PERFORM academico_test.fn_actividad_validar_cotejo_captura(v_pk, p_items_marcados);
    -- Reemplazo completo: cada elemento queda Cumple o No cumple explícito.
    FOR v_item IN SELECT PK_TACTIVIDAD_COTEJO_ITEM AS pk FROM academico_test.TACTIVIDAD_COTEJO_ITEM
                   WHERE FK_TACTIVIDAD = v_pk AND ACTIVE = TRUE LOOP
        PERFORM academico_test.fn_actividad_cotejo_captura_guardar(p_pk_usuario_solicitante, p_pk_tactividad_estudiante, v_item.pk,
            CASE WHEN v_item.pk = ANY (COALESCE(p_items_marcados, ARRAY[]::BIGINT[])) THEN 'S' ELSE 'N' END);
    END LOOP;
    RETURN academico_test.fn_actividad_nota_guardar_interno(p_pk_usuario_solicitante, p_pk_tactividad_estudiante,
        academico_test.fn_actividad_nota_cotejo_recalcular(p_pk_tactividad_estudiante));
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_calificar_escala_interno(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad_estudiante BIGINT,
    p_pk_nivel                 BIGINT,
    p_valor_numerico           NUMERIC
)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk     BIGINT := academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante);
    v_escala BIGINT;
    v_valor  NUMERIC;
    v_por    VARCHAR := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    PERFORM academico_test.fn_actividad_validar_instrumento(v_pk, 'ESCALA_VALORACION');
    PERFORM academico_test.fn_actividad_validar_escala_valor(v_pk, p_pk_nivel, p_valor_numerico, 'la calificación');
    SELECT PK_TACTIVIDAD_ESCALA INTO v_escala FROM academico_test.TACTIVIDAD_ESCALA
     WHERE FK_TACTIVIDAD = v_pk AND ACTIVE = TRUE;
    -- Se guarda lo que el docente marcó; el piso y el tope solo acotan la nota.
    v_valor := COALESCE(p_valor_numerico,
                        (SELECT PONDERACION FROM academico_test.TACTIVIDAD_ESCALA_NIVEL WHERE PK_TACTIVIDAD_ESCALA_NIVEL = p_pk_nivel));
    UPDATE academico_test.TACTIVIDAD_ESCALA_EVALUACION
       SET FK_TACTIVIDAD_ESCALA_NIVEL = p_pk_nivel, VALOR = v_valor,
           PONDERACION = CASE WHEN p_pk_nivel IS NOT NULL THEN v_valor END,
           ACTIVE = TRUE, MODIFIED_BY = v_por, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TACTIVIDAD_ESCALA = v_escala AND FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante;
    IF NOT FOUND THEN
        INSERT INTO academico_test.TACTIVIDAD_ESCALA_EVALUACION (
            FK_TACTIVIDAD_ESCALA, FK_TACTIVIDAD_ESTUDIANTE, FK_TACTIVIDAD_ESCALA_NIVEL, VALOR, PONDERACION,
            CREATED_BY, CREATED_AT, ACTIVE)
        VALUES (v_escala, p_pk_tactividad_estudiante, p_pk_nivel, v_valor,
                CASE WHEN p_pk_nivel IS NOT NULL THEN v_valor END, v_por, CURRENT_TIMESTAMP, TRUE);
    END IF;
    RETURN academico_test.fn_actividad_nota_guardar_interno(p_pk_usuario_solicitante, p_pk_tactividad_estudiante,
        academico_test.fn_actividad_nota_ajustar_por_criterio(v_pk,
            academico_test.fn_actividad_escala_porcentaje(v_pk, p_pk_nivel, p_valor_numerico)));
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_calificar_escala_criterios_interno(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad_estudiante BIGINT,
    p_criterios                JSONB
)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk     BIGINT := academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante);
    v_escala BIGINT;
    v_e      JSONB;
    v_nivel  BIGINT;
    v_valor  NUMERIC;
    v_suma   NUMERIC := 0;
    v_por    VARCHAR := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    PERFORM academico_test.fn_actividad_validar_instrumento(v_pk, 'ESCALA_VALORACION');
    PERFORM academico_test.fn_actividad_validar_escala_criterios(v_pk, p_criterios);
    SELECT PK_TACTIVIDAD_ESCALA INTO v_escala FROM academico_test.TACTIVIDAD_ESCALA
     WHERE FK_TACTIVIDAD = v_pk AND ACTIVE = TRUE;
    FOR v_e IN SELECT * FROM jsonb_array_elements(p_criterios) LOOP
        v_nivel := (v_e->>'pkNivel')::BIGINT;
        v_valor := COALESCE((v_e->>'valorNumerico')::NUMERIC,
                            (SELECT PONDERACION FROM academico_test.TACTIVIDAD_ESCALA_NIVEL WHERE PK_TACTIVIDAD_ESCALA_NIVEL = v_nivel));
        v_suma  := v_suma + academico_test.fn_actividad_escala_porcentaje(v_pk, v_nivel, (v_e->>'valorNumerico')::NUMERIC);
        UPDATE academico_test.TACTIVIDAD_ESCALA_CRITERIO_EVALUACION
           SET FK_TACTIVIDAD_ESCALA = v_escala, FK_TACTIVIDAD_ESCALA_NIVEL = v_nivel, VALOR = v_valor,
               PONDERACION = CASE WHEN v_nivel IS NOT NULL THEN v_valor END,
               ACTIVE = TRUE, MODIFIED_BY = v_por, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante AND CRITERIO_INDEX = (v_e->>'criterioIndex')::INT;
        IF NOT FOUND THEN
            INSERT INTO academico_test.TACTIVIDAD_ESCALA_CRITERIO_EVALUACION (
                FK_TACTIVIDAD_ESCALA, FK_TACTIVIDAD_ESTUDIANTE, CRITERIO_INDEX, FK_TACTIVIDAD_ESCALA_NIVEL, VALOR, PONDERACION,
                CREATED_BY, CREATED_AT, ACTIVE)
            VALUES (v_escala, p_pk_tactividad_estudiante, (v_e->>'criterioIndex')::INT, v_nivel, v_valor,
                    CASE WHEN v_nivel IS NOT NULL THEN v_valor END, v_por, CURRENT_TIMESTAMP, TRUE);
        END IF;
    END LOOP;
    -- Todos los criterios comparten niveles y rango: el promedio de sus
    -- porcentajes es la suma obtenida sobre la suma de máximos (Regla 42).
    RETURN academico_test.fn_actividad_nota_guardar_interno(p_pk_usuario_solicitante, p_pk_tactividad_estudiante,
        academico_test.fn_actividad_nota_ajustar_por_criterio(v_pk, ROUND(v_suma / jsonb_array_length(p_criterios), 2)));
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_calificar_otro_interno(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad_estudiante BIGINT,
    p_porcentaje               NUMERIC
)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk BIGINT := academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante);
BEGIN
    PERFORM academico_test.fn_actividad_validar_instrumento(v_pk, 'OTRO');
    PERFORM academico_test.fn_actividad_validar_porcentaje(p_porcentaje,
        'la calificación de ' || COALESCE(academico_test.fn_actividad_estudiante_nombre(
            (SELECT FK_TMATRICULA FROM academico_test.TACTIVIDAD_ESTUDIANTE WHERE PK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante)),
            'el estudiante'));
    RETURN academico_test.fn_actividad_nota_guardar_interno(p_pk_usuario_solicitante, p_pk_tactividad_estudiante,
        academico_test.fn_actividad_nota_ajustar_por_criterio(v_pk, ROUND(p_porcentaje, 2)));
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_calificar_interno(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad_estudiante BIGINT,
    p_calificacion             JSONB,
    p_fecha                    DATE
)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk BIGINT := academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante);
BEGIN
    PERFORM academico_test.fn_actividad_validar_calificacion(p_pk_tactividad_estudiante, p_fecha);
    IF p_calificacion IS NULL OR jsonb_typeof(p_calificacion) <> 'object' THEN
        RAISE EXCEPTION 'La calificación de % no tiene el formato esperado',
            academico_test.fn_actividad_etiqueta(v_pk) USING ERRCODE = '22023';
    END IF;
    CASE academico_test.fn_actividad_instrumento_efectivo(v_pk)
        WHEN 'RUBRICA' THEN
            RETURN academico_test.fn_actividad_nota_calificar_rubrica_interno(
                p_pk_usuario_solicitante, p_pk_tactividad_estudiante, p_calificacion->'niveles');
        WHEN 'LISTA_COTEJO' THEN
            RETURN academico_test.fn_actividad_nota_calificar_cotejo_interno(
                p_pk_usuario_solicitante, p_pk_tactividad_estudiante,
                ARRAY(SELECT jsonb_array_elements_text(COALESCE(p_calificacion->'itemsMarcados', '[]'::jsonb))::BIGINT));
        WHEN 'ESCALA_VALORACION' THEN
            -- Con varios criterios, un valor suelto vale para cada uno (igual que en bloque).
            IF NOT p_calificacion ? 'criterios' AND academico_test.fn_actividad_escala_criterios_cantidad(v_pk) > 1 THEN
                PERFORM academico_test.fn_actividad_validar_escala_valor(v_pk, (p_calificacion->>'pkNivel')::BIGINT,
                    (p_calificacion->>'valorNumerico')::NUMERIC, 'la calificación');
                p_calificacion := jsonb_build_object('criterios', (
                    SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object('criterioIndex', i,
                               'pkNivel', p_calificacion->'pkNivel', 'valorNumerico', p_calificacion->'valorNumerico')) ORDER BY i)
                      FROM generate_series(0, academico_test.fn_actividad_escala_criterios_cantidad(v_pk) - 1) AS i));
            END IF;
            IF p_calificacion ? 'criterios' THEN
                RETURN academico_test.fn_actividad_nota_calificar_escala_criterios_interno(
                    p_pk_usuario_solicitante, p_pk_tactividad_estudiante, p_calificacion->'criterios');
            END IF;
            RETURN academico_test.fn_actividad_nota_calificar_escala_interno(
                p_pk_usuario_solicitante, p_pk_tactividad_estudiante,
                (p_calificacion->>'pkNivel')::BIGINT, (p_calificacion->>'valorNumerico')::NUMERIC);
        ELSE
            RETURN academico_test.fn_actividad_nota_calificar_otro_interno(
                p_pk_usuario_solicitante, p_pk_tactividad_estudiante, (p_calificacion->>'porcentaje')::NUMERIC);
    END CASE;
END;
$$;

-- ---------------------------------------------------------------------------
-- Captura en bloque: un mismo valor para varios estudiantes
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_calificar_rubrica_bulk_interno(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad            BIGINT,
    p_pk_criterio              BIGINT,
    p_pk_nivel                 BIGINT,
    p_pk_tactividad_estudiante BIGINT[],
    p_fecha                    DATE
)
RETURNS TABLE (pk_tactividad_estudiante BIGINT, criterios_totales INT, criterios_cubiertos INT,
               calificacion NUMERIC, calificacion_actualizada BOOLEAN)
LANGUAGE plpgsql
AS $$
#variable_conflict use_column
DECLARE
    v_total INT;
    v_ae    BIGINT;
    v_pct   NUMERIC;
BEGIN
    PERFORM academico_test.fn_actividad_validar_calificable(p_pk_tactividad);
    PERFORM academico_test.fn_actividad_validar_instrumento(p_pk_tactividad, 'RUBRICA');
    PERFORM academico_test.fn_actividad_validar_rubrica_nivel(p_pk_tactividad, p_pk_criterio, p_pk_nivel);
    PERFORM academico_test.fn_actividad_validar_estudiantes_lote(p_pk_tactividad, p_pk_tactividad_estudiante);
    SELECT COUNT(*) INTO v_total FROM academico_test.TACTIVIDAD_RUBRICA_CRITERIO
     WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE;
    FOREACH v_ae IN ARRAY p_pk_tactividad_estudiante LOOP
        PERFORM academico_test.fn_actividad_validar_asistencia_calificar(v_ae, p_fecha);
        PERFORM academico_test.fn_actividad_rubrica_captura_guardar(p_pk_usuario_solicitante, v_ae, p_pk_criterio, p_pk_nivel);
        -- Los demás criterios ya capturados no se tocan; la nota sale al completarlos.
        v_pct := academico_test.fn_actividad_nota_guardar_interno(p_pk_usuario_solicitante, v_ae,
                     academico_test.fn_actividad_nota_rubrica_recalcular(v_ae));
        pk_tactividad_estudiante := v_ae;
        criterios_totales        := v_total;
        criterios_cubiertos      := (SELECT COUNT(*) FROM academico_test.TACTIVIDAD_RUBRICA_EVALUACION re
                                       JOIN academico_test.TACTIVIDAD_RUBRICA_CRITERIO c
                                         ON c.PK_TACTIVIDAD_RUBRICA_CRITERIO = re.FK_TACTIVIDAD_RUBRICA_CRITERIO
                                        AND c.FK_TACTIVIDAD = p_pk_tactividad AND c.ACTIVE = TRUE
                                      WHERE re.FK_TACTIVIDAD_ESTUDIANTE = v_ae AND re.ACTIVE = TRUE);
        calificacion             := v_pct;
        calificacion_actualizada := v_pct IS NOT NULL;
        RETURN NEXT;
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_calificar_cotejo_bulk_interno(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad            BIGINT,
    p_pk_item                  BIGINT,
    p_cumplido                 CHAR(1),
    p_pk_tactividad_estudiante BIGINT[],
    p_fecha                    DATE
)
RETURNS TABLE (pk_tactividad_estudiante BIGINT, items_totales INT, items_cumplidos INT, calificacion NUMERIC)
LANGUAGE plpgsql
AS $$
#variable_conflict use_column
DECLARE
    v_total INT;
    v_ae    BIGINT;
BEGIN
    PERFORM academico_test.fn_actividad_validar_calificable(p_pk_tactividad);
    PERFORM academico_test.fn_actividad_validar_instrumento(p_pk_tactividad, 'LISTA_COTEJO');
    PERFORM academico_test.fn_actividad_validar_cumplido(p_cumplido);
    PERFORM academico_test.fn_actividad_validar_cotejo_item(p_pk_tactividad, p_pk_item);
    PERFORM academico_test.fn_actividad_validar_estudiantes_lote(p_pk_tactividad, p_pk_tactividad_estudiante);
    SELECT COUNT(*) INTO v_total FROM academico_test.TACTIVIDAD_COTEJO_ITEM
     WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE;
    FOREACH v_ae IN ARRAY p_pk_tactividad_estudiante LOOP
        PERFORM academico_test.fn_actividad_validar_asistencia_calificar(v_ae, p_fecha);
        PERFORM academico_test.fn_actividad_cotejo_captura_guardar(p_pk_usuario_solicitante, v_ae, p_pk_item, p_cumplido);
        -- Un elemento sin captura cuenta como no cumplido: siempre hay nota.
        calificacion := academico_test.fn_actividad_nota_guardar_interno(p_pk_usuario_solicitante, v_ae,
                            academico_test.fn_actividad_nota_cotejo_recalcular(v_ae));
        pk_tactividad_estudiante := v_ae;
        items_totales            := v_total;
        items_cumplidos          := (SELECT COUNT(*) FROM academico_test.TACTIVIDAD_COTEJO_EVALUACION ce
                                       JOIN academico_test.TACTIVIDAD_COTEJO_ITEM i
                                         ON i.PK_TACTIVIDAD_COTEJO_ITEM = ce.FK_TACTIVIDAD_COTEJO_ITEM
                                        AND i.FK_TACTIVIDAD = p_pk_tactividad AND i.ACTIVE = TRUE
                                      WHERE ce.FK_TACTIVIDAD_ESTUDIANTE = v_ae AND ce.ACTIVE = TRUE AND ce.CUMPLIDO = 'S');
        RETURN NEXT;
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_calificar_escala_bulk_interno(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad            BIGINT,
    p_pk_nivel                 BIGINT,
    p_valor_numerico           NUMERIC,
    p_criterios                JSONB,
    p_pk_tactividad_estudiante BIGINT[],
    p_fecha                    DATE
)
RETURNS TABLE (pk_tactividad_estudiante BIGINT, calificacion NUMERIC)
LANGUAGE plpgsql
AS $$
#variable_conflict use_column
DECLARE
    v_criterios JSONB := CASE WHEN jsonb_typeof(p_criterios) = 'null' THEN NULL ELSE p_criterios END;
    v_n         INT;
    v_ae        BIGINT;
BEGIN
    PERFORM academico_test.fn_actividad_validar_calificable(p_pk_tactividad);
    PERFORM academico_test.fn_actividad_validar_instrumento(p_pk_tactividad, 'ESCALA_VALORACION');
    IF v_criterios IS NOT NULL AND (p_pk_nivel IS NOT NULL OR p_valor_numerico IS NOT NULL) THEN
        RAISE EXCEPTION 'Califique por criterios o con un valor para toda la escala, no las dos cosas' USING ERRCODE = '22023';
    END IF;
    PERFORM academico_test.fn_actividad_validar_estudiantes_lote(p_pk_tactividad, p_pk_tactividad_estudiante);
    v_n := academico_test.fn_actividad_escala_criterios_cantidad(p_pk_tactividad);
    IF v_criterios IS NULL THEN
        PERFORM academico_test.fn_actividad_validar_escala_valor(p_pk_tactividad, p_pk_nivel, p_valor_numerico, 'la calificación');
        -- Con varios criterios, el valor suelto se aplica a cada uno.
        IF v_n > 1 THEN
            SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                       'criterioIndex', i, 'pkNivel', p_pk_nivel, 'valorNumerico', p_valor_numerico)) ORDER BY i)
              INTO v_criterios FROM generate_series(0, v_n - 1) AS i;
        END IF;
    END IF;
    FOREACH v_ae IN ARRAY p_pk_tactividad_estudiante LOOP
        PERFORM academico_test.fn_actividad_validar_asistencia_calificar(v_ae, p_fecha);
        pk_tactividad_estudiante := v_ae;
        calificacion := CASE WHEN v_criterios IS NOT NULL
            THEN academico_test.fn_actividad_nota_calificar_escala_criterios_interno(p_pk_usuario_solicitante, v_ae, v_criterios)
            ELSE academico_test.fn_actividad_nota_calificar_escala_interno(p_pk_usuario_solicitante, v_ae, p_pk_nivel, p_valor_numerico)
        END;
        RETURN NEXT;
    END LOOP;
END;
$$;

-- ---------------------------------------------------------------------------
-- Lecturas de resultados
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_obtener_interno(p_pk_tactividad_estudiante BIGINT)
RETURNS TABLE (instrumento VARCHAR, calificacion NUMERIC, calificable CHAR, observacion VARCHAR, detalle JSONB,
               evidencias JSONB, nota_homologada NUMERIC, valoracion VARCHAR, formato_valor VARCHAR,
               resultado_instrumento JSONB)
LANGUAGE sql
STABLE
AS $$
    SELECT lv.VALOR,
           n.CALIFICACION,
           n.CALIFICABLE,
           n.OBSERVACION,
           -- Captura cruda por pk; Otro se lee como su método.
           CASE academico_test.fn_actividad_instrumento_efectivo(a.PK_TACTIVIDAD)
               WHEN 'RUBRICA' THEN COALESCE((
                   SELECT jsonb_agg(jsonb_build_object('pkCriterio', re.FK_TACTIVIDAD_RUBRICA_CRITERIO,
                                                       'pkNivel', re.FK_TACTIVIDAD_RUBRICA_NIVEL,
                                                       'ponderacion', re.PONDERACION))
                     FROM academico_test.TACTIVIDAD_RUBRICA_EVALUACION re
                     JOIN academico_test.TACTIVIDAD_RUBRICA_CRITERIO c
                       ON c.PK_TACTIVIDAD_RUBRICA_CRITERIO = re.FK_TACTIVIDAD_RUBRICA_CRITERIO
                    WHERE re.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                      AND re.ACTIVE = TRUE AND c.FK_TACTIVIDAD = a.PK_TACTIVIDAD), '[]'::jsonb)
               WHEN 'LISTA_COTEJO' THEN COALESCE((
                   SELECT jsonb_agg(jsonb_build_object('pkItem', ce.FK_TACTIVIDAD_COTEJO_ITEM, 'cumplido', ce.CUMPLIDO))
                     FROM academico_test.TACTIVIDAD_COTEJO_EVALUACION ce
                     JOIN academico_test.TACTIVIDAD_COTEJO_ITEM i ON i.PK_TACTIVIDAD_COTEJO_ITEM = ce.FK_TACTIVIDAD_COTEJO_ITEM
                    WHERE ce.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                      AND ce.ACTIVE = TRUE AND i.FK_TACTIVIDAD = a.PK_TACTIVIDAD), '[]'::jsonb)
               WHEN 'ESCALA_VALORACION' THEN COALESCE((
                   SELECT jsonb_agg(jsonb_build_object('criterioIndex', ce.CRITERIO_INDEX,
                                                       'pkNivel', ce.FK_TACTIVIDAD_ESCALA_NIVEL,
                                                       'valor', ce.VALOR, 'ponderacion', ce.PONDERACION)
                                    ORDER BY ce.CRITERIO_INDEX)
                     FROM academico_test.TACTIVIDAD_ESCALA_CRITERIO_EVALUACION ce
                     JOIN academico_test.TACTIVIDAD_ESCALA e ON e.PK_TACTIVIDAD_ESCALA = ce.FK_TACTIVIDAD_ESCALA
                    WHERE ce.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                      AND ce.ACTIVE = TRUE AND e.FK_TACTIVIDAD = a.PK_TACTIVIDAD), (
                   SELECT jsonb_build_object('pkNivel', ee.FK_TACTIVIDAD_ESCALA_NIVEL, 'valor', ee.VALOR,
                                             'ponderacion', ee.PONDERACION)
                     FROM academico_test.TACTIVIDAD_ESCALA_EVALUACION ee
                     JOIN academico_test.TACTIVIDAD_ESCALA e ON e.PK_TACTIVIDAD_ESCALA = ee.FK_TACTIVIDAD_ESCALA
                    WHERE ee.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                      AND ee.ACTIVE = TRUE AND e.FK_TACTIVIDAD = a.PK_TACTIVIDAD))
           END,
           -- Adjuntos de la observación (registro formativo).
           COALESCE((SELECT jsonb_agg(jsonb_build_object('pk', so.PK_TACTIVIDAD_SOPORTE, 'fkTarchivo', so.FK_TARCHIVO,
                                                         'nombre', ar.NOMBRE, 'fecha', so.FECHA)
                                      ORDER BY so.PK_TACTIVIDAD_SOPORTE)
                       FROM academico_test.TACTIVIDAD_SOPORTE so
                       LEFT JOIN academico_test.TARCHIVO ar ON ar.PK_TARCHIVO = so.FK_TARCHIVO
                      WHERE so.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                        AND so.ACTIVE = TRUE AND so.FK_TARCHIVO IS NOT NULL), '[]'::jsonb),
           h.nota_homologada,
           h.valoracion_nombre,
           h.formato_valor,
           academico_test.fn_actividad_nota_resultado_instrumento(ae.PK_TACTIVIDAD_ESTUDIANTE)
      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
      JOIN academico_test.TACTIVIDAD a ON a.PK_TACTIVIDAD = ae.FK_TACTIVIDAD
      LEFT JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = a.FK_TLV_INSTRUMENTO_EVALUACION
      LEFT JOIN academico_test.TACTIVIDAD_NOTA n ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE AND n.ACTIVE = TRUE
      LEFT JOIN LATERAL academico_test.fn_nota_homologar(
                    COALESCE(n.DEFINITIVA, n.CALIFICACION), a.FK_TASIGNATURA,
                    academico_test.fn_actividad_grado_resolver(a.PK_TACTIVIDAD)) h ON TRUE
     WHERE ae.PK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante AND ae.ACTIVE = TRUE;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_estudiantes_calificaciones_listar_interno(
    p_pk_tactividad BIGINT,
    p_fecha         DATE,
    p_search        VARCHAR
)
RETURNS TABLE (pk_tactividad_estudiante BIGINT, pk_tmatricula BIGINT, nombre_estudiante VARCHAR, instrumento VARCHAR,
               fecha DATE, pk_tasistencia BIGINT, fk_tlv_tipo_asistencia BIGINT, tipo_asistencia VARCHAR,
               asistencia_observacion VARCHAR, fk_soporte_archivo BIGINT, calificacion NUMERIC, calificable CHAR,
               nota_observacion VARCHAR, es_formativa BOOLEAN, fecha_asistencia DATE, nota_homologada NUMERIC,
               valoracion VARCHAR, formato_valor VARCHAR, resultado_instrumento JSONB)
LANGUAGE sql
STABLE
AS $$
    WITH act AS (
        SELECT a.PK_TACTIVIDAD, a.FK_TASIGNATURA, lv.VALOR AS instrumento,
               academico_test.fn_actividad_es_formativa(a.PK_TACTIVIDAD) AS formativa,
               academico_test.fn_actividad_grado_resolver(a.PK_TACTIVIDAD) AS grado
          FROM academico_test.TACTIVIDAD a
          LEFT JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = a.FK_TLV_INSTRUMENTO_EVALUACION
         WHERE a.PK_TACTIVIDAD = p_pk_tactividad
    ), base AS (
        SELECT ae.PK_TACTIVIDAD_ESTUDIANTE, ae.FK_TMATRICULA,
               academico_test.fn_actividad_estudiante_nombre(ae.FK_TMATRICULA)::VARCHAR AS nombre
          FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
         WHERE ae.FK_TACTIVIDAD = p_pk_tactividad AND ae.ACTIVE = TRUE
    )
    SELECT b.PK_TACTIVIDAD_ESTUDIANTE, b.FK_TMATRICULA, b.nombre, act.instrumento, p_fecha,
           s.PK_TASISTENCIA, s.FK_TLV_TIPO_ASISTENCIA, lva.NOMBRE::VARCHAR, s.OBSERVACION, s.FK_SOPORTE_ARCHIVO,
           n.CALIFICACION, n.CALIFICABLE, n.OBSERVACION, act.formativa,
           academico_test.fn_actividad_asistencia_fecha_resolver(b.FK_TMATRICULA, p_pk_tactividad),
           h.nota_homologada, h.valoracion_nombre, h.formato_valor,
           academico_test.fn_actividad_nota_resultado_instrumento(b.PK_TACTIVIDAD_ESTUDIANTE)
      FROM base b
     CROSS JOIN act
      LEFT JOIN LATERAL (
          -- En formativas vale la asistencia de cualquier sesión del día.
          SELECT s2.PK_TASISTENCIA, s2.FK_TLV_TIPO_ASISTENCIA, s2.OBSERVACION, s2.FK_SOPORTE_ARCHIVO
            FROM academico_test.TASISTENCIA s2
           WHERE s2.FK_TMATRICULA = b.FK_TMATRICULA AND s2.FECHA = p_fecha AND s2.ACTIVE = TRUE
             AND (act.formativa OR s2.FK_TASIGNATURA = act.FK_TASIGNATURA)
           ORDER BY s2.PK_TASISTENCIA DESC
           LIMIT 1) s ON TRUE
      LEFT JOIN academico_test.TLISTA_VALOR lva ON lva.PK_LISTA_VALOR = s.FK_TLV_TIPO_ASISTENCIA
      LEFT JOIN academico_test.TACTIVIDAD_NOTA n ON n.FK_TACTIVIDAD_ESTUDIANTE = b.PK_TACTIVIDAD_ESTUDIANTE AND n.ACTIVE = TRUE
      LEFT JOIN LATERAL academico_test.fn_nota_homologar(
                    COALESCE(n.DEFINITIVA, n.CALIFICACION), act.FK_TASIGNATURA, act.grado) h ON TRUE
     WHERE NULLIF(TRIM(p_search), '') IS NULL OR b.nombre ILIKE '%' || TRIM(p_search) || '%'
     ORDER BY b.nombre, b.PK_TACTIVIDAD_ESTUDIANTE;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_instrumento_definir_interno(BIGINT, BIGINT, JSONB)
    IS 'INTERNO: valida con fn_actividad_validar_instrumento_definicion y reemplaza la definición del instrumento de la actividad (rúbrica, lista de cotejo, escala u Otro). Lo usan fn_actividad_instrumento_definir y el importador (fn_actividad_importar).';
COMMENT ON FUNCTION academico_test.fn_actividad_otro_definir_interno(BIGINT, BIGINT, JSONB)
    IS 'INTERNO: guarda tipo de evidencia y método de Otro, define la estructura del método y aplica la Regla 41 a las casillas de entrega. Solo desde fn_actividad_instrumento_definir_interno, que ya validó.';
COMMENT ON FUNCTION academico_test.fn_actividad_nota_rubrica_recalcular(BIGINT)
    IS 'INTERNO: nota (0-100) de la rúbrica de un estudiante: suma de los puntajes elegidos sobre la suma de los máximos de cada criterio (Regla 42), con piso y tope institucionales. NULL mientras falten criterios. No escribe.';
COMMENT ON FUNCTION academico_test.fn_actividad_nota_cotejo_recalcular(BIGINT)
    IS 'INTERNO: nota (0-100) de la lista de cotejo: suma de los puntajes cumplidos sobre el total posible (sin puntaje pesa 1), con piso y tope. No escribe.';
COMMENT ON FUNCTION academico_test.fn_actividad_nota_guardar_interno(BIGINT, BIGINT, NUMERIC)
    IS 'INTERNO: escribe el porcentaje en TACTIVIDAD_NOTA y consolida la recuperación (fn_actividad_recuperacion_aplicar). NULL no toca la nota. Lo usan todos los _interno de calificación.';
COMMENT ON FUNCTION academico_test.fn_actividad_nota_calificar_interno(BIGINT, BIGINT, JSONB, DATE)
    IS 'INTERNO: valida la calificación (fn_actividad_validar_calificacion) y la despacha según el instrumento efectivo: {niveles}, {itemsMarcados}, {pkNivel|valorNumerico} o {criterios}, {porcentaje}. Lo usa fn_actividad_nota_calificar.';
COMMENT ON FUNCTION academico_test.fn_actividad_nota_obtener_interno(BIGINT)
    IS 'INTERNO: detalle de la nota de un estudiante (instrumento, %, captura cruda, soportes, homologación y resultado con etiquetas). Lo usa fn_actividad_nota_obtener.';
COMMENT ON FUNCTION academico_test.fn_actividad_estudiantes_calificaciones_listar_interno(BIGINT, DATE, VARCHAR)
    IS 'INTERNO: estudiantes de la actividad con asistencia del día, nota, homologación y resultado del instrumento. Lo usa fn_actividad_estudiantes_calificaciones_listar.';
