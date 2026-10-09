-- ===========================================================================
-- V139 -- DDL e indices de TASISTENCIA (asistencia por asignatura o por
-- ACTIVIDAD).
-- Que hace: FK_TACTIVIDAD (nullable) + FK ON DELETE CASCADE, FK_TASIGNATURA
-- pasa a NULLABLE, CHECK CK_TASISTENCIA_CONTEXTO (asignatura o actividad,
-- nunca ninguna), ORIGEN, el juego de indices de TASISTENCIA (quita los de
-- V22 que nadie usa) con su autovacuum, e IDX_THORARIO_LOOKUP.
-- Depende de: TASISTENCIA/THORARIO (V22), TACTIVIDAD (rama Planeador/V243).
-- ===========================================================================

SET search_path TO academico_test, public;

DO $ddl$
BEGIN
    IF to_regclass('academico_test.TASISTENCIA') IS NULL THEN
        RAISE NOTICE 'TASISTENCIA no existe todavia: se omite el DDL de asistencia por actividad';
        RETURN;
    END IF;

    EXECUTE 'ALTER TABLE academico_test.TASISTENCIA
                 ADD COLUMN IF NOT EXISTS FK_TACTIVIDAD BIGINT';

    IF to_regclass('academico_test.TACTIVIDAD') IS NOT NULL THEN
        -- Solo si falta o no es CASCADE: re-crearla valida la tabla entera.
        IF NOT EXISTS (SELECT 1 FROM pg_constraint
                        WHERE conrelid = 'academico_test.tasistencia'::regclass
                          AND conname = 'fk_tasistencia_actividad'
                          AND confdeltype = 'c') THEN
            EXECUTE 'ALTER TABLE academico_test.TASISTENCIA
                         DROP CONSTRAINT IF EXISTS FK_TASISTENCIA_ACTIVIDAD';
            EXECUTE 'ALTER TABLE academico_test.TASISTENCIA
                         ADD CONSTRAINT FK_TASISTENCIA_ACTIVIDAD
                         FOREIGN KEY (FK_TACTIVIDAD)
                         REFERENCES academico_test.TACTIVIDAD (PK_TACTIVIDAD) ON DELETE CASCADE';
        END IF;
        EXECUTE 'COMMENT ON COLUMN academico_test.TASISTENCIA.FK_TACTIVIDAD IS
                     ''Actividad (preescolar/formativa) a la que corresponde este registro de asistencia. Nullable: la asistencia de asignatura+fecha no la usa.''';
    END IF;

    EXECUTE 'ALTER TABLE academico_test.TASISTENCIA
                 ALTER COLUMN FK_TASIGNATURA DROP NOT NULL';

    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conrelid = 'academico_test.tasistencia'::regclass
                      AND conname = 'ck_tasistencia_contexto') THEN
        EXECUTE 'ALTER TABLE academico_test.TASISTENCIA
                     ADD CONSTRAINT CK_TASISTENCIA_CONTEXTO
                     CHECK (FK_TASIGNATURA IS NOT NULL OR FK_TACTIVIDAD IS NOT NULL)';
    END IF;

    -- Vista Asistencias o Planeador (fila sin bloque); la de la Vista predomina.
    EXECUTE 'ALTER TABLE academico_test.TASISTENCIA
                 ADD COLUMN IF NOT EXISTS ORIGEN VARCHAR(20) NOT NULL DEFAULT ''ASISTENCIA''';
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conrelid = 'academico_test.tasistencia'::regclass
                      AND conname = 'ck_tasistencia_origen') THEN
        EXECUTE 'ALTER TABLE academico_test.TASISTENCIA
                     ADD CONSTRAINT CK_TASISTENCIA_ORIGEN CHECK (ORIGEN IN (''ASISTENCIA'', ''PLANEADOR''))';
    END IF;
END
$ddl$;

-- Indices de TASISTENCIA (pensada para 20M+ filas): cada indice se paga en
-- cada INSERT/UPDATE, asi que solo quedan los que sirven a una consulta o a
-- una FK. Los de FK no pueden ser parciales por ACTIVE (el chequeo de la FK
-- mira todas las filas), pero si por IS NOT NULL. Un indice cuya definicion
-- cambia se recrea solo si su COMMENT no trae la version vigente: reaplicar
-- el archivo no reconstruye indices de millones de filas sin necesidad.
DO $idx$
DECLARE
    r RECORD;
BEGIN
    IF to_regclass('academico_test.TASISTENCIA') IS NULL THEN
        RETURN;
    END IF;

    -- Cubiertos por otro indice o sin consulta que los use.
    DROP INDEX IF EXISTS academico_test.IDX_TASISTENCIA_3;       -- tipo: 6 valores
    DROP INDEX IF EXISTS academico_test.IDX_TASISTENCIA_4;       -- prefijo de IDX_TASISTENCIA_1
    DROP INDEX IF EXISTS academico_test.IDX_TASISTENCIA_7;       -- bloque
    DROP INDEX IF EXISTS academico_test.IDX_TASISTENCIA_ACTIVE;
    DROP INDEX IF EXISTS academico_test.IX_TASISTENCIA_2;        -- fecha: IDX_TASISTENCIA_9
    DROP INDEX IF EXISTS academico_test.IDX_TASISTENCIA_10;      -- IDX_TASISTENCIA_2
    DROP INDEX IF EXISTS academico_test.IDX_TASISTENCIA_11;      -- IDX_TASISTENCIA_ACTIVIDAD

    FOR r IN
        SELECT * FROM (VALUES
            ('uq_tasistencia_sesion', 'v2',
             'CREATE UNIQUE INDEX UQ_TASISTENCIA_SESION ON academico_test.TASISTENCIA
                (FK_TMATRICULA, COALESCE(FK_TASIGNATURA, 0), COALESCE(FK_TACTIVIDAD, 0),
                 FECHA, COALESCE(BLOQUE, 0)) WHERE ACTIVE = true'),
            -- Sin ACTIVE: sirve a la FK de TMATRICULA y a la captura tardia,
            -- que busca la fila inactiva de la sesion.
            ('idx_tasistencia_2', 'v2',
             'CREATE INDEX IDX_TASISTENCIA_2 ON academico_test.TASISTENCIA (FK_TMATRICULA, FECHA)'),
            ('idx_tasistencia_6', 'v2',
             'CREATE INDEX IDX_TASISTENCIA_6 ON academico_test.TASISTENCIA (FK_SOPORTE_ARCHIVO)
                WHERE FK_SOPORTE_ARCHIVO IS NOT NULL'),
            ('idx_tasistencia_actividad', 'v2',
             'CREATE INDEX IDX_TASISTENCIA_ACTIVIDAD ON academico_test.TASISTENCIA (FK_TACTIVIDAD, FECHA)
                WHERE FK_TACTIVIDAD IS NOT NULL')
        ) AS t(nombre, version, ddl)
    LOOP
        IF to_regclass('academico_test.' || r.nombre) IS NULL
           OR obj_description(('academico_test.' || r.nombre)::regclass, 'pg_class')
              IS DISTINCT FROM r.version THEN
            EXECUTE format('DROP INDEX IF EXISTS academico_test.%I', r.nombre);
            EXECUTE r.ddl;
            EXECUTE format('COMMENT ON INDEX academico_test.%I IS %L', r.nombre, r.version);
        END IF;
    END LOOP;

    -- Tabla grande y muy escrita: el autovacuum por defecto (20%) esperaria
    -- millones de filas muertas. fillfactor deja hueco para updates HOT.
    ALTER TABLE academico_test.TASISTENCIA SET (
        fillfactor = 90,
        autovacuum_vacuum_scale_factor = 0.02,
        autovacuum_analyze_scale_factor = 0.01,
        autovacuum_vacuum_insert_scale_factor = 0.05);
END
$idx$;

CREATE INDEX IF NOT EXISTS IDX_TASISTENCIA_9
  ON TASISTENCIA (FECHA, FK_TASIGNATURA) WHERE ACTIVE = true ;

CREATE INDEX IF NOT EXISTS IDX_THORARIO_LOOKUP
  ON THORARIO (FK_TGRUPO, FK_TASIGNATURA, NUMERO_BLOQUE, FK_TLV_DIA_SEMANA)
  WHERE ACTIVE = true ;
