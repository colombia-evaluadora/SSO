-- =============================================================================
-- V165 -- Manejo de TMATRICULA_ARCHIVO: enlazar archivos ya subidos
-- (via file-service, ver docs/subida-archivos-a-queries.md) a una
-- TMATRICULA.
--
-- Dos conceptos que se confunden facil pero son independientes:
--   - TARCHIVO.ETIQUETA: la carpeta S3 (`FILE:clasificacion` en
--     param_types del catalogo). Ya existe la etiqueta 'matricula' (96
--     filas reales) -- se reutiliza tal cual para los 5 campos de archivo
--     del formulario, igual que 'perfilUsuario' es UNA sola etiqueta para
--     toda foto de perfil sin importar el rol. No hace falta una etiqueta
--     distinta por tipo de documento.
--   - TMATRICULA_ARCHIVO.FK_TLV_TIPO_ARCHIVO: catalogo de NEGOCIO (que
--     tipo de documento es), sin relacion con donde quedo guardado el
--     binario. Vive en TLISTA_VALOR/CATEGORIA='ARCHIVO_MATRICULA'.
--
-- Ese catalogo solo traia 2 de los 5 tipos que pide el formulario
-- ("Documento de Identidad", "Certificado Medico") -- se completan aqui
-- los 3 que faltan (certificado de estudios del año anterior, foto del
-- estudiante, otros documentos relevantes), con VALOR consecutivo (04-06)
-- a los 3 ya existentes (01-03). Insert idempotente (WHERE NOT EXISTS),
-- mismo patron que V120.
-- =============================================================================

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

-- =============================================================================
-- fn_matricula_archivo_crear -- funcion GRANULAR: enlaza UN TARCHIVO ya
-- subido a UNA TMATRICULA, con su tipo de documento.
--
-- Gate: mismo patron que V163/V164, resuelto via
-- TMATRICULA -> TGRUPO -> TGRADO -> TPERIODO_ACADEMICO -> TSEDE -> EE.
-- =============================================================================

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
        RAISE EXCEPTION 'No se encontro una matricula activa con ese identificador'
            USING ERRCODE = '22023', HINT = 'p_fk_tmatricula debe apuntar a un TMATRICULA activo, con grupo/grado/periodo/sede activos';
    END IF;

    -- -----------------------------------------------------------------
    -- 1. Gate de autorizacion COMPUESTO -- mismo patron de V163/V164.
    -- -----------------------------------------------------------------
    IF academico_test.fn_puede_afectar_establecimiento(p_pk_usuario_solicitante) THEN
        NULL;
    ELSIF EXISTS (
        SELECT 1
          FROM academico_test.TFUNCIONARIO f
          JOIN academico_test.TESTABLECIMIENTO e
            ON e.FK_TFUNCIONARIO_RECTOR = f.PK_TFUNCIONARIO
         WHERE e.PK_ESTABLECIMIENTO = v_fk_establecimiento
           AND e.ACTIVE             = TRUE
           AND f.ACTIVE             = TRUE
           AND f.FK_TUSUARIO        = p_pk_usuario_solicitante
    ) THEN
        NULL;
    ELSIF EXISTS (
        SELECT 1
          FROM academico_test.TFUNCIONARIO f
          JOIN academico_test.TESTABLECIMIENTO e
            ON e.FK_TFUNCIONARIO_SECRETARIA = f.PK_TFUNCIONARIO
         WHERE e.PK_ESTABLECIMIENTO = v_fk_establecimiento
           AND e.ACTIVE             = TRUE
           AND f.ACTIVE             = TRUE
           AND f.FK_TUSUARIO        = p_pk_usuario_solicitante
    ) THEN
        NULL;
    ELSIF EXISTS (
        SELECT 1
          FROM academico_test.TSEDE_USUARIO su
          JOIN academico_test.TSEDE s
            ON s.PK_TSEDE = su.FK_TSEDE
         WHERE s.FK_TESTABLECIMIENTO = v_fk_establecimiento
           AND s.ACTIVE              = TRUE
           AND su.ACTIVE             = TRUE
           AND su.FK_TROL            = 8
           AND su.FK_TUSUARIO        = p_pk_usuario_solicitante
    ) THEN
        NULL;
    ELSE
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

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

-- =============================================================================
-- fn_matricula_archivo_crear_lote -- funcion ORQUESTADORA: registra de una
-- sola llamada todos los archivos de soporte de una matricula, resolviendo
-- internamente el fk_tlv_tipo_archivo de cada uno contra
-- TLISTA_VALOR/CATEGORIA='ARCHIVO_MATRICULA' (por VALOR, no por PK
-- hardcodeado -- portable entre entornos). Llama a fn_matricula_archivo_crear
-- una vez por archivo:
--   - Documento de identidad del estudiante* -- OBLIGATORIO
--   - Certificado de estudios del año anterior* -- OBLIGATORIO
--   - Certificado medico del estudiante -- opcional
--   - Foto del estudiante -- opcional
--   - Otros documentos relevantes -- opcional, 0..N (arrastra un solo
--     tipo_archivo generico "Otros Documentos Relevantes" para todos)
--
-- p_fk_tarchivo_otros llega como JSONB -- un array de pk_tarchivo, p.ej.
-- '[123, 456]'::jsonb. NOTA: no esta probado todavia como castea esto la
-- capa de :BODY.X del catalogo (:CAST AS JSONB contra un campo de un
-- query registrado) -- se deja asi por ahora segun lo acordado, se ajusta
-- si hace falta cuando se registre la query real.
-- =============================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_archivo_crear_lote(
    p_pk_usuario_solicitante              BIGINT,
    p_fk_tmatricula                       BIGINT,
    p_fk_tarchivo_documento_identidad     BIGINT,
    p_fk_tarchivo_certificado_estudios    BIGINT,
    p_fk_tarchivo_certificado_medico      BIGINT DEFAULT NULL,
    p_fk_tarchivo_foto                    BIGINT DEFAULT NULL,
    p_fk_tarchivo_otros                   JSONB  DEFAULT NULL
)
RETURNS TABLE (
    pk_tmatricula_archivo   BIGINT,
    fk_tlv_tipo_archivo     BIGINT
)
LANGUAGE plpgsql
AS $function$
DECLARE
    v_tipo_doc_identidad  BIGINT;
    v_tipo_cert_estudios  BIGINT;
    v_tipo_cert_medico    BIGINT;
    v_tipo_foto           BIGINT;
    v_tipo_otros          BIGINT;
    v_pk                  BIGINT;
    v_item                JSONB;
BEGIN
    -- -----------------------------------------------------------------
    -- 0. Obligatoriedad de los dos archivos requeridos por el formulario.
    -- -----------------------------------------------------------------
    IF p_fk_tarchivo_documento_identidad IS NULL THEN
        RAISE EXCEPTION 'El documento de identidad del estudiante es obligatorio'
            USING ERRCODE = '23502';
    END IF;
    IF p_fk_tarchivo_certificado_estudios IS NULL THEN
        RAISE EXCEPTION 'El certificado de estudios del año anterior es obligatorio'
            USING ERRCODE = '23502';
    END IF;

    -- -----------------------------------------------------------------
    -- 1. Resolver cada tipo de archivo contra el catalogo, por VALOR
    --    (no por PK hardcodeado -- ver V165 mas arriba para el seed).
    -- -----------------------------------------------------------------
    SELECT PK_LISTA_VALOR INTO v_tipo_doc_identidad
      FROM academico_test.TLISTA_VALOR WHERE CATEGORIA = 'ARCHIVO_MATRICULA' AND VALOR = '01' AND ACTIVE = TRUE;
    SELECT PK_LISTA_VALOR INTO v_tipo_cert_medico
      FROM academico_test.TLISTA_VALOR WHERE CATEGORIA = 'ARCHIVO_MATRICULA' AND VALOR = '02' AND ACTIVE = TRUE;
    SELECT PK_LISTA_VALOR INTO v_tipo_cert_estudios
      FROM academico_test.TLISTA_VALOR WHERE CATEGORIA = 'ARCHIVO_MATRICULA' AND VALOR = '04' AND ACTIVE = TRUE;
    SELECT PK_LISTA_VALOR INTO v_tipo_foto
      FROM academico_test.TLISTA_VALOR WHERE CATEGORIA = 'ARCHIVO_MATRICULA' AND VALOR = '05' AND ACTIVE = TRUE;
    SELECT PK_LISTA_VALOR INTO v_tipo_otros
      FROM academico_test.TLISTA_VALOR WHERE CATEGORIA = 'ARCHIVO_MATRICULA' AND VALOR = '06' AND ACTIVE = TRUE;

    IF v_tipo_doc_identidad IS NULL OR v_tipo_cert_estudios IS NULL THEN
        RAISE EXCEPTION 'El catalogo ARCHIVO_MATRICULA no tiene los tipos de documento requeridos (VALOR 01/04) -- ejecute el seed de V165'
            USING ERRCODE = '23503';
    END IF;

    -- -----------------------------------------------------------------
    -- 2. Obligatorios.
    -- -----------------------------------------------------------------
    v_pk := academico_test.fn_matricula_archivo_crear(
        p_pk_usuario_solicitante, p_fk_tmatricula, p_fk_tarchivo_documento_identidad, v_tipo_doc_identidad);
    RETURN QUERY SELECT v_pk, v_tipo_doc_identidad;

    v_pk := academico_test.fn_matricula_archivo_crear(
        p_pk_usuario_solicitante, p_fk_tmatricula, p_fk_tarchivo_certificado_estudios, v_tipo_cert_estudios);
    RETURN QUERY SELECT v_pk, v_tipo_cert_estudios;

    -- -----------------------------------------------------------------
    -- 3. Opcionales, uno-a-uno.
    -- -----------------------------------------------------------------
    IF p_fk_tarchivo_certificado_medico IS NOT NULL THEN
        v_pk := academico_test.fn_matricula_archivo_crear(
            p_pk_usuario_solicitante, p_fk_tmatricula, p_fk_tarchivo_certificado_medico, v_tipo_cert_medico);
        RETURN QUERY SELECT v_pk, v_tipo_cert_medico;
    END IF;

    IF p_fk_tarchivo_foto IS NOT NULL THEN
        v_pk := academico_test.fn_matricula_archivo_crear(
            p_pk_usuario_solicitante, p_fk_tmatricula, p_fk_tarchivo_foto, v_tipo_foto);
        RETURN QUERY SELECT v_pk, v_tipo_foto;
    END IF;

    -- -----------------------------------------------------------------
    -- 4. "Otros documentos relevantes" -- 0..N, cantidad variable.
    --    TransformadorMultipart (file-service) entrega el campo como
    --    escalar cuando el multipart trae UN solo archivo bajo ese
    --    nombre de campo, y como array cuando trae varios ("Un solo
    --    fichero en el campo -> id suelto. Varios -> lista.") -- hay que
    --    aceptar ambas formas, no solo la de array.
    -- -----------------------------------------------------------------
    IF p_fk_tarchivo_otros IS NOT NULL THEN
        IF jsonb_typeof(p_fk_tarchivo_otros) = 'array' THEN
            FOR v_item IN SELECT * FROM jsonb_array_elements(p_fk_tarchivo_otros)
            LOOP
                v_pk := academico_test.fn_matricula_archivo_crear(
                    p_pk_usuario_solicitante, p_fk_tmatricula, (v_item#>>'{}')::BIGINT, v_tipo_otros);
                RETURN QUERY SELECT v_pk, v_tipo_otros;
            END LOOP;
        ELSE
            v_pk := academico_test.fn_matricula_archivo_crear(
                p_pk_usuario_solicitante, p_fk_tmatricula, (p_fk_tarchivo_otros#>>'{}')::BIGINT, v_tipo_otros);
            RETURN QUERY SELECT v_pk, v_tipo_otros;
        END IF;
    END IF;
END;
$function$;
