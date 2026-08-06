-- ===========================================================================
-- V38 — Modulo de Periodo de Evaluacion (academico_test).
-- Reglas: dentro del rango del padre, sin solaparse con otro activo del mismo
-- padre, y la suma de PORCENTAJE del padre no puede superar 100.
-- ===========================================================================

SET search_path TO academico_test, public;

-- Validacion compartida (rango del padre, solape, suma de pesos). No es
-- gate; se llama desde crear/actualizar. p_pk_excluir = fila a ignorar (update).
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_eval_validar(
    p_fk_periodo   BIGINT,
    p_fecha_inicio DATE,
    p_fecha_fin    DATE,
    p_porcentaje   NUMERIC,
    p_codigo       VARCHAR DEFAULT NULL,
    p_nombre       VARCHAR DEFAULT NULL,
    p_abreviacion  VARCHAR DEFAULT NULL,
    p_pk_excluir   BIGINT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    v_pi DATE; v_pf DATE; v_suma NUMERIC;
BEGIN
    SELECT FECHA_INICIO, FECHA_FIN INTO v_pi, v_pf
      FROM academico_test.TPERIODO_ACADEMICO
     WHERE PK_TPERIODO_ACADEMICO = p_fk_periodo AND ACTIVE = TRUE;
    IF v_pi IS NULL THEN
        RAISE EXCEPTION 'El periodo academico % no existe o esta inactivo', p_fk_periodo USING ERRCODE = '23503';
    END IF;
    IF p_porcentaje IS NOT NULL AND p_porcentaje < 0 THEN
        RAISE EXCEPTION 'El porcentaje (%) no puede ser negativo', p_porcentaje USING ERRCODE = '22023';
    END IF;
    IF NULLIF(TRIM(p_codigo),'') IS NOT NULL AND EXISTS (
        SELECT 1 FROM academico_test.TPERIODO_EVALUACION pe
         WHERE pe.FK_TPERIODO_ACADEMICO = p_fk_periodo AND pe.ACTIVE = TRUE
           AND pe.PK_TPERIODO_EVALUACION <> COALESCE(p_pk_excluir, -1)
           AND UPPER(TRIM(pe.CODIGO)) = UPPER(TRIM(p_codigo))
    ) THEN
        RAISE EXCEPTION 'Ya existe un periodo de evaluacion con el codigo % en este periodo academico', p_codigo
            USING ERRCODE = '23505';
    END IF;
    IF NULLIF(TRIM(p_nombre),'') IS NOT NULL AND EXISTS (
        SELECT 1 FROM academico_test.TPERIODO_EVALUACION pe
         WHERE pe.FK_TPERIODO_ACADEMICO = p_fk_periodo AND pe.ACTIVE = TRUE
           AND pe.PK_TPERIODO_EVALUACION <> COALESCE(p_pk_excluir, -1)
           AND UPPER(TRIM(pe.NOMBRE)) = UPPER(TRIM(p_nombre))
    ) THEN
        RAISE EXCEPTION 'Ya existe un periodo de evaluacion con el nombre % en este periodo academico', p_nombre
            USING ERRCODE = '23505';
    END IF;
    IF NULLIF(TRIM(p_abreviacion),'') IS NOT NULL AND EXISTS (
        SELECT 1 FROM academico_test.TPERIODO_EVALUACION pe
         WHERE pe.FK_TPERIODO_ACADEMICO = p_fk_periodo AND pe.ACTIVE = TRUE
           AND pe.PK_TPERIODO_EVALUACION <> COALESCE(p_pk_excluir, -1)
           AND UPPER(TRIM(pe.ABREVIACION)) = UPPER(TRIM(p_abreviacion))
    ) THEN
        RAISE EXCEPTION 'Ya existe un periodo de evaluacion con la abreviacion % en este periodo academico', p_abreviacion
            USING ERRCODE = '23505';
    END IF;
    IF p_fecha_inicio < v_pi OR p_fecha_fin > v_pf THEN
        RAISE EXCEPTION 'El periodo de evaluacion (% a %) debe estar dentro del periodo academico (% a %)',
            p_fecha_inicio, p_fecha_fin, v_pi, v_pf USING ERRCODE = '22023';
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.TPERIODO_EVALUACION pe
         WHERE pe.FK_TPERIODO_ACADEMICO = p_fk_periodo AND pe.ACTIVE = TRUE
           AND pe.PK_TPERIODO_EVALUACION <> COALESCE(p_pk_excluir, -1)
           AND p_fecha_inicio <= pe.FECHA_FIN AND p_fecha_fin >= pe.FECHA_INICIO
    ) THEN
        RAISE EXCEPTION 'El periodo de evaluacion se solapa con otro existente' USING ERRCODE = '22023';
    END IF;
    SELECT COALESCE(SUM(pe.PORCENTAJE), 0) INTO v_suma
      FROM academico_test.TPERIODO_EVALUACION pe
     WHERE pe.FK_TPERIODO_ACADEMICO = p_fk_periodo AND pe.ACTIVE = TRUE
       AND pe.PK_TPERIODO_EVALUACION <> COALESCE(p_pk_excluir, -1);
    IF v_suma + COALESCE(p_porcentaje, 0) > 100 THEN
        RAISE EXCEPTION 'La suma de pesos (% + %) supera el 100%%', v_suma, COALESCE(p_porcentaje, 0)
            USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_eval_crear(
    p_fk_periodo     BIGINT,
    p_codigo         VARCHAR(30),
    p_nombre         VARCHAR(130),
    p_abreviacion    VARCHAR(30),
    p_fecha_inicio   DATE,
    p_fecha_fin      DATE,
    p_fk_estado      BIGINT,
    p_porcentaje     NUMERIC DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_id BIGINT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    IF NOT academico_test.fn_es_super_admin(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;
    IF p_fk_periodo IS NULL OR NULLIF(TRIM(p_codigo),'') IS NULL OR NULLIF(TRIM(p_nombre),'') IS NULL
       OR NULLIF(TRIM(p_abreviacion),'') IS NULL OR p_fecha_inicio IS NULL OR p_fecha_fin IS NULL
       OR p_fk_estado IS NULL THEN
        RAISE EXCEPTION 'Faltan campos obligatorios del periodo de evaluacion' USING ERRCODE = '22023';
    END IF;
    IF p_fecha_fin <= p_fecha_inicio THEN
        RAISE EXCEPTION 'La fecha fin debe ser posterior a la fecha inicio' USING ERRCODE = '22023';
    END IF;
    PERFORM academico_test.fn_periodo_eval_validar(p_fk_periodo, p_fecha_inicio, p_fecha_fin, p_porcentaje, p_codigo, p_nombre, p_abreviacion, NULL);

    INSERT INTO academico_test.TPERIODO_EVALUACION
        (CODIGO, NOMBRE, ABREVIACION, FECHA_INICIO, FECHA_FIN, FK_TLV_ESTADO,
         FK_TPERIODO_ACADEMICO, PORCENTAJE, CREATED_BY)
    VALUES (p_codigo, p_nombre, p_abreviacion, p_fecha_inicio, p_fecha_fin, p_fk_estado,
            p_fk_periodo, p_porcentaje, v_audit)
    RETURNING PK_TPERIODO_EVALUACION INTO v_id;
    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_eval_actualizar(
    p_pk             BIGINT,
    p_codigo         VARCHAR(30) DEFAULT NULL,
    p_nombre         VARCHAR(130) DEFAULT NULL,
    p_abreviacion    VARCHAR(30) DEFAULT NULL,
    p_fecha_inicio   DATE DEFAULT NULL,
    p_fecha_fin      DATE DEFAULT NULL,
    p_fk_estado      BIGINT DEFAULT NULL,
    p_porcentaje     NUMERIC DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    r academico_test.TPERIODO_EVALUACION;
    v_ini DATE; v_fin DATE; v_pct NUMERIC; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    IF NOT academico_test.fn_es_super_admin(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;
    SELECT * INTO r FROM academico_test.TPERIODO_EVALUACION WHERE PK_TPERIODO_EVALUACION = p_pk;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe el periodo de evaluacion %', p_pk USING ERRCODE = 'P0002';
    END IF;
    IF r.ACTIVE = FALSE THEN
        RAISE EXCEPTION 'El periodo de evaluacion % esta inactivo; no se puede actualizar', p_pk
            USING ERRCODE = '22023';
    END IF;
    v_ini := COALESCE(p_fecha_inicio, r.FECHA_INICIO);
    v_fin := COALESCE(p_fecha_fin, r.FECHA_FIN);
    v_pct := COALESCE(p_porcentaje, r.PORCENTAJE);
    IF v_fin <= v_ini THEN
        RAISE EXCEPTION 'La fecha fin debe ser posterior a la fecha inicio' USING ERRCODE = '22023';
    END IF;
    PERFORM academico_test.fn_periodo_eval_validar(r.FK_TPERIODO_ACADEMICO, v_ini, v_fin, v_pct,
        COALESCE(p_codigo, r.CODIGO), COALESCE(p_nombre, r.NOMBRE), COALESCE(p_abreviacion, r.ABREVIACION), p_pk);

    UPDATE academico_test.TPERIODO_EVALUACION SET
        CODIGO = COALESCE(p_codigo, CODIGO), NOMBRE = COALESCE(p_nombre, NOMBRE),
        ABREVIACION = COALESCE(p_abreviacion, ABREVIACION),
        FECHA_INICIO = v_ini, FECHA_FIN = v_fin,
        FK_TLV_ESTADO = COALESCE(p_fk_estado, FK_TLV_ESTADO), PORCENTAJE = v_pct,
        MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TPERIODO_EVALUACION = p_pk;
    RETURN p_pk;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_eval_soft_delete(
    p_pk BIGINT, p_pk_usuario_solicitante BIGINT
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_n INT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    IF NOT academico_test.fn_es_super_admin(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;
    UPDATE academico_test.TPERIODO_EVALUACION
       SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TPERIODO_EVALUACION = p_pk AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN
        RAISE EXCEPTION 'No existe un periodo de evaluacion activo con PK %', p_pk USING ERRCODE = 'P0002';
    END IF;
    RETURN p_pk;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_eval_listar(p_fk_periodo BIGINT)
RETURNS TABLE (
    id BIGINT, codigo VARCHAR, nombre VARCHAR, abreviacion VARCHAR,
    start_date DATE, end_date DATE, peso NUMERIC, status_id BIGINT, estado VARCHAR,
    academic_period_id BIGINT
)
LANGUAGE sql STABLE AS $$
    SELECT pe.PK_TPERIODO_EVALUACION, pe.CODIGO, pe.NOMBRE, pe.ABREVIACION,
           pe.FECHA_INICIO, pe.FECHA_FIN, pe.PORCENTAJE, pe.FK_TLV_ESTADO, est.VALOR,
           pe.FK_TPERIODO_ACADEMICO
      FROM academico_test.TPERIODO_EVALUACION pe
      JOIN academico_test.TLISTA_VALOR est ON est.PK_LISTA_VALOR = pe.FK_TLV_ESTADO
     WHERE pe.FK_TPERIODO_ACADEMICO = p_fk_periodo AND pe.ACTIVE = TRUE
     ORDER BY pe.FECHA_INICIO;
$$;
