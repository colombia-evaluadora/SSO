-- ===========================================================================
-- V50 — Utilities academicas (foundations).
--
-- Convencion: las funciones de uso transversal a los modulos academicos
-- (establecimiento, sede, funcionarios, periodos, etc.) viven en este
-- archivo, antes de cualquier modulo de negocio. Cualquier migracion
-- posterior puede depender de las funciones aqui definidas.
--
-- Alcance de esta primera entrega:
--   * fn_es_super_admin(p_pk_usuario BIGINT) — gate de autorizacion
--       reutilizable: retorna TRUE si el usuario tiene rol de super-admin
--       (FK_TROL = 1) en al menos una TSEDE_USUARIO activa.
--
-- Reglas de negocio implementadas:
--   * fn_es_super_admin es STABLE (no muta estado) y retorna FALSE si
--       p_pk_usuario es NULL. Marcada LANGUAGE sql para que el planner
--       la inline cuando se llama dentro de un predicado.
--
-- Idempotencia:
--   * CREATE OR REPLACE FUNCTION: el script es seguro de re-ejecutar
--     dentro del mismo ambiente (Flyway solo lo corre una vez por version,
--     pero asi blindamos el comportamiento si se aplica manualmente).
-- ===========================================================================

SET search_path TO academico_test, public;


-- ---------------------------------------------------------------------------
-- fn_es_super_admin
--   Verifica si un usuario (PK_TUSUARIO) tiene rol de super-admin.
--   En este modelo, un usuario es super-admin si figura en TSEDE_USUARIO
--   con FK_TROL = 1 (PK_TROL del super-admin) y la vinculacion esta activa.
--   Basta con UNA sola fila (LIMIT 1 / EXISTS) porque al usuario super-admin
--   se le asigna dicho rol en TODAS las sedes; verificar en una sola es
--   suficiente y mas eficiente que recorrer todas.
--
--   Es una funcion helper reusable para TODOS los modulos academicos
--   (establecimiento, sedes, funcionarios, etc.) que requieran autorizacion
--   de super-admin. Marcada STABLE porque solo lee y no modifica estado.
--
--   Retorna: BOOLEAN (TRUE = es super-admin, FALSE = no lo es).
--     * Si p_pk_usuario es NULL: retorna FALSE (no es super-admin).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_es_super_admin(
    p_pk_usuario BIGINT
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1
          FROM academico_test.TSEDE_USUARIO
         WHERE FK_TUSUARIO = p_pk_usuario
           AND FK_TROL     = 1
           AND ACTIVE      = TRUE
    );
$$;

COMMENT ON FUNCTION academico_test.fn_es_super_admin(BIGINT)
    IS 'Reusable: retorna TRUE si el usuario (PK_TUSUARIO) tiene rol de super-admin (FK_TROL=1) en al menos una TSEDE_USUARIO activa. Usada como gate de autorizacion en crear/eliminar/actualizar de los modulos academicos. Definida en V50 (utilities) y consumida por V52 (campus) y V53 (establishment).';
