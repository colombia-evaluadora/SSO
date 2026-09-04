-- =============================================================================
-- V236 -- Concede el menu SEDES_EDUCATIVAS al auxiliar administrativo (rol 9) y
-- al docente (rol 14), por decision de negocio.
--
--   rol  9  AUXILIAR_ADMINISTRATIVO   -- un auxiliar que no es la secretaria
--                                        general tambien opera sedes
--   rol 14  DOCENTE                   -- necesita listar las opciones de sede
--                                        para otro modulo
--
-- A diferencia de V235, que solo replicaba el acceso que ya daba el gate fijo,
-- esto lo ENSANCHA a proposito: con el gate viejo los dos recibian 42501.
--
-- -----------------------------------------------------------------------------
-- Que alcance le da a cada uno, y por que no es el mismo
-- -----------------------------------------------------------------------------
-- La capability abre la puerta; el ALCANCE lo decide la categoria del rol, que
-- es estructural y no se configura (fn_usuario_sedes_lectura, V29):
--
--   rol 14  DOCENTE          categoria ADMINISTRATIVOS_SEDES, nivel 3
--                            -> SOLO sus propias sedes.
--                            Es exactamente lo pedido. Medido: de los 1.166
--                            docentes, los de nivel 3 ven tantas sedes como
--                            permisos tienen, ni una mas.
--
--   rol  9  AUXILIAR         categoria ADMINISTRATIVOS_ESTABLECIMIENTO, nivel 2
--                            -> TODAS las sedes de su establecimiento, no solo
--                            aquella donde tiene el permiso.
--
-- Esa diferencia hay que tenerla presente: se pidio que el auxiliar alcance "esa
-- sede especifica", y el modelo le da el establecimiento completo. Medido sobre
-- los 36 auxiliares: p.ej. el usuario 120709 tiene 1 sede propia y alcanza 10.
--
-- No se corrige aca a proposito. Acotar al rol 9 a sus sedes exigiria o bien
-- escribir una rama especial para ese rol dentro de la funcion --justo el
-- hardcodeo de roles que este trabajo esta quitando-- o bien reclasificar el
-- rol 9 a nivel 3 en CATEGORIA_ROL, que es tabla del modelo de permisos y
-- afectaria a TODOS los modulos, no solo a sedes. Lo segundo es lo correcto si
-- el negocio lo confirma, y es conversacion con el dueño de ese modelo.
--
-- Nota sobre los docentes con varios roles: fn_usuario_categoria_rol_nivel toma
-- el nivel MAS ALTO de todos sus roles activos, asi que un docente que ademas
-- es rector alcanza como rector. Es correcto -- lo es -- pero explica por que
-- unos pocos docentes veran mas sedes que las suyas (hay uno de nivel 1 que
-- alcanza las 200).
--
-- -----------------------------------------------------------------------------
-- Ojo: esta concesion la puede apagar la pantalla de roles
-- -----------------------------------------------------------------------------
-- Paso en el servidor. Esta migracion inserto la fila del rol 14 a las 03:14 y
-- a las 03:46 y 03:52 la pantalla de roles del super-admin guardo los permisos
-- de ese rol y la dejo en ACTIVE = FALSE. Esa pantalla escribe el CONJUNTO
-- completo de casillas del rol, asi que todo lo que se haya sembrado por SQL y
-- no este marcado en el formulario se apaga en el siguiente guardado.
--
-- Es coherente con el modelo --la pantalla es la fuente de verdad-- pero
-- significa que sembrar por migracion sirve para no perder acceso durante el
-- despliegue, no para fijar una politica. Lo durable es marcar la casilla
-- "Sedes Educativas" en el rol Docente desde la interfaz.
--
-- Por eso el bloque de abajo REACTIVA si la fila existe apagada, en vez de
-- limitarse a insertar: el indice unico u_trol_menu_1 es parcial
-- (fk_trol, fk_tmenu) WHERE active = true, asi que una fila inactiva no lo
-- estorba y un INSERT a secas crearia un duplicado en vez de arreglar nada.
--
-- Idempotente: reactiva la fila apagada si existe, inserta si no hay ninguna.
-- =============================================================================

-- Reactiva a lo sumo UNA fila por (rol, menu) -- la mas reciente. Si hubiera
-- varias apagadas para el mismo par, encenderlas todas violaria u_trol_menu_1.
UPDATE academico_test.TROL_MENU
   SET ACTIVE = TRUE
 WHERE PK_TROL_MENU IN (
       SELECT MAX(rm.PK_TROL_MENU)
         FROM academico_test.TROL_MENU rm
         JOIN academico_test.TMENU m
           ON m.PK_TMENU = rm.FK_TMENU
          AND m.CODIGO   = 'SEDES_EDUCATIVAS'
          AND m.ACTIVE   = TRUE
        WHERE rm.FK_TROL IN (9, 14)
          AND rm.ACTIVE   = FALSE
          AND NOT EXISTS (
              SELECT 1 FROM academico_test.TROL_MENU rm2
               WHERE rm2.FK_TROL  = rm.FK_TROL
                 AND rm2.FK_TMENU = rm.FK_TMENU
                 AND rm2.ACTIVE   = TRUE
          )
        GROUP BY rm.FK_TROL, rm.FK_TMENU
   );

-- -----------------------------------------------------------------------------
-- Por que la siembra resuelve el rol contra TROL en vez de usar el numero
-- -----------------------------------------------------------------------------
-- Las filas de TROL no las crea ninguna migracion: V59 solo define la funcion
-- de alta de roles, y los roles concretos se dan de alta por la aplicacion. En
-- una base recien creada TROL esta vacia, asi que insertar TROL_MENU con el
-- numero de rol a pelo revienta contra fk_trol_menu_1:
--
--   ERROR: insert or update on table "trol_menu" violates foreign key
--          constraint "fk_trol_menu_1"
--   Detail: Key (fk_trol)=(8) is not present in table "trol".
--
-- Eso es exactamente lo que rompio el job flyway-migrations del CI, que aplica
-- el historial completo sobre un Postgres limpio. En el servidor no se noto
-- porque los roles ya existian.
--
-- El JOIN contra TROL hace que la siembra no aporte filas cuando el rol no
-- existe todavia, en vez de abortar la migracion. Es el mismo criterio que ya
-- se usaba para el menu, que se resuelve por CODIGO y no por PK.
-- -----------------------------------------------------------------------------

INSERT INTO academico_test.TROL_MENU (FK_TROL, FK_TMENU, CREATED_BY, CREATED_AT, ACTIVE)
SELECT v.rol, m.PK_TMENU, 'V236_seed', CURRENT_TIMESTAMP, TRUE
  FROM (VALUES (9::BIGINT), (14::BIGINT)) AS v(rol)
  JOIN academico_test.TROL r
    ON r.PK_TROL = v.rol
  JOIN academico_test.TMENU m
    ON m.CODIGO = 'SEDES_EDUCATIVAS'
   AND m.ACTIVE = TRUE
 WHERE NOT EXISTS (
       SELECT 1 FROM academico_test.TROL_MENU rm
        WHERE rm.FK_TROL  = v.rol
          AND rm.FK_TMENU = m.PK_TMENU
          AND rm.ACTIVE   = TRUE
   );
