-- V-pigse-archivoid-gap — cierra un gap real encontrado documentando
-- la prueba de descarga en Postman: ni GET /api/pigse/documentos ni
-- GET /api/pigse/cumplimiento/listar devolvían el pk_tarchivo, sólo
-- fileName/status/sizeBytes. Sin el id no hay forma HTTP de
-- encadenar "veo qué subió este establecimiento" con
-- "GET /files/download/{archivoId}" -- había que ir a psql.
--
-- Se agregan dos columnas, "archivoId" (el pk crudo, por si algún
-- consumidor futuro lo necesita tal cual) y "downloadUrl" (la ruta
-- YA armada, "/api/files/download/<id>" -- mismo patrón que
-- eval-col/funcionario.archivo_descarga_url, V37 en flujo-archivos).
-- Ambas NULL cuando el documento está PENDIENTE o NO_APLICA (no hay
-- ta.pk_tarchivo que mostrar).
--
-- Exponer el id no es una fuga: tenerlo no concede descarga -- el
-- gateway de acceso real sigue siendo FileAccessService#puedeVer en
-- file-service (propietario o privilegiado, V-pigse-visor / V155).
-- Un Ente Territorial que ya ve el "fileName" en cumplimiento/listar
-- hoy no tenía forma de abrir ese archivo salvo por SQL; con esto la
-- cadena queda completa por HTTP de punta a punta.
--
-- CREATE OR REPLACE no permite cambiar el RETURNS TABLE de una
-- función existente -- hay que DROP + CREATE. fn_pigse_documento_
-- guardar/eliminar llaman a fn_pigse_documentos_listar desde su
-- cuerpo PL/pgSQL (texto opaco para Postgres, sin dependencia de
-- catálogo), así que el orden de DROP no importa; se listan igual en
-- el orden lógico del flujo.
DROP FUNCTION IF EXISTS academico_test.fn_pigse_documento_guardar(BIGINT, VARCHAR, VARCHAR, BIGINT);
DROP FUNCTION IF EXISTS academico_test.fn_pigse_documento_eliminar(BIGINT, VARCHAR, VARCHAR);
DROP FUNCTION IF EXISTS academico_test.fn_pigse_documentos_listar(BIGINT);

CREATE FUNCTION academico_test.fn_pigse_documentos_listar(p_fk_establecimiento BIGINT)
RETURNS TABLE (
    id           TEXT,
    "type"       TEXT,
    "typeName"   TEXT,
    status       TEXT,
    "fileName"   TEXT,
    "uploadedAt" TIMESTAMP,
    "sizeBytes"  BIGINT,
    "archivoId"  BIGINT,
    "downloadUrl" TEXT
) AS $$
    SELECT
        tipos.tipo AS id,
        tipos.tipo AS "type",
        tipos.nombre AS "typeName",
        CASE
            WHEN tipos.tipo = 'PEI' AND te.etnias = 'S' THEN 'NO_APLICA'
            WHEN tipos.tipo = 'PEC' AND te.etnias = 'N' THEN 'NO_APLICA'
            WHEN d.fk_tarchivo IS NOT NULL THEN 'COMPLETO'
            ELSE 'PENDIENTE'
        END AS status,
        ta.nombre AS "fileName",
        ta.created_at AS "uploadedAt",
        ta.peso AS "sizeBytes",
        ta.pk_tarchivo AS "archivoId",
        CASE WHEN ta.pk_tarchivo IS NOT NULL
             THEN '/api/files/download/' || ta.pk_tarchivo
             ELSE NULL
        END AS "downloadUrl"
      FROM academico_test.testablecimiento te
     CROSS JOIN (VALUES
                    ('PEI', 'Proyecto Educativo Institucional (PEI)'),
                    ('PEC', 'Proyecto Educativo Comunitario (PEC)'),
                    ('PMI', 'Plan de Mejoramiento Institucional (PMI)')
                ) AS tipos(tipo, nombre)
      LEFT JOIN academico_test.tdocumento_institucional d
             ON d.fk_testablecimiento = te.pk_establecimiento
            AND d.tipo = tipos.tipo
            AND d.active
      LEFT JOIN academico_test.tarchivo ta ON ta.pk_tarchivo = d.fk_tarchivo
     WHERE te.pk_establecimiento = p_fk_establecimiento
     ORDER BY tipos.tipo;
$$ LANGUAGE sql STABLE;

CREATE FUNCTION academico_test.fn_pigse_documento_guardar(
    p_pk_usuario   BIGINT,
    p_email        VARCHAR,
    p_tipo         VARCHAR,
    p_fk_tarchivo  BIGINT
)
RETURNS TABLE (
    id           TEXT,
    "type"       TEXT,
    "typeName"   TEXT,
    status       TEXT,
    "fileName"   TEXT,
    "uploadedAt" TIMESTAMP,
    "sizeBytes"  BIGINT,
    "archivoId"  BIGINT,
    "downloadUrl" TEXT
) AS $$
DECLARE
    v_fk_establecimiento BIGINT;
    v_pk_doc             BIGINT;
    v_fk_tarchivo_previo  BIGINT;
    v_etnias              academico_test.bool_sn;
BEGIN
    IF p_fk_tarchivo IS NULL THEN
        RAISE EXCEPTION 'pigse: p_fk_tarchivo es obligatorio (archivo no subido)';
    END IF;

    v_fk_establecimiento := academico_test.fn_pigse_mi_establecimiento(p_email);

    SELECT etnias INTO v_etnias
      FROM academico_test.testablecimiento
     WHERE pk_establecimiento = v_fk_establecimiento;

    -- PEI excluyente con PEC / PEC excluyente con PEI (V152) -- se
    -- repite aquí porque DROP + CREATE reemplaza el cuerpo entero de
    -- la función, no sólo el RETURNS TABLE. Mismos mensajes/ERRCODE
    -- que V152, para no romper a nadie que ya los esté parseando.
    IF p_tipo = 'PEI' AND v_etnias = 'S' THEN
        RAISE EXCEPTION 'pigse: PEI no aplica a este establecimiento (etnoeducativo -- usar PEC)'
            USING ERRCODE = '23514';
    ELSIF p_tipo = 'PEC' AND v_etnias = 'N' THEN
        RAISE EXCEPTION 'pigse: PEC no aplica a este establecimiento (no etnoeducativo -- usar PEI)'
            USING ERRCODE = '23514';
    END IF;

    SELECT pk_documento_institucional, fk_tarchivo
      INTO v_pk_doc, v_fk_tarchivo_previo
      FROM academico_test.tdocumento_institucional
     WHERE fk_testablecimiento = v_fk_establecimiento AND tipo = p_tipo AND active;

    IF v_pk_doc IS NULL THEN
        INSERT INTO academico_test.tdocumento_institucional
            (fk_testablecimiento, tipo, fk_tarchivo, created_by)
        VALUES (v_fk_establecimiento, p_tipo, p_fk_tarchivo, p_email)
        RETURNING pk_documento_institucional INTO v_pk_doc;
    ELSE
        UPDATE academico_test.tdocumento_institucional
           SET fk_tarchivo = p_fk_tarchivo, modified_by = p_email, modified_at = CURRENT_TIMESTAMP
         WHERE pk_documento_institucional = v_pk_doc;

        IF v_fk_tarchivo_previo IS NOT NULL THEN
            INSERT INTO academico_test.tdocumento_institucional_hist
                (fk_documento_institucional, fk_tarchivo, reemplazado_by)
            VALUES (v_pk_doc, v_fk_tarchivo_previo, p_email);
        END IF;
    END IF;

    RETURN QUERY
    SELECT * FROM academico_test.fn_pigse_documentos_listar(v_fk_establecimiento)
     WHERE fn_pigse_documentos_listar.id = p_tipo;
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION academico_test.fn_pigse_documento_eliminar(
    p_pk_usuario BIGINT,
    p_email      VARCHAR,
    p_tipo       VARCHAR
)
RETURNS TABLE (
    id           TEXT,
    "type"       TEXT,
    "typeName"   TEXT,
    status       TEXT,
    "fileName"   TEXT,
    "uploadedAt" TIMESTAMP,
    "sizeBytes"  BIGINT,
    "archivoId"  BIGINT,
    "downloadUrl" TEXT
) AS $$
DECLARE
    v_fk_establecimiento BIGINT;
    v_pk_doc             BIGINT;
    v_fk_tarchivo_previo BIGINT;
BEGIN
    v_fk_establecimiento := academico_test.fn_pigse_mi_establecimiento(p_email);

    SELECT pk_documento_institucional, fk_tarchivo
      INTO v_pk_doc, v_fk_tarchivo_previo
      FROM academico_test.tdocumento_institucional
     WHERE fk_testablecimiento = v_fk_establecimiento AND tipo = p_tipo AND active;

    IF v_pk_doc IS NULL OR v_fk_tarchivo_previo IS NULL THEN
        RAISE EXCEPTION 'pigse: tipo % desconocido o ya está PENDIENTE para este establecimiento', p_tipo
            USING ERRCODE = 'P0002';
    END IF;

    UPDATE academico_test.tdocumento_institucional
       SET fk_tarchivo = NULL, modified_by = p_email, modified_at = CURRENT_TIMESTAMP
     WHERE pk_documento_institucional = v_pk_doc;

    INSERT INTO academico_test.tdocumento_institucional_hist
        (fk_documento_institucional, fk_tarchivo, reemplazado_by)
    VALUES (v_pk_doc, v_fk_tarchivo_previo, p_email);

    RETURN QUERY
    SELECT * FROM academico_test.fn_pigse_documentos_listar(v_fk_establecimiento)
     WHERE fn_pigse_documentos_listar.id = p_tipo;
END;
$$ LANGUAGE plpgsql;

-- fn_pigse_cumplimiento_listar NO cambia de RETURNS TABLE (pei/pec/pmi
-- siguen siendo JSONB) -- CREATE OR REPLACE basta. Cada sub-objeto
-- gana "archivoId"/"downloadUrl" de la misma fila lateral que ya
-- traía "fileName", así que Ente Territorial también puede encadenar
-- 100% por HTTP: ver el status en cumplimiento/listar y descargar el
-- archivo con el mismo id, sin pasar por psql.
CREATE OR REPLACE FUNCTION academico_test.fn_pigse_cumplimiento_listar()
RETURNS TABLE (
    id                  BIGINT,
    "establishmentName" TEXT,
    pei                 JSONB,
    pec                 JSONB,
    pmi                 JSONB,
    "globalProgress"    INT
) AS $$
    SELECT
        te.pk_establecimiento AS id,
        te.nombre AS "establishmentName",
        jsonb_build_object('status', d_pei.status, 'fileName', d_pei."fileName",
                            'archivoId', d_pei."archivoId", 'downloadUrl', d_pei."downloadUrl") AS pei,
        jsonb_build_object('status', d_pec.status, 'fileName', d_pec."fileName",
                            'archivoId', d_pec."archivoId", 'downloadUrl', d_pec."downloadUrl") AS pec,
        jsonb_build_object('status', d_pmi.status, 'fileName', d_pmi."fileName",
                            'archivoId', d_pmi."archivoId", 'downloadUrl', d_pmi."downloadUrl") AS pmi,
        CASE
            WHEN (CASE WHEN d_pei.status <> 'NO_APLICA' THEN 1 ELSE 0 END
                  + CASE WHEN d_pec.status <> 'NO_APLICA' THEN 1 ELSE 0 END
                  + CASE WHEN d_pmi.status <> 'NO_APLICA' THEN 1 ELSE 0 END) = 0 THEN 0
            ELSE round(
                100.0 * (
                    CASE WHEN d_pei.status = 'COMPLETO' THEN 1 ELSE 0 END
                    + CASE WHEN d_pec.status = 'COMPLETO' THEN 1 ELSE 0 END
                    + CASE WHEN d_pmi.status = 'COMPLETO' THEN 1 ELSE 0 END
                ) / (
                    CASE WHEN d_pei.status <> 'NO_APLICA' THEN 1 ELSE 0 END
                    + CASE WHEN d_pec.status <> 'NO_APLICA' THEN 1 ELSE 0 END
                    + CASE WHEN d_pmi.status <> 'NO_APLICA' THEN 1 ELSE 0 END
                )
            )
        END AS "globalProgress"
      FROM academico_test.testablecimiento te
      JOIN LATERAL (
              SELECT * FROM academico_test.fn_pigse_documentos_listar(te.pk_establecimiento) WHERE id = 'PEI'
          ) d_pei ON true
      JOIN LATERAL (
              SELECT * FROM academico_test.fn_pigse_documentos_listar(te.pk_establecimiento) WHERE id = 'PEC'
          ) d_pec ON true
      JOIN LATERAL (
              SELECT * FROM academico_test.fn_pigse_documentos_listar(te.pk_establecimiento) WHERE id = 'PMI'
          ) d_pmi ON true
     WHERE te.active
     ORDER BY te.nombre;
$$ LANGUAGE sql STABLE;
