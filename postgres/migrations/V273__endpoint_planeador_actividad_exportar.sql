-- =============================================================================
-- V273 -- Endpoint de exportacion de actividades del planeador.
--
--   POST /planeador/actividades/exportar   ->  fn_actividad_exportar (V272)
--
-- -----------------------------------------------------------------------------
-- Por que POST y no GET
-- -----------------------------------------------------------------------------
-- Es una lectura, asi que GET seria lo natural, pero uno de los filtros es una
-- LISTA de identificadores y meterla en el query string es incomodo de generar
-- y de leer. Se sigue el precedente que ya existe en el catalogo para lo mismo:
-- POST /establecimientos/funcionarios/reporte, que tambien es una lectura que
-- recibe filtros en el cuerpo.
--
-- -----------------------------------------------------------------------------
-- El cuerpo
-- -----------------------------------------------------------------------------
--   IDS            lista de PK_TACTIVIDAD  (opcional)
--   PK_TUNIDAD     todas las de una unidad (opcional)
--   FK_TASIGNATURA todas las de una asignatura (opcional)
--   FK_TGRUPO      todas las de un grupo (opcional)
--
-- Los filtros se combinan con AND y hay que enviar al menos uno; sin ninguno la
-- funcion responde 22023 en vez de intentar exportar la base entera.
--
-- IDS se declara BIGINT[] porque este endpoint recibe JSON. Si algun dia se
-- llamara como multipart habria que pasarlo a TEXT con parseo tolerante: en
-- multipart no hay tipos, todo llega como texto, y CAST(texto AS BIGINT[])
-- acepta '{1,2}' pero revienta con '[1,2]' (22P02). Ya paso en los endpoints de
-- movimientos de matricula -- ver V230 y V234.
--
-- Idempotente: borra la fila por uuid antes de insertarla.
-- =============================================================================

DELETE FROM public.query WHERE uuid = 'q-planeador-actividades-exportar-001';

INSERT INTO public.query (
    uuid, query, type, public_end, captcha, detail, action, style,
    createddate, microservice_id, path_template, execution_mode,
    out_param_names, http_method, param_types, cacheable, cache_ttl_seconds
)
SELECT
    'q-planeador-actividades-exportar-001',
    $q$SELECT academico_test.fn_actividad_exportar(
    p_pk_usuario_solicitante => public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    p_pk_tactividades        => CAST(:BODY.IDS AS BIGINT[]),
    p_pk_tunidad             => CAST(:BODY.PK_TUNIDAD AS BIGINT),
    p_fk_tasignatura         => CAST(:BODY.FK_TASIGNATURA AS BIGINT),
    p_fk_tgrupo              => CAST(:BODY.FK_TGRUPO AS BIGINT)
) AS actividades$q$,
    q.type, FALSE, FALSE,
    'Exporta actividades del planeador al formato JSON de intercambio. Filtros combinables por lista de IDS, unidad, asignatura o grupo; hay que enviar al menos uno. Cada actividad incluye su unidad_meta, el instrumento de evaluacion segun corresponda (rubrica, cotejo, escala u otro) y un bloque _identificadores con las PKs para poder reimportarla sin resolver nombres.',
    q.action, q.style,
    CURRENT_TIMESTAMP, q.microservice_id,
    '/planeador/actividades/exportar',
    q.execution_mode, NULL, 'POST',
    '{"BODY.IDS": "BIGINT[]",
      "BODY.PK_TUNIDAD": "BIGINT",
      "BODY.FK_TASIGNATURA": "BIGINT",
      "BODY.FK_TGRUPO": "BIGINT"}'::JSONB,
    FALSE, COALESCE(q.cache_ttl_seconds, 0)
  FROM public.query q
 WHERE q.path_template = '/planeador/actividades'
   AND q.http_method   = 'GET'
 LIMIT 1;
