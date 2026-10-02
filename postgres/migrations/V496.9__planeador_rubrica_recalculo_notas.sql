-- V496.9 - Recalcula las notas de rúbrica ya guardadas con la fórmula de la
-- Regla 42 (suma de los puntajes elegidos sobre la suma de los máximos de
-- cada criterio; antes, promedio de los porcentajes de cada criterio). Solo
-- cambia las notas de rúbricas cuyos criterios tienen máximos distintos, y
-- vuelve a consolidar su recuperación. Idempotente: parte de lo capturado.
-- Depende de: V496.6 (fn_actividad_nota_rubrica_recalcular,
-- fn_actividad_nota_aplicar_interno), V496.5 (instrumento efectivo).
-- Aplica sin pasar por la Regla 55: es la fórmula, no una corrección del docente.

DO $$
DECLARE
    r   RECORD;
    v_n INT := 0;
BEGIN
    FOR r IN
        SELECT ae.PK_TACTIVIDAD_ESTUDIANTE AS pk_ae, n.CALIFICACION,
               academico_test.fn_actividad_nota_rubrica_recalcular(ae.PK_TACTIVIDAD_ESTUDIANTE) AS nueva
          FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
          JOIN academico_test.TACTIVIDAD a ON a.PK_TACTIVIDAD = ae.FK_TACTIVIDAD AND a.ACTIVE = TRUE
          JOIN academico_test.TACTIVIDAD_NOTA n
            ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE AND n.ACTIVE = TRUE AND n.CALIFICACION IS NOT NULL
         WHERE ae.ACTIVE = TRUE
           AND academico_test.fn_actividad_instrumento_efectivo(a.PK_TACTIVIDAD) = 'RUBRICA'
    LOOP
        IF r.nueva IS NOT NULL AND r.nueva IS DISTINCT FROM r.CALIFICACION THEN
            PERFORM academico_test.fn_actividad_nota_aplicar_interno(0, r.pk_ae, r.nueva);
            v_n := v_n + 1;
        END IF;
    END LOOP;
    RAISE NOTICE 'Notas de rúbrica recalculadas (Regla 42): %', v_n;
END
$$;
