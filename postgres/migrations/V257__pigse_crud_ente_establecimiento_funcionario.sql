-- ===========================================================================
-- V257 — CRUD del dominio propio de pigse (entes, establecimientos,
-- funcionarios y sus asignaciones de rol), replica adaptada de los modulos
-- de coleval (V51/V53) sobre las tablas que crea V256. Los roles son los de
-- public.role; los catalogos geograficos siguen siendo de academico_test.
-- Ninguna funcion fn_pigse_* de academico_test se toca.
-- ===========================================================================

SET search_path TO pigse, academico_test, public;


-- Gate unico del modulo: pigse no tiene TROL_MENU, el permiso se resuelve
-- por los roles PIGSE-* de public.role_users enlazados via TUSUARIO.FK_ID_USER.
CREATE OR REPLACE FUNCTION pigse.fn_usuario_tiene_rol(
    p_pk_usuario BIGINT,
    p_roles      VARCHAR[]
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pigse, academico_test, public
AS $$
BEGIN
    IF p_pk_usuario IS NULL OR p_pk_usuario <= 0 THEN
        RETURN FALSE;
    END IF;

    RETURN EXISTS (
        SELECT 1
          FROM pigse.TUSUARIO u
          JOIN public.role_users ru ON ru.user_id = u.FK_ID_USER
          JOIN public.role       r  ON r.id_role  = ru.role_id
         WHERE u.PK_TUSUARIO = p_pk_usuario
           AND u.ACTIVE = TRUE
           AND (p_roles IS NULL OR CARDINALITY(p_roles) = 0 OR r.name = ANY(p_roles))
    );
END;
$$;


-- ---------------------------------------------------------------------------
-- ENTE TERRITORIAL
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pigse.fn_ente_crear(
    p_pk_usuario_solicitante BIGINT,
    p_nit                    VARCHAR,
    p_nombre                 VARCHAR,
    p_fk_tmunicipio          BIGINT,
    p_fk_tente_padre         BIGINT DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pigse, academico_test, public
AS $$
DECLARE
    v_pk_ente BIGINT;
BEGIN
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    IF NOT pigse.fn_usuario_tiene_rol(p_pk_usuario_solicitante,
            ARRAY['PIGSE-ADMINISTRADOR', 'PIGSE-SECRETARIA_TERRITORIAL']::VARCHAR[]) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    IF NULLIF(TRIM(p_nit), '') IS NULL THEN
        RAISE EXCEPTION 'NIT del ente territorial es obligatorio' USING ERRCODE = '22023';
    END IF;
    IF NULLIF(TRIM(p_nombre), '') IS NULL THEN
        RAISE EXCEPTION 'Nombre del ente territorial es obligatorio' USING ERRCODE = '22023';
    END IF;
    IF p_fk_tmunicipio IS NULL THEN
        RAISE EXCEPTION 'Municipio (FK_TMUNICIPIO) es obligatorio' USING ERRCODE = '22023';
    END IF;

    IF EXISTS (SELECT 1 FROM pigse.TENTE e WHERE e.NIT = p_nit AND e.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'Ya existe un ente territorial activo con NIT %', p_nit
            USING ERRCODE = '23505';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pigse.TMUNICIPIO m
                    WHERE m.PK_TMUNICIPIO = p_fk_tmunicipio) THEN
        RAISE EXCEPTION 'El municipio (%) no existe', p_fk_tmunicipio USING ERRCODE = '23503';
    END IF;

    IF p_fk_tente_padre IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pigse.TENTE e
                        WHERE e.PK_ENTE = p_fk_tente_padre AND e.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'El ente territorial padre (%) no existe o no esta activo', p_fk_tente_padre
            USING ERRCODE = '23503';
    END IF;

    INSERT INTO pigse.TENTE (NIT, NOMBRE, FK_TMUNICIPIO, FK_TENTE_PADRE,
                             CREATED_BY, CREATED_AT, ACTIVE)
    VALUES (TRIM(p_nit), TRIM(p_nombre), p_fk_tmunicipio, p_fk_tente_padre,
            p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE)
    RETURNING PK_ENTE INTO v_pk_ente;

    RETURN v_pk_ente;
END;
$$;


CREATE OR REPLACE FUNCTION pigse.fn_ente_actualizar(
    p_pk_usuario_solicitante BIGINT,
    p_pk_ente                BIGINT,
    p_nit                    VARCHAR DEFAULT NULL,
    p_nombre                 VARCHAR DEFAULT NULL,
    p_fk_tmunicipio          BIGINT  DEFAULT NULL,
    p_fk_tente_padre         BIGINT  DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pigse, academico_test, public
AS $$
DECLARE
    v_nombre_actual VARCHAR;
BEGIN
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    IF NOT pigse.fn_usuario_tiene_rol(p_pk_usuario_solicitante,
            ARRAY['PIGSE-ADMINISTRADOR', 'PIGSE-SECRETARIA_TERRITORIAL']::VARCHAR[]) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    SELECT e.NOMBRE INTO v_nombre_actual
      FROM pigse.TENTE e
     WHERE e.PK_ENTE = p_pk_ente AND e.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el ente territorial solicitado (%)', p_pk_ente
            USING ERRCODE = 'P0002';
    END IF;

    IF p_nit IS NOT NULL AND EXISTS (
        SELECT 1 FROM pigse.TENTE e
         WHERE e.NIT = TRIM(p_nit) AND e.ACTIVE = TRUE AND e.PK_ENTE <> p_pk_ente
    ) THEN
        RAISE EXCEPTION 'Ya existe otro ente territorial activo con NIT %', p_nit
            USING ERRCODE = '23505';
    END IF;

    IF p_fk_tmunicipio IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pigse.TMUNICIPIO m
                        WHERE m.PK_TMUNICIPIO = p_fk_tmunicipio) THEN
        RAISE EXCEPTION 'El municipio (%) no existe', p_fk_tmunicipio USING ERRCODE = '23503';
    END IF;

    -- Un ente no puede ser su propio padre (la jerarquia es self-FK).
    IF p_fk_tente_padre IS NOT NULL THEN
        IF p_fk_tente_padre = p_pk_ente THEN
            RAISE EXCEPTION 'El ente territorial "%" no puede ser su propio padre', v_nombre_actual
                USING ERRCODE = '22023';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM pigse.TENTE e
                        WHERE e.PK_ENTE = p_fk_tente_padre AND e.ACTIVE = TRUE) THEN
            RAISE EXCEPTION 'El ente territorial padre (%) no existe o no esta activo', p_fk_tente_padre
                USING ERRCODE = '23503';
        END IF;
    END IF;

    UPDATE pigse.TENTE
       SET NIT            = COALESCE(TRIM(p_nit), NIT),
           NOMBRE         = COALESCE(TRIM(p_nombre), NOMBRE),
           FK_TMUNICIPIO  = COALESCE(p_fk_tmunicipio, FK_TMUNICIPIO),
           FK_TENTE_PADRE = COALESCE(p_fk_tente_padre, FK_TENTE_PADRE),
           MODIFIED_BY    = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT    = CURRENT_TIMESTAMP
     WHERE PK_ENTE = p_pk_ente;

    RETURN TRUE;
END;
$$;


-- Baja logica en cascada: el ente, su puente con establecimientos y sus
-- asignaciones de usuario. Los establecimientos NO se dan de baja: pueden
-- pertenecer a otro ente.
CREATE OR REPLACE FUNCTION pigse.fn_ente_soft_delete(
    p_pk_usuario_solicitante BIGINT,
    p_pk_ente                BIGINT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pigse, academico_test, public
AS $$
DECLARE
    v_nombre_actual VARCHAR;
    v_active        BOOLEAN;
BEGIN
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    IF NOT pigse.fn_usuario_tiene_rol(p_pk_usuario_solicitante,
            ARRAY['PIGSE-ADMINISTRADOR']::VARCHAR[]) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    SELECT e.NOMBRE, e.ACTIVE INTO v_nombre_actual, v_active
      FROM pigse.TENTE e
     WHERE e.PK_ENTE = p_pk_ente;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el ente territorial solicitado (%)', p_pk_ente
            USING ERRCODE = 'P0002';
    END IF;

    IF v_active = FALSE THEN
        RAISE EXCEPTION 'El ente territorial "%" ya se encuentra inactivo', v_nombre_actual
            USING ERRCODE = '22023';
    END IF;

    UPDATE pigse.TENTE
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_ENTE = p_pk_ente;

    UPDATE pigse.TENTE_ESTABLECIMIENTO
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TENTE = p_pk_ente AND ACTIVE = TRUE;

    UPDATE pigse.TENTE_USUARIO
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TENTE = p_pk_ente AND ACTIVE = TRUE;

    RETURN TRUE;
END;
$$;


CREATE OR REPLACE FUNCTION pigse.fn_ente_listar(
    p_pk_usuario_solicitante BIGINT,
    p_search                 VARCHAR DEFAULT NULL,
    p_sort_campo             VARCHAR DEFAULT NULL,
    p_sort_desc              BOOLEAN DEFAULT FALSE,
    p_page_index             INT     DEFAULT 0,
    p_page_size              INT     DEFAULT 10
)
RETURNS TABLE (
    rows        JSONB,
    total_count BIGINT,
    page_count  BIGINT,
    page_index  INT,
    page_size   INT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pigse, academico_test, public
AS $$
DECLARE
    v_page_size  INT := CASE WHEN p_page_size IS NULL THEN NULL
                             ELSE LEAST(CASE WHEN p_page_size > 0 THEN p_page_size ELSE 10 END, 100) END;
    v_page_index INT := GREATEST(COALESCE(p_page_index, 0), 0);
    v_total      BIGINT;
    v_rows       JSONB := '[]'::JSONB;
BEGIN
    IF NOT pigse.fn_usuario_tiene_rol(p_pk_usuario_solicitante, NULL) THEN
        RAISE EXCEPTION 'El usuario no tiene permiso para ver en el modulo ENTE'
            USING ERRCODE = '42501';
    END IF;

    SELECT COUNT(*) INTO v_total
      FROM pigse.TENTE e
      JOIN pigse.TMUNICIPIO m ON m.PK_TMUNICIPIO = e.FK_TMUNICIPIO
     WHERE e.ACTIVE = TRUE
       AND (NULLIF(TRIM(p_search), '') IS NULL
            OR e.NOMBRE ILIKE '%' || p_search || '%'
            OR e.NIT    ILIKE '%' || p_search || '%'
            OR m.NOMBRE ILIKE '%' || p_search || '%');

    SELECT COALESCE(jsonb_agg(to_jsonb(t) - 'orden_fila' ORDER BY t.orden_fila), '[]'::JSONB) INTO v_rows
      FROM (
        SELECT e.PK_ENTE        AS pk_ente,
               e.NIT             AS nit,
               e.NOMBRE          AS nombre,
               e.FK_TMUNICIPIO   AS fk_tmunicipio,
               m.NOMBRE          AS municipio_nombre,
               e.FK_TENTE_PADRE  AS fk_tente_padre,
               p.NOMBRE          AS ente_padre_nombre,
               ROW_NUMBER() OVER (
                   ORDER BY
                     CASE WHEN p_sort_campo = 'name'         AND NOT p_sort_desc THEN e.NOMBRE END ASC,
                     CASE WHEN p_sort_campo = 'name'         AND     p_sort_desc THEN e.NOMBRE END DESC,
                     CASE WHEN p_sort_campo = 'nit'          AND NOT p_sort_desc THEN e.NIT    END ASC,
                     CASE WHEN p_sort_campo = 'nit'          AND     p_sort_desc THEN e.NIT    END DESC,
                     CASE WHEN p_sort_campo = 'municipality' AND NOT p_sort_desc THEN m.NOMBRE END ASC,
                     CASE WHEN p_sort_campo = 'municipality' AND     p_sort_desc THEN m.NOMBRE END DESC,
                     e.NOMBRE ASC, e.PK_ENTE ASC
               ) AS orden_fila
          FROM pigse.TENTE e
          JOIN pigse.TMUNICIPIO m ON m.PK_TMUNICIPIO = e.FK_TMUNICIPIO
     LEFT JOIN pigse.TENTE p ON p.PK_ENTE = e.FK_TENTE_PADRE
         WHERE e.ACTIVE = TRUE
           AND (NULLIF(TRIM(p_search), '') IS NULL
                OR e.NOMBRE ILIKE '%' || p_search || '%'
                OR e.NIT    ILIKE '%' || p_search || '%'
                OR m.NOMBRE ILIKE '%' || p_search || '%')
         ORDER BY orden_fila
         LIMIT v_page_size
        OFFSET v_page_index * COALESCE(v_page_size, 0)
      ) t;

    RETURN QUERY
    SELECT v_rows,
           v_total,
           CASE WHEN v_total = 0 OR v_page_size IS NULL THEN
                    CASE WHEN v_total = 0 THEN 0::BIGINT ELSE 1::BIGINT END
                ELSE CEIL(v_total::NUMERIC / v_page_size)::BIGINT END,
           v_page_index,
           v_page_size;
END;
$$;


CREATE OR REPLACE FUNCTION pigse.fn_ente_buscar_por_pk(
    p_pk_usuario_solicitante BIGINT,
    p_pk_ente                BIGINT
)
RETURNS TABLE (
    pk_ente           BIGINT,
    nit               VARCHAR,
    nombre            VARCHAR,
    fk_tmunicipio     BIGINT,
    municipio_nombre  VARCHAR,
    fk_tente_padre    BIGINT,
    ente_padre_nombre VARCHAR,
    created_by        VARCHAR,
    created_at        TIMESTAMP,
    modified_by       VARCHAR,
    modified_at       TIMESTAMP
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pigse, academico_test, public
AS $$
DECLARE
    v_active BOOLEAN;
BEGIN
    IF NOT pigse.fn_usuario_tiene_rol(p_pk_usuario_solicitante, NULL) THEN
        RAISE EXCEPTION 'El usuario no tiene permiso para ver en el modulo ENTE'
            USING ERRCODE = '42501';
    END IF;

    SELECT e.ACTIVE INTO v_active FROM pigse.TENTE e WHERE e.PK_ENTE = p_pk_ente;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el ente territorial solicitado (%)', p_pk_ente
            USING ERRCODE = 'P0002';
    END IF;

    IF v_active = FALSE THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT e.PK_ENTE, e.NIT, e.NOMBRE, e.FK_TMUNICIPIO, m.NOMBRE,
           e.FK_TENTE_PADRE, p.NOMBRE,
           e.CREATED_BY, e.CREATED_AT, e.MODIFIED_BY, e.MODIFIED_AT
      FROM pigse.TENTE e
      JOIN pigse.TMUNICIPIO m ON m.PK_TMUNICIPIO = e.FK_TMUNICIPIO
 LEFT JOIN pigse.TENTE p ON p.PK_ENTE = e.FK_TENTE_PADRE
     WHERE e.PK_ENTE = p_pk_ente;
END;
$$;


-- ---------------------------------------------------------------------------
-- ESTABLECIMIENTO
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pigse.fn_est_crear(
    p_pk_usuario_solicitante     BIGINT,
    p_fk_ente                    BIGINT,
    p_nombre                     VARCHAR,
    p_nit                        VARCHAR,
    p_fk_tmunicipio              BIGINT,
    p_codigo                     VARCHAR,
    p_fk_tpropiedad_juridica     BIGINT  DEFAULT NULL,
    p_direccion                  VARCHAR DEFAULT NULL,
    p_telefono                   VARCHAR DEFAULT NULL,
    p_correo_electronico         VARCHAR DEFAULT NULL,
    p_fk_tlista_valor_zona       BIGINT  DEFAULT NULL,
    p_fk_testablecimiento_origen BIGINT  DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pigse, academico_test, public
AS $$
DECLARE
    v_pk_establecimiento BIGINT;
BEGIN
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    IF NOT pigse.fn_usuario_tiene_rol(p_pk_usuario_solicitante,
            ARRAY['PIGSE-ADMINISTRADOR', 'PIGSE-SECRETARIA_TERRITORIAL']::VARCHAR[]) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    IF NULLIF(TRIM(p_nombre), '') IS NULL THEN
        RAISE EXCEPTION 'Nombre del establecimiento es obligatorio' USING ERRCODE = '22023';
    END IF;
    IF NULLIF(TRIM(p_nit), '') IS NULL THEN
        RAISE EXCEPTION 'NIT del establecimiento es obligatorio' USING ERRCODE = '22023';
    END IF;
    IF NULLIF(TRIM(p_codigo), '') IS NULL THEN
        RAISE EXCEPTION 'Codigo del establecimiento es obligatorio' USING ERRCODE = '22023';
    END IF;
    IF p_fk_tmunicipio IS NULL THEN
        RAISE EXCEPTION 'Municipio (FK_TMUNICIPIO) es obligatorio' USING ERRCODE = '22023';
    END IF;
    IF p_fk_ente IS NULL THEN
        RAISE EXCEPTION 'Ente territorial (FK_TENTE) es obligatorio' USING ERRCODE = '22023';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pigse.TENTE e
                    WHERE e.PK_ENTE = p_fk_ente AND e.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'El ente territorial (%) no existe o no esta activo', p_fk_ente
            USING ERRCODE = '23503';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pigse.TMUNICIPIO m
                    WHERE m.PK_TMUNICIPIO = p_fk_tmunicipio) THEN
        RAISE EXCEPTION 'El municipio (%) no existe', p_fk_tmunicipio USING ERRCODE = '23503';
    END IF;

    IF p_fk_tpropiedad_juridica IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pigse.TPROPIEDAD_JURIDICA pj
                        WHERE pj.PK_PROPIEDAD_JURIDICA = p_fk_tpropiedad_juridica
                          AND pj.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'La propiedad juridica (%) no existe o no esta activa', p_fk_tpropiedad_juridica
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlista_valor_zona IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pigse.TLISTA_VALOR lv
                        WHERE lv.PK_LISTA_VALOR = p_fk_tlista_valor_zona
                          AND lv.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'La zona (%) no existe o no esta activa en TLISTA_VALOR', p_fk_tlista_valor_zona
            USING ERRCODE = '23503';
    END IF;

    IF EXISTS (SELECT 1 FROM pigse.TESTABLECIMIENTO e
                WHERE e.NIT = TRIM(p_nit) AND e.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'Ya existe un establecimiento activo con NIT %', p_nit
            USING ERRCODE = '23505';
    END IF;
    IF EXISTS (SELECT 1 FROM pigse.TESTABLECIMIENTO e
                WHERE e.CODIGO = TRIM(p_codigo) AND e.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'Ya existe un establecimiento activo con CODIGO %', p_codigo
            USING ERRCODE = '23505';
    END IF;

    INSERT INTO pigse.TESTABLECIMIENTO (
        NOMBRE, NIT, CODIGO, FK_TMUNICIPIO, FK_TPROPIEDAD_JURIDICA,
        DIRECCION, TELEFONO, CORREO_ELECTRONICO, FK_TLISTA_VALOR_ZONA,
        FK_TESTABLECIMIENTO_ORIGEN, CREATED_BY, CREATED_AT, ACTIVE
    )
    VALUES (
        TRIM(p_nombre), TRIM(p_nit), TRIM(p_codigo), p_fk_tmunicipio, p_fk_tpropiedad_juridica,
        p_direccion, p_telefono, p_correo_electronico, p_fk_tlista_valor_zona,
        p_fk_testablecimiento_origen, p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
    )
    RETURNING PK_ESTABLECIMIENTO INTO v_pk_establecimiento;

    INSERT INTO pigse.TENTE_ESTABLECIMIENTO (
        FK_TENTE, FK_TESTABLECIMIENTO, CREATED_BY, CREATED_AT, ACTIVE
    )
    SELECT p_fk_ente, v_pk_establecimiento, p_pk_usuario_solicitante::VARCHAR,
           CURRENT_TIMESTAMP, TRUE
     WHERE NOT EXISTS (
        SELECT 1 FROM pigse.TENTE_ESTABLECIMIENTO te
         WHERE te.FK_TENTE = p_fk_ente
           AND te.FK_TESTABLECIMIENTO = v_pk_establecimiento
           AND te.ACTIVE = TRUE
     );

    RETURN v_pk_establecimiento;
END;
$$;


CREATE OR REPLACE FUNCTION pigse.fn_est_actualizar(
    p_pk_usuario_solicitante BIGINT,
    p_pk_establecimiento     BIGINT,
    p_nombre                 VARCHAR DEFAULT NULL,
    p_nit                    VARCHAR DEFAULT NULL,
    p_codigo                 VARCHAR DEFAULT NULL,
    p_fk_tmunicipio          BIGINT  DEFAULT NULL,
    p_fk_tpropiedad_juridica BIGINT  DEFAULT NULL,
    p_direccion              VARCHAR DEFAULT NULL,
    p_telefono               VARCHAR DEFAULT NULL,
    p_correo_electronico     VARCHAR DEFAULT NULL,
    p_fk_tlista_valor_zona   BIGINT  DEFAULT NULL,
    p_fk_ente                BIGINT  DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pigse, academico_test, public
AS $$
DECLARE
    v_nombre_actual VARCHAR;
BEGIN
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    IF NOT pigse.fn_usuario_tiene_rol(p_pk_usuario_solicitante,
            ARRAY['PIGSE-ADMINISTRADOR', 'PIGSE-SECRETARIA_TERRITORIAL']::VARCHAR[]) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    SELECT e.NOMBRE INTO v_nombre_actual
      FROM pigse.TESTABLECIMIENTO e
     WHERE e.PK_ESTABLECIMIENTO = p_pk_establecimiento AND e.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el establecimiento solicitado (%)', p_pk_establecimiento
            USING ERRCODE = 'P0002';
    END IF;

    IF p_nit IS NOT NULL AND EXISTS (
        SELECT 1 FROM pigse.TESTABLECIMIENTO e
         WHERE e.NIT = TRIM(p_nit) AND e.ACTIVE = TRUE
           AND e.PK_ESTABLECIMIENTO <> p_pk_establecimiento
    ) THEN
        RAISE EXCEPTION 'Ya existe otro establecimiento activo con NIT %', p_nit
            USING ERRCODE = '23505';
    END IF;

    IF p_codigo IS NOT NULL AND EXISTS (
        SELECT 1 FROM pigse.TESTABLECIMIENTO e
         WHERE e.CODIGO = TRIM(p_codigo) AND e.ACTIVE = TRUE
           AND e.PK_ESTABLECIMIENTO <> p_pk_establecimiento
    ) THEN
        RAISE EXCEPTION 'Ya existe otro establecimiento activo con CODIGO %', p_codigo
            USING ERRCODE = '23505';
    END IF;

    IF p_fk_tmunicipio IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pigse.TMUNICIPIO m
                        WHERE m.PK_TMUNICIPIO = p_fk_tmunicipio) THEN
        RAISE EXCEPTION 'El municipio (%) no existe', p_fk_tmunicipio USING ERRCODE = '23503';
    END IF;

    IF p_fk_tpropiedad_juridica IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pigse.TPROPIEDAD_JURIDICA pj
                        WHERE pj.PK_PROPIEDAD_JURIDICA = p_fk_tpropiedad_juridica
                          AND pj.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'La propiedad juridica (%) no existe o no esta activa', p_fk_tpropiedad_juridica
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlista_valor_zona IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pigse.TLISTA_VALOR lv
                        WHERE lv.PK_LISTA_VALOR = p_fk_tlista_valor_zona
                          AND lv.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'La zona (%) no existe o no esta activa en TLISTA_VALOR', p_fk_tlista_valor_zona
            USING ERRCODE = '23503';
    END IF;

    UPDATE pigse.TESTABLECIMIENTO
       SET NOMBRE                 = COALESCE(TRIM(p_nombre), NOMBRE),
           NIT                    = COALESCE(TRIM(p_nit), NIT),
           CODIGO                 = COALESCE(TRIM(p_codigo), CODIGO),
           FK_TMUNICIPIO          = COALESCE(p_fk_tmunicipio, FK_TMUNICIPIO),
           FK_TPROPIEDAD_JURIDICA = COALESCE(p_fk_tpropiedad_juridica, FK_TPROPIEDAD_JURIDICA),
           DIRECCION              = COALESCE(p_direccion, DIRECCION),
           TELEFONO               = COALESCE(p_telefono, TELEFONO),
           CORREO_ELECTRONICO     = COALESCE(p_correo_electronico, CORREO_ELECTRONICO),
           FK_TLISTA_VALOR_ZONA   = COALESCE(p_fk_tlista_valor_zona, FK_TLISTA_VALOR_ZONA),
           MODIFIED_BY            = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT            = CURRENT_TIMESTAMP
     WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;

    -- Reasignar de ente: se cierra el puente vigente y se abre el nuevo.
    IF p_fk_ente IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM pigse.TENTE e
                        WHERE e.PK_ENTE = p_fk_ente AND e.ACTIVE = TRUE) THEN
            RAISE EXCEPTION 'El ente territorial (%) no existe o no esta activo', p_fk_ente
                USING ERRCODE = '23503';
        END IF;

        UPDATE pigse.TENTE_ESTABLECIMIENTO
           SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TESTABLECIMIENTO = p_pk_establecimiento
           AND FK_TENTE <> p_fk_ente
           AND ACTIVE = TRUE;

        INSERT INTO pigse.TENTE_ESTABLECIMIENTO (
            FK_TENTE, FK_TESTABLECIMIENTO, CREATED_BY, CREATED_AT, ACTIVE
        )
        SELECT p_fk_ente, p_pk_establecimiento, p_pk_usuario_solicitante::VARCHAR,
               CURRENT_TIMESTAMP, TRUE
         WHERE NOT EXISTS (
            SELECT 1 FROM pigse.TENTE_ESTABLECIMIENTO te
             WHERE te.FK_TENTE = p_fk_ente
               AND te.FK_TESTABLECIMIENTO = p_pk_establecimiento
               AND te.ACTIVE = TRUE
         );
    END IF;

    RETURN TRUE;
END;
$$;


CREATE OR REPLACE FUNCTION pigse.fn_est_soft_delete(
    p_pk_usuario_solicitante BIGINT,
    p_pk_establecimiento     BIGINT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pigse, academico_test, public
AS $$
DECLARE
    v_nombre_actual VARCHAR;
    v_active        BOOLEAN;
BEGIN
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    IF NOT pigse.fn_usuario_tiene_rol(p_pk_usuario_solicitante,
            ARRAY['PIGSE-ADMINISTRADOR']::VARCHAR[]) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    SELECT e.NOMBRE, e.ACTIVE INTO v_nombre_actual, v_active
      FROM pigse.TESTABLECIMIENTO e
     WHERE e.PK_ESTABLECIMIENTO = p_pk_establecimiento;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el establecimiento solicitado (%)', p_pk_establecimiento
            USING ERRCODE = 'P0002';
    END IF;

    IF v_active = FALSE THEN
        RAISE EXCEPTION 'El establecimiento "%" ya se encuentra inactivo', v_nombre_actual
            USING ERRCODE = '22023';
    END IF;

    UPDATE pigse.TESTABLECIMIENTO
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;

    UPDATE pigse.TENTE_ESTABLECIMIENTO
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TESTABLECIMIENTO = p_pk_establecimiento AND ACTIVE = TRUE;

    UPDATE pigse.TESTABLECIMIENTO_USUARIO
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TESTABLECIMIENTO = p_pk_establecimiento AND ACTIVE = TRUE;

    UPDATE pigse.TFUNCIONARIO
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TESTABLECIMIENTO = p_pk_establecimiento AND ACTIVE = TRUE;

    RETURN TRUE;
END;
$$;


CREATE OR REPLACE FUNCTION pigse.fn_est_listar(
    p_pk_usuario_solicitante BIGINT,
    p_search                 VARCHAR   DEFAULT NULL,
    p_entes                  BIGINT[]  DEFAULT NULL,
    p_municipios             VARCHAR[] DEFAULT NULL,
    p_sort_campo             VARCHAR   DEFAULT NULL,
    p_sort_desc              BOOLEAN   DEFAULT FALSE,
    p_page_index             INT       DEFAULT 0,
    p_page_size              INT       DEFAULT 10
)
RETURNS TABLE (
    rows        JSONB,
    total_count BIGINT,
    page_count  BIGINT,
    page_index  INT,
    page_size   INT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pigse, academico_test, public
AS $$
DECLARE
    v_page_size  INT := CASE WHEN p_page_size IS NULL THEN NULL
                             ELSE LEAST(CASE WHEN p_page_size > 0 THEN p_page_size ELSE 10 END, 100) END;
    v_page_index INT := GREATEST(COALESCE(p_page_index, 0), 0);
    v_total      BIGINT;
    v_rows       JSONB := '[]'::JSONB;
BEGIN
    IF NOT pigse.fn_usuario_tiene_rol(p_pk_usuario_solicitante, NULL) THEN
        RAISE EXCEPTION 'El usuario no tiene permiso para ver en el modulo ESTABLECIMIENTO'
            USING ERRCODE = '42501';
    END IF;

    SELECT COUNT(*) INTO v_total
      FROM pigse.TESTABLECIMIENTO e
      JOIN pigse.TMUNICIPIO m ON m.PK_TMUNICIPIO = e.FK_TMUNICIPIO
     WHERE e.ACTIVE = TRUE
       AND (NULLIF(TRIM(p_search), '') IS NULL
            OR e.NOMBRE ILIKE '%' || p_search || '%'
            OR e.CODIGO ILIKE '%' || p_search || '%'
            OR e.NIT    ILIKE '%' || p_search || '%'
            OR m.NOMBRE ILIKE '%' || p_search || '%')
       AND (p_municipios IS NULL OR CARDINALITY(p_municipios) = 0
            OR m.CODIGO = ANY(p_municipios))
       AND (p_entes IS NULL OR CARDINALITY(p_entes) = 0
            OR EXISTS (SELECT 1 FROM pigse.TENTE_ESTABLECIMIENTO te
                        WHERE te.FK_TESTABLECIMIENTO = e.PK_ESTABLECIMIENTO
                          AND te.ACTIVE = TRUE
                          AND te.FK_TENTE = ANY(p_entes)));

    SELECT COALESCE(jsonb_agg(to_jsonb(t) - 'orden_fila' ORDER BY t.orden_fila), '[]'::JSONB) INTO v_rows
      FROM (
        SELECT e.PK_ESTABLECIMIENTO AS pk_establecimiento,
               e.CODIGO              AS codigo,
               e.NOMBRE              AS nombre,
               e.NIT                 AS nit,
               e.FK_TMUNICIPIO       AS fk_tmunicipio,
               m.NOMBRE              AS municipio_nombre,
               ent.PK_ENTE          AS fk_tente,
               ent.NOMBRE            AS ente_nombre,
               ROW_NUMBER() OVER (
                   ORDER BY
                     CASE WHEN p_sort_campo = 'name'         AND NOT p_sort_desc THEN e.NOMBRE END ASC,
                     CASE WHEN p_sort_campo = 'name'         AND     p_sort_desc THEN e.NOMBRE END DESC,
                     CASE WHEN p_sort_campo = 'dane'         AND NOT p_sort_desc THEN e.CODIGO END ASC,
                     CASE WHEN p_sort_campo = 'dane'         AND     p_sort_desc THEN e.CODIGO END DESC,
                     CASE WHEN p_sort_campo = 'municipality' AND NOT p_sort_desc THEN m.NOMBRE END ASC,
                     CASE WHEN p_sort_campo = 'municipality' AND     p_sort_desc THEN m.NOMBRE END DESC,
                     e.NOMBRE ASC, e.PK_ESTABLECIMIENTO ASC
               ) AS orden_fila
          FROM pigse.TESTABLECIMIENTO e
          JOIN pigse.TMUNICIPIO m ON m.PK_TMUNICIPIO = e.FK_TMUNICIPIO
     LEFT JOIN LATERAL (
            SELECT en.PK_ENTE, en.NOMBRE
              FROM pigse.TENTE_ESTABLECIMIENTO te
              JOIN pigse.TENTE en ON en.PK_ENTE = te.FK_TENTE
             WHERE te.FK_TESTABLECIMIENTO = e.PK_ESTABLECIMIENTO
               AND te.ACTIVE = TRUE
             ORDER BY te.PK_TENTE_ESTABLECIMIENTO DESC
             LIMIT 1
          ) ent ON TRUE
         WHERE e.ACTIVE = TRUE
           AND (NULLIF(TRIM(p_search), '') IS NULL
                OR e.NOMBRE ILIKE '%' || p_search || '%'
                OR e.CODIGO ILIKE '%' || p_search || '%'
                OR e.NIT    ILIKE '%' || p_search || '%'
                OR m.NOMBRE ILIKE '%' || p_search || '%')
           AND (p_municipios IS NULL OR CARDINALITY(p_municipios) = 0
                OR m.CODIGO = ANY(p_municipios))
           AND (p_entes IS NULL OR CARDINALITY(p_entes) = 0
                OR EXISTS (SELECT 1 FROM pigse.TENTE_ESTABLECIMIENTO te2
                            WHERE te2.FK_TESTABLECIMIENTO = e.PK_ESTABLECIMIENTO
                              AND te2.ACTIVE = TRUE
                              AND te2.FK_TENTE = ANY(p_entes)))
         ORDER BY orden_fila
         LIMIT v_page_size
        OFFSET v_page_index * COALESCE(v_page_size, 0)
      ) t;

    RETURN QUERY
    SELECT v_rows,
           v_total,
           CASE WHEN v_total = 0 THEN 0::BIGINT
                WHEN v_page_size IS NULL THEN 1::BIGINT
                ELSE CEIL(v_total::NUMERIC / v_page_size)::BIGINT END,
           v_page_index,
           v_page_size;
END;
$$;


CREATE OR REPLACE FUNCTION pigse.fn_est_buscar_por_pk(
    p_pk_usuario_solicitante BIGINT,
    p_pk_establecimiento     BIGINT
)
RETURNS TABLE (
    pk_establecimiento         BIGINT,
    codigo                     VARCHAR,
    nombre                     VARCHAR,
    nit                        VARCHAR,
    fk_tmunicipio              BIGINT,
    municipio_nombre           VARCHAR,
    fk_tpropiedad_juridica     BIGINT,
    direccion                  VARCHAR,
    telefono                   VARCHAR,
    correo_electronico         VARCHAR,
    fk_tlista_valor_zona       BIGINT,
    fk_testablecimiento_origen BIGINT,
    entes                      JSONB,
    created_by                 VARCHAR,
    created_at                 TIMESTAMP,
    modified_by                VARCHAR,
    modified_at                TIMESTAMP
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pigse, academico_test, public
AS $$
DECLARE
    v_active BOOLEAN;
BEGIN
    IF NOT pigse.fn_usuario_tiene_rol(p_pk_usuario_solicitante, NULL) THEN
        RAISE EXCEPTION 'El usuario no tiene permiso para ver en el modulo ESTABLECIMIENTO'
            USING ERRCODE = '42501';
    END IF;

    SELECT e.ACTIVE INTO v_active
      FROM pigse.TESTABLECIMIENTO e
     WHERE e.PK_ESTABLECIMIENTO = p_pk_establecimiento;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el establecimiento solicitado (%)', p_pk_establecimiento
            USING ERRCODE = 'P0002';
    END IF;

    IF v_active = FALSE THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT e.PK_ESTABLECIMIENTO, e.CODIGO, e.NOMBRE, e.NIT,
           e.FK_TMUNICIPIO, m.NOMBRE, e.FK_TPROPIEDAD_JURIDICA,
           e.DIRECCION, e.TELEFONO, e.CORREO_ELECTRONICO,
           e.FK_TLISTA_VALOR_ZONA, e.FK_TESTABLECIMIENTO_ORIGEN,
           COALESCE((
               SELECT jsonb_agg(jsonb_build_object('pkEnte', en.PK_ENTE, 'nombre', en.NOMBRE)
                                ORDER BY en.NOMBRE)
                 FROM pigse.TENTE_ESTABLECIMIENTO te
                 JOIN pigse.TENTE en ON en.PK_ENTE = te.FK_TENTE AND en.ACTIVE = TRUE
                WHERE te.FK_TESTABLECIMIENTO = e.PK_ESTABLECIMIENTO AND te.ACTIVE = TRUE
           ), '[]'::JSONB),
           e.CREATED_BY, e.CREATED_AT, e.MODIFIED_BY, e.MODIFIED_AT
      FROM pigse.TESTABLECIMIENTO e
      JOIN pigse.TMUNICIPIO m ON m.PK_TMUNICIPIO = e.FK_TMUNICIPIO
     WHERE e.PK_ESTABLECIMIENTO = p_pk_establecimiento;
END;
$$;


-- ---------------------------------------------------------------------------
-- FUNCIONARIO
-- ---------------------------------------------------------------------------
-- Crea el par TUSUARIO + TFUNCIONARIO: en pigse el perfil laboral es 1:1 con
-- la identidad, y la cuenta de login (public.users) se enlaza aparte.
CREATE OR REPLACE FUNCTION pigse.fn_fun_crear(
    p_pk_usuario_solicitante BIGINT,
    p_fk_establecimiento     BIGINT,
    p_correo_electronico     VARCHAR,
    p_identificacion         VARCHAR,
    p_primer_nombre          VARCHAR,
    p_primer_apellido        VARCHAR,
    p_segundo_nombre         VARCHAR DEFAULT NULL,
    p_segundo_apellido       VARCHAR DEFAULT NULL,
    p_telefono               VARCHAR DEFAULT NULL,
    p_fk_tlv_tipo_documento BIGINT DEFAULT NULL,
    p_fk_tlv_cargo  BIGINT  DEFAULT NULL,
    p_fk_id_role             BIGINT  DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pigse, academico_test, public
AS $$
DECLARE
    v_pk_usuario     BIGINT;
    v_pk_funcionario BIGINT;
    v_id_user        BIGINT;
BEGIN
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    IF NOT pigse.fn_usuario_tiene_rol(p_pk_usuario_solicitante,
            ARRAY['PIGSE-ADMINISTRADOR', 'PIGSE-SECRETARIA_TERRITORIAL']::VARCHAR[]) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    IF NULLIF(TRIM(p_correo_electronico), '') IS NULL THEN
        RAISE EXCEPTION 'Correo electronico es obligatorio' USING ERRCODE = '22023';
    END IF;
    IF NULLIF(TRIM(p_identificacion), '') IS NULL THEN
        RAISE EXCEPTION 'Numero de identificacion es obligatorio' USING ERRCODE = '22023';
    END IF;
    IF NULLIF(TRIM(p_primer_nombre), '') IS NULL THEN
        RAISE EXCEPTION 'Primer nombre es obligatorio' USING ERRCODE = '22023';
    END IF;
    IF NULLIF(TRIM(p_primer_apellido), '') IS NULL THEN
        RAISE EXCEPTION 'Primer apellido es obligatorio' USING ERRCODE = '22023';
    END IF;
    IF p_fk_establecimiento IS NULL THEN
        RAISE EXCEPTION 'Establecimiento (FK_TESTABLECIMIENTO) es obligatorio' USING ERRCODE = '22023';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pigse.TESTABLECIMIENTO e
                    WHERE e.PK_ESTABLECIMIENTO = p_fk_establecimiento AND e.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'El establecimiento (%) no existe o no esta activo', p_fk_establecimiento
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_id_role IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.role r WHERE r.id_role = p_fk_id_role) THEN
        RAISE EXCEPTION 'El rol (%) no existe en public.role', p_fk_id_role USING ERRCODE = '23503';
    END IF;

    -- La identidad se reutiliza si el correo ya existe: la cuenta es unica
    -- en el SSO y el mismo usuario puede haber sido creado por otro modulo.
    SELECT u.PK_TUSUARIO INTO v_pk_usuario
      FROM pigse.TUSUARIO u
     WHERE UPPER(u.CORREO_ELECTRONICO) = UPPER(TRIM(p_correo_electronico))
       AND u.ACTIVE = TRUE
     LIMIT 1;

    IF v_pk_usuario IS NULL THEN
        SELECT us.id_user INTO v_id_user
          FROM public.users us
         WHERE UPPER(us.email) = UPPER(TRIM(p_correo_electronico))
         LIMIT 1;

        INSERT INTO pigse.TUSUARIO (
            FK_ID_USER, CORREO_ELECTRONICO, IDENTIFICACION,
            FK_TLV_TIPO_DOCUMENTO,
            PRIMER_NOMBRE, SEGUNDO_NOMBRE, PRIMER_APELLIDO, SEGUNDO_APELLIDO,
            TELEFONO, CREATED_BY, CREATED_AT, ACTIVE
        )
        VALUES (
            v_id_user, TRIM(p_correo_electronico), TRIM(p_identificacion),
            p_fk_tlv_tipo_documento,
            TRIM(p_primer_nombre), p_segundo_nombre, TRIM(p_primer_apellido), p_segundo_apellido,
            p_telefono, p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
        )
        RETURNING PK_TUSUARIO INTO v_pk_usuario;
    END IF;

    IF EXISTS (SELECT 1 FROM pigse.TFUNCIONARIO f
                WHERE f.FK_TUSUARIO = v_pk_usuario AND f.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'El usuario "%" ya tiene un funcionario activo', TRIM(p_correo_electronico)
            USING ERRCODE = '23505';
    END IF;

    INSERT INTO pigse.TFUNCIONARIO (
        FK_TUSUARIO, FK_TESTABLECIMIENTO, FK_TLV_CARGO,
        CREATED_BY, CREATED_AT, ACTIVE
    )
    VALUES (
        v_pk_usuario, p_fk_establecimiento, p_fk_tlv_cargo,
        p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
    )
    RETURNING PK_TFUNCIONARIO INTO v_pk_funcionario;

    IF p_fk_id_role IS NOT NULL THEN
        PERFORM pigse.fn_est_usuario_crear(
            p_pk_usuario_solicitante, v_pk_usuario, p_fk_establecimiento, p_fk_id_role
        );
    END IF;

    RETURN v_pk_funcionario;
END;
$$;


CREATE OR REPLACE FUNCTION pigse.fn_fun_actualizar(
    p_pk_usuario_solicitante BIGINT,
    p_pk_funcionario         BIGINT,
    p_correo_electronico     VARCHAR DEFAULT NULL,
    p_identificacion         VARCHAR DEFAULT NULL,
    p_primer_nombre          VARCHAR DEFAULT NULL,
    p_segundo_nombre         VARCHAR DEFAULT NULL,
    p_primer_apellido        VARCHAR DEFAULT NULL,
    p_segundo_apellido       VARCHAR DEFAULT NULL,
    p_telefono               VARCHAR DEFAULT NULL,
    p_fk_tlv_tipo_documento BIGINT DEFAULT NULL,
    p_fk_tlv_cargo  BIGINT  DEFAULT NULL,
    p_fk_establecimiento     BIGINT  DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pigse, academico_test, public
AS $$
DECLARE
    v_pk_usuario BIGINT;
BEGIN
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    IF NOT pigse.fn_usuario_tiene_rol(p_pk_usuario_solicitante,
            ARRAY['PIGSE-ADMINISTRADOR', 'PIGSE-SECRETARIA_TERRITORIAL']::VARCHAR[]) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    SELECT f.FK_TUSUARIO INTO v_pk_usuario
      FROM pigse.TFUNCIONARIO f
     WHERE f.PK_TFUNCIONARIO = p_pk_funcionario AND f.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el funcionario solicitado (%)', p_pk_funcionario
            USING ERRCODE = 'P0002';
    END IF;

    IF p_fk_establecimiento IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pigse.TESTABLECIMIENTO e
                        WHERE e.PK_ESTABLECIMIENTO = p_fk_establecimiento AND e.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'El establecimiento (%) no existe o no esta activo', p_fk_establecimiento
            USING ERRCODE = '23503';
    END IF;

    IF p_correo_electronico IS NOT NULL AND EXISTS (
        SELECT 1 FROM pigse.TUSUARIO u
         WHERE UPPER(u.CORREO_ELECTRONICO) = UPPER(TRIM(p_correo_electronico))
           AND u.ACTIVE = TRUE AND u.PK_TUSUARIO <> v_pk_usuario
    ) THEN
        RAISE EXCEPTION 'Ya existe otro usuario activo con el correo %', p_correo_electronico
            USING ERRCODE = '23505';
    END IF;

    UPDATE pigse.TUSUARIO
       SET CORREO_ELECTRONICO = COALESCE(TRIM(p_correo_electronico), CORREO_ELECTRONICO),
           IDENTIFICACION     = COALESCE(TRIM(p_identificacion), IDENTIFICACION),
           FK_TLV_TIPO_DOCUMENTO =
               COALESCE(p_fk_tlv_tipo_documento, FK_TLV_TIPO_DOCUMENTO),
           PRIMER_NOMBRE      = COALESCE(TRIM(p_primer_nombre), PRIMER_NOMBRE),
           SEGUNDO_NOMBRE     = COALESCE(p_segundo_nombre, SEGUNDO_NOMBRE),
           PRIMER_APELLIDO    = COALESCE(TRIM(p_primer_apellido), PRIMER_APELLIDO),
           SEGUNDO_APELLIDO   = COALESCE(p_segundo_apellido, SEGUNDO_APELLIDO),
           TELEFONO           = COALESCE(p_telefono, TELEFONO),
           MODIFIED_BY        = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT        = CURRENT_TIMESTAMP
     WHERE PK_TUSUARIO = v_pk_usuario;

    UPDATE pigse.TFUNCIONARIO
       SET FK_TESTABLECIMIENTO   = COALESCE(p_fk_establecimiento, FK_TESTABLECIMIENTO),
           FK_TLV_CARGO = COALESCE(p_fk_tlv_cargo, FK_TLV_CARGO),
           MODIFIED_BY           = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT           = CURRENT_TIMESTAMP
     WHERE PK_TFUNCIONARIO = p_pk_funcionario;

    RETURN TRUE;
END;
$$;


-- Da de baja el perfil laboral y sus asignaciones de rol; la identidad
-- (TUSUARIO) sobrevive porque puede estar enlazada a otros modulos.
CREATE OR REPLACE FUNCTION pigse.fn_fun_soft_delete(
    p_pk_usuario_solicitante BIGINT,
    p_pk_funcionario         BIGINT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pigse, academico_test, public
AS $$
DECLARE
    v_pk_usuario BIGINT;
    v_active     BOOLEAN;
BEGIN
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    IF NOT pigse.fn_usuario_tiene_rol(p_pk_usuario_solicitante,
            ARRAY['PIGSE-ADMINISTRADOR', 'PIGSE-SECRETARIA_TERRITORIAL']::VARCHAR[]) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    SELECT f.FK_TUSUARIO, f.ACTIVE INTO v_pk_usuario, v_active
      FROM pigse.TFUNCIONARIO f
     WHERE f.PK_TFUNCIONARIO = p_pk_funcionario;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el funcionario solicitado (%)', p_pk_funcionario
            USING ERRCODE = 'P0002';
    END IF;

    IF v_active = FALSE THEN
        RAISE EXCEPTION 'El funcionario (%) ya se encuentra inactivo', p_pk_funcionario
            USING ERRCODE = '22023';
    END IF;

    UPDATE pigse.TFUNCIONARIO
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TFUNCIONARIO = p_pk_funcionario;

    UPDATE pigse.TESTABLECIMIENTO_USUARIO
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TUSUARIO = v_pk_usuario AND ACTIVE = TRUE;

    RETURN TRUE;
END;
$$;


CREATE OR REPLACE FUNCTION pigse.fn_fun_listar(
    p_pk_usuario_solicitante BIGINT,
    p_search                 VARCHAR  DEFAULT NULL,
    p_establecimientos       BIGINT[] DEFAULT NULL,
    p_sort_campo             VARCHAR  DEFAULT NULL,
    p_sort_desc              BOOLEAN  DEFAULT FALSE,
    p_page_index             INT      DEFAULT 0,
    p_page_size              INT      DEFAULT 10
)
RETURNS TABLE (
    rows        JSONB,
    total_count BIGINT,
    page_count  BIGINT,
    page_index  INT,
    page_size   INT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pigse, academico_test, public
AS $$
DECLARE
    v_page_size  INT := CASE WHEN p_page_size IS NULL THEN NULL
                             ELSE LEAST(CASE WHEN p_page_size > 0 THEN p_page_size ELSE 10 END, 100) END;
    v_page_index INT := GREATEST(COALESCE(p_page_index, 0), 0);
    v_total      BIGINT;
    v_rows       JSONB := '[]'::JSONB;
BEGIN
    IF NOT pigse.fn_usuario_tiene_rol(p_pk_usuario_solicitante, NULL) THEN
        RAISE EXCEPTION 'El usuario no tiene permiso para ver en el modulo FUNCIONARIO'
            USING ERRCODE = '42501';
    END IF;

    SELECT COUNT(*) INTO v_total
      FROM pigse.TFUNCIONARIO f
      JOIN pigse.TUSUARIO u         ON u.PK_TUSUARIO = f.FK_TUSUARIO
      JOIN pigse.TESTABLECIMIENTO e ON e.PK_ESTABLECIMIENTO = f.FK_TESTABLECIMIENTO
     WHERE f.ACTIVE = TRUE
       AND (NULLIF(TRIM(p_search), '') IS NULL
            OR u.PRIMER_NOMBRE      ILIKE '%' || p_search || '%'
            OR u.PRIMER_APELLIDO    ILIKE '%' || p_search || '%'
            OR u.SEGUNDO_APELLIDO   ILIKE '%' || p_search || '%'
            OR u.IDENTIFICACION     ILIKE '%' || p_search || '%'
            OR u.CORREO_ELECTRONICO ILIKE '%' || p_search || '%'
            OR e.NOMBRE             ILIKE '%' || p_search || '%')
       AND (p_establecimientos IS NULL OR CARDINALITY(p_establecimientos) = 0
            OR f.FK_TESTABLECIMIENTO = ANY(p_establecimientos));

    SELECT COALESCE(jsonb_agg(to_jsonb(t) - 'orden_fila' ORDER BY t.orden_fila), '[]'::JSONB) INTO v_rows
      FROM (
        SELECT f.PK_TFUNCIONARIO      AS pk_funcionario,
               u.PK_TUSUARIO          AS pk_usuario,
               u.IDENTIFICACION       AS identificacion,
               u.PRIMER_NOMBRE        AS primer_nombre,
               u.SEGUNDO_NOMBRE       AS segundo_nombre,
               u.PRIMER_APELLIDO      AS primer_apellido,
               u.SEGUNDO_APELLIDO     AS segundo_apellido,
               u.CORREO_ELECTRONICO   AS correo_electronico,
               u.TELEFONO             AS telefono,
               f.FK_TESTABLECIMIENTO  AS fk_establecimiento,
               e.NOMBRE               AS establecimiento_nombre,
               COALESCE((
                   SELECT jsonb_agg(jsonb_build_object('idRole', r.id_role, 'nombre', r.name)
                                    ORDER BY r.name)
                     FROM pigse.TESTABLECIMIENTO_USUARIO eu
                     JOIN public.role r ON r.id_role = eu.FK_ID_ROLE
                    WHERE eu.FK_TUSUARIO = u.PK_TUSUARIO
                      AND eu.FK_TESTABLECIMIENTO = f.FK_TESTABLECIMIENTO
                      AND eu.ACTIVE = TRUE
               ), '[]'::JSONB) AS roles,
               ROW_NUMBER() OVER (
                   ORDER BY
                     CASE WHEN p_sort_campo = 'name'       AND NOT p_sort_desc THEN u.PRIMER_APELLIDO END ASC,
                     CASE WHEN p_sort_campo = 'name'       AND     p_sort_desc THEN u.PRIMER_APELLIDO END DESC,
                     CASE WHEN p_sort_campo = 'document'   AND NOT p_sort_desc THEN u.IDENTIFICACION  END ASC,
                     CASE WHEN p_sort_campo = 'document'   AND     p_sort_desc THEN u.IDENTIFICACION  END DESC,
                     CASE WHEN p_sort_campo = 'email'      AND NOT p_sort_desc THEN u.CORREO_ELECTRONICO END ASC,
                     CASE WHEN p_sort_campo = 'email'      AND     p_sort_desc THEN u.CORREO_ELECTRONICO END DESC,
                     CASE WHEN p_sort_campo = 'school'     AND NOT p_sort_desc THEN e.NOMBRE END ASC,
                     CASE WHEN p_sort_campo = 'school'     AND     p_sort_desc THEN e.NOMBRE END DESC,
                     u.PRIMER_APELLIDO ASC, f.PK_TFUNCIONARIO ASC
               ) AS orden_fila
          FROM pigse.TFUNCIONARIO f
          JOIN pigse.TUSUARIO u         ON u.PK_TUSUARIO = f.FK_TUSUARIO
          JOIN pigse.TESTABLECIMIENTO e ON e.PK_ESTABLECIMIENTO = f.FK_TESTABLECIMIENTO
         WHERE f.ACTIVE = TRUE
           AND (NULLIF(TRIM(p_search), '') IS NULL
                OR u.PRIMER_NOMBRE      ILIKE '%' || p_search || '%'
                OR u.PRIMER_APELLIDO    ILIKE '%' || p_search || '%'
                OR u.SEGUNDO_APELLIDO   ILIKE '%' || p_search || '%'
                OR u.IDENTIFICACION     ILIKE '%' || p_search || '%'
                OR u.CORREO_ELECTRONICO ILIKE '%' || p_search || '%'
                OR e.NOMBRE             ILIKE '%' || p_search || '%')
           AND (p_establecimientos IS NULL OR CARDINALITY(p_establecimientos) = 0
                OR f.FK_TESTABLECIMIENTO = ANY(p_establecimientos))
         ORDER BY orden_fila
         LIMIT v_page_size
        OFFSET v_page_index * COALESCE(v_page_size, 0)
      ) t;

    RETURN QUERY
    SELECT v_rows,
           v_total,
           CASE WHEN v_total = 0 THEN 0::BIGINT
                WHEN v_page_size IS NULL THEN 1::BIGINT
                ELSE CEIL(v_total::NUMERIC / v_page_size)::BIGINT END,
           v_page_index,
           v_page_size;
END;
$$;


CREATE OR REPLACE FUNCTION pigse.fn_fun_buscar_por_pk(
    p_pk_usuario_solicitante BIGINT,
    p_pk_funcionario         BIGINT
)
RETURNS TABLE (
    pk_funcionario         BIGINT,
    pk_usuario             BIGINT,
    fk_id_user             BIGINT,
    identificacion         VARCHAR,
    fk_tlv_tipo_documento BIGINT,
    primer_nombre          VARCHAR,
    segundo_nombre         VARCHAR,
    primer_apellido        VARCHAR,
    segundo_apellido       VARCHAR,
    correo_electronico     VARCHAR,
    telefono               VARCHAR,
    fk_establecimiento     BIGINT,
    establecimiento_nombre VARCHAR,
    fk_tlv_cargo  BIGINT,
    roles                  JSONB,
    created_by             VARCHAR,
    created_at             TIMESTAMP,
    modified_by            VARCHAR,
    modified_at            TIMESTAMP
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pigse, academico_test, public
AS $$
DECLARE
    v_active BOOLEAN;
BEGIN
    IF NOT pigse.fn_usuario_tiene_rol(p_pk_usuario_solicitante, NULL) THEN
        RAISE EXCEPTION 'El usuario no tiene permiso para ver en el modulo FUNCIONARIO'
            USING ERRCODE = '42501';
    END IF;

    SELECT f.ACTIVE INTO v_active
      FROM pigse.TFUNCIONARIO f
     WHERE f.PK_TFUNCIONARIO = p_pk_funcionario;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el funcionario solicitado (%)', p_pk_funcionario
            USING ERRCODE = 'P0002';
    END IF;

    IF v_active = FALSE THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT f.PK_TFUNCIONARIO, u.PK_TUSUARIO, u.FK_ID_USER,
           u.IDENTIFICACION, u.FK_TLV_TIPO_DOCUMENTO,
           u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE, u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO,
           u.CORREO_ELECTRONICO, u.TELEFONO,
           f.FK_TESTABLECIMIENTO, e.NOMBRE, f.FK_TLV_CARGO,
           COALESCE((
               SELECT jsonb_agg(jsonb_build_object('idRole', r.id_role, 'nombre', r.name)
                                ORDER BY r.name)
                 FROM pigse.TESTABLECIMIENTO_USUARIO eu
                 JOIN public.role r ON r.id_role = eu.FK_ID_ROLE
                WHERE eu.FK_TUSUARIO = u.PK_TUSUARIO
                  AND eu.FK_TESTABLECIMIENTO = f.FK_TESTABLECIMIENTO
                  AND eu.ACTIVE = TRUE
           ), '[]'::JSONB),
           f.CREATED_BY, f.CREATED_AT, f.MODIFIED_BY, f.MODIFIED_AT
      FROM pigse.TFUNCIONARIO f
      JOIN pigse.TUSUARIO u         ON u.PK_TUSUARIO = f.FK_TUSUARIO
      JOIN pigse.TESTABLECIMIENTO e ON e.PK_ESTABLECIMIENTO = f.FK_TESTABLECIMIENTO
     WHERE f.PK_TFUNCIONARIO = p_pk_funcionario;
END;
$$;


-- ---------------------------------------------------------------------------
-- ASIGNACION DE ROLES (usuario x rol x ambito)
-- ---------------------------------------------------------------------------
-- Espejo de academico_test.fn_ente_usuario_crear (V150), pero contra
-- public.role: al alta en pigse tambien se otorga el rol en public.role_users
-- para que el JWT lo refleje sin depender del sync academico.
CREATE OR REPLACE FUNCTION pigse.fn_ente_usuario_crear(
    p_pk_usuario_solicitante BIGINT,
    p_pk_usuario             BIGINT,
    p_fk_ente                BIGINT,
    p_fk_id_role             BIGINT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pigse, academico_test, public
AS $$
DECLARE
    v_id_user BIGINT;
BEGIN
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    IF NOT pigse.fn_usuario_tiene_rol(p_pk_usuario_solicitante,
            ARRAY['PIGSE-ADMINISTRADOR', 'PIGSE-SECRETARIA_TERRITORIAL']::VARCHAR[]) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    IF p_pk_usuario IS NULL OR p_fk_ente IS NULL OR p_fk_id_role IS NULL THEN
        RAISE EXCEPTION 'usuario, ente y rol son obligatorios' USING ERRCODE = '23502';
    END IF;

    SELECT u.FK_ID_USER INTO v_id_user
      FROM pigse.TUSUARIO u
     WHERE u.PK_TUSUARIO = p_pk_usuario AND u.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El usuario (%) no existe o no esta activo', p_pk_usuario
            USING ERRCODE = '23503';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pigse.TENTE e
                    WHERE e.PK_ENTE = p_fk_ente AND e.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'El ente territorial (%) no existe o no esta activo', p_fk_ente
            USING ERRCODE = '23503';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.role r WHERE r.id_role = p_fk_id_role) THEN
        RAISE EXCEPTION 'El rol (%) no existe en public.role', p_fk_id_role
            USING ERRCODE = '23503';
    END IF;

    IF EXISTS (
        SELECT 1 FROM pigse.TENTE_USUARIO eu
         WHERE eu.FK_TENTE = p_fk_ente AND eu.FK_ID_ROLE = p_fk_id_role
           AND eu.FK_TUSUARIO = p_pk_usuario AND eu.ACTIVE = TRUE
    ) THEN
        RETURN TRUE;
    END IF;

    UPDATE pigse.TENTE_USUARIO
       SET ACTIVE = TRUE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TENTE = p_fk_ente AND FK_ID_ROLE = p_fk_id_role
       AND FK_TUSUARIO = p_pk_usuario AND ACTIVE = FALSE;

    IF NOT FOUND THEN
        INSERT INTO pigse.TENTE_USUARIO (
            FK_TENTE, FK_ID_ROLE, FK_TUSUARIO, CREATED_BY, CREATED_AT, ACTIVE
        )
        VALUES (
            p_fk_ente, p_fk_id_role, p_pk_usuario,
            p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
        );
    END IF;

    IF v_id_user IS NOT NULL THEN
        INSERT INTO public.role_users (user_id, role_id)
        SELECT v_id_user, p_fk_id_role
         WHERE NOT EXISTS (
            SELECT 1 FROM public.role_users ru
             WHERE ru.user_id = v_id_user AND ru.role_id = p_fk_id_role
         );
    END IF;

    RETURN TRUE;
END;
$$;


CREATE OR REPLACE FUNCTION pigse.fn_est_usuario_crear(
    p_pk_usuario_solicitante BIGINT,
    p_pk_usuario             BIGINT,
    p_fk_establecimiento     BIGINT,
    p_fk_id_role             BIGINT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pigse, academico_test, public
AS $$
DECLARE
    v_id_user BIGINT;
BEGIN
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    IF NOT pigse.fn_usuario_tiene_rol(p_pk_usuario_solicitante,
            ARRAY['PIGSE-ADMINISTRADOR', 'PIGSE-SECRETARIA_TERRITORIAL']::VARCHAR[]) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    IF p_pk_usuario IS NULL OR p_fk_establecimiento IS NULL OR p_fk_id_role IS NULL THEN
        RAISE EXCEPTION 'usuario, establecimiento y rol son obligatorios' USING ERRCODE = '23502';
    END IF;

    SELECT u.FK_ID_USER INTO v_id_user
      FROM pigse.TUSUARIO u
     WHERE u.PK_TUSUARIO = p_pk_usuario AND u.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El usuario (%) no existe o no esta activo', p_pk_usuario
            USING ERRCODE = '23503';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pigse.TESTABLECIMIENTO e
                    WHERE e.PK_ESTABLECIMIENTO = p_fk_establecimiento AND e.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'El establecimiento (%) no existe o no esta activo', p_fk_establecimiento
            USING ERRCODE = '23503';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.role r WHERE r.id_role = p_fk_id_role) THEN
        RAISE EXCEPTION 'El rol (%) no existe en public.role', p_fk_id_role
            USING ERRCODE = '23503';
    END IF;

    IF EXISTS (
        SELECT 1 FROM pigse.TESTABLECIMIENTO_USUARIO eu
         WHERE eu.FK_TESTABLECIMIENTO = p_fk_establecimiento AND eu.FK_ID_ROLE = p_fk_id_role
           AND eu.FK_TUSUARIO = p_pk_usuario AND eu.ACTIVE = TRUE
    ) THEN
        RETURN TRUE;
    END IF;

    UPDATE pigse.TESTABLECIMIENTO_USUARIO
       SET ACTIVE = TRUE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TESTABLECIMIENTO = p_fk_establecimiento AND FK_ID_ROLE = p_fk_id_role
       AND FK_TUSUARIO = p_pk_usuario AND ACTIVE = FALSE;

    IF NOT FOUND THEN
        INSERT INTO pigse.TESTABLECIMIENTO_USUARIO (
            FK_TESTABLECIMIENTO, FK_ID_ROLE, FK_TUSUARIO, CREATED_BY, CREATED_AT, ACTIVE
        )
        VALUES (
            p_fk_establecimiento, p_fk_id_role, p_pk_usuario,
            p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
        );
    END IF;

    IF v_id_user IS NOT NULL THEN
        INSERT INTO public.role_users (user_id, role_id)
        SELECT v_id_user, p_fk_id_role
         WHERE NOT EXISTS (
            SELECT 1 FROM public.role_users ru
             WHERE ru.user_id = v_id_user AND ru.role_id = p_fk_id_role
         );
    END IF;

    RETURN TRUE;
END;
$$;
