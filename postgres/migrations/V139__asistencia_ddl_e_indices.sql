-- ===========================================================================
-- V139 -- DDL e indices de TASISTENCIA para asistencia por ACTIVIDAD. Vivia en
-- V220 (eliminada); el `ON DELETE CASCADE` y `IDX_TASISTENCIA_ACTIVIDAD` de
-- aqui vienen de V243 (que sigue existiendo y corre despues -- es su version
-- la que gana hoy sobre FK_TASISTENCIA_ACTIVIDAD, V220 no la tenia).
-- Que hace: FK_TACTIVIDAD (nullable) + FK ON DELETE CASCADE, FK_TASIGNATURA
-- pasa a NULLABLE, CHECK CK_TASISTENCIA_CONTEXTO (asignatura o actividad,
-- nunca ninguna), y los indices que usa el modulo (UQ_TASISTENCIA_SESION,
-- IDX_TASISTENCIA_9/10/11, IDX_TASISTENCIA_ACTIVIDAD, IDX_THORARIO_LOOKUP).
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
        EXECUTE 'ALTER TABLE academico_test.TASISTENCIA
                     DROP CONSTRAINT IF EXISTS FK_TASISTENCIA_ACTIVIDAD';
        -- ON DELETE CASCADE: asi la definio V243 (que corre despues de este
        -- archivo) y es la que hoy esta vigente -- sin esto, reaplicar V139
        -- solo dejaria la constraint sin CASCADE hasta que V243 la corrija.
        EXECUTE 'ALTER TABLE academico_test.TASISTENCIA
                     ADD CONSTRAINT FK_TASISTENCIA_ACTIVIDAD
                     FOREIGN KEY (FK_TACTIVIDAD)
                     REFERENCES academico_test.TACTIVIDAD (PK_TACTIVIDAD) ON DELETE CASCADE';
        EXECUTE 'CREATE INDEX IF NOT EXISTS IDX_TASISTENCIA_ACTIVIDAD
                     ON academico_test.TASISTENCIA (FK_TACTIVIDAD)';
        EXECUTE 'COMMENT ON COLUMN academico_test.TASISTENCIA.FK_TACTIVIDAD IS
                     ''Actividad (preescolar/formativa) a la que corresponde este registro de asistencia. Nullable: la asistencia de asignatura+fecha no la usa.''';
    END IF;

    EXECUTE 'ALTER TABLE academico_test.TASISTENCIA
                 ALTER COLUMN FK_TASIGNATURA DROP NOT NULL';

    -- Se recrea para poder reaplicar el archivo (ADD CONSTRAINT no admite
    -- IF NOT EXISTS).
    EXECUTE 'ALTER TABLE academico_test.TASISTENCIA
                 DROP CONSTRAINT IF EXISTS CK_TASISTENCIA_CONTEXTO';
    EXECUTE 'ALTER TABLE academico_test.TASISTENCIA
                 ADD CONSTRAINT CK_TASISTENCIA_CONTEXTO
                 CHECK (FK_TASIGNATURA IS NOT NULL OR FK_TACTIVIDAD IS NOT NULL)';
END
$ddl$;

-- Se dropea antes: coleccion de columnas de UQ_TASISTENCIA_SESION cambio de
-- version en version y CREATE INDEX IF NOT EXISTS no actualiza un indice
-- existente con otra definicion.
DROP INDEX IF EXISTS academico_test.UQ_TASISTENCIA_SESION;
CREATE UNIQUE INDEX IF NOT EXISTS UQ_TASISTENCIA_SESION
  ON TASISTENCIA (FK_TMATRICULA,
                  COALESCE(FK_TASIGNATURA, 0),
                  COALESCE(FK_TACTIVIDAD, 0),
                  FECHA,
                  COALESCE(BLOQUE, 0))
  WHERE ACTIVE = true ;

CREATE INDEX IF NOT EXISTS IDX_TASISTENCIA_11
  ON TASISTENCIA (FK_TACTIVIDAD, FECHA) WHERE ACTIVE = true ;

CREATE INDEX IF NOT EXISTS IDX_TASISTENCIA_9
  ON TASISTENCIA (FECHA, FK_TASIGNATURA) WHERE ACTIVE = true ;

CREATE INDEX IF NOT EXISTS IDX_TASISTENCIA_10
  ON TASISTENCIA (FK_TMATRICULA, FECHA) WHERE ACTIVE = true ;

CREATE INDEX IF NOT EXISTS IDX_THORARIO_LOOKUP
  ON THORARIO (FK_TGRUPO, FK_TASIGNATURA, NUMERO_BLOQUE, FK_TLV_DIA_SEMANA)
  WHERE ACTIVE = true ;
