-- ===========================================================================
-- V332 - Resumen de seguimiento del estudiante. Queda
-- fn_actividad_en_periodo_eval (una actividad cae en un periodo por fecha).
-- fn_estudiante_periodo_observacion_generar/_guardar/_eliminar viven en V490
-- (sus COMMENT en V516). _guardar se crea solo si falta: V433 la comenta.
-- ===========================================================================


CREATE OR REPLACE FUNCTION academico_test.fn_actividad_en_periodo_eval(
    p_pk_tactividad          BIGINT,
    p_fk_tperiodo_evaluacion BIGINT
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $function$
    SELECT COALESCE(a.FECHA_CIERRE, a.FECHA_INICIO, a.FECHA_CREACION::DATE)
               BETWEEN pe.FECHA_INICIO AND pe.FECHA_FIN
      FROM academico_test.TACTIVIDAD a
      JOIN academico_test.TPERIODO_EVALUACION pe
        ON pe.PK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion
     WHERE a.PK_TACTIVIDAD = p_pk_tactividad;
$function$;

COMMENT ON FUNCTION academico_test.fn_actividad_en_periodo_eval(BIGINT, BIGINT)
    IS 'Decide si una actividad pertenece a un periodo de evaluacion. TACTIVIDAD no tiene FK al periodo, asi que la unica via es la fecha: se usa COALESCE(FECHA_CIERRE, FECHA_INICIO, FECHA_CREACION) contra el rango FECHA_INICIO..FECHA_FIN del periodo, la misma convencion de fn_asistencia_periodo_eval. FECHA_CIERRE va primero porque el periodo al que una actividad aporta es aquel en que termina de evaluarse; FECHA_CALIFICADO se descarta aunque seria mas exacta porque solo esta poblada en 4 de 47 filas y porque moveria la actividad de periodo cuando el docente califica tarde, que es justo lo que este modulo quiere detectar como cambio propuesto en vez de absorber; FECHA_CREACION cierra el COALESCE por ser NOT NULL, garantizando que ninguna actividad quede fuera de todo periodo.';

-- V433 la comenta al migrar; la vigente vive en V490
DO $guarda$
BEGIN
    IF to_regprocedure('academico_test.fn_estudiante_periodo_observacion_guardar(bigint,bigint,bigint,text,text,numeric)') IS NULL THEN
        EXECUTE $crear$CREATE OR REPLACE FUNCTION academico_test.fn_estudiante_periodo_observacion_guardar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tmatricula          BIGINT,
    p_fk_tperiodo_evaluacion BIGINT,
    p_observacion            TEXT,
    p_observacion_ia         TEXT     DEFAULT NULL,
    p_observaciones_origen   NUMERIC  DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $function$
DECLARE
    v_fk_peraca  BIGINT;
    v_fk_sede    BIGINT;
    v_fk_jornada BIGINT;
    v_fk_ee      BIGINT;
    v_pe_peraca  BIGINT;
    v_texto      TEXT;
    v_ia         TEXT;
    v_origen     NUMERIC;
    v_estado     VARCHAR;
    v_pk_estado  BIGINT;
    v_pk         BIGINT;
BEGIN
    v_texto := NULLIF(TRIM(COALESCE(p_observacion, '')), '');
    IF v_texto IS NULL THEN
        RAISE EXCEPTION 'La observacion no puede quedar vacia'
            USING ERRCODE = '22023',
                  HINT    = 'Para quitar un resumen ya guardado use fn_estudiante_periodo_observacion_eliminar';
    END IF;

    SELECT gd.FK_TPERIODO_ACADEMICO, s.PK_TSEDE, gr.FK_TLV_JORNADA, s.FK_TESTABLECIMIENTO
      INTO v_fk_peraca, v_fk_sede, v_fk_jornada, v_fk_ee
      FROM academico_test.TMATRICULA m
      JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = m.FK_TGRUPO
      JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa
        ON pa.PK_TPERIODO_ACADEMICO = gd.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE m.PK_TMATRICULA = p_fk_tmatricula
       AND m.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la matricula solicitada'
            USING ERRCODE = 'P0002';
    END IF;

    SELECT pe.FK_TPERIODO_ACADEMICO
      INTO v_pe_peraca
      FROM academico_test.TPERIODO_EVALUACION pe
     WHERE pe.PK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion
       AND pe.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el periodo de evaluacion solicitado'
            USING ERRCODE = 'P0002';
    END IF;

    IF v_pe_peraca IS DISTINCT FROM v_fk_peraca THEN
        RAISE EXCEPTION 'El periodo de evaluacion no pertenece al periodo academico de la matricula'
            USING ERRCODE = '22023';
    END IF;

    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'INFORMES', 'EDITAR',
        v_fk_ee, v_fk_sede, v_fk_jornada
    );

    -- Si el caller no reenvia el borrador de la IA, se asume que guardo lo
    -- que la IA produjo tal cual. Es lo que hace un "guardar" sin edicion.
    v_ia     := COALESCE(NULLIF(TRIM(COALESCE(p_observacion_ia, '')), ''), v_texto);
    v_origen := p_observaciones_origen;

    -- El estado se DEDUCE del texto, no se pide por parametro: asi no puede
    -- contradecirlo.
    v_estado := CASE WHEN v_texto = TRIM(v_ia) THEN 'APROBADA' ELSE 'MODIFICADA' END;

    SELECT lv.PK_LISTA_VALOR INTO v_pk_estado
      FROM academico_test.TLISTA_VALOR lv
     WHERE lv.CATEGORIA = 'ESTADO_OBSERVACION_IA'
       AND lv.VALOR     = v_estado
       AND lv.ACTIVE    = TRUE;

    IF v_pk_estado IS NULL THEN
        RAISE EXCEPTION 'Falta el estado % en el catalogo ESTADO_OBSERVACION_IA', v_estado
            USING ERRCODE = 'P0002';
    END IF;

    -- El unico es TOTAL sobre (matricula, periodo): guardar REEMPLAZA. No se
    -- versiona, la unica verdad es lo que el docente acepto por ultima vez.
    INSERT INTO academico_test.TESTUDIANTE_PERIODO_OBSERVACION (
        FK_TMATRICULA, FK_TPERIODO_EVALUACION, FK_TLV_ESTADO_OBSERVACION,
        OBSERVACION, OBSERVACION_IA, OBSERVACIONES_ORIGEN,
        CREATED_BY, CREATED_AT, ACTIVE
    ) VALUES (
        p_fk_tmatricula, p_fk_tperiodo_evaluacion, v_pk_estado,
        v_texto, v_ia, v_origen,
        p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
    )
    ON CONFLICT (FK_TMATRICULA, FK_TPERIODO_EVALUACION)
    DO UPDATE SET FK_TLV_ESTADO_OBSERVACION = EXCLUDED.FK_TLV_ESTADO_OBSERVACION,
                  OBSERVACION               = EXCLUDED.OBSERVACION,
                  OBSERVACION_IA            = EXCLUDED.OBSERVACION_IA,
                  OBSERVACIONES_ORIGEN      = EXCLUDED.OBSERVACIONES_ORIGEN,
                  ACTIVE                    = TRUE,
                  MODIFIED_BY               = p_pk_usuario_solicitante::VARCHAR,
                  MODIFIED_AT               = CURRENT_TIMESTAMP
    RETURNING PK_TESTUDIANTE_PERIODO_OBSERVACION INTO v_pk;

    RETURN v_pk;
END;
$function$$crear$;
    END IF;
END $guarda$;
