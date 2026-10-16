-- V317 - Catálogo de Áreas oficiales, capa 4 de 4: menú y endpoints.
-- Menú AREAS_OFICIALES bajo ADMINISTRACION solo para el Superadministrador (y
-- SSO-ADMIN en role_query). ADMINISTRACION se crea si falta: en una base
-- limpia esta migración corre antes que V113, como V104. /catalogos/areas-oficiales
-- es la lectura de los selectores (Referente, Plan de Estudio): la ven los
-- mismos roles que /areas/general.
-- Depende de: V316 (wrappers), V315 (fn_areaoficial_opciones), V22 (TMENU,
-- TROL_MENU), V77 (/areas/general).

SET search_path TO academico_test, public;

INSERT INTO academico_test.TMENU (CODIGO, NOMBRE, ICONO, VISIBLE, ESTADO, URL, FK_TMENU, ORDEN, CREATED_BY)
SELECT 'ADMINISTRACION', 'Administración', 'Gear-Icon', 'S', 'A', '/administracion/registro-actividad', NULL, 2, 'migracion'
 WHERE NOT EXISTS (SELECT 1 FROM academico_test.TMENU WHERE CODIGO IN ('ADMINISTRACION', 'ADMINISTRACIÓN'));

-- NOT EXISTS sin mirar ACTIVE: un menú o una concesión desactivados a mano no reviven al re-aplicar.
INSERT INTO academico_test.TMENU (CODIGO, NOMBRE, VISIBLE, ESTADO, URL, FK_TMENU, ORDEN, CREATED_BY)
SELECT 'AREAS_OFICIALES', 'Áreas oficiales', 'S', 'A', '/app/administracion/areas-oficiales', padre.PK_TMENU, 4, 'migracion'
  FROM academico_test.TMENU padre
 WHERE padre.CODIGO IN ('ADMINISTRACION', 'ADMINISTRACIÓN')
   AND padre.FK_TMENU IS NULL
   AND padre.ACTIVE = TRUE
   AND NOT EXISTS (SELECT 1 FROM academico_test.TMENU WHERE CODIGO = 'AREAS_OFICIALES')
 ORDER BY padre.PK_TMENU
 LIMIT 1;

INSERT INTO academico_test.TROL_MENU (FK_TROL, FK_TMENU, ACTIVE, CREATED_BY, CREATED_AT)
SELECT r.PK_TROL, m.PK_TMENU, TRUE, 'migracion', CURRENT_TIMESTAMP
  FROM academico_test.TROL r
  JOIN academico_test.TMENU m ON m.CODIGO = 'AREAS_OFICIALES' AND m.ACTIVE = TRUE
 WHERE r.CODIGO = 'SUPER_ADMINISTRADOR'
   AND r.ACTIVE = TRUE
   AND NOT EXISTS (SELECT 1 FROM academico_test.TROL_MENU tm
                    WHERE tm.FK_TROL = r.PK_TROL AND tm.FK_TMENU = m.PK_TMENU);

-- La gestión del catálogo es exclusiva del Superadministrador (Regla 5).
UPDATE academico_test.TROL_MENU tm
   SET ACTIVE = FALSE, MODIFIED_BY = 'migracion', MODIFIED_AT = CURRENT_TIMESTAMP
  FROM academico_test.TMENU m, academico_test.TROL r
 WHERE m.CODIGO = 'AREAS_OFICIALES'
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
    ('0d2fc71d-47c2-4fb2-9429-2e6a73c09e8d', '/areas-oficiales', 'GET',
     '{"QUERY.BUSCAR": "VARCHAR", "QUERY.NIVEL": "BIGINT", "QUERY.HABILITADA": "BOOLEAN"}',
     'Áreas oficiales no eliminadas, por nombre: [{pkAreaOficial, nombre, habilitada, esDimensionTransversal, especialidad, niveles:[{pkNivel, codigo, nombre}], usos:{planesEstudio, referentes}, enUso}]. ?BUSCAR= filtra por nombre, ?NIVEL= (pk de TNIVEL_ENSENANZA) por nivel educativo y ?HABILITADA=true|false por estado. Errores: 403 (42501) sin VER sobre AREAS_OFICIALES.',
     $q$SELECT academico_test.fn_areaoficial_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.BUSCAR AS VARCHAR),
    CAST(:QUERY.NIVEL AS BIGINT),
    CAST(:QUERY.HABILITADA AS BOOLEAN)) AS resultado;$q$),
    ('1bf02e9d-2a77-43d1-896f-65318fe74542', '/areas-oficiales/:ID', 'GET',
     '{"PARAM.ID": "BIGINT"}',
     'Un área oficial, con la misma forma que el listado. Errores: 404 (P0002); 403 (42501) sin VER sobre AREAS_OFICIALES.',
     $q$SELECT academico_test.fn_areaoficial_detalle(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)) AS resultado;$q$),
    ('c5e53235-da0d-4a2b-ada3-030da7b8b225', '/areas-oficiales', 'POST',
     '{"BODY.NOMBRE": "VARCHAR", "BODY.NIVELES": "BIGINT[]"}',
     'Crea un área oficial activa. BODY.NOMBRE (3-100, único en el catálogo) y BODY.NIVELES (pk de TNIVEL_ENSENANZA, al menos uno). Devuelve el área. Errores: 403 (42501) sin CREAR sobre AREAS_OFICIALES; 400 (22023) nombre o niveles inválidos; 409 (23505) nombre repetido.',
     $q$SELECT academico_test.fn_areaoficial_crear(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.NOMBRE AS VARCHAR),
    CAST(:BODY.NIVELES AS BIGINT[])) AS resultado;$q$),
    ('5a9b0e33-25e3-40e5-94eb-83f79c2a7c21', '/areas-oficiales/:ID', 'PUT',
     '{"PARAM.ID": "BIGINT", "BODY.NOMBRE": "VARCHAR", "BODY.NIVELES": "BIGINT[]"}',
     'Modifica el nombre y reemplaza los niveles del área :ID; las asociaciones existentes no cambian. Devuelve el área. Errores: 404 (P0002); 403 (42501) sin EDITAR sobre AREAS_OFICIALES; 400 (22023) datos inválidos; 409 (23505) nombre repetido.',
     $q$SELECT academico_test.fn_areaoficial_actualizar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.NOMBRE AS VARCHAR),
    CAST(:BODY.NIVELES AS BIGINT[])) AS resultado;$q$),
    ('81be28f6-3356-43e8-912c-4889bc25e76e', '/areas-oficiales/:ID/estado', 'PUT',
     '{"PARAM.ID": "BIGINT", "BODY.HABILITADA": "BOOLEAN"}',
     'Activa (BODY.HABILITADA=true) o inactiva (false) el área :ID, también si está en uso: inactiva deja de ofrecerse para asociaciones nuevas y las existentes la conservan. Devuelve el área. Errores: 404 (P0002); 403 (42501) sin EDITAR sobre AREAS_OFICIALES; 400 (22023) sin HABILITADA.',
     $q$SELECT academico_test.fn_areaoficial_estado(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.HABILITADA AS BOOLEAN)) AS resultado;$q$),
    ('07a74de7-19b4-4573-a7d7-0f7f370a83da', '/areas-oficiales/:ID/eliminar', 'PUT',
     '{"PARAM.ID": "BIGINT"}',
     'Elimina (baja lógica) el área :ID con sus asignaturas de catálogo; solo si ningún Plan de Estudio ni Referente la usa. Devuelve el área como estaba. Errores: 404 (P0002); 403 (42501) sin ELIMINAR sobre AREAS_OFICIALES; 409 (23503) en uso (en ese caso se inactiva).',
     $q$SELECT academico_test.fn_areaoficial_eliminar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)) AS resultado;$q$),
    ('d0d60299-6cd3-4240-8256-df8080971966', '/catalogos/areas-oficiales', 'GET',
     '{"QUERY.NIVEL": "BIGINT"}',
     'Catálogo de los selectores (Referente, Plan de Estudio): áreas oficiales activas [{pkAreaOficial, nombre, esDimensionTransversal}], de un nivel educativo si llega ?NIVEL= (pk de TNIVEL_ENSENANZA). Solo lectura.',
     $q$SELECT academico_test.fn_areaoficial_opciones(
    CAST(:QUERY.NIVEL AS BIGINT)) AS resultado;$q$)
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
   AND q.path_template LIKE '/areas-oficiales%'
   AND r.name NOT IN ('CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN');

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id AND m.serviceid = 'eval-col'
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE q.path_template LIKE '/areas-oficiales%'
ON CONFLICT DO NOTHING;

-- Los selectores: los mismos roles que ya leen el catálogo por /areas/general.
INSERT INTO public.role_query (role_id, query_id)
SELECT rq.role_id, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id AND m.serviceid = 'eval-col'
  JOIN public.query general ON general.microservice_id = q.microservice_id
                           AND general.path_template = '/areas/general' AND general.http_method = 'GET'
  JOIN public.role_query rq ON rq.query_id = general.id_query
 WHERE q.path_template = '/catalogos/areas-oficiales' AND q.http_method = 'GET'
ON CONFLICT DO NOTHING;
