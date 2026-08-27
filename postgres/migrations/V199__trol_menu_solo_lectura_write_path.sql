-- ===========================================================================
-- V199 — write-path de TROL_MENU.SOLO_LECTURA: el admin decide, por menu de
-- un rol, si la concesion es completa o solo-lectura.
--
-- Que hace:
--   1. fn_associate_menus_to_rol: cambia el contrato de entrada de
--      p_pk_tmenus BIGINT[]  ->  p_menus JSONB con forma
--        [{"id": <bigint>, "soloLectura": <bool>}, ...]
--      y persiste ese "soloLectura" en academico_test.trol_menu.SOLO_LECTURA
--      ('SI' cuando soloLectura=true, NULL en caso contrario), tanto al
--      INSERT como al reactivar una fila previamente soft-deleted (se puede
--      promover o degradar el modo en cada request). El resto del contrato
--      (validaciones, ERRCODEs, mensajes, orden_rol por posicion, RETURNS
--      TABLE, modos incremental / p_full_replace) se conserva 1:1 respecto
--      a la version vigente (V123).
--   2. fn_list_menu_possibilities_for_rol: agrega la columna solo_lectura
--      BOOLEAN al final del RETURNS TABLE, poblada con
--      (tm.SOLO_LECTURA = 'SI') para los combos (rol, submenu) ya asignados
--      y FALSE para los no asignados. Es el GET de la matriz "Agregar menu".
--
-- Por que:
--   V198 agrego TROL_MENU.SOLO_LECTURA y enseño a
--   fn_usuario_permisos_menu(BIGINT) a derivar la concesion base de esa
--   columna, pero dejo el write-path sin cubrir: no habia forma de SETEAR
--   SOLO_LECTURA desde la pantalla de administracion de roles. Esta
--   migracion cierra ese hueco.
--
-- Relacion con V123 / V113 / V59 / V198:
--   * V59  (596)  define fn_associate_menus_to_rol con firma
--       (bigint, bigint, bigint[], varchar, bigint DEFAULT NULL)  -- p_pk_tplan
--     y fn_list_menu_possibilities_for_rol (bigint, bigint) con un
--     RETURNS TABLE mas chico (sin plan_id ni orden_rol).
--   * V113 (369)  hace DROP+CREATE de ambas: associate pasa a
--       (bigint, bigint, bigint[], varchar, boolean DEFAULT false)  -- p_full_replace
--     y possibilities gana plan_id + orden_rol. Usa INSERT ... ON CONFLICT.
--   * V123 (40)   CREATE OR REPLACE de associate: misma firma que V113
--     pero reemplaza el ON CONFLICT por "buscar-y-decidir" (SELECT + INSERT
--     o UPDATE) porque el indice util de trol_menu es PARCIAL (V71,
--     WHERE active = true) y ON CONFLICT no lo infiere. V199 PARTE de este
--     cuerpo — mantiene el buscar-y-decidir, no reintroduce ON CONFLICT.
--   * V198        agrego trol_menu.SOLO_LECTURA VARCHAR(5) y el consumo en
--     fn_usuario_permisos_menu. V199 es su write-path complementario;
--     encadenar los dos da el efecto punta a punta.
--
-- Cambio de tipo de parametro => DROP + CREATE (intencional):
--   CREATE OR REPLACE FUNCTION no puede cambiar el tipo de un parametro
--   (bigint[] -> jsonb) ni el RETURNS TABLE (agregar una columna) — Postgres
--   lo rechaza con 42P13 ("cannot change ... of existing function"). Por eso
--   este archivo hace DROP FUNCTION IF EXISTS con TIPOS EXPLICITOS de TODAS
--   las firmas historicas conocidas y luego CREATE OR REPLACE de la firma
--   nueva (asi la 2a corrida de la migracion no choca). Los DROP cuentan con el
--   server drift documentado en docs/etiqueta-catalogo-funciones-fn.md §17
--   ("Menus y roles — drift conocido"): prod (172.233.184.248) corre firmas
--   viejas de estas funciones (memoria "V59 server drift cleanup pending"),
--   asi que se listan tambien las variantes de V59 para que el DROP las
--   alcance sea cual sea el estado del entorno. IF EXISTS hace cada DROP
--   inofensivo donde la firma no exista.
--
-- Oracle-ismos (skill reviewing-oracle-to-postgres-migration):
--   * cadena vacia vs NULL en el cast de "soloLectura": se usa
--     COALESCE(NULLIF(elem->>'soloLectura','')::boolean, FALSE) — NULLIF
--     colapsa el string vacio a NULL ANTES del cast (un ''::boolean
--     reventaria con 22P02), y COALESCE cubre tanto la clave ausente
--     (elem->>'x' => NULL) como el JSON null.
--   * elem->>'soloLectura' puede venir ausente en cualquier elemento del
--     array -> tratado como FALSE (concesion completa), nunca como error.
--   * ningun ORDER BY nuevo dependiente de collation; sin UNION ALL; sin
--     vistas materializadas.
--
-- Idempotencia:
--   * DROP FUNCTION IF EXISTS (tipos explicitos, IF EXISTS) de las firmas
--     historicas + CREATE OR REPLACE de las nuevas -> reejecutable: en la
--     2a corrida los DROP no encuentran nada (NOTICE skip) y el
--     CREATE OR REPLACE reescribe la funcion ya existente sin error.
--   * COMMENT ON FUNCTION reejecutable.
--   * No toca datos de trol_menu salvo via las funciones (que no corren en
--     la migracion).
--   * NO toca el seed de public.query / role_query de /roles/:roleId/menus
--     (vive fuera de Flyway, se ajusta aparte).
-- ===========================================================================

SET search_path TO academico_test, public;

-- ---------------------------------------------------------------------------
-- Limpieza de firmas historicas. Tipos explicitos, IF EXISTS.
-- ---------------------------------------------------------------------------
-- fn_associate_menus_to_rol
DROP FUNCTION IF EXISTS academico_test.fn_associate_menus_to_rol(bigint, bigint, bigint[], character varying, bigint);   -- V59  (p_pk_tplan)
DROP FUNCTION IF EXISTS academico_test.fn_associate_menus_to_rol(bigint, bigint, bigint[], character varying, boolean);  -- V113 / V123 (p_full_replace)
DROP FUNCTION IF EXISTS academico_test.fn_associate_menus_to_rol(bigint, bigint, bigint[], character varying);           -- por si algun entorno quedo sin 5o param
-- fn_list_menu_possibilities_for_rol (misma firma de parametros en V59 y
-- V113; el RETURNS TABLE cambia -> hace falta DROP igual)
DROP FUNCTION IF EXISTS academico_test.fn_list_menu_possibilities_for_rol(bigint, bigint);


-- ---------------------------------------------------------------------------
-- fn_associate_menus_to_rol — contrato JSONB con soloLectura por menu.
--
-- p_menus = [{"id": <bigint>, "soloLectura": <bool>}, ...]
--   * "id"          obligatorio en cada elemento.
--   * "soloLectura" opcional; ausente / null / '' => FALSE (concesion
--     completa, comportamiento historico). true => SOLO_LECTURA = 'SI'.
--
-- Modos (sin cambios respecto a V123):
--   * p_full_replace = FALSE (default): incremental. El array debe traer
--     >= 1 elemento. No toca lo que ya estaba asignado y no viene en la
--     lista.
--   * p_full_replace = TRUE: reemplazo completo (PUT /roles/{id}/menus).
--     El array puede venir vacio ("vaciar el menu del rol"). Todo lo que
--     estaba activo y no figura se soft-deletea (SIN tocar su SOLO_LECTURA).
--     Valida la invariante de jerarquia (un submenu implica su padre).
--
-- ERRCODEs / mensajes (identicos a V123):
--   * rol NULL / inexistente / inactivo -> 'P0002' (no_data_found -> 404).
--   * p_menus NULL o no-array           -> '22023' (invalid_parameter_value).
--   * array vacio en modo incremental   -> '22023'.
--   * elemento sin "id"                 -> '22023'.
--   * invariante de jerarquia rota      -> '22023'.
--   * p_created_by vacio                -> default (P0001 -> 400).
--   * menu per-row inexistente/inactivo -> NO aborta: fila con
--     status='menu_not_found_or_inactive'.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_associate_menus_to_rol(
    p_user_pk      BIGINT,
    p_pk_trol      BIGINT,
    p_menus        JSONB,
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
SET search_path TO 'academico_test', 'public'
AS $function$
DECLARE
    v_ids          BIGINT[];
    v_elem         JSONB;
    v_tmenu        BIGINT;
    v_solo_lectura BOOLEAN;
    v_sl_val       VARCHAR;
    v_idx          NUMERIC := 0;
    v_pk           BIGINT;
    v_now          TIMESTAMP := CURRENT_TIMESTAMP;
BEGIN
    PERFORM academico_test.fn_assert_superadmin(p_user_pk);

    IF p_pk_trol IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM academico_test.trol
            WHERE pk_trol = p_pk_trol AND active = TRUE
       )
    THEN
        -- roleId de la URL de PUT /roles/{roleId}/menus -- documentado como
        -- "404 { status: 'error' } si el rol no existe". ERRCODE='P0002'
        -- (no_data_found), el unico que PostgresErrorMapper traduce a 404.
        RAISE EXCEPTION 'fn_associate_menus_to_rol: TROL pk=% no existe o no esta activo', p_pk_trol
            USING ERRCODE = 'P0002';
    END IF;

    -- p_menus debe ser un array JSON. NULL o cualquier otro tipo -> 22023.
    IF p_menus IS NULL OR jsonb_typeof(p_menus) <> 'array' THEN
        RAISE EXCEPTION 'fn_associate_menus_to_rol: p_menus debe ser un array JSON [{"id":..,"soloLectura":..}], recibido: %', p_menus
            USING ERRCODE = '22023'; -- invalid_parameter_value
    END IF;

    -- El array puede venir vacio SOLO en modo full_replace (equivale a
    -- "vaciar el menu del rol"); en modo incremental debe traer algo.
    IF NOT p_full_replace AND jsonb_array_length(p_menus) = 0 THEN
        RAISE EXCEPTION 'fn_associate_menus_to_rol: p_menus debe contener al menos un elemento en modo incremental'
            USING ERRCODE = '22023';
    END IF;

    IF p_created_by IS NULL OR LENGTH(TRIM(p_created_by)) = 0 THEN
        RAISE EXCEPTION 'fn_associate_menus_to_rol: p_created_by es obligatorio';
    END IF;

    -- Cada elemento debe traer "id".
    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(p_menus) AS e
         WHERE (e->>'id') IS NULL
    ) THEN
        RAISE EXCEPTION 'fn_associate_menus_to_rol: cada elemento de p_menus debe traer "id"'
            USING ERRCODE = '22023';
    END IF;

    -- Set de ids del jsonb (para la invariante de jerarquia y el UPDATE del
    -- full_replace). COALESCE a '{}' cuando el array llega vacio.
    SELECT COALESCE(array_agg((e->>'id')::bigint), ARRAY[]::bigint[])
      INTO v_ids
      FROM jsonb_array_elements(p_menus) AS e;

    -- Invariante de jerarquia (solo tiene sentido en full_replace, que
    -- representa el estado FINAL completo del menu del rol): si un submenu
    -- esta en la lista, su padre tambien debe estarlo.
    IF p_full_replace AND EXISTS (
        SELECT 1
          FROM academico_test.tmenu m
         WHERE m.pk_tmenu = ANY(v_ids)
           AND m.fk_tmenu IS NOT NULL
           AND NOT (m.fk_tmenu = ANY(v_ids))
    ) THEN
        RAISE EXCEPTION 'fn_associate_menus_to_rol: hay submenus en p_menus sin su menu padre incluido (invariante de jerarquia)'
            USING ERRCODE = '22023';
    END IF;

    -- Modo reemplazo completo: desactiva todo lo que NO figure en la lista
    -- nueva. NOT (fk_tmenu = ANY('{}')) es TRUE para todas las filas cuando
    -- el array llega vacio, asi que un array vacio vacia el menu. NO toca
    -- SOLO_LECTURA de las filas que desactiva.
    IF p_full_replace THEN
        UPDATE academico_test.trol_menu tm
           SET active      = FALSE,
               modified_by = TRIM(p_created_by),
               modified_at = v_now
         WHERE tm.fk_trol = p_pk_trol
           AND tm.active  = TRUE
           AND NOT (tm.fk_tmenu = ANY(v_ids));
    END IF;

    -- Recorre los elementos EN ORDEN; orden_rol = posicion 1-based.
    FOR v_elem IN SELECT e FROM jsonb_array_elements(p_menus) AS e
    LOOP
        v_idx          := v_idx + 1;
        v_tmenu        := (v_elem->>'id')::bigint;
        -- '' -> NULL antes del cast; clave ausente / JSON null -> NULL;
        -- COALESCE final -> FALSE (concesion completa).
        v_solo_lectura := COALESCE(NULLIF(v_elem->>'soloLectura', '')::boolean, FALSE);
        v_sl_val       := CASE WHEN v_solo_lectura THEN 'SI' ELSE NULL END;

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

        -- Buscar-y-decidir en vez de INSERT ... ON CONFLICT (ver V123): el
        -- indice util de trol_menu es PARCIAL (V71, WHERE active = true) y
        -- ON CONFLICT no lo infiere. Se busca la fila del par (activa o no)
        -- y se reactiva o inserta segun corresponda.
        v_pk := NULL;

        SELECT tm.pk_trol_menu
          INTO v_pk
          FROM academico_test.trol_menu tm
         WHERE tm.fk_trol  = p_pk_trol
           AND tm.fk_tmenu = v_tmenu
         ORDER BY tm.active DESC, tm.pk_trol_menu
         LIMIT 1;

        IF v_pk IS NULL THEN
            INSERT INTO academico_test.trol_menu (
                fk_trol, fk_tmenu, orden_rol, active, created_by, solo_lectura
            )
            VALUES (
                p_pk_trol, v_tmenu, v_idx, TRUE, TRIM(p_created_by), v_sl_val
            )
            RETURNING academico_test.trol_menu.pk_trol_menu INTO v_pk;
            status := 'inserted';
        ELSE
            -- Reactivar (o actualizar si ya estaba activa): el SOLO_LECTURA
            -- del request MANDA — permite promover (NULL->'SI') o degradar
            -- ('SI'->NULL) el modo de la concesion.
            UPDATE academico_test.trol_menu tm
               SET active       = TRUE,
                   orden_rol    = v_idx,
                   solo_lectura = v_sl_val,
                   modified_by  = TRIM(p_created_by),
                   modified_at  = v_now
             WHERE tm.pk_trol_menu = v_pk;
            status := 'reactivated';
        END IF;

        pk_trol_menu := v_pk;
        RETURN NEXT;
    END LOOP;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_associate_menus_to_rol(BIGINT, BIGINT, JSONB, VARCHAR, BOOLEAN)
    IS 'Vincula TMENU a un TROL. Entrada p_menus JSONB = [{"id": <bigint>, "soloLectura": <bool>}, ...]: "id" obligatorio, "soloLectura" opcional (ausente/null/'''' => FALSE => concesion completa; true => trol_menu.SOLO_LECTURA = ''SI'' => el rol concede el menu solo para ver, lo consume fn_usuario_permisos_menu de V198). Persiste SOLO_LECTURA tanto al insertar como al reactivar una fila soft-deleted (se puede promover o degradar el modo en cada request). p_full_replace=FALSE (default): incremental, el array debe traer >=1 elemento. p_full_replace=TRUE: reemplazo completo (PUT /roles/{id}/menus), array vacio permitido, soft-deletea lo ausente SIN tocar su SOLO_LECTURA, valida la invariante de jerarquia. orden_rol = posicion 1-based en p_menus. Reemplaza el contrato bigint[] de V123/V113 (cambio de tipo de parametro => DROP+CREATE). ERRCODEs: rol inexistente/inactivo P0002 (404); p_menus NULL/no-array, array vacio incremental, elemento sin id, jerarquia rota => 22023; menu per-row inexistente => fila status=''menu_not_found_or_inactive'' sin abortar.';


-- ---------------------------------------------------------------------------
-- fn_list_menu_possibilities_for_rol — igual que V113 + columna solo_lectura.
--
-- Devuelve TODAS las combinaciones padre -> submenu del catalogo, marcadas
-- con ya_asignado + orden_rol + plan_id, y ahora tambien solo_lectura
-- BOOLEAN: (tm.SOLO_LECTURA = 'SI') para los combos (rol, submenu) ya
-- asignados, FALSE para el resto (incluye no asignados y asignados sin
-- SOLO_LECTURA). Es el GET de la matriz "Agregar menu". Solo 2 niveles.
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
    orden_rol       NUMERIC,
    solo_lectura    BOOLEAN
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
        -- 400 (no hay 404 real en PostgresErrorMapper de esta rama).
        -- ERRCODE='22023' (invalid_parameter_value), mismo tratamiento que
        -- el resto de referencias invalidas del archivo original (V113).
        RAISE EXCEPTION 'fn_list_menu_possibilities_for_rol: TROL pk=% no existe o no esta activo', p_pk_trol
            USING ERRCODE = '22023';
    END IF;

    RETURN QUERY
    SELECT
        padre.pk_tmenu                       AS pk_padre,
        padre.nombre                         AS nombre_padre,
        padre.icono                          AS icono_padre,
        padre.orden                          AS orden_padre,
        hijo.pk_tmenu                        AS pk_submenu,
        hijo.nombre                          AS nombre_submenu,
        hijo.url                             AS url,
        (hijo.visible = 'S')                 AS visible,
        hijo.orden                           AS orden_submenu,
        hijo.fk_tplan                        AS plan_id,
        (tm.pk_trol_menu IS NOT NULL)        AS ya_asignado,
        tm.orden_rol                         AS orden_rol,
        COALESCE(tm.solo_lectura = 'SI', FALSE) AS solo_lectura
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

COMMENT ON FUNCTION academico_test.fn_list_menu_possibilities_for_rol(BIGINT, BIGINT)
    IS 'GET de la matriz "Agregar menu": todas las combinaciones padre -> submenu del catalogo (2 niveles), con ya_asignado + orden_rol + plan_id (tmenu.fk_tplan) para los combos (rol, submenu) ya en trol_menu activo, y solo_lectura BOOLEAN = (trol_menu.SOLO_LECTURA = ''SI'') para esos mismos combos (FALSE para no asignados o asignados sin modo solo-lectura). Igual que la version de V113 mas la columna solo_lectura al final del RETURNS TABLE (agregar columna al retorno => DROP+CREATE). Autorizacion: fn_assert_superadmin. Rol inexistente/inactivo => ERRCODE 22023.';
