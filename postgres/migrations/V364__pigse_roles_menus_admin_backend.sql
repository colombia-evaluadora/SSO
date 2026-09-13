-- ============================================================================
-- V364 — backend de la pantalla "Roles y Menús" para PIGSE.
--
-- V363 agregó el ítem de menú, pero la pantalla en sí llama a
-- /api/pigse/roles, /api/pigse/menus, /api/pigse/roles/:id/menus y
-- /api/pigse/plans -- ninguno existía. PIGSE solo tenía /my-menus (la
-- lectura que ya usa el sidebar). Esta migración da de alta el set
-- completo, mirror del que ya existe para CEVAL bajo 'eval-col' (V119)
-- pero contra las tablas GENERICAS del catálogo de menú dinámico
-- (public.route/app_route/role_route/role_app) en vez de un esquema
-- propio -- PIGSE no tiene su propia tabla de menús (a diferencia de
-- CEVAL, que sigue en academico_test.tmenu/trol_menu).
--
-- ALCANCE: solo lo que la pantalla de front_pigse usa hoy --
--   GET/POST  /roles
--   GET/POST/PATCH /menus, PUT /menus/:id/eliminar, PUT /menus/order
--   GET/PUT   /roles/:roleId/menus
--   GET       /plans (stub vacío -- PIGSE no tiene concepto de "plan
--             comercial"; el selector del dialog de menú simplemente
--             queda vacío, optativo en el formulario)
--
-- SEGURIDAD: role_query ya gatea el endpoint completo a
--   PIGSE-ADMINISTRADOR (única identidad con acceso a esta pantalla,
--   mismo criterio que V358 le dio a auditoría). Las funciones de
--   escritura además re-validan el rol del llamante por si el mismo
--   query alguna vez se abre a más roles.
--
-- SCOPING POR APP: todas las funciones filtran explícitamente por
--   app.name = 'PIGSE' (via app_route/role_app) para que un admin de
--   PIGSE no pueda leer/editar/borrar rutas de otra app por adivinar un
--   id -- la tabla route es compartida por todo el catálogo de SSO.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Helper: ¿el usuario tiene el rol PIGSE-ADMINISTRADOR?
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_pigse_es_administrador(p_id_user BIGINT)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1
          FROM public.role_users ru
          JOIN public.role r ON r.id_role = ru.role_id
         WHERE ru.user_id = p_id_user
           AND r.name = 'PIGSE-ADMINISTRADOR'
    )
$$;

-- ---------------------------------------------------------------------------
-- 2. Roles: alta rápida (RoleDto). Crea el rol y lo liga a la app PIGSE
--    (role_app) para que aparezca en el catálogo de "roles de PIGSE".
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_pigse_rol_crear(
    p_id_user BIGINT,
    p_nombre  VARCHAR
)
RETURNS TABLE (id BIGINT, name VARCHAR)
LANGUAGE plpgsql
AS $$
DECLARE
    v_id_role  BIGINT;
    v_id_app   BIGINT;
    v_nombre   VARCHAR;
    v_codigo   VARCHAR;
BEGIN
    IF NOT public.fn_pigse_es_administrador(p_id_user) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    v_nombre := TRIM(p_nombre);
    IF NULLIF(v_nombre, '') IS NULL THEN
        RAISE EXCEPTION 'El nombre del rol es obligatorio' USING ERRCODE = '22023';
    END IF;

    -- Mismo criterio que academico_test.fn_add_trol (V113): el nombre
    -- humano que escribe el admin ("Jefe de bienestar") se guarda tal
    -- cual en description (lo que ve la pantalla), y se deriva un
    -- CODIGO canonico -- UPPER + espacios->'_' -- para el "name" real de
    -- public.role, con el prefijo PIGSE- que ya usan todos los demas.
    v_codigo := 'PIGSE-' || UPPER(regexp_replace(v_nombre, '\s+', '_', 'g'));

    SELECT a.id_app INTO v_id_app FROM public.app a WHERE a.name = 'PIGSE';

    IF EXISTS (SELECT 1 FROM public.role WHERE name = v_codigo OR description = v_nombre) THEN
        RAISE EXCEPTION 'Ya existe un rol con ese nombre' USING ERRCODE = '23505';
    END IF;

    INSERT INTO public.role (name, description)
    VALUES (v_codigo, v_nombre)
    RETURNING id_role INTO v_id_role;

    INSERT INTO public.role_app (id_app, id_role) VALUES (v_id_app, v_id_role)
    ON CONFLICT DO NOTHING;

    RETURN QUERY SELECT v_id_role, v_nombre;
END;
$$;

-- ---------------------------------------------------------------------------
-- 3. Menús (routes de PIGSE): alta.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_pigse_ruta_crear(
    p_id_user   BIGINT,
    p_name      VARCHAR,
    p_path      VARCHAR,
    p_icon      VARCHAR,
    p_id_parent BIGINT
)
RETURNS TABLE (id BIGINT, name VARCHAR, path VARCHAR, icon VARCHAR,
               "menuOrder" INTEGER, type VARCHAR, "idParent" BIGINT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_id_route BIGINT;
    v_id_app   BIGINT;
    v_order    INTEGER;
BEGIN
    IF NOT public.fn_pigse_es_administrador(p_id_user) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;
    IF NULLIF(TRIM(p_name), '') IS NULL THEN
        RAISE EXCEPTION 'El nombre del menu es obligatorio' USING ERRCODE = '22023';
    END IF;

    SELECT a.id_app INTO v_id_app FROM public.app a WHERE a.name = 'PIGSE';

    IF p_id_parent IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.app_route ar
         WHERE ar.id_app = v_id_app AND ar.id_route = p_id_parent
    ) THEN
        RAISE EXCEPTION 'El menu padre (%) no existe o no pertenece a PIGSE', p_id_parent
            USING ERRCODE = '23503';
    END IF;

    SELECT COALESCE(MAX(r.menuorder), 0) + 1 INTO v_order
      FROM public.route r
      JOIN public.app_route ar ON ar.id_route = r.id_route
     WHERE ar.id_app = v_id_app
       AND r.idparent IS NOT DISTINCT FROM p_id_parent;

    INSERT INTO public.route (name, path, icon, menuorder, idparent)
    VALUES (TRIM(p_name), NULLIF(TRIM(p_path), ''), NULLIF(TRIM(p_icon), ''), v_order, p_id_parent)
    RETURNING id_route INTO v_id_route;

    INSERT INTO public.app_route (id_app, id_route) VALUES (v_id_app, v_id_route);

    RETURN QUERY
    SELECT r.id_route, r.name, r.path, r.icon, r.menuorder, r.type, r.idparent
      FROM public.route r WHERE r.id_route = v_id_route;
END;
$$;

-- ---------------------------------------------------------------------------
-- 4. Menús: edición. COALESCE -- solo toca lo que llega no-NULL, mismo
--    criterio que fn_est_actualizar.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_pigse_ruta_actualizar(
    p_id_user   BIGINT,
    p_id        BIGINT,
    p_name      VARCHAR,
    p_path      VARCHAR,
    p_icon      VARCHAR,
    p_id_parent BIGINT,
    p_tiene_parent BOOLEAN  -- distingue "no llego" (NULL, no tocar) de "se quiere volver raiz" (NULL explicito)
)
RETURNS TABLE (id BIGINT, name VARCHAR, path VARCHAR, icon VARCHAR,
               "menuOrder" INTEGER, type VARCHAR, "idParent" BIGINT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_id_app BIGINT;
BEGIN
    IF NOT public.fn_pigse_es_administrador(p_id_user) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    SELECT a.id_app INTO v_id_app FROM public.app a WHERE a.name = 'PIGSE';

    IF NOT EXISTS (SELECT 1 FROM public.app_route ar WHERE ar.id_app = v_id_app AND ar.id_route = p_id) THEN
        RAISE EXCEPTION 'El menu (%) no existe o no pertenece a PIGSE', p_id USING ERRCODE = 'P0002';
    END IF;

    UPDATE public.route
       SET name  = COALESCE(NULLIF(TRIM(p_name), ''), name),
           path  = CASE WHEN p_path IS NULL THEN path ELSE NULLIF(TRIM(p_path), '') END,
           icon  = CASE WHEN p_icon IS NULL THEN icon ELSE NULLIF(TRIM(p_icon), '') END,
           idparent = CASE WHEN p_tiene_parent THEN p_id_parent ELSE idparent END
     WHERE id_route = p_id;

    RETURN QUERY
    SELECT r.id_route, r.name, r.path, r.icon, r.menuorder, r.type, r.idparent
      FROM public.route r WHERE r.id_route = p_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 5. Menús: baja. DELETE real -- route.idparent tiene ON DELETE CASCADE
--    (V1/schema base), asi que borrar un grupo se lleva a sus items solo;
--    app_route/role_route tambien son ON DELETE CASCADE por route_id, asi
--    que quedan limpios sin pasos extra. Logra exactamente el "soft-delete
--    en cascada" que el front ya documenta, sin necesitar una columna
--    active que route no tiene.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_pigse_ruta_eliminar(
    p_id_user BIGINT,
    p_id      BIGINT
)
RETURNS TABLE (status VARCHAR, message VARCHAR)
LANGUAGE plpgsql
AS $$
DECLARE
    v_id_app BIGINT;
    v_name   VARCHAR;
BEGIN
    IF NOT public.fn_pigse_es_administrador(p_id_user) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    SELECT a.id_app INTO v_id_app FROM public.app a WHERE a.name = 'PIGSE';

    SELECT r.name INTO v_name
      FROM public.route r
      JOIN public.app_route ar ON ar.id_route = r.id_route AND ar.id_app = v_id_app
     WHERE r.id_route = p_id;

    IF v_name IS NULL THEN
        RAISE EXCEPTION 'El menu (%) no existe o no pertenece a PIGSE', p_id USING ERRCODE = 'P0002';
    END IF;

    DELETE FROM public.route WHERE id_route = p_id;

    RETURN QUERY SELECT 'success'::VARCHAR, format('Menu "%s" eliminado.', v_name)::VARCHAR;
END;
$$;

-- ---------------------------------------------------------------------------
-- 6. Menús: reordenar (catálogo). BODY.ITEMS es un array de {id, menuOrder}.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_pigse_rutas_reordenar(
    p_id_user BIGINT,
    p_items   JSONB
)
RETURNS TABLE (status VARCHAR, message VARCHAR)
LANGUAGE plpgsql
AS $$
DECLARE
    v_id_app BIGINT;
    v_item   JSONB;
BEGIN
    IF NOT public.fn_pigse_es_administrador(p_id_user) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    SELECT a.id_app INTO v_id_app FROM public.app a WHERE a.name = 'PIGSE';

    FOR v_item IN SELECT jsonb_array_elements(COALESCE(p_items, '[]'::jsonb))
    LOOP
        UPDATE public.route r
           SET menuorder = (v_item->>'menuOrder')::INTEGER
          FROM public.app_route ar
         WHERE ar.id_route = r.id_route
           AND ar.id_app = v_id_app
           AND r.id_route = (v_item->>'id')::BIGINT;
    END LOOP;

    RETURN QUERY SELECT 'success'::VARCHAR, 'Orden actualizado.'::VARCHAR;
END;
$$;

-- ---------------------------------------------------------------------------
-- 7. Rol -> menús asignados: reemplaza el conjunto completo.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_pigse_rol_rutas_actualizar(
    p_id_user  BIGINT,
    p_role_id  BIGINT,
    p_menu_ids BIGINT[]
)
RETURNS TABLE (status VARCHAR, message VARCHAR)
LANGUAGE plpgsql
AS $$
DECLARE
    v_id_app BIGINT;
BEGIN
    IF NOT public.fn_pigse_es_administrador(p_id_user) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.role WHERE id_role = p_role_id) THEN
        RAISE EXCEPTION 'El rol (%) no existe', p_role_id USING ERRCODE = 'P0002';
    END IF;

    SELECT a.id_app INTO v_id_app FROM public.app a WHERE a.name = 'PIGSE';

    -- Solo se tocan los binds del rol que caen dentro del catalogo de
    -- PIGSE -- si el mismo rol tuviera rutas de otra app (no aplica hoy,
    -- pero la funcion queda correcta si algun dia pasa), esas no se
    -- pierden.
    DELETE FROM public.role_route rr
     USING public.app_route ar
     WHERE rr.route_id = ar.id_route
       AND ar.id_app = v_id_app
       AND rr.role_id = p_role_id;

    INSERT INTO public.role_route (role_id, route_id)
    SELECT p_role_id, ar.id_route
      FROM public.app_route ar
     WHERE ar.id_app = v_id_app
       AND ar.id_route = ANY(COALESCE(p_menu_ids, ARRAY[]::BIGINT[]))
    ON CONFLICT DO NOTHING;

    RETURN QUERY SELECT 'success'::VARCHAR, 'Menus del rol actualizados.'::VARCHAR;
END;
$$;

-- ---------------------------------------------------------------------------
-- 8. Registro en public.query (microservicio 'pigse') + role_query para
--    PIGSE-ADMINISTRADOR.
-- ---------------------------------------------------------------------------

-- 8.1 GET /roles -- nombre amigable via role.description (mismo criterio
-- que CEVAL: academico_test.trol.nombre != public.role.name/codigo. PIGSE
-- no tiene una tabla propia tipo trol, pero role.description YA trae ese
-- nombre humanizado desde que se sembraron los roles -- COALESCE a name
-- solo como red de seguridad si algun rol nuevo quedara sin description.
INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT gen_random_uuid()::text,
       $q$SELECT r.id_role AS id, COALESCE(r.description, r.name) AS name
            FROM public.role r
            JOIN public.role_app ra ON ra.id_role = r.id_role
            JOIN public.app a ON a.id_app = ra.id_app
           WHERE a.name = 'PIGSE'
           ORDER BY COALESCE(r.description, r.name)$q$,
       'postgres', false, false, m.id_microservice, '/roles', 'SELECT', 'GET', '{}'::jsonb,
       'roles-permisos PIGSE: catalogo de roles de la app (RoleDto[]), nombre humanizado via role.description.'
  FROM public.microservice m
 WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE microservice_id = m.id_microservice AND path_template = '/roles' AND http_method = 'GET');

-- 8.2 POST /roles
INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT gen_random_uuid()::text,
       $q$SELECT * FROM public.fn_pigse_rol_crear(:CONTEXT.USER_ID::BIGINT, CAST(:BODY.NAME AS VARCHAR))$q$,
       'postgres', false, false, m.id_microservice, '/roles', 'SELECT', 'POST', '{"BODY.NAME":"VARCHAR"}'::jsonb,
       'roles-permisos PIGSE: alta rapida de rol (RoleDto 201).'
  FROM public.microservice m
 WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE microservice_id = m.id_microservice AND path_template = '/roles' AND http_method = 'POST');

-- 8.3 GET /menus
INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT gen_random_uuid()::text,
       $q$SELECT r.id_route AS id, r.name, r.path, r.icon, r.menuorder AS "menuOrder", r.type, r.idparent AS "idParent"
            FROM public.route r
            JOIN public.app_route ar ON ar.id_route = r.id_route
            JOIN public.app a ON a.id_app = ar.id_app
           WHERE a.name = 'PIGSE'
           ORDER BY r.menuorder$q$,
       'postgres', false, false, m.id_microservice, '/menus', 'SELECT', 'GET', '{}'::jsonb,
       'roles-permisos PIGSE: catalogo COMPLETO de menus (MenuDto[]), sin filtrar por rol.'
  FROM public.microservice m
 WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE microservice_id = m.id_microservice AND path_template = '/menus' AND http_method = 'GET');

-- 8.4 POST /menus
INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT gen_random_uuid()::text,
       $q$SELECT * FROM public.fn_pigse_ruta_crear(
           :CONTEXT.USER_ID::BIGINT,
           CAST(:BODY.NAME AS VARCHAR),
           CAST(:BODY.PATH AS VARCHAR),
           CAST(:BODY.ICON AS VARCHAR),
           CAST(:BODY.IDPARENT AS BIGINT)
       )$q$,
       'postgres', false, false, m.id_microservice, '/menus', 'SELECT', 'POST',
       '{"BODY.NAME":"VARCHAR","BODY.PATH":"Nullable(VARCHAR)","BODY.ICON":"Nullable(VARCHAR)","BODY.IDPARENT":"Nullable(BIGINT)"}'::jsonb,
       'roles-permisos PIGSE: alta de menu (MenuDto 201).'
  FROM public.microservice m
 WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE microservice_id = m.id_microservice AND path_template = '/menus' AND http_method = 'POST');

-- 8.5 PATCH /menus/:ID
INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT gen_random_uuid()::text,
       $q$SELECT * FROM public.fn_pigse_ruta_actualizar(
           :CONTEXT.USER_ID::BIGINT,
           CAST(:PARAM.ID AS BIGINT),
           CAST(:BODY.NAME AS VARCHAR),
           CAST(:BODY.PATH AS VARCHAR),
           CAST(:BODY.ICON AS VARCHAR),
           CAST(:BODY.IDPARENT AS BIGINT),
           (:BODY_RAW ? 'idParent')
       )$q$,
       'postgres', false, false, m.id_microservice, '/menus/:ID', 'SELECT', 'PATCH',
       '{"PARAM.ID":"BIGINT","BODY.NAME":"Nullable(VARCHAR)","BODY.PATH":"Nullable(VARCHAR)","BODY.ICON":"Nullable(VARCHAR)","BODY.IDPARENT":"Nullable(BIGINT)"}'::jsonb,
       'roles-permisos PIGSE: edicion de menu (MenuDto).'
  FROM public.microservice m
 WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE microservice_id = m.id_microservice AND path_template = '/menus/:ID' AND http_method = 'PATCH');

-- 8.6 PUT /menus/:ID/eliminar
INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT gen_random_uuid()::text,
       $q$SELECT * FROM public.fn_pigse_ruta_eliminar(:CONTEXT.USER_ID::BIGINT, CAST(:PARAM.ID AS BIGINT))$q$,
       'postgres', false, false, m.id_microservice, '/menus/:ID/eliminar', 'SELECT', 'PUT',
       '{"PARAM.ID":"BIGINT"}'::jsonb,
       'roles-permisos PIGSE: baja de menu en cascada (status/message).'
  FROM public.microservice m
 WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE microservice_id = m.id_microservice AND path_template = '/menus/:ID/eliminar' AND http_method = 'PUT');

-- 8.7 PUT /menus/order
INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT gen_random_uuid()::text,
       $q$SELECT * FROM public.fn_pigse_rutas_reordenar(:CONTEXT.USER_ID::BIGINT, CAST(:BODY.ITEMS AS JSONB))$q$,
       'postgres', false, false, m.id_microservice, '/menus/order', 'SELECT', 'PUT',
       '{"BODY.ITEMS":"JSONB"}'::jsonb,
       'roles-permisos PIGSE: reordena el catalogo de menus (status/message).'
  FROM public.microservice m
 WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE microservice_id = m.id_microservice AND path_template = '/menus/order' AND http_method = 'PUT');

-- 8.8 GET /roles/:ROLEID/menus
INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT gen_random_uuid()::text,
       $q$SELECT r.id_route AS id
            FROM public.role_route rr
            JOIN public.route r ON r.id_route = rr.route_id
            JOIN public.app_route ar ON ar.id_route = r.id_route
            JOIN public.app a ON a.id_app = ar.id_app
           WHERE a.name = 'PIGSE'
             AND rr.role_id = CAST(:PARAM.ROLEID AS BIGINT)
           ORDER BY r.menuorder$q$,
       'postgres', false, false, m.id_microservice, '/roles/:ROLEID/menus', 'SELECT', 'GET',
       '{"PARAM.ROLEID":"BIGINT"}'::jsonb,
       'roles-permisos PIGSE: ids de menu asignados a un rol.'
  FROM public.microservice m
 WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE microservice_id = m.id_microservice AND path_template = '/roles/:ROLEID/menus' AND http_method = 'GET');

-- 8.9 PUT /roles/:ROLEID/menus
INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT gen_random_uuid()::text,
       $q$SELECT * FROM public.fn_pigse_rol_rutas_actualizar(
           :CONTEXT.USER_ID::BIGINT,
           CAST(:PARAM.ROLEID AS BIGINT),
           (SELECT array_agg(x::BIGINT) FROM jsonb_array_elements_text(CAST(:BODY.MENUIDS AS JSONB)) AS x)
       )$q$,
       'postgres', false, false, m.id_microservice, '/roles/:ROLEID/menus', 'SELECT', 'PUT',
       '{"PARAM.ROLEID":"BIGINT","BODY.MENUIDS":"JSONB"}'::jsonb,
       'roles-permisos PIGSE: reemplaza los menus asignados a un rol (status/message).'
  FROM public.microservice m
 WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE microservice_id = m.id_microservice AND path_template = '/roles/:ROLEID/menus' AND http_method = 'PUT');

-- 8.10 GET /plans (stub vacio -- PIGSE no tiene concepto de plan comercial)
INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT gen_random_uuid()::text,
       $q$SELECT NULL::BIGINT AS id, NULL::VARCHAR AS name WHERE FALSE$q$,
       'postgres', false, false, m.id_microservice, '/plans', 'SELECT', 'GET', '{}'::jsonb,
       'roles-permisos PIGSE: stub vacio -- PIGSE no tiene concepto de plan comercial (a diferencia de CEVAL).'
  FROM public.microservice m
 WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE microservice_id = m.id_microservice AND path_template = '/plans' AND http_method = 'GET');

-- ---------------------------------------------------------------------------
-- 9. role_query: PIGSE-ADMINISTRADOR para las 9 queries nuevas.
-- ---------------------------------------------------------------------------
INSERT INTO public.role_query (role_id, query_id)
SELECT ro.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  CROSS JOIN public.role ro
 WHERE m.serviceid = 'pigse'
   AND ro.name = 'PIGSE-ADMINISTRADOR'
   AND (q.path_template, q.http_method) IN (
       ('/roles', 'GET'), ('/roles', 'POST'),
       ('/menus', 'GET'), ('/menus', 'POST'), ('/menus/:ID', 'PATCH'),
       ('/menus/:ID/eliminar', 'PUT'), ('/menus/order', 'PUT'),
       ('/roles/:ROLEID/menus', 'GET'), ('/roles/:ROLEID/menus', 'PUT'),
       ('/plans', 'GET')
   )
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- Verificación
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_queries BIGINT;
    v_binds   BIGINT;
BEGIN
    SELECT count(*) INTO v_queries
      FROM public.query q
      JOIN public.microservice m ON m.id_microservice = q.microservice_id
     WHERE m.serviceid = 'pigse'
       AND (q.path_template, q.http_method) IN (
           ('/roles', 'GET'), ('/roles', 'POST'),
           ('/menus', 'GET'), ('/menus', 'POST'), ('/menus/:ID', 'PATCH'),
           ('/menus/:ID/eliminar', 'PUT'), ('/menus/order', 'PUT'),
           ('/roles/:ROLEID/menus', 'GET'), ('/roles/:ROLEID/menus', 'PUT'),
           ('/plans', 'GET')
       );

    SELECT count(*) INTO v_binds
      FROM public.role_query rq
      JOIN public.role ro ON ro.id_role = rq.role_id
      JOIN public.query q ON q.id_query = rq.query_id
      JOIN public.microservice m ON m.id_microservice = q.microservice_id
     WHERE m.serviceid = 'pigse'
       AND ro.name = 'PIGSE-ADMINISTRADOR'
       AND (q.path_template, q.http_method) IN (
           ('/roles', 'GET'), ('/roles', 'POST'),
           ('/menus', 'GET'), ('/menus', 'POST'), ('/menus/:ID', 'PATCH'),
           ('/menus/:ID/eliminar', 'PUT'), ('/menus/order', 'PUT'),
           ('/roles/:ROLEID/menus', 'GET'), ('/roles/:ROLEID/menus', 'PUT'),
           ('/plans', 'GET')
       );

    RAISE NOTICE 'V364: % queries nuevas registradas, % binds a PIGSE-ADMINISTRADOR (esperado 10/10)', v_queries, v_binds;

    IF v_queries != 10 THEN
        RAISE EXCEPTION 'V364 fallo: se esperaban 10 queries nuevas, se encontraron %', v_queries;
    END IF;
    IF v_binds != 10 THEN
        RAISE WARNING 'V364: PIGSE-ADMINISTRADOR quedo con % de 10 binds -- revisa que el rol exista con ese nombre exacto', v_binds;
    END IF;
END $$;
