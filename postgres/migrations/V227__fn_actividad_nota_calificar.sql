-- ===========================================================================
-- V227 — Planeador educativo: motor de calculo de notas de actividad, segun
-- el instrumento de evaluacion ya definido en V226 (RUBRICA / LISTA_COTEJO /
-- ESCALA_VALORACION / OTRO) (CU-86e311xxp — G. Academico Back Planeador
-- educativo).
--
-- Complementa V226 (definicion del instrumento). Alli se define la
-- ESTRUCTURA (criterios/niveles, items, escala); aqui se CAPTURA la
-- calificacion de un estudiante contra esa estructura y se calcula el %
-- final que se guarda en TACTIVIDAD_NOTA.CALIFICACION.
--
-- Modulos:
--   (1) DDL   — FK_TACTIVIDAD_RUBRICA_NIVEL en TACTIVIDAD_RUBRICA_EVALUACION
--               y FK_TACTIVIDAD_ESCALA_NIVEL en TACTIVIDAD_ESCALA_EVALUACION
--               (ver nota "Tablas de captura" abajo).
--   (2) Helper — fn_actividad_nota_get_or_create (get-or-create de la fila
--               TACTIVIDAD_NOTA por FK_TACTIVIDAD_ESTUDIANTE).
--   (3) Calculo por instrumento — fn_actividad_nota_calificar_rubrica,
--               _cotejo, _escala, _otro.
--   (4) Fachada — fn_actividad_nota_calificar (despacha segun el
--               instrumento de la actividad) y fn_actividad_nota_obtener
--               (lectura).
--
-- -------------------------------------------------------------------------
-- TABLAS DE CAPTURA — se REUTILIZAN, no se crean nuevas.
--
-- V22 ya trae TACTIVIDAD_RUBRICA_EVALUACION, TACTIVIDAD_COTEJO_EVALUACION y
-- TACTIVIDAD_ESCALA_EVALUACION (una fila por criterio/item/escala x
-- TACTIVIDAD_ESTUDIANTE, con UNIQUE que impide duplicados), pensadas
-- exactamente para esto — no hay que inventar tablas nuevas. Se les hacen
-- 2 ajustes minimos via ALTER (las tres tablas estan vacias en todos los
-- ambientes: ningun fn_* las escribia hasta esta migracion):
--
--   * TACTIVIDAD_RUBRICA_EVALUACION solo guardaba la PONDERACION del nivel
--     elegido, sin trazabilidad a CUAL nivel fue (la spec de negocio pide
--     poder saber que nivel selecciono el docente, no solo su peso). Se
--     agrega FK_TACTIVIDAD_RUBRICA_NIVEL (obligatoria en la practica: la
--     exige fn_actividad_nota_calificar_rubrica) y PONDERACION se sigue
--     llenando como snapshot del peso del nivel al momento de calificar
--     (igual que ya hacia la tabla; queda igual si el nivel cambia despues).
--
--   * TACTIVIDAD_ESCALA_EVALUACION mezcla NUMERICA (VALOR = el numero
--     digitado, PONDERACION NULL) y CUALITATIVA (un nivel elegido) en la
--     misma fila, pero tampoco tenia FK al nivel. Se agrega
--     FK_TACTIVIDAD_ESCALA_NIVEL (NULL en NUMERICA, obligatoria en
--     CUALITATIVA). En CUALITATIVA, VALOR se llena con la PONDERACION del
--     nivel elegido (para satisfacer el NOT NULL existente de VALOR de forma
--     consistente: "el valor que califica al estudiante es el peso del
--     nivel"), y PONDERACION queda igual como snapshot del peso.
--
--   * TACTIVIDAD_COTEJO_EVALUACION YA calza perfecto tal cual (CUMPLIDO
--     CHAR(1) S/N, UNIQUE(item, estudiante)): no requiere ALTER. La opcion
--     de "1 fila por item marcado, cumplido implicito" se descarto a favor
--     de "1 fila por item con bandera S/N explicita" porque asi ya la trae
--     V22 y permite distinguir "no marcado todavia" (sin fila) de "marcado
--     como NO cumplido" (fila con CUMPLIDO='N') sin ambiguedad.
--
-- -------------------------------------------------------------------------
-- REGLA DE PORCENTAJE — mismo espiritu que V96
-- (fn_criterio_eval_actualizar / fn_criterio_eval_obtener): el resultado se
-- guarda SIEMPRE como porcentaje (0-100) en TACTIVIDAD_NOTA.CALIFICACION,
-- nunca en la escala visual del periodo/asignatura. V96 convierte en
-- ESCRITURA porque el front le manda la nota ya en la escala del formato;
-- aqui el front no manda una "nota en escala" sino la seleccion cruda
-- (nivel/items/valor), asi que el % se CALCULA aqui mismo a partir de esa
-- seleccion (no hay conversion de formato que hacer en escritura).
--
-- HOMOLOGACION EN LECTURA — fuera de alcance. V96 homologa en lectura
-- contra TASIGNATURA_PLAN.FK_TLV_FORMATO_CALIFICACION_ACT/TESCALA_VALORACION
-- para notas de PERIODO. Para actividades existe una columna analoga
-- (TASIGNATURA_PLAN.FK_TLV_FORMATO_CALIFICACION_ACT), pero resolver la fila
-- de TASIGNATURA_PLAN vigente para una TACTIVIDAD (que plan/periodo aplica)
-- no esta confirmado con negocio y se sale del alcance de esta tarea; se
-- documenta aqui en vez de inventar el join. fn_actividad_nota_obtener
-- retorna el % crudo — homologarlo a la escala visual del periodo es
-- responsabilidad de la capa de lectura/reporte existente.
--
-- ASISTENCIA — fuera de alcance. La regla de negocio de "no calificar sin
-- asistencia registrada" depende de TASISTENCIA, que vive en la rama
-- feature/CU-86e32gvpp-G-Academ-Back-Asistencias (no mergeada aqui;
-- confirmado con git ls-tree). No se agrega ningun JOIN/referencia a esa
-- tabla; no se bloquea la calificacion por este motivo todavia. Mismo
-- criterio que V137 con "adaptacion curricular"/"seguimiento".
--
-- -------------------------------------------------------------------------
-- Depende de (orden de version de Flyway):
--   * V22  — TACTIVIDAD_ESTUDIANTE, TACTIVIDAD_NOTA, TACTIVIDAD_RUBRICA_*,
--            TACTIVIDAD_COTEJO_*, TACTIVIDAD_ESCALA_*.
--   * V224 — fn_actividad_lv_assert, menu 'PLANEADOR'; V29/V185 —
--            fn_assert_permiso_seccion.
--   * V226 — fn_actividad_instrumento_assert, TIPO_ESCALA, ETIQUETA en
--            niveles.
--
-- Estilo: V226 (gate, 22023/23503/P0002, JSONB entrada/salida, fachada por
-- instrumento) y V224 (get-or-create 1:1 tipo fn_actividad_recuperacion_
-- configurar).
-- ===========================================================================

SET search_path TO academico_test, public;

-- ===========================================================================
-- (1) DDL — trazabilidad al nivel elegido (ver nota "Tablas de captura").
-- ===========================================================================

ALTER TABLE TACTIVIDAD_RUBRICA_EVALUACION
  ADD COLUMN IF NOT EXISTS FK_TACTIVIDAD_RUBRICA_NIVEL BIGINT;

ALTER TABLE TACTIVIDAD_RUBRICA_EVALUACION DROP CONSTRAINT IF EXISTS FK_TAC_RUBRICA_EVAL_3;
ALTER TABLE TACTIVIDAD_RUBRICA_EVALUACION ADD CONSTRAINT FK_TAC_RUBRICA_EVAL_3
  FOREIGN KEY (FK_TACTIVIDAD_RUBRICA_NIVEL) REFERENCES TACTIVIDAD_RUBRICA_NIVEL (PK_TACTIVIDAD_RUBRICA_NIVEL) ON DELETE CASCADE;

CREATE INDEX IF NOT EXISTS IDX_TAC_RUBRICA_EVAL_3 ON TACTIVIDAD_RUBRICA_EVALUACION (FK_TACTIVIDAD_RUBRICA_NIVEL);

COMMENT ON COLUMN TACTIVIDAD_RUBRICA_EVALUACION.FK_TACTIVIDAD_RUBRICA_NIVEL IS
  'Nivel de desempeno seleccionado por el docente para este criterio/estudiante. Obligatoria en la practica (la exige fn_actividad_nota_calificar_rubrica); nullable en DDL para no romper si la tabla ya tuviera filas. PONDERACION queda como snapshot del peso del nivel al momento de calificar. V227.';

ALTER TABLE TACTIVIDAD_ESCALA_EVALUACION
  ADD COLUMN IF NOT EXISTS FK_TACTIVIDAD_ESCALA_NIVEL BIGINT;

ALTER TABLE TACTIVIDAD_ESCALA_EVALUACION DROP CONSTRAINT IF EXISTS FK_TAC_ESCALA_EVAL_3;
ALTER TABLE TACTIVIDAD_ESCALA_EVALUACION ADD CONSTRAINT FK_TAC_ESCALA_EVAL_3
  FOREIGN KEY (FK_TACTIVIDAD_ESCALA_NIVEL) REFERENCES TACTIVIDAD_ESCALA_NIVEL (PK_TACTIVIDAD_ESCALA_NIVEL) ON DELETE CASCADE;

CREATE INDEX IF NOT EXISTS IDX_TAC_ESCALA_EVAL_3 ON TACTIVIDAD_ESCALA_EVALUACION (FK_TACTIVIDAD_ESCALA_NIVEL);

COMMENT ON COLUMN TACTIVIDAD_ESCALA_EVALUACION.FK_TACTIVIDAD_ESCALA_NIVEL IS
  'Nivel seleccionado por el docente cuando la escala es CUALITATIVA (NULL en escala NUMERICA). En CUALITATIVA, VALOR se llena con la PONDERACION del nivel elegido y PONDERACION queda como snapshot del peso. V227.';

-- ===========================================================================
-- (2) HELPER — get-or-create de la fila de nota (1:1 por TACTIVIDAD_ESTUDIANTE).
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_get_or_create(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad_estudiante BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk BIGINT;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TACTIVIDAD_ESTUDIANTE
         WHERE PK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se encontro la asignacion actividad-estudiante solicitada' USING ERRCODE = 'P0002';
    END IF;

    SELECT PK_TACTIVIDAD_NOTA INTO v_pk
      FROM academico_test.TACTIVIDAD_NOTA
     WHERE FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante;

    IF v_pk IS NULL THEN
        INSERT INTO academico_test.TACTIVIDAD_NOTA (
            FK_TACTIVIDAD_ESTUDIANTE, CALIFICABLE, CREATED_BY, CREATED_AT, ACTIVE
        ) VALUES (
            p_pk_tactividad_estudiante, 'S', p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
        )
        RETURNING PK_TACTIVIDAD_NOTA INTO v_pk;
    ELSIF NOT (SELECT ACTIVE FROM academico_test.TACTIVIDAD_NOTA WHERE PK_TACTIVIDAD_NOTA = v_pk) THEN
        UPDATE academico_test.TACTIVIDAD_NOTA
           SET ACTIVE = TRUE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TACTIVIDAD_NOTA = v_pk;
    END IF;

    RETURN v_pk;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_nota_get_or_create(BIGINT, BIGINT)
    IS 'Get-or-create de la fila TACTIVIDAD_NOTA (UK_TACTIVIDAD_NOTA_1 es 1:1 por FK_TACTIVIDAD_ESTUDIANTE): la crea con CALIFICABLE=''S'' si no existe, o la reactiva si estaba inactiva. Valida que la asignacion actividad-estudiante exista y este activa. Helper de fn_actividad_nota_calificar_*. V227.';

-- ===========================================================================
-- (3) CALCULO POR INSTRUMENTO
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- fn_actividad_nota_calificar_rubrica
--
-- p_niveles JSONB = [{ "pkCriterio": <pk>, "pkNivel": <pk> }, ...]
--
-- Regla de "todos los criterios cubiertos o parcial": se exige que
-- p_niveles cubra TODOS los criterios activos de la actividad (ni de mas ni
-- de menos) — una rubrica parcial no tiene una nota "justa" sin una regla
-- de negocio explicita para los criterios faltantes (¿cuentan como 0?
-- ¿se excluyen del promedio?), y esa regla no esta confirmada. Se prefiere
-- exigir el set completo y fallar con mensaje claro antes que adivinar.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_calificar_rubrica(
    p_pk_usuario_solicitante    BIGINT,
    p_pk_tactividad_estudiante  BIGINT,
    p_niveles                   JSONB
)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk_tactividad     BIGINT;
    v_pk_nota           BIGINT;
    v_total_criterios   INT;
    v_cubiertos         INT;
    v_pct_final         NUMERIC(5,2);
    v_elem              JSONB;
    v_pk_criterio       BIGINT;
    v_pk_nivel          BIGINT;
    v_nivel_ponderacion NUMERIC(5,2);
    v_max_ponderacion   NUMERIC(5,2);
    v_pk_eval_existente BIGINT;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'EDITAR'
    );

    SELECT ae.FK_TACTIVIDAD INTO v_pk_tactividad
      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
     WHERE ae.PK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante AND ae.ACTIVE = TRUE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la asignacion actividad-estudiante solicitada' USING ERRCODE = 'P0002';
    END IF;
    PERFORM academico_test.fn_actividad_instrumento_assert(v_pk_tactividad, 'RUBRICA');

    IF p_niveles IS NULL OR jsonb_typeof(p_niveles) <> 'array' OR jsonb_array_length(p_niveles) = 0 THEN
        RAISE EXCEPTION 'p_niveles debe ser un arreglo JSON con al menos un {pkCriterio, pkNivel}'
            USING ERRCODE = '22023';
    END IF;

    SELECT COUNT(*) INTO v_total_criterios
      FROM academico_test.TACTIVIDAD_RUBRICA_CRITERIO
     WHERE FK_TACTIVIDAD = v_pk_tactividad AND ACTIVE = TRUE;

    SELECT COUNT(DISTINCT (e->>'pkCriterio')::BIGINT) INTO v_cubiertos
      FROM jsonb_array_elements(p_niveles) e;

    IF v_cubiertos <> jsonb_array_length(p_niveles) THEN
        RAISE EXCEPTION 'p_niveles tiene criterios repetidos: debe traer un nivel por cada criterio, uno solo'
            USING ERRCODE = '22023';
    END IF;
    IF v_cubiertos <> v_total_criterios THEN
        RAISE EXCEPTION 'La rubrica tiene % criterio(s) activo(s) pero se calificaron % — deben cubrirse todos',
            v_total_criterios, v_cubiertos USING ERRCODE = '22023';
    END IF;

    v_pk_nota := academico_test.fn_actividad_nota_get_or_create(p_pk_usuario_solicitante, p_pk_tactividad_estudiante);

    -- Reemplazo completo de la captura previa (mismo espiritu de "reemplazo
    -- completo" que fn_actividad_rubrica_definir en V226).
    UPDATE academico_test.TACTIVIDAD_RUBRICA_EVALUACION re
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
      FROM academico_test.TACTIVIDAD_RUBRICA_CRITERIO c
     WHERE re.FK_TACTIVIDAD_RUBRICA_CRITERIO = c.PK_TACTIVIDAD_RUBRICA_CRITERIO
       AND c.FK_TACTIVIDAD = v_pk_tactividad
       AND re.FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante
       AND re.ACTIVE = TRUE;

    v_pct_final := 0;

    FOR v_elem IN SELECT * FROM jsonb_array_elements(p_niveles) LOOP
        v_pk_criterio := (v_elem->>'pkCriterio')::BIGINT;
        v_pk_nivel    := (v_elem->>'pkNivel')::BIGINT;

        IF NOT EXISTS (
            SELECT 1 FROM academico_test.TACTIVIDAD_RUBRICA_CRITERIO
             WHERE PK_TACTIVIDAD_RUBRICA_CRITERIO = v_pk_criterio
               AND FK_TACTIVIDAD = v_pk_tactividad AND ACTIVE = TRUE
        ) THEN
            RAISE EXCEPTION 'El criterio % no pertenece a la rubrica de esta actividad', v_pk_criterio
                USING ERRCODE = '22023';
        END IF;

        SELECT PONDERACION INTO v_nivel_ponderacion
          FROM academico_test.TACTIVIDAD_RUBRICA_NIVEL
         WHERE PK_TACTIVIDAD_RUBRICA_NIVEL = v_pk_nivel
           AND FK_TACTIVIDAD_RUBRICA_CRITERIO = v_pk_criterio AND ACTIVE = TRUE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'El nivel % no pertenece al criterio % de esta rubrica', v_pk_nivel, v_pk_criterio
                USING ERRCODE = '22023';
        END IF;

        SELECT MAX(PONDERACION) INTO v_max_ponderacion
          FROM academico_test.TACTIVIDAD_RUBRICA_NIVEL
         WHERE FK_TACTIVIDAD_RUBRICA_CRITERIO = v_pk_criterio AND ACTIVE = TRUE;

        -- Upsert manual: UN_TAC_RUBRICA_EVAL_1 es DEFERRABLE INITIALLY DEFERRED
        -- y por eso no sirve como arbitro de ON CONFLICT (mismo motivo que
        -- fn_actividad_escala_definir en V226 hace upsert manual).
        SELECT PK_TACTIVIDAD_RUBRICA_EVAL INTO v_pk_eval_existente
          FROM academico_test.TACTIVIDAD_RUBRICA_EVALUACION
         WHERE FK_TACTIVIDAD_RUBRICA_CRITERIO = v_pk_criterio
           AND FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante;

        IF v_pk_eval_existente IS NULL THEN
            INSERT INTO academico_test.TACTIVIDAD_RUBRICA_EVALUACION (
                FK_TACTIVIDAD_RUBRICA_CRITERIO, FK_TACTIVIDAD_ESTUDIANTE, FK_TACTIVIDAD_RUBRICA_NIVEL,
                PONDERACION, CREATED_BY, CREATED_AT, ACTIVE
            ) VALUES (
                v_pk_criterio, p_pk_tactividad_estudiante, v_pk_nivel,
                v_nivel_ponderacion, p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
            );
        ELSE
            UPDATE academico_test.TACTIVIDAD_RUBRICA_EVALUACION
               SET FK_TACTIVIDAD_RUBRICA_NIVEL = v_pk_nivel,
                   PONDERACION                 = v_nivel_ponderacion,
                   ACTIVE                       = TRUE,
                   MODIFIED_BY                  = p_pk_usuario_solicitante::VARCHAR,
                   MODIFIED_AT                  = CURRENT_TIMESTAMP
             WHERE PK_TACTIVIDAD_RUBRICA_EVAL = v_pk_eval_existente;
        END IF;

        -- % del criterio = ponderacion del nivel elegido / MAX ponderacion del criterio * 100.
        v_pct_final := v_pct_final + (v_nivel_ponderacion / NULLIF(v_max_ponderacion, 0) * 100);
    END LOOP;

    -- Promedio simple de los % por criterio.
    v_pct_final := ROUND(v_pct_final / v_total_criterios, 2);

    UPDATE academico_test.TACTIVIDAD_NOTA
       SET CALIFICACION = v_pct_final, CALIFICABLE = 'S',
           MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TACTIVIDAD_NOTA = v_pk_nota;

    RETURN v_pct_final;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_nota_calificar_rubrica(BIGINT, BIGINT, JSONB)
    IS 'Califica a un estudiante con la rubrica de su actividad: p_niveles = [{pkCriterio, pkNivel}], UNO por cada criterio ACTIVO de la actividad (se exige el set completo; no hay regla de negocio confirmada para rubricas parciales). Por criterio: % = ponderacion del nivel elegido / MAX(ponderacion de los niveles de ese criterio) * 100. Nota final = promedio simple de esos %. Reemplazo completo de TACTIVIDAD_RUBRICA_EVALUACION para ese estudiante y upsert de TACTIVIDAD_NOTA.CALIFICACION (guardado como porcentaje 0-100, ver cabecera). Gate EDITAR sobre PLANEADOR. V227.';

-- ---------------------------------------------------------------------------
-- fn_actividad_nota_calificar_cotejo
--
-- p_items_marcados BIGINT[] = PKs de TACTIVIDAD_COTEJO_ITEM cumplidos.
--
-- Regla de items sin PONDERACION (V226 la dejo opcional y ambigua cuando se
-- mezclan con items ponderados): se tratan como peso 1 tanto en el
-- numerador (si estan marcados) como en el denominador (siempre), es decir
-- "cuentan igual entre si, y se sinergizan con los que si tienen peso"
-- -- exactamente lo que ya explica el COMMENT de V226 sobre PONDERACION
-- ("todos los items sin peso cuentan igual").
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_calificar_cotejo(
    p_pk_usuario_solicitante    BIGINT,
    p_pk_tactividad_estudiante  BIGINT,
    p_items_marcados            BIGINT[]
)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk_tactividad BIGINT;
    v_pk_nota       BIGINT;
    v_total_items   INT;
    v_suma_total    NUMERIC(10,2);
    v_suma_marcada  NUMERIC(10,2);
    v_pct_final     NUMERIC(5,2);
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'EDITAR'
    );

    SELECT ae.FK_TACTIVIDAD INTO v_pk_tactividad
      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
     WHERE ae.PK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante AND ae.ACTIVE = TRUE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la asignacion actividad-estudiante solicitada' USING ERRCODE = 'P0002';
    END IF;
    PERFORM academico_test.fn_actividad_instrumento_assert(v_pk_tactividad, 'LISTA_COTEJO');

    SELECT COUNT(*) INTO v_total_items
      FROM academico_test.TACTIVIDAD_COTEJO_ITEM
     WHERE FK_TACTIVIDAD = v_pk_tactividad AND ACTIVE = TRUE;
    IF v_total_items = 0 THEN
        RAISE EXCEPTION 'La lista de cotejo de esta actividad no tiene items definidos' USING ERRCODE = '22023';
    END IF;

    IF p_items_marcados IS NOT NULL AND EXISTS (
        SELECT 1 FROM unnest(p_items_marcados) m(pk)
         WHERE NOT EXISTS (
             SELECT 1 FROM academico_test.TACTIVIDAD_COTEJO_ITEM
              WHERE PK_TACTIVIDAD_COTEJO_ITEM = m.pk AND FK_TACTIVIDAD = v_pk_tactividad AND ACTIVE = TRUE
         )
    ) THEN
        RAISE EXCEPTION 'p_items_marcados contiene un item que no pertenece a la lista de cotejo de esta actividad'
            USING ERRCODE = '22023';
    END IF;

    v_pk_nota := academico_test.fn_actividad_nota_get_or_create(p_pk_usuario_solicitante, p_pk_tactividad_estudiante);

    -- Reemplazo completo: 1 fila por item, CUMPLIDO='S' si vino en el arreglo, 'N' si no.
    -- Upsert manual (UPDATE + INSERT de faltantes) porque UN_TAC_COTEJO_EVAL_1
    -- es DEFERRABLE INITIALLY DEFERRED y no sirve como arbitro de ON CONFLICT
    -- (mismo motivo documentado en fn_actividad_nota_calificar_rubrica).
    UPDATE academico_test.TACTIVIDAD_COTEJO_EVALUACION ce
       SET CUMPLIDO    = CASE WHEN ce.FK_TACTIVIDAD_COTEJO_ITEM = ANY (COALESCE(p_items_marcados, ARRAY[]::BIGINT[])) THEN 'S' ELSE 'N' END,
           ACTIVE       = TRUE,
           MODIFIED_BY  = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT  = CURRENT_TIMESTAMP
      FROM academico_test.TACTIVIDAD_COTEJO_ITEM i
     WHERE i.PK_TACTIVIDAD_COTEJO_ITEM = ce.FK_TACTIVIDAD_COTEJO_ITEM
       AND i.FK_TACTIVIDAD = v_pk_tactividad AND i.ACTIVE = TRUE
       AND ce.FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante;

    INSERT INTO academico_test.TACTIVIDAD_COTEJO_EVALUACION (
        FK_TACTIVIDAD_COTEJO_ITEM, FK_TACTIVIDAD_ESTUDIANTE, CUMPLIDO, CREATED_BY, CREATED_AT, ACTIVE
    )
    SELECT i.PK_TACTIVIDAD_COTEJO_ITEM, p_pk_tactividad_estudiante,
           CASE WHEN i.PK_TACTIVIDAD_COTEJO_ITEM = ANY (COALESCE(p_items_marcados, ARRAY[]::BIGINT[])) THEN 'S' ELSE 'N' END,
           p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
      FROM academico_test.TACTIVIDAD_COTEJO_ITEM i
     WHERE i.FK_TACTIVIDAD = v_pk_tactividad AND i.ACTIVE = TRUE
       AND NOT EXISTS (
           SELECT 1 FROM academico_test.TACTIVIDAD_COTEJO_EVALUACION ce
            WHERE ce.FK_TACTIVIDAD_COTEJO_ITEM = i.PK_TACTIVIDAD_COTEJO_ITEM
              AND ce.FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante
       );

    -- Items sin PONDERACION cuentan como peso 1 (ver comentario de la funcion).
    SELECT SUM(COALESCE(i.PONDERACION, 1)) INTO v_suma_total
      FROM academico_test.TACTIVIDAD_COTEJO_ITEM i
     WHERE i.FK_TACTIVIDAD = v_pk_tactividad AND i.ACTIVE = TRUE;

    SELECT SUM(COALESCE(i.PONDERACION, 1)) INTO v_suma_marcada
      FROM academico_test.TACTIVIDAD_COTEJO_ITEM i
     WHERE i.FK_TACTIVIDAD = v_pk_tactividad AND i.ACTIVE = TRUE
       AND i.PK_TACTIVIDAD_COTEJO_ITEM = ANY (COALESCE(p_items_marcados, ARRAY[]::BIGINT[]));

    v_pct_final := ROUND(COALESCE(v_suma_marcada, 0) / NULLIF(v_suma_total, 0) * 100, 2);

    UPDATE academico_test.TACTIVIDAD_NOTA
       SET CALIFICACION = v_pct_final, CALIFICABLE = 'S',
           MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TACTIVIDAD_NOTA = v_pk_nota;

    RETURN v_pct_final;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_nota_calificar_cotejo(BIGINT, BIGINT, BIGINT[])
    IS 'Califica a un estudiante con la lista de cotejo de su actividad: p_items_marcados = PKs de TACTIVIDAD_COTEJO_ITEM cumplidos (puede ser vacio/NULL = nada cumplido). % = SUM(ponderacion de los items marcados) / SUM(ponderacion de TODOS los items) * 100, tratando los items SIN ponderacion (V226, columna opcional) como peso 1 tanto en el numerador (si estan marcados) como en el denominador. Reemplazo completo de TACTIVIDAD_COTEJO_EVALUACION (1 fila por item, CUMPLIDO S/N explicito) y upsert de TACTIVIDAD_NOTA.CALIFICACION (porcentaje 0-100). Gate EDITAR sobre PLANEADOR. V227.';

-- ---------------------------------------------------------------------------
-- fn_actividad_nota_calificar_escala
--
-- Exactamente uno de p_pk_nivel (CUALITATIVA) / p_valor_numerico (NUMERICA)
-- segun FK_TLV_TIPO_ESCALA de la escala de la actividad.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_calificar_escala(
    p_pk_usuario_solicitante    BIGINT,
    p_pk_tactividad_estudiante  BIGINT,
    p_pk_nivel                  BIGINT  DEFAULT NULL,
    p_valor_numerico             NUMERIC DEFAULT NULL
)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk_tactividad   BIGINT;
    v_pk_nota         BIGINT;
    v_pk_escala       BIGINT;
    v_tipo_val        VARCHAR;
    v_min             NUMERIC(5,2);
    v_max             NUMERIC(5,2);
    v_nivel_pond      NUMERIC(5,2);
    v_max_pond        NUMERIC(5,2);
    v_pct_final       NUMERIC(5,2);
    v_pk_eval_existente BIGINT;
    v_valor_final     NUMERIC(5,2);
    v_pond_final      NUMERIC(5,2);
    v_nivel_final     BIGINT;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'EDITAR'
    );

    SELECT ae.FK_TACTIVIDAD INTO v_pk_tactividad
      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
     WHERE ae.PK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante AND ae.ACTIVE = TRUE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la asignacion actividad-estudiante solicitada' USING ERRCODE = 'P0002';
    END IF;
    PERFORM academico_test.fn_actividad_instrumento_assert(v_pk_tactividad, 'ESCALA_VALORACION');

    SELECT e.PK_TACTIVIDAD_ESCALA, lv.VALOR, e.VALOR_MIN, e.VALOR_MAX
      INTO v_pk_escala, v_tipo_val, v_min, v_max
      FROM academico_test.TACTIVIDAD_ESCALA e
      JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = e.FK_TLV_TIPO_ESCALA
     WHERE e.FK_TACTIVIDAD = v_pk_tactividad AND e.ACTIVE = TRUE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La actividad no tiene una escala de valoracion definida (use fn_actividad_escala_definir primero)'
            USING ERRCODE = '22023';
    END IF;

    IF (p_pk_nivel IS NOT NULL) = (p_valor_numerico IS NOT NULL) THEN
        RAISE EXCEPTION 'Debe indicarse exactamente uno de pkNivel (escala CUALITATIVA) o valorNumerico (escala NUMERICA)'
            USING ERRCODE = '22023';
    END IF;

    v_pk_nota := academico_test.fn_actividad_nota_get_or_create(p_pk_usuario_solicitante, p_pk_tactividad_estudiante);

    IF v_tipo_val = 'CUALITATIVA' THEN
        IF p_pk_nivel IS NULL THEN
            RAISE EXCEPTION 'La escala de esta actividad es CUALITATIVA: se requiere pkNivel' USING ERRCODE = '22023';
        END IF;

        SELECT PONDERACION INTO v_nivel_pond
          FROM academico_test.TACTIVIDAD_ESCALA_NIVEL
         WHERE PK_TACTIVIDAD_ESCALA_NIVEL = p_pk_nivel
           AND FK_TACTIVIDAD_ESCALA = v_pk_escala AND ACTIVE = TRUE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'El nivel % no pertenece a la escala de esta actividad', p_pk_nivel
                USING ERRCODE = '22023';
        END IF;

        SELECT MAX(PONDERACION) INTO v_max_pond
          FROM academico_test.TACTIVIDAD_ESCALA_NIVEL
         WHERE FK_TACTIVIDAD_ESCALA = v_pk_escala AND ACTIVE = TRUE;

        v_pct_final := ROUND(v_nivel_pond / NULLIF(v_max_pond, 0) * 100, 2);
        v_nivel_final := p_pk_nivel;
        v_valor_final := v_nivel_pond;
        v_pond_final  := v_nivel_pond;

    ELSE  -- NUMERICA
        IF p_valor_numerico IS NULL THEN
            RAISE EXCEPTION 'La escala de esta actividad es NUMERICA: se requiere valorNumerico' USING ERRCODE = '22023';
        END IF;
        IF v_min IS NULL OR v_max IS NULL THEN
            RAISE EXCEPTION 'La escala NUMERICA de esta actividad no tiene valorMin/valorMax definidos' USING ERRCODE = '22023';
        END IF;
        IF p_valor_numerico < v_min OR p_valor_numerico > v_max THEN
            RAISE EXCEPTION 'valorNumerico (%) debe estar entre % y %', p_valor_numerico, v_min, v_max
                USING ERRCODE = '22023';
        END IF;

        v_pct_final := ROUND((p_valor_numerico - v_min) / NULLIF(v_max - v_min, 0) * 100, 2);
        v_nivel_final := NULL;
        v_valor_final := p_valor_numerico;
        v_pond_final  := NULL;
    END IF;

    -- Upsert manual (UN_TAC_ESCALA_EVAL_1 es DEFERRABLE INITIALLY DEFERRED,
    -- no sirve como arbitro de ON CONFLICT; mismo motivo que en rubrica/cotejo).
    SELECT PK_TACTIVIDAD_ESCALA_EVAL INTO v_pk_eval_existente
      FROM academico_test.TACTIVIDAD_ESCALA_EVALUACION
     WHERE FK_TACTIVIDAD_ESCALA = v_pk_escala AND FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante;

    IF v_pk_eval_existente IS NULL THEN
        INSERT INTO academico_test.TACTIVIDAD_ESCALA_EVALUACION (
            FK_TACTIVIDAD_ESCALA, FK_TACTIVIDAD_ESTUDIANTE, FK_TACTIVIDAD_ESCALA_NIVEL,
            VALOR, PONDERACION, CREATED_BY, CREATED_AT, ACTIVE
        ) VALUES (
            v_pk_escala, p_pk_tactividad_estudiante, v_nivel_final,
            v_valor_final, v_pond_final, p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
        );
    ELSE
        UPDATE academico_test.TACTIVIDAD_ESCALA_EVALUACION
           SET FK_TACTIVIDAD_ESCALA_NIVEL = v_nivel_final,
               VALOR                       = v_valor_final,
               PONDERACION                 = v_pond_final,
               ACTIVE                       = TRUE,
               MODIFIED_BY                  = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT                  = CURRENT_TIMESTAMP
         WHERE PK_TACTIVIDAD_ESCALA_EVAL = v_pk_eval_existente;
    END IF;

    UPDATE academico_test.TACTIVIDAD_NOTA
       SET CALIFICACION = v_pct_final, CALIFICABLE = 'S',
           MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TACTIVIDAD_NOTA = v_pk_nota;

    RETURN v_pct_final;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_nota_calificar_escala(BIGINT, BIGINT, BIGINT, NUMERIC)
    IS 'Califica a un estudiante con la escala de valoracion de su actividad. Exactamente uno de p_pk_nivel (CUALITATIVA: % = ponderacion del nivel / MAX ponderacion de la escala * 100) o p_valor_numerico (NUMERICA, dentro de [VALOR_MIN,VALOR_MAX]: % = (valor - min)/(max - min) * 100). Upsert de TACTIVIDAD_ESCALA_EVALUACION (1:1 por estudiante, UN_TAC_ESCALA_EVAL_1) y de TACTIVIDAD_NOTA.CALIFICACION (porcentaje 0-100). Gate EDITAR sobre PLANEADOR. V227.';

-- ---------------------------------------------------------------------------
-- fn_actividad_nota_calificar_otro — sin calculo automatico.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_calificar_otro(
    p_pk_usuario_solicitante    BIGINT,
    p_pk_tactividad_estudiante  BIGINT,
    p_porcentaje                 NUMERIC
)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk_tactividad BIGINT;
    v_pk_nota       BIGINT;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'EDITAR'
    );

    SELECT ae.FK_TACTIVIDAD INTO v_pk_tactividad
      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
     WHERE ae.PK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante AND ae.ACTIVE = TRUE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la asignacion actividad-estudiante solicitada' USING ERRCODE = 'P0002';
    END IF;
    PERFORM academico_test.fn_actividad_instrumento_assert(v_pk_tactividad, 'OTRO');

    IF p_porcentaje IS NULL OR p_porcentaje < 0 OR p_porcentaje > 100 THEN
        RAISE EXCEPTION 'p_porcentaje debe estar entre 0 y 100' USING ERRCODE = '22023';
    END IF;

    v_pk_nota := academico_test.fn_actividad_nota_get_or_create(p_pk_usuario_solicitante, p_pk_tactividad_estudiante);

    UPDATE academico_test.TACTIVIDAD_NOTA
       SET CALIFICACION = ROUND(p_porcentaje, 2), CALIFICABLE = 'S',
           MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TACTIVIDAD_NOTA = v_pk_nota;

    RETURN ROUND(p_porcentaje, 2);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_nota_calificar_otro(BIGINT, BIGINT, NUMERIC)
    IS 'Instrumento OTRO (sin estructura, V226): NO hay calculo automatico. Guarda directo el % (0-100) que manda el llamador en TACTIVIDAD_NOTA.CALIFICACION; el calculo/criterio es responsabilidad del cliente (DESCRIPCION_INSTRUMENTO). Gate EDITAR sobre PLANEADOR. V227.';

-- ===========================================================================
-- (4) FACHADA — despacha segun el instrumento de la actividad + lectura.
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_calificar(
    p_pk_usuario_solicitante    BIGINT,
    p_pk_tactividad_estudiante  BIGINT,
    p_calificacion               JSONB
)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk_tactividad BIGINT;
    v_valor         VARCHAR;
    v_pct           NUMERIC(5,2);
BEGIN
    SELECT ae.FK_TACTIVIDAD INTO v_pk_tactividad
      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
     WHERE ae.PK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante AND ae.ACTIVE = TRUE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la asignacion actividad-estudiante solicitada' USING ERRCODE = 'P0002';
    END IF;

    SELECT lv.VALOR INTO v_valor
      FROM academico_test.TACTIVIDAD a
      LEFT JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = a.FK_TLV_INSTRUMENTO_EVALUACION
     WHERE a.PK_TACTIVIDAD = v_pk_tactividad;

    IF p_calificacion IS NULL OR jsonb_typeof(p_calificacion) <> 'object' THEN
        RAISE EXCEPTION 'p_calificacion debe ser un objeto JSON' USING ERRCODE = '22023';
    END IF;

    CASE v_valor
        WHEN 'RUBRICA' THEN
            v_pct := academico_test.fn_actividad_nota_calificar_rubrica(
                         p_pk_usuario_solicitante, p_pk_tactividad_estudiante, p_calificacion->'niveles');
        WHEN 'LISTA_COTEJO' THEN
            v_pct := academico_test.fn_actividad_nota_calificar_cotejo(
                         p_pk_usuario_solicitante, p_pk_tactividad_estudiante,
                         ARRAY(SELECT jsonb_array_elements_text(COALESCE(p_calificacion->'itemsMarcados', '[]'::jsonb))::BIGINT));
        WHEN 'ESCALA_VALORACION' THEN
            v_pct := academico_test.fn_actividad_nota_calificar_escala(
                         p_pk_usuario_solicitante, p_pk_tactividad_estudiante,
                         (p_calificacion->>'pkNivel')::BIGINT, (p_calificacion->>'valorNumerico')::NUMERIC);
        WHEN 'OTRO' THEN
            v_pct := academico_test.fn_actividad_nota_calificar_otro(
                         p_pk_usuario_solicitante, p_pk_tactividad_estudiante,
                         (p_calificacion->>'porcentaje')::NUMERIC);
        ELSE
            RAISE EXCEPTION 'La actividad no tiene un instrumento de evaluacion valido para calificar (%)',
                COALESCE(v_valor, 'sin instrumento') USING ERRCODE = '22023';
    END CASE;

    RETURN v_pct;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_nota_calificar(BIGINT, BIGINT, JSONB)
    IS 'Fachada: lee el instrumento de la actividad (via TACTIVIDAD_ESTUDIANTE.FK_TACTIVIDAD) y despacha a fn_actividad_nota_calificar_rubrica ({niveles:[{pkCriterio,pkNivel}]}), _cotejo ({itemsMarcados:[pk,...]}), _escala ({pkNivel} o {valorNumerico}) u _otro ({porcentaje}). Calcula (salvo OTRO) y guarda el % (0-100) en TACTIVIDAD_NOTA.CALIFICACION. Gate EDITAR sobre PLANEADOR (via las funciones destino). V227.';

-- ---------------------------------------------------------------------------
-- fn_actividad_nota_obtener — lectura de la nota + detalle de captura.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_obtener(
    p_pk_usuario_solicitante    BIGINT,
    p_pk_tactividad_estudiante  BIGINT
)
RETURNS TABLE (
    instrumento         VARCHAR,
    calificacion        NUMERIC,
    calificable         CHAR(1),
    observacion         VARCHAR,
    detalle             JSONB
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TACTIVIDAD_ESTUDIANTE
         WHERE PK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se encontro la asignacion actividad-estudiante solicitada' USING ERRCODE = 'P0002';
    END IF;

    RETURN QUERY
    SELECT lv.VALOR,
           n.CALIFICACION,
           n.CALIFICABLE,
           n.OBSERVACION,
           CASE lv.VALOR
               WHEN 'RUBRICA' THEN COALESCE((
                   SELECT jsonb_agg(jsonb_build_object(
                              'pkCriterio',  re.FK_TACTIVIDAD_RUBRICA_CRITERIO,
                              'pkNivel',     re.FK_TACTIVIDAD_RUBRICA_NIVEL,
                              'ponderacion', re.PONDERACION))
                     FROM academico_test.TACTIVIDAD_RUBRICA_EVALUACION re
                     JOIN academico_test.TACTIVIDAD_RUBRICA_CRITERIO c
                       ON c.PK_TACTIVIDAD_RUBRICA_CRITERIO = re.FK_TACTIVIDAD_RUBRICA_CRITERIO
                    WHERE re.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                      AND re.ACTIVE = TRUE AND c.FK_TACTIVIDAD = a.PK_TACTIVIDAD
               ), '[]'::jsonb)

               WHEN 'LISTA_COTEJO' THEN COALESCE((
                   SELECT jsonb_agg(jsonb_build_object(
                              'pkItem',   ce.FK_TACTIVIDAD_COTEJO_ITEM,
                              'cumplido', ce.CUMPLIDO))
                     FROM academico_test.TACTIVIDAD_COTEJO_EVALUACION ce
                     JOIN academico_test.TACTIVIDAD_COTEJO_ITEM i
                       ON i.PK_TACTIVIDAD_COTEJO_ITEM = ce.FK_TACTIVIDAD_COTEJO_ITEM
                    WHERE ce.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                      AND ce.ACTIVE = TRUE AND i.FK_TACTIVIDAD = a.PK_TACTIVIDAD
               ), '[]'::jsonb)

               WHEN 'ESCALA_VALORACION' THEN (
                   SELECT jsonb_build_object(
                              'pkNivel',      ee.FK_TACTIVIDAD_ESCALA_NIVEL,
                              'valor',        ee.VALOR,
                              'ponderacion',  ee.PONDERACION)
                     FROM academico_test.TACTIVIDAD_ESCALA_EVALUACION ee
                     JOIN academico_test.TACTIVIDAD_ESCALA e ON e.PK_TACTIVIDAD_ESCALA = ee.FK_TACTIVIDAD_ESCALA
                    WHERE ee.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                      AND ee.ACTIVE = TRUE AND e.FK_TACTIVIDAD = a.PK_TACTIVIDAD
               )

               ELSE NULL
           END
      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
      JOIN academico_test.TACTIVIDAD a ON a.PK_TACTIVIDAD = ae.FK_TACTIVIDAD
      LEFT JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = a.FK_TLV_INSTRUMENTO_EVALUACION
      LEFT JOIN academico_test.TACTIVIDAD_NOTA n
             ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE AND n.ACTIVE = TRUE
     WHERE ae.PK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_nota_obtener(BIGINT, BIGINT)
    IS 'Lee la nota de un estudiante para una actividad: instrumento aplicado, CALIFICACION (porcentaje 0-100, SIN homologar a la escala visual del periodo/asignatura — eso es responsabilidad de la capa de lectura/reporte existente, ver cabecera de V227), CALIFICABLE, OBSERVACION y el detalle de captura segun el instrumento (RUBRICA: [{pkCriterio,pkNivel,ponderacion}]; LISTA_COTEJO: [{pkItem,cumplido}]; ESCALA_VALORACION: {pkNivel,valor,ponderacion}; OTRO/sin captura estructurada: NULL). Gate VER sobre PLANEADOR. V227.';
