-- =============================================================================
-- V115 — menus huerfanos: la cascada de borrado solo bajaba un nivel y el
--        listado devolvia el sobreviviente.
--
-- Sintoma: la pantalla "Configuracion de roles y menus" mostraba, con el rol
-- Super Administrador seleccionado, el aviso
--
--     "Se descartaron 1 menu(s) asignados cuyo menu padre ya no existe (299)."
--
-- El front no puede ubicar al menu 299 en el arbol y lo descarta al guardar.
-- (El texto del aviso ademas era enganoso: el padre SI existe, esta inactivo.)
--
-- Causa raiz, en dos partes:
--
--   1. fn_delete_menu hace soft-delete "en cascada" pero solo un nivel:
--      desactiva el menu y sus HIJOS DIRECTOS (WHERE m.fk_tmenu = p_pk_tmenu).
--      Eso alcanza mientras el arbol tenga dos niveles —que es la invariante
--      que fn_upsert_menu impone hoy, rechazando cualquier tercer nivel—, pero
--      NO alcanza para datos anteriores a esa restriccion. Al dar de baja la
--      rama raiz 247 "DATOS" se desactivaron 247 y sus hijos (249, 261, 267,
--      826); el nieto 299, colgado de 267, quedo vivo y a la deriva.
--
--   2. fn_list_available_menus filtra fila por fila (estado='A' AND active),
--      sin mirar la cadena de ancestros. Como 299 pasa el filtro y su padre
--      no, el cliente recibe un menu que apunta a un padre que no vino en la
--      misma respuesta: imposible de ubicar en el arbol.
--
-- El 299 seguia ademas asignado al rol 1 en trol_menu, que es por lo que el
-- aviso aparecia en ese rol y no en otros.
--
-- Esta migracion hace tres cosas:
--
--   1. fn_delete_menu: cascada RECURSIVA (toda la descendencia, no solo los
--      hijos directos). Para un arbol de dos niveles el resultado es identico
--      al de hoy — el cambio solo se nota con datos legacy mas profundos, que
--      es justo donde fallaba. Se conserva la semantica de `was_deleted`
--      (refiere al menu pedido) y el 404 por pk inexistente/inactivo.
--
--   2. fn_list_available_menus: en vez de filtrar fila por fila, baja desde
--      las raices activas y solo por nodos activos. Un menu cuya cadena de
--      ancestros esta cortada deja de salir. Verificado contra la base de
--      test: 157 filas -> 156, y la unica que se cae es el 299.
--
--   3. Repara los huerfanos que ya existen: los desactiva a ellos y a sus
--      filas de trol_menu. Escrito de forma generica (no hardcodea el 299) e
--      idempotente: si no hay huerfanos, no toca nada.
--
-- No se toca fn_upsert_menu: su rechazo del tercer nivel es correcto y es
-- justamente lo que evita que este caso se vuelva a crear.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- 1) fn_list_available_menus — solo menus con la cadena de ancestros viva.
--    Misma firma, mismas columnas y mismo ORDER BY que V113; cambia unicamente
--    el conjunto de origen.
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
    WITH RECURSIVE vivos AS (
        -- Raices activas.
        SELECT r.pk_tmenu
        FROM academico_test.tmenu r
        WHERE r.estado = 'A'
          AND r.active = TRUE
          AND r.fk_tmenu IS NULL
      UNION ALL
        -- Se desciende SOLO por nodos activos: si un ancestro esta dado de
        -- baja, la rama se corta ahi y sus descendientes no se alcanzan.
        SELECT h.pk_tmenu
        FROM academico_test.tmenu h
        JOIN vivos v ON h.fk_tmenu = v.pk_tmenu
        WHERE h.estado = 'A'
          AND h.active = TRUE
    )
    -- CYCLE: fk_tmenu no deberia formar ciclos (fn_upsert_menu prohibe la
    -- auto-referencia), pero un dato corrupto colgaria la funcion. Barato de
    -- prevenir.
    CYCLE pk_tmenu SET es_ciclo USING ruta
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
    JOIN vivos vv ON vv.pk_tmenu = m.pk_tmenu
    ORDER BY
        COALESCE(m.fk_tmenu, m.pk_tmenu),   -- agrupa submenus bajo su padre
        (m.fk_tmenu IS NULL) DESC,          -- padre antes que hijos
        m.orden NULLS LAST,
        m.nombre;
END;
$$;


-- ---------------------------------------------------------------------------
-- 2) fn_delete_menu — cascada recursiva sobre toda la descendencia.
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
    v_rama BIGINT[];
BEGIN
    PERFORM academico_test.fn_assert_superadmin(p_user_pk);

    IF p_pk_tmenu IS NULL THEN
        RAISE EXCEPTION 'fn_delete_menu: p_pk_tmenu es obligatorio'
            USING ERRCODE = '22023';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM academico_test.tmenu m
         WHERE m.pk_tmenu = p_pk_tmenu AND m.active = TRUE
    ) THEN
        -- 404 (no_data_found). P0002 es el unico SQLSTATE que
        -- PostgresErrorMapper traduce a 404 en esta rama; mismo tratamiento
        -- que fn_upsert_menu (MODO EDITAR) y fn_associate_menus_to_rol.
        RAISE EXCEPTION 'fn_delete_menu: TMENU pk=% no existe o no esta activo', p_pk_tmenu
            USING ERRCODE = 'P0002';
    END IF;

    -- La rama completa: el menu pedido y TODA su descendencia. Antes esto era
    -- "el menu y sus hijos directos", y por eso un nieto sobrevivia al borrado
    -- de la raiz y quedaba huerfano (ver cabecera).
    WITH RECURSIVE rama AS (
        SELECT m.pk_tmenu
        FROM academico_test.tmenu m
        WHERE m.pk_tmenu = p_pk_tmenu
      UNION ALL
        SELECT h.pk_tmenu
        FROM academico_test.tmenu h
        JOIN rama r ON h.fk_tmenu = r.pk_tmenu
    )
    CYCLE pk_tmenu SET es_ciclo USING ruta
    SELECT array_agg(rama.pk_tmenu) INTO v_rama FROM rama;

    -- 1. Desactivar las asignaciones (trol_menu) de toda la rama.
    UPDATE academico_test.trol_menu tm
       SET active      = FALSE,
           modified_by = CURRENT_USER,
           modified_at = CURRENT_TIMESTAMP
     WHERE tm.active = TRUE
       AND tm.fk_tmenu = ANY (v_rama);

    -- 2. Desactivar la descendencia (todo menos el menu pedido).
    UPDATE academico_test.tmenu m
       SET active      = FALSE,
           modified_by = CURRENT_USER,
           modified_at = CURRENT_TIMESTAMP
     WHERE m.pk_tmenu = ANY (v_rama)
       AND m.pk_tmenu <> p_pk_tmenu
       AND m.active   = TRUE;

    -- 3. Desactivar el menu en si. El ROW_COUNT de ESTE update es el que
    --    alimenta was_deleted, igual que antes.
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
-- 3) Reparacion de los huerfanos ya existentes.
--    Generico e idempotente: se apoya en la misma definicion de "vivo" que
--    usa el listado nuevo. En la base de test esto alcanza al menu 299
--    ("Administrar usuarios", duplicado de 267, con la rama 247 "DATOS" ya
--    dada de baja) y a su fila de trol_menu del rol 1.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_huerfanos BIGINT[];
BEGIN
    WITH RECURSIVE vivos AS (
        SELECT r.pk_tmenu
        FROM academico_test.tmenu r
        WHERE r.estado = 'A' AND r.active = TRUE AND r.fk_tmenu IS NULL
      UNION ALL
        SELECT h.pk_tmenu
        FROM academico_test.tmenu h
        JOIN vivos v ON h.fk_tmenu = v.pk_tmenu
        WHERE h.estado = 'A' AND h.active = TRUE
    )
    CYCLE pk_tmenu SET es_ciclo USING ruta
    SELECT array_agg(m.pk_tmenu) INTO v_huerfanos
    FROM academico_test.tmenu m
    WHERE m.active = TRUE
      AND m.fk_tmenu IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM vivos v WHERE v.pk_tmenu = m.pk_tmenu);

    IF v_huerfanos IS NULL OR cardinality(v_huerfanos) = 0 THEN
        RAISE NOTICE 'V115: no hay menus huerfanos que reparar.';
        RETURN;
    END IF;

    RAISE NOTICE 'V115: desactivando % menu(s) huerfano(s): %',
        cardinality(v_huerfanos), v_huerfanos;

    UPDATE academico_test.trol_menu tm
       SET active      = FALSE,
           modified_by = CURRENT_USER,
           modified_at = CURRENT_TIMESTAMP
     WHERE tm.active = TRUE
       AND tm.fk_tmenu = ANY (v_huerfanos);

    UPDATE academico_test.tmenu m
       SET active      = FALSE,
           modified_by = CURRENT_USER,
           modified_at = CURRENT_TIMESTAMP
     WHERE m.pk_tmenu = ANY (v_huerfanos)
       AND m.active   = TRUE;
END;
$$;


-- ---------------------------------------------------------------------------
-- Comentarios actualizados.
-- ---------------------------------------------------------------------------
COMMENT ON FUNCTION academico_test.fn_list_available_menus(BIGINT) IS
    'GET /menus -> MenuDto[]. Arbol completo de tmenu (sin filtro por rol), visible como BOOLEAN, type derivado (GROUP/ITEM de fk_tmenu IS NULL), plan_id de tmenu.fk_tplan. Shape listo para MenuDto. Desde V115 devuelve solo los menus cuya CADENA DE ANCESTROS esta activa (se desciende desde las raices activas): antes filtraba fila por fila y un menu con el padre dado de baja salia igual, dejando al cliente con un nodo imposible de ubicar en el arbol. REQUIERE p_user_pk (fn_assert_superadmin).';

COMMENT ON FUNCTION academico_test.fn_delete_menu(BIGINT, BIGINT) IS
    'Pensada para PUT /menus/{id}/eliminar (el catalogo QUERY no admite HTTP_METHOD=DELETE). Soft-delete en cascada RECURSIVA (V115): el menu, TODA su descendencia, y las filas de trol_menu de todos ellos. Antes bajaba un solo nivel (hijos directos), lo que dejaba nietos huerfanos al borrar una raiz en datos legacy de 3 niveles. Si el pk no existe o no esta activo, RAISE EXCEPTION con ERRCODE=''P0002'' (no_data_found -> 404) — NO devuelve 200 OK con was_deleted=FALSE (bug del 2026-08-14). REQUIERE p_user_pk (fn_assert_superadmin).';
