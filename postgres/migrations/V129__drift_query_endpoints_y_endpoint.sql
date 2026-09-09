-- ===========================================================================
-- V129 - drift del catalogo de query-service: los 12 endpoints de eval-col
--        que NINGUNA rama de origin registra.
--
-- QUE ES ESTO
--   Complemento de V47/V75..V127 (ver docs/query-endpoints-sin-migracion.md).
--   Aquellas cubren los endpoints cuya funcion vive en esta rama; aqui quedan
--   los que no encajaban en ningun grupo:
--
--     * 7 endpoints con SQL inline (no invocan ninguna funcion), asi que no
--       hay migracion de funcion junto a la cual colocarlos.
--     * 5 endpoints cuya funcion SI existe, pero en la rama
--       feature/CU-86e2zfd9r-Cobertura-Matricula-... , que define la funcion y
--       nunca registra el endpoint. Se documentan aqui porque una fila de
--       public.query es texto inerte: no requiere que la funcion exista al
--       migrar, solo al invocarla.
--
-- NUMERACION
--   Hueco libre V129, verificado contra TODAS las ramas de origin. Va despues
--   de V128 (que versiona fn_escala_nivel_bulk_soft_delete) y despues de las
--   migraciones que actualizan alguna de estas filas (V198 para
--   PUT /roles/:ROLEID/menus). Flyway corre con -outOfOrder=true.
--
-- CONTENIDO
--   Volcado literal del catalogo vivo en el servidor de test, uuid incluido
--   (V198 localiza su fila por uuid). Mismo criterio que V75..V127.
--
-- CAVEAT DE RECARGA
--   Fila nueva en public.query = 404 por el gateway hasta reiniciar
--   query-service-eval-col.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. GET /select
--    SQL inline sobre academico_test.tlista_valor: no invoca ninguna
--    funcion, por eso no hay migracion de funcion a la que anclarlo.
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-msdrxpov-g91nz4bp',
    'SELECT DISTINCT CATEGORIA
FROM academico_test.tlista_valor',
    'postgres', true, false,
    m.id_microservice,
    '/select', 'SELECT', 'GET',
    '{}'::jsonb,
    NULL,
    NULL,
    NULL, NULL,
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-ACUDIENTE', 'CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-COORDINADOR', 'CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'CEVAL-DIRECTOR_GRUPO', 'CEVAL-DOCENTE', 'CEVAL-ESTUDIANTE', 'CEVAL-JEFE_AREA', 'CEVAL-JEFE_AREA_CALIDAD', 'CEVAL-JEFE_AREA_COBERTURA', 'CEVAL-JEFE_AREA_PLANEACION', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-PSICO_ORIENTADOR', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN', 'SSO-USER')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/select'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. GET /select/:CATEGORIA
--    SQL inline sobre academico_test.tlista_valor.
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-msdo8yj3-b8peh215',
    'select PK_LISTA_VALOR, NOMBRE, VALOR, ACCION
from academico_test.tlista_valor
where academico_test.tlista_valor.categoria = UPPER(CAST(:PARAM.CATEGORIA AS VARCHAR))
order by VALOR asc',
    'postgres', true, false,
    m.id_microservice,
    '/select/:CATEGORIA', 'SELECT', 'GET',
    '{"PARAM.CATEGORIA": "VARCHAR"}'::jsonb,
    NULL,
    NULL,
    NULL, NULL,
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-ACUDIENTE', 'CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-COORDINADOR', 'CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'CEVAL-DIRECTOR_GRUPO', 'CEVAL-DOCENTE', 'CEVAL-ESTUDIANTE', 'CEVAL-JEFE_AREA', 'CEVAL-JEFE_AREA_CALIDAD', 'CEVAL-JEFE_AREA_COBERTURA', 'CEVAL-JEFE_AREA_PLANEACION', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-PSICO_ORIENTADOR', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN', 'SSO-USER')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/select/:CATEGORIA'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3. GET /funcionario
--    SQL inline. Convive con el listado real de funcionarios
--    (POST /establecimientos/funcionarios/query, V93): este es un
--    listado plano con la ruta de descarga del archivo.
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'eval-col-funcionario-listar-001',
    'SELECT f.pk_tfuncionario AS id, f.telefonos, f.created_by, f.created_at, a.pk_tarchivo AS archivo_id, a.nombre AS archivo_nombre, a.peso AS archivo_peso, a.urls3 AS archivo_url, CASE WHEN a.pk_tarchivo IS NULL THEN NULL ELSE ''/api/files/download/'' || a.pk_tarchivo END AS archivo_descarga_url, ''/api/eval-col/funcionario/'' || f.pk_tfuncionario AS url FROM academico_test.tfuncionario f LEFT JOIN academico_test.tarchivo a ON a.pk_tarchivo = f.fk_tarchivo WHERE f.active = TRUE ORDER BY f.pk_tfuncionario DESC',
    'postgres', false, false,
    m.id_microservice,
    '/funcionario', 'SELECT', 'GET',
    '{}'::jsonb,
    NULL,
    'Listar funcionarios activos con su archivo y la ruta de descarga (via api-gateway)',
    'funcionario-listar', 'DEFAULT',
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

-- Sin filas en role_query en el catalogo vivo: el endpoint no esta expuesto
-- a ningun rol. Se reproduce tal cual (no se inventa un permiso).

-- ---------------------------------------------------------------------------
-- 4. POST /funcionario/crear
--    SQL inline, execution_mode=DML. Es un INSERT directo a
--    TFUNCIONARIO, NO pasa por fn_fun_crear (V51) ni por su gate.
--    Se documenta tal como esta desplegado; revisar si debe
--    migrarse a la funcion es una decision aparte.
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'eval-col-funcionario-crear-001',
    'INSERT INTO academico_test.tfuncionario (fk_tmunicipio_expedicion, telefonos, fk_tarchivo, created_by) VALUES (CAST(:BODY.MUNICIPIO AS BIGINT), CAST(:BODY.TELEFONOS AS VARCHAR), CAST(:BODY.FIRMA AS BIGINT), :CONTEXT.EMAIL) RETURNING pk_tfuncionario AS id',
    'postgres', false, false,
    m.id_microservice,
    '/funcionario/crear', 'DML', 'POST',
    '{}'::jsonb,
    NULL,
    'Catalogo eval-col: crear funcionario con su firma (INSERT tfuncionario, devuelve el id nuevo)',
    'funcionario-crear', 'DEFAULT',
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

-- Sin filas en role_query en el catalogo vivo: el endpoint no esta expuesto
-- a ningun rol. Se reproduce tal cual (no se inventa un permiso).

-- ---------------------------------------------------------------------------
-- 5. GET /funcionario/:ID/archivo-firmado
--    SQL inline.
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'eval-col-funcionario-archivo-firmado-001',
    'SELECT f.pk_tfuncionario AS id, f.telefonos, a.pk_tarchivo AS archivo_id, a.nombre AS archivo_nombre, a.urls3 AS archivo_url, ''/api/files/download/'' || a.pk_tarchivo AS archivo_firmado_url FROM academico_test.tfuncionario f JOIN academico_test.tarchivo a ON a.pk_tarchivo = f.fk_tarchivo WHERE f.active = TRUE AND f.pk_tfuncionario = CAST(:PARAM.ID AS BIGINT)',
    'postgres', false, false,
    m.id_microservice,
    '/funcionario/:ID/archivo-firmado', 'SELECT', 'GET',
    '{}'::jsonb,
    NULL,
    'Catalogo eval-col: funcionario por id con la ruta de descarga de su archivo (via api-gateway)',
    'funcionario-archivo-firmado', 'DEFAULT',
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

-- Sin filas en role_query en el catalogo vivo: el endpoint no esta expuesto
-- a ningun rol. Se reproduce tal cual (no se inventa un permiso).

-- ---------------------------------------------------------------------------
-- 6. POST /tmp-icono-simbolo
--    SQL inline de un solo campo: el binding FILE:graficaSimbolo
--    hace que query-service suba el multipart y devuelva el
--    pk_tarchivo. El prefijo tmp- del path es del despliegue.
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    '2c19e53b-01fa-4283-95c9-1e8738d00bb6',
    'SELECT :BODY.ICONO::bigint AS pk_tarchivo',
    'postgres', false, false,
    m.id_microservice,
    '/tmp-icono-simbolo', 'SELECT', 'POST',
    '{"BODY.ICONO": "FILE:graficaSimbolo"}'::jsonb,
    NULL,
    'Subir icono grafica (caritas/simbolos) - solo super administradores',
    NULL, NULL,
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/tmp-icono-simbolo'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 7. PUT /roles/:ROLEID/menus
--    SQL inline. V198 solo hace UPDATE de esta fila asumiendola
--    preexistente, asi que sobre base limpia no existia.
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'eval-col-roles-menus-update-001',
    'SELECT CASE
                WHEN count(*) = 0 THEN ''success''
                WHEN bool_and(status IN (''inserted'', ''reactivated'')) THEN ''success''
                ELSE ''error''
            END AS status,
            ''Menus del rol actualizados'' AS message
       FROM academico_test.fn_associate_menus_to_rol(
           :CONTEXT.USER_ID::BIGINT,
           CAST(:PARAM.ROLEID AS BIGINT),
           CAST(:BODY_RAW.MENUS AS JSONB),
           :CONTEXT.EMAIL,
           TRUE
       );',
    'postgres', false, false,
    m.id_microservice,
    '/roles/:ROLEID/menus', 'SELECT', 'PUT',
    '{"BODY.MENUS": "JSONB", "PARAM.ROLEID": "BIGINT", "BODY_RAW.MENUS": "JSONB"}'::jsonb,
    NULL,
    'roles-permisos: reemplazo COMPLETO del menu de un rol, con orden y validacion de jerarquia server-side.',
    'roles-menus-update', NULL,
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/roles/:ROLEID/menus'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 8. POST /cobertura-academica/matricula/corregir
--    fn_matricula_corregir_lote se define en V178 de la rama
--    feature/CU-86e2zfd9r-Cobertura-Matricula-Retiro-reingreso-y-reactivacion,
--    que define la funcion pero NUNCA registra el endpoint. La fila es texto
--    inerte hasta que esa rama se integre.
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-mtb2d9k4-cobmatcor1',
    'SELECT academico_test.fn_matricula_corregir_lote(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.IDS AS BIGINT[]),
    CAST(:BODY.GRUPO_DESTINO AS BIGINT)
) AS resultado;',
    'postgres', false, false,
    m.id_microservice,
    '/cobertura-academica/matricula/corregir', 'SELECT', 'POST',
    '{"BODY.IDS": "BIGINT[]", "BODY.GRUPO_DESTINO": "BIGINT"}'::jsonb,
    NULL,
    'V179 -- correccion en lote del grupo de una matricula mal capturada. Mueve la matricula EXISTENTE al grupo destino (cualquier grupo, grado o sede que promover o reubicar aceptarian): NO crea matricula nueva, NO cambia el estado y NO pide motivo ni soporte. Origen: solo Cursando. Todo o nada. Solo rector/secretaria/jefe de sistema',
    NULL, NULL,
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-RECTOR')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/cobertura-academica/matricula/corregir'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 9. POST /cobertura-academica/matricula/promover
--    fn_matricula_promover_lote: V175 de la misma rama, mismo caso.
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-mtb2d9k4-cobmatpro1',
    'SELECT academico_test.fn_matricula_promover_lote(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    ARRAY(SELECT TRIM(t)::BIGINT
             FROM UNNEST(string_to_array(TRIM(BOTH ''[]{} '' FROM :BODY.IDS), '','')) AS t
            WHERE TRIM(t) <> ''''),
    CAST(:BODY.GRUPO_DESTINO AS BIGINT),
    CAST(:BODY.MOTIVO AS VARCHAR),
    CAST(:BODY.SOPORTE AS BIGINT)
) AS resultado;',
    'postgres', false, false,
    m.id_microservice,
    '/cobertura-academica/matricula/promover', 'SELECT', 'POST',
    '{"BODY.IDS": "TEXT", "BODY.MOTIVO": "TEXT", "BODY.SOPORTE": "FILE:matricula", "BODY.GRUPO_DESTINO": "BIGINT"}'::jsonb,
    NULL,
    'V179 -- promocion en lote hacia un grupo de grado superior de la MISMA sede. Crea una matricula nueva en Cursando por cada una (copiando socioeconomico y documentos, encadenada por FK_TMATRICULA_ANTERIOR) y deja la anterior en Promovido. Motivo y soporte OBLIGATORIOS; quedan en TMATRICULA_PROMOCION. Origen: solo Cursando. Todo o nada. Solo rector/secretaria/jefe de sistema',
    NULL, NULL,
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-RECTOR')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/cobertura-academica/matricula/promover'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 10. POST /cobertura-academica/matricula/reubicar
--    fn_matricula_reubicar_lote: V175 de la misma rama, mismo caso.
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-mtb2d9k4-cobmatreu1',
    'SELECT academico_test.fn_matricula_reubicar_lote(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    ARRAY(SELECT TRIM(t)::BIGINT
             FROM UNNEST(string_to_array(TRIM(BOTH ''[]{} '' FROM :BODY.IDS), '','')) AS t
            WHERE TRIM(t) <> ''''),
    CAST(:BODY.GRUPO_DESTINO AS BIGINT),
    CAST(:BODY.MOTIVO AS VARCHAR),
    CAST(:BODY.SOPORTE AS BIGINT)
) AS resultado;',
    'postgres', false, false,
    m.id_microservice,
    '/cobertura-academica/matricula/reubicar', 'SELECT', 'POST',
    '{"BODY.IDS": "TEXT", "BODY.MOTIVO": "TEXT", "BODY.SOPORTE": "FILE:matricula", "BODY.GRUPO_DESTINO": "BIGINT"}'::jsonb,
    NULL,
    'V179 -- reubicacion en lote hacia un grupo de OTRA sede, o de un grado INFERIOR de la misma sede. Crea una matricula nueva en Cursando por cada una y deja la anterior en Reubicado. Motivo y soporte OBLIGATORIOS; quedan en TTRASLADO_ESTUDIANTE. Origen: solo Cursando. Todo o nada. Se exige permiso sobre el establecimiento de origen y el de destino',
    NULL, NULL,
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-RECTOR')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/cobertura-academica/matricula/reubicar'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 11. POST /planeador/actividades/exportar
--    fn_actividad_exportar: V272 de la misma rama, mismo caso.
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-planeador-actividades-exportar-001',
    'SELECT academico_test.fn_actividad_exportar(
    p_pk_usuario_solicitante => public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    p_pk_tactividades        => CAST(:BODY.IDS AS BIGINT[]),
    p_pk_tunidad             => CAST(:BODY.PK_TUNIDAD AS BIGINT),
    p_fk_tasignatura         => CAST(:BODY.FK_TASIGNATURA AS BIGINT),
    p_fk_tgrupo              => CAST(:BODY.FK_TGRUPO AS BIGINT)
) AS actividades',
    'postgres', false, false,
    m.id_microservice,
    '/planeador/actividades/exportar', 'SELECT', 'POST',
    '{"BODY.IDS": "BIGINT[]", "BODY.FK_TGRUPO": "BIGINT", "BODY.PK_TUNIDAD": "BIGINT", "BODY.FK_TASIGNATURA": "BIGINT"}'::jsonb,
    NULL,
    'Exporta actividades del planeador al formato JSON de intercambio. Filtros combinables por lista de IDS, unidad, asignatura o grupo; hay que enviar al menos uno. Cada actividad incluye su unidad_meta, el instrumento de evaluacion segun corresponda (rubrica, cotejo, escala u otro) y un bloque _identificadores con las PKs para poder reimportarla sin resolver nombres.',
    NULL, NULL,
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-DOCENTE', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/planeador/actividades/exportar'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 12. POST /planeador/actividades/importar
--    fn_actividad_importar: V274 de la misma rama, mismo caso.
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-planeador-actividades-importar-001',
    'SELECT academico_test.fn_actividad_importar(
    p_pk_usuario_solicitante    => public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    p_actividades               => CAST(:BODY.ACTIVIDADES AS JSONB),
    p_fk_tasignatura            => CAST(:BODY.FK_TASIGNATURA AS BIGINT),
    p_fk_tgrupo                 => CAST(:BODY.FK_TGRUPO AS BIGINT),
    p_fk_tgrado                 => CAST(:BODY.FK_TGRADO AS BIGINT),
    p_fk_tfuncionario           => CAST(:BODY.FK_TFUNCIONARIO AS BIGINT),
    p_fk_tlv_calculo_definitiva => CAST(:BODY.FK_TLV_CALCULO_DEFINITIVA AS BIGINT),
    p_fk_referente_curricular   => CAST(:BODY.FK_REFERENTE_CURRICULAR AS BIGINT),
    p_solo_validar              => COALESCE(CAST(:BODY.SOLO_VALIDAR AS BOOLEAN), TRUE)
) AS resultado',
    'postgres', false, false,
    m.id_microservice,
    '/planeador/actividades/importar', 'SELECT', 'POST',
    '{"BODY.FK_TGRADO": "BIGINT", "BODY.FK_TGRUPO": "BIGINT", "BODY.ACTIVIDADES": "JSONB", "BODY.SOLO_VALIDAR": "BOOLEAN", "BODY.FK_TASIGNATURA": "BIGINT", "BODY.FK_TFUNCIONARIO": "BIGINT", "BODY.FK_REFERENTE_CURRICULAR": "BIGINT", "BODY.FK_TLV_CALCULO_DEFINITIVA": "BIGINT"}'::jsonb,
    NULL,
    'Importa actividades del planeador desde el formato JSON de intercambio, el mismo que produce /planeador/actividades/exportar. Con SOLO_VALIDAR = true (por defecto) no escribe nada: devuelve el informe fila por fila con las etiquetas que no casan con los catalogos y las reglas del dominio que el archivo incumple. Con SOLO_VALIDAR = false aplica, y es todo o nada: si alguna fila tiene errores no se escribe ninguna. El destino sale de _identificadores de cada actividad si viene y, si no, de los FK_ del cuerpo; nunca se resuelve por nombre.',
    NULL, NULL,
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-DOCENTE', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/planeador/actividades/importar'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;


-- ===========================================================================
-- public.endpoint: las 2 filas que tampoco estaban en ninguna rama.
--
--   public.endpoint es el catalogo que gatea sso-admin/auth-center (V15,
--   SsoAdminAccessManager), distinto de public.query. Auditado completo
--   contra el servidor: 122 filas, 120 cubiertas por migraciones. Estas dos
--   son las unicas que faltaban.
--
--   Los roles se resuelven por nombre y con ON CONFLICT, asi que en un
--   entorno donde falte alguno simplemente no se inserta ese bind.
-- ===========================================================================

INSERT INTO endpoint (method, path, description, numberparams) VALUES
    ('GET',   '/',          'Raiz del gateway / health publico', 0),
    ('PATCH', '/files/**',  'Actualizacion de archivos via file-service (comodin)', 0)
ON CONFLICT DO NOTHING;

-- GET / -> solo el rol administrador del SSO.
INSERT INTO role_endpoint (endpoint_id, role_id)
SELECT e.id_endpoint, r.id_role
  FROM endpoint e
  JOIN role r ON r.name IN ('SSO-ADMIN', 'ADMIN')
 WHERE e.method = 'GET' AND e.path = '/'
ON CONFLICT (endpoint_id, role_id) DO NOTHING;

-- PATCH /files/** -> mismo conjunto de roles que tiene desplegado el servidor.
INSERT INTO role_endpoint (endpoint_id, role_id)
SELECT e.id_endpoint, r.id_role
  FROM endpoint e
  JOIN role r ON r.name IN ('CEVAL-AUXILIAR_ADMINISTRATIVO',
                            'CEVAL-DIRECTOR_ENTE_TERRITORIAL',
                            'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL',
                            'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO',
                            'CEVAL-RECTOR',
                            'CEVAL-SUPER_ADMINISTRADOR',
                            'SSO-ADMIN', 'ADMIN')
 WHERE e.method = 'PATCH' AND e.path = '/files/**'
ON CONFLICT (endpoint_id, role_id) DO NOTHING;
