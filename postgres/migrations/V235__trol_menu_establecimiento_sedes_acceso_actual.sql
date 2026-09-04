-- =============================================================================
-- V235 -- Concede los menus ESTABLECIMIENTO y SEDES_EDUCATIVAS a los roles que
-- HOY ya tienen acceso por el gate fijo, como paso previo a migrar los selects
-- de opciones al modelo dinamico.
--
-- Mismo procedimiento que V231 hizo con MATRICULA: primero se siembra la
-- capability, despues se gira el gate. En ese orden el acceso queda igual o
-- mayor, nunca menor.
--
-- -----------------------------------------------------------------------------
-- Que permite el gate fijo hoy, medido contra la base
-- -----------------------------------------------------------------------------
-- Se probo fn_est_listar_todos y fn_sed_listar_todos con un usuario real de
-- cada rol:
--
--   rol  1  super admin           66 establecimientos / 200 sedes
--   rol  7  rector                 1 / 4
--   rol  8  jefe de sistema        1 / 4
--   rol  9  auxiliar admin        42501 / 42501
--   rol 11  coordinador           42501 /  1     <- solo sedes
--   rol 14  docente               42501 / 42501
--   rol 16  acudiente             42501 / 42501
--
-- Y los roles 2 y 3 (territoriales) entraban por el fast-path de
-- fn_puede_afectar_establecimiento, que es exactamente FK_TROL IN (1,2,3).
--
-- De ahi sale que hay que conceder:
--
--   ESTABLECIMIENTO    -> roles 2, 3, 8      (el 1 y el 7 ya lo tienen)
--   SEDES_EDUCATIVAS   -> roles 2, 3, 8, 11  (idem)
--
-- El rol 9 NO se incluye: el gate fijo le daba 42501 en las dos secciones, y
-- concederselo seria ensanchar el acceso sin que nadie lo haya pedido. En
-- matricula si se incluyo, pero porque fue una decision explicita de negocio
-- (V231). Si despues se quiere aca, se agrega desde la pantalla de roles del
-- super-admin sin tocar codigo -- que es justamente lo que este cambio habilita.
--
-- El rol 11 entra SOLO en SEDES_EDUCATIVAS, no en ESTABLECIMIENTO, replicando
-- lo que hacia la REV1 de fn_sed_listar_todos: el coordinador podia ver su sede
-- en el select pero no el establecimiento.
--
-- -----------------------------------------------------------------------------
-- Relacion con la V118 de la rama de permisos
-- -----------------------------------------------------------------------------
-- V118 (CU-86e2w4xdt) hace un seed equivalente y mas amplio -- producto
-- cartesiano de 5 roles x 7 menus -- pero no esta aplicada en el servidor. Esta
-- migracion no la reemplaza ni la estorba: siembra solo lo que hace falta para
-- que los dos selects de opciones no pierdan acceso, y al ser idempotente
-- convive con V118 cuando esa rama entre.
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
                   (2::BIGINT, 'ESTABLECIMIENTO'),
                   (3::BIGINT, 'ESTABLECIMIENTO'),
                   (8::BIGINT, 'ESTABLECIMIENTO'),
                   (2::BIGINT, 'SEDES_EDUCATIVAS'),
                   (3::BIGINT, 'SEDES_EDUCATIVAS'),
                   (8::BIGINT, 'SEDES_EDUCATIVAS'),
                   (11::BIGINT, 'SEDES_EDUCATIVAS')
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
SELECT v.rol, m.PK_TMENU, 'V235_seed', CURRENT_TIMESTAMP, TRUE
  FROM (VALUES
            (2::BIGINT, 'ESTABLECIMIENTO'),
            (3::BIGINT, 'ESTABLECIMIENTO'),
            (8::BIGINT, 'ESTABLECIMIENTO'),
            (2::BIGINT, 'SEDES_EDUCATIVAS'),
            (3::BIGINT, 'SEDES_EDUCATIVAS'),
            (8::BIGINT, 'SEDES_EDUCATIVAS'),
            (11::BIGINT, 'SEDES_EDUCATIVAS')
       ) AS v(rol, codigo_menu)
  JOIN academico_test.TROL r
    ON r.PK_TROL = v.rol
  JOIN academico_test.TMENU m
    ON m.CODIGO = v.codigo_menu
   AND m.ACTIVE = TRUE
 WHERE NOT EXISTS (
       SELECT 1 FROM academico_test.TROL_MENU rm
        WHERE rm.FK_TROL  = v.rol
          AND rm.FK_TMENU = m.PK_TMENU
          AND rm.ACTIVE   = TRUE
   );
