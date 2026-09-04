-- ===========================================================================
-- V244 — Planeador educativo: listado de actividades "huerfanas" (sin
-- unidad) para vincularlas de forma posterior (CU-86e311xxp).
--
-- CONTEXTO: desde V218 (esta rama) TACTIVIDAD.FK_TUNIDAD es OPCIONAL
-- (FK_TASIGNATURA vive directo en TACTIVIDAD, NOT NULL) -- una actividad
-- puede crearse "suelta" y vincularse a una unidad mas tarde. La vinculacion
-- YA EXISTE: fn_unidad_actividad_vincular (V223, en
-- V223__actividad_unidad_ponderacion.sql) recibe (usuario, pk_tactividad,
-- pk_tunidad, ponderacion) y hace exactamente "vincular de forma posterior a
-- una unidad existente" -- no se reimplementa aqui.
--
-- QUE FALTABA: el LISTADO de esas actividades huerfanas (FK_TUNIDAD IS NULL)
-- para que el docente las vea y decida cual vincular. fn_actividad_listar
-- (V224) YA acepta p_fk_tunidad, pero con la semantica "filtrar por ESA
-- unidad si viene informado, no filtrar si es NULL" -- no hay forma de pedir
-- "solo las que NO tienen unidad" sin cambiar esa semantica (romperia a
-- quien hoy llama sin ese parametro esperando "todas"). Se decidio NO tocar
-- fn_actividad_listar (opcion b del enunciado): una funcion dedicada,
-- liviana, reutilizando el MISMO patron CTE-base + COUNT(*) OVER() y el
-- MISMO indice trigram (idx_tactividad_busqueda_trgm, V224) que ya cubre
-- TITULO+DESCRIPCION -- no se crea ningun indice nuevo.
--
-- PONDERACION DE UNA HUERFANA: TACTIVIDAD.PONDERACION (V223) SIEMPRE es NULL
-- mientras la actividad no tenga unidad. No es una regla nueva de este
-- archivo: el UPDATE de fn_unidad_actividad_vincular es el UNICO lugar que
-- escribe PONDERACION con FK_TUNIDAD no nulo, y fn_unidad_actividad_
-- desvincular limpia ambas columnas juntas (FK_TUNIDAD y PONDERACION a
-- NULL) precisamente para que nunca quede un peso "huerfano". El trigger
-- tr_tactividad_ponderacion_unidad_check tampoco aplica: su chequeo del 100%
-- se salta completo si NEW.FK_TUNIDAD IS NULL. Por eso esta funcion NI
-- siquiera proyecta la columna: documentar es preferible a inventar un valor
-- que el modelo no soporta.
--
-- FIX EN fn_unidad_actividad_vincular (V223, CREATE OR REPLACE en este
-- archivo, misma firma -- patron ya usado en el repo para editar una funcion
-- de otra migracion de la misma rama sin reescribir el archivo viejo): NO
-- validaba que la actividad de destino no tuviera YA una unidad distinta
-- antes de "moverla" silenciosamente (dejaba huerfano el bucket de origen
-- sin que el llamador lo supiera y sin exigir confirmacion). Para el caso de
-- uso de esta pantalla (vincular una HUERFANA existente) eso es exactamente
-- lo esperado -- pero mover una actividad que YA tenia unidad de forma
-- silenciosa no lo es. Se agrega el parametro opcional
-- p_permitir_mover_de_unidad BOOLEAN DEFAULT FALSE: si la actividad ya tiene
-- FK_TUNIDAD distinto al destino y el llamador no confirmo explicitamente el
-- movimiento, se rechaza con 22023 con un mensaje que nombra la unidad
-- origen. Vincular una huerfana (FK_TUNIDAD IS NULL) sigue funcionando
-- exactamente igual que antes, sin tocar el parametro.
--
-- Depende de (orden de version de Flyway):
--   * V218 — TACTIVIDAD.FK_TUNIDAD nullable, FK_TASIGNATURA NOT NULL.
--   * V223 — TACTIVIDAD.PONDERACION, fn_unidad_actividad_vincular,
--            trigger tr_tactividad_ponderacion_unidad_check.
--   * V224 — fn_actividad_listar, idx_tactividad_busqueda_trgm,
--            idx_tactividad_asignatura_fechas.
--   * V216 — fn_assert_permiso_seccion('PLANEADOR', ...).
--
-- Estilo: V223/V224 (CTE-base + COUNT(*) OVER(), catalogos por VALOR nunca
-- por PK, COMMENT ON FUNCTION, 22023/23503/P0002).
-- ===========================================================================

SET search_path TO academico_test, public;

-- ---------------------------------------------------------------------------
-- 1. fn_unidad_actividad_vincular — fix: no mover de unidad sin confirmar.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_unidad_actividad_vincular(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad            BIGINT,
    p_pk_tunidad               BIGINT,
    p_ponderacion              NUMERIC DEFAULT NULL,
    p_permitir_mover_de_unidad BOOLEAN DEFAULT FALSE
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_act_active     BOOLEAN;
    v_fk_grupo       BIGINT;
    v_unidad_previa  BIGINT;
    v_unidad_active  BOOLEAN;
    v_modo           VARCHAR;
    v_suma           NUMERIC(9,2);
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'EDITAR'
    );

    SELECT ACTIVE, FK_TGRUPO, FK_TUNIDAD INTO v_act_active, v_fk_grupo, v_unidad_previa
      FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_pk_tactividad;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la actividad solicitada' USING ERRCODE = 'P0002';
    END IF;
    IF v_act_active = FALSE THEN
        RAISE EXCEPTION 'La actividad esta inactiva; no se puede vincular' USING ERRCODE = '22023';
    END IF;

    -- Fix V244: mover una actividad que YA tenia unidad requiere
    -- confirmacion explicita del llamador; vincular una huerfana
    -- (v_unidad_previa NULL) no se ve afectado por este chequeo.
    IF v_unidad_previa IS NOT NULL
       AND v_unidad_previa <> p_pk_tunidad
       AND NOT p_permitir_mover_de_unidad THEN
        RAISE EXCEPTION
          'La actividad ya esta vinculada a la unidad %; confirme p_permitir_mover_de_unidad=true para moverla a la unidad %',
          v_unidad_previa, p_pk_tunidad
          USING ERRCODE = '22023';
    END IF;

    SELECT ACTIVE INTO v_unidad_active
      FROM academico_test.TUNIDAD WHERE PK_TUNIDAD = p_pk_tunidad;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'FK_TUNIDAD (%) no existe', p_pk_tunidad USING ERRCODE = '23503';
    END IF;
    IF v_unidad_active = FALSE THEN
        RAISE EXCEPTION 'La unidad (%) esta inactiva', p_pk_tunidad USING ERRCODE = '22023';
    END IF;

    IF p_ponderacion IS NOT NULL AND (p_ponderacion < 0 OR p_ponderacion > 100) THEN
        RAISE EXCEPTION 'La ponderacion (%) debe estar entre 0 y 100', p_ponderacion USING ERRCODE = '22023';
    END IF;

    -- El metodo de calculo de la unidad manda si el % se captura a mano
    -- (Ponderar), no aplica (Promediar) o lo calcula el sistema (Sumatoria).
    v_modo := academico_test.fn_unidad_calculo_definitiva_modo(p_pk_tunidad);
    IF p_ponderacion IS NOT NULL AND v_modo = 'PROMEDIAR' THEN
        RAISE EXCEPTION 'La ponderacion no aplica: la unidad (%) promedia sus actividades', p_pk_tunidad
            USING ERRCODE = '22023';
    END IF;
    IF p_ponderacion IS NOT NULL AND v_modo = 'SUMATORIA' THEN
        RAISE EXCEPTION 'La ponderacion de la unidad (%) se autocalcula: es una unidad de Sumatoria, capture el puntaje de la actividad (NOTA_MAXIMA) en vez del porcentaje', p_pk_tunidad
            USING ERRCODE = '22023';
    END IF;

    -- Chequeo previo del 100% (error claro antes del trigger). En modo
    -- Sumatoria/Promediar no se llega aqui (p_ponderacion ya fue rechazada).
    IF p_ponderacion IS NOT NULL THEN
        v_suma := academico_test.fn_unidad_ponderacion_asignada(
                      p_pk_tunidad, v_fk_grupo, p_pk_tactividad);
        IF v_suma + p_ponderacion > 100 THEN
            RAISE EXCEPTION
              'La unidad % ya tiene % %% ponderado para el grupo %; % %% adicionales pasarian de 100',
              p_pk_tunidad, v_suma, v_fk_grupo, p_ponderacion
              USING ERRCODE = '23514';
        END IF;
    END IF;

    UPDATE academico_test.TACTIVIDAD
       SET FK_TUNIDAD   = p_pk_tunidad,
           -- En Promediar el % no aplica y en Sumatoria lo recalcula el
           -- sistema justo abajo: en ambos casos se limpia el valor heredado
           -- para no dejar un peso viejo del modo Ponderar.
           PONDERACION  = CASE WHEN v_modo IN ('PROMEDIAR', 'SUMATORIA') THEN NULL
                               ELSE COALESCE(p_ponderacion, PONDERACION) END,
           MODIFIED_BY  = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT  = CURRENT_TIMESTAMP
     WHERE PK_TACTIVIDAD = p_pk_tactividad;

    -- Sumatoria: reparto proporcional de NOTA_MAXIMA en el bucket destino y,
    -- si la actividad venia de otra unidad, tambien en el de origen.
    PERFORM academico_test.fn_unidad_ponderacion_recalcular_sumatoria(p_pk_tunidad, v_fk_grupo);
    IF v_unidad_previa IS NOT NULL AND v_unidad_previa <> p_pk_tunidad THEN
        PERFORM academico_test.fn_unidad_ponderacion_recalcular_sumatoria(v_unidad_previa, v_fk_grupo);
    END IF;

    RETURN p_pk_tactividad;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_actividad_vincular(BIGINT, BIGINT, BIGINT, NUMERIC, BOOLEAN)
    IS 'Vincula una actividad a una unidad (TACTIVIDAD.FK_TUNIDAD) y fija su PONDERACION (%) dentro de ella. p_ponderacion NULL = no cambiar el peso actual. Valida 0..100 y que la suma por (unidad, grupo de la actividad) no pase de 100 (mismo criterio que el trigger). Fix V244: si la actividad YA estaba vinculada a OTRA unidad, se rechaza (22023) salvo que p_permitir_mover_de_unidad=TRUE -- evita mover una actividad de unidad de forma silenciosa; vincular una huerfana (FK_TUNIDAD IS NULL) no requiere el flag. El metodo de calculo de la unidad (fn_unidad_calculo_definitiva_modo, V73) manda: con Promediar se RECHAZA p_ponderacion (22023, no aplica) y con Sumatoria tambien (el % se autocalcula a partir de NOTA_MAXIMA); en ambos casos la PONDERACION heredada se limpia y, en Sumatoria, se recalcula el bucket destino (y el de origen si la actividad venia de otra unidad) con fn_unidad_ponderacion_recalcular_sumatoria. Gate EDITAR sobre PLANEADOR. Retorna PK_TACTIVIDAD. V223, editada en V244.';

-- ---------------------------------------------------------------------------
-- 2. fn_actividad_huerfanas_listar — actividades sin unidad.
--
-- Mismo patron CTE-base + COUNT(*) OVER() de fn_actividad_listar (V224),
-- reutilizando idx_tactividad_busqueda_trgm (misma expresion exacta en el
-- WHERE) e idx_tactividad_asignatura_fechas (columna lider FK_TASIGNATURA);
-- no se crea ningun indice nuevo.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_huerfanas_listar(
    p_pk_usuario_solicitante   BIGINT,
    p_search                   VARCHAR DEFAULT NULL,
    p_fk_tasignatura           BIGINT  DEFAULT NULL,
    p_fk_tgrupo                BIGINT  DEFAULT NULL,
    p_fecha_desde              DATE    DEFAULT NULL,
    p_fecha_hasta              DATE    DEFAULT NULL,
    p_pagina                   INT     DEFAULT 1,
    p_tamano_pagina            INT     DEFAULT 20
)
RETURNS TABLE (
    pk_tactividad           BIGINT,
    titulo                  VARCHAR,
    fk_tlv_tipo_actividad   BIGINT,
    tipo_actividad          VARCHAR,
    fk_tasignatura          BIGINT,
    asignatura              VARCHAR,
    fk_tgrupo               BIGINT,
    grupo                   VARCHAR,
    fk_tgrado               BIGINT,
    grado                   VARCHAR,
    fecha_inicio            DATE,
    fecha_cierre            DATE,
    total_count             BIGINT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_limite INT;
    v_offset INT;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    v_limite := GREATEST(COALESCE(p_tamano_pagina, 20), 1);
    v_offset := (GREATEST(COALESCE(p_pagina, 1), 1) - 1) * v_limite;

    RETURN QUERY
    WITH base AS (
        SELECT a.PK_TACTIVIDAD AS pk,
               COUNT(*) OVER() AS total
          FROM academico_test.TACTIVIDAD a
         WHERE a.ACTIVE = TRUE
           AND a.FK_TUNIDAD IS NULL
           AND (p_fk_tasignatura IS NULL OR a.FK_TASIGNATURA = p_fk_tasignatura)
           AND (p_fk_tgrupo      IS NULL OR a.FK_TGRUPO = p_fk_tgrupo)
           AND (p_fecha_desde IS NULL OR COALESCE(a.FECHA_CIERRE, a.FECHA_INICIO) >= p_fecha_desde)
           AND (p_fecha_hasta IS NULL OR COALESCE(a.FECHA_INICIO, a.FECHA_CIERRE) <= p_fecha_hasta)
           -- Misma expresion que idx_tactividad_busqueda_trgm (V224).
           AND (p_search IS NULL OR
                (COALESCE(a.TITULO,'') || ' ' || COALESCE(a.DESCRIPCION,''))
                    ILIKE '%' || p_search || '%')
         ORDER BY a.FECHA_INICIO NULLS LAST, a.PK_TACTIVIDAD
         LIMIT v_limite
        OFFSET v_offset
    )
    SELECT a.PK_TACTIVIDAD,
           a.TITULO,
           a.FK_TLV_TIPO_ACTIVIDAD,
           lvt.NOMBRE,
           a.FK_TASIGNATURA,
           asig.NOMBRE,
           a.FK_TGRUPO,
           g.NOMBRE,
           g.FK_TGRADO,
           gr.NOMBRE,
           a.FECHA_INICIO,
           a.FECHA_CIERRE,
           b.total
      FROM base b
      JOIN academico_test.TACTIVIDAD a          ON a.PK_TACTIVIDAD = b.pk
      JOIN academico_test.TASIGNATURA asig      ON asig.PK_TASIGNATURA = a.FK_TASIGNATURA
      LEFT JOIN academico_test.TGRUPO g         ON g.PK_TGRUPO = a.FK_TGRUPO
      LEFT JOIN academico_test.TGRADO gr        ON gr.PK_TGRADO = g.FK_TGRADO
      LEFT JOIN academico_test.TLISTA_VALOR lvt ON lvt.PK_LISTA_VALOR = a.FK_TLV_TIPO_ACTIVIDAD
     ORDER BY a.FECHA_INICIO NULLS LAST, a.PK_TACTIVIDAD;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_huerfanas_listar(BIGINT, VARCHAR, BIGINT, BIGINT, DATE, DATE, INT, INT)
    IS 'Actividades sin unidad (TACTIVIDAD.FK_TUNIDAD IS NULL, ACTIVE) para la pantalla de vinculacion posterior: filtra por asignatura, grupo y ventana de fechas (mismos criterios que fn_actividad_listar, V224), p_search hace ILIKE sobre TITULO+DESCRIPCION con la misma expresion de idx_tactividad_busqueda_trgm (V224, no se crea indice nuevo). No proyecta PONDERACION: una huerfana siempre la tiene en NULL (solo fn_unidad_actividad_vincular la fija al asignar unidad; fn_unidad_actividad_desvincular la limpia junto con FK_TUNIDAD), documentado en vez de inventar un valor. Para vincular una fila del resultado, usar fn_unidad_actividad_vincular (V223/V244). Paginado con p_pagina/p_tamano_pagina, total_count via COUNT(*) OVER() sobre el mismo patron CTE-base de fn_actividad_listar. Gate VER sobre PLANEADOR. V244.';
