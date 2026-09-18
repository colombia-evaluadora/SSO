-- V437 -- Preescolar: el horario se arma solo al guardar el plan de estudio.
-- Los dias salen de la jornada del periodo (Fin de semana -> sabado; el resto
-- -> lunes a viernes) y cada renglon del plan ocupa tantos bloques como su
-- intensidad horaria (NUMERO_HORA), llenando dia por dia. Si no cabe en
-- dias x BLOQUES_POR_DEFECTO, lanza y el guardado del plan se cae con ella.
-- Depende de: V45 (fn_horario_calcular_bloques, THORARIO), V285
-- (fn_grado_es_preescolar, TASIGNATURA_PLAN). Idempotente.

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
    IS 'Arma el horario de un grado de PREESCOLAR a partir de su plan de estudio. Dias segun la jornada del periodo academico: "Fin de semana" -> solo sabado, cualquier otra -> lunes a viernes (VALOR 2..6 de DIA_SEMANA, resuelto por CATEGORIA+VALOR y no por pk). Bloques por dia = TPERIODO_ACADEMICO.BLOQUES_POR_DEFECTO. Recorre los renglones del plan por PK y le da a cada asignatura tantos bloques como su NUMERO_HORA (intensidad horaria, redondeada hacia arriba), llenando la grilla dia por dia: con 5 bloques/dia y 20 horas, ocupa de lunes a jueves. SOLO rellena celdas vacias --lo puesto a mano se respeta-- pero las ocupadas igual consumen capacidad. Idempotente: descuenta los bloques que la asignatura ya tiene, asi que regenerar no duplica y subir la intensidad solo agrega la diferencia. Si el plan no cabe en dias x bloques lanza 22023 y, llamada desde el trigger, tumba el guardado del plan. Devuelve el numero de celdas creadas. Periodo sin jornada configurada (sin BLOQUES_POR_DEFECTO) -> 0 sin error. No es fn_horario_guardar (V45), que es el guardado manual de la grilla completa.';


-- El disparo: cualquier alta o cambio de un renglon del plan regenera el
-- horario del grado. Se hace por trigger y no dentro de fn_plan_agregar /
-- fn_plan_actualizar (V285) para no duplicar aqui esos cuerpos enteros; cubre
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
