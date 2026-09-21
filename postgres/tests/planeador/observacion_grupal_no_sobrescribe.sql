-- V463: la observacion grupal no pisa a quien ya tiene observacion.
-- Reproduce la seleccion que recorre fn_actividad_observar_grupal.
-- Transaccional: no deja nada.  docker exec -i sso-postgres psql -U <u> -d <db> -X < este.sql
SET search_path TO academico_test, public;
BEGIN;
WITH act AS (SELECT pk_tactividad AS a FROM academico_test.tactividad ORDER BY 1 LIMIT 1),
     mat AS (SELECT pk_tmatricula AS m, row_number() OVER (ORDER BY 1) AS i
               FROM academico_test.tmatricula LIMIT 5),
ins_ae AS (
  INSERT INTO academico_test.tactividad_estudiante
      (fk_tactividad, fk_tmatricula, created_by, created_at, active)
  SELECT act.a, mat.m, 'test-v463', now(), TRUE FROM act, mat
  RETURNING pk_tactividad_estudiante AS ae, fk_tmatricula
)
INSERT INTO academico_test.tactividad_nota
    (fk_tactividad_estudiante, calificable, observacion, created_by, created_at, active)
SELECT ins_ae.ae, 'N',
       CASE mat.i WHEN 1 THEN 'ya observado A' WHEN 2 THEN 'ya observado B'
                  WHEN 3 THEN '   '            WHEN 4 THEN NULL END,
       'test-v463', now(), TRUE
  FROM ins_ae JOIN mat ON mat.m = ins_ae.fk_tmatricula
 WHERE mat.i <= 4;

-- Esperado: se omiten SOLO los dos con texto real; el de observacion en
-- blanco, el que tiene nota sin observacion y el que no tiene nota se observan.
SELECT n.observacion AS observacion_previa,
       CASE WHEN NOT EXISTS (SELECT 1 FROM academico_test.tactividad_nota n2
                              WHERE n2.fk_tactividad_estudiante = ae.pk_tactividad_estudiante
                                AND n2.active = TRUE
                                AND NULLIF(TRIM(n2.observacion), '') IS NOT NULL)
            THEN 'SE OBSERVA' ELSE 'se omite (no se pisa)' END AS resultado
  FROM academico_test.tactividad_estudiante ae
  LEFT JOIN academico_test.tactividad_nota n
         ON n.fk_tactividad_estudiante = ae.pk_tactividad_estudiante AND n.active = TRUE
 WHERE ae.created_by = 'test-v463' AND ae.active = TRUE
 ORDER BY 1 NULLS LAST;
ROLLBACK;
