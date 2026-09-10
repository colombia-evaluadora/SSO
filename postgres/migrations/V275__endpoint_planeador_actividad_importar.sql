-- =============================================================================
-- V275 -- Endpoint de importacion de actividades del planeador.
--
--   POST /planeador/actividades/importar   ->  fn_actividad_importar (V274)
--
-- -----------------------------------------------------------------------------
-- Un solo endpoint para validar y para aplicar
-- -----------------------------------------------------------------------------
-- El front necesita dos pasos: primero ensenar "12 actividades, 3 con
-- problemas" y despues, si el usuario acepta, escribir. Son la MISMA operacion
-- con la misma resolucion de catalogos y el mismo destino, asi que se exponen
-- por el mismo endpoint con la bandera SOLO_VALIDAR en vez de duplicar la ruta.
-- Dos rutas serian dos caminos que hay que mantener iguales, y en cuanto
-- divergieran el usuario veria un informe verde y una escritura fallida.
--
-- SOLO_VALIDAR llega por defecto en TRUE desde la funcion: si el front se
-- olvida del campo, la llamada NO escribe. Equivocarse hacia el lado que no
-- toca la base es lo unico aceptable aqui.
--
-- -----------------------------------------------------------------------------
-- El cuerpo
-- -----------------------------------------------------------------------------
--   ACTIVIDADES                 el array del archivo, tal cual  (obligatorio)
--   FK_TASIGNATURA              destino, si las actividades no traen
--   FK_TGRUPO                   _identificadores
--   FK_TGRADO
--   FK_TFUNCIONARIO             dueño de las unidades que haya que crear
--   FK_TLV_CALCULO_DEFINITIVA   forma de calculo de esas unidades
--   FK_REFERENTE_CURRICULAR     referente de esas unidades; tiene que ser de
--                               enfoque EVALUATIVO si alguna actividad trae
--                               instrumento de evaluacion
--   SOLO_VALIDAR                TRUE informa sin escribir; FALSE aplica
--
-- Los cuatro FK_ del destino son opcionales porque un archivo salido de nuestro
-- exportador ya trae _identificadores; para un archivo de un tercero son
-- obligatorios en la practica, y la funcion lo dice fila por fila.
--
-- ACTIVIDADES va como JSONB, no como TEXT: este endpoint recibe JSON. Si algun
-- dia se llamara por multipart -- subir el .json como fichero -- habria que
-- recibirlo en TEXT y castear, porque en multipart no hay tipos. Mismo aviso
-- que en V273.
--
-- Se referencia como :BODY.ACTIVIDADES y no como :BODY_RAW.ACTIVIDADES aunque
-- sea un array de objetos. En el catalogo conviven las dos formas, pero TODO el
-- modulo del planeador usa :BODY -- incluido
-- PUT /planeador/actividades/:ID/adaptaciones, que recibe justamente un array
-- de objetos -- asi que esa es la forma probada aqui. Las de BODY_RAW son de
-- otros modulos.
--
-- Idempotente: borra la fila por uuid antes de insertarla.
-- =============================================================================

DELETE FROM public.query WHERE uuid = 'q-planeador-actividades-importar-001';

INSERT INTO public.query (
    uuid, query, type, public_end, captcha, detail, action, style,
    createddate, microservice_id, path_template, execution_mode,
    out_param_names, http_method, param_types, cacheable, cache_ttl_seconds
)
SELECT
    'q-planeador-actividades-importar-001',
    $q$SELECT academico_test.fn_actividad_importar(
    p_pk_usuario_solicitante    => public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    p_actividades               => CAST(:BODY.ACTIVIDADES AS JSONB),
    p_fk_tasignatura            => CAST(:BODY.FK_TASIGNATURA AS BIGINT),
    p_fk_tgrupo                 => CAST(:BODY.FK_TGRUPO AS BIGINT),
    p_fk_tgrado                 => CAST(:BODY.FK_TGRADO AS BIGINT),
    p_fk_tfuncionario           => CAST(:BODY.FK_TFUNCIONARIO AS BIGINT),
    p_fk_tlv_calculo_definitiva => CAST(:BODY.FK_TLV_CALCULO_DEFINITIVA AS BIGINT),
    p_fk_referente_curricular   => CAST(:BODY.FK_REFERENTE_CURRICULAR AS BIGINT),
    p_solo_validar              => COALESCE(CAST(:BODY.SOLO_VALIDAR AS BOOLEAN), TRUE)
) AS resultado$q$,
    q.type, FALSE, FALSE,
    'Importa actividades del planeador desde el formato JSON de intercambio, el mismo que produce /planeador/actividades/exportar. Con SOLO_VALIDAR = true (por defecto) no escribe nada: devuelve el informe fila por fila con las etiquetas que no casan con los catalogos y las reglas del dominio que el archivo incumple. Con SOLO_VALIDAR = false aplica, y es todo o nada: si alguna fila tiene errores no se escribe ninguna. El destino sale de _identificadores de cada actividad si viene y, si no, de los FK_ del cuerpo; nunca se resuelve por nombre.',
    q.action, q.style,
    CURRENT_TIMESTAMP, q.microservice_id,
    '/planeador/actividades/importar',
    q.execution_mode, NULL, 'POST',
    '{"BODY.ACTIVIDADES": "JSONB",
      "BODY.FK_TASIGNATURA": "BIGINT",
      "BODY.FK_TGRUPO": "BIGINT",
      "BODY.FK_TGRADO": "BIGINT",
      "BODY.FK_TFUNCIONARIO": "BIGINT",
      "BODY.FK_TLV_CALCULO_DEFINITIVA": "BIGINT",
      "BODY.FK_REFERENTE_CURRICULAR": "BIGINT",
      "BODY.SOLO_VALIDAR": "BOOLEAN"}'::JSONB,
    FALSE, COALESCE(q.cache_ttl_seconds, 0)
  FROM public.query q
 WHERE q.path_template = '/planeador/actividades'
   AND q.http_method   = 'GET'
 LIMIT 1;
