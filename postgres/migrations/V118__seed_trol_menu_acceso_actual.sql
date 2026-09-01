-- ===========================================================================
-- V118 — Seed de TROL_MENU: preserva el acceso que los roles tienen HOY de
-- facto a Establecimiento / Sedes / Funcionarios / Periodos Academicos /
-- Matricula.
--
-- CU-86e2w4xdt — Permisos segun rol.
-- Especificacion: docs/gate-permisos-por-menu-analysis.md §3.5 y §5.
--
-- -------------------------------------------------------------------------
-- POR QUE EXISTE ESTA MIGRACION
--
--   La autorizacion de esas cuatro secciones se esta moviendo de allowlists
--   fijas de numero de rol (FK_TROL IN (1,2,3), IN (1,2,3,7,8,9), ...)
--   hacia la CAPABILITY POR MENU que resuelve
--   academico_test.fn_usuario_permisos_menu(PK_TUSUARIO) (V185) a partir de
--   TROL_MENU (concesion del rol, V22 + SOLO_LECTURA de V99) recortada por
--   TUSUARIO_ROL_PERMISO (restriccion por usuario).
--
--   Consecuencia directa de ese cambio: un rol SIN fila activa en TROL_MENU
--   para un menu PIERDE el acceso a esa seccion — fn_usuario_permisos_menu
--   no devuelve el menu, y el gate nuevo responde 42501 (HTTP 403).
--
--   Este seed es la red de seguridad del despliegue: siembra el acceso que
--   los roles ya ejercen hoy, para que el cambio de modelo tenga CERO
--   REGRESIONES el dia que entre. No concede nada nuevo; solo materializa
--   en datos lo que hasta ahora estaba escrito a mano en cada funcion.
--
-- -------------------------------------------------------------------------
-- QUE SIEMBRA
--
--   Producto cartesiano de 5 roles x 7 menus = 35 filas en TROL_MENU, todas
--   con SOLO_LECTURA = NULL (semantica de V99: NULL => el rol concede los
--   CUATRO permisos crear/editar/eliminar/ver) y ACTIVE = TRUE.
--
--   MATRICULA (+ su grupo padre COBERTURA_EDUCATIVA) se añade en el mismo
--   producto: hoy la seccion de matricula la ejercen los mismos roles de
--   establecimiento/territoriales (fn_puede_afectar_establecimiento + rector/
--   secretaria por puntero + jefe de sistema rol 8, ver V159-V166). Se
--   incluye AUXILIAR_ADMINISTRATIVO en MATRICULA aunque el gate viejo de
--   matricula_crear no lo listaba: ya podia editar estudiante/acudiente
--   (fn_puede_afectar_usuarios) y darle el alta de matricula es coherente
--   con su rol; es un ensanche minimo y deliberado, no una regresion.
--
--   Roles (resueltos por TROL.CODIGO, nunca por pk literal — el pk numerico
--   varia por entorno):
--     RECTOR, JEFE_SISTEMA_ESTABLECIMIENTO, AUXILIAR_ADMINISTRATIVO
--       -> categoria ADMINISTRATIVOS_ESTABLECIMIENTO (V120). Hoy pasan los
--          gates de est/sed/fun/periodos via fn_puede_afectar_* y los
--          bloques "ee_accesibles" inline de V51/V52/V53/V72.
--     DIRECTOR_ENTE_TERRITORIAL, JEFE_SISTEMA_ENTE_TERRITORIAL
--       -> categoria ADMINISTRATIVOS_TERRITORIALES. Hoy son el
--          FK_TROL IN (1,2,3) de fn_puede_afectar_establecimiento y el
--          IN (1,2,3,7,8,9) de fn_periodo_usuario_puede_gestionar.
--
--   Menus (resueltos por TMENU.CODIGO, sembrados en V113):
--     ESTABLECIMIENTO_EDUCATIVO  (grupo padre, fk_tmenu IS NULL)
--     ESTABLECIMIENTO, SEDES_EDUCATIVAS, FUNCIONARIOS, PERIODOS_ACADEMICOS
--     COBERTURA_EDUCATIVA        (grupo padre de Matricula, fk_tmenu IS NULL)
--     MATRICULA
--
-- -------------------------------------------------------------------------
-- POR QUE SE INCLUYE EL MENU PADRE 'ESTABLECIMIENTO_EDUCATIVO'
--
--   Para AUTORIZAR no hace falta: el gate solo pregunta por los codigos
--   hijos (fn_assert_permiso_seccion recibe 'ESTABLECIMIENTO' /
--   'SEDES_EDUCATIVAS' / 'FUNCIONARIOS' / 'PERIODOS_ACADEMICOS'), nunca por
--   el grupo. Sembrarlo NO concede ningun permiso extra: no hay ninguna
--   funcion que consulte la capability del codigo del grupo.
--
--   Se incluye igualmente por dos razones concretas:
--
--     1) INVARIANTE DE JERARQUIA de fn_associate_menus_to_rol (V113/V123).
--        En modo p_full_replace = TRUE — que es exactamente el modo que usa
--        PUT /roles/{roleId}/menus, la pantalla con la que el super admin
--        administra esto de aqui en adelante — la funcion RECHAZA con
--        ERRCODE 22023 cualquier payload que traiga un submenu sin su menu
--        padre incluido. Si el seed dejara los 4 hijos huerfanos, el primer
--        GET /roles/{id}/menus + PUT de vuelta (guardar sin cambios) sobre
--        cualquiera de estos 5 roles fallaria con 400. El seed tiene que
--        producir un estado que la propia API considere valido.
--
--     2) ARBOL DEL FRONT. El menu lateral se pinta agrupado (grupo -> hijos);
--        es la misma convencion que sigue el seed del arbol del
--        SUPER_ADMINISTRADOR en V113 bloque (C), que asocia grupos E hijos.
--
-- -------------------------------------------------------------------------
-- QUE **NO** SIEMBRA, Y POR QUE
--
--   * SUPER_ADMINISTRADOR — no lo necesita: es el bypass (paso 0 del gate,
--     antes de mirar capability ni scope). Ademas V113 bloque (C) ya le
--     asocia el arbol COMPLETO de menus para la navegacion.
--   * Categoria ADMINISTRATIVOS_SEDES (PSICO_ORIENTADOR, COORDINADOR,
--     JEFE_AREA, DIRECTOR_GRUPO, DOCENTE) — arrancan SIN acceso.
--   * JEFE_AREA_PLANEACION / _COBERTURA / _CALIDAD — idem.
--   * ESTUDIANTE / ACUDIENTE — no participan de estas secciones.
--
--   Para todos ellos la decision es de negocio, no de migracion: se les
--   concede desde la UI de roles y menus cuando se decida, sin tocar SQL.
--
-- -------------------------------------------------------------------------
-- A PARTIR DE AQUI, LA ADMINISTRACION ES DEL SUPER ADMIN
--
--   Este archivo fija UNICAMENTE el estado inicial. Todo cambio posterior
--   (conceder un menu a un rol, quitarselo, o degradarlo a solo lectura con
--   SOLO_LECTURA='SI') se hace con PUT /roles/{roleId}/menus ->
--   fn_associate_menus_to_rol (V123), y el recorte fino por usuario con los
--   endpoints de V199 (TUSUARIO_ROL_PERMISO). NO se debe volver a tocar
--   TROL_MENU desde migraciones: se pisaria la configuracion operativa.
--
-- -------------------------------------------------------------------------
-- NOTAS TECNICAS
--
--   * NADA DE ON CONFLICT. El indice unico de TROL_MENU es PARCIAL desde
--     V71: u_trol_menu_1 ON trol_menu (fk_trol, fk_tmenu) WHERE active =
--     true. PostgreSQL no infiere un indice parcial salvo que el statement
--     repita su predicado, asi que un ON CONFLICT (fk_trol, fk_tmenu) aqui
--     reventaria con 42P10 — es literalmente el bug que V123 documenta y
--     arregla en fn_associate_menus_to_rol. Se usa el mismo patron que V113
--     bloque (C): INSERT ... SELECT con NOT EXISTS sobre el par
--     (FK_TROL, FK_TMENU).
--
--   * El NOT EXISTS mira el par SIN filtrar por ACTIVE, a proposito: si un
--     administrador ya le habia quitado el menu a un rol (fila soft-deleted,
--     ACTIVE=FALSE), esta migracion NO se lo devuelve ni inserta una fila
--     duplicada. El seed solo actua donde no hay historia previa. Es tambien
--     lo que hace que reejecutarlo sea inofensivo.
--
--   * ORDEN_ROL (columna añadida por V113): 1..7 fijos, tomados de la lista
--     de abajo — grupo padre primero y luego sus hijos en el mismo orden que
--     tienen en el catalogo TMENU (ESTABLECIMIENTO 1, SEDES 2, FUNCIONARIOS
--     3, PERIODOS 4, segun V113 bloque (B); luego el grupo COBERTURA_EDUCATIVA
--     y su hijo MATRICULA). Es la misma semantica que
--     escribe fn_associate_menus_to_rol ("posicion 1-based dentro del
--     payload") y el mismo criterio de ordenacion (padre antes que hijos,
--     luego TMENU.ORDEN) del seed de V113 bloque (C). Se dejan LITERALES en
--     vez de un ROW_NUMBER() porque asi el orden no depende de cuantas filas
--     filtro el NOT EXISTS en una aplicacion parcial.
--
--   * Si en un entorno faltara alguno de los TROL o TMENU esperados, los
--     JOIN por CODIGO simplemente no producen esa fila: la migracion no
--     falla. El RAISE NOTICE final deja constancia de cuantas se sembraron
--     (0 en una reejecucion; 35 en una instalacion limpia y completa).
--
--   * CREATED_BY = 'V118_seed' — marcador rastreable, mismo estilo que el
--     'V59_seed' de V113. Permite auditar despues que filas puso la
--     migracion y cuales creo un administrador desde la UI.
-- ===========================================================================

SET search_path TO academico_test, public;

DO $$
DECLARE
    v_insertadas INTEGER;
BEGIN
    INSERT INTO academico_test.trol_menu (
        fk_trol, fk_tmenu, orden_rol, solo_lectura, active, created_by
    )
    SELECT r.pk_trol,
           m.pk_tmenu,
           men.orden_rol,
           NULL,          -- SOLO_LECTURA NULL => los 4 permisos (V99).
           TRUE,
           'V118_seed'
      FROM (VALUES
                ('RECTOR'),
                ('JEFE_SISTEMA_ESTABLECIMIENTO'),
                ('AUXILIAR_ADMINISTRATIVO'),
                ('DIRECTOR_ENTE_TERRITORIAL'),
                ('JEFE_SISTEMA_ENTE_TERRITORIAL')
           ) AS rol(codigo)
      CROSS JOIN (VALUES
                ('ESTABLECIMIENTO_EDUCATIVO', 1::NUMERIC),   -- grupo padre
                ('ESTABLECIMIENTO',           2::NUMERIC),
                ('SEDES_EDUCATIVAS',          3::NUMERIC),
                ('FUNCIONARIOS',              4::NUMERIC),
                ('PERIODOS_ACADEMICOS',       5::NUMERIC),
                ('COBERTURA_EDUCATIVA',       6::NUMERIC),   -- grupo padre de Matricula
                ('MATRICULA',                 7::NUMERIC)
           ) AS men(codigo, orden_rol)
      JOIN academico_test.trol r
        ON r.codigo = rol.codigo
       AND r.active = TRUE
      JOIN academico_test.tmenu m
        ON m.codigo = men.codigo
       AND m.active = TRUE
     WHERE NOT EXISTS (
               SELECT 1
                 FROM academico_test.trol_menu tm
                WHERE tm.fk_trol  = r.pk_trol
                  AND tm.fk_tmenu = m.pk_tmenu
           );

    GET DIAGNOSTICS v_insertadas = ROW_COUNT;

    RAISE NOTICE 'V118_seed: % fila(s) insertadas en academico_test.trol_menu (esperadas 35 en instalacion limpia, 0 al reejecutar).', v_insertadas;
END;
$$;
