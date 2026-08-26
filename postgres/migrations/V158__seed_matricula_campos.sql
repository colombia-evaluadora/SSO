-- ===========================================================================
--  Seed de TMATRICULA_CAMPO: catalogo de campos que un establecimiento
--  puede marcar como requerido / visible en su configuracion de matricula
--  (ver V157 y el CU-86e2z8aff).
--
--  Los nombres salen 1:1 de las pantallas de "Configuracion de matricula"
--  agrupados por seccion (la seccion es solo un comentario aqui: el
--  catalogo es plano). EDITABLE toma el default 'S'. TABLA / CAMPO_DESTINO
--  quedan NULL: se completan cuando se cablee cada campo a su columna real.
--
--  Idempotente: solo inserta los NOMBRE que aun no existen.
-- ===========================================================================

SET client_min_messages TO WARNING;
SET search_path TO academico_test, public;

INSERT INTO TMATRICULA_CAMPO (NOMBRE, CREATED_BY)
SELECT v.nombre, 'V158_seed'
  FROM (VALUES
    -- Informacion de matricula
    ('Sede'::VARCHAR),
    ('Jornada'),
    ('Grado'),
    ('Grupo'),
    ('Estado de la matricula'),
    ('Caracter / Especialidad / Enfasis'),
    -- Informacion del estudiante
    ('Tipo de documento del estudiante'),
    ('Documento estudiante'),
    ('Nombre del estudiante'),
    ('Segundo nombre del estudiante'),
    ('Primer apellido del estudiante'),
    ('Segundo apellido del estudiante'),
    ('Lugar expedicion documento estudiante departamento'),
    ('Lugar expedicion documento estudiante municipio'),
    ('Fecha de nacimiento'),
    ('Lugar de nacimiento departamento'),
    ('Lugar de nacimiento municipio'),
    ('Genero del estudiante'),
    ('Etnia / Resguardo'),
    -- Domicilio del estudiante
    ('Direccion del estudiante'),
    ('Lugar de residencia departamento estudiante'),
    ('Lugar de residencia municipio estudiante'),
    -- Informacion de contacto del estudiante
    ('Telefono de estudiante'),
    ('Email estudiante'),
    -- Informacion academica del ano anterior
    ('Situacion del ano anterior'),
    ('Condicion del estudiante fin del ano anterior'),
    ('Nombre de la institucion anterior'),
    ('Institucion bienestar de origen'),
    -- Sector de origen
    ('Proviene de sector privado'),
    ('Proviene de otro municipio'),
    ('Cual'),
    -- Victima conflicto armado
    ('Poblacion victima conflicto'),
    ('Ultimo municipio expulsor'),
    -- Informacion complementaria
    ('Estrato socio economico del estudiante'),
    ('Sisben'),
    ('EPS'),
    ('ARS'),
    ('Condiciones especiales del estudiante'),
    ('Talento del estudiante'),
    -- Subsidio o beneficios
    ('Subsidiado'),
    ('Fuente de recursos'),
    ('Alumnos madre cabeza de familia'),
    ('Hijos de madre cabeza de familia'),
    ('Veteranos de la fuerza publica'),
    ('Heroes de la nacion'),
    -- Informacion del acudiente
    ('Parentesco'),
    ('Nombre del acudiente'),
    ('Segundo nombre del acudiente'),
    ('Primer apellido del acudiente'),
    ('Segundo apellido del acudiente'),
    ('Tipo de documento del acudiente'),
    ('Documento acudiente'),
    ('Lugar expedicion documento acudiente departamento'),
    ('Lugar expedicion documento acudiente municipio'),
    -- Informacion de contacto del acudiente
    ('Telefono de acudiente'),
    ('Email acudiente'),
    -- Informacion laboral del acudiente
    ('Profesion acudiente'),
    ('Nombre de la entidad acudiente'),
    ('Direccion de la entidad acudiente'),
    ('Telefono de la entidad acudiente'),
    ('Cargo entidad acudiente')
  ) AS v(nombre)
 WHERE NOT EXISTS (
       SELECT 1
         FROM TMATRICULA_CAMPO mc
        WHERE mc.NOMBRE = v.nombre
       );
