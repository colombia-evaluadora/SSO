-- ===========================================================================
-- V411 - fn informe grupo listar requerido
-- Recortada: las funciones de informes que V535-V541 reescriben en capas
-- se quitaron de aqui y viven alli. Queda lo que sigue vivo y lo que una
-- base limpia necesita al migrar (CREATE solo si la funcion no existe).
-- ===========================================================================


DO $$
DECLARE
    v_fn regprocedure := to_regprocedure('academico_test.fn_informe_grupo_listar(bigint,bigint,bigint[],varchar)');
BEGIN
    IF v_fn IS NOT NULL AND pg_get_function_result(v_fn) NOT LIKE '%modo_periodo%' THEN
        DROP FUNCTION academico_test.fn_informe_grupo_listar(BIGINT, BIGINT, BIGINT[], VARCHAR);
    END IF;
END $$;
