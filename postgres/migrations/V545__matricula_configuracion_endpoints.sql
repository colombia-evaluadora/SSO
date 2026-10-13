-- V545 — Configuración de matrícula por capas (3 de 3): endpoints.
--
-- Qué hace: GET /matricula/configuracion acepta FK_ESTABLECIMIENTO en la
-- query string y PUT /matricula/configuracion/campo/:ID en el body, los dos
-- opcionales; sin ellos responden como antes. Upsert que conserva el id y con
-- él los role_query de cada servidor: no se tocan roles.
-- Por qué aquí: módulo de configuración de matrícula por capas.
-- Depende de: V544 (funciones), V180-V182 (filas).

-- GET /matricula/configuracion
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT 'q-matcfg-obtener-v1', m.id_microservice, '/matricula/configuracion', 'GET', 'postgres', 'SELECT', NULL,
       'false', 'false', 'false', '60', NULL, NULL,
       '{"QUERY.FK_ESTABLECIMIENTO":"BIGINT"}'::jsonb,
       'La configuracion de campos de matricula (visible / obligatorio) de un establecimiento, en un objeto CONFIG. FK_ESTABLECIMIENTO (query string) es opcional: sin el responde la del unico establecimiento que el usuario administra, y 22023 si administra varios; con el, la de ese establecimiento, si el usuario tiene MATRICULA/VER sobre el. Asi un rector de varios colegios elige cual ver y el alta pide la del colegio de la sede elegida.',
       $q$SELECT academico_test.fn_matricula_config_obtener(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.FK_ESTABLECIMIENTO AS BIGINT)
) AS config;$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- PUT /matricula/configuracion/campo/:ID
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT 'q-matcfg-editcampo-v1', m.id_microservice, '/matricula/configuracion/campo/:ID', 'PUT', 'postgres', 'SELECT', NULL,
       'false', 'false', 'false', '60', NULL, NULL,
       '{"PARAM.ID":"BIGINT","BODY.VISIBLE":"BOOLEAN","BODY.REQUERIDO":"BOOLEAN","BODY.FK_ESTABLECIMIENTO":"BIGINT"}'::jsonb,
       'Cambia requerido y/o visible de un campo (:ID es el campo del catalogo, no del establecimiento) y devuelve la configuracion completa en CONFIG. FK_ESTABLECIMIENTO (body) es opcional: sin el, el unico establecimiento que el usuario administra (22023 si administra varios). Pide MATRICULA/EDITAR sobre ese establecimiento.',
       $q$SELECT academico_test.fn_matricula_config_editar_campo(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CASE WHEN CAST(:BODY.REQUERIDO AS BOOLEAN) IS NULL THEN NULL
         WHEN CAST(:BODY.REQUERIDO AS BOOLEAN) THEN 'S' ELSE 'N' END::academico_test.bool_sn,
    CASE WHEN CAST(:BODY.VISIBLE AS BOOLEAN) IS NULL THEN NULL
         WHEN CAST(:BODY.VISIBLE AS BOOLEAN) THEN 'S' ELSE 'N' END::academico_test.bool_sn,
    CAST(:BODY.FK_ESTABLECIMIENTO AS BIGINT)
) AS config;$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;
