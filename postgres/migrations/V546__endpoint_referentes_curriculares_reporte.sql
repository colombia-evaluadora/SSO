-- =============================================================================
-- V546 -- Reporte PDF/Excel de referentes curriculares (Vista Maestra).
--   POST /referentes-curriculares/reporte -> fn_refcurr_listar (V214.3) sin paginar
-- Fila que consume el reporting-service (clave `referentes-curriculares`). Misma
-- funcion, filtros y gate que POST /referentes-curriculares/query (V214), con
-- p_limite NULL (V214.3 ya lo trata como "todas las filas"). Binds bajo
-- BODY.FILTERS.* con los mismos nombres del listado + FILTERS.IDS opcional.
-- estado_label/vigencia/grados_vinculados_texto son solo presentacion ([] de
-- grados = "Todos"). FILTERS.IDS recorta por fuera, DESPUES del gate.
-- Roles copiados de 'refcurr-listar': quien ve el listado puede exportarlo.
-- DEPENDE DE: V214 (fila refcurr-listar y sus roles), V214.3 (fn_refcurr_listar).
-- =============================================================================

DELETE FROM public.query WHERE uuid = 'refcurr-reporte';

INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id,
                           path_template, execution_mode, http_method, param_types, detail)
SELECT
    'refcurr-reporte',
    $q$SELECT t.*,
       CASE WHEN t.estado = 'A' THEN 'Activo' ELSE 'Inactivo' END AS estado_label,
       CASE WHEN t.estado = 'A' THEN 'Desde ' || t.anio_vigencia_desde
            WHEN t.anio_vigencia_hasta IS NOT NULL
                 THEN 'Desde ' || t.anio_vigencia_desde || ' hasta ' || t.anio_vigencia_hasta
            ELSE t.anio_vigencia_desde::TEXT
       END AS vigencia,
       COALESCE((SELECT string_agg(g ->> 'nombre', ', ')
                   FROM jsonb_array_elements(t.grados_vinculados) g), 'Todos') AS grados_vinculados_texto
  FROM academico_test.fn_refcurr_listar(
    p_pk_usuario_solicitante      => public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    p_search                      => CAST(:BODY.FILTERS.SEARCH AS VARCHAR),
    p_fk_tnivel_ensenanza         => CAST(:BODY.FILTERS.NIVEL_EDUCATIVO AS BIGINT),
    p_fk_tlv_enfoque_pedagogico   => CAST(:BODY.FILTERS.ENFOQUE_PEDAGOGICO AS BIGINT),
    p_fk_tlv_tipo_evaluacion      => CAST(:BODY.FILTERS.TIPO_EVALUACION AS BIGINT),
    p_estado                      => CAST(:BODY.FILTERS.ESTADO AS VARCHAR),
    p_orden_por                   => CAST(:BODY.SORTING.ID AS VARCHAR),
    p_orden_asc                   => NOT COALESCE(CAST(:BODY.SORTING.DESC AS BOOLEAN), FALSE),
    p_limite                      => NULL::INT,
    p_offset                      => 0
) t
WHERE CAST(:BODY.FILTERS.IDS AS BIGINT[]) IS NULL
   OR t.pk_referente_curricular = ANY(CAST(:BODY.FILTERS.IDS AS BIGINT[]));$q$,
    'postgres', false, false, m.id_microservice,
    '/referentes-curriculares/reporte', 'SELECT', 'POST',
    '{
       "BODY.FILTERS.SEARCH":             "VARCHAR",
       "BODY.FILTERS.NIVEL_EDUCATIVO":    "BIGINT",
       "BODY.FILTERS.ENFOQUE_PEDAGOGICO": "BIGINT",
       "BODY.FILTERS.TIPO_EVALUACION":    "BIGINT",
       "BODY.FILTERS.ESTADO":             "VARCHAR",
       "BODY.FILTERS.IDS":                "BIGINT[]",
       "BODY.SORTING.ID":                 "VARCHAR",
       "BODY.SORTING.DESC":               "BOOLEAN"
     }'::jsonb,
    'Referentes curriculares SIN PAGINAR para el reporte PDF/Excel (reporting-service, clave referentes-curriculares). Misma funcion, filtros y gate VER sobre REFERENTES_CURRICULARES que POST /referentes-curriculares/query, con los binds bajo BODY.FILTERS.* (SEARCH, NIVEL_EDUCATIVO, ENFOQUE_PEDAGOGICO, TIPO_EVALUACION, ESTADO) + FILTERS.IDS para exportar seleccionados y SORTING.ID/DESC para el orden. Todos opcionales. Agrega estado_label, vigencia y grados_vinculados_texto (Todos si no hay grados) para imprimir.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col';

INSERT INTO public.role_query (query_id, role_id)
SELECT reporte.id_query, rq.role_id
  FROM public.query reporte
  JOIN public.query listado  ON listado.uuid = 'refcurr-listar'
  JOIN public.role_query rq  ON rq.query_id = listado.id_query
 WHERE reporte.uuid = 'refcurr-reporte'
ON CONFLICT (query_id, role_id) DO NOTHING;

-- Sin la fila del listado el INSERT de roles no copia nada y el reporte daria
-- 403 en silencio: mejor que reviente la migracion.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.query WHERE uuid = 'refcurr-reporte') THEN
        RAISE EXCEPTION 'No se creo la fila de POST /referentes-curriculares/reporte (falta el microservicio eval-col)';
    END IF;
END $$;
