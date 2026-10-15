-- V442 - Las zonas de una sede salen por su propio endpoint y GET /select/:CATEGORIA
-- es el catálogo genérico de los selectores.
--   GET /establecimientos/sedes/zonas: zonas que puede tener una SEDE. Con
--     ?ESTABLECIMIENTO manda su zona (fn_est_zonas_sede_permitidas, la misma
--     regla que validan fn_sed_crear y fn_sed_actualizar); sin él salen Urbana y
--     Rural. "Urbana y Rural" (VALOR 3) nunca: describe un conjunto de sedes.
--   GET /select/:CATEGORIA: delega en fn_listavalor_opciones; no conoce casos
--     particulares de ninguna categoría. Solo la fila de eval-col: la de pigse
--     lee su propio esquema.
-- Depende de: V129 (fila de /select/:CATEGORIA), V414 (fn_est_zonas_sede_permitidas),
-- V102 (fn_listavalor_opciones).

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action, style)
SELECT
    'eval-col-establecimientos-sedes-zonas-001',
    'select lv.pk_lista_valor, lv.nombre, lv.valor, lv.accion
  from academico_test.tlista_valor lv
 where lv.categoria = ''ZONA''
   and lv.active
   and lv.habilitado
   and lv.valor <> ''3''
   and (CAST(:QUERY.ESTABLECIMIENTO AS BIGINT) IS NULL
        OR lv.valor = ANY (academico_test.fn_est_zonas_sede_permitidas(
                               CAST(:QUERY.ESTABLECIMIENTO AS BIGINT))))
 order by lv.orden, lv.valor',
    'postgres', false, false,
    m.id_microservice,
    '/establecimientos/sedes/zonas', 'SELECT', 'GET',
    '{"QUERY.ESTABLECIMIENTO": "BIGINT"}'::jsonb,
    NULL,
    'Las zonas que una SEDE puede tener, para el select del alta y la edicion (pk_lista_valor, nombre, valor, accion). ESTABLECIMIENTO es opcional: con el, Urbana si el establecimiento es Urbano, Rural si es Rural, las dos si es mixto o no declaro zona (fn_est_zonas_sede_permitidas, la regla que validan fn_sed_crear y fn_sed_actualizar); sin el, Urbana y Rural. "Urbana y Rural" nunca sale: describe un conjunto de sedes, no un edificio.',
    'establecimientos-sedes-zonas', 'DEFAULT'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET query = EXCLUDED.query, param_types = EXCLUDED.param_types, detail = EXCLUDED.detail,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, execution_mode = EXCLUDED.execution_mode,
       action = EXCLUDED.action, style = EXCLUDED.style;

-- Los mismos roles que el catálogo genérico: quien leía /select/ZONA lee esto.
INSERT INTO public.role_query (query_id, role_id)
SELECT nuevo.id_query, rq.role_id
  FROM public.query nuevo
  JOIN public.query catalogo ON catalogo.microservice_id = nuevo.microservice_id
                            AND catalogo.path_template   = '/select/:CATEGORIA'
                            AND catalogo.http_method     = 'GET'
  JOIN public.role_query rq  ON rq.query_id = catalogo.id_query
 WHERE nuevo.uuid = 'eval-col-establecimientos-sedes-zonas-001'
ON CONFLICT DO NOTHING;

UPDATE public.query q
   SET query = 'select * from academico_test.fn_listavalor_opciones(
    CAST(:PARAM.CATEGORIA AS VARCHAR),
    CAST(:QUERY.PREDETERMINADO AS BOOLEAN),
    CAST(:QUERY.PADRE AS BIGINT))',
       param_types = '{"PARAM.CATEGORIA": "VARCHAR", "QUERY.PREDETERMINADO": "BOOLEAN", "QUERY.PADRE": "BIGINT"}'::jsonb,
       detail = 'Catalogo generico de TLISTA_VALOR por categoria para los selectores: valores activos y habilitados de una lista habilitada, en el orden de la Lista de Valores (pk_lista_valor, nombre, valor, accion, etiqueta, orden, predeterminado, fk_tlista_valor_padre). ?PREDETERMINADO=true devuelve solo el valor predeterminado (0 o 1 fila); ?PADRE=<pk_lista_valor> solo los hijos de ese valor (p.ej. municipios de un departamento). La regla de zonas de una sede vive en GET /establecimientos/sedes/zonas.'
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/select/:CATEGORIA'
   AND q.http_method     = 'GET';
