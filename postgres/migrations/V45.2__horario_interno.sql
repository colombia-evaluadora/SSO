-- ===========================================================================
-- V45.2 -- Horario: nucleos _interno
-- ===========================================================================
-- QUE HACE: guardar/listar/asignaturas del horario de un grado sin permisos,
-- fn_horario_calcular_bloques (helper puro de franjas horarias) y el indice
-- unico de celda activa, y el horario automatico de preescolar con su trigger
-- sobre TASIGNATURA_PLAN. El gate y la auditoria van en V45.3.
-- POR QUE AQUI: capa 2 del modulo (V45.1 / V45.2 / V45.3).
-- DEPENDE DE: V22 (THORARIO, TDESCANSOS, TPERIODO_ACADEMICO), V45.1, V43.2.
-- ===========================================================================

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

    -- Sin jornada valida: no hay bloques que calcular. Igual que buildSlots() -> [] en el front.
    IF v_ini_min IS NULL OR v_fin_min IS NULL OR v_fin_min <= v_ini_min
       OR v_bloques IS NULL OR v_bloques <= 0 THEN
        RETURN;
    END IF;

    -- Segmentos de clase = jornada partida por los descansos activos (se ignoran los
    -- invertidos o fuera de rango; los solapados se fusionan via GREATEST(cursor, fin)).
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

    -- Minutos de clase totales y largo "ideal" de bloque, parejo sobre el total,
    -- antes de repartir por segmento.
    FOR v_seg_idx IN 1..v_n_segs LOOP
        v_teaching_total := v_teaching_total + (v_seg_ends[v_seg_idx] - v_seg_starts[v_seg_idx]);
    END LOOP;
    v_block_minutes := v_teaching_total::NUMERIC / v_bloques;

    -- El ultimo segmento se lleva el resto exacto (v_bloques - v_placed).
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
    IS 'INTERNO: hora de inicio/fin (TIME) de cada NUMERO_BLOQUE (0-based) del periodo academico, partiendo la jornada [HORA_INICIO,HORA_FIN] de TPERIODO_ACADEMICO por los descansos activos de TDESCANSOS. Puerto 1:1 de buildSlots() (front, schedule-data.ts). La usan fn_horario_guardar_interno (THORARIO.HORA_INICIO/HORA_FIN), fn_horario_preescolar_autogenerar y fn_actividad_programacion_assert.';

-- Blinda en la base "una sola asignatura por grupo+dia+bloque activo", no solo
-- por la logica de fn_horario_guardar_interno.
CREATE UNIQUE INDEX IF NOT EXISTS uq_horario_activo_por_celda
ON academico_test.THORARIO (FK_TGRUPO, FK_TLV_DIA_SEMANA, NUMERO_BLOQUE)
WHERE ACTIVE = TRUE;

-- p_entries reemplaza el horario completo del grado: lo que no viene se desactiva.
CREATE OR REPLACE FUNCTION academico_test.fn_horario_guardar_interno(
    p_fk_grado BIGINT,
    p_entries  JSONB,
    p_audit    VARCHAR
)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_max_bloques  BIGINT;
    v_fk_periodo   BIGINT;
    v_nombre_grado VARCHAR(130);
    v_count        INT := 0;
    v_bloque       INT;
    v_grupo        BIGINT;
    v_dia          BIGINT;
    v_planitem     BIGINT;
    v_asig         BIGINT;
    v_tmp_nombre   VARCHAR;
    v_tmp_nombre2  VARCHAR;
    entry          JSONB;
BEGIN
    SELECT pa.BLOQUES_POR_DEFECTO, g.NOMBRE, pa.PK_TPERIODO_ACADEMICO
      INTO v_max_bloques, v_nombre_grado, v_fk_periodo
      FROM academico_test.TGRADO g
      JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
     WHERE g.PK_TGRADO = p_fk_grado AND g.ACTIVE = TRUE;

    IF v_max_bloques IS NULL THEN
        PERFORM academico_test.fn_horario_validar_grado_existe(p_fk_grado);
        PERFORM academico_test.fn_horario_validar_grado_activo(p_fk_grado);
        -- Grado activo cuyo periodo no tiene BLOQUES_POR_DEFECTO: se conserva el error de siempre.
        RAISE EXCEPTION 'El grado "%" existe pero esta inactivo', v_nombre_grado USING ERRCODE = '23503';
    END IF;

    -- Evita que dos transacciones modifiquen a la vez el horario del mismo grado.
    PERFORM pg_advisory_xact_lock(hashtext('horario:' || p_fk_grado::TEXT));

    -- Por si la funcion se llama de nuevo dentro de la misma transaccion.
    DROP TABLE IF EXISTS tmp_horario_entries;
    CREATE TEMP TABLE tmp_horario_entries (
        grupo_id      BIGINT NOT NULL,
        dia_id        BIGINT NOT NULL,
        bloque        INT NOT NULL,
        plan_item_id  BIGINT NOT NULL,
        asignatura_id BIGINT NOT NULL,
        UNIQUE (grupo_id, dia_id, bloque)
    ) ON COMMIT DROP;

    FOR entry IN SELECT * FROM jsonb_array_elements(COALESCE(p_entries, '[]'::JSONB)) LOOP
        v_bloque   := (entry->>'bloque')::INT;
        v_grupo    := (entry->>'grupoId')::BIGINT;
        v_dia      := (entry->>'diaId')::BIGINT;
        v_planitem := (entry->>'planItemId')::BIGINT;

        PERFORM academico_test.fn_horario_validar_celda(
            p_fk_grado, v_max_bloques, v_bloque, v_grupo, v_dia, v_planitem);

        SELECT ap.FK_TASIGNATURA INTO v_asig
          FROM academico_test.TASIGNATURA_PLAN ap
          JOIN academico_test.TPLAN pl ON pl.PK_TPLAN = ap.FK_TPLAN AND pl.ACTIVE = TRUE
         WHERE ap.PK_TASIGNATURA_PLAN = v_planitem AND ap.ACTIVE = TRUE AND pl.FK_TGRADO = p_fk_grado;

        IF EXISTS (SELECT 1 FROM tmp_horario_entries
                    WHERE grupo_id = v_grupo AND dia_id = v_dia AND bloque = v_bloque) THEN
            SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TGRUPO WHERE PK_TGRUPO = v_grupo;
            SELECT NOMBRE INTO v_tmp_nombre2 FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = v_dia;
            RAISE EXCEPTION 'Celda duplicada: grupo "%", dia "%", bloque %', v_tmp_nombre, v_tmp_nombre2, v_bloque
                USING ERRCODE = '22023';
        END IF;

        INSERT INTO tmp_horario_entries (grupo_id, dia_id, bloque, plan_item_id, asignatura_id)
        VALUES (v_grupo, v_dia, v_bloque, v_planitem, v_asig);
    END LOOP;

    -- Celda activa en BD que ya no viene en p_entries: el usuario la elimino.
    UPDATE academico_test.THORARIO h
       SET ACTIVE = FALSE, MODIFIED_BY = p_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE h.ACTIVE = TRUE
       AND h.FK_TGRUPO IN (SELECT g.PK_TGRUPO FROM academico_test.TGRUPO g
                            WHERE g.FK_TGRADO = p_fk_grado AND g.ACTIVE = TRUE)
       AND NOT EXISTS (SELECT 1 FROM tmp_horario_entries e
                        WHERE e.grupo_id = h.FK_TGRUPO AND e.dia_id = h.FK_TLV_DIA_SEMANA
                          AND e.bloque = h.NUMERO_BLOQUE);

    -- Misma celda con otra asignatura: se desactiva la version anterior antes de insertar.
    UPDATE academico_test.THORARIO h
       SET ACTIVE = FALSE, MODIFIED_BY = p_audit, MODIFIED_AT = CURRENT_TIMESTAMP
      FROM tmp_horario_entries e
     WHERE h.ACTIVE = TRUE
       AND h.FK_TGRUPO = e.grupo_id AND h.FK_TLV_DIA_SEMANA = e.dia_id AND h.NUMERO_BLOQUE = e.bloque
       AND h.FK_TASIGNATURA <> e.asignatura_id;

    -- HORA_INICIO/FIN son TIMESTAMP (TIME no castea directo), de ahi el CURRENT_DATE +: la
    -- fecha es arbitraria pero consistente para el EXTRACT(EPOCH ...) de fn_asistencia_calendario.
    -- Sin match en fn_horario_calcular_bloques la celda se guarda con franja NULL.
    INSERT INTO academico_test.THORARIO
        (NUMERO_BLOQUE, FK_TLV_DIA_SEMANA, FK_TGRUPO, FK_TASIGNATURA, HORA_INICIO, HORA_FIN, CREATED_BY)
    SELECT e.bloque, e.dia_id, e.grupo_id, e.asignatura_id,
           CURRENT_DATE + b.hora_inicio, CURRENT_DATE + b.hora_fin, p_audit
      FROM tmp_horario_entries e
      LEFT JOIN academico_test.fn_horario_calcular_bloques(v_fk_periodo) b ON b.numero_bloque = e.bloque
     WHERE NOT EXISTS (SELECT 1 FROM academico_test.THORARIO h
                        WHERE h.ACTIVE = TRUE AND h.FK_TGRUPO = e.grupo_id
                          AND h.FK_TLV_DIA_SEMANA = e.dia_id AND h.NUMERO_BLOQUE = e.bloque);

    SELECT COUNT(*) INTO v_count
      FROM academico_test.THORARIO h
      JOIN academico_test.TGRUPO g ON g.PK_TGRUPO = h.FK_TGRUPO
     WHERE h.ACTIVE = TRUE AND g.FK_TGRADO = p_fk_grado AND g.ACTIVE = TRUE;
    RETURN v_count;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_horario_guardar_interno(BIGINT, JSONB, VARCHAR)
    IS 'INTERNO: valida y reemplaza el horario de un grado (desactiva lo que no viene, inserta lo nuevo con su franja de fn_horario_calcular_bloques). Devuelve las celdas activas. Lo usa fn_horario_guardar.';

CREATE OR REPLACE FUNCTION academico_test.fn_horario_listar_interno(
    p_fk_grado BIGINT,
    p_fk_grupo BIGINT DEFAULT NULL
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
       AND (p_fk_grupo IS NULL OR h.FK_TGRUPO = p_fk_grupo)
     ORDER BY h.FK_TGRUPO, h.FK_TLV_DIA_SEMANA, h.NUMERO_BLOQUE;
$$;

COMMENT ON FUNCTION academico_test.fn_horario_listar_interno(BIGINT, BIGINT)
    IS 'INTERNO: celdas activas del horario de un grado (opcionalmente de un grupo), sin alcance. Lo usa fn_horario_listar.';

CREATE OR REPLACE FUNCTION academico_test.fn_horario_asignaturas_interno(p_fk_grado BIGINT)
RETURNS TABLE (plan_item_id BIGINT, nombre VARCHAR, bloques NUMERIC, color VARCHAR)
LANGUAGE sql STABLE AS $$
    SELECT ap.PK_TASIGNATURA_PLAN, s.NOMBRE, ap.NUMERO_HORA, s.COLOR
      FROM academico_test.TASIGNATURA_PLAN ap
      JOIN academico_test.TPLAN pl      ON pl.PK_TPLAN = ap.FK_TPLAN AND pl.ACTIVE = TRUE
      JOIN academico_test.TASIGNATURA s ON s.PK_TASIGNATURA = ap.FK_TASIGNATURA AND s.ACTIVE = TRUE
     WHERE pl.FK_TGRADO = p_fk_grado AND ap.ACTIVE = TRUE
     ORDER BY s.NOMBRE;
$$;

COMMENT ON FUNCTION academico_test.fn_horario_asignaturas_interno(BIGINT)
    IS 'INTERNO: renglones activos del plan de estudio de un grado con sus horas, sin alcance. Lo usa fn_horario_asignaturas.';

-- ------------------------------------- horario de preescolar (antes V437)
-- El horario de preescolar se arma solo al guardar el plan de estudio.
CREATE OR REPLACE FUNCTION academico_test.fn_horario_preescolar_autogenerar(
    p_fk_grado   BIGINT,
    p_pk_usuario BIGINT DEFAULT NULL
)
RETURNS INT
LANGUAGE plpgsql AS $$
DECLARE
    v_audit      VARCHAR(120) := COALESCE(p_pk_usuario::VARCHAR, 'horario-auto');
    v_periodo    BIGINT;
    v_bloques    INT;
    v_fin_semana BOOLEAN;
    v_dias       BIGINT[];
    v_capacidad  INT;
    v_creadas    INT := 0;
    v_idx        INT;
    v_dia        BIGINT;
    v_bloque     INT;
    v_ya         INT;
    v_pendientes INT;
    v_grado_nom  TEXT;
    r_grupo      RECORD;
    r_item       RECORD;
BEGIN
    IF NOT academico_test.fn_grado_es_preescolar(p_fk_grado) THEN
        RETURN 0;
    END IF;

    SELECT pa.PK_TPERIODO_ACADEMICO, pa.BLOQUES_POR_DEFECTO, g.NOMBRE,
           EXISTS (SELECT 1 FROM academico_test.TLISTA_VALOR lv
                    WHERE lv.PK_LISTA_VALOR = pa.FK_TLV_JORNADA
                      AND lv.NOMBRE ILIKE '%fin de semana%')
      INTO v_periodo, v_bloques, v_grado_nom, v_fin_semana
      FROM academico_test.TGRADO g
      JOIN academico_test.TPERIODO_ACADEMICO pa
        ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
     WHERE g.PK_TGRADO = p_fk_grado AND g.ACTIVE = TRUE;

    -- Periodo sin jornada configurada todavia: no hay grilla que llenar. Se
    -- sale en silencio en vez de bloquear el guardado del plan; al configurar
    -- la jornada, el siguiente guardado genera.
    IF v_periodo IS NULL OR COALESCE(v_bloques, 0) <= 0 THEN
        RETURN 0;
    END IF;

    -- VALOR de DIA_SEMANA: 1..7 = Domingo..Sabado. Se ordena como TEXTO a
    -- proposito: castear VALOR a INT puede evaluarse antes del filtro de
    -- CATEGORIA y reventar contra un VALOR no numerico de otra categoria.
    SELECT array_agg(lv.PK_LISTA_VALOR ORDER BY lv.VALOR)
      INTO v_dias
      FROM academico_test.TLISTA_VALOR lv
     WHERE lv.CATEGORIA = 'DIA_SEMANA' AND lv.ACTIVE = TRUE
       AND lv.VALOR = ANY (CASE WHEN v_fin_semana
                                THEN ARRAY['7']
                                ELSE ARRAY['2','3','4','5','6'] END);

    IF v_dias IS NULL OR array_length(v_dias, 1) = 0 THEN
        RETURN 0;
    END IF;

    v_capacidad := array_length(v_dias, 1) * v_bloques;

    FOR r_grupo IN
        SELECT gr.PK_TGRUPO
          FROM academico_test.TGRUPO gr
         WHERE gr.FK_TGRADO = p_fk_grado AND gr.ACTIVE = TRUE
         ORDER BY gr.PK_TGRUPO
    LOOP
        -- Indice lineal sobre la grilla: dia = v_idx / v_bloques, bloque = resto.
        -- Arranca en 0 por grupo y avanza tambien sobre las celdas ocupadas, que
        -- cuentan contra la capacidad aunque no se toquen.
        v_idx := 0;

        -- Bajar la intensidad retira el sobrante antes de rellenar: se quitan
        -- las ultimas celdas de la grilla (y primero las de dias fuera de la
        -- jornada), para que el hueco quede al final de la semana.
        UPDATE academico_test.THORARIO h
           SET ACTIVE      = FALSE,
               MODIFIED_BY = v_audit,
               MODIFIED_AT = CURRENT_TIMESTAMP
          FROM (
                SELECT h2.PK_THORARIO,
                       p.bloques,
                       COUNT(*) OVER (PARTITION BY h2.FK_TASIGNATURA) AS ya,
                       -- rn = 1 es la ultima celda de la asignatura en la semana.
                       ROW_NUMBER() OVER (
                           PARTITION BY h2.FK_TASIGNATURA
                           ORDER BY array_position(v_dias, h2.FK_TLV_DIA_SEMANA) DESC NULLS FIRST,
                                    h2.NUMERO_BLOQUE DESC) AS rn
                  FROM academico_test.THORARIO h2
                  JOIN (SELECT ap.FK_TASIGNATURA,
                               MAX(CEIL(COALESCE(ap.NUMERO_HORA, 0)))::INT AS bloques
                          FROM academico_test.TASIGNATURA_PLAN ap
                          JOIN academico_test.TPLAN pl
                            ON pl.PK_TPLAN = ap.FK_TPLAN AND pl.ACTIVE = TRUE
                         WHERE pl.FK_TGRADO = p_fk_grado AND ap.ACTIVE = TRUE
                         GROUP BY ap.FK_TASIGNATURA) p
                    ON p.FK_TASIGNATURA = h2.FK_TASIGNATURA
                 WHERE h2.ACTIVE = TRUE
                   AND h2.FK_TGRUPO = r_grupo.PK_TGRUPO
               ) s
         WHERE h.PK_THORARIO = s.PK_THORARIO
           AND s.rn <= s.ya - s.bloques;

        FOR r_item IN
            SELECT ap.FK_TASIGNATURA,
                   CEIL(COALESCE(ap.NUMERO_HORA, 0))::INT AS bloques
              FROM academico_test.TASIGNATURA_PLAN ap
              JOIN academico_test.TPLAN pl ON pl.PK_TPLAN = ap.FK_TPLAN AND pl.ACTIVE = TRUE
             WHERE pl.FK_TGRADO = p_fk_grado AND ap.ACTIVE = TRUE
             ORDER BY ap.PK_TASIGNATURA_PLAN
        LOOP
            -- Lo que la asignatura ya tiene en la grilla cuenta: asi regenerar no
            -- duplica y subir la intensidad solo agrega los bloques que faltan.
            SELECT COUNT(*) INTO v_ya
              FROM academico_test.THORARIO h
             WHERE h.ACTIVE = TRUE
               AND h.FK_TGRUPO = r_grupo.PK_TGRUPO
               AND h.FK_TASIGNATURA = r_item.FK_TASIGNATURA;

            v_pendientes := GREATEST(r_item.bloques - v_ya, 0);

            WHILE v_pendientes > 0 LOOP
                IF v_idx >= v_capacidad THEN
                    RAISE EXCEPTION
                        'El horario del grado "%" no alcanza: la jornada da % dia(s) x % bloque(s) = % celdas y el plan de estudio pide mas. Reduci la intensidad horaria o ampliá los bloques del periodo.',
                        v_grado_nom, array_length(v_dias, 1), v_bloques, v_capacidad
                        USING ERRCODE = '22023';
                END IF;

                v_dia    := v_dias[(v_idx / v_bloques) + 1];
                v_bloque := v_idx % v_bloques;
                v_idx    := v_idx + 1;

                -- Solo rellena vacios: lo que el usuario puso a mano se respeta.
                CONTINUE WHEN EXISTS (
                    SELECT 1 FROM academico_test.THORARIO h
                     WHERE h.ACTIVE = TRUE
                       AND h.FK_TGRUPO = r_grupo.PK_TGRUPO
                       AND h.FK_TLV_DIA_SEMANA = v_dia
                       AND h.NUMERO_BLOQUE = v_bloque
                );

                -- La franja horaria se deriva del periodo, igual que en
                -- fn_horario_guardar; el LEFT JOIN desde una fila fija deja
                -- HORA_INICIO/FIN en NULL si el bloque no tiene franja.
                INSERT INTO academico_test.THORARIO (
                    NUMERO_BLOQUE, FK_TLV_DIA_SEMANA, FK_TGRUPO, FK_TASIGNATURA,
                    HORA_INICIO, HORA_FIN, CREATED_BY
                )
                SELECT v_bloque, v_dia, r_grupo.PK_TGRUPO, r_item.FK_TASIGNATURA,
                       CURRENT_DATE + b.hora_inicio, CURRENT_DATE + b.hora_fin, v_audit
                  FROM (SELECT 1) s
                  LEFT JOIN academico_test.fn_horario_calcular_bloques(v_periodo) b
                         ON b.numero_bloque = v_bloque;

                v_pendientes := v_pendientes - 1;
                v_creadas    := v_creadas + 1;
            END LOOP;
        END LOOP;
    END LOOP;

    RETURN v_creadas;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_horario_preescolar_autogenerar(BIGINT, BIGINT)
    IS 'INTERNO: arma el horario de un grado de PREESCOLAR a partir de su plan de estudio. Dias segun la jornada del periodo academico: "Fin de semana" -> solo sabado, cualquier otra -> lunes a viernes (VALOR 2..6 de DIA_SEMANA, resuelto por CATEGORIA+VALOR y no por pk). Bloques por dia = TPERIODO_ACADEMICO.BLOQUES_POR_DEFECTO. Recorre los renglones del plan por PK y le da a cada asignatura tantos bloques como su NUMERO_HORA (intensidad horaria, redondeada hacia arriba), llenando la grilla dia por dia: con 5 bloques/dia y 20 horas, ocupa de lunes a jueves. SOLO rellena celdas vacias --lo puesto a mano se respeta-- pero las ocupadas igual consumen capacidad. Idempotente: descuenta los bloques que la asignatura ya tiene, asi que regenerar no duplica y subir la intensidad solo agrega la diferencia; bajarla retira (baja logica) las celdas sobrantes empezando por el final de la semana, incluso las puestas a mano, y el hueco queda vacio. Si el plan no cabe en dias x bloques lanza 22023 y, llamada desde el trigger, tumba el guardado del plan. Devuelve el numero de celdas creadas. Periodo sin jornada configurada (sin BLOQUES_POR_DEFECTO) -> 0 sin error. No es fn_horario_guardar (V45.3), que es el guardado manual de la grilla completa.';


-- El disparo: cualquier alta o cambio de un renglon del plan regenera el
-- horario del grado. Se hace por trigger y no dentro de fn_plan_agregar /
-- fn_plan_actualizar (V44.2) para no duplicar aqui esos cuerpos enteros; cubre
-- ademas cualquier otra via que escriba en la tabla.
CREATE OR REPLACE FUNCTION academico_test.fn_tg_horario_preescolar_autogenerar()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_grado   BIGINT;
    v_usuario TEXT := COALESCE(NEW.MODIFIED_BY, NEW.CREATED_BY);
BEGIN
    SELECT pl.FK_TGRADO INTO v_grado
      FROM academico_test.TPLAN pl
     WHERE pl.PK_TPLAN = NEW.FK_TPLAN;

    IF v_grado IS NOT NULL THEN
        PERFORM academico_test.fn_horario_preescolar_autogenerar(
            v_grado,
            CASE WHEN v_usuario ~ '^\d+$' THEN v_usuario::BIGINT END);
    END IF;

    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS tg_horario_preescolar_autogenerar ON academico_test.TASIGNATURA_PLAN;
CREATE TRIGGER tg_horario_preescolar_autogenerar
    AFTER INSERT OR UPDATE ON academico_test.TASIGNATURA_PLAN
    FOR EACH ROW
    -- Solo altas y cambios de renglones VIGENTES. El borrado del plan es un
    -- UPDATE ACTIVE = FALSE, y ahi regenerar no tiene sentido (nunca se quitan
    -- celdas) y ademas podria tumbar el borrado con el error de capacidad.
    WHEN (NEW.ACTIVE = TRUE)
    EXECUTE FUNCTION academico_test.fn_tg_horario_preescolar_autogenerar();
