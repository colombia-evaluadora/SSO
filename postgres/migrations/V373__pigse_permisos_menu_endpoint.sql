-- ============================================================================
-- V373 — GET /permisos-menu/:CODIGO (pigse): resuelve, para el usuario
-- llamante, las 4 capacidades (crear/editar/eliminar/ver) sobre un menu --
-- consume directamente pigse.fn_usuario_puede_en_menu (V370). El front YA
-- tenia un hook stub para esto (`useMenuPermission`, features/navigation)
-- con un comentario explicito: "PIGSE no expone el endpoint permisos-menu
-- que usa CEVAL ... mientras no exista ese catalogo aca, este hook devuelve
-- los cuatro permisos habilitados". Ahora existe.
-- ============================================================================

INSERT INTO public.query (uuid, query, type, microservice_id, path_template, execution_mode, http_method, param_types)
SELECT 'pigse-permisos-menu',
       $q$SELECT
              pigse.fn_usuario_puede_en_menu(public.fn_get_pigse_usuario_id(CAST(:CONTEXT.USER_ID AS BIGINT)), CAST(:PARAM.CODIGO AS VARCHAR), 'CREAR')    AS "puedeCrear",
              pigse.fn_usuario_puede_en_menu(public.fn_get_pigse_usuario_id(CAST(:CONTEXT.USER_ID AS BIGINT)), CAST(:PARAM.CODIGO AS VARCHAR), 'EDITAR')   AS "puedeEditar",
              pigse.fn_usuario_puede_en_menu(public.fn_get_pigse_usuario_id(CAST(:CONTEXT.USER_ID AS BIGINT)), CAST(:PARAM.CODIGO AS VARCHAR), 'ELIMINAR') AS "puedeEliminar",
              pigse.fn_usuario_puede_en_menu(public.fn_get_pigse_usuario_id(CAST(:CONTEXT.USER_ID AS BIGINT)), CAST(:PARAM.CODIGO AS VARCHAR), 'VER')      AS "puedeVer"
       $q$,
       'postgres', m.id_microservice, '/permisos-menu/:CODIGO', 'SELECT', 'GET',
       '{"PARAM.CODIGO": "VARCHAR!"}'::jsonb
  FROM public.microservice m WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE uuid = 'pigse-permisos-menu');

-- Abierto a cualquier rol PIGSE con acceso a la app: la funcion misma es
-- fail-closed (rol sin capability -> FALSE), asi que no hace falta acotar
-- por role_query mas alla de "pertenece a la app".
INSERT INTO public.role_query (query_id, role_id)
SELECT q.id_query, ro.id_role
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id AND m.serviceid = 'pigse'
 CROSS JOIN public.role ro
  JOIN public.role_app ra ON ra.id_role = ro.id_role
  JOIN public.app a ON a.id_app = ra.id_app AND a.name = 'PIGSE'
 WHERE q.uuid = 'pigse-permisos-menu'
   AND NOT EXISTS (SELECT 1 FROM public.role_query rq WHERE rq.query_id = q.id_query AND rq.role_id = ro.id_role);

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.query WHERE uuid = 'pigse-permisos-menu') THEN
        RAISE EXCEPTION 'V373 fallo: pigse-permisos-menu no quedo registrada';
    END IF;
    RAISE NOTICE 'V373 OK: GET /permisos-menu/:CODIGO registrado.';
END $$;
