-- ===========================================================================
-- V52 - Sedes: listados y busquedas de TSEDE.
--
--   fn_sed_listar_todos, fn_sed_buscar_por_pk y fn_sed_por_establecimiento
--   siguen vigentes aqui. El CRUD de escritura y los listados paginados que
--   nacieron en esta migracion viven hoy en V116, V354 y V414; los COMMENT
--   que no se reescribieron estan en V516.
-- ===========================================================================


SET search_path TO academico_test, public;

DROP FUNCTION IF EXISTS academico_test.fn_sed_listar_todos(BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_sed_listar_todos(p_pk_usuario_solicitante bigint)
 RETURNS TABLE(pk_sede bigint, codigo character varying, nombre character varying, fk_tlv_zona bigint, zona_nombre character varying, barrio character varying, comuna character varying, direccion character varying, telefono character varying, fk_establecimiento bigint)
 LANGUAGE plpgsql
 STABLE
AS $$
BEGIN
    -- REV -- gate UNICO por el modelo dinamico (CU-86e2zenhr), mismo patron
    -- que CU-86e2w4xdt aplico a fn_sed_listar: capability 'VER' sobre el menu
    -- SEDES_EDUCATIVAS + scope de lectura por el JOIN de abajo.
    --
    -- Antes eran tres caminos escritos a mano: fast-path de
    -- fn_puede_afectar_establecimiento, un EXISTS con el CTE de EE accesibles
    -- mas una rama suelta para el coordinador (rol 11), y despues el mismo
    -- arbol repetido en el RETURN QUERY.
    --
    -- fn_usuario_sedes_lectura mejora ese caso del coordinador: le devuelve
    -- SOLO sus sedes, no todas las del establecimiento. La REV1 anterior le
    -- daba de mas.
    --
    -- El SUPER_ADMIN (nivel 0) no pasa por la capability -- el scope de lectura
    -- ya le devuelve todas las sedes.
    IF academico_test.fn_usuario_categoria_rol_nivel(p_pk_usuario_solicitante) <> 0
       AND NOT academico_test.fn_usuario_puede_en_menu(p_pk_usuario_solicitante, 'SEDES_EDUCATIVAS', 'VER') THEN
        RAISE EXCEPTION 'El usuario no tiene permiso para ver en el modulo SEDES_EDUCATIVAS'
            USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
    SELECT s.PK_TSEDE, s.CODIGO, s.NOMBRE, s.FK_TLV_ZONA, tlv.NOMBRE,
           s.BARRIO, s.COMUNA, s.DIRECCION, s.TELEFONO, s.FK_TESTABLECIMIENTO
      FROM academico_test.TSEDE s
      JOIN academico_test.fn_usuario_sedes_lectura(p_pk_usuario_solicitante) sl
        ON sl.sede_id = s.PK_TSEDE
 LEFT JOIN academico_test.TLISTA_VALOR tlv ON tlv.PK_LISTA_VALOR = s.FK_TLV_ZONA
     WHERE s.ACTIVE = TRUE
     ORDER BY s.NOMBRE ASC, s.PK_TSEDE ASC;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_sed_listar_todos(BIGINT)
    IS 'Lista TODAS las TSEDE activas que el usuario puede ver, sin paginar, con las columnas necesarias para armar un `Campus` completo del front (codigo/dane, zona resuelta, barrio, comuna, direccion, telefono) mas su EE. Gate identico a fn_sed_listar/fn_sed_contar: super-admin ve todas; el resto ve rector UNION secretaria UNION jefe de sistema (rol 8) de alguna sede del EE. Si ninguno aplica => 42501.';

CREATE OR REPLACE FUNCTION academico_test.fn_sed_buscar_por_pk(
    p_pk_usuario_solicitante  BIGINT,
    p_pk_sede                 BIGINT
)
RETURNS SETOF academico_test.TSEDE
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_active    BOOLEAN;
    v_fk_ee     BIGINT;
BEGIN
    -- 0. Validacion de parametro obligatorio.
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;
    IF p_pk_sede IS NULL OR p_pk_sede <= 0 THEN
        RAISE EXCEPTION 'p_pk_sede es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    -- 1. Lectura de la sede objetivo (activa o no) para decidir gate / error.
    SELECT s.ACTIVE, s.FK_TESTABLECIMIENTO
      INTO v_active, v_fk_ee
      FROM academico_test.TSEDE s
     WHERE s.PK_TSEDE = p_pk_sede;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la sede solicitada'
            USING ERRCODE = 'P0002';
    END IF;

    -- 2. Inactivas => SETOF vacio, sin error (consistente con la
    --    semantica de "borrado logico" del modulo).
    IF v_active = FALSE THEN
        RETURN;
    END IF;

    -- 3. Gate de autorizacion. Mismo patron que fn_sed_listar:
    --    (a) super-admin => ok;
    --    (b) rector del EE padre => ok;
    --    (c) secretaria del EE padre => ok;
    --    (d) jefe de sistema (rol 8) en sede del EE padre => ok;
    --    (e) cualquier otro => 42501.
    IF academico_test.fn_usuario_categoria_rol_nivel(p_pk_usuario_solicitante) <> 0 THEN
        -- REV -- gate por el modelo dinamico (CU-86e2zenhr): capability 'VER'
        -- sobre SEDES_EDUCATIVAS + la sede tiene que caer en el scope de
        -- LECTURA. Reemplaza la cadena de ELSIF de rector / secretaria / rol 8.
        --
        -- fn_usuario_sedes_lectura acota por SEDE, no por establecimiento: al
        -- nivel 3 (coordinador, docente) le devuelve solo las suyas, que es mas
        -- fino que lo que hacia el gate viejo.
        IF NOT academico_test.fn_usuario_puede_en_menu(
                   p_pk_usuario_solicitante, 'SEDES_EDUCATIVAS', 'VER') THEN
            RAISE EXCEPTION 'El usuario no tiene permiso para ver en el modulo SEDES_EDUCATIVAS'
                USING ERRCODE = '42501';
        END IF;

        IF NOT EXISTS (
            SELECT 1
              FROM academico_test.fn_usuario_sedes_lectura(p_pk_usuario_solicitante) sl
             WHERE sl.sede_id = p_pk_sede
        ) THEN
            RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
                USING ERRCODE = '42501';
        END IF;
    END IF;

    -- 4. Retorno de la fila completa (todos los campos del DDL).
    RETURN QUERY
    SELECT *
      FROM academico_test.TSEDE
     WHERE PK_TSEDE = p_pk_sede
       AND ACTIVE = TRUE;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_sed_buscar_por_pk(BIGINT, BIGINT)
    IS 'Busca TSEDE por PK_TSEDE con gate de autorizacion (mismo patron que fn_sed_listar). Solo registros activos: si el PK no existe => P0002; si existe pero esta inactiva (borrado logico) => SETOF vacio. Gate contra el EE padre de la sede (v_fk_ee leido en el primer SELECT): super-admin (fn_puede_afectar_establecimiento, roles 1-3) ve cualquier sede activa; cualquier otro solo si (b) rector activo del EE padre, (c) secretaria activa del EE padre, o (d) jefe de sistema (rol 8 en TSEDE_USUARIO activa) en cualquier sede del EE padre; en otro caso => 42501. p_pk_usuario_solicitante va al inicio (obligatorio, mismo patron que V52/V53). Pensada para carga completa de detalle desde la UI: el SELECT expone todos los campos del DDL (incluye datos sensibles no presentes en el listado paginado), por eso el gate es obligatorio.';

DROP FUNCTION IF EXISTS academico_test.fn_sed_por_establecimiento(BIGINT, BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_sed_por_establecimiento(
    p_pk_usuario_solicitante  BIGINT,
    p_pk_establecimiento      BIGINT
)
RETURNS TABLE (
    pk_sede             BIGINT,
    codigo              VARCHAR,
    nombre              VARCHAR,
    fk_tlv_zona         BIGINT,
    zona_nombre         VARCHAR,
    barrio              VARCHAR,
    comuna              VARCHAR,
    direccion           VARCHAR,
    telefono            VARCHAR,
    fk_establecimiento  BIGINT
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;
    IF p_pk_establecimiento IS NULL OR p_pk_establecimiento <= 0 THEN
        RAISE EXCEPTION 'p_pk_establecimiento es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TESTABLECIMIENTO e
         WHERE e.PK_ESTABLECIMIENTO = p_pk_establecimiento AND e.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se encontro el establecimiento solicitado'
            USING ERRCODE = 'P0002';
    END IF;

    IF academico_test.fn_usuario_categoria_rol_nivel(p_pk_usuario_solicitante) <> 0 THEN
        -- REV -- gate por el modelo dinamico (CU-86e2zenhr): capability 'VER'
        -- sobre SEDES_EDUCATIVAS + el establecimiento en el scope de LECTURA.
        -- Se valida por EE y no por sede porque el parametro de entrada es el
        -- establecimiento; las sedes que devuelve se filtran ademas una por una
        -- en el RETURN QUERY con fn_usuario_sedes_lectura, de modo que un
        -- coordinador o docente reciba solo las suyas de ese EE.
        IF NOT academico_test.fn_usuario_puede_en_menu(
                   p_pk_usuario_solicitante, 'SEDES_EDUCATIVAS', 'VER') THEN
            RAISE EXCEPTION 'El usuario no tiene permiso para ver en el modulo SEDES_EDUCATIVAS'
                USING ERRCODE = '42501';
        END IF;

        IF NOT EXISTS (
            SELECT 1
              FROM academico_test.fn_usuario_ee_lectura(p_pk_usuario_solicitante) el
             WHERE el.establecimiento_id = p_pk_establecimiento
        ) THEN
            RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
                USING ERRCODE = '42501';
        END IF;
    END IF;

    RETURN QUERY
    SELECT s.PK_TSEDE, s.CODIGO, s.NOMBRE, s.FK_TLV_ZONA, tlv.NOMBRE,
           s.BARRIO, s.COMUNA, s.DIRECCION, s.TELEFONO, s.FK_TESTABLECIMIENTO
      FROM academico_test.TSEDE s
      JOIN academico_test.fn_usuario_sedes_lectura(p_pk_usuario_solicitante) sl
        ON sl.sede_id = s.PK_TSEDE
 LEFT JOIN academico_test.TLISTA_VALOR tlv ON tlv.PK_LISTA_VALOR = s.FK_TLV_ZONA
     WHERE s.FK_TESTABLECIMIENTO = p_pk_establecimiento
       AND s.ACTIVE = TRUE
     ORDER BY s.NOMBRE ASC, s.PK_TSEDE ASC;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_sed_por_establecimiento(BIGINT, BIGINT)
    IS 'Lista las TSEDE activas de UN establecimiento puntual (a diferencia de fn_sed_listar_todos, que trae el universo completo accesible al usuario). Columnas: mismo shape que fn_sed_listar_todos (pk_sede, codigo, nombre, zona resuelta, barrio, comuna, direccion, telefono, fk_establecimiento). Gate: super-admin, o rector/secretaria/jefe de sistema (rol 8) del EE objetivo puntual (P0002 si el EE no existe/esta inactivo; 42501 si no pasa el gate).';
