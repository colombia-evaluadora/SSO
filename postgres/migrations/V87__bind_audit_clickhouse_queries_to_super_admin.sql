-- V87 — vincula las 9 filas de catálogo de V85/V86 al rol
-- CEVAL-SUPER_ADMINISTRADOR, para que dejen de responder 403 a
-- cualquier caller (el catálogo requiere una fila role_query
-- explícita por query, no hay bypass implícito ni siquiera para
-- ADMIN — ver SecurityConfig/SsoAdminAccessManager).
--
-- Punto de partida deliberadamente angosto, no una decisión final:
-- el histórico completo de auditoría (quién cambió qué, desde qué
-- IP, en qué sesión) es información sensible — ver a quién más
-- (¿SSO-ADMIN? ¿un rol nuevo "AUDITOR" de solo lectura?) darle
-- acceso es una decisión de negocio, no técnica. Quien la tome
-- puede agregar más filas role_query sin tocar esta migración.
INSERT INTO public.role_query (role_id, query_id)
SELECT
    (SELECT id_role FROM public.role WHERE name = 'CEVAL-SUPER_ADMINISTRADOR'),
    id_query
FROM public.query
WHERE microservice_id = (SELECT id_microservice FROM public.microservice WHERE serviceid = 'audit-clickhouse')
ON CONFLICT DO NOTHING;
