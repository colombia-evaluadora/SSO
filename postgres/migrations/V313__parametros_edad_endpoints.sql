-- V313 - Parámetros de edad, capa 5 de 5: menú y endpoints.
-- Menú PARAMETROS_EDAD bajo ADMINISTRACION solo para el Superadministrador (y
-- SSO-ADMIN en role_query), con guardar y eliminar.
-- Depende de: V312 (wrappers), V104 (ADMINISTRACION), V303 (ADMITE_*).

SET search_path TO academico_test, public;

-- NOT EXISTS sin mirar ACTIVE: un menú desactivado a mano no revive al re-aplicar.
INSERT INTO academico_test.TMENU (CODIGO, NOMBRE, VISIBLE, ESTADO, URL, FK_TMENU, ORDEN, CREATED_BY)
SELECT 'PARAMETROS_EDAD', 'Parámetros de edad', 'S', 'A', '/app/administracion/parametros-edad', padre.PK_TMENU, 6, 'migracion'
  FROM academico_test.TMENU padre
 WHERE padre.CODIGO IN ('ADMINISTRACION', 'ADMINISTRACIÓN')
   AND padre.FK_TMENU IS NULL
   AND padre.ACTIVE = TRUE
   AND NOT EXISTS (SELECT 1 FROM academico_test.TMENU WHERE CODIGO = 'PARAMETROS_EDAD')
 ORDER BY padre.PK_TMENU
 LIMIT 1;

UPDATE academico_test.TMENU
   SET ADMITE_GUARDAR = TRUE, ADMITE_ELIMINAR = TRUE
 WHERE CODIGO = 'PARAMETROS_EDAD'
   AND (ADMITE_GUARDAR IS DISTINCT FROM TRUE OR ADMITE_ELIMINAR IS DISTINCT FROM TRUE);

INSERT INTO academico_test.TROL_MENU (FK_TROL, FK_TMENU, ACTIVE, CREATED_BY, CREATED_AT)
SELECT r.PK_TROL, m.PK_TMENU, TRUE, 'migracion', CURRENT_TIMESTAMP
  FROM academico_test.TROL r
  JOIN academico_test.TMENU m ON m.CODIGO = 'PARAMETROS_EDAD' AND m.ACTIVE = TRUE
 WHERE r.CODIGO = 'SUPER_ADMINISTRADOR'
   AND r.ACTIVE = TRUE
   AND NOT EXISTS (SELECT 1 FROM academico_test.TROL_MENU tm
                    WHERE tm.FK_TROL = r.PK_TROL AND tm.FK_TMENU = m.PK_TMENU);

INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, action, style, param_types, detail, query)
SELECT v.uuid, m.id_microservice, v.ruta, v.metodo, 'postgres', 'SELECT', NULL,
       'f', 'f', NULL, NULL, v.param_types::jsonb, v.detalle, v.consulta
  FROM public.microservice m
 CROSS JOIN (VALUES
    ('53f83e01-1b19-4b5c-80cb-14b4a8dadf92', '/parametros-edad', 'GET', '{}',
     'Parámetros de la situación de edad: {grados:[{pkGrado, grado, edad}], calendarios:[{pkCalendario, calendario, mes, dia}]}, en el orden de las listas GRADOS y CALENDARIO. Errores: 403 (42501) sin VER sobre PARAMETROS_EDAD.',
     $q$SELECT academico_test.fn_parametroedad_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)) AS resultado;$q$),
    ('1b63d7e3-d8b3-44cc-b2a3-c47d2fbc3727', '/parametros-edad/grados/:GRADO', 'PUT',
     '{"PARAM.GRADO": "BIGINT", "BODY.EDAD": "INTEGER"}',
     'Crea o modifica la edad recomendada del grado :GRADO (pkListaValor de GRADOS). BODY.EDAD: años, de 2 a 25. Devuelve {pkGrado, edad}. Errores: 404 (P0002) grado inexistente; 403 (42501) sin EDITAR sobre PARAMETROS_EDAD; 400 (22023) edad fuera de rango.',
     $q$SELECT academico_test.fn_parametroedad_grado_guardar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.GRADO AS BIGINT),
    CAST(:BODY.EDAD AS INTEGER)) AS resultado;$q$),
    ('5a420f08-5e91-4722-b214-1e1f5f32b1c7', '/parametros-edad/calendarios/:CALENDARIO', 'PUT',
     '{"PARAM.CALENDARIO": "BIGINT", "BODY.MES": "INTEGER", "BODY.DIA": "INTEGER"}',
     'Crea o modifica la fecha de corte del calendario :CALENDARIO (pkListaValor de CALENDARIO). BODY.MES (1-12) y BODY.DIA (días del mes; nunca el 29 de febrero). Devuelve {pkCalendario, mes, dia}. Errores: 404 (P0002) calendario inexistente; 403 (42501) sin EDITAR sobre PARAMETROS_EDAD; 400 (22023) fecha inválida.',
     $q$SELECT academico_test.fn_parametroedad_calendario_guardar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.CALENDARIO AS BIGINT),
    CAST(:BODY.MES AS INTEGER),
    CAST(:BODY.DIA AS INTEGER)) AS resultado;$q$),
    ('d5879068-34ef-49e5-a3cb-d6c15127897a', '/parametros-edad/grados/:GRADO/eliminar', 'PUT',
     '{"PARAM.GRADO": "BIGINT"}',
     'Quita la edad recomendada del grado :GRADO (pkListaValor de GRADOS); su situación de edad queda Sin calcular. Devuelve {pkGrado}. Errores: 404 (P0002) grado inexistente o sin edad; 403 (42501) sin ELIMINAR sobre PARAMETROS_EDAD.',
     $q$SELECT academico_test.fn_parametroedad_grado_eliminar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.GRADO AS BIGINT)) AS resultado;$q$),
    ('7df178e2-d43e-43c6-ade7-4d6b97d56df4', '/parametros-edad/calendarios/:CALENDARIO/eliminar', 'PUT',
     '{"PARAM.CALENDARIO": "BIGINT"}',
     'Quita la fecha de corte del calendario :CALENDARIO (pkListaValor de CALENDARIO); su situación de edad queda Sin calcular. Devuelve {pkCalendario}. Errores: 404 (P0002) calendario inexistente o sin fecha de corte; 403 (42501) sin ELIMINAR sobre PARAMETROS_EDAD.',
     $q$SELECT academico_test.fn_parametroedad_calendario_eliminar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.CALENDARIO AS BIGINT)) AS resultado;$q$)
 ) AS v(uuid, ruta, metodo, param_types, detalle, consulta)
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id AND m.serviceid = 'eval-col'
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE q.path_template LIKE '/parametros-edad%'
ON CONFLICT DO NOTHING;
