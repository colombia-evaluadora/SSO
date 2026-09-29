-- ===========================================================================
-- V113 - Gestion administrativa de TROL/TMENU/TLISTA_VALOR (academico_test)
-- servida por public.query. Quedan fn_assert_superadmin, fn_list_roles,
-- fn_add_trol + trigger de sincronizacion con public.role,
-- fn_list_menu_possibilities_for_rol, fn_dissociate_menus_from_rol,
-- fn_upsert_menu, las funciones de planes y las semillas de menu, ruta y rol.
-- fn_associate_menus_to_rol, fn_list_available_menus, fn_delete_menu y
-- fn_reorder_menus se reescribieron en V115, V123 y V498.
-- ===========================================================================


SET search_path TO academico_test, public;

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

INSERT INTO public.role (name, description)
SELECT 'CEVAL-SUPER_ADMINISTRADOR', 'Super Administrador del sistema academico (V113 seed)'
 WHERE NOT EXISTS (
       SELECT 1 FROM public.role WHERE name = 'CEVAL-SUPER_ADMINISTRADOR'
       );

ALTER TABLE academico_test.tmenu
ADD COLUMN IF NOT EXISTS fk_tplan BIGINT
    REFERENCES academico_test.tlista_valor(pk_lista_valor)
    ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_tmenu_fk_tplan
    ON academico_test.tmenu(fk_tplan)
    WHERE fk_tplan IS NOT NULL;

ALTER TABLE academico_test.trol_menu
ADD COLUMN IF NOT EXISTS orden_rol NUMERIC;

DROP FUNCTION IF EXISTS academico_test.fn_add_trol(BIGINT, VARCHAR, VARCHAR, VARCHAR);

DROP FUNCTION IF EXISTS academico_test.fn_list_menu_possibilities_for_rol(BIGINT, BIGINT);

DROP FUNCTION IF EXISTS academico_test.fn_list_plans_from_value(BIGINT);

DROP FUNCTION IF EXISTS academico_test.fn_create_plan_from_value(BIGINT, VARCHAR);

DROP FUNCTION IF EXISTS academico_test.fn_delete_plan_from_value(BIGINT, VARCHAR);

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
        tm.orden_rol                    AS orden_rol,
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
    type     VARCHAR,
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
    v_type       VARCHAR;

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
            -- El :ID de la URL de PATCH /menus/{id} no existe -- 404, no 400.
            -- roles-permisos.postman_collection.json lo documenta como
            -- "404 si el menu no existe". ERRCODE='P0002' (no_data_found) es
            -- el unico SQLSTATE de este archivo que PostgresErrorMapper
            -- traduce a 404 (ver nota del header sobre codigos de error).
            RAISE EXCEPTION 'fn_upsert_menu: TMENU pk=% no existe o no esta activo', p_pk_tmenu_editar
                USING ERRCODE = 'P0002';
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

        -- Reparent (opcional): SaveMenuRequest.idParent siempre viaja en el
        -- body de PATCH /menus/{id}, incluso sin cambiar de padre — asi que
        -- p_id_padre se usa aqui como "nuevo padre deseado" (NULL = mover a
        -- raiz), no como selector de modo (ese rol ya lo cumplio
        -- p_pk_tmenu_editar mas arriba). Tres validaciones antes de aplicar:
        IF p_id_padre IS NOT NULL THEN
            IF p_id_padre = p_pk_tmenu_editar THEN
                RAISE EXCEPTION 'fn_upsert_menu: un menu no puede ser su propio padre'
                    USING ERRCODE = '22023';
            END IF;
            IF NOT EXISTS (
                SELECT 1 FROM academico_test.tmenu m
                 WHERE m.pk_tmenu = p_id_padre AND m.active = TRUE AND m.fk_tmenu IS NULL
            ) THEN
                RAISE EXCEPTION 'fn_upsert_menu: el padre pk=% no existe, no esta activo o no es un menu raiz', p_id_padre
                    USING ERRCODE = '22023';
            END IF;
            IF EXISTS (
                SELECT 1 FROM academico_test.tmenu m
                 WHERE m.fk_tmenu = p_pk_tmenu_editar AND m.active = TRUE
            ) THEN
                -- Solo 2 niveles de jerarquia (V22): un menu que YA tiene
                -- hijos no puede convertirse el mismo en hijo de otro.
                RAISE EXCEPTION 'fn_upsert_menu: pk=% tiene submenus propios, no puede convertirse en submenu', p_pk_tmenu_editar
                    USING ERRCODE = '22023';
            END IF;
        END IF;

        UPDATE academico_test.tmenu m
           SET nombre      = v_nombre,
               codigo      = v_codigo,
               url         = p_url,
               icono       = p_icono,
               visible     = v_visible_ch,
               fk_tplan    = p_plan_id,
               fk_tmenu    = p_id_padre,
               modified_by = TRIM(p_created_by),
               modified_at = CURRENT_TIMESTAMP
         WHERE m.pk_tmenu = p_pk_tmenu_editar
        RETURNING m.pk_tmenu, m.fk_tmenu, m.nombre, m.url, m.icono, m.orden,
                  (m.visible = 'S'), m.fk_tplan,
                  (CASE WHEN m.fk_tmenu IS NULL THEN 'GROUP' ELSE 'ITEM' END)::VARCHAR
          INTO pk_tmenu, pk_padre, nombre, path, icono, orden, visible, plan_id, type;

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
                  (academico_test.tmenu.visible = 'S'), academico_test.tmenu.fk_tplan,
                  (CASE WHEN academico_test.tmenu.fk_tmenu IS NULL THEN 'GROUP' ELSE 'ITEM' END)::VARCHAR
          INTO pk_tmenu, pk_padre, nombre, path, icono, orden, visible, plan_id, type;

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
    type     := 'GROUP'; -- padre: fk_tmenu=NULL por definicion
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
            type     := NULL;
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
                      (academico_test.tmenu.visible = 'S'), academico_test.tmenu.fk_tplan,
                      (CASE WHEN academico_test.tmenu.fk_tmenu IS NULL THEN 'GROUP' ELSE 'ITEM' END)::VARCHAR
              INTO pk_tmenu, nombre, path, orden, visible, plan_id, type;

            status := 'submenu_inserted';
            RETURN NEXT;
        END LOOP;
    END IF;
END;
$$;

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

COMMENT ON FUNCTION academico_test.fn_assert_superadmin(BIGINT) IS
    'Helper interno de V113. Unico punto donde vive la regla "tener el rol CEVAL-SUPER_ADMINISTRADOR para ejecutar las funciones administrativas". Validacion por JOIN entre public.role_users (user_id=p_user_pk) y public.role (name=''CEVAL-SUPER_ADMINISTRADOR''). Cualquier pk sin ese rol (NULL incluida) dispara RAISE EXCEPTION con ERRCODE=''42501'' (insufficient_privilege -> 403).';

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

COMMENT ON FUNCTION academico_test.fn_dissociate_menus_from_rol(BIGINT, BIGINT, BIGINT[]) IS
    'Desvincula (soft-delete) TMENU puntuales de un rol sin afectar el resto. Utilidad de proposito general; PUT /roles/{roleId}/menus usa fn_associate_menus_to_rol(p_full_replace=TRUE) en su lugar.';

COMMENT ON FUNCTION academico_test.fn_upsert_menu(BIGINT, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, NUMERIC, BIGINT, BIGINT, BIGINT, JSONB) IS
    'Reemplaza a fn_create_parent_menu_with_submenus. Tres modos: EDITAR (p_pk_tmenu_editar IS NOT NULL -> PATCH /menus/{id}, UPDATE de una fila; p_id_padre actua como reparent — NULL mueve a raiz, un pk valido mueve bajo ese padre, rechazado si crea 3 niveles o auto-referencia); HIJO BAJO PADRE EXISTENTE (p_pk_tmenu_editar NULL + p_id_padre IS NOT NULL -> POST /menus con idParent, INSERT de un submenu); RAIZ (ambos NULL, default -> POST /menus con idParent=null, INSERT de un menu raiz, +/- batch de p_submenus JSONB para el flujo historico "Crear nuevo menu principal"). p_plan_id (o "plan_id" por submenu) se valida contra tlista_valor CATEGORIA=''PLAN'' y se persiste en tmenu.fk_tplan. Devuelve SIEMPRE la columna TYPE (''GROUP'' si fk_tmenu IS NULL, ''ITEM'' si no) — el contrato MenuDto.type es obligatorio, y el SELECT de los tres modos + el bucle de submenus lo calculan explicitamente (antes del fix 2026-08-14 solo lo retornaba fn_list_available_menus). Duplicado de codigo -> ERRCODE=''23505'' (409); referencias invalidas (padre/plan/menu inexistente, auto-referencia, 3er nivel) -> ERRCODE=''22023'' (400); menu a editar ausente/inactivo -> ERRCODE=''P0002'' (404). REQUIERE p_user_pk (fn_assert_superadmin).';

COMMENT ON FUNCTION academico_test.fn_list_plans_from_value(BIGINT) IS
    'GET /plans -> PlanDto[]. Planes activos de tlista_valor CATEGORIA=''PLAN''. REQUIERE p_user_pk (fn_assert_superadmin).';

COMMENT ON FUNCTION academico_test.fn_create_plan_from_value(BIGINT, VARCHAR) IS
    'POST /plans -> PlanDto. p_created_by se deriva de CURRENT_USER. VALOR canonico derivado del nombre. Duplicado -> RAISE USING ERRCODE=''23505'' (409 Conflict). REQUIERE p_user_pk (fn_assert_superadmin).';

COMMENT ON FUNCTION academico_test.fn_delete_plan_from_value(BIGINT, VARCHAR) IS
    'Soft-delete por nombre sobre tlista_valor CATEGORIA=''PLAN''. Sin endpoint documentado todavia; utilidad general. REQUIERE p_user_pk (fn_assert_superadmin).';
