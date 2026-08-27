-- Dos huecos reales encontrados al probar la exclusión PEI/PEC y la
-- visibilidad de cumplimiento para Ente Territorial:
--
--   1. fn_pigse_documento_guardar (V149) nunca validaba ETNIAS -- la
--      exclusión sólo se aplicaba en la LECTURA
--      (fn_pigse_documentos_listar mostraba NO_APLICA), pero nada
--      impedía subir el tipo excluido. Se agrega el mismo chequeo
--      como guard de escritura.
--
--   2. Los 5 roles "Ente Territorial" (V148: DIRECTOR_ENTE_TERRITORIAL,
--      JEFE_SISTEMA_ENTE_TERRITORIAL, JEFE_AREA_PLANEACION/COBERTURA/
--      CALIDAD) nunca quedaron atados a cumplimiento/metricas,
--      cumplimiento/listar ni a la ruta de menú "Monitoreo y
--      Cumplimiento" (V149 sólo los dio a PIGSE-ADMINISTRADOR/
--      PIGSE-SECRETARIA_TERRITORIAL) -- un jefe de ente territorial no
--      podía ver el tablero, a pesar de ser exactamente el tipo de
--      usuario para el que existe.

-- 1. Guard de escritura -- mismo criterio que el status de lectura
--    (ETNIAS='S' -> sólo PEC; 'N' -> sólo PEI; NULL -> sin restricción,
--    mismo comportamiento laxo que ya tenía la lectura para ese caso).
CREATE OR REPLACE FUNCTION academico_test.fn_pigse_documento_guardar(
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
    "sizeBytes"  BIGINT
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

    -- V152 -- PEI y PEC son excluyentes (ver V149): un establecimiento
    -- etnoeducativo (ETNIAS='S') sólo admite PEC; uno no-etnoeducativo
    -- ('N') sólo admite PEI. ETNIAS NULL (dato sin capturar) no
    -- restringe -- mismo criterio laxo que fn_pigse_documentos_listar.
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

-- 2. Rutas y queries de cumplimiento visibles para los 5 roles de
--    Ente Territorial.
INSERT INTO role_route (route_id, role_id)
SELECT r.id_route, ro.id_role
  FROM route r
 CROSS JOIN role ro
 WHERE r.path = '/monitoreo-cumplimiento'
   AND ro.name IN ('PIGSE-DIRECTOR_ENTE_TERRITORIAL', 'PIGSE-JEFE_SISTEMA_ENTE_TERRITORIAL',
                    'PIGSE-JEFE_AREA_PLANEACION', 'PIGSE-JEFE_AREA_COBERTURA', 'PIGSE-JEFE_AREA_CALIDAD')
   AND NOT EXISTS (SELECT 1 FROM role_route rr WHERE rr.route_id = r.id_route AND rr.role_id = ro.id_role);

INSERT INTO role_query (query_id, role_id)
SELECT q.id_query, ro.id_role
  FROM query q
 CROSS JOIN role ro
 WHERE q.uuid IN ('pigse-cumplimiento-metricas', 'pigse-cumplimiento-listar')
   AND ro.name IN ('PIGSE-DIRECTOR_ENTE_TERRITORIAL', 'PIGSE-JEFE_SISTEMA_ENTE_TERRITORIAL',
                    'PIGSE-JEFE_AREA_PLANEACION', 'PIGSE-JEFE_AREA_COBERTURA', 'PIGSE-JEFE_AREA_CALIDAD')
   AND NOT EXISTS (SELECT 1 FROM role_query rq WHERE rq.query_id = q.id_query AND rq.role_id = ro.id_role);

-- my-menus ya está abierto a "todos los autenticados de PIGSE" listados
-- en V149, pero ese set no incluía los roles de Ente Territorial.
INSERT INTO role_query (query_id, role_id)
SELECT q.id_query, ro.id_role
  FROM query q
 CROSS JOIN role ro
 WHERE q.uuid = 'pigse-my-menus'
   AND ro.name IN ('PIGSE-DIRECTOR_ENTE_TERRITORIAL', 'PIGSE-JEFE_SISTEMA_ENTE_TERRITORIAL',
                    'PIGSE-JEFE_AREA_PLANEACION', 'PIGSE-JEFE_AREA_COBERTURA', 'PIGSE-JEFE_AREA_CALIDAD')
   AND NOT EXISTS (SELECT 1 FROM role_query rq WHERE rq.query_id = q.id_query AND rq.role_id = ro.id_role);
