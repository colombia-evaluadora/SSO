-- ===========================================================================
-- V262 -- PIGSE deja de leer academico_test.
--
-- Cierra el movimiento que empezaron V256 (DDL), V259 (backfill de
-- establecimientos) y V261 (documentos, cumplimiento y sus funciones en el
-- schema pigse): copia los documentos institucionales ya cargados y repunta
-- las 7 filas de public.query del microservicio `pigse` a pigse.*.
--
-- Los contratos HTTP NO cambian: mismo path_template, mismo http_method,
-- mismos param_types y mismos binds. Solo cambia el schema/nombre invocado.
--
-- academico_test no se toca: sus tablas, filas y funciones fn_pigse_* quedan
-- intactas (huerfanas a proposito; su retiro se decide aparte).
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. Backfill de documentos institucionales
--
-- Remapeo por pigse.TESTABLECIMIENTO.FK_TESTABLECIMIENTO_ORIGEN (trazabilidad
-- que dejo V259). Los documentos de un EE sin mapeo se SALTAN, no revientan.
--
-- fk_tarchivo se copia tal cual y NO se duplica la fila de TARCHIVO: el PK de
-- archivo es global (public.seq_pk_tarchivo, V147), la vista pigse.v_archivo
-- (V261) lee los metadatos de cualquiera de los dos schemas, y
-- public.file_reference_location sigue siendo la autoridad de donde vive cada
-- blob. Los archivos historicos se quedan en academico_test.tarchivo.
--
-- Idempotente por WHERE NOT EXISTS sobre claves naturales -- nunca
-- ON CONFLICT: los unicos de este repo son parciales (WHERE ACTIVE = true).
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_doc       BIGINT := 0;
    v_hist      BIGINT := 0;
    v_skip_doc  BIGINT := 0;
    v_skip_hist BIGINT := 0;
BEGIN

DROP TABLE IF EXISTS tmp_v262_doc;
CREATE TEMP TABLE tmp_v262_doc ON COMMIT DROP AS
SELECT o.pk_documento_institucional AS pk_origen,
       m.pk_est_pigse,
       o.tipo, o.fk_tarchivo, o.created_by, o.created_at,
       o.modified_by, o.modified_at, o.active
  FROM academico_test.tdocumento_institucional o
  JOIN LATERAL (
        SELECT min(pe.pk_establecimiento) AS pk_est_pigse
          FROM pigse.testablecimiento pe
         WHERE pe.fk_testablecimiento_origen = o.fk_testablecimiento
           AND pe.active
       ) m ON m.pk_est_pigse IS NOT NULL;

SELECT count(*) INTO v_skip_doc
  FROM academico_test.tdocumento_institucional o
 WHERE NOT EXISTS (SELECT 1 FROM tmp_v262_doc t WHERE t.pk_origen = o.pk_documento_institucional);

-- Clave natural de la copia: EE destino + tipo + created_at. No hay columna de
-- origen en tdocumento_institucional (V261 la calca de V149), y esa terna es
-- unica del lado origen por el unico parcial (fk_testablecimiento, tipo).
INSERT INTO pigse.tdocumento_institucional (
    fk_testablecimiento, tipo, fk_tarchivo, created_by, created_at,
    modified_by, modified_at, active)
SELECT t.pk_est_pigse, t.tipo, t.fk_tarchivo, t.created_by, t.created_at,
       t.modified_by, t.modified_at, t.active
  FROM tmp_v262_doc t
 WHERE NOT EXISTS (
        SELECT 1 FROM pigse.tdocumento_institucional p
         WHERE p.fk_testablecimiento = t.pk_est_pigse
           AND p.tipo = t.tipo
           AND p.created_at = t.created_at);
GET DIAGNOSTICS v_doc = ROW_COUNT;

INSERT INTO pigse.tdocumento_institucional_hist (
    fk_documento_institucional, fk_tarchivo, reemplazado_by, reemplazado_at)
SELECT pd.pk_documento_institucional, h.fk_tarchivo, h.reemplazado_by, h.reemplazado_at
  FROM academico_test.tdocumento_institucional_hist h
  JOIN tmp_v262_doc t ON t.pk_origen = h.fk_documento_institucional
  JOIN pigse.tdocumento_institucional pd
    ON pd.fk_testablecimiento = t.pk_est_pigse
   AND pd.tipo = t.tipo
   AND pd.created_at = t.created_at
 WHERE NOT EXISTS (
        SELECT 1 FROM pigse.tdocumento_institucional_hist p
         WHERE p.fk_documento_institucional = pd.pk_documento_institucional
           AND p.fk_tarchivo = h.fk_tarchivo
           AND p.reemplazado_at = h.reemplazado_at);
GET DIAGNOSTICS v_hist = ROW_COUNT;

SELECT count(*) INTO v_skip_hist
  FROM academico_test.tdocumento_institucional_hist h
 WHERE NOT EXISTS (SELECT 1 FROM tmp_v262_doc t WHERE t.pk_origen = h.fk_documento_institucional);

RAISE NOTICE 'V262 copiados -> tdocumento_institucional=% tdocumento_institucional_hist=%',
    v_doc, v_hist;
RAISE NOTICE 'V262 saltados -> documentos sin establecimiento mapeado=% historicos sin documento mapeado=%',
    v_skip_doc, v_skip_hist;

END $$;

-- ---------------------------------------------------------------------------
-- 2. Repunte de las filas de public.query
--
-- UPDATE, no INSERT: las filas ya existen y un INSERT ... WHERE NOT EXISTS
-- seria un no-op silencioso. Se localizan por uuid, acotando por el
-- microservicio pigse; /cumplimiento/query se creo con gen_random_uuid()
-- (V197), asi que tambien se acepta el par (path_template, http_method).
--
-- pigse-my-menus NO esta en la lista: solo lee public.*.
-- ---------------------------------------------------------------------------
UPDATE public.query q
   SET query = v.nueva
  FROM (VALUES
    ('pigse-establecimientos', '/establecimientos', 'GET',
     'SELECT pk_establecimiento AS id, nombre AS "establishmentName", codigo AS codigo
            FROM pigse.testablecimiento
           WHERE active
           ORDER BY nombre'),

    ('pigse-documentos-listar', '/documentos', 'GET',
     'SELECT * FROM pigse.fn_documentos_listar(
              pigse.fn_mi_establecimiento(:CONTEXT.EMAIL))'),

    ('pigse-documentos-upload', '/documentos/upload', 'POST',
     'SELECT * FROM pigse.fn_documento_guardar(
              p_pk_usuario   => public.fn_get_pigse_usuario_id(:CONTEXT.USER_ID::BIGINT),
              p_email        => CAST(:CONTEXT.EMAIL AS VARCHAR),
              p_tipo         => CAST(:BODY.TIPO AS VARCHAR),
              p_fk_tarchivo  => CAST(:BODY.ARCHIVO AS BIGINT)
          )'),

    ('pigse-documentos-eliminar', '/documentos/:TIPO', 'PATCH',
     'SELECT * FROM pigse.fn_documento_eliminar(
              p_pk_usuario => public.fn_get_pigse_usuario_id(:CONTEXT.USER_ID::BIGINT),
              p_email      => CAST(:CONTEXT.EMAIL AS VARCHAR),
              p_tipo       => CAST(:PARAM.TIPO AS VARCHAR)
          )'),

    ('pigse-cumplimiento-listar', '/cumplimiento/listar', 'GET',
     'SELECT * FROM pigse.fn_cumplimiento_listar()'),

    ('pigse-cumplimiento-metricas', '/cumplimiento/metricas', 'GET',
     'SELECT * FROM pigse.fn_cumplimiento_metricas()'),

    ('de092259-7d86-4e6b-bdc6-c1cd6fd05aa7', '/cumplimiento/query', 'POST',
     'SELECT * FROM pigse.fn_cumplimiento_listar_paginado(
    CAST(:BODY.FILTERS.SEARCH AS VARCHAR),
    CAST(:BODY.FILTERS.PEI AS VARCHAR[]),
    CAST(:BODY.FILTERS.PEC AS VARCHAR[]),
    CAST(:BODY.FILTERS.PMI AS VARCHAR[]),
    CAST(:BODY.SORTING.ID AS VARCHAR),
    CAST(:BODY.SORTING.DESC AS BOOLEAN),
    CAST(:BODY.PAGEINDEX AS INTEGER),
    CAST(:BODY.PAGESIZE AS INTEGER)
);')
  ) AS v(uuid, path_template, http_method, nueva)
 WHERE q.microservice_id = (SELECT id_microservice FROM public.microservice WHERE serviceid = 'pigse')
   AND (q.uuid = v.uuid OR (q.path_template = v.path_template AND q.http_method = v.http_method))
   AND q.query <> v.nueva;

-- ---------------------------------------------------------------------------
-- 3. El destino de archivos de pigse
--
-- V149 lo habia apuntado a academico_test.tarchivo porque ahi vivia el
-- dominio; ahora vive en pigse. requesturi no cambia.
-- ---------------------------------------------------------------------------
UPDATE public.microservice
   SET file_storage_schema = 'pigse',
       file_storage_table  = 'tarchivo'
 WHERE serviceid = 'pigse'
   AND (file_storage_schema, file_storage_table) IS DISTINCT FROM ('pigse', 'tarchivo');

-- ---------------------------------------------------------------------------
-- 4. Verificacion
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_pigse     BIGINT;
    v_coleval   BIGINT;
    v_pendiente TEXT;
BEGIN
    SELECT count(*) FILTER (WHERE q.query LIKE '%pigse.%'),
           count(*) FILTER (WHERE q.query LIKE '%academico_test%'),
           string_agg(q.uuid, ', ') FILTER (WHERE q.query LIKE '%academico_test%')
      INTO v_pigse, v_coleval, v_pendiente
      FROM public.query q
      JOIN public.microservice m ON m.id_microservice = q.microservice_id
     WHERE m.serviceid = 'pigse';

    RAISE NOTICE 'V262 queries de pigse -> apuntando a pigse.*=%', v_pigse;

    IF v_coleval > 0 THEN
        RAISE NOTICE 'V262 ATENCION: % fila(s) de query de pigse siguen mencionando academico_test: %',
            v_coleval, v_pendiente;
    ELSE
        RAISE NOTICE 'V262 OK: ninguna fila de query del microservicio pigse menciona academico_test';
    END IF;
END $$;
