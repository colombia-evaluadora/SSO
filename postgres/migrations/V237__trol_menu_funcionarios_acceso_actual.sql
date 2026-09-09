-- =============================================================================
-- V237 -- Concede el menu FUNCIONARIOS a los roles que HOY ya tienen acceso por
-- el gate fijo, como paso previo a migrar los listados y el detalle de
-- funcionarios al modelo dinamico de permisos.
--
-- Mismo procedimiento que V231 con MATRICULA y V235 con ESTABLECIMIENTO /
-- SEDES_EDUCATIVAS: primero se siembra la capability, despues se gira el gate.
-- En ese orden el acceso queda igual o mayor, nunca menor.
--
-- -----------------------------------------------------------------------------
-- Que permite el gate fijo hoy, medido contra la base
-- -----------------------------------------------------------------------------
-- Se probaron las tres funciones con un usuario real de cada rol, tomando
-- siempre uno cuyo nivel de categoria coincide con el del rol (para que no lo
-- "suba" un segundo rol mas alto):
--
--   rol      fn_usu_empleados_contar   fn_usu_empleado_buscar_por_pk
--    1  super admin        1631                 ok
--    3  jefe sist ET       1631                 ok      (idem rol 2)
--    7  rector                6                 ok
--    8  jefe sist EE          6                 ok
--    9  auxiliar          42501                 ok      <-- asimetrico
--   11  coordinador          26                 ok
--   14  docente           42501               42501
--   16  acudiente         42501               42501
--
-- De ahi sale que hay que conceder FUNCIONARIOS a los roles 2, 3, 8, 9 y 11
-- (el 1 y el 7 ya lo tenian sembrado desde V59).
--
-- Los roles 2 y 3 entraban por el fast-path de fn_puede_afectar_establecimiento
-- (FK_TROL IN (1,2,3)); el 2 se incluye por simetria con el 3 aunque no haya en
-- la base ningun usuario "puro" de ese rol con el que medirlo.
--
-- Los roles 14 y 16 NO se incluyen: el gate fijo les daba 42501 en las tres, y
-- concederselo seria ensanchar sin que nadie lo haya pedido. Si mas adelante se
-- quiere, se agrega desde la pantalla de roles del super-admin sin tocar SQL --
-- que es justamente lo que este cambio habilita.
--
-- -----------------------------------------------------------------------------
-- El rol 9, y el unico ensanchamiento que introduce esta migracion
-- -----------------------------------------------------------------------------
-- El auxiliar administrativo es el caso asimetrico de la tabla: NO podia listar
-- ni contar funcionarios, pero SI podia abrir la ficha de uno. No es un
-- descuido, viene de que el detalle usa otro helper --fn_puede_afectar_usuarios,
-- cuyo comentario en V50 dice literalmente "el rol 9 es exclusivo de usuarios"--
-- y el listado usa fn_puede_afectar_establecimiento, que no lo incluye.
--
-- Con una sola capability por menu no se pueden conservar las dos mitades: hay
-- que elegir. Se concede, y por tanto el rol 9 gana el listado de funcionarios
-- de SU establecimiento. La alternativa --no concederlo-- le quitaria el
-- detalle, y eso rompe un flujo documentado y arreglado a proposito: el
-- autocompletado por documento del alta de funcionario (findPersonByDocument
-- -> GET por PK), que es justo lo que la REV5 de fn_usu_empleado_buscar_por_pk
-- vino a reparar. Perder acceso pesa mas que ganar un listado que, para un
-- auxiliar administrativo de ese mismo establecimiento, es coherente.
--
-- Aparte de eso, el giro del gate no mueve el acceso de nadie mas.
--
-- Nota de alcance, la misma que ya se anoto en V236: la capability abre la
-- puerta, pero el ALCANCE lo decide la categoria del rol, que es estructural y
-- no se configura. El rol 9 es nivel 2 (ADMINISTRATIVOS_ESTABLECIMIENTO), asi
-- que recibe su establecimiento completo y no solo la sede donde tiene el
-- permiso. Acotarlo exigiria reclasificarlo a nivel 3 en CATEGORIA_ROL, que
-- afecta a TODOS los modulos y es conversacion con el dueño de ese modelo.
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
                   (2::BIGINT, 'FUNCIONARIOS'),
                   (3::BIGINT, 'FUNCIONARIOS'),
                   (8::BIGINT, 'FUNCIONARIOS'),
                   (9::BIGINT, 'FUNCIONARIOS'),
                   (11::BIGINT, 'FUNCIONARIOS')
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
SELECT v.rol, m.PK_TMENU, 'V237_seed', CURRENT_TIMESTAMP, TRUE
  FROM (VALUES (2::BIGINT), (3::BIGINT), (8::BIGINT), (9::BIGINT), (11::BIGINT)) AS v(rol)
  JOIN academico_test.TROL r
    ON r.PK_TROL = v.rol
  JOIN academico_test.TMENU m
    ON m.CODIGO = 'FUNCIONARIOS'
   AND m.ACTIVE = TRUE
 WHERE NOT EXISTS (
       SELECT 1 FROM academico_test.TROL_MENU rm
        WHERE rm.FK_TROL  = v.rol
          AND rm.FK_TMENU = m.PK_TMENU
          AND rm.ACTIVE   = TRUE
   );
