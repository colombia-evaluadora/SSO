-- =============================================================================
-- V123 — la asociacion de menus a un rol deja de depender del ON CONFLICT.
--
-- Sintoma: PUT /api/eval-col/roles/{id}/menus respondia 500 para cualquier rol.
-- En el log del query-service:
--
--     sqlState=42P10: there is no unique or exclusion constraint matching the
--     ON CONFLICT specification
--     PL/pgSQL function fn_associate_menus_to_rol(...) line 83
--
-- Historia, porque explica por que este arreglo es distinto del anterior:
--
--   * V65 (mia) trato esto como una deriva del esquema y "restauro" la UNIQUE
--     completa que declara V22. Funciono... hasta la siguiente corrida de
--     Flyway.
--   * V71 hace exactamente lo contrario, y a proposito:
--
--         ALTER TABLE trol_menu DROP CONSTRAINT IF EXISTS u_trol_menu_1;
--         CREATE UNIQUE INDEX u_trol_menu_1 ON trol_menu (fk_trol, fk_tmenu)
--                WHERE active = true;
--
--     No es un accidente: hace lo mismo con trubrica_unidad, tsede y otras.
--     Es el patron de soft-delete del esquema — un par puede repetirse
--     mientras solo uno este activo.
--
--   * 71 > 65, asi que V71 corre despues y revierte V65 en cada deploy. El
--     error volvia solo, sin que nadie tocara nada.
--
-- O sea que V65 estaba peleando contra el diseño del esquema. Lo correcto es
-- que la funcion se adapte al indice, no al reves — y mejor aun, que no
-- dependa de cual indice hay. Eso es lo que hace esta migracion.
--
-- No se toca el indice: V71 manda. V65 queda como no-op (V71 la deshace en la
-- misma corrida) y no se borra porque ya esta aplicada y Flyway valida
-- checksums.
-- =============================================================================

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_associate_menus_to_rol(p_user_pk bigint, p_pk_trol bigint, p_pk_tmenus bigint[], p_created_by character varying, p_full_replace boolean DEFAULT false)
 RETURNS TABLE(pk_tmenu bigint, pk_trol_menu bigint, orden_rol numeric, status character varying)
 LANGUAGE plpgsql
 SET search_path TO 'academico_test', 'public'
AS $function$
DECLARE
    v_tmenu        BIGINT;
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

        -- Buscar-y-decidir en vez de INSERT ... ON CONFLICT.
        --
        -- El ON CONFLICT exigia una UNIQUE completa sobre (FK_TROL, FK_TMENU),
        -- pero el indice de esta tabla es PARCIAL —WHERE active = true, que es
        -- el patron de soft-delete que V71 aplica a proposito en todo el
        -- esquema—. PostgreSQL no infiere un indice parcial salvo que el
        -- statement repita su predicado, asi que la asociacion moria con
        --
        --     42P10: there is no unique or exclusion constraint matching the
        --            ON CONFLICT specification
        --
        -- y el PUT /roles/{id}/menus respondia 500 para cualquier rol.
        --
        -- Se podria haber escrito ON CONFLICT (...) WHERE active = TRUE, pero
        -- eso deja un agujero peor: el indice parcial solo cubre las filas
        -- activas, asi que reasociar un menu que se habia quitado —y quedo en
        -- active = FALSE— no colisionaria con nada e insertaria una fila
        -- NUEVA, dejando el par duplicado y la rama 'reactivated' muerta.
        --
        -- Este camino no depende de que indice exista: busca la fila del par
        -- (activa o no), y reactiva o inserta segun corresponda. Sobrevive a
        -- que el indice cambie de parcial a completo o al reves, que en este
        -- esquema ya paso.
        v_pk := NULL;

        SELECT tm.pk_trol_menu
          INTO v_pk
          FROM academico_test.trol_menu tm
         WHERE tm.fk_trol  = p_pk_trol
           AND tm.fk_tmenu = v_tmenu
         -- Si por datos historicos hubiera mas de una, gana la activa; el
         -- LIMIT deja la eleccion determinista en vez de depender del orden
         -- fisico de las filas.
         ORDER BY tm.active DESC, tm.pk_trol_menu
         LIMIT 1;

        IF v_pk IS NULL THEN
            INSERT INTO academico_test.trol_menu (
                fk_trol, fk_tmenu, orden_rol, active, created_by
            )
            VALUES (
                p_pk_trol, v_tmenu, v_idx, TRUE, TRIM(p_created_by)
            )
            RETURNING academico_test.trol_menu.pk_trol_menu INTO v_pk;
            status := 'inserted';
        ELSE
            UPDATE academico_test.trol_menu tm
               SET active      = TRUE,
                   orden_rol   = v_idx,
                   modified_by = TRIM(p_created_by),
                   modified_at = v_now
             WHERE tm.pk_trol_menu = v_pk;
            status := 'reactivated';
        END IF;

        pk_trol_menu := v_pk;
        RETURN NEXT;
    END LOOP;
END;
$function$;
