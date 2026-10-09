-- ===========================================================================
-- V523 — pigse.fn_cumplimiento_listar: una fila por establecimiento activo con
-- el estado de PEI/PEC/PMI/PFI (LEFT JOIN: desde V521 el tipo no aplicable por
-- ETNIAS no tiene fila y queda NO_APLICA). Cada tipo trae además su avance por
-- anexos (completedCategories/totalCategories), estado derivado (COMPLETO /
-- PARCIAL / SIN_CARGAR / NO_APLICA) y última carga; la fila trae municipio,
-- código, plazo efectivo (fecha global o excepción, V522) y si ya venció.
-- p_fk_establecimiento (opcional) acota a un solo establecimiento: lo usa el
-- detalle documental del tablero sin recalcular el universo.
-- Depende de: V521 (fn_documentos_listar por categorías), V522 (fecha límite).
-- ===========================================================================
DROP FUNCTION IF EXISTS pigse.fn_cumplimiento_listar();
DROP FUNCTION IF EXISTS pigse.fn_cumplimiento_listar(BIGINT);

CREATE FUNCTION pigse.fn_cumplimiento_listar(p_fk_establecimiento BIGINT DEFAULT NULL)
RETURNS TABLE(
    id BIGINT, "establishmentName" TEXT, "establishmentCode" TEXT,
    "municipioId" BIGINT, municipio TEXT, etnoeducativo BOOLEAN,
    pei JSONB, pec JSONB, pmi JSONB, pfi JSONB,
    "globalProgress" INTEGER, "lastUploadedAt" TIMESTAMP,
    "fechaLimite" DATE, "tieneExcepcion" BOOLEAN, plazo TEXT
)
LANGUAGE sql
STABLE
AS $$
    WITH config AS (
        SELECT c.fecha_limite FROM pigse.tgestion_documental_config c WHERE c.pk_config = 1
    ),
    base AS (
        SELECT te.PK_ESTABLECIMIENTO AS id,
               te.NOMBRE::TEXT AS nombre,
               te.CODIGO::TEXT AS codigo,
               te.FK_TMUNICIPIO AS municipio_id,
               mu.NOMBRE::TEXT AS municipio,
               (te.ETNIAS = 'S') AS etnoeducativo,
               docs.por_tipo,
               cargas.ultima_global,
               ex.fecha_limite AS fecha_excepcion,
               COALESCE(ex.fecha_limite, (SELECT fecha_limite FROM config)) AS fecha_limite
          FROM pigse.testablecimiento te
          LEFT JOIN pigse.tmunicipio mu ON mu.PK_TMUNICIPIO = te.FK_TMUNICIPIO
          LEFT JOIN pigse.tgestion_documental_excepcion ex
                 ON ex.fk_testablecimiento = te.PK_ESTABLECIMIENTO AND ex.active
          -- Una sola llamada por establecimiento (antes cuatro, una por tipo).
          LEFT JOIN LATERAL (
              SELECT jsonb_object_agg(d.id, jsonb_build_object(
                         'status', d.status,
                         'estado', CASE
                             WHEN d.status = 'COMPLETO' THEN 'COMPLETO'
                             WHEN COALESCE(d."completedCategories", 0) > 0 THEN 'PARCIAL'
                             ELSE 'SIN_CARGAR' END,
                         'fileName', d."fileName",
                         'archivoId', d."archivoId",
                         'downloadUrl', d."downloadUrl",
                         'completedCategories', d."completedCategories",
                         'totalCategories', d."totalCategories",
                         'lastUploadedAt', u.ultima)) AS por_tipo
                FROM pigse.fn_documentos_listar(te.PK_ESTABLECIMIENTO) d
                LEFT JOIN LATERAL (
                    SELECT max(COALESCE(di.modified_at, di.created_at)) AS ultima
                      FROM pigse.tdocumento_institucional di
                     WHERE di.fk_testablecimiento = te.PK_ESTABLECIMIENTO
                       AND di.tipo = d.id AND di.active AND di.fk_tarchivo IS NOT NULL
                ) u ON true
          ) docs ON true
          LEFT JOIN LATERAL (
              SELECT max(COALESCE(di.modified_at, di.created_at)) AS ultima_global
                FROM pigse.tdocumento_institucional di
               WHERE di.fk_testablecimiento = te.PK_ESTABLECIMIENTO
                 AND di.active AND di.fk_tarchivo IS NOT NULL
          ) cargas ON true
         WHERE te.ACTIVE
           AND (p_fk_establecimiento IS NULL OR te.PK_ESTABLECIMIENTO = p_fk_establecimiento)
    ),
    tipos AS (
        SELECT b.*,
               COALESCE(b.por_tipo->'PEI', '{"status":"NO_APLICA","estado":"NO_APLICA"}'::jsonb) AS j_pei,
               COALESCE(b.por_tipo->'PEC', '{"status":"NO_APLICA","estado":"NO_APLICA"}'::jsonb) AS j_pec,
               COALESCE(b.por_tipo->'PMI', '{"status":"NO_APLICA","estado":"NO_APLICA"}'::jsonb) AS j_pmi,
               COALESCE(b.por_tipo->'PFI', '{"status":"NO_APLICA","estado":"NO_APLICA"}'::jsonb) AS j_pfi
          FROM base b
    ),
    conteo AS (
        SELECT t.*,
               (SELECT count(*) FROM unnest(ARRAY[t.j_pei, t.j_pec, t.j_pmi, t.j_pfi]) j
                 WHERE j->>'status' <> 'NO_APLICA') AS aplicables,
               (SELECT count(*) FROM unnest(ARRAY[t.j_pei, t.j_pec, t.j_pmi, t.j_pfi]) j
                 WHERE j->>'status' = 'COMPLETO') AS completos
          FROM tipos t
    )
    SELECT
        c.id,
        c.nombre,
        c.codigo,
        c.municipio_id,
        c.municipio,
        c.etnoeducativo,
        c.j_pei, c.j_pec, c.j_pmi, c.j_pfi,
        CASE WHEN c.aplicables = 0 THEN 0
             ELSE round(100.0 * c.completos / c.aplicables)::INTEGER END,
        c.ultima_global,
        c.fecha_limite,
        (c.fecha_excepcion IS NOT NULL),
        CASE
            WHEN c.fecha_limite IS NULL THEN 'SIN_FECHA'
            WHEN CURRENT_DATE > c.fecha_limite THEN 'VENCIDO'
            ELSE 'VIGENTE'
        END
      FROM conteo c
     ORDER BY c.nombre;
$$;

COMMENT ON FUNCTION pigse.fn_cumplimiento_listar(BIGINT) IS
    'INTERNO: tablero de Monitoreo (fn_cumplimiento_listar_paginado, /cumplimiento/listar) y detalle documental (fn_cumplimiento_documento_detalle). Estado por tipo con avance por anexos, ultima carga y plazo efectivo (global o excepcion, V522). p_fk_establecimiento NULL = todos.';
