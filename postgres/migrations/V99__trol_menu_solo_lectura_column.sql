-- ===========================================================================
-- V99 — TROL_MENU.SOLO_LECTURA: columna que marca la concesion de un menu
-- por un rol como "solo lectura".
--
-- Que hace:
--   ALTER TABLE academico_test.TROL_MENU ADD COLUMN SOLO_LECTURA VARCHAR(5)
--   (nullable, sin default). Misma columna y semantica de valores que
--   TUSUARIO_ROL_PERMISO.SOLO_LECTURA (V22, linea ~2316):
--     - 'SI'                       -> el rol concede ese menu SOLO para ver
--                                     (crear/editar/eliminar = FALSE, ver = TRUE).
--     - NULL / 'NO' / cualquier otro valor
--                                  -> el rol concede los 4 permisos
--                                     (crear/editar/eliminar/ver = TRUE),
--                                     comportamiento historico (V22).
--
-- Por que va numerada V99 (por debajo del maximo aplicado):
--   La columna la consumen funciones definidas en V113
--   (fn_list_menu_possibilities_for_rol), V123 (fn_associate_menus_to_rol) y
--   V185 (fn_usuario_permisos_menu, LANGUAGE sql — se valida al crearse, asi
--   que la columna DEBE existir antes de V185). Por eso el ALTER se coloca
--   antes de V113. En un entorno ya migrado por encima de V99 esta es una
--   migracion OUT-OF-ORDER: Flyway solo la aplica con -outOfOrder=true; sin
--   esa bandera queda registrada como pendiente y NO corre. Deploy en
--   servidores existentes: correr `flyway repair` (las funciones de
--   V113/V123/V185 cambiaron de checksum al refundir aqui el modo
--   solo-lectura) y `flyway migrate -outOfOrder=true`.
--
-- Idempotente: ADD COLUMN IF NOT EXISTS (columna nueva NULL ya = "los 4",
-- sin backfill). COMMENT ON COLUMN reejecutable.
-- ===========================================================================

SET search_path TO academico_test, public;

ALTER TABLE academico_test.TROL_MENU
    ADD COLUMN IF NOT EXISTS SOLO_LECTURA VARCHAR(5);

COMMENT ON COLUMN academico_test.TROL_MENU.SOLO_LECTURA IS
    'Modo de concesion del menu por el rol. ''SI'' => el rol concede este menu SOLO para ver (crear/editar/eliminar = FALSE, ver = TRUE). NULL / ''NO'' / cualquier otro valor => el rol concede los 4 permisos (crear/editar/eliminar/ver = TRUE), comportamiento historico. Misma semantica de valores que TUSUARIO_ROL_PERMISO.SOLO_LECTURA, que sigue siendo el recorte fino por usuario. Lo escriben fn_associate_menus_to_rol (V123) y lo leen fn_list_menu_possibilities_for_rol (V113) y fn_usuario_permisos_menu (V185).';
