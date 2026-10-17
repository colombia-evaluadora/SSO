-- V321 - Criterios de prioridad, capa 4 de 4: menú y endpoints.
-- Menú CRITERIOS_PRIORIDAD bajo ADMINISTRACION, solo para el Superadministrador
-- (y SSO-ADMIN en role_query). /catalogos/criterios-prioridad (activos) y su
-- /:ID/evaluar son el servicio de Cobertura (Configuración de la admisión e
-- Inscripción): los leen los mismos roles que /matricula/query.
-- Depende de: V320 (wrappers), V319 (activos y evaluador), V22 (TMENU,
-- TROL_MENU), V104 (ADMINISTRACION).

SET search_path TO academico_test, public;

INSERT INTO academico_test.TMENU (CODIGO, NOMBRE, ICONO, VISIBLE, ESTADO, URL, FK_TMENU, ORDEN, CREATED_BY)
SELECT 'ADMINISTRACION', 'Administración', 'Gear-Icon', 'S', 'A', '/administracion/registro-actividad', NULL, 2, 'migracion'
 WHERE NOT EXISTS (SELECT 1 FROM academico_test.TMENU WHERE CODIGO IN ('ADMINISTRACION', 'ADMINISTRACIÓN'));

-- NOT EXISTS sin mirar ACTIVE: un menú o una concesión desactivados a mano no reviven al re-aplicar.
INSERT INTO academico_test.TMENU (CODIGO, NOMBRE, VISIBLE, ESTADO, URL, FK_TMENU, ORDEN, CREATED_BY)
SELECT 'CRITERIOS_PRIORIDAD', 'Criterios de prioridad', 'S', 'A', '/app/administracion/criterios-prioridad', padre.PK_TMENU, 5, 'migracion'
  FROM academico_test.TMENU padre
 WHERE padre.CODIGO IN ('ADMINISTRACION', 'ADMINISTRACIÓN')
   AND padre.FK_TMENU IS NULL
   AND padre.ACTIVE = TRUE
   AND NOT EXISTS (SELECT 1 FROM academico_test.TMENU WHERE CODIGO = 'CRITERIOS_PRIORIDAD')
 ORDER BY padre.PK_TMENU
 LIMIT 1;

INSERT INTO academico_test.TROL_MENU (FK_TROL, FK_TMENU, ACTIVE, CREATED_BY, CREATED_AT)
SELECT r.PK_TROL, m.PK_TMENU, TRUE, 'migracion', CURRENT_TIMESTAMP
  FROM academico_test.TROL r
  JOIN academico_test.TMENU m ON m.CODIGO = 'CRITERIOS_PRIORIDAD' AND m.ACTIVE = TRUE
 WHERE r.CODIGO = 'SUPER_ADMINISTRADOR'
   AND r.ACTIVE = TRUE
   AND NOT EXISTS (SELECT 1 FROM academico_test.TROL_MENU tm
                    WHERE tm.FK_TROL = r.PK_TROL AND tm.FK_TMENU = m.PK_TMENU);

-- La gestión de los criterios es exclusiva del Superadministrador (Regla 7).
UPDATE academico_test.TROL_MENU tm
   SET ACTIVE = FALSE, MODIFIED_BY = 'migracion', MODIFIED_AT = CURRENT_TIMESTAMP
  FROM academico_test.TMENU m, academico_test.TROL r
 WHERE m.CODIGO = 'CRITERIOS_PRIORIDAD'
   AND tm.FK_TMENU = m.PK_TMENU
   AND r.PK_TROL = tm.FK_TROL
   AND r.CODIGO <> 'SUPER_ADMINISTRADOR'
   AND tm.ACTIVE = TRUE;

INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, action, style, param_types, detail, query)
SELECT v.uuid, m.id_microservice, v.ruta, v.metodo, 'postgres', 'SELECT', NULL,
       'f', 'f', NULL, NULL, v.param_types::jsonb, v.detalle, v.consulta
  FROM public.microservice m
 CROSS JOIN (VALUES
    ('4b8e2c71-5d3a-4f19-a2e6-7c0b9d1e3f52', '/criterios-prioridad', 'GET', '{}',
     'Criterios de prioridad no eliminados, por nombre: [{pkCriterio, nombre, descripcion, habilitado, enUso, campo:{pkCampo, codigo, nombre, tipo, categoria, bloque:{codigo, nombre}}, regla:{pkRegla, codigo, nombre}, valores:[{pkListaValor, nombre}]}]. Errores: 403 (42501) sin VER sobre CRITERIOS_PRIORIDAD.',
     $q$SELECT academico_test.fn_criterioprio_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)) AS resultado;$q$),
    ('9a1f6d38-0c2e-4b7a-8e45-3d6f2a9b1c07', '/criterios-prioridad/:ID', 'GET', '{"PARAM.ID": "BIGINT"}',
     'Un criterio de prioridad, con la misma forma que el listado. Errores: 404 (P0002); 403 (42501) sin VER.',
     $q$SELECT academico_test.fn_criterioprio_detalle(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)) AS resultado;$q$),
    ('e3c5a9f1-7b24-4d8e-9f61-2a0c4b7d8e93', '/catalogos/criterios-prioridad/campos', 'GET', '{}',
     'Bloques 2.2 a 2.13 de la matrícula e Inscripción con sus campos evaluables: [{codigo, nombre, campos:[{pkCampo, codigo, nombre, tipo, categoria, esOrdinal, reglas:[{pkRegla, codigo, nombre, motivo}], valores:[{pkListaValor, nombre}]}]}]. motivo NULL = la regla aplica. Errores: 403 (42501) sin VER sobre CRITERIOS_PRIORIDAD.',
     $q$SELECT academico_test.fn_criterioprio_campos(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)) AS resultado;$q$),
    ('1d7b3e05-6a9c-4f28-b3d1-8e5f0a2c6b49', '/criterios-prioridad', 'POST',
     '{"BODY.NOMBRE": "VARCHAR", "BODY.DESCRIPCION": "VARCHAR", "BODY.CAMPO": "BIGINT", "BODY.REGLA": "BIGINT", "BODY.VALORES": "BIGINT[]", "BODY.HABILITADO": "BOOLEAN"}',
     'Crea un criterio. BODY.NOMBRE (4-80, único), BODY.DESCRIPCION (opcional, 10-300), BODY.CAMPO (pkCampo), BODY.REGLA (pkRegla de REGLA_PRIORIDAD), BODY.VALORES (pks de la lista del campo, solo con Es uno de), BODY.HABILITADO (por defecto true). Errores: 403 (42501); 400 (22023) datos inválidos o regla que no aplica; 409 (23505) nombre repetido.',
     $q$SELECT academico_test.fn_criterioprio_crear(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.NOMBRE AS VARCHAR),
    CAST(:BODY.DESCRIPCION AS VARCHAR),
    CAST(:BODY.CAMPO AS BIGINT),
    CAST(:BODY.REGLA AS BIGINT),
    CAST(:BODY.VALORES AS BIGINT[]),
    COALESCE(CAST(:BODY.HABILITADO AS BOOLEAN), TRUE)) AS resultado;$q$),
    ('6f0e8a24-3b51-4c97-a7d2-5b9c1e4f0a68', '/criterios-prioridad/:ID', 'PUT',
     '{"PARAM.ID": "BIGINT", "BODY.NOMBRE": "VARCHAR", "BODY.DESCRIPCION": "VARCHAR", "BODY.CAMPO": "BIGINT", "BODY.REGLA": "BIGINT", "BODY.VALORES": "BIGINT[]"}',
     'Modifica un criterio que no está en uso (mismo BODY que el alta, sin HABILITADO). Errores: 404 (P0002); 403 (42501); 409 (23503) en uso: solo se desactiva; 400 (22023); 409 (23505) nombre repetido.',
     $q$SELECT academico_test.fn_criterioprio_actualizar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.NOMBRE AS VARCHAR),
    CAST(:BODY.DESCRIPCION AS VARCHAR),
    CAST(:BODY.CAMPO AS BIGINT),
    CAST(:BODY.REGLA AS BIGINT),
    CAST(:BODY.VALORES AS BIGINT[])) AS resultado;$q$),
    ('b2d4f7a9-8e13-4a5c-9b06-1f3e7c2d5a84', '/criterios-prioridad/:ID/estado', 'PUT',
     '{"PARAM.ID": "BIGINT", "BODY.HABILITADO": "BOOLEAN"}',
     'Activa (BODY.HABILITADO=true) o desactiva (false) el criterio, también si está en uso: los períodos que ya lo usan no cambian. Errores: 404 (P0002); 403 (42501); 400 (22023) sin HABILITADO o, al activar, campo o regla que ya no aplican.',
     $q$SELECT academico_test.fn_criterioprio_estado(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.HABILITADO AS BOOLEAN)) AS resultado;$q$),
    ('c8a1e6d3-2f47-4b90-8d5e-6a2b9f1c3e07', '/criterios-prioridad/:ID/eliminar', 'PUT', '{"PARAM.ID": "BIGINT"}',
     'Elimina (baja lógica) un criterio que no está en uso. Devuelve el criterio como estaba. Errores: 404 (P0002); 403 (42501); 409 (23503) en uso: solo se desactiva.',
     $q$SELECT academico_test.fn_criterioprio_eliminar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)) AS resultado;$q$),
    ('0f5c2b8e-9d36-4e71-a4b8-7c1d3e9f2a56', '/catalogos/criterios-prioridad', 'GET', '{}',
     'Criterios activos para la Configuración de la admisión (Cobertura 3.7): [{pkCriterio, nombre, descripcion, campo:{…, bloque}, regla:{codigo, nombre}}]. Solo lectura.',
     $q$SELECT academico_test.fn_criterioprio_activos() AS resultado;$q$),
    ('7e3a9c15-4b62-4d08-b1f7-9e2c5a8d0b34', '/catalogos/criterios-prioridad/:ID/evaluar', 'GET',
     '{"PARAM.ID": "BIGINT", "QUERY.MATRICULA": "BIGINT", "QUERY.INSCRIPCION": "BIGINT"}',
     'Evalúa el criterio :ID sobre ?MATRICULA= o, sin ella, ?INSCRIPCION=: {pkCriterio, nombre, regla, cumple, valor:{pk, nombre}, clave}. clave ordena ascendente con NULLS LAST (vacíos al final). Errores: 404 (P0002) criterio o matrícula inexistente; 400 (22023) sin matrícula ni inscripción.',
     $q$SELECT academico_test.fn_criterioprio_evaluar_interno(
    CAST(:PARAM.ID AS BIGINT),
    CAST(:QUERY.MATRICULA AS BIGINT),
    CAST(:QUERY.INSCRIPCION AS BIGINT)) AS resultado;$q$)
 ) AS v(uuid, ruta, metodo, param_types, detalle, consulta)
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

DELETE FROM public.role_query rq
 USING public.query q, public.microservice m, public.role r
 WHERE rq.query_id = q.id_query
   AND rq.role_id = r.id_role
   AND m.id_microservice = q.microservice_id
   AND m.serviceid = 'eval-col'
   AND (q.path_template LIKE '/criterios-prioridad%' OR q.path_template = '/catalogos/criterios-prioridad/campos')
   AND r.name NOT IN ('CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN');

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id AND m.serviceid = 'eval-col'
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE q.path_template LIKE '/criterios-prioridad%' OR q.path_template LIKE '/catalogos/criterios-prioridad%'
ON CONFLICT DO NOTHING;

-- El servicio de Cobertura: los mismos roles que ya consultan matrículas.
INSERT INTO public.role_query (role_id, query_id)
SELECT rq.role_id, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id AND m.serviceid = 'eval-col'
  JOIN public.query mat ON mat.microservice_id = q.microservice_id
                       AND mat.path_template = '/matricula/query' AND mat.http_method = 'POST'
  JOIN public.role_query rq ON rq.query_id = mat.id_query
 WHERE q.path_template IN ('/catalogos/criterios-prioridad', '/catalogos/criterios-prioridad/:ID/evaluar')
   AND q.http_method = 'GET'
ON CONFLICT DO NOTHING;
