-- V77: fn_plan_agregar declaraba la etiqueta DESPUES del INSERT INTO TPLAN (el
-- contenedor del plan de estudio, creado solo la primera vez que un grado recibe
-- una asignatura). trg_audit_ctx es BEFORE STATEMENT: para esa fila puntual el
-- INSERT ya habia disparado el trigger antes de que fn_audit_declarar fijara
-- app.etiqueta/app.contexto, asi que esa fila (y solo esa) llegaba a ClickHouse
-- con etiqueta/app_user vacios. Encontrado con la prueba end-to-end contra el
-- stack local completo (api-gateway -> query-service -> Postgres -> cdc-capture
-- -> RabbitMQ -> cdc-worker -> ClickHouse). El resto de INSERTs de la funcion
-- (TASIGNATURA_PLAN, TCRITERIO_EVALUACION_ASIGNATURA_PLAN) ya iban despues de
-- fn_audit_declarar y no se ven afectados.
--
-- Fix: mover fn_audit_declarar para que quede antes del primer DML de la
-- funcion (el INSERT INTO TPLAN), igual que en el resto de funciones adoptadas.

CREATE OR REPLACE FUNCTION academico_test.fn_plan_agregar(p_fk_grado bigint, p_fk_asignatura bigint, p_numero_hora numeric, p_influencia_area numeric, p_numero_credito bigint, p_influye_desempeno boolean, p_matricula_obligatoria boolean, p_aprobacion_obligatoria boolean, p_fk_formato_calif bigint DEFAULT NULL::bigint, p_fk_criterio_nota bigint DEFAULT NULL::bigint, p_pk_usuario_solicitante bigint DEFAULT NULL::bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_grado_nom TEXT; v_plan_id BIGINT; v_id BIGINT; v_periodo BIGINT;
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_establecimiento_id BIGINT; v_asignatura_nom TEXT;
BEGIN
    SELECT academico_test.fn_periodo_establecimiento(g.FK_TPERIODO_ACADEMICO)
      INTO v_establecimiento_id
      FROM academico_test.TGRADO g WHERE g.PK_TGRADO = p_fk_grado;
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, v_establecimiento_id);
    IF p_fk_grado IS NULL OR p_fk_asignatura IS NULL THEN
        RAISE EXCEPTION 'Grado y asignatura son obligatorios' USING ERRCODE = '22023';
    END IF;
    -- Validaciones numericas.
    IF p_numero_hora IS NOT NULL AND p_numero_hora <= 0 THEN
        RAISE EXCEPTION 'La intensidad horaria debe ser mayor a 0' USING ERRCODE = '22023';
    END IF;
    IF p_influencia_area IS NOT NULL AND (p_influencia_area < 0 OR p_influencia_area > 100) THEN
        RAISE EXCEPTION 'La influencia en el area (%%) debe estar entre 0 y 100' USING ERRCODE = '22023';
    END IF;
    IF p_numero_credito IS NOT NULL AND p_numero_credito < 0 THEN
        RAISE EXCEPTION 'El numero de creditos no puede ser negativo' USING ERRCODE = '22023';
    END IF;

    SELECT NOMBRE INTO v_grado_nom FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_grado AND ACTIVE = TRUE;
    IF v_grado_nom IS NULL THEN
        RAISE EXCEPTION 'El grado % no existe o esta inactivo', p_fk_grado USING ERRCODE = '23503';
    END IF;
    SELECT NOMBRE INTO v_asignatura_nom FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_fk_asignatura AND ACTIVE = TRUE;
    IF v_asignatura_nom IS NULL THEN
        RAISE EXCEPTION 'La asignatura % no existe o esta inactiva', p_fk_asignatura USING ERRCODE = '23503';
    END IF;

    -- V77: la etiqueta se declara ANTES de tocar TPLAN/TASIGNATURA_PLAN (antes
    -- iba despues del INSERT INTO TPLAN, dejando esa fila puntual sin contexto).
    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        format('Asignación de %s al plan de estudio del grado %s', v_asignatura_nom, v_grado_nom),
        v_establecimiento_id);

    PERFORM pg_advisory_xact_lock(hashtext('plan:' || p_fk_grado::text));
    SELECT PK_TPLAN INTO v_plan_id FROM academico_test.TPLAN WHERE FK_TGRADO = p_fk_grado AND ACTIVE = TRUE;
    IF v_plan_id IS NULL THEN
        INSERT INTO academico_test.TPLAN (CODIGO, NOMBRE, FK_TGRADO, CREATED_BY)
        VALUES (LEFT(v_grado_nom, 30), 'Plan ' || v_grado_nom, p_fk_grado, v_audit)
        RETURNING PK_TPLAN INTO v_plan_id;
    END IF;
    -- No permitir la misma asignatura dos veces en el plan del grado.
    IF EXISTS (
        SELECT 1 FROM academico_test.TASIGNATURA_PLAN
         WHERE FK_TPLAN = v_plan_id AND FK_TASIGNATURA = p_fk_asignatura AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'La asignatura % ya esta en el plan de estudio de este grado', p_fk_asignatura
            USING ERRCODE = '23505';
    END IF;

    INSERT INTO academico_test.TASIGNATURA_PLAN (
        FK_TPLAN, FK_TASIGNATURA, NUMERO_HORA, INFLUENCIA_AREA, NUMERO_CREDITO,
        INFLUYE_DESEMPLENO_ACADEMICO, MATRICULA_OBLIGATORIA, APROBACION_OBLIGATORIA,
        FK_TLV_FORMATO_CALIFICACION_DEF, FK_TLV_CALCULO_DEFINITIVA, CREATED_BY
    ) VALUES (
        v_plan_id, p_fk_asignatura, p_numero_hora, p_influencia_area, p_numero_credito,
        CASE WHEN p_influye_desempeno THEN 'S' ELSE 'N' END::academico_test.bool_sn,
        CASE WHEN p_matricula_obligatoria THEN 'S' ELSE 'N' END::academico_test.bool_sn,
        CASE WHEN p_aprobacion_obligatoria THEN 'S' ELSE 'N' END,
        p_fk_formato_calif, p_fk_criterio_nota, v_audit
    )
    RETURNING PK_TASIGNATURA_PLAN INTO v_id;

    -- Enlaza el renglon del plan con el criterio de evaluacion POR DEFECTO del
    -- periodo (PK del criterio = PK del periodo). Los overrides personalizados
    -- de formato/criterio-nota viven en las columnas de TASIGNATURA_PLAN.
    SELECT FK_TPERIODO_ACADEMICO INTO v_periodo FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_grado;
    IF EXISTS (
        SELECT 1 FROM academico_test.TCRITERIO_EVALUACION
         WHERE PK_TCRITERIO_EVALUACION = v_periodo AND ACTIVE = TRUE
    ) THEN
        INSERT INTO academico_test.TCRITERIO_EVALUACION_ASIGNATURA_PLAN
            (FK_TCRITERIO_EVALUACION, FK_TASIGNATURA_PLAN, FK_TGRADO, POR_DEFECTO, CREATED_BY)
        VALUES (v_periodo, v_id, NULL, 'S', v_audit);
    END IF;
    RETURN v_id;
END;
$function$
;
