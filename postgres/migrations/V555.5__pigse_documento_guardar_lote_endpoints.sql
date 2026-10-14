-- ===========================================================================
-- V555.5 — Endpoints del guardado "todo o nada" de Gestión documental.
--   POST /documentos/archivos      (multipart, file-service) sube un archivo
--   PUT  /documentos/:TIPO/anexos  enlaza todos los anexos de una vez
-- Roles: los mismos que pigse-documentos-upload (V149 + V521). Ese endpoint
-- sigue vivo para no romper el front anterior mientras se despliega.
-- Depende de: V555.4 (wrappers).
-- ===========================================================================

INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id,
                          path_template, execution_mode, http_method, param_types, detail)
SELECT 'pigse-documentos-archivo-preparar',
       $q$SELECT * FROM pigse.fn_documento_archivo_preparar(
              p_pk_usuario  => public.fn_get_pigse_usuario_id(:CONTEXT.USER_ID::BIGINT),
              p_email       => CAST(:CONTEXT.EMAIL AS VARCHAR),
              p_tipo        => CAST(:BODY.TIPO AS VARCHAR),
              p_categoria   => CAST(:BODY.CATEGORIA AS VARCHAR),
              p_fk_tarchivo => CAST(:BODY.ARCHIVO AS BIGINT)
          )$q$,
       'postgres', false, false, m.id_microservice,
       '/documentos/archivos', 'SELECT', 'POST',
       '{"BODY.TIPO": "TEXT!", "BODY.CATEGORIA": "TEXT!", "BODY.ARCHIVO": "FILE:documentoInstitucional!"}'::jsonb,
       'Sube UN archivo de un anexo sin enlazarlo; el enlace lo hace PUT /documentos/:TIPO/anexos.'
  FROM public.microservice m WHERE m.serviceid = 'pigse'
ON CONFLICT (uuid) DO UPDATE
   SET query = EXCLUDED.query, param_types = EXCLUDED.param_types,
       path_template = EXCLUDED.path_template, http_method = EXCLUDED.http_method,
       execution_mode = EXCLUDED.execution_mode, detail = EXCLUDED.detail;

-- ANEXOS/QUITAR por BODY_RAW: con BODY.* el motor aplanaría las listas.
INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id,
                          path_template, execution_mode, http_method, param_types, detail)
SELECT 'pigse-documentos-guardar-lote',
       $q$SELECT * FROM pigse.fn_documento_guardar_lote(
              p_pk_usuario => public.fn_get_pigse_usuario_id(:CONTEXT.USER_ID::BIGINT),
              p_email      => CAST(:CONTEXT.EMAIL AS VARCHAR),
              p_tipo       => CAST(:PARAM.TIPO AS VARCHAR),
              p_anexos     => CAST(:BODY_RAW.ANEXOS AS JSONB),
              p_quitar     => CAST(:BODY_RAW.QUITAR AS JSONB)
          )$q$,
       'postgres', false, false, m.id_microservice,
       '/documentos/:TIPO/anexos', 'SELECT', 'PUT',
       '{"PARAM.TIPO": "TEXT", "BODY_RAW.ANEXOS": "JSONB", "BODY_RAW.QUITAR": "JSONB"}'::jsonb,
       'Guarda TODOS los anexos de un documento en una transaccion; rechaza si queda un obligatorio sin archivo.'
  FROM public.microservice m WHERE m.serviceid = 'pigse'
ON CONFLICT (uuid) DO UPDATE
   SET query = EXCLUDED.query, param_types = EXCLUDED.param_types,
       path_template = EXCLUDED.path_template, http_method = EXCLUDED.http_method,
       execution_mode = EXCLUDED.execution_mode, detail = EXCLUDED.detail;

INSERT INTO public.role_query (query_id, role_id)
SELECT q.id_query, ro.id_role
  FROM public.query q
 CROSS JOIN public.role ro
 WHERE q.uuid IN ('pigse-documentos-archivo-preparar', 'pigse-documentos-guardar-lote')
   AND ro.name IN ('PIGSE-ADMINISTRADOR', 'PIGSE-RECTOR', 'PIGSE-SECRETARIO')
   AND NOT EXISTS (SELECT 1 FROM public.role_query rq WHERE rq.query_id = q.id_query AND rq.role_id = ro.id_role);

DO $$
DECLARE
    v_grants INTEGER;
BEGIN
    SELECT count(*) INTO v_grants
      FROM public.role_query rq
      JOIN public.query q ON q.id_query = rq.query_id
      JOIN public.role ro ON ro.id_role = rq.role_id
     WHERE q.uuid IN ('pigse-documentos-archivo-preparar', 'pigse-documentos-guardar-lote')
       AND ro.name IN ('PIGSE-ADMINISTRADOR', 'PIGSE-RECTOR', 'PIGSE-SECRETARIO');

    IF v_grants <> 6 THEN
        RAISE EXCEPTION 'pigse: se esperaban 6 grants (2 endpoints x 3 roles) para el guardado en lote, hay %', v_grants;
    END IF;
END $$;
