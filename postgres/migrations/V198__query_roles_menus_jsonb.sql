-- ===========================================================================
-- V198 — el catalogo public.query de PUT /roles/:ROLEID/menus pasa al
-- contrato JSONB de fn_associate_menus_to_rol (V123).
--
-- Contexto:
--   V123 cambio la firma de academico_test.fn_associate_menus_to_rol:
--     p_pk_tmenus BIGINT[]  ->  p_menus JSONB = [{"id": <bigint>,
--                                                 "soloLectura": <bool>}, ...]
--   La fila del catalogo que sirve PUT /api/eval-col/roles/:ROLEID/menus
--   (id_query 132 en el server de test) NO estaba versionada en Flyway: las
--   filas eval-col de roles/menus (126-132) se sembraron a mano en la BD.
--   Esta migracion la trae al repo y la deja alineada con V123 — sin este
--   UPDATE, ese PUT responde 500 tras desplegar V123 (la query sigue
--   pasando :BODY.MENUIDS como BIGINT[] a una funcion que ya no acepta ese
--   tipo).
--
-- Cambios sobre la fila:
--   * param_types: BODY.MENUS / BODY_RAW.MENUS = JSONB
--     (antes BODY.MENUIDS = BIGINT[]). PARAM.ROLEID = BIGINT se mantiene.
--   * el SQL pasa CAST(:BODY_RAW.MENUS AS JSONB) a la funcion — mismo
--     patron que la fila de PUT /menus/order (id 129), que ya envia un
--     array JSON via :BODY_RAW.ITEMS.
--
-- CONTRATO NUEVO DEL FRONT (panel de administracion de roles):
--   el body de PUT /roles/{roleId}/menus deja de ser
--       { "menuIds": [12, 34, 56] }
--   y pasa a ser
--       { "menus": [ { "id": 12, "soloLectura": true },
--                    { "id": 34 },
--                    { "id": 56, "soloLectura": false } ] }
--   "soloLectura" es opcional por elemento (ausente/false => el rol
--   concede el menu completo; true => solo lectura, se persiste como
--   trol_menu.SOLO_LECTURA = 'SI', lo consume fn_usuario_permisos_menu).
--   Este cambio de forma del request hay que coordinarlo con el front.
--
-- microservice_id se resuelve por serviceid='eval-col' (no id literal,
-- varia por entorno — patron V185/V124). role_query NO se toca (la fila
-- 132 conserva sus grants). Idempotente: fija el mismo texto; 0 filas si
-- la query aun no existe en el entorno donde corre esta migracion.
--
-- Tras aplicar: el contenedor query-service que sirve 'eval-col' cachea
-- el catalogo — reiniciarlo para que tome la fila nueva (mismo requisito
-- que cualquier alta/cambio en public.query).
-- ===========================================================================

SET search_path TO public;

UPDATE public.query q
   SET query = $q$SELECT CASE
                WHEN count(*) = 0 THEN 'success'
                WHEN bool_and(status IN ('inserted', 'reactivated')) THEN 'success'
                ELSE 'error'
            END AS status,
            'Menus del rol actualizados' AS message
       FROM academico_test.fn_associate_menus_to_rol(
           :CONTEXT.USER_ID::BIGINT,
           CAST(:PARAM.ROLEID AS BIGINT),
           CAST(:BODY_RAW.MENUS AS JSONB),
           :CONTEXT.EMAIL,
           TRUE
       );$q$,
       param_types = '{"BODY.MENUS": "JSONB", "BODY_RAW.MENUS": "JSONB", "PARAM.ROLEID": "BIGINT"}'::jsonb
  FROM public.microservice m
 WHERE q.microservice_id = m.id_microservice
   AND m.serviceid       = 'eval-col'
   AND q.path_template    = '/roles/:ROLEID/menus'
   AND q.http_method      = 'PUT';
