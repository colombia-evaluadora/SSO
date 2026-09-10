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
--   Funcion: copiada tal cual desde testv2 (172.233.184.248), verificada
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
--   TROL.pk_trol SI es estable entre entornos (a diferencia de
--   TLISTA_VALOR/CATEGORIA_ROL): mismo codigo Oracle en ambos, verificado
--   fila por fila contra testv2 antes de escribir esto.
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

-- Siembra TROL_MENU. WHERE NOT EXISTS por (fk_trol, fk_tmenu): no hay
-- UNIQUE en la tabla (solo pk_trol_menu identity), así que el guard es
-- manual para que re-aplicar esto no duplique filas.
INSERT INTO academico_test.trol_menu (fk_trol, fk_tmenu, orden_rol, active, created_by, created_at)
SELECT v.fk_trol, v.fk_tmenu, v.orden_rol, TRUE, 'migracion', CURRENT_TIMESTAMP
FROM (VALUES
    (1, 1, 4),  (1, 2, 1),  (1, 4, 9),  (1, 14, 11), (1, 10, 3),
    (1, 8, 8),  (1, 7, 7),  (1, 9, 2),  (1, 15, 12), (1, 5, 5),
    (1, 13, 10),(1, 6, 6),
    (2, 1, 1),  (2, 4, 6),  (2, 8, 5),  (2, 7, NULL),(2, 15, 7),
    (2, 5, NULL),(2, 6, NULL),
    (3, 1, 1),  (3, 4, 6),  (3, 8, 5),  (3, 7, NULL),(3, 15, 7),
    (3, 5, NULL),(3, 6, NULL),
    (7, 1, 8),  (7, 2, 5),  (7, 4, 1),  (7, 14, 3),  (7, 10, 7),
    (7, 8, 12), (7, 7, 11), (7, 9, 6),  (7, 15, 4),  (7, 5, 9),
    (7, 13, 2), (7, 6, 10),
    (8, 1, 1),  (8, 8, 5),  (8, 7, NULL),(8, 15, NULL),(8, 5, NULL),
    (8, 6, NULL),
    (9, 1, 1),  (9, 8, 5),  (9, 7, NULL),(9, 15, NULL),(9, 5, 2),
    (9, 6, NULL),
    (11, 7, NULL),(11, 6, NULL),
    (14, 1, 4), (14, 6, 5),
    (16, 1, 3), (16, 2, 2), (16, 3, 6), (16, 4, 1)
) AS v(fk_trol, fk_tmenu, orden_rol)
WHERE NOT EXISTS (
    SELECT 1 FROM academico_test.trol_menu tm
     WHERE tm.fk_trol = v.fk_trol AND tm.fk_tmenu = v.fk_tmenu AND tm.active = TRUE
);
