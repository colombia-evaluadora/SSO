-- ===========================================================================
-- V165 - Archivos de matricula: tipo en TLISTA_VALOR y crear/listar/borrar.
-- fn_matricula_archivo_crear_lote vive en V416.
-- ===========================================================================


INSERT INTO academico_test.TLISTA_VALOR (CATEGORIA, NOMBRE, VALOR, CREATED_BY)
SELECT v.categoria, v.nombre, v.valor, 'V165_seed'
  FROM (VALUES
    ('ARCHIVO_MATRICULA'::VARCHAR, 'Certificado de Estudios del Año Anterior'::VARCHAR, '04'::VARCHAR),
    ('ARCHIVO_MATRICULA'::VARCHAR, 'Foto del Estudiante'::VARCHAR,                       '05'::VARCHAR),
    ('ARCHIVO_MATRICULA'::VARCHAR, 'Otros Documentos Relevantes'::VARCHAR,               '06'::VARCHAR)
  ) AS v(categoria, nombre, valor)
 WHERE NOT EXISTS (
       SELECT 1 FROM academico_test.TLISTA_VALOR lv
        WHERE lv.CATEGORIA = v.categoria AND lv.VALOR = v.valor
   );

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_archivo_crear(
    p_pk_usuario_solicitante   BIGINT,
    p_fk_tmatricula            BIGINT,
    p_fk_tarchivo              BIGINT,
    p_fk_tlv_tipo_archivo      BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $function$
DECLARE
    v_fk_establecimiento BIGINT;
    v_id_creado          BIGINT;
BEGIN
    -- -----------------------------------------------------------------
    -- 0. Resolver el EE de la matricula recibida (para el gate).
    -- -----------------------------------------------------------------
    SELECT s.FK_TESTABLECIMIENTO
      INTO v_fk_establecimiento
      FROM academico_test.TMATRICULA m
      JOIN academico_test.TGRUPO gr              ON gr.PK_TGRUPO = m.FK_TGRUPO
      JOIN academico_test.TGRADO g               ON g.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa   ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s                 ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE m.PK_TMATRICULA = p_fk_tmatricula
       AND m.ACTIVE        = TRUE
       AND gr.ACTIVE       = TRUE
       AND g.ACTIVE        = TRUE
       AND pa.ACTIVE       = TRUE
       AND s.ACTIVE        = TRUE;

    IF v_fk_establecimiento IS NULL THEN
        RAISE EXCEPTION 'No se encontro una matricula activa con el identificador %',
            p_fk_tmatricula
            USING ERRCODE = '22023', HINT = 'p_fk_tmatricula debe apuntar a un TMATRICULA activo, con grupo/grado/periodo/sede activos';
    END IF;

    -- -----------------------------------------------------------------
    -- 1. Gate de autorizacion COMPUESTO -- mismo patron de V163/V164.
    -- -----------------------------------------------------------------
    PERFORM academico_test.fn_matricula_gate_escritura(
        p_pk_usuario_solicitante, academico_test.fn_matricula_grupo(p_fk_tmatricula), 'EDITAR');

    -- -----------------------------------------------------------------
    -- 2. Validaciones de existencia.
    -- -----------------------------------------------------------------
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TARCHIVO WHERE PK_TARCHIVO = p_fk_tarchivo
    ) THEN
        -- TARCHIVO no tiene columna ACTIVE segun el DDL -- basta con que
        -- la fila exista (mismo criterio que fn_usu_crear con p_fk_tarchivo_foto).
        RAISE EXCEPTION 'archivo (%) no existe en TARCHIVO', p_fk_tarchivo
            USING ERRCODE = '23503';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_fk_tlv_tipo_archivo AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'tipo de archivo (%) no existe o no esta activo', p_fk_tlv_tipo_archivo
            USING ERRCODE = '23503';
    END IF;

    -- -----------------------------------------------------------------
    -- 3. INSERT.
    -- -----------------------------------------------------------------
    INSERT INTO academico_test.TMATRICULA_ARCHIVO (
        FK_TMATRICULA, FK_TARCHIVO, FK_TLV_TIPO_ARCHIVO,
        CREATED_BY, CREATED_AT, ACTIVE
    ) VALUES (
        p_fk_tmatricula, p_fk_tarchivo, p_fk_tlv_tipo_archivo,
        p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
    )
    RETURNING PK_TMATRICULA_ARCHIVO INTO v_id_creado;

    RETURN v_id_creado;
END;
$function$;

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_archivo_listar_por_matricula(
    p_pk_usuario_solicitante  BIGINT,
    p_fk_tmatricula           BIGINT
)
RETURNS TABLE (
    pk_tmatricula_archivo   BIGINT,
    fk_tarchivo             BIGINT,
    archivo_nombre          VARCHAR,
    archivo_etiqueta        VARCHAR,
    archivo_peso            BIGINT,
    fk_tlv_tipo_archivo     BIGINT,
    tipo_archivo_valor      VARCHAR,
    tipo_archivo_nombre     VARCHAR,
    created_at              TIMESTAMP
)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_fk_establecimiento BIGINT;
BEGIN
    SELECT s.FK_TESTABLECIMIENTO
      INTO v_fk_establecimiento
      FROM academico_test.TMATRICULA m
      JOIN academico_test.TGRUPO gr              ON gr.PK_TGRUPO = m.FK_TGRUPO
      JOIN academico_test.TGRADO g               ON g.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa   ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s                 ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE m.PK_TMATRICULA = p_fk_tmatricula
       AND m.ACTIVE        = TRUE
       AND gr.ACTIVE       = TRUE
       AND g.ACTIVE        = TRUE
       AND pa.ACTIVE       = TRUE
       AND s.ACTIVE        = TRUE;

    IF v_fk_establecimiento IS NULL THEN
        RETURN;
    END IF;

    PERFORM academico_test.fn_matricula_gate_escritura(
        p_pk_usuario_solicitante, academico_test.fn_matricula_grupo(p_fk_tmatricula), 'VER');

    RETURN QUERY
    SELECT
        ma.PK_TMATRICULA_ARCHIVO,
        ma.FK_TARCHIVO,
        a.NOMBRE,
        a.ETIQUETA,
        a.PESO,
        ma.FK_TLV_TIPO_ARCHIVO, ta.VALOR, ta.NOMBRE,
        ma.CREATED_AT
      FROM academico_test.TMATRICULA_ARCHIVO ma
      JOIN academico_test.TARCHIVO a       ON a.PK_TARCHIVO = ma.FK_TARCHIVO
 LEFT JOIN academico_test.TLISTA_VALOR ta  ON ta.PK_LISTA_VALOR = ma.FK_TLV_TIPO_ARCHIVO
     WHERE ma.FK_TMATRICULA = p_fk_tmatricula
       AND ma.ACTIVE        = TRUE
     ORDER BY ta.VALOR ASC, ma.PK_TMATRICULA_ARCHIVO ASC;
END;
$function$;

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_archivo_soft_delete(
    p_pk_usuario_solicitante  BIGINT,
    p_fk_tmatricula           BIGINT
)
RETURNS INTEGER
LANGUAGE plpgsql
AS $function$
DECLARE
    v_n INTEGER;
BEGIN
    UPDATE academico_test.TMATRICULA_ARCHIVO
       SET ACTIVE      = FALSE,
           MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TMATRICULA = p_fk_tmatricula
       AND ACTIVE        = TRUE;

    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END;
$function$;
