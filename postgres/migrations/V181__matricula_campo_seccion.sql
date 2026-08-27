-- ===========================================================================
--  Cobertura Matricula (CU-86e2z8aff) -- seccion de cada campo del catalogo.
--
--  La UI de "Configuracion de parametros requeridos" agrupa los campos en
--  tarjetas por seccion ("Informacion de matricula", "Informacion del
--  estudiante", "Domicilio del estudiante", ...). El catalogo
--  TMATRICULA_CAMPO no llevaba esa agrupacion, asi que el endpoint de
--  lectura devolvia una lista plana y el front tenia que agrupar a mano.
--
--   1. TMATRICULA_CAMPO.SECCION: etiqueta de la tarjeta a la que pertenece
--      el campo (texto tal cual lo muestra la UI).
--   2. Seed de SECCION para los 61 campos de V158, en el mismo agrupamiento
--      que ya usaban los comentarios de esa migracion.
--   3. fn_matricula_config_obtener pasa a devolver la config YA AGRUPADA por
--      seccion: { ..., secciones: [ { seccion, campos: [...] } ] }. El orden
--      de secciones y de campos dentro de cada seccion respeta el orden del
--      catalogo (PK_MATRICULA_CAMPO). fn_matricula_config_editar_campo no
--      cambia: ya delega la respuesta en fn_matricula_config_obtener.
-- ===========================================================================

SET client_min_messages TO WARNING;
SET search_path TO academico_test, public;

-- ---------------------------------------------------------------------------
-- 1) Columna SECCION.
-- ---------------------------------------------------------------------------
ALTER TABLE TMATRICULA_CAMPO
    ADD COLUMN IF NOT EXISTS SECCION VARCHAR(80);

COMMENT ON COLUMN TMATRICULA_CAMPO.SECCION IS
    'Seccion / tarjeta de la UI de configuracion de matricula a la que pertenece el campo (encabezado de grupo).';

-- ---------------------------------------------------------------------------
-- 2) Seed de SECCION para los 61 campos (V158). Idempotente por NOMBRE.
-- ---------------------------------------------------------------------------
UPDATE TMATRICULA_CAMPO mc
   SET SECCION = v.seccion
  FROM (VALUES
    -- Informacion de matricula
    ('Sede',                                               'Información de matrícula'),
    ('Jornada',                                            'Información de matrícula'),
    ('Grado',                                              'Información de matrícula'),
    ('Grupo',                                              'Información de matrícula'),
    ('Estado de la matricula',                             'Información de matrícula'),
    ('Caracter / Especialidad / Enfasis',                  'Información de matrícula'),
    -- Informacion del estudiante
    ('Tipo de documento del estudiante',                   'Información del estudiante'),
    ('Documento estudiante',                               'Información del estudiante'),
    ('Nombre del estudiante',                              'Información del estudiante'),
    ('Segundo nombre del estudiante',                      'Información del estudiante'),
    ('Primer apellido del estudiante',                     'Información del estudiante'),
    ('Segundo apellido del estudiante',                    'Información del estudiante'),
    ('Lugar expedicion documento estudiante departamento', 'Información del estudiante'),
    ('Lugar expedicion documento estudiante municipio',    'Información del estudiante'),
    ('Fecha de nacimiento',                                'Información del estudiante'),
    ('Lugar de nacimiento departamento',                   'Información del estudiante'),
    ('Lugar de nacimiento municipio',                      'Información del estudiante'),
    ('Genero del estudiante',                              'Información del estudiante'),
    ('Etnia / Resguardo',                                  'Información del estudiante'),
    -- Domicilio del estudiante
    ('Direccion del estudiante',                           'Domicilio del estudiante'),
    ('Lugar de residencia departamento estudiante',        'Domicilio del estudiante'),
    ('Lugar de residencia municipio estudiante',           'Domicilio del estudiante'),
    -- Informacion de contacto del estudiante
    ('Telefono de estudiante',                             'Información de contacto del estudiante'),
    ('Email estudiante',                                   'Información de contacto del estudiante'),
    -- Informacion academica del ano anterior
    ('Situacion del ano anterior',                         'Información académica del año anterior'),
    ('Condicion del estudiante fin del ano anterior',      'Información académica del año anterior'),
    ('Nombre de la institucion anterior',                  'Información académica del año anterior'),
    ('Institucion bienestar de origen',                    'Información académica del año anterior'),
    -- Sector de origen
    ('Proviene de sector privado',                         'Sector de origen'),
    ('Proviene de otro municipio',                         'Sector de origen'),
    ('Cual',                                               'Sector de origen'),
    -- Victima conflicto armado
    ('Poblacion victima conflicto',                        'Víctima conflicto armado'),
    ('Ultimo municipio expulsor',                          'Víctima conflicto armado'),
    -- Informacion complementaria
    ('Estrato socio economico del estudiante',             'Información complementaria'),
    ('Sisben',                                             'Información complementaria'),
    ('EPS',                                                'Información complementaria'),
    ('ARS',                                                'Información complementaria'),
    ('Condiciones especiales del estudiante',              'Información complementaria'),
    ('Talento del estudiante',                             'Información complementaria'),
    -- Subsidio o beneficios
    ('Subsidiado',                                         'Subsidio o beneficios'),
    ('Fuente de recursos',                                 'Subsidio o beneficios'),
    ('Alumnos madre cabeza de familia',                    'Subsidio o beneficios'),
    ('Hijos de madre cabeza de familia',                   'Subsidio o beneficios'),
    ('Veteranos de la fuerza publica',                     'Subsidio o beneficios'),
    ('Heroes de la nacion',                                'Subsidio o beneficios'),
    -- Informacion del acudiente
    ('Parentesco',                                         'Información del acudiente'),
    ('Nombre del acudiente',                               'Información del acudiente'),
    ('Segundo nombre del acudiente',                       'Información del acudiente'),
    ('Primer apellido del acudiente',                      'Información del acudiente'),
    ('Segundo apellido del acudiente',                     'Información del acudiente'),
    ('Tipo de documento del acudiente',                    'Información del acudiente'),
    ('Documento acudiente',                                'Información del acudiente'),
    ('Lugar expedicion documento acudiente departamento',  'Información del acudiente'),
    ('Lugar expedicion documento acudiente municipio',     'Información del acudiente'),
    -- Informacion de contacto del acudiente
    ('Telefono de acudiente',                              'Información de contacto del acudiente'),
    ('Email acudiente',                                    'Información de contacto del acudiente'),
    -- Informacion laboral del acudiente
    ('Profesion acudiente',                                'Información laboral del acudiente'),
    ('Nombre de la entidad acudiente',                     'Información laboral del acudiente'),
    ('Direccion de la entidad acudiente',                  'Información laboral del acudiente'),
    ('Telefono de la entidad acudiente',                   'Información laboral del acudiente'),
    ('Cargo entidad acudiente',                            'Información laboral del acudiente')
  ) AS v(nombre, seccion)
 WHERE mc.NOMBRE = v.nombre
   AND mc.SECCION IS DISTINCT FROM v.seccion;

-- ---------------------------------------------------------------------------
-- 3) fn_matricula_config_obtener -- salida AGRUPADA por seccion.
--
--    { fk_establecimiento, establecimiento, pk_matricula_config,
--      secciones: [ { seccion, campos: [ { fk_campo, nombre, editable,
--                                          requerido, visible } ] } ] }
--
--    Orden de secciones = orden del primer campo de cada seccion en el
--    catalogo (MIN(PK_MATRICULA_CAMPO)); orden de campos dentro de la
--    seccion = PK_MATRICULA_CAMPO. Campos sin SECCION caen en "Otros".
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
                   SELECT jsonb_agg(s.seccion_obj ORDER BY s.orden)
                     FROM (
                         SELECT COALESCE(mc.SECCION, 'Otros') AS seccion,
                                MIN(mc.PK_MATRICULA_CAMPO)    AS orden,
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
    'Devuelve, para el establecimiento del que el solicitante es rector/secretaria/jefe de sistema (fn_matricula_config_ee_solicitante), su configuracion de matricula AGRUPADA por seccion: { fk_establecimiento, establecimiento, pk_matricula_config, secciones: [ { seccion, campos: [ { fk_campo, nombre, editable, requerido, visible } ] } ] }. Flags como booleanos. Orden de secciones = primer campo de cada seccion en el catalogo; orden de campos = PK_MATRICULA_CAMPO. 42501 sin rol, 22023 si administra 2+ EE.';
