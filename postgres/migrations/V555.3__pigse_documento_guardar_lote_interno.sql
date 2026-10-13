-- ===========================================================================
-- V555.3 — Núcleos del guardado "todo o nada" de Gestión documental.
--   * fn_documento_archivo_preparar_interno: datos de un archivo recién
--     subido (aún sin enlazar a ningún anexo).
--   * fn_documento_guardar_lote_interno: aplica N anexos nuevos y N bajas en
--     una sola transacción y al final exige el documento completo; si falta
--     un obligatorio, RAISE y no queda nada escrito.
-- Depende de: V555.2 (validaciones), V522 (tabla de historial).
-- ===========================================================================

CREATE OR REPLACE FUNCTION pigse.fn_documento_archivo_preparar_interno(
    p_fk_tarchivo BIGINT
)
RETURNS TABLE("archivoId" BIGINT, "fileName" TEXT, "sizeBytes" BIGINT)
LANGUAGE sql
STABLE
AS $$
    -- pigse.tarchivo y no v_archivo: file-service activa la fila DESPUÉS de
    -- que esta consulta responde, así que aquí todavía está active = false.
    SELECT a.pk_tarchivo, a.nombre::TEXT, a.peso
      FROM pigse.tarchivo a
     WHERE a.pk_tarchivo = p_fk_tarchivo;
$$;

COMMENT ON FUNCTION pigse.fn_documento_archivo_preparar_interno(BIGINT) IS
    'INTERNO: archivoId/fileName/sizeBytes de un archivo recien subido a pigse.tarchivo (aun inactivo). No lo enlaza a ningun anexo.';

CREATE OR REPLACE FUNCTION pigse.fn_documento_guardar_lote_interno(
    p_fk_establecimiento BIGINT,
    p_email              VARCHAR,
    p_tipo               VARCHAR,
    p_anexos             JSONB,
    p_quitar             JSONB
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_anexo      JSONB;
    v_categoria  VARCHAR;
    v_archivo    BIGINT;
    v_pk_doc     BIGINT;
    v_previo     BIGINT;
    v_cambios    INTEGER := 0;
BEGIN
    IF jsonb_typeof(COALESCE(p_anexos, '[]'::jsonb)) <> 'array'
       OR jsonb_typeof(COALESCE(p_quitar, '[]'::jsonb)) <> 'array' THEN
        RAISE EXCEPTION 'pigse: ANEXOS y QUITAR deben ser listas'
            USING ERRCODE = '22023';
    END IF;

    -- Serializa guardados concurrentes del mismo documento: la verificación
    -- de "completo" del final tiene que ver lo que escribió el otro.
    PERFORM pg_advisory_xact_lock(hashtext('pigse.documento:' || p_fk_establecimiento || ':' || p_tipo));

    -- Un anexo de archivo único no puede venir dos veces en el mismo lote.
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(p_anexos, '[]'::jsonb)) e
                WHERE e->>'categoria' IS DISTINCT FROM 'PLAN_ESTUDIOS'
                GROUP BY e->>'categoria' HAVING count(*) > 1) THEN
        RAISE EXCEPTION 'pigse: cada anexo (salvo Plan de estudios) admite un solo archivo por guardado'
            USING ERRCODE = '22023';
    END IF;

    -- Bajas primero: así "quitar uno de Plan de estudios y subir otro" no
    -- depende del orden en que el front arme las listas.
    FOR v_archivo IN SELECT (q #>> '{}')::BIGINT FROM jsonb_array_elements(COALESCE(p_quitar, '[]'::jsonb)) q LOOP
        SELECT t.pk_documento_institucional INTO v_pk_doc
          FROM pigse.tdocumento_institucional t
         WHERE t.fk_testablecimiento = p_fk_establecimiento
           AND t.tipo = p_tipo
           AND t.fk_tarchivo = v_archivo
           AND t.active;

        IF v_pk_doc IS NULL THEN
            RAISE EXCEPTION 'pigse: el archivo % no es un anexo vigente de % en este establecimiento', v_archivo, p_tipo
                USING ERRCODE = 'P0002';
        END IF;

        UPDATE pigse.tdocumento_institucional
           SET active = (categoria IS DISTINCT FROM 'PLAN_ESTUDIOS'),
               fk_tarchivo = NULL, modified_by = p_email, modified_at = CURRENT_TIMESTAMP
         WHERE pk_documento_institucional = v_pk_doc;

        INSERT INTO pigse.tdocumento_institucional_hist (fk_documento_institucional, fk_tarchivo, reemplazado_by)
        VALUES (v_pk_doc, v_archivo, p_email);
        v_cambios := v_cambios + 1;
    END LOOP;

    FOR v_anexo IN SELECT e FROM jsonb_array_elements(COALESCE(p_anexos, '[]'::jsonb)) e LOOP
        v_categoria := v_anexo->>'categoria';
        v_archivo   := (v_anexo->>'archivoId')::BIGINT;

        PERFORM pigse.fn_documento_validar_categoria(p_tipo, v_categoria);
        IF v_archivo IS NULL THEN
            RAISE EXCEPTION 'pigse: falta el archivo del anexo %', v_categoria
                USING ERRCODE = '22023';
        END IF;
        PERFORM pigse.fn_documento_validar_archivo_libre(p_email, v_archivo);

        IF v_categoria = 'PLAN_ESTUDIOS' THEN
            INSERT INTO pigse.tdocumento_institucional (fk_testablecimiento, tipo, categoria, fk_tarchivo, created_by)
            VALUES (p_fk_establecimiento, p_tipo, v_categoria, v_archivo, p_email);
        ELSE
            v_pk_doc := NULL;
            v_previo := NULL;
            SELECT t.pk_documento_institucional, t.fk_tarchivo INTO v_pk_doc, v_previo
              FROM pigse.tdocumento_institucional t
             WHERE t.fk_testablecimiento = p_fk_establecimiento
               AND t.tipo = p_tipo
               AND t.categoria = v_categoria
               AND t.active;

            IF v_pk_doc IS NULL THEN
                INSERT INTO pigse.tdocumento_institucional (fk_testablecimiento, tipo, categoria, fk_tarchivo, created_by)
                VALUES (p_fk_establecimiento, p_tipo, v_categoria, v_archivo, p_email);
            ELSE
                UPDATE pigse.tdocumento_institucional
                   SET fk_tarchivo = v_archivo, modified_by = p_email, modified_at = CURRENT_TIMESTAMP
                 WHERE pk_documento_institucional = v_pk_doc;

                IF v_previo IS NOT NULL THEN
                    INSERT INTO pigse.tdocumento_institucional_hist (fk_documento_institucional, fk_tarchivo, reemplazado_by)
                    VALUES (v_pk_doc, v_previo, p_email);
                END IF;
            END IF;
        END IF;
        v_cambios := v_cambios + 1;
    END LOOP;

    IF v_cambios = 0 THEN
        RAISE EXCEPTION 'pigse: no hay cambios para guardar'
            USING ERRCODE = '22023';
    END IF;

    PERFORM pigse.fn_documento_validar_completo(p_fk_establecimiento, p_tipo);
END;
$$;

COMMENT ON FUNCTION pigse.fn_documento_guardar_lote_interno(BIGINT, VARCHAR, VARCHAR, JSONB, JSONB) IS
    'INTERNO: aplica bajas (p_quitar: [archivoId]) y anexos (p_anexos: [{categoria, archivoId}]) de UN documento en una transaccion; reemplazar pasa el previo al historial, Plan de estudios suma filas. Termina con fn_documento_validar_completo: si falta un obligatorio, nada queda escrito.';
