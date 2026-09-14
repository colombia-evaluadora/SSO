-- ============================================================================
-- V385 — /catalogos/municipios (fila de pigse) no seleccionaba
-- pigse.tmunicipio.codigo (el código DANE real, distinto de pk_tmunicipio)
-- pese a que la columna existe desde que se creó la tabla. El front
-- (use-municipalities.ts) ya tenía el mapeo `code: row.codigo` portado
-- defensivamente desde CEVAL, pero sin esta columna en el SELECT siempre
-- llegaba undefined.
-- ============================================================================

UPDATE public.query q
   SET query = $Q$SELECT m2.pk_tmunicipio AS pk_municipio, m2.codigo, m2.nombre,
       d.pk_departamento, d.nombre AS departamento_nombre
  FROM pigse.tmunicipio m2
  JOIN pigse.tdepartamento d ON d.pk_departamento = m2.pk_tdepartamento
 WHERE m2.active = true
 ORDER BY d.nombre, m2.nombre
$Q$
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND q.path_template = '/catalogos/municipios'
   AND q.query ILIKE '%pigse.tmunicipio%';

DO $$
DECLARE
    v_ok BOOLEAN;
BEGIN
    SELECT (q.query ILIKE '%m2.codigo%') INTO v_ok
      FROM public.query q
     WHERE q.path_template = '/catalogos/municipios'
       AND q.query ILIKE '%pigse.tmunicipio%';

    IF NOT coalesce(v_ok, false) THEN
        RAISE EXCEPTION 'V385: /catalogos/municipios (pigse) no se actualizo';
    END IF;

    RAISE NOTICE 'V385 OK: /catalogos/municipios (pigse) ahora incluye codigo.';
END $$;
