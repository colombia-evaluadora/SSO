-- ===========================================================================
--  Cobertura Matricula (CU-86e2z8aff) -- campo "Genero del acudiente".
--
--  Se agrega al catalogo de campos configurables (TMATRICULA_CAMPO, seed
--  original en V158) el campo "Genero del acudiente", en la seccion
--  "Informacion del acudiente" (SECCION_ORDEN 10, ver V181/V182).
--
--  NO editable: el dato vive en el TUSUARIO del acudiente (tpadre -> tusuario)
--  y TUSUARIO.FK_TLV_GENERO tiene constraint NOT NULL -- misma regla que
--  los otros 11 campos con EDITABLE='N': su REQUERIDO/VISIBLE quedan fijos
--  en 'S'/'S' (el candado trg_matricula_valor_no_editable de V159 lo
--  refuerza en cualquier via de escritura).
--
--   1. Alta del campo (idempotente por NOMBRE).
--   2. Propagacion a las TMATRICULA_CONFIG existentes con su valor por
--      defecto ('S'/'S'). ON CONFLICT DO NOTHING => idempotente.
-- ===========================================================================

SET client_min_messages TO WARNING;
SET search_path TO academico_test, public;

-- ---------------------------------------------------------------------------
-- 1) Alta del campo "Genero del acudiente" (no editable).
-- ---------------------------------------------------------------------------
INSERT INTO TMATRICULA_CAMPO (
    NOMBRE, EDITABLE, REQUERIDO_DEFECTO, VISIBLE_DEFECTO,
    SECCION, SECCION_ORDEN, CREATED_BY
)
SELECT 'Genero del acudiente', 'N', 'S', 'S',
       'Información del acudiente', 10, 'V217_seed'
 WHERE NOT EXISTS (
       SELECT 1 FROM TMATRICULA_CAMPO mc WHERE mc.NOMBRE = 'Genero del acudiente'
 );

-- ---------------------------------------------------------------------------
-- 2) Propagar el campo nuevo a las configuraciones ya existentes.
-- ---------------------------------------------------------------------------
INSERT INTO TMATRICULA_VALOR (
    REQUERIDO, VISIBLE, FK_TMATRICULA_CONFIG, FK_TMATRICULA_CAMPO, CREATED_BY
)
SELECT mc.REQUERIDO_DEFECTO, mc.VISIBLE_DEFECTO, c.PK_MATRICULA_CONFIG, mc.PK_MATRICULA_CAMPO, 'V217_seed'
  FROM TMATRICULA_CONFIG c
  CROSS JOIN TMATRICULA_CAMPO mc
 WHERE mc.NOMBRE  = 'Genero del acudiente'
   AND mc.ACTIVE  = TRUE
ON CONFLICT (FK_TMATRICULA_CONFIG, FK_TMATRICULA_CAMPO) DO NOTHING;
