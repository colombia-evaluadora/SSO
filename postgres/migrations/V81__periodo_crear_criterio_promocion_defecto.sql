SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_crear(
    p_fk_sede BIGINT,
    p_fk_estado BIGINT,
    p_fecha_inicio DATE,
    p_fecha_fin DATE,
    p_fecha_limite_matricula DATE,
    p_fk_jornada BIGINT,
    p_hora_inicio TIME,
    p_hora_fin TIME,
    p_reserva academico_test.bool_sn DEFAULT 'S',
    p_bloques_por_defecto BIGINT DEFAULT 0,
    p_fk_periodo_anterior BIGINT DEFAULT NULL,
    p_descanso_inicio TIME[] DEFAULT NULL,
    p_descanso_fin TIME[] DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_establecimiento    BIGINT;
    v_nombre_sede        VARCHAR(130);
    v_nombre_ano         VARCHAR(50);
    v_nombre_jornada     TEXT;
    v_nombre_estado      TEXT;
    v_categoria_jornada  VARCHAR(30);
    v_categoria_estado   VARCHAR(30);
    v_ano_id             BIGINT;
    v_id                 BIGINT;
    v_tmp_nombre         TEXT;
    v_audit              VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    i                    INT;
    j                    INT;
    c_formato_calif        BIGINT;
    c_elemento_def         BIGINT;
    c_criterio_final       BIGINT;
    c_criterio_area        BIGINT;
    c_desempeno_sin_calif  BIGINT;
    c_modif_final_peraca   BIGINT;
    c_modo_redondear       BIGINT;
    c_criterio_asignatura  BIGINT;
    v_formato_nombre       VARCHAR(120);
    v_formato_max          NUMERIC;
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, NULL, NULL, NULL, 'CREAR');

    IF p_fk_sede IS NULL OR p_fk_estado IS NULL OR p_fecha_inicio IS NULL
       OR p_fecha_fin IS NULL OR p_fecha_limite_matricula IS NULL
       OR p_fk_jornada IS NULL OR p_hora_inicio IS NULL OR p_hora_fin IS NULL THEN
        RAISE EXCEPTION 'Faltan campos obligatorios del periodo academico'
            USING ERRCODE = '22023';
    END IF;

    IF p_fecha_fin <= p_fecha_inicio THEN
        RAISE EXCEPTION 'La fecha fin (%) debe ser posterior a la fecha inicio (%)',
            p_fecha_fin, p_fecha_inicio USING ERRCODE = '22023';
    END IF;
    IF p_fecha_limite_matricula < p_fecha_inicio OR p_fecha_limite_matricula > p_fecha_fin THEN
        RAISE EXCEPTION 'La fecha limite de matricula (%) debe estar entre inicio (%) y fin (%)',
            p_fecha_limite_matricula, p_fecha_inicio, p_fecha_fin USING ERRCODE = '22023';
    END IF;
    IF p_hora_fin < p_hora_inicio THEN
        RAISE EXCEPTION 'La hora fin (%) no puede ser anterior a la hora inicio (%)',
            p_hora_fin, p_hora_inicio USING ERRCODE = '22023';
    END IF;

    SELECT FK_TESTABLECIMIENTO, NOMBRE INTO v_establecimiento, v_nombre_sede
      FROM academico_test.TSEDE WHERE PK_TSEDE = p_fk_sede AND ACTIVE = TRUE;
    IF v_establecimiento IS NULL THEN
        SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TSEDE WHERE PK_TSEDE = p_fk_sede;
        IF v_tmp_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'La sede "%" existe pero esta inactiva', v_tmp_nombre USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'La sede seleccionada no existe' USING ERRCODE = '23503';
        END IF;
    END IF;
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_establecimiento, p_fk_sede, p_fk_jornada, 'CREAR');

    IF p_fk_periodo_anterior IS NOT NULL THEN
        PERFORM 1
          FROM academico_test.TPERIODO_ACADEMICO pa
          JOIN academico_test.TSEDE se ON se.PK_TSEDE = pa.FK_TSEDE
         WHERE pa.PK_TPERIODO_ACADEMICO = p_fk_periodo_anterior
           AND pa.ACTIVE = TRUE
           AND se.FK_TESTABLECIMIENTO = v_establecimiento;
        IF NOT FOUND THEN
            SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TPERIODO_ACADEMICO
             WHERE PK_TPERIODO_ACADEMICO = p_fk_periodo_anterior;
            IF v_tmp_nombre IS NOT NULL THEN
                RAISE EXCEPTION 'El periodo academico anterior "%" existe pero esta inactivo o pertenece a otro establecimiento',
                    v_tmp_nombre USING ERRCODE = '22023';
            ELSE
                RAISE EXCEPTION 'El periodo academico anterior seleccionado no existe' USING ERRCODE = '22023';
            END IF;
        END IF;
    END IF;

    v_nombre_ano := to_char(p_fecha_inicio, 'YYYY');
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Creación del año lectivo %s', v_nombre_ano), v_establecimiento);
    INSERT INTO academico_test.TANO_LECTIVO (NOMBRE, FK_TESTABLECIMIENTO, CREATED_BY)
    VALUES (v_nombre_ano, v_establecimiento, v_audit)
    ON CONFLICT (FK_TESTABLECIMIENTO, NOMBRE) DO NOTHING
    RETURNING PK_ANO_LECTIVO INTO v_ano_id;
    IF v_ano_id IS NULL THEN
        SELECT PK_ANO_LECTIVO INTO v_ano_id FROM academico_test.TANO_LECTIVO
         WHERE FK_TESTABLECIMIENTO = v_establecimiento AND NOMBRE = v_nombre_ano;
    END IF;

    SELECT VALOR, CATEGORIA INTO v_nombre_estado, v_categoria_estado
      FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_fk_estado;
    IF v_nombre_estado IS NULL THEN
        RAISE EXCEPTION 'El estado seleccionado no existe' USING ERRCODE = '23503';
    END IF;
    IF v_categoria_estado <> 'ESTADOPERIODO' THEN
        RAISE EXCEPTION 'El estado "%" no pertenece a la categoria ESTADOPERIODO (es %)',
            v_nombre_estado, v_categoria_estado USING ERRCODE = '22023';
    END IF;

    SELECT VALOR, CATEGORIA INTO v_nombre_jornada, v_categoria_jornada
      FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_fk_jornada;
    IF v_nombre_jornada IS NULL THEN
        RAISE EXCEPTION 'La jornada seleccionada no existe' USING ERRCODE = '23503';
    END IF;
    IF v_categoria_jornada <> 'JORNADA' THEN
        RAISE EXCEPTION 'La jornada "%" no pertenece a la categoria JORNADA (es %)',
            v_nombre_jornada, v_categoria_jornada USING ERRCODE = '22023';
    END IF;

    IF EXISTS (
        SELECT 1 FROM academico_test.TPERIODO_ACADEMICO
         WHERE FK_TANO_LECTIVO = v_ano_id AND FK_TSEDE = p_fk_sede
           AND FK_TLV_JORNADA = p_fk_jornada AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'La sede "%" ya tiene un periodo academico activo en la jornada "%" para el año lectivo %',
            v_nombre_sede, v_nombre_jornada, v_nombre_ano USING ERRCODE = '23505';
    END IF;

    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Creación del periodo académico %s - %s en la sede %s', v_nombre_ano, v_nombre_jornada, v_nombre_sede),
        v_establecimiento);

    INSERT INTO academico_test.TPERIODO_ACADEMICO (
        FK_TPERIODO_ACADEMICO, FK_TANO_LECTIVO, FK_TLV_ESTADO, FK_TSEDE,
        FECHA_INICIO, FECHA_FIN, FECHA_LIMITE_MATRICULA, FK_TLV_JORNADA,
        RESERVA, BLOQUES_POR_DEFECTO, NOMBRE, HORA_INICIO, HORA_FIN, CREATED_BY
    ) VALUES (
        p_fk_periodo_anterior, v_ano_id, p_fk_estado, p_fk_sede,
        p_fecha_inicio, p_fecha_fin, p_fecha_limite_matricula, p_fk_jornada,
        COALESCE(p_reserva, 'S'), COALESCE(p_bloques_por_defecto, 0),
        v_nombre_ano || ' - ' || v_nombre_jornada, p_hora_inicio, p_hora_fin, v_audit
    )
    RETURNING PK_TPERIODO_ACADEMICO INTO v_id;

    SELECT PK_LISTA_VALOR, NOMBRE INTO c_formato_calif, v_formato_nombre
      FROM academico_test.TLISTA_VALOR WHERE CATEGORIA = 'FORMATO_CALIFICACION' AND VALOR = 'DIEZ' AND ACTIVE = TRUE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el valor por defecto de FORMATO_CALIFICACION (VALOR=DIEZ) en TLISTA_VALOR' USING ERRCODE = 'P0002';
    END IF;
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
        ROUND(1 / v_formato_max * 100, 2), 100, v_audit
    )
    ON CONFLICT (PK_TCRITERIO_EVALUACION) DO NOTHING;

    INSERT INTO academico_test.TCRITERIO_PROMOCION (
        FK_TPERIODO_ACADEMICO, FK_TGRADO, NODO_CURRICULAR, CANTIDAD_NIVELAR,
        ASIGNATURA_OBLIGATORIA, APROBACION_PROMEDIO, DESEMPENHO_MINIMO_GENERAL,
        DESEMPENHO_MINIMO, MAX_ASIG_PROMEDIO, MINIMO_INASISTENCIAS,
        MAX_ASIG_NIVELAR_PROMOVIDO, POR_DEFECTO, CREATED_BY
    ) VALUES (
        v_id, NULL, 'AS', 2, 'N', 'N', 25, 25, 1, 25, 2, 'S', v_audit
    );

    IF p_descanso_inicio IS NOT NULL THEN
        IF p_descanso_fin IS NULL
           OR COALESCE(array_length(p_descanso_inicio, 1), 0) <> COALESCE(array_length(p_descanso_fin, 1), 0) THEN
            RAISE EXCEPTION 'Los arreglos de inicio/fin de descansos deben tener la misma longitud'
                USING ERRCODE = '22023';
        END IF;
        IF array_length(p_descanso_inicio, 1) IS NOT NULL THEN
            FOR i IN 1 .. array_length(p_descanso_inicio, 1) LOOP
            IF p_descanso_fin[i] < p_descanso_inicio[i] THEN
                RAISE EXCEPTION 'Descanso %: hora fin anterior a inicio', i USING ERRCODE = '22023';
            END IF;
            IF p_descanso_inicio[i] < p_hora_inicio OR p_descanso_fin[i] > p_hora_fin THEN
                RAISE EXCEPTION 'Descanso % (% a %) fuera del horario del periodo (% a %)',
                    i, p_descanso_inicio[i], p_descanso_fin[i], p_hora_inicio, p_hora_fin
                    USING ERRCODE = '22023';
            END IF;
            FOR j IN 1 .. i - 1 LOOP
                IF p_descanso_inicio[i] < p_descanso_fin[j] AND p_descanso_fin[i] > p_descanso_inicio[j] THEN
                    RAISE EXCEPTION 'Los descansos % y % se traslapan', j, i USING ERRCODE = '22023';
                END IF;
            END LOOP;
            INSERT INTO academico_test.TDESCANSOS (FK_TPERIODO_ACADEMICO, HORA_INICIO, HORA_FIN, CREATED_BY)
            VALUES (v_id, p_descanso_inicio[i], p_descanso_fin[i], v_audit);
        END LOOP;
        END IF;
    END IF;

    RETURN v_id;
END;
$$;
