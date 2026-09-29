-- ===========================================================================
-- V515 -- "Plan de estudios" (una de las 5 categorías de PEI/PEC, V512) deja
-- de ser un slot de UN archivo vigente: admite varios archivos activos a la
-- vez. Las otras 4 categorías (SIEE, Manual de convivencia, Proyectos
-- pedagógicos transversales, Plan escolar de gestión del riesgo) NO cambian
-- -- siguen siendo un archivo vigente por categoría, como quedó en V512.
--
-- "Completa" para Plan de estudios sigue siendo "al menos 1 archivo" -- el
-- mismo criterio de COMPLETO/PENDIENTE de fn_documentos_listar (V512) no
-- cambia: cuenta como categoría completa apenas hay 1 archivo, sin importar
-- cuántos más se agreguen después.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. Único parcial: deja de aplicar a Plan de estudios. Las otras 4
--    categorías (y PMI) siguen con "máximo 1 fila activa" como antes.
-- ---------------------------------------------------------------------------
DROP INDEX IF EXISTS pigse.u_pigse_tdocumento_inst_ee_tipo_categoria;
CREATE UNIQUE INDEX IF NOT EXISTS u_pigse_tdocumento_inst_ee_tipo_categoria
    ON pigse.tdocumento_institucional (fk_testablecimiento, tipo, (COALESCE(categoria, '')))
    WHERE active = true AND categoria IS DISTINCT FROM 'PLAN_ESTUDIOS';

-- ---------------------------------------------------------------------------
-- 2. fn_documento_categorias_listar -- Plan de estudios pasa a devolver una
--    fila POR ARCHIVO activo (`id` = pk de la fila, no la categoría, porque
--    ahora puede haber más de una) en vez de una única fila con/sin archivo.
--    Sin archivos, sigue devolviendo 1 fila PENDIENTE (misma forma que las
--    otras 4) para que la categoría siga apareciendo en la pantalla aunque
--    todavía no se haya cargado nada.
--
--    Las otras 4 categorías NO cambian de forma (1 fila fija cada una).
--
--    DROP+CREATE: mismo `RETURNS TABLE`, pero cambia de LANGUAGE sql a
--    plpgsql (la lógica condicional -- UNION de fijas + variables -- ya no
--    entra cómoda en una sola sentencia SQL declarativa).
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
    END;
    v_no_aplica BOOLEAN;
BEGIN
    SELECT (p_tipo = 'PEI' AND te.ETNIAS = 'S') OR (p_tipo = 'PEC' AND te.ETNIAS = 'N')
      INTO v_no_aplica
      FROM pigse.testablecimiento te
     WHERE te.PK_ESTABLECIMIENTO = p_fk_establecimiento;

    -- Las 4 categorías de un solo archivo -- sin cambios de comportamiento
    -- respecto a V512, solo movidas a este cuerpo plpgsql.
    RETURN QUERY
    SELECT
        cat.categoria AS id,
        p_tipo AS "type",
        v_type_name AS "typeName",
        cat.categoria AS categoria,
        cat.nombre AS "categoriaName",
        CASE
            WHEN v_no_aplica THEN 'NO_APLICA'
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
      FROM (VALUES
                ('SIEE', 'Sistema Institucional de Evaluación (SIEE)'),
                ('MANUAL_CONVIVENCIA', 'Manual de convivencia'),
                ('PROYECTOS_TRANSVERSALES', 'Proyectos pedagógicos transversales'),
                ('PLAN_GESTION_RIESGO', 'Plan escolar de gestión del riesgo')
           ) AS cat(categoria, nombre)
      LEFT JOIN pigse.tdocumento_institucional d
             ON d.fk_testablecimiento = p_fk_establecimiento
            AND d.tipo = p_tipo
            AND d.categoria = cat.categoria
            AND d.active
      LEFT JOIN pigse.v_archivo ta ON ta.pk_tarchivo = d.fk_tarchivo
     ORDER BY cat.categoria;

    -- Plan de estudios -- una fila por archivo activo.
    RETURN QUERY
    SELECT
        d.pk_documento_institucional::TEXT AS id,
        p_tipo AS "type",
        v_type_name AS "typeName",
        'PLAN_ESTUDIOS'::TEXT AS categoria,
        'Plan de estudios'::TEXT AS "categoriaName",
        (CASE WHEN v_no_aplica THEN 'NO_APLICA' ELSE 'COMPLETO' END) AS status,
        ta.nombre AS "fileName",
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

    -- Plan de estudios -- si no hay NINGÚN archivo activo todavía, una fila
    -- placeholder PENDIENTE (misma forma que las otras 4 cuando están
    -- vacías) para que la categoría siga apareciendo en la pantalla.
    IF NOT EXISTS (
        SELECT 1 FROM pigse.tdocumento_institucional
         WHERE fk_testablecimiento = p_fk_establecimiento
           AND tipo = p_tipo AND categoria = 'PLAN_ESTUDIOS' AND active
    ) THEN
        RETURN QUERY
        SELECT
            'PLAN_ESTUDIOS'::TEXT, p_tipo, v_type_name, 'PLAN_ESTUDIOS'::TEXT,
            'Plan de estudios'::TEXT,
            (CASE WHEN v_no_aplica THEN 'NO_APLICA' ELSE 'PENDIENTE' END),
            NULL::TEXT, NULL::TIMESTAMP, NULL::BIGINT, NULL::BIGINT, NULL::TEXT;
    END IF;
END;
$$;

COMMENT ON FUNCTION pigse.fn_documento_categorias_listar(BIGINT, VARCHAR) IS
    'V515: Plan de estudios devuelve una fila POR ARCHIVO activo (id = pk de tdocumento_institucional) en vez de una única fila -- admite varios archivos. Sin archivos, una fila PENDIENTE placeholder (mismo criterio que V512 para las otras 4 categorías). Las otras 4 categorías no cambian.';

-- ---------------------------------------------------------------------------
-- 3. fn_documento_guardar -- Plan de estudios pasa a ser SIEMPRE un INSERT
--    (nunca "reemplaza" el archivo existente, porque ahora puede haber
--    varios). Las otras categorías y PMI no cambian (buscan la fila activa
--    existente y la reemplazan, como en V512).
--
--    DROP+CREATE: misma firma, mismo RETURNS TABLE -- podría ser
--    CREATE OR REPLACE, pero se mantiene DROP+CREATE por consistencia con
--    el resto de esta cadena de migraciones (V512 ya lo hace así).
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

    IF p_tipo = 'PEI' AND v_etnias = 'S' THEN
        RAISE EXCEPTION 'pigse: PEI no aplica a este establecimiento (etnoeducativo -- usar PEC)'
            USING ERRCODE = '23514';
    ELSIF p_tipo = 'PEC' AND v_etnias = 'N' THEN
        RAISE EXCEPTION 'pigse: PEC no aplica a este establecimiento (no etnoeducativo -- usar PEI)'
            USING ERRCODE = '23514';
    END IF;

    IF p_categoria = 'PLAN_ESTUDIOS' THEN
        -- Nunca reemplaza: cada carga es un archivo más en la lista.
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
    'V515: Plan de estudios siempre INSERTA (nunca reemplaza) -- admite varios archivos activos. Las demas categorias y PMI conservan el comportamiento de reemplazo de V512.';

-- ---------------------------------------------------------------------------
-- 4. fn_documento_eliminar -- gana p_fk_tarchivo, OBLIGATORIO solo para Plan
--    de estudios (identifica CUÁL de los varios archivos activos se da de
--    baja). Para las demás categorías y PMI, sigue identificando la única
--    fila activa por (tipo, categoria) como en V512 -- p_fk_tarchivo debe
--    venir NULL ahí, se rechaza si no.
-- ---------------------------------------------------------------------------
-- Dos DROP, mismo motivo que V512: la firma VIEJA (4 args, primera vez que
-- corre esta migración) y la NUEVA (5 args, si se re-ejecuta sobre un
-- esquema donde ya corrió antes -- el chequeo de idempotencia de CI la
-- aplica dos veces). Sin el segundo DROP, el CREATE de abajo choca con la
-- firma que la MISMA migración ya había creado.
DROP FUNCTION IF EXISTS pigse.fn_documento_eliminar(BIGINT, VARCHAR, VARCHAR, VARCHAR);
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
    IF p_tipo = 'PMI' AND p_categoria IS NOT NULL THEN
        RAISE EXCEPTION 'pigse: PMI no tiene categorias (p_categoria debe ser NULL)'
            USING ERRCODE = '22023';
    ELSIF p_tipo IN ('PEI', 'PEC') AND p_categoria IS NULL THEN
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
        SELECT pk_documento_institucional, fk_tarchivo
          INTO v_pk_doc, v_fk_tarchivo_previo
          FROM pigse.tdocumento_institucional
         WHERE fk_testablecimiento = v_fk_establecimiento
           AND tipo = p_tipo
           AND categoria = 'PLAN_ESTUDIOS'
           AND fk_tarchivo = p_fk_tarchivo
           AND active;

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

        -- No hay "la fila que queda": esta se dio de baja del todo (no vuelve
        -- a PENDIENTE como las categorías de un solo archivo, simplemente
        -- deja de listarse). Se devuelve un eco de lo eliminado para que el
        -- front confirme la baja; la lista real la vuelve a pedir aparte
        -- (invalidación de queries).
        RETURN QUERY
        SELECT p_fk_tarchivo::TEXT, p_tipo,
               (CASE p_tipo WHEN 'PEI' THEN 'Proyecto Educativo Institucional (PEI)'
                            WHEN 'PEC' THEN 'Proyecto Educativo Comunitario (PEC)' END),
               'PLAN_ESTUDIOS'::TEXT, 'Plan de estudios'::TEXT, 'PENDIENTE'::TEXT,
               NULL::TEXT, NULL::TIMESTAMP, NULL::BIGINT, NULL::BIGINT, NULL::TEXT;
        RETURN;
    END IF;

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

COMMENT ON FUNCTION pigse.fn_documento_eliminar(BIGINT, VARCHAR, VARCHAR, VARCHAR, BIGINT) IS
    'V515: gana p_fk_tarchivo -- obligatorio para PLAN_ESTUDIOS (identifica cual de los varios archivos activos se da de baja), debe ser NULL para las demas categorias/PMI.';

-- ---------------------------------------------------------------------------
-- 5. public.query -- el eliminar de categoria puntual suma BODY.ARCHIVOID
--    (opcional en el catalogo; la funcion exige el valor solo para
--    PLAN_ESTUDIOS). Va en el BODY, no en la URL: el path_template
--    (/documentos/:TIPO/categorias/:CATEGORIA) no cambia, así que las otras
--    4 categorías (que ya llaman este mismo endpoint sin este campo) siguen
--    funcionando exactamente igual -- un PATCH sin body para ellas.
-- ---------------------------------------------------------------------------
UPDATE public.query
   SET param_types = param_types || '{"BODY.ARCHIVOID": "INTEGER"}'::jsonb,
       query = $q$SELECT * FROM pigse.fn_documento_eliminar(
              p_pk_usuario  => public.fn_get_pigse_usuario_id(:CONTEXT.USER_ID::BIGINT),
              p_email       => CAST(:CONTEXT.EMAIL AS VARCHAR),
              p_tipo        => CAST(:PARAM.TIPO AS VARCHAR),
              p_categoria   => CAST(:PARAM.CATEGORIA AS VARCHAR),
              p_fk_tarchivo => CAST(:BODY.ARCHIVOID AS BIGINT)
          )$q$
 WHERE uuid = 'pigse-documentos-categoria-eliminar';

-- ---------------------------------------------------------------------------
-- 6. Verificacion
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_param_ok BOOLEAN;
BEGIN
    SELECT (param_types ? 'BODY.ARCHIVOID') INTO v_param_ok
      FROM public.query WHERE uuid = 'pigse-documentos-categoria-eliminar';

    RAISE NOTICE 'V515: pigse-documentos-categoria-eliminar tiene BODY.ARCHIVOID=%', v_param_ok;

    IF NOT v_param_ok THEN
        RAISE EXCEPTION 'V515 fallo: pigse-documentos-categoria-eliminar no gano BODY.ARCHIVOID';
    END IF;
END $$;
