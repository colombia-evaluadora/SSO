-- V226 - Instrumentos de evaluación de una actividad: catálogo TIPO_ESCALA,
-- columnas de cotejo y niveles (PONDERACION, ETIQUETA) y el helper
-- fn_actividad_instrumento_reset. La definición de rúbrica, lista de cotejo,
-- escala y Otro vive hoy en V496.5 (validaciones) y V496.6 (_interno), y la
-- fachada del endpoint en V496.3.
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
