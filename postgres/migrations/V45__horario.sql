-- ===========================================================================
-- Horario — funciones consolidadas (última versión)
-- Generado: 2026-09-04
--
-- Migracion real: ejecutada en orden secuencial por Flyway. El bloque de
-- gate de permisos (fn_periodo_gate_escritura, fn_periodo_puede_ver, etc.)
-- vive en V36_1__gate_permisos_periodo_academico.sql, que corre antes.
-- (sin reformatear), la última versión vigente de cada función del módulo
-- Horario, verificada contra el número de migración más alto que la
-- redefine en postgres/migrations/.
--
-- Migraciones fuente consultadas:
--   V45__schedule_module.sql
--   V81__fix_schedule.sql
--   V108__horario_mensajes_error_con_nombre.sql
-- ===========================================================================

-- Fuente: V108__horario_mensajes_error_con_nombre.sql
SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_horario_calcular_bloques(
    p_fk_periodo_academico BIGINT
)
RETURNS TABLE (
    numero_bloque INT,
    hora_inicio   TIME,
    hora_fin      TIME
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_ini_min        INT;
    v_fin_min        INT;
    v_bloques        INT;
    v_cursor         INT;
    v_seg_starts     INT[] := '{}';
    v_seg_ends       INT[] := '{}';
    v_teaching_total INT := 0;
    v_block_minutes  NUMERIC;
    v_placed         INT := 0;
    v_seg_idx        INT;
    v_n_segs         INT;
    v_seg_start      INT;
    v_seg_end        INT;
    v_seg_len        INT;
    v_blocks_in_seg  INT;
    v_local_block    NUMERIC;
    v_block_no       INT := 0;
    v_k              INT;
    r                RECORD;
BEGIN
    SELECT (EXTRACT(HOUR FROM pa.HORA_INICIO)::INT * 60 + EXTRACT(MINUTE FROM pa.HORA_INICIO)::INT),
           (EXTRACT(HOUR FROM pa.HORA_FIN)::INT    * 60 + EXTRACT(MINUTE FROM pa.HORA_FIN)::INT),
           pa.BLOQUES_POR_DEFECTO
      INTO v_ini_min, v_fin_min, v_bloques
      FROM academico_test.TPERIODO_ACADEMICO pa
     WHERE pa.PK_TPERIODO_ACADEMICO = p_fk_periodo_academico;

    -- Sin jornada valida (periodo inexistente, sin horas o sin bloques): no
    -- hay bloques que calcular. Igual que buildSlots() -> [] en el front.
    IF v_ini_min IS NULL OR v_fin_min IS NULL OR v_fin_min <= v_ini_min
       OR v_bloques IS NULL OR v_bloques <= 0 THEN
        RETURN;
    END IF;

    -- 1. Segmentos de clase = la jornada partida por los descansos activos
    --    (se ignoran los que caen fuera de [HORA_INICIO, HORA_FIN] o estan
    --    invertidos; los solapados se fusionan via GREATEST(cursor, fin)).
    v_cursor := v_ini_min;
    FOR r IN
        SELECT (EXTRACT(HOUR FROM d.HORA_INICIO)::INT * 60 + EXTRACT(MINUTE FROM d.HORA_INICIO)::INT) AS ini,
               (EXTRACT(HOUR FROM d.HORA_FIN)::INT    * 60 + EXTRACT(MINUTE FROM d.HORA_FIN)::INT)    AS fin
          FROM academico_test.TDESCANSOS d
         WHERE d.FK_TPERIODO_ACADEMICO = p_fk_periodo_academico
           AND d.ACTIVE = TRUE
         ORDER BY d.HORA_INICIO
    LOOP
        IF r.fin <= r.ini OR r.ini < v_ini_min OR r.fin > v_fin_min THEN
            CONTINUE;
        END IF;
        IF r.ini > v_cursor THEN
            v_seg_starts := array_append(v_seg_starts, v_cursor);
            v_seg_ends   := array_append(v_seg_ends, r.ini);
        END IF;
        v_cursor := GREATEST(v_cursor, r.fin);
    END LOOP;
    IF v_fin_min > v_cursor THEN
        v_seg_starts := array_append(v_seg_starts, v_cursor);
        v_seg_ends   := array_append(v_seg_ends, v_fin_min);
    END IF;

    v_n_segs := array_length(v_seg_starts, 1);
    IF v_n_segs IS NULL THEN
        RETURN;  -- la jornada entera quedo cubierta por descansos
    END IF;

    -- 2. Minutos de clase totales y largo "ideal" de bloque (BLOQUES_POR_DEFECTO
    --    parejo sobre el total, antes de repartir por segmento).
    FOR v_seg_idx IN 1..v_n_segs LOOP
        v_teaching_total := v_teaching_total + (v_seg_ends[v_seg_idx] - v_seg_starts[v_seg_idx]);
    END LOOP;
    v_block_minutes := v_teaching_total::NUMERIC / v_bloques;

    -- 3. Reparto de bloques dentro de cada segmento (el ultimo se lleva el
    --    resto exacto: v_bloques - v_placed).
    FOR v_seg_idx IN 1..v_n_segs LOOP
        v_seg_start := v_seg_starts[v_seg_idx];
        v_seg_end   := v_seg_ends[v_seg_idx];
        v_seg_len   := v_seg_end - v_seg_start;

        v_blocks_in_seg := GREATEST(0,
            CASE WHEN v_seg_idx = v_n_segs
                 THEN v_bloques - v_placed
                 ELSE ROUND(v_seg_len / v_block_minutes)::INT
            END);
        v_local_block := CASE WHEN v_blocks_in_seg > 0
                               THEN v_seg_len::NUMERIC / v_blocks_in_seg
                               ELSE v_block_minutes END;

        FOR v_k IN 0..v_blocks_in_seg - 1 LOOP
            numero_bloque := v_block_no;
            hora_inicio   := '00:00'::TIME + (ROUND(v_seg_start + v_k * v_local_block)::TEXT || ' minutes')::INTERVAL;
            hora_fin      := '00:00'::TIME + (ROUND(v_seg_start + (v_k + 1) * v_local_block)::TEXT || ' minutes')::INTERVAL;
            RETURN NEXT;
            v_block_no := v_block_no + 1;
        END LOOP;
        v_placed := v_placed + v_blocks_in_seg;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_horario_calcular_bloques(BIGINT)
    IS 'Hora de inicio/fin (TIME) de cada NUMERO_BLOQUE (0-based) del periodo academico, partiendo la jornada [HORA_INICIO,HORA_FIN] de TPERIODO_ACADEMICO por los descansos activos de TDESCANSOS. Puerto 1:1 de buildSlots() (front, schedule-data.ts). La consume fn_horario_guardar para persistir THORARIO.HORA_INICIO/HORA_FIN.';

-- Fuente: V81__fix_schedule.sql. Indice inseparable del fix de
-- fn_horario_guardar de abajo (V108 lo reconsolida verbatim en su propio
-- archivo, junto al cuerpo de la funcion, por eso se ubica aqui): blinda a
-- nivel de base de datos la garantia "una sola asignatura por grupo+dia+
-- bloque activo", no solo por la logica de la funcion.
CREATE UNIQUE INDEX IF NOT EXISTS uq_horario_activo_por_celda
ON academico_test.THORARIO (
    FK_TGRUPO,
    FK_TLV_DIA_SEMANA,
    NUMERO_BLOQUE
)
WHERE ACTIVE = TRUE;

-- Fuente: V108__horario_mensajes_error_con_nombre.sql
CREATE OR REPLACE FUNCTION academico_test.fn_horario_guardar(
    p_fk_grado bigint,
    p_entries jsonb,
    p_pk_usuario_solicitante bigint
)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    v_audit        VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_max_bloques  BIGINT;
    v_fk_periodo   BIGINT;
    v_count        INT := 0;

    v_bloque       INT;
    v_grupo        BIGINT;
    v_dia          BIGINT;
    v_planitem     BIGINT;
    v_asig         BIGINT;

    entry          JSONB;

    v_nombre_grado VARCHAR(130);
    v_tmp_nombre   VARCHAR;
    v_tmp_nombre2  VARCHAR;
BEGIN

    --------------------------------------------------------------------------
    -- 1. Validar que el período permita escritura
    --------------------------------------------------------------------------

    --------------------------------------------------------------------------
    -- 2. Obtener cantidad máxima de bloques del período (se adelanta para
    --    poder resolver sede+jornada del gate de abajo, CU-86e2w4xdt).
    --------------------------------------------------------------------------

    SELECT pa.BLOQUES_POR_DEFECTO, g.NOMBRE, pa.PK_TPERIODO_ACADEMICO
      INTO v_max_bloques, v_nombre_grado, v_fk_periodo
      FROM academico_test.TGRADO g
      JOIN academico_test.TPERIODO_ACADEMICO pa
        ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
     WHERE g.PK_TGRADO = p_fk_grado
       AND g.ACTIVE = TRUE;

    -- 1. Autorizacion (CU-86e2w4xdt): gate por (EE, sede, jornada) del periodo del grado.
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante,
        academico_test.fn_periodo_establecimiento(v_fk_periodo),
        academico_test.fn_periodo_sede(v_fk_periodo),
        academico_test.fn_periodo_jornada(v_fk_periodo), 'EDITAR');

    IF v_max_bloques IS NULL THEN
        SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_grado;
        IF v_tmp_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'El grado "%" existe pero esta inactivo', v_tmp_nombre
                USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'El grado seleccionado no existe' USING ERRCODE = '23503';
        END IF;
    END IF;


    --------------------------------------------------------------------------
    -- 3. Lock por grado
    --
    -- Evita que dos transacciones modifiquen simultáneamente
    -- el horario del mismo grado.
    --------------------------------------------------------------------------

    PERFORM pg_advisory_xact_lock(
        hashtext('horario:' || p_fk_grado::TEXT)
    );

    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        format('Configuración del horario del grado %s', v_nombre_grado),
        academico_test.fn_periodo_establecimiento((
            SELECT g.FK_TPERIODO_ACADEMICO FROM academico_test.TGRADO g WHERE g.PK_TGRADO = p_fk_grado))
    );


    --------------------------------------------------------------------------
    -- 4. Crear tabla temporal con el estado deseado
    --
    -- Si la función se llama nuevamente dentro de la misma transacción,
    -- primero eliminamos la tabla temporal anterior.
    --------------------------------------------------------------------------

    DROP TABLE IF EXISTS tmp_horario_entries;

    CREATE TEMP TABLE tmp_horario_entries (
        grupo_id       BIGINT NOT NULL,
        dia_id         BIGINT NOT NULL,
        bloque         INT NOT NULL,
        plan_item_id   BIGINT NOT NULL,
        asignatura_id  BIGINT NOT NULL,

        -- Una sola asignatura por grupo + día + bloque
        UNIQUE (grupo_id, dia_id, bloque)
    ) ON COMMIT DROP;


    --------------------------------------------------------------------------
    -- 5. Validar y cargar p_entries en la tabla temporal
    --------------------------------------------------------------------------

    FOR entry IN
        SELECT *
        FROM jsonb_array_elements(
            COALESCE(p_entries, '[]'::JSONB)
        )
    LOOP

        ----------------------------------------------------------------------
        -- Obtener valores del JSON
        ----------------------------------------------------------------------

        v_bloque   := (entry->>'bloque')::INT;
        v_grupo    := (entry->>'grupoId')::BIGINT;
        v_dia      := (entry->>'diaId')::BIGINT;
        v_planitem := (entry->>'planItemId')::BIGINT;


        ----------------------------------------------------------------------
        -- Validar campos obligatorios
        ----------------------------------------------------------------------

        IF v_bloque IS NULL
           OR v_grupo IS NULL
           OR v_dia IS NULL
           OR v_planitem IS NULL
        THEN
            RAISE EXCEPTION
                'Cada celda requiere grupoId, planItemId, diaId y bloque'
                USING ERRCODE = '22023';
        END IF;


        ----------------------------------------------------------------------
        -- Validar rango del bloque
        ----------------------------------------------------------------------

        IF v_bloque < 0
           OR v_bloque >= v_max_bloques
        THEN
            RAISE EXCEPTION
                'Bloque % fuera de rango (0 a %)',
                v_bloque,
                v_max_bloques - 1
                USING ERRCODE = '22023';
        END IF;


        ----------------------------------------------------------------------
        -- Validar que el grupo pertenezca al grado y esté activo
        ----------------------------------------------------------------------

        IF NOT EXISTS (
            SELECT 1
            FROM academico_test.TGRUPO
            WHERE PK_TGRUPO = v_grupo
              AND FK_TGRADO = p_fk_grado
              AND ACTIVE = TRUE
        )
        THEN
            SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TGRUPO WHERE PK_TGRUPO = v_grupo;
            IF v_tmp_nombre IS NOT NULL THEN
                RAISE EXCEPTION
                    'El grupo "%" no pertenece al grado "%" o esta inactivo',
                    v_tmp_nombre,
                    v_nombre_grado
                    USING ERRCODE = '22023';
            ELSE
                RAISE EXCEPTION 'El grupo seleccionado no existe' USING ERRCODE = '22023';
            END IF;
        END IF;


        ----------------------------------------------------------------------
        -- Validar día de la semana
        ----------------------------------------------------------------------

        IF NOT EXISTS (
            SELECT 1
            FROM academico_test.TLISTA_VALOR
            WHERE PK_LISTA_VALOR = v_dia
              AND ACTIVE = TRUE
              AND CATEGORIA = 'DIA_SEMANA'
        )
        THEN
            SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = v_dia;
            IF v_tmp_nombre IS NOT NULL THEN
                RAISE EXCEPTION
                    'El dia "%" no es valido (debe ser de la categoria DIA_SEMANA)',
                    v_tmp_nombre
                    USING ERRCODE = '23503';
            ELSE
                RAISE EXCEPTION 'El dia seleccionado no existe' USING ERRCODE = '23503';
            END IF;
        END IF;


        ----------------------------------------------------------------------
        -- Obtener asignatura a partir del planItem
        ----------------------------------------------------------------------

        SELECT ap.FK_TASIGNATURA
          INTO v_asig
          FROM academico_test.TASIGNATURA_PLAN ap
          JOIN academico_test.TPLAN pl
            ON pl.PK_TPLAN = ap.FK_TPLAN
           AND pl.ACTIVE = TRUE
         WHERE ap.PK_TASIGNATURA_PLAN = v_planitem
           AND ap.ACTIVE = TRUE
           AND pl.FK_TGRADO = p_fk_grado;


        ----------------------------------------------------------------------
        -- Validar planItem
        ----------------------------------------------------------------------

        IF v_asig IS NULL THEN
            SELECT a.NOMBRE INTO v_tmp_nombre
              FROM academico_test.TASIGNATURA_PLAN ap
              JOIN academico_test.TASIGNATURA a ON a.PK_TASIGNATURA = ap.FK_TASIGNATURA
             WHERE ap.PK_TASIGNATURA_PLAN = v_planitem;
            IF v_tmp_nombre IS NOT NULL THEN
                RAISE EXCEPTION
                    'El renglon de plan de la asignatura "%" no esta activo o no pertenece al grado "%"',
                    v_tmp_nombre,
                    v_nombre_grado
                    USING ERRCODE = '23503';
            ELSE
                RAISE EXCEPTION 'El renglon de plan seleccionado no existe' USING ERRCODE = '23503';
            END IF;
        END IF;


        ----------------------------------------------------------------------
        -- Validar duplicado dentro del payload
        --
        -- La identidad de una celda es:
        --
        -- grupo + día + bloque
        ----------------------------------------------------------------------

        IF EXISTS (
            SELECT 1
            FROM tmp_horario_entries
            WHERE grupo_id = v_grupo
              AND dia_id = v_dia
              AND bloque = v_bloque
        )
        THEN
            SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TGRUPO WHERE PK_TGRUPO = v_grupo;
            SELECT NOMBRE INTO v_tmp_nombre2 FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = v_dia;
            RAISE EXCEPTION
                'Celda duplicada: grupo "%", dia "%", bloque %',
                v_tmp_nombre,
                v_tmp_nombre2,
                v_bloque
                USING ERRCODE = '22023';
        END IF;


        ----------------------------------------------------------------------
        -- Guardar entrada validada
        ----------------------------------------------------------------------

        INSERT INTO tmp_horario_entries (
            grupo_id,
            dia_id,
            bloque,
            plan_item_id,
            asignatura_id
        )
        VALUES (
            v_grupo,
            v_dia,
            v_bloque,
            v_planitem,
            v_asig
        );

    END LOOP;


    --------------------------------------------------------------------------
    -- 6. DESACTIVAR CELDAS ELIMINADAS
    --
    -- Si existe una celda activa en BD pero ya no viene en p_entries,
    -- significa que el usuario la eliminó.
    --------------------------------------------------------------------------

    UPDATE academico_test.THORARIO h
       SET ACTIVE      = FALSE,
           MODIFIED_BY = v_audit,
           MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE h.ACTIVE = TRUE
       AND h.FK_TGRUPO IN (
            SELECT g.PK_TGRUPO
            FROM academico_test.TGRUPO g
            WHERE g.FK_TGRADO = p_fk_grado
              AND g.ACTIVE = TRUE
       )
       AND NOT EXISTS (
            SELECT 1
            FROM tmp_horario_entries e
            WHERE e.grupo_id = h.FK_TGRUPO
              AND e.dia_id = h.FK_TLV_DIA_SEMANA
              AND e.bloque = h.NUMERO_BLOQUE
       );


    --------------------------------------------------------------------------
    -- 7. DESACTIVAR VERSIONES ANTERIORES DE CELDAS MODIFICADAS
    --
    -- Ejemplo:
    --
    -- BD:
    -- lunes / bloque 2 / Matemáticas
    --
    -- Nuevo payload:
    -- lunes / bloque 2 / Física
    --
    -- Se desactiva Matemáticas.
    --------------------------------------------------------------------------

    UPDATE academico_test.THORARIO h
       SET ACTIVE      = FALSE,
           MODIFIED_BY = v_audit,
           MODIFIED_AT = CURRENT_TIMESTAMP
      FROM tmp_horario_entries e
     WHERE h.ACTIVE = TRUE
       AND h.FK_TGRUPO = e.grupo_id
       AND h.FK_TLV_DIA_SEMANA = e.dia_id
       AND h.NUMERO_BLOQUE = e.bloque
       AND h.FK_TASIGNATURA <> e.asignatura_id;


    --------------------------------------------------------------------------
    -- 8. INSERTAR CELDAS NUEVAS O MODIFICADAS
    --
    -- Las celdas que:
    --
    --  - nunca existieron
    --  - fueron modificadas y la versión anterior acaba de ser desactivada
    --
    -- se insertan como ACTIVE=true.
    --------------------------------------------------------------------------

    INSERT INTO academico_test.THORARIO (
        NUMERO_BLOQUE,
        FK_TLV_DIA_SEMANA,
        FK_TGRUPO,
        FK_TASIGNATURA,
        HORA_INICIO,
        HORA_FIN,
        CREATED_BY
    )
    SELECT
        e.bloque,
        e.dia_id,
        e.grupo_id,
        e.asignatura_id,
        -- Hora real del bloque (partiendo la jornada del periodo por los
        -- descansos, fn_horario_calcular_bloques) y NO la de todo el periodo
        -- academico. THORARIO.HORA_INICIO/FIN son TIMESTAMP (no TIME) y
        -- Postgres no castea TIME a TIMESTAMP directo -- se combina con
        -- CURRENT_DATE (solo importa la hora; la fecha es arbitraria pero
        -- consistente entre inicio y fin para el EXTRACT(EPOCH FROM ...)
        -- que hace fn_asistencia_calendario). Sin match (periodo sin
        -- BLOQUES_POR_DEFECTO/horas o bloque fuera del reparto calculado)
        -- queda NULL: se guarda la celda igual, sin franja horaria derivada.
        CURRENT_DATE + b.hora_inicio,
        CURRENT_DATE + b.hora_fin,
        v_audit
    FROM tmp_horario_entries e
    LEFT JOIN academico_test.fn_horario_calcular_bloques(v_fk_periodo) b
           ON b.numero_bloque = e.bloque
    WHERE NOT EXISTS (
        SELECT 1
        FROM academico_test.THORARIO h
        WHERE h.ACTIVE = TRUE
          AND h.FK_TGRUPO = e.grupo_id
          AND h.FK_TLV_DIA_SEMANA = e.dia_id
          AND h.NUMERO_BLOQUE = e.bloque
    );


    --------------------------------------------------------------------------
    -- 9. Retornar cantidad de celdas activas del grado
    --------------------------------------------------------------------------

    SELECT COUNT(*)
      INTO v_count
      FROM academico_test.THORARIO h
      JOIN academico_test.TGRUPO g
        ON g.PK_TGRUPO = h.FK_TGRUPO
     WHERE h.ACTIVE = TRUE
       AND g.FK_TGRADO = p_fk_grado
       AND g.ACTIVE = TRUE;


    RETURN v_count;

END;
$$;

-- Fuente: V45__schedule_module.sql
CREATE OR REPLACE FUNCTION academico_test.fn_horario_listar(
    p_fk_grado BIGINT,
    p_fk_grupo BIGINT DEFAULT NULL,   -- filtro opcional por grupo
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS TABLE (id BIGINT, grado_id BIGINT, grado VARCHAR, grupo_id BIGINT, grupo VARCHAR,
               plan_item_id BIGINT, asignatura_id BIGINT, asignatura VARCHAR,
               dia_id BIGINT, dia VARCHAR, dia_name VARCHAR, bloque NUMERIC)
LANGUAGE sql STABLE AS $$
    SELECT h.PK_THORARIO, g.PK_TGRADO, g.NOMBRE, h.FK_TGRUPO, gr.NOMBRE,
           ap.PK_TASIGNATURA_PLAN, h.FK_TASIGNATURA, s.NOMBRE,
           h.FK_TLV_DIA_SEMANA, dia.VALOR, dia.NOMBRE, h.NUMERO_BLOQUE
      FROM academico_test.THORARIO h
      JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = h.FK_TGRUPO AND gr.ACTIVE = TRUE
      JOIN academico_test.TGRADO g ON g.PK_TGRADO = gr.FK_TGRADO
      LEFT JOIN academico_test.TASIGNATURA s ON s.PK_TASIGNATURA = h.FK_TASIGNATURA
      LEFT JOIN academico_test.TLISTA_VALOR dia ON dia.PK_LISTA_VALOR = h.FK_TLV_DIA_SEMANA
      LEFT JOIN academico_test.TPLAN pl ON pl.FK_TGRADO = gr.FK_TGRADO AND pl.ACTIVE = TRUE
      LEFT JOIN academico_test.TASIGNATURA_PLAN ap ON ap.FK_TPLAN = pl.PK_TPLAN
           AND ap.FK_TASIGNATURA = h.FK_TASIGNATURA AND ap.ACTIVE = TRUE
     WHERE gr.FK_TGRADO = p_fk_grado AND h.ACTIVE = TRUE
       AND academico_test.fn_periodo_puede_ver(p_pk_usuario_solicitante, g.FK_TPERIODO_ACADEMICO)
       AND (p_fk_grupo IS NULL OR h.FK_TGRUPO = p_fk_grupo)
     ORDER BY h.FK_TGRUPO, h.FK_TLV_DIA_SEMANA, h.NUMERO_BLOQUE;
$$;

-- Fuente: V45__schedule_module.sql
CREATE OR REPLACE FUNCTION academico_test.fn_horario_asignaturas(
    p_fk_grado BIGINT, p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS TABLE (plan_item_id BIGINT, nombre VARCHAR, bloques NUMERIC, color VARCHAR)
LANGUAGE sql STABLE AS $$
    SELECT ap.PK_TASIGNATURA_PLAN, s.NOMBRE, ap.NUMERO_HORA, s.COLOR
      FROM academico_test.TASIGNATURA_PLAN ap
      JOIN academico_test.TPLAN pl       ON pl.PK_TPLAN = ap.FK_TPLAN AND pl.ACTIVE = TRUE
      JOIN academico_test.TASIGNATURA s  ON s.PK_TASIGNATURA = ap.FK_TASIGNATURA AND s.ACTIVE = TRUE
     WHERE pl.FK_TGRADO = p_fk_grado AND ap.ACTIVE = TRUE
       AND academico_test.fn_periodo_puede_ver(p_pk_usuario_solicitante,
             (SELECT g.FK_TPERIODO_ACADEMICO FROM academico_test.TGRADO g WHERE g.PK_TGRADO = p_fk_grado))
     ORDER BY s.NOMBRE;
$$;
