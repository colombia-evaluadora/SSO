-- ===========================================================================
-- V512 - PEI y PEC pasan de un solo archivo a 5 anexos por categoria (Plan de
-- estudios, SIEE, Manual de convivencia, Proyectos pedagogicos transversales,
-- Plan escolar de gestion del riesgo). PMI sigue siendo un solo archivo.
-- Quedan: columna categoria + CHECKs + unico parcial, archivado de los PEI/PEC
-- viejos, fn_documentos_listar(_todos), fn_cumplimiento_metricas y las filas
-- de public.query/role_query de los endpoints de categorias.
-- fn_documento_categorias_listar/_guardar/_eliminar viven en V515.
-- ===========================================================================


ALTER TABLE pigse.tdocumento_institucional
    ADD COLUMN IF NOT EXISTS categoria VARCHAR(30);

COMMENT ON COLUMN pigse.tdocumento_institucional.categoria IS
    'V512: anexo dentro de PEI/PEC (Plan de estudios, SIEE, Manual de convivencia, Proyectos pedagogicos transversales, Plan escolar de gestion del riesgo). NULL siempre para PMI, obligatoria para PEI/PEC ACTIVOS (ver pigse_tdocumento_institucional_tipo_categoria_chk).';

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

ALTER TABLE pigse.tdocumento_institucional
    DROP CONSTRAINT IF EXISTS pigse_tdocumento_institucional_categoria_chk;

ALTER TABLE pigse.tdocumento_institucional
    ADD CONSTRAINT pigse_tdocumento_institucional_categoria_chk CHECK (
        categoria IS NULL
        OR categoria IN ('PLAN_ESTUDIOS', 'SIEE', 'MANUAL_CONVIVENCIA',
                          'PROYECTOS_TRANSVERSALES', 'PLAN_GESTION_RIESGO')
    );

ALTER TABLE pigse.tdocumento_institucional
    DROP CONSTRAINT IF EXISTS pigse_tdocumento_institucional_tipo_categoria_chk;

ALTER TABLE pigse.tdocumento_institucional
    ADD CONSTRAINT pigse_tdocumento_institucional_tipo_categoria_chk CHECK (
        NOT active
        OR (tipo = 'PMI' AND categoria IS NULL)
        OR (tipo IN ('PEI', 'PEC') AND categoria IS NOT NULL)
    );

DROP INDEX IF EXISTS pigse.u_pigse_tdocumento_inst_ee_tipo;

CREATE UNIQUE INDEX IF NOT EXISTS u_pigse_tdocumento_inst_ee_tipo_categoria
    ON pigse.tdocumento_institucional (fk_testablecimiento, tipo, (COALESCE(categoria, '')))
    WHERE active = true;

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

DROP FUNCTION IF EXISTS pigse.fn_documento_guardar(BIGINT, VARCHAR, VARCHAR, BIGINT);

DROP FUNCTION IF EXISTS pigse.fn_documento_eliminar(BIGINT, VARCHAR, VARCHAR);

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
