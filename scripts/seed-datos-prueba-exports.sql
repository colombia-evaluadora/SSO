-- =============================================================================
-- Datos de prueba para ejercitar los endpoints de EXPORTACION a PDF/Excel.
--
--   V404  POST /planeador/actividades/export-all
--   V406  POST /planeador/unidades/export-all
--   V228  POST /asistencias/export-all
--   V405  los tres de auditoria (NO necesitan siembra: se alimentan de
--         ClickHouse, que ya tiene datos reales del CDC)
--
-- SOLO PARA LA BASE LOCAL DE DOCKER (sso-postgres). Nunca contra el servidor
-- de test ni produccion: inserta filas con PK fijas en el rango 97xxxx, que se
-- elige alto y contiguo justamente para poder borrarlo entero despues sin
-- tocar nada mas (ver scripts/seed-datos-prueba-exports-limpiar.sql).
--
-- Es idempotente: todo va con ON CONFLICT DO NOTHING, asi que correrlo dos
-- veces no duplica ni falla.
--
-- Uso:
--   docker cp scripts/seed-datos-prueba-exports.sql sso-postgres:/tmp/seed.sql
--   docker exec sso-postgres psql -U neondb_owner -d sso_db -f /tmp/seed.sql
-- =============================================================================

BEGIN;

-- --- Catalogo academico minimo -------------------------------------------
-- La base local viene sin area/asignatura: hay que crear la cadena entera
-- (tarea_asignatura -> tarea -> tasignatura) antes de colgar nada de ella.
INSERT INTO academico_test.tarea_asignatura (pk_tarea_asignatura, nombre, created_by, created_at, active)
VALUES (970001, 'AREA DE PRUEBA', 'seed-exports', CURRENT_TIMESTAMP, TRUE)
ON CONFLICT DO NOTHING;

INSERT INTO academico_test.tarea (pk_tarea, nombre, fk_tperiodo_academico, fk_tarea_asignatura, created_by, created_at, active)
VALUES (970001, 'Matematicas', 990501, 970001, 'seed-exports', CURRENT_TIMESTAMP, TRUE)
ON CONFLICT DO NOTHING;

INSERT INTO academico_test.tasignatura (pk_tasignatura, codigo, nombre, fk_tarea, created_by, created_at, active)
VALUES (970001, 'SEG-VAL', 'SEGUIMIENTO Y VALORACION', 970001, 'seed-exports', CURRENT_TIMESTAMP, TRUE),
       (970002, 'MAT',     'MATEMATICAS',              970001, 'seed-exports', CURRENT_TIMESTAMP, TRUE)
ON CONFLICT DO NOTHING;

-- --- Unidades tematicas (pestana "Unidad tematica") -----------------------
-- Las mismas tres de la pantalla, para que el reporte se pueda comparar con
-- lo que se ve. Una con descripcion y dos sin ella, para que el PDF muestre
-- tambien como sale una celda vacia.
INSERT INTO academico_test.tunidad (pk_tunidad, nombre, descripcion, fk_tasignatura, fk_tgrado, fk_tfuncionario, created_by, created_at, active)
VALUES (970001, 'Centenas', 'Saber que es una centena', 970001, 990501, 6, 'seed-exports', CURRENT_TIMESTAMP, TRUE),
       (970002, 'Decenas',  NULL,                       970001, 990501, 6, 'seed-exports', CURRENT_TIMESTAMP, TRUE),
       (970003, 'hola',     NULL,                       970001, 990501, 6, 'seed-exports', CURRENT_TIMESTAMP, TRUE)
ON CONFLICT DO NOTHING;

-- --- Actividades (pestana "Actividades") ----------------------------------
-- Con fechas repartidas para que el estado DERIVADO salga distinto en cada
-- una: una ya cerrada, una en curso y una futura. Asi el reporte no sale con
-- una sola etiqueta repetida y se ve que la columna Estado funciona.
--   379 = Quiz, 380 = Tarea (TIPO_ACTIVIDAD)
--   399 = Actividad (TIPO_JERARQUIA_ACTIVIDAD)
--   262 = Rubrica, 270 = Lista de cotejo (INSTRUMENTO_EVALUACION)
INSERT INTO academico_test.tactividad (
    pk_tactividad, titulo, descripcion, fecha_creacion,
    fk_tunidad, fk_tasignatura, fk_tlv_tipo_actividad, fk_tlv_jerarquia,
    fk_tlv_instrumento_evaluacion, fecha_inicio, fecha_cierre,
    ponderacion, es_evaluativa, created_by, created_at, active)
VALUES
 (970001, 'Quiz de centenas',      'Evaluacion corta',      CURRENT_DATE - 20, 970001, 970001, 379, 399, 262, CURRENT_DATE - 20, CURRENT_DATE - 15, 20, 'S', 'seed-exports', CURRENT_TIMESTAMP, TRUE),
 (970002, 'Taller de decenas',     'Trabajo en clase',      CURRENT_DATE - 5,  970002, 970001, 380, 399, 270, CURRENT_DATE - 2,  CURRENT_DATE + 3,  30, 'S', 'seed-exports', CURRENT_TIMESTAMP, TRUE),
 (970003, 'Exposicion final',      NULL,                    CURRENT_DATE,      970003, 970001, 380, 399, 262, CURRENT_DATE + 10, CURRENT_DATE + 15, 50, 'S', 'seed-exports', CURRENT_TIMESTAMP, TRUE),
 (970004, 'Actividad sin unidad',  'Huerfana a proposito',  CURRENT_DATE,      NULL,   970002, 379, 399, NULL, NULL,             NULL,              10, 'N', 'seed-exports', CURRENT_TIMESTAMP, TRUE)
ON CONFLICT DO NOTHING;

-- --- Asistencias (pantalla Asistencia > Seguimiento) ----------------------
-- tasistencia exige un periodo de evaluacion y la base local no tiene
-- ninguno, asi que se crea uno.
--   14 = un estado cualquiera del catalogo (la pantalla no lo pinta)
INSERT INTO academico_test.tperiodo_evaluacion (
    pk_tperiodo_evaluacion, codigo, nombre, abreviacion,
    fecha_inicio, fecha_fin, fk_tlv_estado, fk_tperiodo_academico,
    created_by, created_at, active)
VALUES (970001, 'PE-SEED', 'Periodo de prueba', 'P1',
        CURRENT_DATE - 60, CURRENT_DATE + 60, 14, 990501,
        'seed-exports', CURRENT_TIMESTAMP, TRUE)
ON CONFLICT DO NOTHING;

-- Una fila por tipo de asistencia, para que las tarjetas de la pantalla
-- (Asistieron / Ausentes / Llego tarde) tengan algo distinto que contar y el
-- filtro TIPO_ASISTENCIA se pueda probar de verdad.
--   390 Asistio | 391 NO Asistio | 392 NO Asistio justificada
--   393 Llego tarde | 394 Llego tarde justificada
INSERT INTO academico_test.tasistencia (
    pk_tasistencia, fecha, fk_tlv_tipo_asistencia, fk_tperiodo_evaluacion,
    fk_tmatricula, fk_tasignatura, observacion, created_by, created_at, active)
VALUES
 (970001, CURRENT_DATE - 3, 390, 970001, 990001, 970001, NULL,                    'seed-exports', CURRENT_TIMESTAMP, TRUE),
 (970002, CURRENT_DATE - 3, 391, 970001, 990902, 970001, 'Sin justificar',        'seed-exports', CURRENT_TIMESTAMP, TRUE),
 (970003, CURRENT_DATE - 2, 392, 970001, 990909, 970001, 'Trajo excusa medica',   'seed-exports', CURRENT_TIMESTAMP, TRUE),
 (970004, CURRENT_DATE - 2, 393, 970001, 990903, 970001, 'Llego 10 min tarde',    'seed-exports', CURRENT_TIMESTAMP, TRUE),
 (970005, CURRENT_DATE - 1, 390, 970001, 990001, 970002, NULL,                    'seed-exports', CURRENT_TIMESTAMP, TRUE),
 (970006, CURRENT_DATE - 1, 394, 970001, 990902, 970002, 'Transporte',            'seed-exports', CURRENT_TIMESTAMP, TRUE)
ON CONFLICT DO NOTHING;

COMMIT;

SELECT 'unidades'    AS tabla, count(*) AS n FROM academico_test.tunidad     WHERE pk_tunidad     BETWEEN 970000 AND 979999
UNION ALL SELECT 'actividades', count(*) FROM academico_test.tactividad      WHERE pk_tactividad  BETWEEN 970000 AND 979999
UNION ALL SELECT 'asistencias', count(*) FROM academico_test.tasistencia     WHERE pk_tasistencia BETWEEN 970000 AND 979999;
