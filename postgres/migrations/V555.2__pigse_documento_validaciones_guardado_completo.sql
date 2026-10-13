-- ===========================================================================
-- V555.2 — Validaciones del guardado "todo o nada" de Gestión documental.
-- Un documento (PEI/PEC/PMI/PFI) solo se guarda con TODOS sus anexos
-- obligatorios; cada regla va en su propia función para que el núcleo de
-- V555.3 y los wrappers de V555.4 las compongan sin duplicarlas.
-- Depende de: V522 (fecha límite y excepciones), V554 (categorías PMI/PFI).
-- ===========================================================================

CREATE OR REPLACE FUNCTION pigse.fn_documento_validar_categoria(
    p_tipo      VARCHAR,
    p_categoria VARCHAR
)
RETURNS VOID
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_tipo IS NULL OR p_tipo NOT IN ('PEI', 'PEC', 'PMI', 'PFI') THEN
        RAISE EXCEPTION 'pigse: tipo de documento invalido: %', COALESCE(p_tipo, '(vacio)')
            USING ERRCODE = '22023';
    END IF;

    IF p_categoria IS NULL THEN
        RAISE EXCEPTION 'pigse: % requiere indicar la categoria del anexo', p_tipo
            USING ERRCODE = '22023';
    ELSIF p_tipo IN ('PEI', 'PEC') AND p_categoria NOT IN
          ('PLAN_ESTUDIOS', 'SIEE', 'MANUAL_CONVIVENCIA', 'PROYECTOS_TRANSVERSALES', 'PLAN_GESTION_RIESGO') THEN
        RAISE EXCEPTION 'pigse: % no admite la categoria %', p_tipo, p_categoria
            USING ERRCODE = '22023';
    ELSIF p_tipo = 'PMI' AND p_categoria NOT IN ('PLAN_MEJORAMIENTO', 'AUTOEVALUACION_INSTITUCIONAL') THEN
        RAISE EXCEPTION 'pigse: PMI solo admite las categorias PLAN_MEJORAMIENTO y AUTOEVALUACION_INSTITUCIONAL'
            USING ERRCODE = '22023';
    ELSIF p_tipo = 'PFI' AND p_categoria NOT IN ('PLAN_FORTALECIMIENTO', 'AUTOEVALUACION_INSTITUCIONAL') THEN
        RAISE EXCEPTION 'pigse: PFI solo admite las categorias PLAN_FORTALECIMIENTO y AUTOEVALUACION_INSTITUCIONAL'
            USING ERRCODE = '22023';
    END IF;
END;
$$;

COMMENT ON FUNCTION pigse.fn_documento_validar_categoria(VARCHAR, VARCHAR) IS
    'INTERNO: 22023 si el tipo no existe o la categoria no corresponde al tipo (PEI/PEC: 5 anexos; PMI/PFI: plan + autoevaluacion).';

CREATE OR REPLACE FUNCTION pigse.fn_documento_validar_fecha_limite(
    p_fk_establecimiento BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_fecha_limite DATE;
BEGIN
    -- La excepción activa del establecimiento reemplaza a la global (no se suman).
    SELECT COALESCE(
               (SELECT e.fecha_limite FROM pigse.tgestion_documental_excepcion e
                 WHERE e.fk_testablecimiento = p_fk_establecimiento AND e.active),
               (SELECT c.fecha_limite FROM pigse.tgestion_documental_config c WHERE c.pk_config = 1)
           ) INTO v_fecha_limite;

    IF v_fecha_limite IS NOT NULL AND CURRENT_DATE > v_fecha_limite THEN
        RAISE EXCEPTION 'pigse: la fecha limite para Gestion Documental (%) ya paso', v_fecha_limite
            USING ERRCODE = '23514';
    END IF;
END;
$$;

COMMENT ON FUNCTION pigse.fn_documento_validar_fecha_limite(BIGINT) IS
    'INTERNO: 23514 si ya paso la fecha limite de Gestion Documental del establecimiento (excepcion activa, si no la global). Mismo criterio que fn_documento_guardar.';

CREATE OR REPLACE FUNCTION pigse.fn_documento_validar_tipo_aplica(
    p_fk_establecimiento BIGINT,
    p_tipo               VARCHAR
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_etnias pigse.bool_sn;
BEGIN
    SELECT ETNIAS INTO v_etnias
      FROM pigse.testablecimiento
     WHERE PK_ESTABLECIMIENTO = p_fk_establecimiento;

    IF p_tipo = 'PEI' AND v_etnias = 'S' THEN
        RAISE EXCEPTION 'pigse: PEI no aplica a este establecimiento (etnoeducativo -- usar PEC)'
            USING ERRCODE = '23514';
    ELSIF p_tipo = 'PEC' AND v_etnias = 'N' THEN
        RAISE EXCEPTION 'pigse: PEC no aplica a este establecimiento (no etnoeducativo -- usar PEI)'
            USING ERRCODE = '23514';
    ELSIF p_tipo = 'PMI' AND v_etnias = 'S' THEN
        RAISE EXCEPTION 'pigse: PMI no aplica a este establecimiento (etnoeducativo -- usar PFI)'
            USING ERRCODE = '23514';
    ELSIF p_tipo = 'PFI' AND v_etnias = 'N' THEN
        RAISE EXCEPTION 'pigse: PFI no aplica a este establecimiento (no etnoeducativo -- usar PMI)'
            USING ERRCODE = '23514';
    END IF;
END;
$$;

COMMENT ON FUNCTION pigse.fn_documento_validar_tipo_aplica(BIGINT, VARCHAR) IS
    'INTERNO: 23514 si el tipo no corresponde a la modalidad del establecimiento (ETNIAS S -> PEC/PFI, N -> PEI/PMI).';

CREATE OR REPLACE FUNCTION pigse.fn_documento_validar_archivo_libre(
    p_email       VARCHAR,
    p_fk_tarchivo BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    -- Solo se enlaza un archivo que subió el mismo usuario y que no cuelga
    -- todavía de ningún documento: sin esto, un id ajeno se podría "adoptar".
    IF NOT EXISTS (SELECT 1 FROM pigse.tarchivo a
                    WHERE a.pk_tarchivo = p_fk_tarchivo
                      AND lower(a.created_by) = lower(p_email)) THEN
        RAISE EXCEPTION 'pigse: el archivo % no existe o no fue cargado por este usuario', p_fk_tarchivo
            USING ERRCODE = 'P0002';
    END IF;

    IF EXISTS (SELECT 1 FROM pigse.tdocumento_institucional d WHERE d.fk_tarchivo = p_fk_tarchivo)
       OR EXISTS (SELECT 1 FROM pigse.tdocumento_institucional_hist h WHERE h.fk_tarchivo = p_fk_tarchivo) THEN
        RAISE EXCEPTION 'pigse: el archivo % ya esta asociado a un documento', p_fk_tarchivo
            USING ERRCODE = '22023';
    END IF;
END;
$$;

COMMENT ON FUNCTION pigse.fn_documento_validar_archivo_libre(VARCHAR, BIGINT) IS
    'INTERNO: P0002 si el pk_tarchivo no existe en pigse.tarchivo o lo subio otro usuario; 22023 si ya cuelga de un documento (vigente o historial).';

CREATE OR REPLACE FUNCTION pigse.fn_documento_validar_completo(
    p_fk_establecimiento BIGINT,
    p_tipo               VARCHAR
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_faltan TEXT[];
BEGIN
    -- PLAN_GESTION_RIESGO es el único anexo opcional (V521).
    SELECT array_agg(req.nombre ORDER BY req.orden) INTO v_faltan
      FROM (VALUES
                (1, 'PLAN_ESTUDIOS',                'Plan de estudios',                          ARRAY['PEI', 'PEC']),
                (2, 'SIEE',                         'Sistema Institucional de Evaluacion (SIEE)', ARRAY['PEI', 'PEC']),
                (3, 'MANUAL_CONVIVENCIA',           'Manual de convivencia',                     ARRAY['PEI', 'PEC']),
                (4, 'PROYECTOS_TRANSVERSALES',      'Proyectos pedagogicos transversales',       ARRAY['PEI', 'PEC']),
                (1, 'PLAN_MEJORAMIENTO',            'Plan de Mejoramiento Institucional',        ARRAY['PMI']),
                (1, 'PLAN_FORTALECIMIENTO',         'Plan de Fortalecimiento Institucional',     ARRAY['PFI']),
                (2, 'AUTOEVALUACION_INSTITUCIONAL', 'Autoevaluacion institucional',              ARRAY['PMI', 'PFI'])
           ) AS req(orden, categoria, nombre, tipos)
     WHERE p_tipo = ANY(req.tipos)
       AND NOT EXISTS (SELECT 1 FROM pigse.tdocumento_institucional d
                        WHERE d.fk_testablecimiento = p_fk_establecimiento
                          AND d.tipo = p_tipo
                          AND d.categoria = req.categoria
                          AND d.fk_tarchivo IS NOT NULL
                          AND d.active);

    IF v_faltan IS NOT NULL THEN
        RAISE EXCEPTION 'pigse: faltan % anexo(s) obligatorio(s) de %: %',
            cardinality(v_faltan), p_tipo, array_to_string(v_faltan, ', ')
            USING ERRCODE = '23514';
    END IF;
END;
$$;

COMMENT ON FUNCTION pigse.fn_documento_validar_completo(BIGINT, VARCHAR) IS
    'INTERNO: 23514 con la lista legible de anexos obligatorios sin archivo vigente del tipo (todos menos PLAN_GESTION_RIESGO). La usa el guardado en lote despues de escribir, dentro de la misma transaccion.';
