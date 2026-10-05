-- V496.5 - Instrumentos, calificación y resultados de actividades:
-- validaciones (una por regla), los validadores centrales de definición y de
-- calificación, el assert de propiedad de resultados (Regla 54) y las reglas
-- del registro narrativo (Regla 61). Crea los catálogos ESTADO_RESULTADO y
-- MOMENTO_REGISTRO y el estado, momento y enlace de TACTIVIDAD_NOTA (Reglas
-- 58 y 62), y el redondeo institucional de la nota (Regla 30). La
-- asistencia de la actividad (fecha fin si ya llegó y se tomó, si no primer día; congelada al calificar) decide el
-- No asistido; No asistido y No presentó bloquean calificar y observar.
-- Depende de: V496.1 (etiquetas, validar_existente/activa, catálogo,
-- archivos, URL), V479, V458, V226, V475 (es_formativa), V461 (soportes),
-- V450 (fn_actividad_asistencia_dia).

SET search_path TO academico_test, public;

DROP FUNCTION IF EXISTS academico_test.fn_actividad_instrumento_assert(BIGINT, VARCHAR);
DROP FUNCTION IF EXISTS academico_test.fn_actividad_nota_asistencia_assert(BIGINT, DATE);
-- Reglas 62/73: la reemplaza fn_actividad_validar_permite_calificar, por estado.
DROP FUNCTION IF EXISTS academico_test.fn_actividad_validar_asistencia_calificar(BIGINT, DATE);
DROP FUNCTION IF EXISTS academico_test.fn_actividad_observacion_validar_formativa(BIGINT);
DROP FUNCTION IF EXISTS academico_test.fn_actividad_validar_evidencia_archivo(BIGINT);
-- Agregan p_requiere_puntaje: el 2-arg queda reemplazado, no sobrecargado.
DROP FUNCTION IF EXISTS academico_test.fn_actividad_validar_rubrica_definicion(JSONB, VARCHAR);
DROP FUNCTION IF EXISTS academico_test.fn_actividad_validar_cotejo_definicion(JSONB, VARCHAR);

-- Regla confirmada por negocio: el puntaje de cada nivel de un criterio de rúbrica (Bloque 5)
-- pasa a ser opcional (pesa 1, igual que un elemento sin puntaje de la lista de cotejo,
-- TACTIVIDAD_COTEJO_ITEM.PONDERACION) cuando la Unidad vinculada no exige puntaje (calcula por
-- Promedio simple, o la actividad no tiene unidad). Con niveles sin puntaje explícito, dos
-- niveles del mismo criterio pueden "empatar" en el peso por defecto (1): la UNIQUE que asumía
-- puntaje siempre obligatorio y distinto ya no es válida en general; la distinción de puntajes
-- cuando SÍ es obligatorio (Ponderar/Sumatoria) la arbitra fn_actividad_validar_rubrica_definicion.
ALTER TABLE academico_test.TACTIVIDAD_RUBRICA_NIVEL DROP CONSTRAINT IF EXISTS UN_TAC_RUBRICA_NIVEL_1;

-- ---------------------------------------------------------------------------
-- Estados de resultado y momento del registro narrativo (Reglas 58, 61, 62)
-- ---------------------------------------------------------------------------
SELECT setval(pg_get_serial_sequence('academico_test.tlista_valor', 'pk_lista_valor'),
              GREATEST((SELECT COALESCE(MAX(PK_LISTA_VALOR), 0) FROM academico_test.TLISTA_VALOR), 1));

INSERT INTO academico_test.TLISTA_VALOR (CATEGORIA, NOMBRE, VALOR, CREATED_BY)
SELECT v.categoria, v.nombre, v.valor, 'seed_estado_resultado'
  FROM (VALUES
    ('ESTADO_RESULTADO', 'Calificado', 'CALIFICADO'),
    ('ESTADO_RESULTADO', 'Pendiente de calificar', 'PENDIENTE'),
    ('ESTADO_RESULTADO', 'No presentó', 'NO_PRESENTO'),
    ('ESTADO_RESULTADO', 'No asistido - Justificada', 'NO_ASISTIO_JUSTIFICADA'),
    ('ESTADO_RESULTADO', 'No asistido - No justificada', 'NO_ASISTIO_NO_JUSTIFICADA'),
    ('MOMENTO_REGISTRO', 'Inicio', 'INICIO'),
    ('MOMENTO_REGISTRO', 'Proceso', 'PROCESO'),
    ('MOMENTO_REGISTRO', 'Cierre', 'CIERRE')
  ) AS v(categoria, nombre, valor)
 WHERE NOT EXISTS (SELECT 1 FROM academico_test.TLISTA_VALOR lv
                    WHERE lv.CATEGORIA = v.categoria AND lv.VALOR = v.valor);

ALTER TABLE academico_test.TACTIVIDAD_NOTA ADD COLUMN IF NOT EXISTS FK_TLV_ESTADO_RESULTADO BIGINT;
ALTER TABLE academico_test.TACTIVIDAD_NOTA ADD COLUMN IF NOT EXISTS FK_TLV_MOMENTO BIGINT;
ALTER TABLE academico_test.TACTIVIDAD_NOTA ADD COLUMN IF NOT EXISTS EVIDENCIA_ENLACE VARCHAR(1000);
ALTER TABLE academico_test.TACTIVIDAD_NOTA ADD COLUMN IF NOT EXISTS FK_TLV_TIPO_ASISTENCIA BIGINT;
ALTER TABLE academico_test.TACTIVIDAD_NOTA ADD COLUMN IF NOT EXISTS ASISTENCIA_JUSTIFICADA BOOLEAN;
ALTER TABLE academico_test.TACTIVIDAD_NOTA ADD COLUMN IF NOT EXISTS ASISTENCIA_ORIGEN VARCHAR(20);

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_tactividad_nota_estado_resultado') THEN
        ALTER TABLE academico_test.TACTIVIDAD_NOTA ADD CONSTRAINT fk_tactividad_nota_estado_resultado
            FOREIGN KEY (FK_TLV_ESTADO_RESULTADO) REFERENCES academico_test.TLISTA_VALOR (PK_LISTA_VALOR);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_tactividad_nota_momento') THEN
        ALTER TABLE academico_test.TACTIVIDAD_NOTA ADD CONSTRAINT fk_tactividad_nota_momento
            FOREIGN KEY (FK_TLV_MOMENTO) REFERENCES academico_test.TLISTA_VALOR (PK_LISTA_VALOR);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_tactividad_nota_tipo_asistencia') THEN
        ALTER TABLE academico_test.TACTIVIDAD_NOTA ADD CONSTRAINT fk_tactividad_nota_tipo_asistencia
            FOREIGN KEY (FK_TLV_TIPO_ASISTENCIA) REFERENCES academico_test.TLISTA_VALOR (PK_LISTA_VALOR);
    END IF;
END;
$$;

COMMENT ON COLUMN academico_test.TACTIVIDAD_NOTA.FK_TLV_ESTADO_RESULTADO
    IS 'Regla 62: TLISTA_VALOR ESTADO_RESULTADO. Solo CALIFICADO lleva CALIFICACION; los demás la dejan NULL (fn_actividad_validar_estado_coherente).';
COMMENT ON COLUMN academico_test.TACTIVIDAD_NOTA.FK_TLV_MOMENTO
    IS 'Momento del registro narrativo (TLISTA_VALOR MOMENTO_REGISTRO: Inicio, Proceso, Cierre).';
COMMENT ON COLUMN academico_test.TACTIVIDAD_NOTA.FK_TLV_TIPO_ASISTENCIA
    IS 'Asistencia de la actividad fijada para este estudiante (TIPO_ASISTENCIA 1/2/5): la marcada en el Planeador o la copia congelada al registrar el primer resultado. NULL = vale la tomada ese día (fn_actividad_asistencia_dia). Nunca cambia TASISTENCIA de la Vista.';
COMMENT ON COLUMN academico_test.TACTIVIDAD_NOTA.ASISTENCIA_JUSTIFICADA
    IS 'Con FK_TLV_TIPO_ASISTENCIA: TRUE si la inasistencia tiene excusa (archivo en algún bloque de la Vista). El docente nunca la elige.';
COMMENT ON COLUMN academico_test.TACTIVIDAD_NOTA.ASISTENCIA_ORIGEN
    IS 'Con FK_TLV_TIPO_ASISTENCIA: PLANEADOR si la marcó el docente en la tabla de calificaciones; ASISTENCIA si es la copia congelada de la Vista.';
COMMENT ON COLUMN academico_test.TACTIVIDAD_NOTA.EVIDENCIA_ENLACE
    IS 'Regla 61: enlace externo de la evidencia narrativa, alternativo a los hasta 3 archivos de TACTIVIDAD_SOPORTE.';

CREATE OR REPLACE FUNCTION academico_test.fn_tlv_estado_resultado_pk(p_valor TEXT)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT PK_LISTA_VALOR FROM academico_test.TLISTA_VALOR
     WHERE CATEGORIA = 'ESTADO_RESULTADO' AND VALOR = upper(TRIM(p_valor)) AND ACTIVE = TRUE
     LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_tlv_momento_registro_pk(p_valor TEXT)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT PK_LISTA_VALOR FROM academico_test.TLISTA_VALOR
     WHERE CATEGORIA = 'MOMENTO_REGISTRO' AND VALOR = upper(TRIM(p_valor)) AND ACTIVE = TRUE
     LIMIT 1;
$$;

-- Backfill: una nota capturada, o el texto/evidencias de una formativa, es un resultado.
UPDATE academico_test.TACTIVIDAD_NOTA n
   SET FK_TLV_ESTADO_RESULTADO = academico_test.fn_tlv_estado_resultado_pk(
           CASE WHEN n.CALIFICACION IS NOT NULL
                  OR (n.CALIFICABLE = 'N' AND (NULLIF(TRIM(n.OBSERVACION), '') IS NOT NULL
                       OR EXISTS (SELECT 1 FROM academico_test.TACTIVIDAD_SOPORTE so
                                   WHERE so.FK_TACTIVIDAD_ESTUDIANTE = n.FK_TACTIVIDAD_ESTUDIANTE
                                     AND so.ACTIVE = TRUE AND so.FK_TARCHIVO IS NOT NULL)))
                THEN 'CALIFICADO' ELSE 'PENDIENTE' END)
 WHERE n.FK_TLV_ESTADO_RESULTADO IS NULL;

CREATE OR REPLACE FUNCTION academico_test.fn_tactividad_nota_estado_default()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    -- El pk del catálogo difiere entre ambientes: no cabe en un DEFAULT de columna.
    IF NEW.FK_TLV_ESTADO_RESULTADO IS NULL THEN
        NEW.FK_TLV_ESTADO_RESULTADO := academico_test.fn_tlv_estado_resultado_pk(
            CASE WHEN NEW.CALIFICACION IS NOT NULL THEN 'CALIFICADO' ELSE 'PENDIENTE' END);
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_tactividad_nota_estado_default ON academico_test.TACTIVIDAD_NOTA;
CREATE TRIGGER trg_tactividad_nota_estado_default
    BEFORE INSERT ON academico_test.TACTIVIDAD_NOTA
    FOR EACH ROW EXECUTE FUNCTION academico_test.fn_tactividad_nota_estado_default();

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_estado_resultado(p_pk_tactividad_nota BIGINT)
RETURNS VARCHAR
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(lv.VALOR, CASE WHEN n.CALIFICACION IS NOT NULL THEN 'CALIFICADO' ELSE 'PENDIENTE' END)::VARCHAR
      FROM academico_test.TACTIVIDAD_NOTA n
      LEFT JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = n.FK_TLV_ESTADO_RESULTADO
     WHERE n.PK_TACTIVIDAD_NOTA = p_pk_tactividad_nota;
$$;

-- Asistencia de la actividad para un estudiante: la fijada en su resultado
-- (marcada en el Planeador o congelada al calificar) o la tomada ese día.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_asistencia_estudiante(p_pk_tactividad_estudiante BIGINT)
RETURNS TABLE (fecha DATE, tipo_valor VARCHAR, fk_tlv_tipo_asistencia BIGINT, ausente BOOLEAN,
               justificada BOOLEAN, origen VARCHAR, pk_tasistencia BIGINT, fk_soporte_archivo BIGINT,
               observacion VARCHAR)
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(d.fecha, academico_test.fn_actividad_fecha_asistencia(ae.FK_TACTIVIDAD)),
           COALESCE(lv.VALOR, d.tipo_valor)::VARCHAR,
           COALESCE(n.FK_TLV_TIPO_ASISTENCIA, d.fk_tlv_tipo_asistencia),
           CASE WHEN n.FK_TLV_TIPO_ASISTENCIA IS NOT NULL THEN lv.VALOR = '2' ELSE d.ausente END,
           CASE WHEN n.FK_TLV_TIPO_ASISTENCIA IS NOT NULL THEN COALESCE(n.ASISTENCIA_JUSTIFICADA, FALSE) ELSE d.justificada END,
           COALESCE(n.ASISTENCIA_ORIGEN, d.origen)::VARCHAR,
           d.pk_tasistencia, d.fk_soporte_archivo, d.observacion
      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
      LEFT JOIN academico_test.TACTIVIDAD_NOTA n
             ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE AND n.ACTIVE = TRUE
      LEFT JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = n.FK_TLV_TIPO_ASISTENCIA
      LEFT JOIN LATERAL academico_test.fn_actividad_asistencia_dia(ae.FK_TMATRICULA, ae.FK_TACTIVIDAD) d ON TRUE
     WHERE ae.PK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante
       AND (n.FK_TLV_TIPO_ASISTENCIA IS NOT NULL OR d.tipo_valor IS NOT NULL);
$$;

-- Regla 73: Asistió y Llegó tarde no cambian el resultado; No asistió lo
-- marca No asistido, Justificada solo si hay excusa.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_estado_por_asistencia(p_ausente BOOLEAN, p_justificada BOOLEAN)
RETURNS VARCHAR
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT (CASE WHEN NOT COALESCE(p_ausente, FALSE) THEN NULL
                 WHEN COALESCE(p_justificada, FALSE) THEN 'NO_ASISTIO_JUSTIFICADA'
                 ELSE 'NO_ASISTIO_NO_JUSTIFICADA' END)::VARCHAR;
$$;

-- Redefine la de V450 para contar también lo marcado en esta actividad.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_asistencia_fecha_resolver(
    p_fk_tmatricula BIGINT,
    p_pk_tactividad BIGINT
)
RETURNS DATE
LANGUAGE sql
STABLE
AS $$
    SELECT s.fecha
      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
     CROSS JOIN LATERAL academico_test.fn_actividad_asistencia_estudiante(ae.PK_TACTIVIDAD_ESTUDIANTE) s
     WHERE ae.FK_TMATRICULA = p_fk_tmatricula AND ae.FK_TACTIVIDAD = p_pk_tactividad AND ae.ACTIVE = TRUE
     LIMIT 1;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_asistencia_fecha_resolver(BIGINT, BIGINT)
    IS 'Primer día de la actividad si el estudiante tiene asistencia en ella (tomada en la Vista, marcada en el Planeador o congelada); NULL si no. Lo leen la planilla (fechaAsistencia/tieneAsistencia) y la tabla de calificaciones (fecha_asistencia). Sin asistencia no se califica (fn_actividad_validar_permite_calificar).';
COMMENT ON FUNCTION academico_test.fn_actividad_asistencia_estudiante(BIGINT)
    IS 'Asistencia de la actividad para un estudiante (PK_TACTIVIDAD_ESTUDIANTE): la fijada en TACTIVIDAD_NOTA (marcada en el Planeador para esta actividad o congelada al registrar el resultado) o, si no hay, la tomada en la fecha fin o, si aún no, el primer día (fn_actividad_asistencia_dia: la Vista predomina sobre la oficial que dejó el Planeador). Sin ninguna no devuelve filas. La usan el listado de calificaciones, las validaciones de calificar y la sincronización.';
COMMENT ON FUNCTION academico_test.fn_actividad_estado_por_asistencia(BOOLEAN, BOOLEAN)
    IS 'Regla 73: estado de resultado que impone la asistencia: NO_ASISTIO_JUSTIFICADA / NO_ASISTIO_NO_JUSTIFICADA si está ausente (según la excusa), NULL si asistió o llegó tarde (no cambia nada).';

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_resultados_completos(p_pk_tactividad BIGINT)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    -- Regla 58: sin fila de nota el estudiante también está Pendiente.
    SELECT NOT EXISTS (
        SELECT 1
          FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
          LEFT JOIN academico_test.TACTIVIDAD_NOTA n
                 ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE AND n.ACTIVE = TRUE
         WHERE ae.FK_TACTIVIDAD = p_pk_tactividad AND ae.ACTIVE = TRUE
           AND (n.PK_TACTIVIDAD_NOTA IS NULL
                OR academico_test.fn_actividad_estado_resultado(n.PK_TACTIVIDAD_NOTA) = 'PENDIENTE'));
$$;

-- Registrado = observación (texto, enlace o archivos) o un estado distinto de Pendiente.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_resultado_registrado(p_pk_tactividad_estudiante BIGINT)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    SELECT EXISTS (SELECT 1 FROM academico_test.TACTIVIDAD_NOTA n
                    WHERE n.FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante AND n.ACTIVE = TRUE
                      AND (NULLIF(TRIM(n.OBSERVACION), '') IS NOT NULL OR n.EVIDENCIA_ENLACE IS NOT NULL
                           OR academico_test.fn_actividad_estado_resultado(n.PK_TACTIVIDAD_NOTA) <> 'PENDIENTE'))
        OR EXISTS (SELECT 1 FROM academico_test.TACTIVIDAD_SOPORTE so
                    WHERE so.FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante
                      AND so.ACTIVE = TRUE AND so.FK_TARCHIVO IS NOT NULL);
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_estudiante_etiqueta(p_pk_tactividad_estudiante BIGINT)
RETURNS VARCHAR
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(
        (SELECT academico_test.fn_actividad_estudiante_nombre(ae.FK_TMATRICULA)
           FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
          WHERE ae.PK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante),
        'el estudiante')::VARCHAR;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_observacion_soporte_resolver(p_pk_tactividad_soporte BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_pk_ae BIGINT;
BEGIN
    SELECT FK_TACTIVIDAD_ESTUDIANTE INTO v_pk_ae
      FROM academico_test.TACTIVIDAD_SOPORTE
     WHERE PK_TACTIVIDAD_SOPORTE = p_pk_tactividad_soporte AND ACTIVE = TRUE AND FK_TARCHIVO IS NOT NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontró la evidencia de la observación (o ya fue retirada)' USING ERRCODE = 'P0002';
    END IF;
    RETURN v_pk_ae;
END;
$$;

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
    p_criterios        JSONB,
    p_etiqueta         VARCHAR,
    p_requiere_puntaje BOOLEAN DEFAULT TRUE
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
        RAISE EXCEPTION 'La rúbrica debe tener al menos un criterio con un nivel y su puntaje.' USING ERRCODE = '22023';
    END IF;
    FOR v_c IN SELECT e AS j, ord FROM jsonb_array_elements(p_criterios) WITH ORDINALITY AS t(e, ord) LOOP
        v_nombre := NULLIF(TRIM(v_c.j->>'nombre'), '');
        IF v_nombre IS NULL THEN
            RAISE EXCEPTION 'El criterio % de la rúbrica de % no tiene nombre', v_c.ord, p_etiqueta
                USING ERRCODE = '22023';
        END IF;
        v_niveles := v_c.j->'niveles';
        IF v_niveles IS NULL OR jsonb_typeof(v_niveles) <> 'array' OR jsonb_array_length(v_niveles) = 0 THEN
            RAISE EXCEPTION 'La rúbrica debe tener al menos un criterio con un nivel y su puntaje.'
                USING ERRCODE = '22023';
        END IF;
        -- El puntaje de cada nivel solo es obligatorio si la unidad vinculada calcula
        -- su definitiva por Ponderación o Sumatoria (p_requiere_puntaje, resuelto por
        -- el llamador con fn_unidad_calculo_definitiva_modo); si la unidad Promedia o
        -- la actividad no tiene unidad, el nivel sin puntaje pesa 1 (igual que cotejo).
        IF p_requiere_puntaje AND EXISTS (SELECT 1 FROM jsonb_array_elements(v_niveles) n
                                            WHERE NULLIF(n->>'ponderacion', '') IS NULL) THEN
            RAISE EXCEPTION 'La rúbrica debe tener al menos un criterio con un nivel y su puntaje.'
                USING ERRCODE = '22023';
        END IF;
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_niveles) n
                    WHERE NULLIF(n->>'ponderacion', '') IS NOT NULL
                       AND ((n->>'ponderacion') !~ '^\d{1,3}(\.\d+)?$'
                            OR (n->>'ponderacion')::NUMERIC > 100)) THEN
            RAISE EXCEPTION 'Cada nivel del criterio "%" necesita un puntaje entre 0 y 100', v_nombre
                USING ERRCODE = '22023';
        END IF;
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_niveles) n WHERE NULLIF(TRIM(n->>'descripcion'), '') IS NULL) THEN
            RAISE EXCEPTION 'Cada nivel del criterio "%" necesita su descripción o juicio de valor', v_nombre
                USING ERRCODE = '22023';
        END IF;
        -- Duplicados y máximo en 0 solo se evalúan cuando el puntaje es obligatorio: si es
        -- opcional, los niveles sin puntaje pesan 1 por igual y no se consideran "iguales".
        IF p_requiere_puntaje THEN
            IF (SELECT COUNT(*) <> COUNT(DISTINCT (n->>'ponderacion')::NUMERIC) FROM jsonb_array_elements(v_niveles) n) THEN
                RAISE EXCEPTION 'El criterio "%" tiene dos niveles con el mismo puntaje', v_nombre USING ERRCODE = '22023';
            END IF;
            -- Con el máximo en 0 el criterio no aporta nada y la nota quedaría indefinida.
            IF (SELECT MAX((n->>'ponderacion')::NUMERIC) FROM jsonb_array_elements(v_niveles) n) = 0 THEN
                RAISE EXCEPTION 'El criterio "%" necesita al menos un nivel con puntaje mayor que 0', v_nombre
                    USING ERRCODE = '22023';
            END IF;
        END IF;
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_cotejo_definicion(
    p_items            JSONB,
    p_etiqueta         VARCHAR,
    p_requiere_puntaje BOOLEAN DEFAULT FALSE
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
    -- El puntaje de cada elemento solo es obligatorio si la unidad vinculada calcula su
    -- definitiva por Ponderación o Sumatoria (ver fn_actividad_validar_rubrica_definicion).
    IF p_requiere_puntaje AND EXISTS (SELECT 1 FROM jsonb_array_elements(p_items) e
                                        WHERE NULLIF(e->>'ponderacion', '') IS NULL) THEN
        RAISE EXCEPTION 'Cada elemento de la lista de cotejo necesita un puntaje.'
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
    -- Regla confirmada por negocio (fila 24 de la especificación, 2026-10): el puntaje de
    -- nivel/elemento del Bloque 5 solo es obligatorio si la Unidad vinculada en el Bloque 1
    -- calcula su definitiva por Ponderación o Sumatoria; si calcula por Promedio simple, o la
    -- actividad no tiene unidad (FK_TUNIDAD NULL), el puntaje sigue opcional y pesa 1.
    v_requiere_puntaje BOOLEAN := academico_test.fn_unidad_calculo_definitiva_modo(
                                      (SELECT a.FK_TUNIDAD FROM academico_test.TACTIVIDAD a
                                        WHERE a.PK_TACTIVIDAD = p_pk_tactividad)
                                  ) IN ('PONDERAR', 'SUMATORIA');
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
        WHEN 'RUBRICA'      THEN PERFORM academico_test.fn_actividad_validar_rubrica_definicion(v_def, v_etiqueta, v_requiere_puntaje);
        WHEN 'LISTA_COTEJO' THEN PERFORM academico_test.fn_actividad_validar_cotejo_definicion(v_def, v_etiqueta, v_requiere_puntaje);
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
    PERFORM academico_test.fn_actividad_validar_referente_calificable(p_pk_tactividad);
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
END;
$$;

-- ---------------------------------------------------------------------------
-- Estados de resultado (Reglas 59 y 62)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_estado_resultado_asignable(p_estado VARCHAR)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF upper(TRIM(p_estado)) = 'CALIFICADO' THEN
        RAISE EXCEPTION 'El estado Calificado no se marca a mano: se fija al registrar el resultado con el instrumento'
            USING ERRCODE = '22023';
    END IF;
    -- J/NJ no los elige el docente: salen de la asistencia y su excusa.
    IF upper(TRIM(p_estado)) LIKE 'NO_ASISTIO%' THEN
        RAISE EXCEPTION 'No asistido no se marca a mano: cambie la asistencia del estudiante en el Planeador; Justificada o No justificada depende de la excusa'
            USING ERRCODE = '22023';
    END IF;
    IF academico_test.fn_tlv_estado_resultado_pk(p_estado) IS NULL THEN
        RAISE EXCEPTION 'Estado de resultado "%" no reconocido: use %', COALESCE(p_estado, ''),
            (SELECT string_agg(lv.NOMBRE, ', ' ORDER BY lv.PK_LISTA_VALOR) FROM academico_test.TLISTA_VALOR lv
              WHERE lv.CATEGORIA = 'ESTADO_RESULTADO' AND lv.ACTIVE = TRUE AND lv.VALOR IN ('PENDIENTE', 'NO_PRESENTO'))
            USING ERRCODE = '22023';
    END IF;
END;
$$;

-- Regla 62: los estados son excluyentes. No presentó exige que no haya nota ni
-- inasistencia; salir de No asistido es cambiar la asistencia, no el estado.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_estado_transicion(
    p_pk_tactividad_estudiante BIGINT,
    p_estado                   VARCHAR
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_actual  VARCHAR;
    v_nota    NUMERIC;
    v_ausente BOOLEAN;
BEGIN
    SELECT academico_test.fn_actividad_estado_resultado(n.PK_TACTIVIDAD_NOTA), n.CALIFICACION
      INTO v_actual, v_nota
      FROM academico_test.TACTIVIDAD_NOTA n
     WHERE n.FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante AND n.ACTIVE = TRUE;
    SELECT a.ausente INTO v_ausente FROM academico_test.fn_actividad_asistencia_estudiante(p_pk_tactividad_estudiante) a;
    IF COALESCE(v_actual, '') LIKE 'NO_ASISTIO%' OR COALESCE(v_ausente, FALSE) THEN
        RAISE EXCEPTION '% está No asistido en %: cambie primero su asistencia en el Planeador',
            academico_test.fn_actividad_estudiante_etiqueta(p_pk_tactividad_estudiante),
            academico_test.fn_actividad_etiqueta(academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante))
            USING ERRCODE = '22023';
    END IF;
    IF upper(TRIM(p_estado)) = 'NO_PRESENTO' AND (v_nota IS NOT NULL OR v_actual = 'CALIFICADO') THEN
        RAISE EXCEPTION '% ya tiene resultado registrado en %: quite la nota antes de marcar No presentó',
            academico_test.fn_actividad_estudiante_etiqueta(p_pk_tactividad_estudiante),
            academico_test.fn_actividad_etiqueta(academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante))
            USING ERRCODE = '22023';
    END IF;
END;
$$;

-- Sin asistencia, No asistido y No presentó no se califican ni se observan:
-- toda nota nace con su asistencia, que queda congelada.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_permite_calificar(p_pk_tactividad_estudiante BIGINT)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_estado  VARCHAR;
    v_ausente BOOLEAN;
    v_hay     BOOLEAN;
BEGIN
    SELECT academico_test.fn_actividad_estado_resultado(n.PK_TACTIVIDAD_NOTA) INTO v_estado
      FROM academico_test.TACTIVIDAD_NOTA n
     WHERE n.FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante AND n.ACTIVE = TRUE;
    SELECT a.ausente INTO v_ausente FROM academico_test.fn_actividad_asistencia_estudiante(p_pk_tactividad_estudiante) a;
    v_hay := FOUND;
    -- Un Calificado previo a esta regla puede no tener asistencia: se deja recalificar.
    IF NOT v_hay AND COALESCE(v_estado, '') <> 'CALIFICADO' THEN
        RAISE EXCEPTION '% no tiene asistencia en %: regístrela en la Vista Asistencias o en el Planeador para registrar el resultado',
            academico_test.fn_actividad_estudiante_etiqueta(p_pk_tactividad_estudiante),
            academico_test.fn_actividad_etiqueta(academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante))
            USING ERRCODE = '22023';
    END IF;
    IF COALESCE(v_estado, '') LIKE 'NO_ASISTIO%' OR (COALESCE(v_ausente, FALSE) AND COALESCE(v_estado, '') <> 'CALIFICADO') THEN
        RAISE EXCEPTION '% está No asistido en %: cambie su asistencia en el Planeador para registrar el resultado',
            academico_test.fn_actividad_estudiante_etiqueta(p_pk_tactividad_estudiante),
            academico_test.fn_actividad_etiqueta(academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante))
            USING ERRCODE = '22023';
    END IF;
    IF v_estado = 'NO_PRESENTO' THEN
        RAISE EXCEPTION '% está marcado No presentó en %: quítelo (estado Pendiente) para registrar el resultado',
            academico_test.fn_actividad_estudiante_etiqueta(p_pk_tactividad_estudiante),
            academico_test.fn_actividad_etiqueta(academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante))
            USING ERRCODE = '22023';
    END IF;
END;
$$;

-- Con resultado registrado la asistencia de la actividad queda congelada.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_asistencia_editable(p_pk_tactividad_estudiante BIGINT)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM academico_test.TACTIVIDAD_NOTA n
                WHERE n.FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante AND n.ACTIVE = TRUE
                  AND (n.CALIFICACION IS NOT NULL
                       OR academico_test.fn_actividad_estado_resultado(n.PK_TACTIVIDAD_NOTA) = 'CALIFICADO')) THEN
        RAISE EXCEPTION '% ya tiene resultado en %: su asistencia en la actividad no se puede cambiar',
            academico_test.fn_actividad_estudiante_etiqueta(p_pk_tactividad_estudiante),
            academico_test.fn_actividad_etiqueta(academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante))
            USING ERRCODE = '22023';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_validar_estado_transicion(BIGINT, VARCHAR)
    IS 'Regla 62: 22023 si el estudiante está No asistido (se corrige cambiando su asistencia en el Planeador) o si se marca No presentó sobre un resultado ya registrado. La usa fn_actividad_resultado_estado_set_interno.';
COMMENT ON FUNCTION academico_test.fn_actividad_validar_permite_calificar(BIGINT)
    IS '22023 si el estudiante no tiene asistencia en la actividad, está No asistido (por estado o por la asistencia de la actividad) o No presentó: no se califica ni se observa. Un resultado ya Calificado no se bloquea (su asistencia quedó congelada). La usan fn_actividad_nota_guardar_interno y fn_actividad_observar_estudiante_interno.';
COMMENT ON FUNCTION academico_test.fn_actividad_validar_asistencia_editable(BIGINT)
    IS '22023 si el estudiante ya tiene nota u observación en la actividad: su asistencia de la actividad quedó congelada. La usa fn_actividad_asistencia_planeador_set_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_estado_coherente(p_pk_tactividad_nota BIGINT)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_n RECORD;
BEGIN
    SELECT n.CALIFICACION, ae.PK_TACTIVIDAD_ESTUDIANTE, ae.FK_TACTIVIDAD,
           academico_test.fn_actividad_estado_resultado(n.PK_TACTIVIDAD_NOTA) AS estado
      INTO v_n
      FROM academico_test.TACTIVIDAD_NOTA n
      JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae ON ae.PK_TACTIVIDAD_ESTUDIANTE = n.FK_TACTIVIDAD_ESTUDIANTE
     WHERE n.PK_TACTIVIDAD_NOTA = p_pk_tactividad_nota;
    IF FOUND AND v_n.estado <> 'CALIFICADO' AND v_n.CALIFICACION IS NOT NULL THEN
        RAISE EXCEPTION 'El resultado de % en % no puede tener nota y estar marcado como %',
            academico_test.fn_actividad_estudiante_etiqueta(v_n.PK_TACTIVIDAD_ESTUDIANTE),
            academico_test.fn_actividad_etiqueta(v_n.FK_TACTIVIDAD),
            (SELECT NOMBRE FROM academico_test.TLISTA_VALOR WHERE CATEGORIA = 'ESTADO_RESULTADO' AND VALOR = v_n.estado LIMIT 1)
            USING ERRCODE = '22023';
    END IF;
END;
$$;

-- Regla 59: un referente inactivo conserva su historia pero ya no recibe resultados.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_referente_calificable(p_pk_tactividad BIGINT)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_nombre VARCHAR;
BEGIN
    SELECT rc.NOMBRE INTO v_nombre
      FROM academico_test.TACTIVIDAD a
      JOIN academico_test.TUNIDAD u ON u.PK_TUNIDAD = a.FK_TUNIDAD
      JOIN academico_test.TREFERENTE_CURRICULAR rc ON rc.PK_REFERENTE_CURRICULAR = u.FK_REFERENTE_CURRICULAR
     WHERE a.PK_TACTIVIDAD = p_pk_tactividad
       AND (rc.ACTIVE = FALSE OR rc.ESTADO <> 'A');
    IF FOUND THEN
        RAISE EXCEPTION '% se rige por el referente curricular "%", que está inactivo: ya no se registran resultados en ella',
            academico_test.fn_actividad_etiqueta(p_pk_tactividad), v_nombre USING ERRCODE = '22023';
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Registro narrativo (§6, Regla 61)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_formativa(p_pk_tactividad BIGINT)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF NOT academico_test.fn_actividad_es_formativa(p_pk_tactividad) THEN
        RAISE EXCEPTION '% tiene referente evaluativo (o no tiene unidad): se califica con su instrumento, no con observaciones',
            academico_test.fn_actividad_etiqueta(p_pk_tactividad) USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_observacion_texto(p_observacion TEXT)
RETURNS VOID
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    PERFORM academico_test.fn_actividad_validar_texto(p_observacion, 'La observación', 1000);
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_momento(p_momento VARCHAR)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF NULLIF(TRIM(p_momento), '') IS NOT NULL AND academico_test.fn_tlv_momento_registro_pk(p_momento) IS NULL THEN
        RAISE EXCEPTION 'Momento "%" no reconocido: use %', p_momento,
            (SELECT string_agg(lv.NOMBRE, ', ' ORDER BY lv.PK_LISTA_VALOR) FROM academico_test.TLISTA_VALOR lv
              WHERE lv.CATEGORIA = 'MOMENTO_REGISTRO' AND lv.ACTIVE = TRUE)
            USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_evidencias_cantidad(p_archivos INT)
RETURNS VOID
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_archivos > 3 THEN
        RAISE EXCEPTION 'La evidencia admite hasta 3 archivos por estudiante; quedarían %', p_archivos USING ERRCODE = '22023';
    END IF;
END;
$$;

-- p_evidencias / p_enlace NULL = no se tocan: valen los actuales.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_evidencias_narrativas(
    p_evidencias        BIGINT[],
    p_enlace            VARCHAR,
    p_archivos_actuales INT     DEFAULT 0,
    p_enlace_actual     VARCHAR DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_archivo  BIGINT;
    v_archivos INT := CASE WHEN p_evidencias IS NULL THEN COALESCE(p_archivos_actuales, 0)
                           ELSE (SELECT COUNT(DISTINCT x) FROM unnest(p_evidencias) x WHERE x IS NOT NULL) END;
    v_enlace   VARCHAR := CASE WHEN p_enlace IS NULL THEN NULLIF(TRIM(p_enlace_actual), '')
                               ELSE NULLIF(TRIM(p_enlace), '') END;
BEGIN
    PERFORM academico_test.fn_actividad_validar_evidencias_cantidad(v_archivos);
    FOREACH v_archivo IN ARRAY COALESCE(p_evidencias, ARRAY[]::BIGINT[]) LOOP
        PERFORM academico_test.fn_actividad_validar_archivo_existente(v_archivo, 'la evidencia de la observación');
        PERFORM academico_test.fn_actividad_validar_archivo_formato(
            v_archivo, 'la evidencia de la observación', ARRAY['pdf', 'doc', 'docx', 'jpg', 'jpeg', 'png'], 10);
    END LOOP;
    PERFORM academico_test.fn_actividad_validar_url(v_enlace, 'la evidencia de la observación');
    IF v_archivos > 0 AND v_enlace IS NOT NULL THEN
        RAISE EXCEPTION 'La evidencia va en archivos (hasta 3) o en un enlace externo, no en los dos'
            USING ERRCODE = '22023';
    END IF;
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
    IS 'Validador central de PUT /planeador/actividades/:ID/instrumento: instrumento configurable, permitido por el referente y definición válida según su tipo (en Otro, su propia configuración y la del método elegido). Resuelve p_requiere_puntaje con fn_unidad_calculo_definitiva_modo sobre TACTIVIDAD.FK_TUNIDAD (PONDERAR/SUMATORIA exigen puntaje de nivel/elemento en rúbrica y cotejo; PROMEDIAR o sin unidad lo dejan opcional) y lo propaga a fn_actividad_validar_rubrica_definicion/fn_actividad_validar_cotejo_definicion. Lo usa fn_actividad_instrumento_definir_interno.';
COMMENT ON FUNCTION academico_test.fn_actividad_validar_calificable(BIGINT)
    IS 'Reglas 52 y 59: 22023 si la actividad está eliminada, su referente está inactivo, es formativa (se registra con observación) o no tiene instrumento.';
COMMENT ON FUNCTION academico_test.fn_actividad_validar_calificacion(BIGINT, DATE)
    IS 'Validador central de una calificación: la asignación existe (P0002) y la actividad es calificable. p_fecha se conserva por contrato y no se usa: la asistencia de la actividad (fecha fin o primer día) la valida fn_actividad_validar_permite_calificar. Lo usa fn_actividad_nota_calificar_interno.';
COMMENT ON FUNCTION academico_test.fn_actividad_assert_propietario_resultados(BIGINT, BIGINT)
    IS 'Regla 54: 42501 si un docente de aula ve o registra resultados de una actividad que no creó. Coordinación, rectoría y super admin pasan. Lo usan los wrappers de calificación y de lectura de notas.';
COMMENT ON FUNCTION academico_test.fn_tlv_estado_resultado_pk(TEXT)
    IS 'PK_LISTA_VALOR del ESTADO_RESULTADO con ese VALOR (CALIFICADO, PENDIENTE, NO_PRESENTO, NO_ASISTIO_JUSTIFICADA, NO_ASISTIO_NO_JUSTIFICADA), por texto. NULL si no existe.';
COMMENT ON FUNCTION academico_test.fn_tlv_momento_registro_pk(TEXT)
    IS 'PK_LISTA_VALOR del MOMENTO_REGISTRO (INICIO, PROCESO, CIERRE) por texto. NULL si no existe.';
COMMENT ON FUNCTION academico_test.fn_actividad_estado_resultado(BIGINT)
    IS 'VALOR del estado de resultado de una TACTIVIDAD_NOTA; sin estado, CALIFICADO si tiene CALIFICACION y si no PENDIENTE. Lo usan los listados de calificación y los informes.';
COMMENT ON FUNCTION academico_test.fn_actividad_resultados_completos(BIGINT)
    IS 'Regla 58 (derivada, no persistida): TRUE si ningún estudiante activo de la actividad está Pendiente de calificar (sin nota cuenta como Pendiente).';
COMMENT ON FUNCTION academico_test.fn_actividad_resultado_registrado(BIGINT)
    IS 'TRUE si el estudiante ya tiene resultado en la actividad: observación con texto, enlace o archivos, o un estado distinto de Pendiente. La usa fn_actividad_observar_grupal_interno para no sobrescribir.';
COMMENT ON FUNCTION academico_test.fn_actividad_estudiante_etiqueta(BIGINT)
    IS 'Nombre del estudiante de una asignación actividad-estudiante para mensajes y etiquetas de auditoría; "el estudiante" si no se resuelve.';
COMMENT ON FUNCTION academico_test.fn_actividad_observacion_soporte_resolver(BIGINT)
    IS 'TACTIVIDAD_ESTUDIANTE de un soporte de observación activo; P0002 si no existe o ya fue retirado. La usan los wrappers de quitar y favorito.';
COMMENT ON FUNCTION academico_test.fn_actividad_validar_estado_resultado_asignable(VARCHAR)
    IS 'Regla 62: 22023 si el estado no existe en ESTADO_RESULTADO, es CALIFICADO (lo fija el registro del resultado) o es No asistido (lo decide la asistencia). Solo PENDIENTE y NO_PRESENTO se marcan a mano.';
COMMENT ON FUNCTION academico_test.fn_actividad_validar_estado_coherente(BIGINT)
    IS 'Regla 62: 22023 si la nota está en un estado distinto de Calificado y conserva CALIFICACION.';
COMMENT ON FUNCTION academico_test.fn_actividad_validar_referente_calificable(BIGINT)
    IS 'Regla 59: 22023 si la unidad de la actividad se rige por un referente curricular eliminado o inactivo.';
COMMENT ON FUNCTION academico_test.fn_actividad_validar_formativa(BIGINT)
    IS 'Regla 52: 22023 si la actividad no es formativa (se califica con su instrumento, no con observaciones). La usan los _interno de observación y soportes, junto a fn_actividad_validar_referente_calificable.';
COMMENT ON FUNCTION academico_test.fn_actividad_validar_evidencias_narrativas(BIGINT[], VARCHAR, INT, VARCHAR)
    IS 'Regla 61: hasta 3 archivos pdf/doc/docx/jpg/png de máximo 10 MB (fn_actividad_validar_archivo_formato), o un enlace http(s); no los dos. NULL en p_evidencias/p_enlace = se conservan los actuales.';

-- ---------------------------------------------------------------------------
-- Regla 30: redondeo institucional, en la ESCALA del formato (1 decimal de
-- 0-5 es un paso de 2 %), no sobre el porcentaje guardado.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_nota_redondear(
    p_valor     NUMERIC,
    p_decimales INT     DEFAULT 1,
    p_modo      VARCHAR DEFAULT NULL
)
RETURNS NUMERIC
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE
             WHEN p_valor IS NULL THEN NULL
             WHEN upper(COALESCE(p_modo, '')) LIKE '%NO RED%' THEN p_valor
             WHEN upper(COALESCE(p_modo, '')) LIKE '%ARRIBA%'
                  THEN ceil(p_valor * power(10::NUMERIC, COALESCE(p_decimales, 1))) / power(10::NUMERIC, COALESCE(p_decimales, 1))
             WHEN upper(COALESCE(p_modo, '')) LIKE '%ABAJO%'
                  THEN floor(p_valor * power(10::NUMERIC, COALESCE(p_decimales, 1))) / power(10::NUMERIC, COALESCE(p_decimales, 1))
             ELSE round(p_valor, COALESCE(p_decimales, 1))
           END;
$$;

COMMENT ON FUNCTION academico_test.fn_nota_redondear(NUMERIC, INT, VARCHAR)
    IS 'Regla 30, aritmética pura: redondea p_valor a p_decimales (1 por defecto) según el modo MODO_REDONDEAR por texto (Hacia arriba, Hacia abajo, No redondear; cualquier otro, incluido NULL, = al más cercano). La usa fn_criterio_evaluacion_nota_redondear.';

CREATE OR REPLACE FUNCTION academico_test.fn_criterio_evaluacion_nota_redondear(
    p_pk_criterio BIGINT,
    p_porcentaje  NUMERIC
)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    -- Sin criterio o formato cualitativo, la escala es el propio porcentaje.
    SELECT CASE WHEN p_porcentaje IS NULL THEN NULL ELSE
           academico_test.fn_nota_redondear(p_porcentaje * COALESCE(f.nota_maxima, 100) / 100,
                                            COALESCE(f.decimales, 1), lv.NOMBRE)
           * 100 / COALESCE(f.nota_maxima, 100) END
      FROM (SELECT 1) uno
      LEFT JOIN academico_test.fn_criterio_evaluacion_formato(p_pk_criterio) f ON TRUE
      LEFT JOIN academico_test.TCRITERIO_EVALUACION ce ON ce.PK_TCRITERIO_EVALUACION = p_pk_criterio
      LEFT JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = ce.FK_TLV_MODO_REDONDEAR;
$$;

COMMENT ON FUNCTION academico_test.fn_criterio_evaluacion_nota_redondear(BIGINT, NUMERIC)
    IS 'Regla 30: redondea un porcentaje 0-100 en la escala del formato del criterio (NUMERO_DECIMALES, 1 por defecto, y FK_TLV_MODO_REDONDEAR) y lo devuelve otra vez en porcentaje. La usan fn_actividad_nota_redondear y la consolidación de la recuperación.';

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_criterio_evaluacion(p_pk_tactividad BIGINT)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT academico_test.fn_asignatura_criterio_evaluacion_vigente(
               a.FK_TASIGNATURA, academico_test.fn_actividad_grado_resolver(a.PK_TACTIVIDAD))
      FROM academico_test.TACTIVIDAD a
     WHERE a.PK_TACTIVIDAD = p_pk_tactividad AND a.FK_TASIGNATURA IS NOT NULL;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_redondear(p_pk_tactividad BIGINT, p_porcentaje NUMERIC)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    SELECT academico_test.fn_criterio_evaluacion_nota_redondear(
               academico_test.fn_actividad_criterio_evaluacion(p_pk_tactividad), p_porcentaje);
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_nota_redondear(BIGINT, NUMERIC)
    IS 'Regla 30 para la nota de una actividad: resuelve su criterio de evaluación (grado + asignatura) y redondea. La usa fn_actividad_nota_aplicar_interno, punto único donde se escribe TACTIVIDAD_NOTA.CALIFICACION.';
