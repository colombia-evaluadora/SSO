-- ===========================================================================
-- V50 — Utilities academicas (foundations).
--
-- Convencion: las funciones de uso transversal a los modulos academicos
-- (establecimiento, sede, funcionarios, periodos, etc.) viven en este
-- archivo, antes de cualquier modulo de negocio. Cualquier migracion
-- posterior puede depender de las funciones aqui definidas.
--
-- Alcance de esta entrega:
--   Tres gates de autorizacion jerarquicos, todos STABLE LANGUAGE sql para
--   que el planner los inlinee en predicados. La jerarquia refleja
--   cuanto modulo puede ver/afectar un usuario:
--
--   * fn_puede_afectar_establecimiento(p_pk_usuario BIGINT)
--       TRUE si el usuario tiene rol 1, 2 o 3 en al menos una TSEDE_USUARIO
--       activa. Cubre V53 (TESTABLECIMIENTO) y sirve de base para los
--       demas gates.
--
--   * fn_puede_afectar_sede(p_pk_usuario BIGINT)
--       TRUE si fn_puede_afectar_establecimiento(...) OR rol 7 u 8.
--       Cubre V52 (TSEDE). NOTA: incluye implicitamente a los roles 1-3
--       por la delegacion en la funcion base.
--
--   * fn_puede_afectar_usuarios(p_pk_usuario BIGINT)
--       TRUE si fn_puede_afectar_sede(...) OR rol 9.
--       Cubre V51 (TUSUARIO / TFUNCIONARIO). El rol 9 es EXCLUSIVO de
--       usuarios: NO pasa los gates de sede ni de establecimiento.
--
-- Convencion de roles (TROL.PK_TROL):
--   1, 2, 3 -> pueden afectar: establecimiento, sede, usuarios.
--   7, 8    -> pueden afectar: sede, usuarios (NO establecimiento).
--   9       -> puede afectar: usuarios (NO sede, NO establecimiento).
--
-- Reglas de negocio implementadas:
--   * Todas retornan FALSE si p_pk_usuario es NULL.
--   * Todas usan EXISTS sobre TSEDE_USUARIO (ACTIVE=TRUE): basta con
--     UNA vinculacion activa del rol para autorizar.
--   * STABLE: solo lectura, no mutan estado.
--
-- Idempotencia:
--   * CREATE OR REPLACE FUNCTION: el script es seguro de re-ejecutar
--     dentro del mismo ambiente.
-- ===========================================================================

SET search_path TO academico_test, public;


-- ---------------------------------------------------------------------------
-- fn_puede_afectar_establecimiento
--   Gate base de la jerarquia. TRUE si el usuario tiene rol 1, 2 o 3
--   en al menos una TSEDE_USUARIO activa.
--   Cubre: V53 (TESTABLECIMIENTO).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_puede_afectar_establecimiento(
    p_pk_usuario BIGINT
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    SELECT CASE
             WHEN p_pk_usuario IS NULL THEN FALSE
             ELSE EXISTS (
                 SELECT 1
                   FROM academico_test.TSEDE_USUARIO
                  WHERE FK_TUSUARIO = p_pk_usuario
                    AND FK_TROL     IN (1, 2, 3)
                    AND ACTIVE       = TRUE
             )
           END;
$$;

COMMENT ON FUNCTION academico_test.fn_puede_afectar_establecimiento(BIGINT)
    IS 'Reusable: retorna TRUE si el usuario (PK_TUSUARIO) tiene rol 1, 2 o 3 en al menos una TSEDE_USUARIO activa. Gate base de la jerarquia de autorizacion: cubre el modulo de establecimiento (V53) y sirve de apoyo para los gates de sede y usuarios. Si p_pk_usuario es NULL retorna FALSE. Definida en V50 (utilities).';


-- ---------------------------------------------------------------------------
-- fn_puede_afectar_sede -- ELIMINADA (CU-86e2w4xdt).
--   Su unico caller era fn_puede_afectar_usuarios (abajo), donde su logica
--   quedo inlineada como `fn_puede_afectar_establecimiento OR rol IN (7,8,9)`.
--   Los modulos de sede (V52) migraron su gate a fn_assert_permiso_seccion
--   (V29), asi que ya no la usan. El DROP formal esta en V211.
-- ---------------------------------------------------------------------------


-- ---------------------------------------------------------------------------
-- fn_puede_afectar_usuarios
--   TRUE si el usuario pasa el gate de establecimiento (roles 1-3) o tiene
--   rol 7, 8 o 9 en alguna TSEDE_USUARIO activa.
--   Cubre: V51 (fn_usu_crear) y V150 (PIGSE fn_ente_usuario_*).
--   NOTA: el rol 9 es exclusivo de usuarios; no implica permiso sobre sede
--   ni establecimiento.
--   CU-86e2w4xdt: se inlinea la logica de fn_puede_afectar_sede (era su
--   unico caller) para poder eliminar esa funcion -- ver V211.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_puede_afectar_usuarios(
    p_pk_usuario BIGINT
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    SELECT CASE
             WHEN p_pk_usuario IS NULL THEN FALSE
             ELSE academico_test.fn_puede_afectar_establecimiento(p_pk_usuario)
                  OR EXISTS (
                      SELECT 1
                        FROM academico_test.TSEDE_USUARIO
                       WHERE FK_TUSUARIO = p_pk_usuario
                         AND FK_TROL     IN (7, 8, 9)
                         AND ACTIVE       = TRUE
                  )
           END;
$$;

COMMENT ON FUNCTION academico_test.fn_puede_afectar_usuarios(BIGINT)
    IS 'Reusable: retorna TRUE si el usuario puede afectar sede (roles 1-3, 7, 8) o si tiene rol 9 en al menos una TSEDE_USUARIO activa. Gate de autorizacion del modulo de usuarios/funcionarios (V51). El rol 9 es exclusivo de usuarios: NO da permiso sobre sede ni establecimiento. Si p_pk_usuario es NULL retorna FALSE. Definida en V50 (utilities).';


-- ---------------------------------------------------------------------------
-- fn_resolver_establecimiento_unico (REV2 de V50)
--   Resuelve el (unico) EE al que esta ligado el usuario, para los
--   endpoints de alta que reciben p_fk_establecimiento OPCIONAL (NULL) --
--   el select de EE del front solo se muestra para super-admin
--   (fn_puede_afectar_establecimiento); rector, secretaria y jefe de
--   sistema NO ven ese select porque, por ahora, se asume que cada uno de
--   esos tres roles solo esta ligado a UN EE (decision de negocio, no de
--   codigo -- si esa asuncion deja de ser cierta, esta funcion deja de
--   alcanzar y hace falta volver a pedir el EE explicito para esos roles).
--
--   Union de las mismas tres vias que ya usa el gate compuesto de
--   fn_sed_crear/fn_fun_enlazar_establecimiento (rector, secretaria, jefe
--   de sistema en alguna sede del EE) -- NO incluye al super-admin: ese
--   rol siempre debe mandar el EE explicito (puede estar en cualquiera),
--   nunca se le resuelve solo.
--
--   Retorna: PK_ESTABLECIMIENTO si el usuario esta ligado a EXACTAMENTE
--   uno; NULL si no esta ligado a ninguno O si (contra la asuncion de
--   arriba) esta ligado a mas de uno -- en ese caso el caller debe seguir
--   pidiendo el EE de forma explicita (con RAISE '22023' de "obligatorio",
--   igual que si p_fk_establecimiento nunca hubiera sido opcional).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_resolver_establecimiento_unico(
    p_pk_usuario BIGINT
)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT x.PK_ESTABLECIMIENTO
      FROM (
          SELECT ee.PK_ESTABLECIMIENTO, COUNT(*) OVER () AS n
            FROM (
                SELECT e.PK_ESTABLECIMIENTO
                  FROM academico_test.TESTABLECIMIENTO e
                  JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_RECTOR
                 WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario
                UNION
                SELECT e.PK_ESTABLECIMIENTO
                  FROM academico_test.TESTABLECIMIENTO e
                  JOIN academico_test.TFUNCIONARIO f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_SECRETARIA
                 WHERE e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario
                UNION
                SELECT DISTINCT s.FK_TESTABLECIMIENTO
                  FROM academico_test.TSEDE_USUARIO su
                  JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
                 WHERE s.ACTIVE = TRUE AND su.ACTIVE = TRUE AND su.FK_TROL = 8
                   AND su.FK_TUSUARIO = p_pk_usuario
            ) ee
      ) x
     WHERE x.n = 1;
$$;

COMMENT ON FUNCTION academico_test.fn_resolver_establecimiento_unico(BIGINT)
    IS 'Resuelve el unico EE (rector, secretaria, o jefe de sistema en alguna de sus sedes) al que esta ligado el usuario -- para endpoints de alta cuyo p_fk_establecimiento es opcional y el front no le muestra select (ese select solo aparece para super-admin). Asume que el usuario esta ligado a UN SOLO EE bajo esos tres roles (decision de negocio explicita, no garantizada por constraint); si esta ligado a 0 o 2+ retorna NULL y el caller debe seguir exigiendo el EE de forma explicita. NO cubre al super-admin (siempre debe mandarlo explicito). Definida en V50 (utilities).';
