-- V83 — dos columnas nuevas en query_param_constraint: min_value y
-- max_value. Complementan max_digits (que limita CUÁNTAS cifras
-- tiene un número, no su magnitud) con un rango real de valor —
-- el patrón que aparece en los CHECK reales de academico_test, p.ej.
-- `CHECK (valoracion >= 0 AND valoracion <= 100)` en
-- teval_docente_detalle. Hoy, mandar 99999 donde la función espera
-- 0..100 revienta como violación de constraint dentro del INSERT,
-- un error de Postgres crudo — con estas columnas, query-service lo
-- rechaza antes del bind con el mismo 400 PARAM_CONSTRAINT_VIOLATION
-- que ya usan las demás reglas.
--
-- NUMERIC sin precisión/escala fija: el rango puede aplicar tanto a
-- INTEGER/BIGINT como a NUMERIC con decimales, y la validación real
-- la hace ParamConstraintValidator en Java, no Postgres — esta
-- columna sólo persiste el límite que el autor declaró.

ALTER TABLE public.query_param_constraint
    ADD COLUMN min_value numeric,
    ADD COLUMN max_value numeric;

ALTER TABLE public.query_param_constraint
    ADD CONSTRAINT ck_qpc_value_range CHECK (
        min_value IS NULL OR max_value IS NULL OR min_value <= max_value
    );

COMMENT ON COLUMN public.query_param_constraint.min_value IS
    'Numéricos: valor mínimo admitido (inclusive).';
COMMENT ON COLUMN public.query_param_constraint.max_value IS
    'Numéricos: valor máximo admitido (inclusive).';
