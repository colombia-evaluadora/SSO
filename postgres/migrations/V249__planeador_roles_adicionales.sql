-- ===========================================================================
-- V249 — Planeador educativo: amplia el acceso de los 48 endpoints
-- (V245-V248, `/planeador/...` en eval-col) a CEVAL-DOCENTE
-- (CU-86e311xxp).
--
-- CONTEXTO: V245-V248 documentaron explicitamente que `role_query` solo
-- traia CEVAL-SUPER_ADMINISTRADOR porque, en ese momento, era el UNICO rol
-- CEVAL-* sincronizado en el Postgres LOCAL de pruebas -- pero el catalogo
-- real de TROL (16 roles) SI existe en el servidor, y el menu PLANEADOR
-- (V216) YA estaba sembrado para DOCENTE + SUPER_ADMINISTRADOR en
-- TROL_MENU (confirmado consultando el servidor real, no se repite aqui).
--
-- Se restringe a DOCENTE por ahora (decision del usuario): otros roles
-- (RECTOR, COORDINADOR, DIRECTOR_GRUPO, AUXILIAR_ADMINISTRATIVO,
-- PSICO_ORIENTADOR) NO tienen el menu PLANEADOR asignado en TROL_MENU
-- todavia, asi que agregarlos aqui a role_query seria un permiso vacio: el
-- usuario pasaria el gateway pero fn_assert_permiso_seccion (V29/V216) lo
-- rechazaria igual (42501) por no tener el menu. Cuando el negocio defina
-- que otros roles deben ver Planeador, esa es una migracion nueva que
-- primero siembra TROL_MENU y luego amplia role_query -- no se adelanta
-- aqui.
--
-- role_query es el gate del GATEWAY (public.query), independiente de
-- TROL_MENU (el gate fino real, dentro de cada funcion via
-- fn_assert_permiso_seccion). Un solo INSERT para los 48 endpoints
-- `/planeador/%` de eval-col YA REGISTRADOS (V245-V248) -- no hace falta
-- repetir 48 bloques como V245-V248 porque aqui el mismo rol aplica a
-- todos.
--
-- Depende de: V216 (menu PLANEADOR + fn_assert_permiso_seccion, DOCENTE ya
-- sembrado en TROL_MENU), V245-V248 (los 48 endpoints /planeador/... de
-- eval-col).
-- ===========================================================================

SET search_path TO academico_test, public;

-- ===========================================================================
-- role_query — CEVAL-DOCENTE sobre los 48 endpoints /planeador/... de
-- eval-col YA registrados (V245-V248).
-- ===========================================================================
INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name = 'CEVAL-DOCENTE'
 WHERE m.serviceid = 'eval-col'
   AND q.path_template LIKE '/planeador/%'
ON CONFLICT DO NOTHING;
