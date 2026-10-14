-- V104 - CRUD de listas de valores (TLISTA_VALOR), capa 4 de 4: menú y
-- endpoints. Menú LISTAS_VALOR bajo ADMINISTRACION para Super administrador,
-- Rector, Jefe de sistema del establecimiento y Auxiliar administrativo; los mismos roles (y SSO-ADMIN) en role_query. ADMINISTRACION
-- se crea si falta: en una base limpia esta migración corre antes que V113, y
-- sin CACHEABLE/CACHE_TTL_SECONDS porque nacen en V110 (sus defaults: no cachear).
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
 WHERE r.CODIGO IN ('SUPER_ADMINISTRADOR', 'RECTOR', 'JEFE_SISTEMA_ESTABLECIMIENTO',
                    'AUXILIAR_ADMINISTRATIVO')
   AND r.ACTIVE = TRUE
   AND NOT EXISTS (SELECT 1 FROM academico_test.TROL_MENU tm
                    WHERE tm.FK_TROL = r.PK_TROL AND tm.FK_TMENU = m.PK_TMENU);

INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, action, style, param_types, detail, query)
SELECT v.uuid, m.id_microservice, v.ruta, v.metodo, 'postgres', 'SELECT', NULL,
       'f', 'f', NULL, NULL, v.param_types::jsonb, v.detalle, v.consulta
  FROM public.microservice m
 CROSS JOIN (VALUES
    ('37c585b7-9c4a-428e-b3f8-6282ca0bcffc', '/listas-valor/categorias', 'GET',
     '{}',
     'Categorías de listas de valores con valores activos: [{categoria, totalValores, esSistema, categoriasPadre}]. esSistema = la categoría tiene valores sembrados por el sistema (solo el super administrador le agrega o elimina valores). categoriasPadre = categorías a las que apuntan sus valores (p.ej. TMUNICIPIO -> [TDEPARTAMENTO]). Errores: 403 (42501) sin VER sobre LISTAS_VALOR.',
     $q$SELECT academico_test.fn_listavalor_categorias_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)) AS resultado;$q$),
    ('1fd9284f-cc85-4e75-9eea-708119006970', '/listas-valor', 'GET',
     '{"QUERY.CATEGORIA": "VARCHAR", "QUERY.PADRE": "BIGINT"}',
     'Valores activos de una categoría (?CATEGORIA=) y/o hijos de un valor (?PADRE=<pkListaValor>, p.ej. los municipios de un departamento): [{pkListaValor, categoria, nombre, valor, accion, esSistema, active, padre: {pkListaValor, categoria, nombre, valor} | null}]. Al menos un filtro. Errores: 400 (22023) sin filtros; 403 (42501) sin VER sobre LISTAS_VALOR.',
     $q$SELECT academico_test.fn_listavalor_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.CATEGORIA AS VARCHAR),
    CAST(:QUERY.PADRE AS BIGINT)) AS resultado;$q$),
    ('61659ccb-1d6c-421c-80b8-59a9443326ff', '/listas-valor/categorias', 'POST',
     '{"BODY.CATEGORIA": "VARCHAR", "BODY.VALORES": "JSONB"}',
     'Crea una categoría con sus primeros valores. BODY.CATEGORIA: mayúsculas sin tildes, números y _ (≤30). BODY.VALORES: arreglo [{nombre, valor, accion?, padre?}] (padre = pkListaValor de un valor existente de otra categoría). Devuelve {categoria, valores:[...]}. Todo o nada. Errores: 403 (42501) sin CREAR sobre LISTAS_VALOR o si la categoría tuvo valores del sistema y no es super administrador; 400 (22023) formato, valores vacíos o repetidos, padre inválido; 409 (23505) si la categoría ya existe.',
     $q$SELECT academico_test.fn_listavalor_categoria_crear(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.CATEGORIA AS VARCHAR),
    CAST(:BODY.VALORES AS JSONB)) AS resultado;$q$),
    ('12a5269b-b00c-4a0e-9185-b92c9754350f', '/listas-valor/categorias/:CATEGORIA/eliminar', 'PUT',
     '{"PARAM.CATEGORIA": "VARCHAR"}',
     'Elimina (baja lógica) todos los valores de la categoría :CATEGORIA. Devuelve {categoria, valoresEliminados}. Errores: 404 (P0002) si la categoría no existe; 403 (42501) sin ELIMINAR sobre LISTAS_VALOR o si la categoría tiene valores del sistema y no es super administrador; 409 (23503) si algún valor está en uso en otra tabla o tiene hijos activos.',
     $q$SELECT academico_test.fn_listavalor_categoria_eliminar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.CATEGORIA AS VARCHAR)) AS resultado;$q$),
    ('77ea5618-9ddb-4da8-93ae-55410ce015e8', '/listas-valor', 'POST',
     '{"BODY.CATEGORIA": "VARCHAR", "BODY.NOMBRE": "VARCHAR", "BODY.VALOR": "VARCHAR", "BODY.ACCION": "VARCHAR", "BODY.PADRE": "BIGINT"}',
     'Agrega un valor a una categoría existente. BODY.NOMBRE (≤120) y BODY.VALOR (código, ≤130, único en la categoría) obligatorios; BODY.ACCION (≤150) y BODY.PADRE (pkListaValor del valor padre) opcionales. El padre debe ser de la misma categoría que los padres de los demás valores. Devuelve el valor creado. Errores: 404 (P0002) categoría inexistente; 403 (42501) sin CREAR o categoría del sistema sin ser super administrador; 400 (22023) datos o padre inválidos; 409 (23505) código repetido.',
     $q$SELECT academico_test.fn_listavalor_crear(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.CATEGORIA AS VARCHAR),
    CAST(:BODY.NOMBRE AS VARCHAR),
    CAST(:BODY.VALOR AS VARCHAR),
    CAST(:BODY.ACCION AS VARCHAR),
    CAST(:BODY.PADRE AS BIGINT)) AS resultado;$q$),
    ('d18fdc62-5963-4fcb-b823-46e9001b75f7', '/listas-valor/:ID', 'PUT',
     '{"PARAM.ID": "BIGINT", "BODY.NOMBRE": "VARCHAR", "BODY.ACCION": "VARCHAR", "BODY.PADRE": "BIGINT"}',
     'Reemplaza nombre, acción y padre del valor :ID; ACCION o PADRE omitidos quedan en NULL (así se quita el padre). CATEGORIA y VALOR no se editan. En un valor del sistema solo el super administrador cambia NOMBRE o ACCION (el código los lee); el padre lo puede cambiar cualquiera con EDITAR. Devuelve el valor. Errores: 404 (P0002); 400 (22023) eliminado, datos inválidos, padre inexistente, en ciclo o de otra categoría que la de sus hermanos; 403 (42501) sin EDITAR sobre LISTAS_VALOR o cambio de nombre/acción de un valor del sistema.',
     $q$SELECT academico_test.fn_listavalor_actualizar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.NOMBRE AS VARCHAR),
    CAST(:BODY.ACCION AS VARCHAR),
    CAST(:BODY.PADRE AS BIGINT)) AS resultado;$q$),
    ('735faab2-a465-41da-9664-2eb77bfc7e07', '/listas-valor/:ID/eliminar', 'PUT',
     '{"PARAM.ID": "BIGINT"}',
     'Elimina (baja lógica) el valor :ID. Devuelve el valor con active=false. Errores: 404 (P0002); 400 (22023) ya eliminado; 403 (42501) sin ELIMINAR sobre LISTAS_VALOR o valor del sistema sin ser super administrador; 409 (23503) si está en uso en otra tabla o tiene valores hijos activos.',
     $q$SELECT academico_test.fn_listavalor_eliminar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)) AS resultado;$q$)
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
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR', 'CEVAL-RECTOR', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO',
                                   'CEVAL-AUXILIAR_ADMINISTRATIVO', 'SSO-ADMIN')
 WHERE (q.path_template, q.http_method) IN (
        ('/listas-valor/categorias', 'GET'),
        ('/listas-valor', 'GET'),
        ('/listas-valor/categorias', 'POST'),
        ('/listas-valor/categorias/:CATEGORIA/eliminar', 'PUT'),
        ('/listas-valor', 'POST'),
        ('/listas-valor/:ID', 'PUT'),
        ('/listas-valor/:ID/eliminar', 'PUT'))
ON CONFLICT DO NOTHING;
