-- ===========================================================================
-- V253 — Planeador educativo: el filtro ?estados= vuelve usable por HTTP
-- (CU-86e311xxp).
--
-- HALLAZGO (probado contra el servidor de test, autenticado como docente):
--   GET /planeador/actividades/mias?estados=EN_EVALUACION  -> 400
--   {"code":"BAD_REQUEST","message":"El parametro 'QUERY.ESTADOS' se declaro
--    como TEXT[] (array) pero el cliente envio String."}
--
-- No es un problema del cliente ni un formato mal escrito: NINGUN formato de
-- array funciona por query-string. Se probaron los tres razonables y los tres
-- dan 400:
--     ?estados=EN_EVALUACION&estados=PROGRAMADA   (repetido)
--     ?estados=["EN_EVALUACION"]                  (JSON)
--     ?estados={EN_EVALUACION}                    (literal PG)
--
-- La causa esta en el binder (common/.../ParamBinder.validateAgainstDeclared):
-- para un tipo declarado en ARRAY_TYPES exige que el valor sea un
-- java.util.List o un array Java. Los valores de un query-string SIEMPRE
-- llegan como String -- solo un body JSON produce List (via Jackson). Por lo
-- tanto un parametro QUERY.* declarado como TEXT[]/BIGINT[] es imposible de
-- satisfacer en un GET: el endpoint queda inutilizable.
--
-- Eran los DOS unicos casos en /planeador/% (verificado sobre param_types):
--     GET /planeador/actividades         -> QUERY.ESTADOS TEXT[]   (V246)
--     GET /planeador/actividades/mias    -> QUERY.ESTADOS TEXT[]   (V250)
-- y justo son el filtro que alimenta el "Ver detalles" de cada tarjeta del
-- tablero, asi que el flujo principal de la pantalla estaba roto.
--
-- ARREGLO: el parametro pasa a declararse VARCHAR (escalar, que si viaja por
-- query-string) y el SQL lo convierte a array con string_to_array(...,','),
-- es decir la lista separada por comas -- exactamente el formato que el front
-- ya venia usando en su propia coleccion (?estados=PENDIENTE_POR_EVALUAR,VENCIDA).
-- NULLIF(TRIM(...),'') deja que "sin filtro" siga siendo NULL, y se recorta
-- cada elemento para tolerar "A, B" con espacios.
--
-- No se toca ninguna funcion PL/pgSQL: fn_actividad_listar / _listar_docente
-- siguen recibiendo VARCHAR[] igual que antes; lo que cambia es como el
-- endpoint arma ese array desde la peticion.
--
-- Depende de: V246 (GET /planeador/actividades), V250 (GET /planeador/actividades/mias).
-- ===========================================================================

SET search_path TO academico_test, public;

-- ---------------------------------------------------------------------------
-- El reemplazo es textual sobre el SQL ya registrado para no reescribir las
-- dos filas completas (son largas y su unico cambio es este CAST): se cambia
--     CAST(:QUERY.ESTADOS AS VARCHAR[])
-- por
--     string_to_array(NULLIF(TRIM(CAST(:QUERY.ESTADOS AS VARCHAR)), ''), ',')
-- y se corrige el tipo declarado en param_types.
-- ---------------------------------------------------------------------------
UPDATE public.query q
   SET query = replace(
                 q.query,
                 'CAST(:QUERY.ESTADOS AS VARCHAR[])',
                 'string_to_array(NULLIF(TRIM(CAST(:QUERY.ESTADOS AS VARCHAR)), ''''), '''','''')'
               ),
       param_types = q.param_types || '{"QUERY.ESTADOS": "VARCHAR"}'::jsonb
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template IN ('/planeador/actividades', '/planeador/actividades/mias')
   AND q.http_method   = 'GET'
   AND q.query LIKE '%CAST(:QUERY.ESTADOS AS VARCHAR[])%';

-- Variante por si alguna fila quedo registrada con el alias TEXT[] en el CAST.
UPDATE public.query q
   SET query = replace(
                 q.query,
                 'CAST(:QUERY.ESTADOS AS TEXT[])',
                 'string_to_array(NULLIF(TRIM(CAST(:QUERY.ESTADOS AS VARCHAR)), ''''), '''','''')'
               ),
       param_types = q.param_types || '{"QUERY.ESTADOS": "VARCHAR"}'::jsonb
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template IN ('/planeador/actividades', '/planeador/actividades/mias')
   AND q.http_method   = 'GET'
   AND q.query LIKE '%CAST(:QUERY.ESTADOS AS TEXT[])%';
