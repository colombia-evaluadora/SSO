-- ===========================================================================
-- V512 -- PEI y PEC dejan de ser UN solo archivo: pasan a tener 5 anexos por
-- categoria (Plan de estudios, SIEE, Manual de convivencia, Proyectos
-- pedagogicos transversales, Plan escolar de gestion del riesgo), cada uno
-- con su propio archivo vigente -- mismo semantica de "version vigente" que
-- ya tenia el documento entero, pero ahora una por categoria.
--
-- PMI NO cambia: sigue siendo un solo archivo (pedido explicito).
--
-- Reportado: el front solo dejaba subir 1 PDF para PEI/PEC, pero el negocio
-- exige anexos separados por categoria dentro de cada uno.
--
-- ---- Que NO cambia -----------------------------------------------------
--   - tipo sigue siendo PEI/PEC/PMI, mismo CHECK.
--   - fn_mi_establecimiento, la tabla de historial, el file-service: iguales.
--   - Los 3 path_template/http_method de siempre (/documentos,
--     /documentos/upload, /documentos/:TIPO) NO cambian de firma HTTP.
--
-- ---- Que SI cambia -------------------------------------------------------
--   - tdocumento_institucional gana `categoria` (NULL solo para PMI,
--     obligatoria para PEI/PEC -- ver CHECK). El unico parcial pasa a
--     incluirla: ahora puede haber HASTA 5 filas activas por (EE, PEI) y
--     5 por (EE, PEC), una por categoria -- antes solo 1.
--   - fn_documentos_listar: para PEI/PEC ya NO trae un archivo propio
--     (fileName/archivoId/downloadUrl quedan NULL) -- ahora reporta
--     "completedCategories"/"totalCategories" (5) y status = COMPLETO solo
--     si las 5 categorias tienen archivo. PMI sigue exactamente igual que
--     antes (un archivo, sin categorias).
--   - Nueva fn_documento_categorias_listar(p_fk_establecimiento, p_tipo):
--     el detalle de las 5 categorias de un PEI o PEC puntual -- es lo que
--     alimenta la pantalla de "entrar" a PEI/PEC.
--   - fn_documento_guardar/fn_documento_eliminar ganan p_categoria
--     (obligatorio para PEI/PEC, debe ser NULL para PMI).
--   - Nuevos endpoints: GET /documentos/:TIPO/categorias (detalle) y
--     PATCH /documentos/:TIPO/categorias/:CATEGORIA (dar de baja una
--     categoria puntual) -- el POST /documentos/upload existente suma un
--     campo BODY.CATEGORIA opcional (obligatorio en la funcion cuando
--     TIPO es PEI/PEC).
--   - fn_cumplimiento_metricas dejaba de ser correcta leyendo
--     tdocumento_institucional directo (ahora hay hasta 5 filas activas por
--     EE+tipo en vez de 1): se reescribe para pasar por
--     fn_documentos_listar(), igual que ya hacia fn_cumplimiento_listar.
--
-- ---- Los archivos YA subidos como PEI/PEC de un solo documento -----------
--   No hay forma correcta de adivinar a que categoria pertenecia un PDF
--   subido antes de que existieran categorias -- asignarlo a una al azar
--   seria peor que dejarlo en blanco (el EE creeria que esa categoria en
--   particular esta resuelta cuando en realidad es "el PEI/PEC entero de
--   antes"). Se ARCHIVAN (mismo mecanismo que fn_documento_eliminar: se
--   desactivan y quedan en tdocumento_institucional_hist, el archivo NO se
--   borra ni se pierde) y las 5 categorias quedan PENDIENTE para que el EE
--   las vuelva a cargar ya separadas. Esto es una regresion visible en el
--   tablero de Monitoreo (un PEI que hoy muestra COMPLETO va a pasar a
--   PENDIENTE hasta que se recarguen las 5 categorias) -- aviso explicito
--   para quien promueva esto a produccion, no es un bug de la migracion.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. Categoria: columna (sin CHECK todavia -- ver el punto 3: agregarlo acá
--    mismo rompía en producción, que SÍ tiene PEI/PEC de un solo archivo
--    viejos con categoria NULL todavía activos; el CHECK se valida contra
--    TODAS las filas existentes en el momento de crearse, y el archivado
--    del punto 2 corre recién después).
-- ---------------------------------------------------------------------------
ALTER TABLE pigse.tdocumento_institucional
    ADD COLUMN IF NOT EXISTS categoria VARCHAR(30);

COMMENT ON COLUMN pigse.tdocumento_institucional.categoria IS
    'V512: anexo dentro de PEI/PEC (Plan de estudios, SIEE, Manual de convivencia, Proyectos pedagogicos transversales, Plan escolar de gestion del riesgo). NULL siempre para PMI, obligatoria para PEI/PEC ACTIVOS (ver pigse_tdocumento_institucional_tipo_categoria_chk).';

-- ---------------------------------------------------------------------------
-- 2. Archiva los PEI/PEC de un solo archivo que existieran antes de esta
--    migracion (categoria todavia NULL en una fila activa PEI/PEC -- eso
--    solo puede pasar en filas creadas antes de V512). Mismo patron que
--    fn_documento_eliminar: desactiva + copia a _hist, nunca borra. Tiene
--    que correr ANTES de agregar el CHECK del punto 3.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_archivados BIGINT;
BEGIN
    INSERT INTO pigse.tdocumento_institucional_hist
        (fk_documento_institucional, fk_tarchivo, reemplazado_by)
    SELECT pk_documento_institucional, fk_tarchivo, 'V512'
      FROM pigse.tdocumento_institucional
     WHERE tipo IN ('PEI', 'PEC')
       AND categoria IS NULL
       AND active
       AND fk_tarchivo IS NOT NULL;
    GET DIAGNOSTICS v_archivados = ROW_COUNT;

    UPDATE pigse.tdocumento_institucional
       SET active = false, modified_by = 'V512', modified_at = CURRENT_TIMESTAMP
     WHERE tipo IN ('PEI', 'PEC')
       AND categoria IS NULL
       AND active;

    RAISE NOTICE 'V512: % documento(s) PEI/PEC de un solo archivo archivado(s) (categorias quedan PENDIENTE, el archivo sigue en el historial)',
        v_archivados;
END $$;

-- ---------------------------------------------------------------------------
-- 3. Los CHECK, recién ahora que el punto 2 ya dejó inactivas las filas
--    viejas que los violarían. `pigse_tdocumento_institucional_tipo_
--    categoria_chk` además exceptúa las filas YA inactivas (`NOT active`)
--    a propósito -- por si queda alguna fila historica (de un EE dado de
--    baja, por ejemplo) que el archivado de arriba no haya cubierto; el
--    invariante "categoria obligatoria para PEI/PEC" es sobre documentos
--    VIGENTES, no sobre el historial completo.
-- ---------------------------------------------------------------------------
ALTER TABLE pigse.tdocumento_institucional
    DROP CONSTRAINT IF EXISTS pigse_tdocumento_institucional_categoria_chk;
ALTER TABLE pigse.tdocumento_institucional
    ADD CONSTRAINT pigse_tdocumento_institucional_categoria_chk CHECK (
        categoria IS NULL
        OR categoria IN ('PLAN_ESTUDIOS', 'SIEE', 'MANUAL_CONVIVENCIA',
                          'PROYECTOS_TRANSVERSALES', 'PLAN_GESTION_RIESGO')
    );

-- PMI nunca lleva categoria; PEI/PEC ACTIVOS siempre la llevan.
ALTER TABLE pigse.tdocumento_institucional
    DROP CONSTRAINT IF EXISTS pigse_tdocumento_institucional_tipo_categoria_chk;
ALTER TABLE pigse.tdocumento_institucional
    ADD CONSTRAINT pigse_tdocumento_institucional_tipo_categoria_chk CHECK (
        NOT active
        OR (tipo = 'PMI' AND categoria IS NULL)
        OR (tipo IN ('PEI', 'PEC') AND categoria IS NOT NULL)
    );

-- ---------------------------------------------------------------------------
-- 5. Unico parcial: ahora por (EE, tipo, categoria) -- antes por (EE, tipo).
--    COALESCE(categoria, '') en la expresion: dos NULL no son iguales entre
--    si para un indice unico comun, y PMI SIEMPRE tiene categoria NULL, asi
--    que sin esto dos filas PMI activas del mismo EE no chocarian.
-- ---------------------------------------------------------------------------
DROP INDEX IF EXISTS pigse.u_pigse_tdocumento_inst_ee_tipo;
CREATE UNIQUE INDEX IF NOT EXISTS u_pigse_tdocumento_inst_ee_tipo_categoria
    ON pigse.tdocumento_institucional (fk_testablecimiento, tipo, (COALESCE(categoria, '')))
    WHERE active = true;

-- ---------------------------------------------------------------------------
-- 6. fn_documentos_listar -- para PEI/PEC ya no trae un archivo propio:
--    reporta el avance por categorias. PMI sin cambios de comportamiento.
--    DROP+CREATE (no OR REPLACE): cambia el RETURNS TABLE.
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
         CROSS JOIN (VALUES ('PEI'), ('PEC')) AS tipos(tipo)
         CROSS JOIN (VALUES ('PLAN_ESTUDIOS'), ('SIEE'), ('MANUAL_CONVIVENCIA'),
                             ('PROYECTOS_TRANSVERSALES'), ('PLAN_GESTION_RIESGO')) AS cat(categoria)
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
        CASE
            WHEN tipos.tipo = 'PEI' AND te.ETNIAS = 'S' THEN 'NO_APLICA'
            WHEN tipos.tipo = 'PEC' AND te.ETNIAS = 'N' THEN 'NO_APLICA'
            WHEN tipos.tipo IN ('PEI', 'PEC') THEN
                CASE WHEN c.completadas = c.total THEN 'COMPLETO' ELSE 'PENDIENTE' END
            WHEN d.fk_tarchivo IS NOT NULL THEN 'COMPLETO'
            ELSE 'PENDIENTE'
        END AS status,
        -- PEI/PEC ya no cuelgan de un archivo propio: el detalle esta en
        -- fn_documento_categorias_listar. PMI sigue igual que siempre.
        CASE WHEN tipos.tipo = 'PMI' THEN ta.nombre END AS "fileName",
        CASE WHEN tipos.tipo = 'PMI' THEN ta.created_at END AS "uploadedAt",
        CASE WHEN tipos.tipo = 'PMI' THEN ta.peso END AS "sizeBytes",
        CASE WHEN tipos.tipo = 'PMI' THEN ta.pk_tarchivo END AS "archivoId",
        CASE WHEN tipos.tipo = 'PMI' AND ta.pk_tarchivo IS NOT NULL
             THEN '/api/files/download/' || ta.pk_tarchivo
             ELSE NULL
        END AS "downloadUrl",
        c.completadas::INT AS "completedCategories",
        c.total::INT AS "totalCategories"
      FROM pigse.testablecimiento te
     CROSS JOIN (VALUES
                    ('PEI', 'Proyecto Educativo Institucional (PEI)'),
                    ('PEC', 'Proyecto Educativo Comunitario (PEC)'),
                    ('PMI', 'Plan de Mejoramiento Institucional (PMI)')
                ) AS tipos(tipo, nombre)
      LEFT JOIN pigse.tdocumento_institucional d
             ON d.fk_testablecimiento = te.PK_ESTABLECIMIENTO
            AND d.tipo = tipos.tipo
            AND d.tipo = 'PMI'
            AND d.active
      LEFT JOIN pigse.v_archivo ta ON ta.pk_tarchivo = d.fk_tarchivo
      LEFT JOIN categorias c
             ON c.fk_establecimiento = te.PK_ESTABLECIMIENTO
            AND c.tipo = tipos.tipo
     WHERE te.PK_ESTABLECIMIENTO = p_fk_establecimiento
     ORDER BY tipos.tipo;
$$;

COMMENT ON FUNCTION pigse.fn_documentos_listar(BIGINT) IS
    'V512: PEI/PEC ya no traen archivo propio -- "completedCategories"/"totalCategories" resumen el avance de sus 5 anexos (ver fn_documento_categorias_listar para el detalle). PMI sin cambios.';

-- ---------------------------------------------------------------------------
-- 7. Nueva: detalle de las 5 categorias de un PEI o PEC puntual.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pigse.fn_documento_categorias_listar(
    p_fk_establecimiento BIGINT,
    p_tipo                VARCHAR
)
RETURNS TABLE(
    id TEXT, type TEXT, "typeName" TEXT, categoria TEXT, "categoriaName" TEXT,
    status TEXT, "fileName" TEXT, "uploadedAt" TIMESTAMP, "sizeBytes" BIGINT,
    "archivoId" BIGINT, "downloadUrl" TEXT
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        cat.categoria AS id,
        p_tipo AS "type",
        -- Mismas 2 etiquetas que ya usa fn_documentos_listar -- PMI no
        -- entra acá (el llamador nunca pide categorías de un PMI).
        CASE p_tipo
            WHEN 'PEI' THEN 'Proyecto Educativo Institucional (PEI)'
            WHEN 'PEC' THEN 'Proyecto Educativo Comunitario (PEC)'
        END AS "typeName",
        cat.categoria AS categoria,
        cat.nombre AS "categoriaName",
        CASE
            WHEN p_tipo = 'PEI' AND te.ETNIAS = 'S' THEN 'NO_APLICA'
            WHEN p_tipo = 'PEC' AND te.ETNIAS = 'N' THEN 'NO_APLICA'
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
        END AS "downloadUrl"
      FROM pigse.testablecimiento te
     CROSS JOIN (VALUES
                    ('PLAN_ESTUDIOS', 'Plan de estudios'),
                    ('SIEE', 'Sistema Institucional de Evaluación (SIEE)'),
                    ('MANUAL_CONVIVENCIA', 'Manual de convivencia'),
                    ('PROYECTOS_TRANSVERSALES', 'Proyectos pedagógicos transversales'),
                    ('PLAN_GESTION_RIESGO', 'Plan escolar de gestión del riesgo')
                ) AS cat(categoria, nombre)
      LEFT JOIN pigse.tdocumento_institucional d
             ON d.fk_testablecimiento = te.PK_ESTABLECIMIENTO
            AND d.tipo = p_tipo
            AND d.categoria = cat.categoria
            AND d.active
      LEFT JOIN pigse.v_archivo ta ON ta.pk_tarchivo = d.fk_tarchivo
     WHERE te.PK_ESTABLECIMIENTO = p_fk_establecimiento
     ORDER BY cat.categoria;
$$;

COMMENT ON FUNCTION pigse.fn_documento_categorias_listar(BIGINT, VARCHAR) IS
    'V512: los 5 anexos de un PEI o PEC puntual -- alimenta la pantalla de "entrar" a PEI/PEC desde Gestion documental. p_tipo debe ser PEI o PEC (PMI no tiene categorias, no lo valida acá -- el llamador nunca navega ahí para PMI).';

-- ---------------------------------------------------------------------------
-- 8. fn_documento_guardar / fn_documento_eliminar ganan p_categoria.
--    DROP+CREATE: cambia la firma (nuevo parametro) y el RETURNS TABLE.
-- ---------------------------------------------------------------------------
-- Dos DROP: la firma VIEJA (4 args, primera vez que corre esta migración) y
-- la NUEVA (5 args, si esta migración se re-ejecuta sobre un esquema donde
-- ya corrió antes -- el chequeo de idempotencia de CI la aplica dos veces).
-- Sin el segundo DROP, el CREATE de abajo choca con la firma que la MISMA
-- migración ya había creado.
DROP FUNCTION IF EXISTS pigse.fn_documento_guardar(BIGINT, VARCHAR, VARCHAR, BIGINT);
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
    v_etnias              pigse.bool_sn;
BEGIN
    IF p_fk_tarchivo IS NULL THEN
        RAISE EXCEPTION 'pigse: p_fk_tarchivo es obligatorio (archivo no subido)';
    END IF;

    IF p_tipo = 'PMI' AND p_categoria IS NOT NULL THEN
        RAISE EXCEPTION 'pigse: PMI no tiene categorias (p_categoria debe ser NULL)'
            USING ERRCODE = '22023';
    ELSIF p_tipo IN ('PEI', 'PEC') AND p_categoria IS NULL THEN
        RAISE EXCEPTION 'pigse: % requiere indicar la categoria del anexo', p_tipo
            USING ERRCODE = '22023';
    ELSIF p_categoria IS NOT NULL
          AND p_categoria NOT IN ('PLAN_ESTUDIOS', 'SIEE', 'MANUAL_CONVIVENCIA',
                                   'PROYECTOS_TRANSVERSALES', 'PLAN_GESTION_RIESGO') THEN
        RAISE EXCEPTION 'pigse: categoria invalida: %', p_categoria
            USING ERRCODE = '22023';
    END IF;

    v_fk_establecimiento := pigse.fn_mi_establecimiento(p_email);

    SELECT ETNIAS INTO v_etnias
      FROM pigse.testablecimiento
     WHERE PK_ESTABLECIMIENTO = v_fk_establecimiento;

    -- Mismos mensajes y ERRCODE que V152/V261: hay clientes que ya los parsean.
    IF p_tipo = 'PEI' AND v_etnias = 'S' THEN
        RAISE EXCEPTION 'pigse: PEI no aplica a este establecimiento (etnoeducativo -- usar PEC)'
            USING ERRCODE = '23514';
    ELSIF p_tipo = 'PEC' AND v_etnias = 'N' THEN
        RAISE EXCEPTION 'pigse: PEC no aplica a este establecimiento (no etnoeducativo -- usar PEI)'
            USING ERRCODE = '23514';
    END IF;

    SELECT pk_documento_institucional, fk_tarchivo
      INTO v_pk_doc, v_fk_tarchivo_previo
      FROM pigse.tdocumento_institucional
     WHERE fk_testablecimiento = v_fk_establecimiento
       AND tipo = p_tipo
       AND categoria IS NOT DISTINCT FROM p_categoria
       AND active;

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

    IF p_tipo = 'PMI' THEN
        RETURN QUERY
        SELECT l.id, l.type, l."typeName", NULL::TEXT, NULL::TEXT, l.status,
               l."fileName", l."uploadedAt", l."sizeBytes", l."archivoId", l."downloadUrl"
          FROM pigse.fn_documentos_listar(v_fk_establecimiento) l
         WHERE l.id = p_tipo;
    ELSE
        RETURN QUERY
        SELECT * FROM pigse.fn_documento_categorias_listar(v_fk_establecimiento, p_tipo)
         WHERE categoria = p_categoria;
    END IF;
END;
$$;

COMMENT ON FUNCTION pigse.fn_documento_guardar(BIGINT, VARCHAR, VARCHAR, BIGINT, VARCHAR) IS
    'V512: gana p_categoria -- obligatoria para PEI/PEC (una de las 5 fijas), debe ser NULL para PMI. Devuelve la forma de fn_documento_categorias_listar para PEI/PEC, o la de fn_documentos_listar (categoria/categoriaName en NULL) para PMI -- mismo shape que ya esperaba el front.';

-- Mismo motivo que arriba: firma vieja (3 args) + firma nueva (4 args).
DROP FUNCTION IF EXISTS pigse.fn_documento_eliminar(BIGINT, VARCHAR, VARCHAR);
DROP FUNCTION IF EXISTS pigse.fn_documento_eliminar(BIGINT, VARCHAR, VARCHAR, VARCHAR);

CREATE FUNCTION pigse.fn_documento_eliminar(
    p_pk_usuario BIGINT,
    p_email      VARCHAR,
    p_tipo       VARCHAR,
    p_categoria  VARCHAR DEFAULT NULL
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
    IF p_tipo = 'PMI' AND p_categoria IS NOT NULL THEN
        RAISE EXCEPTION 'pigse: PMI no tiene categorias (p_categoria debe ser NULL)'
            USING ERRCODE = '22023';
    ELSIF p_tipo IN ('PEI', 'PEC') AND p_categoria IS NULL THEN
        RAISE EXCEPTION 'pigse: % requiere indicar la categoria del anexo a eliminar', p_tipo
            USING ERRCODE = '22023';
    END IF;

    v_fk_establecimiento := pigse.fn_mi_establecimiento(p_email);

    SELECT pk_documento_institucional, fk_tarchivo
      INTO v_pk_doc, v_fk_tarchivo_previo
      FROM pigse.tdocumento_institucional
     WHERE fk_testablecimiento = v_fk_establecimiento
       AND tipo = p_tipo
       AND categoria IS NOT DISTINCT FROM p_categoria
       AND active;

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

    IF p_tipo = 'PMI' THEN
        RETURN QUERY
        SELECT l.id, l.type, l."typeName", NULL::TEXT, NULL::TEXT, l.status,
               l."fileName", l."uploadedAt", l."sizeBytes", l."archivoId", l."downloadUrl"
          FROM pigse.fn_documentos_listar(v_fk_establecimiento) l
         WHERE l.id = p_tipo;
    ELSE
        RETURN QUERY
        SELECT * FROM pigse.fn_documento_categorias_listar(v_fk_establecimiento, p_tipo)
         WHERE categoria = p_categoria;
    END IF;
END;
$$;

COMMENT ON FUNCTION pigse.fn_documento_eliminar(BIGINT, VARCHAR, VARCHAR, VARCHAR) IS
    'V512: gana p_categoria -- misma regla que fn_documento_guardar. Sigue siendo baja logica: el archivo pasa al historial, nunca se borra.';

-- ---------------------------------------------------------------------------
-- 9. fn_cumplimiento_metricas -- ya NO puede leer tdocumento_institucional
--    directo (PEI/PEC pueden tener hasta 5 filas activas por EE ahora): pasa
--    a apoyarse en fn_documentos_listar(), igual que ya hacia
--    fn_cumplimiento_listar. Mismo shape de salida, mismo criterio de
--    "completo" (status = COMPLETO, que ya exige las 5 categorias para
--    PEI/PEC).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pigse.fn_cumplimiento_metricas()
RETURNS TABLE("totalEstablishments" BIGINT, pei JSONB, pec JSONB, pmi JSONB)
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
            'total',     count(*) FILTER (WHERE ee.etnias = 'N'),
            'percent',   CASE WHEN count(*) FILTER (WHERE ee.etnias = 'N') = 0 THEN 0
                              ELSE round(100.0 * count(*) FILTER (WHERE docs.tipo = 'PEI' AND docs.completo)
                                         / count(*) FILTER (WHERE ee.etnias = 'N'))
                          END
        ) AS pei,
        jsonb_build_object(
            'completed', count(*) FILTER (WHERE docs.tipo = 'PEC' AND docs.completo),
            'total',     count(*) FILTER (WHERE ee.etnias = 'S'),
            'percent',   CASE WHEN count(*) FILTER (WHERE ee.etnias = 'S') = 0 THEN 0
                              ELSE round(100.0 * count(*) FILTER (WHERE docs.tipo = 'PEC' AND docs.completo)
                                         / count(*) FILTER (WHERE ee.etnias = 'S'))
                          END
        ) AS pec,
        jsonb_build_object(
            'completed', count(*) FILTER (WHERE docs.tipo = 'PMI' AND docs.completo),
            'total',     (SELECT count(*) FROM ee),
            'percent',   CASE WHEN (SELECT count(*) FROM ee) = 0 THEN 0
                              ELSE round(100.0 * count(*) FILTER (WHERE docs.tipo = 'PMI' AND docs.completo)
                                         / (SELECT count(*) FROM ee))
                          END
        ) AS pmi
      FROM ee
      LEFT JOIN docs ON docs.pk_establecimiento = ee.pk_establecimiento;
$$;

COMMENT ON FUNCTION pigse.fn_cumplimiento_metricas() IS
    'V512: pasa a leer fn_documentos_listar() (antes leia tdocumento_institucional directo) porque PEI/PEC ahora pueden tener hasta 5 filas activas por EE -- contarlas crudas habria inflado "completed". "completo" = status COMPLETO, que para PEI/PEC ya exige las 5 categorias.';

-- ---------------------------------------------------------------------------
-- 9.1 fn_documentos_listar_todos (V368, fiscalización PIGSE-ADMINISTRADOR/
--     PIGSE-SECRETARIA_TERRITORIAL) -- mismo problema que fn_cumplimiento_
--     metricas: hace `LEFT JOIN tdocumento_institucional ON tipo = ... AND
--     active` sin filtrar categoria, así que con hasta 5 filas activas por
--     (EE, PEI) el join hace fan-out y duplicaba la fila 5 veces con
--     archivo/status distintos. Mismo tratamiento que fn_documentos_listar:
--     PEI/PEC reportan avance por categorías, no un archivo propio.
--     DROP+CREATE: cambia el RETURNS TABLE (gana completedCategories/
--     totalCategories).
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
         CROSS JOIN (VALUES ('PEI'), ('PEC')) AS tipos(tipo)
         CROSS JOIN (VALUES ('PLAN_ESTUDIOS'), ('SIEE'), ('MANUAL_CONVIVENCIA'),
                             ('PROYECTOS_TRANSVERSALES'), ('PLAN_GESTION_RIESGO')) AS cat(categoria)
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
        CASE
            WHEN tipos.tipo = 'PEI' AND te.ETNIAS = 'S' THEN 'NO_APLICA'
            WHEN tipos.tipo = 'PEC' AND te.ETNIAS = 'N' THEN 'NO_APLICA'
            WHEN tipos.tipo IN ('PEI', 'PEC') THEN
                CASE WHEN c.completadas = c.total THEN 'COMPLETO' ELSE 'PENDIENTE' END
            WHEN d.fk_tarchivo IS NOT NULL THEN 'COMPLETO'
            ELSE 'PENDIENTE'
        END AS status,
        CASE WHEN tipos.tipo = 'PMI' THEN ta.nombre END AS "fileName",
        CASE WHEN tipos.tipo = 'PMI' THEN ta.created_at END AS "uploadedAt",
        CASE WHEN tipos.tipo = 'PMI' THEN ta.peso END AS "sizeBytes",
        CASE WHEN tipos.tipo = 'PMI' THEN ta.pk_tarchivo END AS "archivoId",
        CASE WHEN tipos.tipo = 'PMI' AND ta.pk_tarchivo IS NOT NULL
             THEN '/api/files/download/' || ta.pk_tarchivo
             ELSE NULL
        END AS "downloadUrl",
        te.PK_ESTABLECIMIENTO AS "establecimientoId",
        te.NOMBRE AS "establecimientoNombre",
        c.completadas::INT AS "completedCategories",
        c.total::INT AS "totalCategories"
      FROM pigse.testablecimiento te
     CROSS JOIN (VALUES
                    ('PEI', 'Proyecto Educativo Institucional (PEI)'),
                    ('PEC', 'Proyecto Educativo Comunitario (PEC)'),
                    ('PMI', 'Plan de Mejoramiento Institucional (PMI)')
                ) AS tipos(tipo, nombre)
      LEFT JOIN pigse.tdocumento_institucional d
             ON d.fk_testablecimiento = te.PK_ESTABLECIMIENTO
            AND d.tipo = tipos.tipo
            AND d.tipo = 'PMI'
            AND d.active
      LEFT JOIN pigse.v_archivo ta ON ta.pk_tarchivo = d.fk_tarchivo
      LEFT JOIN categorias c
             ON c.fk_establecimiento = te.PK_ESTABLECIMIENTO
            AND c.tipo = tipos.tipo
     WHERE te.ACTIVE = TRUE
     ORDER BY te.NOMBRE, tipos.tipo;
$$;

COMMENT ON FUNCTION pigse.fn_documentos_listar_todos() IS
    'V512: PEI/PEC ya no leen tdocumento_institucional como un archivo propio (evita el fan-out de hasta 5 filas por categoría) -- reportan completedCategories/totalCategories, igual que fn_documentos_listar. PMI sin cambios.';

-- ---------------------------------------------------------------------------
-- 10. public.query -- nuevos endpoints + el upload existente gana
--    BODY.CATEGORIA (opcional en el catalogo; la funcion exige el valor
--    cuando corresponde).
-- ---------------------------------------------------------------------------
UPDATE public.query
   SET param_types = param_types || '{"BODY.CATEGORIA": "VARCHAR"}'::jsonb,
       query = $q$SELECT * FROM pigse.fn_documento_guardar(
              p_pk_usuario   => public.fn_get_pigse_usuario_id(:CONTEXT.USER_ID::BIGINT),
              p_email        => CAST(:CONTEXT.EMAIL AS VARCHAR),
              p_tipo         => CAST(:BODY.TIPO AS VARCHAR),
              p_fk_tarchivo  => CAST(:BODY.ARCHIVO AS BIGINT),
              p_categoria    => CAST(:BODY.CATEGORIA AS VARCHAR)
          )$q$
 WHERE uuid = 'pigse-documentos-upload';

UPDATE public.query
   SET query = $q$SELECT * FROM pigse.fn_documento_eliminar(
              p_pk_usuario => public.fn_get_pigse_usuario_id(:CONTEXT.USER_ID::BIGINT),
              p_email      => CAST(:CONTEXT.EMAIL AS VARCHAR),
              p_tipo       => CAST(:PARAM.TIPO AS VARCHAR)
          )$q$
 WHERE uuid = 'pigse-documentos-eliminar';

INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id,
                          path_template, execution_mode, http_method, param_types)
SELECT 'pigse-documentos-categorias-listar',
       $q$SELECT * FROM pigse.fn_documento_categorias_listar(
                pigse.fn_mi_establecimiento(:CONTEXT.EMAIL),
                CAST(:PARAM.TIPO AS VARCHAR)
            )$q$,
       'postgres', false, false, m.id_microservice,
       '/documentos/:TIPO/categorias', 'SELECT', 'GET',
       '{"PARAM.TIPO": "TEXT"}'::jsonb
  FROM public.microservice m WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE uuid = 'pigse-documentos-categorias-listar');

INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id,
                          path_template, execution_mode, http_method, param_types)
SELECT 'pigse-documentos-categoria-eliminar',
       $q$SELECT * FROM pigse.fn_documento_eliminar(
                p_pk_usuario => public.fn_get_pigse_usuario_id(:CONTEXT.USER_ID::BIGINT),
                p_email      => CAST(:CONTEXT.EMAIL AS VARCHAR),
                p_tipo       => CAST(:PARAM.TIPO AS VARCHAR),
                p_categoria  => CAST(:PARAM.CATEGORIA AS VARCHAR)
            )$q$,
       'postgres', false, false, m.id_microservice,
       '/documentos/:TIPO/categorias/:CATEGORIA', 'SELECT', 'PATCH',
       '{"PARAM.TIPO": "TEXT", "PARAM.CATEGORIA": "TEXT"}'::jsonb
  FROM public.microservice m WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE uuid = 'pigse-documentos-categoria-eliminar');

-- role_query: mismos roles que ya tenian listar/eliminar (mas
-- RESPONSABLE_CARGUE, V359).
INSERT INTO public.role_query (query_id, role_id)
SELECT q.id_query, ro.id_role
  FROM public.query q
 CROSS JOIN public.role ro
 WHERE q.uuid = 'pigse-documentos-categorias-listar'
   AND ro.name IN ('PIGSE-ADMINISTRADOR', 'PIGSE-RECTOR', 'PIGSE-SECRETARIO', 'PIGSE-RESPONSABLE_CARGUE')
   AND NOT EXISTS (SELECT 1 FROM public.role_query rq WHERE rq.query_id = q.id_query AND rq.role_id = ro.id_role);

INSERT INTO public.role_query (query_id, role_id)
SELECT q.id_query, ro.id_role
  FROM public.query q
 CROSS JOIN public.role ro
 WHERE q.uuid = 'pigse-documentos-categoria-eliminar'
   AND ro.name IN ('PIGSE-ADMINISTRADOR', 'PIGSE-SECRETARIO', 'PIGSE-RESPONSABLE_CARGUE')
   AND NOT EXISTS (SELECT 1 FROM public.role_query rq WHERE rq.query_id = q.id_query AND rq.role_id = ro.id_role);

-- ---------------------------------------------------------------------------
-- 11. Verificacion
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_queries      BIGINT;
    v_role_query   BIGINT;
    v_pei_pec_sin_categoria BIGINT;
BEGIN
    SELECT count(*) INTO v_queries
      FROM public.query
     WHERE uuid IN ('pigse-documentos-categorias-listar', 'pigse-documentos-categoria-eliminar');

    SELECT count(*) INTO v_role_query
      FROM public.role_query rq
      JOIN public.query q ON q.id_query = rq.query_id
     WHERE q.uuid IN ('pigse-documentos-categorias-listar', 'pigse-documentos-categoria-eliminar');

    SELECT count(*) INTO v_pei_pec_sin_categoria
      FROM pigse.tdocumento_institucional
     WHERE tipo IN ('PEI', 'PEC') AND categoria IS NULL AND active;

    RAISE NOTICE 'V512: nuevas queries=% (esperado 2) role_query nuevos=% (esperado 7: 4+3) PEI/PEC activos sin categoria=% (esperado 0)',
        v_queries, v_role_query, v_pei_pec_sin_categoria;

    IF v_queries <> 2 THEN
        RAISE EXCEPTION 'V512 fallo: se esperaban 2 queries nuevas, se encontraron %', v_queries;
    END IF;
    IF v_pei_pec_sin_categoria <> 0 THEN
        RAISE EXCEPTION 'V512 fallo: quedaron % fila(s) PEI/PEC activas sin categoria (el CHECK deberia haberlo impedido)',
            v_pei_pec_sin_categoria;
    END IF;
END $$;
