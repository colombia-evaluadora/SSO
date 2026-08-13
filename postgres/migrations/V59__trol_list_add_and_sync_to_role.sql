-- ===========================================================================
-- V59 — Gestion administrativa de TROL (academico_test) y sus menus asociados.
--
-- Diez funciones + un trigger + un helper interno, todos enfocados en la
-- tabla academico_test.trol (catalogo de roles academicos), su reflejo en
-- public.role con el prefijo CEVAL-, la asignacion/creacion de menus/
-- submenus via academico_test.tmenu y academico_test.trol_menu, y la
-- gestion de planes academicos via academico_test.tlista_valor
-- (seccion CATEGORIA='PLAN').
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
--   H. fn_assert_superadmin(p_user_pk BIGINT) -> VOID
--      Helper interno. Unico punto donde vive la regla "tener el rol
--      CEVAL-SUPER_ADMINISTRADOR"; todas las demas funciones lo invocan
--      con PERFORM al inicio del BEGIN. El seed insert justo debajo
--      garantiza que el rol exista incluso en entornos donde V36 no lo
--      haya importado desde academico_test.trol.
--
--   1. fn_list_trol_names_for_superadmin(p_user_pk BIGINT)
--      Lista UNICAMENTE los nombres (NOMBRE) de los roles definidos en
--      academico_test.trol. Pensada para alimentar el dropdown "Rol" de
--      la UI administrativa.
--
--   2. fn_add_trol(p_user_pk BIGINT, p_nombre VARCHAR, p_created_by
--                   VARCHAR, p_estado VARCHAR) + trigger
--      Inserta un nuevo rol en academico_test.trol con validaciones
--      explicitas:
--        * p_nombre obligatorio (input del usuario en lowercase y con
--          espacios, p. ej. "jefe de area"). La funcion lo transforma
--          internamente al CODIGO canonico: UPPER + reemplazo de cualquier
--          secuencia de espacios por '_' ("jefe de area" -> "JEFE_DE_AREA").
--        * p_estado OPCIONAL. Si llega NULL o vacio, el registro se crea
--          como ACTIVO (estado_ai = 'A'). Si llega un valor, debe estar en
--          {A, I, ACTIVO, INACTIVO} y se normaliza a 'A'/'I'.
--        * p_created_by obligatorio.
--        * no duplica un CODIGO activo (case-insensitive) ni un NOMBRE
--          ya existente (U_TROL_1 UNIQUE(NOMBRE)).
--      Devuelve una fila con el PK_TROL del nuevo registro y el NOMBRE
--      almacenado (recortado).
--      El trigger AFTER INSERT ON trol inserta automaticamente su homologo
--      en public.role con nombre = 'CEVAL-' || NEW.CODIGO y descripcion =
--      NEW.NOMBRE. Idempotente via ON CONFLICT (name) DO NOTHING. No
--      requiere p_user_pk porque ya viene protegido por fn_add_trol.
--
--   3. fn_list_menu_possibilities_for_rol(p_user_pk BIGINT, p_pk_trol
--                                         BIGINT)
--      Devuelve TODAS las posibilidades padre -> submenu del catalogo
--      academico_test.tmenu, marcadas con un flag ya_asignado cuando la
--      combinacion (rol, submenu) ya existe en academico_test.trol_menu
--      (la UI usa este flag para pintar los submenus como "ya activados"
--      vs "disponibles"). Pensada para alimentar la pantalla "Agregar menu"
--      de sso-admin (selector de Rol + selector de Menu padre + grilla de
--      Submenus con columnas Visible / URL). Solo contempla 2 niveles de
--      jerarquia (padre -> hijo); menus con FK_TMENU no nulo y ni nulo son
--      excluidos como padres y los nietos no se devuelven.
--
--   4. fn_associate_menus_to_rol(p_user_pk BIGINT, p_pk_trol BIGINT,
--                                p_pk_tmenus BIGINT[], p_created_by VARCHAR,
--                                p_pk_tplan BIGINT DEFAULT NULL)
--      Vincula uno o varios TMENU a un rol creando filas en
--      academico_test.trol_menu. Pensada para el boton "Guardar" de la
--      pantalla "Agregar menu": la UI envia los pks de los submenus que
--      el admin acaba de activar y la funcion los materializa.
--      Comportamiento UPSERT sobre la UNIQUE (FK_TROL, FK_TMENU):
--        * si no existe la combinacion, INSERT (active=TRUE, created_by,
--          fk_tplan = p_pk_tplan).
--        * si existe pero active=FALSE, REACTIVA (active=TRUE, modified_by,
--          fk_tplan = EXCLUDED.fk_tplan).
--        * si ya esta activa, no-op.
--      p_pk_tplan es OPCIONAL (default NULL); cuando la UI envia el plan
--      elegido en el dropdown de cada submenu, se valida que pertenezca a
--      CATEGORIA='PLAN' de tlista_valor y se persiste en la columna
--      trol_menu.fk_tplan (FK nullable a tlista_valor). EXCLUDED.fk_tplan
--      permite limpiar una asignacion previa enviando NULL.
--      Devuelve una fila por cada p_pk_tmenu: pk_tmenu, pk_trol_menu y
--      status ('inserted' / 'reactivated' / 'menu_not_found_or_inactive').
--      Si el rol no existe o no esta activo, la funcion falla con EXCEPTION.
--
--   5. fn_dissociate_menus_from_rol(p_user_pk BIGINT, p_pk_trol BIGINT,
--                                   p_pk_tmenus BIGINT[])
--      Desvincula uno o varios TMENU de un rol. Pensada para el caso
--      opuesto: la UI envia los pks de los submenus que el admin acaba de
--      desactivar y la funcion marca cada fila como active=FALSE
--      (soft-delete para preservar audit: created_by/created_at se conservan,
--      modified_by/modified_at se actualizan con la operacion, fk_tplan se
--      preserva para reactivacion futura via fn_associate_menus_to_rol).
--      Devuelve una fila por cada p_pk_tmenu: pk_tmenu y was_deleted
--      (true solo si habia una asociacion activa que se acaba de desactivar).
--
--   6. fn_list_available_menus(p_user_pk BIGINT)
--      Devuelve el ARBOL completo de academico_test.tmenu (parents +
--      submenus), ordenado jerarquicamente (parents first, submenus
--      agrupados bajo su padre por pk_padre, luego por orden y nombre).
--      Pensada para alimentar el panel "Menus disponibles" del
--      TransferList de sso-admin: el admin ve la lista completa del
--      catalogo, mueve items al panel "Menus asignados" via
--      fn_associate_menus_to_rol, y los devuelve con
--      fn_dissociate_menus_from_rol. Sin filtro por rol: el UI es
--      responsable de cruzar con trol_menu (o usar ya_asignado de la
--      funcion 3) para distinguir disponibles vs asignados. Solo incluye
--      filas activas (estado='A' AND active=TRUE).
--
--   7. fn_create_parent_menu_with_submenus(p_user_pk BIGINT,
--         p_padre_nombre VARCHAR, p_padre_created_by VARCHAR,
--         p_padre_icono VARCHAR, p_padre_visible VARCHAR,
--         p_padre_orden NUMERIC, p_padre_url VARCHAR, p_submenus JSONB)
--      Crea un menu padre en academico_test.tmenu (fk_tmenu=NULL) junto
--      con N submenus en la misma operacion. Pensada para el dialog
--      "Agregar menu" de sso-admin cuando el usuario elige "Crear nuevo
--      menu principal" en el dropdown "Menu padre": completa los campos
--      del padre y agrega filas en la grilla "Submenus" antes de pulsar
--      Guardar.
--      Reutiliza la logica de derivacion de CODIGO de fn_add_trol
--      (UPPER + colapso de espacios a '_'). Valida duplicados de CODIGO
--      y NOMBRE activos antes de cada INSERT. La entrada de submenus
--      viaja como JSONB array; cada elemento puede traer {nombre, url,
--      visible, orden} y se procesa per-row (errores no abortan la lista).
--      Devuelve una fila por cada TMENU creado:
--        * la PRIMERA fila es el padre (pk_submenu=NULL, status
--          'parent_created').
--        * las filas siguientes son los submenus (pk_padre = pk del padre,
--          status 'submenu_inserted' o 'submenu_error:<motivo>').
--
--   8. fn_list_plans_from_value(p_user_pk BIGINT)
--      Lista los planes academicos activos definidos en la seccion
--      CATEGORIA='PLAN' de academico_test.tlista_valor. Pensada para
--      alimentar el dropdown "Plan" de la pantalla "Agregar menu" de
--      sso-admin (junto a Preescolar / Basico / Medio seedeados abajo).
--      Devuelve pk_lista_valor, nombre, valor y active.
--
--   9. fn_create_plan_from_value(p_user_pk BIGINT, p_nombre VARCHAR)
--      Inserta un nuevo plan en la seccion CATEGORIA='PLAN' de
--      academico_test.tlista_valor. p_created_by se deriva de CURRENT_USER
--      (la sesion que ejecuta la operacion). El VALOR se genera
--      canonicamente a partir del nombre (UPPER + reemplazo de espacios
--      por '_' — mismo patron que fn_add_trol / fn_create_parent_menu_with_submenus).
--      Falla con EXCEPTION si el VALOR ya existe como plan activo (UNIQUE
--      (CATEGORIA, VALOR)).
--
--  10. fn_delete_plan_from_value(p_user_pk BIGINT, p_nombre VARCHAR)
--      Marca como active=FALSE un plan existente en la seccion
--      CATEGORIA='PLAN' (soft-delete para preservar audit). La UI conoce
--      el nombre del plan que el admin va a retirar del dropdown. Retorna
--      pk_lista_valor, nombre y was_deleted (true solo si realmente habia
--      un plan activo con ese VALOR derivado y se acaba de desactivar).
--
-- Mapping:
--   academico_test.trol.PK_TROL  -- clave primaria del catalogo
--   academico_test.trol.CODIGO   -- identificador snake_case que va al name
--   academico_test.trol.NOMBRE   -- etiqueta humana que va a description
--   public.role.name = 'CEVAL-' || trol.codigo
--   public.role.description = trol.nombre
--   academico_test.tmenu.PK_TMENU / FK_TMENU -- jerarquia padre -> submenu
--   academico_test.trol_menu.FK_TROL / FK_TMENU -- asignacion rol -> menu
--   academico_test.trol_menu.FK_TPLAN -- plan academico (FK nullable a
--                                       tlista_valor(pk_lista_valor) con
--                                       CATEGORIA='PLAN'; persistido por
--                                       fn_associate_menus_to_rol o por el
--                                       INSERT seed de este archivo)
--
-- Idempotencia:
--   * CREATE OR REPLACE FUNCTION en las diez funciones + el helper
--     interno (fn_assert_superadmin).
--   * DROP TRIGGER IF EXISTS antes del CREATE para re-aplicacion segura.
--   * public.role se inserta con ON CONFLICT (name) DO NOTHING sobre la
--     UNIQUE ya existente en role.name.
--   * Seed de planes academicos con WHERE NOT EXISTS para re-aplicacion
--     segura (solo inserta los que falten).
--   * TROL_MENU usa ON CONFLICT (FK_TROL, FK_TMENU) DO UPDATE para
--     re-activar filas previamente soft-deleted; fk_tplan se materializa
--     con EXCLUDED.fk_tplan (NULL limpio).
--   * TLISTA_VALOR (seccion PLAN) se inserta con WHERE NOT EXISTS por
--     la UNIQUE (CATEGORIA, VALOR) y se soft-deletea en lugar de borrar.
--   * ADD COLUMN IF NOT EXISTS + CREATE INDEX IF NOT EXISTS para el FK
--     fk_tplan; INSERT demo de persistencia con WHERE NOT EXISTS sobre
--     (FK_TROL, FK_TMENU).
--
-- No cubre (fuera de scope):
--   * Autorizacion fina por operacion + recurso: si en el futuro la UI
--     debe permitir que usuarios SIN CEVAL-SUPER_ADMINISTRADOR editen
--     planes o menus para su propia institucion, se requerira una
--     evolucion del helper (p. ej. fn_assert_authorized(p_user_pk,
--     p_operacion, p_recurso)). Por ahora la regla es binaria: rol
--     CEVAL-SUPER_ADMINISTRADOR o nada.
--   * Asignacion masiva de CEVAL-SUPER_ADMINISTRADOR a usuarios iniciales:
--     V59 garantiza que el rol exista (seed), pero la vinculacion con
--     public.users debe hacerse via sso-admin (que crea filas en
--     public.role_users) o cargas iniciales externas. Antes de migrar a
--     esta validacion basada en rol, el equipo debe asegurarse de que
--     al menos los usuarios historicamente superadministradores (pk 1,
--     2, 3 del public.users) tengan una fila en role_users bajo ese rol.
--   * UPDATE / DELETE sobre trol (no se sincroniza en public.role — mismo
--     criterio que V57 decido conscientemente para no chocar con el flujo
--     manual de sso-admin).
--   * Validacion de FK a tlista_valor para ESTADO; heredamos la misma
--     flexibilidad de V22 (estado es un enum SQL propio, pero lo validamos
--     contra el texto canonico por si la columna se conserva como VARCHAR).
--   * La columna "Plan" del formulario de la UI no se persiste en
--     TROL_MENU (V22 no la modela); si el equipo decide agregarla se
--     requerira una migracion posterior para crear el catalogo y la
--     relacion. Esta funcion devuelve la informacion de menu/submenu tal
--     cual existe hoy; el binding a planes queda fuera del join.
--   * DELETE HARD sobre TROL_MENU: la disociacion siempre es soft-delete
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
--    name = 'CEVAL-SUPER_ADMINISTRADOR'. Esto reemplaza la validacion
--    anterior (p_user_pk IN {1,2,3}) que era fragil y no escalaba.
--
--    Todas las funciones listadas abajo lo invocan con PERFORM al inicio
--    de su BEGIN como PRIMER statement, antes de tocar datos.
--
--    Cualquier pk que no figure en public.role_users bajo el rol
--    CEVAL-SUPER_ADMINISTRADOR (NULL incluida) dispara RAISE EXCEPTION
--    con ERRCODE='42501' (insufficient_privilege, mapeado por la UI a 403).
--
--    El helper deliberadamente no recibe nada mas que p_user_pk: el
--    contrato es tan pequeno como el requisito. Si en el futuro se
--    requiere un chequeo mas rico (rol + operacion + recurso), se
--    reemplaza por fn_assert_authorized(p_user_pk, p_operacion, p_recurso)
--    manteniendo la firma similar.
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
-- academico_test.trol (mapea TROL.CODIGO 'SUPER_ADMINISTRADOR' -> CEVAL-
-- SUPER_ADMINISTRADOR), pero este INSERT actua como red de seguridad para
-- entornos donde V36 no se haya corrido o donde TROL no tenga la fila
-- correspondiente. Idempotente (WHERE NOT EXISTS).
--
-- NOTA: este seed NO asigna el rol a ningun usuario; los asignamientos
-- se gestionan via sso-admin (que crea los rows en public.role_users) o
-- cargas iniciales externas. V59 solo garantiza que el rol exista para
-- que fn_assert_superadmin pueda encontrarlo.
-- ---------------------------------------------------------------------------
INSERT INTO public.role (name, description)
SELECT 'CEVAL-SUPER_ADMINISTRADOR', 'Super Administrador del sistema academico (V59 seed)'
 WHERE NOT EXISTS (
       SELECT 1 FROM public.role WHERE name = 'CEVAL-SUPER_ADMINISTRADOR'
       );


-- ---------------------------------------------------------------------------
-- Esquema: persistir el binding submenu × plan en trol_menu.
--
-- Anade la columna fk_tplan BIGINT a academico_test.trol_menu que apunta a
-- academico_test.tlista_valor(pk_lista_valor). Nullable (no todas las
-- asignaciones tienen plan) y FK ON DELETE SET NULL — si un plan se
-- hard-elimina, las asignaciones quedan con fk_tplan=NULL en vez de
-- referenciar una fila inexistente. En operacion normal los planes se
-- soft-eliminan (UPDATE active=FALSE), asi que este SET NULL actua solo
-- como defensa contra un DELETE manual.
--
-- El indice cubre las queries que la UI hara del estilo "submenus
-- habilitados para el plan Preescolar" — sin el indice seria una
-- secuencia scan sobre la junction table.
-- ---------------------------------------------------------------------------
ALTER TABLE academico_test.trol_menu
ADD COLUMN IF NOT EXISTS fk_tplan BIGINT
    REFERENCES academico_test.tlista_valor(pk_lista_valor)
    ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_trol_menu_fk_tplan
    ON academico_test.trol_menu(fk_tplan)
    WHERE fk_tplan IS NOT NULL;


-- ---------------------------------------------------------------------------
-- 1) fn_list_trol_names_for_superadmin
--    Lista los nombres (NOMBRE) de academico_test.trol.
--    Restringido a superadministradores via helper (rol CEVAL-SUPER_ADMINISTRADOR).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_list_trol_names_for_superadmin(
    p_user_pk BIGINT
)
RETURNS TABLE (role_name VARCHAR)
LANGUAGE plpgsql
STABLE
SET search_path = academico_test, public
AS $$
BEGIN
    -- Autorizacion: solo superadministradores.
    PERFORM academico_test.fn_assert_superadmin(p_user_pk);

    RETURN QUERY
    SELECT t.nombre
      FROM academico_test.trol t
     WHERE t.nombre IS NOT NULL
     ORDER BY t.nombre;
END;
$$;


-- ---------------------------------------------------------------------------
-- 2) fn_add_trol
--    Inserta un nuevo rol en academico_test.trol. El CODIGO se deriva
--    internamente del NOMBRE:
--        * el usuario entrega el nombre en lowercase con espacios
--          (ej. "jefe de area");
--        * la funcion lo transforma a UPPERCASE colapsando cualquier
--          secuencia de espacios a '_', produciendo el codigo canonico
--          (ej. "JEFE_DE_AREA") que se usa en public.role con prefijo CEVAL-.
--    Devuelve una fila (pk_trol, nombre) para que el caller pueda
--    encadenar la operacion con el siguiente paso del flujo.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_add_trol(
    p_user_pk    BIGINT,
    p_nombre     VARCHAR,
    p_created_by VARCHAR,
    p_estado     VARCHAR DEFAULT 'A'
)
RETURNS TABLE (pk_trol BIGINT, nombre VARCHAR)
LANGUAGE plpgsql
VOLATILE
SET search_path = academico_test, public
AS $$
DECLARE
    v_nombre    VARCHAR;
    v_codigo    VARCHAR;
    v_estado    CHAR(1);
    v_existente BIGINT;
    v_pk        BIGINT;
    v_nombre_db VARCHAR;
BEGIN
    -- Autorizacion: solo superadministradores.
    PERFORM academico_test.fn_assert_superadmin(p_user_pk);

    -- Validacion 1: nombre obligatorio y no vacio. Lo almacenamos ya
    -- recortado y lo usamos tambien como base para derivar el codigo.
    IF p_nombre IS NULL OR LENGTH(TRIM(p_nombre)) = 0 THEN
        RAISE EXCEPTION 'fn_add_trol: p_nombre es obligatorio';
    END IF;
    v_nombre := TRIM(p_nombre);

    -- Derivacion del CODIGO a partir del NOMBRE:
    --   'jefe de area'           -> 'JEFE_DE_AREA'
    --   '  super   administrador' -> 'SUPER_ADMINISTRADOR' (colapsa espacios)
    --   'admin-rol mixto'        -> 'ADMIN-ROL_MIXTO'  (los guiones quedan)
    -- Se trunca a 30 chars porque academico_test.trol.CODIGO es VARCHAR(30);
    -- nombres largos producirian codigos que excederian la columna.
    v_codigo := LEFT(UPPER(REGEXP_REPLACE(v_nombre, '\s+', '_', 'g')), 30);

    -- Validacion 2 + normalizacion del estado. TROL.ESTADO es el dominio
    --   estado_ai (V22) que solo admite 'A'/'I' en storage; p_estado es
    --   OPCIONAL y DEFAULT 'A' (regla de negocio: todo nuevo rol arranca
    --   como ACTIVO). Si llega valor explicito, debe estar en {A, I, ACTIVO,
    --   INACTIVO} y se normaliza a 'A'/'I' antes del INSERT.
    IF p_estado IS NULL OR LENGTH(TRIM(p_estado)) = 0 THEN
        v_estado := 'A'; -- default canonico (ACTIVO)
    ELSIF UPPER(TRIM(p_estado)) IN ('I', 'INACTIVO') THEN
        v_estado := 'I';
    ELSIF UPPER(TRIM(p_estado)) IN ('A', 'ACTIVO') THEN
        v_estado := 'A';
    ELSE
        RAISE EXCEPTION 'fn_add_trol: p_estado % invalido (valores: ACTIVO, INACTIVO)', p_estado;
    END IF;

    -- Validacion 3: created_by obligatorio (consistente con el resto de TROL).
    IF p_created_by IS NULL OR LENGTH(TRIM(p_created_by)) = 0 THEN
        RAISE EXCEPTION 'fn_add_trol: p_created_by es obligatorio';
    END IF;

    -- Validacion de existencia: no duplicar el CODIGO derivado.
    -- pk_trol se califica con el alias para evitar la colision con el
    -- parametro OUT declarado via RETURNS TABLE (pk_trol BIGINT).
    SELECT t.pk_trol
      INTO v_existente
      FROM academico_test.trol t
     WHERE UPPER(TRIM(t.codigo)) = v_codigo
       AND t.active = TRUE
     LIMIT 1;

    IF v_existente IS NOT NULL THEN
        RAISE EXCEPTION 'fn_add_trol: ya existe un TROL activo con codigo=% (pk=%)', v_codigo, v_existente;
    END IF;

    -- Validacion de existencia: no duplicar NOMBRE (U_TROL_1).
    SELECT t.pk_trol
      INTO v_existente
      FROM academico_test.trol t
     WHERE UPPER(TRIM(t.nombre)) = UPPER(v_nombre)
     LIMIT 1;

    IF v_existente IS NOT NULL THEN
        RAISE EXCEPTION 'fn_add_trol: ya existe un TROL con nombre=% (pk=%)', v_nombre, v_existente;
    END IF;

    -- Insercion. TROL tiene DEFAULT en CREATED_AT/ACTIVE, los demas campos
    -- se completan con NULL hasta una eventual edicion administrativa.
    INSERT INTO academico_test.trol (
        codigo, nombre, estado, created_by
    )
    VALUES (
        v_codigo,
        v_nombre,
        v_estado,
        TRIM(p_created_by)
    )
    RETURNING academico_test.trol.pk_trol, academico_test.trol.nombre
      INTO v_pk, v_nombre_db;

    -- Asignamos a los OUT params declarados via RETURNS TABLE para
    -- devolver ambos valores con un solo RETURN NEXT.
    pk_trol := v_pk;
    nombre  := v_nombre_db;
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
    -- Defensa: si el CODIGO viene vacio, no hay como construir el name.
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
--    Devuelve TODAS las combinaciones padre -> submenu de tmenu, marcadas
--    con ya_asignado si esa combinacion (rol, submenu) ya esta en trol_menu.
--    Pensada para alimentar la UI "Agregar menu" de sso-admin: el usuario
--    elige un Rol y un Menu padre, y la grilla de Submenus se llena con las
--    filas devueltas (cada fila incluye nombre, URL, visible y si ya esta
--    asignada al rol para que la UI la muestre como activada vs disponible).
--    Solo 2 niveles de jerarquia: padre = tmenu.fk_tmenu IS NULL, hijo =
--    tmenu.fk_tmenu = padre.pk_tmenu. Nietos y niveles mas profundos se
--    ignoran (V22 modela el auto-FK recursivo pero el formulario actual
--    solo expone 2 niveles).
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
    visible         CHAR(1),
    orden_submenu   NUMERIC,
    ya_asignado     BOOLEAN
)
LANGUAGE plpgsql
STABLE
SET search_path = academico_test
AS $$
BEGIN
    -- Autorizacion: solo superadministradores.
    PERFORM academico_test.fn_assert_superadmin(p_user_pk);

    -- Validacion: el rol debe existir y estar activo. ERRCODE P0002
    -- (no_data_found) para que la UI lo traduzca a 404.
    IF p_pk_trol IS NULL
       OR NOT EXISTS (
           SELECT 1
             FROM academico_test.trol
            WHERE pk_trol = p_pk_trol
              AND active = TRUE
       )
    THEN
        RAISE EXCEPTION 'fn_list_menu_possibilities_for_rol: TROL pk=% no existe o no esta activo', p_pk_trol
            USING ERRCODE = 'P0002';
    END IF;

    RETURN QUERY
    SELECT
        padre.pk_tmenu                                AS pk_padre,
        padre.nombre                                  AS nombre_padre,
        padre.icono                                   AS icono_padre,
        padre.orden                                   AS orden_padre,
        hijo.pk_tmenu                                 AS pk_submenu,
        hijo.nombre                                   AS nombre_submenu,
        hijo.url                                      AS url,
        hijo.visible::CHAR(1)                          AS visible,
        hijo.orden                                    AS orden_submenu,
        (tm.pk_trol_menu IS NOT NULL)                 AS ya_asignado
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
--    Materializa uno o varios TROL_MENU (FK_TROL, FK_TMENU) para el rol
--    indicado. Pensada para el boton "Guardar" de la pantalla "Agregar
--    menu" en sso-admin: la UI envia el conjunto de submenus que el admin
--    acaba de activar y esta funcion los persiste en academico_test.trol_menu.
--
--    Semantica UPSERT sobre la U_TROL_MENU_1 (FK_TROL, FK_TMENU):
--      * No existe la combinacion -> INSERT (active=TRUE, created_by).
--      * Existe pero active=FALSE (disociada previamente) -> REACTIVA
--        poniendo active=TRUE y modified_by/modified_at = operacion.
--      * Ya esta activa -> no-op (la fila RETURNING distingue via xmax=0).
--
--    Validacion PER-ROW del TMENU: si el menu no existe o esta inactivo,
--    se emite una fila de error pero el resto del array sigue procesandose.
--    Si el ROL no existe o esta inactivo, la funcion falla con EXCEPTION
--    (no se procesa ninguna fila).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_associate_menus_to_rol(
    p_user_pk    BIGINT,
    p_pk_trol    BIGINT,
    p_pk_tmenus  BIGINT[],
    p_created_by VARCHAR,
    p_pk_tplan   BIGINT DEFAULT NULL
)
RETURNS TABLE (
    pk_tmenu     BIGINT,
    pk_trol_menu BIGINT,
    status       VARCHAR
)
LANGUAGE plpgsql
VOLATILE
SET search_path = academico_test, public
AS $$
DECLARE
    v_tmenu        BIGINT;
    v_pk           BIGINT;
    v_was_inserted BOOLEAN;
    v_now          TIMESTAMP := CURRENT_TIMESTAMP;
BEGIN
    -- Autorizacion: solo superadministradores.
    PERFORM academico_test.fn_assert_superadmin(p_user_pk);

    -- Validacion 1: rol obligatorio y activo (fail-fast).
    IF p_pk_trol IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM academico_test.trol
            WHERE pk_trol = p_pk_trol AND active = TRUE
       )
    THEN
        RAISE EXCEPTION 'fn_associate_menus_to_rol: TROL pk=% no existe o no esta activo', p_pk_trol
            USING ERRCODE = 'P0002';
    END IF;

    -- Validacion 2: array de menues no vacio.
    IF p_pk_tmenus IS NULL
       OR array_length(p_pk_tmenus, 1) IS NULL
       OR array_length(p_pk_tmenus, 1) = 0
    THEN
        RAISE EXCEPTION 'fn_associate_menus_to_rol: p_pk_tmenus debe contener al menos un PK'
            USING ERRCODE = '22023'; -- invalid_parameter_value
    END IF;

    -- Validacion 3: created_by obligatorio.
    IF p_created_by IS NULL OR LENGTH(TRIM(p_created_by)) = 0 THEN
        RAISE EXCEPTION 'fn_associate_menus_to_rol: p_created_by es obligatorio';
    END IF;

    -- Validacion 4: si se proporciono un plan, debe existir, estar activo
    -- y pertenecer a la seccion CATEGORIA='PLAN' de tlista_valor. Asi se
    -- evita que la UI envie un pk_lista_valor de otra categoria por error.
    IF p_pk_tplan IS NOT NULL
       AND NOT EXISTS (
           SELECT 1 FROM academico_test.tlista_valor
            WHERE pk_lista_valor = p_pk_tplan
              AND categoria      = 'PLAN'
              AND active         = TRUE
       )
    THEN
        RAISE EXCEPTION 'fn_associate_menus_to_rol: p_pk_tplan=% no es un plan activo (CATEGORIA=PLAN)', p_pk_tplan
            USING ERRCODE = 'P0002';
    END IF;

    FOREACH v_tmenu IN ARRAY p_pk_tmenus LOOP
        pk_tmenu     := v_tmenu;
        pk_trol_menu := NULL;
        status       := NULL;

        -- Validacion per-row: el menu debe existir y estar activo.
        -- m.* evita la colision con el parametro OUT `pk_tmenu` de RETURNS TABLE.
        IF v_tmenu IS NULL OR NOT EXISTS (
            SELECT 1 FROM academico_test.tmenu m
             WHERE m.pk_tmenu = v_tmenu
               AND m.active   = TRUE
               AND m.estado   = 'A'
        ) THEN
            status := 'menu_not_found_or_inactive';
            RETURN NEXT;
            CONTINUE;
        END IF;

        -- UPSERT. xmax=0 en el RETURNING distingue insercion vs update;
        -- actualizamos modified_by/at solo si la fila ya existia (estaba
        -- soft-deleted y la estamos reviviendo), no si es 100% nueva.
        -- fk_tplan se materializa con el valor de p_pk_tplan (NULL = el
        -- admin no eligio plan para este submenu, EXCLUDED.fk_tplan en
        -- NULL limpia una asignacion anterior).
        INSERT INTO academico_test.trol_menu (
            fk_trol, fk_tmenu, fk_tplan, active, created_by
        )
        VALUES (
            p_pk_trol, v_tmenu, p_pk_tplan, TRUE, TRIM(p_created_by)
        )
        ON CONFLICT (fk_trol, fk_tmenu) DO UPDATE
           SET active      = TRUE,
               modified_by = TRIM(p_created_by),
               modified_at = v_now,
               fk_tplan    = EXCLUDED.fk_tplan
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
--    Desvincula uno o varios TROL_MENU (FK_TROL, FK_TMENU) del rol dado.
--    Pensada para el caso opuesto: la UI envia los pks de los submenus
--    que el admin acaba de desactivar y la funcion marca cada fila como
--    active=FALSE (soft-delete para preservar auditoria: created_by y
--    created_at se conservan, modified_by/modified_at quedan registrados
--    por la operacion).
--
--    Por fila: si el menu no estaba asociado a ese rol (o ya estaba
--    inactivo), devuelve was_deleted=FALSE (no-op). Devuelve TRUE solo
--    si realmente habia una asociacion activa que se acaba de desactivar.
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
    -- Autorizacion: solo superadministradores.
    PERFORM academico_test.fn_assert_superadmin(p_user_pk);

    IF p_pk_trol IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM academico_test.trol
            WHERE pk_trol = p_pk_trol AND active = TRUE
       )
    THEN
        RAISE EXCEPTION 'fn_dissociate_menus_from_rol: TROL pk=% no existe o no esta activo', p_pk_trol
            USING ERRCODE = 'P0002';
    END IF;

    IF p_pk_tmenus IS NULL
       OR array_length(p_pk_tmenus, 1) IS NULL
       OR array_length(p_pk_tmenus, 1) = 0
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
--    Devuelve el ARBOL completo de academico_test.tmenu (parents + submenus)
--    en orden jerarquico, sin filtro por rol. Pensada para alimentar el
--    panel "Menus disponibles" del TransferList de sso-admin: cada fila es
--    un TMENU con metadata de jerarquia (es_padre + pk_padre) para que el
--    cliente reconstruya el arbol padre -> hijo en pantalla.
--
--    Orden de las filas devueltas:
--      1. Parents agrupados por pk_padre (parents mapean a si mismos via
--         COALESCE(fk_tmenu, pk_tmenu)).
--      2. Submenus agrupados bajo su padre (mismo COALESCE).
--      3. Dentro de cada grupo, padre primero (es_padre DESC), luego por
--         ORDEN NULLS LAST, luego por NOMBRE.
--
--    Sin estado de asignacion: el UI cruza con trolley_menu (via fn_3
--    ya_asignado o un query directo) para pintar disponibles vs asignados.
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
    visible  CHAR(1),
    orden    NUMERIC,
    es_padre BOOLEAN
)
LANGUAGE plpgsql
STABLE
SET search_path = academico_test, public
AS $$
BEGIN
    -- Autorizacion: solo superadministradores.
    PERFORM academico_test.fn_assert_superadmin(p_user_pk);

    RETURN QUERY
    SELECT
        m.pk_tmenu                                                 AS pk_tmenu,
        m.fk_tmenu                                                AS pk_padre,
        m.nombre                                                  AS nombre,
        m.url                                                     AS url,
        m.icono                                                   AS icono,
        m.visible::CHAR(1)                                         AS visible,
        m.orden                                                   AS orden,
        (m.fk_tmenu IS NULL)                                      AS es_padre
    FROM academico_test.tmenu m
    WHERE m.estado = 'A'
      AND m.active = TRUE
    ORDER BY
        COALESCE(m.fk_tmenu, m.pk_tmenu),                         -- agrupa submenus bajo su padre
        (m.fk_tmenu IS NULL) DESC,                                -- padre antes que hijos
        m.orden NULLS LAST,
        m.nombre;
END;
$$;


-- ---------------------------------------------------------------------------
-- 8) fn_create_parent_menu_with_submenus
--    Crea un menu padre (fk_tmenu=NULL) en academico_test.tmenu junto
--    con N submenus hijos en una sola operacion. Pensada para el dialog
--    "Agregar menu" de sso-admin cuando el usuario selecciona "Crear
--    nuevo menu principal" en el dropdown "Menu padre".
--
--    Reutiliza la logica de derivacion de CODIGO de fn_add_trol:
--      'Gestion de Biblioteca' -> 'GESTION_DE_BIBLIOTECA'
--    Validacion explicita de duplicados (case-insensitive) tanto en
--    CODIGO como en NOMBRE del padre; para los submenus se procesan
--    per-row (un error individual no aborta la lista de submenus).
--
--    Formato del JSONB p_submenus (cada elemento):
--      { "nombre":  "...", "url": "...",
--        "visible": "S"|"N"|null, "orden": 1 }
--
--    Una vez creado el padre y los submenus, la UI los vincula a un rol
--    via fn_associate_menus_to_rol (no es responsabilidad de esta funcion
--    — la pantalla "Agregar menu" no expone un selector de rol; la
--    asignacion se hace en flujo aparte).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_create_parent_menu_with_submenus(
    p_user_pk         BIGINT,
    p_padre_nombre     VARCHAR,
    p_padre_created_by VARCHAR,
    p_padre_icono      VARCHAR DEFAULT NULL,
    p_padre_visible    VARCHAR DEFAULT 'S',
    p_padre_orden      NUMERIC DEFAULT NULL,
    p_padre_url        VARCHAR DEFAULT NULL,
    p_submenus         JSONB   DEFAULT '[]'::JSONB
)
RETURNS TABLE (
    pk_padre       BIGINT,
    nombre_padre   VARCHAR,
    pk_submenu     BIGINT,
    nombre_submenu VARCHAR,
    status         VARCHAR
)
LANGUAGE plpgsql
VOLATILE
SET search_path = academico_test, public
AS $$
DECLARE
    v_padre_nombre   VARCHAR;
    v_padre_codigo   VARCHAR;
    v_padre_visible  CHAR(1);
    v_padre_pk       BIGINT;
    v_existente      BIGINT;

    -- Iteradores per-submenu (FOR ... IN SELECT loop over jsonb_array_elements)
    v_sub_nombre     VARCHAR;
    v_sub_url        VARCHAR;
    v_sub_visible_in VARCHAR;
    v_sub_orden      NUMERIC;
    v_sub_codigo     VARCHAR;
    v_sub_pk         BIGINT;
BEGIN
    -- Autorizacion: solo superadministradores.
    PERFORM academico_test.fn_assert_superadmin(p_user_pk);

    -- ---------------------------------------------------------------------
    -- Validaciones del PADRE
    -- ---------------------------------------------------------------------
    IF p_padre_nombre IS NULL OR LENGTH(TRIM(p_padre_nombre)) = 0 THEN
        RAISE EXCEPTION 'fn_create_parent_menu_with_submenus: p_padre_nombre es obligatorio';
    END IF;
    v_padre_nombre := TRIM(p_padre_nombre);

    -- Codigo derivado del nombre (mismo patron que fn_add_trol).
    v_padre_codigo := LEFT(UPPER(REGEXP_REPLACE(v_padre_nombre, '\s+', '_', 'g')), 30);

    -- Visible normalizado: 'S'/'N' (acepta variantes SI/NO/TRUE/FALSE en MAYUS).
    IF p_padre_visible IS NULL OR LENGTH(TRIM(p_padre_visible)) = 0 THEN
        v_padre_visible := 'S';
    ELSIF UPPER(TRIM(p_padre_visible)) IN ('S', 'SI', 'TRUE', 'Y', '1') THEN
        v_padre_visible := 'S';
    ELSIF UPPER(TRIM(p_padre_visible)) IN ('N', 'NO', 'FALSE', '0') THEN
        v_padre_visible := 'N';
    ELSE
        RAISE EXCEPTION 'fn_create_parent_menu_with_submenus: p_padre_visible % invalido', p_padre_visible;
    END IF;

    -- Created_by obligatorio (consistente con fn_add_trol).
    IF p_padre_created_by IS NULL OR LENGTH(TRIM(p_padre_created_by)) = 0 THEN
        RAISE EXCEPTION 'fn_create_parent_menu_with_submenus: p_padre_created_by es obligatorio';
    END IF;

    -- Duplicado CODIGO (case-insensitive). Alias m.* para evitar la colision
    -- con el parametro OUT `pk_submenu` de RETURNS TABLE.
    SELECT m.pk_tmenu
      INTO v_existente
      FROM academico_test.tmenu m
     WHERE UPPER(TRIM(m.codigo)) = v_padre_codigo
       AND m.active = TRUE
     LIMIT 1;
    IF v_existente IS NOT NULL THEN
        RAISE EXCEPTION 'fn_create_parent_menu_with_submenus: ya existe un TMENU activo con codigo=% (pk=%)', v_padre_codigo, v_existente;
    END IF;

    -- Duplicado NOMBRE (defensivo — V22 no lo modela pero lo mantenemos
    -- consistente con fn_add_trol para evitar nombres duplicados en la UI).
    SELECT m.pk_tmenu
      INTO v_existente
      FROM academico_test.tmenu m
     WHERE UPPER(TRIM(m.nombre)) = UPPER(v_padre_nombre)
       AND m.active = TRUE
     LIMIT 1;
    IF v_existente IS NOT NULL THEN
        RAISE EXCEPTION 'fn_create_parent_menu_with_submenus: ya existe un TMENU activo con nombre=% (pk=%)', v_padre_nombre, v_existente;
    END IF;

    -- INSERT del padre (fk_tmenu=NULL por definicion).
    INSERT INTO academico_test.tmenu (
        codigo, nombre, icono, visible, estado,
        url, fk_tmenu, orden, created_by
    )
    VALUES (
        v_padre_codigo, v_padre_nombre, p_padre_icono, v_padre_visible, 'A',
        p_padre_url, NULL, p_padre_orden, TRIM(p_padre_created_by)
    )
    RETURNING academico_test.tmenu.pk_tmenu
      INTO v_padre_pk;

    -- Fila numero 1: el padre (pk_submenu / nombre_submenu NULL).
    pk_padre       := v_padre_pk;
    nombre_padre   := v_padre_nombre;
    pk_submenu     := NULL;
    nombre_submenu := NULL;
    status         := 'parent_created';
    RETURN NEXT;

    -- ---------------------------------------------------------------------
    -- Iterar submenus (si los hay).
    -- ---------------------------------------------------------------------
    IF p_submenus IS NOT NULL
       AND jsonb_typeof(p_submenus) = 'array'
       AND jsonb_array_length(p_submenus) > 0
    THEN
        FOR v_sub_nombre, v_sub_url, v_sub_visible_in, v_sub_orden IN
            SELECT
                (elem ->> 'nombre')::VARCHAR,
                (elem ->> 'url')::VARCHAR,
                COALESCE((elem ->> 'visible')::VARCHAR, 'S'),
                (elem ->> 'orden')::NUMERIC
              FROM jsonb_array_elements(p_submenus) elem
        LOOP
            -- Defaults por fila (pk_padre / nombre_padre).
            pk_padre     := v_padre_pk;
            nombre_padre := v_padre_nombre;
            pk_submenu     := NULL;
            nombre_submenu := NULL;
            status         := NULL;

            -- Validacion 1: nombre no vacio.
            IF v_sub_nombre IS NULL OR LENGTH(TRIM(v_sub_nombre)) = 0 THEN
                status         := 'submenu_error:nombre_requerido';
                pk_submenu     := NULL;
                nombre_submenu := NULL;
                RETURN NEXT;
                CONTINUE;
            END IF;

            -- Validacion 2: url no vacia (los submenus SIEMPRE necesitan url;
            -- los padres pueden tenerla NULL).
            IF v_sub_url IS NULL OR LENGTH(TRIM(v_sub_url)) = 0 THEN
                status         := 'submenu_error:url_requerida';
                pk_submenu     := NULL;
                nombre_submenu := TRIM(v_sub_nombre);
                RETURN NEXT;
                CONTINUE;
            END IF;

            -- Validacion 3: visible normalizado.
            IF v_sub_visible_in IS NULL
               OR LENGTH(TRIM(v_sub_visible_in)) = 0
               OR UPPER(TRIM(v_sub_visible_in)) IN ('S', 'SI', 'TRUE', 'Y', '1')
            THEN
                v_sub_visible_in := 'S';
            ELSIF UPPER(TRIM(v_sub_visible_in)) IN ('N', 'NO', 'FALSE', '0') THEN
                v_sub_visible_in := 'N';
            ELSE
                status         := format('submenu_error:visible_invalido:%s', v_sub_visible_in);
                pk_submenu     := NULL;
                nombre_submenu := TRIM(v_sub_nombre);
                RETURN NEXT;
                CONTINUE;
            END IF;

            -- Codigo del submenu (mismo patron).
            v_sub_codigo := LEFT(UPPER(REGEXP_REPLACE(TRIM(v_sub_nombre), '\s+', '_', 'g')), 30);

            -- Validacion de duplicado CODIGO a nivel global (no solo dentro del array).
            SELECT m.pk_tmenu
              INTO v_existente
              FROM academico_test.tmenu m
             WHERE UPPER(TRIM(m.codigo)) = v_sub_codigo
               AND m.active = TRUE
             LIMIT 1;
            IF v_existente IS NOT NULL THEN
                status         := 'submenu_error:codigo_duplicado';
                pk_submenu     := v_existente;
                nombre_submenu := TRIM(v_sub_nombre);
                RETURN NEXT;
                CONTINUE;
            END IF;

            -- INSERT del submenu (fk_tmenu=padre_pk, estado='A' fijo).
            INSERT INTO academico_test.tmenu (
                codigo, nombre, url, visible, estado,
                fk_tmenu, orden, created_by
            )
            VALUES (
                v_sub_codigo, TRIM(v_sub_nombre), TRIM(v_sub_url),
                v_sub_visible_in, 'A',
                v_padre_pk, v_sub_orden, TRIM(p_padre_created_by)
            )
            RETURNING academico_test.tmenu.pk_tmenu
              INTO v_sub_pk;

            pk_submenu     := v_sub_pk;
            nombre_submenu := TRIM(v_sub_nombre);
            status         := 'submenu_inserted';
            RETURN NEXT;
        END LOOP;
    END IF;
END;
$$;


-- ---------------------------------------------------------------------------
-- 9) fn_list_plans_from_value
--    Lista los planes academicos activos definidos en la seccion
--    CATEGORIA='PLAN' de academico_test.tlista_valor. Pensada para
--    alimentar el dropdown "Plan" de la pantalla "Agregar menu" de
--    sso-admin (los valores seedeados son Preescolar / Basico / Medio).
--    Sin parametros, sin validaciones: solo lectura.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_list_plans_from_value(
    p_user_pk BIGINT
)
RETURNS TABLE (
    pk_lista_valor BIGINT,
    nombre         VARCHAR,
    valor          VARCHAR,
    activo         BOOLEAN
)
LANGUAGE plpgsql
STABLE
SET search_path = academico_test, public
AS $$
BEGIN
    -- Autorizacion: solo superadministradores.
    PERFORM academico_test.fn_assert_superadmin(p_user_pk);

    RETURN QUERY
    SELECT
        lv.pk_lista_valor,
        lv.nombre,
        lv.valor,
        lv.active
    FROM academico_test.tlista_valor lv
    WHERE lv.categoria = 'PLAN'
      AND lv.active    = TRUE
    ORDER BY lv.nombre;
END;
$$;


-- ---------------------------------------------------------------------------
-- 10) fn_create_plan_from_value
--     Inserta un nuevo plan en la seccion CATEGORIA='PLAN' de
--     academico_test.tlista_valor. La UI solo envia el nombre (campo
--     "Nombre del nuevo plan" + boton +), asi que p_created_by se deriva
--     de CURRENT_USER. El VALOR canonico se genera del nombre (UPPER +
--     colapso de espacios a '_' — mismo patron que fn_add_trol). Falla
--     con EXCEPTION si ya existe un plan activo con el VALOR derivado
--     (UNIQUE (CATEGORIA, VALOR) lo garantiza, pero lo verificamos antes
--     para emitir un mensaje claro).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_create_plan_from_value(
    p_user_pk BIGINT,
    p_nombre  VARCHAR
)
RETURNS TABLE (
    pk_lista_valor BIGINT,
    nombre         VARCHAR,
    valor          VARCHAR,
    status         VARCHAR
)
LANGUAGE plpgsql
VOLATILE
SET search_path = academico_test, public
AS $$
DECLARE
    v_nombre    VARCHAR;
    v_valor     VARCHAR;
    v_pk        BIGINT;
    v_existente BIGINT;
BEGIN
    -- Autorizacion: solo superadministradores.
    PERFORM academico_test.fn_assert_superadmin(p_user_pk);

    IF p_nombre IS NULL OR LENGTH(TRIM(p_nombre)) = 0 THEN
        RAISE EXCEPTION 'fn_create_plan_from_value: p_nombre es obligatorio';
    END IF;
    v_nombre := TRIM(p_nombre);

    -- Mismo patron de derivacion de codigo que fn_add_trol /
    -- fn_create_parent_menu_with_submenus.
    v_valor := LEFT(UPPER(REGEXP_REPLACE(v_nombre, '\s+', '_', 'g')), 30);

    -- Verificacion explicita de duplicado (case-insensitive en VALOR)
    -- sobre la seccion CATEGORIA='PLAN'. Alias lv.* para evitar la
    -- colision con el parametro OUT `pk_lista_valor` de RETURNS TABLE.
    SELECT lv.pk_lista_valor
      INTO v_existente
      FROM academico_test.tlista_valor lv
     WHERE lv.categoria = 'PLAN'
       AND UPPER(TRIM(lv.valor)) = v_valor
       AND lv.active = TRUE
     LIMIT 1;

    IF v_existente IS NOT NULL THEN
        RAISE EXCEPTION 'fn_create_plan_from_value: ya existe un plan activo con valor=% (pk_lista_valor=%)',
            v_valor, v_existente;
    END IF;

    INSERT INTO academico_test.tlista_valor (
        categoria, nombre, valor, created_by
    )
    VALUES (
        'PLAN', v_nombre, v_valor, CURRENT_USER
    )
    RETURNING academico_test.tlista_valor.pk_lista_valor,
              academico_test.tlista_valor.nombre,
              academico_test.tlista_valor.valor
      INTO v_pk, nombre, valor;

    pk_lista_valor := v_pk;
    status         := 'inserted';
    RETURN NEXT;
END;
$$;


-- ---------------------------------------------------------------------------
-- 11) fn_delete_plan_from_value
--     Soft-delete (active=FALSE) sobre la seccion CATEGORIA='PLAN' de
--     academico_test.tlista_valor. Tambien opera por nombre: la UI
--     conoce el plan que el admin acaba de retirar del dropdown, asi que
--     solo necesitamos p_nombre. Conserva el VALOR/CATEGORIA/NOMBRE/CREATED_*
--     para auditoria; registra modified_by/at con CURRENT_USER.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_delete_plan_from_value(
    p_user_pk BIGINT,
    p_nombre  VARCHAR
)
RETURNS TABLE (
    pk_lista_valor BIGINT,
    nombre         VARCHAR,
    was_deleted    BOOLEAN
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
    -- Autorizacion: solo superadministradores.
    PERFORM academico_test.fn_assert_superadmin(p_user_pk);

    IF p_nombre IS NULL OR LENGTH(TRIM(p_nombre)) = 0 THEN
        RAISE EXCEPTION 'fn_delete_plan_from_value: p_nombre es obligatorio';
    END IF;

    v_valor := UPPER(REGEXP_REPLACE(TRIM(p_nombre), '\s+', '_', 'g'));

    -- Lookup del plan activo en la seccion PLAN. Alias lv.* para evitar
    -- la colision con el parametro OUT `pk_lista_valor` de RETURNS TABLE.
    SELECT lv.pk_lista_valor
      INTO v_pk
      FROM academico_test.tlista_valor lv
     WHERE lv.categoria   = 'PLAN'
       AND UPPER(TRIM(lv.valor)) = v_valor
       AND lv.active      = TRUE
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

    pk_lista_valor := v_pk;
    nombre         := TRIM(p_nombre);
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


-- ---------------------------------------------------------------------------
-- Ejemplo de persistencia del binding (rol, submenu, plan).
--
-- Demuestra el uso de la nueva columna academico_test.trol_menu.fk_tplan:
-- para cada plan academico seedeado arriba (Preescolar / Basico / Medio),
-- crea una vinculacion 'demo' entre TROL, TMENU y el plan para que la UI
-- tenga algo que mostrar al primer arranque.
--
-- Caracteristicas:
--   * Es un ejemplo (valores 'demo_*'). En produccion la UI reemplazara
--     estos registros via fn_associate_menus_to_rol cuando un superadmin
--     guarde una asignacion real.
--   * Hace JOIN por nombre (no por pk) para que sea resistente a
--     re-ejecuciones de la migracion y a migraciones con datos ligeramente
--     distintos entre entornos.
--   * Si no existe ningun TROL o TMENU 'demo', el INSERT no falla — el
--     LEFT JOIN filtra todas las filas (la UI lo vera vacio y poblara
--     via fn_associate_menus_to_rol cuando el admin lo necesite).
--   * Re-aplicable: la combinacion (FK_TROL, FK_TMENU, FK_TPLAN) ya esta
--     UNIQUE por FK_TROL, FK_TMENU; re-correr este INSERT no duplica.
-- ---------------------------------------------------------------------------
INSERT INTO academico_test.trol_menu (
    fk_trol, fk_tmenu, fk_tplan, active, created_by
)
SELECT t.pk_trol, m.pk_tmenu, p.pk_lista_valor, TRUE, 'V59_seed'
  FROM academico_test.trol           t
  JOIN academico_test.tmenu           m ON m.nombre = 'demo_menu'      AND m.active = TRUE
  JOIN academico_test.tlista_valor    p ON p.valor  IN ('PREESCOLAR','BASICO','MEDIO')
                                     AND p.categoria = 'PLAN'        AND p.active = TRUE
 WHERE NOT EXISTS (
       SELECT 1
         FROM academico_test.trol_menu tm
        WHERE tm.fk_trol  = t.pk_trol
          AND tm.fk_tmenu = m.pk_tmenu
       );


-- ---------------------------------------------------------------------------
-- Comentarios de documentacion
-- ---------------------------------------------------------------------------
COMMENT ON FUNCTION academico_test.fn_assert_superadmin(BIGINT) IS
    'Helper interno de V59. Unico punto donde vive la regla "tener el rol CEVAL-SUPER_ADMINISTRADOR para ejecutar las funciones administrativas". La validacion se hace por JOIN entre public.role_users (user_id = p_user_pk) y public.role (name = ''CEVAL-SUPER_ADMINISTRADOR'') — NO por una lista hardcoded de pks (la version anterior con p_user_pk IN {1,2,3} era fragil). Todas las funciones listadas lo invocan con PERFORM al inicio del BEGIN como PRIMER statement; cualquier pk sin ese rol (NULL incluida) dispara RAISE EXCEPTION con ERRCODE=''42501'' (insufficient_privilege -> 403). El seed INSERT previo al helper garantiza que el rol exista en public.role incluso si V36 nunca se ejecuto. Requiere que el rol sea asignado al usuario via sso-admin (fila en role_users).';

COMMENT ON FUNCTION academico_test.fn_list_trol_names_for_superadmin(BIGINT) IS
    'Lista unicamente los nombres (NOMBRE) de los roles en academico_test.trol. Restringido a superadministradores via fn_assert_superadmin (el usuario p_user_pk debe tener el rol CEVAL-SUPER_ADMINISTRADOR en public.role_users); cualquier otra pk dispara EXCEPTION con ERRCODE 42501 (insufficient_privilege) ANTES de tocar datos.';

COMMENT ON FUNCTION academico_test.fn_add_trol(BIGINT, VARCHAR, VARCHAR, VARCHAR) IS
    'Inserta un nuevo rol en academico_test.trol. REQUIERE p_user_pk (validado por fn_assert_superadmin al inicio). p_nombre es input del usuario en lowercase con espacios (p. ej. "jefe de area") y la funcion deriva el CODIGO canonico (UPPER + reemplazo de espacios por "_", p. ej. "JEFE_DE_AREA"). p_estado es OPCIONAL y DEFAULT ''A'' (todo nuevo rol arranca ACTIVO); si llega valor debe ser uno de {A, I, ACTIVO, INACTIVO} y se normaliza al dominio estado_ai (''A''/''I''). Validaciones adicionales: nombre/created_by no vacios, no duplica codigo activo ni nombre (U_TROL_1). Retorna una fila (pk_trol, nombre). El trigger AFTER INSERT la sigue para materializar public.role (CEVAL-<codigo>).';

COMMENT ON FUNCTION academico_test.fn_sync_trol_to_public_role() IS
    'Trigger AFTER INSERT ON trol: inserta el homologo en public.role con name = CEVAL-<codigo> y description = trol.nombre. Idempotente via ON CONFLICT (name) DO NOTHING. No-op (WARNING) si CODIGO viene vacio. No requiere p_user_pk: lo invoca el motor automaticamente despues de fn_add_trol, que ya exigio superadmin.';

COMMENT ON TRIGGER trg_sync_trol_to_public_role ON academico_test.trol IS
    'Dispara fn_sync_trol_to_public_role despues de cada INSERT en trol para mantener public.role sincronizado con el catalogo academico bajo el prefijo CEVAL-.';

COMMENT ON FUNCTION academico_test.fn_list_menu_possibilities_for_rol(BIGINT, BIGINT) IS
    'Devuelve TODAS las combinaciones padre -> submenu (2 niveles) de academico_test.tmenu, marcando con ya_asignado=true las que ya estan vinculadas al rol via academico_test.trol_menu. REQUIERE p_user_pk (validado por fn_assert_superadmin). Pensada para alimentar la pantalla "Agregar menu" de sso-admin (selector de Rol + selector de Menu padre + grilla de Submenus con columnas Nombre/URL/Visible). Valida ademas que el rol exista y este activo (RAISE EXCEPTION con ERRCODE P0002 si no). Solo contempla menues padre (FK_TMENU IS NULL) y sus hijos directos.';

COMMENT ON FUNCTION academico_test.fn_associate_menus_to_rol(BIGINT, BIGINT, BIGINT[], VARCHAR, BIGINT) IS
    'Vincula uno o varios TMENU a un rol (academico_test.trol_menu). REQUIERE p_user_pk (validado por fn_assert_superadmin al inicio). UPSERT sobre U_TROL_MENU_1 (FK_TROL, FK_TMENU): inserta si la combinacion no existe (active=TRUE, created_by), reactiva si existe pero active=FALSE (modified_by/at), no-op si ya esta activa. Acepta p_pk_tplan BIGINT opcional (default NULL) para persistir el plan academico elegido en el dropdown de la UI; se valida que pertenezca a CATEGORIA=''PLAN'' de tlista_valor y se materializa en la columna trol_menu.fk_tplan (FK nullable a tlista_valor.pk_lista_valor). Devuelve una fila por cada p_pk_tmenu: pk_tmenu, pk_trol_menu, status (inserted/reactivated/menu_not_found_or_inactive). El rol debe existir y estar activo (RAISE EXCEPTION con ERRCODE P0002 si no); cada menu se valida per-row y se reporta el error sin abortar.';

COMMENT ON FUNCTION academico_test.fn_dissociate_menus_from_rol(BIGINT, BIGINT, BIGINT[]) IS
    'Desvincula uno o varios TMENU de un rol realizando soft-delete (UPDATE active=FALSE) sobre academico_test.trol_menu. REQUIERE p_user_pk (validado por fn_assert_superadmin). Pensada para la desactivacion de submenus desde la UI "Agregar menu". Conserva created_by/created_at y registra modified_by/at en la operacion. Devuelve una fila por cada p_pk_tmenu: pk_tmenu y was_deleted (true solo si habia una asociacion activa que se acaba de desactivar; false si el menu nunca estuvo asociado o ya estaba desactivado). El rol debe existir y estar activo (RAISE EXCEPTION con ERRCODE P0002 si no).';

COMMENT ON FUNCTION academico_test.fn_list_available_menus(BIGINT) IS
    'Devuelve el ARBOL completo de academico_test.tmenu (parents + submenus) ordenado jerarquicamente (padre primero, submenus agrupados bajo su padre por pk_padre, luego por ORDEN y NOMBRE). REQUIERE p_user_pk (validado por fn_assert_superadmin). Pensada para el panel "Menus disponibles" del TransferList de sso-admin; el UI cruza con trolley_menu (o usa ya_asignado de fn_list_menu_possibilities_for_rol) para distinguir disponibles vs asignados. Sin filtro por rol. Solo incluye filas activas (estado=''A'' AND active=TRUE).';

COMMENT ON FUNCTION academico_test.fn_create_parent_menu_with_submenus(BIGINT, VARCHAR, VARCHAR, VARCHAR, VARCHAR, NUMERIC, VARCHAR, JSONB) IS
    'Crea un menu padre (fk_tmenu=NULL) en academico_test.tmenu junto con N submenus hijos en una sola operacion. REQUIERE p_user_pk (validado por fn_assert_superadmin). Pensada para el dialog "Agregar menu" de sso-admin cuando el usuario elige "Crear nuevo menu principal" en el dropdown "Menu padre". Reutiliza la logica de derivacion de CODIGO de fn_add_trol (UPPER + reemplazo de cualquier secuencia de espacios por "_"); valida duplicados de CODIGO y NOMBRE activos antes de cada INSERT; los submenus llegan en un JSONB array y se procesan per-row (un error individual no aborta la lista, se reporta en status). Devuelve una fila por TMENU: la primera es el padre (pk_submenu=NULL, status ''parent_created''); las siguientes son los submenus (pk_padre=pk del padre, status ''submenu_inserted'' o ''submenu_error:<motivo>''). La vinculacion a un rol se hace en flujo aparte via fn_associate_menus_to_rol.';

COMMENT ON FUNCTION academico_test.fn_list_plans_from_value(BIGINT) IS
    'Lista los planes academicos activos definidos en la seccion CATEGORIA=''PLAN'' de academico_test.tlista_valor. REQUIERE p_user_pk (validado por fn_assert_superadmin). Pensada para alimentar el dropdown "Plan" de la pantalla "Agregar menu" de sso-admin (junto a Preescolar / Basico / Medio seedeados por V59). Solo lectura.';

COMMENT ON FUNCTION academico_test.fn_create_plan_from_value(BIGINT, VARCHAR) IS
    'Inserta un nuevo plan en la seccion CATEGORIA=''PLAN'' de academico_test.tlista_valor. REQUIERE p_user_pk (validado por fn_assert_superadmin). La UI recoge p_nombre del campo "Nombre del nuevo plan" del dropdown de sso-admin. El VALOR canonico se deriva del nombre (UPPER + reemplazo de cualquier secuencia de espacios por "_"); p_created_by se obtiene de CURRENT_USER (la sesion que ejecuta la operacion). Falla con RAISE EXCEPTION si ya existe un plan activo con el VALOR derivado (UNIQUE CATEGORIA+VALOR). Devuelve una fila (pk_lista_valor, nombre, valor, status=''inserted'').';

COMMENT ON FUNCTION academico_test.fn_delete_plan_from_value(BIGINT, VARCHAR) IS
    'Soft-delete (UPDATE active=FALSE) sobre un plan de la seccion CATEGORIA=''PLAN'' de academico_test.tlista_valor, recibido por nombre. REQUIERE p_user_pk (validado por fn_assert_superadmin). La UI conoce el plan que el admin va a retirar del dropdown; la funcion deriva el VALOR canonico (UPPER + reemplazo de espacios) para encontrarlo y desactivarlo (registra modified_by/at con CURRENT_USER). Conserva el historial. Devuelve pk_lista_valor, nombre y was_deleted (true solo si habia un plan activo con ese VALOR y se acaba de desactivar).';
