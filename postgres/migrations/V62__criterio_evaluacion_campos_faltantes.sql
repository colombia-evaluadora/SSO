-- ===========================================================================
-- V62 — TCRITERIO_EVALUACION: campos que faltaban de la pestaña "Criterios
-- de evaluación" del periodo académico, más tres bugs de wiring que salieron
-- a la luz al investigar por qué no estaban.
--
-- Contexto (ver docs/superpowers/specs — analisis en vivo contra el
-- servidor de test, academico_test.tlista_valor):
--
-- La pestaña muestra 10 campos. Cruzando cada uno contra las columnas
-- reales de TCRITERIO_EVALUACION (V22) y TPERIODO_ACADEMICO_CONFIG (V22):
--
--   Escala de valoración              -> TCRITERIO_EVALUACION.FK_TESCALA (ya existe)
--   Formato de calificación           -> FK_TLV_FORMATO_CALIFICACION / TLISTA_VALOR.FORMATO_CALIFICACION (ya existe)
--   Sin calificaciones                -> FK_TLV_DESEMPENO_SIN_CALIF / TLISTA_VALOR.DESEMPENIOSUGERIR (ya existe)
--   Nota máxima de recuperación/nivelación -> PORCENTAJE_INICIAL_CALIF (ya existe — único campo
--                                        de tipo porcentaje en la tabla; mal nombrado como
--                                        "initial_grade" en las funciones V41, ver bug 3)
--   Criterio para calcular la nota del área -> FK_TLV_CRITERIO_AREA / TLISTA_VALOR.CRITERIO_AREA (ya existe)
--   Criterio para calcular la nota final -> FK_TLV_CRITERIO_FINAL / TLISTA_VALOR.CRITERIO_FINAL_PERACA (ya existe)
--   Elementos para calcular la nota  -> FK_TLV_ELEMENTO_DEF / TLISTA_VALOR.ELEMENTO_CALCULO_DEF (ya existe)
--   Regla de redondeo                -> TPERIODO_ACADEMICO_CONFIG.FK_TLV_MODO_REDONDEAR / TLISTA_VALOR.MODO_REDONDEAR
--                                        (existe, pero en la tabla EQUIVOCADA — se traslada acá)
--   Criterio para calcular la nota de la asignatura -> NINGUNA columna en ninguna
--                                        de las dos tablas. Sus valores YA EXISTEN en
--                                        TLISTA_VALOR bajo la categoría CRITERIO_DESEMPENO
--                                        (5 filas: "Promediar la calificación de las
--                                        actividades/áreas/asignaturas", "Ponderar...
--                                        intensidad horaria", "Ponderar...porcentaje
--                                        dentro del área") — categoría confirmada sin
--                                        NINGÚN otro consumidor en las 61 migraciones
--                                        del repo (grep limpio). Estaba huérfana.
--
-- Lo que NO se agrega acá, por falta de dato de respaldo (ni columna ni
-- categoría de TLISTA_VALOR que calce, no hay nada de donde partir sin
-- adivinar semántica/escala):
--   - "Nota inicial para las calificaciones" — con PORCENTAJE_INICIAL_CALIF
--     reidentificada como "nota máxima de recuperación" (ver arriba), este
--     campo se queda sin columna propia. Ninguna otra columna de
--     TCRITERIO_EVALUACION calza.
--   - "Número de desempeños que deben modificar los digitados" (de las
--     condiciones de aceptación, no aparece en la imagen) — no es lo
--     mismo que FK_TLV_MODIF_FINAL_PERACA (ver bug 1 abajo): esa columna
--     es SI/NO ("¿se puede modificar la nota final?"), no un conteo.
--
-- ---------------------------------------------------------------------------
-- Bug 1 — fn_criterio_eval_actualizar/obtener (V41): el parámetro
-- "subject_grade_criteria" ("criterio para calcular la nota de la
-- asignatura") en realidad lee/escribe FK_TLV_MODIF_FINAL_PERACA — la
-- columna SI/NO de "¿el digitador puede modificar la nota final del
-- periodo?", un concepto totalmente distinto (confirmado con datos reales:
-- esa columna sólo tiene valores SI/NO en TLISTA_VALOR, nunca los criterios
-- de CRITERIO_DESEMPENO). El nombre del parámetro es correcto — apunta a
-- donde el campo SIEMPRE debió estar, sólo que esa columna nunca se creó.
--
-- Bug 2 — mismas funciones: el parámetro "rounding_mode" ("regla de
-- redondeo") en realidad lee/escribe NUMERO_DECIMALES — la CANTIDAD de
-- decimales a mostrar (comentario propio de V22: "Cantidad de decimales a
-- usar en las calificaciones"), no el MODO de redondear (hacia arriba /
-- hacia abajo / depende del valor / no redondear, que es lo que
-- MODO_REDONDEAR en TLISTA_VALOR realmente representa). Son dos conceptos
-- independientes que se conflaron en un solo parámetro porque el dato real
-- de redondeo vivía en la tabla equivocada (TPERIODO_ACADEMICO_CONFIG) y
-- esta función nunca la tocaba.
--
-- Bug 3 — mismas funciones: el parámetro "initial_grade" ("nota inicial")
-- en realidad lee/escribe PORCENTAJE_INICIAL_CALIF, que — según quien
-- conoce el negocio, no algo que esta migración dedujera del esquema — es
-- la "Nota máxima de recuperación/nivelación" de la imagen, no una "nota
-- inicial". Se renombra el parámetro/columna de salida a
-- "max_recovery_grade" para que el nombre diga lo que el campo hace; la
-- columna de esquema (PORCENTAJE_INICIAL_CALIF) NO se renombra —
-- renombrar una columna ya poblada (139 filas) es un cambio mucho más
-- invasivo que corregir cómo la función la expone, y el nombre de columna
-- en sí no le importa a ningún consumidor (todos pasan por la función).
--
-- Ninguna fila del catálogo llama estas funciones por nombre de argumento
-- (confirmado: la fila 51, PUT /periodos/:ID/criterio-evaluacion, pasa los
-- 12 argumentos posicionalmente) — así que el fix se limita al CUERPO de
-- las funciones (bugs 1-2) y al RENOMBRE de parámetro/salida (bug 3), sin
-- tocar su posición ni tipo. Firma (orden, cantidad de parámetros
-- existentes) sin tocar; los dos parámetros nuevos van al final para no
-- romper la llamada posicional existente.
--
-- ADVERTENCIA — drift confirmado antes de escribir el fix: el archivo V41
-- (tal como vive en el repo) NO es lo que corre en el servidor de test.
-- fn_criterio_eval_obtener EN VIVO tiene un parámetro extra
-- (p_pk_usuario_solicitante, con gate de visibilidad
-- fn_periodo_usuario_puede_ver) y resuelve cada FK a su NOMBRE via LEFT
-- JOIN (columnas *_name) — ninguna de las dos cosas existe en el V41 del
-- repo. Confirmado con pg_get_functiondef contra el server antes de
-- escribir este CREATE OR REPLACE, para no pisar funcionalidad que el
-- archivo nunca reflejó (mismo patrón de drift que V42/V52/V53 —
-- ediciones post-aplicación nunca re-corridas). Este migration se basa en
-- la definición REAL, no en la del archivo.
-- ===========================================================================

SET search_path TO academico_test, public;

-- ---------------------------------------------------------------------------
-- 1. Columnas nuevas en TCRITERIO_EVALUACION.
-- ---------------------------------------------------------------------------

ALTER TABLE academico_test.TCRITERIO_EVALUACION
    ADD COLUMN IF NOT EXISTS FK_TLV_MODO_REDONDEAR BIGINT
        REFERENCES academico_test.TLISTA_VALOR (PK_LISTA_VALOR),
    ADD COLUMN IF NOT EXISTS FK_TLV_CRITERIO_ASIGNATURA BIGINT
        REFERENCES academico_test.TLISTA_VALOR (PK_LISTA_VALOR);

CREATE INDEX IF NOT EXISTS IDX_TCRITERIO_EVALUACION_MODO_REDONDEAR
    ON academico_test.TCRITERIO_EVALUACION (FK_TLV_MODO_REDONDEAR);
CREATE INDEX IF NOT EXISTS IDX_TCRITERIO_EVALUACION_CRITERIO_ASIGNATURA
    ON academico_test.TCRITERIO_EVALUACION (FK_TLV_CRITERIO_ASIGNATURA);

COMMENT ON COLUMN academico_test.TCRITERIO_EVALUACION.FK_TLV_MODO_REDONDEAR IS
    'Llave foranea de lista valor para obtener MODO_REDONDEAR. Trasladada desde TPERIODO_ACADEMICO_CONFIG (V62) — vivia en la tabla equivocada; fn_criterio_eval_actualizar/obtener (V41) la exponen como "criterios de evaluacion" del periodo, no TPERIODO_ACADEMICO_CONFIG.';
COMMENT ON COLUMN academico_test.TCRITERIO_EVALUACION.FK_TLV_CRITERIO_ASIGNATURA IS
    'Llave foranea de lista valor para obtener CRITERIO_DESEMPENO (V62). Antes de V62 esta categoria de TLISTA_VALOR existia sin ningun consumidor: fn_criterio_eval_actualizar (V41) ya tenia un parametro "subject_grade_criteria" pensado para esto, pero escribia por error FK_TLV_MODIF_FINAL_PERACA (un SI/NO no relacionado).';

-- ---------------------------------------------------------------------------
-- 2. Backfill: copiar el valor vigente de TPERIODO_ACADEMICO_CONFIG antes
--    de borrar la columna de origen. Relacion 1:1 via PK compartida con
--    TPERIODO_ACADEMICO (mismo patron que TCRITERIO_EVALUACION — ver V22,
--    ambas tablas tienen PK_x = PK_TPERIODO_ACADEMICO).
-- ---------------------------------------------------------------------------

UPDATE academico_test.TCRITERIO_EVALUACION ce
   SET FK_TLV_MODO_REDONDEAR = cfg.FK_TLV_MODO_REDONDEAR
  FROM academico_test.TPERIODO_ACADEMICO_CONFIG cfg
 WHERE cfg.PK_TPERIODO_ACADEMICO_CONFIG = ce.PK_TCRITERIO_EVALUACION
   AND cfg.FK_TLV_MODO_REDONDEAR IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 3. Traslado completo: la columna deja de existir en TPERIODO_ACADEMICO_CONFIG
--    (drop del indice + la FK antes de la columna, Postgres los arrastra con
--    CASCADE de todas formas al hacer DROP COLUMN, pero se listan explicitos
--    por trazabilidad con lo que V22 registro).
-- ---------------------------------------------------------------------------

DROP INDEX IF EXISTS academico_test.IDX_TPERIODO_ACADEMICO_CFG_21;

ALTER TABLE academico_test.TPERIODO_ACADEMICO_CONFIG
    DROP CONSTRAINT IF EXISTS FK_TPERIDO_ACADEMICO_CONFIG_14,
    DROP COLUMN IF EXISTS FK_TLV_MODO_REDONDEAR;

-- ---------------------------------------------------------------------------
-- 4. fn_criterio_eval_obtener — reconstruida sobre la definicion REAL (ver
--    advertencia de drift arriba), no sobre el V41 del repo. Se preserva:
--    el parametro p_pk_usuario_solicitante + el gate de visibilidad
--    fn_periodo_usuario_puede_ver, y el patron de resolver cada FK a su
--    NOMBRE via LEFT JOIN (columnas *_name). Se corrige el mapeo de
--    rounding_mode / subject_grade_criteria a las columnas reales (ahora
--    con su propio *_name, igual que el resto de lookups) y se agregan
--    decimal_places y final_grade_editable al final de RETURNS TABLE
--    (posicion nueva, no rompe "SELECT *" existente de la fila 50 del
--    catalogo).
--
--    Postgres rechaza CREATE OR REPLACE cuando cambia el RETURNS TABLE
--    (aunque los parametros de entrada sean identicos) — hay que DROP
--    primero, mismo patron ya usado en V52/V53 para el error analogo de
--    "cannot change name of input parameter". Se dropea tambien la firma
--    de 1 argumento del V41 del repo por si alguna instalacion la tiene
--    (nunca debio existir en el servidor de test, pero es gratis cubrirla).
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS academico_test.fn_criterio_eval_obtener(BIGINT);
DROP FUNCTION IF EXISTS academico_test.fn_criterio_eval_obtener(BIGINT, BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_criterio_eval_obtener(
    p_pk_periodo BIGINT, p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS TABLE (
    academic_period_id BIGINT,
    grading_format BIGINT, grading_format_name VARCHAR,
    grading_scale BIGINT, grading_scale_name VARCHAR,
    period_calculation_elements BIGINT, period_calculation_elements_name VARCHAR,
    subject_grade_criteria BIGINT, subject_grade_criteria_name VARCHAR,
    final_grade_criteria BIGINT, final_grade_criteria_name VARCHAR,
    area_grade_criteria BIGINT, area_grade_criteria_name VARCHAR,
    student_without_grades_performance BIGINT, student_without_grades_performance_name VARCHAR,
    rounding_mode BIGINT, rounding_mode_name VARCHAR,
    max_recovery_grade NUMERIC,
    decimal_places NUMERIC,
    final_grade_editable BIGINT, final_grade_editable_name VARCHAR
)
LANGUAGE sql STABLE AS $$
    SELECT
        ce.PK_TCRITERIO_EVALUACION,

        ce.FK_TLV_FORMATO_CALIFICACION,
        formato.NOMBRE,

        ce.FK_TESCALA,
        escala.NOMBRE,

        ce.FK_TLV_ELEMENTO_DEF,
        elemento.NOMBRE,

        ce.FK_TLV_CRITERIO_ASIGNATURA,
        criterio_asignatura.NOMBRE,

        ce.FK_TLV_CRITERIO_FINAL,
        criterio_final.NOMBRE,

        ce.FK_TLV_CRITERIO_AREA,
        criterio_area.NOMBRE,

        ce.FK_TLV_DESEMPENO_SIN_CALIF,
        desempeno.NOMBRE,

        ce.FK_TLV_MODO_REDONDEAR,
        modo_redondear.NOMBRE,

        ce.PORCENTAJE_INICIAL_CALIF,

        ce.NUMERO_DECIMALES,

        ce.FK_TLV_MODIF_FINAL_PERACA,
        modif_final.NOMBRE

    FROM academico_test.TCRITERIO_EVALUACION ce

    LEFT JOIN academico_test.TLISTA_VALOR formato
        ON formato.PK_LISTA_VALOR = ce.FK_TLV_FORMATO_CALIFICACION

    LEFT JOIN academico_test.TESCALA escala
        ON escala.PK_TESCALA = ce.FK_TESCALA

    LEFT JOIN academico_test.TLISTA_VALOR elemento
        ON elemento.PK_LISTA_VALOR = ce.FK_TLV_ELEMENTO_DEF

    LEFT JOIN academico_test.TLISTA_VALOR criterio_asignatura
        ON criterio_asignatura.PK_LISTA_VALOR = ce.FK_TLV_CRITERIO_ASIGNATURA

    LEFT JOIN academico_test.TLISTA_VALOR criterio_final
        ON criterio_final.PK_LISTA_VALOR = ce.FK_TLV_CRITERIO_FINAL

    LEFT JOIN academico_test.TLISTA_VALOR criterio_area
        ON criterio_area.PK_LISTA_VALOR = ce.FK_TLV_CRITERIO_AREA

    LEFT JOIN academico_test.TLISTA_VALOR desempeno
        ON desempeno.PK_LISTA_VALOR = ce.FK_TLV_DESEMPENO_SIN_CALIF

    LEFT JOIN academico_test.TLISTA_VALOR modo_redondear
        ON modo_redondear.PK_LISTA_VALOR = ce.FK_TLV_MODO_REDONDEAR

    LEFT JOIN academico_test.TLISTA_VALOR modif_final
        ON modif_final.PK_LISTA_VALOR = ce.FK_TLV_MODIF_FINAL_PERACA

    WHERE ce.PK_TCRITERIO_EVALUACION = p_pk_periodo
      AND ce.ACTIVE = TRUE
      AND academico_test.fn_periodo_usuario_puede_ver(
          p_pk_usuario_solicitante,
          p_pk_periodo
      );
$$;

COMMENT ON FUNCTION academico_test.fn_criterio_eval_obtener(BIGINT, BIGINT) IS
    'V62: rounding_mode ahora lee FK_TLV_MODO_REDONDEAR (antes leia NUMERO_DECIMALES por error) y gana su propio rounding_mode_name, igual que el resto de lookups. subject_grade_criteria ahora lee la columna dedicada FK_TLV_CRITERIO_ASIGNATURA (antes leia FK_TLV_MODIF_FINAL_PERACA por error). max_recovery_grade (antes "initial_grade") sigue leyendo PORCENTAJE_INICIAL_CALIF, sin cambio de columna — solo se corrige el nombre para reflejar lo que realmente representa (nota maxima de recuperacion/nivelacion, no una nota inicial). decimal_places y final_grade_editable son nuevos, exponen NUMERO_DECIMALES y FK_TLV_MODIF_FINAL_PERACA bajo su nombre real para no perder esa capacidad.';

-- ---------------------------------------------------------------------------
-- 5. fn_criterio_eval_actualizar — misma correccion en el UPDATE; dos
--    parametros nuevos al FINAL de la firma (p_decimal_places,
--    p_final_grade_editable), DEFAULT NULL, para no romper la llamada
--    posicional de 12 argumentos que ya usa el catalogo (fila 51).
--
--    Igual que con fn_criterio_eval_obtener: Postgres NO trata "agregar
--    parametros nuevos con DEFAULT al final" como un simple REPLACE — crea
--    un OVERLOAD nuevo y deja el de 12 argumentos intacto. Sin el DROP
--    explicito, la fila 51 del catalogo (que llama con exactamente 12
--    argumentos posicionales) seguiria resolviendo al overload VIEJO —
--    el fix no tendria ningun efecto en produccion pese a que la migracion
--    "corre limpia". Se dropea la firma vieja por su lista de tipos exacta.
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS academico_test.fn_criterio_eval_actualizar(
    BIGINT, BIGINT, BIGINT, BOOLEAN, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, NUMERIC, NUMERIC, BIGINT
);

-- p_rounding_mode se queda NUMERIC (no BIGINT) a proposito, aunque ahora
-- alimenta un FK BIGINT: la fila 51 del catalogo lo declara
-- "BODY.ROUNDING_MODE": "NUMERIC" y hace CAST(:BODY.ROUNDING_MODE AS
-- NUMERIC) antes de pasarlo. Cambiar el tipo del parametro habria exigido
-- tocar esa fila tambien (fuera del alcance de esta migracion, que es
-- puramente de esquema/DDL+funciones); en vez de eso, el cast a BIGINT
-- pasa DENTRO del cuerpo, sobre el valor ya recibido.
CREATE OR REPLACE FUNCTION academico_test.fn_criterio_eval_actualizar(
    p_pk_periodo             BIGINT,
    p_grading_format         BIGINT DEFAULT NULL,
    p_grading_scale          BIGINT DEFAULT NULL,   -- nullable a proposito
    p_set_grading_scale      BOOLEAN DEFAULT FALSE, -- TRUE = aplicar p_grading_scale (incl. NULL)
    p_period_calc_elements   BIGINT DEFAULT NULL,
    p_subject_grade_criteria BIGINT DEFAULT NULL,
    p_final_grade_criteria   BIGINT DEFAULT NULL,
    p_area_grade_criteria    BIGINT DEFAULT NULL,
    p_student_wo_grades      BIGINT DEFAULT NULL,
    p_rounding_mode          NUMERIC DEFAULT NULL,
    p_max_recovery_grade     NUMERIC DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL,
    p_decimal_places         NUMERIC DEFAULT NULL,
    p_final_grade_editable   BIGINT DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_n INT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_escala_actual BIGINT;
BEGIN
    -- Alcance por rol (como V37): grueso + fino (el criterio comparte PK con el
    -- periodo, asi que el establecimiento sale de p_pk_periodo).
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, academico_test.fn_periodo_establecimiento(p_pk_periodo));
    -- FK_TESCALA solo cambia si p_set_grading_scale = TRUE (permite ponerla o
    -- limpiarla explicitamente); en FALSE no se toca. El resto es COALESCE.
    -- Si se va a asignar una escala no nula, debe existir y estar activa.
    IF p_set_grading_scale AND p_grading_scale IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM academico_test.TESCALA WHERE PK_TESCALA = p_grading_scale AND ACTIVE = TRUE
        ) THEN
            RAISE EXCEPTION 'La escala de valoracion % no existe o esta inactiva', p_grading_scale USING ERRCODE = '23503';
        END IF;
        -- La escala maestra debe pertenecer al periodo (estar ligada via TNIVEL_ESCALA).
        IF NOT EXISTS (
            SELECT 1 FROM academico_test.TNIVEL_ESCALA
             WHERE FK_TESCALA = p_grading_scale AND FK_PERIODO_ACADEMICO = p_pk_periodo AND ACTIVE = TRUE
        ) THEN
            RAISE EXCEPTION 'La escala % no pertenece al periodo academico %', p_grading_scale, p_pk_periodo
                USING ERRCODE = '22023';
        END IF;
    END IF;
    -- Escala maestra actual (para decidir si hay que propagar).
    SELECT FK_TESCALA INTO v_escala_actual
      FROM academico_test.TCRITERIO_EVALUACION
     WHERE PK_TCRITERIO_EVALUACION = p_pk_periodo AND ACTIVE = TRUE;
    UPDATE academico_test.TCRITERIO_EVALUACION SET
        FK_TLV_FORMATO_CALIFICACION = COALESCE(p_grading_format, FK_TLV_FORMATO_CALIFICACION),
        FK_TESCALA                  = CASE WHEN p_set_grading_scale THEN p_grading_scale ELSE FK_TESCALA END,
        FK_TLV_ELEMENTO_DEF         = COALESCE(p_period_calc_elements, FK_TLV_ELEMENTO_DEF),
        FK_TLV_CRITERIO_ASIGNATURA  = COALESCE(p_subject_grade_criteria, FK_TLV_CRITERIO_ASIGNATURA),
        FK_TLV_CRITERIO_FINAL       = COALESCE(p_final_grade_criteria, FK_TLV_CRITERIO_FINAL),
        FK_TLV_CRITERIO_AREA        = COALESCE(p_area_grade_criteria, FK_TLV_CRITERIO_AREA),
        FK_TLV_DESEMPENO_SIN_CALIF  = COALESCE(p_student_wo_grades, FK_TLV_DESEMPENO_SIN_CALIF),
        FK_TLV_MODO_REDONDEAR       = COALESCE(p_rounding_mode::BIGINT, FK_TLV_MODO_REDONDEAR),
        PORCENTAJE_INICIAL_CALIF    = COALESCE(p_max_recovery_grade, PORCENTAJE_INICIAL_CALIF),
        NUMERO_DECIMALES            = COALESCE(p_decimal_places, NUMERO_DECIMALES),
        FK_TLV_MODIF_FINAL_PERACA   = COALESCE(p_final_grade_editable, FK_TLV_MODIF_FINAL_PERACA),
        MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TCRITERIO_EVALUACION = p_pk_periodo AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN
        RAISE EXCEPTION 'No existe criterio de evaluacion activo para el periodo %', p_pk_periodo
            USING ERRCODE = 'P0002';
    END IF;

    -- Solo al ELEGIR una escala maestra distinta a la actual se propaga a las
    -- demas escalas del periodo. Guardar otros campos (o re-guardar la misma
    -- escala) no vuelve a pisar las personalizaciones de las otras escalas.
    IF p_set_grading_scale AND p_grading_scale IS NOT NULL
       AND p_grading_scale IS DISTINCT FROM v_escala_actual THEN
        PERFORM academico_test.fn_escala_propagar(p_pk_periodo, p_grading_scale, v_audit);
    END IF;

    RETURN p_pk_periodo;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_criterio_eval_actualizar(
    BIGINT, BIGINT, BIGINT, BOOLEAN, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, NUMERIC, NUMERIC, BIGINT, NUMERIC, BIGINT
) IS
    'V62: corrige el wiring de p_rounding_mode (antes escribia NUMERO_DECIMALES; ahora FK_TLV_MODO_REDONDEAR, columna trasladada desde TPERIODO_ACADEMICO_CONFIG) y de p_subject_grade_criteria (antes escribia FK_TLV_MODIF_FINAL_PERACA; ahora la columna dedicada FK_TLV_CRITERIO_ASIGNATURA). p_max_recovery_grade (antes "p_initial_grade") sigue escribiendo PORCENTAJE_INICIAL_CALIF sin cambio de columna -- solo se corrige el nombre (nota maxima de recuperacion/nivelacion, no nota inicial). p_decimal_places y p_final_grade_editable son nuevos, al final de la firma para no romper la llamada posicional del catalogo (fila 51).';
