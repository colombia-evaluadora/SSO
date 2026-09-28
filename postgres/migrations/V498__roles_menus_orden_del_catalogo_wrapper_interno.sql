-- Que hace: el menu de un rol pasa a ser un CONJUNTO; su orden es siempre el
--   del catalogo (tmenu.orden). GET /roles/:ROLEID/menus ordena como el arbol
--   de GET /menus, PUT /roles/:ROLEID/menus deja de escribir trol_menu.orden_rol
--   y se anula el que habia, para que fn_list_my_menus caiga a tmenu.orden.
-- Parte las 4 funciones de la pantalla roles-menus en wrapper (gate + etiqueta
--   de auditoria) y nucleo _interno sin permisos, con las validaciones como
--   fn_*_validar_* reutilizables. Contratos HTTP identicos (roles-permisos-dtos).
-- Depende de: V113 (tmenu.fk_tplan, trol_menu.orden_rol, fn_assert_superadmin),
--   V123/V198 (contrato JSONB), V99 (SOLO_LECTURA), V66 (fn_audit_declarar),
--   V215 (fn_get_academico_usuario_id).

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

-- Solo sale un menu con toda su cadena de ancestros activa: se desciende desde
-- las raices vivas (V115; hay datos legacy de tres niveles). Orden del arbol:
-- por el camino (menuOrder, pk) desde la raiz, asi el grupo va por SU
-- menuOrder (antes por pk: reordenar grupos no se veia) y cada hijo bajo su
-- padre. menuOrder NULL va al final de sus hermanos.
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

CREATE OR REPLACE FUNCTION academico_test.fn_rol_menus_listar_interno(p_pk_trol BIGINT)
RETURNS TABLE (id BIGINT, solo_lectura BOOLEAN)
LANGUAGE sql
STABLE
SET search_path = academico_test, public
AS $$
    SELECT c.pk_tmenu,
           COALESCE(bool_or(tm.solo_lectura = 'SI'), FALSE)
      FROM academico_test.fn_menu_catalogo_listar_interno() c
      JOIN academico_test.trol_menu tm
        ON tm.fk_tmenu = c.pk_tmenu
       AND tm.fk_trol  = p_pk_trol
       AND tm.active   = TRUE
     GROUP BY c.pk_tmenu, c.posicion
     ORDER BY c.posicion;
$$;

COMMENT ON FUNCTION academico_test.fn_rol_menus_listar_interno(BIGINT)
    IS 'INTERNO: menus activos asignados a un TROL con su marca de solo lectura, en el orden del catalogo (no hay orden propio del rol). Lo usa GET /roles/:ROLEID/menus.';

-- Conjunto: el orden del array no significa nada y un id repetido cuenta una
-- vez. Repetido con soloLectura distinto es ambiguo y se rechaza.
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
        SELECT 1 FROM jsonb_array_elements(p_menus) e
         GROUP BY (e ->> 'id')::BIGINT
        HAVING COUNT(DISTINCT COALESCE(NULLIF(e ->> 'soloLectura', '')::BOOLEAN, FALSE)) > 1
    ) THEN
        RAISE EXCEPTION 'Un mismo menu viene repetido con soloLectura distinto'
            USING ERRCODE = '22023';
    END IF;

    SELECT COALESCE(array_agg(DISTINCT (e ->> 'id')::BIGINT), ARRAY[]::BIGINT[])
      INTO v_ids
      FROM jsonb_array_elements(p_menus) e;

    IF p_full_replace THEN
        PERFORM academico_test.fn_rol_menus_validar_jerarquia(v_ids);

        UPDATE academico_test.trol_menu tm
           SET active      = FALSE,
               modified_by = TRIM(p_modificado_por),
               modified_at = v_now
         WHERE tm.fk_trol = p_pk_trol
           AND tm.active  = TRUE
           AND NOT (tm.fk_tmenu = ANY(v_ids));
    END IF;

    FOR v_item IN
        SELECT DISTINCT ON ((e ->> 'id')::BIGINT)
               (e ->> 'id')::BIGINT AS id,
               CASE WHEN COALESCE(NULLIF(e ->> 'soloLectura', '')::BOOLEAN, FALSE)
                    THEN 'SI' END AS solo_lectura
          FROM jsonb_array_elements(p_menus) e
         ORDER BY (e ->> 'id')::BIGINT
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

        -- Buscar-y-decidir y no ON CONFLICT: el unico de trol_menu es parcial
        -- (WHERE active) y un par dado de baja no colisionaria (ver V123).
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
            -- orden_rol := NULL: fn_list_my_menus ordena por
            -- COALESCE(orden_rol, tmenu.orden); anulado manda el catalogo.
            UPDATE academico_test.trol_menu tm
               SET active       = TRUE,
                   orden_rol    = NULL,
                   solo_lectura = v_item.solo_lectura,
                   modified_by  = TRIM(p_modificado_por),
                   modified_at  = v_now
             WHERE tm.pk_trol_menu = v_pk;
            status := 'reactivated';
        END IF;

        pk_trol_menu := v_pk;
        RETURN NEXT;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_rol_menus_asignar_interno(BIGINT, JSONB, VARCHAR, BOOLEAN)
    IS 'INTERNO: asigna a un TROL el CONJUNTO p_menus=[{"id","soloLectura"}] (orden ignorado, repetidos cuentan una vez). p_full_replace=TRUE da de baja lo ausente y exige la jerarquia completa. No escribe orden_rol. Menu inexistente => fila status=menu_not_found_or_inactive sin abortar. Lo usa PUT /roles/:ROLEID/menus (fn_associate_menus_to_rol).';

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
-- Wrappers (gate + etiqueta). Firmas de V113/V123 conservadas salvo
-- fn_reorder_menus, que recibe el correo del actor para modified_by (antes
-- guardaba CURRENT_USER, el rol de base de datos). Con DEFAULT, para que la
-- llamada de 2 argumentos que query-service tiene cacheada siga resolviendo.
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

CREATE OR REPLACE FUNCTION academico_test.fn_rol_menus_listar(p_user_pk BIGINT, p_pk_trol BIGINT)
RETURNS TABLE (id BIGINT, solo_lectura BOOLEAN)
LANGUAGE plpgsql
STABLE
SET search_path = academico_test, public
AS $$
BEGIN
    PERFORM academico_test.fn_assert_superadmin(p_user_pk);

    RETURN QUERY SELECT r.id, r.solo_lectura
                   FROM academico_test.fn_rol_menus_listar_interno(p_pk_trol) r;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_rol_menus_listar(BIGINT, BIGINT)
    IS 'GET /roles/:ROLEID/menus: menus asignados a un rol (RoleMenuAssignment {id, soloLectura}) en el orden del catalogo; [] si el rol no existe o no tiene menus. Gate fn_assert_superadmin. Nucleo fn_rol_menus_listar_interno.';

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
-- Filas de public.query. UPDATE por ruta (no por uuid) porque en los
-- servidores las filas no siempre tienen el uuid de V119/V126/V129.
-- ---------------------------------------------------------------------------
UPDATE public.query q
   SET query  = $q$SELECT id, solo_lectura AS "soloLectura"
       FROM academico_test.fn_rol_menus_listar(
           :CONTEXT.USER_ID::BIGINT,
           CAST(:PARAM.ROLEID AS BIGINT)
       );$q$,
       param_types = '{"PARAM.ROLEID": "BIGINT"}'::jsonb,
       detail = 'roles-permisos: menus asignados a un rol (id + soloLectura) en el orden del catalogo de GET /menus. Mismo elemento que el body de PUT /roles/:ROLEID/menus.'
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

DO $$
BEGIN
    IF (SELECT COUNT(*) FROM public.query q
          JOIN public.microservice m ON m.id_microservice = q.microservice_id
         WHERE m.serviceid = 'eval-col'
           AND ((q.path_template = '/roles/:ROLEID/menus' AND q.http_method IN ('GET', 'PUT'))
             OR (q.path_template = '/menus/order' AND q.http_method = 'PUT')
             OR (q.path_template = '/menus' AND q.http_method = 'GET'))) <> 4
    THEN
        RAISE EXCEPTION 'Faltan filas de public.query de la pantalla roles-menus (eval-col)';
    END IF;
END;
$$;
