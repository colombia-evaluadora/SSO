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
--
-- -----------------------------------------------------------------------------
-- Contrato de entrada: p_menus JSONB (antes p_pk_tmenus BIGINT[]).
--
--   p_menus = [{"id": <bigint>, "soloLectura": <bool>}, ...]
--     * "id"          obligatorio en cada elemento.
--     * "soloLectura" opcional; ausente / null / '' => FALSE (concesion
--       completa, comportamiento historico). true => trol_menu.SOLO_LECTURA
--       (columna agregada por V99) = 'SI' => el rol concede ese menu SOLO
--       para ver — lo consume fn_usuario_permisos_menu(BIGINT) de V185.
--
--   El valor se persiste tanto al INSERT como al reactivar una fila
--   soft-deleted: el request MANDA, se puede promover (NULL->'SI') o
--   degradar ('SI'->NULL) el modo en cada llamada. El UPDATE ... active=FALSE
--   del p_full_replace NO toca SOLO_LECTURA.
--
--   Cambio de tipo de parametro (bigint[] -> jsonb) => CREATE OR REPLACE no
--   basta (Postgres 42P13 "cannot change ... of existing function"). Se hace
--   DROP FUNCTION IF EXISTS con TIPOS EXPLICITOS de todas las firmas
--   historicas (V59 con p_pk_tplan bigint; V113/V123 con p_full_replace
--   boolean; y la de 4 params por si algun entorno quedo sin el 5o) y luego
--   CREATE OR REPLACE de la firma nueva (asi la 2a corrida de la migracion
--   no choca). Los DROP cuentan con el server drift documentado en
--   docs/etiqueta-catalogo-funciones-fn.md §17 ("Menus y roles — drift
--   conocido"): prod corre firmas viejas de esta funcion. IF EXISTS hace
--   cada DROP inofensivo donde la firma no exista.
--
--   El resto del contrato (validaciones, ERRCODEs, mensajes, orden_rol por
--   posicion 1-based, RETURNS TABLE, modos incremental / p_full_replace,
--   invariante de jerarquia, "buscar-y-decidir" en vez de ON CONFLICT) se
--   conserva 1:1.
-- =============================================================================

SET search_path TO academico_test, public;

-- Limpieza de firmas historicas de fn_associate_menus_to_rol. Tipos
-- explicitos, IF EXISTS (inofensivo donde no exista la firma).
DROP FUNCTION IF EXISTS academico_test.fn_associate_menus_to_rol(bigint, bigint, bigint[], character varying, bigint);   -- V59  (p_pk_tplan)
DROP FUNCTION IF EXISTS academico_test.fn_associate_menus_to_rol(bigint, bigint, bigint[], character varying, boolean);  -- V113 / V123 previo (p_full_replace)
DROP FUNCTION IF EXISTS academico_test.fn_associate_menus_to_rol(bigint, bigint, bigint[], character varying);           -- por si algun entorno quedo sin 5o param

CREATE OR REPLACE FUNCTION academico_test.fn_associate_menus_to_rol(p_user_pk bigint, p_pk_trol bigint, p_menus jsonb, p_created_by character varying, p_full_replace boolean DEFAULT false)
 RETURNS TABLE(pk_tmenu bigint, pk_trol_menu bigint, orden_rol numeric, status character varying)
 LANGUAGE plpgsql
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

    -- Invariante de jerarquia (solo tiene sentido validarla en full_replace,
    -- que representa el estado FINAL completo del menu del rol): si un
    -- submenu esta en la lista, su padre tambien debe estarlo.
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

    -- Modo reemplazo completo: desactiva todo lo que NO figure en la
    -- lista nueva. NOT (fk_tmenu = ANY('{}')) es TRUE para todas las filas
    -- cuando el array llega vacio, asi que un array vacio vacia el menu.
    -- NO toca SOLO_LECTURA de las filas que desactiva.
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
        -- '' -> NULL antes del cast (un ''::boolean reventaria con 22P02);
        -- clave ausente / JSON null -> NULL; COALESCE final -> FALSE
        -- (concesion completa).
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

COMMENT ON FUNCTION academico_test.fn_associate_menus_to_rol(bigint, bigint, jsonb, character varying, boolean)
    IS 'Vincula TMENU a un TROL. Entrada p_menus JSONB = [{"id": <bigint>, "soloLectura": <bool>}, ...]: "id" obligatorio, "soloLectura" opcional (ausente/null/'''' => FALSE => concesion completa; true => trol_menu.SOLO_LECTURA = ''SI'' => el rol concede el menu solo para ver, lo consume fn_usuario_permisos_menu de V185). Persiste SOLO_LECTURA tanto al insertar como al reactivar una fila soft-deleted (se puede promover o degradar el modo en cada request). p_full_replace=FALSE (default): incremental, el array debe traer >=1 elemento. p_full_replace=TRUE: reemplazo completo (PUT /roles/{id}/menus), array vacio permitido, soft-deletea lo ausente SIN tocar su SOLO_LECTURA, valida la invariante de jerarquia. orden_rol = posicion 1-based en p_menus. Reemplaza el contrato bigint[] anterior (cambio de tipo de parametro => DROP+CREATE). ERRCODEs: rol inexistente/inactivo P0002 (404); p_menus NULL/no-array, array vacio incremental, elemento sin id, jerarquia rota => 22023; menu per-row inexistente => fila status=''menu_not_found_or_inactive'' sin abortar.';
