CREATE UNIQUE INDEX IF NOT EXISTS uq_horario_activo_por_celda
ON academico_test.THORARIO (
    FK_TGRUPO,
    FK_TLV_DIA_SEMANA,
    NUMERO_BLOQUE
)
WHERE ACTIVE = TRUE;

CREATE OR REPLACE FUNCTION academico_test.fn_horario_guardar(
    p_fk_grado                  BIGINT,
    p_entries                   JSONB,
    p_pk_usuario_solicitante    BIGINT
)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_audit        VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_max_bloques  BIGINT;
    v_count        INT := 0;

    v_bloque       INT;
    v_grupo        BIGINT;
    v_dia          BIGINT;
    v_planitem     BIGINT;
    v_asig         BIGINT;

    entry          JSONB;
BEGIN

    --------------------------------------------------------------------------
    -- 1. Validar que el período permita escritura
    --------------------------------------------------------------------------

    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante,
        (
            SELECT academico_test.fn_periodo_establecimiento(
                g.FK_TPERIODO_ACADEMICO
            )
            FROM academico_test.TGRADO g
            WHERE g.PK_TGRADO = p_fk_grado
        )
    );


    --------------------------------------------------------------------------
    -- 2. Obtener cantidad máxima de bloques del período
    --------------------------------------------------------------------------

    SELECT pa.BLOQUES_POR_DEFECTO
      INTO v_max_bloques
      FROM academico_test.TGRADO g
      JOIN academico_test.TPERIODO_ACADEMICO pa
        ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
     WHERE g.PK_TGRADO = p_fk_grado
       AND g.ACTIVE = TRUE;

    IF v_max_bloques IS NULL THEN
        RAISE EXCEPTION
            'El grado % no existe o esta inactivo',
            p_fk_grado
            USING ERRCODE = '23503';
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
            RAISE EXCEPTION
                'El grupo % no pertenece al grado % o esta inactivo',
                v_grupo,
                p_fk_grado
                USING ERRCODE = '22023';
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
            RAISE EXCEPTION
                'El dia % no es valido (debe ser de la categoria DIA_SEMANA)',
                v_dia
                USING ERRCODE = '23503';
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
            RAISE EXCEPTION
                'El renglon de plan % no existe, esta inactivo o no pertenece al grado %',
                v_planitem,
                p_fk_grado
                USING ERRCODE = '23503';
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
            RAISE EXCEPTION
                'Celda duplicada: grupo %, dia %, bloque %',
                v_grupo,
                v_dia,
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
        CREATED_BY
    )
    SELECT
        e.bloque,
        e.dia_id,
        e.grupo_id,
        e.asignatura_id,
        v_audit
    FROM tmp_horario_entries e
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