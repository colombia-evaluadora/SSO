-- ===========================================================================
-- V521 — Varios cambios en "Gestión documental" de PIGSE, pedido explícito:
--   1. PMI se separa en dos tipos: PMI (tradicional) / PFI (étnico), mismo
--      criterio de exclusión que PEI/PEC (ETNIAS).
--   2. PMI/PFI pasan a tener categoría, como PEI/PEC: una sola, obligatoria,
--      "Autoevaluación institucional" (AUTOEVALUACION_INSTITUCIONAL).
--   3. PEI/PEC: "Plan escolar de gestión del riesgo" deja de contar para
--      COMPLETO (las otras 4 categorías siguen obligatorias) — sigue
--      pudiendo cargarse, solo no bloquea el estado del documento padre.
--   4. El tipo que NO aplica a un establecimiento (por ETNIAS) deja de
--      listarse como NO_APLICA: directamente no aparece la fila.
--   5. Rector gana los mismos permisos de escritura que Secretario.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 0. Constraints viejos afuera ANTES de tocar datos (mismo orden que el
--    incidente de V512: la ADD CONSTRAINT valida TODAS las filas existentes
--    de una, así que primero se arregla el dato, recién después se endurece
--    la regla).
-- ---------------------------------------------------------------------------
ALTER TABLE pigse.tdocumento_institucional
    DROP CONSTRAINT IF EXISTS pigse_tdocumento_institucional_tipo_categoria_chk;
ALTER TABLE pigse.tdocumento_institucional
    DROP CONSTRAINT IF EXISTS pigse_tdocumento_institucional_categoria_chk;
ALTER TABLE pigse.tdocumento_institucional
    DROP CONSTRAINT IF EXISTS pigse_tdocumento_institucional_tipo_chk;

-- ---------------------------------------------------------------------------
-- 1. Dato: PMI activo de un establecimiento étnico pasa a ser PFI. El
--    archivo no se toca (mismo pk_documento_institucional, mismo
--    fk_tarchivo) -- solo cambia la etiqueta de tipo.
-- ---------------------------------------------------------------------------
UPDATE pigse.tdocumento_institucional d
   SET tipo = 'PFI', modified_by = 'V521', modified_at = CURRENT_TIMESTAMP
  FROM pigse.testablecimiento te
 WHERE d.fk_testablecimiento = te.PK_ESTABLECIMIENTO
   AND d.tipo = 'PMI'
   AND d.active
   AND te.ETNIAS = 'S';

-- 2. Dato: todo PMI/PFI activo (ya reclasificado arriba) gana la categoría
--    fija, para que la constraint nueva (paso 5) no los rechace.
UPDATE pigse.tdocumento_institucional
   SET categoria = 'AUTOEVALUACION_INSTITUCIONAL', modified_by = 'V521', modified_at = CURRENT_TIMESTAMP
 WHERE tipo IN ('PMI', 'PFI')
   AND active
   AND categoria IS NULL;

-- ---------------------------------------------------------------------------
-- 3-5. Constraints nuevos.
-- ---------------------------------------------------------------------------
ALTER TABLE pigse.tdocumento_institucional
    ADD CONSTRAINT pigse_tdocumento_institucional_tipo_chk
    CHECK (tipo IN ('PEI', 'PEC', 'PMI', 'PFI'));

ALTER TABLE pigse.tdocumento_institucional
    ADD CONSTRAINT pigse_tdocumento_institucional_categoria_chk
    CHECK (
        categoria IS NULL
        OR categoria IN ('PLAN_ESTUDIOS', 'SIEE', 'MANUAL_CONVIVENCIA',
                          'PROYECTOS_TRANSVERSALES', 'PLAN_GESTION_RIESGO',
                          'AUTOEVALUACION_INSTITUCIONAL')
    );

ALTER TABLE pigse.tdocumento_institucional
    ADD CONSTRAINT pigse_tdocumento_institucional_tipo_categoria_chk
    CHECK (
        NOT active
        OR (tipo IN ('PMI', 'PFI') AND categoria = 'AUTOEVALUACION_INSTITUCIONAL')
        OR (tipo IN ('PEI', 'PEC') AND categoria IN
            ('PLAN_ESTUDIOS', 'SIEE', 'MANUAL_CONVIVENCIA',
             'PROYECTOS_TRANSVERSALES', 'PLAN_GESTION_RIESGO'))
    );

-- ---------------------------------------------------------------------------
-- 6. fn_documentos_listar -- PMI/PFI pasan al mismo patrón "categorías" que
--    PEI/PEC (ya no hay columna de archivo propia: completedCategories/
--    totalCategories resume el avance, el detalle vive en
--    fn_documento_categorias_listar). El tipo no aplicable directamente NO
--    aparece (antes: fila con status NO_APLICA). PLAN_GESTION_RIESGO no
--    cuenta en el "total" de PEI/PEC (sigue siendo categoría opcional).
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS pigse.fn_documentos_listar(BIGINT);

CREATE FUNCTION pigse.fn_documentos_listar(p_fk_establecimiento BIGINT)
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
             SELECT 'AUTOEVALUACION_INSTITUCIONAL' WHERE tipos.tipo IN ('PMI', 'PFI')
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
        NULL::TEXT AS "fileName",
        NULL::TIMESTAMP AS "uploadedAt",
        NULL::BIGINT AS "sizeBytes",
        NULL::BIGINT AS "archivoId",
        NULL::TEXT AS "downloadUrl",
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
     WHERE te.PK_ESTABLECIMIENTO = p_fk_establecimiento
     ORDER BY tipos.tipo;
$$;

COMMENT ON FUNCTION pigse.fn_documentos_listar(BIGINT) IS
    'V521: PMI/PFI van por categorías como PEI/PEC (AUTOEVALUACION_INSTITUCIONAL). El tipo no aplicable (ETNIAS) no aparece -- antes devolvía NO_APLICA. PLAN_GESTION_RIESGO no cuenta para el total de PEI/PEC.';

-- ---------------------------------------------------------------------------
-- 7. fn_documentos_listar_todos -- mismo criterio que fn_documentos_listar,
--    para TODOS los establecimientos activos (la tabla de "Gestión
--    documental").
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS pigse.fn_documentos_listar_todos();

CREATE FUNCTION pigse.fn_documentos_listar_todos()
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
             SELECT 'AUTOEVALUACION_INSTITUCIONAL' WHERE tipos.tipo IN ('PMI', 'PFI')
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
        NULL::TEXT AS "fileName",
        NULL::TIMESTAMP AS "uploadedAt",
        NULL::BIGINT AS "sizeBytes",
        NULL::BIGINT AS "archivoId",
        NULL::TEXT AS "downloadUrl",
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
     WHERE te.ACTIVE = TRUE
     ORDER BY te.NOMBRE, tipos.tipo;
$$;

COMMENT ON FUNCTION pigse.fn_documentos_listar_todos() IS
    'V521: mismo criterio que fn_documentos_listar -- PMI/PFI por categoría, tipo no aplicable no aparece, PLAN_GESTION_RIESGO opcional.';

-- ---------------------------------------------------------------------------
-- 8. fn_cumplimiento_metricas -- gana la clave "pfi" (cambia el RETURNS
--    TABLE, hace falta DROP). pmi/pfi ahora tienen denominador propio por
--    ETNIAS, igual que pei/pec (antes "pmi" contaba TODOS los
--    establecimientos).
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS pigse.fn_cumplimiento_metricas();

CREATE FUNCTION pigse.fn_cumplimiento_metricas()
RETURNS TABLE("totalEstablishments" BIGINT, pei JSONB, pec JSONB, pmi JSONB, pfi JSONB)
LANGUAGE sql
STABLE
AS $$
    WITH ee AS (
        SELECT PK_ESTABLECIMIENTO AS pk_establecimiento, ETNIAS AS etnias
          FROM pigse.testablecimiento WHERE ACTIVE
    ),
    docs AS (
        SELECT ee.pk_establecimiento,
               l.id AS tipo,
               l.status = 'COMPLETO' AS completo
          FROM ee
          JOIN LATERAL pigse.fn_documentos_listar(ee.pk_establecimiento) l ON true
    )
    SELECT
        (SELECT count(*) FROM ee) AS "totalEstablishments",
        jsonb_build_object(
            'completed', count(*) FILTER (WHERE docs.tipo = 'PEI' AND docs.completo),
            'total',     count(DISTINCT ee.pk_establecimiento) FILTER (WHERE ee.etnias = 'N'),
            'percent',   CASE WHEN count(DISTINCT ee.pk_establecimiento) FILTER (WHERE ee.etnias = 'N') = 0 THEN 0
                              ELSE round(100.0 * count(*) FILTER (WHERE docs.tipo = 'PEI' AND docs.completo)
                                         / count(DISTINCT ee.pk_establecimiento) FILTER (WHERE ee.etnias = 'N'))
                          END
        ) AS pei,
        jsonb_build_object(
            'completed', count(*) FILTER (WHERE docs.tipo = 'PEC' AND docs.completo),
            'total',     count(DISTINCT ee.pk_establecimiento) FILTER (WHERE ee.etnias = 'S'),
            'percent',   CASE WHEN count(DISTINCT ee.pk_establecimiento) FILTER (WHERE ee.etnias = 'S') = 0 THEN 0
                              ELSE round(100.0 * count(*) FILTER (WHERE docs.tipo = 'PEC' AND docs.completo)
                                         / count(DISTINCT ee.pk_establecimiento) FILTER (WHERE ee.etnias = 'S'))
                          END
        ) AS pec,
        jsonb_build_object(
            'completed', count(*) FILTER (WHERE docs.tipo = 'PMI' AND docs.completo),
            'total',     count(DISTINCT ee.pk_establecimiento) FILTER (WHERE ee.etnias = 'N'),
            'percent',   CASE WHEN count(DISTINCT ee.pk_establecimiento) FILTER (WHERE ee.etnias = 'N') = 0 THEN 0
                              ELSE round(100.0 * count(*) FILTER (WHERE docs.tipo = 'PMI' AND docs.completo)
                                         / count(DISTINCT ee.pk_establecimiento) FILTER (WHERE ee.etnias = 'N'))
                          END
        ) AS pmi,
        jsonb_build_object(
            'completed', count(*) FILTER (WHERE docs.tipo = 'PFI' AND docs.completo),
            'total',     count(DISTINCT ee.pk_establecimiento) FILTER (WHERE ee.etnias = 'S'),
            'percent',   CASE WHEN count(DISTINCT ee.pk_establecimiento) FILTER (WHERE ee.etnias = 'S') = 0 THEN 0
                              ELSE round(100.0 * count(*) FILTER (WHERE docs.tipo = 'PFI' AND docs.completo)
                                         / count(DISTINCT ee.pk_establecimiento) FILTER (WHERE ee.etnias = 'S'))
                          END
        ) AS pfi
      FROM ee
      LEFT JOIN docs ON docs.pk_establecimiento = ee.pk_establecimiento;
$$;

COMMENT ON FUNCTION pigse.fn_cumplimiento_metricas() IS
    'V521: gana la clave "pfi" (antes PMI contaba TODOS los establecimientos; ahora pmi/pfi tienen denominador propio por ETNIAS, igual que pei/pec).';

-- ---------------------------------------------------------------------------
-- 9. fn_documento_categorias_listar -- PMI/PFI: una sola categoría fija
--    (AUTOEVALUACION_INSTITUCIONAL), mismo patrón de archivo único que las
--    4 categorías fijas de PEI/PEC. PEI/PEC: PLAN_GESTION_RIESGO se marca
--    "(opcional)" en el nombre mostrado -- sigue siendo una categoría más,
--    solo que ya no bloquea el COMPLETO del documento padre.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS pigse.fn_documento_categorias_listar(BIGINT, VARCHAR);

CREATE FUNCTION pigse.fn_documento_categorias_listar(
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
        RETURN QUERY
        WITH doc AS (
            SELECT d.fk_tarchivo
              FROM pigse.tdocumento_institucional d
             WHERE d.fk_testablecimiento = p_fk_establecimiento
               AND d.tipo = p_tipo
               AND d.categoria = 'AUTOEVALUACION_INSTITUCIONAL'
               AND d.active
        )
        SELECT
            'AUTOEVALUACION_INSTITUCIONAL'::TEXT, p_tipo::TEXT, v_type_name,
            'AUTOEVALUACION_INSTITUCIONAL'::TEXT, 'Autoevaluación institucional'::TEXT,
            CASE
                WHEN v_no_aplica THEN 'NO_APLICA'
                WHEN ta.pk_tarchivo IS NOT NULL THEN 'COMPLETO'
                ELSE 'PENDIENTE'
            END,
            ta.nombre::TEXT, ta.created_at, ta.peso, ta.pk_tarchivo,
            CASE WHEN ta.pk_tarchivo IS NOT NULL
                 THEN '/api/files/download/' || ta.pk_tarchivo ELSE NULL END
          FROM (SELECT 1) AS one
          LEFT JOIN doc ON true
          LEFT JOIN pigse.v_archivo ta ON ta.pk_tarchivo = doc.fk_tarchivo;
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
    'V521: PMI/PFI devuelven su única categoría fija (AUTOEVALUACION_INSTITUCIONAL), mismo patrón que las 4 categorías fijas de PEI/PEC. PLAN_GESTION_RIESGO marcada "(opcional)" en el nombre.';

-- ---------------------------------------------------------------------------
-- 10. fn_documento_guardar -- PMI/PFI ya no son casos aparte: pasan por el
--     mismo camino de categoría que PEI/PEC. Gana la validación de que
--     PMI/PFI no acepten otra categoría que AUTOEVALUACION_INSTITUCIONAL (y
--     viceversa), y el chequeo de "no aplica" para los dos tipos nuevos.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS pigse.fn_documento_guardar(BIGINT, VARCHAR, VARCHAR, BIGINT, VARCHAR);

CREATE FUNCTION pigse.fn_documento_guardar(
    p_pk_usuario  BIGINT,
    p_email       VARCHAR,
    p_tipo        VARCHAR,
    p_fk_tarchivo BIGINT,
    p_categoria   VARCHAR DEFAULT NULL
)
RETURNS TABLE(
    id TEXT, type TEXT, "typeName" TEXT, categoria TEXT, "categoriaName" TEXT,
    status TEXT, "fileName" TEXT, "uploadedAt" TIMESTAMP, "sizeBytes" BIGINT,
    "archivoId" BIGINT, "downloadUrl" TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_fk_establecimiento BIGINT;
    v_pk_doc             BIGINT;
    v_fk_tarchivo_previo BIGINT;
    v_etnias             pigse.bool_sn;
BEGIN
    IF p_fk_tarchivo IS NULL THEN
        RAISE EXCEPTION 'pigse: p_fk_tarchivo es obligatorio (archivo no subido)';
    END IF;

    IF p_categoria IS NULL THEN
        RAISE EXCEPTION 'pigse: % requiere indicar la categoria del anexo', p_tipo
            USING ERRCODE = '22023';
    ELSIF p_categoria NOT IN ('PLAN_ESTUDIOS', 'SIEE', 'MANUAL_CONVIVENCIA',
                               'PROYECTOS_TRANSVERSALES', 'PLAN_GESTION_RIESGO',
                               'AUTOEVALUACION_INSTITUCIONAL') THEN
        RAISE EXCEPTION 'pigse: categoria invalida: %', p_categoria
            USING ERRCODE = '22023';
    ELSIF p_tipo IN ('PMI', 'PFI') AND p_categoria <> 'AUTOEVALUACION_INSTITUCIONAL' THEN
        RAISE EXCEPTION 'pigse: % solo admite la categoria AUTOEVALUACION_INSTITUCIONAL', p_tipo
            USING ERRCODE = '22023';
    ELSIF p_tipo IN ('PEI', 'PEC') AND p_categoria = 'AUTOEVALUACION_INSTITUCIONAL' THEN
        RAISE EXCEPTION 'pigse: % no admite la categoria AUTOEVALUACION_INSTITUCIONAL', p_tipo
            USING ERRCODE = '22023';
    END IF;

    v_fk_establecimiento := pigse.fn_mi_establecimiento(p_email);

    SELECT ETNIAS INTO v_etnias
      FROM pigse.testablecimiento
     WHERE PK_ESTABLECIMIENTO = v_fk_establecimiento;

    IF p_tipo = 'PEI' AND v_etnias = 'S' THEN
        RAISE EXCEPTION 'pigse: PEI no aplica a este establecimiento (etnoeducativo -- usar PEC)'
            USING ERRCODE = '23514';
    ELSIF p_tipo = 'PEC' AND v_etnias = 'N' THEN
        RAISE EXCEPTION 'pigse: PEC no aplica a este establecimiento (no etnoeducativo -- usar PEI)'
            USING ERRCODE = '23514';
    ELSIF p_tipo = 'PMI' AND v_etnias = 'S' THEN
        RAISE EXCEPTION 'pigse: PMI no aplica a este establecimiento (etnoeducativo -- usar PFI)'
            USING ERRCODE = '23514';
    ELSIF p_tipo = 'PFI' AND v_etnias = 'N' THEN
        RAISE EXCEPTION 'pigse: PFI no aplica a este establecimiento (no etnoeducativo -- usar PMI)'
            USING ERRCODE = '23514';
    END IF;

    IF p_categoria = 'PLAN_ESTUDIOS' THEN
        -- Nunca reemplaza: cada carga es un archivo más en la lista (V515).
        INSERT INTO pigse.tdocumento_institucional
            (fk_testablecimiento, tipo, categoria, fk_tarchivo, created_by)
        VALUES (v_fk_establecimiento, p_tipo, p_categoria, p_fk_tarchivo, p_email)
        RETURNING pk_documento_institucional INTO v_pk_doc;

        RETURN QUERY
        SELECT c.id, c.type, c."typeName", c.categoria, c."categoriaName", c.status,
               c."fileName", c."uploadedAt", c."sizeBytes", c."archivoId", c."downloadUrl"
          FROM pigse.fn_documento_categorias_listar(v_fk_establecimiento, p_tipo) c
         WHERE c.id = v_pk_doc::TEXT;
        RETURN;
    END IF;

    SELECT t.pk_documento_institucional, t.fk_tarchivo
      INTO v_pk_doc, v_fk_tarchivo_previo
      FROM pigse.tdocumento_institucional t
     WHERE t.fk_testablecimiento = v_fk_establecimiento
       AND t.tipo = p_tipo
       AND t.categoria IS NOT DISTINCT FROM p_categoria
       AND t.active;

    IF v_pk_doc IS NULL THEN
        INSERT INTO pigse.tdocumento_institucional
            (fk_testablecimiento, tipo, categoria, fk_tarchivo, created_by)
        VALUES (v_fk_establecimiento, p_tipo, p_categoria, p_fk_tarchivo, p_email)
        RETURNING pk_documento_institucional INTO v_pk_doc;
    ELSE
        UPDATE pigse.tdocumento_institucional
           SET fk_tarchivo = p_fk_tarchivo, modified_by = p_email, modified_at = CURRENT_TIMESTAMP
         WHERE pk_documento_institucional = v_pk_doc;

        IF v_fk_tarchivo_previo IS NOT NULL THEN
            INSERT INTO pigse.tdocumento_institucional_hist
                (fk_documento_institucional, fk_tarchivo, reemplazado_by)
            VALUES (v_pk_doc, v_fk_tarchivo_previo, p_email);
        END IF;
    END IF;

    RETURN QUERY
    SELECT * FROM pigse.fn_documento_categorias_listar(v_fk_establecimiento, p_tipo) c
     WHERE c.categoria = p_categoria;
END;
$$;

COMMENT ON FUNCTION pigse.fn_documento_guardar(BIGINT, VARCHAR, VARCHAR, BIGINT, VARCHAR) IS
    'V521: PMI/PFI ya no son casos aparte -- van por categoria (AUTOEVALUACION_INSTITUCIONAL) igual que PEI/PEC. Valida que cada tipo solo use sus categorias propias.';

-- ---------------------------------------------------------------------------
-- 11. fn_documento_eliminar -- mismo criterio: PMI/PFI dejan de ser casos
--     aparte.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS pigse.fn_documento_eliminar(BIGINT, VARCHAR, VARCHAR, VARCHAR, BIGINT);

CREATE FUNCTION pigse.fn_documento_eliminar(
    p_pk_usuario  BIGINT,
    p_email       VARCHAR,
    p_tipo        VARCHAR,
    p_categoria   VARCHAR DEFAULT NULL,
    p_fk_tarchivo BIGINT  DEFAULT NULL
)
RETURNS TABLE(
    id TEXT, type TEXT, "typeName" TEXT, categoria TEXT, "categoriaName" TEXT,
    status TEXT, "fileName" TEXT, "uploadedAt" TIMESTAMP, "sizeBytes" BIGINT,
    "archivoId" BIGINT, "downloadUrl" TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_fk_establecimiento BIGINT;
    v_pk_doc             BIGINT;
    v_fk_tarchivo_previo BIGINT;
BEGIN
    IF p_categoria IS NULL THEN
        RAISE EXCEPTION 'pigse: % requiere indicar la categoria del anexo a eliminar', p_tipo
            USING ERRCODE = '22023';
    END IF;

    IF p_categoria = 'PLAN_ESTUDIOS' AND p_fk_tarchivo IS NULL THEN
        RAISE EXCEPTION 'pigse: PLAN_ESTUDIOS admite varios archivos -- indique cual (p_fk_tarchivo)'
            USING ERRCODE = '22023';
    ELSIF (p_categoria IS DISTINCT FROM 'PLAN_ESTUDIOS') AND p_fk_tarchivo IS NOT NULL THEN
        RAISE EXCEPTION 'pigse: p_fk_tarchivo solo aplica a PLAN_ESTUDIOS'
            USING ERRCODE = '22023';
    END IF;

    v_fk_establecimiento := pigse.fn_mi_establecimiento(p_email);

    IF p_categoria = 'PLAN_ESTUDIOS' THEN
        SELECT t.pk_documento_institucional, t.fk_tarchivo
          INTO v_pk_doc, v_fk_tarchivo_previo
          FROM pigse.tdocumento_institucional t
         WHERE t.fk_testablecimiento = v_fk_establecimiento
           AND t.tipo = p_tipo
           AND t.categoria = 'PLAN_ESTUDIOS'
           AND t.fk_tarchivo = p_fk_tarchivo
           AND t.active;

        IF v_pk_doc IS NULL THEN
            RAISE EXCEPTION 'pigse: archivo % no encontrado en PLAN_ESTUDIOS para este establecimiento', p_fk_tarchivo
                USING ERRCODE = 'P0002';
        END IF;

        UPDATE pigse.tdocumento_institucional
           SET active = false, fk_tarchivo = NULL, modified_by = p_email, modified_at = CURRENT_TIMESTAMP
         WHERE pk_documento_institucional = v_pk_doc;

        INSERT INTO pigse.tdocumento_institucional_hist
            (fk_documento_institucional, fk_tarchivo, reemplazado_by)
        VALUES (v_pk_doc, v_fk_tarchivo_previo, p_email);

        RETURN QUERY
        SELECT p_fk_tarchivo::TEXT, p_tipo::TEXT,
               (CASE p_tipo WHEN 'PEI' THEN 'Proyecto Educativo Institucional (PEI)'
                            WHEN 'PEC' THEN 'Proyecto Educativo Comunitario (PEC)' END),
               'PLAN_ESTUDIOS'::TEXT, 'Plan de estudios'::TEXT, 'PENDIENTE'::TEXT,
               NULL::TEXT, NULL::TIMESTAMP, NULL::BIGINT, NULL::BIGINT, NULL::TEXT;
        RETURN;
    END IF;

    SELECT t.pk_documento_institucional, t.fk_tarchivo
      INTO v_pk_doc, v_fk_tarchivo_previo
      FROM pigse.tdocumento_institucional t
     WHERE t.fk_testablecimiento = v_fk_establecimiento
       AND t.tipo = p_tipo
       AND t.categoria IS NOT DISTINCT FROM p_categoria
       AND t.active;

    IF v_pk_doc IS NULL OR v_fk_tarchivo_previo IS NULL THEN
        RAISE EXCEPTION 'pigse: % % desconocido o ya esta PENDIENTE para este establecimiento',
            p_tipo, COALESCE(p_categoria, '')
            USING ERRCODE = 'P0002';
    END IF;

    UPDATE pigse.tdocumento_institucional
       SET fk_tarchivo = NULL, modified_by = p_email, modified_at = CURRENT_TIMESTAMP
     WHERE pk_documento_institucional = v_pk_doc;

    INSERT INTO pigse.tdocumento_institucional_hist
        (fk_documento_institucional, fk_tarchivo, reemplazado_by)
    VALUES (v_pk_doc, v_fk_tarchivo_previo, p_email);

    RETURN QUERY
    SELECT * FROM pigse.fn_documento_categorias_listar(v_fk_establecimiento, p_tipo) c
     WHERE c.categoria = p_categoria;
END;
$$;

COMMENT ON FUNCTION pigse.fn_documento_eliminar(BIGINT, VARCHAR, VARCHAR, VARCHAR, BIGINT) IS
    'V521: PMI/PFI dejan de ser casos aparte -- van por categoria igual que PEI/PEC.';

-- ---------------------------------------------------------------------------
-- 12. Rector gana los mismos permisos de escritura que Secretario.
-- ---------------------------------------------------------------------------
INSERT INTO public.role_query (query_id, role_id)
SELECT q.id_query, ro.id_role
  FROM public.query q
 CROSS JOIN public.role ro
 WHERE q.uuid IN ('pigse-documentos-upload', 'pigse-documentos-eliminar', 'pigse-documentos-categoria-eliminar')
   AND ro.name = 'PIGSE-RECTOR'
   AND NOT EXISTS (SELECT 1 FROM public.role_query rq WHERE rq.query_id = q.id_query AND rq.role_id = ro.id_role);

-- ---------------------------------------------------------------------------
-- 13. Verificación.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_pmi_sin_categoria INTEGER;
    v_rector_grants     INTEGER;
BEGIN
    SELECT count(*) INTO v_pmi_sin_categoria
      FROM pigse.tdocumento_institucional
     WHERE tipo IN ('PMI', 'PFI') AND active AND categoria IS NULL;

    SELECT count(*) INTO v_rector_grants
      FROM public.role_query rq
      JOIN public.query q ON q.id_query = rq.query_id
      JOIN public.role ro ON ro.id_role = rq.role_id
     WHERE q.uuid IN ('pigse-documentos-upload', 'pigse-documentos-eliminar', 'pigse-documentos-categoria-eliminar')
       AND ro.name = 'PIGSE-RECTOR';

    IF v_pmi_sin_categoria > 0 THEN
        RAISE EXCEPTION 'V521 fallo: % documento(s) PMI/PFI activos sin categoria', v_pmi_sin_categoria;
    END IF;
    IF v_rector_grants <> 3 THEN
        RAISE EXCEPTION 'V521 fallo: Rector deberia tener 3 grants de escritura, tiene %', v_rector_grants;
    END IF;

    RAISE NOTICE 'V521 OK: PMI/PFI con categoria (0 sin asignar), Rector con % grants de escritura.', v_rector_grants;
END $$;
