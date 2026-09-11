-- ===========================================================================
-- V207 - agrupa Referentes Curriculares y Planeador bajo un nuevo grupo
--        "Gestión Académica", agrega el ítem "Asistencias" que faltaba
--        por completo, y siembra TROL_MENU para los 4 ítems.
--
-- POR QUE ESTA MIGRACION EXISTE
--   V193/V195 trajeron 'Referentes Curriculares' (pk 16) y 'Planeador'
--   (pk 17) como ítems SUELTOS (sin padre), tomando el cluster
--   testv2.tmenu(897,903) -- que resultó ser una versión vieja/huérfana
--   dentro del propio testv2, sin ninguna asignación de rol en
--   TROL_MENU (por eso V193 no les asignó nada).
--
--   El cluster que SÍ está vivo y en uso real en testv2 es
--   tmenu(898,899,901,904): un grupo "Gestión Académica" con tres hijos
--   -- Referentes curriculares, Asistencias, Planeador -- cada uno con
--   asignaciones de rol reales (SUPER_ADMINISTRADOR, RECTOR, DOCENTE,
--   etc.). 'Asistencias' no existía en este servidor en absoluto.
--
--   Este servidor no tenía "Gestión Académica" como grupo -- se crea
--   aquí; a diferencia de V195, aquí SÍ hace falta un pk_tmenu nuevo
--   (no existía ningún candidato a reparentar), así que se usa un
--   bloque PL/pgSQL para capturarlo y usarlo en los UPDATE/INSERT que
--   siguen.
--
-- QUE SE HACE, EN ORDEN
--   1. Crear el grupo "Gestión Académica" (pk_tmenu nuevo).
--   2. Reparentar 'Referentes Curriculares' (pk 16) y 'Planeador'
--      (pk 17) bajo ese grupo, actualizando su url a la real de testv2
--      ('/app/gestion-academica/referentes-curriculares' y
--      '/app/planeador/actividades').
--   3. Crear 'Asistencias' como hijo nuevo del grupo
--      ('/app/asistencia').
--   4. Sembrar TROL_MENU para el grupo + sus 3 hijos, traducido de
--      testv2 por CODIGO de rol (TROL.pk_trol es estable entre
--      entornos, ver V193).
--
-- NUMERACION
--   Hueco libre V207, verificado contra TODAS las ramas de origin.
-- ===========================================================================

DO $$
DECLARE
    v_pk_grupo      BIGINT;
    v_pk_asistencias BIGINT;
BEGIN
    -- 1. Grupo "Gestión Académica" (idempotente por nombre+url exactos).
    SELECT pk_tmenu INTO v_pk_grupo
      FROM academico_test.tmenu
     WHERE nombre = 'Gestión Académica' AND fk_tmenu IS NULL;

    IF v_pk_grupo IS NULL THEN
        INSERT INTO academico_test.tmenu
            (codigo, fk_tmenu, nombre, url, icono, visible, orden, estado, active, created_by, created_at)
        VALUES
            ('GESTION_ACADEMICA', NULL, 'Gestión Académica', '/referentes-curriculares', 'Calendar-Icon', 'S', 28, 'A', TRUE, 'migracion', CURRENT_TIMESTAMP)
        RETURNING pk_tmenu INTO v_pk_grupo;
    END IF;

    -- 2. Reparentar Referentes Curriculares (16) y Planeador (17).
    UPDATE academico_test.tmenu
       SET fk_tmenu = v_pk_grupo,
           url = '/app/gestion-academica/referentes-curriculares'
     WHERE pk_tmenu = 16 AND nombre = 'Referentes Curriculares';

    UPDATE academico_test.tmenu
       SET fk_tmenu = v_pk_grupo,
           url = '/app/planeador/actividades'
     WHERE pk_tmenu = 17 AND nombre = 'Planeador';

    -- 3. Asistencias, nuevo (idempotente por nombre+padre).
    SELECT pk_tmenu INTO v_pk_asistencias
      FROM academico_test.tmenu
     WHERE nombre = 'Asistencias' AND fk_tmenu = v_pk_grupo;

    IF v_pk_asistencias IS NULL THEN
        INSERT INTO academico_test.tmenu
            (codigo, fk_tmenu, nombre, url, icono, visible, orden, estado, active, created_by, created_at)
        VALUES
            ('ASISTENCIAS', v_pk_grupo, 'Asistencias', '/app/asistencia', NULL, 'S', 1, 'A', TRUE, 'migracion', CURRENT_TIMESTAMP)
        RETURNING pk_tmenu INTO v_pk_asistencias;
    END IF;

    -- 4. TROL_MENU: grupo + 3 hijos, por rol (fk_trol = pk_trol, estable
    --    entre entornos). WHERE NOT EXISTS por (fk_trol, fk_tmenu) activo.
    INSERT INTO academico_test.trol_menu (fk_trol, fk_tmenu, orden_rol, active, created_by, created_at)
    SELECT v.fk_trol,
           CASE v.hijo
               WHEN 'grupo' THEN v_pk_grupo
               WHEN 'referentes' THEN 16
               WHEN 'asistencias' THEN v_pk_asistencias
               WHEN 'planeador' THEN 17
           END,
           v.orden_rol, TRUE, 'migracion', CURRENT_TIMESTAMP
    FROM (VALUES
        (1, 'grupo',       13),
        (1, 'referentes',  16),
        (1, 'asistencias', 15),
        (1, 'planeador',   14),
        (7, 'grupo',       13),
        (7, 'asistencias', 14),
        (8, 'asistencias', NULL),
        (9, 'asistencias', NULL),
        (10,'asistencias', NULL),
        (11,'asistencias', NULL),
        (12,'asistencias', NULL),
        (13,'asistencias', NULL),
        (14,'grupo',       1),
        (14,'asistencias', 2),
        (14,'planeador',   3)
    ) AS v(fk_trol, hijo, orden_rol)
    WHERE NOT EXISTS (
        SELECT 1 FROM academico_test.trol_menu tm
         WHERE tm.fk_trol = v.fk_trol
           AND tm.fk_tmenu = CASE v.hijo
                                 WHEN 'grupo' THEN v_pk_grupo
                                 WHEN 'referentes' THEN 16
                                 WHEN 'asistencias' THEN v_pk_asistencias
                                 WHEN 'planeador' THEN 17
                             END
           AND tm.active = TRUE
    );
END $$;
