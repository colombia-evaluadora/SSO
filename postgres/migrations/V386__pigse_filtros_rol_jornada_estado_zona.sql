-- ============================================================================
-- V386 — P2 de la auditoria de paridad PIGSE/CEVAL: /funcionarios/query no
-- aceptaba filtrar por Rol/Jornada/Estado (el front los tenia recortados a
-- solo texto libre, documentado como limitacion de backend) y /sedes/query
-- no aceptaba filtrar por Zona.
--
-- CEVAL resuelve esto con fn_usu_empleados_listar_paginado (roles/jornadas/
-- estados como VARCHAR[], matcheando "el funcionario tiene AL MENOS UN
-- permiso que matchea"), pero su implementacion real son varias funciones
-- encadenadas y con varios overloads acumulados -- replicar esa arquitectura
-- exacta no es proporcional. Acá se logra el mismo resultado visible
-- (filtrar por cualquiera de los permisos activos del funcionario) con un
-- EXISTS directo contra pigse.TSEDE_USUARIO, mas simple porque el modelo de
-- PIGSE tambien lo es.
-- ============================================================================

DROP FUNCTION IF EXISTS pigse.fn_fun_listar(bigint, character varying, bigint[], character varying, boolean, integer, integer);

CREATE OR REPLACE FUNCTION pigse.fn_fun_listar(
    p_pk_usuario_solicitante bigint,
    p_search character varying DEFAULT NULL::character varying,
    p_establecimientos bigint[] DEFAULT NULL::bigint[],
    p_roles character varying[] DEFAULT NULL::character varying[],
    p_jornadas character varying[] DEFAULT NULL::character varying[],
    p_estados character varying[] DEFAULT NULL::character varying[],
    p_sort_campo character varying DEFAULT NULL::character varying,
    p_sort_desc boolean DEFAULT false,
    p_page_index integer DEFAULT 0,
    p_page_size integer DEFAULT 10
)
 RETURNS TABLE(rows jsonb, total_count bigint, page_count bigint, page_index integer, page_size integer)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'pigse', 'public'
AS $function$
DECLARE
    v_page_size  INT := CASE WHEN p_page_size IS NULL THEN NULL
                             ELSE LEAST(CASE WHEN p_page_size > 0 THEN p_page_size ELSE 10 END, 100) END;
    v_page_index INT := GREATEST(COALESCE(p_page_index, 0), 0);
    v_total      BIGINT;
    v_rows       JSONB := '[]'::JSONB;
BEGIN
    PERFORM pigse.fn_assert_permiso_funcionario(p_pk_usuario_solicitante, 'VER');

    SELECT COUNT(*) INTO v_total
      FROM pigse.TFUNCIONARIO f
      JOIN pigse.TUSUARIO u ON u.PK_TUSUARIO = f.FK_TUSUARIO
      JOIN pigse.TESTABLECIMIENTO e ON e.PK_ESTABLECIMIENTO = f.FK_TESTABLECIMIENTO
     WHERE f.ACTIVE = TRUE
       AND (NULLIF(TRIM(p_search), '') IS NULL
            OR u.PRIMER_NOMBRE ILIKE '%' || p_search || '%' OR u.PRIMER_APELLIDO ILIKE '%' || p_search || '%'
            OR u.SEGUNDO_APELLIDO ILIKE '%' || p_search || '%' OR u.IDENTIFICACION ILIKE '%' || p_search || '%'
            OR u.CORREO_ELECTRONICO ILIKE '%' || p_search || '%' OR e.NOMBRE ILIKE '%' || p_search || '%')
       AND (p_establecimientos IS NULL OR CARDINALITY(p_establecimientos) = 0 OR f.FK_TESTABLECIMIENTO = ANY(p_establecimientos))
       AND (p_roles IS NULL OR CARDINALITY(p_roles) = 0 OR EXISTS (
               SELECT 1 FROM pigse.TSEDE_USUARIO su
               JOIN public.role r ON r.id_role = su.FK_ID_ROLE
              WHERE su.FK_TUSUARIO = u.PK_TUSUARIO AND su.ACTIVE = TRUE AND r.name = ANY(p_roles)
           ))
       AND (p_jornadas IS NULL OR CARDINALITY(p_jornadas) = 0 OR EXISTS (
               SELECT 1 FROM pigse.TSEDE_USUARIO su
               JOIN pigse.TLISTA_VALOR jr ON jr.PK_LISTA_VALOR = su.FK_TLV_JORNADA
              WHERE su.FK_TUSUARIO = u.PK_TUSUARIO AND su.ACTIVE = TRUE AND jr.NOMBRE = ANY(p_jornadas)
           ))
       AND (p_estados IS NULL OR CARDINALITY(p_estados) = 0 OR EXISTS (
               SELECT 1 FROM pigse.TSEDE_USUARIO su
              WHERE su.FK_TUSUARIO = u.PK_TUSUARIO AND su.ACTIVE = TRUE AND su.TLV_ESTADO = ANY(p_estados)
           ));

    SELECT COALESCE(jsonb_agg(to_jsonb(t) - 'orden_fila' ORDER BY t.orden_fila), '[]'::JSONB) INTO v_rows
      FROM (
        SELECT f.PK_TFUNCIONARIO AS pk_funcionario, u.PK_TUSUARIO AS pk_usuario,
               u.IDENTIFICACION AS identificacion, u.PRIMER_NOMBRE AS primer_nombre,
               u.SEGUNDO_NOMBRE AS segundo_nombre, u.PRIMER_APELLIDO AS primer_apellido,
               u.SEGUNDO_APELLIDO AS segundo_apellido, u.CORREO_ELECTRONICO AS correo_electronico,
               u.TELEFONO AS telefono, f.FK_TESTABLECIMIENTO AS fk_establecimiento,
               e.NOMBRE AS establecimiento_nombre,
               COALESCE((
                   SELECT jsonb_agg(jsonb_build_object(
                              'id', su.PK_TSEDE_USUARIO, 'orden', su.ORDEN,
                              'idRole', r.id_role, 'nombre', r.name,
                              'idSede', s.PK_TSEDE, 'sede', s.NOMBRE,
                              'idJornada', su.FK_TLV_JORNADA, 'jornada', jr.NOMBRE,
                              'estado', su.TLV_ESTADO)
                            ORDER BY su.ORDEN)
                     FROM pigse.TSEDE_USUARIO su
                     JOIN public.role r ON r.id_role = su.FK_ID_ROLE
                     JOIN pigse.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
                     JOIN pigse.TLISTA_VALOR jr ON jr.PK_LISTA_VALOR = su.FK_TLV_JORNADA
                    WHERE su.FK_TUSUARIO = u.PK_TUSUARIO AND su.ACTIVE = TRUE
               ), '[]'::JSONB) AS permisos,
               ROW_NUMBER() OVER (
                   ORDER BY
                     CASE WHEN p_sort_campo = 'name'     AND NOT p_sort_desc THEN u.PRIMER_APELLIDO END ASC,
                     CASE WHEN p_sort_campo = 'name'     AND     p_sort_desc THEN u.PRIMER_APELLIDO END DESC,
                     CASE WHEN p_sort_campo = 'document' AND NOT p_sort_desc THEN u.IDENTIFICACION END ASC,
                     CASE WHEN p_sort_campo = 'document' AND     p_sort_desc THEN u.IDENTIFICACION END DESC,
                     CASE WHEN p_sort_campo = 'email'    AND NOT p_sort_desc THEN u.CORREO_ELECTRONICO END ASC,
                     CASE WHEN p_sort_campo = 'email'    AND     p_sort_desc THEN u.CORREO_ELECTRONICO END DESC,
                     CASE WHEN p_sort_campo = 'school'   AND NOT p_sort_desc THEN e.NOMBRE END ASC,
                     CASE WHEN p_sort_campo = 'school'   AND     p_sort_desc THEN e.NOMBRE END DESC,
                     u.PRIMER_APELLIDO ASC, f.PK_TFUNCIONARIO ASC
               ) AS orden_fila
          FROM pigse.TFUNCIONARIO f
          JOIN pigse.TUSUARIO u ON u.PK_TUSUARIO = f.FK_TUSUARIO
          JOIN pigse.TESTABLECIMIENTO e ON e.PK_ESTABLECIMIENTO = f.FK_TESTABLECIMIENTO
         WHERE f.ACTIVE = TRUE
           AND (NULLIF(TRIM(p_search), '') IS NULL
                OR u.PRIMER_NOMBRE ILIKE '%' || p_search || '%' OR u.PRIMER_APELLIDO ILIKE '%' || p_search || '%'
                OR u.SEGUNDO_APELLIDO ILIKE '%' || p_search || '%' OR u.IDENTIFICACION ILIKE '%' || p_search || '%'
                OR u.CORREO_ELECTRONICO ILIKE '%' || p_search || '%' OR e.NOMBRE ILIKE '%' || p_search || '%')
           AND (p_establecimientos IS NULL OR CARDINALITY(p_establecimientos) = 0 OR f.FK_TESTABLECIMIENTO = ANY(p_establecimientos))
           AND (p_roles IS NULL OR CARDINALITY(p_roles) = 0 OR EXISTS (
                   SELECT 1 FROM pigse.TSEDE_USUARIO su
                   JOIN public.role r ON r.id_role = su.FK_ID_ROLE
                  WHERE su.FK_TUSUARIO = u.PK_TUSUARIO AND su.ACTIVE = TRUE AND r.name = ANY(p_roles)
               ))
           AND (p_jornadas IS NULL OR CARDINALITY(p_jornadas) = 0 OR EXISTS (
                   SELECT 1 FROM pigse.TSEDE_USUARIO su
                   JOIN pigse.TLISTA_VALOR jr ON jr.PK_LISTA_VALOR = su.FK_TLV_JORNADA
                  WHERE su.FK_TUSUARIO = u.PK_TUSUARIO AND su.ACTIVE = TRUE AND jr.NOMBRE = ANY(p_jornadas)
               ))
           AND (p_estados IS NULL OR CARDINALITY(p_estados) = 0 OR EXISTS (
                   SELECT 1 FROM pigse.TSEDE_USUARIO su
                  WHERE su.FK_TUSUARIO = u.PK_TUSUARIO AND su.ACTIVE = TRUE AND su.TLV_ESTADO = ANY(p_estados)
               ))
         ORDER BY orden_fila
         LIMIT v_page_size OFFSET v_page_index * COALESCE(v_page_size, 0)
      ) t;

    RETURN QUERY
    SELECT v_rows, v_total,
           CASE WHEN v_total = 0 THEN 0::BIGINT WHEN v_page_size IS NULL THEN 1::BIGINT
                ELSE CEIL(v_total::NUMERIC / v_page_size)::BIGINT END,
           v_page_index, v_page_size;
END;
$function$;

DROP FUNCTION IF EXISTS pigse.fn_sed_listar(bigint, character varying, bigint, character varying, boolean, integer, integer);

CREATE OR REPLACE FUNCTION pigse.fn_sed_listar(
    p_pk_usuario_solicitante bigint,
    p_search character varying DEFAULT NULL::character varying,
    p_fk_establecimiento bigint DEFAULT NULL::bigint,
    p_zonas character varying[] DEFAULT NULL::character varying[],
    p_sort_campo character varying DEFAULT NULL::character varying,
    p_sort_desc boolean DEFAULT false,
    p_page_index integer DEFAULT 0,
    p_page_size integer DEFAULT 10
)
 RETURNS TABLE(rows jsonb, total_count bigint, page_count bigint, page_index integer, page_size integer)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'pigse', 'public'
AS $function$
DECLARE
    v_page_size  INT := LEAST(GREATEST(COALESCE(p_page_size, 10), 1), 100);
    v_page_index INT := GREATEST(COALESCE(p_page_index, 0), 0);
    v_total      BIGINT;
    v_rows       JSONB := '[]'::JSONB;
BEGIN
    PERFORM pigse.fn_assert_permiso_seccion(p_pk_usuario_solicitante, 'SEDES_EDUCATIVAS', 'VER');

    SELECT COUNT(*) INTO v_total
      FROM pigse.TSEDE s
      JOIN pigse.TESTABLECIMIENTO e ON e.PK_ESTABLECIMIENTO = s.FK_TESTABLECIMIENTO
      JOIN pigse.TLISTA_VALOR zv ON zv.PK_LISTA_VALOR = s.FK_TLV_ZONA
     WHERE s.ACTIVE = TRUE
       AND (NULLIF(TRIM(p_search), '') IS NULL
            OR s.NOMBRE ILIKE '%' || p_search || '%' OR s.CODIGO ILIKE '%' || p_search || '%')
       AND (p_fk_establecimiento IS NULL OR s.FK_TESTABLECIMIENTO = p_fk_establecimiento)
       AND (p_zonas IS NULL OR CARDINALITY(p_zonas) = 0 OR zv.NOMBRE = ANY(p_zonas));

    SELECT COALESCE(jsonb_agg(to_jsonb(t) - 'orden_fila' ORDER BY t.orden_fila), '[]'::JSONB) INTO v_rows
      FROM (
        SELECT s.PK_TSEDE AS pk_sede, s.CODIGO AS codigo, s.NOMBRE AS nombre,
               s.CONSECUTIVO AS consecutivo, s.FK_TLV_ZONA AS fk_zona, zv.NOMBRE AS zona_nombre,
               s.FK_TESTABLECIMIENTO AS fk_establecimiento,
               e.NOMBRE AS establecimiento_nombre, s.DIRECCION AS direccion, s.TELEFONO AS telefono,
               ROW_NUMBER() OVER (
                   ORDER BY
                     CASE WHEN p_sort_campo = 'nombre' AND NOT p_sort_desc THEN s.NOMBRE END ASC,
                     CASE WHEN p_sort_campo = 'nombre' AND     p_sort_desc THEN s.NOMBRE END DESC,
                     s.NOMBRE ASC, s.PK_TSEDE ASC
               ) AS orden_fila
          FROM pigse.TSEDE s
          JOIN pigse.TESTABLECIMIENTO e ON e.PK_ESTABLECIMIENTO = s.FK_TESTABLECIMIENTO
          JOIN pigse.TLISTA_VALOR zv ON zv.PK_LISTA_VALOR = s.FK_TLV_ZONA
         WHERE s.ACTIVE = TRUE
           AND (NULLIF(TRIM(p_search), '') IS NULL
                OR s.NOMBRE ILIKE '%' || p_search || '%' OR s.CODIGO ILIKE '%' || p_search || '%')
           AND (p_fk_establecimiento IS NULL OR s.FK_TESTABLECIMIENTO = p_fk_establecimiento)
           AND (p_zonas IS NULL OR CARDINALITY(p_zonas) = 0 OR zv.NOMBRE = ANY(p_zonas))
         ORDER BY orden_fila
         LIMIT v_page_size OFFSET v_page_index * v_page_size
      ) t;

    RETURN QUERY
    SELECT v_rows, v_total,
           CASE WHEN v_total = 0 THEN 0::BIGINT ELSE CEIL(v_total::NUMERIC / v_page_size)::BIGINT END,
           v_page_index, v_page_size;
END;
$function$;

-- ----------------------------------------------------------------------------
-- Catalogo: /funcionarios/query gana ROL/JORNADA/ESTADO; /sedes/query gana ZONA
-- ----------------------------------------------------------------------------

UPDATE public.query q
   SET query = $Q$SELECT * FROM pigse.fn_fun_listar(
    public.fn_get_pigse_usuario_id(CAST(:CONTEXT.USER_ID AS BIGINT)),
    CAST(:BODY.FILTERS.SEARCH AS VARCHAR),
    CAST(:BODY.FILTERS.ESTABLECIMIENTOS AS BIGINT[]),
    CAST(:BODY.FILTERS.ROL AS VARCHAR[]),
    CAST(:BODY.FILTERS.JORNADA AS VARCHAR[]),
    CAST(:BODY.FILTERS.ESTADO AS VARCHAR[]),
    CAST(:BODY.SORTING.ID AS VARCHAR),
    CAST(:BODY.SORTING.DESC AS BOOLEAN),
    CAST(:BODY.PAGEINDEX AS INTEGER),
    CAST(:BODY.PAGESIZE AS INTEGER)
)
$Q$,
       param_types = param_types || '{"BODY.FILTERS.ROL": "VARCHAR[]", "BODY.FILTERS.JORNADA": "VARCHAR[]", "BODY.FILTERS.ESTADO": "VARCHAR[]"}'::jsonb
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND q.path_template = '/funcionarios/query'
   AND m.serviceid = 'pigse';

UPDATE public.query q
   SET query = $Q$SELECT * FROM pigse.fn_sed_listar(
    public.fn_get_pigse_usuario_id(CAST(:CONTEXT.USER_ID AS BIGINT)),
    CAST(:BODY.FILTERS.SEARCH AS VARCHAR),
    CAST(:BODY.FILTERS.ESTABLECIMIENTO AS BIGINT),
    CAST(:BODY.FILTERS.ZONA AS VARCHAR[]),
    CAST(:BODY.SORTING.ID AS VARCHAR),
    CAST(:BODY.SORTING.DESC AS BOOLEAN),
    CAST(:BODY.PAGEINDEX AS INTEGER),
    CAST(:BODY.PAGESIZE AS INTEGER)
)
$Q$,
       param_types = param_types || '{"BODY.FILTERS.ZONA": "VARCHAR[]"}'::jsonb
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND q.path_template = '/sedes/query'
   AND m.serviceid = 'pigse';

DO $$
DECLARE
    v_fun_ok BOOLEAN;
    v_sed_ok BOOLEAN;
BEGIN
    SELECT (q.param_types ? 'BODY.FILTERS.ROL' AND q.param_types ? 'BODY.FILTERS.JORNADA' AND q.param_types ? 'BODY.FILTERS.ESTADO')
      INTO v_fun_ok
      FROM public.query q JOIN public.microservice m ON m.id_microservice = q.microservice_id
     WHERE q.path_template = '/funcionarios/query' AND m.serviceid = 'pigse';

    SELECT (q.param_types ? 'BODY.FILTERS.ZONA') INTO v_sed_ok
      FROM public.query q JOIN public.microservice m ON m.id_microservice = q.microservice_id
     WHERE q.path_template = '/sedes/query' AND m.serviceid = 'pigse';

    IF NOT coalesce(v_fun_ok, false) OR NOT coalesce(v_sed_ok, false) THEN
        RAISE EXCEPTION 'V386: /funcionarios/query o /sedes/query no ganaron sus nuevos filtros (fun=%, sed=%)', v_fun_ok, v_sed_ok;
    END IF;

    RAISE NOTICE 'V386 OK: /funcionarios/query filtra por rol/jornada/estado, /sedes/query filtra por zona.';
END $$;
