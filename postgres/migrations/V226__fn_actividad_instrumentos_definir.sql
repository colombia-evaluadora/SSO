-- V226 - Instrumentos de evaluación de una actividad: catálogos TIPO_ESCALA y
-- TIPO_EVIDENCIA_OTRO, columnas de cotejo y niveles (PONDERACION, ETIQUETA),
-- la tabla TACTIVIDAD_OTRO del instrumento Otro con
-- fn_actividad_otro_metodo_valoracion, y el helper
-- fn_actividad_instrumento_reset. Definir el instrumento vive hoy en V496.5
-- (validaciones) y V496.6 (_interno), y la fachada del endpoint en V496.3.
-- Depende de: V22 (tablas de instrumento).

SET search_path TO academico_test, public;

INSERT INTO academico_test.tlista_valor (categoria, nombre, valor, created_by)
SELECT v.categoria, v.nombre, v.valor, 'V226_seed'
  FROM (VALUES
    ('TIPO_ESCALA'::VARCHAR, 'Numérica'::VARCHAR,    'NUMERICA'::VARCHAR),
    ('TIPO_ESCALA',          'Cualitativa',          'CUALITATIVA')
  ) AS v(categoria, nombre, valor)
 WHERE NOT EXISTS (
     SELECT 1 FROM academico_test.tlista_valor lv
      WHERE lv.categoria = v.categoria AND lv.valor = v.valor
 );

ALTER TABLE TACTIVIDAD_COTEJO_ITEM
  ADD COLUMN IF NOT EXISTS PONDERACION NUMERIC(5,2);

ALTER TABLE TACTIVIDAD_COTEJO_ITEM DROP CONSTRAINT IF EXISTS CK_TAC_COTEJO_ITEM_PONDERACION;

ALTER TABLE TACTIVIDAD_COTEJO_ITEM ADD CONSTRAINT CK_TAC_COTEJO_ITEM_PONDERACION
  CHECK (PONDERACION IS NULL OR (PONDERACION >= 0 AND PONDERACION <= 100));

COMMENT ON COLUMN TACTIVIDAD_COTEJO_ITEM.PONDERACION IS
  'Peso (%) OPCIONAL del item dentro de la lista de cotejo (0..100). NULL = el item no pondera. Se permite mezclar items con y sin peso y NO se exige que sumen 100. V226.';

ALTER TABLE TACTIVIDAD_RUBRICA_NIVEL ADD COLUMN IF NOT EXISTS ETIQUETA VARCHAR(130);

ALTER TABLE TACTIVIDAD_ESCALA_NIVEL  ADD COLUMN IF NOT EXISTS ETIQUETA VARCHAR(130);

COMMENT ON COLUMN TACTIVIDAD_RUBRICA_NIVEL.ETIQUETA IS
  'Rotulo del nivel de desempeno (ej: "Excelente", "Bueno"). El texto largo va en DESCRIPCION ("Descriptor por nivel" del figma). Nullable. V226.';

COMMENT ON COLUMN TACTIVIDAD_ESCALA_NIVEL.ETIQUETA IS
  'Rotulo del nivel de la escala cualitativa (ej: "Bajo", "Medio", "Alto"). El texto largo va en DESCRIPCION ("Interpretacion / descriptor" del figma). Nullable. V226.';

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_instrumento_reset(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad            BIGINT,
    
    p_conservar                VARCHAR DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    -- Rubrica: niveles antes que criterios (FK).
    IF p_conservar IS DISTINCT FROM 'RUBRICA' THEN
        UPDATE academico_test.TACTIVIDAD_RUBRICA_NIVEL n
           SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
          FROM academico_test.TACTIVIDAD_RUBRICA_CRITERIO c
         WHERE n.FK_TACTIVIDAD_RUBRICA_CRITERIO = c.PK_TACTIVIDAD_RUBRICA_CRITERIO
           AND c.FK_TACTIVIDAD = p_pk_tactividad
           AND n.ACTIVE = TRUE;
        UPDATE academico_test.TACTIVIDAD_RUBRICA_CRITERIO
           SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE;
    END IF;

    IF p_conservar IS DISTINCT FROM 'LISTA_COTEJO' THEN
        UPDATE academico_test.TACTIVIDAD_COTEJO_ITEM
           SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE;
    END IF;

    IF p_conservar IS DISTINCT FROM 'ESCALA_VALORACION' THEN
        UPDATE academico_test.TACTIVIDAD_ESCALA_NIVEL n
           SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
          FROM academico_test.TACTIVIDAD_ESCALA e
         WHERE n.FK_TACTIVIDAD_ESCALA = e.PK_TACTIVIDAD_ESCALA
           AND e.FK_TACTIVIDAD = p_pk_tactividad
           AND n.ACTIVE = TRUE;
        UPDATE academico_test.TACTIVIDAD_ESCALA
           SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE;
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_instrumento_reset(BIGINT, BIGINT, VARCHAR)
    IS 'Soft delete de los instrumentos de evaluacion de una actividad EXCEPTO el indicado en p_conservar (RUBRICA | LISTA_COTEJO | ESCALA_VALORACION; NULL = borra los tres). Una actividad tiene UN solo instrumento (TACTIVIDAD.FK_TLV_INSTRUMENTO_EVALUACION), asi que definir uno limpia los otros. Helper de fn_actividad_*_definir_interno (V496.6). V226.';

-- Instrumento Otro (antes V240/V241).
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
