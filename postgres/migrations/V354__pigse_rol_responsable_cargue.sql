-- ===========================================================================
-- V354 — Rol propio PIGSE-RESPONSABLE_CARGUE.
--
-- CONTEXTO
--   Se van a dar de alta ~100 cuentas para los 50 establecimientos del ente
--   territorial: un Rector y un "Responsable de cargue" por establecimiento.
--   Rector ya tiene rol propio desde V148 (PIGSE-RECTOR). "Responsable de
--   cargue" no existia: el candidato mas cercano del catalogo era
--   PIGSE-AUXILIAR_ADMINISTRATIVO, pero reutilizarlo habria mezclado dos
--   figuras distintas bajo el mismo rol y habria arrastrado a las 3 cuentas
--   que HOY lo tienen cualquier permiso que se le agregue despues por el
--   cargue. Se crea rol propio.
--
-- PREFIJO
--   PIGSE- (guion), el mismo que V148 fijo para los 8 roles originales y que
--   QueryAdminService.rolesPermitidosPara usa para filtrar por app. Un
--   PIGSE_ con guion bajo quedaria fuera de ese patron.
--
-- PERMISOS
--   El responsable de cargue es exactamente quien sube y actualiza los
--   documentos institucionales de SU establecimiento. Ese conjunto ya existe
--   en el catalogo: es el de PIGSE-SECRETARIO (V149/V261) mas los endpoints
--   de archivo que PIGSE-RECTOR ya tiene. No se inventa ninguna query nueva.
--
--     public.query    (query-service "pigse")
--       GET   /documentos          ver los documentos del establecimiento
--       POST  /documentos/upload   cargar un documento
--       PATCH /documentos/:TIPO    reemplazar/actualizar por tipo
--       GET   /establecimientos    resolver su propio establecimiento
--       GET   /my-menus            armar el menu lateral del front
--
--     public.endpoint (microservicios REST)
--       POST  /files/**                    subir binario
--       PUT   /files/**                    idem, metodo PUT (catch-all)
--       GET   /files/download/{archivoId}  descargar
--       GET   /files/view/{archivoId}      ver inline
--       POST  /files/view-token/{archivoId} acuñar token de vista
--
--   NO recibe /cumplimiento/** : el seguimiento de cumplimiento es del ente
--   territorial, no del establecimiento que carga.
--
-- role_grant (V260) — SIN ESTO EL ALTA DELEGADA NO PUEDE CREAR ESTAS CUENTAS.
--   V260 crea public.role_grant y siembra, con un INSERT de una sola vez,
--   que PIGSE-ADMINISTRADOR puede otorgar todos los roles que EN ESE
--   MOMENTO estuvieran en role_app para la app PIGSE. Ese seed ya corrio
--   (V260 < V354) y no se re-ejecuta solo: un rol PIGSE creado despues no
--   entra ahi por si mismo. Sin la fila explicita de abajo,
--   PIGSE-RESPONSABLE_CARGUE quedaria creado pero NINGUN PIGSE-ADMINISTRADOR
--   podria asignarlo via POST /register/account (AccountRegistrationService
--   rechaza cualquier rol que el otorgante no tenga en role_grant; solo
--   ADMIN tiene bypass, ver V260).
--
-- IDEMPOTENCIA
--   Todo por NOMBRE de rol / path+metodo, nunca por id: los id_query e
--   id_endpoint difieren entre test y produccion. Reejecutable sin efecto.
-- ===========================================================================

-- 1. El rol.
INSERT INTO public.role (name, description)
SELECT 'PIGSE-RESPONSABLE_CARGUE', 'Responsable de cargue (Establecimiento)'
 WHERE NOT EXISTS (
     SELECT 1 FROM public.role WHERE name = 'PIGSE-RESPONSABLE_CARGUE'
 );

-- 2. role_app: el rol ve la app PIGSE. Sin esto el rol existe pero
--    rolesPermitidosPara no lo ofrece y no se puede atar a las queries.
INSERT INTO public.role_app (id_app, id_role)
SELECT a.id_app, r.id_role
  FROM public.app a
  JOIN public.role r ON r.name = 'PIGSE-RESPONSABLE_CARGUE'
 WHERE a.name = 'PIGSE'
   AND NOT EXISTS (
       SELECT 1 FROM public.role_app ra
        WHERE ra.id_app = a.id_app AND ra.id_role = r.id_role
   );

-- 3. role_query: las 5 queries del query-service "pigse". El join contra
--    microservice acota el match a este query-service — hay path_template
--    homonimos en otros servicios.
INSERT INTO public.role_query (query_id, role_id)
SELECT q.id_query, r.id_role
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
                            AND m.serviceid = 'pigse'
  JOIN public.role r ON r.name = 'PIGSE-RESPONSABLE_CARGUE'
 WHERE (q.http_method, q.path_template) IN (
         ('GET',   '/documentos'),
         ('POST',  '/documentos/upload'),
         ('PATCH', '/documentos/:TIPO'),
         ('GET',   '/establecimientos'),
         ('GET',   '/my-menus')
       )
   AND NOT EXISTS (
       SELECT 1 FROM public.role_query rq
        WHERE rq.query_id = q.id_query AND rq.role_id = r.id_role
   );

-- 4. role_endpoint: los endpoints de archivo. /files/** tiene mas de una
--    fila por metodo (distinta description, ver uq_endpoint_path_method_desc),
--    por eso el match es por (method, path) y toma las que haya.
INSERT INTO public.role_endpoint (endpoint_id, role_id)
SELECT e.id_endpoint, r.id_role
  FROM public.endpoint e
  JOIN public.role r ON r.name = 'PIGSE-RESPONSABLE_CARGUE'
 WHERE (e.method, e.path) IN (
         ('POST', '/files/**'),
         ('PUT',  '/files/**'),
         ('GET',  '/files/download/{archivoId}'),
         ('GET',  '/files/view/{archivoId}'),
         ('POST', '/files/view-token/{archivoId}')
       )
   AND NOT EXISTS (
       SELECT 1 FROM public.role_endpoint re
        WHERE re.endpoint_id = e.id_endpoint AND re.role_id = r.id_role
   );

-- 5. role_grant: PIGSE-ADMINISTRADOR puede otorgar este rol nuevo al dar de
--    alta una cuenta via POST /register/account. No toca ADMIN (bypass,
--    ver V260) ni ningun otro rol PIGSE (solo PIGSE-ADMINISTRADOR reparte,
--    por diseño de V260).
INSERT INTO public.role_grant (granting_role_id, grantable_role_id)
SELECT admin.id_role, r.id_role
  FROM public.role admin
  JOIN public.role r ON r.name = 'PIGSE-RESPONSABLE_CARGUE'
 WHERE admin.name = 'PIGSE-ADMINISTRADOR'
   AND NOT EXISTS (
       SELECT 1 FROM public.role_grant rg
        WHERE rg.granting_role_id = admin.id_role
          AND rg.grantable_role_id = r.id_role
   );

-- 6. Red de seguridad: si el rol quedo sin ninguna query, es que el catalogo
--    del entorno no tiene el query-service "pigse" cargado todavia y las
--    100 cuentas entrarian a una app en la que no pueden hacer nada. Si
--    quedo sin la fila de role_grant, es que PIGSE-ADMINISTRADOR todavia no
--    existe en este entorno (V148) y el alta delegada no podria asignarlo.
--    Mejor fallar la migracion aca que descubrirlo con los usuarios ya
--    creados.
DO $$
DECLARE
    v_queries   INT;
    v_endpoints INT;
    v_grant     INT;
BEGIN
    SELECT count(*) INTO v_queries
      FROM public.role_query rq
      JOIN public.role r ON r.id_role = rq.role_id
     WHERE r.name = 'PIGSE-RESPONSABLE_CARGUE';

    SELECT count(*) INTO v_endpoints
      FROM public.role_endpoint re
      JOIN public.role r ON r.id_role = re.role_id
     WHERE r.name = 'PIGSE-RESPONSABLE_CARGUE';

    SELECT count(*) INTO v_grant
      FROM public.role_grant rg
      JOIN public.role admin ON admin.id_role = rg.granting_role_id
      JOIN public.role r     ON r.id_role     = rg.grantable_role_id
     WHERE admin.name = 'PIGSE-ADMINISTRADOR'
       AND r.name = 'PIGSE-RESPONSABLE_CARGUE';

    IF v_queries < 5 THEN
        RAISE EXCEPTION
            'PIGSE-RESPONSABLE_CARGUE quedo con % de 5 queries. Falta cargar el catalogo del query-service "pigse" en este entorno.',
            v_queries;
    END IF;

    IF v_grant < 1 THEN
        RAISE EXCEPTION
            'PIGSE-ADMINISTRADOR no puede otorgar PIGSE-RESPONSABLE_CARGUE (role_grant vacio). Falta PIGSE-ADMINISTRADOR (V148) o role_grant (V260) en este entorno.';
    END IF;

    RAISE NOTICE 'PIGSE-RESPONSABLE_CARGUE listo: % queries, % endpoints, otorgable por PIGSE-ADMINISTRADOR.',
        v_queries, v_endpoints;
END $$;
