-- Modulo "plan de estudio" (fn_plan_agregar, fn_plan_actualizar, fn_plan_eliminar,
-- fn_plan_soft_delete): varios RAISE EXCEPTION exponian el PK crudo de una FK
-- pasada por el usuario (grado, asignatura, formato de calificacion, criterio de
-- calculo de nota) o del propio renglon de plan buscado, sin resolver a un
-- nombre legible -- gap de la misma familia que V99 (fn_periodo_crear/actualizar).
--
-- Se tocaron unicamente los RAISE que cumplen las reglas 3/4/5 del barrido:
--   - "<entidad> % no existe o esta inactiv[ao]" para una FK pasada por el
--     usuario => se agrega un lookup IGNORANDO ACTIVE=TRUE justo antes del
--     RAISE. Si aparece (existe pero inactiva) se usa su nombre; si no aparece
--     en absoluto, el mensaje queda generico y SIN el id crudo. Mismo ERRCODE
--     en ambas ramas.
--   - "<entidad> % ya esta en el plan de estudio de este grado" (fn_plan_agregar
--     y fn_plan_actualizar): la asignatura YA fue validada como existente/activa
--     unas lineas antes, asi que se reusa el NOMBRE ya resuelto en esa validacion
--     (se cambio el NOT EXISTS/EXISTS por un SELECT ... INTO para capturarlo).
--   - "No existe un renglon de plan activo con PK %" (fn_plan_actualizar,
--     fn_plan_eliminar): mismo patron que el de arriba, pero el renglon
--     (TASIGNATURA_PLAN) no tiene nombre propio, asi que el lookup ignorando
--     ACTIVE hace join hasta asignatura+grado para armar una descripcion.
--   - "No existe un plan de estudio activo para el grado %" y "No se puede
--     eliminar el plan del grado %: ..." (fn_plan_soft_delete): p_fk_grado es
--     FK pasada por el usuario; incluso el mensaje "no se puede eliminar" se
--     alcanza solo si el grado YA resolvio nombre (existe una fila de TPLAN que
--     lo referencia), asi que ese segundo mensaje reusa el mismo lookup (regla 3).
--
-- Decision ambigua marcada explicitamente: "El formato de calificacion % no
-- existe o no es valido" / "El criterio de calculo de nota % no existe o no
-- es valido" (en fn_plan_agregar y fn_plan_actualizar) no calzan textualmente
-- con el patron "no existe o esta inactiv[ao]" de la regla 4, pero son
-- conceptualmente identicos (FK de catalogo TLISTA_VALOR que puede existir con
-- categoria/estado invalido); se les aplico el mismo tratamiento por
-- consistencia -- avisar si se prefiere dejarlos como estaban.
--
-- NO se tocaron (regla 1/2/6, sin ID crudo o validacion pura):
--   'Grado y asignatura son obligatorios'
--   'La intensidad horaria debe ser mayor a 0'
--   'La influencia en el area (%%) debe estar entre 0 y 100'
--   'El numero de creditos no puede ser negativo'
--   'No se puede eliminar: la asignatura tiene asignaciones academicas (docentes) en grupos del grado'
-- Tampoco se toco la logica de bloqueo/cascada de fn_plan_soft_delete (V44):
-- solo se modificaron los textos/argumentos de los RAISE, firma y ERRCODEs
-- intactos.

CREATE OR REPLACE FUNCTION academico_test.fn_plan_agregar(
    p_fk_grado             BIGINT,
    p_fk_asignatura        BIGINT,
    p_numero_hora          NUMERIC,
    p_influencia_area      NUMERIC,
    p_numero_credito       BIGINT,
    p_influye_desempeno    BOOLEAN,
    p_matricula_obligatoria BOOLEAN,
    p_aprobacion_obligatoria BOOLEAN,
    p_fk_formato_calif     BIGINT DEFAULT NULL,
    p_fk_criterio_nota     BIGINT DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_grado_nom TEXT; v_plan_id BIGINT; v_id BIGINT; v_periodo BIGINT;
    v_asignatura_nom TEXT; v_lookup TEXT;
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, (
        SELECT academico_test.fn_periodo_establecimiento(g.FK_TPERIODO_ACADEMICO)
          FROM academico_test.TGRADO g WHERE g.PK_TGRADO = p_fk_grado));
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
        SELECT NOMBRE INTO v_lookup FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_grado;
        IF v_lookup IS NOT NULL THEN
            RAISE EXCEPTION 'El grado "%" existe pero esta inactivo', v_lookup USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'El grado indicado no existe' USING ERRCODE = '23503';
        END IF;
    END IF;

    SELECT NOMBRE INTO v_asignatura_nom FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_fk_asignatura AND ACTIVE = TRUE;
    IF v_asignatura_nom IS NULL THEN
        SELECT NOMBRE INTO v_lookup FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_fk_asignatura;
        IF v_lookup IS NOT NULL THEN
            RAISE EXCEPTION 'La asignatura "%" existe pero esta inactiva', v_lookup USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'La asignatura indicada no existe' USING ERRCODE = '23503';
        END IF;
    END IF;
    -- Formato de calificacion / criterio de nota son opcionales (NULL = hereda
    -- del criterio de evaluacion del periodo), pero si vienen deben resolver a
    -- una fila activa de TLISTA_VALOR de la categoria correcta.
    IF p_fk_formato_calif IS NOT NULL THEN
        SELECT VALOR INTO v_lookup FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_fk_formato_calif AND ACTIVE = TRUE AND CATEGORIA = 'FORMATO_CALIFICACION';
        IF v_lookup IS NULL THEN
            SELECT VALOR INTO v_lookup FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_fk_formato_calif;
            IF v_lookup IS NOT NULL THEN
                RAISE EXCEPTION 'El formato de calificacion "%" existe pero esta inactivo o no pertenece a la categoria correspondiente', v_lookup
                    USING ERRCODE = '23503';
            ELSE
                RAISE EXCEPTION 'El formato de calificacion indicado no existe' USING ERRCODE = '23503';
            END IF;
        END IF;
    END IF;
    IF p_fk_criterio_nota IS NOT NULL THEN
        SELECT VALOR INTO v_lookup FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_fk_criterio_nota AND ACTIVE = TRUE AND CATEGORIA = 'TIPO_CALCULO';
        IF v_lookup IS NULL THEN
            SELECT VALOR INTO v_lookup FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_fk_criterio_nota;
            IF v_lookup IS NOT NULL THEN
                RAISE EXCEPTION 'El criterio de calculo de nota "%" existe pero esta inactivo o no pertenece a la categoria correspondiente', v_lookup
                    USING ERRCODE = '23503';
            ELSE
                RAISE EXCEPTION 'El criterio de calculo de nota indicado no existe' USING ERRCODE = '23503';
            END IF;
        END IF;
    END IF;

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
        RAISE EXCEPTION 'La asignatura "%" ya esta en el plan de estudio de este grado', v_asignatura_nom
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
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_plan_actualizar(
    p_pk                   BIGINT,
    p_fk_asignatura        BIGINT  DEFAULT NULL,
    p_numero_hora          NUMERIC DEFAULT NULL,
    p_influencia_area      NUMERIC DEFAULT NULL,
    p_numero_credito       BIGINT  DEFAULT NULL,
    p_influye_desempeno    BOOLEAN DEFAULT NULL,
    p_matricula_obligatoria BOOLEAN DEFAULT NULL,
    p_aprobacion_obligatoria BOOLEAN DEFAULT NULL,
    p_fk_formato_calif     BIGINT  DEFAULT NULL,
    p_fk_criterio_nota     BIGINT  DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_n INT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_asignatura_nom TEXT; v_grado_nom TEXT; v_lookup TEXT;
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, (
        SELECT academico_test.fn_periodo_establecimiento(g.FK_TPERIODO_ACADEMICO)
          FROM academico_test.TASIGNATURA_PLAN ap
          JOIN academico_test.TPLAN pl ON pl.PK_TPLAN = ap.FK_TPLAN
          JOIN academico_test.TGRADO g ON g.PK_TGRADO = pl.FK_TGRADO
         WHERE ap.PK_TASIGNATURA_PLAN = p_pk));
    -- Validaciones numericas (solo si vienen).
    IF p_numero_hora IS NOT NULL AND p_numero_hora <= 0 THEN
        RAISE EXCEPTION 'La intensidad horaria debe ser mayor a 0' USING ERRCODE = '22023';
    END IF;
    IF p_influencia_area IS NOT NULL AND (p_influencia_area < 0 OR p_influencia_area > 100) THEN
        RAISE EXCEPTION 'La influencia en el area (%%) debe estar entre 0 y 100' USING ERRCODE = '22023';
    END IF;
    IF p_numero_credito IS NOT NULL AND p_numero_credito < 0 THEN
        RAISE EXCEPTION 'El numero de creditos no puede ser negativo' USING ERRCODE = '22023';
    END IF;
    -- Si se cambia la asignatura: debe existir/activa y no duplicar en el plan.
    IF p_fk_asignatura IS NOT NULL THEN
        SELECT NOMBRE INTO v_asignatura_nom FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_fk_asignatura AND ACTIVE = TRUE;
        IF v_asignatura_nom IS NULL THEN
            SELECT NOMBRE INTO v_lookup FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_fk_asignatura;
            IF v_lookup IS NOT NULL THEN
                RAISE EXCEPTION 'La asignatura "%" existe pero esta inactiva', v_lookup USING ERRCODE = '23503';
            ELSE
                RAISE EXCEPTION 'La asignatura indicada no existe' USING ERRCODE = '23503';
            END IF;
        END IF;
        IF EXISTS (
            SELECT 1 FROM academico_test.TASIGNATURA_PLAN x
              JOIN academico_test.TASIGNATURA_PLAN cur ON cur.PK_TASIGNATURA_PLAN = p_pk
             WHERE x.FK_TPLAN = cur.FK_TPLAN AND x.PK_TASIGNATURA_PLAN <> p_pk
               AND x.FK_TASIGNATURA = p_fk_asignatura AND x.ACTIVE = TRUE
        ) THEN
            RAISE EXCEPTION 'La asignatura "%" ya esta en el plan de estudio de este grado', v_asignatura_nom
                USING ERRCODE = '23505';
        END IF;
    END IF;
    -- Formato de calificacion / criterio de nota: mismos checks que en
    -- fn_plan_agregar (NULL = vuelve a heredar del criterio de evaluacion).
    IF p_fk_formato_calif IS NOT NULL THEN
        SELECT VALOR INTO v_lookup FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_fk_formato_calif AND ACTIVE = TRUE AND CATEGORIA = 'FORMATO_CALIFICACION';
        IF v_lookup IS NULL THEN
            SELECT VALOR INTO v_lookup FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_fk_formato_calif;
            IF v_lookup IS NOT NULL THEN
                RAISE EXCEPTION 'El formato de calificacion "%" existe pero esta inactivo o no pertenece a la categoria correspondiente', v_lookup
                    USING ERRCODE = '23503';
            ELSE
                RAISE EXCEPTION 'El formato de calificacion indicado no existe' USING ERRCODE = '23503';
            END IF;
        END IF;
    END IF;
    IF p_fk_criterio_nota IS NOT NULL THEN
        SELECT VALOR INTO v_lookup FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_fk_criterio_nota AND ACTIVE = TRUE AND CATEGORIA = 'TIPO_CALCULO';
        IF v_lookup IS NULL THEN
            SELECT VALOR INTO v_lookup FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_fk_criterio_nota;
            IF v_lookup IS NOT NULL THEN
                RAISE EXCEPTION 'El criterio de calculo de nota "%" existe pero esta inactivo o no pertenece a la categoria correspondiente', v_lookup
                    USING ERRCODE = '23503';
            ELSE
                RAISE EXCEPTION 'El criterio de calculo de nota indicado no existe' USING ERRCODE = '23503';
            END IF;
        END IF;
    END IF;
    -- formato/criterio se setean SIEMPRE (permiten volver a NULL = heredar).
    UPDATE academico_test.TASIGNATURA_PLAN SET
        FK_TASIGNATURA = COALESCE(p_fk_asignatura, FK_TASIGNATURA),
        NUMERO_HORA = COALESCE(p_numero_hora, NUMERO_HORA),
        INFLUENCIA_AREA = COALESCE(p_influencia_area, INFLUENCIA_AREA),
        NUMERO_CREDITO = COALESCE(p_numero_credito, NUMERO_CREDITO),
        INFLUYE_DESEMPLENO_ACADEMICO = CASE WHEN p_influye_desempeno IS NULL THEN INFLUYE_DESEMPLENO_ACADEMICO
                                            WHEN p_influye_desempeno THEN 'S' ELSE 'N' END::academico_test.bool_sn,
        MATRICULA_OBLIGATORIA = CASE WHEN p_matricula_obligatoria IS NULL THEN MATRICULA_OBLIGATORIA
                                     WHEN p_matricula_obligatoria THEN 'S' ELSE 'N' END::academico_test.bool_sn,
        APROBACION_OBLIGATORIA = CASE WHEN p_aprobacion_obligatoria IS NULL THEN APROBACION_OBLIGATORIA
                                      WHEN p_aprobacion_obligatoria THEN 'S' ELSE 'N' END,
        FK_TLV_FORMATO_CALIFICACION_DEF = p_fk_formato_calif,
        FK_TLV_CALCULO_DEFINITIVA = p_fk_criterio_nota,
        MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TASIGNATURA_PLAN = p_pk AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN
        SELECT ta.NOMBRE, tg.NOMBRE INTO v_asignatura_nom, v_grado_nom
          FROM academico_test.TASIGNATURA_PLAN ap
          JOIN academico_test.TASIGNATURA ta ON ta.PK_TASIGNATURA = ap.FK_TASIGNATURA
          JOIN academico_test.TPLAN pl ON pl.PK_TPLAN = ap.FK_TPLAN
          JOIN academico_test.TGRADO tg ON tg.PK_TGRADO = pl.FK_TGRADO
         WHERE ap.PK_TASIGNATURA_PLAN = p_pk;
        IF v_asignatura_nom IS NOT NULL THEN
            RAISE EXCEPTION 'El renglon de plan para la asignatura "%" del grado "%" existe pero esta inactivo', v_asignatura_nom, v_grado_nom
                USING ERRCODE = 'P0002';
        ELSE
            RAISE EXCEPTION 'No existe un renglon de plan activo con el identificador indicado' USING ERRCODE = 'P0002';
        END IF;
    END IF;
    RETURN p_pk;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_plan_eliminar(p_pk bigint, p_pk_usuario_solicitante bigint)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_n INT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_asignatura_nom TEXT; v_grado_nom TEXT;
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, (
        SELECT academico_test.fn_periodo_establecimiento(g.FK_TPERIODO_ACADEMICO)
          FROM academico_test.TASIGNATURA_PLAN ap
          JOIN academico_test.TPLAN pl ON pl.PK_TPLAN = ap.FK_TPLAN
          JOIN academico_test.TGRADO g ON g.PK_TGRADO = pl.FK_TGRADO
         WHERE ap.PK_TASIGNATURA_PLAN = p_pk));
    -- Bloqueo: la asignatura del renglon tiene asignaciones docente activas en
    -- algun grupo del grado del plan.
    IF EXISTS (
        SELECT 1
          FROM academico_test.TASIGNATURA_PLAN ap
          JOIN academico_test.TPLAN pl ON pl.PK_TPLAN = ap.FK_TPLAN
          JOIN academico_test.TGRUPO g ON g.FK_TGRADO = pl.FK_TGRADO AND g.ACTIVE = TRUE
          JOIN academico_test.TDOCENTE_ASIGNATURA da ON da.FK_TGRUPO = g.PK_TGRUPO
               AND da.FK_TASIGNATURA = ap.FK_TASIGNATURA AND da.ACTIVE = TRUE
         WHERE ap.PK_TASIGNATURA_PLAN = p_pk AND ap.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar: la asignatura tiene asignaciones academicas (docentes) en grupos del grado'
            USING ERRCODE = '23503';
    END IF;
    UPDATE academico_test.TASIGNATURA_PLAN SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TASIGNATURA_PLAN = p_pk AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN
        SELECT ta.NOMBRE, tg.NOMBRE INTO v_asignatura_nom, v_grado_nom
          FROM academico_test.TASIGNATURA_PLAN ap
          JOIN academico_test.TASIGNATURA ta ON ta.PK_TASIGNATURA = ap.FK_TASIGNATURA
          JOIN academico_test.TPLAN pl ON pl.PK_TPLAN = ap.FK_TPLAN
          JOIN academico_test.TGRADO tg ON tg.PK_TGRADO = pl.FK_TGRADO
         WHERE ap.PK_TASIGNATURA_PLAN = p_pk;
        IF v_asignatura_nom IS NOT NULL THEN
            RAISE EXCEPTION 'El renglon de plan para la asignatura "%" del grado "%" existe pero esta inactivo', v_asignatura_nom, v_grado_nom
                USING ERRCODE = 'P0002';
        ELSE
            RAISE EXCEPTION 'No existe un renglon de plan activo con el identificador indicado' USING ERRCODE = 'P0002';
        END IF;
    END IF;
    -- Da de baja el enlace con el criterio de evaluacion.
    UPDATE academico_test.TCRITERIO_EVALUACION_ASIGNATURA_PLAN
       SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TASIGNATURA_PLAN = p_pk AND ACTIVE = TRUE;
    RETURN p_pk;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_plan_soft_delete(p_fk_grado bigint, p_pk_usuario_solicitante bigint)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_pk_plan BIGINT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_grado_nom TEXT;
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, (
        SELECT academico_test.fn_periodo_establecimiento(g.FK_TPERIODO_ACADEMICO)
          FROM academico_test.TGRADO g WHERE g.PK_TGRADO = p_fk_grado));
    -- Nombre del grado (ignorando ACTIVE), reusado en ambos mensajes de abajo.
    SELECT NOMBRE INTO v_grado_nom FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_grado;
    SELECT PK_TPLAN INTO v_pk_plan FROM academico_test.TPLAN
     WHERE FK_TGRADO = p_fk_grado AND ACTIVE = TRUE;
    IF v_pk_plan IS NULL THEN
        IF v_grado_nom IS NOT NULL THEN
            RAISE EXCEPTION 'No existe un plan de estudio activo para el grado "%"', v_grado_nom USING ERRCODE = 'P0002';
        ELSE
            RAISE EXCEPTION 'No existe un plan de estudio activo para el grado indicado' USING ERRCODE = 'P0002';
        END IF;
    END IF;
    -- Bloqueo: algun renglon del plan tiene asignaciones docente activas.
    IF EXISTS (
        SELECT 1
          FROM academico_test.TASIGNATURA_PLAN ap
          JOIN academico_test.TGRUPO g ON g.FK_TGRADO = p_fk_grado AND g.ACTIVE = TRUE
          JOIN academico_test.TDOCENTE_ASIGNATURA da ON da.FK_TGRUPO = g.PK_TGRUPO
               AND da.FK_TASIGNATURA = ap.FK_TASIGNATURA AND da.ACTIVE = TRUE
         WHERE ap.FK_TPLAN = v_pk_plan AND ap.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el plan del grado "%": hay asignaturas con asignaciones academicas (docentes) activas', v_grado_nom
            USING ERRCODE = '23503';
    END IF;
    -- Enlaces al criterio de evaluacion de los renglones del plan.
    UPDATE academico_test.TCRITERIO_EVALUACION_ASIGNATURA_PLAN
       SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE ACTIVE = TRUE AND FK_TASIGNATURA_PLAN IN (
         SELECT PK_TASIGNATURA_PLAN FROM academico_test.TASIGNATURA_PLAN
          WHERE FK_TPLAN = v_pk_plan AND ACTIVE = TRUE
     );
    -- Renglones del plan.
    UPDATE academico_test.TASIGNATURA_PLAN SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TPLAN = v_pk_plan AND ACTIVE = TRUE;
    -- Header del plan.
    UPDATE academico_test.TPLAN SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TPLAN = v_pk_plan AND ACTIVE = TRUE;
    RETURN v_pk_plan;
END;
$$;
