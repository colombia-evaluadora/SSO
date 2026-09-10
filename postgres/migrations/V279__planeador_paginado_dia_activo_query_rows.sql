-- ===========================================================================
-- V279 — Planeador educativo: el paginado por DIA ACTIVO se vuelve alcanzable
-- por HTTP (CU-86e311xxp).
--
-- POR QUE HACE FALTA ESTA MIGRACION Y NO BASTA CON EDITAR V245/V246/V250
--
-- El paginado por dia activo (?dia=) y el estado derivado de la unidad se
-- implementaron editando en sitio las funciones (V216 fn_unidad_listar,
-- V224 fn_actividad_listar / fn_actividad_listar_docente) y las filas de
-- public.query de V245 / V246 / V250. Las funciones se recrean sin problema
-- -- son CREATE OR REPLACE, y donde cambia el tipo de retorno hay un DROP
-- previo --, pero las filas de public.query se insertan con
--
--     ON CONFLICT (microservice_id, path_template, http_method) DO NOTHING
--
-- asi que en CUALQUIER base donde el endpoint ya existe (local y el servidor
-- de test) re-ejecutar V245/V246/V250 no cambia nada: la fila vieja sigue
-- llamando a la funcion con los argumentos de antes y sin declarar
-- QUERY.DIA. Resultado: la funcion soporta el dia, el front lo manda, y el
-- endpoint lo ignora en silencio -- que es exactamente el modo de falla mas
-- caro de diagnosticar. Verificado contra la base local: tras aplicar las
-- tres migraciones editadas, las tres filas seguian sin QUERY.DIA.
--
-- Es el mismo problema y el mismo remedio de V253 (el filtro ?estados=): una
-- migracion aparte cuyo unico trabajo es RECONCILIAR las filas ya
-- registradas, con UPDATE en vez de INSERT.
--
-- Los tres UPDATE son idempotentes por construccion: el guard
-- `query NOT LIKE '%:QUERY.DIA AS DATE%'` los vuelve no-op en cuanto la fila
-- ya quedo parchada (incluida una base nueva, donde V245/V246/V250 ya la
-- insertaron parchada). Y son un reemplazo TEXTUAL del final de la llamada,
-- como en V253, para no reescribir filas enteras que son larguisimas y cuyo
-- unico cambio son los argumentos de cola.
--
-- OJO con el guard: NO se puede usar LIKE '%QUERY.DIA%' porque
-- QUERY.DIAS_GRACIA -- que varias de estas filas ya declaran -- tambien
-- contiene esa cadena; de ahi el ':QUERY.DIA AS DATE' completo.
--
-- Depende de: V216 (fn_unidad_listar con p_dia/p_dias_gracia), V224
-- (fn_actividad_listar y fn_actividad_listar_docente con p_dia),
-- V245 / V246 / V250 (las filas que se reconcilian). Debe correr DESPUES de
-- V253, que parcha el CAST de ?estados= en dos de estas mismas filas -- no
-- se pisan (V253 toca el argumento de estados, esta el final de la llamada),
-- pero el orden importa para que el LIKE de V253 siga encontrando su patron.
-- ===========================================================================

SET search_path TO academico_test, public;

-- ---------------------------------------------------------------------------
-- 1) GET /planeador/unidades -> fn_unidad_listar
--    Gana DOS argumentos de cola: p_dia y p_dias_gracia (el segundo alimenta
--    el umbral de VENCIDA del estado derivado de la unidad).
-- ---------------------------------------------------------------------------
UPDATE public.query q
   SET query = replace(
                 q.query,
                 E'COALESCE(CAST(:QUERY.OFFSET AS INT), 0)\n);',
                 E'COALESCE(CAST(:QUERY.OFFSET AS INT), 0),\n    CAST(:QUERY.DIA AS DATE),\n    COALESCE(CAST(:QUERY.DIAS_GRACIA AS INT), 2)\n);'
               ),
       param_types = COALESCE(q.param_types, '{}'::jsonb)
                     || '{"QUERY.DIA": "DATE", "QUERY.DIAS_GRACIA": "INT"}'::jsonb
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/unidades'
   AND q.http_method     = 'GET'
   AND q.query LIKE '%fn_unidad_listar%'
   AND q.query NOT LIKE '%:QUERY.DIA AS DATE%';

-- ---------------------------------------------------------------------------
-- 2) GET /planeador/actividades -> fn_actividad_listar
--    La fila llama con 16 argumentos: omite p_fk_tfuncionario (posicion 17),
--    que solo usa el tablero del docente. p_dia es la 18, asi que para
--    alcanzarla por posicion hay que rellenar la 17 con NULL = "sin filtro
--    por docente", que es justo lo que esta ruta quiere.
-- ---------------------------------------------------------------------------
UPDATE public.query q
   SET query = replace(
                 q.query,
                 E'COALESCE(CAST(:QUERY.OFFSET AS INT), 0)\n);',
                 E'COALESCE(CAST(:QUERY.OFFSET AS INT), 0),\n    NULL,\n    CAST(:QUERY.DIA AS DATE)\n);'
               ),
       param_types = COALESCE(q.param_types, '{}'::jsonb)
                     || '{"QUERY.DIA": "DATE"}'::jsonb
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/actividades'
   AND q.http_method     = 'GET'
   AND q.query LIKE '%fn_actividad_listar(%'
   AND q.query NOT LIKE '%:QUERY.DIA AS DATE%';

-- ---------------------------------------------------------------------------
-- 3) GET /planeador/actividades/mias -> fn_actividad_listar_docente
--    Aqui p_dia es el ultimo argumento y no hay huecos que rellenar.
-- ---------------------------------------------------------------------------
UPDATE public.query q
   SET query = replace(
                 q.query,
                 E'COALESCE(CAST(:QUERY.OFFSET AS INT), 0)\n);',
                 E'COALESCE(CAST(:QUERY.OFFSET AS INT), 0),\n    CAST(:QUERY.DIA AS DATE)\n);'
               ),
       param_types = COALESCE(q.param_types, '{}'::jsonb)
                     || '{"QUERY.DIA": "DATE"}'::jsonb
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/actividades/mias'
   AND q.http_method     = 'GET'
   AND q.query LIKE '%fn_actividad_listar_docente%'
   AND q.query NOT LIKE '%:QUERY.DIA AS DATE%';

-- ---------------------------------------------------------------------------
-- Red de seguridad: si alguna de las tres filas quedo sin parchar, el
-- endpoint aceptaria ?dia= y lo ignoraria en silencio. Mejor que falle la
-- migracion aqui que descubrirlo en la pantalla.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_faltantes TEXT;
BEGIN
    SELECT string_agg(q.path_template, ', ')
      INTO v_faltantes
      FROM public.query q
      JOIN public.microservice m ON m.id_microservice = q.microservice_id
     WHERE m.serviceid     = 'eval-col'
       AND q.http_method   = 'GET'
       AND q.path_template IN ('/planeador/unidades',
                               '/planeador/actividades',
                               '/planeador/actividades/mias')
       AND (q.query NOT LIKE '%:QUERY.DIA AS DATE%'
            OR q.param_types->>'QUERY.DIA' IS NULL);

    IF v_faltantes IS NOT NULL THEN
        RAISE EXCEPTION 'V279: estas filas de public.query quedaron sin el paginado por dia activo: %', v_faltantes;
    END IF;
END $$;
