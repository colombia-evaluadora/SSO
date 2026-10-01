-- ===========================================================================
-- V257 - PIGSE: CRUD de entes, alta/edicion/baja de establecimientos y alta
-- de usuarios de ente y de establecimiento.
-- fn_est_crear/fn_est_actualizar viven en V394/V362 (14 parametros); la firma de
-- 12 que creaba esta migracion se borra en V362.1.
-- ===========================================================================


SET search_path TO pigse, academico_test, public;

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
