-- V564 -- Menu FOROS: el item del sidebar para /app/comunicaciones/foros
-- Que hace: agrega una fila a TMENU (codigo FOROS) y la concede a todo rol que ya tenga
--   el menu COMUNICACIONES (V562).
-- Por que: el front solo abre una ruta de /app si su URL viene en GET /eval-col/my-menus;
--   quien entra a los foros y que puede hacer adentro lo decide comms-service (membresia
--   del canal y politica de foros), no el menu.
-- Idempotente: los dos INSERT van guardados por NOT EXISTS; el de TROL_MENU no mira ACTIVE
--   para no revivir una concesion quitada desde la pantalla de roles.

INSERT INTO academico_test.tmenu
    (codigo, fk_tmenu, nombre, url, icono, visible, orden, estado,
     active, created_by, created_at)
SELECT 'FOROS', NULL, 'Foros', '/app/comunicaciones/foros', 'fas fa-comments',
       'S', 91, 'A', TRUE, 'V564', CURRENT_TIMESTAMP
 WHERE NOT EXISTS (SELECT 1 FROM academico_test.tmenu m WHERE m.codigo = 'FOROS');

INSERT INTO academico_test.trol_menu (fk_trol, fk_tmenu, active, created_by, created_at)
SELECT r.fk_trol, f.pk_tmenu, TRUE, 'V564', CURRENT_TIMESTAMP
  FROM (SELECT DISTINCT tm.fk_trol
          FROM academico_test.trol_menu tm
          JOIN academico_test.tmenu c ON c.pk_tmenu = tm.fk_tmenu
         WHERE c.codigo = 'COMUNICACIONES' AND tm.active = TRUE) r
 CROSS JOIN (SELECT pk_tmenu FROM academico_test.tmenu
              WHERE codigo = 'FOROS' AND active = TRUE ORDER BY pk_tmenu LIMIT 1) f
 WHERE NOT EXISTS (SELECT 1 FROM academico_test.trol_menu x
                    WHERE x.fk_trol = r.fk_trol AND x.fk_tmenu = f.pk_tmenu);
