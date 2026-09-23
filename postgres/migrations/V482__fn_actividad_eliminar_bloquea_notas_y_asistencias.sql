-- ===========================================================================
-- V482 — Borrar una actividad no puede llevarse notas ni asistencias.
-- El bloqueo solo miraba TACTIVIDAD_NOTA.CALIFICACION: dejaba borrar una
-- actividad con nota solo en DEFINITIVA, con observaciones formativas
-- (CALIFICABLE='N'), con capturas de rúbrica/cotejo/escala o con
-- asistencias tomadas por actividad (TASISTENCIA.FK_TACTIVIDAD, preescolar).
-- Cada bloqueo es un validador propio; fn_actividad_eliminar queda como
-- wrapper (existencia → estado → gate → dependencias) sobre un núcleo
-- _interno que hace la cascada.
-- Depende de: V220 (TASISTENCIA.FK_TACTIVIDAD), V224 (versión previa),
-- V226/V227 (capturas), V408 (fn_actividad_recuperacion_revertir).
-- ===========================================================================

SET search_path TO academico_test, public;

-- ---------------------------------------------------------------------------
-- 1. Validadores: lanzan 23503 o no hacen nada.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_sin_notas(
    p_pk_tactividad BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_estudiantes BIGINT;
BEGIN
    -- Cuenta como tomada la misma nota que cuenta como "evaluado" en el
    -- progreso de la actividad, más cualquier captura de instrumento: una
    -- rúbrica llena sin nota consolidada también es trabajo del docente.
    SELECT COUNT(DISTINCT ae.PK_TACTIVIDAD_ESTUDIANTE) INTO v_estudiantes
      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
     WHERE ae.FK_TACTIVIDAD = p_pk_tactividad
       AND ae.ACTIVE = TRUE
       AND (EXISTS (SELECT 1 FROM academico_test.TACTIVIDAD_NOTA n
                     WHERE n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                       AND n.ACTIVE = TRUE
                       AND (COALESCE(n.DEFINITIVA, n.CALIFICACION) IS NOT NULL
                            OR NULLIF(TRIM(n.OBSERVACION), '') IS NOT NULL))
         OR EXISTS (SELECT 1 FROM academico_test.TACTIVIDAD_RUBRICA_EVALUACION re
                     WHERE re.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE AND re.ACTIVE = TRUE)
         OR EXISTS (SELECT 1 FROM academico_test.TACTIVIDAD_COTEJO_EVALUACION ce
                     WHERE ce.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE AND ce.ACTIVE = TRUE)
         OR EXISTS (SELECT 1 FROM academico_test.TACTIVIDAD_ESCALA_EVALUACION ee
                     WHERE ee.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE AND ee.ACTIVE = TRUE));

    IF v_estudiantes > 0 THEN
        RAISE EXCEPTION 'La actividad "%" ya tiene notas u observaciones registradas para % estudiante(s); no se puede eliminar',
            (SELECT TITULO FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_pk_tactividad), v_estudiantes
            USING ERRCODE = '23503',
                  HINT = 'Anule las calificaciones y observaciones de los estudiantes antes de eliminar la actividad';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_validar_sin_notas(BIGINT)
    IS 'INTERNO: 23503 si algún estudiante activo de la actividad tiene nota (DEFINITIVA o CALIFICACION), observación, o captura de rúbrica / lista de cotejo / escala activa. Lo usa fn_actividad_eliminar.';

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_sin_asistencias(
    p_pk_tactividad BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_registros BIGINT;
    v_fechas    BIGINT;
BEGIN
    SELECT COUNT(*), COUNT(DISTINCT FECHA) INTO v_registros, v_fechas
      FROM academico_test.TASISTENCIA
     WHERE FK_TACTIVIDAD = p_pk_tactividad
       AND ACTIVE = TRUE;

    IF v_registros > 0 THEN
        RAISE EXCEPTION 'La actividad "%" tiene % registro(s) de asistencia en % fecha(s); no se puede eliminar',
            (SELECT TITULO FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_pk_tactividad), v_registros, v_fechas
            USING ERRCODE = '23503',
                  HINT = 'Elimine primero las asistencias tomadas en esta actividad';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_validar_sin_asistencias(BIGINT)
    IS 'INTERNO: 23503 si hay asistencias activas tomadas por la actividad (TASISTENCIA.FK_TACTIVIDAD, sesiones de preescolar / referente formativo). Lo usa fn_actividad_eliminar.';

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_sin_recuperaciones(
    p_pk_tactividad BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_dependientes BIGINT;
BEGIN
    SELECT COUNT(*) INTO v_dependientes
      FROM academico_test.TACTIVIDAD_RECUPERACION r
      JOIN academico_test.TACTIVIDAD a ON a.PK_TACTIVIDAD = r.FK_TACTIVIDAD
     WHERE r.FK_TACTIVIDAD_RECUPERAR = p_pk_tactividad
       AND r.ACTIVE = TRUE AND a.ACTIVE = TRUE;

    IF v_dependientes > 0 THEN
        RAISE EXCEPTION 'La actividad "%" es recuperada por % actividad(es) de recuperacion activa(s); no se puede eliminar',
            (SELECT TITULO FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_pk_tactividad), v_dependientes
            USING ERRCODE = '23503',
                  HINT = 'Reconfigure o elimine esas actividades de recuperacion y reintente';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_validar_sin_recuperaciones(BIGINT)
    IS 'INTERNO: 23503 si otra actividad de recuperación activa recupera a esta (TACTIVIDAD_RECUPERACION.FK_TACTIVIDAD_RECUPERAR). Lo usa fn_actividad_eliminar.';

-- Punto único de extensión: una regla nueva de "no se puede borrar" es un
-- validador más aquí, sin tocar el wrapper.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validar_eliminable(
    p_pk_tactividad BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_actividad_validar_sin_notas(p_pk_tactividad);
    PERFORM academico_test.fn_actividad_validar_sin_asistencias(p_pk_tactividad);
    PERFORM academico_test.fn_actividad_validar_sin_recuperaciones(p_pk_tactividad);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_validar_eliminable(BIGINT)
    IS 'INTERNO: todas las dependencias que impiden borrar una actividad (23503): notas/observaciones/capturas, asistencias, recuperaciones activas. Para agregar una regla, se crea su fn_actividad_validar_<regla> y se invoca aquí. Lo usa fn_actividad_eliminar.';

-- ---------------------------------------------------------------------------
-- 2. Núcleo: la cascada, sin gate ni validaciones.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_eliminar_interno(
    p_pk_tactividad BIGINT,
    -- Solo para auditoría (MODIFIED_BY) y para revertir la recuperación.
    p_pk_usuario    BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_por        VARCHAR := p_pk_usuario::VARCHAR;
    v_fk_tunidad BIGINT;
    v_fk_tgrupo  BIGINT;
BEGIN
    SELECT FK_TUNIDAD, FK_TGRUPO INTO v_fk_tunidad, v_fk_tgrupo
      FROM academico_test.TACTIVIDAD
     WHERE PK_TACTIVIDAD = p_pk_tactividad;

    -- 1. Capturas por estudiante.
    UPDATE academico_test.TACTIVIDAD_RUBRICA_EVALUACION re
       SET ACTIVE = FALSE, MODIFIED_BY = v_por, MODIFIED_AT = CURRENT_TIMESTAMP
      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
     WHERE re.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
       AND ae.FK_TACTIVIDAD = p_pk_tactividad AND re.ACTIVE = TRUE;

    UPDATE academico_test.TACTIVIDAD_COTEJO_EVALUACION ce
       SET ACTIVE = FALSE, MODIFIED_BY = v_por, MODIFIED_AT = CURRENT_TIMESTAMP
      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
     WHERE ce.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
       AND ae.FK_TACTIVIDAD = p_pk_tactividad AND ce.ACTIVE = TRUE;

    UPDATE academico_test.TACTIVIDAD_ESCALA_EVALUACION ee
       SET ACTIVE = FALSE, MODIFIED_BY = v_por, MODIFIED_AT = CURRENT_TIMESTAMP
      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
     WHERE ee.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
       AND ae.FK_TACTIVIDAD = p_pk_tactividad AND ee.ACTIVE = TRUE;

    UPDATE academico_test.TACTIVIDAD_NOTA n
       SET ACTIVE = FALSE, MODIFIED_BY = v_por, MODIFIED_AT = CURRENT_TIMESTAMP
      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
     WHERE n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
       AND ae.FK_TACTIVIDAD = p_pk_tactividad AND n.ACTIVE = TRUE;

    UPDATE academico_test.TACTIVIDAD_SOPORTE s
       SET ACTIVE = FALSE, MODIFIED_BY = v_por, MODIFIED_AT = CURRENT_TIMESTAMP
      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
     WHERE s.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
       AND ae.FK_TACTIVIDAD = p_pk_tactividad AND s.ACTIVE = TRUE;

    -- 2. Adaptaciones por estudiante y los estudiantes.
    UPDATE academico_test.TACTIVIDAD_ADAPTACION_ESTUDIANTE ade
       SET ACTIVE = FALSE, MODIFIED_BY = v_por, MODIFIED_AT = CURRENT_TIMESTAMP
      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
     WHERE ade.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
       AND ae.FK_TACTIVIDAD = p_pk_tactividad AND ade.ACTIVE = TRUE;

    UPDATE academico_test.TACTIVIDAD_ESTUDIANTE
       SET ACTIVE = FALSE, MODIFIED_BY = v_por, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE;

    -- 3. Definición del instrumento: hijos antes que padres.
    UPDATE academico_test.TACTIVIDAD_RUBRICA_NIVEL rn
       SET ACTIVE = FALSE, MODIFIED_BY = v_por, MODIFIED_AT = CURRENT_TIMESTAMP
      FROM academico_test.TACTIVIDAD_RUBRICA_CRITERIO rc
     WHERE rn.FK_TACTIVIDAD_RUBRICA_CRITERIO = rc.PK_TACTIVIDAD_RUBRICA_CRITERIO
       AND rc.FK_TACTIVIDAD = p_pk_tactividad AND rn.ACTIVE = TRUE;

    UPDATE academico_test.TACTIVIDAD_RUBRICA_CRITERIO
       SET ACTIVE = FALSE, MODIFIED_BY = v_por, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE;

    UPDATE academico_test.TACTIVIDAD_COTEJO_ITEM
       SET ACTIVE = FALSE, MODIFIED_BY = v_por, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE;

    UPDATE academico_test.TACTIVIDAD_ESCALA_NIVEL en
       SET ACTIVE = FALSE, MODIFIED_BY = v_por, MODIFIED_AT = CURRENT_TIMESTAMP
      FROM academico_test.TACTIVIDAD_ESCALA e
     WHERE en.FK_TACTIVIDAD_ESCALA = e.PK_TACTIVIDAD_ESCALA
       AND e.FK_TACTIVIDAD = p_pk_tactividad AND en.ACTIVE = TRUE;

    UPDATE academico_test.TACTIVIDAD_ESCALA
       SET ACTIVE = FALSE, MODIFIED_BY = v_por, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE;

    -- 4. Satélites directos.
    UPDATE academico_test.TACTIVIDAD_MATERIAL
       SET ACTIVE = FALSE, MODIFIED_BY = v_por, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE;

    UPDATE academico_test.TACTIVIDAD_ADAPTACION
       SET ACTIVE = FALSE, MODIFIED_BY = v_por, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE;

    -- Antes de desactivar la config: deshace lo que la recuperación escribió.
    PERFORM academico_test.fn_actividad_recuperacion_revertir(p_pk_usuario, p_pk_tactividad);
    UPDATE academico_test.TACTIVIDAD_RECUPERACION
       SET ACTIVE = FALSE, MODIFIED_BY = v_por, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE;

    UPDATE academico_test.TACTIVIDAD_EVIDENCIA
       SET ACTIVE = FALSE, MODIFIED_BY = v_por, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE;

    UPDATE academico_test.TACTIVIDAD_CRITERIO_UNIDAD
       SET ACTIVE = FALSE, MODIFIED_BY = v_por, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE;

    -- 5. La actividad, soltada de la unidad: su peso deja de ocupar cupo en
    --    la regla del 100% por (unidad, grupo).
    UPDATE academico_test.TACTIVIDAD
       SET ACTIVE      = FALSE,
           FK_TUNIDAD  = NULL,
           PONDERACION = NULL,
           MODIFIED_BY = v_por,
           MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TACTIVIDAD = p_pk_tactividad;

    -- 6. Con la unidad/grupo leídos ANTES del paso 5. No-op fuera de Sumatoria.
    PERFORM academico_test.fn_unidad_ponderacion_recalcular_sumatoria(v_fk_tunidad, v_fk_tgrupo);

    RETURN p_pk_tactividad;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_eliminar_interno(BIGINT, BIGINT)
    IS 'INTERNO: soft delete en cascada de una TACTIVIDAD y todos sus satélites activos (capturas, notas, soportes, adaptaciones, estudiantes, definición del instrumento, materiales, recuperación revertida, evidencias, criterios de unidad); la suelta de su unidad y recalcula la Sumatoria del bucket. No valida permisos ni dependencias: eso es de fn_actividad_eliminar. p_pk_usuario solo para auditoría.';

-- ---------------------------------------------------------------------------
-- 3. Wrapper: existencia → estado → gate → dependencias → núcleo.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_eliminar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad            BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_active BOOLEAN;
    v_titulo VARCHAR;
BEGIN
    SELECT ACTIVE, TITULO INTO v_active, v_titulo
      FROM academico_test.TACTIVIDAD
     WHERE PK_TACTIVIDAD = p_pk_tactividad;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la actividad solicitada' USING ERRCODE = 'P0002';
    END IF;

    IF v_active = FALSE THEN
        RAISE EXCEPTION 'La actividad "%" ya se encuentra inactiva', v_titulo USING ERRCODE = '22023';
    END IF;

    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'ELIMINAR', NULL, NULL, NULL, p_pk_tactividad
    );

    -- Después del gate: a quien no puede borrar no se le cuenta qué hay dentro.
    PERFORM academico_test.fn_actividad_validar_eliminable(p_pk_tactividad);

    RETURN academico_test.fn_actividad_eliminar_interno(p_pk_tactividad, p_pk_usuario_solicitante);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_eliminar(BIGINT, BIGINT)
    IS 'DELETE /planeador/actividades/:ID: P0002 si no existe, 22023 si ya está inactiva, gate ELIMINAR con alcance sobre la actividad (fn_planeador_assert_alcance), y 23503 si alguna dependencia lo impide (fn_actividad_validar_eliminable: notas u observaciones o capturas de instrumento, asistencias tomadas, recuperación activa que la recupera). Luego delega en fn_actividad_eliminar_interno. Retorna PK_TACTIVIDAD.';
