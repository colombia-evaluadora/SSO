-- ===========================================================================
-- V193 - fn_list_my_menus (GET /my-menus, menu lateral del front) y siembra
-- de TROL_MENU con las asignaciones rol -> menu reales.
-- El menu de un usuario es la union de los menus de sus roles; un submenu
-- trae a su padre, y los submenus de un modulo inactivo no se muestran.
-- Depende de: V113 (TMENU, orden_rol).
-- ===========================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_list_my_menus(p_user_pk bigint)
 RETURNS TABLE(pk_tmenu bigint, pk_padre bigint, nombre character varying, url character varying, icono character varying, visible boolean, orden numeric, plan_id bigint, type character varying)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'academico_test', 'public'
AS $function$
BEGIN
    -- Sin usuario: 42501 (403), no una lista vacia. Sin fn_assert_superadmin:
    -- la llama cualquier usuario para su sidebar; el recorte por rol autoriza.
    IF p_user_pk IS NULL THEN
        RAISE EXCEPTION 'fn_list_my_menus: no hay usuario autenticado en el token'
            USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
    WITH asignados AS (
        -- Union de los roles del usuario; con varios ordenes gana el menor.
        SELECT tm.fk_tmenu,
               MIN(tm.orden_rol) AS orden_rol
          FROM academico_test.trol_menu tm
          JOIN academico_test.trol      r  ON r.pk_trol  = tm.fk_trol
          JOIN public.role              pr ON pr.name    = 'CEVAL-' || r.codigo
          JOIN public.role_users        ru ON ru.role_id = pr.id_role
         WHERE ru.user_id = p_user_pk
           AND tm.active  = TRUE
           AND r.active   = TRUE
           AND r.estado   = 'A'
         GROUP BY tm.fk_tmenu
    ),
    visibles AS (
        SELECT a.fk_tmenu AS pk_tmenu
          FROM asignados a
        UNION
        -- El hijo asignado arrastra a su padre: el sidebar es un arbol de dos niveles.
        SELECT m.fk_tmenu
          FROM academico_test.tmenu m
          JOIN asignados a ON a.fk_tmenu = m.pk_tmenu
         WHERE m.fk_tmenu IS NOT NULL
    )
    SELECT
        m.pk_tmenu,
        m.fk_tmenu                          AS pk_padre,
        m.nombre,
        m.url,
        m.icono,
        (m.visible = 'S')                   AS visible,
        -- Orden del rol; el padre arrastrado sin orden_rol cae a m.orden.
        COALESCE(a.orden_rol, m.orden)      AS orden,
        m.fk_tplan                          AS plan_id,
        (CASE WHEN m.fk_tmenu IS NULL THEN 'GROUP' ELSE 'ITEM' END)::VARCHAR AS type
    FROM academico_test.tmenu m
    LEFT JOIN asignados a ON a.fk_tmenu = m.pk_tmenu
    LEFT JOIN academico_test.tmenu p ON p.pk_tmenu = m.fk_tmenu
    WHERE m.pk_tmenu IN (SELECT v.pk_tmenu FROM visibles v)
      AND m.estado = 'A'
      AND m.active = TRUE
      -- Los submenus de un modulo inactivo dejan de mostrarse.
      AND (m.fk_tmenu IS NULL OR (p.estado = 'A' AND p.active = TRUE))
    ORDER BY
        COALESCE(m.fk_tmenu, m.pk_tmenu),   -- agrupa submenus bajo su padre
        (m.fk_tmenu IS NULL) DESC,          -- padre antes que hijos
        COALESCE(a.orden_rol, m.orden) NULLS LAST,
        m.nombre;
END;
$function$;

-- Siembra por CODIGO (pk de TMENU varia por entorno; TROL llega del dump:
-- sin catalogo es no-op). NOT EXISTS sin mirar ACTIVE: una pareja dada de
-- baja desde la UI no revive al re-aplicar.
INSERT INTO academico_test.trol_menu (fk_trol, fk_tmenu, orden_rol, active, created_by, created_at)
SELECT r.pk_trol, m.pk_tmenu, v.orden_rol, TRUE, 'migracion', CURRENT_TIMESTAMP
FROM (VALUES
    ('SUPER_ADMINISTRADOR', 'ESTABLECIMIENTO_EDUCATIVO', 4),  ('SUPER_ADMINISTRADOR', 'ADMINISTRACION', 1),
    ('SUPER_ADMINISTRADOR', 'COBERTURA_EDUCATIVA', 9),        ('SUPER_ADMINISTRADOR', 'INSCRITOS', 11),
    ('SUPER_ADMINISTRADOR', 'CONFIG_ROLES_MENUS', 3),         ('SUPER_ADMINISTRADOR', 'PERIODOS_ACADEMICOS', 8),
    ('SUPER_ADMINISTRADOR', 'FUNCIONARIOS', 7),               ('SUPER_ADMINISTRADOR', 'REGISTRO_ACTIVIDAD', 2),
    ('SUPER_ADMINISTRADOR', 'MATRICULA', 12),                 ('SUPER_ADMINISTRADOR', 'ESTABLECIMIENTO', 5),
    ('SUPER_ADMINISTRADOR', 'PRE_MATRICULA', 10),             ('SUPER_ADMINISTRADOR', 'SEDES_EDUCATIVAS', 6),
    ('DIRECTOR_ENTE_TERRITORIAL', 'ESTABLECIMIENTO_EDUCATIVO', 1), ('DIRECTOR_ENTE_TERRITORIAL', 'COBERTURA_EDUCATIVA', 6),
    ('DIRECTOR_ENTE_TERRITORIAL', 'PERIODOS_ACADEMICOS', 5),       ('DIRECTOR_ENTE_TERRITORIAL', 'FUNCIONARIOS', NULL),
    ('DIRECTOR_ENTE_TERRITORIAL', 'MATRICULA', 7),                 ('DIRECTOR_ENTE_TERRITORIAL', 'ESTABLECIMIENTO', NULL),
    ('DIRECTOR_ENTE_TERRITORIAL', 'SEDES_EDUCATIVAS', NULL),
    ('JEFE_SISTEMA_ENTE_TERRITORIAL', 'ESTABLECIMIENTO_EDUCATIVO', 1), ('JEFE_SISTEMA_ENTE_TERRITORIAL', 'COBERTURA_EDUCATIVA', 6),
    ('JEFE_SISTEMA_ENTE_TERRITORIAL', 'PERIODOS_ACADEMICOS', 5),       ('JEFE_SISTEMA_ENTE_TERRITORIAL', 'FUNCIONARIOS', NULL),
    ('JEFE_SISTEMA_ENTE_TERRITORIAL', 'MATRICULA', 7),                 ('JEFE_SISTEMA_ENTE_TERRITORIAL', 'ESTABLECIMIENTO', NULL),
    ('JEFE_SISTEMA_ENTE_TERRITORIAL', 'SEDES_EDUCATIVAS', NULL),
    ('RECTOR', 'ESTABLECIMIENTO_EDUCATIVO', 8),  ('RECTOR', 'ADMINISTRACION', 5),      ('RECTOR', 'COBERTURA_EDUCATIVA', 1),
    ('RECTOR', 'INSCRITOS', 3),                  ('RECTOR', 'CONFIG_ROLES_MENUS', 7),  ('RECTOR', 'PERIODOS_ACADEMICOS', 12),
    ('RECTOR', 'FUNCIONARIOS', 11),              ('RECTOR', 'REGISTRO_ACTIVIDAD', 6),  ('RECTOR', 'MATRICULA', 4),
    ('RECTOR', 'ESTABLECIMIENTO', 9),            ('RECTOR', 'PRE_MATRICULA', 2),       ('RECTOR', 'SEDES_EDUCATIVAS', 10),
    ('JEFE_SISTEMA_ESTABLECIMIENTO', 'ESTABLECIMIENTO_EDUCATIVO', 1), ('JEFE_SISTEMA_ESTABLECIMIENTO', 'PERIODOS_ACADEMICOS', 5),
    ('JEFE_SISTEMA_ESTABLECIMIENTO', 'FUNCIONARIOS', NULL),           ('JEFE_SISTEMA_ESTABLECIMIENTO', 'MATRICULA', NULL),
    ('JEFE_SISTEMA_ESTABLECIMIENTO', 'ESTABLECIMIENTO', NULL),        ('JEFE_SISTEMA_ESTABLECIMIENTO', 'SEDES_EDUCATIVAS', NULL),
    ('AUXILIAR_ADMINISTRATIVO', 'ESTABLECIMIENTO_EDUCATIVO', 1), ('AUXILIAR_ADMINISTRATIVO', 'PERIODOS_ACADEMICOS', 5),
    ('AUXILIAR_ADMINISTRATIVO', 'FUNCIONARIOS', NULL),           ('AUXILIAR_ADMINISTRATIVO', 'MATRICULA', NULL),
    ('AUXILIAR_ADMINISTRATIVO', 'ESTABLECIMIENTO', 2),           ('AUXILIAR_ADMINISTRATIVO', 'SEDES_EDUCATIVAS', NULL),
    ('COORDINADOR', 'FUNCIONARIOS', NULL),       ('COORDINADOR', 'SEDES_EDUCATIVAS', NULL),
    ('DOCENTE', 'ESTABLECIMIENTO_EDUCATIVO', 4), ('DOCENTE', 'SEDES_EDUCATIVAS', 5),
    ('ACUDIENTE', 'ESTABLECIMIENTO_EDUCATIVO', 3), ('ACUDIENTE', 'ADMINISTRACION', 2),
    ('ACUDIENTE', 'USUARIOS', 6),                  ('ACUDIENTE', 'COBERTURA_EDUCATIVA', 1)
) AS v(rol_codigo, menu_codigo, orden_rol)
JOIN academico_test.trol r
  ON r.codigo = v.rol_codigo AND r.active = TRUE
JOIN LATERAL (
    SELECT m.pk_tmenu
      FROM academico_test.tmenu m
     WHERE UPPER(TRANSLATE(m.codigo, 'ÁÉÍÓÚ', 'AEIOU')) = v.menu_codigo
       AND m.active = TRUE
     ORDER BY m.pk_tmenu
     LIMIT 1
) m ON TRUE
WHERE NOT EXISTS (
    SELECT 1 FROM academico_test.trol_menu tm
     WHERE tm.fk_trol = r.pk_trol AND tm.fk_tmenu = m.pk_tmenu
);
