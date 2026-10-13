-- V549: filas `.../reporte` del microservicio pigse para el reporting-service
-- (claves pigse-establecimientos / pigse-sedes / pigse-funcionarios).
-- Sin ellas el reporte de PIGSE caia en las filas de eval-col (V67) y el
-- query-service respondia 403 "No tienes acceso a esta consulta, o no existe".
-- Reusan las funciones del listado (mismos filtros, mismo gate) y aplanan el
-- `rows` JSONB a columnas. role_query = el de la fila hermana `.../query`.
-- fn_sed_listar topa page_size en 100: el reporte recorre todas las paginas.
-- Depende de: V258/V386/V387 (filas y funciones de listado pigse).

DELETE FROM public.query WHERE uuid IN (
    'pigse-establecimientos-reporte', 'pigse-sedes-reporte', 'pigse-funcionarios-reporte');

INSERT INTO public.query (uuid, query, type, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT 'pigse-establecimientos-reporte',
       $q$SELECT x.r->>'codigo' AS codigo, x.r->>'nombre' AS nombre, x.r->>'nit' AS nit,
       x.r->>'departamento_nombre' AS departamento_nombre,
       x.r->>'municipio_nombre' AS municipio_nombre,
       x.r->>'ente_nombre' AS ente_nombre, x.r->>'estado_nombre' AS estado_nombre
  FROM pigse.fn_est_listar(
           public.fn_get_pigse_usuario_id(CAST(:CONTEXT.USER_ID AS BIGINT)),
           CAST(:BODY.FILTERS.SEARCH AS VARCHAR),
           CAST(:BODY.FILTERS.ENTES AS BIGINT[]),
           CAST(:BODY.FILTERS.MUNICIPIOS AS VARCHAR[]),
           CAST(:BODY.SORTING.ID AS VARCHAR),
           CAST(:BODY.SORTING.DESC AS BOOLEAN),
           NULL::INTEGER, NULL::INTEGER) f
 CROSS JOIN LATERAL jsonb_array_elements(f.rows) WITH ORDINALITY x(r, n)
 WHERE CAST(:BODY.FILTERS.IDS AS BIGINT[]) IS NULL
    OR (x.r->>'pk_establecimiento')::BIGINT = ANY(CAST(:BODY.FILTERS.IDS AS BIGINT[]))
 ORDER BY x.n$q$,
       h.type, h.microservice_id, '/establecimientos/reporte', 'SELECT', 'POST',
       '{"BODY.FILTERS.SEARCH": "VARCHAR", "BODY.FILTERS.ENTES": "BIGINT[]",
         "BODY.FILTERS.MUNICIPIOS": "VARCHAR[]", "BODY.FILTERS.IDS": "BIGINT[]",
         "BODY.SORTING.ID": "VARCHAR", "BODY.SORTING.DESC": "BOOLEAN"}'::jsonb,
       'Reporte (sin paginar) de pigse.fn_est_listar; FILTERS.IDS = solo los marcados. No es /establecimientos/query.'
  FROM public.query h WHERE h.uuid = 'pigse-establecimientos-query';

INSERT INTO public.query (uuid, query, type, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT 'pigse-sedes-reporte',
       $q$WITH primera AS (
    SELECT f.page_count
      FROM pigse.fn_sed_listar(
               public.fn_get_pigse_usuario_id(CAST(:CONTEXT.USER_ID AS BIGINT)),
               CAST(:BODY.FILTERS.SEARCH AS VARCHAR),
               CAST(:BODY.FILTERS.ESTABLECIMIENTO AS BIGINT),
               CAST(:BODY.FILTERS.ZONA AS VARCHAR[]),
               CAST(:BODY.SORTING.ID AS VARCHAR),
               CAST(:BODY.SORTING.DESC AS BOOLEAN),
               0, 100) f
)
SELECT x.r->>'codigo' AS codigo, x.r->>'nombre' AS nombre, x.r->>'consecutivo' AS consecutivo,
       x.r->>'establecimiento_nombre' AS establecimiento_nombre,
       x.r->>'zona_nombre' AS zona_nombre, x.r->>'direccion' AS direccion,
       x.r->>'telefono' AS telefono
  FROM primera p
 CROSS JOIN LATERAL generate_series(0, GREATEST(p.page_count - 1, 0)::INTEGER) g(i)
 CROSS JOIN LATERAL pigse.fn_sed_listar(
           public.fn_get_pigse_usuario_id(CAST(:CONTEXT.USER_ID AS BIGINT)),
           CAST(:BODY.FILTERS.SEARCH AS VARCHAR),
           CAST(:BODY.FILTERS.ESTABLECIMIENTO AS BIGINT),
           CAST(:BODY.FILTERS.ZONA AS VARCHAR[]),
           CAST(:BODY.SORTING.ID AS VARCHAR),
           CAST(:BODY.SORTING.DESC AS BOOLEAN),
           g.i, 100) f
 CROSS JOIN LATERAL jsonb_array_elements(f.rows) WITH ORDINALITY x(r, n)
 WHERE CAST(:BODY.FILTERS.IDS AS BIGINT[]) IS NULL
    OR (x.r->>'pk_sede')::BIGINT = ANY(CAST(:BODY.FILTERS.IDS AS BIGINT[]))
 ORDER BY g.i, x.n$q$,
       h.type, h.microservice_id, '/sedes/reporte', 'SELECT', 'POST',
       '{"BODY.FILTERS.SEARCH": "VARCHAR", "BODY.FILTERS.ESTABLECIMIENTO": "BIGINT",
         "BODY.FILTERS.ZONA": "VARCHAR[]", "BODY.FILTERS.IDS": "BIGINT[]",
         "BODY.SORTING.ID": "VARCHAR", "BODY.SORTING.DESC": "BOOLEAN"}'::jsonb,
       'Reporte (todas las paginas) de pigse.fn_sed_listar; FILTERS.IDS = solo las marcadas. No es /sedes/query.'
  FROM public.query h WHERE h.uuid = 'pigse-sedes-query';

INSERT INTO public.query (uuid, query, type, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT 'pigse-funcionarios-reporte',
       $q$SELECT x.r->>'identificacion' AS numero_documento,
       concat_ws(' ', x.r->>'primer_nombre', x.r->>'segundo_nombre',
                      x.r->>'primer_apellido', x.r->>'segundo_apellido') AS nombre_completo,
       x.r->>'correo_electronico' AS correo_electronico, x.r->>'telefono' AS telefono,
       x.r->>'establecimiento_nombre' AS establecimiento_nombre,
       (SELECT string_agg(DISTINCT regexp_replace(p->>'nombre', '^PIGSE-', ''), ', ')
          FROM jsonb_array_elements(x.r->'permisos') p) AS roles,
       (SELECT string_agg(DISTINCT p->>'sede', ', ') FROM jsonb_array_elements(x.r->'permisos') p) AS sedes,
       (SELECT string_agg(DISTINCT p->>'jornada', ', ') FROM jsonb_array_elements(x.r->'permisos') p) AS jornadas
  FROM pigse.fn_fun_listar(
           public.fn_get_pigse_usuario_id(CAST(:CONTEXT.USER_ID AS BIGINT)),
           CAST(:BODY.FILTERS.SEARCH AS VARCHAR),
           CAST(:BODY.FILTERS.ESTABLECIMIENTOS AS BIGINT[]),
           CAST(:BODY.FILTERS.ROL AS VARCHAR[]),
           CAST(:BODY.FILTERS.JORNADA AS VARCHAR[]),
           CAST(:BODY.FILTERS.ESTADO AS VARCHAR[]),
           CAST(:BODY.SORTING.ID AS VARCHAR),
           CAST(:BODY.SORTING.DESC AS BOOLEAN),
           NULL::INTEGER, NULL::INTEGER) f
 CROSS JOIN LATERAL jsonb_array_elements(f.rows) WITH ORDINALITY x(r, n)
 WHERE CAST(:BODY.FILTERS.IDS AS BIGINT[]) IS NULL
    OR (x.r->>'pk_funcionario')::BIGINT = ANY(CAST(:BODY.FILTERS.IDS AS BIGINT[]))
 ORDER BY x.n$q$,
       h.type, h.microservice_id, '/funcionarios/reporte', 'SELECT', 'POST',
       '{"BODY.FILTERS.SEARCH": "VARCHAR", "BODY.FILTERS.ESTABLECIMIENTOS": "BIGINT[]",
         "BODY.FILTERS.ROL": "VARCHAR[]", "BODY.FILTERS.JORNADA": "VARCHAR[]",
         "BODY.FILTERS.ESTADO": "VARCHAR[]", "BODY.FILTERS.IDS": "BIGINT[]",
         "BODY.SORTING.ID": "VARCHAR", "BODY.SORTING.DESC": "BOOLEAN"}'::jsonb,
       'Reporte (sin paginar) de pigse.fn_fun_listar; FILTERS.IDS = pk_funcionario marcados. No es /funcionarios/query.'
  FROM public.query h WHERE h.uuid = 'pigse-funcionarios-query';

-- Quien ve el listado puede exportarlo.
INSERT INTO public.role_query (query_id, role_id)
SELECT r.id_query, rq.role_id
  FROM (VALUES ('pigse-establecimientos-reporte', 'pigse-establecimientos-query'),
               ('pigse-sedes-reporte',            'pigse-sedes-query'),
               ('pigse-funcionarios-reporte',     'pigse-funcionarios-query')) v(reporte, hermana)
  JOIN public.query r ON r.uuid = v.reporte
  JOIN public.query h ON h.uuid = v.hermana
  JOIN public.role_query rq ON rq.query_id = h.id_query
ON CONFLICT DO NOTHING;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM public.query WHERE uuid = 'pigse-funcionarios-query')
       AND (SELECT COUNT(*) FROM public.query WHERE uuid IN (
               'pigse-establecimientos-reporte', 'pigse-sedes-reporte', 'pigse-funcionarios-reporte')) <> 3 THEN
        RAISE EXCEPTION 'V549: no se crearon las 3 filas de reporte de pigse';
    END IF;
END $$;
