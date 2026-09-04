-- =============================================================================
-- V240 -- El editar de matricula acepta la key del acudiente que debe quedar.
--
-- Empalma con el parametro nuevo de fn_matricula_directa_actualizar
-- (p_pk_usuario_acudiente, ver V177). El front manda SIEMPRE
-- BODY.PK_USUARIO_ACUDIENTE con la persona que debe figurar como acudiente de
-- esa matricula:
--
--   * coincide con el que ya esta -> no hay sustitucion. Con
--     ACTUALIZAR_ACUDIENTE en true se editan sus datos en sitio.
--   * es otra persona            -> se sustituye. PARENTESCO pasa a ser
--     obligatorio (TNUCLEO_FAMILIAR.FK_TLV_PARENTESCO es NOT NULL y no se
--     puede deducir), y el resto de campos del acudiente alimentan la
--     CREACION de sus registros, no la edicion de los del anterior.
--   * no se manda                -> el acudiente de la matricula no se toca.
--
-- La persona la resuelve antes el front con el endpoint de alta de usuario,
-- que la devuelve si ya existe en vez de duplicarla. Aqui solo llega su
-- PK_TUSUARIO.
--
-- Idempotente: el UPDATE no vuelve a añadir el parametro si ya esta.
-- =============================================================================

UPDATE public.query
   SET query = REPLACE(
           query,
           '    p_pk_tpadre => CAST(:BODY.PK_TPADRE AS BIGINT),',
           '    p_pk_usuario_acudiente => CAST(:BODY.PK_USUARIO_ACUDIENTE AS BIGINT),' || CHR(10) ||
           '    p_pk_tpadre => CAST(:BODY.PK_TPADRE AS BIGINT),'
       ),
       param_types = param_types || '{"BODY.PK_USUARIO_ACUDIENTE": "BIGINT"}'::JSONB
 WHERE uuid = 'q-mtb2d9k4-cobmatedi1'
   AND query NOT ILIKE '%PK_USUARIO_ACUDIENTE%';
