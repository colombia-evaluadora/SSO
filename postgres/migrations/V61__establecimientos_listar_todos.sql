-- ===========================================================================
-- V61 — Listado no paginado de establecimientos (para selects del front).
--
-- fn_est_listar / fn_est_listar_paginado (V53) acotan p_page_size a (0,100]
-- (LEAST(..., 100)) porque estan pensadas para la tabla paginada. Eso las
-- vuelve inutiles para un <select> que necesita TODOS los EE activos que el
-- usuario puede ver (ej. el selector de establecimiento del alta de sedes,
-- que solo aparece para super admin) — con mas de 100 EE activos, pedir una
-- pagina grande simplemente no trae el resto.
--
-- fn_est_listar_todos reusa el MISMO gate de autorizacion que fn_est_listar
-- (super-admin ve todos los EE activos; el resto solo ve los EE de los que
-- es rector), pero sin LIMIT/OFFSET y con una forma de salida liviana
-- (pk + nombre) pensada para alimentar {value, label} directo, mismo
-- criterio que fn_cat_municipios_listar / fn_cat_propiedad_juridica_listar
-- (V58).
--
-- Convenciones heredadas de V58:
--   * RETURNS TABLE con columnas planas pk_establecimiento + nombre.
--   * Solo EE con ACTIVE=TRUE.
--   * ORDER BY NOMBRE ASC, PK_ESTABLECIMIENTO ASC (orden estable).
--   * LANGUAGE plpgsql (no sql puro, porque el gate compuesto necesita
--     IF/ELSE — igual que fn_est_listar, del que es un recorte).
--
-- Idempotencia: CREATE OR REPLACE FUNCTION.
--
-- Excepciones:
--   SQLSTATE '42501' — el usuario no es super-admin ni rector de ningun EE
--                       activo (mismo criterio que fn_est_listar).
-- ===========================================================================

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_est_listar_todos(
    p_pk_usuario_solicitante  BIGINT
)
RETURNS TABLE (
    pk_establecimiento  BIGINT,
    nombre              VARCHAR
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    -- Camino super-admin: todos los EE activos.
    IF academico_test.fn_puede_afectar_establecimiento(p_pk_usuario_solicitante) THEN
        RETURN QUERY
        SELECT e.PK_ESTABLECIMIENTO, e.NOMBRE
          FROM academico_test.TESTABLECIMIENTO e
         WHERE e.ACTIVE = TRUE
         ORDER BY e.NOMBRE ASC, e.PK_ESTABLECIMIENTO ASC;
        RETURN;
    END IF;

    -- Camino no-super-admin: solo los EE de los que es rector (mismo
    -- criterio que fn_est_listar/fn_est_contar). Sin al menos uno => 42501.
    IF NOT EXISTS (
        SELECT 1
          FROM academico_test.TESTABLECIMIENTO e
          JOIN academico_test.TFUNCIONARIO  f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_RECTOR
         WHERE e.ACTIVE      = TRUE
           AND f.ACTIVE      = TRUE
           AND f.FK_TUSUARIO = p_pk_usuario_solicitante
    ) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
    SELECT e.PK_ESTABLECIMIENTO, e.NOMBRE
      FROM academico_test.TESTABLECIMIENTO e
      JOIN academico_test.TFUNCIONARIO  f ON f.PK_TFUNCIONARIO = e.FK_TFUNCIONARIO_RECTOR
     WHERE e.ACTIVE      = TRUE
       AND f.ACTIVE      = TRUE
       AND f.FK_TUSUARIO  = p_pk_usuario_solicitante
     ORDER BY e.NOMBRE ASC, e.PK_ESTABLECIMIENTO ASC;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_est_listar_todos(BIGINT)
    IS 'Lista TODOS los TESTABLECIMIENTO activos que el usuario puede ver, sin paginar: pk_establecimiento + nombre, pensada para alimentar un <select> (ej. el selector de EE del alta de sedes, solo visible para super admin). Mismo gate que fn_est_listar (V53): super-admin ve todos los EE activos; el resto solo los EE de los que es rector (FK_TFUNCIONARIO_RECTOR). Si no es super-admin y no es rector de ningun EE activo => 42501. Orden estable por NOMBRE ASC, PK_ESTABLECIMIENTO ASC. A diferencia de fn_est_listar, no acota p_page_size (no aplica) — a proposito, para que el select reciba el universo completo. p_pk_usuario_solicitante va al inicio (obligatorio, mismo patron que V50/V52/V53/V58).';
