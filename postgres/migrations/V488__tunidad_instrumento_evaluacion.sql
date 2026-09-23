-- ===========================================================================
-- V488 — Instrumento de evaluación PROPIO de la unidad (TUNIDAD).
--
-- CONTEXTO: el front quiere titular "Actividades en {instrumento}"/
-- "Criterios en {instrumento}" en el panel de una unidad (pedido explícito),
-- pero hoy el instrumento de evaluación vive SOLO por actividad
-- (TACTIVIDAD.FK_TLV_INSTRUMENTO_EVALUACION, nullable hasta que el docente
-- lo configura) -- no hay ningún dato a nivel de UNIDAD del que derivarlo de
-- forma confiable. El front lo venía resolviendo mirando las actividades ya
-- vinculadas (si TODAS comparten el mismo instrumento), pero eso falla en el
-- caso más común: actividades recién vinculadas, todavía sin instrumento
-- configurado -- el título se quedaba siempre en el genérico.
--
-- FIX: se agrega TUNIDAD.FK_TLV_INSTRUMENTO_EVALUACION, mismo catálogo
-- (TLISTA_VALOR CATEGORIA='INSTRUMENTO_EVALUACION') que ya usa
-- TACTIVIDAD.FK_TLV_INSTRUMENTO_EVALUACION -- mismo patrón que V73 agregó
-- FK_TLV_CALCULO_DEFINITIVA a TUNIDAD (columna nullable + índice parcial +
-- COMMENT). El docente lo elige al crear/editar la unidad (como ya elige
-- "Método de cálculo"); las unidades existentes quedan con NULL -- sin
-- backfill, no hay de dónde inferirlo retroactivamente con certeza. NULL
-- sigue siendo un estado legítimo: "esta unidad no fijó un instrumento",
-- caso en el que el front sigue cayendo a su título genérico.
--
-- Se actualizan los CUATRO puntos de entrada/salida del dato:
--   1. fn_unidad_crear      — nuevo parámetro opcional, valida contra el
--                             catálogo si viene informado.
--   2. fn_unidad_actualizar — nuevo parámetro opcional, PATCH parcial (NULL
--                             = no tocar, mismo criterio que el resto de la
--                             función).
--   3. fn_unidad_listar     — agrega fk_tlv_instrumento_evaluacion +
--                             instrumento_evaluacion (nombre resuelto).
--   4. fn_unidad_buscar_por_pk — idem, para el detalle.
--
-- Cambiar el RETURNS TABLE de una función existente no lo permite CREATE OR
-- REPLACE -- DROP FUNCTION IF EXISTS primero en fn_unidad_listar/
-- fn_unidad_buscar_por_pk (mismo patrón ya usado en V479/V480/V481).
-- Agregar un parámetro nuevo (aunque tenga DEFAULT) cambia la aridad de la
-- función y CREATE OR REPLACE tampoco reemplaza esa firma -- crearía una
-- SOBRECARGA ambigua con la llamada posicional ya registrada (misma lección
-- de V244/V478) -- DROP FUNCTION IF EXISTS primero también en
-- fn_unidad_crear/fn_unidad_actualizar.
--
-- Depende de: V22 (TUNIDAD, TLISTA_VALOR), V216 (fn_unidad_crear/_listar/
-- _buscar_por_pk), V478 (última versión de fn_unidad_actualizar), V73
-- (mismo patrón de columna).
-- ===========================================================================

SET search_path TO academico_test, public;

-- ---------------------------------------------------------------------------
-- 1. TUNIDAD.FK_TLV_INSTRUMENTO_EVALUACION
-- ---------------------------------------------------------------------------
ALTER TABLE TUNIDAD
    ADD COLUMN IF NOT EXISTS FK_TLV_INSTRUMENTO_EVALUACION BIGINT
    REFERENCES TLISTA_VALOR (PK_LISTA_VALOR);

CREATE INDEX IF NOT EXISTS IDX_TUNIDAD_FK_TLV_INSTRUMENTO_EVALUACION
    ON academico_test.TUNIDAD (FK_TLV_INSTRUMENTO_EVALUACION)
    WHERE FK_TLV_INSTRUMENTO_EVALUACION IS NOT NULL;

COMMENT ON COLUMN academico_test.TUNIDAD.FK_TLV_INSTRUMENTO_EVALUACION IS
    'Instrumento de evaluación que el docente fija para ESTA unidad (Rúbrica / Lista de cotejo / Escala de valoración / Otro) -- TLISTA_VALOR CATEGORIA=''INSTRUMENTO_EVALUACION'', mismo catálogo que TACTIVIDAD.FK_TLV_INSTRUMENTO_EVALUACION (V224). Nullable: unidad sin instrumento fijado (incluidas TODAS las unidades existentes antes de V488, sin backfill -- no hay de dónde inferirlo con certeza). No condiciona ni valida el instrumento de las actividades que se vinculen -- es solo el rótulo de la unidad ("Actividades en {instrumento}" en el panel), independiente de TACTIVIDAD.FK_TLV_INSTRUMENTO_EVALUACION. V488.';

-- ---------------------------------------------------------------------------
-- 2. fn_unidad_crear — nuevo parámetro opcional al final.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_unidad_crear(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, VARCHAR, BIGINT, VARCHAR[], VARCHAR[], BIGINT[], NUMERIC);

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_crear(
    p_pk_usuario_solicitante        BIGINT,
    p_nombre                        VARCHAR(250),
    p_fk_tasignatura                BIGINT,
    p_fk_tgrado                     BIGINT,
    p_fk_tfuncionario               BIGINT,
    p_fk_tlv_calculo_definitiva     BIGINT,
    p_descripcion                   VARCHAR(4000) DEFAULT NULL,
    p_fk_referente_curricular       BIGINT        DEFAULT NULL,
    -- Uno por elemento; el ORDEN se toma de la posicion en el array.
    -- Elementos NULL o en blanco se ignoran.
    p_objetivos                     VARCHAR[]     DEFAULT NULL,
    p_contenidos                    VARCHAR[]     DEFAULT NULL,
    -- PK_REFERENTE_ENUNCIADO (nivel 1, TREFERENTE_ENUNCIADO) del referente
    -- curricular (p_fk_referente_curricular) que aplican a esta unidad.
    -- Solo tiene sentido si se pasa p_fk_referente_curricular; cada uno se
    -- relaciona via fn_unidad_enunciado_relacionar (V214.1), que ya valida
    -- que el enunciado sea nivel 1 y comparta el nivel de ensenanza de la
    -- unidad (a traves del grado) -- no se duplica esa validacion aqui.
    p_enunciados                    BIGINT[]      DEFAULT NULL,
    -- Peso (%) de ESTA unidad dentro de su (asignatura, grado) —
    -- TUNIDAD.PONDERACION (V239). Opcional. Ver el bloque 2.c.
    p_ponderacion                   NUMERIC       DEFAULT NULL,
    -- V488: instrumento de evaluación de la unidad (rótulo), TLISTA_VALOR
    -- CATEGORIA='INSTRUMENTO_EVALUACION'. Opcional -- a diferencia de
    -- p_fk_tlv_calculo_definitiva, este NO es obligatorio: una unidad puede
    -- crearse sin fijarlo todavía.
    p_fk_tlv_instrumento_evaluacion BIGINT        DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_id_creado  BIGINT;
    -- Referente EFECTIVO: el que mando el cliente o, si no lo mando, el
    -- derivado del grado. Es este el que se inserta, nunca el parametro.
    v_fk_referente BIGINT;
    v_pk_plan    BIGINT;
    v_elemento   VARCHAR;
    v_modo       VARCHAR;
    v_suma       NUMERIC(9,2);
BEGIN
    -- 0. Gate: capability CREAR sobre PLANEADOR (sin scope territorial).
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'CREAR', NULL, p_fk_tgrado
    );

    -- 1. Obligatorios.
    IF NULLIF(TRIM(p_nombre), '') IS NULL THEN
        RAISE EXCEPTION 'El nombre de la unidad es obligatorio'
            USING ERRCODE = '22023', HINT = 'p_nombre no puede ser NULL ni vacio';
    END IF;
    IF p_fk_tasignatura IS NULL THEN
        RAISE EXCEPTION 'La asignatura (FK_TASIGNATURA) es obligatoria' USING ERRCODE = '22023';
    END IF;
    IF p_fk_tgrado IS NULL THEN
        RAISE EXCEPTION 'El grado (FK_TGRADO) es obligatorio' USING ERRCODE = '22023';
    END IF;
    -- El docente autor NO se le pide al cliente: se DERIVA del usuario
    -- autenticado. El front no tiene de donde sacar un PK_TFUNCIONARIO -- el
    -- JWT solo trae el id de usuario, y su claim "fid" es un identificador de
    -- sesion que cambia en cada login, no el funcionario -- asi que exigirlo
    -- en el body obligaba a inventarlo. fn_funcionario_actual (V224) hace la
    -- resolucion, desempatando por el alcance del propio usuario cuando tiene
    -- funcionario en varios establecimientos.
    --
    -- Se mantiene el parametro y se respeta si viene: un coordinador o rector
    -- puede crear la unidad a nombre de otro docente. Solo deja de ser
    -- obligatorio.
    p_fk_tfuncionario := COALESCE(
        p_fk_tfuncionario,
        academico_test.fn_funcionario_actual(p_pk_usuario_solicitante)
    );

    IF p_fk_tfuncionario IS NULL THEN
        RAISE EXCEPTION 'No se pudo determinar el docente autor de la unidad'
            USING ERRCODE = '22023',
                  HINT = 'El usuario autenticado no tiene un funcionario activo asociado; envie FK_TFUNCIONARIO explicitamente';
    END IF;
    IF p_fk_tlv_calculo_definitiva IS NULL THEN
        RAISE EXCEPTION 'La forma de calculo de la nota (FK_TLV_CALCULO_DEFINITIVA) es obligatoria'
            USING ERRCODE = '22023', HINT = 'Promediar / Ponderar / Sumatoria de Actividades';
    END IF;

    -- 2. FKs existen y estan activas.
    IF NOT EXISTS (SELECT 1 FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_fk_tasignatura AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'La asignatura seleccionada no esta disponible' USING ERRCODE = '23503';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_tgrado AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'El grado seleccionado no esta disponible' USING ERRCODE = '23503';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM academico_test.TFUNCIONARIO WHERE PK_TFUNCIONARIO = p_fk_tfuncionario AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'El docente seleccionado no esta disponible' USING ERRCODE = '23503';
    END IF;

    -- 2.a Forma de calculo de la nota de la unidad (obligatoria).
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_fk_tlv_calculo_definitiva
           AND CATEGORIA = 'CALCULO_DEFINITIVA'
           AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'La forma de calculo de la nota seleccionada no es valida' USING ERRCODE = '23503';
    END IF;

    -- 2.a.2 (V488) Instrumento de evaluación de la unidad (opcional).
    IF p_fk_tlv_instrumento_evaluacion IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_fk_tlv_instrumento_evaluacion
           AND CATEGORIA = 'INSTRUMENTO_EVALUACION'
           AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'El instrumento de evaluacion seleccionado no es valido' USING ERRCODE = '23503';
    END IF;

    -- 2.b Referente curricular al que se acoge la unidad.
    --
    -- El parametro es opcional, pero "no lo mandaron" NO puede significar
    -- "unidad sin referente": el referente se DERIVA del grado (no se elige a
    -- mano en ninguna pantalla), y una unidad sin el queda inservible -- el
    -- front no puede rotular los niveles, ni decidir si hay seccion de
    -- evaluacion, ni ofrecer enunciados que marcar, porque
    -- GET /planeador/unidades/:ID/referente (V255) le devuelve todo NULL.
    -- Comprobado en el servidor de test: las unidades creadas desde la UI
    -- (60, 61, 62) quedaron con FK_REFERENTE_CURRICULAR NULL.
    --
    -- Asi que si no llega, se deriva aqui con la MISMA regla que usa el
    -- endpoint que el front consulta (fn_unidad_referente_aplicable). Si no
    -- hay ninguno aplicable queda NULL, que sigue siendo legitimo: hay grados
    -- sin referente cargado todavia.
    IF p_fk_referente_curricular IS NULL THEN
        v_fk_referente := academico_test.fn_unidad_referente_aplicable(
            p_fk_tgrado, p_fk_tasignatura);
    ELSE
        v_fk_referente := p_fk_referente_curricular;

        -- ACTIVE (borrado logico) Y ESTADO (estado de negocio que edita el
        -- usuario): un referente marcado Inactivo no se puede relacionar,
        -- aunque su fila siga viva.
        IF NOT EXISTS (
            SELECT 1 FROM academico_test.TREFERENTE_CURRICULAR
             WHERE PK_REFERENTE_CURRICULAR = v_fk_referente
               AND ACTIVE = TRUE
               AND ESTADO = 'A'
        ) THEN
            RAISE EXCEPTION 'El referente curricular seleccionado ya no esta vigente'
                USING ERRCODE = '23503';
        END IF;

        -- Y que APLIQUE al nivel educativo del grado de la unidad. Sin esta
        -- comprobacion se podia crear una unidad de Preescolar acogida a un
        -- referente de Primaria (probado en el servidor de test: pasaba sin
        -- queja). El resultado no era un error visible sino un callejon sin
        -- salida: fn_unidad_enunciado_relacionar (V214.1) exige que el enunciado
        -- sea del mismo nivel que la unidad, asi que ese referente no podia
        -- aportar NI UN enunciado -- una unidad con referente que nunca sirve
        -- para nada.
        IF NOT EXISTS (
            SELECT 1
              FROM academico_test.TREFERENTE_CURRICULAR_NIVEL rcn
              JOIN academico_test.TGRADO g ON g.PK_TGRADO = p_fk_tgrado
             WHERE rcn.FK_REFERENTE_CURRICULAR = v_fk_referente
               AND rcn.FK_TNIVEL_ENSENANZA = g.FK_TNIVEL_ENSENANZA
               AND rcn.ACTIVE = TRUE
        ) THEN
            RAISE EXCEPTION 'El referente curricular (%) no aplica al nivel educativo del grado (%) de la unidad', v_fk_referente, p_fk_tgrado
                USING ERRCODE = '23503';
        END IF;
    END IF;

    -- 2.c Peso (%) de la unidad dentro de su (asignatura, grado)
    --     — TUNIDAD.PONDERACION (V239). Mismo tratamiento que V223/V224 le dan
    --     a TACTIVIDAD.PONDERACION un nivel abajo: rango 0..100, "el modo de
    --     calculo manda si el campo aplica", y chequeo previo del 100% para
    --     dar un error claro ANTES de que salte el trigger
    --     tr_tunidad_ponderacion_asignatura.
    IF p_ponderacion IS NOT NULL THEN
        IF p_ponderacion < 0 OR p_ponderacion > 100 THEN
            RAISE EXCEPTION 'La ponderacion (%) debe estar entre 0 y 100', p_ponderacion
                USING ERRCODE = '22023';
        END IF;

        -- Quien decide si el peso de la UNIDAD aplica no es la unidad (su
        -- FK_TLV_CALCULO_DEFINITIVA gobierna a sus ACTIVIDADES), sino el PLAN
        -- de la asignatura para ese GRADO: solo si la definitiva se calcula
        -- por UNIDADES y esas unidades se combinan PONDERANDO/SUMANDO existe
        -- un peso de unidad que signifique algo (V239,
        -- fn_planilla_definitiva_proyectada).
        --
        -- TUNIDAD no tiene grupo, por eso se resuelve el plan por GRADO
        -- (fn_asignatura_plan_vigente_por_grado, V239) y no por grupo.
        --
        -- CRITERIO ANTE LO NO RESOLUBLE (consistente con el fallback (e) de
        -- V239): solo se rechaza cuando se puede AFIRMAR que el peso no
        -- aplica. Si no hay fila de TASIGNATURA_PLAN, o el plan no tiene
        -- elemento/modo configurado (helpers -> NULL), no hay con que validar
        -- y se PERMITE guardar el peso: es un dato de configuracion inocuo
        -- que la definitiva simplemente ignorara mientras el plan no lo
        -- habilite, y bloquear ahi impediria preparar la unidad antes de que
        -- coordinacion termine de configurar el plan.
        v_pk_plan := academico_test.fn_asignatura_plan_vigente_por_grado(
                         p_fk_tgrado, p_fk_tasignatura);
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

        -- Regla del 100% por (asignatura, grado). Sin excluir nada: la unidad
        -- todavia no existe.
        v_suma := academico_test.fn_unidad_ponderacion_intra_asignatura_asignada(
                      p_fk_tasignatura, p_fk_tgrado, NULL);
        IF v_suma + p_ponderacion > 100 THEN
            RAISE EXCEPTION
              'Las unidades de esa asignatura y grado ya tienen % %% ponderado; % %% adicionales pasarian de 100',
              v_suma, p_ponderacion
              USING ERRCODE = '23514';
        END IF;
    END IF;

    -- 3. Unicidad (NOMBRE, asignatura, grado) entre unidades activas —
    --    backstop del constraint UN_TUNIDAD_1 (V218).
    IF EXISTS (
        SELECT 1 FROM academico_test.TUNIDAD
         WHERE UPPER(TRIM(NOMBRE)) = UPPER(TRIM(p_nombre))
           AND FK_TASIGNATURA = p_fk_tasignatura
           AND FK_TGRADO = p_fk_tgrado
           AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'Ya existe una unidad activa "%" para esa asignatura y grado', p_nombre
            USING ERRCODE = '23505';
    END IF;

    -- 4. INSERT de la unidad.
    INSERT INTO academico_test.TUNIDAD (
        NOMBRE, FK_TASIGNATURA, FK_TGRADO, FK_TFUNCIONARIO,
        DESCRIPCION, FK_TLV_CALCULO_DEFINITIVA, FK_REFERENTE_CURRICULAR,
        PONDERACION, FK_TLV_INSTRUMENTO_EVALUACION, CREATED_BY, CREATED_AT, ACTIVE
    ) VALUES (
        TRIM(p_nombre), p_fk_tasignatura, p_fk_tgrado, p_fk_tfuncionario,
        NULLIF(TRIM(p_descripcion), ''), p_fk_tlv_calculo_definitiva, v_fk_referente,
        p_ponderacion, p_fk_tlv_instrumento_evaluacion, p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
    )
    RETURNING PK_TUNIDAD INTO v_id_creado;

    -- 5. Objetivos (opcional) — ORDEN por posicion, se ignoran los vacios.
    IF p_objetivos IS NOT NULL THEN
        INSERT INTO academico_test.TUNIDAD_OBJETIVO (FK_TUNIDAD, ORDEN, DESCRIPCION, CREATED_BY, CREATED_AT, ACTIVE)
        SELECT v_id_creado,
               ROW_NUMBER() OVER (ORDER BY o.pos),
               TRIM(o.txt),
               p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
          FROM unnest(p_objetivos) WITH ORDINALITY AS o(txt, pos)
         WHERE NULLIF(TRIM(o.txt), '') IS NOT NULL;
    END IF;

    -- 6. Contenidos / componentes (opcional) — misma regla.
    IF p_contenidos IS NOT NULL THEN
        INSERT INTO academico_test.TUNIDAD_CONTENIDO (FK_TUNIDAD, ORDEN, DESCRIPCION, CREATED_BY, CREATED_AT, ACTIVE)
        SELECT v_id_creado,
               ROW_NUMBER() OVER (ORDER BY c.pos),
               TRIM(c.txt),
               p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
          FROM unnest(p_contenidos) WITH ORDINALITY AS c(txt, pos)
         WHERE NULLIF(TRIM(c.txt), '') IS NOT NULL;
    END IF;

    -- 7. Enunciados del referente curricular que aplican a la unidad
    --    (opcional; TUNIDAD_ENUNCIADO, V214.1). Delega la validacion completa
    --    (nivel 1, mismo nivel de ensenanza) en fn_unidad_enunciado_relacionar
    --    -- si algun PK no cumple, la funcion revienta y aborta el CREATE
    --    completo (misma transaccion).
    IF p_enunciados IS NOT NULL THEN
        PERFORM academico_test.fn_unidad_enunciado_relacionar(
                    p_pk_usuario_solicitante, v_id_creado, e)
          FROM unnest(p_enunciados) AS e
         WHERE e IS NOT NULL;
    END IF;

    RETURN v_id_creado;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_crear(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, VARCHAR, BIGINT, VARCHAR[], VARCHAR[], BIGINT[], NUMERIC, BIGINT)
    IS 'Crea una unidad tematica del Planeador (gate CREAR sobre PLANEADOR). REFERENTE CURRICULAR: p_fk_referente_curricular es opcional, pero omitirlo NO significa "unidad sin referente" -- se DERIVA del grado con fn_unidad_referente_aplicable. p_fk_tfuncionario (el docente autor) es OPCIONAL: si viene NULL se DERIVA del usuario autenticado con fn_funcionario_actual (V224). Inserta TUNIDAD (identificacion nombre/asignatura/grado/autor + DESCRIPCION + FK_TLV_CALCULO_DEFINITIVA [forma de calculo, OBLIGATORIA, V73] + FK_REFERENTE_CURRICULAR + FK_TLV_INSTRUMENTO_EVALUACION [V488, instrumento de evaluacion de la UNIDAD -- catalogo INSTRUMENTO_EVALUACION, mismo que usa TACTIVIDAD, OPCIONAL a diferencia del metodo de calculo: solo el rotulo del panel ("Actividades en {instrumento}"), no condiciona el instrumento de las actividades que se vinculen]) y, si se pasan, sus objetivos, contenidos y los enunciados del referente que aplican. Valida existencia/estado de todas las FKs (incluido el instrumento, contra CATEGORIA=''INSTRUMENTO_EVALUACION'', solo si viene informado) y unicidad (nombre, asignatura, grado) entre unidades activas. p_ponderacion (opcional) fija TUNIDAD.PONDERACION (V239). Retorna PK_TUNIDAD. V216, editada en V488.';

-- ---------------------------------------------------------------------------
-- 3. fn_unidad_actualizar — nuevo parámetro opcional al final (PATCH: NULL
--    = no tocar, mismo criterio que el resto de la función, ver V478).
-- ---------------------------------------------------------------------------
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
    -- Peso (%) de ESTA unidad dentro de su (asignatura, grado), TUNIDAD.PONDERACION
    -- (V239). NULL = no tocar; p_limpiar_ponderacion = TRUE lo vuelve NULL
    -- (mismo par "valor / limpiar" que ya usa el referente curricular).
    p_ponderacion                   NUMERIC       DEFAULT NULL,
    p_limpiar_ponderacion           BOOLEAN       DEFAULT FALSE,
    -- V488: instrumento de evaluación de la unidad. NULL = no tocar (mismo
    -- criterio simple que el resto del PATCH; a diferencia de referente/
    -- ponderación no tiene "limpiar" propio en esta primera versión -- una
    -- vez fijado, se reemplaza por otro, no se vacía).
    p_fk_tlv_instrumento_evaluacion BIGINT        DEFAULT NULL
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
    -- V488: instrumento de evaluacion de la unidad (solo si viene informado).
    IF p_fk_tlv_instrumento_evaluacion IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_fk_tlv_instrumento_evaluacion AND CATEGORIA = 'INSTRUMENTO_EVALUACION' AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'El instrumento de evaluacion seleccionado no es valido' USING ERRCODE = '23503';
    END IF;
    -- ACTIVE (borrado logico) Y ESTADO (estado de negocio que edita el
    -- usuario): ver la nota equivalente en fn_unidad_crear.
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
       SET NOMBRE                        = v_nombre,
           DESCRIPCION                   = CASE WHEN p_descripcion IS NULL THEN DESCRIPCION
                                                ELSE NULLIF(TRIM(p_descripcion), '') END,
           FK_TASIGNATURA                = v_asig,
           FK_TGRADO                     = v_grado,
           FK_TFUNCIONARIO               = COALESCE(p_fk_tfuncionario, FK_TFUNCIONARIO),
           FK_TLV_CALCULO_DEFINITIVA     = COALESCE(p_fk_tlv_calculo_definitiva, FK_TLV_CALCULO_DEFINITIVA),
           -- Ya resuelto arriba (limpiar / nuevo validado / conservar o
           -- re-derivar si dejo de aplicar). No se recalcula aqui.
           FK_REFERENTE_CURRICULAR       = v_fk_referente,
           PONDERACION                   = v_ponder,
           -- V488: NULL = no tocar (mismo criterio que FK_TLV_CALCULO_DEFINITIVA).
           FK_TLV_INSTRUMENTO_EVALUACION = COALESCE(p_fk_tlv_instrumento_evaluacion, FK_TLV_INSTRUMENTO_EVALUACION),
           MODIFIED_BY                   = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT                   = CURRENT_TIMESTAMP
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

    RETURN p_pk_tunidad;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_actualizar(BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, BOOLEAN, VARCHAR[], VARCHAR[], NUMERIC, BOOLEAN, BIGINT)
    IS 'PATCH parcial de TUNIDAD (gate EDITAR): cada parametro NULL preserva el valor actual. REFERENTE CURRICULAR, tres casos (ver V216). p_objetivos / p_contenidos NULL = no tocar; cualquier array (incl. vacio) = reemplazo completo. p_ponderacion / p_limpiar_ponderacion editan TUNIDAD.PONDERACION (V239). GUARD "instrumento huerfano" (V214.2). FIX V478: si FK_TLV_CALCULO_DEFINITIVA cambia de verdad, se resetea/recalcula PONDERACION de las actividades ya vinculadas. V488: p_fk_tlv_instrumento_evaluacion edita TUNIDAD.FK_TLV_INSTRUMENTO_EVALUACION (instrumento de evaluacion de la UNIDAD, catalogo INSTRUMENTO_EVALUACION) -- NULL = no tocar, sin validacion de huerfanos ni de 100%: es solo el rotulo del panel, no condiciona actividades. Retorna PK_TUNIDAD.';

-- ---------------------------------------------------------------------------
-- 4. fn_unidad_listar — agrega fk_tlv_instrumento_evaluacion + instrumento_evaluacion.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_unidad_listar(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, BOOLEAN, VARCHAR, BOOLEAN, INT, INT, DATE, INT);

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_listar(
    p_pk_usuario_solicitante      BIGINT,
    p_search                      VARCHAR   DEFAULT NULL,
    p_fk_tasignatura              BIGINT    DEFAULT NULL,
    p_fk_tgrado                   BIGINT    DEFAULT NULL,
    p_fk_tfuncionario             BIGINT    DEFAULT NULL,
    p_incluir_inactivos           BOOLEAN   DEFAULT FALSE,
    p_orden_por                   VARCHAR   DEFAULT 'nombre',
    p_orden_asc                   BOOLEAN   DEFAULT TRUE,
    p_limite                      INT       DEFAULT 20,
    p_offset                      INT       DEFAULT 0,
    -- Paginado por DIA ACTIVO, la misma barra "Hoy | MARTES 16 | < >" de las
    -- actividades. Una unidad "esta" en un dia si ALGUNA de sus actividades
    -- activas esta vigente ese dia (la unidad no tiene fechas propias: sus
    -- fecha_inicio/fecha_fin ya son derivadas de las actividades).
    -- NULL = sin paginado por dia.
    p_dia                         DATE      DEFAULT NULL,
    -- Dias de gracia del estado derivado; se propaga tal cual a
    -- fn_unidad_estado -> fn_actividad_estado. Mismo default que alla.
    p_dias_gracia                 INT       DEFAULT 2
)
RETURNS TABLE (
    pk_tunidad                  BIGINT,
    nombre                      VARCHAR,
    descripcion                 VARCHAR,
    fk_tasignatura              BIGINT,
    asignatura                  VARCHAR,
    fk_tarea                    BIGINT,
    area                        VARCHAR,
    fk_tgrado                   BIGINT,
    grado                       VARCHAR,
    fk_tfuncionario             BIGINT,
    docente                     VARCHAR,
    fk_tlv_calculo_definitiva   BIGINT,
    calculo_definitiva          VARCHAR,
    fk_referente_curricular     BIGINT,
    referente_curricular        VARCHAR,
    -- FALSE solo cuando la unidad TIENE un FK_REFERENTE_CURRICULAR guardado
    -- que ya no resuelve (lo desactivaron en el catalogo). Sirve para no
    -- confundir "esta unidad no se acoge a ningun referente" (FK NULL, esto
    -- TRUE) con "se acoge a uno que ya no existe" (FK puesta, esto FALSE),
    -- que para el front son dos situaciones distintas: la segunda hay que
    -- avisarla, porque la unidad no va a poder ofrecer enunciados.
    referente_vigente           BOOLEAN,
    total_actividades           BIGINT,
    total_objetivos             BIGINT,
    total_contenidos            BIGINT,
    fecha_inicio                DATE,
    fecha_fin                   DATE,
    -- Estado DERIVADO de la unidad (fn_unidad_estado, V224): agrega el de sus
    -- actividades con la cascada de prioridades de negocio -- una vencida
    -- manda, si no una pendiente, si todas finalizadas FINALIZADA, si no
    -- EN_EVALUACION. Son los MISMOS cuatro valores del estado de actividad.
    estado                      VARCHAR,
    active                      BOOLEAN,
    -- Navegacion del paginado por dia (flechas < >), con la misma semantica
    -- que en fn_actividad_listar: el dia ocupado mas cercano a cada lado bajo
    -- los mismos filtros, saltando los vacios. NULL si no se pidio dia o si
    -- no hay mas dias por ese lado.
    dia                         DATE,
    dia_anterior                DATE,
    dia_siguiente               DATE,
    -- V488: instrumento de evaluación FIJADO en la unidad (rótulo del panel,
    -- "Actividades en {instrumento}") -- distinto del instrumento de cada
    -- actividad (TACTIVIDAD.FK_TLV_INSTRUMENTO_EVALUACION). NULL en unidades
    -- que no lo fijaron (incluidas todas las anteriores a V488).
    fk_tlv_instrumento_evaluacion BIGINT,
    instrumento_evaluacion       VARCHAR,
    total_count                 BIGINT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_sedes_lectura BIGINT[];
    v_alcance_total BOOLEAN;
    v_solo_propias  BOOLEAN;
    v_fk_tfuncionario BIGINT;
    v_key VARCHAR;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    -- Un docente puro NO administra su sede: dentro de ella solo le tocan SUS
    -- unidades. Sin esto, el alcance territorial de su rol le mostraba las de
    -- los demas docentes de la sede. Rector/coordinador no se tocan.
    v_solo_propias    := academico_test.fn_usuario_es_docente_puro(p_pk_usuario_solicitante);
    v_fk_tfuncionario := academico_test.fn_funcionario_actual(p_pk_usuario_solicitante);

    v_alcance_total := COALESCE(
        academico_test.fn_usuario_categoria_rol_nivel(p_pk_usuario_solicitante), 99) <= 1;
    v_sedes_lectura := ARRAY(
        SELECT sl.sede_id
          FROM academico_test.fn_usuario_sedes_lectura(p_pk_usuario_solicitante) sl);

    v_key := LOWER(TRIM(COALESCE(p_orden_por, 'nombre')));
    IF v_key NOT IN ('nombre', 'asignatura', 'grado') THEN
        v_key := 'nombre';
    END IF;

    RETURN QUERY
    WITH universo AS (
        SELECT u.PK_TUNIDAD AS pk,
               u.NOMBRE      AS nom,
               basig.NOMBRE  AS asig_nom,
               bgr.NOMBRE    AS gr_nom
          FROM academico_test.TUNIDAD u
          JOIN academico_test.TASIGNATURA basig ON basig.PK_TASIGNATURA = u.FK_TASIGNATURA
          JOIN academico_test.TGRADO bgr        ON bgr.PK_TGRADO = u.FK_TGRADO
         WHERE (p_incluir_inactivos OR u.ACTIVE = TRUE)
           AND EXISTS (SELECT 1 FROM academico_test.TPERIODO_ACADEMICO pa_sc
                        JOIN academico_test.TSEDE s_sc
                          ON s_sc.PK_TSEDE = pa_sc.FK_TSEDE AND s_sc.ACTIVE = TRUE
                       WHERE pa_sc.PK_TPERIODO_ACADEMICO = bgr.FK_TPERIODO_ACADEMICO
                         AND (v_alcance_total
                              OR pa_sc.FK_TSEDE = ANY(v_sedes_lectura)))
           AND (p_search IS NULL OR
                (COALESCE(u.NOMBRE,'') || ' ' || COALESCE(u.DESCRIPCION,''))
                    ILIKE '%' || p_search || '%')
           AND (p_fk_tasignatura  IS NULL OR u.FK_TASIGNATURA = p_fk_tasignatura)
           AND (p_fk_tgrado       IS NULL OR u.FK_TGRADO = p_fk_tgrado)
           AND (p_fk_tfuncionario IS NULL OR u.FK_TFUNCIONARIO = p_fk_tfuncionario)
           AND (NOT v_solo_propias OR u.FK_TFUNCIONARIO = v_fk_tfuncionario)
    ),
    del_dia AS (
        SELECT un.*
          FROM universo un
         WHERE p_dia IS NULL
            OR EXISTS (SELECT 1
                         FROM academico_test.TACTIVIDAD a_d
                        WHERE a_d.FK_TUNIDAD = un.pk
                          AND a_d.ACTIVE = TRUE
                          AND (a_d.FECHA_INICIO IS NOT NULL OR a_d.FECHA_CIERRE IS NOT NULL)
                          AND (a_d.FECHA_INICIO IS NULL OR a_d.FECHA_INICIO <= p_dia)
                          AND (a_d.FECHA_CIERRE IS NULL OR a_d.FECHA_CIERRE >= p_dia))
    ),
    nav AS (
        SELECT MAX(CASE WHEN a_n.FECHA_CIERRE IS NOT NULL AND a_n.FECHA_CIERRE < p_dia THEN a_n.FECHA_CIERRE
                        WHEN a_n.FECHA_INICIO IS NOT NULL AND a_n.FECHA_INICIO < p_dia THEN p_dia - 1
                   END) AS anterior,
               MIN(CASE WHEN a_n.FECHA_INICIO IS NOT NULL AND a_n.FECHA_INICIO > p_dia THEN a_n.FECHA_INICIO
                        WHEN a_n.FECHA_CIERRE IS NOT NULL AND a_n.FECHA_CIERRE > p_dia THEN p_dia + 1
                   END) AS siguiente
          FROM universo un
          JOIN academico_test.TACTIVIDAD a_n
                ON a_n.FK_TUNIDAD = un.pk AND a_n.ACTIVE = TRUE
         WHERE p_dia IS NOT NULL
        HAVING p_dia IS NOT NULL
    ),
    base AS (
        SELECT d.pk,
               COUNT(*) OVER() AS total
          FROM del_dia d
         ORDER BY
           CASE WHEN     p_orden_asc AND v_key = 'nombre'     THEN d.nom      END ASC  NULLS LAST,
           CASE WHEN NOT p_orden_asc AND v_key = 'nombre'     THEN d.nom      END DESC NULLS LAST,
           CASE WHEN     p_orden_asc AND v_key = 'asignatura' THEN d.asig_nom END ASC  NULLS LAST,
           CASE WHEN NOT p_orden_asc AND v_key = 'asignatura' THEN d.asig_nom END DESC NULLS LAST,
           CASE WHEN     p_orden_asc AND v_key = 'grado'      THEN d.gr_nom   END ASC  NULLS LAST,
           CASE WHEN NOT p_orden_asc AND v_key = 'grado'      THEN d.gr_nom   END DESC NULLS LAST,
           d.pk
         LIMIT CASE WHEN p_limite IS NULL THEN NULL ELSE GREATEST(p_limite, 1) END
        OFFSET GREATEST(COALESCE(p_offset, 0), 0)
    )
    SELECT u.PK_TUNIDAD,
           u.NOMBRE,
           u.DESCRIPCION,
           u.FK_TASIGNATURA,
           asig.NOMBRE,
           asig.FK_TAREA,
           ar.NOMBRE,
           u.FK_TGRADO,
           gr.NOMBRE,
           u.FK_TFUNCIONARIO,
           NULLIF(TRIM(CONCAT_WS(' ', us.PRIMER_NOMBRE, us.SEGUNDO_NOMBRE, us.PRIMER_APELLIDO, us.SEGUNDO_APELLIDO)), '')::VARCHAR,
           u.FK_TLV_CALCULO_DEFINITIVA,
           lvc.NOMBRE,
           u.FK_REFERENTE_CURRICULAR,
           rc.NOMBRE,
           (u.FK_REFERENTE_CURRICULAR IS NULL OR rc.PK_REFERENTE_CURRICULAR IS NOT NULL),
           agg.total_actividades,
           (SELECT COUNT(*) FROM academico_test.TUNIDAD_OBJETIVO o  WHERE o.FK_TUNIDAD = u.PK_TUNIDAD AND o.ACTIVE = TRUE),
           (SELECT COUNT(*) FROM academico_test.TUNIDAD_CONTENIDO c WHERE c.FK_TUNIDAD = u.PK_TUNIDAD AND c.ACTIVE = TRUE),
           agg.fecha_inicio,
           agg.fecha_fin,
           academico_test.fn_unidad_estado(u.PK_TUNIDAD, CURRENT_DATE, p_dias_gracia),
           u.ACTIVE,
           p_dia,
           n.anterior,
           n.siguiente,
           u.FK_TLV_INSTRUMENTO_EVALUACION,
           lvi.NOMBRE,
           COALESCE(b.total, 0)
      FROM base b
      FULL OUTER JOIN nav n ON TRUE
      LEFT JOIN academico_test.TUNIDAD u         ON u.PK_TUNIDAD = b.pk
      LEFT JOIN academico_test.TASIGNATURA asig  ON asig.PK_TASIGNATURA = u.FK_TASIGNATURA
      LEFT JOIN academico_test.TAREA ar          ON ar.PK_TAREA = asig.FK_TAREA
      LEFT JOIN academico_test.TGRADO gr         ON gr.PK_TGRADO = u.FK_TGRADO
      LEFT JOIN academico_test.TFUNCIONARIO fu   ON fu.PK_TFUNCIONARIO = u.FK_TFUNCIONARIO
      LEFT JOIN academico_test.TUSUARIO us       ON us.PK_TUSUARIO = fu.FK_TUSUARIO
      LEFT JOIN academico_test.TLISTA_VALOR lvc  ON lvc.PK_LISTA_VALOR = u.FK_TLV_CALCULO_DEFINITIVA
      LEFT JOIN academico_test.TLISTA_VALOR lvi  ON lvi.PK_LISTA_VALOR = u.FK_TLV_INSTRUMENTO_EVALUACION
      LEFT JOIN academico_test.TREFERENTE_CURRICULAR rc ON rc.PK_REFERENTE_CURRICULAR = u.FK_REFERENTE_CURRICULAR
                                                      AND rc.ACTIVE = TRUE
                                                      AND rc.ESTADO = 'A'
      LEFT JOIN LATERAL (
          SELECT COUNT(*)::BIGINT      AS total_actividades,
                 MIN(a.FECHA_INICIO)   AS fecha_inicio,
                 MAX(a.FECHA_CIERRE)   AS fecha_fin
            FROM academico_test.TACTIVIDAD a
           WHERE a.FK_TUNIDAD = u.PK_TUNIDAD AND a.ACTIVE = TRUE
      ) agg ON TRUE
     ORDER BY
       CASE WHEN     p_orden_asc AND v_key = 'nombre'     THEN u.NOMBRE    END ASC  NULLS LAST,
       CASE WHEN NOT p_orden_asc AND v_key = 'nombre'     THEN u.NOMBRE    END DESC NULLS LAST,
       CASE WHEN     p_orden_asc AND v_key = 'asignatura' THEN asig.NOMBRE END ASC  NULLS LAST,
       CASE WHEN NOT p_orden_asc AND v_key = 'asignatura' THEN asig.NOMBRE END DESC NULLS LAST,
       CASE WHEN     p_orden_asc AND v_key = 'grado'      THEN gr.NOMBRE   END ASC  NULLS LAST,
       CASE WHEN NOT p_orden_asc AND v_key = 'grado'      THEN gr.NOMBRE   END DESC NULLS LAST,
       u.PK_TUNIDAD;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_listar(BIGINT, VARCHAR, BIGINT, BIGINT, BIGINT, BOOLEAN, VARCHAR, BOOLEAN, INT, INT, DATE, INT)
    IS 'ALCANCE: la sede acota QUE se ve y, ademas, a un docente puro se le acota a SUS unidades. El referente curricular se resuelve SOLO si esta ACTIVE. Devuelve estado: el estado DERIVADO de la unidad (fn_unidad_estado, V224). p_dia es el PAGINADO POR DIA ACTIVO. Pagina de TUNIDAD con filtros y orden (whitelist nombre|asignatura|grado). V488: agrega fk_tlv_instrumento_evaluacion / instrumento_evaluacion -- el instrumento de evaluacion FIJADO en la unidad (TUNIDAD.FK_TLV_INSTRUMENTO_EVALUACION, catalogo INSTRUMENTO_EVALUACION), NULL en unidades que no lo fijaron (todas las anteriores a V488, sin backfill). Es el rotulo del panel ("Actividades en {instrumento}"), distinto del instrumento de cada actividad. total_count via COUNT(*) OVER(). Gate VER. V216, editada en V488.';

-- ---------------------------------------------------------------------------
-- 5. fn_unidad_buscar_por_pk — idem, para el detalle.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_unidad_buscar_por_pk(BIGINT, BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_buscar_por_pk(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tunidad               BIGINT
)
RETURNS TABLE (
    pk_tunidad                  BIGINT,
    nombre                      VARCHAR,
    descripcion                 VARCHAR,
    fk_tasignatura              BIGINT,
    asignatura                  VARCHAR,
    fk_tarea                    BIGINT,
    area                        VARCHAR,
    fk_tgrado                   BIGINT,
    grado                       VARCHAR,
    fk_tfuncionario             BIGINT,
    docente                     VARCHAR,
    fk_tlv_calculo_definitiva   BIGINT,
    calculo_definitiva          VARCHAR,
    fk_referente_curricular     BIGINT,
    referente_curricular        VARCHAR,
    referente_vigente           BOOLEAN,
    total_actividades           BIGINT,
    fecha_inicio                DATE,
    fecha_fin                   DATE,
    objetivos                   JSONB,
    contenidos                  JSONB,
    campos_disponibles          JSONB,
    estado                      VARCHAR,
    active                      BOOLEAN,
    -- V488: ver el comentario homólogo en fn_unidad_listar.
    fk_tlv_instrumento_evaluacion BIGINT,
    instrumento_evaluacion       VARCHAR
)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', NULL, NULL, p_pk_tunidad
    );

    RETURN QUERY
    SELECT u.PK_TUNIDAD,
           u.NOMBRE,
           u.DESCRIPCION,
           u.FK_TASIGNATURA,
           asig.NOMBRE,
           asig.FK_TAREA,
           ar.NOMBRE,
           u.FK_TGRADO,
           gr.NOMBRE,
           u.FK_TFUNCIONARIO,
           NULLIF(TRIM(CONCAT_WS(' ', us.PRIMER_NOMBRE, us.SEGUNDO_NOMBRE, us.PRIMER_APELLIDO, us.SEGUNDO_APELLIDO)), '')::VARCHAR,
           u.FK_TLV_CALCULO_DEFINITIVA,
           lvc.NOMBRE,
           u.FK_REFERENTE_CURRICULAR,
           rc.NOMBRE,
           (u.FK_REFERENTE_CURRICULAR IS NULL OR rc.PK_REFERENTE_CURRICULAR IS NOT NULL),
           (SELECT COUNT(*) FROM academico_test.TACTIVIDAD a WHERE a.FK_TUNIDAD = u.PK_TUNIDAD AND a.ACTIVE = TRUE),
           (SELECT MIN(a.FECHA_INICIO) FROM academico_test.TACTIVIDAD a WHERE a.FK_TUNIDAD = u.PK_TUNIDAD AND a.ACTIVE = TRUE),
           (SELECT MAX(a.FECHA_CIERRE) FROM academico_test.TACTIVIDAD a WHERE a.FK_TUNIDAD = u.PK_TUNIDAD AND a.ACTIVE = TRUE),
           COALESCE((
               SELECT jsonb_agg(jsonb_build_object('pk', o.PK_TUNIDAD_OBJETIVO, 'orden', o.ORDEN, 'descripcion', o.DESCRIPCION)
                                ORDER BY o.ORDEN)
                 FROM academico_test.TUNIDAD_OBJETIVO o
                WHERE o.FK_TUNIDAD = u.PK_TUNIDAD AND o.ACTIVE = TRUE
           ), '[]'::jsonb),
           COALESCE((
               SELECT jsonb_agg(jsonb_build_object('pk', c.PK_TUNIDAD_CONTENIDO, 'orden', c.ORDEN, 'descripcion', c.DESCRIPCION)
                                ORDER BY c.ORDEN)
                 FROM academico_test.TUNIDAD_CONTENIDO c
                WHERE c.FK_TUNIDAD = u.PK_TUNIDAD AND c.ACTIVE = TRUE
           ), '[]'::jsonb),
           academico_test.fn_unidad_campos_disponibles(p_pk_usuario_solicitante, u.PK_TUNIDAD),
           academico_test.fn_unidad_estado(u.PK_TUNIDAD, CURRENT_DATE),
           u.ACTIVE,
           u.FK_TLV_INSTRUMENTO_EVALUACION,
           lvi.NOMBRE
      FROM academico_test.TUNIDAD u
      JOIN academico_test.TASIGNATURA asig       ON asig.PK_TASIGNATURA = u.FK_TASIGNATURA
      LEFT JOIN academico_test.TAREA ar          ON ar.PK_TAREA = asig.FK_TAREA
      JOIN academico_test.TGRADO gr              ON gr.PK_TGRADO = u.FK_TGRADO
      LEFT JOIN academico_test.TFUNCIONARIO fu   ON fu.PK_TFUNCIONARIO = u.FK_TFUNCIONARIO
      LEFT JOIN academico_test.TUSUARIO us       ON us.PK_TUSUARIO = fu.FK_TUSUARIO
      LEFT JOIN academico_test.TLISTA_VALOR lvc  ON lvc.PK_LISTA_VALOR = u.FK_TLV_CALCULO_DEFINITIVA
      LEFT JOIN academico_test.TLISTA_VALOR lvi  ON lvi.PK_LISTA_VALOR = u.FK_TLV_INSTRUMENTO_EVALUACION
      LEFT JOIN academico_test.TREFERENTE_CURRICULAR rc ON rc.PK_REFERENTE_CURRICULAR = u.FK_REFERENTE_CURRICULAR
                                                      AND rc.ACTIVE = TRUE
                                                      AND rc.ESTADO = 'A'
     WHERE u.PK_TUNIDAD = p_pk_tunidad;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_buscar_por_pk(BIGINT, BIGINT)
    IS 'Detalle de una TUNIDAD (pestaña "Informacion general"): escalares + nombres resueltos, total de actividades activas, Inicio/Fin DERIVADOS, objetivos/contenidos JSONB, campos_disponibles y estado derivado. V488: agrega fk_tlv_instrumento_evaluacion / instrumento_evaluacion -- ver el comentario homologo en fn_unidad_listar. SETOF 0 o 1 fila (incluye inactivas). Gate VER.';

-- ---------------------------------------------------------------------------
-- 6. Endpoints registrados (public.query, V245) — POST /planeador/unidades y
--    PUT /planeador/unidades/:ID llaman a fn_unidad_crear/fn_unidad_actualizar
--    con una lista POSICIONAL de `CAST(:BODY.X AS TIPO)` escrita literal en
--    `query.query` -- agregar un parametro nuevo a la funcion (aunque tenga
--    DEFAULT) NO lo hace llegar solo: el texto SQL ya registrado sigue
--    mandando los mismos N argumentos de siempre, así que el instrumento
--    nunca viajaría desde el body sin tocar esto. Un INSERT nuevo con
--    ON CONFLICT DO NOTHING (el patrón que usa V245 para crear la fila) NO
--    sirve aquí: la fila para (microservice_id, path_template, http_method)
--    YA EXISTE desde V245, así que ON CONFLICT DO NOTHING la dejaría
--    intacta -- hace falta un UPDATE explícito de `query`/`param_types`.
--    GET /planeador/unidades y GET /planeador/unidades/:ID NO necesitan
--    tocarse: su `query.query` es `SELECT * FROM fn_x(...)` (columnas por
--    `*`, no una lista explícita), así que las dos columnas nuevas del
--    RETURNS TABLE ya viajan solas.
-- ---------------------------------------------------------------------------
UPDATE public.query
   SET query = 'SELECT * FROM academico_test.fn_unidad_crear(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.NOMBRE AS VARCHAR),
    CAST(:BODY.FK_TASIGNATURA AS BIGINT),
    CAST(:BODY.FK_TGRADO AS BIGINT),
    CAST(:BODY.FK_TFUNCIONARIO AS BIGINT),
    CAST(:BODY.FK_TLV_CALCULO_DEFINITIVA AS BIGINT),
    CAST(:BODY.DESCRIPCION AS VARCHAR),
    CAST(:BODY.FK_REFERENTE_CURRICULAR AS BIGINT),
    CAST(:BODY.OBJETIVOS AS VARCHAR[]),
    CAST(:BODY.CONTENIDOS AS VARCHAR[]),
    CAST(:BODY.ENUNCIADOS AS BIGINT[]),
    CAST(:BODY.PONDERACION AS NUMERIC),
    CAST(:BODY.FK_TLV_INSTRUMENTO_EVALUACION AS BIGINT)
);',
       param_types = param_types || '{"BODY.FK_TLV_INSTRUMENTO_EVALUACION": "BIGINT"}'::jsonb,
       detail = detail || ' V488: agrega BODY.FK_TLV_INSTRUMENTO_EVALUACION (opcional) -- instrumento de evaluacion de la UNIDAD, catalogo INSTRUMENTO_EVALUACION.'
 WHERE path_template = '/planeador/unidades'
   AND http_method    = 'POST'
   AND microservice_id = (SELECT id_microservice FROM public.microservice WHERE serviceid = 'eval-col');

UPDATE public.query
   SET query = 'SELECT * FROM academico_test.fn_unidad_actualizar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.NOMBRE AS VARCHAR),
    CAST(:BODY.DESCRIPCION AS VARCHAR),
    CAST(:BODY.FK_TASIGNATURA AS BIGINT),
    CAST(:BODY.FK_TGRADO AS BIGINT),
    CAST(:BODY.FK_TFUNCIONARIO AS BIGINT),
    CAST(:BODY.FK_TLV_CALCULO_DEFINITIVA AS BIGINT),
    CAST(:BODY.FK_REFERENTE_CURRICULAR AS BIGINT),
    COALESCE(CAST(:BODY.LIMPIAR_REFERENTE AS BOOLEAN), FALSE),
    CAST(:BODY.OBJETIVOS AS VARCHAR[]),
    CAST(:BODY.CONTENIDOS AS VARCHAR[]),
    CAST(:BODY.PONDERACION AS NUMERIC),
    COALESCE(CAST(:BODY.LIMPIAR_PONDERACION AS BOOLEAN), FALSE),
    CAST(:BODY.FK_TLV_INSTRUMENTO_EVALUACION AS BIGINT)
);',
       param_types = param_types || '{"BODY.FK_TLV_INSTRUMENTO_EVALUACION": "BIGINT"}'::jsonb,
       detail = detail || ' V488: agrega BODY.FK_TLV_INSTRUMENTO_EVALUACION (opcional, PATCH -- NULL no toca) -- instrumento de evaluacion de la UNIDAD, catalogo INSTRUMENTO_EVALUACION.'
 WHERE path_template = '/planeador/unidades/:ID'
   AND http_method    = 'PUT'
   AND microservice_id = (SELECT id_microservice FROM public.microservice WHERE serviceid = 'eval-col');
