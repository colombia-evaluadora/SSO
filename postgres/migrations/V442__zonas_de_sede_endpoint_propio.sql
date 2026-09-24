-- ===========================================================================
-- V442 - Las zonas de una sede salen por su propio endpoint.
--
--   GET /establecimientos/sedes/zonas   nuevo
--   GET /select/:CATEGORIA              vuelve a ser el catalogo generico
--
--
-- QUE SE DESHACE Y POR QUE
--   El V414 metio la regla de zonas dentro del catalogo generico: le agrego a
--   GET /select/:CATEGORIA un parametro opcional ESTABLECIMIENTO que solo
--   tenia efecto cuando la categoria era ZONA. Funciona, y el argumento de
--   entonces --no crear una ruta paralela para una diferencia chica-- no era
--   malo. Pero deja un endpoint que hace dos cosas: es un catalogo por
--   categoria Y, para un valor particular de esa categoria, aplica una regla
--   de negocio de otro modulo.
--
--   El costo real de eso no es estetico. Ese SELECT lo usan unas quince
--   pantallas; cualquiera que lo lea para entender otra cosa se encuentra una
--   condicion sobre ZONA que no le incumbe, y cualquiera que manana quiera
--   filtrar OTRA categoria tiene el precedente de seguir agregandole ramas al
--   mismo WHERE. Un catalogo generico deja de serlo en cuanto conoce un caso
--   particular.
--
--   Asi que la regla se muda a un endpoint que solo habla de eso, y el
--   catalogo vuelve exactamente a lo que era: categoria adentro, filas
--   afuera.
--
--
-- LA REGLA NO CAMBIA
--   Sigue viviendo en fn_est_zonas_sede_permitidas (V414), que es la que usan
--   tambien fn_sed_crear, fn_sed_actualizar y la sede automatica de
--   fn_est_crear. Aqui solo cambia QUIEN la expone al front. Si cambiara la
--   regla, se cambia alli y estos cuatro se enteran solos.
--
--     EE Urbana           -> Urbana
--     EE Rural            -> Rural
--     EE mixto o sin zona -> Urbana o Rural
--
--
-- SIN ESTABLECIMIENTO, LAS DOS -- PERO NUNCA LA TERCERA
--   El parametro es opcional porque el front lo llama antes de que el usuario
--   elija el EE (en el alta el selector arranca vacio). En ese caso salen
--   Urbana y Rural.
--
--   Lo que NO sale nunca, ni con EE ni sin el, es "Urbana y Rural". Y ese es
--   el otro arreglo que trae esta migracion: por el endpoint viejo, un alta
--   sin EE elegido devolvia las TRES opciones, de modo que se podia elegir
--   una zona que fn_sed_crear despues rechazaba. El error llegaba al guardar,
--   cuando ya no se entiende de donde salio. Aca esa opcion no se ofrece.
--
--   La condicion se escribe como "distinto de 3" y no como una lista blanca
--   {1,2}, porque eso es literalmente la regla: "Urbana y Rural" describe un
--   CONJUNTO de sedes, que es lo que el establecimiento es, no un edificio.
--
--
-- POR QUE UN QUERY PARAM Y NO /establecimientos/:ID/zonas-sede
--   Porque el establecimiento es opcional -- ver arriba --, y una ruta con el
--   id en el path obligaria al front a no llamar, o a inventar un id, en el
--   caso en que todavia no hay ninguno elegido. Con el parametro opcional hay
--   una sola llamada y una sola forma de respuesta.
--
-- Idempotente: UPDATE de la fila que ya existe e INSERT ... ON CONFLICT DO
-- NOTHING para la nueva y sus roles.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 1. El endpoint nuevo: las zonas que una SEDE puede tener.
--
--    Va en SQL en la fila de public.query, igual que el catalogo generico del
--    que sale, y no en una fn_*: son dos condiciones sobre TLISTA_VALOR, y la
--    unica que es negocio ya esta encapsulada en fn_est_zonas_sede_permitidas.
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action, style)
SELECT
    'eval-col-establecimientos-sedes-zonas-001',
    'select lv.pk_lista_valor, lv.nombre, lv.valor, lv.accion
  from academico_test.tlista_valor lv
 where lv.categoria = ''ZONA''
   and lv.active
   -- Una sede es un edificio y esta en un sitio: "Urbana y Rural" describe
   -- un CONJUNTO de sedes, que es lo que el establecimiento es. Nunca se
   -- ofrece, haya o no establecimiento.
   and lv.valor <> ''3''
   -- Con establecimiento, ademas, manda su zona. Sin el --el alta antes de
   -- elegirlo-- salen las dos que quedan.
   and (CAST(:QUERY.ESTABLECIMIENTO AS BIGINT) IS NULL
        OR lv.valor = ANY (academico_test.fn_est_zonas_sede_permitidas(
                               CAST(:QUERY.ESTABLECIMIENTO AS BIGINT))))
 order by lv.valor asc',
    'postgres', false, false,
    m.id_microservice,
    '/establecimientos/sedes/zonas', 'SELECT', 'GET',
    '{"QUERY.ESTABLECIMIENTO": "BIGINT"}'::jsonb,
    NULL,
    'Las zonas que una SEDE puede tener, para el select del alta y la edicion. Devuelve las mismas columnas que el catalogo generico (pk_lista_valor, nombre, valor, accion), asi que el front lo consume igual. ESTABLECIMIENTO es OPCIONAL: con el, las opciones se acotan a lo que permite la zona de ese establecimiento -- Urbana si es Urbana, Rural si es Rural, las dos si es mixto o no declaro zona (fn_est_zonas_sede_permitidas, V414, que es la misma regla que validan fn_sed_crear y fn_sed_actualizar); sin el -- el alta antes de elegir establecimiento -- salen Urbana y Rural. "Urbana y Rural" NUNCA sale, con o sin establecimiento: describe un conjunto de sedes, que es lo que el establecimiento es, no un edificio. Antes esto vivia como un parametro opcional de GET /select/:CATEGORIA (V414); se separo para que el catalogo generico no conozca un caso particular, y de paso porque por aquella via un alta sin establecimiento elegido ofrecia las tres opciones y dejaba elegir una que fn_sed_crear despues rechazaba.',
    'establecimientos-sedes-zonas', 'DEFAULT'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;


-- ---------------------------------------------------------------------------
-- 2. Roles: los mismos que el catalogo del que sale.
--
--    Quien podia leer /select/ZONA puede leer esto. Se copian en vez de
--    escribirse a mano para que no se desincronicen.
-- ---------------------------------------------------------------------------
INSERT INTO public.role_query (query_id, role_id)
SELECT nuevo.id_query, rq.role_id
  FROM public.query nuevo
  JOIN public.query catalogo ON catalogo.microservice_id = nuevo.microservice_id
                            AND catalogo.path_template   = '/select/:CATEGORIA'
                            AND catalogo.http_method     = 'GET'
  JOIN public.role_query rq  ON rq.query_id = catalogo.id_query
 WHERE nuevo.uuid = 'eval-col-establecimientos-sedes-zonas-001'
ON CONFLICT DO NOTHING;


-- ---------------------------------------------------------------------------
-- 3. El catalogo generico vuelve a ser generico.
--
--    Queda igual que antes del V414: la categoria entra por la ruta, las
--    filas salen, y no sabe nada de ZONA ni de establecimientos. Se toca solo
--    la fila de eval-col, que es la unica que el V414 habia modificado -- la
--    de pigse apunta a otro esquema y nunca participo de esto.
-- ---------------------------------------------------------------------------
UPDATE public.query q
   SET query = 'select lv.pk_lista_valor, lv.nombre, lv.valor, lv.accion
  from academico_test.tlista_valor lv
 where lv.categoria = UPPER(CAST(:PARAM.CATEGORIA AS VARCHAR))
   and lv.active
 order by lv.valor asc',
       param_types = '{"PARAM.CATEGORIA": "VARCHAR"}'::jsonb,
       detail = 'Catalogo generico de TLISTA_VALOR por categoria: la categoria entra por la ruta y salen sus filas activas (pk_lista_valor, nombre, valor, accion), ordenadas por valor. Lo usan unas quince pantallas. Entre V414 y V442 acepto ademas un parametro opcional ESTABLECIMIENTO que solo tenia efecto con la categoria ZONA; esa regla se mudo a GET /establecimientos/sedes/zonas para que este catalogo no conozca un caso particular, y el parametro dejo de existir aqui.'
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/select/:CATEGORIA'
   AND q.http_method     = 'GET';
