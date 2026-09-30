-- ===========================================================================
-- V53 - Establecimientos: busquedas y listado de TESTABLECIMIENTO.
--
--   fn_est_buscar_por_nit, fn_est_buscar_por_pk y fn_est_listar_todos siguen
--   vigentes aqui. El CRUD de escritura y los listados paginados que nacieron
--   en esta migracion viven hoy en V111, V116, V354 y V399; los COMMENT que no
--   se reescribieron estan en V516.
-- ===========================================================================


SET search_path TO academico_test, public;

DROP FUNCTION IF EXISTS academico_test.fn_est_crear(
    BIGINT,
    VARCHAR, VARCHAR, BIGINT, BIGINT,
    VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR,
    VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR,
    BIGINT,
    VARCHAR, VARCHAR, DATE,
    BIGINT, BIGINT, BIGINT, BIGINT,
    academico_test.bool_sn, academico_test.bool_sn,
    BIGINT, BIGINT, academico_test.bool_sn,
    BIGINT, BIGINT, BIGINT, BIGINT,
    BIGINT
);

CREATE OR REPLACE FUNCTION academico_test.fn_est_buscar_por_nit(
    p_nit                  VARCHAR(30),
    p_incluir_inactivos    BOOLEAN DEFAULT FALSE
)
RETURNS SETOF academico_test.TESTABLECIMIENTO
LANGUAGE sql
STABLE
AS $$
    SELECT *
    FROM academico_test.TESTABLECIMIENTO
    WHERE NIT = p_nit
      AND (p_incluir_inactivos = TRUE OR ACTIVE = TRUE)
    ORDER BY ACTIVE DESC, PK_ESTABLECIMIENTO;
$$;

COMMENT ON FUNCTION academico_test.fn_est_buscar_por_nit(VARCHAR, BOOLEAN)
    IS 'Busca TESTABLECIMIENTO por NIT. Por defecto solo activos; con p_incluir_inactivos=TRUE trae tambien los dados de baja.';

CREATE OR REPLACE FUNCTION academico_test.fn_est_buscar_por_pk(
    p_pk_usuario_solicitante  BIGINT,
    p_pk_establecimiento      BIGINT
)
RETURNS SETOF academico_test.TESTABLECIMIENTO
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_active  BOOLEAN;
BEGIN
    -- 0. Validacion de parametro obligatorio.
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;
    IF p_pk_establecimiento IS NULL OR p_pk_establecimiento <= 0 THEN
        RAISE EXCEPTION 'p_pk_establecimiento es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    -- 1. Lectura del EE objetivo (activo o no) para decidir gate / error.
    SELECT e.ACTIVE
      INTO v_active
      FROM academico_test.TESTABLECIMIENTO e
     WHERE e.PK_ESTABLECIMIENTO = p_pk_establecimiento;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el establecimiento solicitado'
            USING ERRCODE = 'P0002';
    END IF;

    -- 2. Inactivos => SETOF vacio, sin error (consistente con la
    --    semantica de "borrado logico" del modulo).
    IF v_active = FALSE THEN
        RETURN;
    END IF;

    -- 3. Gate de autorizacion. Mismo patron que fn_est_listar:
    --    (a) super-admin => ok;
    --    (b) rector del EE objetivo => ok;
    --    (c) cualquier otro => 42501.
    IF academico_test.fn_usuario_categoria_rol_nivel(p_pk_usuario_solicitante) <> 0 THEN
        -- REV -- gate por el modelo dinamico (CU-86e2zenhr): capability 'VER'
        -- sobre el menu ESTABLECIMIENTO + el objeto tiene que caer dentro del
        -- scope de LECTURA del usuario. Reemplaza la cadena de ELSIF que
        -- enumeraba rector / secretaria / rol 8 a mano.
        --
        -- El SUPER_ADMIN (nivel 0) no entra a este bloque: fn_usuario_ee_lectura
        -- ya le devuelve todo. Es una consulta, no una escritura, asi que aca no
        -- aplica la exclusion del super-admin que tiene el modulo de matricula.
        --
        -- Ensancha a proposito: el gate viejo de esta funcion solo aceptaba
        -- super-admin y RECTOR -- ni secretaria ni jefe de sistema, aunque ambos
        -- si podian ver el establecimiento en el listado. Quien lo ve en la
        -- lista ahora tambien puede abrirlo.
        IF NOT academico_test.fn_usuario_puede_en_menu(
                   p_pk_usuario_solicitante, 'ESTABLECIMIENTO', 'VER') THEN
            RAISE EXCEPTION 'El usuario no tiene permiso para ver en el modulo ESTABLECIMIENTO'
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

    -- 4. Retorno de la fila completa (todos los campos del DDL).
    RETURN QUERY
    SELECT *
      FROM academico_test.TESTABLECIMIENTO
     WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento
       AND ACTIVE = TRUE;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_est_buscar_por_pk(BIGINT, BIGINT)
    IS 'Busca TESTABLECIMIENTO por PK_ESTABLECIMIENTO con gate de autorizacion (mismo patron que fn_est_listar). Solo registros activos: si el PK no existe => P0002; si existe pero esta inactivo (borrado logico) => SETOF vacio. Gate: super-admin (fn_puede_afectar_establecimiento, roles 1-3) ve cualquier EE activo; cualquier otro solo si es rector activo del EE objetivo (TFUNCIONARIO.ACTIVE=TRUE con FK_TFUNCIONARIO_RECTOR = e.FK_TFUNCIONARIO_RECTOR y FK_TUSUARIO = p_pk_usuario_solicitante); en otro caso => 42501. p_pk_usuario_solicitante va al inicio (obligatorio, mismo patron que V52/V53). Pensada para carga completa de detalle desde la UI: el SELECT expone todos los campos del DDL (incluye datos sensibles no presentes en el listado paginado), por eso el gate es obligatorio.';

CREATE OR REPLACE FUNCTION academico_test.fn_est_listar_todos(
    p_pk_usuario_solicitante  BIGINT
)
RETURNS TABLE (
    pk_establecimiento  BIGINT,
    nombre              VARCHAR
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    -- REV -- gate UNICO por el modelo dinamico (CU-86e2zenhr, sigue el patron
    -- que CU-86e2w4xdt aplico a fn_est_listar): capability 'VER' sobre el menu
    -- ESTABLECIMIENTO + scope de lectura resuelto por el JOIN de abajo.
    --
    -- Antes eran dos gates cosidos a mano: un fast-path para
    -- fn_puede_afectar_establecimiento (roles 1-3) y, para el resto, un EXISTS
    -- sobre un CTE de EE accesibles que se repetia otra vez, casi igual, en el
    -- RETURN QUERY. Esa duplicacion es justo lo que hacia que agregar un rol
    -- obligara a tocar codigo en dos lugares.
    --
    -- El SUPER_ADMIN (nivel 0) no pasa por la capability: fn_usuario_ee_lectura
    -- ya le devuelve todos los establecimientos. Es una CONSULTA de opciones,
    -- asi que aca no aplica la exclusion del super-admin que si tiene el modulo
    -- de matricula -- esa es sobre ESCRITURA de datos academicos.
    --
    -- Gana ademas el nivel 3 (coordinador y companiia), que antes quedaba fuera
    -- del gate y no podia ni ver el establecimiento de su propia sede en el
    -- select: fn_usuario_ee_lectura le devuelve el EE de sus sedes.
    IF academico_test.fn_usuario_categoria_rol_nivel(p_pk_usuario_solicitante) <> 0
       AND NOT academico_test.fn_usuario_puede_en_menu(p_pk_usuario_solicitante, 'ESTABLECIMIENTO', 'VER') THEN
        RAISE EXCEPTION 'El usuario no tiene permiso para ver en el modulo ESTABLECIMIENTO'
            USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
    SELECT e.PK_ESTABLECIMIENTO, e.NOMBRE
      FROM academico_test.TESTABLECIMIENTO e
      JOIN academico_test.fn_usuario_ee_lectura(p_pk_usuario_solicitante) el
        ON el.establecimiento_id = e.PK_ESTABLECIMIENTO
     WHERE e.ACTIVE = TRUE
     ORDER BY e.NOMBRE ASC, e.PK_ESTABLECIMIENTO ASC;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_est_listar_todos(BIGINT)
    IS 'Lista TODOS los TESTABLECIMIENTO activos que el usuario puede ver, sin paginar: pk_establecimiento + nombre, para alimentar un <select>. Super-admin ve todos; el resto ve rector UNION secretaria UNION jefe de sistema (rol 8) de alguna sede del EE. Si ninguno aplica => 42501.';
