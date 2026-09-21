-- V464: fn_asistencia_registrar_bulk rechaza fechas futuras; hoy y el pasado
-- pasan el gate de fecha (y siguen con el resto de validaciones).
SET search_path TO academico_test, public;
DO $$
DECLARE d DATE; BEGIN
  FOREACH d IN ARRAY ARRAY[CURRENT_DATE + 1, CURRENT_DATE + 30] LOOP
    BEGIN
      PERFORM academico_test.fn_asistencia_registrar_bulk(1, 1, 1, d, NULL, NULL, 1, NULL);
      RAISE WARNING '<<< FALLA: acepto la fecha futura %', d;
    EXCEPTION
      WHEN SQLSTATE '22023' THEN RAISE NOTICE 'ok % -> %', d, SQLERRM;
      WHEN OTHERS THEN RAISE WARNING '<<< FALLA % : error inesperado % %', d, SQLSTATE, SQLERRM;
    END;
  END LOOP;
  FOREACH d IN ARRAY ARRAY[CURRENT_DATE, CURRENT_DATE - 1] LOOP
    BEGIN
      PERFORM academico_test.fn_asistencia_registrar_bulk(1, 1, 1, d, NULL, NULL, 1, NULL);
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM LIKE '%fecha futura%' THEN RAISE WARNING '<<< FALLA: % bloqueada por el gate de fecha', d;
      ELSE RAISE NOTICE 'ok % -> pasa el gate de fecha (se detiene despues: %)', d, SQLSTATE;
      END IF;
    END;
  END LOOP;
END $$;

-- V464: RETRASADA se cuenta desde el DIA ANTERIOR; la sesion de hoy no vence.
SELECT CASE WHEN pg_get_functiondef(
              'academico_test.fn_asistencia_calendario(bigint,bigint,integer,integer,bigint,bigint,date,bigint)'::regprocedure
            ) LIKE '%<  p_fecha_hoy   THEN ''RETRASADA''%'
       THEN 'ok: RETRASADA usa < p_fecha_hoy' ELSE '<<< FALLA: sigue en <=' END AS frontera_retrasada;
