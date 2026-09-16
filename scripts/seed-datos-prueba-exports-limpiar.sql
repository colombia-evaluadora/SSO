-- =============================================================================
-- Deshace scripts/seed-datos-prueba-exports.sql.
--
-- Borra SOLO el rango de PKs 970000-979999, que es el que usa ese script -- por
-- eso las PKs van fijas y contiguas ahi: para que la limpieza sea un rango y no
-- una lista que haya que mantener en paralelo.
--
-- El orden es de hijo a padre, porque las FK no son ON DELETE CASCADE.
--
-- No borra nada de auditoria: esas filas viven en ClickHouse y las escribe el
-- CDC, no este script.
--
--   docker cp scripts/seed-datos-prueba-exports-limpiar.sql sso-postgres:/tmp/l.sql
--   docker exec sso-postgres psql -U neondb_owner -d sso_db -f /tmp/l.sql
-- =============================================================================

BEGIN;

DELETE FROM academico_test.tasistencia          WHERE pk_tasistencia          BETWEEN 970000 AND 979999;
DELETE FROM academico_test.tperiodo_evaluacion  WHERE pk_tperiodo_evaluacion  BETWEEN 970000 AND 979999;
DELETE FROM academico_test.tactividad           WHERE pk_tactividad           BETWEEN 970000 AND 979999;
DELETE FROM academico_test.tunidad              WHERE pk_tunidad              BETWEEN 970000 AND 979999;
DELETE FROM academico_test.tasignatura          WHERE pk_tasignatura          BETWEEN 970000 AND 979999;
DELETE FROM academico_test.tarea                WHERE pk_tarea                BETWEEN 970000 AND 979999;
DELETE FROM academico_test.tarea_asignatura     WHERE pk_tarea_asignatura     BETWEEN 970000 AND 979999;

COMMIT;

SELECT 'quedan en el rango de prueba' AS q,
       (SELECT count(*) FROM academico_test.tunidad     WHERE pk_tunidad     BETWEEN 970000 AND 979999)
     + (SELECT count(*) FROM academico_test.tactividad  WHERE pk_tactividad  BETWEEN 970000 AND 979999)
     + (SELECT count(*) FROM academico_test.tasistencia WHERE pk_tasistencia BETWEEN 970000 AND 979999) AS n;
