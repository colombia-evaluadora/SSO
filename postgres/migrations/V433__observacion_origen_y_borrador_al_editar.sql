-- ===========================================================================
-- V433 - La etiqueta "Desactualizada" no debe encenderse al editar un resumen.
--
-- Backfill de TESTUDIANTE_PERIODO_OBSERVACION.OBSERVACIONES_ORIGEN: las filas
-- que quedaron en NULL (el front no reenvia la cuenta al editar) muestran la
-- etiqueta para siempre, porque el listado lee NULL como cero. Se les pone la
-- cuenta de hoy; si alguna tenia observaciones posteriores de verdad, se le
-- apaga una etiqueta correcta: la cuenta historica no se guardo.
-- Idempotente: solo toca filas que siguen en NULL.
-- ===========================================================================

COMMENT ON FUNCTION academico_test.fn_estudiante_periodo_observacion_guardar(BIGINT, BIGINT, BIGINT, TEXT, TEXT, NUMERIC)
    IS 'Guarda el resumen del periodo de un estudiante. Reemplaza: el indice unico es total sobre (matricula, periodo) y no se versiona. El ESTADO se deduce comparando el texto contra OBSERVACION_IA -- iguales APROBADA, distintos MODIFICADA --, nunca se pide por parametro. V433 arregla dos cosas que hacian mentir a la pantalla cuando alguien EDITABA un resumen ya guardado, porque en ese camino el front no reenvia ni el borrador ni la cuenta: (1) si no llega OBSERVACIONES_ORIGEN se CUENTAN las observaciones por actividad en el momento de guardar, con la misma consulta de fn_estudiante_periodo_observacion_generar, en vez de dejar la columna en NULL -- el listado la lee con COALESCE(...,0), y cero significa "no habia ninguna", de modo que toda fila con al menos una observacion quedaba marcada como Desactualizada para siempre; (2) si no llega OBSERVACION_IA se conserva el borrador YA GUARDADO en lugar de asumir que el texto nuevo es el de la IA, asi que editar un resumen generado queda como MODIFICADA y no como APROBADA. Sin fila previa y sin OBSERVACION_IA se mantiene el comportamiento anterior (el texto hace de borrador, estado APROBADA): es el caso de escribirlo a mano desde cero. V336, V413, V433.';

UPDATE academico_test.TESTUDIANTE_PERIODO_OBSERVACION ob
   SET OBSERVACIONES_ORIGEN = (
           SELECT COUNT(*)
             FROM academico_test.TACTIVIDAD a
             JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
               ON ae.FK_TACTIVIDAD = a.PK_TACTIVIDAD
              AND ae.FK_TMATRICULA = ob.FK_TMATRICULA
              AND ae.ACTIVE = TRUE
             JOIN academico_test.TACTIVIDAD_NOTA n
               ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
              AND n.ACTIVE = TRUE
            WHERE a.ACTIVE = TRUE
              AND NULLIF(TRIM(COALESCE(n.OBSERVACION, '')), '') IS NOT NULL
              AND academico_test.fn_actividad_en_periodo_eval(
                      a.PK_TACTIVIDAD, ob.FK_TPERIODO_EVALUACION) = TRUE
       )
 WHERE ob.OBSERVACIONES_ORIGEN IS NULL
   AND ob.ACTIVE = TRUE;
