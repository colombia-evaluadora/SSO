-- ===========================================================================
-- V146 - u_tano_lectivo_1 vuelve a ser un indice unico TOTAL (sin el
--        predicado WHERE active = true).
--        Desbloquea la creacion de periodos academicos, que respondia 500.
--
-- EL FALLO
--   fn_periodo_crear y fn_periodo_actualizar resuelven el año lectivo del
--   periodo con un upsert:
--
--       INSERT INTO academico_test.TANO_LECTIVO (NOMBRE, FK_TESTABLECIMIENTO, CREATED_BY)
--       VALUES (...)
--       ON CONFLICT (FK_TESTABLECIMIENTO, NOMBRE) DO NOTHING
--       RETURNING PK_ANO_LECTIVO INTO v_ano_id;
--
--   V71 (titulada "V65" en su cabecera) convirtio las 84 constraints UNIQUE
--   de academico_test en indices PARCIALES, y esta quedo asi:
--
--       CREATE UNIQUE INDEX u_tano_lectivo_1
--           ON academico_test.tano_lectivo (fk_testablecimiento, nombre)
--        WHERE active = true;
--
--   PostgreSQL solo acepta un indice parcial como arbitro de ON CONFLICT si
--   la clausula repite el MISMO predicado. Como el upsert no lo repite, no
--   hay arbitro y la sentencia aborta antes de ejecutarse:
--
--       ERROR: there is no unique or exclusion constraint matching the
--              ON CONFLICT specification
--
--   El error llega al cliente como 500. Reproducido en produccion con
--   POST /periodos-academicos: fallaba el 100% de las veces, con cualquier
--   sede y cualquier dato.
--
--   En el servidor de pruebas el indice NO era parcial, y por eso alli el
--   mismo endpoint funcionaba.
--
-- LA DECISION Y SU COSTE
--   Hay dos formas de alinear indice y funcion. Se elige, por decision
--   explicita, alinear el INDICE:
--
--     (a) Declarar el predicado en el ON CONFLICT de las dos funciones.
--         Conserva las 84 constraints coherentes, pero obliga a reemplazar
--         el cuerpo completo de ambas funciones para cambiar dos lineas.
--     (b) Quitar el predicado del indice  <-- ESTA MIGRACION
--         No toca ninguna funcion.
--
--   El coste de (b) hay que tenerlo presente, porque revierte para esta
--   tabla lo que V71 buscaba:
--
--     * Un año lectivo dado de baja (ACTIVE = false) vuelve a RESERVAR su
--       nombre de forma permanente: no se podra volver a crear "2026" en
--       ese establecimiento aunque el anterior este borrado.
--     * tano_lectivo queda como la unica excepcion entre las 84 constraints
--       que V71 hizo parciales, cuya cabecera dice que "la intencion de
--       negocio siempre fue unico entre los activos".
--
--   Si mas adelante aparece el caso de reutilizar el nombre de un año
--   lectivo borrado, el camino es (a): reponer el indice parcial y añadir
--   WHERE ACTIVE = TRUE al ON CONFLICT de las dos funciones.
--
-- POR QUE ES SEGURO CREARLO AHORA
--   Un indice unico total falla si existen duplicados contando tambien las
--   filas inactivas. Medido antes de escribir esta migracion:
--
--       produccion  tano_lectivo    0 filas,  0 duplicados
--       pruebas     tano_lectivo  350 filas,  0 duplicados
--
--   Aun asi el DO comprueba los duplicados en tiempo de ejecucion y aborta
--   con un mensaje util en vez de dejar un error de indice a medias.
--
-- ALCANCE
--   SOLO u_tano_lectivo_1. Las otras 83 constraints parciales de V71 no se
--   tocan.
--
--   En particular NO se toca uq_tasistencia_sesion, que tambien es parcial:
--   su funcion (fn_asistencia_registrar_bulk) SI declara
--   "WHERE ACTIVE = true" en el ON CONFLICT, de modo que esta correctamente
--   alineada y volverla total la romperia.
--
--   Idempotente: si el indice ya es total no hace nada.
-- ===========================================================================

DO $$
DECLARE
    v_es_parcial  BOOLEAN;
    v_duplicados  BIGINT;
BEGIN
    SELECT (indexdef ILIKE '%WHERE%')
      INTO v_es_parcial
      FROM pg_indexes
     WHERE schemaname = 'academico_test'
       AND indexname  = 'u_tano_lectivo_1';

    IF v_es_parcial IS NULL THEN
        RAISE NOTICE 'V146: u_tano_lectivo_1 no existe; se crea total';
    ELSIF v_es_parcial = FALSE THEN
        RAISE NOTICE 'V146: u_tano_lectivo_1 ya era TOTAL, no se toca';
        RETURN;
    END IF;

    -- Guarda: con duplicados entre filas inactivas el indice total no se
    -- puede crear. Mejor un error explicito que un fallo de CREATE INDEX.
    SELECT count(*)
      INTO v_duplicados
      FROM (
            SELECT FK_TESTABLECIMIENTO, NOMBRE
              FROM academico_test.TANO_LECTIVO
             GROUP BY 1, 2
            HAVING count(*) > 1
           ) d;

    IF v_duplicados > 0 THEN
        RAISE EXCEPTION 'V146: hay % combinaciones (FK_TESTABLECIMIENTO, NOMBRE) duplicadas contando filas inactivas; el indice unico total no se puede crear. Resuelvelas antes de aplicar esta migracion.',
            v_duplicados
            USING ERRCODE = '23505';
    END IF;

    -- El nombre puede colgar de una CONSTRAINT (base que aun no paso por
    -- V71, donde sigue siendo UNIQUE) o de un INDEX suelto (base ya
    -- convertida). DROP INDEX falla sobre el primero -- "constraint
    -- u_tano_lectivo_1 requires it" -- asi que hay que distinguirlos.
    IF EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname = 'u_tano_lectivo_1'
           AND conrelid = 'academico_test.tano_lectivo'::regclass
    ) THEN
        ALTER TABLE academico_test.TANO_LECTIVO DROP CONSTRAINT u_tano_lectivo_1;
    ELSE
        DROP INDEX IF EXISTS academico_test.u_tano_lectivo_1;
    END IF;

    CREATE UNIQUE INDEX u_tano_lectivo_1
        ON academico_test.TANO_LECTIVO (FK_TESTABLECIMIENTO, NOMBRE);

    RAISE NOTICE 'V146: u_tano_lectivo_1 pasa a UNIQUE total (arbitro valido para el ON CONFLICT de fn_periodo_crear/_actualizar)';
END $$;

COMMENT ON INDEX academico_test.u_tano_lectivo_1 IS
    'Unicidad de (FK_TESTABLECIMIENTO, NOMBRE) en TANO_LECTIVO. TOTAL a proposito (V146), no parcial como las otras 83 de V71: es el arbitro del ON CONFLICT de fn_periodo_crear/fn_periodo_actualizar, que no declara predicado. Contrapartida: un año lectivo inactivo sigue reservando su nombre.';
