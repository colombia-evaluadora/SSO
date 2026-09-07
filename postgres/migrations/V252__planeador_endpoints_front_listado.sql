-- ===========================================================================
-- V252 — Planeador educativo: hace funcionar tal cual la coleccion Postman
-- del front "planeador-listado-stats-calendario" (CU-86e311xxp).
--
-- Esa coleccion pedia 3 cosas desde la pantalla principal del Planeador y
-- marcaba 2 como "propuestas, no implementadas". Este archivo cierra las
-- tres SIN inventar parametros nuevos en el motor ni un flag "sinPaginar":
--
--   (1) Cards de resumen  -> se registra /planeador/actividades/stats
--   (2) Filtro+paginacion -> se ARREGLA el 500 al omitir size/offset
--   (3) Calendario        -> ya resuelto en V251
--       (/planeador/actividades/calendario), y ademas aqui el listado
--       acepta ?desde=/?hasta= como alias del rango.
--
-- -------------------------------------------------------------------------
-- (2) EL "BUG DE PAGINACION" NO ERA DEL MOTOR — ERA DEL CATALOGO.
--
-- Se venia documentando (V245-V248 y las 4 colecciones Postman) que los
-- endpoints paginados devuelven 500 si el cliente NO manda ?size= y
-- ?offset= explicitos, y se atribuia a un bug de query-service.
--
-- No lo es. ParamBinder (common, bloque "V62 (nulabilidad)") lo explica:
-- todo parametro DECLARADO en param_types acepta null -- omitirlo bindea
-- NULL y el COALESCE del SQL aplica su default. Lo que revienta es un
-- placeholder que el SQL SI referencia pero que NO esta declarado: se queda
-- sin valor en el MapSqlParameterSource y Spring lanza una excepcion que no
-- es SQLException -- exactamente el "500 opaco sin log" observado.
--
-- El origen del error es la convencion que arrastraron V245-V248:
-- "QUERY.SIZE/QUERY.OFFSET son system-bound, no necesitan entrada en
-- param_types". Falso: hay que declararlos como cualquier otro. Ninguna
-- fila del catalogo los declaraba (verificado), por eso el sintoma aparecio
-- recien con esta tanda -- es la primera que los usa.
--
-- Se corrige de raiz para TODOS los endpoints /planeador/% que los
-- referencian, con un UPDATE guiado por el propio texto del SQL (no una
-- lista a mano, que se desactualiza): a partir de aqui, omitir ?size=/
-- ?offset= usa el default del COALESCE en vez de responder 500.
--
-- -------------------------------------------------------------------------
-- (1) /planeador/actividades/stats — la ruta que el front ya escribio.
--
-- La funcion ya existia (fn_actividad_resumen_estados_docente, V224/V250) y
-- se expuso en V250 como /planeador/actividades/tablero. Se registra ADEMAS
-- /stats, que es la ruta con la que el front ya armo su coleccion: misma
-- funcion, misma fuente de verdad, cero logica duplicada.
--
-- La respuesta trae las dos nomenclaturas para que el front no tenga que
-- mapear nada:
--   pending      = pendientes_por_evaluar   (PENDIENTE_POR_EVALUAR)
--   in_progress  = en_evaluacion            (EN_EVALUACION)
--   completed    = finalizadas              (FINALIZADA)
--   cancelled    = vencidas                 (VENCIDA)
-- OJO con la ultima: en el Planeador nada se "cancela". La cuarta tarjeta
-- es "Vencidas (> N dias)" y ese N es ?diasGracia= (default 2) -- de ahi el
-- "> 2 dias" de la etiqueta. Se mantiene el alias `cancelled` porque es el
-- nombre que ya usa el tipo ActividadStatus del front, pero el nombre real
-- (`vencidas`) viaja en la misma fila.
--
-- -------------------------------------------------------------------------
-- (3) ?desde= / ?hasta= en /planeador/actividades.
--
-- El rango YA existia como ?fechaDesde=/?fechaHasta= (V246). El front
-- escribio ?desde=/?hasta=. En vez de renombrar (romperia lo ya
-- documentado) se aceptan AMBOS: COALESCE(fechaDesde, desde). Para la
-- grilla mensual sigue siendo preferible /planeador/actividades/calendario
-- (V251): no pagina y devuelve la fecha de anclaje ya resuelta.
--
-- Depende de: V245-V248/V250/V251 (los endpoints /planeador/...),
-- V224/V250 (fn_actividad_resumen_estados_docente).
-- ===========================================================================

SET search_path TO academico_test, public;

-- ===========================================================================
-- (A) FIX del 500 al omitir ?size=/?offset= — declarar los placeholders de
--     paginacion que el SQL de cada fila ya referencia.
-- ===========================================================================
UPDATE public.query q
   SET param_types = COALESCE(q.param_types, '{}'::jsonb)
                   || CASE WHEN q.query LIKE '%:QUERY.SIZE%'
                           THEN '{"QUERY.SIZE": "INT"}'::jsonb ELSE '{}'::jsonb END
                   || CASE WHEN q.query LIKE '%:QUERY.OFFSET%'
                           THEN '{"QUERY.OFFSET": "INT"}'::jsonb ELSE '{}'::jsonb END
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template LIKE '/planeador/%'
   AND (q.query LIKE '%:QUERY.SIZE%' OR q.query LIKE '%:QUERY.OFFSET%');

-- ===========================================================================
-- (B) ?desde= / ?hasta= como alias del rango en /planeador/actividades.
-- ===========================================================================
UPDATE public.query q
   SET query = replace(
                 replace(q.query,
                         'CAST(:QUERY.FECHA_DESDE AS DATE)',
                         'COALESCE(CAST(:QUERY.FECHA_DESDE AS DATE), CAST(:QUERY.DESDE AS DATE))'),
                         'CAST(:QUERY.FECHA_HASTA AS DATE)',
                         'COALESCE(CAST(:QUERY.FECHA_HASTA AS DATE), CAST(:QUERY.HASTA AS DATE))'),
       param_types = COALESCE(q.param_types, '{}'::jsonb)
                   || '{"QUERY.DESDE": "DATE", "QUERY.HASTA": "DATE"}'::jsonb
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/actividades'
   AND q.http_method     = 'GET'
   AND q.query LIKE '%CAST(:QUERY.FECHA_DESDE AS DATE)%';

-- ===========================================================================
-- (C) GET /planeador/actividades/stats — alias de /tablero con la
--     nomenclatura que ya usa el front.
-- ===========================================================================
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT t.pendientes_por_evaluar AS pending,
       t.en_evaluacion          AS in_progress,
       t.finalizadas            AS completed,
       t.vencidas               AS cancelled,
       t.pendientes_por_evaluar,
       t.en_evaluacion,
       t.finalizadas,
       t.vencidas,
       t.programadas,
       t.sin_programar,
       t.total
  FROM academico_test.fn_actividad_resumen_estados_docente(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.ASIGNATURA AS BIGINT),
    CAST(:QUERY.GRUPO AS BIGINT),
    CAST(:QUERY.UNIDAD AS BIGINT),
    CAST(:QUERY.FECHA_DESDE AS DATE),
    CAST(:QUERY.FECHA_HASTA AS DATE),
    COALESCE(CAST(:QUERY.DIAS_GRACIA AS INT), 2)
) t;',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades/stats', 'SELECT', 'GET',
    '{"QUERY.ASIGNATURA": "BIGINT", "QUERY.GRUPO": "BIGINT", "QUERY.UNIDAD": "BIGINT", "QUERY.FECHA_DESDE": "DATE", "QUERY.FECHA_HASTA": "DATE", "QUERY.DIAS_GRACIA": "INT"}'::jsonb,
    'V252 -- contadores por estado para las 4 tarjetas de resumen de la pantalla principal del Planeador, del DOCENTE autenticado (fn_actividad_resumen_estados_docente, V224/V250). Misma funcion que GET /planeador/actividades/tablero (V250): esta ruta existe porque es la que el front ya tenia escrita, no duplica logica. Devuelve la fila con LAS DOS nomenclaturas -- los alias que usa el tipo ActividadStatus del front (pending / in_progress / completed / cancelled) y los nombres reales del estado derivado (pendientes_por_evaluar / en_evaluacion / finalizadas / vencidas), mas programadas, sin_programar y total. OJO: `cancelled` es un ALIAS de `vencidas`; en el Planeador nada se cancela -- la cuarta tarjeta es "Vencidas (> N dias)" y ese N es ?diasGracia= (default 2). Reemplaza el atajo del front de traer el listado completo con size=500 y contar en el navegador: aqui es un solo COUNT(*) FILTER. El docente se resuelve del token y NO es parametro; si el usuario no es docente activo, todos los contadores en 0. Filtros opcionales ?asignatura=, ?grupo=, ?unidad=, ?fechaDesde=, ?fechaHasta=. Sin paginacion. Gate VER sobre PLANEADOR.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR', 'CEVAL-DOCENTE')
 WHERE m.serviceid = 'eval-col'
   AND q.path_template = '/planeador/actividades/stats'
ON CONFLICT DO NOTHING;
