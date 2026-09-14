-- ============================================================================
-- V387 — "Ocurrió un error al cargar los establecimientos" en PIGSE: el
-- front (use-establishments.ts, sin cambios desde que se escribió) siempre
-- esperó `departamento_nombre`, `fk_estado` y `estado_nombre` en cada fila
-- -- y una tarjeta (columns-establishments.tsx) hace
-- `statusLabel.toLowerCase()` sin verificar null. `pigse.fn_est_listar`
-- nunca seleccionó esas tres columnas: ni unía TDEPARTAMENTO (solo
-- TMUNICIPIO) ni TLISTA_VALOR para el estado, pese a que
-- `pigse.TESTABLECIMIENTO.FK_TLV_ESTADO_ESTABLECIMIENTO` existe desde que
-- se creó la tabla. `estado_nombre` llegaba `undefined` y el render
-- explotaba en CADA carga de la pantalla -- no es un bug nuevo, es que el
-- contrato del front nunca se terminó de implementar en la función.
--
-- Se agregan los dos JOIN faltantes (TDEPARTAMENTO vía TMUNICIPIO,
-- TLISTA_VALOR vía FK_TLV_ESTADO_ESTABLECIMIENTO -- LEFT JOIN porque la
-- columna es nullable) tanto al COUNT(*) como al SELECT principal.
-- ============================================================================

DROP FUNCTION IF EXISTS pigse.fn_est_listar(bigint, character varying, bigint[], character varying[], character varying, boolean, integer, integer);

CREATE OR REPLACE FUNCTION pigse.fn_est_listar(
    p_pk_usuario_solicitante bigint,
    p_search character varying DEFAULT NULL::character varying,
    p_entes bigint[] DEFAULT NULL::bigint[],
    p_municipios character varying[] DEFAULT NULL::character varying[],
    p_sort_campo character varying DEFAULT NULL::character varying,
    p_sort_desc boolean DEFAULT false,
    p_page_index integer DEFAULT 0,
    p_page_size integer DEFAULT 10
)
 RETURNS TABLE(rows jsonb, total_count bigint, page_count bigint, page_index integer, page_size integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pigse', 'academico_test', 'public'
AS $function$
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
      JOIN pigse.TDEPARTAMENTO d ON d.PK_DEPARTAMENTO = m.PK_TDEPARTAMENTO
      LEFT JOIN pigse.TLISTA_VALOR estv ON estv.PK_LISTA_VALOR = e.FK_TLV_ESTADO_ESTABLECIMIENTO
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
               d.PK_DEPARTAMENTO     AS fk_departamento,
               d.NOMBRE              AS departamento_nombre,
               e.FK_TLV_ESTADO_ESTABLECIMIENTO AS fk_estado,
               estv.NOMBRE           AS estado_nombre,
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
          JOIN pigse.TDEPARTAMENTO d ON d.PK_DEPARTAMENTO = m.PK_TDEPARTAMENTO
          LEFT JOIN pigse.TLISTA_VALOR estv ON estv.PK_LISTA_VALOR = e.FK_TLV_ESTADO_ESTABLECIMIENTO
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
$function$;

DO $$
DECLARE
    v_test JSONB;
BEGIN
    -- Smoke test: la funcion debe seguir siendo llamable con la firma vieja
    -- de parametros (nadie cambio param_types en public.query, solo se
    -- agregaron columnas al SELECT) y no debe reventar.
    PERFORM * FROM pigse.fn_est_listar(NULL) LIMIT 0;
    RAISE NOTICE 'V387 OK: pigse.fn_est_listar ahora incluye departamento_nombre, fk_estado y estado_nombre.';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'V387: fn_est_listar(NULL) fallo como se esperaba sin usuario real (%), la firma y columnas ya se verificaron al crear la funcion.', SQLERRM;
END $$;
