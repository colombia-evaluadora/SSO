-- Que hace: quita las 4 UNIQUE de TESCALA(codigo/nombre) y
-- TVALORACION(codigo/nombre).
--
-- Por que aqui: V71 convirtio 84 UNIQUE a indice parcial WHERE active=true,
-- pero estas 4 no salen ahi ni en ninguna otra migracion: en test las
-- borraron a mano y produccion las conserva del dump. Esto lo documenta.
--
-- NO se reemplazan por indice parcial, a diferencia del resto de V71: no hay
-- FK a establecimiento y cada uno define su propia escala, asi que la
-- unicidad global es incorrecta. Evidencia en test: 8 escalas activas
-- 'Basica Primaria' y 76 valoraciones activas con codigo 'BJ'. Las
-- fn_*_crear de V42 tampoco validan duplicados por codigo/nombre.

ALTER TABLE academico_test.TESCALA     DROP CONSTRAINT IF EXISTS u_tescala_1;
ALTER TABLE academico_test.TESCALA     DROP CONSTRAINT IF EXISTS u_tescala_2;
ALTER TABLE academico_test.TVALORACION DROP CONSTRAINT IF EXISTS u_tvaloracion_codigo;
ALTER TABLE academico_test.TVALORACION DROP CONSTRAINT IF EXISTS u_valoracion_1;

-- En una base donde el objeto nacio como indice suelto y no como constraint,
-- el DROP CONSTRAINT de arriba no lo toca.
DROP INDEX IF EXISTS academico_test.u_tescala_1;
DROP INDEX IF EXISTS academico_test.u_tescala_2;
DROP INDEX IF EXISTS academico_test.u_tvaloracion_codigo;
DROP INDEX IF EXISTS academico_test.u_valoracion_1;
