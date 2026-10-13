-- ===========================================================================
-- V554.1 — fn_documentos_listar(_todos): el avance por anexos cuenta
-- CATEGORÍAS distintas, no filas. "Plan de estudios" admite varios archivos
-- (V515) y cada uno sumaba al total y a las completadas: un PEC con dos
-- archivos de plan + SIEE salía 3/5 en vez de 2/4, y con dos planes y dos
-- anexos más quedaba COMPLETO sin tener los cuatro. Mismo cuerpo que V554
-- salvo los count(DISTINCT ...). Va aparte y no editando V554 porque V554
-- reetiqueta datos (UPDATE de AUTOEVALUACION_INSTITUCIONAL): re-aplicarla
-- movería las autoevaluaciones cargadas después.
-- Depende de: V554.
-- ===========================================================================
CREATE OR REPLACE FUNCTION pigse.fn_documentos_listar(p_fk_establecimiento BIGINT)
RETURNS TABLE(
    id TEXT, type TEXT, "typeName" TEXT, status TEXT, "fileName" TEXT,
    "uploadedAt" TIMESTAMP, "sizeBytes" BIGINT, "archivoId" BIGINT,
    "downloadUrl" TEXT, "completedCategories" INT, "totalCategories" INT
)
LANGUAGE sql
STABLE
AS $$
    WITH categorias AS (
        SELECT te.PK_ESTABLECIMIENTO AS fk_establecimiento,
               tipos.tipo,
               count(DISTINCT cat.categoria) FILTER (WHERE d.fk_tarchivo IS NOT NULL) AS completadas,
               count(DISTINCT cat.categoria) AS total
          FROM pigse.testablecimiento te
         CROSS JOIN (VALUES ('PEI'), ('PEC'), ('PMI'), ('PFI')) AS tipos(tipo)
         CROSS JOIN LATERAL (
             SELECT categoria FROM (VALUES
                 ('PLAN_ESTUDIOS'), ('SIEE'), ('MANUAL_CONVIVENCIA'), ('PROYECTOS_TRANSVERSALES')
             ) c(categoria) WHERE tipos.tipo IN ('PEI', 'PEC')
             UNION ALL
             SELECT categoria FROM (VALUES
                 ('PMI', 'PLAN_MEJORAMIENTO'), ('PMI', 'AUTOEVALUACION_INSTITUCIONAL'),
                 ('PFI', 'PLAN_FORTALECIMIENTO'), ('PFI', 'AUTOEVALUACION_INSTITUCIONAL')
             ) p(tipo, categoria) WHERE p.tipo = tipos.tipo
         ) AS cat(categoria)
          LEFT JOIN pigse.tdocumento_institucional d
                 ON d.fk_testablecimiento = te.PK_ESTABLECIMIENTO
                AND d.tipo = tipos.tipo
                AND d.categoria = cat.categoria
                AND d.active
         WHERE te.PK_ESTABLECIMIENTO = p_fk_establecimiento
         GROUP BY te.PK_ESTABLECIMIENTO, tipos.tipo
    )
    SELECT
        tipos.tipo AS id,
        tipos.tipo AS "type",
        tipos.nombre AS "typeName",
        CASE WHEN c.completadas = c.total THEN 'COMPLETO' ELSE 'PENDIENTE' END AS status,
        plan.nombre::TEXT AS "fileName",
        plan.created_at AS "uploadedAt",
        plan.peso AS "sizeBytes",
        plan.pk_tarchivo AS "archivoId",
        '/api/files/download/' || plan.pk_tarchivo AS "downloadUrl",
        c.completadas::INT AS "completedCategories",
        c.total::INT AS "totalCategories"
      FROM pigse.testablecimiento te
     CROSS JOIN LATERAL (
         SELECT 'PEI' AS tipo, 'Proyecto Educativo Institucional (PEI)' AS nombre WHERE te.ETNIAS IS DISTINCT FROM 'S'
         UNION ALL
         SELECT 'PEC', 'Proyecto Educativo Comunitario (PEC)' WHERE te.ETNIAS IS DISTINCT FROM 'N'
         UNION ALL
         SELECT 'PMI', 'Plan de Mejoramiento Institucional (PMI)' WHERE te.ETNIAS IS DISTINCT FROM 'S'
         UNION ALL
         SELECT 'PFI', 'Plan de Fortalecimiento Institucional (PFI)' WHERE te.ETNIAS IS DISTINCT FROM 'N'
     ) AS tipos(tipo, nombre)
      JOIN categorias c
        ON c.fk_establecimiento = te.PK_ESTABLECIMIENTO
       AND c.tipo = tipos.tipo
      -- PMI/PFI: el archivo del plan viaja en la fila (tablero de monitoreo).
      LEFT JOIN LATERAL (
          SELECT ta.nombre, ta.created_at, ta.peso, ta.pk_tarchivo
            FROM pigse.tdocumento_institucional d
            JOIN pigse.v_archivo ta ON ta.pk_tarchivo = d.fk_tarchivo
           WHERE d.fk_testablecimiento = te.PK_ESTABLECIMIENTO
             AND d.tipo = tipos.tipo
             AND d.categoria IN ('PLAN_MEJORAMIENTO', 'PLAN_FORTALECIMIENTO')
             AND d.active
           LIMIT 1
      ) plan ON true
     WHERE te.PK_ESTABLECIMIENTO = p_fk_establecimiento
     ORDER BY tipos.tipo;
$$;

COMMENT ON FUNCTION pigse.fn_documentos_listar(BIGINT) IS
    'V554.1: avance por anexos sobre categorias distintas (Plan de estudios admite varios archivos). PMI/PFI por categorias (plan + AUTOEVALUACION_INSTITUCIONAL); fileName/archivoId/downloadUrl son los del plan. El tipo no aplicable (ETNIAS) no aparece. PLAN_GESTION_RIESGO no cuenta para el total de PEI/PEC.';

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
    "establecimientoNombre" TEXT,
    "completedCategories" INT,
    "totalCategories"     INT
)
LANGUAGE sql
STABLE
AS $$
    WITH categorias AS (
        SELECT te.PK_ESTABLECIMIENTO AS fk_establecimiento,
               tipos.tipo,
               count(DISTINCT cat.categoria) FILTER (WHERE d.fk_tarchivo IS NOT NULL) AS completadas,
               count(DISTINCT cat.categoria) AS total
          FROM pigse.testablecimiento te
         CROSS JOIN (VALUES ('PEI'), ('PEC'), ('PMI'), ('PFI')) AS tipos(tipo)
         CROSS JOIN LATERAL (
             SELECT categoria FROM (VALUES
                 ('PLAN_ESTUDIOS'), ('SIEE'), ('MANUAL_CONVIVENCIA'), ('PROYECTOS_TRANSVERSALES')
             ) c(categoria) WHERE tipos.tipo IN ('PEI', 'PEC')
             UNION ALL
             SELECT categoria FROM (VALUES
                 ('PMI', 'PLAN_MEJORAMIENTO'), ('PMI', 'AUTOEVALUACION_INSTITUCIONAL'),
                 ('PFI', 'PLAN_FORTALECIMIENTO'), ('PFI', 'AUTOEVALUACION_INSTITUCIONAL')
             ) p(tipo, categoria) WHERE p.tipo = tipos.tipo
         ) AS cat(categoria)
          LEFT JOIN pigse.tdocumento_institucional d
                 ON d.fk_testablecimiento = te.PK_ESTABLECIMIENTO
                AND d.tipo = tipos.tipo
                AND d.categoria = cat.categoria
                AND d.active
         WHERE te.ACTIVE = TRUE
         GROUP BY te.PK_ESTABLECIMIENTO, tipos.tipo
    )
    SELECT
        tipos.tipo AS id,
        tipos.tipo AS "type",
        tipos.nombre AS "typeName",
        CASE WHEN c.completadas = c.total THEN 'COMPLETO' ELSE 'PENDIENTE' END AS status,
        plan.nombre::TEXT AS "fileName",
        plan.created_at AS "uploadedAt",
        plan.peso AS "sizeBytes",
        plan.pk_tarchivo AS "archivoId",
        '/api/files/download/' || plan.pk_tarchivo AS "downloadUrl",
        te.PK_ESTABLECIMIENTO AS "establecimientoId",
        te.NOMBRE AS "establecimientoNombre",
        c.completadas::INT AS "completedCategories",
        c.total::INT AS "totalCategories"
      FROM pigse.testablecimiento te
     CROSS JOIN LATERAL (
         SELECT 'PEI' AS tipo, 'Proyecto Educativo Institucional (PEI)' AS nombre WHERE te.ETNIAS IS DISTINCT FROM 'S'
         UNION ALL
         SELECT 'PEC', 'Proyecto Educativo Comunitario (PEC)' WHERE te.ETNIAS IS DISTINCT FROM 'N'
         UNION ALL
         SELECT 'PMI', 'Plan de Mejoramiento Institucional (PMI)' WHERE te.ETNIAS IS DISTINCT FROM 'S'
         UNION ALL
         SELECT 'PFI', 'Plan de Fortalecimiento Institucional (PFI)' WHERE te.ETNIAS IS DISTINCT FROM 'N'
     ) AS tipos(tipo, nombre)
      JOIN categorias c
        ON c.fk_establecimiento = te.PK_ESTABLECIMIENTO
       AND c.tipo = tipos.tipo
      -- PMI/PFI: el archivo del plan viaja en la fila (tablero de monitoreo).
      LEFT JOIN LATERAL (
          SELECT ta.nombre, ta.created_at, ta.peso, ta.pk_tarchivo
            FROM pigse.tdocumento_institucional d
            JOIN pigse.v_archivo ta ON ta.pk_tarchivo = d.fk_tarchivo
           WHERE d.fk_testablecimiento = te.PK_ESTABLECIMIENTO
             AND d.tipo = tipos.tipo
             AND d.categoria IN ('PLAN_MEJORAMIENTO', 'PLAN_FORTALECIMIENTO')
             AND d.active
           LIMIT 1
      ) plan ON true
     WHERE te.ACTIVE = TRUE
     ORDER BY te.NOMBRE, tipos.tipo;
$$;

COMMENT ON FUNCTION pigse.fn_documentos_listar_todos() IS
    'V554: mismo criterio que fn_documentos_listar -- PMI/PFI por categoría, tipo no aplicable no aparece, PLAN_GESTION_RIESGO opcional.';
