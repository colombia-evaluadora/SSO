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
-- Idempotente: no inserta si la fila ya existe.
-- =============================================================================

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
  JOIN academico_test.TMENU m
    ON m.CODIGO = v.codigo_menu
   AND m.ACTIVE = TRUE
 WHERE NOT EXISTS (
       SELECT 1 FROM academico_test.TROL_MENU rm
        WHERE rm.FK_TROL  = v.rol
          AND rm.FK_TMENU = m.PK_TMENU
          AND rm.ACTIVE   = TRUE
   );
