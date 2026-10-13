-- V496.6 - Instrumentos, calificación y resultados de actividades: núcleos
-- _interno sin permisos. Definen rúbrica, lista de cotejo, escala y Otro
-- (Regla 41), califican individual y en bloque (la rúbrica suma puntajes
-- sobre la suma de máximos, Regla 42; la escala por criterios, Regla 56),
-- fijan el estado de resultado (Regla 62) y lo derivan de la asistencia del
-- primer día, de la Vista o marcada en el Planeador (Regla 73), registran la observación y sus soportes (Regla 61) y leen la
-- nota y el listado de calificaciones (Regla 58). La nota se escribe en un
-- solo punto (aplicar_interno); guardar_interno decide si es una corrección
-- que exige aprobación (Regla 55, tablas de V496.18).
-- Depende de: V496.5 (validaciones, catálogos), V227 (get_or_create, ajuste
-- por criterio), V226, V408 (recuperación), V428, V450, V463 (evidencias),
-- V136 (fn_asistencia_validar_tipo), V137 (fn_asistencia_periodo_eval).

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
-- Cambia el tipo de retorno (estado, momento, enlace, resultados_completos).
DROP FUNCTION IF EXISTS academico_test.fn_actividad_estudiantes_calificaciones_listar_interno(BIGINT, DATE, VARCHAR);

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
        -- TACTIVIDAD_RUBRICA_NIVEL.PONDERACION es NOT NULL (V22): a diferencia del item de
        -- cotejo (que guarda NULL y resuelve el peso 1 al calcular), acá el default "pesa 1"
        -- se escribe tal cual al definir, porque fn_actividad_validar_rubrica_definicion ya
        -- dejó pasar niveles sin puntaje explícito cuando la unidad no lo exige.
        INSERT INTO academico_test.TACTIVIDAD_RUBRICA_NIVEL (
            FK_TACTIVIDAD_RUBRICA_CRITERIO, ETIQUETA, DESCRIPCION, PONDERACION, CREATED_BY, CREATED_AT, ACTIVE)
        SELECT v_pk, NULLIF(TRIM(n->>'etiqueta'), ''), TRIM(n->>'descripcion'),
               COALESCE(NULLIF(n->>'ponderacion', '')::NUMERIC, 1),
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

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_aplicar_interno(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad_estudiante BIGINT,
    p_porcentaje               NUMERIC
)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk_nota BIGINT  := academico_test.fn_actividad_nota_get_or_create(p_pk_usuario_solicitante, p_pk_tactividad_estudiante);
    v_pct     NUMERIC := academico_test.fn_actividad_nota_redondear(
                             academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante), p_porcentaje);
BEGIN
    -- NULL = captura aún incompleta: se guarda lo marcado pero no se toca la nota.
    IF v_pct IS NOT NULL THEN
        UPDATE academico_test.TACTIVIDAD_NOTA
           SET CALIFICACION = v_pct, CALIFICABLE = 'S',
               FK_TLV_ESTADO_RESULTADO = academico_test.fn_tlv_estado_resultado_pk('CALIFICADO'),
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TACTIVIDAD_NOTA = v_pk_nota;
        PERFORM academico_test.fn_actividad_asistencia_congelar_interno(v_pk_nota);
        PERFORM academico_test.fn_actividad_recuperacion_aplicar(p_pk_usuario_solicitante, p_pk_tactividad_estudiante);
    END IF;
    RETURN v_pct;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_nota_aplicar_interno(BIGINT, BIGINT, NUMERIC)
    IS 'INTERNO: escribe la nota (porcentaje, redondeado con la Regla 30), la marca Calificado y consolida la recuperación. Sin decisión de aprobación: la usan fn_actividad_nota_guardar_interno y la aprobación de una corrección de resultado.';

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_guardar_interno(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad_estudiante BIGINT,
    p_porcentaje               NUMERIC
)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_pct NUMERIC := academico_test.fn_actividad_nota_redondear(
                         academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante), p_porcentaje);
BEGIN
    PERFORM academico_test.fn_actividad_validar_permite_calificar(p_pk_tactividad_estudiante);
    -- Regla 55: con aprobación pendiente tampoco vale la captura, y ya se
    -- escribió. Se aborta con PA055 (porcentaje en DETAIL) para que quien
    -- capturó lo atrape, revierta y abra la solicitud. Se compara ya
    -- redondeado: el mismo número otra vez no es una corrección. Al aprobar,
    -- la captura se repite con academico_test.aprobacion_en_curso = 'on'.
    IF v_pct IS NOT NULL
       AND to_regclass('academico_test.tsolicitud_aprobacion') IS NOT NULL
       AND current_setting('academico_test.aprobacion_en_curso', TRUE) IS DISTINCT FROM 'on'
       AND academico_test.fn_resultado_correccion_requiere_aprobacion(p_pk_tactividad_estudiante, v_pct) IS TRUE THEN
        RAISE EXCEPTION 'Corregir el resultado de % requiere aprobación del Coordinador académico',
            academico_test.fn_actividad_estudiante_etiqueta(p_pk_tactividad_estudiante)
            USING ERRCODE = 'PA055', DETAIL = v_pct::TEXT;
    END IF;
    -- Redondea una sola vez quien escribe.
    RETURN academico_test.fn_actividad_nota_aplicar_interno(p_pk_usuario_solicitante, p_pk_tactividad_estudiante, p_porcentaje);
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

-- Regla 56: suma de lo obtenido sobre la suma de los máximos de cada criterio.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_calificar_escala_criterios_interno(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad_estudiante BIGINT,
    p_criterios                JSONB
)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk       BIGINT := academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante);
    v_escala   BIGINT;
    v_valor_max NUMERIC;
    v_nivel_max NUMERIC;
    v_e        JSONB;
    v_nivel    BIGINT;
    v_valor    NUMERIC;
    v_obtenido NUMERIC := 0;
    v_maximo   NUMERIC := 0;
    v_por      VARCHAR := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    PERFORM academico_test.fn_actividad_validar_instrumento(v_pk, 'ESCALA_VALORACION');
    PERFORM academico_test.fn_actividad_validar_escala_criterios(v_pk, p_criterios);
    SELECT e.PK_TACTIVIDAD_ESCALA, e.VALOR_MAX,
           (SELECT MAX(n.PONDERACION) FROM academico_test.TACTIVIDAD_ESCALA_NIVEL n
             WHERE n.FK_TACTIVIDAD_ESCALA = e.PK_TACTIVIDAD_ESCALA AND n.ACTIVE = TRUE)
      INTO v_escala, v_valor_max, v_nivel_max
      FROM academico_test.TACTIVIDAD_ESCALA e
     WHERE e.FK_TACTIVIDAD = v_pk AND e.ACTIVE = TRUE;
    FOR v_e IN SELECT * FROM jsonb_array_elements(p_criterios) LOOP
        v_nivel := (v_e->>'pkNivel')::BIGINT;
        v_valor := COALESCE((v_e->>'valorNumerico')::NUMERIC,
                            (SELECT PONDERACION FROM academico_test.TACTIVIDAD_ESCALA_NIVEL WHERE PK_TACTIVIDAD_ESCALA_NIVEL = v_nivel));
        v_obtenido := v_obtenido + COALESCE(v_valor, 0);
        v_maximo   := v_maximo + COALESCE(CASE WHEN v_nivel IS NOT NULL THEN v_nivel_max ELSE v_valor_max END, 0);
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
    RETURN academico_test.fn_actividad_nota_guardar_interno(p_pk_usuario_solicitante, p_pk_tactividad_estudiante,
        academico_test.fn_actividad_nota_ajustar_por_criterio(v_pk,
            CASE WHEN v_maximo > 0 THEN ROUND(v_obtenido / v_maximo * 100, 2) END));
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
        'la calificación de ' || academico_test.fn_actividad_estudiante_etiqueta(p_pk_tactividad_estudiante));
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
    v_pk  BIGINT := academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante);
    v_pct TEXT;
    v_res NUMERIC;
BEGIN
    PERFORM academico_test.fn_actividad_validar_calificacion(p_pk_tactividad_estudiante, p_fecha);
    IF p_calificacion IS NULL OR jsonb_typeof(p_calificacion) <> 'object' THEN
        RAISE EXCEPTION 'La calificación de % no tiene el formato esperado',
            academico_test.fn_actividad_etiqueta(v_pk) USING ERRCODE = '22023';
    END IF;
    BEGIN
    CASE academico_test.fn_actividad_instrumento_efectivo(v_pk)
        WHEN 'RUBRICA' THEN
            v_res := academico_test.fn_actividad_nota_calificar_rubrica_interno(
                p_pk_usuario_solicitante, p_pk_tactividad_estudiante, p_calificacion->'niveles');
        WHEN 'LISTA_COTEJO' THEN
            v_res := academico_test.fn_actividad_nota_calificar_cotejo_interno(
                p_pk_usuario_solicitante, p_pk_tactividad_estudiante,
                ARRAY(SELECT jsonb_array_elements_text(COALESCE(p_calificacion->'itemsMarcados', '[]'::jsonb))::BIGINT));
        WHEN 'ESCALA_VALORACION' THEN
            IF NOT p_calificacion ? 'criterios' AND academico_test.fn_actividad_escala_criterios_cantidad(v_pk) > 1 THEN
                PERFORM academico_test.fn_actividad_validar_escala_valor(v_pk, (p_calificacion->>'pkNivel')::BIGINT,
                    (p_calificacion->>'valorNumerico')::NUMERIC, 'la calificación');
                p_calificacion := jsonb_build_object('criterios', (
                    SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object('criterioIndex', i,
                               'pkNivel', p_calificacion->'pkNivel', 'valorNumerico', p_calificacion->'valorNumerico')) ORDER BY i)
                      FROM generate_series(0, academico_test.fn_actividad_escala_criterios_cantidad(v_pk) - 1) AS i));
            END IF;
            IF p_calificacion ? 'criterios' THEN
                v_res := academico_test.fn_actividad_nota_calificar_escala_criterios_interno(
                    p_pk_usuario_solicitante, p_pk_tactividad_estudiante, p_calificacion->'criterios');
            ELSE
                v_res := academico_test.fn_actividad_nota_calificar_escala_interno(
                    p_pk_usuario_solicitante, p_pk_tactividad_estudiante,
                    (p_calificacion->>'pkNivel')::BIGINT, (p_calificacion->>'valorNumerico')::NUMERIC);
            END IF;
        ELSE
            v_res := academico_test.fn_actividad_nota_calificar_otro_interno(
                p_pk_usuario_solicitante, p_pk_tactividad_estudiante, (p_calificacion->>'porcentaje')::NUMERIC);
    END CASE;
    -- Solo la nota completa cancela: en bloque se perderían criterios ya corregidos.
    IF v_res IS NOT NULL
       AND current_setting('academico_test.aprobacion_en_curso', TRUE) IS DISTINCT FROM 'on' THEN
        PERFORM academico_test.fn_actividad_resultado_correccion_cancelar_interno(
            p_pk_usuario_solicitante, p_pk_tactividad_estudiante);
    END IF;
    RETURN v_res;
    EXCEPTION WHEN SQLSTATE 'PA055' THEN
        GET STACKED DIAGNOSTICS v_pct = PG_EXCEPTION_DETAIL;
        RETURN academico_test.fn_actividad_resultado_correccion_diferir_interno(p_pk_usuario_solicitante,
            p_pk_tactividad_estudiante, v_pct::NUMERIC,
            jsonb_build_object('operacion', 'CALIFICAR', 'calificacion', p_calificacion));
    END;
END;
$$;

-- Vista previa: la nota que dejaría una captura, sin guardar ni abrir solicitud.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_previsualizar_interno(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad_estudiante BIGINT,
    p_calificacion             JSONB,
    p_fecha                    DATE
)
RETURNS TABLE (porcentaje NUMERIC, nota_homologada NUMERIC)
LANGUAGE plpgsql
AS $$
DECLARE
    v_txt TEXT;
    v_pct NUMERIC;
BEGIN
    -- Captura como si estuviera aprobada (sin PA055) y el error final
    -- deshace la escritura y el set_config: solo queda el porcentaje.
    BEGIN
        PERFORM set_config('academico_test.aprobacion_en_curso', 'on', TRUE);
        v_pct := academico_test.fn_actividad_nota_calificar_interno(
                     p_pk_usuario_solicitante, p_pk_tactividad_estudiante, p_calificacion, p_fecha);
        RAISE EXCEPTION 'vista previa' USING ERRCODE = 'PV001', DETAIL = COALESCE(v_pct::TEXT, '');
    EXCEPTION WHEN SQLSTATE 'PV001' THEN
        GET STACKED DIAGNOSTICS v_txt = PG_EXCEPTION_DETAIL;
    END;

    RETURN QUERY
    SELECT NULLIF(v_txt, '')::NUMERIC, h.nota_homologada
      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
      JOIN academico_test.TACTIVIDAD a  ON a.PK_TACTIVIDAD = ae.FK_TACTIVIDAD
      JOIN academico_test.TMATRICULA m  ON m.PK_TMATRICULA = ae.FK_TMATRICULA
      JOIN academico_test.TGRUPO gr     ON gr.PK_TGRUPO = m.FK_TGRUPO
      LEFT JOIN LATERAL academico_test.fn_nota_homologar(
                    NULLIF(v_txt, '')::NUMERIC, a.FK_TASIGNATURA, gr.FK_TGRADO) h ON TRUE
     WHERE ae.PK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante;
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
    v_det   TEXT;
BEGIN
    PERFORM academico_test.fn_actividad_validar_calificable(p_pk_tactividad);
    PERFORM academico_test.fn_actividad_validar_instrumento(p_pk_tactividad, 'RUBRICA');
    PERFORM academico_test.fn_actividad_validar_rubrica_nivel(p_pk_tactividad, p_pk_criterio, p_pk_nivel);
    PERFORM academico_test.fn_actividad_validar_estudiantes_lote(p_pk_tactividad, p_pk_tactividad_estudiante);
    SELECT COUNT(*) INTO v_total FROM academico_test.TACTIVIDAD_RUBRICA_CRITERIO
     WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE;
    FOREACH v_ae IN ARRAY p_pk_tactividad_estudiante LOOP
        BEGIN
            PERFORM academico_test.fn_actividad_rubrica_captura_guardar(p_pk_usuario_solicitante, v_ae, p_pk_criterio, p_pk_nivel);
            -- Los demás criterios ya capturados no se tocan; la nota sale al completarlos.
            v_pct := academico_test.fn_actividad_nota_guardar_interno(p_pk_usuario_solicitante, v_ae,
                         academico_test.fn_actividad_nota_rubrica_recalcular(v_ae));
            calificacion_actualizada := v_pct IS NOT NULL;
        EXCEPTION WHEN SQLSTATE 'PA055' THEN
            GET STACKED DIAGNOSTICS v_det = PG_EXCEPTION_DETAIL;
            v_pct := academico_test.fn_actividad_resultado_correccion_diferir_interno(p_pk_usuario_solicitante, v_ae,
                         v_det::NUMERIC, jsonb_build_object('operacion', 'RUBRICA_CRITERIO',
                                                            'pkCriterio', p_pk_criterio, 'pkNivel', p_pk_nivel));
            calificacion_actualizada := FALSE;
        END;
        pk_tactividad_estudiante := v_ae;
        criterios_totales        := v_total;
        criterios_cubiertos      := (SELECT COUNT(*) FROM academico_test.TACTIVIDAD_RUBRICA_EVALUACION re
                                       JOIN academico_test.TACTIVIDAD_RUBRICA_CRITERIO c
                                         ON c.PK_TACTIVIDAD_RUBRICA_CRITERIO = re.FK_TACTIVIDAD_RUBRICA_CRITERIO
                                        AND c.FK_TACTIVIDAD = p_pk_tactividad AND c.ACTIVE = TRUE
                                      WHERE re.FK_TACTIVIDAD_ESTUDIANTE = v_ae AND re.ACTIVE = TRUE);
        calificacion             := v_pct;
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
    v_det   TEXT;
BEGIN
    PERFORM academico_test.fn_actividad_validar_calificable(p_pk_tactividad);
    PERFORM academico_test.fn_actividad_validar_instrumento(p_pk_tactividad, 'LISTA_COTEJO');
    PERFORM academico_test.fn_actividad_validar_cumplido(p_cumplido);
    PERFORM academico_test.fn_actividad_validar_cotejo_item(p_pk_tactividad, p_pk_item);
    PERFORM academico_test.fn_actividad_validar_estudiantes_lote(p_pk_tactividad, p_pk_tactividad_estudiante);
    SELECT COUNT(*) INTO v_total FROM academico_test.TACTIVIDAD_COTEJO_ITEM
     WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE;
    FOREACH v_ae IN ARRAY p_pk_tactividad_estudiante LOOP
        BEGIN
            PERFORM academico_test.fn_actividad_cotejo_captura_guardar(p_pk_usuario_solicitante, v_ae, p_pk_item, p_cumplido);
            -- Un elemento sin captura cuenta como no cumplido: siempre hay nota.
            calificacion := academico_test.fn_actividad_nota_guardar_interno(p_pk_usuario_solicitante, v_ae,
                                academico_test.fn_actividad_nota_cotejo_recalcular(v_ae));
        EXCEPTION WHEN SQLSTATE 'PA055' THEN
            GET STACKED DIAGNOSTICS v_det = PG_EXCEPTION_DETAIL;
            calificacion := academico_test.fn_actividad_resultado_correccion_diferir_interno(p_pk_usuario_solicitante, v_ae,
                                v_det::NUMERIC, jsonb_build_object('operacion', 'COTEJO_ITEM',
                                                                   'pkItem', p_pk_item, 'cumplido', p_cumplido));
        END;
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
    v_det       TEXT;
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
        pk_tactividad_estudiante := v_ae;
        BEGIN
            calificacion := CASE WHEN v_criterios IS NOT NULL
                THEN academico_test.fn_actividad_nota_calificar_escala_criterios_interno(p_pk_usuario_solicitante, v_ae, v_criterios)
                ELSE academico_test.fn_actividad_nota_calificar_escala_interno(p_pk_usuario_solicitante, v_ae, p_pk_nivel, p_valor_numerico)
            END;
            IF calificacion IS NOT NULL THEN
                PERFORM academico_test.fn_actividad_resultado_correccion_cancelar_interno(p_pk_usuario_solicitante, v_ae);
            END IF;
        EXCEPTION WHEN SQLSTATE 'PA055' THEN
            GET STACKED DIAGNOSTICS v_det = PG_EXCEPTION_DETAIL;
            -- Se guarda con la forma del calificar individual, que es la que se repite al aprobar.
            calificacion := academico_test.fn_actividad_resultado_correccion_diferir_interno(p_pk_usuario_solicitante, v_ae,
                                v_det::NUMERIC, jsonb_build_object('operacion', 'CALIFICAR', 'calificacion',
                                    CASE WHEN v_criterios IS NOT NULL THEN jsonb_build_object('criterios', v_criterios)
                                         ELSE jsonb_strip_nulls(jsonb_build_object('pkNivel', p_pk_nivel, 'valorNumerico', p_valor_numerico)) END));
        END;
        RETURN NEXT;
    END LOOP;
END;
$$;

-- ---------------------------------------------------------------------------
-- Estado de resultado (Reglas 62 y 73)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_resultado_estado_set_interno(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad_estudiante BIGINT,
    p_estado                   VARCHAR
)
RETURNS VARCHAR
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk      BIGINT  := academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante);
    v_estado  VARCHAR := upper(TRIM(p_estado));
    v_pk_nota BIGINT;
BEGIN
    PERFORM academico_test.fn_actividad_validar_activa(v_pk);
    PERFORM academico_test.fn_actividad_validar_referente_calificable(v_pk);
    PERFORM academico_test.fn_actividad_validar_estado_resultado_asignable(v_estado);
    PERFORM academico_test.fn_actividad_validar_estado_transicion(p_pk_tactividad_estudiante, v_estado);
    v_pk_nota := academico_test.fn_actividad_nota_get_or_create(p_pk_usuario_solicitante, p_pk_tactividad_estudiante);
    -- Regla 62: el estado excluye la nota. DEFINITIVA solo se limpia si no la
    -- sostiene una recuperación ya aplicada (RECUPERACION).
    UPDATE academico_test.TACTIVIDAD_NOTA
       SET FK_TLV_ESTADO_RESULTADO = academico_test.fn_tlv_estado_resultado_pk(v_estado),
           CALIFICACION = NULL,
           DEFINITIVA   = CASE WHEN RECUPERACION IS NULL THEN NULL ELSE DEFINITIVA END,
           -- Sin resultado la asistencia copiada de la Vista vuelve a leerse en vivo;
           -- la marcada en el Planeador se conserva.
           FK_TLV_TIPO_ASISTENCIA = CASE WHEN ASISTENCIA_ORIGEN = 'PLANEADOR' THEN FK_TLV_TIPO_ASISTENCIA END,
           ASISTENCIA_JUSTIFICADA = CASE WHEN ASISTENCIA_ORIGEN = 'PLANEADOR' THEN ASISTENCIA_JUSTIFICADA END,
           ASISTENCIA_ORIGEN      = CASE WHEN ASISTENCIA_ORIGEN = 'PLANEADOR' THEN ASISTENCIA_ORIGEN END,
           MODIFIED_BY  = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TACTIVIDAD_NOTA = v_pk_nota;
    PERFORM academico_test.fn_actividad_validar_estado_coherente(v_pk_nota);
    RETURN v_estado;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_resultado_estado_set_bulk_interno(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad            BIGINT,
    p_estado                   VARCHAR,
    p_pk_tactividad_estudiante BIGINT[]
)
RETURNS TABLE (pk_tactividad_estudiante BIGINT, estado_resultado VARCHAR)
LANGUAGE plpgsql
AS $$
#variable_conflict use_column
DECLARE
    v_ae BIGINT;
BEGIN
    PERFORM academico_test.fn_actividad_validar_estado_resultado_asignable(p_estado);
    PERFORM academico_test.fn_actividad_validar_estudiantes_lote(p_pk_tactividad, p_pk_tactividad_estudiante);
    FOREACH v_ae IN ARRAY p_pk_tactividad_estudiante LOOP
        pk_tactividad_estudiante := v_ae;
        estado_resultado := academico_test.fn_actividad_resultado_estado_set_interno(p_pk_usuario_solicitante, v_ae, p_estado);
        RETURN NEXT;
    END LOOP;
END;
$$;

-- Regla 73: al guardar la Vista (o la oficial del Planeador), la asistencia del día que vale (fecha fin o primer día) de cada
-- actividad (fn_actividad_asistencia_dia) fija el estado de los resultados aún
-- sin registrar: No asistido según la excusa, o vuelve a Pendiente si estaba
-- No asistido. Lo cambiado en el Planeador se conserva (solo toma la excusa).
-- Nunca toca un resultado Calificado ni un No presentó.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_resultado_desde_asistencia_interno(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tgrupo              BIGINT,
    p_fk_tasignatura         BIGINT,
    p_fecha                  DATE,
    p_matriculas             BIGINT[] DEFAULT NULL
)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_r       RECORD;
    v_pk_nota BIGINT;
    v_estado  VARCHAR;
    v_actual  VARCHAR;
    v_n       INT := 0;
BEGIN
    IF p_fk_tgrupo IS NULL OR p_fecha IS NULL THEN
        RETURN 0;
    END IF;
    FOR v_r IN
        SELECT ae.PK_TACTIVIDAD_ESTUDIANTE AS pk_ae, d.ausente, d.justificada,
               (SELECT n.PK_TACTIVIDAD_NOTA FROM academico_test.TACTIVIDAD_NOTA n
                 WHERE n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                 ORDER BY n.ACTIVE DESC LIMIT 1) AS pk_nota,
               (SELECT bool_or(n.ACTIVE) FROM academico_test.TACTIVIDAD_NOTA n
                 WHERE n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE) AS nota_activa,
               (SELECT lv.VALOR FROM academico_test.TACTIVIDAD_NOTA n
                  JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = n.FK_TLV_TIPO_ASISTENCIA
                 WHERE n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE AND n.ACTIVE = TRUE
                   AND n.ASISTENCIA_ORIGEN = 'PLANEADOR') AS marca
          FROM academico_test.TACTIVIDAD a
          JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae ON ae.FK_TACTIVIDAD = a.PK_TACTIVIDAD AND ae.ACTIVE = TRUE
         CROSS JOIN LATERAL academico_test.fn_actividad_asistencia_dia(ae.FK_TMATRICULA, a.PK_TACTIVIDAD) d
         WHERE a.FK_TGRUPO = p_fk_tgrupo AND a.ACTIVE = TRUE
           AND p_fecha IN (academico_test.fn_actividad_fecha_asistencia(a.PK_TACTIVIDAD),
                           academico_test.fn_actividad_fecha_inicio_asistencia(a.PK_TACTIVIDAD))
           AND d.fecha = p_fecha
           AND (a.FK_TASIGNATURA = p_fk_tasignatura OR academico_test.fn_actividad_es_formativa(a.PK_TACTIVIDAD))
           AND (p_matriculas IS NULL OR ae.FK_TMATRICULA = ANY (p_matriculas))
    LOOP
        -- Una nota dada de baja no se reactiva: get_or_create traería su nota vieja.
        IF v_r.pk_nota IS NOT NULL AND NOT COALESCE(v_r.nota_activa, FALSE) THEN
            CONTINUE;
        END IF;
        -- Lo cambiado en el Planeador se respeta; de la Vista solo toma la excusa:
        -- un No asistió marcado ahí pasa a Justificada cuando la Vista la trae.
        IF v_r.marca IS NOT NULL THEN
            IF v_r.marca = '2' THEN
                UPDATE academico_test.TACTIVIDAD_NOTA n
                   SET ASISTENCIA_JUSTIFICADA = COALESCE(v_r.justificada, FALSE),
                       FK_TLV_ESTADO_RESULTADO = academico_test.fn_tlv_estado_resultado_pk(
                           academico_test.fn_actividad_estado_por_asistencia(TRUE, v_r.justificada)),
                       MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
                 WHERE n.PK_TACTIVIDAD_NOTA = v_r.pk_nota
                   AND academico_test.fn_actividad_estado_resultado(n.PK_TACTIVIDAD_NOTA) LIKE 'NO_ASISTIO%';
                IF FOUND THEN
                    v_n := v_n + 1;
                END IF;
            END IF;
            CONTINUE;
        END IF;
        v_estado := academico_test.fn_actividad_estado_por_asistencia(v_r.ausente, v_r.justificada);
        -- Presente y sin resultado: no hay nada que escribir.
        IF v_r.pk_nota IS NULL AND v_estado IS NULL THEN
            CONTINUE;
        END IF;
        v_pk_nota := COALESCE(v_r.pk_nota,
                              academico_test.fn_actividad_nota_get_or_create(p_pk_usuario_solicitante, v_r.pk_ae));
        v_actual := academico_test.fn_actividad_estado_resultado(v_pk_nota);
        IF v_actual IN ('CALIFICADO', 'NO_PRESENTO') THEN
            CONTINUE;
        END IF;
        UPDATE academico_test.TACTIVIDAD_NOTA n
           SET FK_TLV_ESTADO_RESULTADO = academico_test.fn_tlv_estado_resultado_pk(
                   COALESCE(v_estado, CASE WHEN v_actual LIKE 'NO_ASISTIO%' THEN 'PENDIENTE' ELSE v_actual END)),
               FK_TLV_TIPO_ASISTENCIA = NULL, ASISTENCIA_JUSTIFICADA = NULL, ASISTENCIA_ORIGEN = NULL,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE n.PK_TACTIVIDAD_NOTA = v_pk_nota
           AND n.CALIFICACION IS NULL
           AND NULLIF(TRIM(n.OBSERVACION), '') IS NULL;
        IF FOUND THEN
            v_n := v_n + 1;
        END IF;
    END LOOP;
    RETURN v_n;
END;
$$;

-- Asistencia marcada en la tabla de calificaciones del Planeador: se fija en
-- TACTIVIDAD_NOTA y nunca toca la de la Vista. Sin Vista ese día, la oficial
-- (una fila por bloque) se calcula con las marcas de todas las actividades del
-- día. J/NJ lo decide la excusa de la Vista.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_asistencia_planeador_set_interno(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad_estudiante BIGINT,
    p_tipo_asistencia          NUMERIC
)
RETURNS VARCHAR
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk       BIGINT := academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante);
    v_fk_tipo  BIGINT;
    v_ae       RECORD;
    v_dia      RECORD;
    v_fecha    DATE;
    v_periodo  BIGINT;
    v_just     BOOLEAN;
    v_estado   VARCHAR;
    v_actual   VARCHAR;
    v_pk_nota  BIGINT;
    v_oficial  BIGINT;
BEGIN
    PERFORM academico_test.fn_actividad_validar_activa(v_pk);
    PERFORM academico_test.fn_actividad_validar_referente_calificable(v_pk);
    v_fk_tipo := academico_test.fn_asistencia_validar_tipo(p_tipo_asistencia);
    PERFORM academico_test.fn_actividad_validar_asistencia_editable(p_pk_tactividad_estudiante);
    PERFORM academico_test.fn_asistencia_validar_fecha_no_futura(academico_test.fn_actividad_fecha_asistencia(v_pk));

    SELECT ae.FK_TMATRICULA, a.FK_TASIGNATURA, a.FK_TGRUPO INTO v_ae
      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
      JOIN academico_test.TACTIVIDAD a ON a.PK_TACTIVIDAD = ae.FK_TACTIVIDAD
     WHERE ae.PK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante;
    v_fecha := academico_test.fn_actividad_fecha_asistencia(v_pk);
    SELECT * INTO v_dia FROM academico_test.fn_actividad_asistencia_dia(v_ae.FK_TMATRICULA, v_pk);

    -- Llegó tarde con excusa y se cambia a No asistido: Justificada.
    v_just   := p_tipo_asistencia = 2 AND v_dia.origen = 'ASISTENCIA' AND COALESCE(v_dia.justificada, FALSE);
    v_estado := academico_test.fn_actividad_estado_por_asistencia(p_tipo_asistencia = 2, v_just);
    v_pk_nota := academico_test.fn_actividad_nota_get_or_create(p_pk_usuario_solicitante, p_pk_tactividad_estudiante);
    v_actual := academico_test.fn_actividad_estado_resultado(v_pk_nota);
    UPDATE academico_test.TACTIVIDAD_NOTA
       SET FK_TLV_TIPO_ASISTENCIA = v_fk_tipo, ASISTENCIA_JUSTIFICADA = v_just, ASISTENCIA_ORIGEN = 'PLANEADOR',
           FK_TLV_ESTADO_RESULTADO = academico_test.fn_tlv_estado_resultado_pk(
               COALESCE(v_estado, CASE WHEN v_actual LIKE 'NO_ASISTIO%' THEN 'PENDIENTE' ELSE v_actual END)),
           MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TACTIVIDAD_NOTA = v_pk_nota;

    -- Sin Vista ese día la oficial sale de todas las marcas del día: presente si
    -- asistió en alguna actividad, tarde si solo llegó tarde, ausente si faltó en todas.
    IF COALESCE(v_dia.origen, '') <> 'ASISTENCIA' THEN
        SELECT academico_test.fn_asistencia_tipo_pk(
                   CASE WHEN BOOL_OR(lv.VALOR = '1') THEN 1 WHEN BOOL_OR(lv.VALOR = '5') THEN 5 ELSE 2 END)
          INTO v_oficial
          FROM academico_test.TACTIVIDAD a
          JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
            ON ae.FK_TACTIVIDAD = a.PK_TACTIVIDAD AND ae.ACTIVE = TRUE AND ae.FK_TMATRICULA = v_ae.FK_TMATRICULA
          JOIN academico_test.TACTIVIDAD_NOTA n
            ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE AND n.ACTIVE = TRUE
           AND n.ASISTENCIA_ORIGEN = 'PLANEADOR'
          JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = n.FK_TLV_TIPO_ASISTENCIA
         WHERE a.FK_TGRUPO = v_ae.FK_TGRUPO AND a.ACTIVE = TRUE
           AND academico_test.fn_actividad_fecha_asistencia(a.PK_TACTIVIDAD) = v_fecha
           AND (a.FK_TASIGNATURA = v_ae.FK_TASIGNATURA OR academico_test.fn_actividad_es_formativa(a.PK_TACTIVIDAD));

        UPDATE academico_test.TASISTENCIA s
           SET FK_TLV_TIPO_ASISTENCIA = v_oficial,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE s.ORIGEN = 'PLANEADOR' AND s.ACTIVE = TRUE AND s.FECHA = v_fecha
           AND s.FK_TMATRICULA = v_ae.FK_TMATRICULA
           AND s.FK_TASIGNATURA IS NOT DISTINCT FROM v_ae.FK_TASIGNATURA;
        IF NOT FOUND THEN
            v_periodo := academico_test.fn_asistencia_periodo_eval(v_ae.FK_TGRUPO, v_fecha);
            IF v_periodo IS NULL THEN
                RAISE EXCEPTION 'no hay periodo de evaluacion activo para el grupo % que contenga la fecha %',
                    v_ae.FK_TGRUPO, v_fecha USING ERRCODE = '22023';
            END IF;
            INSERT INTO academico_test.TASISTENCIA (
                FECHA, FK_TLV_TIPO_ASISTENCIA, FK_TASIGNATURA, FK_TPERIODO_EVALUACION, FK_TMATRICULA,
                BLOQUE, ORIGEN, CREATED_BY, CREATED_AT, ACTIVE)
            SELECT v_fecha, v_oficial, v_ae.FK_TASIGNATURA, v_periodo, v_ae.FK_TMATRICULA,
                   b.bloque, 'PLANEADOR', p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
              FROM (SELECT bp.bloque FROM academico_test.fn_asistencia_bloques_programados(
                        p_pk_usuario_solicitante, v_ae.FK_TGRUPO, v_ae.FK_TASIGNATURA, v_fecha) bp
                    UNION ALL
                    -- Sin horario resoluble: una toma sin bloque, para no perder la asistencia.
                    SELECT NULL::NUMERIC WHERE NOT EXISTS (
                        SELECT 1 FROM academico_test.fn_asistencia_bloques_programados(
                            p_pk_usuario_solicitante, v_ae.FK_TGRUPO, v_ae.FK_TASIGNATURA, v_fecha))) b
            ON CONFLICT (FK_TMATRICULA, COALESCE(FK_TASIGNATURA, 0), COALESCE(FK_TACTIVIDAD, 0),
                         FECHA, COALESCE(BLOQUE, 0)) WHERE ACTIVE = true
            DO NOTHING;
        END IF;
        -- Es oficial: las actividades del día sin marca propia toman su estado.
        PERFORM academico_test.fn_actividad_resultado_desde_asistencia_interno(
            p_pk_usuario_solicitante, v_ae.FK_TGRUPO, v_ae.FK_TASIGNATURA, v_fecha,
            ARRAY[v_ae.FK_TMATRICULA]);
    END IF;
    RETURN academico_test.fn_actividad_estado_resultado(v_pk_nota);
END;
$$;

-- Al registrar el primer resultado se copia la asistencia vigente: desde ahí la
-- actividad no ve los cambios posteriores de TASISTENCIA.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_asistencia_congelar_interno(p_pk_tactividad_nota BIGINT)
RETURNS VOID
LANGUAGE sql
AS $$
    UPDATE academico_test.TACTIVIDAD_NOTA n
       SET FK_TLV_TIPO_ASISTENCIA = d.fk_tlv_tipo_asistencia,
           ASISTENCIA_JUSTIFICADA = d.justificada,
           ASISTENCIA_ORIGEN      = d.origen
      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
     CROSS JOIN LATERAL academico_test.fn_actividad_asistencia_dia(ae.FK_TMATRICULA, ae.FK_TACTIVIDAD) d
     WHERE n.PK_TACTIVIDAD_NOTA = p_pk_tactividad_nota
       AND ae.PK_TACTIVIDAD_ESTUDIANTE = n.FK_TACTIVIDAD_ESTUDIANTE
       AND n.FK_TLV_TIPO_ASISTENCIA IS NULL;
$$;

-- ---------------------------------------------------------------------------
-- Registro narrativo (formativo) y sus soportes
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_observar_estudiante_interno(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad_estudiante BIGINT,
    p_observacion              TEXT,
    p_fecha                    DATE,
    p_evidencias               BIGINT[],
    p_momento                  VARCHAR,
    p_enlace                   VARCHAR
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk_tactividad BIGINT := academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante);
    v_pk_nota       BIGINT;
    v_actuales      INT;
    v_enlace        VARCHAR;
    v_evidencias    INT;
BEGIN
    PERFORM academico_test.fn_actividad_validar_formativa(v_pk_tactividad);
    PERFORM academico_test.fn_actividad_validar_referente_calificable(v_pk_tactividad);
    PERFORM academico_test.fn_actividad_validar_permite_calificar(p_pk_tactividad_estudiante);
    PERFORM academico_test.fn_actividad_validar_observacion_texto(p_observacion);
    PERFORM academico_test.fn_actividad_validar_momento(p_momento);
    SELECT COUNT(*) INTO v_actuales FROM academico_test.TACTIVIDAD_SOPORTE
     WHERE FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante AND ACTIVE = TRUE AND FK_TARCHIVO IS NOT NULL;
    SELECT EVIDENCIA_ENLACE INTO v_enlace FROM academico_test.TACTIVIDAD_NOTA
     WHERE FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante AND ACTIVE = TRUE;
    PERFORM academico_test.fn_actividad_validar_evidencias_narrativas(p_evidencias, p_enlace, v_actuales, v_enlace);

    v_pk_nota := academico_test.fn_actividad_nota_get_or_create(p_pk_usuario_solicitante, p_pk_tactividad_estudiante);

    -- Texto vacío = observación sin texto (se guarda NULL), no un error.
    UPDATE academico_test.TACTIVIDAD_NOTA
       SET OBSERVACION = NULLIF(TRIM(p_observacion), ''), CALIFICACION = NULL, CALIFICABLE = 'N',
           FK_TLV_ESTADO_RESULTADO = academico_test.fn_tlv_estado_resultado_pk('CALIFICADO'),
           FK_TLV_MOMENTO = CASE WHEN p_momento IS NULL THEN FK_TLV_MOMENTO
                                 ELSE academico_test.fn_tlv_momento_registro_pk(NULLIF(TRIM(p_momento), '')) END,
           EVIDENCIA_ENLACE = CASE WHEN p_enlace IS NULL THEN EVIDENCIA_ENLACE ELSE NULLIF(TRIM(p_enlace), '') END,
           MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TACTIVIDAD_NOTA = v_pk_nota
    RETURNING EVIDENCIA_ENLACE INTO v_enlace;
    PERFORM academico_test.fn_actividad_asistencia_congelar_interno(v_pk_nota);

    v_evidencias := academico_test.fn_actividad_observacion_evidencias_set(
        p_pk_usuario_solicitante, p_pk_tactividad_estudiante, p_evidencias, p_fecha);

    -- Sin texto, ni archivos, ni enlace no es una observación; el RAISE deshace el UPDATE.
    IF NULLIF(TRIM(p_observacion), '') IS NULL AND v_enlace IS NULL
       AND COALESCE(v_evidencias, v_actuales) = 0 THEN
        RAISE EXCEPTION 'La observación necesita texto, al menos una evidencia o un enlace' USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_observar_grupal_interno(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT,
    p_observacion            TEXT,
    p_fecha                  DATE,
    p_evidencias             BIGINT[],
    p_momento                VARCHAR,
    p_enlace                 VARCHAR
)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk_ae      BIGINT;
    v_pk_nota    BIGINT;
    v_observados INT := 0;
    v_omitidos   INT := 0;
BEGIN
    PERFORM academico_test.fn_actividad_validar_formativa(p_pk_tactividad);
    PERFORM academico_test.fn_actividad_validar_referente_calificable(p_pk_tactividad);
    PERFORM academico_test.fn_actividad_validar_observacion_texto(p_observacion);
    PERFORM academico_test.fn_actividad_validar_momento(p_momento);
    PERFORM academico_test.fn_actividad_validar_evidencias_narrativas(p_evidencias, p_enlace);
    IF NULLIF(TRIM(p_observacion), '') IS NULL AND NULLIF(TRIM(p_enlace), '') IS NULL
       AND NOT EXISTS (SELECT 1 FROM unnest(p_evidencias) x WHERE x IS NOT NULL) THEN
        RAISE EXCEPTION 'La observación necesita texto, al menos una evidencia o un enlace' USING ERRCODE = '22023';
    END IF;

    SELECT COUNT(*) INTO v_omitidos FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
     WHERE ae.FK_TACTIVIDAD = p_pk_tactividad AND ae.ACTIVE = TRUE
       AND (academico_test.fn_actividad_resultado_registrado(ae.PK_TACTIVIDAD_ESTUDIANTE)
            OR NOT EXISTS (SELECT 1 FROM academico_test.fn_actividad_asistencia_estudiante(ae.PK_TACTIVIDAD_ESTUDIANTE) x
                            WHERE NOT COALESCE(x.ausente, FALSE)));
    IF v_omitidos > 0 THEN
        RAISE WARNING 'fn_actividad_observar_grupal: se omiten % estudiante(s) de % que ya tienen resultado registrado, están No asistido o no tienen asistencia; la grupal no sobrescribe',
            v_omitidos, academico_test.fn_actividad_etiqueta(p_pk_tactividad);
    END IF;

    FOR v_pk_ae IN
        SELECT ae.PK_TACTIVIDAD_ESTUDIANTE FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
         WHERE ae.FK_TACTIVIDAD = p_pk_tactividad AND ae.ACTIVE = TRUE
           AND NOT academico_test.fn_actividad_resultado_registrado(ae.PK_TACTIVIDAD_ESTUDIANTE)
           -- Solo presentes: sin asistencia o No asistido no se observan.
           AND EXISTS (SELECT 1 FROM academico_test.fn_actividad_asistencia_estudiante(ae.PK_TACTIVIDAD_ESTUDIANTE) x
                        WHERE NOT COALESCE(x.ausente, FALSE))
    LOOP
        v_pk_nota := academico_test.fn_actividad_nota_get_or_create(p_pk_usuario_solicitante, v_pk_ae);
        UPDATE academico_test.TACTIVIDAD_NOTA
           SET OBSERVACION = NULLIF(TRIM(p_observacion), ''), CALIFICACION = NULL, CALIFICABLE = 'N',
               FK_TLV_ESTADO_RESULTADO = academico_test.fn_tlv_estado_resultado_pk('CALIFICADO'),
               FK_TLV_MOMENTO = academico_test.fn_tlv_momento_registro_pk(NULLIF(TRIM(p_momento), '')),
               EVIDENCIA_ENLACE = NULLIF(TRIM(p_enlace), ''),
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TACTIVIDAD_NOTA = v_pk_nota;
        PERFORM academico_test.fn_actividad_asistencia_congelar_interno(v_pk_nota);
        -- En la grupal las evidencias son las de la sesión, las mismas para todos.
        PERFORM academico_test.fn_actividad_observacion_evidencias_set(
            p_pk_usuario_solicitante, v_pk_ae, p_evidencias, p_fecha);
        v_observados := v_observados + 1;
    END LOOP;
    RETURN v_observados;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_observacion_soporte_agregar_interno(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad_estudiante BIGINT,
    p_fk_tarchivo              BIGINT,
    p_fecha                    DATE
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk_tactividad BIGINT := academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante);
    v_pk_soporte    BIGINT;
    v_otros         INT;
BEGIN
    PERFORM academico_test.fn_actividad_validar_formativa(v_pk_tactividad);
    PERFORM academico_test.fn_actividad_validar_referente_calificable(v_pk_tactividad);
    IF p_fk_tarchivo IS NULL THEN
        RAISE EXCEPTION 'Indique el archivo de la evidencia' USING ERRCODE = '22023';
    END IF;

    SELECT PK_TACTIVIDAD_SOPORTE INTO v_pk_soporte
      FROM academico_test.TACTIVIDAD_SOPORTE
     WHERE FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante AND FK_TARCHIVO = p_fk_tarchivo AND ACTIVE = TRUE;
    IF FOUND THEN
        RETURN v_pk_soporte;              -- ya estaba adjunto: idempotente
    END IF;

    SELECT COUNT(*) INTO v_otros FROM academico_test.TACTIVIDAD_SOPORTE
     WHERE FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante AND ACTIVE = TRUE AND FK_TARCHIVO IS NOT NULL;
    PERFORM academico_test.fn_actividad_validar_evidencias_cantidad(v_otros + 1);
    PERFORM academico_test.fn_actividad_validar_evidencias_narrativas(
        ARRAY[p_fk_tarchivo], NULL, 0,
        (SELECT EVIDENCIA_ENLACE FROM academico_test.TACTIVIDAD_NOTA
          WHERE FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante AND ACTIVE = TRUE));

    -- Reactivar antes que insertar: un_tactividad_soporte_archivo es parcial
    -- sobre ACTIVE y la fila inactiva del archivo quitado sigue existiendo.
    UPDATE academico_test.TACTIVIDAD_SOPORTE
       SET ACTIVE = TRUE, FECHA = p_fecha,
           MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante AND FK_TARCHIVO = p_fk_tarchivo AND ACTIVE = FALSE
    RETURNING PK_TACTIVIDAD_SOPORTE INTO v_pk_soporte;
    IF v_pk_soporte IS NOT NULL THEN
        RETURN v_pk_soporte;
    END IF;

    INSERT INTO academico_test.TACTIVIDAD_SOPORTE (
        FK_TACTIVIDAD_ESTUDIANTE, FK_TARCHIVO, FECHA, CREATED_BY, CREATED_AT, ACTIVE)
    VALUES (p_pk_tactividad_estudiante, p_fk_tarchivo, p_fecha,
            p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE)
    RETURNING PK_TACTIVIDAD_SOPORTE INTO v_pk_soporte;
    RETURN v_pk_soporte;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_observacion_soportes_listar_interno(p_pk_tactividad_estudiante BIGINT)
RETURNS TABLE (pk_tactividad_soporte BIGINT, fk_tarchivo BIGINT, nombre VARCHAR, urls3 VARCHAR, peso BIGINT,
               etiqueta VARCHAR, fecha DATE, created_at TIMESTAMP, es_favorito BOOLEAN)
LANGUAGE sql
STABLE
AS $$
    SELECT so.PK_TACTIVIDAD_SOPORTE, so.FK_TARCHIVO, ar.NOMBRE, ar.URLS3, ar.PESO, ar.ETIQUETA,
           so.FECHA, so.CREATED_AT, so.ES_FAVORITO
      FROM academico_test.TACTIVIDAD_SOPORTE so
      JOIN academico_test.TARCHIVO ar ON ar.PK_TARCHIVO = so.FK_TARCHIVO
     WHERE so.FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante
       AND so.ACTIVE = TRUE
       AND so.FK_TARCHIVO IS NOT NULL
     ORDER BY so.PK_TACTIVIDAD_SOPORTE;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_observacion_soporte_quitar_interno(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad_soporte  BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk BIGINT := academico_test.fn_actividad_estudiante_actividad(
                       academico_test.fn_actividad_observacion_soporte_resolver(p_pk_tactividad_soporte));
BEGIN
    PERFORM academico_test.fn_actividad_validar_formativa(v_pk);
    PERFORM academico_test.fn_actividad_validar_referente_calificable(v_pk);
    UPDATE academico_test.TACTIVIDAD_SOPORTE
       SET ACTIVE = FALSE, ES_FAVORITO = FALSE,
           MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TACTIVIDAD_SOPORTE = p_pk_tactividad_soporte;
    RETURN p_pk_tactividad_soporte;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_observacion_soporte_favorito_interno(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad_soporte  BIGINT,
    p_es_favorito            BOOLEAN
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk_ae BIGINT := academico_test.fn_actividad_observacion_soporte_resolver(p_pk_tactividad_soporte);
    v_pk    BIGINT := academico_test.fn_actividad_estudiante_actividad(v_pk_ae);
BEGIN
    PERFORM academico_test.fn_actividad_validar_formativa(v_pk);
    PERFORM academico_test.fn_actividad_validar_referente_calificable(v_pk);
    -- La anterior se apaga primero: un_tactividad_soporte_favorito no admite dos.
    IF COALESCE(p_es_favorito, TRUE) THEN
        UPDATE academico_test.TACTIVIDAD_SOPORTE
           SET ES_FAVORITO = FALSE,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TACTIVIDAD_ESTUDIANTE = v_pk_ae AND ES_FAVORITO = TRUE
           AND PK_TACTIVIDAD_SOPORTE <> p_pk_tactividad_soporte;
    END IF;
    UPDATE academico_test.TACTIVIDAD_SOPORTE
       SET ES_FAVORITO = COALESCE(p_es_favorito, TRUE),
           MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TACTIVIDAD_SOPORTE = p_pk_tactividad_soporte;
    RETURN p_pk_tactividad_soporte;
END;
$$;

-- ---------------------------------------------------------------------------
-- Lecturas de resultados
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_numero_corto(p_valor NUMERIC)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE
               WHEN p_valor IS NULL THEN NULL
               WHEN STRPOS(p_valor::TEXT, '.') = 0 THEN p_valor::TEXT
               ELSE TRIM(TRAILING '.' FROM TRIM(TRAILING '0' FROM p_valor::TEXT))
           END;
$$;

COMMENT ON FUNCTION academico_test.fn_numero_corto(NUMERIC)
    IS 'Representacion corta de un numero para textos de UI: quita los ceros de relleno y el punto que queda suelto (3.00 -> 3, 3.50 -> 3.5). Nucleo puro sin permisos. V477.';

DROP FUNCTION IF EXISTS academico_test.fn_instrumento_base_derivar(NUMERIC[]);

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_resultado_instrumento(
    p_pk_tactividad_estudiante BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_pk_tactividad BIGINT;
    v_tipo          VARCHAR;
    v_pct           NUMERIC;
    v_res           JSONB;
BEGIN
    SELECT ae.FK_TACTIVIDAD, academico_test.fn_actividad_instrumento_efectivo(ae.FK_TACTIVIDAD)
      INTO v_pk_tactividad, v_tipo
      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
     WHERE ae.PK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    -- CALIFICACION y no DEFINITIVA: la definitiva ya incorpora recuperacion y
    -- los topes del criterio, y el instrumento describe lo que se marco.
    SELECT n.CALIFICACION INTO v_pct
      FROM academico_test.TACTIVIDAD_NOTA n
     WHERE n.FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante AND n.ACTIVE = TRUE
     LIMIT 1;

    CASE v_tipo
        WHEN 'RUBRICA' THEN
            -- Regla 42: valor = puntaje del nivel elegido; base = nivel mas alto
            -- del criterio; la actividad suma valores sobre la suma de bases.
            WITH marcado AS (
                SELECT c.PK_TACTIVIDAD_RUBRICA_CRITERIO AS pk_criterio, c.NOMBRE AS criterio, c.ORDEN AS orden,
                       n.PK_TACTIVIDAD_RUBRICA_NIVEL AS pk_nivel, COALESCE(n.ETIQUETA, n.DESCRIPCION) AS nivel,
                       re.PONDERACION AS valor,
                       (SELECT MAX(nl.PONDERACION) FROM academico_test.TACTIVIDAD_RUBRICA_NIVEL nl
                         WHERE nl.FK_TACTIVIDAD_RUBRICA_CRITERIO = c.PK_TACTIVIDAD_RUBRICA_CRITERIO AND nl.ACTIVE = TRUE) AS base
                  FROM academico_test.TACTIVIDAD_RUBRICA_EVALUACION re
                  JOIN academico_test.TACTIVIDAD_RUBRICA_CRITERIO c
                    ON c.PK_TACTIVIDAD_RUBRICA_CRITERIO = re.FK_TACTIVIDAD_RUBRICA_CRITERIO
                  LEFT JOIN academico_test.TACTIVIDAD_RUBRICA_NIVEL n ON n.PK_TACTIVIDAD_RUBRICA_NIVEL = re.FK_TACTIVIDAD_RUBRICA_NIVEL
                 WHERE re.FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante AND re.ACTIVE = TRUE
                   AND c.FK_TACTIVIDAD = v_pk_tactividad AND c.ACTIVE = TRUE
            )
            SELECT jsonb_build_object(
                       'tipo', 'RUBRICA',
                       'resumen', string_agg(m.criterio || ': ' || COALESCE(m.nivel, '-') || ' ('
                                             || academico_test.fn_numero_corto(m.valor) || ' / '
                                             || academico_test.fn_numero_corto(m.base) || ')', ' · ' ORDER BY m.orden),
                       'porcentaje', v_pct,
                       'valor', SUM(m.valor),
                       'base',  SUM(m.base),
                       'detalle', jsonb_agg(jsonb_build_object(
                                      'pkCriterio', m.pk_criterio, 'criterio', m.criterio,
                                      'pkNivel', m.pk_nivel, 'nivel', m.nivel,
                                      'ponderacion', m.valor, 'base', m.base, 'valor', m.valor) ORDER BY m.orden))
              INTO v_res
              FROM marcado m
            HAVING COUNT(*) > 0;

        WHEN 'LISTA_COTEJO' THEN
            -- Puntos de los elementos cumplidos sobre el total posible (sin
            -- puntaje pesa 1), mas el conteo de elementos.
            SELECT jsonb_build_object(
                       'tipo', 'LISTA_COTEJO',
                       'resumen', academico_test.fn_numero_corto(SUM(COALESCE(i.PONDERACION, 1)) FILTER (WHERE ce.CUMPLIDO = 'S'))
                                  || ' / ' || academico_test.fn_numero_corto(SUM(COALESCE(i.PONDERACION, 1)))
                                  || ' (' || COUNT(*) FILTER (WHERE ce.CUMPLIDO = 'S') || '/' || COUNT(*) || ' elementos)',
                       'cumplidos', COUNT(*) FILTER (WHERE ce.CUMPLIDO = 'S'),
                       'total', COUNT(*),
                       'valor', COALESCE(SUM(COALESCE(i.PONDERACION, 1)) FILTER (WHERE ce.CUMPLIDO = 'S'), 0),
                       'base',  SUM(COALESCE(i.PONDERACION, 1)),
                       'porcentaje', v_pct,
                       'detalle', jsonb_agg(jsonb_build_object(
                                      'pkItem', i.PK_TACTIVIDAD_COTEJO_ITEM, 'item', i.DESCRIPCION,
                                      'puntaje', COALESCE(i.PONDERACION, 1),
                                      'cumplido', COALESCE(ce.CUMPLIDO, 'N') = 'S') ORDER BY i.ORDEN))
              INTO v_res
              FROM academico_test.TACTIVIDAD_COTEJO_ITEM i
              LEFT JOIN academico_test.TACTIVIDAD_COTEJO_EVALUACION ce
                     ON ce.FK_TACTIVIDAD_COTEJO_ITEM = i.PK_TACTIVIDAD_COTEJO_ITEM
                    AND ce.FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante AND ce.ACTIVE = TRUE
             WHERE i.FK_TACTIVIDAD = v_pk_tactividad AND i.ACTIVE = TRUE
            HAVING COUNT(ce.PK_TACTIVIDAD_COTEJO_EVAL) > 0;

        WHEN 'ESCALA_VALORACION' THEN
            -- Cualitativa: puntaje del nivel sobre el nivel mas alto; numerica:
            -- valor sobre el maximo declarado. Con varios criterios, uno por cada uno.
            WITH marcado AS (
                SELECT ce.CRITERIO_INDEX AS idx, ce.FK_TACTIVIDAD_ESCALA_NIVEL AS pk_nivel, ce.VALOR AS valor, e.PK_TACTIVIDAD_ESCALA AS escala
                  FROM academico_test.TACTIVIDAD_ESCALA_CRITERIO_EVALUACION ce
                  JOIN academico_test.TACTIVIDAD_ESCALA e ON e.PK_TACTIVIDAD_ESCALA = ce.FK_TACTIVIDAD_ESCALA
                 WHERE ce.FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante AND ce.ACTIVE = TRUE
                   AND e.FK_TACTIVIDAD = v_pk_tactividad
                UNION ALL
                SELECT NULL, ee.FK_TACTIVIDAD_ESCALA_NIVEL, ee.VALOR, e.PK_TACTIVIDAD_ESCALA
                  FROM academico_test.TACTIVIDAD_ESCALA_EVALUACION ee
                  JOIN academico_test.TACTIVIDAD_ESCALA e ON e.PK_TACTIVIDAD_ESCALA = ee.FK_TACTIVIDAD_ESCALA
                 WHERE ee.FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante AND ee.ACTIVE = TRUE
                   AND e.FK_TACTIVIDAD = v_pk_tactividad
                   AND NOT EXISTS (SELECT 1 FROM academico_test.TACTIVIDAD_ESCALA_CRITERIO_EVALUACION x
                                    WHERE x.FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante AND x.ACTIVE = TRUE)
            ), con_base AS (
                SELECT m.*, COALESCE(n.ETIQUETA, n.DESCRIPCION) AS nivel,
                       NULLIF(TRIM(split_part(e.CRITERIOS_GENERALES, ',', COALESCE(m.idx, 0) + 1)), '') AS criterio,
                       CASE WHEN m.pk_nivel IS NOT NULL
                            THEN (SELECT MAX(nl.PONDERACION) FROM academico_test.TACTIVIDAD_ESCALA_NIVEL nl
                                   WHERE nl.FK_TACTIVIDAD_ESCALA = m.escala AND nl.ACTIVE = TRUE)
                            ELSE e.VALOR_MAX END AS base,
                       e.VALOR_MIN, e.VALOR_MAX, COUNT(*) OVER () AS n
                  FROM marcado m
                  JOIN academico_test.TACTIVIDAD_ESCALA e ON e.PK_TACTIVIDAD_ESCALA = m.escala
                  LEFT JOIN academico_test.TACTIVIDAD_ESCALA_NIVEL n ON n.PK_TACTIVIDAD_ESCALA_NIVEL = m.pk_nivel
            )
            SELECT jsonb_build_object(
                       'tipo', CASE WHEN bool_or(cb.pk_nivel IS NOT NULL) THEN 'ESCALA_CUALITATIVA' ELSE 'ESCALA_NUMERICA' END,
                       'resumen', string_agg(CASE WHEN cb.n > 1 AND cb.criterio IS NOT NULL THEN cb.criterio || ': ' ELSE '' END
                                             || COALESCE(cb.nivel || ' (', '') || academico_test.fn_numero_corto(cb.valor)
                                             || ' / ' || academico_test.fn_numero_corto(cb.base) || CASE WHEN cb.nivel IS NOT NULL THEN ')' ELSE '' END,
                                             ' · ' ORDER BY cb.idx),
                       'pkNivel', MIN(cb.pk_nivel), 'nivel', MIN(cb.nivel),
                       'valor', SUM(cb.valor), 'base', SUM(cb.base),
                       'valorMin', MIN(cb.VALOR_MIN), 'valorMax', MIN(cb.VALOR_MAX),
                       'porcentaje', v_pct,
                       'detalle', jsonb_agg(jsonb_build_object('criterioIndex', cb.idx, 'criterio', cb.criterio,
                                      'pkNivel', cb.pk_nivel, 'nivel', cb.nivel, 'valor', cb.valor, 'base', cb.base) ORDER BY cb.idx))
              INTO v_res
              FROM con_base cb
            HAVING COUNT(*) > 0;

        ELSE
            SELECT jsonb_build_object('tipo', 'OTRO',
                                      'resumen', academico_test.fn_numero_corto(n.CALIFICACION) || ' %',
                                      'porcentaje', n.CALIFICACION,
                                      -- Sin estructura el porcentaje ES la nota, sobre 100.
                                      'base', 100,
                                      'valor', n.CALIFICACION)
              INTO v_res
              FROM academico_test.TACTIVIDAD_NOTA n
             WHERE n.FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante
               AND n.ACTIVE = TRUE AND n.CALIFICACION IS NOT NULL;
    END CASE;

    RETURN v_res;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_nota_resultado_instrumento(BIGINT)
    IS 'Resultado que el docente marcó en el instrumento, con etiquetas y en el formato del instrumento: {tipo, resumen, valor, base, porcentaje, detalle}. Regla 42: rúbrica = puntajes elegidos sobre la suma de los niveles más altos de cada criterio; lista de cotejo = puntos cumplidos sobre el total posible; escala = puntaje del nivel sobre el más alto, o valor sobre el máximo, por criterio. El porcentaje se lee de TACTIVIDAD_NOTA.CALIFICACION. NULL si no hay captura. Sin permisos: helper de lectura de listados ya gateados.';

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
               valoracion VARCHAR, formato_valor VARCHAR, resultado_instrumento JSONB,
               estado_resultado VARCHAR, momento VARCHAR, evidencia_enlace VARCHAR, resultados_completos BOOLEAN,
               tipo_asistencia_valor VARCHAR, asistencia_justificada BOOLEAN, origen_asistencia VARCHAR,
               asistencia_editable BOOLEAN)
LANGUAGE sql
STABLE
AS $$
    WITH act AS (
        SELECT a.PK_TACTIVIDAD, a.FK_TASIGNATURA, lv.VALOR AS instrumento,
               academico_test.fn_actividad_es_formativa(a.PK_TACTIVIDAD) AS formativa,
               academico_test.fn_actividad_grado_resolver(a.PK_TACTIVIDAD) AS grado,
               academico_test.fn_actividad_resultados_completos(a.PK_TACTIVIDAD) AS completos
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
           s.pk_tasistencia, s.fk_tlv_tipo_asistencia, lva.NOMBRE::VARCHAR, s.observacion, s.fk_soporte_archivo,
           n.CALIFICACION, n.CALIFICABLE, n.OBSERVACION, act.formativa,
           s.fecha,
           h.nota_homologada, h.valoracion_nombre, h.formato_valor,
           academico_test.fn_actividad_nota_resultado_instrumento(b.PK_TACTIVIDAD_ESTUDIANTE),
           COALESCE(lve.VALOR, CASE WHEN n.CALIFICACION IS NOT NULL THEN 'CALIFICADO' ELSE 'PENDIENTE' END)::VARCHAR,
           lvm.VALOR::VARCHAR, n.EVIDENCIA_ENLACE, act.completos,
           s.tipo_valor, s.justificada, s.origen,
           NOT COALESCE(n.CALIFICACION IS NOT NULL OR lve.VALOR = 'CALIFICADO', FALSE)
      FROM base b
     CROSS JOIN act
      -- Asistencia de la actividad (primer día, todos los bloques; congelada con resultado).
      LEFT JOIN LATERAL academico_test.fn_actividad_asistencia_estudiante(b.PK_TACTIVIDAD_ESTUDIANTE) s ON TRUE
      LEFT JOIN academico_test.TLISTA_VALOR lva ON lva.PK_LISTA_VALOR = s.fk_tlv_tipo_asistencia
      LEFT JOIN academico_test.TACTIVIDAD_NOTA n ON n.FK_TACTIVIDAD_ESTUDIANTE = b.PK_TACTIVIDAD_ESTUDIANTE AND n.ACTIVE = TRUE
      LEFT JOIN academico_test.TLISTA_VALOR lve ON lve.PK_LISTA_VALOR = n.FK_TLV_ESTADO_RESULTADO
      LEFT JOIN academico_test.TLISTA_VALOR lvm ON lvm.PK_LISTA_VALOR = n.FK_TLV_MOMENTO
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
    IS 'INTERNO: decide cómo guardar la nota de un estudiante (porcentaje 0-100). Si es una corrección con el periodo de evaluación ya no calificable lanza PA055 con el porcentaje en DETAIL, para que quien capturó revierta la captura y abra la solicitud (Reglas 55 y 70); si no, la escribe con fn_actividad_nota_aplicar_interno. Con academico_test.aprobacion_en_curso = on (aprobación) escribe directo. Lo usan todos los _interno de calificación, individuales y en bloque.';
COMMENT ON FUNCTION academico_test.fn_actividad_nota_previsualizar_interno(BIGINT, BIGINT, JSONB, DATE)
    IS 'INTERNO: porcentaje y nota homologada que dejaría fn_actividad_nota_calificar_interno con esa captura (validaciones, Regla 42, piso y tope incluidos), sin guardar nada ni abrir solicitud: captura con aprobacion_en_curso y revierte. Lo usa fn_actividad_nota_previsualizar.';
COMMENT ON FUNCTION academico_test.fn_actividad_nota_calificar_interno(BIGINT, BIGINT, JSONB, DATE)
    IS 'INTERNO: valida la calificación (fn_actividad_validar_calificacion) y la despacha según el instrumento efectivo: {niveles}, {itemsMarcados}, {pkNivel|valorNumerico} o {criterios}, {porcentaje}. Si la corrección exige aprobación (PA055) revierte la captura, abre la solicitud con fn_actividad_resultado_correccion_diferir_interno y devuelve la nota vigente. Lo usan fn_actividad_nota_calificar y la aprobación de una corrección.';
COMMENT ON FUNCTION academico_test.fn_actividad_nota_obtener_interno(BIGINT)
    IS 'INTERNO: detalle de la nota de un estudiante (instrumento, %, captura cruda, soportes, homologación y resultado con etiquetas). Lo usa fn_actividad_nota_obtener.';
COMMENT ON FUNCTION academico_test.fn_actividad_estudiantes_calificaciones_listar_interno(BIGINT, DATE, VARCHAR)
    IS 'INTERNO: estudiantes de la actividad con la asistencia de la actividad (fn_actividad_asistencia_estudiante: fecha fin o primer día, bloques agregados, la Vista predomina, congelada con resultado; tipo_asistencia_valor 1/2/5, asistencia_justificada, origen_asistencia ASISTENCIA/PLANEADOR, asistencia_editable = sin resultado registrado), nota, homologación, resultado del instrumento, estado de resultado, momento, enlace de evidencia y resultados_completos (Regla 58, igual en todas las filas). Lo usa fn_actividad_estudiantes_calificaciones_listar.';
COMMENT ON FUNCTION academico_test.fn_actividad_resultado_estado_set_interno(BIGINT, BIGINT, VARCHAR)
    IS 'INTERNO: fija el estado de resultado a mano (PENDIENTE o NO_PRESENTO; No asistido sale de la asistencia) de un estudiante y borra su CALIFICACION (Regla 62); No presentó exige que no haya nota ni inasistencia (fn_actividad_validar_estado_transicion). Lo usan fn_actividad_resultado_estado_set y su variante en bloque.';
COMMENT ON FUNCTION academico_test.fn_actividad_resultado_estado_set_bulk_interno(BIGINT, BIGINT, VARCHAR, BIGINT[])
    IS 'INTERNO: el mismo estado para varios estudiantes de una actividad, uno por uno con fn_actividad_resultado_estado_set_interno. Lo usa fn_actividad_resultado_estado_set_bulk.';
COMMENT ON FUNCTION academico_test.fn_actividad_resultado_desde_asistencia_interno(BIGINT, BIGINT, BIGINT, DATE, BIGINT[])
    IS 'INTERNO: Regla 73. Tras guardar la Vista Asistencias o la asistencia oficial que calcula el Planeador, para las actividades del grupo cuyo primer día o fecha fin es p_fecha y es el día que vale para el estudiante (de la asignatura, o formativas): ausente => No asistido (Justificada si algún bloque trae excusa), presente => vuelve a Pendiente si estaba No asistido. Conserva lo cambiado en el Planeador: de la Vista solo toma la excusa (un No asistió marcado ahí pasa a Justificada cuando la Vista la trae). No toca resultados Calificados ni No presentó. Devuelve cuántos cambió. La usan fn_asistencia_registrar_bulk_interno, fn_asistencia_editar_interno y fn_actividad_asistencia_planeador_set_interno.';
COMMENT ON FUNCTION academico_test.fn_actividad_asistencia_planeador_set_interno(BIGINT, BIGINT, NUMERIC)
    IS 'INTERNO: asistencia (1/2/5) de un estudiante marcada desde el Planeador. La fija en TACTIVIDAD_NOTA (ASISTENCIA_ORIGEN PLANEADOR) y recalcula el estado: No asistido Justificada solo si la Vista trae excusa ese día, si no No justificada; Asistió/Llegó tarde devuelve a Pendiente un No asistido. Nunca cambia la asistencia de la Vista; si ese día no se tomó, recalcula la oficial (ORIGEN PLANEADOR, una fila por bloque de fn_asistencia_bloques_programados) con las marcas de todas las actividades del día: presente si asistió en alguna, tarde si solo llegó tarde, ausente si faltó en todas; y sincroniza las actividades sin marca propia. La Vista, al guardarse, la reemplaza. 22023 si el estudiante ya tiene resultado o la actividad aún no empieza. Lo usa fn_actividad_asistencia_planeador_set.';
COMMENT ON FUNCTION academico_test.fn_actividad_asistencia_congelar_interno(BIGINT)
    IS 'INTERNO: copia en TACTIVIDAD_NOTA la asistencia vigente (fn_actividad_asistencia_dia: fecha fin o primer día) si aún no tiene una fijada. La llaman al registrar resultado fn_actividad_nota_aplicar_interno y las observaciones.';
COMMENT ON FUNCTION academico_test.fn_actividad_observar_estudiante_interno(BIGINT, BIGINT, TEXT, DATE, BIGINT[], VARCHAR, VARCHAR)
    IS 'INTERNO: observación de UN estudiante en una actividad formativa: texto ≤1000, Momento (MOMENTO_REGISTRO), hasta 3 archivos o un enlace (Regla 61); marca Calificado. NULL en momento/evidencias/enlace = no tocar. Lo usa fn_actividad_observar_estudiante.';
COMMENT ON FUNCTION academico_test.fn_actividad_observar_grupal_interno(BIGINT, BIGINT, TEXT, DATE, BIGINT[], VARCHAR, VARCHAR)
    IS 'INTERNO: la misma observación para los estudiantes de una actividad formativa que siguen Pendientes, sin observación y presentes (con asistencia y no ausentes); los demás se omiten con WARNING. Devuelve cuántos observó. Lo usa fn_actividad_observar_grupal.';
COMMENT ON FUNCTION academico_test.fn_actividad_observacion_soportes_listar_interno(BIGINT)
    IS 'INTERNO: archivos activos adjuntos a la observación de un estudiante, con los datos de TARCHIVO. Lo usa fn_actividad_observacion_soportes_listar.';
COMMENT ON FUNCTION academico_test.fn_actividad_observacion_soporte_agregar_interno(BIGINT, BIGINT, BIGINT, DATE)
    IS 'INTERNO: adjunta UN archivo a la observación (idempotente, reactiva si estaba de baja) dentro de los límites de la Regla 61. Lo usa fn_actividad_observacion_soporte_agregar.';
COMMENT ON FUNCTION academico_test.fn_actividad_observacion_soporte_quitar_interno(BIGINT, BIGINT)
    IS 'INTERNO: baja lógica de un soporte de observación de una actividad formativa con referente activo (desmarca favorito). Lo usa fn_actividad_observacion_soporte_quitar.';
COMMENT ON FUNCTION academico_test.fn_actividad_observacion_soporte_favorito_interno(BIGINT, BIGINT, BOOLEAN)
    IS 'INTERNO: marca o desmarca la evidencia favorita (a lo sumo una por estudiante) de una actividad formativa con referente activo. P0002 si el soporte no existe o fue retirado. Lo usa fn_actividad_observacion_soporte_favorito.';
COMMENT ON FUNCTION academico_test.fn_actividad_nota_calificar_escala_criterios_interno(BIGINT, BIGINT, JSONB)
    IS 'INTERNO: califica la escala de valoración criterio a criterio ({criterioIndex, pkNivel|valorNumerico}) y guarda la nota como Σ valores obtenidos / Σ máximos de cada criterio (Regla 56): el máximo de un criterio por nivel es el nivel más alto de la escala; el de uno numérico, VALOR_MAX. Pasa por piso/tope y por fn_actividad_nota_guardar_interno. La usan fn_actividad_nota_calificar_interno y el calificar en bloque de escala.';
