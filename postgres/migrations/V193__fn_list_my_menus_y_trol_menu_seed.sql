-- ===========================================================================
-- V193 - academico_test.fn_list_my_menus (sidebar del front) + siembra de
--        TROL_MENU con las asignaciones reales de rol->menu.
--
-- POR QUE ESTA MIGRACION EXISTE
--   La query de catalogo 'eval-col-my-menus-001' (GET /my-menus) llama a
--   academico_test.fn_list_my_menus(:CONTEXT.USER_ID::BIGINT) para pintar
--   el sidebar de Colombia Evaluadora. Esa funcion NUNCA existio en
--   postgres/migrations/ -- vive solo en la base de datos de otro entorno
--   (testv2), agregada fuera de Flyway en algun momento. Un servidor
--   sembrado solo por migraciones (o por el pipeline de deploy limpio)
--   nunca la tiene: GET /my-menus responde 404 ("no query registered")
--   para CUALQUIER usuario, no solo uno en particular -- la query en si
--   funciona, es la funcion PL/pgSQL detras la que falta.
--
--   Ademas TROL_MENU (la tabla que fn_list_my_menus lee para decidir que
--   ve cada rol) estaba vacia: aunque exista la funcion, sin filas ahi
--   el sidebar de CUALQUIER usuario -- incluido un rol con nivel 0
--   (Super Administrador) -- se queda vacio. fn_list_my_menus NO tiene
--   bypass de superadmin (a proposito, ver su propio comentario: "el
--   recorte por rol ES la autorizacion").
--
-- ORIGEN DE LOS DATOS
--   Funcion: copiada tal cual desde testv2 (el servidor de test), verificada
--   contra pg_get_functiondef.
--
--   TROL_MENU: testv2 acumulo 331 asignaciones activas sobre 150+ filas de
--   TMENU propias, con numeracion de PK completamente distinta a la de
--   este servidor y con entradas de prueba obvias (p.ej.
--   'CurlProbe-DELETE-ME', 'catalog test menu edited') que NO se
--   replican aqui. Se tradujeron SOLO las asignaciones correspondientes
--   a los 17 items de academico_test.tmenu que YA existen en este
--   servidor (ver V-anterior que sembro tmenu), resolviendo el mapeo por
--   NOMBRE (no por PK crudo, igual criterio que V120/V189 para catalogos
--   cuya numeracion no es estable entre entornos):
--
--     testv2 PK -> este servidor PK (nombre)
--     855 -> 1  (Establecimiento Educativo)   856 -> 2  (Administracion)
--     857 -> 3  (Usuarios)                    858 -> 4  (Cobertura Educativa)
--     866 -> 5  (Establecimiento)              869 -> 6  (Sedes Educativas)
--     863 -> 7  (Funcionarios)                 861 -> 8  (Periodos Academicos)
--     864 -> 9  (Registro de actividad)        860 -> 10 (Configuracion de roles y menus)
--     867 -> 11 (Equipo)                       862 -> 12 (Roles)
--     868 -> 13 (Pre-Matricula)                859 -> 14 (Inscritos / Inscripciones)
--     865 -> 15 (Matricula)                    897 -> 16 (Referentes Curriculares)
--     903 -> 17 (Planeador)
--
--   Ni TROL ni TMENU se siembran en las migraciones (llegan por el dump
--   base) y los pk de TMENU cambian por entorno, asi que la siembra
--   resuelve ambos por CODIGO y es no-op donde el catalogo no exista.
--
-- NUMERACION
--   Hueco libre V193, verificado contra TODAS las ramas de origin.
-- ===========================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_list_my_menus(p_user_pk bigint)
 RETURNS TABLE(pk_tmenu bigint, pk_padre bigint, nombre character varying, url character varying, icono character varying, visible boolean, orden numeric, plan_id bigint, type character varying)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'academico_test', 'public'
AS $function$
BEGIN
    -- Sin usuario en el token no hay menú que devolver. Se corta con 42501
    -- (insufficient_privilege), que PostgresErrorMapper traduce a 403: una
    -- lista vacía mentiría diciendo "no tenés menús asignados".
    --
    -- Y NO se llama a fn_assert_superadmin: a diferencia de
    -- fn_list_available_menus, esta la invoca cualquier usuario logueado para
    -- pintar SU sidebar. El recorte por rol ES la autorización.
    IF p_user_pk IS NULL THEN
        RAISE EXCEPTION 'fn_list_my_menus: no hay usuario autenticado en el token'
            USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
    WITH asignados AS (
        -- Un usuario puede tener varios roles: su menú es la unión. El GROUP BY
        -- colapsa el mismo item concedido por dos roles distintos.
        --
        -- orden_rol es EL ORDEN QUE EL ADMIN LE DIO A ESE ROL en la pantalla de
        -- configuración, distinto del orden del catálogo (tmenu.orden). Se toma
        -- el MIN porque con varios roles hay varios órdenes posibles para el
        -- mismo menú y hay que elegir uno: gana la posición más alta.
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
        -- El hijo asignado arrastra a su padre aunque el padre no esté
        -- asignado: el sidebar es un árbol de dos niveles y un submenú
        -- huérfano no tendría de dónde colgar.
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
        -- Acá va el orden DEL ROL, no el del catálogo: esta función responde
        -- "mi menú", y el orden que el admin le dio a mi rol es parte de eso.
        -- El fallback a m.orden cubre al padre que entró arrastrado por un hijo
        -- sin estar asignado él mismo (no tiene orden_rol propio).
        COALESCE(a.orden_rol, m.orden)      AS orden,
        m.fk_tplan                          AS plan_id,
        (CASE WHEN m.fk_tmenu IS NULL THEN 'GROUP' ELSE 'ITEM' END)::VARCHAR AS type
    FROM academico_test.tmenu m
    LEFT JOIN asignados a ON a.fk_tmenu = m.pk_tmenu
    WHERE m.pk_tmenu IN (SELECT v.pk_tmenu FROM visibles v)
      AND m.estado = 'A'
      AND m.active = TRUE
    ORDER BY
        COALESCE(m.fk_tmenu, m.pk_tmenu),   -- agrupa submenus bajo su padre
        (m.fk_tmenu IS NULL) DESC,          -- padre antes que hijos
        COALESCE(a.orden_rol, m.orden) NULLS LAST,
        m.nombre;
END;
$function$;

-- Siembra TROL_MENU resolviendo rol y menu por CODIGO (los pk de TMENU no
-- son estables entre entornos y TROL no viene en las migraciones: si el
-- catalogo no esta, el JOIN no devuelve fila y la siembra es no-op). El
-- CODIGO del menu se compara sin tildes: hay entornos con 'ADMINISTRACIÓN'.
-- WHERE NOT EXISTS por (fk_trol, fk_tmenu): la tabla no tiene UNIQUE.
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
     WHERE tm.fk_trol = r.pk_trol AND tm.fk_tmenu = m.pk_tmenu AND tm.active = TRUE
);
