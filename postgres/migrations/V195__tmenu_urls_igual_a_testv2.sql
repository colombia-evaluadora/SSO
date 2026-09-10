-- ===========================================================================
-- V195 - corrige las URL de academico_test.tmenu para que coincidan
--        exactamente con testv2 (172.233.184.248), la referencia con las
--        rutas reales del frontend de Colombia Evaluadora.
--
-- POR QUE ESTA MIGRACION EXISTE
--   Comparando tmenu.url ítem por ítem contra testv2 (mismo NOMBRE, ver
--   V193 para el mapeo de PKs) aparecieron dos problemas:
--
--   1. Los 4 ítems GROUP (padres) tenían la MISMA url que su primer hijo
--      en vez de una propia (testv2 usa '/app/<seccion>/general' o NULL).
--      P.ej. 'Establecimiento Educativo' (padre) y 'Establecimiento'
--      (hijo) compartían literalmente '/establecimiento-educativo/
--      establecimiento' -- un bug de cómo se sembró esta tabla aquí.
--
--   2. A los ítems (hijos) les faltaba el prefijo '/app' que sí llevan
--      en testv2, y en algunos casos el segmento intermedio también
--      difería (p.ej. 'cobertura-educativa' vs 'cobertura', 'periodos-
--      academicos' vs 'periodos').
--
--   'Equipo', 'Roles', 'Referentes Curriculares' y 'Planeador' ya
--   coincidían exactamente entre ambos entornos -- no se tocan.
--
-- GUARD DE IDEMPOTENCIA
--   Cada UPDATE exige el valor VIEJO conocido (el que trajo la migración
--   original) antes de escribir el nuevo. Si alguien ya editó una de
--   estas URLs a mano después de esa siembra, esta migración no la pisa
--   en silencio.
-- ===========================================================================

UPDATE academico_test.tmenu SET url = '/app/establecimiento-educativo/general'
 WHERE pk_tmenu = 1 AND nombre = 'Establecimiento Educativo'
   AND url = '/establecimiento-educativo/establecimiento';

UPDATE academico_test.tmenu SET url = '/app/registro-de-actividad/sesiones'
 WHERE pk_tmenu = 2 AND nombre = 'Administración'
   AND url = '/administracion/registro-actividad';

UPDATE academico_test.tmenu SET url = NULL
 WHERE pk_tmenu = 3 AND nombre = 'Usuarios'
   AND url = '/usuarios/equipo';

UPDATE academico_test.tmenu SET url = NULL
 WHERE pk_tmenu = 4 AND nombre = 'Cobertura Educativa'
   AND url = '/cobertura-educativa/pre-matricula';

UPDATE academico_test.tmenu SET url = '/app/establecimiento-educativo/general'
 WHERE pk_tmenu = 5 AND nombre = 'Establecimiento'
   AND url = '/establecimiento-educativo/establecimiento';

UPDATE academico_test.tmenu SET url = '/app/establecimiento-educativo/sedes'
 WHERE pk_tmenu = 6 AND nombre = 'Sedes Educativas'
   AND url = '/establecimiento-educativo/sedes';

UPDATE academico_test.tmenu SET url = '/app/establecimiento-educativo/funcionarios'
 WHERE pk_tmenu = 7 AND nombre = 'Funcionarios'
   AND url = '/establecimiento-educativo/funcionarios';

UPDATE academico_test.tmenu SET url = '/app/establecimiento-educativo/periodos'
 WHERE pk_tmenu = 8 AND nombre = 'Periodos Académicos'
   AND url = '/establecimiento-educativo/periodos-academicos';

UPDATE academico_test.tmenu SET url = '/app/registro-de-actividad/sesiones'
 WHERE pk_tmenu = 9 AND nombre = 'Registro de actividad'
   AND url = '/administracion/registro-actividad';

UPDATE academico_test.tmenu SET url = '/app/administracion/roles-menus'
 WHERE pk_tmenu = 10 AND nombre = 'Configuración de roles y menús'
   AND url = '/administracion/roles-menus';

UPDATE academico_test.tmenu SET url = '/app/cobertura/pre-matricula'
 WHERE pk_tmenu = 13 AND nombre = 'Pre-Matrícula'
   AND url = '/cobertura-educativa/pre-matricula';

UPDATE academico_test.tmenu SET url = '/app/cobertura/inscritos'
 WHERE pk_tmenu = 14 AND nombre = 'Inscritos'
   AND url = '/cobertura-educativa/inscritos';

UPDATE academico_test.tmenu SET url = '/app/cobertura/matricula'
 WHERE pk_tmenu = 15 AND nombre = 'Matrícula'
   AND url = '/cobertura-educativa/matricula';
