-- ===========================================================================
-- V185 — fn_usuario_permisos_menu: permisos de menu efectivos de un usuario,
-- para que el front pueda decidir que botones (crear/editar/eliminar/ver)
-- mostrar segun su rol.
--
-- CU-86e2w4xdt — Fix validacion front botones segun permisos.
--
-- Renumerada de V131 -> V185: V131 quedo tomado por otra migracion real
-- (param_types_clickhouse_sin_cast_pg) que ya se habia mergeado a dev en
-- paralelo -- mismo patron de resolucion que las colisiones V66/V123 de
-- este repo: renombrar el archivo nuevo, nunca borrar el que ya esta en
-- dev. Contenido SQL sin cambios, solo el numero de version y este
-- comentario.
--
-- Fuentes (dado solo PK_TUSUARIO, sin parametro de sede/ente):
--   * TSEDE_USUARIO (ACTIVE=TRUE) — resuelve los TROL que el usuario tiene
--     HOY, en cualquier sede. Mismo criterio "solo ACTIVE" que
--     fn_cat_roles_listar (V121), sin filtrar ademas por TLV_ESTADO.
--   * TROL_MENU (ACTIVE=TRUE) — las opciones de menu que cada uno de esos
--     roles concede (join TMENU ACTIVE=TRUE para el nombre/url/codigo).
--     Esto es la CONCESION base: por defecto los 4 permisos (crear, editar,
--     eliminar, ver) son TRUE para todo menu concedido por el rol.
--   * TUSUARIO_ROL_PERMISO (ACTIVE=TRUE) — los BLOQUEOS del usuario sobre
--     un TROL_MENU puntual (no hay columnas CREAR/EDITAR/ELIMINAR/VER en
--     esta tabla, solo SOLO_LECTURA):
--       - SOLO_LECTURA = 'SI'  -> bloquea crear/editar/eliminar, deja VER.
--       - SOLO_LECTURA <> 'SI' (incluye NULL/'NO') -> bloqueo total, los 4
--         permisos quedan en FALSE para ese TROL_MENU.
--     Si coexisten un bloqueo total y uno de solo-lectura sobre el MISMO
--     TROL_MENU (filas distintas, p.ej. una por sede y otra por ente), gana
--     el bloqueo total (mas restrictivo) para ese TROL_MENU puntual.
--
-- Un mismo TMENU puede llegar via varios roles del usuario (varios
-- TROL_MENU distintos apuntando al mismo PK_TMENU). El bloqueo es por
-- TROL_MENU (la combinacion rol+menu), no por menu a secas: si el usuario
-- tiene el mismo menu concedido por OTRO rol sin bloqueo, ese acceso se
-- mantiene (se agregan los permisos de todos los TROL_MENU del mismo
-- PK_TMENU con OR — el mas permisivo gana). Decision documentada, no
-- verificada contra el front (que hoy no distingue "bloqueado por un rol,
-- concedido por otro").
--
-- No filtra por FK_TSEDE/FK_ENTE de TUSUARIO_ROL_PERMISO porque la funcion
-- no recibe sede/establecimiento como parametro (solo PK_TUSUARIO, tal como
-- se pidio) — cualquier bloqueo activo del usuario sobre ese TROL_MENU
-- aplica, sea cual sea su alcance.
--
-- Idempotente: CREATE OR REPLACE FUNCTION, mismo patron que V58/V121.
-- ===========================================================================

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_usuario_permisos_menu(
    p_pk_tusuario  BIGINT
)
RETURNS TABLE (
    pk_tmenu       BIGINT,
    codigo         VARCHAR,
    nombre         VARCHAR,
    path           VARCHAR,
    puede_crear    BOOLEAN,
    puede_editar   BOOLEAN,
    puede_eliminar BOOLEAN,
    puede_ver      BOOLEAN
)
LANGUAGE sql
STABLE
AS $$
    WITH roles_activos AS (
        -- Roles que el usuario tiene HOY, en cualquier sede.
        SELECT DISTINCT su.FK_TROL AS pk_trol
          FROM academico_test.TSEDE_USUARIO su
         WHERE su.FK_TUSUARIO = p_pk_tusuario
           AND su.ACTIVE = TRUE
    ),
    menus_del_rol AS (
        -- Cada combinacion (rol, menu) concedida -- puede haber mas de una
        -- fila por PK_TMENU si varios roles del usuario lo conceden.
        SELECT rm.PK_TROL_MENU, m.PK_TMENU, m.CODIGO, m.NOMBRE, m.URL
          FROM roles_activos ra
          JOIN academico_test.TROL_MENU rm
            ON rm.FK_TROL = ra.pk_trol AND rm.ACTIVE = TRUE
          JOIN academico_test.TMENU m
            ON m.PK_TMENU = rm.FK_TMENU AND m.ACTIVE = TRUE
    ),
    bloqueos AS (
        -- Bloqueos activos del usuario, agregados por TROL_MENU. Si hay
        -- alguna fila de bloqueo total (SOLO_LECTURA distinto de 'SI'),
        -- gana sobre un bloqueo de solo-lectura del mismo TROL_MENU.
        SELECT p.FK_TROL_MENU,
               bool_or(p.SOLO_LECTURA IS DISTINCT FROM 'SI') AS bloqueo_total,
               bool_or(p.SOLO_LECTURA = 'SI')                AS bloqueo_solo_lectura
          FROM academico_test.TUSUARIO_ROL_PERMISO p
         WHERE p.FK_TUSUARIO = p_pk_tusuario
           AND p.ACTIVE = TRUE
         GROUP BY p.FK_TROL_MENU
    ),
    permisos_por_combo AS (
        -- Permisos resultantes por CADA combinacion (rol, menu) concedida,
        -- antes de colapsar por PK_TMENU.
        SELECT mr.PK_TMENU, mr.CODIGO, mr.NOMBRE, mr.URL,
               NOT (COALESCE(b.bloqueo_total, FALSE)
                    OR COALESCE(b.bloqueo_solo_lectura, FALSE)) AS puede_editar_like,
               NOT COALESCE(b.bloqueo_total, FALSE)             AS puede_ver_combo
          FROM menus_del_rol mr
          LEFT JOIN bloqueos b ON b.FK_TROL_MENU = mr.PK_TROL_MENU
    )
    SELECT pc.PK_TMENU,
           MIN(pc.CODIGO),
           MIN(pc.NOMBRE),
           MIN(pc.URL),
           bool_or(pc.puede_editar_like) AS puede_crear,
           bool_or(pc.puede_editar_like) AS puede_editar,
           bool_or(pc.puede_editar_like) AS puede_eliminar,
           bool_or(pc.puede_ver_combo)   AS puede_ver
      FROM permisos_por_combo pc
     GROUP BY pc.PK_TMENU
     ORDER BY MIN(pc.NOMBRE) ASC, pc.PK_TMENU ASC;
$$;

COMMENT ON FUNCTION academico_test.fn_usuario_permisos_menu(BIGINT)
    IS 'Permisos de menu efectivos de un usuario (dado solo su PK_TUSUARIO): una fila por TMENU activo concedido por alguno de sus roles activos en TSEDE_USUARIO, con su codigo/nombre/path (TMENU.URL) y 4 flags (puede_crear, puede_editar, puede_eliminar, puede_ver). Por defecto los 4 son TRUE (lo que el rol concede via TROL_MENU); TUSUARIO_ROL_PERMISO (ACTIVE=TRUE) los recorta por combinacion (rol, menu) puntual: SOLO_LECTURA=''SI'' bloquea crear/editar/eliminar y deja solo ver; cualquier otro bloqueo activo (SOLO_LECTURA NULL o distinto de ''SI'') bloquea los 4. Si el mismo TMENU llega via mas de un rol del usuario, se agregan con OR (el rol menos restrictivo gana para ese menu). No filtra por FK_TSEDE/FK_ENTE de TUSUARIO_ROL_PERMISO -- aplica cualquier bloqueo activo del usuario sobre ese TROL_MENU, sin importar su alcance, porque la funcion no recibe sede/establecimiento como parametro.';

-- ---------------------------------------------------------------------------
-- Registro en `query` (motor SSO / query-service): GET
-- /usuarios/:PK_TUSUARIO/permisos-menu
--
-- microservice_id se resuelve por serviceid='eval-col' (kind=QUERY,
-- dialect=postgres -- el motor que corre funciones PL/pgSQL de
-- academico_test) en vez de fijar el id numerico literal, que varia por
-- ambiente (mismo patron que V85/V124). Si esa fila no existe todavia en
-- el ambiente donde corre esta migracion, el INSERT no encuentra
-- microservice_id (NULL) y viola el NOT NULL de la columna -- fallaria
-- fuerte en vez de registrar la query contra el microservicio equivocado.
--
-- Idempotente: no inserta una fila duplicada para el mismo
-- (microservice_id, path_template, http_method).
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_usuario_permisos_menu(
    CAST(:PARAM.PK_TUSUARIO AS BIGINT)
);',
    'postgres', false, false,
    m.id_microservice, '/usuarios/:PK_TUSUARIO/permisos-menu', 'SELECT', 'GET',
    '{"PARAM.PK_TUSUARIO": "BIGINT"}'::jsonb,
    'V185 -- permisos de menu (crear/editar/eliminar/ver) del usuario, para que el front decida que botones mostrar segun su rol'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

-- Sin una fila role_query explicita, la query responde 403 a cualquier
-- caller (no hay bypass implicito ni para ADMIN -- mismo patron que V87).
-- Punto de partida deliberadamente angosto: cada usuario solo deberia
-- poder consultar SUS PROPIOS permisos de menu (CONTEXT.USER_ID en vez de
-- PARAM.PK_TUSUARIO seria lo ideal para eso), pero la funcion recibe el PK
-- como parametro explicito -- cualquier rol con esta query puede consultar
-- los permisos de CUALQUIER usuario. Se otorga solo a
-- CEVAL-SUPER_ADMINISTRADOR por ahora; abrir a mas roles (o cambiar a
-- CONTEXT.USER_ID) es una decision de negocio, no tecnica.
INSERT INTO public.role_query (role_id, query_id)
SELECT
    (SELECT id_role FROM public.role WHERE name = 'CEVAL-SUPER_ADMINISTRADOR'),
    q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
 WHERE m.serviceid = 'eval-col'
   AND q.path_template = '/usuarios/:PK_TUSUARIO/permisos-menu'
   AND q.http_method = 'GET'
ON CONFLICT DO NOTHING;
