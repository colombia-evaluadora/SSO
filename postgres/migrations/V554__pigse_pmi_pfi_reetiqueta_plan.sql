-- ===========================================================================
-- V554 — PMI/PFI separan el plan de la autoevaluación institucional:
-- PMI = PLAN_MEJORAMIENTO + AUTOEVALUACION_INSTITUCIONAL, PFI =
-- PLAN_FORTALECIMIENTO + AUTOEVALUACION_INSTITUCIONAL (ambas obligatorias).
-- Lo cargado hasta hoy en AUTOEVALUACION_INSTITUCIONAL es el plan: se
-- reetiqueta sin tocar el archivo. fn_documentos_listar(_todos) vuelven a
-- exponer el archivo del plan (lo copia fn_cumplimiento_listar, V523).
-- Depende de: V521 (constraints y funciones que se reescriben acá).
-- ===========================================================================
ALTER TABLE pigse.tdocumento_institucional
    DROP CONSTRAINT IF EXISTS pigse_tdocumento_institucional_tipo_categoria_chk;
ALTER TABLE pigse.tdocumento_institucional
    DROP CONSTRAINT IF EXISTS pigse_tdocumento_institucional_categoria_chk;

UPDATE pigse.tdocumento_institucional
   SET categoria   = CASE tipo WHEN 'PMI' THEN 'PLAN_MEJORAMIENTO' ELSE 'PLAN_FORTALECIMIENTO' END,
       modified_by = 'V554',
       modified_at = CURRENT_TIMESTAMP
 WHERE tipo IN ('PMI', 'PFI')
   AND categoria = 'AUTOEVALUACION_INSTITUCIONAL';

ALTER TABLE pigse.tdocumento_institucional
    ADD CONSTRAINT pigse_tdocumento_institucional_categoria_chk
    CHECK (
        categoria IS NULL
        OR categoria IN ('PLAN_ESTUDIOS', 'SIEE', 'MANUAL_CONVIVENCIA',
                          'PROYECTOS_TRANSVERSALES', 'PLAN_GESTION_RIESGO',
                          'AUTOEVALUACION_INSTITUCIONAL', 'PLAN_MEJORAMIENTO',
                          'PLAN_FORTALECIMIENTO')
    );

ALTER TABLE pigse.tdocumento_institucional
    ADD CONSTRAINT pigse_tdocumento_institucional_tipo_categoria_chk
    CHECK (
        NOT active
        OR (tipo = 'PMI' AND categoria IN ('PLAN_MEJORAMIENTO', 'AUTOEVALUACION_INSTITUCIONAL'))
        OR (tipo = 'PFI' AND categoria IN ('PLAN_FORTALECIMIENTO', 'AUTOEVALUACION_INSTITUCIONAL'))
        OR (tipo IN ('PEI', 'PEC') AND categoria IN
            ('PLAN_ESTUDIOS', 'SIEE', 'MANUAL_CONVIVENCIA',
             'PROYECTOS_TRANSVERSALES', 'PLAN_GESTION_RIESGO'))
    );

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
               count(*) FILTER (WHERE d.fk_tarchivo IS NOT NULL) AS completadas,
               count(*) AS total
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
    'V554: PMI/PFI van por categorías como PEI/PEC (plan + AUTOEVALUACION_INSTITUCIONAL); fileName/archivoId/downloadUrl son los del plan. El tipo no aplicable (ETNIAS) no aparece -- antes devolvía NO_APLICA. PLAN_GESTION_RIESGO no cuenta para el total de PEI/PEC.';

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
               count(*) FILTER (WHERE d.fk_tarchivo IS NOT NULL) AS completadas,
               count(*) AS total
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

CREATE OR REPLACE FUNCTION pigse.fn_documento_categorias_listar(
    p_fk_establecimiento BIGINT,
    p_tipo                VARCHAR
)
RETURNS TABLE(
    id TEXT, type TEXT, "typeName" TEXT, categoria TEXT, "categoriaName" TEXT,
    status TEXT, "fileName" TEXT, "uploadedAt" TIMESTAMP, "sizeBytes" BIGINT,
    "archivoId" BIGINT, "downloadUrl" TEXT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_type_name TEXT := CASE p_tipo
        WHEN 'PEI' THEN 'Proyecto Educativo Institucional (PEI)'
        WHEN 'PEC' THEN 'Proyecto Educativo Comunitario (PEC)'
        WHEN 'PMI' THEN 'Plan de Mejoramiento Institucional (PMI)'
        WHEN 'PFI' THEN 'Plan de Fortalecimiento Institucional (PFI)'
    END;
    v_no_aplica BOOLEAN;
BEGIN
    SELECT (p_tipo = 'PEI' AND te.ETNIAS = 'S') OR (p_tipo = 'PEC' AND te.ETNIAS = 'N')
        OR (p_tipo = 'PMI' AND te.ETNIAS = 'S') OR (p_tipo = 'PFI' AND te.ETNIAS = 'N')
      INTO v_no_aplica
      FROM pigse.testablecimiento te
     WHERE te.PK_ESTABLECIMIENTO = p_fk_establecimiento;

    IF p_tipo IN ('PMI', 'PFI') THEN
        -- Dos categorías obligatorias: el plan (primero) y su anexo.
        RETURN QUERY
        SELECT
            cat.categoria, p_tipo::TEXT, v_type_name, cat.categoria, cat.nombre,
            CASE
                WHEN v_no_aplica THEN 'NO_APLICA'
                WHEN ta.pk_tarchivo IS NOT NULL THEN 'COMPLETO'
                ELSE 'PENDIENTE'
            END,
            ta.nombre::TEXT, ta.created_at, ta.peso, ta.pk_tarchivo,
            CASE WHEN ta.pk_tarchivo IS NOT NULL
                 THEN '/api/files/download/' || ta.pk_tarchivo ELSE NULL END
          FROM (VALUES
                    (1, 'PLAN_MEJORAMIENTO', 'Plan de Mejoramiento Institucional', 'PMI'),
                    (1, 'PLAN_FORTALECIMIENTO', 'Plan de Fortalecimiento Institucional', 'PFI'),
                    (2, 'AUTOEVALUACION_INSTITUCIONAL', 'Autoevaluación institucional (anexo)', p_tipo)
               ) AS cat(orden, categoria, nombre, tipo)
          LEFT JOIN pigse.tdocumento_institucional d
                 ON d.fk_testablecimiento = p_fk_establecimiento
                AND d.tipo = p_tipo
                AND d.categoria = cat.categoria
                AND d.active
          LEFT JOIN pigse.v_archivo ta ON ta.pk_tarchivo = d.fk_tarchivo
         WHERE cat.tipo = p_tipo
         ORDER BY cat.orden;
        RETURN;
    END IF;

    -- PEI/PEC: 4 categorías de un solo archivo. PLAN_GESTION_RIESGO sigue
    -- acá (se puede cargar igual), el "(opcional)" en el nombre es la unica
    -- senal al front de que no hace falta para el COMPLETO del padre.
    RETURN QUERY
    SELECT
        cat.categoria AS id,
        p_tipo::TEXT AS "type",
        v_type_name AS "typeName",
        cat.categoria AS categoria,
        cat.nombre AS "categoriaName",
        CASE
            WHEN v_no_aplica THEN 'NO_APLICA'
            WHEN d.fk_tarchivo IS NOT NULL THEN 'COMPLETO'
            ELSE 'PENDIENTE'
        END AS status,
        ta.nombre::TEXT AS "fileName",
        ta.created_at AS "uploadedAt",
        ta.peso AS "sizeBytes",
        ta.pk_tarchivo AS "archivoId",
        CASE WHEN ta.pk_tarchivo IS NOT NULL
             THEN '/api/files/download/' || ta.pk_tarchivo
             ELSE NULL
        END AS "downloadUrl"
      FROM (VALUES
                ('SIEE', 'Sistema Institucional de Evaluación (SIEE)'),
                ('MANUAL_CONVIVENCIA', 'Manual de convivencia'),
                ('PROYECTOS_TRANSVERSALES', 'Proyectos pedagógicos transversales'),
                ('PLAN_GESTION_RIESGO', 'Plan escolar de gestión del riesgo (opcional)')
           ) AS cat(categoria, nombre)
      LEFT JOIN pigse.tdocumento_institucional d
             ON d.fk_testablecimiento = p_fk_establecimiento
            AND d.tipo = p_tipo
            AND d.categoria = cat.categoria
            AND d.active
      LEFT JOIN pigse.v_archivo ta ON ta.pk_tarchivo = d.fk_tarchivo
     ORDER BY cat.categoria;

    -- Plan de estudios -- sin cambios (V515): una fila por archivo activo.
    RETURN QUERY
    SELECT
        d.pk_documento_institucional::TEXT AS id,
        p_tipo::TEXT AS "type",
        v_type_name AS "typeName",
        'PLAN_ESTUDIOS'::TEXT AS categoria,
        'Plan de estudios'::TEXT AS "categoriaName",
        (CASE WHEN v_no_aplica THEN 'NO_APLICA' ELSE 'COMPLETO' END) AS status,
        ta.nombre::TEXT AS "fileName",
        ta.created_at AS "uploadedAt",
        ta.peso AS "sizeBytes",
        ta.pk_tarchivo AS "archivoId",
        '/api/files/download/' || ta.pk_tarchivo AS "downloadUrl"
      FROM pigse.tdocumento_institucional d
      JOIN pigse.v_archivo ta ON ta.pk_tarchivo = d.fk_tarchivo
     WHERE d.fk_testablecimiento = p_fk_establecimiento
       AND d.tipo = p_tipo
       AND d.categoria = 'PLAN_ESTUDIOS'
       AND d.active
     ORDER BY ta.created_at;

    IF NOT EXISTS (
        SELECT 1 FROM pigse.tdocumento_institucional t
         WHERE t.fk_testablecimiento = p_fk_establecimiento
           AND t.tipo = p_tipo AND t.categoria = 'PLAN_ESTUDIOS' AND t.active
    ) THEN
        RETURN QUERY
        SELECT
            'PLAN_ESTUDIOS'::TEXT, p_tipo::TEXT, v_type_name, 'PLAN_ESTUDIOS'::TEXT,
            'Plan de estudios'::TEXT,
            (CASE WHEN v_no_aplica THEN 'NO_APLICA' ELSE 'PENDIENTE' END),
            NULL::TEXT, NULL::TIMESTAMP, NULL::BIGINT, NULL::BIGINT, NULL::TEXT;
    END IF;
END;
$$;

COMMENT ON FUNCTION pigse.fn_documento_categorias_listar(BIGINT, VARCHAR) IS
    'V554: PMI/PFI devuelven el plan (PLAN_MEJORAMIENTO/PLAN_FORTALECIMIENTO) y su anexo AUTOEVALUACION_INSTITUCIONAL, mismo patrón que las 4 categorías fijas de PEI/PEC. PLAN_GESTION_RIESGO marcada "(opcional)" en el nombre.';

DO $$
DECLARE
    v_restantes INTEGER;
BEGIN
    SELECT count(*) INTO v_restantes
      FROM pigse.tdocumento_institucional
     WHERE tipo IN ('PMI', 'PFI') AND categoria = 'AUTOEVALUACION_INSTITUCIONAL';

    IF v_restantes > 0 THEN
        RAISE EXCEPTION 'V554 fallo: % documento(s) PMI/PFI siguen en AUTOEVALUACION_INSTITUCIONAL', v_restantes;
    END IF;
END $$;
