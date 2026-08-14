-- ===========================================================================
-- V59 — Gestion administrativa de TROL/TMENU/TLISTA_VALOR (academico_test),
-- cableada para servir el contrato de docs/roles-permisos-dtos.md via el
-- catalogo publico.QUERY (SELECT * FROM academico_test.fn_xxx(...)).
--
-- Doce funciones + un trigger + un helper interno, enfocados en:
--   * academico_test.trol       (catalogo de roles academicos) y su reflejo
--     en public.role con el prefijo CEVAL-.
--   * academico_test.tmenu      (catalogo de menus/submenus, jerarquia a 2
--     niveles via FK_TMENU) — incluye FK_TPLAN (plan academico del menu).
--   * academico_test.trol_menu  (asignacion rol <-> menu, con ORDEN_ROL
--     propio para persistir el orden POR ROL, independiente del ORDEN de
--     tmenu que es el orden del catalogo).
--   * academico_test.tlista_valor (seccion CATEGORIA='PLAN').
--
-- AUTORIZACION (aplica a TODAS las funciones excepto el trigger):
--   Cada funcion recibe p_user_pk BIGINT como PRIMER parametro y delega la
--   validacion en el helper academico_test.fn_assert_superadmin, que
--   consulta public.role_users JOIN public.role y exige que p_user_pk
--   tenga vinculado el rol con name = 'CEVAL-SUPER_ADMINISTRADOR'.
--   Cualquier pk que no figure bajo ese rol (NULL incluida) dispara RAISE
--   EXCEPTION con ERRCODE='42501' (insufficient_privilege) y aborta la
--   operacion antes de tocar datos.
--   El trigger fn_sync_trol_to_public_role NO requiere p_user_pk (lo invoca
--   el motor automaticamente tras fn_add_trol, que ya exige superadmin).
--
-- SOBRE CODIGOS DE ERROR (importante para quien cablee el catalogo QUERY):
--   query-service traduce SQLSTATE -> HTTP via PostgresErrorMapper.java (tal
--   como existe HOY en esta rama — sin el caso P0002 que otras ramas puedan
--   tener agregado):
--     42501            -> 403 Forbidden   (RAISE ... USING ERRCODE='42501')
--     23xxx            -> 409 Conflict    (RAISE ... USING ERRCODE='23505' etc.)
--     22xxx            -> 400 Bad Request (RAISE ... USING ERRCODE='22023' etc.)
--     P0001 (default, RAISE EXCEPTION sin USING) -> 400 Bad Request
--     CUALQUIER OTRO INCLUYENDO P0002 -> 500 Internal Server Error (!)
--   El mapper de esta rama NO tiene caso para 404 — ninguno de los ERRCODE
--   disponibles produce HttpStatus.NOT_FOUND. Por eso V59 usa esta
--   convencion, aplicada consistentemente en las tres categorias:
--     * 42501  -> exclusivo de fn_assert_superadmin (autorizacion).
--     * 23505  -> "ya existe" (violacion de unicidad): duplicar CODIGO/
--       NOMBRE/VALOR en trol, tmenu o tlista_valor. Mapea a 409, que es
--       lo que el contrato de roles-permisos-dtos.md documenta para estos
--       casos ("409 nombre repetido").
--     * 22023  -> "referencia invalida": el pk que el caller mando (rol,
--       menu, padre, plan, ids de un array) no existe, no esta activo, o
--       el array/JSONB de entrada esta vacio o mal formado. Aplicado de
--       forma UNIFORME a toda validacion de esta naturaleza, aunque HOY
--       coincida en HTTP status (400) con el default P0001 — la distincion
--       de SQLSTATE documenta la intencion semantica y deja el archivo
--       listo para el dia que el mapper distinga 22xxx de P0001, o agregue
--       un caso para 404.
--     * default (P0001) -> solo para validaciones de "campo obligatorio
--       vacio" / "valor fuera del enum permitido" — el nivel mas basico de
--       error de entrada, sin referenciar ninguna otra fila.
--
--   H. fn_assert_superadmin(p_user_pk BIGINT) -> VOID
--      Helper interno. Unico punto donde vive la regla "tener el rol
--      CEVAL-SUPER_ADMINISTRADOR"; todas las demas funciones lo invocan
--      con PERFORM al inicio del BEGIN. El seed insert justo debajo
--      garantiza que el rol exista incluso en entornos donde V36 no lo
--      haya importado desde academico_test.trol.
--
--   1. fn_list_roles(p_user_pk BIGINT) -> TABLE(id, name)
--      GET /roles. Lista (pk_trol, nombre) de academico_test.trol activos.
--      Reemplaza a la version anterior fn_list_trol_names_for_superadmin,
--      que solo devolvia el nombre — RoleDto{id,name} necesita ambos.
--
--   2. fn_add_trol(p_user_pk, p_nombre, p_created_by, p_estado DEFAULT 'A')
--      -> TABLE(id, name) + trigger
--      POST /roles. Inserta un nuevo rol en academico_test.trol:
--        * p_nombre obligatorio (input del usuario en lowercase y con
--          espacios, p. ej. "jefe de area"). La funcion lo transforma
--          internamente al CODIGO canonico: UPPER + reemplazo de cualquier
--          secuencia de espacios por '_', truncado a 30 chars (limite de
--          trol.codigo VARCHAR(30)).
--        * p_estado OPCIONAL. NULL/vacio -> ACTIVO (estado_ai='A').
--        * no duplica CODIGO activo ni NOMBRE (U_TROL_1) — ambos casos
--          disparan RAISE ... USING ERRCODE='23505' -> 409 Conflict,
--          igual que el contrato documenta para /roles.
--      El trigger AFTER INSERT ON trol materializa 'CEVAL-' || codigo en
--      public.role. Idempotente via ON CONFLICT (name) DO NOTHING.
--
--   3. fn_list_menu_possibilities_for_rol(p_user_pk, p_pk_trol)
--      Devuelve TODAS las combinaciones padre -> submenu del catalogo,
--      marcadas con ya_asignado + orden_rol cuando la combinacion (rol,
--      submenu) ya existe en trol_menu, y con plan_id (tmenu.fk_tplan del
--      submenu). Pensada para la grilla "Submenus" del dialog "Agregar
--      menu". Solo 2 niveles de jerarquia.
--
--   4. fn_associate_menus_to_rol(p_user_pk, p_pk_trol, p_pk_tmenus[],
--                                p_created_by, p_full_replace DEFAULT FALSE)
--      -> TABLE(pk_tmenu, pk_trol_menu, orden_rol, status)
--      Vincula TMENU a un rol. Dos modos:
--        * p_full_replace = FALSE (default, comportamiento incremental
--          historico): UPSERT sobre cada pk del array; lo que ya estaba
--          asignado y no viene en el array queda intacto (no se toca).
--        * p_full_replace = TRUE: semantica de PUT /roles/{roleId}/menus
--          — REEMPLAZO COMPLETO. Todo lo que estaba activo para ese rol y
--          NO figura en p_pk_tmenus se desactiva (soft-delete); el array
--          puede venir vacio (representa "vaciar el menu del rol"). Valida
--          la invariante de jerarquia: si un submenu esta en la lista, su
--          padre tambien debe estarlo (si no, RAISE -> 400).
--      En ambos modos, orden_rol se persiste segun la POSICION del pk
--      dentro de p_pk_tmenus (1-based) — es la columna que GET
--      /roles/{roleId}/menus usa para devolver el array en el orden
--      guardado. Ya NO acepta p_pk_tplan (el plan se mudo a tmenu.fk_tplan,
--      ver fn_upsert_menu) — sigue siendo el paso 4 de la numeracion por
--      continuidad con versiones previas de este archivo.
--
--   5. fn_dissociate_menus_from_rol(p_user_pk, p_pk_trol, p_pk_tmenus[])
--      Desvincula (soft-delete) TMENU especificos de un rol sin afectar el
--      resto de la asignacion. Utilidad de proposito general — el contrato
--      de roles-permisos-dtos.md resuelve el "quitar menu" via
--      fn_associate_menus_to_rol(p_full_replace=TRUE), pero esta funcion
--      sigue disponible para desasignaciones puntuales sin reemplazo total.
--
--   6. fn_list_available_menus(p_user_pk) -> TABLE(..., plan_id, type, ...)
--      GET /menus. Arbol COMPLETO de tmenu, sin filtro por rol. Devuelve
--      visible como BOOLEAN, type como 'GROUP'/'ITEM' (derivado de
--      fk_tmenu IS NULL) y plan_id (tmenu.fk_tplan) — shape listo para
--      MenuDto sin transformaciones adicionales en el catalogo QUERY.
--
--   7. fn_upsert_menu(...) -> TABLE(pk_tmenu, pk_padre, nombre, path,
--                                   icono, orden, visible, plan_id, status)
--      Reemplaza y absorbe a fn_create_parent_menu_with_submenus (V59
--      original). Tres modos segun que parametros opcionales lleguen:
--        MODO EDITAR    (p_pk_tmenu_editar IS NOT NULL)
--          -> PATCH /menus/{id}: UPDATE de esa unica fila. No toca orden
--          ni jerarquia. RAISE (400, no hay 404 real) si no existe/activo.
--        MODO HIJO      (p_pk_tmenu_editar NULL, p_id_padre IS NOT NULL)
--          -> POST /menus con idParent set: INSERT de UN submenu bajo un
--          padre EXISTENTE (valida que el padre exista, este activo y sea
--          raiz — fk_tmenu IS NULL). orden = MAX(orden)+1 entre hermanos
--          si no se especifica p_orden.
--        MODO RAIZ      (ambos NULL, default)
--          -> POST /menus con idParent=null: INSERT de un menu raiz
--          (fk_tmenu=NULL). Si ademas viene p_submenus (JSONB array), se
--          crean N hijos bajo ese nuevo padre en la misma llamada (flujo
--          batch "Crear nuevo menu principal" con grilla de submenus) —
--          se preserva por compatibilidad con el flujo original de V59.
--          Cada elemento de p_submenus admite {nombre,url,visible,orden,
--          plan_id}; se procesan per-row (un error no aborta la lista).
--      p_plan_id (o el "plan_id" de cada submenu del array) se valida
--      contra tlista_valor CATEGORIA='PLAN' y se persiste en tmenu.fk_tplan
--      — este es el unico lugar de todo V59 donde se escribe esa columna,
--      consistente con la decision de que el plan es propiedad del MENU
--      (catalogo), no de la asignacion rol x menu.
--
--   8. fn_reorder_menus(p_user_pk, p_items JSONB)
--      -> TABLE(pk_tmenu, orden)
--      PUT /menus/order. p_items = [{"id":.., "menuOrder":..}, ...] (las
--      mismas claves que manda el front, sin transformar). Bulk UPDATE
--      atomico (una sola funcion = una sola transaccion) de tmenu.orden.
--      Valida que TODOS los ids compartan el mismo padre (fk_tmenu) antes
--      de aplicar nada — "el movimiento es siempre entre hermanos".
--
--   9. fn_delete_menu(p_user_pk, p_pk_tmenu)
--      -> TABLE(pk_tmenu, was_deleted)
--      Pensada para PUT /menus/{id}/eliminar (el catalogo QUERY NO admite
--      HTTP_METHOD=DELETE — V33/V55: "para borrar, publica un
--      procedimiento y llamalo con CALL/PUT"; el resto del sistema sigue
--      el patron PUT .../eliminar, nunca un verbo DELETE literal). Soft-
--      delete en cascada: el menu, sus hijos directos, y las filas de
--      trol_menu de todos ellos.
--
--  10. fn_list_plans_from_value(p_user_pk) -> TABLE(id, name, valor, activo)
--      GET /plans. Planes activos de tlista_valor CATEGORIA='PLAN'.
--
--  11. fn_create_plan_from_value(p_user_pk, p_nombre)
--      -> TABLE(id, name, valor, status)
--      POST /plans. p_created_by se deriva de CURRENT_USER (la UI solo
--      manda el nombre). Duplicado de VALOR -> RAISE USING ERRCODE='23505'
--      -> 409 Conflict (antes caia en el default 400).
--
--  12. fn_delete_plan_from_value(p_user_pk, p_nombre)
--      -> TABLE(id, name, was_deleted)
--      Soft-delete por nombre. No tiene endpoint documentado en
--      roles-permisos-dtos.md todavia; se conserva como utilidad general.
--
-- Mapping:
--   academico_test.trol.PK_TROL  -- clave primaria del catalogo de roles
--   academico_test.trol.CODIGO   -- identificador snake_case que va al name
--   academico_test.trol.NOMBRE   -- etiqueta humana que va a description
--   public.role.name = 'CEVAL-' || trol.codigo
--   public.role.description = trol.nombre
--   academico_test.tmenu.PK_TMENU / FK_TMENU -- jerarquia padre -> submenu
--   academico_test.tmenu.FK_TPLAN -- plan academico del MENU (catalogo),
--                                    FK nullable a tlista_valor(pk_lista_valor)
--                                    con CATEGORIA='PLAN'. Escrito SOLO por
--                                    fn_upsert_menu.
--   academico_test.trol_menu.FK_TROL / FK_TMENU -- asignacion rol -> menu
--   academico_test.trol_menu.ORDEN_ROL -- posicion de ese menu DENTRO del
--                                          menu de ESE rol (independiente
--                                          de tmenu.orden, que es el orden
--                                          del catalogo). Escrito por
--                                          fn_associate_menus_to_rol.
--
-- Idempotencia:
--   * CREATE OR REPLACE FUNCTION en las doce funciones + el helper interno.
--   * DROP TRIGGER IF EXISTS antes del CREATE para re-aplicacion segura.
--   * public.role se inserta con ON CONFLICT (name) DO NOTHING.
--   * Seed de planes academicos con WHERE NOT EXISTS (solo inserta lo que
--     falte).
--   * TROL_MENU usa ON CONFLICT (FK_TROL, FK_TMENU) DO UPDATE para
--     re-activar filas previamente soft-deleted.
--   * ADD COLUMN IF NOT EXISTS + CREATE INDEX IF NOT EXISTS para
--     tmenu.fk_tplan y trol_menu.orden_rol.
--
-- Historial de diseno (por que cambio desde la primera version de V59):
--   * V59 originalmente until esta revision guardaba el plan en
--     trol_menu.fk_tplan (plan por asignacion rol x submenu). Al cablear
--     el contrato real (docs/roles-permisos-dtos.md), MenuDto.planId /
--     SaveMenuRequest.planId resultaron ser propiedades del MENU en
--     GET/POST/PATCH /menus — SIN rol en la URL. Se migro la columna a
--     tmenu.fk_tplan y se elimino trol_menu.fk_tplan (nunca broke produccion:
--     la migracion no habia salido de una rama de feature).
--   * fn_create_parent_menu_with_submenus se renombro/expandio a
--     fn_upsert_menu para tambien cubrir "editar un menu" (PATCH) y "crear
--     UN hijo bajo un padre existente" (POST con idParent) sin sumar dos
--     funciones nuevas — la logica de derivacion de CODIGO, validacion de
--     duplicados y normalizacion de visible se reutiliza entre los 3 modos.
--   * fn_associate_menus_to_rol gano p_full_replace en vez de crear una
--     fn_replace_role_menus aparte — el bucle FOREACH ya recorria el array
--     con una posicion implicita, que ahora se persiste como orden_rol.
--   * fn_list_trol_names_for_superadmin se renombro a fn_list_roles porque
--     su forma de retorno cambio de "solo nombre" a "(id, name)" para
--     alimentar RoleDto directamente.
--   * fn_reorder_menus y fn_delete_menu SI son funciones nuevas — no hay
--     ninguna existente cuya responsabilidad se solape con un bulk-UPDATE
--     de orden entre hermanos o con un soft-delete en cascada.
--
-- No cubre (fuera de scope):
--   * GET /sso-admin/myMenu?app= (menu ya filtrado por los roles del JWT,
--     usado en TODA la app, no solo en la pantalla de administracion).
--     Requiere resolver academico_test.trol por CODIGO a partir de
--     :CONTEXT.ROLES_ARRAY (strip del prefijo 'CEVAL-'), lo cual es una
--     consulta de forma distinta a todo lo demas en este archivo (no
--     recibe p_pk_trol explicito ni exige superadmin — cualquier usuario
--     autenticado puede pedir SU propio menu). Se deja para una migracion
--     aparte.
--   * Autorizacion fina por operacion + recurso: la regla actual es
--     binaria (CEVAL-SUPER_ADMINISTRADOR o nada). Si en el futuro se
--     necesita que un usuario sin ese rol edite solo SU institucion, hace
--     falta evolucionar el helper.
--   * Asignacion masiva de CEVAL-SUPER_ADMINISTRADOR a usuarios iniciales:
--     el seed garantiza que el ROL exista, pero vincularlo a usuarios
--     concretos (pk 1, 2, 3 historicos) se hace aparte via sso-admin o una
--     carga inicial.
--   * UPDATE/DELETE sobre trol en si (el ROL academico): no se sincroniza
--     ese tipo de cambio en public.role — mismo criterio que V57.
--   * DELETE HARD en cualquier tabla de este archivo: todo es soft-delete
--     (active=FALSE) para preservar auditoria historica.
-- ===========================================================================

SET search_path TO academico_test, public;


-- ---------------------------------------------------------------------------
-- H) fn_assert_superadmin (helper interno)
--    Unico punto donde vive la regla "solo superadministradores pueden
--    ejecutar las funciones administrativas de V59". La autorizacion se
--    hace por ROL, no por lista hardcoded de pks: la funcion consulta
--    public.role_users (unido a public.role por id_role) y exige que
--    public.users.id_user = p_user_pk tenga vinculado el rol cuyo
--    name = 'CEVAL-SUPER_ADMINISTRADOR'.
--
--    Todas las funciones listadas abajo lo invocan con PERFORM al inicio
--    de su BEGIN como PRIMER statement, antes de tocar datos.
--
--    Cualquier pk que no figure en public.role_users bajo el rol
--    CEVAL-SUPER_ADMINISTRADOR (NULL incluida) dispara RAISE EXCEPTION
--    con ERRCODE='42501' (insufficient_privilege, mapeado a 403).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_assert_superadmin(
    p_user_pk BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
SET search_path = academico_test, public
AS $$
BEGIN
    IF p_user_pk IS NULL THEN
        RAISE EXCEPTION 'fn_assert_superadmin: p_user_pk es obligatorio'
            USING ERRCODE = '42501'; -- insufficient_privilege
    END IF;

    IF NOT EXISTS (
        SELECT 1
          FROM public.role_users ru
          JOIN public.role     r ON r.id_role = ru.role_id
         WHERE ru.user_id = p_user_pk
           AND r.name     = 'CEVAL-SUPER_ADMINISTRADOR'
    ) THEN
        RAISE EXCEPTION 'fn_assert_superadmin: usuario pk=% no tiene el rol CEVAL-SUPER_ADMINISTRADOR', p_user_pk
            USING ERRCODE = '42501'; -- insufficient_privilege
    END IF;
END;
$$;


-- ---------------------------------------------------------------------------
-- Seed defensivo: asegura que el rol CEVAL-SUPER_ADMINISTRADOR exista en
-- public.role. En condiciones normales V36 lo importa desde
-- academico_test.trol, pero este INSERT actua como red de seguridad.
-- Idempotente (WHERE NOT EXISTS). No asigna el rol a ningun usuario.
-- ---------------------------------------------------------------------------
INSERT INTO public.role (name, description)
SELECT 'CEVAL-SUPER_ADMINISTRADOR', 'Super Administrador del sistema academico (V59 seed)'
 WHERE NOT EXISTS (
       SELECT 1 FROM public.role WHERE name = 'CEVAL-SUPER_ADMINISTRADOR'
       );


-- ---------------------------------------------------------------------------
-- Esquema.
--
-- (1) tmenu.fk_tplan — el plan academico es propiedad del MENU (catalogo),
--     no de la asignacion rol x menu. Nullable + ON DELETE SET NULL (si un
--     plan se hard-elimina, el menu queda sin plan en vez de referenciar
--     una fila inexistente; en operacion normal los planes se soft-eliminan).
--
-- (2) trol_menu.orden_rol — posicion del menu DENTRO del menu de un rol
--     especifico. Distinto de tmenu.orden (orden del catalogo, global).
--     Es la columna que GET /roles/{roleId}/menus usa para devolver la
--     lista "en el orden guardado" en vez de recalculada — la distincion
--     que roles-permisos-dtos.md marca como clave del backend.
-- ---------------------------------------------------------------------------
ALTER TABLE academico_test.tmenu
ADD COLUMN IF NOT EXISTS fk_tplan BIGINT
    REFERENCES academico_test.tlista_valor(pk_lista_valor)
    ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_tmenu_fk_tplan
    ON academico_test.tmenu(fk_tplan)
    WHERE fk_tplan IS NOT NULL;

ALTER TABLE academico_test.trol_menu
ADD COLUMN IF NOT EXISTS orden_rol NUMERIC;


-- ---------------------------------------------------------------------------
-- Limpieza de firmas anteriores de V59 que cambian de forma en esta
-- revision. CREATE OR REPLACE FUNCTION no puede cambiar el tipo de
-- retorno (RETURNS TABLE) de una funcion existente — Postgres exige un
-- DROP primero (InvalidFunctionDefinition: "cannot change return type of
-- existing function"). Tambien se eliminan explicitamente las funciones
-- renombradas (fn_list_trol_names_for_superadmin -> fn_list_roles,
-- fn_create_parent_menu_with_submenus -> fn_upsert_menu) para que no
-- queden huerfanas en un entorno donde ya se aplico una version anterior
-- de este mismo archivo. IF EXISTS hace esto seguro tanto en un entorno
-- nuevo (nada que borrar) como en uno con la V59 previa ya aplicada.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_list_trol_names_for_superadmin(BIGINT);
DROP FUNCTION IF EXISTS academico_test.fn_add_trol(BIGINT, VARCHAR, VARCHAR, VARCHAR);
DROP FUNCTION IF EXISTS academico_test.fn_list_menu_possibilities_for_rol(BIGINT, BIGINT);
DROP FUNCTION IF EXISTS academico_test.fn_associate_menus_to_rol(BIGINT, BIGINT, BIGINT[], VARCHAR, BIGINT);
DROP FUNCTION IF EXISTS academico_test.fn_list_available_menus(BIGINT);
DROP FUNCTION IF EXISTS academico_test.fn_create_parent_menu_with_submenus(BIGINT, VARCHAR, VARCHAR, VARCHAR, VARCHAR, NUMERIC, VARCHAR, JSONB);
DROP FUNCTION IF EXISTS academico_test.fn_list_plans_from_value(BIGINT);
DROP FUNCTION IF EXISTS academico_test.fn_create_plan_from_value(BIGINT, VARCHAR);
DROP FUNCTION IF EXISTS academico_test.fn_delete_plan_from_value(BIGINT, VARCHAR);


-- ---------------------------------------------------------------------------
-- 1) fn_list_roles
--    GET /roles -> RoleDto[]. Lista (pk_trol, nombre) de trol activos.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_list_roles(
    p_user_pk BIGINT
)
RETURNS TABLE (id BIGINT, name VARCHAR)
LANGUAGE plpgsql
STABLE
SET search_path = academico_test, public
AS $$
BEGIN
    PERFORM academico_test.fn_assert_superadmin(p_user_pk);

    RETURN QUERY
    SELECT t.pk_trol, t.nombre
      FROM academico_test.trol t
     WHERE t.active = TRUE
     ORDER BY t.nombre;
END;
$$;


-- ---------------------------------------------------------------------------
-- 2) fn_add_trol
--    POST /roles -> RoleDto. Inserta un nuevo rol en academico_test.trol.
--    El CODIGO se deriva del NOMBRE: UPPER + colapso de espacios a '_',
--    truncado a 30 chars (limite de trol.codigo VARCHAR(30)).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_add_trol(
    p_user_pk    BIGINT,
    p_nombre     VARCHAR,
    p_created_by VARCHAR,
    p_estado     VARCHAR DEFAULT 'A'
)
RETURNS TABLE (id BIGINT, name VARCHAR)
LANGUAGE plpgsql
VOLATILE
SET search_path = academico_test, public
AS $$
DECLARE
    v_nombre    VARCHAR;
    v_codigo    VARCHAR;
    v_estado    CHAR(1);
    v_existente BIGINT;
BEGIN
    PERFORM academico_test.fn_assert_superadmin(p_user_pk);

    -- Validacion 1: nombre obligatorio y no vacio (400 — RAISE sin ERRCODE).
    IF p_nombre IS NULL OR LENGTH(TRIM(p_nombre)) = 0 THEN
        RAISE EXCEPTION 'fn_add_trol: p_nombre es obligatorio';
    END IF;
    v_nombre := TRIM(p_nombre);

    -- Derivacion del CODIGO: 'jefe de area' -> 'JEFE_DE_AREA'.
    v_codigo := LEFT(UPPER(REGEXP_REPLACE(v_nombre, '\s+', '_', 'g')), 30);

    -- Validacion 2 + normalizacion del estado (dominio estado_ai: 'A'/'I').
    IF p_estado IS NULL OR LENGTH(TRIM(p_estado)) = 0 THEN
        v_estado := 'A';
    ELSIF UPPER(TRIM(p_estado)) IN ('I', 'INACTIVO') THEN
        v_estado := 'I';
    ELSIF UPPER(TRIM(p_estado)) IN ('A', 'ACTIVO') THEN
        v_estado := 'A';
    ELSE
        RAISE EXCEPTION 'fn_add_trol: p_estado % invalido (valores: ACTIVO, INACTIVO)', p_estado;
    END IF;

    IF p_created_by IS NULL OR LENGTH(TRIM(p_created_by)) = 0 THEN
        RAISE EXCEPTION 'fn_add_trol: p_created_by es obligatorio';
    END IF;

    -- Duplicado CODIGO activo -> 409 Conflict (contrato: "409 nombre repetido").
    SELECT t.pk_trol INTO v_existente
      FROM academico_test.trol t
     WHERE UPPER(TRIM(t.codigo)) = v_codigo AND t.active = TRUE
     LIMIT 1;
    IF v_existente IS NOT NULL THEN
        RAISE EXCEPTION 'fn_add_trol: ya existe un TROL activo con codigo=% (pk=%)', v_codigo, v_existente
            USING ERRCODE = '23505'; -- unique_violation -> 409 Conflict
    END IF;

    -- Duplicado NOMBRE (U_TROL_1) -> 409 Conflict.
    SELECT t.pk_trol INTO v_existente
      FROM academico_test.trol t
     WHERE UPPER(TRIM(t.nombre)) = UPPER(v_nombre)
     LIMIT 1;
    IF v_existente IS NOT NULL THEN
        RAISE EXCEPTION 'fn_add_trol: ya existe un TROL con nombre=% (pk=%)', v_nombre, v_existente
            USING ERRCODE = '23505'; -- unique_violation -> 409 Conflict
    END IF;

    INSERT INTO academico_test.trol (codigo, nombre, estado, created_by)
    VALUES (v_codigo, v_nombre, v_estado, TRIM(p_created_by))
    RETURNING academico_test.trol.pk_trol, academico_test.trol.nombre
      INTO id, name;

    RETURN NEXT;
END;
$$;


-- ---------------------------------------------------------------------------
-- 3) Trigger AFTER INSERT ON trol -> public.role
--    Refleja el nuevo rol en public.role con prefijo CEVAL-.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_sync_trol_to_public_role()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_role_name VARCHAR;
BEGIN
    IF NEW.codigo IS NULL OR LENGTH(TRIM(NEW.codigo)) = 0 THEN
        RAISE WARNING 'fn_sync_trol_to_public_role: TROL pk=% sin CODIGO — skip', NEW.pk_trol;
        RETURN NEW;
    END IF;

    v_role_name := 'CEVAL-' || TRIM(NEW.codigo);

    INSERT INTO public.role (name, description)
    VALUES (v_role_name, NEW.nombre)
    ON CONFLICT (name) DO NOTHING;

    RETURN NEW;
END;
$$;


DROP TRIGGER IF EXISTS trg_sync_trol_to_public_role
    ON academico_test.trol;

CREATE TRIGGER trg_sync_trol_to_public_role
    AFTER INSERT ON academico_test.trol
    FOR EACH ROW
    EXECUTE FUNCTION academico_test.fn_sync_trol_to_public_role();


-- ---------------------------------------------------------------------------
-- 4) fn_list_menu_possibilities_for_rol
--    Devuelve TODAS las combinaciones padre -> submenu, marcadas con
--    ya_asignado + orden_rol (de trol_menu) y plan_id (de tmenu.fk_tplan
--    del submenu). Pensada para la grilla "Submenus" del dialog "Agregar
--    menu". Solo 2 niveles de jerarquia.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_list_menu_possibilities_for_rol(
    p_user_pk  BIGINT,
    p_pk_trol  BIGINT
)
RETURNS TABLE (
    pk_padre        BIGINT,
    nombre_padre    VARCHAR,
    icono_padre     VARCHAR,
    orden_padre     NUMERIC,
    pk_submenu      BIGINT,
    nombre_submenu  VARCHAR,
    url             VARCHAR,
    visible         BOOLEAN,
    orden_submenu   NUMERIC,
    plan_id         BIGINT,
    ya_asignado     BOOLEAN,
    orden_rol       NUMERIC
)
LANGUAGE plpgsql
STABLE
SET search_path = academico_test, public
AS $$
BEGIN
    PERFORM academico_test.fn_assert_superadmin(p_user_pk);

    IF p_pk_trol IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM academico_test.trol
            WHERE pk_trol = p_pk_trol AND active = TRUE
       )
    THEN
        -- 400 (no hay 404 real en PostgresErrorMapper — ver nota del header).
        -- ERRCODE='22023' (invalid_parameter_value): p_pk_trol no referencia
        -- una fila valida, mismo tratamiento que el resto de referencias
        -- invalidas en este archivo (consistencia de categoria de error).
        RAISE EXCEPTION 'fn_list_menu_possibilities_for_rol: TROL pk=% no existe o no esta activo', p_pk_trol
            USING ERRCODE = '22023';
    END IF;

    RETURN QUERY
    SELECT
        padre.pk_tmenu                  AS pk_padre,
        padre.nombre                    AS nombre_padre,
        padre.icono                     AS icono_padre,
        padre.orden                     AS orden_padre,
        hijo.pk_tmenu                   AS pk_submenu,
        hijo.nombre                     AS nombre_submenu,
        hijo.url                        AS url,
        (hijo.visible = 'S')            AS visible,
        hijo.orden                      AS orden_submenu,
        hijo.fk_tplan                   AS plan_id,
        (tm.pk_trol_menu IS NOT NULL)   AS ya_asignado,
        tm.orden_rol                    AS orden_rol
    FROM academico_test.tmenu padre
    INNER JOIN academico_test.tmenu hijo
           ON hijo.fk_tmenu  = padre.pk_tmenu
          AND hijo.estado    = 'A'
          AND hijo.active    = TRUE
    LEFT JOIN academico_test.trol_menu tm
           ON tm.fk_tmenu = hijo.pk_tmenu
          AND tm.fk_trol  = p_pk_trol
          AND tm.active   = TRUE
    WHERE padre.fk_tmenu IS NULL
      AND padre.estado   = 'A'
      AND padre.active   = TRUE
    ORDER BY
        padre.orden NULLS LAST, padre.nombre,
        hijo.orden  NULLS LAST, hijo.nombre;
END;
$$;


-- ---------------------------------------------------------------------------
-- 5) fn_associate_menus_to_rol
--    Vincula TMENU a un rol. p_full_replace=FALSE (default) preserva el
--    comportamiento incremental historico (UPSERT, no toca lo demas).
--    p_full_replace=TRUE implementa PUT /roles/{roleId}/menus: reemplazo
--    completo con orden persistido (orden_rol = posicion en el array) y
--    validacion de la invariante de jerarquia (submenu implica su padre).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_associate_menus_to_rol(
    p_user_pk      BIGINT,
    p_pk_trol      BIGINT,
    p_pk_tmenus    BIGINT[],
    p_created_by   VARCHAR,
    p_full_replace BOOLEAN DEFAULT FALSE
)
RETURNS TABLE (
    pk_tmenu     BIGINT,
    pk_trol_menu BIGINT,
    orden_rol    NUMERIC,
    status       VARCHAR
)
LANGUAGE plpgsql
VOLATILE
SET search_path = academico_test, public
AS $$
DECLARE
    v_tmenu        BIGINT;
    v_idx          NUMERIC := 0;
    v_pk           BIGINT;
    v_was_inserted BOOLEAN;
    v_now          TIMESTAMP := CURRENT_TIMESTAMP;
BEGIN
    PERFORM academico_test.fn_assert_superadmin(p_user_pk);

    IF p_pk_trol IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM academico_test.trol
            WHERE pk_trol = p_pk_trol AND active = TRUE
       )
    THEN
        RAISE EXCEPTION 'fn_associate_menus_to_rol: TROL pk=% no existe o no esta activo', p_pk_trol
            USING ERRCODE = '22023';
    END IF;

    -- El array puede venir vacio SOLO en modo full_replace (equivale a
    -- "vaciar el menu del rol"); en modo incremental debe traer algo.
    IF p_pk_tmenus IS NULL THEN
        RAISE EXCEPTION 'fn_associate_menus_to_rol: p_pk_tmenus no puede ser NULL'
            USING ERRCODE = '22023'; -- invalid_parameter_value
    END IF;
    IF NOT p_full_replace AND array_length(p_pk_tmenus, 1) IS NULL THEN
        RAISE EXCEPTION 'fn_associate_menus_to_rol: p_pk_tmenus debe contener al menos un PK en modo incremental'
            USING ERRCODE = '22023';
    END IF;

    IF p_created_by IS NULL OR LENGTH(TRIM(p_created_by)) = 0 THEN
        RAISE EXCEPTION 'fn_associate_menus_to_rol: p_created_by es obligatorio';
    END IF;

    -- Invariante de jerarquia (solo tiene sentido validarla en full_replace,
    -- que representa el estado FINAL completo del menu del rol): si un
    -- submenu esta en la lista, su padre tambien debe estarlo.
    IF p_full_replace AND EXISTS (
        SELECT 1
          FROM academico_test.tmenu m
         WHERE m.pk_tmenu = ANY(p_pk_tmenus)
           AND m.fk_tmenu IS NOT NULL
           AND NOT (m.fk_tmenu = ANY(p_pk_tmenus))
    ) THEN
        RAISE EXCEPTION 'fn_associate_menus_to_rol: hay submenus en p_pk_tmenus sin su menu padre incluido (invariante de jerarquia)'
            USING ERRCODE = '22023';
    END IF;

    -- Modo reemplazo completo: desactiva todo lo que NO figure en la
    -- lista nueva. NOT (fk_tmenu = ANY('{}')) es TRUE para todas las filas
    -- cuando el array llega vacio, asi que un array vacio vacia el menu.
    IF p_full_replace THEN
        UPDATE academico_test.trol_menu tm
           SET active      = FALSE,
               modified_by = TRIM(p_created_by),
               modified_at = v_now
         WHERE tm.fk_trol = p_pk_trol
           AND tm.active  = TRUE
           AND NOT (tm.fk_tmenu = ANY(p_pk_tmenus));
    END IF;

    FOREACH v_tmenu IN ARRAY p_pk_tmenus LOOP
        v_idx        := v_idx + 1;
        pk_tmenu     := v_tmenu;
        pk_trol_menu := NULL;
        orden_rol    := v_idx;
        status       := NULL;

        -- Validacion per-row: el menu debe existir y estar activo.
        IF v_tmenu IS NULL OR NOT EXISTS (
            SELECT 1 FROM academico_test.tmenu m
             WHERE m.pk_tmenu = v_tmenu AND m.active = TRUE AND m.estado = 'A'
        ) THEN
            status := 'menu_not_found_or_inactive';
            RETURN NEXT;
            CONTINUE;
        END IF;

        INSERT INTO academico_test.trol_menu (
            fk_trol, fk_tmenu, orden_rol, active, created_by
        )
        VALUES (
            p_pk_trol, v_tmenu, v_idx, TRUE, TRIM(p_created_by)
        )
        ON CONFLICT (fk_trol, fk_tmenu) DO UPDATE
           SET active      = TRUE,
               orden_rol   = v_idx,
               modified_by = TRIM(p_created_by),
               modified_at = v_now
        RETURNING academico_test.trol_menu.pk_trol_menu,
                  (academico_test.trol_menu.xmax = 0)
          INTO v_pk, v_was_inserted;

        pk_trol_menu := v_pk;
        status := CASE WHEN v_was_inserted THEN 'inserted' ELSE 'reactivated' END;
        RETURN NEXT;
    END LOOP;
END;
$$;


-- ---------------------------------------------------------------------------
-- 6) fn_dissociate_menus_from_rol
--    Desvincula (soft-delete) TMENU puntuales de un rol, sin tocar el
--    resto de su asignacion. Utilidad de proposito general.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_dissociate_menus_from_rol(
    p_user_pk   BIGINT,
    p_pk_trol   BIGINT,
    p_pk_tmenus BIGINT[]
)
RETURNS TABLE (
    pk_tmenu    BIGINT,
    was_deleted BOOLEAN
)
LANGUAGE plpgsql
VOLATILE
SET search_path = academico_test, public
AS $$
DECLARE
    v_tmenu BIGINT;
    v_rows  INTEGER;
BEGIN
    PERFORM academico_test.fn_assert_superadmin(p_user_pk);

    IF p_pk_trol IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM academico_test.trol
            WHERE pk_trol = p_pk_trol AND active = TRUE
       )
    THEN
        RAISE EXCEPTION 'fn_dissociate_menus_from_rol: TROL pk=% no existe o no esta activo', p_pk_trol
            USING ERRCODE = '22023';
    END IF;

    IF p_pk_tmenus IS NULL
       OR array_length(p_pk_tmenus, 1) IS NULL
    THEN
        RAISE EXCEPTION 'fn_dissociate_menus_from_rol: p_pk_tmenus debe contener al menos un PK'
            USING ERRCODE = '22023';
    END IF;

    FOREACH v_tmenu IN ARRAY p_pk_tmenus LOOP
        pk_tmenu    := v_tmenu;
        was_deleted := FALSE;

        UPDATE academico_test.trol_menu
           SET active      = FALSE,
               modified_by = CURRENT_USER,
               modified_at = CURRENT_TIMESTAMP
         WHERE fk_trol  = p_pk_trol
           AND fk_tmenu = v_tmenu
           AND active   = TRUE;

        GET DIAGNOSTICS v_rows = ROW_COUNT;
        was_deleted := (v_rows > 0);

        RETURN NEXT;
    END LOOP;
END;
$$;


-- ---------------------------------------------------------------------------
-- 7) fn_list_available_menus
--    GET /menus -> MenuDto[]. Arbol completo de tmenu, sin filtro por rol.
--    visible como BOOLEAN, type derivado ('GROUP'/'ITEM'), plan_id de
--    tmenu.fk_tplan — shape listo para MenuDto.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_list_available_menus(
    p_user_pk BIGINT
)
RETURNS TABLE (
    pk_tmenu BIGINT,
    pk_padre BIGINT,
    nombre   VARCHAR,
    url      VARCHAR,
    icono    VARCHAR,
    visible  BOOLEAN,
    orden    NUMERIC,
    plan_id  BIGINT,
    type     VARCHAR
)
LANGUAGE plpgsql
STABLE
SET search_path = academico_test, public
AS $$
BEGIN
    PERFORM academico_test.fn_assert_superadmin(p_user_pk);

    RETURN QUERY
    SELECT
        m.pk_tmenu,
        m.fk_tmenu                          AS pk_padre,
        m.nombre,
        m.url,
        m.icono,
        (m.visible = 'S')                   AS visible,
        m.orden,
        m.fk_tplan                          AS plan_id,
        (CASE WHEN m.fk_tmenu IS NULL THEN 'GROUP' ELSE 'ITEM' END)::VARCHAR AS type
    FROM academico_test.tmenu m
    WHERE m.estado = 'A'
      AND m.active = TRUE
    ORDER BY
        COALESCE(m.fk_tmenu, m.pk_tmenu),   -- agrupa submenus bajo su padre
        (m.fk_tmenu IS NULL) DESC,          -- padre antes que hijos
        m.orden NULLS LAST,
        m.nombre;
END;
$$;


-- ---------------------------------------------------------------------------
-- 8) fn_upsert_menu
--    Tres modos (ver header): EDITAR (p_pk_tmenu_editar), HIJO BAJO PADRE
--    EXISTENTE (p_id_padre), o RAIZ +/- batch de submenus (default).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_upsert_menu(
    p_user_pk         BIGINT,
    p_nombre          VARCHAR,
    p_created_by      VARCHAR,
    p_url             VARCHAR DEFAULT NULL,
    p_icono           VARCHAR DEFAULT NULL,
    p_visible         VARCHAR DEFAULT 'S',
    p_orden           NUMERIC DEFAULT NULL,
    p_plan_id         BIGINT  DEFAULT NULL,
    p_id_padre        BIGINT  DEFAULT NULL,
    p_pk_tmenu_editar BIGINT  DEFAULT NULL,
    p_submenus        JSONB   DEFAULT NULL
)
RETURNS TABLE (
    pk_tmenu BIGINT,
    pk_padre BIGINT,
    nombre   VARCHAR,
    path     VARCHAR,
    icono    VARCHAR,
    orden    NUMERIC,
    visible  BOOLEAN,
    plan_id  BIGINT,
    status   VARCHAR
)
LANGUAGE plpgsql
VOLATILE
SET search_path = academico_test, public
AS $$
DECLARE
    v_nombre     VARCHAR;
    v_codigo     VARCHAR;
    v_visible_ch CHAR(1);
    v_existente  BIGINT;
    v_orden_calc NUMERIC;

    -- Iteradores per-submenu (modo RAIZ + batch).
    v_sub_nombre     VARCHAR;
    v_sub_url        VARCHAR;
    v_sub_visible_in VARCHAR;
    v_sub_orden      NUMERIC;
    v_sub_plan_id    BIGINT;
    v_sub_codigo     VARCHAR;
    v_sub_orden_calc NUMERIC;
    v_padre_pk       BIGINT;
BEGIN
    PERFORM academico_test.fn_assert_superadmin(p_user_pk);

    IF p_created_by IS NULL OR LENGTH(TRIM(p_created_by)) = 0 THEN
        RAISE EXCEPTION 'fn_upsert_menu: p_created_by es obligatorio';
    END IF;

    -- Normalizacion de visible: 'S'/'N' (acepta SI/NO/TRUE/FALSE/Y/1/0).
    IF p_visible IS NULL OR LENGTH(TRIM(p_visible)) = 0
       OR UPPER(TRIM(p_visible)) IN ('S', 'SI', 'TRUE', 'Y', '1')
    THEN
        v_visible_ch := 'S';
    ELSIF UPPER(TRIM(p_visible)) IN ('N', 'NO', 'FALSE', '0') THEN
        v_visible_ch := 'N';
    ELSE
        RAISE EXCEPTION 'fn_upsert_menu: p_visible % invalido', p_visible;
    END IF;

    -- Validacion de plan (si viene): debe existir, activo, CATEGORIA='PLAN'.
    IF p_plan_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.tlista_valor lv
         WHERE lv.pk_lista_valor = p_plan_id
           AND lv.categoria      = 'PLAN'
           AND lv.active         = TRUE
    ) THEN
        RAISE EXCEPTION 'fn_upsert_menu: p_plan_id=% no es un plan activo (CATEGORIA=PLAN)', p_plan_id
            USING ERRCODE = '22023';
    END IF;

    -- =======================================================================
    -- MODO EDITAR — PATCH /menus/{id}
    -- =======================================================================
    IF p_pk_tmenu_editar IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM academico_test.tmenu m
             WHERE m.pk_tmenu = p_pk_tmenu_editar AND m.active = TRUE
        ) THEN
            RAISE EXCEPTION 'fn_upsert_menu: TMENU pk=% no existe o no esta activo', p_pk_tmenu_editar
                USING ERRCODE = '22023';
        END IF;

        IF p_nombre IS NULL OR LENGTH(TRIM(p_nombre)) = 0 THEN
            RAISE EXCEPTION 'fn_upsert_menu: p_nombre es obligatorio';
        END IF;
        v_nombre := TRIM(p_nombre);
        v_codigo := LEFT(UPPER(REGEXP_REPLACE(v_nombre, '\s+', '_', 'g')), 30);

        SELECT m.pk_tmenu INTO v_existente
          FROM academico_test.tmenu m
         WHERE UPPER(TRIM(m.codigo)) = v_codigo
           AND m.active = TRUE
           AND m.pk_tmenu <> p_pk_tmenu_editar
         LIMIT 1;
        IF v_existente IS NOT NULL THEN
            RAISE EXCEPTION 'fn_upsert_menu: ya existe otro TMENU activo con codigo=% (pk=%)', v_codigo, v_existente
                USING ERRCODE = '23505';
        END IF;

        UPDATE academico_test.tmenu m
           SET nombre      = v_nombre,
               codigo      = v_codigo,
               url         = p_url,
               icono       = p_icono,
               visible     = v_visible_ch,
               fk_tplan    = p_plan_id,
               modified_by = TRIM(p_created_by),
               modified_at = CURRENT_TIMESTAMP
         WHERE m.pk_tmenu = p_pk_tmenu_editar
        RETURNING m.pk_tmenu, m.fk_tmenu, m.nombre, m.url, m.icono, m.orden,
                  (m.visible = 'S'), m.fk_tplan
          INTO pk_tmenu, pk_padre, nombre, path, icono, orden, visible, plan_id;

        status := 'updated';
        RETURN NEXT;
        RETURN;
    END IF;

    -- =======================================================================
    -- MODO HIJO BAJO PADRE EXISTENTE — POST /menus con idParent
    -- =======================================================================
    IF p_id_padre IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM academico_test.tmenu m
             WHERE m.pk_tmenu = p_id_padre
               AND m.active = TRUE
               AND m.fk_tmenu IS NULL
        ) THEN
            RAISE EXCEPTION 'fn_upsert_menu: el padre pk=% no existe, no esta activo o no es un menu raiz', p_id_padre
                USING ERRCODE = '22023';
        END IF;

        IF p_nombre IS NULL OR LENGTH(TRIM(p_nombre)) = 0 THEN
            RAISE EXCEPTION 'fn_upsert_menu: p_nombre es obligatorio';
        END IF;
        v_nombre := TRIM(p_nombre);
        v_codigo := LEFT(UPPER(REGEXP_REPLACE(v_nombre, '\s+', '_', 'g')), 30);

        SELECT m.pk_tmenu INTO v_existente
          FROM academico_test.tmenu m
         WHERE UPPER(TRIM(m.codigo)) = v_codigo AND m.active = TRUE
         LIMIT 1;
        IF v_existente IS NOT NULL THEN
            RAISE EXCEPTION 'fn_upsert_menu: ya existe un TMENU activo con codigo=% (pk=%)', v_codigo, v_existente
                USING ERRCODE = '23505';
        END IF;

        -- orden = ultimo entre hermanos si no se especifica.
        v_orden_calc := COALESCE(
            p_orden,
            (SELECT COALESCE(MAX(m.orden), 0) + 1
               FROM academico_test.tmenu m
              WHERE m.fk_tmenu = p_id_padre AND m.active = TRUE)
        );

        INSERT INTO academico_test.tmenu (
            codigo, nombre, url, icono, visible, estado,
            fk_tmenu, fk_tplan, orden, created_by
        )
        VALUES (
            v_codigo, v_nombre, p_url, p_icono, v_visible_ch, 'A',
            p_id_padre, p_plan_id, v_orden_calc, TRIM(p_created_by)
        )
        RETURNING academico_test.tmenu.pk_tmenu, academico_test.tmenu.fk_tmenu,
                  academico_test.tmenu.nombre, academico_test.tmenu.url,
                  academico_test.tmenu.icono, academico_test.tmenu.orden,
                  (academico_test.tmenu.visible = 'S'), academico_test.tmenu.fk_tplan
          INTO pk_tmenu, pk_padre, nombre, path, icono, orden, visible, plan_id;

        status := 'created';
        RETURN NEXT;
        RETURN;
    END IF;

    -- =======================================================================
    -- MODO RAIZ (default) — POST /menus con idParent=null, +/- batch de
    -- submenus (p_submenus) para el flujo "Crear nuevo menu principal".
    -- =======================================================================
    IF p_nombre IS NULL OR LENGTH(TRIM(p_nombre)) = 0 THEN
        RAISE EXCEPTION 'fn_upsert_menu: p_nombre es obligatorio';
    END IF;
    v_nombre := TRIM(p_nombre);
    v_codigo := LEFT(UPPER(REGEXP_REPLACE(v_nombre, '\s+', '_', 'g')), 30);

    SELECT m.pk_tmenu INTO v_existente
      FROM academico_test.tmenu m
     WHERE UPPER(TRIM(m.codigo)) = v_codigo AND m.active = TRUE
     LIMIT 1;
    IF v_existente IS NOT NULL THEN
        RAISE EXCEPTION 'fn_upsert_menu: ya existe un TMENU activo con codigo=% (pk=%)', v_codigo, v_existente
            USING ERRCODE = '23505';
    END IF;

    v_orden_calc := COALESCE(
        p_orden,
        (SELECT COALESCE(MAX(m.orden), 0) + 1
           FROM academico_test.tmenu m
          WHERE m.fk_tmenu IS NULL AND m.active = TRUE)
    );

    INSERT INTO academico_test.tmenu (
        codigo, nombre, url, icono, visible, estado,
        fk_tmenu, fk_tplan, orden, created_by
    )
    VALUES (
        v_codigo, v_nombre, p_url, p_icono, v_visible_ch, 'A',
        NULL, p_plan_id, v_orden_calc, TRIM(p_created_by)
    )
    RETURNING academico_test.tmenu.pk_tmenu
      INTO v_padre_pk;

    pk_tmenu := v_padre_pk;
    pk_padre := NULL;
    nombre   := v_nombre;
    path     := p_url;
    icono    := p_icono;
    orden    := v_orden_calc;
    visible  := (v_visible_ch = 'S');
    plan_id  := p_plan_id;
    status   := 'created';
    RETURN NEXT;

    -- Batch de submenus (opcional). Cada elemento: {nombre, url, visible,
    -- orden, plan_id}. Errores per-row: no abortan el resto de la lista.
    IF p_submenus IS NOT NULL
       AND jsonb_typeof(p_submenus) = 'array'
       AND jsonb_array_length(p_submenus) > 0
    THEN
        FOR v_sub_nombre, v_sub_url, v_sub_visible_in, v_sub_orden, v_sub_plan_id IN
            SELECT
                (elem ->> 'nombre')::VARCHAR,
                (elem ->> 'url')::VARCHAR,
                COALESCE((elem ->> 'visible')::VARCHAR, 'S'),
                (elem ->> 'orden')::NUMERIC,
                (elem ->> 'plan_id')::BIGINT
              FROM jsonb_array_elements(p_submenus) elem
        LOOP
            pk_tmenu := NULL;
            pk_padre := v_padre_pk;
            nombre   := NULL;
            path     := NULL;
            icono    := NULL;
            orden    := NULL;
            visible  := NULL;
            plan_id  := NULL;
            status   := NULL;

            IF v_sub_nombre IS NULL OR LENGTH(TRIM(v_sub_nombre)) = 0 THEN
                status := 'submenu_error:nombre_requerido';
                RETURN NEXT;
                CONTINUE;
            END IF;
            nombre := TRIM(v_sub_nombre);

            IF v_sub_url IS NULL OR LENGTH(TRIM(v_sub_url)) = 0 THEN
                status := 'submenu_error:url_requerida';
                RETURN NEXT;
                CONTINUE;
            END IF;

            IF v_sub_visible_in IS NULL
               OR LENGTH(TRIM(v_sub_visible_in)) = 0
               OR UPPER(TRIM(v_sub_visible_in)) IN ('S', 'SI', 'TRUE', 'Y', '1')
            THEN
                v_sub_visible_in := 'S';
            ELSIF UPPER(TRIM(v_sub_visible_in)) IN ('N', 'NO', 'FALSE', '0') THEN
                v_sub_visible_in := 'N';
            ELSE
                status := format('submenu_error:visible_invalido:%s', v_sub_visible_in);
                RETURN NEXT;
                CONTINUE;
            END IF;

            IF v_sub_plan_id IS NOT NULL AND NOT EXISTS (
                SELECT 1 FROM academico_test.tlista_valor lv
                 WHERE lv.pk_lista_valor = v_sub_plan_id
                   AND lv.categoria      = 'PLAN'
                   AND lv.active         = TRUE
            ) THEN
                status := 'submenu_error:plan_id_invalido';
                RETURN NEXT;
                CONTINUE;
            END IF;

            v_sub_codigo := LEFT(UPPER(REGEXP_REPLACE(TRIM(v_sub_nombre), '\s+', '_', 'g')), 30);

            SELECT m.pk_tmenu INTO v_existente
              FROM academico_test.tmenu m
             WHERE UPPER(TRIM(m.codigo)) = v_sub_codigo AND m.active = TRUE
             LIMIT 1;
            IF v_existente IS NOT NULL THEN
                status  := 'submenu_error:codigo_duplicado';
                pk_tmenu := v_existente;
                RETURN NEXT;
                CONTINUE;
            END IF;

            v_sub_orden_calc := COALESCE(v_sub_orden,
                (SELECT COALESCE(MAX(m.orden), 0) + 1
                   FROM academico_test.tmenu m
                  WHERE m.fk_tmenu = v_padre_pk AND m.active = TRUE));

            INSERT INTO academico_test.tmenu (
                codigo, nombre, url, visible, estado,
                fk_tmenu, fk_tplan, orden, created_by
            )
            VALUES (
                v_sub_codigo, TRIM(v_sub_nombre), TRIM(v_sub_url),
                v_sub_visible_in, 'A',
                v_padre_pk, v_sub_plan_id, v_sub_orden_calc, TRIM(p_created_by)
            )
            RETURNING academico_test.tmenu.pk_tmenu, academico_test.tmenu.nombre,
                      academico_test.tmenu.url, academico_test.tmenu.orden,
                      (academico_test.tmenu.visible = 'S'), academico_test.tmenu.fk_tplan
              INTO pk_tmenu, nombre, path, orden, visible, plan_id;

            status := 'submenu_inserted';
            RETURN NEXT;
        END LOOP;
    END IF;
END;
$$;


-- ---------------------------------------------------------------------------
-- 9) fn_reorder_menus
--    PUT /menus/order. p_items = [{"id":.., "menuOrder":..}, ...] (mismas
--    claves que manda el front). Bulk UPDATE atomico de tmenu.orden.
--    Valida que todos los ids compartan el mismo padre antes de aplicar.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_reorder_menus(
    p_user_pk BIGINT,
    p_items   JSONB
)
RETURNS TABLE (
    pk_tmenu BIGINT,
    orden    NUMERIC
)
LANGUAGE plpgsql
VOLATILE
SET search_path = academico_test, public
AS $$
DECLARE
    v_ids BIGINT[];
BEGIN
    PERFORM academico_test.fn_assert_superadmin(p_user_pk);

    IF p_items IS NULL
       OR jsonb_typeof(p_items) <> 'array'
       OR jsonb_array_length(p_items) = 0
    THEN
        RAISE EXCEPTION 'fn_reorder_menus: p_items debe ser un array JSON no vacio'
            USING ERRCODE = '22023';
    END IF;

    SELECT array_agg((x ->> 'id')::BIGINT)
      INTO v_ids
      FROM jsonb_array_elements(p_items) x;

    IF EXISTS (
        SELECT 1
          FROM academico_test.tmenu m
         WHERE m.pk_tmenu = ANY(v_ids)
        HAVING COUNT(DISTINCT COALESCE(m.fk_tmenu, -1)) > 1
    ) THEN
        RAISE EXCEPTION 'fn_reorder_menus: todos los items deben ser hermanos (mismo padre)'
            USING ERRCODE = '22023';
    END IF;

    IF (SELECT COUNT(*) FROM academico_test.tmenu m
         WHERE m.pk_tmenu = ANY(v_ids) AND m.active = TRUE) <> array_length(v_ids, 1)
    THEN
        RAISE EXCEPTION 'fn_reorder_menus: alguno de los ids no existe o no esta activo'
            USING ERRCODE = '22023';
    END IF;

    RETURN QUERY
    UPDATE academico_test.tmenu m
       SET orden       = (x ->> 'menuOrder')::NUMERIC,
           modified_by = CURRENT_USER,
           modified_at = CURRENT_TIMESTAMP
      FROM jsonb_array_elements(p_items) x
     WHERE m.pk_tmenu = (x ->> 'id')::BIGINT
    RETURNING m.pk_tmenu, m.orden;
END;
$$;


-- ---------------------------------------------------------------------------
-- 10) fn_delete_menu
--     Pensada para PUT /menus/{id}/eliminar (el catalogo QUERY no admite
--     HTTP_METHOD=DELETE). Soft-delete en cascada: el menu, sus hijos
--     directos, y las filas de trol_menu de todos ellos.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_delete_menu(
    p_user_pk  BIGINT,
    p_pk_tmenu BIGINT
)
RETURNS TABLE (
    pk_tmenu    BIGINT,
    was_deleted BOOLEAN
)
LANGUAGE plpgsql
VOLATILE
SET search_path = academico_test, public
AS $$
DECLARE
    v_rows INTEGER;
BEGIN
    PERFORM academico_test.fn_assert_superadmin(p_user_pk);

    IF p_pk_tmenu IS NULL THEN
        RAISE EXCEPTION 'fn_delete_menu: p_pk_tmenu es obligatorio'
            USING ERRCODE = '22023';
    END IF;

    -- 1. Desactivar las asignaciones (trol_menu) del menu y de sus hijos.
    UPDATE academico_test.trol_menu tm
       SET active      = FALSE,
           modified_by = CURRENT_USER,
           modified_at = CURRENT_TIMESTAMP
     WHERE tm.active = TRUE
       AND tm.fk_tmenu IN (
           SELECT m.pk_tmenu FROM academico_test.tmenu m
            WHERE m.pk_tmenu = p_pk_tmenu OR m.fk_tmenu = p_pk_tmenu
       );

    -- 2. Desactivar los hijos directos.
    UPDATE academico_test.tmenu m
       SET active      = FALSE,
           modified_by = CURRENT_USER,
           modified_at = CURRENT_TIMESTAMP
     WHERE m.fk_tmenu = p_pk_tmenu
       AND m.active   = TRUE;

    -- 3. Desactivar el menu en si.
    UPDATE academico_test.tmenu m
       SET active      = FALSE,
           modified_by = CURRENT_USER,
           modified_at = CURRENT_TIMESTAMP
     WHERE m.pk_tmenu = p_pk_tmenu
       AND m.active   = TRUE;

    GET DIAGNOSTICS v_rows = ROW_COUNT;

    pk_tmenu    := p_pk_tmenu;
    was_deleted := (v_rows > 0);
    RETURN NEXT;
END;
$$;


-- ---------------------------------------------------------------------------
-- 11) fn_list_plans_from_value
--     GET /plans -> PlanDto[]. Planes activos de tlista_valor CATEGORIA='PLAN'.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_list_plans_from_value(
    p_user_pk BIGINT
)
RETURNS TABLE (
    id     BIGINT,
    name   VARCHAR,
    valor  VARCHAR,
    activo BOOLEAN
)
LANGUAGE plpgsql
STABLE
SET search_path = academico_test, public
AS $$
BEGIN
    PERFORM academico_test.fn_assert_superadmin(p_user_pk);

    RETURN QUERY
    SELECT lv.pk_lista_valor, lv.nombre, lv.valor, lv.active
      FROM academico_test.tlista_valor lv
     WHERE lv.categoria = 'PLAN'
       AND lv.active    = TRUE
     ORDER BY lv.nombre;
END;
$$;


-- ---------------------------------------------------------------------------
-- 12) fn_create_plan_from_value
--     POST /plans -> PlanDto. p_created_by se deriva de CURRENT_USER.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_create_plan_from_value(
    p_user_pk BIGINT,
    p_nombre  VARCHAR
)
RETURNS TABLE (
    id     BIGINT,
    name   VARCHAR,
    valor  VARCHAR,
    status VARCHAR
)
LANGUAGE plpgsql
VOLATILE
SET search_path = academico_test, public
AS $$
DECLARE
    v_nombre    VARCHAR;
    v_valor     VARCHAR;
    v_existente BIGINT;
BEGIN
    PERFORM academico_test.fn_assert_superadmin(p_user_pk);

    IF p_nombre IS NULL OR LENGTH(TRIM(p_nombre)) = 0 THEN
        RAISE EXCEPTION 'fn_create_plan_from_value: p_nombre es obligatorio';
    END IF;
    v_nombre := TRIM(p_nombre);
    v_valor  := LEFT(UPPER(REGEXP_REPLACE(v_nombre, '\s+', '_', 'g')), 30);

    SELECT lv.pk_lista_valor INTO v_existente
      FROM academico_test.tlista_valor lv
     WHERE lv.categoria = 'PLAN'
       AND UPPER(TRIM(lv.valor)) = v_valor
       AND lv.active = TRUE
     LIMIT 1;
    IF v_existente IS NOT NULL THEN
        RAISE EXCEPTION 'fn_create_plan_from_value: ya existe un plan activo con valor=% (pk=%)', v_valor, v_existente
            USING ERRCODE = '23505'; -- unique_violation -> 409 Conflict
    END IF;

    INSERT INTO academico_test.tlista_valor (categoria, nombre, valor, created_by)
    VALUES ('PLAN', v_nombre, v_valor, CURRENT_USER)
    RETURNING academico_test.tlista_valor.pk_lista_valor,
              academico_test.tlista_valor.nombre,
              academico_test.tlista_valor.valor
      INTO id, name, valor;

    status := 'inserted';
    RETURN NEXT;
END;
$$;


-- ---------------------------------------------------------------------------
-- 13) fn_delete_plan_from_value
--     Soft-delete por nombre. Sin endpoint documentado todavia en
--     roles-permisos-dtos.md; se conserva como utilidad general.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_delete_plan_from_value(
    p_user_pk BIGINT,
    p_nombre  VARCHAR
)
RETURNS TABLE (
    id          BIGINT,
    name        VARCHAR,
    was_deleted BOOLEAN
)
LANGUAGE plpgsql
VOLATILE
SET search_path = academico_test, public
AS $$
DECLARE
    v_valor VARCHAR;
    v_pk    BIGINT;
    v_rows  INTEGER;
BEGIN
    PERFORM academico_test.fn_assert_superadmin(p_user_pk);

    IF p_nombre IS NULL OR LENGTH(TRIM(p_nombre)) = 0 THEN
        RAISE EXCEPTION 'fn_delete_plan_from_value: p_nombre es obligatorio';
    END IF;

    v_valor := UPPER(REGEXP_REPLACE(TRIM(p_nombre), '\s+', '_', 'g'));

    SELECT lv.pk_lista_valor INTO v_pk
      FROM academico_test.tlista_valor lv
     WHERE lv.categoria = 'PLAN'
       AND UPPER(TRIM(lv.valor)) = v_valor
       AND lv.active = TRUE
     LIMIT 1;

    IF v_pk IS NOT NULL THEN
        UPDATE academico_test.tlista_valor lv
           SET active      = FALSE,
               modified_by = CURRENT_USER,
               modified_at = CURRENT_TIMESTAMP
         WHERE lv.pk_lista_valor = v_pk;

        GET DIAGNOSTICS v_rows = ROW_COUNT;
        was_deleted := (v_rows > 0);
    ELSE
        was_deleted := FALSE;
    END IF;

    id          := v_pk;
    name        := TRIM(p_nombre);
    RETURN NEXT;
END;
$$;


-- ---------------------------------------------------------------------------
-- Seed inicial: Preescolar, Basico y Medio en CATEGORIA='PLAN'.
-- WHERE NOT EXISTS sobre la UNIQUE (CATEGORIA, VALOR) — re-aplicable.
-- ---------------------------------------------------------------------------
INSERT INTO academico_test.tlista_valor (categoria, nombre, valor, created_by)
SELECT v.categoria, v.nombre, v.valor, 'V59_seed'
  FROM (VALUES
    ('PLAN'::VARCHAR, 'Preescolar'::VARCHAR, 'PREESCOLAR'::VARCHAR),
    ('PLAN'::VARCHAR, 'Basico'::VARCHAR,     'BASICO'::VARCHAR),
    ('PLAN'::VARCHAR, 'Medio'::VARCHAR,      'MEDIO'::VARCHAR)
  ) AS v(categoria, nombre, valor)
 WHERE NOT EXISTS (
       SELECT 1
         FROM academico_test.tlista_valor lv
        WHERE lv.categoria = 'PLAN'
          AND lv.valor     = v.valor
          AND lv.active    = TRUE
       );


-- ===========================================================================
-- Seed: arbol de menu por defecto (4 grupos + sus submenus), conectado a
-- DOS roles distintos via DOS mecanismos distintos, porque son dos
-- universos de roles que no se pisan:
--
--   * CEVAL-SUPER_ADMINISTRADOR -> academico_test.tmenu + trol_menu.
--     trol_menu solo puede referenciar filas de academico_test.trol, y el
--     trigger de este archivo SIEMPRE nombra el rol resultante como
--     'CEVAL-<codigo>' — asi que el UNICO rol academico que puede recibir
--     este menu por esta via es el que corresponde a
--     academico_test.trol.codigo='SUPER_ADMINISTRADOR' (que V36 importa
--     como public.role 'CEVAL-SUPER_ADMINISTRADOR').
--
--   * SSO-ADMIN -> public.route + public.role_route. 'SSO-ADMIN' es un rol
--     de la app SSO (V6/V10), sin fila equivalente en academico_test.trol
--     y sin el prefijo CEVAL- — trol_menu estructuralmentente no puede
--     representarlo. public.route es el catalogo de navegacion generico
--     que ya consume GET /sso-admin/myMenu?app=, y public.role_route es su
--     join de autorizacion por rol — el mecanismo correcto para conectar
--     un arbol de menu a un rol no-academico como SSO-ADMIN.
--
-- Los DOS catalogos (tmenu y route) se siembran con la MISMA estructura
-- (mismos nombres/urls/orden) para que ambos roles vean el mismo menu,
-- aunque cada uno vive en su propia tabla — no hay una unica fuente de
-- verdad compartida entre ambos sistemas hoy; sincronizarlos es manual
-- (este seed) hasta que se decida unificarlos.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- (A) academico_test.tmenu — grupos (padres, fk_tmenu=NULL).
--     CODIGO sigue la misma convencion canonica que fn_upsert_menu deriva
--     (UPPER + espacios->'_'), para que si alguien edita estos menus desde
--     la UI mas adelante, el codigo ya calce con lo que la funcion
--     generaria. URL del grupo = URL de su primer hijo (convencion de
--     roles-permisos-dtos.md: "un grupo no tiene ruta propia").
--     WHERE NOT EXISTS sobre CODIGO activo — re-aplicable.
-- ---------------------------------------------------------------------------
INSERT INTO academico_test.tmenu (codigo, nombre, icono, visible, estado, url, fk_tmenu, orden, created_by)
SELECT v.codigo, v.nombre, v.icono, 'S', 'A', v.url, NULL, v.orden, 'V59_seed'
  FROM (VALUES
    ('COBERTURA_EDUCATIVA',       'Cobertura Educativa',       'BookOpen-Icon',  '/cobertura-educativa/pre-matricula',           1::NUMERIC),
    ('ADMINISTRACION',            'Administración',            'Gear-Icon',      '/administracion/registro-actividad',            2::NUMERIC),
    ('ESTABLECIMIENTO_EDUCATIVO', 'Establecimiento Educativo', 'Buildings-Icon', '/establecimiento-educativo/establecimiento',    3::NUMERIC),
    ('USUARIOS',                  'Usuarios',                  'Users-Icon',     '/usuarios/equipo',                              4::NUMERIC)
  ) AS v(codigo, nombre, icono, url, orden)
 WHERE NOT EXISTS (
       SELECT 1 FROM academico_test.tmenu m
        WHERE m.codigo = v.codigo AND m.active = TRUE
       );

-- ---------------------------------------------------------------------------
-- (B) academico_test.tmenu — submenus (hijos), unidos a su padre por
--     CODIGO. Icono NULL: el icono visible es el del grupo (mismo criterio
--     que fn_upsert_menu documenta para submenus creados desde la UI).
--     WHERE NOT EXISTS sobre CODIGO activo — re-aplicable.
-- ---------------------------------------------------------------------------
INSERT INTO academico_test.tmenu (codigo, nombre, url, visible, estado, fk_tmenu, orden, created_by)
SELECT v.codigo, v.nombre, v.url, 'S', 'A', padre.pk_tmenu, v.orden, 'V59_seed'
  FROM (VALUES
    ('PRE_MATRICULA',       'Pre-Matrícula',                  '/cobertura-educativa/pre-matricula',             'COBERTURA_EDUCATIVA',       1::NUMERIC),
    ('INSCRITOS',           'Inscritos',                      '/cobertura-educativa/inscritos',                 'COBERTURA_EDUCATIVA',       2::NUMERIC),
    ('MATRICULA',           'Matrícula',                      '/cobertura-educativa/matricula',                 'COBERTURA_EDUCATIVA',       3::NUMERIC),
    ('REGISTRO_ACTIVIDAD',  'Registro de actividad',          '/administracion/registro-actividad',             'ADMINISTRACION',            1::NUMERIC),
    ('CONFIG_ROLES_MENUS',  'Configuración de roles y menús', '/administracion/roles-menus',                    'ADMINISTRACION',            2::NUMERIC),
    ('ESTABLECIMIENTO',     'Establecimiento',                '/establecimiento-educativo/establecimiento',     'ESTABLECIMIENTO_EDUCATIVO', 1::NUMERIC),
    ('SEDES_EDUCATIVAS',    'Sedes Educativas',               '/establecimiento-educativo/sedes',               'ESTABLECIMIENTO_EDUCATIVO', 2::NUMERIC),
    ('FUNCIONARIOS',        'Funcionarios',                   '/establecimiento-educativo/funcionarios',        'ESTABLECIMIENTO_EDUCATIVO', 3::NUMERIC),
    ('PERIODOS_ACADEMICOS', 'Periodos Académicos',            '/establecimiento-educativo/periodos-academicos', 'ESTABLECIMIENTO_EDUCATIVO', 4::NUMERIC),
    ('EQUIPO',              'Equipo',                         '/usuarios/equipo',                               'USUARIOS',                  1::NUMERIC),
    ('ROLES',               'Roles',                          '/usuarios/roles',                                'USUARIOS',                  2::NUMERIC)
  ) AS v(codigo, nombre, url, padre_codigo, orden)
  JOIN academico_test.tmenu padre
    ON padre.codigo = v.padre_codigo
   AND padre.active = TRUE
   AND padre.fk_tmenu IS NULL
 WHERE NOT EXISTS (
       SELECT 1 FROM academico_test.tmenu m
        WHERE m.codigo = v.codigo AND m.active = TRUE
       );

-- ---------------------------------------------------------------------------
-- (C) academico_test.trol_menu — conecta TODO el arbol (A + B) al rol
--     CEVAL-SUPER_ADMINISTRADOR (academico_test.trol.codigo=
--     'SUPER_ADMINISTRADOR'). orden_rol se calcula con ROW_NUMBER() sobre
--     el mismo criterio de orden que usa fn_list_available_menus (padre
--     agrupando a sus hijos, padre antes que hijos, luego ORDEN).
--     WHERE NOT EXISTS sobre (fk_trol, fk_tmenu) — re-aplicable. No falla
--     si el TROL SUPER_ADMINISTRADOR no existe (CROSS JOIN + WHERE
--     simplemente no producen filas).
-- ---------------------------------------------------------------------------
INSERT INTO academico_test.trol_menu (fk_trol, fk_tmenu, orden_rol, active, created_by)
SELECT t.pk_trol,
       m.pk_tmenu,
       ROW_NUMBER() OVER (
           ORDER BY COALESCE(m.fk_tmenu, m.pk_tmenu),
                    (m.fk_tmenu IS NULL) DESC,
                    m.orden
       ),
       TRUE,
       'V59_seed'
  FROM academico_test.tmenu m
 CROSS JOIN academico_test.trol t
 WHERE t.codigo = 'SUPER_ADMINISTRADOR'
   AND t.active = TRUE
   AND m.active = TRUE
   AND m.codigo IN (
       'COBERTURA_EDUCATIVA', 'ADMINISTRACION', 'ESTABLECIMIENTO_EDUCATIVO', 'USUARIOS',
       'PRE_MATRICULA', 'INSCRITOS', 'MATRICULA',
       'REGISTRO_ACTIVIDAD', 'CONFIG_ROLES_MENUS',
       'ESTABLECIMIENTO', 'SEDES_EDUCATIVAS', 'FUNCIONARIOS', 'PERIODOS_ACADEMICOS',
       'EQUIPO', 'ROLES'
   )
   AND NOT EXISTS (
       SELECT 1 FROM academico_test.trol_menu tm
        WHERE tm.fk_trol = t.pk_trol AND tm.fk_tmenu = m.pk_tmenu
       );

-- ---------------------------------------------------------------------------
-- (D) public.route — el mismo arbol, para el rol SSO-ADMIN. Sin CODIGO
--     propio (ROUTE no lo modela — V3), asi que la idempotencia se hace
--     por NAME dentro del mismo nivel (idparent). Grupos primero.
-- ---------------------------------------------------------------------------
INSERT INTO public.route (name, icon, path, menuorder, type, idparent)
SELECT v.name, v.icon, v.path, v.orden, 'GROUP', NULL
  FROM (VALUES
    ('Cobertura Educativa',       'BookOpen-Icon',  '/cobertura-educativa/pre-matricula',         1),
    ('Administración',            'Gear-Icon',      '/administracion/registro-actividad',          2),
    ('Establecimiento Educativo', 'Buildings-Icon', '/establecimiento-educativo/establecimiento',  3),
    ('Usuarios',                  'Users-Icon',     '/usuarios/equipo',                             4)
  ) AS v(name, icon, path, orden)
 WHERE NOT EXISTS (
       SELECT 1 FROM public.route r
        WHERE r.name = v.name AND r.idparent IS NULL
       );

-- ---------------------------------------------------------------------------
-- (E) public.route — submenus, unidos a su padre por NAME (idparent IS NULL).
-- ---------------------------------------------------------------------------
INSERT INTO public.route (name, path, menuorder, type, idparent)
SELECT v.name, v.path, v.orden, 'ITEM', padre.id_route
  FROM (VALUES
    ('Pre-Matrícula',                  '/cobertura-educativa/pre-matricula',             'Cobertura Educativa',       1),
    ('Inscritos',                      '/cobertura-educativa/inscritos',                 'Cobertura Educativa',       2),
    ('Matrícula',                      '/cobertura-educativa/matricula',                 'Cobertura Educativa',       3),
    ('Registro de actividad',          '/administracion/registro-actividad',             'Administración',           1),
    ('Configuración de roles y menús', '/administracion/roles-menus',                    'Administración',           2),
    ('Establecimiento',                '/establecimiento-educativo/establecimiento',     'Establecimiento Educativo',1),
    ('Sedes Educativas',               '/establecimiento-educativo/sedes',               'Establecimiento Educativo',2),
    ('Funcionarios',                   '/establecimiento-educativo/funcionarios',        'Establecimiento Educativo',3),
    ('Periodos Académicos',            '/establecimiento-educativo/periodos-academicos', 'Establecimiento Educativo',4),
    ('Equipo',                         '/usuarios/equipo',                               'Usuarios',                 1),
    ('Roles',                          '/usuarios/roles',                                'Usuarios',                 2)
  ) AS v(name, path, padre_name, orden)
  JOIN public.route padre
    ON padre.name = v.padre_name AND padre.idparent IS NULL
 WHERE NOT EXISTS (
       SELECT 1 FROM public.route r
        WHERE r.name = v.name AND r.idparent = padre.id_route
       );

-- ---------------------------------------------------------------------------
-- (F) public.role_route — conecta TODO el arbol (D + E) al rol SSO-ADMIN.
--     ON CONFLICT sobre la PK compuesta (route_id, role_id) — re-aplicable.
--     No falla si SSO-ADMIN no existe (CROSS JOIN + WHERE no produce filas).
-- ---------------------------------------------------------------------------
INSERT INTO public.role_route (route_id, role_id)
SELECT r.id_route, ro.id_role
  FROM public.route r
 CROSS JOIN public.role ro
 WHERE ro.name = 'SSO-ADMIN'
   AND r.name IN (
       'Cobertura Educativa', 'Administración', 'Establecimiento Educativo', 'Usuarios',
       'Pre-Matrícula', 'Inscritos', 'Matrícula',
       'Registro de actividad', 'Configuración de roles y menús',
       'Establecimiento', 'Sedes Educativas', 'Funcionarios', 'Periodos Académicos',
       'Equipo', 'Roles'
   )
 ON CONFLICT (route_id, role_id) DO NOTHING;


-- ---------------------------------------------------------------------------
-- Comentarios de documentacion
-- ---------------------------------------------------------------------------
COMMENT ON FUNCTION academico_test.fn_assert_superadmin(BIGINT) IS
    'Helper interno de V59. Unico punto donde vive la regla "tener el rol CEVAL-SUPER_ADMINISTRADOR para ejecutar las funciones administrativas". Validacion por JOIN entre public.role_users (user_id=p_user_pk) y public.role (name=''CEVAL-SUPER_ADMINISTRADOR''). Cualquier pk sin ese rol (NULL incluida) dispara RAISE EXCEPTION con ERRCODE=''42501'' (insufficient_privilege -> 403).';

COMMENT ON FUNCTION academico_test.fn_list_roles(BIGINT) IS
    'GET /roles -> RoleDto[]. Lista (id, name) de academico_test.trol activos. REQUIERE p_user_pk (fn_assert_superadmin). Reemplaza a fn_list_trol_names_for_superadmin (solo devolvia el nombre).';

COMMENT ON FUNCTION academico_test.fn_add_trol(BIGINT, VARCHAR, VARCHAR, VARCHAR) IS
    'POST /roles -> RoleDto. Inserta un rol en academico_test.trol. p_nombre en lowercase con espacios (p. ej. "jefe de area"); deriva CODIGO canonico (UPPER + espacios->"_", LEFT 30). p_estado OPCIONAL DEFAULT ''A''. Duplicado de codigo activo o de nombre (U_TROL_1) -> RAISE USING ERRCODE=''23505'' (409 Conflict, igual que el contrato documenta). Retorna (id, name). El trigger AFTER INSERT materializa public.role (CEVAL-<codigo>).';

COMMENT ON FUNCTION academico_test.fn_sync_trol_to_public_role() IS
    'Trigger AFTER INSERT ON trol: inserta el homologo en public.role con name = CEVAL-<codigo> y description = trol.nombre. Idempotente via ON CONFLICT (name) DO NOTHING.';

COMMENT ON TRIGGER trg_sync_trol_to_public_role ON academico_test.trol IS
    'Dispara fn_sync_trol_to_public_role despues de cada INSERT en trol para mantener public.role sincronizado con el catalogo academico bajo el prefijo CEVAL-.';

COMMENT ON FUNCTION academico_test.fn_list_menu_possibilities_for_rol(BIGINT, BIGINT) IS
    'Devuelve TODAS las combinaciones padre -> submenu (2 niveles), con ya_asignado + orden_rol (de trol_menu) y plan_id (tmenu.fk_tplan del submenu). Pensada para la grilla "Submenus" del dialog "Agregar menu". REQUIERE p_user_pk (fn_assert_superadmin). El rol debe existir y estar activo.';

COMMENT ON FUNCTION academico_test.fn_associate_menus_to_rol(BIGINT, BIGINT, BIGINT[], VARCHAR, BOOLEAN) IS
    'Vincula TMENU a un rol (trol_menu). p_full_replace=FALSE (default): UPSERT incremental, no toca lo demas. p_full_replace=TRUE: semantica de PUT /roles/{roleId}/menus — reemplazo completo (desactiva lo que no este en la lista, puede venir vacia), valida la invariante de jerarquia (submenu implica su padre) y persiste orden_rol = posicion en el array. Ya NO acepta plan (se mudo a tmenu.fk_tplan via fn_upsert_menu). Devuelve (pk_tmenu, pk_trol_menu, orden_rol, status).';

COMMENT ON FUNCTION academico_test.fn_dissociate_menus_from_rol(BIGINT, BIGINT, BIGINT[]) IS
    'Desvincula (soft-delete) TMENU puntuales de un rol sin afectar el resto. Utilidad de proposito general; PUT /roles/{roleId}/menus usa fn_associate_menus_to_rol(p_full_replace=TRUE) en su lugar.';

COMMENT ON FUNCTION academico_test.fn_list_available_menus(BIGINT) IS
    'GET /menus -> MenuDto[]. Arbol completo de tmenu (sin filtro por rol), visible como BOOLEAN, type derivado (GROUP/ITEM de fk_tmenu IS NULL), plan_id de tmenu.fk_tplan. Shape listo para MenuDto. REQUIERE p_user_pk (fn_assert_superadmin).';

COMMENT ON FUNCTION academico_test.fn_upsert_menu(BIGINT, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, NUMERIC, BIGINT, BIGINT, BIGINT, JSONB) IS
    'Reemplaza a fn_create_parent_menu_with_submenus. Tres modos: EDITAR (p_pk_tmenu_editar IS NOT NULL -> PATCH /menus/{id}, UPDATE de una fila); HIJO BAJO PADRE EXISTENTE (p_id_padre IS NOT NULL -> POST /menus con idParent, INSERT de un submenu); RAIZ (default -> POST /menus con idParent=null, INSERT de un menu raiz, +/- batch de p_submenus JSONB para el flujo historico "Crear nuevo menu principal"). p_plan_id (o "plan_id" por submenu) se valida contra tlista_valor CATEGORIA=''PLAN'' y se persiste en tmenu.fk_tplan. Duplicado de codigo -> ERRCODE=''23505'' (409). REQUIERE p_user_pk (fn_assert_superadmin).';

COMMENT ON FUNCTION academico_test.fn_reorder_menus(BIGINT, JSONB) IS
    'PUT /menus/order. p_items=[{"id":..,"menuOrder":..}] (mismas claves del front). Bulk UPDATE atomico de tmenu.orden; valida que todos los ids sean hermanos (mismo fk_tmenu) y existan/esten activos antes de aplicar. REQUIERE p_user_pk (fn_assert_superadmin).';

COMMENT ON FUNCTION academico_test.fn_delete_menu(BIGINT, BIGINT) IS
    'Pensada para PUT /menus/{id}/eliminar (el catalogo QUERY no admite HTTP_METHOD=DELETE). Soft-delete en cascada: el menu, sus hijos directos, y las filas de trol_menu de todos ellos. REQUIERE p_user_pk (fn_assert_superadmin).';

COMMENT ON FUNCTION academico_test.fn_list_plans_from_value(BIGINT) IS
    'GET /plans -> PlanDto[]. Planes activos de tlista_valor CATEGORIA=''PLAN''. REQUIERE p_user_pk (fn_assert_superadmin).';

COMMENT ON FUNCTION academico_test.fn_create_plan_from_value(BIGINT, VARCHAR) IS
    'POST /plans -> PlanDto. p_created_by se deriva de CURRENT_USER. VALOR canonico derivado del nombre. Duplicado -> RAISE USING ERRCODE=''23505'' (409 Conflict). REQUIERE p_user_pk (fn_assert_superadmin).';

COMMENT ON FUNCTION academico_test.fn_delete_plan_from_value(BIGINT, VARCHAR) IS
    'Soft-delete por nombre sobre tlista_valor CATEGORIA=''PLAN''. Sin endpoint documentado todavia; utilidad general. REQUIERE p_user_pk (fn_assert_superadmin).';
