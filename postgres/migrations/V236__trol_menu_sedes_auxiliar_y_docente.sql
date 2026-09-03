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
-- Idempotente: no inserta si la fila ya existe.
-- =============================================================================

INSERT INTO academico_test.TROL_MENU (FK_TROL, FK_TMENU, CREATED_BY, CREATED_AT, ACTIVE)
SELECT v.rol, m.PK_TMENU, 'V236_seed', CURRENT_TIMESTAMP, TRUE
  FROM (VALUES (9::BIGINT), (14::BIGINT)) AS v(rol)
  JOIN academico_test.TMENU m
    ON m.CODIGO = 'SEDES_EDUCATIVAS'
   AND m.ACTIVE = TRUE
 WHERE NOT EXISTS (
       SELECT 1 FROM academico_test.TROL_MENU rm
        WHERE rm.FK_TROL  = v.rol
          AND rm.FK_TMENU = m.PK_TMENU
          AND rm.ACTIVE   = TRUE
   );
