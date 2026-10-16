-- ===========================================================================
-- V555.4 — Wrappers del guardado "todo o nada" de Gestión documental.
-- Mismo gate que fn_documento_guardar (V522): establecimiento del usuario,
-- fecha límite (excepción o global) y tipo según la modalidad del EE. Los
-- roles los pone role_query en V555.5.
-- Depende de: V555.2 (validaciones), V555.3 (núcleos), V261 (fn_mi_establecimiento).
-- ===========================================================================

CREATE OR REPLACE FUNCTION pigse.fn_documento_archivo_preparar(
    p_pk_usuario  BIGINT,
    p_email       VARCHAR,
    p_tipo        VARCHAR,
    p_categoria   VARCHAR,
    p_fk_tarchivo BIGINT
)
RETURNS TABLE("archivoId" BIGINT, "fileName" TEXT, "sizeBytes" BIGINT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_fk_establecimiento BIGINT;
BEGIN
    IF p_fk_tarchivo IS NULL THEN
        RAISE EXCEPTION 'pigse: p_fk_tarchivo es obligatorio (archivo no subido)'
            USING ERRCODE = '22023';
    END IF;
    PERFORM pigse.fn_documento_validar_categoria(p_tipo, p_categoria);

    v_fk_establecimiento := pigse.fn_mi_establecimiento(p_email);
    PERFORM pigse.fn_documento_validar_fecha_limite(v_fk_establecimiento);
    PERFORM pigse.fn_documento_validar_tipo_aplica(v_fk_establecimiento, p_tipo);

    RETURN QUERY SELECT * FROM pigse.fn_documento_archivo_preparar_interno(p_fk_tarchivo);
END;
$$;

COMMENT ON FUNCTION pigse.fn_documento_archivo_preparar(BIGINT, VARCHAR, VARCHAR, VARCHAR, BIGINT) IS
    'POST /documentos/archivos (multipart via file-service): sube UN archivo de un anexo SIN enlazarlo; devuelve archivoId/fileName/sizeBytes para mandarlo despues en PUT /documentos/:TIPO/anexos. Gate: EE del usuario, fecha limite (23514), tipo segun ETNIAS (23514), categoria del tipo (22023).';

CREATE OR REPLACE FUNCTION pigse.fn_documento_guardar_lote(
    p_pk_usuario BIGINT,
    p_email      VARCHAR,
    p_tipo       VARCHAR,
    p_anexos     JSONB,
    p_quitar     JSONB
)
RETURNS TABLE(
    id TEXT, type TEXT, "typeName" TEXT, categoria TEXT, "categoriaName" TEXT,
    status TEXT, "fileName" TEXT, "uploadedAt" TIMESTAMP, "sizeBytes" BIGINT,
    "archivoId" BIGINT, "downloadUrl" TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_fk_establecimiento BIGINT;
BEGIN
    IF p_tipo IS NULL OR p_tipo NOT IN ('PEI', 'PEC', 'PMI', 'PFI') THEN
        RAISE EXCEPTION 'pigse: tipo de documento invalido: %', COALESCE(p_tipo, '(vacio)')
            USING ERRCODE = '22023';
    END IF;

    v_fk_establecimiento := pigse.fn_mi_establecimiento(p_email);
    PERFORM pigse.fn_documento_validar_fecha_limite(v_fk_establecimiento);
    PERFORM pigse.fn_documento_validar_tipo_aplica(v_fk_establecimiento, p_tipo);

    PERFORM pigse.fn_audit_declarar(p_pk_usuario,
        format('Guardado de los anexos del documento %s', p_tipo), v_fk_establecimiento);

    PERFORM pigse.fn_documento_guardar_lote_interno(v_fk_establecimiento, p_email, p_tipo, p_anexos, p_quitar);

    RETURN QUERY SELECT * FROM pigse.fn_documento_categorias_listar(v_fk_establecimiento, p_tipo);
END;
$$;

COMMENT ON FUNCTION pigse.fn_documento_guardar_lote(BIGINT, VARCHAR, VARCHAR, JSONB, JSONB) IS
    'PUT /documentos/:TIPO/anexos: guarda TODO el documento en una transaccion (ANEXOS [{categoria, archivoId}] de POST /documentos/archivos, QUITAR [archivoId]). Rechaza 23514 si al terminar falta un anexo obligatorio. Gate igual a fn_documento_guardar. Devuelve los anexos del tipo (fn_documento_categorias_listar).';
