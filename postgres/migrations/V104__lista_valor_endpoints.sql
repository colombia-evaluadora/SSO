-- V104 - CRUD de listas de valores, capa 4 de 4: menú y endpoints.
-- Menú LISTAS_VALOR bajo ADMINISTRACION solo para el Superadministrador (y
-- SSO-ADMIN en role_query); a los demás roles se les retira lo concedido antes.
-- ADMINISTRACION se crea si falta: en una base limpia esta migración corre antes
-- que V113, y sin CACHEABLE/CACHE_TTL_SECONDS porque nacen en V110 (sus
-- defaults: no cachear).
-- Depende de: V103 (wrappers), V22 (TMENU, TROL_MENU), V99 (SOLO_LECTURA).

SET search_path TO academico_test, public;

INSERT INTO academico_test.TMENU (CODIGO, NOMBRE, ICONO, VISIBLE, ESTADO, URL, FK_TMENU, ORDEN, CREATED_BY)
SELECT 'ADMINISTRACION', 'Administración', 'Gear-Icon', 'S', 'A', '/administracion/registro-actividad', NULL, 2, 'migracion'
 WHERE NOT EXISTS (SELECT 1 FROM academico_test.TMENU WHERE CODIGO IN ('ADMINISTRACION', 'ADMINISTRACIÓN'));

-- NOT EXISTS sin mirar ACTIVE: un menú o una concesión desactivados a mano no reviven al re-aplicar.
INSERT INTO academico_test.TMENU (CODIGO, NOMBRE, VISIBLE, ESTADO, URL, FK_TMENU, ORDEN, CREATED_BY)
SELECT 'LISTAS_VALOR', 'Listas de valores', 'S', 'A', '/app/administracion/listas-valor', padre.PK_TMENU, 3, 'migracion'
  FROM academico_test.TMENU padre
 WHERE padre.CODIGO IN ('ADMINISTRACION', 'ADMINISTRACIÓN')
   AND padre.FK_TMENU IS NULL
   AND padre.ACTIVE = TRUE
   AND NOT EXISTS (SELECT 1 FROM academico_test.TMENU WHERE CODIGO = 'LISTAS_VALOR')
 ORDER BY padre.PK_TMENU
 LIMIT 1;

INSERT INTO academico_test.TROL_MENU (FK_TROL, FK_TMENU, ACTIVE, CREATED_BY, CREATED_AT)
SELECT r.PK_TROL, m.PK_TMENU, TRUE, 'migracion', CURRENT_TIMESTAMP
  FROM academico_test.TROL r
  JOIN academico_test.TMENU m ON m.CODIGO = 'LISTAS_VALOR' AND m.ACTIVE = TRUE
 WHERE r.CODIGO = 'SUPER_ADMINISTRADOR'
   AND r.ACTIVE = TRUE
   AND NOT EXISTS (SELECT 1 FROM academico_test.TROL_MENU tm
                    WHERE tm.FK_TROL = r.PK_TROL AND tm.FK_TMENU = m.PK_TMENU);

-- La gestión de la Lista de Valores es exclusiva del Superadministrador.
UPDATE academico_test.TROL_MENU tm
   SET ACTIVE = FALSE, MODIFIED_BY = 'migracion', MODIFIED_AT = CURRENT_TIMESTAMP
  FROM academico_test.TMENU m, academico_test.TROL r
 WHERE m.CODIGO = 'LISTAS_VALOR'
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
    ('37c585b7-9c4a-428e-b3f8-6282ca0bcffc', '/listas-valor/categorias', 'GET',
     '{"QUERY.BUSCAR": "VARCHAR"}',
     'Listas activas (habilitadas o no), por código: [{categoria, descripcion, categoriaPadre, esOrdinal, habilitada, totalValores, esSistema, predeterminado (pkListaValor o null), categoriasPadre}]. ?BUSCAR= filtra por código (con _ o espacios) o descripción. esSistema = tiene valores usados por el sistema. Errores: 403 (42501) sin VER sobre LISTAS_VALOR.',
     $q$SELECT academico_test.fn_listavalor_categorias_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.BUSCAR AS VARCHAR)) AS resultado;$q$),
    ('1fd9284f-cc85-4e75-9eea-708119006970', '/listas-valor', 'GET',
     '{"QUERY.CATEGORIA": "VARCHAR", "QUERY.PADRE": "BIGINT", "QUERY.HABILITADO": "BOOLEAN"}',
     'Valores no eliminados de una lista (?CATEGORIA=) y/o hijos de un valor (?PADRE=<pkListaValor>), en su orden; ?HABILITADO=true|false filtra por estado (sin él, todos). [{pkListaValor, categoria, nombre, valor, etiqueta, accion, orden, predeterminado, habilitado, esSistema, active, padre}]. Pantalla de administración: los selectores usan GET /select/:CATEGORIA. Errores: 400 (22023) sin CATEGORIA ni PADRE; 403 (42501) sin VER sobre LISTAS_VALOR.',
     $q$SELECT academico_test.fn_listavalor_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.CATEGORIA AS VARCHAR),
    CAST(:QUERY.PADRE AS BIGINT),
    CAST(:QUERY.HABILITADO AS BOOLEAN)) AS resultado;$q$),
    ('61659ccb-1d6c-421c-80b8-59a9443326ff', '/listas-valor/categorias', 'POST',
     '{"BODY.CATEGORIA": "VARCHAR", "BODY.DESCRIPCION": "VARCHAR", "BODY.PADRE": "VARCHAR", "BODY.ORDINAL": "BOOLEAN", "BODY.VALORES": "JSONB"}',
     'Crea una lista. BODY.CATEGORIA: código inmutable, mayúsculas sin tildes, números y _ (≤30). BODY.DESCRIPCION (10-300), BODY.PADRE (código de la lista padre) y BODY.ORDINAL opcionales. BODY.VALORES opcional: [{nombre, valor, etiqueta?, accion?, padre?, predeterminado?}] en el orden de presentación. Devuelve la lista con valores:[...]. Todo o nada. Errores: 403 (42501) sin CREAR sobre LISTAS_VALOR; 400 (22023) formato, lista padre, valores repetidos o más de un predeterminado; 409 (23505) lista o código ya existe.',
     $q$SELECT academico_test.fn_listavalor_categoria_crear(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.CATEGORIA AS VARCHAR),
    CAST(:BODY.VALORES AS JSONB),
    CAST(:BODY.DESCRIPCION AS VARCHAR),
    CAST(:BODY.PADRE AS VARCHAR),
    CAST(:BODY.ORDINAL AS BOOLEAN)) AS resultado;$q$),
    ('7c79d8a6-e2f2-4642-beeb-14aa32487354', '/listas-valor/categorias/:CATEGORIA', 'PUT',
     '{"PARAM.CATEGORIA": "VARCHAR", "BODY.DESCRIPCION": "VARCHAR", "BODY.PADRE": "VARCHAR", "BODY.ORDINAL": "BOOLEAN"}',
     'Modifica la lista :CATEGORIA: BODY.DESCRIPCION y BODY.PADRE (código de la lista padre) se reemplazan, omitidos quedan en NULL; BODY.ORDINAL omitido no cambia. El código de la lista no se edita. Devuelve la lista. Errores: 404 (P0002); 403 (42501) sin EDITAR sobre LISTAS_VALOR; 400 (22023) descripción, lista padre inexistente, la misma lista, en ciclo o distinta de la de los valores padre que ya tienen sus valores.',
     $q$SELECT academico_test.fn_listavalor_categoria_actualizar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.CATEGORIA AS VARCHAR),
    CAST(:BODY.DESCRIPCION AS VARCHAR),
    CAST(:BODY.PADRE AS VARCHAR),
    CAST(:BODY.ORDINAL AS BOOLEAN)) AS resultado;$q$),
    ('0fa6076a-6cf4-407f-9dd8-66ce38d29a5e', '/listas-valor/categorias/:CATEGORIA/estado', 'PUT',
     '{"PARAM.CATEGORIA": "VARCHAR", "BODY.HABILITADA": "BOOLEAN"}',
     'Activa (BODY.HABILITADA=true) o inactiva (false) la lista :CATEGORIA: inactiva, GET /select/:CATEGORIA no ofrece ninguno de sus valores; los registros que ya los tienen no cambian. Devuelve la lista. Errores: 404 (P0002); 403 (42501) sin EDITAR sobre LISTAS_VALOR; 409 (23503) al inactivar una lista con valores usados por el sistema o que es lista padre de otra activa.',
     $q$SELECT academico_test.fn_listavalor_categoria_estado(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.CATEGORIA AS VARCHAR),
    CAST(:BODY.HABILITADA AS BOOLEAN)) AS resultado;$q$),
    ('cc6d2f7d-a35a-4e92-acc7-d1a75dd7de7b', '/listas-valor/categorias/:CATEGORIA/orden', 'PUT',
     '{"PARAM.CATEGORIA": "VARCHAR", "BODY.ORDEN": "JSONB"}',
     'Reordena los valores de :CATEGORIA (arrastrar y soltar). BODY.ORDEN: arreglo con todos los pkListaValor no eliminados de la lista, en el orden nuevo (posición 1..n). Devuelve los valores en su orden. Errores: 404 (P0002); 403 (42501) sin EDITAR sobre LISTAS_VALOR; 400 (22023) si falta, sobra o se repite algún pk.',
     $q$SELECT academico_test.fn_listavalor_categoria_ordenar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.CATEGORIA AS VARCHAR),
    CAST(:BODY.ORDEN AS JSONB)) AS resultado;$q$),
    ('12a5269b-b00c-4a0e-9185-b92c9754350f', '/listas-valor/categorias/:CATEGORIA/eliminar', 'PUT',
     '{"PARAM.CATEGORIA": "VARCHAR"}',
     'Elimina (baja lógica) la lista :CATEGORIA y sus valores; solo si nunca se usó. Devuelve {categoria, valoresEliminados}. Errores: 404 (P0002); 403 (42501) sin ELIMINAR sobre LISTAS_VALOR; 409 (23503) si tiene valores usados por el sistema, es lista padre de otra activa o algún valor está en uso (en ese caso se inactiva).',
     $q$SELECT academico_test.fn_listavalor_categoria_eliminar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.CATEGORIA AS VARCHAR)) AS resultado;$q$),
    ('77ea5618-9ddb-4da8-93ae-55410ce015e8', '/listas-valor', 'POST',
     '{"BODY.CATEGORIA": "VARCHAR", "BODY.NOMBRE": "VARCHAR", "BODY.VALOR": "VARCHAR", "BODY.ETIQUETA": "VARCHAR", "BODY.ACCION": "VARCHAR", "BODY.PADRE": "BIGINT", "BODY.ORDEN": "INTEGER", "BODY.PREDETERMINADO": "BOOLEAN"}',
     'Agrega un valor a una lista. BODY.NOMBRE (1-100, único en la lista) y BODY.VALOR (código inmutable: 2-20 mayúsculas, números o _, único) obligatorios; BODY.ETIQUETA (≤10), BODY.ACCION (≤150), BODY.ORDEN (≥1, por defecto al final) y BODY.PREDETERMINADO (desmarca el anterior) opcionales; BODY.PADRE (pkListaValor) obligatorio si la lista tiene lista padre y de esa lista. Errores: 404 (P0002); 403 (42501) sin CREAR; 400 (22023) datos o padre inválidos; 409 (23505) código o nombre repetido.',
     $q$SELECT academico_test.fn_listavalor_crear(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.CATEGORIA AS VARCHAR),
    CAST(:BODY.NOMBRE AS VARCHAR),
    CAST(:BODY.VALOR AS VARCHAR),
    CAST(:BODY.ACCION AS VARCHAR),
    CAST(:BODY.PADRE AS BIGINT),
    CAST(:BODY.ETIQUETA AS VARCHAR),
    CAST(:BODY.ORDEN AS INTEGER),
    CAST(:BODY.PREDETERMINADO AS BOOLEAN)) AS resultado;$q$),
    ('d18fdc62-5963-4fcb-b823-46e9001b75f7', '/listas-valor/:ID', 'PUT',
     '{"PARAM.ID": "BIGINT", "BODY.NOMBRE": "VARCHAR", "BODY.ETIQUETA": "VARCHAR", "BODY.ACCION": "VARCHAR", "BODY.PADRE": "BIGINT", "BODY.ORDEN": "INTEGER"}',
     'Modifica el valor :ID: NOMBRE, ETIQUETA y PADRE se reemplazan (omitidos quedan en NULL); ACCION omitida no cambia y "" la quita; ORDEN lo mueve a esa posición (omitido no se mueve). CATEGORIA y VALOR (código) no se editan. En un valor del sistema solo el super administrador cambia NOMBRE o ACCION. Errores: 404 (P0002); 400 (22023) eliminado, datos inválidos, padre inexistente, inactivo, en ciclo o de otra lista; 403 (42501) sin EDITAR; 409 (23505) nombre repetido.',
     $q$SELECT academico_test.fn_listavalor_actualizar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.NOMBRE AS VARCHAR),
    CAST(:BODY.ACCION AS VARCHAR),
    CAST(:BODY.PADRE AS BIGINT),
    CAST(:BODY.ETIQUETA AS VARCHAR),
    CAST(:BODY.ORDEN AS INTEGER)) AS resultado;$q$),
    ('3495c555-9d18-4ee4-85a1-7189f98b0314', '/listas-valor/:ID/estado', 'PUT',
     '{"PARAM.ID": "BIGINT", "BODY.HABILITADO": "BOOLEAN"}',
     'Activa (BODY.HABILITADO=true) o inactiva (false) el valor :ID: inactivo, no aparece en GET /select/:CATEGORIA pero sigue en los registros que ya lo tienen; al inactivarlo deja de ser predeterminado. Devuelve el valor. Errores: 404 (P0002); 400 (22023) eliminado, o activar con el valor padre inactivo; 403 (42501) sin EDITAR; 409 (23503) inactivar un valor usado por el sistema o con valores hijos activos.',
     $q$SELECT academico_test.fn_listavalor_estado(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.HABILITADO AS BOOLEAN)) AS resultado;$q$),
    ('4d999c6c-e495-4741-8a2b-8b63877cdb4e', '/listas-valor/:ID/predeterminado', 'PUT',
     '{"PARAM.ID": "BIGINT", "BODY.PREDETERMINADO": "BOOLEAN"}',
     'Marca el valor :ID como el único predeterminado de su lista y desmarca el anterior; BODY.PREDETERMINADO=false lo desmarca (omitido = true). Devuelve el valor. Errores: 404 (P0002); 400 (22023) eliminado o inactivo; 403 (42501) sin EDITAR sobre LISTAS_VALOR.',
     $q$SELECT academico_test.fn_listavalor_predeterminado(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.PREDETERMINADO AS BOOLEAN)) AS resultado;$q$),
    ('735faab2-a465-41da-9664-2eb77bfc7e07', '/listas-valor/:ID/eliminar', 'PUT',
     '{"PARAM.ID": "BIGINT"}',
     'Elimina (baja lógica) el valor :ID; solo si nunca se usó. Devuelve el valor con active=false. Errores: 404 (P0002); 400 (22023) ya eliminado; 403 (42501) sin ELIMINAR sobre LISTAS_VALOR; 409 (23503) si es usado por el sistema, está en uso en otra tabla o tiene valores hijos activos (en ese caso se inactiva).',
     $q$SELECT academico_test.fn_listavalor_eliminar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)) AS resultado;$q$)
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
   AND q.path_template LIKE '/listas-valor%'
   AND r.name NOT IN ('CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN');

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id AND m.serviceid = 'eval-col'
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE q.path_template LIKE '/listas-valor%'
ON CONFLICT DO NOTHING;
