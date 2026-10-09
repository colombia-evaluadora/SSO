-- ===========================================================================
-- V555.1 — GET /cumplimiento/establecimientos/:ESTABLECIMIENTO/documentos/:TIPO
-- Detalle documental de UN establecimiento para el tablero de Monitoreo: el
-- estado del tipo (avance, plazo) más cada anexo con sus archivos. Los roles
-- territoriales no pueden usar /documentos/:TIPO/categorias (resuelve el EE
-- del token), por eso este endpoint recibe el establecimiento por la ruta.
-- Gate: el usuario debe tener algún rol con acceso a /cumplimiento/query; los
-- grants se copian de ese endpoint (mismo criterio que V197).
-- Depende de: V523 (fn_cumplimiento_listar), V554/V554.1 (anexos por categoría).
-- ===========================================================================
CREATE OR REPLACE FUNCTION pigse.fn_cumplimiento_assert_acceso(p_id_user BIGINT)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
          FROM public.role_users ru
          JOIN public.role_query rq ON rq.role_id = ru.role_id
          JOIN public.query q ON q.id_query = rq.query_id
          JOIN public.microservice m ON m.id_microservice = q.microservice_id AND m.serviceid = 'pigse'
         WHERE ru.user_id = p_id_user
           AND q.path_template = '/cumplimiento/query'
    ) THEN
        RAISE EXCEPTION 'El usuario no tiene permisos para consultar el monitoreo documental'
            USING ERRCODE = '42501';
    END IF;
END;
$$;

COMMENT ON FUNCTION pigse.fn_cumplimiento_assert_acceso(BIGINT) IS
    'Gate de lectura del tablero de Monitoreo: el usuario debe tener un rol con acceso a /cumplimiento/query.';

CREATE OR REPLACE FUNCTION pigse.fn_cumplimiento_documento_detalle_interno(
    p_fk_establecimiento  BIGINT,
    p_tipo                VARCHAR
)
RETURNS TABLE(
    "establishmentId" BIGINT, "establishmentName" TEXT, "establishmentCode" TEXT,
    municipio TEXT, etnoeducativo BOOLEAN, type TEXT, "typeName" TEXT,
    status TEXT, estado TEXT, "completedCategories" INT, "totalCategories" INT,
    "lastUploadedAt" TIMESTAMP, "fechaLimite" DATE, "tieneExcepcion" BOOLEAN,
    plazo TEXT, categorias JSONB
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_tipo TEXT := upper(trim(p_tipo));
BEGIN
    IF v_tipo IS NULL OR v_tipo NOT IN ('PEI', 'PEC', 'PMI', 'PFI') THEN
        RAISE EXCEPTION 'Tipo de documento invalido: %', p_tipo USING ERRCODE = '22023';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pigse.testablecimiento te
         WHERE te.PK_ESTABLECIMIENTO = p_fk_establecimiento AND te.ACTIVE
    ) THEN
        RAISE EXCEPTION 'El establecimiento educativo no existe' USING ERRCODE = 'P0002';
    END IF;

    RETURN QUERY
    WITH cab AS (
        SELECT c.*, CASE v_tipo WHEN 'PEI' THEN c.pei WHEN 'PEC' THEN c.pec
                                WHEN 'PMI' THEN c.pmi ELSE c.pfi END AS doc
          FROM pigse.fn_cumplimiento_listar(p_fk_establecimiento) c
    ),
    anexos AS (
        SELECT a.categoria,
               min(a."categoriaName") AS nombre,
               min(a.ord) AS orden,
               jsonb_agg(jsonb_build_object(
                   'id', a.id,
                   'archivoId', a."archivoId",
                   'fileName', a."fileName",
                   'uploadedAt', a."uploadedAt",
                   'sizeBytes', a."sizeBytes",
                   'downloadUrl', a."downloadUrl"
               ) ORDER BY a."uploadedAt") FILTER (WHERE a."archivoId" IS NOT NULL) AS archivos,
               bool_or(a.status = 'NO_APLICA') AS no_aplica
          FROM (SELECT l.*, row_number() OVER () AS ord
                  FROM pigse.fn_documento_categorias_listar(p_fk_establecimiento, v_tipo) l) a
         GROUP BY a.categoria
    )
    SELECT
        cab.id, cab."establishmentName", cab."establishmentCode", cab.municipio,
        cab.etnoeducativo, v_tipo,
        CASE v_tipo
            WHEN 'PEI' THEN 'Proyecto Educativo Institucional (PEI)'
            WHEN 'PEC' THEN 'Proyecto Educativo Comunitario (PEC)'
            WHEN 'PMI' THEN 'Plan de Mejoramiento Institucional (PMI)'
            ELSE 'Plan de Fortalecimiento Institucional (PFI)'
        END,
        cab.doc->>'status', cab.doc->>'estado',
        (cab.doc->>'completedCategories')::INT, (cab.doc->>'totalCategories')::INT,
        (cab.doc->>'lastUploadedAt')::TIMESTAMP,
        cab."fechaLimite", cab."tieneExcepcion", cab.plazo,
        COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'categoria', an.categoria,
                       'categoriaName', an.nombre,
                       -- Mismo criterio que fn_documentos_listar: el plan de
                       -- gestión del riesgo no cuenta para el COMPLETO.
                       'obligatoria', an.categoria <> 'PLAN_GESTION_RIESGO',
                       'status', CASE WHEN an.no_aplica THEN 'NO_APLICA'
                                      WHEN an.archivos IS NOT NULL THEN 'COMPLETO'
                                      ELSE 'PENDIENTE' END,
                       'multiple', an.categoria = 'PLAN_ESTUDIOS',
                       'archivos', COALESCE(an.archivos, '[]'::jsonb)
                   ) ORDER BY an.categoria <> 'PLAN_ESTUDIOS', an.orden)
              FROM anexos an
        ), '[]'::jsonb)
      FROM cab;
END;
$$;

COMMENT ON FUNCTION pigse.fn_cumplimiento_documento_detalle_interno(BIGINT, VARCHAR) IS
    'INTERNO: detalle documental (estado, plazo, anexos y archivos) de un establecimiento; lo usa fn_cumplimiento_documento_detalle.';

CREATE OR REPLACE FUNCTION pigse.fn_cumplimiento_documento_detalle(
    p_id_user             BIGINT,
    p_fk_establecimiento  BIGINT,
    p_tipo                VARCHAR
)
RETURNS TABLE(
    "establishmentId" BIGINT, "establishmentName" TEXT, "establishmentCode" TEXT,
    municipio TEXT, etnoeducativo BOOLEAN, type TEXT, "typeName" TEXT,
    status TEXT, estado TEXT, "completedCategories" INT, "totalCategories" INT,
    "lastUploadedAt" TIMESTAMP, "fechaLimite" DATE, "tieneExcepcion" BOOLEAN,
    plazo TEXT, categorias JSONB
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM pigse.fn_cumplimiento_assert_acceso(p_id_user);
    RETURN QUERY SELECT * FROM pigse.fn_cumplimiento_documento_detalle_interno(p_fk_establecimiento, p_tipo);
END;
$$;

COMMENT ON FUNCTION pigse.fn_cumplimiento_documento_detalle(BIGINT, BIGINT, VARCHAR) IS
    'GET /cumplimiento/establecimientos/:ESTABLECIMIENTO/documentos/:TIPO: estado, plazo y anexos (con sus archivos) de un tipo documental de cualquier establecimiento, para los roles del tablero de Monitoreo.';

INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id,
                          path_template, execution_mode, http_method, param_types, detail)
SELECT 'pigse-cumplimiento-documento-detalle',
       $q$SELECT * FROM pigse.fn_cumplimiento_documento_detalle(
                :CONTEXT.USER_ID::BIGINT,
                CAST(:PARAM.ESTABLECIMIENTO AS BIGINT),
                CAST(:PARAM.TIPO AS VARCHAR)
            )$q$,
       'postgres', false, false, m.id_microservice,
       '/cumplimiento/establecimientos/:ESTABLECIMIENTO/documentos/:TIPO', 'SELECT', 'GET',
       '{"PARAM.ESTABLECIMIENTO": "INTEGER", "PARAM.TIPO": "VARCHAR"}'::jsonb,
       'V555.1: detalle documental (anexos y archivos) de un establecimiento para Monitoreo.'
  FROM public.microservice m WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE uuid = 'pigse-cumplimiento-documento-detalle');

-- Mismos roles que el tablero: se copian de /cumplimiento/query.
INSERT INTO public.role_query (query_id, role_id)
SELECT DISTINCT nuevo.id_query, rq.role_id
  FROM public.query nuevo
  JOIN public.query tablero
    ON tablero.path_template = '/cumplimiento/query'
   AND tablero.microservice_id = nuevo.microservice_id
  JOIN public.role_query rq ON rq.query_id = tablero.id_query
 WHERE nuevo.uuid = 'pigse-cumplimiento-documento-detalle'
   AND NOT EXISTS (SELECT 1 FROM public.role_query ex
                    WHERE ex.query_id = nuevo.id_query AND ex.role_id = rq.role_id);
