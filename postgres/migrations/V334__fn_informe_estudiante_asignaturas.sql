-- ===========================================================================
-- V334 - fn_grado_desempeno_minimo: umbral de aprobacion del grado, desde
-- TCRITERIO_PROMOCION.DESEMPENHO_MINIMO (V22). Primero la fila del GRADO
-- exacto, si no la POR_DEFECTO del mismo periodo academico.
--
-- fn_informe_estudiante_asignaturas nacio aqui; la vigente es la de V428 y su
-- COMMENT esta en V514. Idempotente: CREATE OR REPLACE.
-- ===========================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_grado_desempeno_minimo(
    p_fk_tgrado BIGINT
)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $function$
    SELECT cp.DESEMPENHO_MINIMO
      FROM academico_test.TGRADO g
      JOIN academico_test.TCRITERIO_PROMOCION cp
        ON cp.ACTIVE = TRUE
       AND cp.DESEMPENHO_MINIMO IS NOT NULL
       AND (cp.FK_TGRADO = g.PK_TGRADO
            OR (cp.POR_DEFECTO = 'S'
                AND cp.FK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO))
     WHERE g.PK_TGRADO = p_fk_tgrado
     -- El override del grado exacto antes que la fila por defecto. FALSE
     -- ordena antes que TRUE, asi que "no es del grado" cae al final.
     ORDER BY (cp.FK_TGRADO IS DISTINCT FROM g.PK_TGRADO),
              cp.PK_TCRITERIO_PROMOCION DESC
     LIMIT 1;
$function$;

COMMENT ON FUNCTION academico_test.fn_grado_desempeno_minimo(BIGINT)
    IS 'Porcentaje minimo para dar por aprobada una asignatura en un grado, desde TCRITERIO_PROMOCION.DESEMPENHO_MINIMO ("Porcentaje minimo por area o asignatura", V22). Es un PORCENTAJE, asi que se compara directo contra la nota proyectada sin homologar. Resuelve primero la fila del grado exacto y si no la fila POR_DEFECTO del mismo periodo academico, el mismo escalonado de fn_asignatura_criterio_evaluacion_vigente. Devuelve NULL cuando el colegio no lo configuro -- 425 de las 742 filas activas lo tienen en NULL -- y en ese caso "aprobada" debe tratarse como DESCONOCIDA, no como falsa: inventar un 60 por defecto reprobaria gente por una configuracion que nadie hizo.';
