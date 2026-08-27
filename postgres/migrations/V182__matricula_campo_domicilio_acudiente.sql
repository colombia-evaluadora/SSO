-- ===========================================================================
--  Cobertura Matricula (CU-86e2z8aff) -- seccion "Domicilio del acudiente".
--
--  La UI tiene una tarjeta "Domicilio del acudiente" (entre "Informacion
--  del acudiente" y "Informacion de contacto del acudiente") con 3 campos
--  que no estaban en el seed de V158:
--    - Direccion de acudiente
--    - Lugar de residencia departamento acudiente
--    - Lugar de residencia municipio acudiente
--
--  Ademas: el orden de secciones en fn_matricula_config_obtener se calculaba
--  por MIN(PK_MATRICULA_CAMPO), asi que una seccion agregada despues (PKs
--  altos) caia al final. Se agrega TMATRICULA_CAMPO.SECCION_ORDEN para fijar
--  el orden de las tarjetas de forma explicita e independiente del PK.
--
--   1. TMATRICULA_CAMPO.SECCION_ORDEN (SMALLINT) + backfill de las 13 secciones.
--   2. Alta de los 3 campos nuevos (SECCION = 'Domicilio del acudiente',
--      SECCION_ORDEN = 11). Editables (columna destino nullable en TUSUARIO
--      del padre) -> heredan EDITABLE/REQUERIDO_DEFECTO/VISIBLE_DEFECTO por
--      default ('S'/'S'/'S').
--   3. Propagacion a las TMATRICULA_CONFIG existentes (ON CONFLICT DO NOTHING).
--   4. fn_matricula_config_obtener ordena las secciones por SECCION_ORDEN.
-- ===========================================================================

SET client_min_messages TO WARNING;
SET search_path TO academico_test, public;

-- ---------------------------------------------------------------------------
-- 1) Orden explicito de secciones.
-- ---------------------------------------------------------------------------
ALTER TABLE TMATRICULA_CAMPO
    ADD COLUMN IF NOT EXISTS SECCION_ORDEN SMALLINT;

COMMENT ON COLUMN TMATRICULA_CAMPO.SECCION_ORDEN IS
    'Orden de la seccion/tarjeta en la UI de configuracion de matricula. Constante por SECCION.';

UPDATE TMATRICULA_CAMPO mc
   SET SECCION_ORDEN = v.orden
  FROM (VALUES
    ('Información de matrícula',                1),
    ('Información del estudiante',              2),
    ('Domicilio del estudiante',               3),
    ('Información de contacto del estudiante',  4),
    ('Información académica del año anterior',  5),
    ('Sector de origen',                       6),
    ('Víctima conflicto armado',               7),
    ('Información complementaria',              8),
    ('Subsidio o beneficios',                  9),
    ('Información del acudiente',              10),
    ('Domicilio del acudiente',               11),
    ('Información de contacto del acudiente',  12),
    ('Información laboral del acudiente',      13)
  ) AS v(seccion, orden)
 WHERE mc.SECCION = v.seccion
   AND mc.SECCION_ORDEN IS DISTINCT FROM v.orden;

-- ---------------------------------------------------------------------------
-- 2) Alta de los 3 campos de "Domicilio del acudiente". Idempotente por NOMBRE.
-- ---------------------------------------------------------------------------
INSERT INTO TMATRICULA_CAMPO (NOMBRE, SECCION, SECCION_ORDEN, CREATED_BY)
SELECT v.nombre, 'Domicilio del acudiente', 11, 'V182_seed'
  FROM (VALUES
    ('Direccion de acudiente'),
    ('Lugar de residencia departamento acudiente'),
    ('Lugar de residencia municipio acudiente')
  ) AS v(nombre)
 WHERE NOT EXISTS (
       SELECT 1 FROM TMATRICULA_CAMPO mc WHERE mc.NOMBRE = v.nombre
 );

-- ---------------------------------------------------------------------------
-- 3) Propagar los 3 campos nuevos a las configuraciones ya existentes,
--    con su definicion por defecto. ON CONFLICT DO NOTHING => idempotente.
-- ---------------------------------------------------------------------------
INSERT INTO TMATRICULA_VALOR (
    REQUERIDO, VISIBLE, FK_TMATRICULA_CONFIG, FK_TMATRICULA_CAMPO, CREATED_BY
)
SELECT mc.REQUERIDO_DEFECTO, mc.VISIBLE_DEFECTO, c.PK_MATRICULA_CONFIG, mc.PK_MATRICULA_CAMPO, 'V182_seed'
  FROM TMATRICULA_CONFIG c
  CROSS JOIN TMATRICULA_CAMPO mc
 WHERE mc.SECCION = 'Domicilio del acudiente'
   AND mc.ACTIVE  = TRUE
ON CONFLICT (FK_TMATRICULA_CONFIG, FK_TMATRICULA_CAMPO) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 4) fn_matricula_config_obtener -- ordena secciones por SECCION_ORDEN
--    (fallback al PK si alguna seccion no lo tuviera).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_matricula_config_obtener(
    p_pk_usuario_solicitante BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_fk_est    BIGINT;
    v_pk_config BIGINT;
    v_result    JSONB;
BEGIN
    v_fk_est    := academico_test.fn_matricula_config_ee_solicitante(p_pk_usuario_solicitante);
    v_pk_config := academico_test.fn_matricula_config_crear_interno(
                       v_fk_est, p_pk_usuario_solicitante::VARCHAR);

    SELECT jsonb_build_object(
               'fk_establecimiento',  v_fk_est,
               'establecimiento',     (SELECT NOMBRE FROM academico_test.TESTABLECIMIENTO
                                        WHERE PK_ESTABLECIMIENTO = v_fk_est),
               'pk_matricula_config', v_pk_config,
               'secciones', COALESCE((
                   SELECT jsonb_agg(s.seccion_obj ORDER BY s.orden, s.seccion)
                     FROM (
                         SELECT COALESCE(mc.SECCION, 'Otros') AS seccion,
                                MIN(COALESCE(mc.SECCION_ORDEN, 32767)) AS orden,
                                jsonb_build_object(
                                    'seccion', COALESCE(mc.SECCION, 'Otros'),
                                    'campos',  jsonb_agg(jsonb_build_object(
                                                   'fk_campo',  mc.PK_MATRICULA_CAMPO,
                                                   'nombre',    mc.NOMBRE,
                                                   'editable',  (mc.EDITABLE  = 'S'),
                                                   'requerido', (mv.REQUERIDO = 'S'),
                                                   'visible',   (mv.VISIBLE   = 'S')
                                               ) ORDER BY mc.PK_MATRICULA_CAMPO)
                                ) AS seccion_obj
                           FROM academico_test.TMATRICULA_VALOR mv
                           JOIN academico_test.TMATRICULA_CAMPO mc
                             ON mc.PK_MATRICULA_CAMPO = mv.FK_TMATRICULA_CAMPO
                          WHERE mv.FK_TMATRICULA_CONFIG = v_pk_config
                            AND mc.ACTIVE = TRUE
                          GROUP BY COALESCE(mc.SECCION, 'Otros')
                     ) s
               ), '[]'::jsonb)
           )
      INTO v_result;

    RETURN v_result;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_matricula_config_obtener(BIGINT) IS
    'Devuelve la configuracion de matricula del establecimiento del solicitante (rector/secretaria/jefe de sistema) AGRUPADA por seccion: { fk_establecimiento, establecimiento, pk_matricula_config, secciones: [ { seccion, campos: [ { fk_campo, nombre, editable, requerido, visible } ] } ] }. Orden de secciones por TMATRICULA_CAMPO.SECCION_ORDEN; orden de campos por PK_MATRICULA_CAMPO. Flags como booleanos. 42501 sin rol, 22023 si administra 2+ EE.';
