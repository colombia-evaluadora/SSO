-- V562 -- Menu COMUNICACIONES: el item del sidebar para /app/comunicaciones/chat
-- Que hace: agrega una fila a TMENU (codigo COMUNICACIONES) y la concede a todo rol activo
--   que ya tenga algun menu.
-- Por que: el front solo deja abrir una ruta de /app si su URL viene en GET /eval-col/my-menus
--   (route-access.ts); sin este menu el chat muestra "Sin acceso" a todos. La bandeja de
--   notificaciones y /app/pendientes no lo necesitan: el front las abre a cualquier sesion.
-- A quien: el chat es para todos los perfiles (directivos, docentes, acudientes y estudiantes);
--   lo que cada uno puede hacer adentro lo decide la politica de chat de comms-service, no el
--   menu. Mismo reparto que el menu ASISTENTE (V557.3).
-- Idempotente: los dos INSERT van guardados por NOT EXISTS. El de TROL_MENU no mira ACTIVE:
--   no revive una concesion que se quito desde la pantalla de roles.

INSERT INTO academico_test.tmenu
    (codigo, fk_tmenu, nombre, url, icono, visible, orden, estado,
     active, created_by, created_at)
SELECT 'COMUNICACIONES', NULL, 'Comunicaciones', '/app/comunicaciones/chat', 'fas fa-comments',
       'S', 90, 'A', TRUE, 'V562', CURRENT_TIMESTAMP
 WHERE NOT EXISTS (SELECT 1 FROM academico_test.tmenu m WHERE m.codigo = 'COMUNICACIONES');

INSERT INTO academico_test.trol_menu (fk_trol, fk_tmenu, active, created_by, created_at)
SELECT r.pk_trol, c.pk_tmenu, TRUE, 'V562', CURRENT_TIMESTAMP
  FROM (SELECT DISTINCT t.pk_trol
          FROM academico_test.trol t
          JOIN academico_test.trol_menu tm ON tm.fk_trol = t.pk_trol AND tm.active = TRUE
         WHERE t.active = TRUE AND t.estado = 'A') r
 CROSS JOIN (SELECT pk_tmenu FROM academico_test.tmenu
              WHERE codigo = 'COMUNICACIONES' AND active = TRUE ORDER BY pk_tmenu LIMIT 1) c
 WHERE NOT EXISTS (SELECT 1 FROM academico_test.trol_menu x
                    WHERE x.fk_trol = r.pk_trol AND x.fk_tmenu = c.pk_tmenu);
