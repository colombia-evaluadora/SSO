-- ===========================================================================
-- Criterio de Evaluación — funciones consolidadas (última versión)
-- Generado: 2026-09-04
--
-- Este es un documento de REFERENCIA de solo lectura. NO ejecutar directamente,
-- NO es una migracion Flyway, y NO debe copiarse a postgres/migrations/.
-- Su unico proposito es reunir en un solo lugar la version vigente de cada
-- funcion del modulo, ya que con el tiempo varias han sido redefinidas
-- (CREATE OR REPLACE FUNCTION) en migraciones posteriores.
--
-- Migraciones fuente consultadas:
--   - V41__evaluation_criteria_module.sql
--   - V62__criterio_evaluacion_campos_faltantes.sql
--   - V96__fn_criterio_eval_actualizar_guarda_como_porcentaje.sql
--   - V104__criterio_evaluacion_mensajes_error_con_nombre.sql
--
-- Verificacion: se corrio
--   grep -rn "FUNCTION academico_test.fn_criterio_eval_" postgres/migrations/
-- Confirmado: V62 es la migracion mas alta que toca fn_criterio_eval_obtener;
-- V104 es la mas alta que toca fn_criterio_eval_actualizar. No se encontro
-- nada mas nuevo que V104 tocando estas funciones; el mapeo entregado
-- coincide exactamente con lo observado en el repo.
--
-- *** NOTA IMPORTANTE: fn_criterio_eval_actualizar tiene 3 OVERLOADS ***
-- Segun el encabezado de V104 (lineas 1-34), se confirmo en vivo contra
-- pg_proc que coexisten TRES firmas realmente desplegadas de esta funcion
-- (no son solo volcados historicos en el repo):
--   1) 12 argumentos, con p_decimal_places / p_final_grade_editable al final.
--   2) 14 argumentos, con p_modif_final_peraca y p_max_recovery_grade.
--      *** ESTA ES LA QUE USA PRODUCCION *** — invocada posicionalmente por
--      public.query id_query=51 con exactamente esta firma de 14 args.
--   3) 12 argumentos, variante que reemplaza p_grading_scale por
--      p_pk_tescala_valoracion (resuelve la escala vía TESCALA_VALORACION).
-- Las tres siguen vigentes en pg_proc por compatibilidad con distintos
-- llamadores historicos, y V104 las corrige y redefine a las tres (mismos
-- mensajes de error mejorados, mismas firmas/DEFAULTs/ERRCODEs de siempre).
-- fn_criterio_eval_obtener NO forma parte de este problema: es LANGUAGE sql,
-- de una sola firma, sin manejo de errores propio.
-- ===========================================================================

-- Fuente: V62__criterio_evaluacion_campos_faltantes.sql
SET search_path TO academico_test, public;

-- ---------------------------------------------------------------------------
-- DDL + migración de datos de V62, inseparable de fn_criterio_eval_obtener/
-- _actualizar de abajo (las funciones leen estas columnas). Sin esto, un
-- consolidado que solo tuviera los CREATE FUNCTION quedaría referenciando
-- columnas que nunca se crearon (FK_TLV_MODO_REDONDEAR, FK_TLV_CRITERIO_
-- ASIGNATURA, PORCENTAJE_MAXIMO_RECUPERACION) y con el dato de catálogo 494
-- todavía con su nombre viejo.
-- ---------------------------------------------------------------------------

-- 1. Columnas nuevas en TCRITERIO_EVALUACION.
ALTER TABLE academico_test.TCRITERIO_EVALUACION
    ADD COLUMN IF NOT EXISTS FK_TLV_MODO_REDONDEAR BIGINT
        REFERENCES academico_test.TLISTA_VALOR (PK_LISTA_VALOR),
    ADD COLUMN IF NOT EXISTS FK_TLV_CRITERIO_ASIGNATURA BIGINT
        REFERENCES academico_test.TLISTA_VALOR (PK_LISTA_VALOR),
    ADD COLUMN IF NOT EXISTS PORCENTAJE_MAXIMO_RECUPERACION NUMERIC(5,2);

CREATE INDEX IF NOT EXISTS IDX_TCRITERIO_EVALUACION_MODO_REDONDEAR
    ON academico_test.TCRITERIO_EVALUACION (FK_TLV_MODO_REDONDEAR);
CREATE INDEX IF NOT EXISTS IDX_TCRITERIO_EVALUACION_CRITERIO_ASIGNATURA
    ON academico_test.TCRITERIO_EVALUACION (FK_TLV_CRITERIO_ASIGNATURA);

-- 1b. Comentarios de mapeo UI <-> columna <-> lista_valor para los 10 campos
--     de la pestaña "Criterios de evaluacion" (7 preexistentes desde V22 +
--     3 nuevos de arriba).
COMMENT ON COLUMN academico_test.TCRITERIO_EVALUACION.FK_TLV_MODO_REDONDEAR IS
    'Campo UI "Regla de redondeo" (imagen, columna 3 fila 2). Llave foranea de lista valor, categoria MODO_REDONDEAR: "Hacia arriba" / "Hacia Abajo" / "Depende del valor" (~ "Al mas cercano") / "No redondear" (extra, sin campo UI). Trasladada desde TPERIODO_ACADEMICO_CONFIG (V62) — vivia en la tabla equivocada; fn_criterio_eval_actualizar/obtener (V41) la exponen como "criterios de evaluacion" del periodo, no TPERIODO_ACADEMICO_CONFIG.';
COMMENT ON COLUMN academico_test.TCRITERIO_EVALUACION.FK_TLV_CRITERIO_ASIGNATURA IS
    'Campo UI "Criterio para calcular la nota de la asignatura" (imagen, columna 2 fila 3). Llave foranea de lista valor, categoria TIPO_CALCULO: "Promediado" / "Ponderado" / "Sumatoria" / "Nota Directa" (extra, sin campo UI) — misma categoria que TACTIVIDAD.FK_TLV_TIPO_CALCULO usa a nivel de actividad, reutilizada aqui a nivel de periodo. fn_criterio_eval_actualizar (V41) ya tenia un parametro "subject_grade_criteria" pensado para esto, pero escribia por error FK_TLV_MODIF_FINAL_PERACA (un SI/NO no relacionado).';
COMMENT ON COLUMN academico_test.TCRITERIO_EVALUACION.PORCENTAJE_MAXIMO_RECUPERACION IS
    'Campo UI "Nota maxima de recuperacion" (imagen, columna 2 fila 2). Tope para que una actividad de nivelacion no iguale la nota de quien aprobo de una. Numero libre, sin lookup de TLISTA_VALOR (no existe categoria que calce con este concepto en todo el esquema).';
COMMENT ON COLUMN academico_test.TCRITERIO_EVALUACION.FK_TESCALA IS
    'Campo UI "Escala de valoracion" (imagen, columna 1 fila 1). Llave foranea a TESCALA — NO a TLISTA_VALOR. Verificado contra el servidor de test: no existe una fila unica "Escala Nacional" en TESCALA (22 escalas, todas institucionales: "ESCALA DE VALORACION INSTITUCIONAL", "DECRETO 1290...", etc.) — el concepto de "escala nacional" es el marco legal (Superior/Alto/Basico/Bajo, Decreto 1290), no una fila del catalogo; TVALORACION tiene 27 filas con nombres tipo Superior/Alto/Basico/Bajo repartidas entre distintas TESCALA institucionales, cada institucion las nombra/codifica a su manera (ej. pk_tvaloracion 158-165, 218-223, 336-339). El vinculo TESCALA<->periodo pasa por TNIVEL_ESCALA (fk_tescala + fk_periodo_academico), no hay columna fk_tescala directa en TVALORACION.';
COMMENT ON COLUMN academico_test.TCRITERIO_EVALUACION.FK_TLV_FORMATO_CALIFICACION IS
    'Campo UI "Formato de calificacion" (imagen, columna 2 fila 1). Llave foranea de lista valor, categoria FORMATO_CALIFICACION. Verificado contra el servidor de test: 6 filas activas, no 3 — "DE CERO A CINCO" (51857), "DE CERO A DIEZ" (51882), "DE CERO A CIEN" (51889) calzan con la especificacion; la categoria tiene ademas "Simbolos" (51861), "Valoraciones" (51893) y "Caritas" (51914), formatos no numericos fuera del alcance de la especificacion de esta pestaña (probablemente usados en otra UI, no en "Criterios de evaluacion").';
COMMENT ON COLUMN academico_test.TCRITERIO_EVALUACION.FK_TLV_DESEMPENO_SIN_CALIF IS
    'Campo UI "Sin calificaciones" (imagen, columna 3 fila 1). Llave foranea de lista valor, categoria DESEMPENIOSUGERIR. Verificado contra el servidor de test, texto exacto: "Menor calificación posible" (521) / "Ninguna Calificación" (522) — nota que asume el sistema si un docente deja una actividad o asignatura sin calificar.';
COMMENT ON COLUMN academico_test.TCRITERIO_EVALUACION.PORCENTAJE_INICIAL_CALIF IS
    'Campo UI "Nota inicial para las calificaciones" (imagen, columna 1 fila 2). Numero libre, sin lookup de TLISTA_VALOR — limite inferior real de la escala institucional (ej. 0, 1, 10); valores reales observados en la tabla: 0,1,10,20,30,40.';
COMMENT ON COLUMN academico_test.TCRITERIO_EVALUACION.FK_TLV_ELEMENTO_DEF IS
    'Campo UI "Elementos para calcular la nota de la asignatura" (imagen, columna 1 fila 3). Llave foranea de lista valor, categoria ELEMENTO_CALCULO_DEF: "Actividades" (495) / "Unidades" (494, renombrada por V62 desde "Descriptores de desempeño" — ver seccion 1c).';
COMMENT ON COLUMN academico_test.TCRITERIO_EVALUACION.FK_TLV_CRITERIO_AREA IS
    'Campo UI "Criterio para calcular la nota del area" (imagen, columna 3 fila 3). Llave foranea de lista valor, categoria CRITERIO_AREA. Verificado contra el servidor de test, texto exacto (distinto de la redaccion de la especificacion funcional, mismo significado): "Promediar las Asignaturas" (510, ~"Promediar las asignaturas") / "Cada asignatura tiene un porcentaje" (508, ~"Ponderar las asignaturas") / "Proporcional a la intensidad horaria" (509, ~"De acuerdo a la intensidad horaria").';
COMMENT ON COLUMN academico_test.TCRITERIO_EVALUACION.FK_TLV_CRITERIO_FINAL IS
    'Campo UI "Criterio para calcular la nota final" (imagen, columna 1 fila 4). Llave foranea de lista valor, categoria CRITERIO_FINAL_PERACA. Verificado contra el servidor de test, texto exacto (distinto de la redaccion de la especificacion funcional, mismo significado): "Equitativamente de acuerdo al número de PE" (501, ~"Promedio de periodos") / "De acuerdo al porcentaje de cada PE" (502, ~"Ponderacion de periodos"). PE = Periodo de Evaluacion.';

-- 1c. Renombra el dato de TLISTA_VALOR pk_lista_valor=494 (categoria
--     ELEMENTO_CALCULO_DEF) de "Descriptores de desempeño" a "Unidades".
UPDATE academico_test.TLISTA_VALOR
   SET NOMBRE = 'Unidades',
       MODIFIED_BY = CURRENT_USER,
       MODIFIED_AT = CURRENT_TIMESTAMP
 WHERE PK_LISTA_VALOR = 494
   AND CATEGORIA = 'ELEMENTO_CALCULO_DEF'
   AND NOMBRE = 'Descriptores de desempeño';

-- 2 + 3. Backfill de FK_TLV_MODO_REDONDEAR desde TPERIODO_ACADEMICO_CONFIG
--    (vivia ahi por error) hacia TCRITERIO_EVALUACION, y drop de la columna
--    de origen. Guardado en un DO $$ idempotente: si la columna de origen ya
--    no existe (corrida previa completa), sale sin hacer nada.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
          FROM information_schema.columns
         WHERE table_schema = 'academico_test'
           AND table_name   = 'tperiodo_academico_config'
           AND column_name  = 'fk_tlv_modo_redondear'
    ) THEN
        RETURN;
    END IF;

    UPDATE academico_test.TCRITERIO_EVALUACION ce
       SET FK_TLV_MODO_REDONDEAR = cfg.FK_TLV_MODO_REDONDEAR
      FROM academico_test.TPERIODO_ACADEMICO_CONFIG cfg
     WHERE cfg.PK_TPERIODO_ACADEMICO_CONFIG = ce.PK_TCRITERIO_EVALUACION
       AND cfg.FK_TLV_MODO_REDONDEAR IS NOT NULL
       AND ce.FK_TLV_MODO_REDONDEAR IS NULL;

    EXECUTE 'DROP INDEX IF EXISTS academico_test.IDX_TPERIODO_ACADEMICO_CFG_21';
    EXECUTE 'ALTER TABLE academico_test.TPERIODO_ACADEMICO_CONFIG
                DROP CONSTRAINT IF EXISTS FK_TPERIDO_ACADEMICO_CONFIG_14,
                DROP COLUMN IF EXISTS FK_TLV_MODO_REDONDEAR';
END $$;

-- 4. DROP previo obligatorio: Postgres rechaza CREATE OR REPLACE cuando
--    cambia el RETURNS TABLE (decimal_places/final_grade_editable nuevos al
--    final), aunque los parametros de entrada sean identicos.
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
    initial_grade NUMERIC,
    decimal_places NUMERIC,
    final_grade_editable BIGINT, final_grade_editable_name VARCHAR,
    max_recovery_grade NUMERIC
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

        round(ce.PORCENTAJE_INICIAL_CALIF / 100
              * (CASE UPPER(TRIM(COALESCE(formato.NOMBRE, ''))) WHEN 'DE CERO A CINCO' THEN 5 WHEN 'DE CERO A DIEZ' THEN 10 ELSE 100 END), 2),

        ce.NUMERO_DECIMALES,

        ce.FK_TLV_MODIF_FINAL_PERACA,
        modif_final.NOMBRE,

        round(ce.PORCENTAJE_MAXIMO_RECUPERACION / 100
              * (CASE UPPER(TRIM(COALESCE(formato.NOMBRE, ''))) WHEN 'DE CERO A CINCO' THEN 5 WHEN 'DE CERO A DIEZ' THEN 10 ELSE 100 END), 2)

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
      AND academico_test.fn_periodo_puede_ver(
          p_pk_usuario_solicitante,
          p_pk_periodo
      );
$$;

COMMENT ON FUNCTION academico_test.fn_criterio_eval_obtener(BIGINT, BIGINT) IS
    'V62: rounding_mode ahora lee FK_TLV_MODO_REDONDEAR (antes leia NUMERO_DECIMALES por error) y gana su propio rounding_mode_name, igual que el resto de lookups. subject_grade_criteria ahora lee la columna dedicada FK_TLV_CRITERIO_ASIGNATURA (antes leia FK_TLV_MODIF_FINAL_PERACA por error). initial_grade y max_recovery_grade ahora convierten PORCENTAJE_INICIAL_CALIF/PORCENTAJE_MAXIMO_RECUPERACION de vuelta al rango real del formato de calificacion (V22: "Porcentaje inicial del rango de calificaciones" -- la columna SIEMPRE fue un %, nunca el valor crudo; V41 jamas convirtio, bug heredado corregido aqui). Regla identica a V42 (fn_escala_guardar_bulk/fn_escala_listar: "las notas se guardan en % contra el formato del periodo"), pero comparando contra TLISTA_VALOR.NOMBRE en vez de VALOR -- V42 compara contra VALOR ("CINCO"/"DIEZ"/"CIEN", confirmado con datos reales), que nunca calza con los literales "DE CERO A CINCO"/"DE CERO A DIEZ" de su propio CASE, asi que su rango cae siempre al ELSE (100); no se replica ese bug aca. decimal_places y final_grade_editable son nuevos, exponen NUMERO_DECIMALES y FK_TLV_MODIF_FINAL_PERACA bajo su nombre real para no perder esa capacidad.';

-- Fuente: V104__criterio_evaluacion_mensajes_error_con_nombre.sql
-- Overload 1 de 3: 12 argumentos, con p_decimal_places / p_final_grade_editable al final (oid 39517 en pg_proc)
CREATE OR REPLACE FUNCTION academico_test.fn_criterio_eval_actualizar(
    p_pk_periodo bigint,
    p_grading_format bigint DEFAULT NULL::bigint,
    p_grading_scale bigint DEFAULT NULL::bigint,
    p_set_grading_scale boolean DEFAULT false,
    p_period_calc_elements bigint DEFAULT NULL::bigint,
    p_modif_final_peraca bigint DEFAULT NULL::bigint,
    p_subject_grade_criteria bigint DEFAULT NULL::bigint,
    p_final_grade_criteria bigint DEFAULT NULL::bigint,
    p_area_grade_criteria bigint DEFAULT NULL::bigint,
    p_student_wo_grades bigint DEFAULT NULL::bigint,
    p_rounding_mode bigint DEFAULT NULL::bigint,
    p_initial_grade numeric DEFAULT NULL::numeric,
    p_max_recovery_grade numeric DEFAULT NULL::numeric,
    p_pk_usuario_solicitante bigint DEFAULT NULL::bigint
)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_n INT;
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_escala_actual BIGINT;
    v_fk_tescala BIGINT;
    v_formato_id BIGINT;
    v_formato_nombre VARCHAR;
    v_formato_max NUMERIC;
    v_initial_pct NUMERIC;
    v_max_recovery_pct NUMERIC;
    v_tmp_nombre VARCHAR;
    v_tmp_nombre2 VARCHAR;
    v_establecimiento_id BIGINT;
    v_periodo_nombre VARCHAR;
BEGIN
    v_establecimiento_id := academico_test.fn_periodo_establecimiento(p_pk_periodo);
    -- CU-86e2w4xdt: gate por (EE, sede, jornada) del periodo del criterio.
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_establecimiento_id,
        academico_test.fn_periodo_sede(p_pk_periodo),
        academico_test.fn_periodo_jornada(p_pk_periodo), 'EDITAR'
    );
    -- No habia una variable que resolviera el nombre del periodo sin
    -- condicion (v_tmp_nombre2 solo se llena en la rama de error de escala);
    -- se agrega para la etiqueta de auditoria.
    SELECT NOMBRE INTO v_periodo_nombre FROM academico_test.TPERIODO_ACADEMICO
     WHERE PK_TPERIODO_ACADEMICO = p_pk_periodo;

    IF p_set_grading_scale AND p_grading_scale IS NOT NULL THEN
        SELECT tv.FK_TESCALA
          INTO v_fk_tescala
          FROM academico_test.TESCALA_VALORACION tv
          JOIN academico_test.TESCALA t ON t.PK_TESCALA = tv.FK_TESCALA AND t.ACTIVE = TRUE
         WHERE tv.PK_TESCALA_VALORACION = p_grading_scale
           AND tv.ACTIVE = TRUE;

        IF v_fk_tescala IS NULL THEN
            SELECT v.NOMBRE INTO v_tmp_nombre
              FROM academico_test.TESCALA_VALORACION tv
              JOIN academico_test.TVALORACION v ON v.PK_TVALORACION = tv.FK_TVALORACION
             WHERE tv.PK_TESCALA_VALORACION = p_grading_scale;
            IF v_tmp_nombre IS NOT NULL THEN
                RAISE EXCEPTION 'La valoracion "%" existe pero esta inactiva', v_tmp_nombre
                    USING ERRCODE = '23503';
            ELSE
                RAISE EXCEPTION 'La valoracion seleccionada no existe' USING ERRCODE = '23503';
            END IF;
        END IF;

        IF NOT EXISTS (
            SELECT 1
            FROM academico_test.TNIVEL_ESCALA
            WHERE FK_TESCALA = v_fk_tescala
              AND FK_PERIODO_ACADEMICO = p_pk_periodo
              AND ACTIVE = TRUE
        ) THEN
            SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TESCALA WHERE PK_TESCALA = v_fk_tescala;
            SELECT NOMBRE INTO v_tmp_nombre2 FROM academico_test.TPERIODO_ACADEMICO WHERE PK_TPERIODO_ACADEMICO = p_pk_periodo;
            RAISE EXCEPTION 'La escala "%" no pertenece al periodo academico "%"',
                v_tmp_nombre, v_tmp_nombre2
                USING ERRCODE = '22023';
        END IF;
    END IF;

    IF p_grading_format IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_grading_format AND ACTIVE = TRUE
           AND CATEGORIA = 'FORMATO_CALIFICACION'
    ) THEN
        SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_grading_format;
        IF v_tmp_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'El formato de calificacion "%" no es valido para este campo', v_tmp_nombre
                USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'El formato de calificacion seleccionado no existe' USING ERRCODE = '23503';
        END IF;
    END IF;

    IF p_period_calc_elements IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_period_calc_elements AND ACTIVE = TRUE
           AND CATEGORIA = 'ELEMENTO_CALCULO_DEF'
    ) THEN
        SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_period_calc_elements;
        IF v_tmp_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'El elemento de calculo del periodo "%" no es valido para este campo', v_tmp_nombre
                USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'El elemento de calculo del periodo seleccionado no existe' USING ERRCODE = '23503';
        END IF;
    END IF;

    IF p_modif_final_peraca IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_modif_final_peraca AND ACTIVE = TRUE
    ) THEN
        SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_modif_final_peraca;
        IF v_tmp_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'El valor "%" existe pero esta inactivo en el catalogo', v_tmp_nombre
                USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'El valor seleccionado no existe en el catalogo' USING ERRCODE = '23503';
        END IF;
    END IF;

    IF p_subject_grade_criteria IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_subject_grade_criteria AND ACTIVE = TRUE
           AND CATEGORIA = 'TIPO_CALCULO'
    ) THEN
        SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_subject_grade_criteria;
        IF v_tmp_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'El criterio de calculo de la asignatura "%" no es valido para este campo', v_tmp_nombre
                USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'El criterio de calculo de la asignatura seleccionado no existe' USING ERRCODE = '23503';
        END IF;
    END IF;

    IF p_final_grade_criteria IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_final_grade_criteria AND ACTIVE = TRUE
           AND CATEGORIA = 'CRITERIO_FINAL_PERACA'
    ) THEN
        SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_final_grade_criteria;
        IF v_tmp_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'El criterio de nota final "%" no es valido para este campo', v_tmp_nombre
                USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'El criterio de nota final seleccionado no existe' USING ERRCODE = '23503';
        END IF;
    END IF;

    IF p_area_grade_criteria IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_area_grade_criteria AND ACTIVE = TRUE
           AND CATEGORIA = 'CRITERIO_AREA'
    ) THEN
        SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_area_grade_criteria;
        IF v_tmp_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'El criterio de nota de area "%" no es valido para este campo', v_tmp_nombre
                USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'El criterio de nota de area seleccionado no existe' USING ERRCODE = '23503';
        END IF;
    END IF;

    IF p_student_wo_grades IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_student_wo_grades AND ACTIVE = TRUE
           AND CATEGORIA = 'DESEMPENIOSUGERIR'
    ) THEN
        SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_student_wo_grades;
        IF v_tmp_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'El desempeno sugerido sin calificacion "%" no es valido para este campo', v_tmp_nombre
                USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'El desempeno sugerido sin calificacion seleccionado no existe' USING ERRCODE = '23503';
        END IF;
    END IF;

    IF p_rounding_mode IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_rounding_mode AND ACTIVE = TRUE
           AND CATEGORIA = 'MODO_REDONDEAR'
    ) THEN
        SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_rounding_mode;
        IF v_tmp_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'El modo de redondeo "%" no es valido para este campo', v_tmp_nombre
                USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'El modo de redondeo seleccionado no existe' USING ERRCODE = '23503';
        END IF;
    END IF;

    SELECT FK_TESCALA
      INTO v_escala_actual
      FROM academico_test.TCRITERIO_EVALUACION
     WHERE PK_TCRITERIO_EVALUACION = p_pk_periodo
       AND ACTIVE = TRUE;

    IF p_initial_grade IS NOT NULL OR p_max_recovery_grade IS NOT NULL THEN
        SELECT COALESCE(p_grading_format, FK_TLV_FORMATO_CALIFICACION)
          INTO v_formato_id
          FROM academico_test.TCRITERIO_EVALUACION
         WHERE PK_TCRITERIO_EVALUACION = p_pk_periodo
           AND ACTIVE = TRUE;

        SELECT NOMBRE INTO v_formato_nombre
          FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = v_formato_id;

        v_formato_max := CASE UPPER(TRIM(COALESCE(v_formato_nombre, '')))
                              WHEN 'DE CERO A CINCO' THEN 5
                              WHEN 'DE CERO A DIEZ' THEN 10
                              ELSE 100
                          END;

        IF p_initial_grade IS NOT NULL THEN
            v_initial_pct := ROUND(p_initial_grade / v_formato_max * 100, 2);
        END IF;

        IF p_max_recovery_grade IS NOT NULL THEN
            v_max_recovery_pct := ROUND(p_max_recovery_grade / v_formato_max * 100, 2);
        END IF;
    END IF;

    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Actualización del criterio de evaluación del periodo %s', v_periodo_nombre),
        v_establecimiento_id);

    UPDATE academico_test.TCRITERIO_EVALUACION
       SET
           FK_TLV_FORMATO_CALIFICACION = COALESCE(p_grading_format, FK_TLV_FORMATO_CALIFICACION),
           FK_TESCALA = CASE WHEN p_set_grading_scale THEN v_fk_tescala ELSE FK_TESCALA END,
           FK_TLV_ELEMENTO_DEF = COALESCE(p_period_calc_elements, FK_TLV_ELEMENTO_DEF),
           FK_TLV_MODIF_FINAL_PERACA = COALESCE(p_modif_final_peraca, FK_TLV_MODIF_FINAL_PERACA),
           FK_TLV_CRITERIO_ASIGNATURA = COALESCE(p_subject_grade_criteria, FK_TLV_CRITERIO_ASIGNATURA),
           FK_TLV_CRITERIO_FINAL = COALESCE(p_final_grade_criteria, FK_TLV_CRITERIO_FINAL),
           FK_TLV_CRITERIO_AREA = COALESCE(p_area_grade_criteria, FK_TLV_CRITERIO_AREA),
           FK_TLV_DESEMPENO_SIN_CALIF = COALESCE(p_student_wo_grades, FK_TLV_DESEMPENO_SIN_CALIF),
           FK_TLV_MODO_REDONDEAR = COALESCE(p_rounding_mode, FK_TLV_MODO_REDONDEAR),
           PORCENTAJE_INICIAL_CALIF = COALESCE(v_initial_pct, PORCENTAJE_INICIAL_CALIF),
           PORCENTAJE_MAXIMO_RECUPERACION = COALESCE(v_max_recovery_pct, PORCENTAJE_MAXIMO_RECUPERACION),
           MODIFIED_BY = v_audit,
           MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TCRITERIO_EVALUACION = p_pk_periodo
       AND ACTIVE = TRUE;

    GET DIAGNOSTICS v_n = ROW_COUNT;

    IF v_n = 0 THEN
        SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TPERIODO_ACADEMICO WHERE PK_TPERIODO_ACADEMICO = p_pk_periodo;
        IF v_tmp_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'No existe criterio de evaluacion activo para el periodo "%"', v_tmp_nombre
                USING ERRCODE = 'P0002';
        ELSE
            RAISE EXCEPTION 'El periodo academico seleccionado no existe' USING ERRCODE = 'P0002';
        END IF;
    END IF;

    IF p_set_grading_scale AND p_grading_scale IS NOT NULL AND v_fk_tescala IS DISTINCT FROM v_escala_actual THEN
        PERFORM academico_test.fn_escala_propagar(p_pk_periodo, v_fk_tescala, v_audit);
    END IF;

    RETURN p_pk_periodo;
END;
$$;

-- Fuente: V104__criterio_evaluacion_mensajes_error_con_nombre.sql
-- Overload 2 de 3: 14 argumentos, con p_modif_final_peraca / p_max_recovery_grade (oid 39651) — ESTA ES LA DE PRODUCCION (public.query id_query=51, invocacion posicional)
CREATE OR REPLACE FUNCTION academico_test.fn_criterio_eval_actualizar(
    p_pk_periodo bigint,
    p_grading_format bigint DEFAULT NULL::bigint,
    p_grading_scale bigint DEFAULT NULL::bigint,
    p_set_grading_scale boolean DEFAULT false,
    p_period_calc_elements bigint DEFAULT NULL::bigint,
    p_subject_grade_criteria bigint DEFAULT NULL::bigint,
    p_final_grade_criteria bigint DEFAULT NULL::bigint,
    p_area_grade_criteria bigint DEFAULT NULL::bigint,
    p_student_wo_grades bigint DEFAULT NULL::bigint,
    p_rounding_mode numeric DEFAULT NULL::numeric,
    p_initial_grade numeric DEFAULT NULL::numeric,
    p_pk_usuario_solicitante bigint DEFAULT NULL::bigint,
    p_decimal_places numeric DEFAULT NULL::numeric,
    p_final_grade_editable bigint DEFAULT NULL::bigint,
    p_max_recovery_grade numeric DEFAULT NULL::numeric
)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_n INT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_escala_actual BIGINT;
    v_fmt_nombre TEXT; v_max NUMERIC;
    v_tmp_nombre VARCHAR; v_tmp_nombre2 VARCHAR;
    v_establecimiento_id BIGINT;
    v_periodo_nombre VARCHAR;
BEGIN
    v_establecimiento_id := academico_test.fn_periodo_establecimiento(p_pk_periodo);
    -- CU-86e2w4xdt: gate por (EE, sede, jornada) del periodo del criterio.
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_establecimiento_id,
        academico_test.fn_periodo_sede(p_pk_periodo),
        academico_test.fn_periodo_jornada(p_pk_periodo), 'EDITAR');
    -- No habia una variable que resolviera el nombre del periodo sin
    -- condicion; se agrega para la etiqueta de auditoria.
    SELECT NOMBRE INTO v_periodo_nombre FROM academico_test.TPERIODO_ACADEMICO
     WHERE PK_TPERIODO_ACADEMICO = p_pk_periodo;
    SELECT lv.NOMBRE INTO v_fmt_nombre
      FROM academico_test.TLISTA_VALOR lv
     WHERE lv.PK_LISTA_VALOR = COALESCE(p_grading_format, (
         SELECT FK_TLV_FORMATO_CALIFICACION FROM academico_test.TCRITERIO_EVALUACION
          WHERE PK_TCRITERIO_EVALUACION = p_pk_periodo AND ACTIVE = TRUE
     ));
    v_max := CASE UPPER(TRIM(COALESCE(v_fmt_nombre, '')))
                WHEN 'DE CERO A CINCO' THEN 5
                WHEN 'DE CERO A DIEZ'  THEN 10
                ELSE 100
              END;
    IF p_set_grading_scale AND p_grading_scale IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM academico_test.TESCALA WHERE PK_TESCALA = p_grading_scale AND ACTIVE = TRUE
        ) THEN
            SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TESCALA WHERE PK_TESCALA = p_grading_scale;
            IF v_tmp_nombre IS NOT NULL THEN
                RAISE EXCEPTION 'La escala de valoracion "%" existe pero esta inactiva', v_tmp_nombre
                    USING ERRCODE = '23503';
            ELSE
                RAISE EXCEPTION 'La escala de valoracion seleccionada no existe' USING ERRCODE = '23503';
            END IF;
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM academico_test.TNIVEL_ESCALA
             WHERE FK_TESCALA = p_grading_scale AND FK_PERIODO_ACADEMICO = p_pk_periodo AND ACTIVE = TRUE
        ) THEN
            SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TESCALA WHERE PK_TESCALA = p_grading_scale;
            SELECT NOMBRE INTO v_tmp_nombre2 FROM academico_test.TPERIODO_ACADEMICO WHERE PK_TPERIODO_ACADEMICO = p_pk_periodo;
            RAISE EXCEPTION 'La escala "%" no pertenece al periodo academico "%"', v_tmp_nombre, v_tmp_nombre2
                USING ERRCODE = '22023';
        END IF;
    END IF;
    SELECT FK_TESCALA INTO v_escala_actual
      FROM academico_test.TCRITERIO_EVALUACION
     WHERE PK_TCRITERIO_EVALUACION = p_pk_periodo AND ACTIVE = TRUE;
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Actualización del criterio de evaluación del periodo %s', v_periodo_nombre),
        v_establecimiento_id);

    UPDATE academico_test.TCRITERIO_EVALUACION SET
        FK_TLV_FORMATO_CALIFICACION = COALESCE(p_grading_format, FK_TLV_FORMATO_CALIFICACION),
        FK_TESCALA                  = CASE WHEN p_set_grading_scale THEN p_grading_scale ELSE FK_TESCALA END,
        FK_TLV_ELEMENTO_DEF         = COALESCE(p_period_calc_elements, FK_TLV_ELEMENTO_DEF),
        FK_TLV_CRITERIO_ASIGNATURA  = COALESCE(p_subject_grade_criteria, FK_TLV_CRITERIO_ASIGNATURA),
        FK_TLV_CRITERIO_FINAL       = COALESCE(p_final_grade_criteria, FK_TLV_CRITERIO_FINAL),
        FK_TLV_CRITERIO_AREA        = COALESCE(p_area_grade_criteria, FK_TLV_CRITERIO_AREA),
        FK_TLV_DESEMPENO_SIN_CALIF  = COALESCE(p_student_wo_grades, FK_TLV_DESEMPENO_SIN_CALIF),
        FK_TLV_MODO_REDONDEAR       = COALESCE(p_rounding_mode::BIGINT, FK_TLV_MODO_REDONDEAR),
        PORCENTAJE_INICIAL_CALIF    = COALESCE(p_initial_grade / v_max * 100, PORCENTAJE_INICIAL_CALIF),
        NUMERO_DECIMALES            = COALESCE(p_decimal_places, NUMERO_DECIMALES),
        FK_TLV_MODIF_FINAL_PERACA   = COALESCE(p_final_grade_editable, FK_TLV_MODIF_FINAL_PERACA),
        PORCENTAJE_MAXIMO_RECUPERACION = COALESCE(p_max_recovery_grade / v_max * 100, PORCENTAJE_MAXIMO_RECUPERACION),
        MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TCRITERIO_EVALUACION = p_pk_periodo AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN
        SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TPERIODO_ACADEMICO WHERE PK_TPERIODO_ACADEMICO = p_pk_periodo;
        IF v_tmp_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'No existe criterio de evaluacion activo para el periodo "%"', v_tmp_nombre
                USING ERRCODE = 'P0002';
        ELSE
            RAISE EXCEPTION 'El periodo academico seleccionado no existe' USING ERRCODE = 'P0002';
        END IF;
    END IF;

    IF p_set_grading_scale AND p_grading_scale IS NOT NULL
       AND p_grading_scale IS DISTINCT FROM v_escala_actual THEN
        PERFORM academico_test.fn_escala_propagar(p_pk_periodo, p_grading_scale, v_audit);
    END IF;

    RETURN p_pk_periodo;
END;
$$;

-- Fuente: V104__criterio_evaluacion_mensajes_error_con_nombre.sql
-- Overload 3 de 3: 12 argumentos, con p_pk_tescala_valoracion en vez de p_grading_scale (oid 40148)
CREATE OR REPLACE FUNCTION academico_test.fn_criterio_eval_actualizar(
    p_pk_periodo bigint,
    p_grading_format bigint DEFAULT NULL::bigint,
    p_pk_tescala_valoracion bigint DEFAULT NULL::bigint,
    p_set_grading_scale boolean DEFAULT false,
    p_period_calc_elements bigint DEFAULT NULL::bigint,
    p_subject_grade_criteria bigint DEFAULT NULL::bigint,
    p_final_grade_criteria bigint DEFAULT NULL::bigint,
    p_area_grade_criteria bigint DEFAULT NULL::bigint,
    p_student_wo_grades bigint DEFAULT NULL::bigint,
    p_rounding_mode numeric DEFAULT NULL::numeric,
    p_initial_grade numeric DEFAULT NULL::numeric,
    p_pk_usuario_solicitante bigint DEFAULT NULL::bigint
)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_n INT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_escala_actual BIGINT;
    v_grading_scale BIGINT;
    v_tmp_nombre VARCHAR; v_tmp_nombre2 VARCHAR;
    v_establecimiento_id BIGINT;
    v_periodo_nombre VARCHAR;
BEGIN
    v_establecimiento_id := academico_test.fn_periodo_establecimiento(p_pk_periodo);
    -- CU-86e2w4xdt: gate por (EE, sede, jornada) del periodo del criterio.
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_establecimiento_id,
        academico_test.fn_periodo_sede(p_pk_periodo),
        academico_test.fn_periodo_jornada(p_pk_periodo), 'EDITAR');
    -- No habia una variable que resolviera el nombre del periodo sin
    -- condicion; se agrega para la etiqueta de auditoria.
    SELECT NOMBRE INTO v_periodo_nombre FROM academico_test.TPERIODO_ACADEMICO
     WHERE PK_TPERIODO_ACADEMICO = p_pk_periodo;

    IF p_set_grading_scale AND p_pk_tescala_valoracion IS NOT NULL THEN
        SELECT FK_ESCALA INTO v_grading_scale
          FROM academico_test.TESCALA_VALORACION
         WHERE PK_TESCALA_VALORACION = p_pk_tescala_valoracion AND ACTIVE = TRUE;

        IF v_grading_scale IS NULL THEN
            SELECT v.NOMBRE INTO v_tmp_nombre
              FROM academico_test.TESCALA_VALORACION tv
              JOIN academico_test.TVALORACION v ON v.PK_TVALORACION = tv.FK_TVALORACION
             WHERE tv.PK_TESCALA_VALORACION = p_pk_tescala_valoracion;
            IF v_tmp_nombre IS NOT NULL THEN
                RAISE EXCEPTION 'La valoracion "%" existe pero esta inactiva', v_tmp_nombre
                    USING ERRCODE = '23503';
            ELSE
                RAISE EXCEPTION 'La valoracion seleccionada no existe' USING ERRCODE = '23503';
            END IF;
        END IF;

        IF NOT EXISTS (
            SELECT 1 FROM academico_test.TESCALA WHERE PK_TESCALA = v_grading_scale AND ACTIVE = TRUE
        ) THEN
            SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TESCALA WHERE PK_TESCALA = v_grading_scale;
            IF v_tmp_nombre IS NOT NULL THEN
                RAISE EXCEPTION 'La escala de valoracion "%" existe pero esta inactiva', v_tmp_nombre
                    USING ERRCODE = '23503';
            ELSE
                RAISE EXCEPTION 'La escala de valoracion seleccionada no existe' USING ERRCODE = '23503';
            END IF;
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM academico_test.TNIVEL_ESCALA
             WHERE FK_TESCALA = v_grading_scale AND FK_PERIODO_ACADEMICO = p_pk_periodo AND ACTIVE = TRUE
        ) THEN
            SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TESCALA WHERE PK_TESCALA = v_grading_scale;
            SELECT NOMBRE INTO v_tmp_nombre2 FROM academico_test.TPERIODO_ACADEMICO WHERE PK_TPERIODO_ACADEMICO = p_pk_periodo;
            RAISE EXCEPTION 'La escala "%" no pertenece al periodo academico "%"', v_tmp_nombre, v_tmp_nombre2
                USING ERRCODE = '22023';
        END IF;
    END IF;

    SELECT FK_TESCALA INTO v_escala_actual
      FROM academico_test.TCRITERIO_EVALUACION
     WHERE PK_TCRITERIO_EVALUACION = p_pk_periodo AND ACTIVE = TRUE;

    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Actualización del criterio de evaluación del periodo %s', v_periodo_nombre),
        v_establecimiento_id);

    UPDATE academico_test.TCRITERIO_EVALUACION SET
        FK_TLV_FORMATO_CALIFICACION = COALESCE(p_grading_format, FK_TLV_FORMATO_CALIFICACION),
        FK_TESCALA                  = CASE WHEN p_set_grading_scale THEN v_grading_scale ELSE FK_TESCALA END,
        FK_TLV_ELEMENTO_DEF         = COALESCE(p_period_calc_elements, FK_TLV_ELEMENTO_DEF),
        FK_TLV_MODIF_FINAL_PERACA   = COALESCE(p_subject_grade_criteria, FK_TLV_MODIF_FINAL_PERACA),
        FK_TLV_CRITERIO_FINAL       = COALESCE(p_final_grade_criteria, FK_TLV_CRITERIO_FINAL),
        FK_TLV_CRITERIO_AREA        = COALESCE(p_area_grade_criteria, FK_TLV_CRITERIO_AREA),
        FK_TLV_DESEMPENO_SIN_CALIF  = COALESCE(p_student_wo_grades, FK_TLV_DESEMPENO_SIN_CALIF),
        NUMERO_DECIMALES            = COALESCE(p_rounding_mode, NUMERO_DECIMALES),
        PORCENTAJE_INICIAL_CALIF    = COALESCE(p_initial_grade, PORCENTAJE_INICIAL_CALIF),
        MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TCRITERIO_EVALUACION = p_pk_periodo AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN
        SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TPERIODO_ACADEMICO WHERE PK_TPERIODO_ACADEMICO = p_pk_periodo;
        IF v_tmp_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'No existe criterio de evaluacion activo para el periodo "%"', v_tmp_nombre
                USING ERRCODE = 'P0002';
        ELSE
            RAISE EXCEPTION 'El periodo academico seleccionado no existe' USING ERRCODE = 'P0002';
        END IF;
    END IF;

    IF p_set_grading_scale AND v_grading_scale IS NOT NULL
       AND v_grading_scale IS DISTINCT FROM v_escala_actual THEN
        PERFORM academico_test.fn_escala_propagar(p_pk_periodo, v_grading_scale, v_audit);
    END IF;

    RETURN p_pk_periodo;
END;
$$;
