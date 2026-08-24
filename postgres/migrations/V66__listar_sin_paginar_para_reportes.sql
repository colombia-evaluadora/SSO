-- =============================================================================
-- V66 — p_page_size NULL significa "sin limite" en las funciones de listado.
--
-- Motivacion: el servicio de reporting (JasperReports) tiene que correr las
-- MISMAS funciones que alimentan los listados de pantalla, con los mismos
-- filtros y el mismo gate de autorizacion, pero sin paginar: el reporte lleva
-- todo lo que pasa el filtro, y sin filtros lleva todo.
--
-- Hasta ahora eso era imposible. El tope de pagina no vivia en la capa HTTP
-- sino clavado en el cuerpo de cada funcion:
--
--     v_page_size INT := LEAST(CASE WHEN p_page_size > 0
--                                   THEN p_page_size ELSE 10 END, 100);
--     ...
--      LIMIT v_page_size
--     OFFSET v_page_index * v_page_size;
--
-- Mandar p_page_size = 999999 no servia: LEAST lo recortaba a 100.
--
-- Se descarto la alternativa de crear funciones fn_X_reporte sin paginar:
-- duplicaria el WHERE y el gate de autorizacion de cada listado, y el dia que
-- cambie un filtro el reporte y la pantalla dejarian de coincidir sin que
-- nadie se entere. Reusar la misma funcion mantiene una sola fuente de verdad.
--
-- Cambios, en dos grupos:
--
-- 1. fn_est_listar / fn_sed_listar / fn_usu_empleados_listar
--    p_page_size NULL ahora deja v_page_size en NULL, y PostgreSQL trata
--    LIMIT NULL como "sin clausula LIMIT". El OFFSET pasa a COALESCE(...,0)
--    para no propagar el NULL. Para cualquier valor NO nulo el comportamiento
--    es identico al de hoy, incluido el 0 -> 10 y el tope de 100: la rama
--    vieja se conservo entera dentro del ELSE.
--
-- 2. fn_est_listar_paginado / fn_sed_listar_paginado /
--    fn_usu_empleados_listar_paginado
--    Estos wrappers le reenviaban a la funcion interna los parametros CRUDOS
--    (p_page_index, p_page_size) en vez de los normalizados. Con el cambio 1
--    eso se vuelve peligroso: un pageSize NULL por el endpoint paginado
--    habria devuelto la tabla entera mientras el wrapper reportaba
--    page_size = 10 y page_count = NULL. Ahora reenvian v_page_index /
--    v_page_size, asi que el endpoint paginado NUNCA puede quedar sin tope.
--    Es la unica diferencia en los wrappers; el resto del cuerpo no cambio.
--
-- Sin cambio de firma: misma aridad, mismos tipos, mismos defaults. Ningun
-- llamador existente necesita tocarse.
--
-- Verificacion (ver detalle en el plan): para cada dominio, contar las filas
-- que devuelve fn_X_listar con las paginas en NULL y compararlas contra
-- fn_X_contar con los mismos filtros. Si coinciden, el filtro se respeto y no
-- se perdio ni sobro ninguna fila.
-- =============================================================================

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_est_listar(p_pk_usuario_solicitante bigint, p_search character varying DEFAULT NULL::character varying, p_departamentos bigint[] DEFAULT NULL::bigint[], p_municipios bigint[] DEFAULT NULL::bigint[], p_estados bigint[] DEFAULT NULL::bigint[], p_sort_campo character varying DEFAULT NULL::character varying, p_sort_desc boolean DEFAULT false, p_page_index integer DEFAULT 0, p_page_size integer DEFAULT 10)
 RETURNS TABLE(pk_establecimiento bigint, codigo character varying, nombre character varying, nit character varying, fk_departamento bigint, departamento_nombre character varying, fk_municipio bigint, municipio_nombre character varying, fk_estado bigint, estado_nombre character varying)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_page_size  INT := CASE
        WHEN p_page_size IS NULL THEN NULL   -- reporte: sin limite
        ELSE LEAST(CASE WHEN p_page_size > 0 THEN p_page_size ELSE 10 END, 100)
    END;
    v_page_index INT := GREATEST(COALESCE(p_page_index, 0), 0);
BEGIN
    -- Gate de autorizacion: super-admin ve todo; cualquier otro solo
    -- ve EE de los que es rector O secretaria (FK_TFUNCIONARIO_RECTOR /
    -- FK_TFUNCIONARIO_SECRETARIA -> TFUNCIONARIO activo cuyo FK_TUSUARIO =
    -- p_pk_usuario_solicitante). Mismo patron "ee_accesibles" (rector UNION
    -- secretaria) que fn_sed_listar (V52).
    IF academico_test.fn_puede_afectar_establecimiento(p_pk_usuario_solicitante) THEN
        RETURN QUERY
        SELECT e.PK_ESTABLECIMIENTO, e.CODIGO, e.NOMBRE, e.NIT,
               d.PK_DEPARTAMENTO, d.NOMBRE,
               m.PK_TMUNICIPIO, m.NOMBRE,
               e.FK_TLV_ESTADO_ESTABLECIMIENTO, tlv.NOMBRE
          FROM academico_test.TESTABLECIMIENTO e
          JOIN academico_test.TMUNICIPIO    m ON m.PK_TMUNICIPIO    = e.FK_TMUNICIPIO
          JOIN academico_test.TDEPARTAMENTO d ON d.PK_DEPARTAMENTO  = m.PK_TDEPARTAMENTO
     LEFT JOIN academico_test.TLISTA_VALOR  tlv ON tlv.PK_LISTA_VALOR = e.FK_TLV_ESTADO_ESTABLECIMIENTO
         WHERE e.ACTIVE = TRUE
           AND (NULLIF(TRIM(p_search), '') IS NULL
                OR e.NOMBRE ILIKE '%' || p_search || '%'
                OR e.CODIGO ILIKE '%' || p_search || '%'
                OR d.NOMBRE ILIKE '%' || p_search || '%'
                OR m.NOMBRE ILIKE '%' || p_search || '%')
           AND (p_departamentos IS NULL OR CARDINALITY(p_departamentos) = 0
                OR d.PK_DEPARTAMENTO = ANY(p_departamentos))
           AND (p_municipios IS NULL OR CARDINALITY(p_municipios) = 0
                OR m.PK_TMUNICIPIO = ANY(p_municipios))
           AND (p_estados IS NULL OR CARDINALITY(p_estados) = 0
                OR e.FK_TLV_ESTADO_ESTABLECIMIENTO = ANY(p_estados))
         ORDER BY
            CASE WHEN p_sort_campo = 'name'         AND NOT p_sort_desc THEN e.NOMBRE   END ASC,
            CASE WHEN p_sort_campo = 'name'         AND     p_sort_desc THEN e.NOMBRE   END DESC,
            CASE WHEN p_sort_campo = 'dane'         AND NOT p_sort_desc THEN e.CODIGO   END ASC,
            CASE WHEN p_sort_campo = 'dane'         AND     p_sort_desc THEN e.CODIGO   END DESC,
            CASE WHEN p_sort_campo = 'department'   AND NOT p_sort_desc THEN d.NOMBRE   END ASC,
            CASE WHEN p_sort_campo = 'department'   AND     p_sort_desc THEN d.NOMBRE   END DESC,
            CASE WHEN p_sort_campo = 'municipality' AND NOT p_sort_desc THEN m.NOMBRE   END ASC,
            CASE WHEN p_sort_campo = 'municipality' AND     p_sort_desc THEN m.NOMBRE   END DESC,
            CASE WHEN p_sort_campo = 'status'       AND NOT p_sort_desc THEN tlv.NOMBRE END ASC,
            CASE WHEN p_sort_campo = 'status'       AND     p_sort_desc THEN tlv.NOMBRE END DESC,
            e.NOMBRE ASC,
            e.PK_ESTABLECIMIENTO ASC
         LIMIT v_page_size
        OFFSET v_page_index * COALESCE(v_page_size, 0);
        RETURN;
    END IF;

    -- Camino no-super-admin: filtrar por rector UNION secretaria.
    IF NOT EXISTS (
        WITH ee_accesibles AS (
            SELECT e.PK_ESTABLECIMIENTO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO  f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_RECTOR
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
            UNION
            SELECT e.PK_ESTABLECIMIENTO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO  f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_SECRETARIA
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
        )
        SELECT 1 FROM ee_accesibles
    ) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
    SELECT e.PK_ESTABLECIMIENTO, e.CODIGO, e.NOMBRE, e.NIT,
           d.PK_DEPARTAMENTO, d.NOMBRE,
           m.PK_TMUNICIPIO, m.NOMBRE,
           e.FK_TLV_ESTADO_ESTABLECIMIENTO, tlv.NOMBRE
      FROM academico_test.TESTABLECIMIENTO e
      JOIN (
          SELECT e2.PK_ESTABLECIMIENTO
            FROM academico_test.TESTABLECIMIENTO e2
            JOIN academico_test.TFUNCIONARIO  f ON f.PK_TFUNCIONARIO = e2.FK_TFUNCIONARIO_RECTOR
           WHERE e2.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
          UNION
          SELECT e2.PK_ESTABLECIMIENTO
            FROM academico_test.TESTABLECIMIENTO e2
            JOIN academico_test.TFUNCIONARIO  f ON f.PK_TFUNCIONARIO = e2.FK_TFUNCIONARIO_SECRETARIA
           WHERE e2.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
      ) ee ON ee.PK_ESTABLECIMIENTO = e.PK_ESTABLECIMIENTO
      JOIN academico_test.TMUNICIPIO    m ON m.PK_TMUNICIPIO    = e.FK_TMUNICIPIO
      JOIN academico_test.TDEPARTAMENTO d ON d.PK_DEPARTAMENTO  = m.PK_TDEPARTAMENTO
 LEFT JOIN academico_test.TLISTA_VALOR  tlv ON tlv.PK_LISTA_VALOR = e.FK_TLV_ESTADO_ESTABLECIMIENTO
     WHERE e.ACTIVE = TRUE
       AND (NULLIF(TRIM(p_search), '') IS NULL
            OR e.NOMBRE ILIKE '%' || p_search || '%'
            OR e.CODIGO ILIKE '%' || p_search || '%'
            OR d.NOMBRE ILIKE '%' || p_search || '%'
            OR m.NOMBRE ILIKE '%' || p_search || '%')
       AND (p_departamentos IS NULL OR CARDINALITY(p_departamentos) = 0
            OR d.PK_DEPARTAMENTO = ANY(p_departamentos))
       AND (p_municipios IS NULL OR CARDINALITY(p_municipios) = 0
            OR m.PK_TMUNICIPIO = ANY(p_municipios))
       AND (p_estados IS NULL OR CARDINALITY(p_estados) = 0
            OR e.FK_TLV_ESTADO_ESTABLECIMIENTO = ANY(p_estados))
     ORDER BY
        CASE WHEN p_sort_campo = 'name'         AND NOT p_sort_desc THEN e.NOMBRE   END ASC,
        CASE WHEN p_sort_campo = 'name'         AND     p_sort_desc THEN e.NOMBRE   END DESC,
        CASE WHEN p_sort_campo = 'dane'         AND NOT p_sort_desc THEN e.CODIGO   END ASC,
        CASE WHEN p_sort_campo = 'dane'         AND     p_sort_desc THEN e.CODIGO   END DESC,
        CASE WHEN p_sort_campo = 'department'   AND NOT p_sort_desc THEN d.NOMBRE   END ASC,
        CASE WHEN p_sort_campo = 'department'   AND     p_sort_desc THEN d.NOMBRE   END DESC,
        CASE WHEN p_sort_campo = 'municipality' AND NOT p_sort_desc THEN m.NOMBRE   END ASC,
        CASE WHEN p_sort_campo = 'municipality' AND     p_sort_desc THEN m.NOMBRE   END DESC,
        CASE WHEN p_sort_campo = 'status'       AND NOT p_sort_desc THEN tlv.NOMBRE END ASC,
        CASE WHEN p_sort_campo = 'status'       AND     p_sort_desc THEN tlv.NOMBRE END DESC,
        e.NOMBRE ASC,
        e.PK_ESTABLECIMIENTO ASC
     LIMIT v_page_size
    OFFSET v_page_index * COALESCE(v_page_size, 0);
END;
$function$;

CREATE OR REPLACE FUNCTION academico_test.fn_est_listar_paginado(p_pk_usuario_solicitante bigint, p_search character varying DEFAULT NULL::character varying, p_departamentos bigint[] DEFAULT NULL::bigint[], p_municipios bigint[] DEFAULT NULL::bigint[], p_estados bigint[] DEFAULT NULL::bigint[], p_sort_campo character varying DEFAULT NULL::character varying, p_sort_desc boolean DEFAULT false, p_page_index integer DEFAULT 0, p_page_size integer DEFAULT 10)
 RETURNS TABLE(rows jsonb, total_count bigint, page_count bigint, page_index integer, page_size integer)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_rows_json   JSONB   := '[]'::JSONB;
    v_total       BIGINT;
    v_page_size   INT     := LEAST(CASE WHEN p_page_size > 0 THEN p_page_size ELSE 10 END, 100);
    v_page_index  INT     := GREATEST(COALESCE(p_page_index, 0), 0);
    v_page_count  BIGINT;
    v_one_row     JSONB;
BEGIN
    -- 1) Total de filas que cumplen los filtros (con gate aplicado).
    --    fn_est_contar ya aplica el gate de autorizacion (super-admin OR
    --    rector de >=1 EE activo). Si no cumple, lanza 42501.
    v_total := academico_test.fn_est_contar(
        p_pk_usuario_solicitante,
        p_search,
        p_departamentos,
        p_municipios,
        p_estados
    );

    -- 2) Calculo de page_count (0 si no hay resultados).
    v_page_count := CASE WHEN v_total = 0 THEN 0 ELSE CEIL(v_total::NUMERIC / v_page_size)::BIGINT END;

    -- 3) Captura de la pagina via FOR ... IN SELECT ... LOOP sobre
    --    fn_est_listar. fn_est_listar aplica los mismos filtros + gate y
    --    ya respeta p_page_index/p_page_size.
    FOR
        v_one_row IN
        SELECT to_jsonb(t)
          FROM academico_test.fn_est_listar(
              p_pk_usuario_solicitante,
              p_search,
              p_departamentos,
              p_municipios,
              p_estados,
              p_sort_campo,
              p_sort_desc,
              v_page_index,
              v_page_size
          ) AS t(
              pk_establecimiento, codigo, nombre, nit,
              fk_departamento, departamento_nombre,
              fk_municipio, municipio_nombre,
              fk_estado, estado_nombre
          )
    LOOP
        v_rows_json := v_rows_json || jsonb_build_array(v_one_row);
    END LOOP;

    -- 4) Resultado final en un solo record.
    RETURN QUERY
    SELECT v_rows_json, v_total, v_page_count, v_page_index, v_page_size;
END;
$function$;

CREATE OR REPLACE FUNCTION academico_test.fn_sed_listar(p_pk_usuario_solicitante bigint, p_search character varying DEFAULT NULL::character varying, p_zones bigint[] DEFAULT NULL::bigint[], p_sort_campo character varying DEFAULT NULL::character varying, p_sort_desc boolean DEFAULT false, p_page_index integer DEFAULT 0, p_page_size integer DEFAULT 10)
 RETURNS TABLE(pk_sede bigint, codigo character varying, nombre character varying, consecutivo character varying, fk_zona bigint, zona_nombre character varying, direccion character varying, telefono character varying)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_page_size  INT := CASE
        WHEN p_page_size IS NULL THEN NULL   -- reporte: sin limite
        ELSE LEAST(CASE WHEN p_page_size > 0 THEN p_page_size ELSE 10 END, 100)
    END;
    v_page_index INT := GREATEST(COALESCE(p_page_index, 0), 0);
BEGIN
    -- -----------------------------------------------------------------
    -- Camino (a) super-admin: ve todas las sedes activas (mismo query
    -- legacy, sin filtro por EE).
    -- -----------------------------------------------------------------
    IF academico_test.fn_puede_afectar_establecimiento(p_pk_usuario_solicitante) THEN
        RETURN QUERY
        SELECT s.PK_TSEDE, s.CODIGO, s.NOMBRE, s.CONSECUTIVO,
               s.FK_TLV_ZONA, tlv.NOMBRE,
               s.DIRECCION, s.TELEFONO
          FROM academico_test.TSEDE s
     LEFT JOIN academico_test.TLISTA_VALOR tlv ON tlv.PK_LISTA_VALOR = s.FK_TLV_ZONA
         WHERE s.ACTIVE = TRUE
           AND (NULLIF(TRIM(p_search), '') IS NULL
                OR s.NOMBRE ILIKE '%' || p_search || '%'
                OR s.CODIGO ILIKE '%' || p_search || '%')
           AND (p_zones IS NULL OR CARDINALITY(p_zones) = 0
                OR s.FK_TLV_ZONA = ANY(p_zones))
         ORDER BY
            CASE WHEN p_sort_campo = 'name'   AND NOT p_sort_desc THEN s.NOMBRE END ASC,
            CASE WHEN p_sort_campo = 'name'   AND     p_sort_desc THEN s.NOMBRE END DESC,
            CASE WHEN p_sort_campo = 'dane'   AND NOT p_sort_desc THEN s.CODIGO END ASC,
            CASE WHEN p_sort_campo = 'dane'   AND     p_sort_desc THEN s.CODIGO END DESC,
            CASE WHEN p_sort_campo = 'zone'   AND NOT p_sort_desc THEN tlv.NOMBRE END ASC,
            CASE WHEN p_sort_campo = 'zone'   AND     p_sort_desc THEN tlv.NOMBRE END DESC,
            s.NOMBRE ASC,
            s.PK_TSEDE ASC
         LIMIT v_page_size
        OFFSET v_page_index * COALESCE(v_page_size, 0);
        RETURN;
    END IF;

    -- -----------------------------------------------------------------
    -- Camino no-super-admin: filtra por EE accesibles (rector/secretaria/
    -- jefe de sistema). Si el conjunto de EE accesibles es vacio => 42501.
    -- -----------------------------------------------------------------
    IF NOT EXISTS (
        WITH ee_accesibles AS (
            SELECT e.PK_ESTABLECIMIENTO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO  f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_RECTOR
             WHERE e.ACTIVE      = TRUE
               AND f.ACTIVE      = TRUE
               AND f.FK_TUSUARIO = p_pk_usuario_solicitante
            UNION
            SELECT e.PK_ESTABLECIMIENTO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO  f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_SECRETARIA
             WHERE e.ACTIVE      = TRUE
               AND f.ACTIVE      = TRUE
               AND f.FK_TUSUARIO = p_pk_usuario_solicitante
            UNION
            SELECT DISTINCT s.FK_TESTABLECIMIENTO
              FROM academico_test.TSEDE_USUARIO su
              JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
             WHERE s.ACTIVE       = TRUE
               AND su.ACTIVE      = TRUE
               AND su.FK_TROL     = 8
               AND su.FK_TUSUARIO = p_pk_usuario_solicitante
        )
        SELECT 1 FROM ee_accesibles
    ) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
    SELECT s.PK_TSEDE, s.CODIGO, s.NOMBRE, s.CONSECUTIVO,
           s.FK_TLV_ZONA, tlv.NOMBRE,
           s.DIRECCION, s.TELEFONO
      FROM academico_test.TSEDE s
      JOIN (
          -- Misma CTE ee_accesibles que arriba, materializada inline.
          SELECT e.PK_ESTABLECIMIENTO
            FROM academico_test.TESTABLECIMIENTO e
            JOIN academico_test.TFUNCIONARIO  f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_RECTOR
           WHERE e.ACTIVE      = TRUE
             AND f.ACTIVE      = TRUE
             AND f.FK_TUSUARIO = p_pk_usuario_solicitante
          UNION
          SELECT e.PK_ESTABLECIMIENTO
            FROM academico_test.TESTABLECIMIENTO e
            JOIN academico_test.TFUNCIONARIO  f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_SECRETARIA
           WHERE e.ACTIVE      = TRUE
             AND f.ACTIVE      = TRUE
             AND f.FK_TUSUARIO = p_pk_usuario_solicitante
          UNION
          SELECT DISTINCT s2.FK_TESTABLECIMIENTO
            FROM academico_test.TSEDE_USUARIO su
            JOIN academico_test.TSEDE s2 ON s2.PK_TSEDE = su.FK_TSEDE
           WHERE s2.ACTIVE      = TRUE
             AND su.ACTIVE      = TRUE
             AND su.FK_TROL     = 8
             AND su.FK_TUSUARIO = p_pk_usuario_solicitante
      ) ee ON ee.PK_ESTABLECIMIENTO = s.FK_TESTABLECIMIENTO
 LEFT JOIN academico_test.TLISTA_VALOR tlv ON tlv.PK_LISTA_VALOR = s.FK_TLV_ZONA
     WHERE s.ACTIVE = TRUE
       AND (NULLIF(TRIM(p_search), '') IS NULL
            OR s.NOMBRE ILIKE '%' || p_search || '%'
            OR s.CODIGO ILIKE '%' || p_search || '%')
       AND (p_zones IS NULL OR CARDINALITY(p_zones) = 0
            OR s.FK_TLV_ZONA = ANY(p_zones))
     ORDER BY
        CASE WHEN p_sort_campo = 'name'   AND NOT p_sort_desc THEN s.NOMBRE END ASC,
        CASE WHEN p_sort_campo = 'name'   AND     p_sort_desc THEN s.NOMBRE END DESC,
        CASE WHEN p_sort_campo = 'dane'   AND NOT p_sort_desc THEN s.CODIGO END ASC,
        CASE WHEN p_sort_campo = 'dane'   AND     p_sort_desc THEN s.CODIGO END DESC,
        CASE WHEN p_sort_campo = 'zone'   AND NOT p_sort_desc THEN tlv.NOMBRE END ASC,
        CASE WHEN p_sort_campo = 'zone'   AND     p_sort_desc THEN tlv.NOMBRE END DESC,
        s.NOMBRE ASC,
        s.PK_TSEDE ASC
     LIMIT v_page_size
    OFFSET v_page_index * COALESCE(v_page_size, 0);
END;
$function$;

CREATE OR REPLACE FUNCTION academico_test.fn_sed_listar_paginado(p_pk_usuario_solicitante bigint, p_search character varying DEFAULT NULL::character varying, p_zones bigint[] DEFAULT NULL::bigint[], p_sort_campo character varying DEFAULT NULL::character varying, p_sort_desc boolean DEFAULT false, p_page_index integer DEFAULT 0, p_page_size integer DEFAULT 10)
 RETURNS TABLE(rows jsonb, total_count bigint, page_count bigint, page_index integer, page_size integer)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_rows_json   JSONB   := '[]'::JSONB;
    v_total       BIGINT;
    v_page_size   INT     := LEAST(CASE WHEN p_page_size > 0 THEN p_page_size ELSE 10 END, 100);
    v_page_index  INT     := GREATEST(COALESCE(p_page_index, 0), 0);
    v_page_count  BIGINT;
    v_one_row     JSONB;
BEGIN
    -- 1) Total de filas que cumplen los filtros (con gate aplicado).
    --    fn_sed_contar ya aplica el gate de autorizacion (super-admin OR
    --    rector/secretaria/jefe de sistema de >=1 EE activo). Si no
    --    cumple, lanza 42501.
    v_total := academico_test.fn_sed_contar(
        p_pk_usuario_solicitante,
        p_search,
        p_zones
    );

    -- 2) Calculo de page_count (0 si no hay resultados).
    v_page_count := CASE WHEN v_total = 0 THEN 0 ELSE CEIL(v_total::NUMERIC / v_page_size)::BIGINT END;

    -- 3) Captura de la pagina via FOR ... IN SELECT ... LOOP sobre
    --    fn_sed_listar. fn_sed_listar aplica los mismos filtros + gate y
    --    ya respeta p_page_index/p_page_size.
    FOR
        v_one_row IN
        SELECT to_jsonb(t)
          FROM academico_test.fn_sed_listar(
              p_pk_usuario_solicitante,
              p_search,
              p_zones,
              p_sort_campo,
              p_sort_desc,
              v_page_index,
              v_page_size
          ) AS t(
              pk_sede, codigo, nombre, consecutivo,
              fk_zona, zona_nombre,
              direccion, telefono
          )
    LOOP
        v_rows_json := v_rows_json || jsonb_build_array(v_one_row);
    END LOOP;

    -- 4) Resultado final en un solo record.
    RETURN QUERY
    SELECT v_rows_json, v_total, v_page_count, v_page_index, v_page_size;
END;
$function$;

CREATE OR REPLACE FUNCTION academico_test.fn_usu_empleados_listar(p_pk_usuario_solicitante bigint, p_search character varying DEFAULT NULL::character varying, p_roles bigint[] DEFAULT NULL::bigint[], p_work_schedules bigint[] DEFAULT NULL::bigint[], p_statuses character varying[] DEFAULT NULL::character varying[], p_campus_id bigint DEFAULT NULL::bigint, p_sort_campo character varying DEFAULT NULL::character varying, p_sort_desc boolean DEFAULT false, p_page_index integer DEFAULT 0, p_page_size integer DEFAULT 10)
 RETURNS TABLE(pk_empleado bigint, numero_documento character varying, primer_nombre character varying, segundo_nombre character varying, primer_apellido character varying, segundo_apellido character varying, nombre_completo character varying, fk_estado character varying, estado_label character varying, jornada_id bigint, jornada_nombre character varying, roles jsonb, sedes jsonb, estados_permisos jsonb)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_page_size  INT := CASE
        WHEN p_page_size IS NULL THEN NULL   -- reporte: sin limite
        ELSE LEAST(CASE WHEN p_page_size > 0 THEN p_page_size ELSE 10 END, 100)
    END;
    v_page_index INT := GREATEST(COALESCE(p_page_index, 0), 0);
    v_es_super   BOOLEAN := academico_test.fn_puede_afectar_establecimiento(p_pk_usuario_solicitante);
BEGIN
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    -- REV6 (V51 REV5, cambio de modelo -- ver header de V51): ya no se
    -- resuelve UN EE via fn_resolver_establecimiento_unico (fallaba con
    -- NULL si el solicitante administra 2+ EE a la vez, algo que antes
    -- era raro y ahora es comun por como TFUNCIONARIO reusa TUSUARIO).
    -- Se pasa al mismo patron "union de EE accesibles" que ya usa
    -- fn_sed_listar/_contar: rector, secretaria, o jefe de sistema (rol 8
    -- via TSEDE_USUARIO) de CUALQUIERA de sus EE, no de "el unico".
    IF NOT v_es_super AND NOT EXISTS (
        WITH ee_accesibles AS (
            SELECT e.PK_ESTABLECIMIENTO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_RECTOR
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
            UNION
            SELECT e.PK_ESTABLECIMIENTO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_SECRETARIA
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
            UNION
            SELECT DISTINCT s.FK_TESTABLECIMIENTO
              FROM academico_test.TSEDE_USUARIO su
              JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
             WHERE s.ACTIVE = TRUE AND su.ACTIVE = TRUE AND su.FK_TROL = 8 AND su.FK_TUSUARIO = p_pk_usuario_solicitante
        )
        SELECT 1 FROM ee_accesibles
    ) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
    WITH ee_accesibles AS (
        SELECT e.PK_ESTABLECIMIENTO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_RECTOR
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
            UNION
            SELECT e.PK_ESTABLECIMIENTO
              FROM academico_test.TESTABLECIMIENTO e
              JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_SECRETARIA
             WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
            UNION
            SELECT DISTINCT s.FK_TESTABLECIMIENTO
              FROM academico_test.TSEDE_USUARIO su
              JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
             WHERE s.ACTIVE = TRUE AND su.ACTIVE = TRUE AND su.FK_TROL = 8 AND su.FK_TUSUARIO = p_pk_usuario_solicitante
    ),
    funcionarios_ee AS (
        SELECT e.FK_TFUNCIONARIO_RECTOR AS pk_tfuncionario
          FROM academico_test.TESTABLECIMIENTO e
         WHERE e.PK_ESTABLECIMIENTO IN (SELECT PK_ESTABLECIMIENTO FROM ee_accesibles) AND e.ACTIVE = TRUE
           AND e.FK_TFUNCIONARIO_RECTOR IS NOT NULL
        UNION
        SELECT e.FK_TFUNCIONARIO_SECRETARIA
          FROM academico_test.TESTABLECIMIENTO e
         WHERE e.PK_ESTABLECIMIENTO IN (SELECT PK_ESTABLECIMIENTO FROM ee_accesibles) AND e.ACTIVE = TRUE
           AND e.FK_TFUNCIONARIO_SECRETARIA IS NOT NULL
        UNION
        SELECT f3.PK_TFUNCIONARIO
          FROM academico_test.TFUNCIONARIO f3
          JOIN academico_test.TSEDE_USUARIO su ON su.FK_TUSUARIO = f3.FK_TUSUARIO AND su.ACTIVE = TRUE
          JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
         WHERE s.FK_TESTABLECIMIENTO IN (SELECT PK_ESTABLECIMIENTO FROM ee_accesibles) AND f3.ACTIVE = TRUE
    ),
    -- Funcionarios visibles que matchean search/estado/roles/campus/jornada.
    -- A lo sumo el total de funcionarios activos del sistema (o del
    -- establecimiento si no es superadmin) — nunca el universo de
    -- TSEDE_USUARIO. sedes_agg/estados_agg/roles_agg/jornada YA NO se
    -- calculan aqui: se resuelven mas abajo, por fila, despues de
    -- ORDER BY + LIMIT (punto 1 del header).
    base AS (
        SELECT DISTINCT f.PK_TFUNCIONARIO, u.PK_TUSUARIO, u.IDENTIFICACION,
               u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
               u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO,
               u.ESTADO
          FROM academico_test.TFUNCIONARIO f
          JOIN academico_test.TUSUARIO      u ON u.PK_TUSUARIO = f.FK_TUSUARIO
         WHERE f.ACTIVE = TRUE
           AND (v_es_super OR f.PK_TFUNCIONARIO IN (SELECT pk_tfuncionario FROM funcionarios_ee))
           AND (NULLIF(TRIM(p_search), '') IS NULL
                OR (COALESCE(u.PRIMER_NOMBRE,'') || ' ' || COALESCE(u.SEGUNDO_NOMBRE,'') || ' ' ||
                    COALESCE(u.PRIMER_APELLIDO,'') || ' ' || COALESCE(u.SEGUNDO_APELLIDO,'') || ' ' ||
                    COALESCE(u.IDENTIFICACION,'')) ILIKE '%' || p_search || '%'
                OR EXISTS (
                    SELECT 1 FROM academico_test.TSEDE_USUARIO su2
                      JOIN academico_test.TSEDE  s ON s.PK_TSEDE = su2.FK_TSEDE
                      JOIN academico_test.TROL   r ON r.PK_TROL  = su2.FK_TROL
                     WHERE su2.FK_TUSUARIO = u.PK_TUSUARIO
                       AND su2.ACTIVE      = TRUE
                       AND (s.NOMBRE ILIKE '%' || p_search || '%'
                            OR r.NOMBRE ILIKE '%' || p_search || '%')
                  )
           )
           AND (p_statuses IS NULL OR CARDINALITY(p_statuses) = 0
                OR u.ESTADO = ANY(
                    SELECT CASE
                             WHEN x = 'ACTIVE'    THEN 'A'
                             WHEN x = 'SUSPENDED' THEN 'I'
                           END
                      FROM unnest(p_statuses) AS x
                     WHERE x IN ('ACTIVE','SUSPENDED')
                ))
           AND (p_campus_id IS NULL OR EXISTS (
                SELECT 1 FROM academico_test.TSEDE_USUARIO su3
                 WHERE su3.FK_TUSUARIO = u.PK_TUSUARIO
                   AND su3.ACTIVE      = TRUE
                   AND su3.FK_TSEDE    = p_campus_id
           ))
           AND (p_roles IS NULL OR CARDINALITY(p_roles) = 0 OR EXISTS (
                SELECT 1 FROM academico_test.TSEDE_USUARIO su4
                 WHERE su4.FK_TUSUARIO = u.PK_TUSUARIO
                   AND su4.ACTIVE      = TRUE
                   AND su4.FK_TROL     = ANY(p_roles)
           ))
           AND (p_work_schedules IS NULL OR CARDINALITY(p_work_schedules) = 0 OR EXISTS (
                SELECT 1 FROM academico_test.TSEDE_USUARIO su5
                 WHERE su5.FK_TUSUARIO    = u.PK_TUSUARIO
                   AND su5.ACTIVE         = TRUE
                   AND su5.FK_TLV_JORNADA = ANY(p_work_schedules)
           ))
    )
    SELECT b.PK_TFUNCIONARIO,
           b.IDENTIFICACION,
           b.PRIMER_NOMBRE,
           b.SEGUNDO_NOMBRE,
           b.PRIMER_APELLIDO,
           b.SEGUNDO_APELLIDO,
           TRIM(COALESCE(b.PRIMER_NOMBRE,'') || ' ' || COALESCE(b.SEGUNDO_NOMBRE,'')
                || ' ' || COALESCE(b.PRIMER_APELLIDO,'') || ' ' || COALESCE(b.SEGUNDO_APELLIDO,''))::VARCHAR AS nombre_completo,
           b.ESTADO::VARCHAR AS fk_estado,
           (CASE b.ESTADO
                WHEN 'A' THEN 'ACTIVE'
                WHEN 'I' THEN 'SUSPENDED'
                ELSE NULL
           END)::VARCHAR      AS estado_label,
           jp.jornada_id,
           jp.jornada_nombre,
           -- roles_agg: ya era una subquery correlacionada (patron correcto,
           -- sin cambios). Se evalua solo para las filas que sobreviven
           -- ORDER BY + LIMIT, igual que sedes_agg/estados_agg de abajo.
           COALESCE(
               (SELECT jsonb_agg(DISTINCT role_obj ORDER BY role_obj)
                  FROM (
                      SELECT jsonb_build_object('id', r.PK_TROL, 'nombre', r.NOMBRE) AS role_obj
                        FROM academico_test.TSEDE_USUARIO su_r
                        JOIN academico_test.TROL          r ON r.PK_TROL = su_r.FK_TROL
                       WHERE su_r.FK_TUSUARIO = b.PK_TUSUARIO
                         AND su_r.ACTIVE      = TRUE
                      UNION
                      SELECT jsonb_build_object('id', 7, 'nombre', 'Rector')
                       WHERE EXISTS (
                           SELECT 1 FROM academico_test.TESTABLECIMIENTO e
                            WHERE e.FK_TFUNCIONARIO_RECTOR = b.PK_TFUNCIONARIO AND e.ACTIVE = TRUE
                       )
                      UNION
                      SELECT jsonb_build_object('id', 17, 'nombre', 'Secretaria')
                       WHERE EXISTS (
                           SELECT 1 FROM academico_test.TESTABLECIMIENTO e
                            WHERE e.FK_TFUNCIONARIO_SECRETARIA = b.PK_TFUNCIONARIO AND e.ACTIVE = TRUE
                       )
                  ) roles_union),
               '[]'::jsonb
           )                             AS roles_agg,
           -- sedes_agg / estados_agg: FIX V71. Antes venian de un CTE
           -- `agregados` con GROUP BY sobre TODO TSEDE_USUARIO activo
           -- (126 704 usuarios en el servidor de test), unido con LEFT
           -- JOIN normal -> Postgres no podia empujar el filtro de `base`
           -- adentro y tenia que materializar el agregado completo antes
           -- de filtrar (11.5s medidos, aislado). Ahora son subqueries
           -- correlacionadas directas contra b.PK_TUSUARIO, exactamente
           -- el mismo patron que roles_agg de arriba: Postgres las evalua
           -- perezosamente solo para las <=v_page_size filas finales.
           COALESCE(
               (SELECT jsonb_agg(DISTINCT jsonb_build_object('id', s.PK_TSEDE, 'nombre', s.NOMBRE)
                                  ORDER BY jsonb_build_object('id', s.PK_TSEDE, 'nombre', s.NOMBRE))
                  FROM academico_test.TSEDE_USUARIO su_s
                  JOIN academico_test.TSEDE         s ON s.PK_TSEDE = su_s.FK_TSEDE
                 WHERE su_s.FK_TUSUARIO = b.PK_TUSUARIO AND su_s.ACTIVE = TRUE),
               '[]'::jsonb
           )                             AS sedes_agg,
           COALESCE(
               (SELECT jsonb_agg(DISTINCT su_e.TLV_ESTADO ORDER BY su_e.TLV_ESTADO)
                  FROM academico_test.TSEDE_USUARIO su_e
                 WHERE su_e.FK_TUSUARIO = b.PK_TUSUARIO AND su_e.ACTIVE = TRUE),
               '[]'::jsonb
           )                             AS estados_agg
      FROM base b
      -- jornada: FIX V71. Antes CTE `jornada_pick` con DISTINCT ON sobre
      -- TODO TSEDE_USUARIO activo (mismo problema de alcance que
      -- `agregados`, aunque con costo propio menor: ~165ms aislado por el
      -- sort de 130K filas). LATERAL + LIMIT 1 aplica exactamente la
      -- misma regla (PREDETERMINADO=1 si existe, si no ORDEN minimo) pero
      -- solo para las filas de `base`, y usa
      -- idx_tsede_usuario_fk_tusuario_activo (V71) para resolver el
      -- ORDER BY sin sort.
      LEFT JOIN LATERAL (
            SELECT su.FK_TLV_JORNADA AS jornada_id, tlv.NOMBRE AS jornada_nombre
              FROM academico_test.TSEDE_USUARIO su
              JOIN academico_test.TLISTA_VALOR  tlv ON tlv.PK_LISTA_VALOR = su.FK_TLV_JORNADA
             WHERE su.FK_TUSUARIO = b.PK_TUSUARIO AND su.ACTIVE = TRUE
             ORDER BY su.PREDETERMINADO DESC, su.ORDEN ASC, su.PK_TSEDE_USUARIO ASC
             LIMIT 1
      ) jp ON TRUE
     ORDER BY
        CASE WHEN p_sort_campo = 'name'      AND NOT p_sort_desc
             THEN TRIM(COALESCE(b.PRIMER_NOMBRE,'') || ' ' || COALESCE(b.SEGUNDO_NOMBRE,'')
                       || ' ' || COALESCE(b.PRIMER_APELLIDO,'') || ' ' || COALESCE(b.SEGUNDO_APELLIDO,''))
        END ASC,
        CASE WHEN p_sort_campo = 'name'      AND     p_sort_desc
             THEN TRIM(COALESCE(b.PRIMER_NOMBRE,'') || ' ' || COALESCE(b.SEGUNDO_NOMBRE,'')
                       || ' ' || COALESCE(b.PRIMER_APELLIDO,'') || ' ' || COALESCE(b.SEGUNDO_APELLIDO,''))
        END DESC,
        CASE WHEN p_sort_campo = 'document'  AND NOT p_sort_desc THEN b.IDENTIFICACION END ASC,
        CASE WHEN p_sort_campo = 'document'  AND     p_sort_desc THEN b.IDENTIFICACION END DESC,
        CASE WHEN p_sort_campo = 'status'    AND NOT p_sort_desc THEN b.ESTADO END ASC,
        CASE WHEN p_sort_campo = 'status'    AND     p_sort_desc THEN b.ESTADO END DESC,
        b.PRIMER_NOMBRE  ASC,
        b.PRIMER_APELLIDO ASC,
        b.PK_TFUNCIONARIO ASC
     LIMIT v_page_size
    OFFSET v_page_index * COALESCE(v_page_size, 0);
END;
$function$;

CREATE OR REPLACE FUNCTION academico_test.fn_usu_empleados_listar_paginado(p_pk_usuario_solicitante bigint, p_search character varying DEFAULT NULL::character varying, p_roles bigint[] DEFAULT NULL::bigint[], p_work_schedules bigint[] DEFAULT NULL::bigint[], p_statuses character varying[] DEFAULT NULL::character varying[], p_campus_id bigint DEFAULT NULL::bigint, p_sort_campo character varying DEFAULT NULL::character varying, p_sort_desc boolean DEFAULT false, p_page_index integer DEFAULT 0, p_page_size integer DEFAULT 10)
 RETURNS TABLE(rows jsonb, total_count bigint, page_count bigint, page_index integer, page_size integer)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_rows_json   JSONB   := '[]'::JSONB;
    v_total       BIGINT;
    v_page_size   INT     := LEAST(CASE WHEN p_page_size > 0 THEN p_page_size ELSE 10 END, 100);
    v_page_index  INT     := GREATEST(COALESCE(p_page_index, 0), 0);
    v_page_count  BIGINT;
    v_one_row     JSONB;
BEGIN
    v_total := academico_test.fn_usu_empleados_contar(
        p_pk_usuario_solicitante, p_search, p_roles, p_work_schedules, p_statuses, p_campus_id
    );

    v_page_count := CASE WHEN v_total = 0 THEN 0 ELSE CEIL(v_total::NUMERIC / v_page_size)::BIGINT END;

    FOR
        v_one_row IN
        SELECT to_jsonb(t)
          FROM academico_test.fn_usu_empleados_listar(
              p_pk_usuario_solicitante, p_search, p_roles, p_work_schedules, p_statuses, p_campus_id,
              p_sort_campo, p_sort_desc, v_page_index, v_page_size
          ) AS t(
              pk_empleado, numero_documento, primer_nombre, segundo_nombre,
              primer_apellido, segundo_apellido, nombre_completo,
              fk_estado, estado_label, jornada_id, jornada_nombre,
              roles, sedes, estados_permisos
          )
    LOOP
        v_rows_json := v_rows_json || jsonb_build_array(v_one_row);
    END LOOP;

    RETURN QUERY
    SELECT v_rows_json, v_total, v_page_count, v_page_index, v_page_size;
END;
$function$;
