-- ============================================================================
-- V368 — "Gestión Documental" para PIGSE-ADMINISTRADOR/PIGSE-SECRETARIA_TERRITORIAL:
-- deben ver los documentos de TODAS las instituciones (con el nombre del EE
-- dueño de cada fila), no solo el propio establecimiento del token.
--
-- pigse.fn_documentos_listar(p_fk_establecimiento) ya existe (V149/V261) y
-- sigue intacta -- la usan PIGSE-RECTOR/PIGSE-SECRETARIO para SU EE, vía
-- `GET /documentos` (pigse.fn_mi_establecimiento(:CONTEXT.EMAIL)). Esta
-- migración agrega una variante "todos" con el mismo shape + 2 columnas
-- nuevas (establecimientoId/establecimientoNombre), sin tocar la existente.
-- ============================================================================

CREATE OR REPLACE FUNCTION pigse.fn_documentos_listar_todos()
RETURNS TABLE (
    id                    TEXT,
    "type"                TEXT,
    "typeName"            TEXT,
    status                TEXT,
    "fileName"            TEXT,
    "uploadedAt"          TIMESTAMP,
    "sizeBytes"           BIGINT,
    "archivoId"           BIGINT,
    "downloadUrl"         TEXT,
    "establecimientoId"   BIGINT,
    "establecimientoNombre" TEXT
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        tipos.tipo AS id,
        tipos.tipo AS "type",
        tipos.nombre AS "typeName",
        CASE
            WHEN tipos.tipo = 'PEI' AND te.ETNIAS = 'S' THEN 'NO_APLICA'
            WHEN tipos.tipo = 'PEC' AND te.ETNIAS = 'N' THEN 'NO_APLICA'
            WHEN d.fk_tarchivo IS NOT NULL THEN 'COMPLETO'
            ELSE 'PENDIENTE'
        END AS status,
        ta.nombre AS "fileName",
        ta.created_at AS "uploadedAt",
        ta.peso AS "sizeBytes",
        ta.pk_tarchivo AS "archivoId",
        CASE WHEN ta.pk_tarchivo IS NOT NULL
             THEN '/api/files/download/' || ta.pk_tarchivo
             ELSE NULL
        END AS "downloadUrl",
        te.PK_ESTABLECIMIENTO AS "establecimientoId",
        te.NOMBRE AS "establecimientoNombre"
      FROM pigse.testablecimiento te
     CROSS JOIN (VALUES
                    ('PEI', 'Proyecto Educativo Institucional (PEI)'),
                    ('PEC', 'Proyecto Educativo Comunitario (PEC)'),
                    ('PMI', 'Plan de Mejoramiento Institucional (PMI)')
                ) AS tipos(tipo, nombre)
      LEFT JOIN pigse.tdocumento_institucional d
             ON d.fk_testablecimiento = te.PK_ESTABLECIMIENTO
            AND d.tipo = tipos.tipo
            AND d.active
      LEFT JOIN pigse.v_archivo ta ON ta.pk_tarchivo = d.fk_tarchivo
     WHERE te.ACTIVE = TRUE
     ORDER BY te.NOMBRE, tipos.tipo;
$$;

COMMENT ON FUNCTION pigse.fn_documentos_listar_todos() IS
    'V368: variante de fn_documentos_listar SIN scope de establecimiento -- para PIGSE-ADMINISTRADOR/PIGSE-SECRETARIA_TERRITORIAL, que deben ver el estado de entrega de TODAS las instituciones, no solo la propia. Agrega establecimientoId/establecimientoNombre.';

-- ---------------------------------------------------------------------------
-- Paginado real (servidor) -- mismo patron que
-- pigse.fn_cumplimiento_listar_paginado (Monitoreo y Cumplimiento): pagina
-- SOBRE fn_documentos_listar_todos() en SQL, devuelve una sola fila
-- (rows jsonb, total_count, page_count, page_index, page_size) que el
-- front desenvuelve con unwrapPaginated. Nada de traer todo y paginar en
-- el cliente -- esa pantalla, con cientos de instituciones x 3 tipos,
-- no puede permitirselo.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pigse.fn_documentos_listar_todos_paginado(
    p_search      VARCHAR DEFAULT NULL,
    p_sort_campo  VARCHAR DEFAULT NULL,
    p_sort_desc   BOOLEAN DEFAULT FALSE,
    p_page_index  INTEGER DEFAULT 0,
    p_page_size   INTEGER DEFAULT 10
)
RETURNS TABLE (rows JSONB, total_count BIGINT, page_count INTEGER, page_index INTEGER, page_size INTEGER)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_page_size  INTEGER := GREATEST(1, LEAST(COALESCE(p_page_size, 10), 200));
    v_page_index INTEGER := GREATEST(0, COALESCE(p_page_index, 0));
    v_campo      VARCHAR := COALESCE(NULLIF(p_sort_campo, ''), 'establecimientoNombre');
    v_desc       BOOLEAN := COALESCE(p_sort_desc, FALSE);
BEGIN
    RETURN QUERY
    WITH base AS (
        SELECT * FROM pigse.fn_documentos_listar_todos()
    ),
    filtrada AS (
        SELECT b.*
          FROM base b
         WHERE NULLIF(p_search, '') IS NULL
            OR translate(lower(b."establecimientoNombre"), 'áéíóúüñ', 'aeiouun')
               LIKE '%' || translate(lower(p_search), 'áéíóúüñ', 'aeiouun') || '%'
    ),
    numerada AS (
        SELECT f.*,
               ROW_NUMBER() OVER (
                   ORDER BY
                       CASE WHEN v_campo = 'establecimientoNombre' AND v_desc
                            THEN f."establecimientoNombre" END DESC,
                       f."establecimientoNombre" ASC,
                       f."type" ASC
               ) AS rn
          FROM filtrada f
    ),
    pagina AS (
        SELECT * FROM numerada
         WHERE rn >  v_page_index * v_page_size
           AND rn <= (v_page_index + 1) * v_page_size
    )
    SELECT
        COALESCE((SELECT jsonb_agg(to_jsonb(p) - 'rn' ORDER BY p.rn) FROM pagina p), '[]'::jsonb),
        (SELECT COUNT(*) FROM filtrada),
        GREATEST(1, CEIL((SELECT COUNT(*) FROM filtrada)::numeric / v_page_size)::integer),
        v_page_index,
        v_page_size;
END;
$$;

COMMENT ON FUNCTION pigse.fn_documentos_listar_todos_paginado(VARCHAR, VARCHAR, BOOLEAN, INTEGER, INTEGER) IS
    'V368: variante paginada (servidor) de fn_documentos_listar_todos, mismo patron que fn_cumplimiento_listar_paginado.';

INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT gen_random_uuid()::text,
       $q$SELECT * FROM pigse.fn_documentos_listar_todos_paginado(
           CAST(:BODY.FILTERS.SEARCH AS VARCHAR),
           CAST(:BODY.SORTING.ID AS VARCHAR),
           CAST(:BODY.SORTING.DESC AS BOOLEAN),
           CAST(:BODY.PAGEINDEX AS INTEGER),
           CAST(:BODY.PAGESIZE AS INTEGER)
       )$q$,
       'postgres', false, false, m.id_microservice, '/documentos/todos/query', 'SELECT', 'POST',
       '{"BODY.PAGESIZE":"INTEGER","BODY.PAGEINDEX":"INTEGER","BODY.SORTING.ID":"VARCHAR","BODY.SORTING.DESC":"BOOLEAN","BODY.FILTERS.SEARCH":"VARCHAR"}'::jsonb,
       'Gestion documental PIGSE: documentos de TODAS las instituciones, paginado real en servidor, para roles de fiscalizacion (admin/secretaria territorial).'
  FROM public.microservice m
 WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE microservice_id = m.id_microservice AND path_template = '/documentos/todos/query' AND http_method = 'POST');

INSERT INTO public.role_query (role_id, query_id)
SELECT ro.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  CROSS JOIN public.role ro
 WHERE m.serviceid = 'pigse'
   AND q.path_template IN ('/documentos/todos', '/documentos/todos/query')
   AND ro.name IN ('PIGSE-ADMINISTRADOR', 'PIGSE-SECRETARIA_TERRITORIAL')
ON CONFLICT DO NOTHING;

DO $$
DECLARE
    v_binds BIGINT;
BEGIN
    SELECT count(*) INTO v_binds
      FROM public.role_query rq
      JOIN public.role ro ON ro.id_role = rq.role_id
      JOIN public.query q ON q.id_query = rq.query_id
      JOIN public.microservice m ON m.id_microservice = q.microservice_id
     WHERE m.serviceid = 'pigse' AND q.path_template IN ('/documentos/todos', '/documentos/todos/query')
       AND ro.name IN ('PIGSE-ADMINISTRADOR', 'PIGSE-SECRETARIA_TERRITORIAL');

    RAISE NOTICE 'V368: % binds a /documentos/todos + /documentos/todos/query (esperado 4)', v_binds;
    IF v_binds != 4 THEN
        RAISE WARNING 'V368: se esperaban 4 binds, se encontraron %', v_binds;
    END IF;
END $$;
