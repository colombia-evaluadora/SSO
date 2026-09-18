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
    v_pk_grupo       BIGINT;
    v_pk_asistencias BIGINT;
    v_pk_referentes  BIGINT;
    v_pk_planeador   BIGINT;
BEGIN
    -- Todo se resuelve por CODIGO (sin tildes: hay entornos con
    -- 'GESTIÓN_ACÁDEMICA'); los pk de TMENU no son estables entre entornos.
    SELECT pk_tmenu INTO v_pk_grupo
      FROM academico_test.tmenu
     WHERE UPPER(TRANSLATE(codigo, 'ÁÉÍÓÚ', 'AEIOU')) = 'GESTION_ACADEMICA'
       AND fk_tmenu IS NULL AND active = TRUE
     ORDER BY pk_tmenu LIMIT 1;

    IF v_pk_grupo IS NULL THEN
        INSERT INTO academico_test.tmenu
            (codigo, fk_tmenu, nombre, url, icono, visible, orden, estado, active, created_by, created_at)
        VALUES
            ('GESTION_ACADEMICA', NULL, 'Gestión Académica', '/referentes-curriculares', 'Calendar-Icon', 'S', 28, 'A', TRUE, 'migracion', CURRENT_TIMESTAMP)
        RETURNING pk_tmenu INTO v_pk_grupo;
    END IF;

    SELECT pk_tmenu INTO v_pk_referentes FROM academico_test.tmenu
     WHERE codigo = 'REFERENTES_CURRICULARES' AND active = TRUE ORDER BY pk_tmenu LIMIT 1;
    SELECT pk_tmenu INTO v_pk_planeador FROM academico_test.tmenu
     WHERE codigo = 'PLANEADOR' AND active = TRUE ORDER BY pk_tmenu LIMIT 1;

    UPDATE academico_test.tmenu
       SET fk_tmenu = v_pk_grupo,
           url = '/app/gestion-academica/referentes-curriculares'
     WHERE pk_tmenu = v_pk_referentes
       AND (fk_tmenu IS DISTINCT FROM v_pk_grupo
            OR url IS DISTINCT FROM '/app/gestion-academica/referentes-curriculares');

    UPDATE academico_test.tmenu
       SET fk_tmenu = v_pk_grupo,
           url = '/app/planeador/actividades'
     WHERE pk_tmenu = v_pk_planeador
       AND (fk_tmenu IS DISTINCT FROM v_pk_grupo
            OR url IS DISTINCT FROM '/app/planeador/actividades');

    SELECT pk_tmenu INTO v_pk_asistencias
      FROM academico_test.tmenu
     WHERE codigo = 'ASISTENCIAS' AND fk_tmenu = v_pk_grupo AND active = TRUE
     ORDER BY pk_tmenu LIMIT 1;

    IF v_pk_asistencias IS NULL THEN
        INSERT INTO academico_test.tmenu
            (codigo, fk_tmenu, nombre, url, icono, visible, orden, estado, active, created_by, created_at)
        VALUES
            ('ASISTENCIAS', v_pk_grupo, 'Asistencias', '/app/asistencia', NULL, 'S', 1, 'A', TRUE, 'migracion', CURRENT_TIMESTAMP)
        RETURNING pk_tmenu INTO v_pk_asistencias;
    END IF;

    -- TROL por CODIGO: no viene en las migraciones, no-op si falta el rol.
    -- NOT EXISTS sin mirar ACTIVE: no revive parejas desactivadas desde la UI.
    INSERT INTO academico_test.trol_menu (fk_trol, fk_tmenu, orden_rol, active, created_by, created_at)
    SELECT r.pk_trol, x.pk_tmenu, v.orden_rol, TRUE, 'migracion', CURRENT_TIMESTAMP
    FROM (VALUES
        ('SUPER_ADMINISTRADOR',          'grupo',       13),
        ('SUPER_ADMINISTRADOR',          'referentes',  16),
        ('SUPER_ADMINISTRADOR',          'asistencias', 15),
        ('SUPER_ADMINISTRADOR',          'planeador',   14),
        ('RECTOR',                       'grupo',       13),
        ('RECTOR',                       'asistencias', 14),
        ('JEFE_SISTEMA_ESTABLECIMIENTO', 'asistencias', NULL),
        ('AUXILIAR_ADMINISTRATIVO',      'asistencias', NULL),
        ('PSICO_ORIENTADOR',             'asistencias', NULL),
        ('COORDINADOR',                  'asistencias', NULL),
        ('JEFE_AREA',                    'asistencias', NULL),
        ('DIRECTOR_GRUPO',               'asistencias', NULL),
        ('DOCENTE',                      'grupo',       1),
        ('DOCENTE',                      'asistencias', 2),
        ('DOCENTE',                      'planeador',   3)
    ) AS v(rol_codigo, hijo, orden_rol)
    JOIN academico_test.trol r ON r.codigo = v.rol_codigo AND r.active = TRUE
    JOIN LATERAL (
        SELECT CASE v.hijo
                   WHEN 'grupo'       THEN v_pk_grupo
                   WHEN 'referentes'  THEN v_pk_referentes
                   WHEN 'asistencias' THEN v_pk_asistencias
                   WHEN 'planeador'   THEN v_pk_planeador
               END AS pk_tmenu
    ) x ON x.pk_tmenu IS NOT NULL
    WHERE NOT EXISTS (
        SELECT 1 FROM academico_test.trol_menu tm
         WHERE tm.fk_trol = r.pk_trol AND tm.fk_tmenu = x.pk_tmenu
    );
END $$;
