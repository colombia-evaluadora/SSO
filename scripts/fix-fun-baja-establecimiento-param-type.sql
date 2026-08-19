-- Declara el tipo de :PARAM.ID para la ruta PUT /establecimientos/funcionarios/:ID
-- (fn_fun_baja_establecimiento, uuid=eval-col-funcionarios-baja-001) en el catalogo
-- de sso-admin (tabla public.query). Sin esto, cualquier llamada devuelve 400
-- "placeholders sin tipo declarado" -- la ruta nunca se habia probado antes de
-- V78 (fn_fun_baja_establecimiento no existia localmente hasta esa migracion).
--
-- Ver docs/etiqueta-cambios-por-funcion.md, seccion "V78 — sincronización desde
-- producción". No es una migracion Flyway porque public.query es dato
-- administrado por sso-admin (mismo criterio que
-- scripts/wrap-write-queries-audit-context.sql).
--
--   psql -h <host> -U <user> -d sso_db -f scripts/fix-fun-baja-establecimiento-param-type.sql

UPDATE public.query
SET param_types = '{"PARAM.ID": "BIGINT"}'::jsonb
WHERE query ILIKE '%fn_fun_baja_establecimiento(%'
  AND (param_types IS NULL OR param_types = '{}'::jsonb);
