-- ===========================================================================
-- V37.2 -- Periodo academico: nucleos _interno
-- ===========================================================================
-- QUE HACE: crear/actualizar/eliminar periodos y descansos, listado,
-- detalle, anteriores por sede y selects de filtros, sin permisos. Validan con V37.1 antes de
-- escribir; el gate y la etiqueta de auditoria van en V37.3.
-- POR QUE AQUI: capa 2 del modulo (V37.1 / V37.2 / V37.3). Crear inserta en
-- TCRITERIO_PROMOCION (V38): plpgsql no valida el cuerpo al crearse.
-- DEPENDE DE: V22, V37 (u_tano_lectivo_1), V37.1; en ejecucion V38 y V66.
-- ===========================================================================

SET search_path TO academico_test, public;

-- Etiqueta su propio INSERT y devuelve la etiqueta del llamador: el trigger
-- de auditoria es BEFORE STATEMENT y lee app.etiqueta en ese momento.
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_ano_lectivo_asegurar_interno(
    p_fk_establecimiento BIGINT, p_fecha_inicio DATE, p_audit VARCHAR
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_nombre   VARCHAR(50) := to_char(p_fecha_inicio, 'YYYY');
    v_etiqueta TEXT := current_setting('app.etiqueta', true);
    v_id       BIGINT;
BEGIN
    PERFORM academico_test.fn_audit_declarar(NULL,
        format('Creación del año lectivo %s', v_nombre), p_fk_establecimiento);
    INSERT INTO academico_test.TANO_LECTIVO (NOMBRE, FK_TESTABLECIMIENTO, CREATED_BY)
    VALUES (v_nombre, p_fk_establecimiento, p_audit)
    ON CONFLICT (FK_TESTABLECIMIENTO, NOMBRE) DO NOTHING
    RETURNING PK_ANO_LECTIVO INTO v_id;
    IF v_id IS NULL THEN
        SELECT PK_ANO_LECTIVO INTO v_id FROM academico_test.TANO_LECTIVO
         WHERE FK_TESTABLECIMIENTO = p_fk_establecimiento AND NOMBRE = v_nombre;
    END IF;
    IF NULLIF(v_etiqueta, '') IS NOT NULL THEN
        PERFORM set_config('app.etiqueta', v_etiqueta, true);
    END IF;
    RETURN v_id;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_ano_lectivo_asegurar_interno(BIGINT, DATE, VARCHAR)
    IS 'INTERNO: devuelve el año lectivo (establecimiento, año de p_fecha_inicio) y lo crea si no existe. Lo usan fn_periodo_crear_interno y fn_periodo_actualizar_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_crear_interno(
    p_fk_sede                BIGINT,
    p_fk_estado              BIGINT,
    p_fecha_inicio           DATE,
    p_fecha_fin              DATE,
    p_fecha_limite_matricula DATE,
    p_fk_jornada             BIGINT,
    p_hora_inicio            TIME,
    p_hora_fin               TIME,
    p_reserva                academico_test.bool_sn,
    p_bloques_por_defecto    BIGINT,
    p_fk_periodo_anterior    BIGINT,
    p_descanso_inicio        TIME[],
    p_descanso_fin           TIME[],
    p_audit                  VARCHAR
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_establecimiento     BIGINT;
    v_ano_id              BIGINT;
    v_id                  BIGINT;
    c_formato_calif       BIGINT;
    c_elemento_def        BIGINT;
    c_criterio_final      BIGINT;
    c_criterio_area       BIGINT;
    c_desempeno_sin_calif BIGINT;
    c_modif_final_peraca  BIGINT;
    c_modo_redondear      BIGINT;
    c_criterio_asignatura BIGINT;
    v_formato_nombre      VARCHAR(120);
    v_formato_max         NUMERIC;
    i                     INT;
BEGIN
    PERFORM academico_test.fn_periodo_validar_campos(p_fk_sede, p_fk_estado, p_fecha_inicio, p_fecha_fin,
        p_fecha_limite_matricula, p_fk_jornada, p_hora_inicio, p_hora_fin);
    PERFORM academico_test.fn_periodo_validar(p_fecha_inicio, p_fecha_fin, p_fecha_limite_matricula,
        p_hora_inicio, p_hora_fin);
    PERFORM academico_test.fn_periodo_validar_sede(p_fk_sede);
    SELECT FK_TESTABLECIMIENTO INTO v_establecimiento FROM academico_test.TSEDE WHERE PK_TSEDE = p_fk_sede;
    PERFORM academico_test.fn_periodo_validar_anterior(p_fk_periodo_anterior, v_establecimiento);

    v_ano_id := academico_test.fn_periodo_ano_lectivo_asegurar_interno(v_establecimiento, p_fecha_inicio, p_audit);
    PERFORM academico_test.fn_periodo_validar_estado(p_fk_estado);
    PERFORM academico_test.fn_periodo_validar_jornada(p_fk_jornada);
    PERFORM academico_test.fn_periodo_validar_unico_jornada(v_ano_id, p_fk_sede, p_fk_jornada, NULL);

    INSERT INTO academico_test.TPERIODO_ACADEMICO (
        FK_TPERIODO_ACADEMICO, FK_TANO_LECTIVO, FK_TLV_ESTADO, FK_TSEDE,
        FECHA_INICIO, FECHA_FIN, FECHA_LIMITE_MATRICULA, FK_TLV_JORNADA,
        RESERVA, BLOQUES_POR_DEFECTO, NOMBRE, HORA_INICIO, HORA_FIN, CREATED_BY
    ) VALUES (
        p_fk_periodo_anterior, v_ano_id, p_fk_estado, p_fk_sede,
        p_fecha_inicio, p_fecha_fin, p_fecha_limite_matricula, p_fk_jornada,
        COALESCE(p_reserva, 'S'), COALESCE(p_bloques_por_defecto, 0),
        to_char(p_fecha_inicio, 'YYYY') || ' - '
            || (SELECT VALOR FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_fk_jornada),
        p_hora_inicio, p_hora_fin, p_audit
    )
    RETURNING PK_TPERIODO_ACADEMICO INTO v_id;

    -- Criterio de evaluacion por defecto (1:1, PK compartida), resuelto por
    -- (CATEGORIA, VALOR): NOMBRE es etiqueta visible y ya se renombro.
    SELECT PK_LISTA_VALOR, NOMBRE INTO c_formato_calif, v_formato_nombre
      FROM academico_test.TLISTA_VALOR WHERE CATEGORIA = 'FORMATO_CALIFICACION' AND VALOR = 'DIEZ' AND ACTIVE = TRUE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el valor por defecto de FORMATO_CALIFICACION (VALOR=DIEZ) en TLISTA_VALOR' USING ERRCODE = 'P0002';
    END IF;
    -- Mismo mapeo NOMBRE -> maximo que fn_criterio_eval_*.
    v_formato_max := CASE UPPER(TRIM(COALESCE(v_formato_nombre, '')))
                          WHEN 'DE CERO A CINCO' THEN 5
                          WHEN 'DE CERO A DIEZ'  THEN 10
                          ELSE 100
                      END;

    SELECT PK_LISTA_VALOR INTO c_elemento_def
      FROM academico_test.TLISTA_VALOR WHERE CATEGORIA = 'ELEMENTO_CALCULO_DEF' AND VALOR = '2' AND ACTIVE = TRUE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el valor por defecto de ELEMENTO_CALCULO_DEF (VALOR=2) en TLISTA_VALOR' USING ERRCODE = 'P0002';
    END IF;

    SELECT PK_LISTA_VALOR INTO c_criterio_asignatura
      FROM academico_test.TLISTA_VALOR WHERE CATEGORIA = 'TIPO_CALCULO' AND VALOR = '1' AND ACTIVE = TRUE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el valor por defecto de TIPO_CALCULO (VALOR=1) en TLISTA_VALOR' USING ERRCODE = 'P0002';
    END IF;

    SELECT PK_LISTA_VALOR INTO c_criterio_final
      FROM academico_test.TLISTA_VALOR WHERE CATEGORIA = 'CRITERIO_FINAL_PERACA' AND VALOR = '1' AND ACTIVE = TRUE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el valor por defecto de CRITERIO_FINAL_PERACA (VALOR=1) en TLISTA_VALOR' USING ERRCODE = 'P0002';
    END IF;

    SELECT PK_LISTA_VALOR INTO c_criterio_area
      FROM academico_test.TLISTA_VALOR WHERE CATEGORIA = 'CRITERIO_AREA' AND VALOR = '1' AND ACTIVE = TRUE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el valor por defecto de CRITERIO_AREA (VALOR=1) en TLISTA_VALOR' USING ERRCODE = 'P0002';
    END IF;

    SELECT PK_LISTA_VALOR INTO c_desempeno_sin_calif
      FROM academico_test.TLISTA_VALOR WHERE CATEGORIA = 'DESEMPENIOSUGERIR' AND VALOR = '2' AND ACTIVE = TRUE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el valor por defecto de DESEMPENIOSUGERIR (VALOR=2) en TLISTA_VALOR' USING ERRCODE = 'P0002';
    END IF;

    SELECT PK_LISTA_VALOR INTO c_modif_final_peraca
      FROM academico_test.TLISTA_VALOR WHERE CATEGORIA = 'MODIF_FINAL_PERACA' AND VALOR = '1' AND ACTIVE = TRUE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el valor por defecto de MODIF_FINAL_PERACA (VALOR=1) en TLISTA_VALOR' USING ERRCODE = 'P0002';
    END IF;

    SELECT PK_LISTA_VALOR INTO c_modo_redondear
      FROM academico_test.TLISTA_VALOR WHERE CATEGORIA = 'MODO_REDONDEAR' AND VALOR = '3' AND ACTIVE = TRUE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el valor por defecto de MODO_REDONDEAR (VALOR=3) en TLISTA_VALOR' USING ERRCODE = 'P0002';
    END IF;

    INSERT INTO academico_test.TCRITERIO_EVALUACION (
        PK_TCRITERIO_EVALUACION, FK_TLV_FORMATO_CALIFICACION, FK_TLV_ELEMENTO_DEF,
        FK_TLV_MODIF_FINAL_PERACA, FK_TLV_CRITERIO_ASIGNATURA, FK_TLV_CRITERIO_FINAL,
        FK_TLV_CRITERIO_AREA, FK_TLV_DESEMPENO_SIN_CALIF, FK_TLV_MODO_REDONDEAR,
        PORCENTAJE_INICIAL_CALIF, PORCENTAJE_MAXIMO_RECUPERACION, CREATED_BY
    ) VALUES (
        v_id, c_formato_calif, c_elemento_def, c_modif_final_peraca, c_criterio_asignatura,
        c_criterio_final, c_criterio_area, c_desempeno_sin_calif, c_modo_redondear,
        -- PORCENTAJE_X es % del maximo del formato: nota inicial real = 1.
        ROUND(1 / v_formato_max * 100, 2), 100, p_audit
    )
    ON CONFLICT (PK_TCRITERIO_EVALUACION) DO NOTHING;

    INSERT INTO academico_test.TCRITERIO_PROMOCION (
        FK_TPERIODO_ACADEMICO, FK_TGRADO, NODO_CURRICULAR, CANTIDAD_NIVELAR,
        ASIGNATURA_OBLIGATORIA, APROBACION_PROMEDIO, DESEMPENHO_MINIMO_GENERAL,
        DESEMPENHO_MINIMO, MAX_ASIG_PROMEDIO, MINIMO_INASISTENCIAS,
        MAX_ASIG_NIVELAR_PROMOVIDO, POR_DEFECTO, CREATED_BY
    ) VALUES (
        v_id, NULL, 'AS', 2, 'N', 'N', 25, 25, 1, 25, 2, 'S', p_audit
    );

    IF p_descanso_inicio IS NOT NULL THEN
        PERFORM academico_test.fn_periodo_validar_descansos(p_descanso_inicio, p_descanso_fin,
            p_hora_inicio, p_hora_fin);
        FOR i IN 1 .. COALESCE(array_length(p_descanso_inicio, 1), 0) LOOP
            INSERT INTO academico_test.TDESCANSOS (FK_TPERIODO_ACADEMICO, HORA_INICIO, HORA_FIN, CREATED_BY)
            VALUES (v_id, p_descanso_inicio[i], p_descanso_fin[i], p_audit);
        END LOOP;
    END IF;

    RETURN v_id;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_crear_interno(BIGINT, BIGINT, DATE, DATE, DATE, BIGINT, TIME, TIME, academico_test.bool_sn, BIGINT, BIGINT, TIME[], TIME[], VARCHAR)
    IS 'INTERNO: valida e inserta un periodo academico con su año lectivo, criterio de evaluacion y criterio de promocion por defecto y sus descansos. Lo usa fn_periodo_crear.';

-- Los NULL conservan el valor actual. p_descanso_inicio NULL = no tocar los
-- descansos (solo se exige que sigan dentro del horario); arreglo (aun vacio)
-- = reemplazo del set activo por diff, sin churn de PKs.
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_actualizar_interno(
    p_pk_periodo             BIGINT,
    p_fk_estado              BIGINT,
    p_fk_sede                BIGINT,
    p_fecha_inicio           DATE,
    p_fecha_fin              DATE,
    p_fecha_limite_matricula DATE,
    p_fk_jornada             BIGINT,
    p_reserva                academico_test.bool_sn,
    p_bloques_por_defecto    BIGINT,
    p_fk_periodo_anterior    BIGINT,
    p_hora_inicio            TIME,
    p_hora_fin               TIME,
    p_descanso_inicio        TIME[],
    p_descanso_fin           TIME[],
    p_audit                  VARCHAR
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    r         academico_test.TPERIODO_ACADEMICO;
    v_sede    BIGINT;
    v_inicio  DATE;
    v_fin     DATE;
    v_limite  DATE;
    v_jornada BIGINT;
    v_hi      TIME;
    v_hf      TIME;
    v_est     BIGINT;
    v_ano_id  BIGINT;
BEGIN
    SELECT * INTO r FROM academico_test.TPERIODO_ACADEMICO WHERE PK_TPERIODO_ACADEMICO = p_pk_periodo;
    v_sede    := COALESCE(p_fk_sede, r.FK_TSEDE);
    v_inicio  := COALESCE(p_fecha_inicio, r.FECHA_INICIO);
    v_fin     := COALESCE(p_fecha_fin, r.FECHA_FIN);
    v_limite  := COALESCE(p_fecha_limite_matricula, r.FECHA_LIMITE_MATRICULA);
    v_jornada := COALESCE(p_fk_jornada, r.FK_TLV_JORNADA);
    v_hi      := COALESCE(p_hora_inicio, r.HORA_INICIO);
    v_hf      := COALESCE(p_hora_fin, r.HORA_FIN);

    IF v_sede <> r.FK_TSEDE THEN
        PERFORM academico_test.fn_periodo_validar_sede(v_sede);
        PERFORM academico_test.fn_periodo_validar_sede_mismo_establecimiento(r.FK_TSEDE, v_sede);
    END IF;
    PERFORM academico_test.fn_periodo_validar(v_inicio, v_fin, v_limite, v_hi, v_hf);

    IF p_descanso_inicio IS NULL THEN
        PERFORM academico_test.fn_periodo_validar_descansos_en_horario(p_pk_periodo, v_hi, v_hf);
    ELSE
        PERFORM academico_test.fn_periodo_validar_descansos(p_descanso_inicio, p_descanso_fin, v_hi, v_hf);
        UPDATE academico_test.TDESCANSOS d
           SET ACTIVE = FALSE, MODIFIED_BY = p_audit, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE d.FK_TPERIODO_ACADEMICO = p_pk_periodo AND d.ACTIVE = TRUE
           AND NOT EXISTS (
               SELECT 1 FROM unnest(p_descanso_inicio, p_descanso_fin) AS nuevo(hi, hf)
                WHERE nuevo.hi = d.HORA_INICIO AND nuevo.hf = d.HORA_FIN
           );
        INSERT INTO academico_test.TDESCANSOS (FK_TPERIODO_ACADEMICO, HORA_INICIO, HORA_FIN, CREATED_BY)
        SELECT p_pk_periodo, nuevo.hi, nuevo.hf, p_audit
          FROM unnest(p_descanso_inicio, p_descanso_fin) AS nuevo(hi, hf)
         WHERE NOT EXISTS (
               SELECT 1 FROM academico_test.TDESCANSOS d
                WHERE d.FK_TPERIODO_ACADEMICO = p_pk_periodo AND d.ACTIVE = TRUE
                  AND d.HORA_INICIO = nuevo.hi AND d.HORA_FIN = nuevo.hf
           );
    END IF;

    SELECT FK_TESTABLECIMIENTO INTO v_est FROM academico_test.TSEDE WHERE PK_TSEDE = v_sede;
    IF p_fk_periodo_anterior IS NOT NULL THEN
        PERFORM academico_test.fn_periodo_validar_anterior_distinto(p_pk_periodo, p_fk_periodo_anterior);
        PERFORM academico_test.fn_periodo_validar_anterior(p_fk_periodo_anterior, v_est);
    END IF;

    v_ano_id := academico_test.fn_periodo_ano_lectivo_asegurar_interno(v_est, v_inicio, p_audit);
    PERFORM academico_test.fn_periodo_validar_unico_jornada(v_ano_id, v_sede, v_jornada, p_pk_periodo);
    PERFORM academico_test.fn_periodo_validar_estado(COALESCE(p_fk_estado, r.FK_TLV_ESTADO));
    PERFORM academico_test.fn_periodo_validar_jornada(v_jornada);

    UPDATE academico_test.TPERIODO_ACADEMICO SET
        FK_TLV_ESTADO          = COALESCE(p_fk_estado, FK_TLV_ESTADO),
        FK_TSEDE               = v_sede,
        FECHA_INICIO           = v_inicio,
        FECHA_FIN              = v_fin,
        FECHA_LIMITE_MATRICULA = v_limite,
        FK_TLV_JORNADA         = v_jornada,
        FK_TANO_LECTIVO        = v_ano_id,
        RESERVA                = COALESCE(p_reserva, RESERVA),
        BLOQUES_POR_DEFECTO    = COALESCE(p_bloques_por_defecto, BLOQUES_POR_DEFECTO),
        FK_TPERIODO_ACADEMICO  = COALESCE(p_fk_periodo_anterior, FK_TPERIODO_ACADEMICO),
        HORA_INICIO            = v_hi,
        HORA_FIN               = v_hf,
        NOMBRE                 = to_char(v_inicio, 'YYYY') || ' - '
            || (SELECT VALOR FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = v_jornada),
        MODIFIED_BY            = p_audit,
        MODIFIED_AT            = CURRENT_TIMESTAMP
     WHERE PK_TPERIODO_ACADEMICO = p_pk_periodo;

    RETURN p_pk_periodo;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_actualizar_interno(BIGINT, BIGINT, BIGINT, DATE, DATE, DATE, BIGINT, academico_test.bool_sn, BIGINT, BIGINT, TIME, TIME, TIME[], TIME[], VARCHAR)
    IS 'INTERNO: valida y actualiza un periodo academico existente y activo, reconcilia sus descansos y recalcula año lectivo y nombre. Lo usa fn_periodo_actualizar.';

-- Criterios de evaluacion y de promocion propios del periodo y sus descansos
-- se dan de baja con el; los overrides por grado ya bajaron con fn_grado_soft_delete.
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_eliminar_interno(p_pk_periodo BIGINT, p_audit VARCHAR)
RETURNS BIGINT LANGUAGE plpgsql AS $$
BEGIN
    PERFORM academico_test.fn_periodo_validar_sin_dependientes(p_pk_periodo);

    UPDATE academico_test.TPERIODO_ACADEMICO
       SET ACTIVE = FALSE, MODIFIED_BY = p_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TPERIODO_ACADEMICO = p_pk_periodo;

    UPDATE academico_test.TCRITERIO_EVALUACION
       SET ACTIVE = FALSE, MODIFIED_BY = p_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TCRITERIO_EVALUACION = p_pk_periodo AND ACTIVE = TRUE;

    UPDATE academico_test.TCRITERIO_PROMOCION_ASIGNATURA_OBLIGATORIA
       SET ACTIVE = FALSE, MODIFIED_BY = p_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE ACTIVE = TRUE AND FK_TCRITERIO_PROMOCION IN (
         SELECT PK_TCRITERIO_PROMOCION FROM academico_test.TCRITERIO_PROMOCION
          WHERE FK_TPERIODO_ACADEMICO = p_pk_periodo AND ACTIVE = TRUE
     );
    UPDATE academico_test.TCRITERIO_PROMOCION
       SET ACTIVE = FALSE, MODIFIED_BY = p_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TPERIODO_ACADEMICO = p_pk_periodo AND ACTIVE = TRUE;

    UPDATE academico_test.TDESCANSOS
       SET ACTIVE = FALSE, MODIFIED_BY = p_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TPERIODO_ACADEMICO = p_pk_periodo AND ACTIVE = TRUE;

    RETURN p_pk_periodo;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_eliminar_interno(BIGINT, VARCHAR)
    IS 'INTERNO: baja logica de un periodo academico activo; 23503 si tiene horarios, planes, periodos de evaluacion, escalas, asignaciones, areas o grados. Lo usa fn_periodo_soft_delete.';

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_listar_interno(
    p_periodos    BIGINT[],
    p_fk_sede     BIGINT DEFAULT NULL,
    p_nombre_sede TEXT   DEFAULT NULL,
    p_ano         TEXT   DEFAULT NULL,
    p_fk_estado   BIGINT DEFAULT NULL,
    p_fecha_desde DATE   DEFAULT NULL,
    p_fecha_hasta DATE   DEFAULT NULL,
    p_page_index  INT    DEFAULT 0,
    p_page_size   INT    DEFAULT 10,
    p_sort_by     TEXT   DEFAULT NULL,
    p_sort_dir    TEXT   DEFAULT NULL
)
RETURNS TABLE (
    id BIGINT, sede_id BIGINT, sede_name VARCHAR, school_year_id BIGINT,
    school_year_name VARCHAR, status_id BIGINT, status VARCHAR, status_name VARCHAR,
    start_date DATE, end_date DATE, enrollment_deadline DATE, name VARCHAR,
    jornada_id BIGINT, jornada VARCHAR, jornada_name VARCHAR,
    reserva academico_test.bool_sn, default_blocks_count BIGINT,
    schedule_start_time TIME, schedule_end_time TIME, descansos JSONB,
    previous_period_id BIGINT, previous_period_name VARCHAR, total_count BIGINT
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_col TEXT;
    v_dir TEXT;
BEGIN
    -- Whitelist: nunca se interpola input del usuario en el ORDER BY.
    v_col := CASE lower(coalesce(p_sort_by, ''))
        WHEN 'sedename'           THEN 's.NOMBRE'
        WHEN 'schoolyearid'       THEN 'al.NOMBRE'
        WHEN 'status'             THEN 'est.VALOR'
        WHEN 'startdate'          THEN 'pa.FECHA_INICIO'
        WHEN 'enddate'            THEN 'pa.FECHA_FIN'
        WHEN 'enrollmentdeadline' THEN 'pa.FECHA_LIMITE_MATRICULA'
        WHEN 'name'               THEN 'pa.NOMBRE'
        ELSE 'pa.FECHA_INICIO'
    END;
    v_dir := CASE WHEN lower(coalesce(p_sort_dir, '')) = 'asc' THEN 'ASC' ELSE 'DESC' END;

    -- p_page_size 0/NULL = sin limite (lo usa el reporte).
    RETURN QUERY EXECUTE format($q$
        SELECT pa.PK_TPERIODO_ACADEMICO, pa.FK_TSEDE, s.NOMBRE, pa.FK_TANO_LECTIVO,
               al.NOMBRE, pa.FK_TLV_ESTADO, est.VALOR, est.NOMBRE,
               pa.FECHA_INICIO, pa.FECHA_FIN, pa.FECHA_LIMITE_MATRICULA, pa.NOMBRE,
               pa.FK_TLV_JORNADA, jor.VALOR, jor.NOMBRE, pa.RESERVA, pa.BLOQUES_POR_DEFECTO,
               pa.HORA_INICIO, pa.HORA_FIN,
               COALESCE((
                   SELECT jsonb_agg(
                              jsonb_build_object(
                                  'startTime', to_char(d.HORA_INICIO, 'HH24:MI'),
                                  'endTime',   to_char(d.HORA_FIN,    'HH24:MI'))
                              ORDER BY d.HORA_INICIO)
                     FROM academico_test.TDESCANSOS d
                    WHERE d.FK_TPERIODO_ACADEMICO = pa.PK_TPERIODO_ACADEMICO
                      AND d.ACTIVE = TRUE
               ), '[]'::jsonb),
               pa.FK_TPERIODO_ACADEMICO, pp.NOMBRE, count(*) OVER()::BIGINT
          FROM academico_test.TPERIODO_ACADEMICO pa
          JOIN academico_test.TSEDE s          ON s.PK_TSEDE = pa.FK_TSEDE
          JOIN academico_test.TANO_LECTIVO al  ON al.PK_ANO_LECTIVO = pa.FK_TANO_LECTIVO
          JOIN academico_test.TLISTA_VALOR est ON est.PK_LISTA_VALOR = pa.FK_TLV_ESTADO
          JOIN academico_test.TLISTA_VALOR jor ON jor.PK_LISTA_VALOR = pa.FK_TLV_JORNADA
          LEFT JOIN academico_test.TPERIODO_ACADEMICO pp ON pp.PK_TPERIODO_ACADEMICO = pa.FK_TPERIODO_ACADEMICO
         WHERE pa.ACTIVE = TRUE
           AND ($9 IS NULL OR pa.PK_TPERIODO_ACADEMICO = ANY($9))
           AND ($1 IS NULL OR pa.FK_TSEDE = $1)
           AND ($2 IS NULL OR s.NOMBRE ILIKE '%%' || $2 || '%%')
           AND ($3 IS NULL OR al.NOMBRE = $3)
           AND ($4 IS NULL OR pa.FK_TLV_ESTADO = $4)
           AND ($5 IS NULL OR pa.FECHA_INICIO >= $5)
           AND ($6 IS NULL OR pa.FECHA_INICIO <= $6)
         ORDER BY %s %s, pa.PK_TPERIODO_ACADEMICO DESC
         LIMIT NULLIF($8, 0)
        OFFSET COALESCE($7, 0) * COALESCE(NULLIF($8, 0), 0)
    $q$, v_col, v_dir)
    USING p_fk_sede, p_nombre_sede, p_ano, p_fk_estado, p_fecha_desde,
          p_fecha_hasta, p_page_index, p_page_size, p_periodos;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_listar_interno(BIGINT[], BIGINT, TEXT, TEXT, BIGINT, DATE, DATE, INT, INT, TEXT, TEXT)
    IS 'INTERNO: periodos academicos activos filtrados, paginados y ordenados, sin alcance. p_periodos = ids visibles ya resueltos por el llamador (NULL = sin restriccion). Lo usa fn_periodo_listar (pantalla y reporte).';

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_detalle_interno(p_pk_periodo BIGINT)
RETURNS TABLE(
    id BIGINT, sede_id BIGINT, sede_name VARCHAR, school_year_id BIGINT,
    school_year_name VARCHAR, status_id BIGINT, status VARCHAR, status_name VARCHAR,
    start_date DATE, end_date DATE, enrollment_deadline DATE, name VARCHAR,
    jornada_id BIGINT, jornada VARCHAR, jornada_name VARCHAR,
    reserva academico_test.bool_sn, default_blocks_count BIGINT,
    schedule_start_time TIME, schedule_end_time TIME, descansos JSONB,
    previous_period_id BIGINT
)
LANGUAGE sql STABLE AS $$
    SELECT pa.PK_TPERIODO_ACADEMICO, pa.FK_TSEDE, s.NOMBRE, pa.FK_TANO_LECTIVO,
           al.NOMBRE, pa.FK_TLV_ESTADO, est.VALOR, est.NOMBRE,
           pa.FECHA_INICIO, pa.FECHA_FIN, pa.FECHA_LIMITE_MATRICULA, pa.NOMBRE,
           pa.FK_TLV_JORNADA, jor.VALOR, jor.NOMBRE, pa.RESERVA, pa.BLOQUES_POR_DEFECTO,
           pa.HORA_INICIO, pa.HORA_FIN,
           COALESCE((
               SELECT jsonb_agg(
                          jsonb_build_object(
                              'startTime', to_char(d.HORA_INICIO, 'HH24:MI'),
                              'endTime',   to_char(d.HORA_FIN,    'HH24:MI'))
                          ORDER BY d.HORA_INICIO)
                 FROM academico_test.TDESCANSOS d
                WHERE d.FK_TPERIODO_ACADEMICO = pa.PK_TPERIODO_ACADEMICO
                  AND d.ACTIVE = TRUE
           ), '[]'::jsonb),
           pa.FK_TPERIODO_ACADEMICO
      FROM academico_test.TPERIODO_ACADEMICO pa
      JOIN academico_test.TSEDE s          ON s.PK_TSEDE = pa.FK_TSEDE
      JOIN academico_test.TANO_LECTIVO al  ON al.PK_ANO_LECTIVO = pa.FK_TANO_LECTIVO
      JOIN academico_test.TLISTA_VALOR est ON est.PK_LISTA_VALOR = pa.FK_TLV_ESTADO
      JOIN academico_test.TLISTA_VALOR jor ON jor.PK_LISTA_VALOR = pa.FK_TLV_JORNADA
     WHERE pa.PK_TPERIODO_ACADEMICO = p_pk_periodo AND pa.ACTIVE = TRUE;
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_detalle_interno(BIGINT)
    IS 'INTERNO: un periodo academico activo con sus descansos, sin alcance. Lo usa fn_periodo_detalle.';

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_anteriores_por_sede_interno(
    p_fk_sede BIGINT, p_excluir_periodo BIGINT DEFAULT NULL
)
RETURNS TABLE (id BIGINT, name VARCHAR, start_date DATE)
LANGUAGE sql STABLE AS $$
    SELECT pa.PK_TPERIODO_ACADEMICO, pa.NOMBRE, pa.FECHA_INICIO
      FROM academico_test.TPERIODO_ACADEMICO pa
     WHERE pa.FK_TSEDE = p_fk_sede
       AND pa.ACTIVE = TRUE
       AND (p_excluir_periodo IS NULL OR pa.PK_TPERIODO_ACADEMICO <> p_excluir_periodo)
     ORDER BY pa.FECHA_INICIO DESC;
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_anteriores_por_sede_interno(BIGINT, BIGINT)
    IS 'INTERNO: periodos academicos activos de una sede (candidatos a periodo anterior), sin alcance. Lo usa fn_periodo_anteriores_por_sede.';

CREATE OR REPLACE FUNCTION academico_test.fn_descanso_agregar_interno(
    p_fk_periodo BIGINT, p_hora_inicio TIME, p_hora_fin TIME, p_audit VARCHAR
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_id BIGINT;
BEGIN
    PERFORM academico_test.fn_descanso_validar_rango(p_hora_inicio, p_hora_fin);
    PERFORM academico_test.fn_descanso_validar_dentro_periodo(p_fk_periodo, p_hora_inicio, p_hora_fin);
    PERFORM academico_test.fn_descanso_validar_sin_traslape(p_fk_periodo, p_hora_inicio, p_hora_fin);

    INSERT INTO academico_test.TDESCANSOS (FK_TPERIODO_ACADEMICO, HORA_INICIO, HORA_FIN, CREATED_BY)
    VALUES (p_fk_periodo, p_hora_inicio, p_hora_fin, p_audit)
    RETURNING PK_TDESCANSOS INTO v_id;
    RETURN v_id;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_descanso_agregar_interno(BIGINT, TIME, TIME, VARCHAR)
    IS 'INTERNO: valida (rango, dentro del horario del periodo, sin traslape) e inserta un descanso. Lo usa fn_descanso_agregar.';

CREATE OR REPLACE FUNCTION academico_test.fn_descanso_eliminar_interno(p_pk_descanso BIGINT, p_audit VARCHAR)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_hi TIME; v_hf TIME;
BEGIN
    UPDATE academico_test.TDESCANSOS
       SET ACTIVE = FALSE, MODIFIED_BY = p_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TDESCANSOS = p_pk_descanso AND ACTIVE = TRUE;
    IF NOT FOUND THEN
        SELECT HORA_INICIO, HORA_FIN INTO v_hi, v_hf
          FROM academico_test.TDESCANSOS WHERE PK_TDESCANSOS = p_pk_descanso;
        IF v_hi IS NOT NULL THEN
            RAISE EXCEPTION 'El descanso de % a % existe pero ya esta inactivo', v_hi, v_hf
                USING ERRCODE = 'P0002';
        ELSE
            RAISE EXCEPTION 'El descanso seleccionado no existe' USING ERRCODE = 'P0002';
        END IF;
    END IF;
    RETURN p_pk_descanso;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_descanso_eliminar_interno(BIGINT, VARCHAR)
    IS 'INTERNO: baja logica de un descanso; P0002 si no existe o ya estaba inactivo. Lo usa fn_descanso_eliminar.';

-- ------------------------------------------------- selects de los filtros
-- Alcance ya resuelto por el wrapper: p_global, o el periodo cae en uno de
-- p_establecimientos o de p_sedes.

-- TANO_LECTIVO es unico por (establecimiento, nombre): el mismo "2026" es una
-- fila por establecimiento. El filtro solo necesita el nombre: un id por año.
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_anos_lectivos_listar_interno(
    p_global BOOLEAN, p_establecimientos BIGINT[], p_sedes BIGINT[]
)
RETURNS TABLE (id BIGINT, name VARCHAR)
LANGUAGE sql STABLE AS $$
    SELECT MIN(al.PK_ANO_LECTIVO), al.NOMBRE
      FROM academico_test.TANO_LECTIVO al
      JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.FK_TANO_LECTIVO = al.PK_ANO_LECTIVO
      JOIN academico_test.TSEDE s               ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE al.ACTIVE = TRUE
       AND pa.ACTIVE = TRUE
       AND al.NOMBRE = to_char(CURRENT_DATE, 'YYYY')
       AND (p_global IS TRUE
            OR s.FK_TESTABLECIMIENTO = ANY(p_establecimientos)
            OR pa.FK_TSEDE = ANY(p_sedes))
     GROUP BY al.NOMBRE
     ORDER BY al.NOMBRE DESC;
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_anos_lectivos_listar_interno(BOOLEAN, BIGINT[], BIGINT[])
    IS 'INTERNO: años lectivos del año en curso con algun periodo academico activo dentro del alcance dado. Lo usa fn_periodo_anos_lectivos_listar.';

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_jornadas_listar_interno(
    p_fk_sede BIGINT, p_global BOOLEAN, p_establecimientos BIGINT[], p_sedes BIGINT[]
)
RETURNS TABLE (id BIGINT, name VARCHAR)
LANGUAGE sql STABLE AS $$
    SELECT MIN(jor.PK_LISTA_VALOR), jor.NOMBRE
      FROM academico_test.TPERIODO_ACADEMICO pa
      JOIN academico_test.TANO_LECTIVO al  ON al.PK_ANO_LECTIVO = pa.FK_TANO_LECTIVO
      JOIN academico_test.TSEDE s          ON s.PK_TSEDE = pa.FK_TSEDE
      JOIN academico_test.TLISTA_VALOR jor ON jor.PK_LISTA_VALOR = pa.FK_TLV_JORNADA
     WHERE pa.ACTIVE = TRUE
       AND al.ACTIVE = TRUE
       AND (p_fk_sede IS NULL OR pa.FK_TSEDE = p_fk_sede)
       AND (p_global IS TRUE
            OR s.FK_TESTABLECIMIENTO = ANY(p_establecimientos)
            OR pa.FK_TSEDE = ANY(p_sedes))
     GROUP BY jor.NOMBRE
     ORDER BY jor.NOMBRE;
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_jornadas_listar_interno(BIGINT, BOOLEAN, BIGINT[], BIGINT[])
    IS 'INTERNO: jornadas con algun periodo academico activo (opcionalmente de una sede) dentro del alcance dado. Lo usa fn_periodo_jornadas_listar.';

-- Sin restriccion de año: sirve de filtro de la tabla de periodos academicos.
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_sedes_listar_interno(
    p_global BOOLEAN, p_establecimientos BIGINT[], p_sedes BIGINT[]
)
RETURNS TABLE (id BIGINT, name VARCHAR)
LANGUAGE sql STABLE AS $$
    SELECT DISTINCT s.PK_TSEDE, s.NOMBRE
      FROM academico_test.TPERIODO_ACADEMICO pa
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE pa.ACTIVE = TRUE
       AND s.ACTIVE = TRUE
       AND (p_global IS TRUE
            OR s.FK_TESTABLECIMIENTO = ANY(p_establecimientos)
            OR pa.FK_TSEDE = ANY(p_sedes))
     ORDER BY s.NOMBRE;
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_sedes_listar_interno(BOOLEAN, BIGINT[], BIGINT[])
    IS 'INTERNO: sedes activas con algun periodo academico activo dentro del alcance dado. Lo usa fn_periodo_sedes_listar.';
