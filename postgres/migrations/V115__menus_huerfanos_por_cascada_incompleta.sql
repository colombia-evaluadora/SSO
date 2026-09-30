-- =============================================================================
-- V115 — fn_delete_menu: baja de un menu y de toda su descendencia.
--
-- Un menu solo se da de baja si ya nadie lo ve: ninguno de la rama puede estar
-- visible ni asignado a un rol activo (23503 -> 409). Si pasa, desactiva la rama
-- entera y las trol_menu de roles inactivos que queden.
--
-- Viven en otras migraciones: fn_list_available_menus (V498). La reparacion de
-- huerfanos que corria aqui ya se aplico en todos los ambientes.
-- Depende de: V113 (fn_assert_superadmin).
-- =============================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_menu_validar_rama_no_visible(p_rama BIGINT[])
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_menus TEXT;
BEGIN
    SELECT string_agg(format('"%s"', m.nombre), ', ' ORDER BY m.nombre) INTO v_menus
      FROM academico_test.tmenu m
     WHERE m.pk_tmenu = ANY (p_rama) AND m.active = TRUE AND m.visible = 'S';
    IF v_menus IS NOT NULL THEN
        RAISE EXCEPTION 'No se puede eliminar: el menu es visible (%). Ocultelo antes de eliminarlo', v_menus
            USING ERRCODE = '23503';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_menu_validar_rama_sin_roles(p_rama BIGINT[])
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_roles TEXT;
BEGIN
    SELECT string_agg(DISTINCT format('%s (%s)', r.nombre, m.nombre), ', ') INTO v_roles
      FROM academico_test.trol_menu tm
      JOIN academico_test.trol r  ON r.pk_trol  = tm.fk_trol  AND r.active = TRUE
      JOIN academico_test.tmenu m ON m.pk_tmenu = tm.fk_tmenu
     WHERE tm.fk_tmenu = ANY (p_rama) AND tm.active = TRUE;
    IF v_roles IS NOT NULL THEN
        RAISE EXCEPTION 'No se puede eliminar: el menu esta asignado a los roles %. Quiteselo antes de eliminarlo', v_roles
            USING ERRCODE = '23503';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_menu_eliminar_interno(
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
    IF p_pk_tmenu IS NULL THEN
        RAISE EXCEPTION 'fn_menu_eliminar_interno: p_pk_tmenu es obligatorio'
            USING ERRCODE = '22023';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM academico_test.tmenu m
         WHERE m.pk_tmenu = p_pk_tmenu AND m.active = TRUE
    ) THEN
        -- 404 (no_data_found). P0002 es el unico SQLSTATE que
        -- PostgresErrorMapper traduce a 404 en esta rama; mismo tratamiento
        -- que fn_upsert_menu (MODO EDITAR) y fn_associate_menus_to_rol.
        RAISE EXCEPTION 'El menu pk=% no existe o no esta activo', p_pk_tmenu
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

    PERFORM academico_test.fn_menu_validar_rama_no_visible(v_rama);
    PERFORM academico_test.fn_menu_validar_rama_sin_roles(v_rama);

    -- 1. Desactivar las asignaciones (trol_menu) de toda la rama; solo pueden
    --    quedar las de roles inactivos.
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
AS $$
BEGIN
    PERFORM academico_test.fn_assert_superadmin(p_user_pk);
    RETURN QUERY SELECT * FROM academico_test.fn_menu_eliminar_interno(p_pk_tmenu);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_menu_eliminar_interno(BIGINT)
    IS 'INTERNO: soft-delete de un TMENU y toda su descendencia, sin gate; lo llama fn_delete_menu. Rechaza con 23503 si algun menu de la rama es visible o esta asignado a un rol activo.';


-- ---------------------------------------------------------------------------
-- Comentarios actualizados.
-- ---------------------------------------------------------------------------
COMMENT ON FUNCTION academico_test.fn_delete_menu(BIGINT, BIGINT) IS
    'PUT /menus/{id}/eliminar (el catalogo QUERY no admite HTTP_METHOD=DELETE). Wrapper: gate de super admin y delega en fn_menu_eliminar_interno. 409 (23503) si el menu o algun submenu es visible o esta asignado a un rol activo.';
