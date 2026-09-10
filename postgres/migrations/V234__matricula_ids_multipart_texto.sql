-- =============================================================================
-- V234 -- promover y reubicar leen IDS como TEXTO y lo parsean, porque van por
-- multipart y ahi no existen los tipos.
--
-- -----------------------------------------------------------------------------
-- El problema
-- -----------------------------------------------------------------------------
-- V230 dejo los cuatro endpoints de lista con `CAST(:BODY.IDS AS BIGINT[])`,
-- que es la convencion de los veinte endpoints de lista del catalogo. Funciona
-- para los que reciben JSON -- bulk-delete y corregir -- porque el motor
-- construye el array a partir del array del cuerpo.
--
-- Pero promover y reubicar van por MULTIPART, porque llevan el archivo de
-- soporte, y en multipart/form-data TODOS los valores llegan como cadena. Y
-- CAST(texto AS BIGINT[]) solo acepta la sintaxis de array de Postgres:
--
--   '{222844}'    -> OK
--   '[222844]'    -> ERROR 22P02  malformed array literal
--   '222844'      -> ERROR 22P02
--
-- Un array de JavaScript serializado da '[222844]', que es exactamente la
-- forma que falla. De ahi que corregir funcione y estos dos no.
--
-- -----------------------------------------------------------------------------
-- La solucion
-- -----------------------------------------------------------------------------
-- Se declara BODY.IDS como TEXT y se parsea a mano, aceptando cualquiera de las
-- formas en que un cliente razonable puede mandar la lista:
--
--   '[1,2]'    '{1,2}'    '1,2'    '1'    ' [1, 2] '
--
-- Se recortan los delimitadores de los dos dialectos ([] de JSON y {} de
-- Postgres) mas los espacios, se corta por coma y se convierte cada pieza. Los
-- elementos vacios se descartan, asi que una coma sobrante o un espacio no
-- rompen nada. Verificado contra las siete formas de arriba.
--
-- -----------------------------------------------------------------------------
-- Por que bulk-delete y corregir NO cambian
-- -----------------------------------------------------------------------------
-- Van por JSON y con BIGINT[] ya funcionan -- corregir esta probado en la
-- plataforma. Pasarlos a TEXT seria peor: para un parametro TEXT el motor
-- tendria que serializar el array del cuerpo, y si lo aplanara quedaria solo el
-- primer elemento, perdiendo el resto en silencio. Es el riesgo que ya
-- documentaba V169. Cada endpoint usa la forma que corresponde a su transporte:
--
--   JSON       ->  "BODY.IDS": "BIGINT[]"   CAST(:BODY.IDS AS BIGINT[])
--   multipart  ->  "BODY.IDS": "TEXT"       parse explicito
--
-- La asimetria no es arbitraria: multipart no tiene tipos y JSON si.
--
-- Idempotente: el UPDATE es no-op si ya esta aplicado.
-- =============================================================================

UPDATE public.query
   SET query = REPLACE(
           query,
           'CAST(:BODY.IDS AS BIGINT[])',
           'ARRAY(SELECT TRIM(t)::BIGINT
             FROM UNNEST(string_to_array(TRIM(BOTH ''[]{} '' FROM :BODY.IDS), '','')) AS t
            WHERE TRIM(t) <> '''')'),
       param_types = param_types || '{"BODY.IDS": "TEXT"}'::jsonb
 WHERE uuid IN (
           'q-mtb2d9k4-cobmatpro1',   -- 263 promover  (multipart: lleva SOPORTE)
           'q-mtb2d9k4-cobmatreu1'    -- 264 reubicar  (multipart: lleva SOPORTE)
       )
   AND query LIKE '%CAST(:BODY.IDS AS BIGINT[])%';
