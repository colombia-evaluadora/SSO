-- V548 -- backfill de public.route.codigo para los menus de Establecimiento de PIGSE.
-- Qué hace: asigna ESTABLECIMIENTO / SEDES_EDUCATIVAS / FUNCIONARIOS a los items
--   (no grupos) del catalogo PIGSE cuyo path, sin '/' ni 'app/' inicial, coincide.
-- Por qué: V370/V375 los buscaban por path exacto sin prefijo, pero los menus
--   recreados desde la pantalla Roles y Menus guardan '/app/...'; con codigo NULL
--   pigse.fn_usuario_puede_en_menu devuelve FALSE (fail-closed) y el front oculta
--   Agregar/Editar/Eliminar para todos los roles, incluido el administrador.
-- Depende de: V370 (route.codigo), V364 (catalogo PIGSE en app_route).

UPDATE public.route r
   SET codigo = v.codigo
  FROM (VALUES ('establecimiento-educativo/general',      'ESTABLECIMIENTO'),
               ('establecimiento-educativo/sedes',        'SEDES_EDUCATIVAS'),
               ('establecimiento-educativo/funcionarios', 'FUNCIONARIOS')
       ) AS v(path, codigo),
       public.app_route ar
  JOIN public.app a ON a.id_app = ar.id_app AND a.name = 'PIGSE'
 WHERE ar.id_route = r.id_route
   AND r.idparent IS NOT NULL
   AND r.codigo IS NULL
   AND regexp_replace(r.path, '^/?(app/)?', '') = v.path;
