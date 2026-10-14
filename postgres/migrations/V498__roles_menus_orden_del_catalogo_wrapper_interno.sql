-- El menu de un rol es un CONJUNTO ordenado como el catalogo (tmenu.orden).
-- Funciones de la pantalla roles-menus en wrapper (gate + auditoria) y nucleo
-- _interno. Los permisos del rol se escriben y leen en TROL_MENU_PERMISO.
-- Depende de: V113, V123/V198, V99 (SOLO_LECTURA y TROL_MENU_PERMISO), V66, V215.

SET search_path TO academico_test, public;

-- ---------------------------------------------------------------------------
-- Validaciones
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_trol_validar_activo(p_pk_trol BIGINT)
RETURNS VOID
LANGUAGE plpgsql
STABLE
SET search_path = academico_test, public
AS $$
BEGIN
    IF p_pk_trol IS NULL OR NOT EXISTS (
        SELECT 1 FROM academico_test.trol WHERE pk_trol = p_pk_trol AND active = TRUE
    ) THEN
        RAISE EXCEPTION 'El rol pk=% no existe o no esta activo', p_pk_trol
            USING ERRCODE = 'P0002';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_trol_validar_activo(BIGINT)
    IS 'INTERNO: P0002 si el TROL no existe o esta inactivo. Lo usa fn_rol_menus_asignar_interno (PUT /roles/:ROLEID/menus).';

CREATE OR REPLACE FUNCTION academico_test.fn_menus_validar_lista(p_items JSONB, p_permite_vacia BOOLEAN)
RETURNS VOID
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
        RAISE EXCEPTION 'Se esperaba un array JSON de menus [{"id":..}], recibido: %', p_items
            USING ERRCODE = '22023';
    END IF;
    IF NOT p_permite_vacia AND jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'La lista de menus no puede venir vacia'
            USING ERRCODE = '22023';
    END IF;
    -- 12 y "12" valen (el cast historico aceptaba ambos); null, "abc" y 1.5 no.
    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(p_items) e
         WHERE (e ->> 'id') IS NULL OR (e ->> 'id') !~ '^[0-9]+$'
    ) THEN
        RAISE EXCEPTION 'Cada elemento de la lista de menus debe traer un "id" entero'
            USING ERRCODE = '22023';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_menus_validar_lista(JSONB, BOOLEAN)
    IS 'INTERNO: 22023 si p_items no es un array JSON, llega vacio sin p_permite_vacia, o algun elemento no trae "id" entero. Compartido por la asignacion de menus a un rol y el reordenamiento del catalogo.';

CREATE OR REPLACE FUNCTION academico_test.fn_rol_menus_validar_jerarquia(p_ids BIGINT[])
RETURNS VOID
LANGUAGE plpgsql
STABLE
SET search_path = academico_test, public
AS $$
DECLARE
    v_huerfano VARCHAR;
BEGIN
    SELECT m.nombre INTO v_huerfano
      FROM academico_test.tmenu m
     WHERE m.pk_tmenu = ANY(p_ids)
       AND m.fk_tmenu IS NOT NULL
       AND NOT (m.fk_tmenu = ANY(p_ids))
     LIMIT 1;

    IF v_huerfano IS NOT NULL THEN
        RAISE EXCEPTION 'El submenu "%" viene sin su menu padre (invariante de jerarquia)', v_huerfano
            USING ERRCODE = '22023';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_rol_menus_validar_jerarquia(BIGINT[])
    IS 'INTERNO: 22023 si algun submenu del conjunto llega sin su padre. Se valida sobre el estado FINAL del menu de un rol (reemplazo completo).';

CREATE OR REPLACE FUNCTION academico_test.fn_menus_validar_hermanos(p_ids BIGINT[])
RETURNS VOID
LANGUAGE plpgsql
STABLE
SET search_path = academico_test, public
AS $$
BEGIN
    IF (SELECT COUNT(DISTINCT COALESCE(m.fk_tmenu, -1))
          FROM academico_test.tmenu m
         WHERE m.pk_tmenu = ANY(p_ids)) > 1
    THEN
        RAISE EXCEPTION 'Todos los menus a reordenar deben ser hermanos (mismo padre)'
            USING ERRCODE = '22023';
    END IF;

    IF (SELECT COUNT(*) FROM academico_test.tmenu m
         WHERE m.pk_tmenu = ANY(p_ids) AND m.active = TRUE AND m.estado = 'A')
       <> cardinality(p_ids)
    THEN
        RAISE EXCEPTION 'Alguno de los menus a reordenar no existe o no esta activo'
            USING ERRCODE = 'P0002';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_menus_validar_hermanos(BIGINT[])
    IS 'INTERNO: 22023 si los ids (sin repetidos) no comparten padre; P0002 si alguno no existe o esta inactivo.';

-- ---------------------------------------------------------------------------
-- Nucleos
-- ---------------------------------------------------------------------------

-- Solo menus con toda su cadena de ancestros activa, en orden de arbol
-- (menuOrder, pk desde la raiz); menuOrder NULL va al final de sus hermanos.
CREATE OR REPLACE FUNCTION academico_test.fn_menu_catalogo_listar_interno()
RETURNS TABLE (
    pk_tmenu BIGINT,
    pk_padre BIGINT,
    nombre   VARCHAR,
    url      VARCHAR,
    icono    VARCHAR,
    visible  BOOLEAN,
    orden    NUMERIC,
    plan_id  BIGINT,
    type     VARCHAR,
    posicion BIGINT
)
LANGUAGE sql
STABLE
SET search_path = academico_test, public
AS $$
    WITH RECURSIVE vivos AS (
        SELECT r.pk_tmenu, ARRAY[COALESCE(r.orden, 1e18), r.pk_tmenu]::NUMERIC[] AS camino
          FROM academico_test.tmenu r
         WHERE r.estado = 'A' AND r.active = TRUE AND r.fk_tmenu IS NULL
      UNION ALL
        SELECT h.pk_tmenu, v.camino || ARRAY[COALESCE(h.orden, 1e18), h.pk_tmenu]::NUMERIC[]
          FROM academico_test.tmenu h
          JOIN vivos v ON h.fk_tmenu = v.pk_tmenu
         WHERE h.estado = 'A' AND h.active = TRUE
    )
    CYCLE pk_tmenu SET es_ciclo USING ruta
    SELECT m.pk_tmenu,
           m.fk_tmenu,
           m.nombre,
           m.url,
           m.icono,
           (m.visible = 'S'),
           m.orden,
           m.fk_tplan,
           (CASE WHEN m.fk_tmenu IS NULL THEN 'GROUP' ELSE 'ITEM' END)::VARCHAR,
           ROW_NUMBER() OVER (ORDER BY v.camino)
      FROM vivos v
      JOIN academico_test.tmenu m ON m.pk_tmenu = v.pk_tmenu
     WHERE NOT v.es_ciclo
     ORDER BY 10;
$$;

COMMENT ON FUNCTION academico_test.fn_menu_catalogo_listar_interno()
    IS 'INTERNO: catalogo activo de TMENU en orden de arbol (posicion 1..n). Unica fuente del orden: la usan GET /menus (fn_list_available_menus) y GET /roles/:ROLEID/menus (fn_rol_menus_listar_interno).';

-- Catalogo de la pestana Modulos y submodulos: tambien los inactivos (estado
-- 'I'), que siguen listados con su estado; los dados de baja (active) no.
CREATE OR REPLACE FUNCTION academico_test.fn_menu_catalogo_admin_listar_interno()
RETURNS TABLE (
    pk_tmenu BIGINT,
    pk_padre BIGINT,
    nombre   VARCHAR,
    url      VARCHAR,
    icono    VARCHAR,
    visible  BOOLEAN,
    orden    NUMERIC,
    plan_id  BIGINT,
    type     VARCHAR,
    activo   BOOLEAN,
    en_uso   BOOLEAN,
    posicion BIGINT
)
LANGUAGE sql
STABLE
SET search_path = academico_test, public
AS $$
    WITH RECURSIVE arbol AS (
        SELECT r.pk_tmenu, ARRAY[COALESCE(r.orden, 1e18), r.pk_tmenu]::NUMERIC[] AS camino
          FROM academico_test.tmenu r
         WHERE r.active = TRUE AND r.fk_tmenu IS NULL
      UNION ALL
        SELECT h.pk_tmenu, a.camino || ARRAY[COALESCE(h.orden, 1e18), h.pk_tmenu]::NUMERIC[]
          FROM academico_test.tmenu h
          JOIN arbol a ON h.fk_tmenu = a.pk_tmenu
         WHERE h.active = TRUE
    )
    CYCLE pk_tmenu SET es_ciclo USING ruta
    SELECT m.pk_tmenu,
           m.fk_tmenu,
           m.nombre,
           m.url,
           m.icono,
           (m.visible = 'S'),
           m.orden,
           m.fk_tplan,
           (CASE WHEN m.fk_tmenu IS NULL THEN 'GROUP' ELSE 'ITEM' END)::VARCHAR,
           (m.estado = 'A'),
           EXISTS (SELECT 1 FROM academico_test.trol_menu tm
                    WHERE tm.fk_tmenu = m.pk_tmenu AND tm.active = TRUE),
           ROW_NUMBER() OVER (ORDER BY a.camino)
      FROM arbol a
      JOIN academico_test.tmenu m ON m.pk_tmenu = a.pk_tmenu
     WHERE NOT a.es_ciclo
     ORDER BY 12;
$$;

COMMENT ON FUNCTION academico_test.fn_menu_catalogo_admin_listar_interno()
    IS 'INTERNO: catalogo de TMENU no dado de baja (active), activos e inactivos, en orden de arbol, con activo (estado = A) y en_uso (asignado a algun rol). Lo usa GET /menus/catalogo.';

CREATE OR REPLACE FUNCTION academico_test.fn_menu_estado_cambiar_interno(
    p_pk_tmenu       BIGINT,
    p_activo         BOOLEAN,
    p_modificado_por VARCHAR
)
RETURNS VOID
LANGUAGE plpgsql
VOLATILE
SET search_path = academico_test, public
AS $$
BEGIN
    IF p_activo IS NULL THEN
        RAISE EXCEPTION 'Indique si el menu queda activo o inactivo' USING ERRCODE = '22023';
    END IF;

    -- Solo el menu: sus submenus conservan su estado y dejan de mostrarse
    -- mientras el padre este inactivo.
    UPDATE academico_test.tmenu m
       SET estado      = CASE WHEN p_activo THEN 'A' ELSE 'I' END,
           modified_by = TRIM(p_modificado_por),
           modified_at = CURRENT_TIMESTAMP
     WHERE m.pk_tmenu = p_pk_tmenu
       AND m.active   = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El menu pk=% no existe', p_pk_tmenu USING ERRCODE = 'P0002';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_menu_estado_cambiar_interno(BIGINT, BOOLEAN, VARCHAR)
    IS 'INTERNO: activa o inactiva un menu (estado A/I) sin tocar el de sus submenus. P0002 si no existe o esta dado de baja. Lo usa PUT /menus/:ID/estado.';

-- Cambia el RETURNS TABLE: se sueltan wrapper y nucleo antes de recrearlos.
DROP FUNCTION IF EXISTS academico_test.fn_rol_menus_listar(BIGINT, BIGINT);
DROP FUNCTION IF EXISTS academico_test.fn_rol_menus_listar_interno(BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_rol_menus_listar_interno(p_pk_trol BIGINT)
RETURNS TABLE (id BIGINT, solo_lectura BOOLEAN, guardar BOOLEAN, eliminar BOOLEAN)
LANGUAGE sql
STABLE
SET search_path = academico_test, public
AS $$
    SELECT c.pk_tmenu,
           NOT COALESCE(bool_or(p.crear OR p.editar OR p.eliminar), FALSE),
           COALESCE(bool_or(p.crear OR p.editar), FALSE),
           COALESCE(bool_or(p.eliminar), FALSE)
      FROM academico_test.fn_menu_catalogo_listar_interno() c
      JOIN academico_test.trol_menu tm
        ON tm.fk_tmenu = c.pk_tmenu
       AND tm.fk_trol  = p_pk_trol
       AND tm.active   = TRUE
      LEFT JOIN academico_test.trol_menu_permiso p
        ON p.fk_trol_menu = tm.pk_trol_menu
     GROUP BY c.pk_tmenu, c.posicion
     ORDER BY c.posicion;
$$;

COMMENT ON FUNCTION academico_test.fn_rol_menus_listar_interno(BIGINT)
    IS 'INTERNO: menus activos asignados a un TROL con sus permisos (TROL_MENU_PERMISO): guardar = crear o editar, eliminar, y solo_lectura = ninguno de los tres. Orden del catalogo. Lo usa GET /roles/:ROLEID/menus.';

CREATE OR REPLACE FUNCTION academico_test.fn_rol_funcionarios_contar_interno(p_pk_trol BIGINT)
RETURNS BIGINT
LANGUAGE sql
STABLE
SET search_path = academico_test, public
AS $$
    SELECT COUNT(DISTINCT su.fk_tusuario)
      FROM academico_test.tsede_usuario su
      JOIN academico_test.tusuario u ON u.pk_tusuario = su.fk_tusuario
     WHERE su.fk_trol = p_pk_trol
       AND su.active  = TRUE
       AND u.active   = TRUE
       AND u.estado   = 'A';
$$;

COMMENT ON FUNCTION academico_test.fn_rol_funcionarios_contar_interno(BIGINT)
    IS 'INTERNO: personas distintas con una asignacion activa (TSEDE_USUARIO) del rol, en cualquier sede y establecimiento, con el usuario activo. Lo usa GET /roles/:ROLEID/funcionarios/total.';

-- Payload a filas; sin guardar/eliminar se derivan de soloLectura (payload viejo).
CREATE OR REPLACE FUNCTION academico_test.fn_rol_menus_items(p_menus JSONB)
RETURNS TABLE (id BIGINT, guardar BOOLEAN, eliminar BOOLEAN)
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT (e ->> 'id')::BIGINT,
           COALESCE(NULLIF(e ->> 'guardar', '')::BOOLEAN, NOT s.solo),
           COALESCE(NULLIF(e ->> 'eliminar', '')::BOOLEAN, NOT s.solo)
      FROM jsonb_array_elements(p_menus) e
     CROSS JOIN LATERAL (
           SELECT COALESCE(NULLIF(e ->> 'soloLectura', '')::BOOLEAN, FALSE) AS solo
     ) s;
$$;

COMMENT ON FUNCTION academico_test.fn_rol_menus_items(JSONB)
    IS 'INTERNO: convierte p_menus=[{"id","guardar","eliminar"} | {"id","soloLectura"}] en filas (id, guardar, eliminar). Lo usa fn_rol_menus_asignar_interno.';

-- Conjunto: un id repetido cuenta una vez; con permisos distintos se rechaza.
CREATE OR REPLACE FUNCTION academico_test.fn_rol_menus_asignar_interno(
    p_pk_trol        BIGINT,
    p_menus          JSONB,
    p_modificado_por VARCHAR,
    p_full_replace   BOOLEAN DEFAULT FALSE
)
RETURNS TABLE (pk_tmenu BIGINT, pk_trol_menu BIGINT, status VARCHAR)
LANGUAGE plpgsql
VOLATILE
SET search_path = academico_test, public
AS $$
DECLARE
    v_ids  BIGINT[];
    v_item RECORD;
    v_pk   BIGINT;
    v_now  TIMESTAMP := CURRENT_TIMESTAMP;
BEGIN
    PERFORM academico_test.fn_trol_validar_activo(p_pk_trol);
    PERFORM academico_test.fn_menus_validar_lista(p_menus, p_full_replace);

    IF p_modificado_por IS NULL OR LENGTH(TRIM(p_modificado_por)) = 0 THEN
        RAISE EXCEPTION 'El usuario que modifica es obligatorio' USING ERRCODE = '22023';
    END IF;

    IF EXISTS (
        SELECT 1 FROM academico_test.fn_rol_menus_items(p_menus) i
         GROUP BY i.id
        HAVING COUNT(DISTINCT (i.guardar, i.eliminar)) > 1
    ) THEN
        RAISE EXCEPTION 'Un mismo menu viene repetido con permisos distintos'
            USING ERRCODE = '22023';
    END IF;

    SELECT COALESCE(array_agg(DISTINCT i.id), ARRAY[]::BIGINT[])
      INTO v_ids
      FROM academico_test.fn_rol_menus_items(p_menus) i;

    IF p_full_replace THEN
        PERFORM academico_test.fn_rol_menus_validar_jerarquia(v_ids);

        -- Los recortes por funcionario de un menu quitado caen con el: si no,
        -- reaparecen cuando se vuelve a asignar el menu.
        WITH bajas AS (
            UPDATE academico_test.trol_menu tm
               SET active      = FALSE,
                   modified_by = TRIM(p_modificado_por),
                   modified_at = v_now
             WHERE tm.fk_trol = p_pk_trol
               AND tm.active  = TRUE
               AND NOT (tm.fk_tmenu = ANY(v_ids))
            RETURNING tm.pk_trol_menu
        )
        UPDATE academico_test.tusuario_rol_permiso p
           SET active      = FALSE,
               modified_by = TRIM(p_modificado_por),
               modified_at = v_now
          FROM bajas b
         WHERE p.fk_trol_menu = b.pk_trol_menu
           AND p.active       = TRUE;
    END IF;

    FOR v_item IN
        SELECT DISTINCT ON (i.id) i.id, i.guardar, i.eliminar,
               CASE WHEN NOT (i.guardar OR i.eliminar) THEN 'SI' END AS solo_lectura
          FROM academico_test.fn_rol_menus_items(p_menus) i
         ORDER BY i.id
    LOOP
        pk_tmenu     := v_item.id;
        pk_trol_menu := NULL;

        IF NOT EXISTS (
            SELECT 1 FROM academico_test.tmenu m
             WHERE m.pk_tmenu = v_item.id AND m.active = TRUE AND m.estado = 'A'
        ) THEN
            status := 'menu_not_found_or_inactive';
            RETURN NEXT;
            CONTINUE;
        END IF;

        -- Sin ON CONFLICT: el unico de trol_menu es parcial (WHERE active).
        SELECT tm.pk_trol_menu INTO v_pk
          FROM academico_test.trol_menu tm
         WHERE tm.fk_trol = p_pk_trol AND tm.fk_tmenu = v_item.id
         ORDER BY tm.active DESC, tm.pk_trol_menu
         LIMIT 1;

        IF v_pk IS NULL THEN
            INSERT INTO academico_test.trol_menu (fk_trol, fk_tmenu, active, created_by, solo_lectura)
            VALUES (p_pk_trol, v_item.id, TRUE, TRIM(p_modificado_por), v_item.solo_lectura)
            RETURNING academico_test.trol_menu.pk_trol_menu INTO v_pk;
            status := 'inserted';
        ELSE
            -- orden_rol NULL: manda el orden del catalogo.
            UPDATE academico_test.trol_menu tm
               SET active       = TRUE,
                   orden_rol    = NULL,
                   solo_lectura = v_item.solo_lectura,
                   modified_by  = TRIM(p_modificado_por),
                   modified_at  = v_now
             WHERE tm.pk_trol_menu = v_pk;
            status := 'reactivated';
        END IF;

        -- Despues del trigger de SOLO_LECTURA: guardar y eliminar por separado.
        UPDATE academico_test.trol_menu_permiso p
           SET ver         = TRUE,
               crear       = v_item.guardar,
               editar      = v_item.guardar,
               eliminar    = v_item.eliminar,
               modified_by = TRIM(p_modificado_por),
               modified_at = v_now
         WHERE p.fk_trol_menu = v_pk;

        pk_trol_menu := v_pk;
        RETURN NEXT;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_rol_menus_asignar_interno(BIGINT, JSONB, VARCHAR, BOOLEAN)
    IS 'INTERNO: asigna a un TROL el CONJUNTO p_menus=[{"id","guardar","eliminar"}] (o {"id","soloLectura"}, de donde se derivan) y escribe TROL_MENU_PERMISO: guardar = crear y editar. Orden ignorado, repetidos cuentan una vez. p_full_replace=TRUE da de baja lo ausente y exige la jerarquia completa. Menu inexistente => status=menu_not_found_or_inactive sin abortar. Lo usa PUT /roles/:ROLEID/menus (fn_associate_menus_to_rol).';

CREATE OR REPLACE FUNCTION academico_test.fn_menus_reordenar_interno(
    p_items          JSONB,
    p_modificado_por VARCHAR
)
RETURNS TABLE (pk_tmenu BIGINT, orden NUMERIC)
LANGUAGE plpgsql
VOLATILE
SET search_path = academico_test, public
AS $$
DECLARE
    v_ids BIGINT[];
BEGIN
    PERFORM academico_test.fn_menus_validar_lista(p_items, FALSE);

    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(p_items) e
         WHERE (e ->> 'menuOrder') IS NULL OR (e ->> 'menuOrder') !~ '^-?[0-9]+(\.[0-9]+)?$'
    ) THEN
        RAISE EXCEPTION 'Cada elemento debe traer un "menuOrder" numerico' USING ERRCODE = '22023';
    END IF;

    SELECT array_agg((e ->> 'id')::BIGINT) INTO v_ids FROM jsonb_array_elements(p_items) e;

    -- Un id repetido haria que el UPDATE ... FROM eligiera un menuOrder al azar.
    IF cardinality(v_ids) <> (SELECT COUNT(DISTINCT x) FROM unnest(v_ids) x) THEN
        RAISE EXCEPTION 'Un mismo menu viene repetido en el reordenamiento' USING ERRCODE = '22023';
    END IF;

    PERFORM academico_test.fn_menus_validar_hermanos(v_ids);

    RETURN QUERY
    UPDATE academico_test.tmenu m
       SET orden       = (e ->> 'menuOrder')::NUMERIC,
           modified_by = COALESCE(NULLIF(TRIM(p_modificado_por), ''), m.modified_by),
           modified_at = CURRENT_TIMESTAMP
      FROM jsonb_array_elements(p_items) e
     WHERE m.pk_tmenu = (e ->> 'id')::BIGINT
    RETURNING m.pk_tmenu, m.orden;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_menus_reordenar_interno(JSONB, VARCHAR)
    IS 'INTERNO: fija tmenu.orden de un grupo de hermanos, p_items=[{"id","menuOrder"}]. 22023 lista invalida/repetidos/no hermanos, P0002 id inexistente. Lo usa PUT /menus/order (fn_reorder_menus).';

-- ---------------------------------------------------------------------------
-- Wrappers (gate + etiqueta). fn_reorder_menus recibe el correo del actor,
-- con DEFAULT para la llamada de 2 argumentos cacheada en query-service.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_list_available_menus(p_user_pk BIGINT)
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
    SELECT c.pk_tmenu, c.pk_padre, c.nombre, c.url, c.icono,
           c.visible, c.orden, c.plan_id, c.type
      FROM academico_test.fn_menu_catalogo_listar_interno() c
     ORDER BY c.posicion;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_list_available_menus(BIGINT)
    IS 'GET /menus: catalogo completo de menus (MenuNode[]) en orden de arbol, sin filtrar por rol. Gate fn_assert_superadmin; el catalogo lo arma fn_menu_catalogo_listar_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_menu_catalogo_admin_listar(p_user_pk BIGINT)
RETURNS TABLE (
    pk_tmenu BIGINT,
    pk_padre BIGINT,
    nombre   VARCHAR,
    url      VARCHAR,
    icono    VARCHAR,
    visible  BOOLEAN,
    orden    NUMERIC,
    plan_id  BIGINT,
    type     VARCHAR,
    activo   BOOLEAN,
    en_uso   BOOLEAN
)
LANGUAGE plpgsql
STABLE
SET search_path = academico_test, public
AS $$
BEGIN
    PERFORM academico_test.fn_assert_superadmin(p_user_pk);

    RETURN QUERY
    SELECT c.pk_tmenu, c.pk_padre, c.nombre, c.url, c.icono, c.visible,
           c.orden, c.plan_id, c.type, c.activo, c.en_uso
      FROM academico_test.fn_menu_catalogo_admin_listar_interno() c
     ORDER BY c.posicion;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_menu_catalogo_admin_listar(BIGINT)
    IS 'GET /menus/catalogo: catalogo de menus para la pestana Modulos y submodulos, con inactivos, activo y enUso. Gate fn_assert_superadmin. Nucleo fn_menu_catalogo_admin_listar_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_menu_estado_cambiar(
    p_user_pk        BIGINT,
    p_pk_tmenu       BIGINT,
    p_activo         BOOLEAN,
    p_modificado_por VARCHAR
)
RETURNS TABLE (status VARCHAR, message VARCHAR)
LANGUAGE plpgsql
VOLATILE
SET search_path = academico_test, public
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM academico_test.tmenu m
                    WHERE m.pk_tmenu = p_pk_tmenu AND m.active = TRUE) THEN
        RAISE EXCEPTION 'El menu pk=% no existe', p_pk_tmenu USING ERRCODE = 'P0002';
    END IF;

    PERFORM academico_test.fn_assert_superadmin(p_user_pk);

    PERFORM academico_test.fn_audit_declarar(
        public.fn_get_academico_usuario_id(p_user_pk),
        CASE WHEN p_activo THEN 'Activacion' ELSE 'Inactivacion' END || ' del menu '
            || (SELECT m.nombre FROM academico_test.tmenu m WHERE m.pk_tmenu = p_pk_tmenu),
        NULL, NULL, ARRAY['ROLES_MENUS']);

    PERFORM academico_test.fn_menu_estado_cambiar_interno(p_pk_tmenu, p_activo, p_modificado_por);

    RETURN QUERY SELECT 'success'::VARCHAR,
                        (CASE WHEN p_activo THEN 'Menu activado' ELSE 'Menu inactivado' END)::VARCHAR;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_menu_estado_cambiar(BIGINT, BIGINT, BOOLEAN, VARCHAR)
    IS 'PUT /menus/:ID/estado: activa o inactiva un menu, body {activo}. Respuesta {status, message}. P0002 si no existe, gate fn_assert_superadmin, 22023 si falta activo. Nucleo fn_menu_estado_cambiar_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_rol_menus_listar(p_user_pk BIGINT, p_pk_trol BIGINT)
RETURNS TABLE (id BIGINT, solo_lectura BOOLEAN, guardar BOOLEAN, eliminar BOOLEAN)
LANGUAGE plpgsql
STABLE
SET search_path = academico_test, public
AS $$
BEGIN
    PERFORM academico_test.fn_assert_superadmin(p_user_pk);

    RETURN QUERY SELECT r.id, r.solo_lectura, r.guardar, r.eliminar
                   FROM academico_test.fn_rol_menus_listar_interno(p_pk_trol) r;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_rol_menus_listar(BIGINT, BIGINT)
    IS 'GET /roles/:ROLEID/menus: menus asignados a un rol (RoleMenuAssignment {id, soloLectura, guardar, eliminar}) en el orden del catalogo; [] si el rol no existe o no tiene menus. Gate fn_assert_superadmin. Nucleo fn_rol_menus_listar_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_rol_funcionarios_contar(p_user_pk BIGINT, p_pk_trol BIGINT)
RETURNS TABLE (total BIGINT)
LANGUAGE plpgsql
STABLE
SET search_path = academico_test, public
AS $$
BEGIN
    PERFORM academico_test.fn_assert_superadmin(p_user_pk);

    RETURN QUERY SELECT academico_test.fn_rol_funcionarios_contar_interno(p_pk_trol);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_rol_funcionarios_contar(BIGINT, BIGINT)
    IS 'GET /roles/:ROLEID/funcionarios/total: cuantos funcionarios tienen el rol, para la confirmacion de quitar permisos. Mismo gate que el resto de la pantalla roles-menus (fn_assert_superadmin). Nucleo fn_rol_funcionarios_contar_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_associate_menus_to_rol(
    p_user_pk      BIGINT,
    p_pk_trol      BIGINT,
    p_menus        JSONB,
    p_created_by   VARCHAR,
    p_full_replace BOOLEAN DEFAULT FALSE
)
RETURNS TABLE (pk_tmenu BIGINT, pk_trol_menu BIGINT, orden_rol NUMERIC, status VARCHAR)
LANGUAGE plpgsql
VOLATILE
SET search_path = academico_test, public
AS $$
BEGIN
    PERFORM academico_test.fn_assert_superadmin(p_user_pk);

    PERFORM academico_test.fn_audit_declarar(
        public.fn_get_academico_usuario_id(p_user_pk),
        'Actualizacion de los menus del rol '
            || COALESCE((SELECT r.nombre FROM academico_test.trol r WHERE r.pk_trol = p_pk_trol),
                        p_pk_trol::TEXT),
        NULL, NULL, ARRAY['ROLES_MENUS']);

    -- orden_rol se mantiene en el RETURNS TABLE solo por compatibilidad de firma.
    RETURN QUERY
    SELECT a.pk_tmenu, a.pk_trol_menu, NULL::NUMERIC, a.status
      FROM academico_test.fn_rol_menus_asignar_interno(
               p_pk_trol, p_menus, p_created_by, p_full_replace) a;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_associate_menus_to_rol(BIGINT, BIGINT, JSONB, VARCHAR, BOOLEAN)
    IS 'PUT /roles/:ROLEID/menus: asigna el conjunto de menus de un rol, body {menus:[{id,soloLectura}]} (orden ignorado). Gate fn_assert_superadmin + etiqueta de auditoria; la logica vive en fn_rol_menus_asignar_interno. orden_rol sale siempre NULL. ERRCODEs: P0002 rol inexistente, 22023 lista invalida/jerarquia rota/repetido ambiguo, 42501 sin permiso.';

DROP FUNCTION IF EXISTS academico_test.fn_reorder_menus(BIGINT, JSONB);

CREATE OR REPLACE FUNCTION academico_test.fn_reorder_menus(
    p_user_pk        BIGINT,
    p_items          JSONB,
    p_modificado_por VARCHAR DEFAULT NULL
)
RETURNS TABLE (pk_tmenu BIGINT, orden NUMERIC)
LANGUAGE plpgsql
VOLATILE
SET search_path = academico_test, public
AS $$
BEGIN
    PERFORM academico_test.fn_assert_superadmin(p_user_pk);

    PERFORM academico_test.fn_audit_declarar(
        public.fn_get_academico_usuario_id(p_user_pk),
        'Reordenamiento del catalogo de menus', NULL, NULL, ARRAY['ROLES_MENUS']);

    RETURN QUERY SELECT r.pk_tmenu, r.orden
                   FROM academico_test.fn_menus_reordenar_interno(p_items, p_modificado_por) r;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_reorder_menus(BIGINT, JSONB, VARCHAR)
    IS 'PUT /menus/order: body {items:[{id,menuOrder}]} con solo los hermanos que cambiaron de lugar. Gate fn_assert_superadmin + etiqueta de auditoria; logica en fn_menus_reordenar_interno.';

-- ---------------------------------------------------------------------------
-- El orden propio del rol deja de existir: se anula el guardado.
-- ---------------------------------------------------------------------------
SELECT academico_test.fn_audit_declarar(NULL,
    'Orden propio de los menus por rol reemplazado por el del catalogo',
    NULL, NULL, ARRAY['ROLES_MENUS', 'MIGRACION']);

UPDATE academico_test.trol_menu
   SET orden_rol   = NULL,
       modified_by = 'migracion',
       modified_at = CURRENT_TIMESTAMP
 WHERE orden_rol IS NOT NULL;

COMMENT ON COLUMN academico_test.trol_menu.orden_rol
    IS 'Obsoleta: el orden del menu de un rol es el del catalogo (tmenu.orden). Ya no se escribe; se conserva porque fn_list_my_menus la lee con COALESCE(orden_rol, tmenu.orden).';

-- ---------------------------------------------------------------------------
-- Filas de public.query por ruta: en los servidores no siempre tienen el uuid.
-- ---------------------------------------------------------------------------
UPDATE public.query q
   SET query  = $q$SELECT id, solo_lectura AS "soloLectura", guardar, eliminar
       FROM academico_test.fn_rol_menus_listar(
           :CONTEXT.USER_ID::BIGINT,
           CAST(:PARAM.ROLEID AS BIGINT)
       );$q$,
       param_types = '{"PARAM.ROLEID": "BIGINT"}'::jsonb,
       detail = 'roles-permisos: menus asignados a un rol (id, soloLectura, guardar, eliminar) en el orden del catalogo de GET /menus. Mismo elemento que el body de PUT /roles/:ROLEID/menus.'
  FROM public.microservice m
 WHERE q.microservice_id = m.id_microservice
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/roles/:ROLEID/menus'
   AND q.http_method     = 'GET';

UPDATE public.query q
   SET detail = 'roles-permisos: reemplazo COMPLETO del conjunto de menus de un rol (orden del array ignorado) con soloLectura por menu y validacion de jerarquia. Respuesta {status, message}.'
  FROM public.microservice m
 WHERE q.microservice_id = m.id_microservice
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/roles/:ROLEID/menus'
   AND q.http_method     = 'PUT';

UPDATE public.query q
   SET query = $q$SELECT pk_tmenu, orden
       FROM academico_test.fn_reorder_menus(
           :CONTEXT.USER_ID::BIGINT,
           CAST(:BODY_RAW.ITEMS AS JSONB),
           :CONTEXT.EMAIL
       );$q$,
       detail = 'roles-permisos: reordena menus hermanos del catalogo, body {items:[{id,menuOrder}]} solo con los que cambiaron. Atomico.'
  FROM public.microservice m
 WHERE q.microservice_id = m.id_microservice
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/menus/order'
   AND q.http_method     = 'PUT';

-- Mismos roles que GET /roles/:ROLEID/menus: lo llama quien abre la pantalla.
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, detail, action, cacheable)
SELECT
    'eval-col-roles-funcionarios-total-001',
    $q$SELECT total
       FROM academico_test.fn_rol_funcionarios_contar(
           :CONTEXT.USER_ID::BIGINT,
           CAST(:PARAM.ROLEID AS BIGINT)
       );$q$,
    'postgres', false, false,
    m.id_microservice,
    '/roles/:ROLEID/funcionarios/total', 'SELECT', 'GET',
    '{"PARAM.ROLEID": "BIGINT"}'::jsonb,
    'roles-permisos: cuantos funcionarios (personas activas) tienen el rol, para la confirmacion de quitar permisos.',
    'roles-funcionarios-total',
    false
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL
    DO UPDATE SET query       = EXCLUDED.query,
                  param_types = EXCLUDED.param_types,
                  detail      = EXCLUDED.detail;

INSERT INTO public.role_query (role_id, query_id)
SELECT rq.role_id, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.query qm
    ON qm.microservice_id = q.microservice_id
   AND qm.path_template   = '/roles/:ROLEID/menus'
   AND qm.http_method     = 'GET'
  JOIN public.role_query rq ON rq.query_id = qm.id_query
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/roles/:ROLEID/funcionarios/total'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

-- Pestana Modulos y submodulos. Mismos roles que GET /roles/:ROLEID/menus.
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, detail, action, cacheable)
SELECT
    'eval-col-menus-catalogo-001',
    $q$SELECT pk_tmenu AS id, pk_padre AS "idParent", nombre AS name, url AS path,
              icono AS icon, visible, orden AS "menuOrder", plan_id AS "planId", type,
              activo, en_uso AS "enUso"
       FROM academico_test.fn_menu_catalogo_admin_listar(:CONTEXT.USER_ID::BIGINT);$q$,
    'postgres', false, false,
    m.id_microservice,
    '/menus/catalogo', 'SELECT', 'GET',
    '{}'::jsonb,
    'roles-permisos: catalogo de menus con inactivos, activo y enUso (pestana Modulos y submodulos).',
    'menus-catalogo',
    false
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL
    DO UPDATE SET query       = EXCLUDED.query,
                  param_types = EXCLUDED.param_types,
                  detail      = EXCLUDED.detail;

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, detail, action, cacheable)
SELECT
    'eval-col-menus-estado-001',
    $q$SELECT status, message
       FROM academico_test.fn_menu_estado_cambiar(
           :CONTEXT.USER_ID::BIGINT,
           CAST(:PARAM.ID AS BIGINT),
           CAST(:BODY.ACTIVO AS BOOLEAN),
           :CONTEXT.EMAIL
       );$q$,
    'postgres', false, false,
    m.id_microservice,
    '/menus/:ID/estado', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT", "BODY.ACTIVO": "BOOLEAN"}'::jsonb,
    'roles-permisos: activa o inactiva un menu, body {activo}. Respuesta {status, message}.',
    'menus-estado',
    false
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL
    DO UPDATE SET query       = EXCLUDED.query,
                  param_types = EXCLUDED.param_types,
                  detail      = EXCLUDED.detail;

INSERT INTO public.role_query (role_id, query_id)
SELECT rq.role_id, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.query qm
    ON qm.microservice_id = q.microservice_id
   AND qm.path_template   = '/roles/:ROLEID/menus'
   AND qm.http_method     = 'GET'
  JOIN public.role_query rq ON rq.query_id = qm.id_query
 WHERE m.serviceid = 'eval-col'
   AND ((q.path_template = '/menus/catalogo' AND q.http_method = 'GET')
     OR (q.path_template = '/menus/:ID/estado' AND q.http_method = 'PUT'))
ON CONFLICT DO NOTHING;

DO $$
BEGIN
    IF (SELECT COUNT(*) FROM public.query q
          JOIN public.microservice m ON m.id_microservice = q.microservice_id
         WHERE m.serviceid = 'eval-col'
           AND ((q.path_template = '/roles/:ROLEID/menus' AND q.http_method IN ('GET', 'PUT'))
             OR (q.path_template = '/menus/order' AND q.http_method = 'PUT')
             OR (q.path_template = '/menus' AND q.http_method = 'GET')
             OR (q.path_template = '/roles/:ROLEID/funcionarios/total' AND q.http_method = 'GET')
             OR (q.path_template = '/menus/catalogo' AND q.http_method = 'GET')
             OR (q.path_template = '/menus/:ID/estado' AND q.http_method = 'PUT'))) <> 7
    THEN
        RAISE EXCEPTION 'Faltan filas de public.query de la pantalla roles-menus (eval-col)';
    END IF;
END;
$$;
