-- =============================================================================
-- V230 -- Corrige la declaracion de los parametros de los endpoints de
-- matricula: las listas de identificadores, las claves BODY_RAW y el archivo de
-- soporte. Los tres impedian que la peticion llegara a ejecutar la query.
--
-- NUMERACION: de aqui en adelante las migraciones nuevas del modulo arrancan en
-- 230. Los numeros 180-226 son de otra rama que todavia no se ha mergeado; se
-- deja ese rango libre para no colisionar al integrar.
--
-- =============================================================================
-- PARTE 1 -- "placeholders sin tipo declarado: [BODY.IDS]"
-- =============================================================================
-- El motor valida la clave que llega en el cuerpo contra `BODY.<NOMBRE>`, que es
-- lo que deriva del JSON. El texto de la query, en cambio, puede pedir el valor
-- de dos formas:
--
--   :BODY.X      -- el valor ya procesado por el motor
--   :BODY_RAW.X  -- el JSON crudo, sin aplanar
--
-- Declarar SOLO `BODY_RAW.X` deja la clave entrante sin tipo: el motor busca
-- `BODY.X`, no lo encuentra y aborta. Se confirma en el catalogo -- los seis
-- endpoints que usan BODY_RAW y funcionan declaran AMBAS claves:
-- /areas/:ID/asignaturas (44), /escalas (53), /horarios (79), /menus/order
-- (129), /roles/:ROLEID/menus (132), /asistencias/registrar (266).
--
-- 1.a IDS -- se adopta la convencion de la casa en vez de arreglar BODY_RAW.
--     Para una lista de numeros no hace falta JSONB:
--
--       CAST(:BODY.IDS AS BIGINT[])      con   "BODY.IDS": "BIGINT[]"
--
--     Es lo que hacen los veinte endpoints de lista del catalogo
--     (/grados/eliminacion-masiva, /escalas/bulk-delete, /grupos/bulk-delete,
--     /plan-asignaturas/bulk-delete, /periodo-evaluacion/bulk-delete...). El
--     comentario de V169 justificaba BODY_RAW diciendo que ":BODY.IDS aplanaria
--     el array"; esos veinte lo desmienten. El rodeo con
--     jsonb_array_elements_text era innecesario y mas fragil.
--
--     Afecta a bulk-delete (227), promover (263), reubicar (264) y corregir
--     (298). El 227 tenia la misma falla latente desde V169 y nunca habria
--     funcionado desde la plataforma.
--
-- 1.b OTROS_DOCUMENTOS_RELEVANTES -- aca el JSONB SI hace falta: no es una
--     lista de numeros sino de OBJETOS ({pkTmatriculaArchivo, fkTarchivo}). Se
--     le agrega la clave `BODY.` que faltaba y se conserva la `BODY_RAW.` que
--     usa el texto de la query. Afecta al POST del alta (215) y al PATCH de
--     edicion (294); el 215 tenia el mismo hueco y solo no habia salido porque
--     nadie habia enviado ese campo.
--
-- =============================================================================
-- PARTE 2 -- "El campo 'SOPORTE' no esta declarado como archivo para esta ruta"
-- =============================================================================
-- Ese error lo devuelve el file-service, no el motor de queries: encontro la
-- ruta pero no reconocio SOPORTE como campo de archivo. Hay dos causas posibles
-- y se corrigen las dos, porque desde la base no se pueden distinguir.
--
-- 2.a EL METODO. En todo el catalogo, los endpoints con campos FILE son POST
--     (/establecimientos 40, /tmp-icono-simbolo 144, /documentos/upload 195,
--     el alta de matricula 215) o PATCH (/establecimientos/:ID 87,
--     /establecimientos/funcionarios/:ID 119, la edicion de matricula 294,
--     /usuarios/:ID 295). Los UNICOS dos en PUT eran promover y reubicar. Se
--     pasan a POST, que es ademas lo que ya usa el bulk-delete del modulo para
--     una accion de coleccion con cuerpo.
--
--     corregir (298) pasa tambien a POST aunque no lleve archivo: los tres son
--     acciones hermanas de la misma pantalla y tenerlas en verbos distintos
--     solo complica al front. Las acciones individuales de estado
--     (retirar 245, reingresar 248, reactivar 252) NO se tocan: no llevan
--     archivo, ya funcionan y el front ya las consume por PUT.
--
-- 2.b EL SUFIJO "!". Se habia declarado FILE:matricula! para marcar el soporte
--     como obligatorio. La unica otra declaracion con "!" del catalogo es
--     /documentos/upload, que es el endpoint propio del file-service y puede
--     estar tratado aparte. El alta de matricula, que si funciona, usa
--     FILE:matricula sin sufijo. Se iguala a esa forma.
--
--     No se pierde la obligatoriedad: fn_matricula_mover_lote ya rechaza con
--     22023 si el soporte no llega ("Se debe adjuntar el soporte de la
--     accion"). La validacion vive en la funcion, que es donde no se puede
--     saltar.
--
-- Idempotente: todos los UPDATE son no-ops si ya estan aplicados.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- 1.a IDS -> BODY.IDS de tipo BIGINT[], sin BODY_RAW
-- ---------------------------------------------------------------------------
UPDATE public.query
   SET query = REPLACE(
           query,
           'ARRAY(SELECT jsonb_array_elements_text(CAST(:BODY_RAW.IDS AS JSONB))::BIGINT)',
           'CAST(:BODY.IDS AS BIGINT[])'),
       param_types = (param_types - 'BODY_RAW.IDS')
                     || '{"BODY.IDS": "BIGINT[]"}'::jsonb
 WHERE uuid IN (
           'q-mtb2d9k4-cobmatdel2',   -- 227 bulk-delete
           'q-mtb2d9k4-cobmatpro1',   -- 263 promover
           'q-mtb2d9k4-cobmatreu1',   -- 264 reubicar
           'q-mtb2d9k4-cobmatcor1'    -- 298 corregir
       )
   AND param_types ? 'BODY_RAW.IDS';


-- ---------------------------------------------------------------------------
-- 1.b OTROS_DOCUMENTOS_RELEVANTES -> se agrega la clave BODY. que faltaba
-- ---------------------------------------------------------------------------
UPDATE public.query
   SET param_types = param_types
                     || '{"BODY.OTROS_DOCUMENTOS_RELEVANTES": "JSONB"}'::jsonb
 WHERE uuid IN (
           'q-mtb2d9k4-cobmatd1',     -- 215 POST  /matricula
           'q-mtb2d9k4-cobmatedi1'    -- 294 PATCH /matricula/:ID
       )
   AND param_types ? 'BODY_RAW.OTROS_DOCUMENTOS_RELEVANTES'
   AND NOT param_types ? 'BODY.OTROS_DOCUMENTOS_RELEVANTES';


-- ---------------------------------------------------------------------------
-- 2.a Las tres acciones de coleccion pasan a POST
-- ---------------------------------------------------------------------------
UPDATE public.query
   SET http_method = 'POST'
 WHERE uuid IN (
           'q-mtb2d9k4-cobmatpro1',   -- 263 promover
           'q-mtb2d9k4-cobmatreu1',   -- 264 reubicar
           'q-mtb2d9k4-cobmatcor1'    -- 298 corregir
       )
   AND http_method <> 'POST';


-- ---------------------------------------------------------------------------
-- 2.b SOPORTE sin el sufijo "!", igual que los archivos del alta
-- ---------------------------------------------------------------------------
UPDATE public.query
   SET param_types = param_types || '{"BODY.SOPORTE": "FILE:matricula"}'::jsonb
 WHERE uuid IN (
           'q-mtb2d9k4-cobmatpro1',   -- 263 promover
           'q-mtb2d9k4-cobmatreu1'    -- 264 reubicar
       )
   AND param_types ->> 'BODY.SOPORTE' <> 'FILE:matricula';


-- ---------------------------------------------------------------------------
-- 2.c MOTIVO tambien pierde el "!": la obligatoriedad la valida la funcion
--     (22023 "Se debe indicar el motivo de la accion"), y dejar el sufijo solo
--     en estos dos endpoints los separa del resto del catalogo sin ganar nada.
-- ---------------------------------------------------------------------------
UPDATE public.query
   SET param_types = param_types || '{"BODY.MOTIVO": "TEXT"}'::jsonb
 WHERE uuid IN (
           'q-mtb2d9k4-cobmatpro1',
           'q-mtb2d9k4-cobmatreu1'
       )
   AND param_types ->> 'BODY.MOTIVO' <> 'TEXT';
