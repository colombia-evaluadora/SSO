-- ===========================================================================
-- V411 - fn_informe_grupo_listar agrego MODO_PERIODO al RETURNS TABLE; V428
-- la reescribe con CREATE OR REPLACE y sin DROP, asi que la firma de V335
-- tiene que desaparecer antes. La funcion vigente es la de V490.
-- ===========================================================================


-- Solo si aun tiene el retorno de V335: re-aplicar no tumba la vigente.
DO $$
DECLARE
    v_fn regprocedure := to_regprocedure('academico_test.fn_informe_grupo_listar(bigint,bigint,bigint[],varchar)');
BEGIN
    IF v_fn IS NOT NULL AND pg_get_function_result(v_fn) NOT LIKE '%modo_periodo%' THEN
        DROP FUNCTION academico_test.fn_informe_grupo_listar(BIGINT, BIGINT, BIGINT[], VARCHAR);
    END IF;
END $$;
