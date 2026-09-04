-- ===========================================================================
-- V240 — Planeador educativo: instrumento de evaluacion "Otro (personalizado)"
-- de una actividad (CU-86e311xxp — G. Academico Back Planeador educativo).
--
-- Complementa V224 (CRUD de actividades, catalogo INSTRUMENTO_EVALUACION con
-- el valor OTRO) y V226 (definicion de RUBRICA / LISTA_COTEJO /
-- ESCALA_VALORACION). Cuando TACTIVIDAD.FK_TLV_INSTRUMENTO_EVALUACION = OTRO
-- el docente configura, ademas del texto libre ya existente
-- (DESCRIPCION_INSTRUMENTO, REQUIERE_ARCHIVO, REQUIERE_TEXTO — V224, no se
-- duplican aqui), el tipo de evidencia esperada y un METODO DE VALORACION
-- para poder calificar (figma: bloque "Otro (personalizado)").
--
-- Modulos:
--   (1) Seed TIPO_EVIDENCIA_OTRO   — catalogo nuevo, distinto de
--                                    TIPO_EVIDENCIA (V224, bloque
--                                    "Seguimiento"): el figma de este bloque
--                                    muestra opciones diferentes (sin
--                                    Imagen/Video separados, con
--                                    "Observacion directa" / "Registro en
--                                    campo"). Confirmado con negocio.
--   (2) DDL                        — TACTIVIDAD_OTRO (1:1 con TACTIVIDAD).
--   (3) fn_actividad_otro_definir  — configura TACTIVIDAD_OTRO y delega la
--                                    estructura del metodo de valoracion
--                                    elegido a fn_actividad_rubrica_definir /
--                                    _cotejo_definir / _escala_definir
--                                    (V226) — cero tablas de estructura
--                                    nuevas.
--   (4) fn_actividad_instrumento_assert — se AMPLIA (misma firma) para que
--                                    reconozca el instrumento OTRO con un
--                                    metodo de valoracion ya configurado como
--                                    equivalente al instrumento estructurado
--                                    correspondiente.
--   (5) fn_actividad_instrumento_definir / _obtener (V226) — CREATE OR
--                                    REPLACE: la rama OTRO ahora delega en
--                                    fn_actividad_otro_definir y devuelve su
--                                    definicion completa.
--
-- -------------------------------------------------------------------------
-- DECISIONES DE NEGOCIO confirmadas con el usuario (preguntadas y
-- respondidas explicitamente, no se repiten):
--
--   * TIPO_EVIDENCIA (V224) se mantiene SEPARADO de este catalogo nuevo
--     TIPO_EVIDENCIA_OTRO: aunque ambos representan "tipo de evidencia", el
--     figma de "Otro (personalizado)" trae opciones propias (Archivo /
--     Enlace / Observacion directa / Registro en campo, sin Imagen/Video
--     como valores independientes).
--   * "Metodo de valoracion" NO es un catalogo ni una estructura nueva: es
--     el MISMO catalogo INSTRUMENTO_EVALUACION (V224) reutilizado — RUBRICA,
--     LISTA_COTEJO o ESCALA_VALORACION (nunca OTRO, seria circular) — y al
--     elegirlo se reutiliza la MISMA definicion de estructura ya construida
--     en V226 (fn_actividad_rubrica_definir / _cotejo_definir /
--     _escala_definir). Se descarto seedear un catalogo METODO_VALORACION
--     paralelo con los mismos 3 valores por ser una duplicacion directa.
--     TACTIVIDAD.FK_TLV_METODO_VALORACION (columna generica de V22, sin seed
--     desde V224) NO es esta columna: sigue sin uso, no se toca aqui.
--
-- -------------------------------------------------------------------------
-- fn_actividad_instrumento_assert — como se resolvio la "circularidad":
--
-- fn_actividad_rubrica_definir / _cotejo_definir / _escala_definir (V226)
-- llaman internamente a fn_actividad_instrumento_assert(actividad, 'RUBRICA'
-- | 'LISTA_COTEJO' | 'ESCALA_VALORACION'), que hasta V226 exigia coincidencia
-- EXACTA con TACTIVIDAD.FK_TLV_INSTRUMENTO_EVALUACION. Con instrumento OTRO
-- ese valor sigue siendo 'OTRO' (nunca cambia a 'RUBRICA', etc.), asi que la
-- llamada rompia. Alternativas evaluadas:
--   a) Cambiar la FIRMA para aceptar una lista de valores validos — se
--      descarto: obliga a tocar las 3 llamadas existentes en V226 y a
--      pensar en compatibilidad de sobrecarga sin necesidad real.
--   b) (ELEGIDA) Mantener la firma (BIGINT, VARCHAR) y AMPLIAR la logica:
--      si el instrumento de la actividad es 'OTRO', se acepta el valor
--      esperado si existe una fila ACTIVA en TACTIVIDAD_OTRO para esa
--      actividad cuyo FK_TLV_METODO_VALORACION resuelto coincide con ese
--      mismo valor. fn_actividad_otro_definir fija ese metodo en
--      TACTIVIDAD_OTRO ANTES de delegar, por eso el orden importa.
-- Esto NO abre una puerta trasera: TACTIVIDAD_OTRO solo se escribe desde
-- fn_actividad_otro_definir (no hay otro INSERT/UPDATE publico), y llamar
-- fn_actividad_rubrica_definir directo sobre una actividad OTRO sin fila en
-- TACTIVIDAD_OTRO (o con otro metodo) sigue rechazando con 22023 igual que
-- antes de V240.
--
-- fn_actividad_instrumento_reset NO se toca: solo hace soft delete de
-- TACTIVIDAD_RUBRICA_*/_COTEJO_ITEM/_ESCALA*, nunca de TACTIVIDAD_OTRO (tabla
-- distinta), asi que reutilizarlo desde dentro de fn_actividad_rubrica_definir
-- etc. (via fn_actividad_otro_definir) no borra la configuracion de "Otro".
--
-- Depende de (orden de version de Flyway):
--   * V224 — TACTIVIDAD, seed INSTRUMENTO_EVALUACION/TIPO_EVIDENCIA,
--            fn_actividad_lv_assert, menu 'PLANEADOR'.
--   * V226 — fn_actividad_instrumento_assert/_reset,
--            fn_actividad_rubrica_definir/_cotejo_definir/_escala_definir,
--            fn_actividad_instrumento_definir/_obtener.
--
-- Estilo: V226 (gate, 22023/23503/P0002, upsert 1:1, JSONB entrada/salida,
-- COMMENT ON FUNCTION) y V120/V224/V226 (seed idempotente WHERE NOT EXISTS).
-- ===========================================================================

SET search_path TO academico_test, public;

-- ===========================================================================
-- (1) SEED TIPO_EVIDENCIA_OTRO — catalogo nuevo del bloque "Otro
-- (personalizado)", distinto de TIPO_EVIDENCIA (V224).
-- ===========================================================================
INSERT INTO academico_test.tlista_valor (categoria, nombre, valor, created_by)
SELECT v.categoria, v.nombre, v.valor, 'V240_seed'
  FROM (VALUES
    ('TIPO_EVIDENCIA_OTRO'::VARCHAR, 'Archivo'::VARCHAR,               'ARCHIVO'::VARCHAR),
    ('TIPO_EVIDENCIA_OTRO',          'Enlace',                         'ENLACE'),
    ('TIPO_EVIDENCIA_OTRO',          'Observación directa',            'OBSERVACION_DIRECTA'),
    ('TIPO_EVIDENCIA_OTRO',          'Registro en campo',              'REGISTRO_CAMPO')
  ) AS v(categoria, nombre, valor)
 WHERE NOT EXISTS (
     SELECT 1 FROM academico_test.tlista_valor lv
      WHERE lv.categoria = v.categoria AND lv.valor = v.valor
 );

-- ===========================================================================
-- (2) DDL — TACTIVIDAD_OTRO (1:1 con TACTIVIDAD, mismo patron que
-- TACTIVIDAD_ESCALA: UNIQUE sin filtro por ACTIVE, se hace upsert).
-- ===========================================================================
CREATE TABLE IF NOT EXISTS TACTIVIDAD_OTRO (
  PK_TACTIVIDAD_OTRO BIGINT GENERATED BY DEFAULT AS IDENTITY NOT NULL,
  FK_TACTIVIDAD BIGINT NOT NULL,
  FK_TLV_TIPO_EVIDENCIA_OTRO BIGINT NOT NULL,
  FK_TLV_METODO_VALORACION BIGINT NOT NULL,
  CREATED_BY VARCHAR(120) NOT NULL,
  CREATED_AT TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
  MODIFIED_BY VARCHAR(120),
  MODIFIED_AT TIMESTAMP,
  ACTIVE BOOLEAN DEFAULT TRUE NOT NULL,
  CONSTRAINT PK_TAC_OTRO PRIMARY KEY (PK_TACTIVIDAD_OTRO),
  CONSTRAINT UN_TAC_OTRO_1 UNIQUE (FK_TACTIVIDAD) DEFERRABLE INITIALLY DEFERRED,
  CONSTRAINT FK_TAC_OTRO_1 FOREIGN KEY (FK_TACTIVIDAD) REFERENCES TACTIVIDAD (PK_TACTIVIDAD) ON DELETE CASCADE,
  CONSTRAINT FK_TAC_OTRO_2 FOREIGN KEY (FK_TLV_TIPO_EVIDENCIA_OTRO) REFERENCES TLISTA_VALOR (PK_LISTA_VALOR),
  CONSTRAINT FK_TAC_OTRO_3 FOREIGN KEY (FK_TLV_METODO_VALORACION) REFERENCES TLISTA_VALOR (PK_LISTA_VALOR)
);

CREATE INDEX IF NOT EXISTS IDX_TAC_OTRO_1 ON TACTIVIDAD_OTRO (FK_TACTIVIDAD);
CREATE INDEX IF NOT EXISTS IDX_TAC_OTRO_2 ON TACTIVIDAD_OTRO (FK_TLV_TIPO_EVIDENCIA_OTRO);
CREATE INDEX IF NOT EXISTS IDX_TAC_OTRO_3 ON TACTIVIDAD_OTRO (FK_TLV_METODO_VALORACION);
CREATE INDEX IF NOT EXISTS IDX_TACTIVIDAD_OTRO_ACTIVE ON TACTIVIDAD_OTRO (PK_TACTIVIDAD_OTRO) WHERE ACTIVE = true;

COMMENT ON COLUMN TACTIVIDAD_OTRO.PK_TACTIVIDAD_OTRO IS 'Llave primaria de la tabla';
COMMENT ON COLUMN TACTIVIDAD_OTRO.FK_TACTIVIDAD IS 'Llave foranea a tabla TACTIVIDAD (relacion 1:1, solo aplica cuando FK_TLV_INSTRUMENTO_EVALUACION = OTRO)';
COMMENT ON COLUMN TACTIVIDAD_OTRO.FK_TLV_TIPO_EVIDENCIA_OTRO IS 'Tipo de evidencia esperada del instrumento Otro. Llave foranea de lista valor, categoria TIPO_EVIDENCIA_OTRO (distinta de TIPO_EVIDENCIA de V224)';
COMMENT ON COLUMN TACTIVIDAD_OTRO.FK_TLV_METODO_VALORACION IS 'Metodo de valoracion elegido para poder calificar el instrumento Otro. Llave foranea de lista valor, categoria INSTRUMENTO_EVALUACION reutilizada (solo RUBRICA | LISTA_COTEJO | ESCALA_VALORACION, nunca OTRO)';

COMMENT ON TABLE TACTIVIDAD_OTRO IS 'Configuracion del instrumento de evaluacion "Otro (personalizado)" de una actividad (1:1 con TACTIVIDAD cuando INSTRUMENTO = OTRO): tipo de evidencia esperada + metodo de valoracion elegido para calificar. El detalle textual/ponderacion generica (DESCRIPCION_INSTRUMENTO, REQUIERE_ARCHIVO, REQUIERE_TEXTO, PONDERACION) vive en TACTIVIDAD (V224); la estructura del metodo de valoracion vive en TACTIVIDAD_RUBRICA_*/_COTEJO_ITEM/_ESCALA* (V226), no se duplica aqui. V240.';

-- ===========================================================================
-- (3) fn_actividad_instrumento_assert — se AMPLIA (misma firma) para
-- reconocer OTRO + metodo de valoracion configurado. Ver cabecera.
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_instrumento_assert(
    p_pk_tactividad   BIGINT,
    p_valor_esperado  VARCHAR
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_active BOOLEAN;
    v_valor  VARCHAR;
BEGIN
    SELECT a.ACTIVE, lv.VALOR
      INTO v_active, v_valor
      FROM academico_test.TACTIVIDAD a
      LEFT JOIN academico_test.TLISTA_VALOR lv
             ON lv.PK_LISTA_VALOR = a.FK_TLV_INSTRUMENTO_EVALUACION
     WHERE a.PK_TACTIVIDAD = p_pk_tactividad;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la actividad solicitada' USING ERRCODE = 'P0002';
    END IF;
    IF v_active = FALSE THEN
        RAISE EXCEPTION 'La actividad esta inactiva; no se le puede definir el instrumento' USING ERRCODE = '22023';
    END IF;
    IF v_valor IS NULL THEN
        RAISE EXCEPTION 'La actividad no tiene instrumento de evaluacion definido; fijelo primero con fn_actividad_crear/_actualizar (FK_TLV_INSTRUMENTO_EVALUACION)'
            USING ERRCODE = '22023';
    END IF;

    IF v_valor = p_valor_esperado THEN
        RETURN;
    END IF;

    -- V240: el instrumento OTRO reutiliza rubrica/cotejo/escala como METODO
    -- DE VALORACION (TACTIVIDAD_OTRO.FK_TLV_METODO_VALORACION, fijado por
    -- fn_actividad_otro_definir). Se acepta como equivalente al instrumento
    -- estructurado esperado SOLO si ya quedo configurado ese metodo.
    IF v_valor = 'OTRO'
       AND p_valor_esperado IN ('RUBRICA', 'LISTA_COTEJO', 'ESCALA_VALORACION')
       AND EXISTS (
           SELECT 1
             FROM academico_test.TACTIVIDAD_OTRO o
             JOIN academico_test.TLISTA_VALOR lvm ON lvm.PK_LISTA_VALOR = o.FK_TLV_METODO_VALORACION
            WHERE o.FK_TACTIVIDAD = p_pk_tactividad
              AND o.ACTIVE = TRUE
              AND lvm.VALOR = p_valor_esperado
       )
    THEN
        RETURN;
    END IF;

    RAISE EXCEPTION 'El instrumento de la actividad es % y no % — cambielo antes de definirlo', v_valor, p_valor_esperado
        USING ERRCODE = '22023';
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_instrumento_assert(BIGINT, VARCHAR)
    IS 'Valida que la actividad exista, este activa y que su FK_TLV_INSTRUMENTO_EVALUACION (VALOR de TLISTA_VALOR) sea el esperado. Lanza P0002 / 22023. V240: ademas acepta como equivalente el caso instrumento OTRO con TACTIVIDAD_OTRO.FK_TLV_METODO_VALORACION ya configurado con el mismo valor esperado (RUBRICA | LISTA_COTEJO | ESCALA_VALORACION) — asi fn_actividad_rubrica_definir/_cotejo_definir/_escala_definir se pueden invocar desde fn_actividad_otro_definir sin romper. Helper de fn_actividad_*_definir. V226/V240.';

-- ===========================================================================
-- (4) fn_actividad_otro_definir — configura el instrumento Otro y delega la
-- estructura del metodo de valoracion elegido.
--
-- p_config JSONB = {
--   "tipoEvidencia": <pk_lv TIPO_EVIDENCIA_OTRO>,                     -- obligatorio
--   "metodoValoracion": <pk_lv INSTRUMENTO_EVALUACION, RUBRICA |
--                         LISTA_COTEJO | ESCALA_VALORACION>,          -- obligatorio
--   "definicion": <JSONB reenviado tal cual a fn_actividad_rubrica_definir
--                   / _cotejo_definir / _escala_definir segun
--                   metodoValoracion>                                 -- obligatorio
-- }
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_otro_definir(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad            BIGINT,
    p_config                   JSONB
)
RETURNS VARCHAR
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk_tipo_evidencia  BIGINT;
    v_pk_metodo          BIGINT;
    v_valor_metodo       VARCHAR;
    v_definicion         JSONB;
    v_pk_otro            BIGINT;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'EDITAR'
    );
    PERFORM academico_test.fn_actividad_instrumento_assert(p_pk_tactividad, 'OTRO');

    IF p_config IS NULL OR jsonb_typeof(p_config) <> 'object' THEN
        RAISE EXCEPTION 'p_config debe ser un objeto JSON' USING ERRCODE = '22023';
    END IF;

    v_pk_tipo_evidencia := NULLIF(p_config->>'tipoEvidencia', '')::BIGINT;
    v_pk_metodo         := NULLIF(p_config->>'metodoValoracion', '')::BIGINT;
    v_definicion        := p_config->'definicion';

    IF v_pk_tipo_evidencia IS NULL THEN
        RAISE EXCEPTION 'El instrumento Otro requiere tipoEvidencia' USING ERRCODE = '22023';
    END IF;
    PERFORM academico_test.fn_actividad_lv_assert(v_pk_tipo_evidencia, 'TIPO_EVIDENCIA_OTRO', 'tipoEvidencia');

    IF v_pk_metodo IS NULL THEN
        RAISE EXCEPTION 'El instrumento Otro requiere metodoValoracion (RUBRICA, LISTA_COTEJO o ESCALA_VALORACION)'
            USING ERRCODE = '22023';
    END IF;
    PERFORM academico_test.fn_actividad_lv_assert(v_pk_metodo, 'INSTRUMENTO_EVALUACION', 'metodoValoracion');

    SELECT VALOR INTO v_valor_metodo FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = v_pk_metodo;
    IF v_valor_metodo NOT IN ('RUBRICA', 'LISTA_COTEJO', 'ESCALA_VALORACION') THEN
        RAISE EXCEPTION 'metodoValoracion no puede ser % (solo RUBRICA, LISTA_COTEJO o ESCALA_VALORACION; nunca OTRO)', v_valor_metodo
            USING ERRCODE = '22023';
    END IF;

    IF v_definicion IS NULL THEN
        RAISE EXCEPTION 'El instrumento Otro requiere definicion (segun el metodoValoracion elegido)' USING ERRCODE = '22023';
    END IF;

    -- Upsert de TACTIVIDAD_OTRO ANTES de delegar: fn_actividad_instrumento_assert
    -- (V240) exige que el metodo ya este configurado aqui para aceptar la
    -- llamada interna que hace fn_actividad_*_definir sobre una actividad OTRO.
    SELECT PK_TACTIVIDAD_OTRO INTO v_pk_otro
      FROM academico_test.TACTIVIDAD_OTRO WHERE FK_TACTIVIDAD = p_pk_tactividad;

    IF v_pk_otro IS NULL THEN
        INSERT INTO academico_test.TACTIVIDAD_OTRO (
            FK_TACTIVIDAD, FK_TLV_TIPO_EVIDENCIA_OTRO, FK_TLV_METODO_VALORACION,
            CREATED_BY, CREATED_AT, ACTIVE
        ) VALUES (
            p_pk_tactividad, v_pk_tipo_evidencia, v_pk_metodo,
            p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
        )
        RETURNING PK_TACTIVIDAD_OTRO INTO v_pk_otro;
    ELSE
        UPDATE academico_test.TACTIVIDAD_OTRO
           SET FK_TLV_TIPO_EVIDENCIA_OTRO = v_pk_tipo_evidencia,
               FK_TLV_METODO_VALORACION   = v_pk_metodo,
               ACTIVE                     = TRUE,
               MODIFIED_BY                = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT                = CURRENT_TIMESTAMP
         WHERE PK_TACTIVIDAD_OTRO = v_pk_otro;
    END IF;

    -- Delega la estructura del metodo de valoracion elegido: reutiliza tal
    -- cual fn_actividad_rubrica_definir / _cotejo_definir / _escala_definir
    -- (V226) — mismo patron de dispatch que fn_actividad_instrumento_definir.
    -- Cada una hace su propio fn_actividad_instrumento_reset(..., NULL), que
    -- solo toca TACTIVIDAD_RUBRICA_*/_COTEJO_ITEM/_ESCALA* (nunca
    -- TACTIVIDAD_OTRO), asi que no borra lo recien configurado arriba.
    CASE v_valor_metodo
        WHEN 'RUBRICA' THEN
            PERFORM academico_test.fn_actividad_rubrica_definir(
                        p_pk_usuario_solicitante, p_pk_tactividad, v_definicion);
        WHEN 'LISTA_COTEJO' THEN
            PERFORM academico_test.fn_actividad_cotejo_definir(
                        p_pk_usuario_solicitante, p_pk_tactividad, v_definicion);
        WHEN 'ESCALA_VALORACION' THEN
            PERFORM academico_test.fn_actividad_escala_definir(
                        p_pk_usuario_solicitante, p_pk_tactividad, v_definicion);
    END CASE;

    RETURN v_valor_metodo;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_otro_definir(BIGINT, BIGINT, JSONB)
    IS 'Configura el instrumento de evaluacion "Otro (personalizado)" de una actividad: upsert de TACTIVIDAD_OTRO (tipoEvidencia contra TIPO_EVIDENCIA_OTRO, metodoValoracion contra INSTRUMENTO_EVALUACION restringido a RUBRICA|LISTA_COTEJO|ESCALA_VALORACION) y delega la estructura (definicion) al fn_actividad_*_definir correspondiente (V226) — cero tablas de estructura nuevas. Exige que el instrumento de la actividad sea OTRO (fn_actividad_instrumento_assert). Gate EDITAR sobre PLANEADOR. Retorna el VALOR del metodo de valoracion aplicado. V240.';

-- ===========================================================================
-- (5) fn_actividad_instrumento_definir — CREATE OR REPLACE: la rama OTRO
-- ahora delega en fn_actividad_otro_definir.
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_instrumento_definir(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad            BIGINT,
    p_definicion               JSONB
)
RETURNS VARCHAR
LANGUAGE plpgsql
AS $$
DECLARE
    v_valor VARCHAR;
BEGIN
    SELECT lv.VALOR INTO v_valor
      FROM academico_test.TACTIVIDAD a
      LEFT JOIN academico_test.TLISTA_VALOR lv
             ON lv.PK_LISTA_VALOR = a.FK_TLV_INSTRUMENTO_EVALUACION
     WHERE a.PK_TACTIVIDAD = p_pk_tactividad;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la actividad solicitada' USING ERRCODE = 'P0002';
    END IF;

    CASE v_valor
        WHEN 'RUBRICA' THEN
            PERFORM academico_test.fn_actividad_rubrica_definir(
                        p_pk_usuario_solicitante, p_pk_tactividad, p_definicion);
        WHEN 'LISTA_COTEJO' THEN
            PERFORM academico_test.fn_actividad_cotejo_definir(
                        p_pk_usuario_solicitante, p_pk_tactividad, p_definicion);
        WHEN 'ESCALA_VALORACION' THEN
            PERFORM academico_test.fn_actividad_escala_definir(
                        p_pk_usuario_solicitante, p_pk_tactividad, p_definicion);
        WHEN 'OTRO' THEN
            -- V240: p_definicion es aqui el p_config de fn_actividad_otro_definir
            -- {tipoEvidencia, metodoValoracion, definicion}.
            PERFORM academico_test.fn_actividad_otro_definir(
                        p_pk_usuario_solicitante, p_pk_tactividad, p_definicion);
        ELSE
            RAISE EXCEPTION 'La actividad no tiene un instrumento de evaluacion valido para definir (%)',
                COALESCE(v_valor, 'sin instrumento') USING ERRCODE = '22023';
    END CASE;

    RETURN v_valor;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_instrumento_definir(BIGINT, BIGINT, JSONB)
    IS 'Fachada: lee TACTIVIDAD.FK_TLV_INSTRUMENTO_EVALUACION y despacha a fn_actividad_rubrica_definir (array de criterios), fn_actividad_cotejo_definir (array de items), fn_actividad_escala_definir (objeto de config) o fn_actividad_otro_definir (objeto {tipoEvidencia, metodoValoracion, definicion} — V240). Gate EDITAR sobre PLANEADOR (via las funciones destino). Retorna el VALOR del instrumento aplicado. V226/V240.';

-- ===========================================================================
-- fn_actividad_instrumento_obtener — CREATE OR REPLACE: la rama OTRO ahora
-- devuelve tipoEvidencia + metodoValoracion + la definicion de la estructura
-- reutilizada (mismo formato JSONB que ya arman las ramas RUBRICA /
-- LISTA_COTEJO / ESCALA_VALORACION, sin diverger).
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_instrumento_obtener(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad            BIGINT
)
RETURNS TABLE (
    instrumento         VARCHAR,
    instrumento_nombre  VARCHAR,
    definicion          JSONB
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    RETURN QUERY
    SELECT lv.VALOR,
           lv.NOMBRE,
           CASE lv.VALOR
               WHEN 'RUBRICA' THEN COALESCE((
                   SELECT jsonb_agg(jsonb_build_object(
                              'pk',          c.PK_TACTIVIDAD_RUBRICA_CRITERIO,
                              'orden',       c.ORDEN,
                              'nombre',      c.NOMBRE,
                              'descripcion', c.DESCRIPCION,
                              'niveles', COALESCE((
                                  SELECT jsonb_agg(jsonb_build_object(
                                             'pk',          n.PK_TACTIVIDAD_RUBRICA_NIVEL,
                                             'etiqueta',    n.ETIQUETA,
                                             'descripcion', n.DESCRIPCION,
                                             'ponderacion', n.PONDERACION)
                                             ORDER BY n.PONDERACION DESC)
                                    FROM academico_test.TACTIVIDAD_RUBRICA_NIVEL n
                                   WHERE n.FK_TACTIVIDAD_RUBRICA_CRITERIO = c.PK_TACTIVIDAD_RUBRICA_CRITERIO
                                     AND n.ACTIVE = TRUE
                              ), '[]'::jsonb))
                              ORDER BY c.ORDEN)
                     FROM academico_test.TACTIVIDAD_RUBRICA_CRITERIO c
                    WHERE c.FK_TACTIVIDAD = a.PK_TACTIVIDAD AND c.ACTIVE = TRUE
               ), '[]'::jsonb)

               WHEN 'LISTA_COTEJO' THEN COALESCE((
                   SELECT jsonb_agg(jsonb_build_object(
                              'pk',          i.PK_TACTIVIDAD_COTEJO_ITEM,
                              'orden',       i.ORDEN,
                              'descripcion', i.DESCRIPCION,
                              'ponderacion', i.PONDERACION)
                              ORDER BY i.ORDEN)
                     FROM academico_test.TACTIVIDAD_COTEJO_ITEM i
                    WHERE i.FK_TACTIVIDAD = a.PK_TACTIVIDAD AND i.ACTIVE = TRUE
               ), '[]'::jsonb)

               WHEN 'ESCALA_VALORACION' THEN (
                   SELECT jsonb_build_object(
                              'pk',                   e.PK_TACTIVIDAD_ESCALA,
                              'tipoEscala',           e.FK_TLV_TIPO_ESCALA,
                              'tipoEscalaNombre',     lte.NOMBRE,
                              'tipoEscalaValor',      lte.VALOR,
                              'criteriosGenerales',   e.CRITERIOS_GENERALES,
                              'valorMin',             e.VALOR_MIN,
                              'valorMax',             e.VALOR_MAX,
                              'interpretacionRangos', e.INTERPRETACION_RANGOS,
                              'niveles', COALESCE((
                                  SELECT jsonb_agg(jsonb_build_object(
                                             'pk',          en.PK_TACTIVIDAD_ESCALA_NIVEL,
                                             'orden',       en.ORDEN,
                                             'etiqueta',    en.ETIQUETA,
                                             'descripcion', en.DESCRIPCION,
                                             'ponderacion', en.PONDERACION)
                                             ORDER BY en.ORDEN)
                                    FROM academico_test.TACTIVIDAD_ESCALA_NIVEL en
                                   WHERE en.FK_TACTIVIDAD_ESCALA = e.PK_TACTIVIDAD_ESCALA
                                     AND en.ACTIVE = TRUE
                              ), '[]'::jsonb))
                     FROM academico_test.TACTIVIDAD_ESCALA e
                     LEFT JOIN academico_test.TLISTA_VALOR lte ON lte.PK_LISTA_VALOR = e.FK_TLV_TIPO_ESCALA
                    WHERE e.FK_TACTIVIDAD = a.PK_TACTIVIDAD AND e.ACTIVE = TRUE
               )

               WHEN 'OTRO' THEN (
                   SELECT jsonb_build_object(
                              'pk',                     o.PK_TACTIVIDAD_OTRO,
                              'tipoEvidencia',           o.FK_TLV_TIPO_EVIDENCIA_OTRO,
                              'tipoEvidenciaNombre',     lte.NOMBRE,
                              'metodoValoracion',        o.FK_TLV_METODO_VALORACION,
                              'metodoValoracionNombre',  lvm.NOMBRE,
                              'metodoValoracionValor',   lvm.VALOR,
                              'definicion', CASE lvm.VALOR
                                  WHEN 'RUBRICA' THEN COALESCE((
                                      SELECT jsonb_agg(jsonb_build_object(
                                                 'pk',          c.PK_TACTIVIDAD_RUBRICA_CRITERIO,
                                                 'orden',       c.ORDEN,
                                                 'nombre',      c.NOMBRE,
                                                 'descripcion', c.DESCRIPCION,
                                                 'niveles', COALESCE((
                                                     SELECT jsonb_agg(jsonb_build_object(
                                                                'pk',          n.PK_TACTIVIDAD_RUBRICA_NIVEL,
                                                                'etiqueta',    n.ETIQUETA,
                                                                'descripcion', n.DESCRIPCION,
                                                                'ponderacion', n.PONDERACION)
                                                                ORDER BY n.PONDERACION DESC)
                                                       FROM academico_test.TACTIVIDAD_RUBRICA_NIVEL n
                                                      WHERE n.FK_TACTIVIDAD_RUBRICA_CRITERIO = c.PK_TACTIVIDAD_RUBRICA_CRITERIO
                                                        AND n.ACTIVE = TRUE
                                                 ), '[]'::jsonb))
                                                 ORDER BY c.ORDEN)
                                        FROM academico_test.TACTIVIDAD_RUBRICA_CRITERIO c
                                       WHERE c.FK_TACTIVIDAD = a.PK_TACTIVIDAD AND c.ACTIVE = TRUE
                                  ), '[]'::jsonb)

                                  WHEN 'LISTA_COTEJO' THEN COALESCE((
                                      SELECT jsonb_agg(jsonb_build_object(
                                                 'pk',          i.PK_TACTIVIDAD_COTEJO_ITEM,
                                                 'orden',       i.ORDEN,
                                                 'descripcion', i.DESCRIPCION,
                                                 'ponderacion', i.PONDERACION)
                                                 ORDER BY i.ORDEN)
                                        FROM academico_test.TACTIVIDAD_COTEJO_ITEM i
                                       WHERE i.FK_TACTIVIDAD = a.PK_TACTIVIDAD AND i.ACTIVE = TRUE
                                  ), '[]'::jsonb)

                                  WHEN 'ESCALA_VALORACION' THEN (
                                      SELECT jsonb_build_object(
                                                 'pk',                   e.PK_TACTIVIDAD_ESCALA,
                                                 'tipoEscala',           e.FK_TLV_TIPO_ESCALA,
                                                 'tipoEscalaNombre',     lte2.NOMBRE,
                                                 'tipoEscalaValor',      lte2.VALOR,
                                                 'criteriosGenerales',   e.CRITERIOS_GENERALES,
                                                 'valorMin',             e.VALOR_MIN,
                                                 'valorMax',             e.VALOR_MAX,
                                                 'interpretacionRangos', e.INTERPRETACION_RANGOS,
                                                 'niveles', COALESCE((
                                                     SELECT jsonb_agg(jsonb_build_object(
                                                                'pk',          en.PK_TACTIVIDAD_ESCALA_NIVEL,
                                                                'orden',       en.ORDEN,
                                                                'etiqueta',    en.ETIQUETA,
                                                                'descripcion', en.DESCRIPCION,
                                                                'ponderacion', en.PONDERACION)
                                                                ORDER BY en.ORDEN)
                                                       FROM academico_test.TACTIVIDAD_ESCALA_NIVEL en
                                                      WHERE en.FK_TACTIVIDAD_ESCALA = e.PK_TACTIVIDAD_ESCALA
                                                        AND en.ACTIVE = TRUE
                                                 ), '[]'::jsonb))
                                        FROM academico_test.TACTIVIDAD_ESCALA e
                                        LEFT JOIN academico_test.TLISTA_VALOR lte2 ON lte2.PK_LISTA_VALOR = e.FK_TLV_TIPO_ESCALA
                                       WHERE e.FK_TACTIVIDAD = a.PK_TACTIVIDAD AND e.ACTIVE = TRUE
                                  )
                                  ELSE NULL
                              END)
                     FROM academico_test.TACTIVIDAD_OTRO o
                     LEFT JOIN academico_test.TLISTA_VALOR lte ON lte.PK_LISTA_VALOR = o.FK_TLV_TIPO_EVIDENCIA_OTRO
                     LEFT JOIN academico_test.TLISTA_VALOR lvm ON lvm.PK_LISTA_VALOR = o.FK_TLV_METODO_VALORACION
                    WHERE o.FK_TACTIVIDAD = a.PK_TACTIVIDAD AND o.ACTIVE = TRUE
               )

               ELSE NULL
           END
      FROM academico_test.TACTIVIDAD a
      LEFT JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = a.FK_TLV_INSTRUMENTO_EVALUACION
     WHERE a.PK_TACTIVIDAD = p_pk_tactividad;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_instrumento_obtener(BIGINT, BIGINT)
    IS 'Lee el instrumento de evaluacion definido para una actividad: devuelve su VALOR/NOMBRE y la definicion como JSONB segun el tipo — RUBRICA: [{pk,orden,nombre,descripcion,niveles:[{pk,etiqueta,descripcion,ponderacion}]}] (niveles ordenados por ponderacion DESC); LISTA_COTEJO: [{pk,orden,descripcion,ponderacion}]; ESCALA_VALORACION: {tipoEscala,criteriosGenerales,valorMin,valorMax,interpretacionRangos,niveles:[...]}; OTRO: {pk,tipoEvidencia,tipoEvidenciaNombre,metodoValoracion,metodoValoracionNombre,metodoValoracionValor,definicion} donde definicion reutiliza el MISMO formato de RUBRICA/LISTA_COTEJO/ESCALA_VALORACION segun el metodo elegido; sin instrumento: NULL. Gate VER sobre PLANEADOR. V226/V240.';
