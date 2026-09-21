-- Reglas de color del tablero del Planeador (V462). Se corre contra el
-- Postgres local:  docker exec -i sso-postgres psql -U <user> -d <db> -X < este.sql
-- Cualquier fila con "<<< FALLA" es una regresion de fn_actividad_estado.
SET search_path TO academico_test, public;

WITH casos(caso, ini, cie, cal, esperado) AS (VALUES
 ('azul: futura, empieza y cierra en 10 dias',   DATE '2026-10-01', DATE '2026-10-10', NULL::DATE, 'EN_EVALUACION'),
 ('azul: en curso, hoy dentro de la ventana',    DATE '2026-09-15', DATE '2026-09-25', NULL::DATE, 'EN_EVALUACION'),
 ('azul: cierra hoy (el plazo no se cumplio)',   DATE '2026-09-10', DATE '2026-09-21', NULL::DATE, 'EN_EVALUACION'),
 ('azul: sin fecha de cierre',                   DATE '2026-09-01', NULL,              NULL::DATE, 'EN_EVALUACION'),
 ('azul: sin ninguna fecha',                     NULL,              NULL,              NULL::DATE, 'EN_EVALUACION'),
 ('amarillo: cerro ayer, sin calificar',         DATE '2026-09-10', DATE '2026-09-20', NULL::DATE, 'PENDIENTE_POR_EVALUAR'),
 ('amarillo: cerro antier, sin calificar',       DATE '2026-09-10', DATE '2026-09-19', NULL::DATE, 'PENDIENTE_POR_EVALUAR'),
 ('rojo: cerro hace 3 dias, sin calificar',      DATE '2026-09-10', DATE '2026-09-18', NULL::DATE, 'VENCIDA'),
 ('rojo: cerro hace 30 dias, sin calificar',     DATE '2026-08-01', DATE '2026-08-22', NULL::DATE, 'VENCIDA'),
 ('verde: evaluada al 100% dentro de plazo',     DATE '2026-09-15', DATE '2026-09-25', DATE '2026-09-20', 'FINALIZADA'),
 ('verde: evaluada al 100% tarde, gana al rojo', DATE '2026-08-01', DATE '2026-08-22', DATE '2026-09-20', 'FINALIZADA')
)
SELECT caso, esperado,
       academico_test.fn_actividad_estado(ini, cie, cal, DATE '2026-09-21') AS obtenido,
       CASE WHEN academico_test.fn_actividad_estado(ini, cie, cal, DATE '2026-09-21') = esperado
            THEN 'ok' ELSE '<<< FALLA' END AS resultado
  FROM casos;
