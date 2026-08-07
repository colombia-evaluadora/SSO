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
-- fn_puede_afectar_sede
--   TRUE si el usuario pasa el gate de establecimiento OR tiene rol 7 u 8.
--   Cubre: V52 (TSEDE).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_puede_afectar_sede(
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
                         AND FK_TROL     IN (7, 8)
                         AND ACTIVE       = TRUE
                  )
           END;
$$;

COMMENT ON FUNCTION academico_test.fn_puede_afectar_sede(BIGINT)
    IS 'Reusable: retorna TRUE si el usuario puede afectar establecimiento (roles 1-3) o si tiene rol 7 u 8 en al menos una TSEDE_USUARIO activa. Gate de autorizacion del modulo de sede (V52). Tambien cubre implicitamente todas las acciones de usuarios (los roles 7 y 8 pueden afectar usuarios). Si p_pk_usuario es NULL retorna FALSE. Definida en V50 (utilities).';


-- ---------------------------------------------------------------------------
-- fn_puede_afectar_usuarios
--   TRUE si el usuario pasa el gate de sede OR tiene rol 9.
--   Cubre: V51 (TUSUARIO, TFUNCIONARIO).
--   NOTA: el rol 9 es exclusivo de usuarios; no implica permiso sobre
--   sede ni establecimiento.
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
             ELSE academico_test.fn_puede_afectar_sede(p_pk_usuario)
                  OR EXISTS (
                      SELECT 1
                        FROM academico_test.TSEDE_USUARIO
                       WHERE FK_TUSUARIO = p_pk_usuario
                         AND FK_TROL     = 9
                         AND ACTIVE       = TRUE
                  )
           END;
$$;

COMMENT ON FUNCTION academico_test.fn_puede_afectar_usuarios(BIGINT)
    IS 'Reusable: retorna TRUE si el usuario puede afectar sede (roles 1-3, 7, 8) o si tiene rol 9 en al menos una TSEDE_USUARIO activa. Gate de autorizacion del modulo de usuarios/funcionarios (V51). El rol 9 es exclusivo de usuarios: NO da permiso sobre sede ni establecimiento. Si p_pk_usuario es NULL retorna FALSE. Definida en V50 (utilities).';
