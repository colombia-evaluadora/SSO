-- ===========================================================================
-- Plan de Estudio — funciones consolidadas (última versión)
-- Generado: 2026-09-04
--
-- Migracion real, aplicada por Flyway en orden secuencial.
-- Su unico proposito es reunir en un solo lugar la version vigente de cada
-- funcion del modulo, ya que con el tiempo varias han sido redefinidas
-- (CREATE OR REPLACE FUNCTION) en migraciones posteriores.
--
-- Migraciones fuente consultadas:
--   - V44__study_plan_module.sql
--   - V107__plan_estudio_mensajes_error_con_nombre.sql
--   - V186__fn_plan_reporte_listar.sql
--   - V195__fn_plan_listar_y_disponibles_exponen_id_y_enfasis.sql
--
-- Verificacion: se corrio
--   grep -rn "FUNCTION academico_test.<nombre>(" postgres/migrations/
-- para cada funcion del modulo; el archivo mas reciente listado arriba es el
-- de mayor numero V en todos los casos, sin discrepancias respecto al mapeo
-- de partida. Nota especial: fn_plan_eliminar aparece definida DOS veces
-- dentro de V107 (una hacia el inicio del archivo, y una segunda mas abajo en
-- una seccion "Consolidado" que el propio V107 agrega para incorporar cambios
-- de V114/V117/V119 de otra rama) -- se tomo la segunda definicion, que es la
-- que queda vigente al final de la ejecucion del archivo (agrega el bloqueo
-- por THORARIO y la cascada de desactivar TPLAN si queda sin renglones).
-- ===========================================================================

-- Fuente: V107__plan_estudio_mensajes_error_con_nombre.sql
SET search_path TO academico_test, public;

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
    -- CU-86e2w4xdt: gate por (EE, sede, jornada) del periodo del grado.
    SELECT g.FK_TPERIODO_ACADEMICO INTO v_periodo
      FROM academico_test.TGRADO g WHERE g.PK_TGRADO = p_fk_grado;
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante,
        academico_test.fn_periodo_establecimiento(v_periodo),
        academico_test.fn_periodo_sede(v_periodo),
        academico_test.fn_periodo_jornada(v_periodo), 'CREAR');
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

    -- La etiqueta se declara aca, antes del pg_advisory_xact_lock e incluso del
    -- posible INSERT INTO TPLAN (creacion del header la primera vez que un
    -- grado recibe una asignatura) -- si se declarara despues de ese INSERT,
    -- el trigger BEFORE STATEMENT de auditoria vería esa fila sin etiqueta.
    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        format('Asignación de %s al plan de estudio del grado %s', v_asignatura_nom, v_grado_nom),
        academico_test.fn_periodo_establecimiento((
            SELECT g.FK_TPERIODO_ACADEMICO FROM academico_test.TGRADO g WHERE g.PK_TGRADO = p_fk_grado))
    );

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

-- Fuente: V107__plan_estudio_mensajes_error_con_nombre.sql
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
    v_periodo_id BIGINT;
BEGIN
    -- CU-86e2w4xdt: gate por (EE, sede, jornada) del periodo del plan.
    SELECT g.FK_TPERIODO_ACADEMICO INTO v_periodo_id
      FROM academico_test.TASIGNATURA_PLAN ap
      JOIN academico_test.TPLAN pl ON pl.PK_TPLAN = ap.FK_TPLAN
      JOIN academico_test.TGRADO g ON g.PK_TGRADO = pl.FK_TGRADO
     WHERE ap.PK_TASIGNATURA_PLAN = p_pk;
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante,
        academico_test.fn_periodo_establecimiento(v_periodo_id),
        academico_test.fn_periodo_sede(v_periodo_id),
        academico_test.fn_periodo_jornada(v_periodo_id), 'EDITAR');
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
    -- v_grado_nom (y v_asignatura_nom si no vino en el patch) no estaban
    -- resueltos en este punto -- se agrega este lookup solo para la etiqueta,
    -- mismo patron que ya usa mas abajo el branch de "renglon no encontrado".
    IF v_asignatura_nom IS NULL THEN
        SELECT ta.NOMBRE INTO v_asignatura_nom
          FROM academico_test.TASIGNATURA_PLAN ap
          JOIN academico_test.TASIGNATURA ta ON ta.PK_TASIGNATURA = ap.FK_TASIGNATURA
         WHERE ap.PK_TASIGNATURA_PLAN = p_pk;
    END IF;
    SELECT tg.NOMBRE INTO v_grado_nom
      FROM academico_test.TASIGNATURA_PLAN ap
      JOIN academico_test.TPLAN pl ON pl.PK_TPLAN = ap.FK_TPLAN
      JOIN academico_test.TGRADO tg ON tg.PK_TGRADO = pl.FK_TGRADO
     WHERE ap.PK_TASIGNATURA_PLAN = p_pk;

    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        format('Actualización del plan de estudio: %s en %s', v_asignatura_nom, v_grado_nom),
        academico_test.fn_periodo_establecimiento((
            SELECT g.FK_TPERIODO_ACADEMICO FROM academico_test.TASIGNATURA_PLAN ap
              JOIN academico_test.TPLAN pl ON pl.PK_TPLAN = ap.FK_TPLAN
              JOIN academico_test.TGRADO g ON g.PK_TGRADO = pl.FK_TGRADO
             WHERE ap.PK_TASIGNATURA_PLAN = p_pk))
    );

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

-- Fuente: V107__plan_estudio_mensajes_error_con_nombre.sql (segunda
-- definicion en el archivo, dentro de la seccion "Consolidado desde V119" —
-- es la que queda vigente; reemplaza tanto a la primera definicion de este
-- mismo archivo como a la de V44)
CREATE OR REPLACE FUNCTION academico_test.fn_plan_eliminar(p_pk bigint, p_pk_usuario_solicitante bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $$
DECLARE
    v_n INT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_asignatura_nom TEXT; v_grado_nom TEXT;
    v_plan_id BIGINT;
    v_periodo_id BIGINT;
BEGIN
    -- CU-86e2w4xdt: gate por (EE, sede, jornada) del periodo del plan.
    SELECT g.FK_TPERIODO_ACADEMICO INTO v_periodo_id
      FROM academico_test.TASIGNATURA_PLAN ap
      JOIN academico_test.TPLAN pl ON pl.PK_TPLAN = ap.FK_TPLAN
      JOIN academico_test.TGRADO g ON g.PK_TGRADO = pl.FK_TGRADO
     WHERE ap.PK_TASIGNATURA_PLAN = p_pk;
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante,
        academico_test.fn_periodo_establecimiento(v_periodo_id),
        academico_test.fn_periodo_sede(v_periodo_id),
        academico_test.fn_periodo_jornada(v_periodo_id), 'ELIMINAR');
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
    IF EXISTS (
        SELECT 1
          FROM academico_test.TASIGNATURA_PLAN ap
          JOIN academico_test.TPLAN pl ON pl.PK_TPLAN = ap.FK_TPLAN
          JOIN academico_test.TGRUPO g ON g.FK_TGRADO = pl.FK_TGRADO AND g.ACTIVE = TRUE
          JOIN academico_test.THORARIO h ON h.FK_TGRUPO = g.PK_TGRUPO
               AND h.FK_TASIGNATURA = ap.FK_TASIGNATURA AND h.ACTIVE = TRUE
         WHERE ap.PK_TASIGNATURA_PLAN = p_pk AND ap.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar: la asignatura tiene bloques de horario configurados en grupos del grado'
            USING ERRCODE = '23503';
    END IF;
    SELECT FK_TPLAN INTO v_plan_id FROM academico_test.TASIGNATURA_PLAN WHERE PK_TASIGNATURA_PLAN = p_pk;
    -- v_asignatura_nom/v_grado_nom no estaban resueltos en este punto (solo se
    -- calculan mas abajo si el UPDATE no afecta filas) -- se adelanta aca el
    -- mismo lookup solo para la etiqueta, sin logica nueva.
    SELECT ta.NOMBRE, tg.NOMBRE INTO v_asignatura_nom, v_grado_nom
      FROM academico_test.TASIGNATURA_PLAN ap
      JOIN academico_test.TASIGNATURA ta ON ta.PK_TASIGNATURA = ap.FK_TASIGNATURA
      JOIN academico_test.TPLAN pl ON pl.PK_TPLAN = ap.FK_TPLAN
      JOIN academico_test.TGRADO tg ON tg.PK_TGRADO = pl.FK_TGRADO
     WHERE ap.PK_TASIGNATURA_PLAN = p_pk;
    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        format('Eliminación de %s del plan de estudio de %s', v_asignatura_nom, v_grado_nom),
        academico_test.fn_periodo_establecimiento((
            SELECT g.FK_TPERIODO_ACADEMICO FROM academico_test.TASIGNATURA_PLAN ap
              JOIN academico_test.TPLAN pl ON pl.PK_TPLAN = ap.FK_TPLAN
              JOIN academico_test.TGRADO g ON g.PK_TGRADO = pl.FK_TGRADO
             WHERE ap.PK_TASIGNATURA_PLAN = p_pk))
    );
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
    UPDATE academico_test.TCRITERIO_EVALUACION_ASIGNATURA_PLAN
       SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TASIGNATURA_PLAN = p_pk AND ACTIVE = TRUE;
    IF v_plan_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TASIGNATURA_PLAN
         WHERE FK_TPLAN = v_plan_id AND ACTIVE = TRUE
    ) THEN
        UPDATE academico_test.TPLAN
           SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TPLAN = v_plan_id AND ACTIVE = TRUE;
    END IF;
    RETURN p_pk;
END;
$$;

-- Fuente: V107__plan_estudio_mensajes_error_con_nombre.sql
CREATE OR REPLACE FUNCTION academico_test.fn_plan_soft_delete(p_fk_grado bigint, p_pk_usuario_solicitante bigint)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_pk_plan BIGINT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_grado_nom TEXT;
    v_periodo_id BIGINT;
BEGIN
    -- CU-86e2w4xdt: gate por (EE, sede, jornada) del periodo del grado.
    SELECT g.FK_TPERIODO_ACADEMICO INTO v_periodo_id
      FROM academico_test.TGRADO g WHERE g.PK_TGRADO = p_fk_grado;
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante,
        academico_test.fn_periodo_establecimiento(v_periodo_id),
        academico_test.fn_periodo_sede(v_periodo_id),
        academico_test.fn_periodo_jornada(v_periodo_id), 'ELIMINAR');
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
    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        format('Eliminación del plan de estudio completo del grado %s', v_grado_nom),
        academico_test.fn_periodo_establecimiento((
            SELECT g.FK_TPERIODO_ACADEMICO FROM academico_test.TGRADO g WHERE g.PK_TGRADO = p_fk_grado))
    );

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

-- Fuente: V107__plan_estudio_mensajes_error_con_nombre.sql (funcion nueva,
-- no existia en V44; consolidada desde V114__fn_plan_asignatura_bulk_delete.sql
-- de otra rama)
CREATE OR REPLACE FUNCTION academico_test.fn_plan_asignatura_bulk_delete(
    p_ids bigint[],
    p_pk_usuario_solicitante bigint
)
RETURNS TABLE(id bigint, eliminado boolean, error_code text, error_mensaje text)
LANGUAGE plpgsql AS $$
DECLARE v_id BIGINT; v_state TEXT; v_msg TEXT;
BEGIN
    IF p_ids IS NULL THEN RETURN; END IF;
    FOREACH v_id IN ARRAY p_ids LOOP
        BEGIN
            PERFORM academico_test.fn_plan_eliminar(v_id, p_pk_usuario_solicitante);
            id := v_id; eliminado := TRUE; error_code := NULL; error_mensaje := NULL;
            RETURN NEXT;
        EXCEPTION WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
            id := v_id; eliminado := FALSE; error_code := v_state; error_mensaje := v_msg;
            RETURN NEXT;
        END;
    END LOOP;
    RETURN;
END;
$$;

-- Fuente: V195__fn_plan_listar_y_disponibles_exponen_id_y_enfasis.sql
DROP FUNCTION IF EXISTS academico_test.fn_plan_listar(BIGINT, TEXT, INT, INT, BIGINT, TEXT, TEXT);
CREATE OR REPLACE FUNCTION academico_test.fn_plan_listar(
    p_fk_grado BIGINT, p_filtro TEXT DEFAULT NULL,
    p_page_index INT DEFAULT 0, p_page_size INT DEFAULT 10,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL,
    -- Orden: id de columna del front + direccion ('asc'/'desc'), igual que fn_periodo_listar (V37).
    p_sort_by TEXT DEFAULT NULL,
    p_sort_dir TEXT DEFAULT NULL
)
RETURNS TABLE (codigo BIGINT, asignatura_id BIGINT, asignatura VARCHAR, enfasis_nombre VARCHAR,
               intensidad_horaria NUMERIC, influencia_area NUMERIC,
               numero_creditos BIGINT, influye_desempeno BOOLEAN, matricula_obligatoria BOOLEAN,
               aprobacion_obligatoria BOOLEAN, formato_calificacion BIGINT, criterio_nota BIGINT,
               personalizado BOOLEAN, total_count BIGINT)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_col TEXT;
    v_dir TEXT;
BEGIN
    v_col := CASE lower(coalesce(p_sort_by, ''))
        WHEN 'asignatura'        THEN 's.NOMBRE'
        WHEN 'intensidadhoraria' THEN 'ap.NUMERO_HORA'
        WHEN 'influenciaarea'    THEN 'ap.INFLUENCIA_AREA'
        WHEN 'numerocreditos'    THEN 'ap.NUMERO_CREDITO'
        ELSE 's.NOMBRE'
    END;
    v_dir := CASE WHEN lower(coalesce(p_sort_dir, '')) = 'desc' THEN 'DESC' ELSE 'ASC' END;

    RETURN QUERY EXECUTE format($q$
        SELECT ap.PK_TASIGNATURA_PLAN, s.PK_TASIGNATURA, s.NOMBRE, e.NOMBRE,
               ap.NUMERO_HORA, ap.INFLUENCIA_AREA, ap.NUMERO_CREDITO,
               (ap.INFLUYE_DESEMPLENO_ACADEMICO = 'S'), (ap.MATRICULA_OBLIGATORIA = 'S'),
               (ap.APROBACION_OBLIGATORIA = 'S'),
               COALESCE(ap.FK_TLV_FORMATO_CALIFICACION_DEF, ce.FK_TLV_FORMATO_CALIFICACION),
               COALESCE(ap.FK_TLV_CALCULO_DEFINITIVA,      ce.FK_TLV_MODIF_FINAL_PERACA),
               (ap.FK_TLV_FORMATO_CALIFICACION_DEF IS NOT NULL OR ap.FK_TLV_CALCULO_DEFINITIVA IS NOT NULL),
               count(*) OVER()::BIGINT
          FROM academico_test.TASIGNATURA_PLAN ap
          JOIN academico_test.TPLAN p        ON p.PK_TPLAN = ap.FK_TPLAN
          JOIN academico_test.TGRADO g       ON g.PK_TGRADO = p.FK_TGRADO
          JOIN academico_test.TASIGNATURA s  ON s.PK_TASIGNATURA = ap.FK_TASIGNATURA
          LEFT JOIN academico_test.TENFASIS e ON e.PK_TENFASIS = s.FK_TENFASIS AND e.ACTIVE = TRUE
          LEFT JOIN academico_test.TCRITERIO_EVALUACION_ASIGNATURA_PLAN cap
                 ON cap.FK_TASIGNATURA_PLAN = ap.PK_TASIGNATURA_PLAN AND cap.ACTIVE = TRUE
          LEFT JOIN academico_test.TCRITERIO_EVALUACION ce
                 ON ce.PK_TCRITERIO_EVALUACION = cap.FK_TCRITERIO_EVALUACION AND ce.ACTIVE = TRUE
         WHERE p.FK_TGRADO = $1 AND ap.ACTIVE = TRUE
           AND ($2 IS NULL OR s.NOMBRE ILIKE '%%' || $2 || '%%')
           -- CU-86e2w4xdt: capability + scope de lectura sobre el periodo del grado.
           AND academico_test.fn_periodo_puede_ver($5, g.FK_TPERIODO_ACADEMICO)
         ORDER BY %s %s, ap.PK_TASIGNATURA_PLAN
         LIMIT NULLIF($4, 0)
        OFFSET COALESCE($3, 0) * COALESCE(NULLIF($4, 0), 0)
    $q$, v_col, v_dir)
    USING p_fk_grado, NULLIF(TRIM(p_filtro),''), p_page_index, p_page_size, p_pk_usuario_solicitante;
END;
$$;

-- Fuente: V44__study_plan_module.sql
DROP FUNCTION IF EXISTS academico_test.fn_plan_obtener(BIGINT);
CREATE OR REPLACE FUNCTION academico_test.fn_plan_obtener(
    p_pk BIGINT, p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS TABLE (codigo BIGINT, asignatura_id BIGINT, asignatura VARCHAR,
               intensidad_horaria NUMERIC, influencia_area NUMERIC, numero_creditos BIGINT,
               influye_desempeno BOOLEAN, matricula_obligatoria BOOLEAN, aprobacion_obligatoria BOOLEAN,
               formato_calificacion BIGINT, criterio_nota BIGINT, personalizado BOOLEAN, grado_id BIGINT)
LANGUAGE sql STABLE AS $$
    SELECT ap.PK_TASIGNATURA_PLAN, ap.FK_TASIGNATURA, s.NOMBRE,
           ap.NUMERO_HORA, ap.INFLUENCIA_AREA, ap.NUMERO_CREDITO,
           (ap.INFLUYE_DESEMPLENO_ACADEMICO = 'S'), (ap.MATRICULA_OBLIGATORIA = 'S'),
           (ap.APROBACION_OBLIGATORIA = 'S'),
           COALESCE(ap.FK_TLV_FORMATO_CALIFICACION_DEF, ce.FK_TLV_FORMATO_CALIFICACION),
           COALESCE(ap.FK_TLV_CALCULO_DEFINITIVA,      ce.FK_TLV_MODIF_FINAL_PERACA),
           (ap.FK_TLV_FORMATO_CALIFICACION_DEF IS NOT NULL OR ap.FK_TLV_CALCULO_DEFINITIVA IS NOT NULL),
           p.FK_TGRADO
      FROM academico_test.TASIGNATURA_PLAN ap
      JOIN academico_test.TPLAN p        ON p.PK_TPLAN = ap.FK_TPLAN
      JOIN academico_test.TGRADO g       ON g.PK_TGRADO = p.FK_TGRADO
      JOIN academico_test.TASIGNATURA s  ON s.PK_TASIGNATURA = ap.FK_TASIGNATURA
      LEFT JOIN academico_test.TCRITERIO_EVALUACION_ASIGNATURA_PLAN cap
             ON cap.FK_TASIGNATURA_PLAN = ap.PK_TASIGNATURA_PLAN AND cap.ACTIVE = TRUE
      LEFT JOIN academico_test.TCRITERIO_EVALUACION ce
             ON ce.PK_TCRITERIO_EVALUACION = cap.FK_TCRITERIO_EVALUACION AND ce.ACTIVE = TRUE
     WHERE ap.PK_TASIGNATURA_PLAN = p_pk AND ap.ACTIVE = TRUE
       -- CU-86e2w4xdt: capability + scope de lectura sobre el periodo del grado.
       AND academico_test.fn_periodo_puede_ver(p_pk_usuario_solicitante, g.FK_TPERIODO_ACADEMICO);
$$;

-- Fuente: V195__fn_plan_listar_y_disponibles_exponen_id_y_enfasis.sql
DROP FUNCTION IF EXISTS academico_test.fn_plan_asignaturas_disponibles_listar(BIGINT, TEXT, BIGINT);
CREATE OR REPLACE FUNCTION academico_test.fn_plan_asignaturas_disponibles_listar(
    p_fk_grado BIGINT, p_filtro TEXT DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS TABLE (id BIGINT, nombre VARCHAR, area_id BIGINT, area_nombre VARCHAR, enfasis_nombre VARCHAR)
LANGUAGE sql STABLE AS $$
    SELECT s.PK_TASIGNATURA, s.NOMBRE, a.PK_TAREA, a.NOMBRE, e.NOMBRE
      FROM academico_test.TGRADO g
      JOIN academico_test.TAREA a       ON a.FK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO AND a.ACTIVE = TRUE
      JOIN academico_test.TASIGNATURA s ON s.FK_TAREA = a.PK_TAREA AND s.ACTIVE = TRUE
      LEFT JOIN academico_test.TENFASIS e ON e.PK_TENFASIS = s.FK_TENFASIS AND e.ACTIVE = TRUE
     WHERE g.PK_TGRADO = p_fk_grado
       AND (NULLIF(TRIM(p_filtro),'') IS NULL OR s.NOMBRE ILIKE '%' || p_filtro || '%')
       AND NOT EXISTS (
             SELECT 1 FROM academico_test.TASIGNATURA_PLAN ap
               JOIN academico_test.TPLAN p ON p.PK_TPLAN = ap.FK_TPLAN
              WHERE p.FK_TGRADO = p_fk_grado AND ap.FK_TASIGNATURA = s.PK_TASIGNATURA AND ap.ACTIVE = TRUE)
       -- CU-86e2w4xdt: capability + scope de lectura sobre el periodo del grado.
       AND academico_test.fn_periodo_puede_ver(p_pk_usuario_solicitante, g.FK_TPERIODO_ACADEMICO)
     ORDER BY a.NOMBRE, s.NOMBRE;
$$;

-- Fuente: V186__fn_plan_reporte_listar.sql
CREATE OR REPLACE FUNCTION academico_test.fn_plan_reporte_listar(
    p_fk_periodo      BIGINT,
    p_fk_grado        BIGINT[] DEFAULT NULL,
    p_fk_asignatura   BIGINT[] DEFAULT NULL,
    p_fk_especialidad BIGINT[] DEFAULT NULL,
    p_pk_usuario      BIGINT   DEFAULT NULL,
    p_page_index      INT      DEFAULT 0,
    p_page_size       INT      DEFAULT 10
)
RETURNS TABLE (
    id BIGINT, grado_id BIGINT, grado_name VARCHAR,
    asignatura_id BIGINT, asignatura VARCHAR, abreviacion VARCHAR,
    especialidad_id BIGINT, especialidad_name VARCHAR,
    intensidad_horaria NUMERIC, influencia_area NUMERIC,
    matricula_obligatoria BOOLEAN, aprobacion_obligatoria BOOLEAN,
    influye_desempeno BOOLEAN, total_count BIGINT
)
LANGUAGE sql STABLE AS $$
    SELECT ap.PK_TASIGNATURA_PLAN, g.PK_TGRADO, g.NOMBRE,
           s.PK_TASIGNATURA, s.NOMBRE, s.ABREVIACION,
           en.PK_TENFASIS, en.NOMBRE,
           ap.NUMERO_HORA, ap.INFLUENCIA_AREA,
           (ap.MATRICULA_OBLIGATORIA = 'S'), (ap.APROBACION_OBLIGATORIA = 'S'),
           (ap.INFLUYE_DESEMPLENO_ACADEMICO = 'S'),
           count(*) OVER()::BIGINT
      FROM academico_test.TASIGNATURA_PLAN ap
      JOIN academico_test.TPLAN p        ON p.PK_TPLAN = ap.FK_TPLAN AND p.ACTIVE = TRUE
      JOIN academico_test.TGRADO g       ON g.PK_TGRADO = p.FK_TGRADO
      JOIN academico_test.TASIGNATURA s  ON s.PK_TASIGNATURA = ap.FK_TASIGNATURA
 LEFT JOIN academico_test.TENFASIS en    ON en.PK_TENFASIS = s.FK_TENFASIS
     WHERE ap.ACTIVE = TRUE
       AND g.FK_TPERIODO_ACADEMICO = p_fk_periodo
       AND academico_test.fn_periodo_puede_ver(p_pk_usuario, p_fk_periodo)
       AND (p_fk_grado        IS NULL OR CARDINALITY(p_fk_grado)        = 0 OR g.PK_TGRADO      = ANY(p_fk_grado))
       AND (p_fk_asignatura   IS NULL OR CARDINALITY(p_fk_asignatura)   = 0 OR s.PK_TASIGNATURA  = ANY(p_fk_asignatura))
       AND (p_fk_especialidad IS NULL OR CARDINALITY(p_fk_especialidad) = 0 OR en.PK_TENFASIS    = ANY(p_fk_especialidad))
     ORDER BY g.NOMBRE, s.NOMBRE
     LIMIT NULLIF(p_page_size, 0)
    OFFSET COALESCE(p_page_index, 0) * COALESCE(NULLIF(p_page_size, 0), 0);
$$;
