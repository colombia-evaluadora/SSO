-- =============================================================================
-- V231 -- Concede el menu MATRICULA a los roles administrativos de
-- establecimiento que le faltaban, como paso previo a migrar los gates del
-- modulo al modelo de permisos dinamicos (capability + scope, V29).
--
-- Hoy MATRICULA esta concedido solo a los roles 1 (super-admin) y 7 (rector).
-- Los roles 8 y 9 tienen unicamente COBERTURA_EDUCATIVA, que es el menu PADRE
-- del grupo, no la seccion. Con el gate viejo -- una allowlist fija de roles --
-- eso no importaba, porque el rol 8 estaba escrito a mano en cada funcion. Con
-- el gate nuevo la capability se resuelve por TROL_MENU, asi que sin estas dos
-- filas los 33 jefes de sistema y los 35 auxiliares administrativos quedarian
-- sin acceso al modulo.
--
--   rol 7  RECTOR                              ya lo tenia
--   rol 8  JEFE_SISTEMA_ESTABLECIMIENTO        se concede aca
--   rol 9  AUXILIAR_ADMINISTRATIVO             se concede aca
--
-- El rol 9 se incluye por decision de negocio: los auxiliares administrativos
-- que no son la secretaria del establecimiento tambien operan matricula. El
-- gate viejo no los contemplaba, asi que esto ENSANCHA el acceso -- es
-- deliberado, no un efecto colateral.
--
-- No se toca PRE_MATRICULA: es otra pantalla, de otro modulo, y quien decide
-- quien entra ahi es su dueño.
--
-- -----------------------------------------------------------------------------
-- Por que basta con esto y no hace falta sembrar nada mas
-- -----------------------------------------------------------------------------
-- Conceder es BINARIO. fn_usuario_permisos_menu (V185) NO lee
-- TROL_MENU.SOLO_LECTURA -- se comprueba en su codigo y en los datos: las 409
-- filas activas la tienen en NULL. Si existe la fila (rol, menu), ese rol
-- obtiene las cuatro acciones; el unico mecanismo de recorte es
-- TUSUARIO_ROL_PERMISO, por usuario, que se administra desde
-- PUT /funcionario/:ID/filtros-permiso (217) y son datos operativos, no
-- migracion.
--
-- Ademas, en esa misma funcion los tres flags de escritura salen del mismo
-- calculo:
--
--   puede_crear = puede_editar = puede_eliminar = bool_or(puede_editar_like)
--
-- Solo puede_ver se calcula aparte. Es decir que hoy distinguir CREAR de
-- EDITAR de ELIMINAR no cambia el resultado; se declara igual en los gates
-- para que el dia que separen los flags nuestras funciones ya esten correctas.
--
-- -----------------------------------------------------------------------------
-- Esto NO cambia ningun comportamiento todavia
-- -----------------------------------------------------------------------------
-- Los gates del modulo siguen siendo las allowlists fijas. Este seed solo deja
-- el modelo dinamico configurado para que, al migrarlos, el acceso quede igual
-- o mayor -- nunca menor. Y una vez migrados, el super-admin puede cambiarlo
-- desde la pantalla de roles (PUT /roles/:ROLEID/menus, 132) sin tocar codigo.
--
-- Idempotente: reactiva la fila apagada si existe, inserta si no hay ninguna.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Reactivacion: la pantalla de roles puede haber apagado estas filas
-- -----------------------------------------------------------------------------
-- La pantalla de roles del super-admin guarda el CONJUNTO completo de casillas
-- de un rol, asi que lo que se siembre por SQL y no quede marcado alli se
-- apaga en el siguiente guardado. Paso en el servidor con el rol 14 y SEDES_EDUCATIVAS (ver V236).
--
-- Un INSERT a secas no lo arregla: u_trol_menu_1 es un indice unico PARCIAL
-- --(fk_trol, fk_tmenu) WHERE active = true-- asi que una fila inactiva no lo
-- estorba y se crearia un duplicado en vez de recuperar el permiso. De ahi
-- este UPDATE previo, acotado a una sola fila por par para no violar el indice
-- si hubiera varias apagadas.
UPDATE academico_test.TROL_MENU
   SET ACTIVE = TRUE
 WHERE PK_TROL_MENU IN (
       SELECT MAX(rm.PK_TROL_MENU)
         FROM academico_test.TROL_MENU rm
         JOIN academico_test.TMENU m
           ON m.PK_TMENU = rm.FK_TMENU
          AND m.ACTIVE   = TRUE
         JOIN (VALUES
                   (8::BIGINT, 'MATRICULA'),
                   (9::BIGINT, 'MATRICULA')
              ) AS v(rol, codigo_menu)
           ON v.rol = rm.FK_TROL
          AND v.codigo_menu = m.CODIGO
        WHERE rm.ACTIVE = FALSE
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
SELECT v.rol, m.PK_TMENU, 'V231_seed', CURRENT_TIMESTAMP, TRUE
  FROM (VALUES (8::BIGINT), (9::BIGINT)) AS v(rol)
  JOIN academico_test.TROL r
    ON r.PK_TROL = v.rol
  CROSS JOIN academico_test.TMENU m
 WHERE m.CODIGO = 'MATRICULA'
   AND m.ACTIVE = TRUE
   AND NOT EXISTS (
       SELECT 1 FROM academico_test.TROL_MENU rm
        WHERE rm.FK_TROL = v.rol
          AND rm.FK_TMENU = m.PK_TMENU
          AND rm.ACTIVE = TRUE
   );
