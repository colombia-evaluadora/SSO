-- ===========================================================================
-- V198 — TROL_MENU.SOLO_LECTURA: concesion de menu por rol en modo solo-lectura
--
-- Que hace:
--   1. ALTER TABLE academico_test.TROL_MENU ADD COLUMN SOLO_LECTURA VARCHAR(5)
--      (nullable, sin default). Misma columna y semantica de valores que
--      TUSUARIO_ROL_PERMISO.SOLO_LECTURA (V22, linea ~2316):
--        - 'SI'                       -> el rol concede ese menu SOLO para ver
--                                        (crear/editar/eliminar = FALSE, ver = TRUE).
--        - NULL / 'NO' / cualquier otro valor
--                                     -> el rol concede los 4 permisos
--                                        (crear/editar/eliminar/ver = TRUE),
--                                        comportamiento historico (V22).
--   2. Reescribe academico_test.fn_usuario_permisos_menu(BIGINT) (definida en
--      V185): la CONCESION BASE por combinacion (rol, menu) ya NO es "4 TRUE
--      fijos" sino que depende de TROL_MENU.SOLO_LECTURA. El recorte por
--      usuario desde TUSUARIO_ROL_PERMISO se aplica DESPUES, con la MISMA
--      logica de V185 (bloqueo total vs. solo-lectura, bool_or por
--      TROL_MENU, y OR al colapsar por PK_TMENU cuando el mismo menu llega
--      por varios roles -- el rol menos restrictivo gana).
--   3. Refresca el campo `detail` de la fila de public.query que V185
--      registro para GET /usuarios/:PK_TUSUARIO/permisos-menu (serviceid
--      'eval-col'), para mencionar que la base ahora sale de
--      TROL_MENU.SOLO_LECTURA. role_query NO se toca (sigue solo
--      CEVAL-SUPER_ADMINISTRADOR).
--
-- Por que:
--   Hoy la concesion de menu por rol es todo-o-nada (menu presente en
--   TROL_MENU => los 4 permisos en TRUE). Se quiere que el rol pueda
--   conceder un menu en modo solo-lectura sin depender de un recorte por
--   usuario en TUSUARIO_ROL_PERMISO.
--
-- Fuentes / relacion con V185:
--   Este archivo es una evolucion puntual de V185 (V185 ya esta aplicado en
--   el servidor de test; editarlo romperia su checksum, de ahi una
--   migracion nueva). El cuerpo de la funcion conserva el estilo de V185
--   (CREATE OR REPLACE FUNCTION ... LANGUAGE sql STABLE, CTEs, comentarios).
--   Unico cambio funcional: `menus_del_rol` arrastra rm.SOLO_LECTURA y la
--   base por combo pasa a ser (SOLO_LECTURA = 'SI' ? solo-ver : 4-TRUE).
--   Para 'ver' no cambia nada (un menu concedido siempre es al menos
--   visible salvo bloqueo total del usuario); solo se recorta la triada
--   crear/editar/eliminar.
--
--   Oracle-ismo cadena vacia vs NULL: se usa `IS DISTINCT FROM 'SI'`, que
--   trata NULL y '' (y 'NO', y cualquier otro texto) igual -> "concede los
--   4", identico al criterio que V185 aplica sobre
--   TUSUARIO_ROL_PERMISO.SOLO_LECTURA. Solo el literal exacto 'SI' activa
--   el modo solo-lectura.
--
-- Idempotente:
--   * ADD COLUMN IF NOT EXISTS (columna nueva NULL ya = "los 4", sin backfill).
--   * COMMENT ON COLUMN / COMMENT ON FUNCTION: reejecutables.
--   * CREATE OR REPLACE FUNCTION: misma firma que V185, sin DROP.
--   * UPDATE ... WHERE idempotente (fija el mismo texto); microservice_id
--     se resuelve por serviceid='eval-col', nunca por id literal (patron
--     V185/V85/V124). Si la fila de query no existe todavia, el UPDATE
--     afecta 0 filas sin error.
-- ===========================================================================

SET search_path TO academico_test, public;

-- ---------------------------------------------------------------------------
-- 1. Columna TROL_MENU.SOLO_LECTURA
-- ---------------------------------------------------------------------------
ALTER TABLE academico_test.TROL_MENU
    ADD COLUMN IF NOT EXISTS SOLO_LECTURA VARCHAR(5);

COMMENT ON COLUMN academico_test.TROL_MENU.SOLO_LECTURA IS
    'Modo de concesion del menu por el rol. ''SI'' => el rol concede este menu SOLO para ver (crear/editar/eliminar = FALSE, ver = TRUE). NULL / ''NO'' / cualquier otro valor => el rol concede los 4 permisos (crear/editar/eliminar/ver = TRUE), comportamiento historico. Misma semantica de valores que TUSUARIO_ROL_PERMISO.SOLO_LECTURA, que sigue siendo el recorte fino por usuario. Lo consume fn_usuario_permisos_menu(BIGINT).';

-- ---------------------------------------------------------------------------
-- 2. fn_usuario_permisos_menu: la base por (rol, menu) sale de
--    TROL_MENU.SOLO_LECTURA
-- ---------------------------------------------------------------------------
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
        -- rm.SOLO_LECTURA define la CONCESION base del rol para ese menu:
        --   'SI'                -> solo ver (crear/editar/eliminar FALSE).
        --   NULL / distinto     -> los 4 permisos (comportamiento historico).
        SELECT rm.PK_TROL_MENU, m.PK_TMENU, m.CODIGO, m.NOMBRE, m.URL,
               (rm.SOLO_LECTURA IS DISTINCT FROM 'SI') AS base_puede_editar_like
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
        -- antes de colapsar por PK_TMENU: base del rol (SOLO_LECTURA) menos
        -- el recorte del usuario. 'ver' solo se pierde con bloqueo total.
        SELECT mr.PK_TMENU, mr.CODIGO, mr.NOMBRE, mr.URL,
               mr.base_puede_editar_like
                    AND NOT (COALESCE(b.bloqueo_total, FALSE)
                             OR COALESCE(b.bloqueo_solo_lectura, FALSE)) AS puede_editar_like,
               NOT COALESCE(b.bloqueo_total, FALSE)                      AS puede_ver_combo
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
    IS 'Permisos de menu efectivos de un usuario (dado solo su PK_TUSUARIO): una fila por TMENU activo concedido por alguno de sus roles activos en TSEDE_USUARIO, con su codigo/nombre/path (TMENU.URL) y 4 flags (puede_crear, puede_editar, puede_eliminar, puede_ver). La CONCESION base por combinacion (rol, menu) sale de TROL_MENU.SOLO_LECTURA: ''SI'' => solo ver (crear/editar/eliminar = FALSE, ver = TRUE); NULL o cualquier otro valor => los 4 permisos. TUSUARIO_ROL_PERMISO (ACTIVE=TRUE) recorta esa base por combinacion (rol, menu) puntual: SOLO_LECTURA=''SI'' bloquea crear/editar/eliminar y deja solo ver; cualquier otro bloqueo activo (SOLO_LECTURA NULL o distinto de ''SI'') bloquea los 4. Si el mismo TMENU llega via mas de un rol del usuario, se agregan con OR (el rol menos restrictivo gana para ese menu). No filtra por FK_TSEDE/FK_ENTE de TUSUARIO_ROL_PERMISO -- aplica cualquier bloqueo activo del usuario sobre ese TROL_MENU, sin importar su alcance, porque la funcion no recibe sede/establecimiento como parametro.';

-- ---------------------------------------------------------------------------
-- 3. Refresca el `detail` de la query GET /usuarios/:PK_TUSUARIO/permisos-menu
--    (serviceid 'eval-col'). microservice_id se resuelve por serviceid, no
--    por id literal (patron V185). role_query NO se toca.
-- ---------------------------------------------------------------------------
UPDATE public.query q
   SET detail = 'V185 -- permisos de menu (crear/editar/eliminar/ver) del usuario, para que el front decida que botones mostrar segun su rol. Desde V198 la concesion base por (rol, menu) sale de TROL_MENU.SOLO_LECTURA (''SI'' => menu concedido en solo-lectura: solo ver), ya no son 4 permisos fijos; TUSUARIO_ROL_PERMISO sigue recortando por usuario.'
  FROM public.microservice m
 WHERE q.microservice_id = m.id_microservice
   AND m.serviceid = 'eval-col'
   AND q.path_template = '/usuarios/:PK_TUSUARIO/permisos-menu'
   AND q.http_method = 'GET';
