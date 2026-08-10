-- =============================================================================
-- V34 — admitir el modo DML en el CHECK de EXECUTION_MODE.
--
-- La V33 habilitó escribir INSERT/UPDATE directamente en el campo SQL, con un
-- modo derivado nuevo ('DML'), pero se olvidó de ampliar el CHECK que dejó la
-- V28 sobre EXECUTION_MODE. El síntoma: guardar una query con un UPDATE
-- fallaba con 500 al insertar la fila —
--
--   ERROR: new row for relation "query" violates check constraint
--          "chk_query_execution_mode"
--
-- — porque el CHECK sólo conocía SELECT, PROCEDURE y FUNCTION.
--
-- FUNCTION se conserva en la lista aunque la V32 convirtió las filas
-- existentes y el formulario ya no lo ofrece: si quedara alguna fila con ese
-- valor en otro entorno, esta migración no debe hacerla ilegal de golpe.
-- =============================================================================

ALTER TABLE QUERY
    DROP CONSTRAINT IF EXISTS chk_query_execution_mode;

ALTER TABLE QUERY
    ADD CONSTRAINT chk_query_execution_mode
    CHECK (EXECUTION_MODE IN ('SELECT', 'PROCEDURE', 'FUNCTION', 'DML'));

COMMENT ON COLUMN QUERY.EXECUTION_MODE IS
    'Derivado del primer keyword del SQL, no editable por el admin: SELECT/WITH -> SELECT, CALL -> PROCEDURE, INSERT/UPDATE -> DML. FUNCTION es historico (V32 lo convirtio a SELECT). Una fila DML no pasa por rejectIfMutating y exige HTTP_METHOD POST o PUT.';
