-- ===========================================================================
-- V331 - Menu INFORMES: la seccion bajo la que viven consolidacion y boletin.
--
-- POR QUE HACE FALTA
--   fn_assert_permiso_seccion resuelve el modulo por TMENU.CODIGO, y no hay
--   ningun codigo que corresponda a esta vista. Los que existen son de otra
--   generacion (P30, P30H31 "Informes y constancias", P30H205 "Informes -
--   constancias"), del arbol viejo que se numeraba P<padre>H<hijo>; los
--   modulos nuevos usan codigos parlantes -- MATRICULA, PRE_MATRICULA,
--   PLANEADOR, ASISTENCIAS -- y este sigue esa familia.
--
--   Sin el menu, toda funcion de este modulo responderia 42501 -> 403 a
--   cualquiera que no sea super admin, incluido el rector. No es una mejora
--   opcional: es lo que hace que lo demas sea ejecutable.
--
-- A QUIEN SE LE CONCEDE
--   A los mismos tres roles que hoy tienen PLANEADOR (menu 904): Super
--   Administrador (1), Rector (7) y Docente (14). Es el reparto correcto para
--   esta vista -- el docente califica y revisa el seguimiento de su grupo, el
--   rector consolida y firma el boletin -- y ademas evita inventar un criterio
--   nuevo: si alguien puede planear y calificar, puede ver el informe de lo
--   que califico.
--
--   SOLO_LECTURA se deja en NULL, que segun fn_usuario_permisos_menu (rama
--   normal, columna agregada por V99) concede los cuatro permisos. Afinar por
--   rol -- por ejemplo que el docente no pueda ELIMINAR -- es una decision de
--   negocio que se toma desde la pantalla de roles, no cableada aqui.
--
-- LO QUE NO TOCA
--   No modifica ningun menu existente ni ninguna concesion previa. Solo
--   agrega una fila a TMENU y tres a TROL_MENU.
--
-- Idempotente: los dos INSERT van guardados por NOT EXISTS.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 1. El menu.
--
--    PK_TMENU es IDENTITY, asi que no se fija a mano. VISIBLE y ESTADO son
--    NOT NULL sin default y van con los mismos valores que todo menu vivo
--    ('S' / 'A').
--
--    El padre se toma de PLANEADOR en vez de escribirse a mano: hoy es
--    "Gestion Academica" (898), que es donde corresponde, pero ese nombre
--    lleva tildes en el CODIGO y fijarlo por literal seria fragil. Si
--    PLANEADOR no estuviera, el menu queda en la raiz -- degradado, no roto.
-- ---------------------------------------------------------------------------
INSERT INTO academico_test.TMENU
    (NOMBRE, CODIGO, VISIBLE, ESTADO, URL, FK_TMENU, ORDEN,
     CREATED_BY, CREATED_AT, ACTIVE)
SELECT 'Informes',
       'INFORMES',
       'S',
       'A',
       '/app/gestion-academica/informes',
       (SELECT p.FK_TMENU
          FROM academico_test.TMENU p
         WHERE p.CODIGO = 'PLANEADOR' AND p.ACTIVE = TRUE
         ORDER BY p.PK_TMENU DESC
         LIMIT 1),
       1,
       'V331',
       CURRENT_TIMESTAMP,
       TRUE
 WHERE NOT EXISTS (
           SELECT 1 FROM academico_test.TMENU m WHERE m.CODIGO = 'INFORMES'
       );


-- ---------------------------------------------------------------------------
-- 2. Las concesiones, copiadas de quien ya tiene PLANEADOR.
--
--    Se listan los roles por PK y no por nombre: los nombres se editan desde
--    la pantalla de roles, los PK no.
-- ---------------------------------------------------------------------------
INSERT INTO academico_test.TROL_MENU (FK_TROL, FK_TMENU, CREATED_BY, CREATED_AT, ACTIVE)
SELECT r.pk_trol,
       (SELECT m.PK_TMENU FROM academico_test.TMENU m WHERE m.CODIGO = 'INFORMES'),
       'V331',
       CURRENT_TIMESTAMP,
       TRUE
  FROM (VALUES (1::BIGINT), (7::BIGINT), (14::BIGINT)) AS r(pk_trol)
 WHERE EXISTS (
           SELECT 1 FROM academico_test.TROL t WHERE t.PK_TROL = r.pk_trol
       )
   AND NOT EXISTS (
           SELECT 1
             FROM academico_test.TROL_MENU rm
             JOIN academico_test.TMENU m ON m.PK_TMENU = rm.FK_TMENU
            WHERE m.CODIGO   = 'INFORMES'
              AND rm.FK_TROL = r.pk_trol
       );
