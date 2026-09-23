-- V492 — Planeador: enunciados en el PUT de unidad y mínimo solo al quitar.
--
-- Qué hace: fn_unidad_actualizar gana p_enunciados (NULL = no tocar, array =
-- reemplazo; quitar un enunciado desactiva las evidencias que colgaban de él)
-- y PUT /planeador/unidades/:ID acepta BODY.ENUNCIADOS. Quita los triggers de
-- V483 sobre TUNIDAD y TACTIVIDAD: el flujo crea la unidad/actividad y asigna
-- enunciados/evidencias después, así que el mínimo no puede exigirse al crear.
-- Se conservan los de TUNIDAD_ENUNCIADO/TACTIVIDAD_EVIDENCIA: no se puede
-- quitar el último enunciado o evidencia.
-- Depende de: V478 (cuerpo de fn_unidad_actualizar), V214.1, V245, V483.

SET search_path TO academico_test, public;

DROP TRIGGER IF EXISTS tr_tunidad_minimo_enunciado ON academico_test.TUNIDAD;
DROP TRIGGER IF EXISTS tr_tactividad_minimo_evidencia ON academico_test.TACTIVIDAD;

DROP FUNCTION IF EXISTS academico_test.fn_unidad_actualizar(BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, BOOLEAN, VARCHAR[], VARCHAR[], NUMERIC, BOOLEAN);

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_actualizar(
    p_pk_usuario_solicitante        BIGINT,
    p_pk_tunidad                    BIGINT,
    p_nombre                        VARCHAR(250)  DEFAULT NULL,
    p_descripcion                   VARCHAR(4000) DEFAULT NULL,
    p_fk_tasignatura                BIGINT        DEFAULT NULL,
    p_fk_tgrado                     BIGINT        DEFAULT NULL,
    p_fk_tfuncionario               BIGINT        DEFAULT NULL,
    p_fk_tlv_calculo_definitiva     BIGINT        DEFAULT NULL,
    p_fk_referente_curricular       BIGINT        DEFAULT NULL,
    -- NULL param no distingue "no tocar" de "quitar" el referente:
    -- p_limpiar_referente = TRUE fuerza FK_REFERENTE_CURRICULAR a NULL.
    p_limpiar_referente             BOOLEAN       DEFAULT FALSE,
    -- NULL = no tocar la lista; array (incl. vacio) = reemplazo completo:
    -- se desactivan los activos y se re-insertan los del array.
    p_objetivos                     VARCHAR[]     DEFAULT NULL,
    p_contenidos                    VARCHAR[]     DEFAULT NULL,
    -- Peso (%) de la unidad dentro de su (asignatura, grado), TUNIDAD.PONDERACION
    -- (V239). NULL = no tocar; p_limpiar_ponderacion = TRUE lo vuelve NULL
    -- (mismo par "valor / limpiar" que ya usa el referente curricular).
    p_ponderacion                   NUMERIC       DEFAULT NULL,
    p_limpiar_ponderacion           BOOLEAN       DEFAULT FALSE,
    -- NULL = no tocar; array = reemplazo completo de TUNIDAD_ENUNCIADO.
    p_enunciados                    BIGINT[]      DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_actual     academico_test.TUNIDAD%ROWTYPE;
    v_nombre     VARCHAR(250);
    v_asig       BIGINT;
    v_grado      BIGINT;
    -- Referente EFECTIVO tras el PATCH; ver el bloque que lo resuelve.
    v_fk_referente BIGINT;
    v_ponder     NUMERIC;
    v_pk_plan    BIGINT;
    v_elemento   VARCHAR;
    v_modo       VARCHAR;
    v_suma       NUMERIC(9,2);
    -- Guard "instrumento huerfano": actividades de la unidad que ya tienen
    -- instrumento de evaluacion y bloquean dejar la unidad no evaluativa.
    v_instrumentadas TEXT;
    -- V478: metodo de calculo EFECTIVO tras el PATCH y si cambio de verdad
    -- respecto al que la unidad ya tenia -- gatea el reset/recalculo de
    -- PONDERACION de las actividades ya vinculadas, ver el bloque al final.
    v_calculo_cambio   BOOLEAN;
    v_grupo_bucket     BIGINT;
BEGIN
    SELECT * INTO v_actual
      FROM academico_test.TUNIDAD
     WHERE PK_TUNIDAD = p_pk_tunidad;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la unidad tematica solicitada'
            USING ERRCODE = 'P0002';
    END IF;

    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'EDITAR', NULL, p_fk_tgrado, p_pk_tunidad
    );

    IF v_actual.ACTIVE = FALSE THEN
        RAISE EXCEPTION 'La unidad "%" ya no esta disponible; no se puede editar', v_actual.NOMBRE
            USING ERRCODE = '22023';
    END IF;

    IF p_nombre IS NOT NULL AND NULLIF(TRIM(p_nombre), '') IS NULL THEN
        RAISE EXCEPTION 'El nombre de la unidad no puede quedar vacio' USING ERRCODE = '22023';
    END IF;

    -- FKs nuevas (solo si vienen) existen y estan activas.
    IF p_fk_tasignatura IS NOT NULL AND NOT EXISTS (SELECT 1 FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_fk_tasignatura AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'La asignatura seleccionada no esta disponible' USING ERRCODE = '23503';
    END IF;
    IF p_fk_tgrado IS NOT NULL AND NOT EXISTS (SELECT 1 FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_tgrado AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'El grado seleccionado no esta disponible' USING ERRCODE = '23503';
    END IF;
    IF p_fk_tfuncionario IS NOT NULL AND NOT EXISTS (SELECT 1 FROM academico_test.TFUNCIONARIO WHERE PK_TFUNCIONARIO = p_fk_tfuncionario AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'El docente seleccionado no esta disponible' USING ERRCODE = '23503';
    END IF;
    IF p_fk_tlv_calculo_definitiva IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_fk_tlv_calculo_definitiva AND CATEGORIA = 'CALCULO_DEFINITIVA' AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'La forma de calculo de la nota seleccionada no es valida' USING ERRCODE = '23503';
    END IF;
    -- ACTIVE (borrado logico) Y ESTADO (estado de negocio): ver la nota
    -- equivalente en fn_unidad_crear.
    IF NOT p_limpiar_referente AND p_fk_referente_curricular IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TREFERENTE_CURRICULAR
         WHERE PK_REFERENTE_CURRICULAR = p_fk_referente_curricular AND ACTIVE = TRUE AND ESTADO = 'A'
    ) THEN
        RAISE EXCEPTION 'El referente curricular seleccionado ya no esta vigente' USING ERRCODE = '23503';
    END IF;

    -- Unicidad con los valores resultantes (NOMBRE, asignatura, grado).
    v_nombre := COALESCE(NULLIF(TRIM(p_nombre), ''), v_actual.NOMBRE);
    v_asig   := COALESCE(p_fk_tasignatura, v_actual.FK_TASIGNATURA);
    v_grado  := COALESCE(p_fk_tgrado, v_actual.FK_TGRADO);

    -- V478: se resuelve ACA (antes del UPDATE) si el metodo de calculo va a
    -- cambiar de verdad -- comparando contra el valor actual, no contra NULL
    -- -- para poder usarlo despues del UPDATE sin volver a leer v_actual.
    v_calculo_cambio := p_fk_tlv_calculo_definitiva IS NOT NULL
                         AND p_fk_tlv_calculo_definitiva IS DISTINCT FROM v_actual.FK_TLV_CALCULO_DEFINITIVA;

    -- ----------------------------------------------------------------------
    -- Referente EFECTIVO tras el PATCH. Se resuelve aqui, y no arriba, porque
    -- depende del grado RESULTANTE: mover la unidad de grado puede cambiarle
    -- el nivel educativo, y con el, que referentes aplican.
    --
    -- Tres casos:
    --   a) p_limpiar_referente = TRUE  -> NULL (el caller lo pidio explicito).
    --   b) llega un referente nuevo    -> se exige que aplique al nivel del
    --      grado resultante (misma razon que en fn_unidad_crear: un referente
    --      de otro nivel no puede aportar ni un enunciado, por la validacion
    --      de fn_unidad_enunciado_relacionar / V214.1).
    --   c) no lo tocan                 -> se CONSERVA el actual, salvo que
    --      haya dejado de aplicar (porque cambio el grado, o porque alguien
    --      desactivo ese referente en el catalogo). En ese caso se RE-DERIVA
    --      con la regla del grado nuevo en vez de dejar una FK muerta.
    --
    -- El caso (c) es el que estaba roto en el servidor de test: las unidades
    -- 12-15 apuntaban a los referentes 11 y 12, ambos ACTIVE = false, y
    -- GET /planeador/unidades/:ID/referente devolvia todo NULL mientras el
    -- listado seguia mostrando el nombre del referente muerto.
    -- ----------------------------------------------------------------------
    IF p_limpiar_referente THEN
        v_fk_referente := NULL;
    ELSIF p_fk_referente_curricular IS NOT NULL THEN
        v_fk_referente := p_fk_referente_curricular;

        IF NOT EXISTS (
            SELECT 1
              FROM academico_test.TREFERENTE_CURRICULAR_NIVEL rcn
              JOIN academico_test.TGRADO g ON g.PK_TGRADO = v_grado
             WHERE rcn.FK_REFERENTE_CURRICULAR = v_fk_referente
               AND rcn.FK_TNIVEL_ENSENANZA = g.FK_TNIVEL_ENSENANZA
               AND rcn.ACTIVE = TRUE
        ) THEN
            RAISE EXCEPTION 'El referente curricular "%" no aplica al nivel educativo del grado "%"',
                (SELECT NOMBRE FROM academico_test.TREFERENTE_CURRICULAR WHERE PK_REFERENTE_CURRICULAR = v_fk_referente),
                (SELECT NOMBRE FROM academico_test.TGRADO WHERE PK_TGRADO = v_grado)
                USING ERRCODE = '23503';
        END IF;
    ELSE
        v_fk_referente := v_actual.FK_REFERENTE_CURRICULAR;

        IF v_fk_referente IS NULL
           OR NOT EXISTS (
                SELECT 1
                  FROM academico_test.TREFERENTE_CURRICULAR rc
                  JOIN academico_test.TREFERENTE_CURRICULAR_NIVEL rcn
                        ON rcn.FK_REFERENTE_CURRICULAR = rc.PK_REFERENTE_CURRICULAR
                       AND rcn.ACTIVE = TRUE
                  JOIN academico_test.TGRADO g ON g.PK_TGRADO = v_grado
                 WHERE rc.PK_REFERENTE_CURRICULAR = v_fk_referente
                   AND rc.ACTIVE = TRUE
                   AND rc.ESTADO = 'A'
                   AND rcn.FK_TNIVEL_ENSENANZA = g.FK_TNIVEL_ENSENANZA
           ) THEN
            v_fk_referente := academico_test.fn_unidad_referente_aplicable(v_grado, v_asig);
        END IF;
    END IF;
    -- ----------------------------------------------------------------------
    -- GUARD "instrumento huerfano" (V214.2). Si la unidad ERA evaluativa y tras
    -- el PATCH deja de serlo, sus actividades con instrumento de evaluacion
    -- quedarian con un instrumento que la unidad ya no admite -- y a partir de
    -- ahi fn_actividad_actualizar (V224) rechaza CUALQUIER edicion sobre
    -- ellas, incluso desvincularlas, porque revalida el instrumento heredado.
    -- Se aborta antes de escribir, nombrando las actividades que lo impiden.
    --
    -- Cubre los TRES caminos que dejan la unidad no evaluativa, porque los
    -- tres desembocan en el mismo v_fk_referente: limpiarle el referente
    -- (p_limpiar_referente), moverla a uno FORMATIVO, y la re-derivacion
    -- silenciosa del caso (c) -- que es la que produjo las 6 actividades
    -- rotas del servidor de test: al desactivarse el referente evaluativo de
    -- Preescolar, un PATCH de solo el nombre las re-derivo al unico vigente,
    -- que es formativo.
    -- ----------------------------------------------------------------------
    IF academico_test.fn_unidad_referente_evaluativo(p_pk_tunidad)
       AND NOT academico_test.fn_referente_es_evaluativo_vigente(v_fk_referente) THEN
        v_instrumentadas := academico_test.fn_unidad_actividades_instrumentadas(p_pk_tunidad);

        IF v_instrumentadas IS NOT NULL THEN
            IF v_fk_referente IS NULL THEN
                RAISE EXCEPTION
                    'No se puede dejar la unidad "%" sin referente curricular: estas actividades ya tienen un instrumento de evaluacion configurado y lo necesitan (%). Ajusta primero esas actividades y vuelve a intentarlo.',
                    v_actual.NOMBRE, v_instrumentadas
                    USING ERRCODE = '22023';
            ELSE
                RAISE EXCEPTION
                    'No se puede acoger la unidad "%" al referente curricular "%": con ese referente el aprendizaje se valora con observaciones y no con instrumentos, y estas actividades ya tienen uno configurado (%). Ajusta primero esas actividades y vuelve a intentarlo.',
                    v_actual.NOMBRE,
                    (SELECT NOMBRE FROM academico_test.TREFERENTE_CURRICULAR WHERE PK_REFERENTE_CURRICULAR = v_fk_referente),
                    v_instrumentadas
                    USING ERRCODE = '22023';
            END IF;
        END IF;
    END IF;

    IF EXISTS (
        SELECT 1 FROM academico_test.TUNIDAD
         WHERE UPPER(TRIM(NOMBRE)) = UPPER(TRIM(v_nombre))
           AND FK_TASIGNATURA = v_asig
           AND FK_TGRADO = v_grado
           AND ACTIVE = TRUE
           AND PK_TUNIDAD <> p_pk_tunidad
    ) THEN
        RAISE EXCEPTION 'Ya existe otra unidad activa "%" para esa asignatura y grado', v_nombre
            USING ERRCODE = '23505';
    END IF;

    -- Peso (%) de la unidad dentro de su (asignatura, grado) — TUNIDAD.PONDERACION
    -- (V239). Se valida sobre los valores RESULTANTES del PATCH (v_asig /
    -- v_grado ya calculados arriba), mismo criterio que V224 aplica a
    -- ES_EVALUATIVA / unidad / instrumento: un PATCH que mueve la unidad de
    -- asignatura o de grado cambia el bucket contra el que se mide el 100%.
    v_ponder := CASE WHEN p_limpiar_ponderacion THEN NULL
                     ELSE COALESCE(p_ponderacion, v_actual.PONDERACION) END;

    IF v_ponder IS NOT NULL THEN
        IF v_ponder < 0 OR v_ponder > 100 THEN
            RAISE EXCEPTION 'La ponderacion (%) debe estar entre 0 y 100', v_ponder
                USING ERRCODE = '22023';
        END IF;

        -- Mismo gate por plan (y mismo criterio ante lo no resoluble) que
        -- fn_unidad_crear; ver el comentario extenso del bloque 2.c de esa
        -- funcion. Solo se evalua cuando el caller esta TOCANDO el campo:
        -- un PATCH de otra cosa no debe reventar por un peso heredado que
        -- dejo de aplicar al reconfigurarse el plan.
        IF p_ponderacion IS NOT NULL THEN
            v_pk_plan := academico_test.fn_asignatura_plan_vigente_por_grado(v_grado, v_asig);
            IF v_pk_plan IS NOT NULL THEN
                v_elemento := academico_test.fn_asignatura_plan_elemento_calculo(v_pk_plan);
                v_modo     := academico_test.fn_asignatura_plan_calculo_definitiva_modo(v_pk_plan);

                IF v_elemento = 'ACTIVIDADES' THEN
                    RAISE EXCEPTION 'Esta asignatura no reparte la nota por unidades, asi que la unidad no lleva peso (%%); el peso se define en cada actividad'
                        USING ERRCODE = '22023',
                              HINT = 'TASIGNATURA_PLAN.FK_TLV_ELEMENTO_CALCULO_DEF de esa asignatura combina ACTIVIDADES; el peso por actividad se captura en TACTIVIDAD.PONDERACION (V223)';
                END IF;
                IF v_modo = 'PROMEDIAR' THEN
                    RAISE EXCEPTION 'Esta asignatura promedia sus unidades, asi que la unidad no lleva peso (%%)'
                        USING ERRCODE = '22023';
                END IF;
            END IF;
        END IF;

        -- Regla del 100% sin contar el peso viejo de la fila que se toca.
        v_suma := academico_test.fn_unidad_ponderacion_intra_asignatura_asignada(
                      v_asig, v_grado, p_pk_tunidad);
        IF v_suma + v_ponder > 100 THEN
            RAISE EXCEPTION
              'Las unidades de esa asignatura y grado ya tienen % %% ponderado; % %% pasarian de 100',
              v_suma, v_ponder
              USING ERRCODE = '23514';
        END IF;
    END IF;

    UPDATE academico_test.TUNIDAD
       SET NOMBRE                    = v_nombre,
           DESCRIPCION               = CASE WHEN p_descripcion IS NULL THEN DESCRIPCION
                                            ELSE NULLIF(TRIM(p_descripcion), '') END,
           FK_TASIGNATURA            = v_asig,
           FK_TGRADO                 = v_grado,
           FK_TFUNCIONARIO           = COALESCE(p_fk_tfuncionario, FK_TFUNCIONARIO),
           FK_TLV_CALCULO_DEFINITIVA = COALESCE(p_fk_tlv_calculo_definitiva, FK_TLV_CALCULO_DEFINITIVA),
           -- Ya resuelto arriba (limpiar / nuevo validado / conservar o
           -- re-derivar si dejo de aplicar). No se recalcula aqui.
           FK_REFERENTE_CURRICULAR   = v_fk_referente,
           PONDERACION               = v_ponder,
           MODIFIED_BY               = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT               = CURRENT_TIMESTAMP
     WHERE PK_TUNIDAD = p_pk_tunidad;

    -- Objetivos: reemplazo completo solo si el caller mando el parametro.
    IF p_objetivos IS NOT NULL THEN
        UPDATE academico_test.TUNIDAD_OBJETIVO
           SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TUNIDAD = p_pk_tunidad AND ACTIVE = TRUE;

        INSERT INTO academico_test.TUNIDAD_OBJETIVO (FK_TUNIDAD, ORDEN, DESCRIPCION, CREATED_BY, CREATED_AT, ACTIVE)
        SELECT p_pk_tunidad, ROW_NUMBER() OVER (ORDER BY o.pos), TRIM(o.txt),
               p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
          FROM unnest(p_objetivos) WITH ORDINALITY AS o(txt, pos)
         WHERE NULLIF(TRIM(o.txt), '') IS NOT NULL;
    END IF;

    -- Contenidos: idem.
    IF p_contenidos IS NOT NULL THEN
        UPDATE academico_test.TUNIDAD_CONTENIDO
           SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TUNIDAD = p_pk_tunidad AND ACTIVE = TRUE;

        INSERT INTO academico_test.TUNIDAD_CONTENIDO (FK_TUNIDAD, ORDEN, DESCRIPCION, CREATED_BY, CREATED_AT, ACTIVE)
        SELECT p_pk_tunidad, ROW_NUMBER() OVER (ORDER BY c.pos), TRIM(c.txt),
               p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
          FROM unnest(p_contenidos) WITH ORDINALITY AS c(txt, pos)
         WHERE NULLIF(TRIM(c.txt), '') IS NOT NULL;
    END IF;

    -- ------------------------------------------------------------------
    -- V478 — el metodo de calculo cambio: la PONDERACION que las
    -- actividades ya vinculadas traian del modo ANTERIOR ya no significa
    -- nada (o significa algo distinto) en el modo nuevo. Se resetea a
    -- NULL para las tres actividades -- igual que hace
    -- fn_unidad_actividad_vincular con una actividad puntual -- y, si el
    -- modo nuevo es SUMATORIA, se recalcula de una el reparto real por
    -- cada bucket (unidad, grupo) que tenga actividades activas, en vez
    -- de dejarlo pendiente hasta que alguien vincule/desvincule algo.
    -- ------------------------------------------------------------------
    IF v_calculo_cambio THEN
        UPDATE academico_test.TACTIVIDAD
           SET PONDERACION = NULL,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TUNIDAD = p_pk_tunidad
           AND ACTIVE = TRUE
           AND PONDERACION IS NOT NULL;

        IF academico_test.fn_unidad_calculo_definitiva_modo(p_pk_tunidad) = 'SUMATORIA' THEN
            FOR v_grupo_bucket IN
                SELECT DISTINCT a.FK_TGRUPO
                  FROM academico_test.TACTIVIDAD a
                 WHERE a.FK_TUNIDAD = p_pk_tunidad
                   AND a.ACTIVE = TRUE
            LOOP
                PERFORM academico_test.fn_unidad_ponderacion_recalcular_sumatoria(
                    p_pk_tunidad, v_grupo_bucket);
            END LOOP;
        END IF;
    END IF;

    -- V492: enunciados del referente (mismo contrato que en fn_unidad_crear).
    IF p_enunciados IS NOT NULL THEN
        UPDATE academico_test.TACTIVIDAD_EVIDENCIA ae
           SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
          FROM academico_test.TREFERENTE_ENUNCIADO ev, academico_test.TACTIVIDAD a
         WHERE ae.FK_REFERENTE_ENUNCIADO = ev.PK_REFERENTE_ENUNCIADO
           AND a.PK_TACTIVIDAD = ae.FK_TACTIVIDAD
           AND a.FK_TUNIDAD = p_pk_tunidad
           AND ae.ACTIVE = TRUE
           AND ev.FK_PADRE <> ALL(ARRAY(SELECT x FROM unnest(p_enunciados) x WHERE x IS NOT NULL));

        UPDATE academico_test.TUNIDAD_ENUNCIADO
           SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TUNIDAD = p_pk_tunidad
           AND ACTIVE = TRUE
           AND FK_REFERENTE_ENUNCIADO <> ALL(ARRAY(SELECT x FROM unnest(p_enunciados) x WHERE x IS NOT NULL));

        PERFORM academico_test.fn_unidad_enunciado_relacionar(p_pk_usuario_solicitante, p_pk_tunidad, e)
          FROM (SELECT DISTINCT e FROM unnest(p_enunciados) AS e WHERE e IS NOT NULL) s;
    END IF;

    RETURN p_pk_tunidad;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_actualizar(BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, BOOLEAN, VARCHAR[], VARCHAR[], NUMERIC, BOOLEAN, BIGINT[])
    IS 'PATCH parcial de TUNIDAD (gate EDITAR): cada parametro NULL preserva el valor actual. REFERENTE CURRICULAR, tres casos, resueltos contra el grado RESULTANTE del PATCH (mover la unidad de grado le cambia el nivel educativo y con el que referentes aplican): p_limpiar_referente=TRUE lo fuerza a NULL; si llega uno nuevo se exige que APLIQUE al nivel de ese grado (23503 si no, misma razon que en fn_unidad_crear); y si no lo tocan se CONSERVA el actual salvo que haya dejado de aplicar -- porque cambio el grado o porque lo desactivaron en el catalogo --, caso en el que se RE-DERIVA con fn_unidad_referente_aplicable en vez de dejar una FK muerta (era lo que pasaba en el servidor de test: unidades apuntando a referentes con ACTIVE=false, con el detalle devolviendo NULL y el listado mostrando el nombre del referente muerto). p_objetivos / p_contenidos NULL = no tocar; cualquier array (incl. vacio) = reemplazo completo (desactiva los activos y re-inserta con ORDEN por posicion, ignora vacios). Revalida FKs y unicidad (nombre, asignatura, grado) -- la unidad ya no depende de un periodo de evaluacion (V218). p_ponderacion / p_limpiar_ponderacion editan TUNIDAD.PONDERACION (V239, peso % de la unidad dentro de su (asignatura, grado)): NULL = no tocar, p_limpiar_ponderacion=TRUE la vuelve NULL. Se valida contra los valores RESULTANTES del PATCH (un PATCH que mueve la unidad de asignatura o grado cambia el bucket del 100%): rango 0..100, regla del 100% via fn_unidad_ponderacion_intra_asignatura_asignada excluyendo el peso viejo de esta misma unidad, y -- solo cuando el caller esta tocando el campo -- que el peso APLIQUE segun el plan de la asignatura para ese grado (22023 si el plan calcula por ACTIVIDADES o promedia sus unidades; si el plan no se resuelve o no esta configurado se permite, mismo criterio que fn_unidad_crear). GUARD "instrumento huerfano" (V214.2): si la unidad ERA evaluativa y el PATCH la deja no evaluativa -- por los TRES caminos: p_limpiar_referente, mover a un referente FORMATIVO, o la re-derivacion silenciosa del caso (c) --, se ABORTA (22023) cuando alguna de sus actividades activas ya tiene instrumento de evaluacion configurado, nombrandolas con fn_unidad_actividades_instrumentadas. Antes pasaba sin queja y esas actividades quedaban con un instrumento que la unidad ya no admite, estado desde el cual fn_actividad_actualizar (V224) rechaza CUALQUIER edicion sobre ellas -- incluido desvincularlas --, porque revalida el instrumento heredado en cada llamada. FIX V478: si FK_TLV_CALCULO_DEFINITIVA efectivamente cambia (p_fk_tlv_calculo_definitiva informado y DISTINCT del valor anterior), se resetea a NULL la PONDERACION de todas las actividades ACTIVE ya vinculadas -- el valor del modo anterior no tiene sentido en el nuevo -- y, si el modo resultante es SUMATORIA, se recalcula de una el reparto real (fn_unidad_ponderacion_recalcular_sumatoria) por cada bucket (unidad, FK_TGRUPO) con actividades activas; antes ese recalculo solo ocurria al vincular/desvincular una actividad puntual, y la tabla "Actividades"/el popover "Vincular actividad" seguian mostrando los numeros del metodo ANTERIOR hasta que algo mas tocara el bucket. p_enunciados (V492): NULL = no tocar; array = reemplazo completo de TUNIDAD_ENUNCIADO via fn_unidad_enunciado_relacionar, desactivando las evidencias de actividades que colgaban de los enunciados quitados. Retorna PK_TUNIDAD.';

UPDATE public.query
   SET query       = replace(query, E'COALESCE(CAST(:BODY.LIMPIAR_PONDERACION AS BOOLEAN), FALSE)
);',
                                    E'COALESCE(CAST(:BODY.LIMPIAR_PONDERACION AS BOOLEAN), FALSE),
    CAST(:BODY.ENUNCIADOS AS BIGINT[])
);'),
       param_types = param_types || '{"BODY.ENUNCIADOS": "BIGINT[]"}'::jsonb,
       detail      = detail || ' V492: BODY.ENUNCIADOS (PKs de TREFERENTE_ENUNCIADO nivel 1) NULL = no tocar, array = reemplazo completo.'
 WHERE path_template = '/planeador/unidades/:ID' AND http_method = 'PUT'
   AND microservice_id = (SELECT id_microservice FROM public.microservice WHERE serviceid = 'eval-col')
   AND query NOT LIKE '%:BODY.ENUNCIADOS%';
