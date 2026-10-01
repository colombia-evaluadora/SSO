-- V496.19 - Aprobación del Coordinador, capa 2 de 4: núcleos _interno sin
-- permisos. Las escrituras que exigen aprobación (Reglas 55, 69, 75) crean la
-- solicitud y dejan el valor vigente (Regla 70); aprobar aplica con el núcleo
-- de siempre y marca el informe ya emitido (Regla 71); rechazar no toca nada.
-- La decisión de la nota (guardar/aplicar) vive en V496.6, que llama aquí.
-- Depende de: V496.18, V496.6 (estado de resultado), V137, V408, V348.

SET search_path TO academico_test, public;

-- ---------------------------------------------------------------------------
-- Solicitud: crear, y las creadas en la transacción para el endpoint
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_solicitud_aprobacion_crear_interno(
    p_pk_usuario_solicitante BIGINT,
    p_tipo                   VARCHAR,
    p_tabla_objeto           VARCHAR,
    p_fk_objeto              BIGINT,
    p_fk_tgrupo              BIGINT,
    p_fk_tasignatura         BIGINT,
    p_fk_tperiodo_evaluacion BIGINT,
    p_fk_tactividad          BIGINT,
    p_valor_anterior         JSONB,
    p_valor_propuesto        JSONB,
    p_motivo                 VARCHAR DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_tipo BIGINT := academico_test.fn_tlv_solicitud_tipo_pk(p_tipo);
    v_pk   BIGINT;
BEGIN
    -- Una sola pendiente por objeto y tipo: la nueva propuesta reemplaza a la
    -- anterior, que nunca llegó a aplicarse.
    SELECT s.PK_TSOLICITUD_APROBACION INTO v_pk
      FROM academico_test.TSOLICITUD_APROBACION s
     WHERE s.TABLA_OBJETO = p_tabla_objeto AND s.FK_OBJETO = p_fk_objeto
       AND s.FK_TLV_TIPO = v_tipo AND s.ACTIVE = TRUE
       AND s.FK_TLV_ESTADO = academico_test.fn_tlv_solicitud_estado_pk('PENDIENTE')
     FOR UPDATE;

    IF v_pk IS NOT NULL THEN
        UPDATE academico_test.TSOLICITUD_APROBACION
           SET VALOR_PROPUESTO = p_valor_propuesto,
               MOTIVO = COALESCE(NULLIF(TRIM(p_motivo), ''), MOTIVO),
               FK_TUSUARIO_SOLICITANTE = p_pk_usuario_solicitante,
               FECHA_SOLICITUD = CURRENT_TIMESTAMP,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TSOLICITUD_APROBACION = v_pk;
    ELSE
        INSERT INTO academico_test.TSOLICITUD_APROBACION (
            FK_TLV_TIPO, FK_TLV_ESTADO, TABLA_OBJETO, FK_OBJETO, FK_TGRUPO, FK_TASIGNATURA,
            FK_TPERIODO_EVALUACION, FK_TACTIVIDAD, VALOR_ANTERIOR, VALOR_PROPUESTO,
            FK_TUSUARIO_SOLICITANTE, MOTIVO, CREATED_BY)
        VALUES (
            v_tipo, academico_test.fn_tlv_solicitud_estado_pk('PENDIENTE'), p_tabla_objeto, p_fk_objeto,
            p_fk_tgrupo, p_fk_tasignatura, p_fk_tperiodo_evaluacion, p_fk_tactividad,
            p_valor_anterior, p_valor_propuesto, p_pk_usuario_solicitante,
            NULLIF(TRIM(p_motivo), ''), COALESCE(p_pk_usuario_solicitante::VARCHAR, 'SISTEMA'))
        RETURNING PK_TSOLICITUD_APROBACION INTO v_pk;
    END IF;

    -- La escritura que la origina devuelve su propio tipo (una nota, un pk):
    -- el endpoint lee las solicitudes creadas de aquí.
    PERFORM set_config('academico_test.solicitudes_creadas',
                       concat_ws(',', NULLIF(current_setting('academico_test.solicitudes_creadas', TRUE), ''), v_pk),
                       TRUE);
    RETURN v_pk;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_solicitud_aprobacion_crear_interno(BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, JSONB, JSONB, VARCHAR)
    IS 'INTERNO: registra (o actualiza, si ya hay una PENDIENTE del mismo tipo y objeto) una solicitud de aprobación y la anota en la transacción para fn_solicitud_aprobacion_creadas. La usan la consolidación de la recuperación, la corrección de resultado y la de asistencia.';

CREATE OR REPLACE FUNCTION academico_test.fn_solicitud_aprobacion_creadas()
RETURNS BIGINT[]
LANGUAGE sql
VOLATILE
AS $$
    SELECT COALESCE(string_to_array(NULLIF(current_setting('academico_test.solicitudes_creadas', TRUE), ''), ',')::BIGINT[],
                    '{}'::BIGINT[]);
$$;

COMMENT ON FUNCTION academico_test.fn_solicitud_aprobacion_creadas()
    IS 'INTERNO: PK de las solicitudes de aprobación creadas en la transacción actual. Las filas de calificar y de editar asistencia la añaden como solicitudes_pendientes (vacío = se aplicó directo).';

-- ---------------------------------------------------------------------------
-- Regla 55: solicitud de corrección de un resultado (la decide fn_actividad_nota_guardar_interno, V496.6)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_resultado_correccion_solicitar_interno(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad_estudiante BIGINT,
    p_porcentaje               NUMERIC
)
RETURNS BIGINT
LANGUAGE sql
AS $$
    SELECT academico_test.fn_solicitud_aprobacion_crear_interno(
               p_pk_usuario_solicitante, 'CORRECCION_RESULTADO', 'TACTIVIDAD_ESTUDIANTE', ae.PK_TACTIVIDAD_ESTUDIANTE,
               m.FK_TGRUPO, a.FK_TASIGNATURA,
               academico_test.fn_actividad_periodo_evaluacion(a.PK_TACTIVIDAD, ae.FK_TMATRICULA), a.PK_TACTIVIDAD,
               jsonb_build_object('porcentaje', n.CALIFICACION),
               jsonb_build_object('porcentaje', p_porcentaje))
      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
      JOIN academico_test.TACTIVIDAD a  ON a.PK_TACTIVIDAD = ae.FK_TACTIVIDAD
      JOIN academico_test.TMATRICULA m  ON m.PK_TMATRICULA = ae.FK_TMATRICULA
      LEFT JOIN academico_test.TACTIVIDAD_NOTA n
             ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE AND n.ACTIVE = TRUE
     WHERE ae.PK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_resultado_correccion_solicitar_interno(BIGINT, BIGINT, NUMERIC)
    IS 'INTERNO: abre (o actualiza) la solicitud CORRECCION_RESULTADO con la nota vigente y la propuesta (Regla 55). Devuelve su PK. La usa fn_actividad_nota_guardar_interno.';

-- ---------------------------------------------------------------------------
-- Recuperación: combinar sin redondear (redondea una sola vez quien escribe)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_recuperacion_combinar(
    p_nota_base         NUMERIC,
    p_nota_recuperacion NUMERIC,
    p_aplicacion        VARCHAR,
    p_calculo           VARCHAR,
    p_ponderacion       NUMERIC,
    p_politica_sin_nota VARCHAR,
    p_piso              NUMERIC
)
RETURNS NUMERIC
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_base NUMERIC := p_nota_base;
BEGIN
    IF p_nota_recuperacion IS NULL THEN
        RETURN NULL;
    END IF;

    IF p_aplicacion = 'REEMPLAZAR' THEN
        RETURN p_nota_recuperacion;
    END IF;

    IF v_base IS NULL THEN
        IF p_politica_sin_nota = 'MENOR' THEN
            v_base := COALESCE(p_piso, 0);
        ELSIF p_politica_sin_nota = 'NINGUNA' THEN
            RETURN p_nota_recuperacion;
        ELSE
            RETURN NULL;
        END IF;
    END IF;

    IF p_calculo = 'PONDERADO' AND p_ponderacion IS NOT NULL THEN
        RETURN p_nota_recuperacion * p_ponderacion / 100 + v_base * (100 - p_ponderacion) / 100;
    END IF;

    RETURN (v_base + p_nota_recuperacion) / 2;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_recuperacion_combinar(NUMERIC, NUMERIC, VARCHAR, VARCHAR, NUMERIC, VARCHAR, NUMERIC)
    IS 'Definición única de cómo una nota de recuperación se combina con la anterior, en porcentaje 0-100: REEMPLAZAR devuelve la recuperación; COMPUTAR+PONDERADO, recuperación*p/100 + base*(100-p)/100 (p = peso de la RECUPERACIÓN); COMPUTAR+PROMEDIADO o sin p, el promedio. Sin nota previa en COMPUTAR decide la política institucional recibida (MENOR = piso, NINGUNA = vale la recuperación, otra = NULL para abstenerse). No redondea ni acota: lo hace una sola vez fn_actividad_recuperacion_consolidar_interno con la Regla 30, para no redondear dos veces. Pura (IMMUTABLE).';

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_recuperacion_consolidar_interno(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad_estudiante BIGINT,
    p_pk_tactividad_excluir    BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk_tactividad   BIGINT;
    v_fk_tmatricula   BIGINT;
    v_fk_tasignatura  BIGINT;
    v_es_recuperacion CHAR(1);
    v_destino         VARCHAR;
    v_aplicacion      VARCHAR;
    v_calculo         VARCHAR;
    v_ponderacion     NUMERIC;
    v_fk_recuperar    BIGINT;
    v_nota_recup      NUMERIC;
    v_fk_tgrado       BIGINT;
    v_pk_criterio     BIGINT;
    v_politica        VARCHAR;
    v_piso            NUMERIC;
    v_tope            NUMERIC;
    v_base            NUMERIC;
    v_definitiva      NUMERIC;
    v_pk_destino      BIGINT;
    v_fk_periodo_eval BIGINT;
    v_pk_ae_orig      BIGINT;
    v_usuario         VARCHAR := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    SELECT ae.FK_TACTIVIDAD, ae.FK_TMATRICULA, a.ES_RECUPERACION, a.FK_TASIGNATURA
      INTO v_pk_tactividad, v_fk_tmatricula, v_es_recuperacion, v_fk_tasignatura
      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
      JOIN academico_test.TACTIVIDAD a ON a.PK_TACTIVIDAD = ae.FK_TACTIVIDAD
     WHERE ae.PK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante;

    IF v_es_recuperacion IS DISTINCT FROM 'S' THEN
        RETURN jsonb_build_object('aplicada', FALSE, 'motivo', 'NO_ES_RECUPERACION');
    END IF;

    SELECT lv_d.VALOR, lv_a.VALOR, lv_c.VALOR,
           r.VALOR_PONDERACION_RECUPERACION, r.FK_TACTIVIDAD_RECUPERAR
      INTO v_destino, v_aplicacion, v_calculo, v_ponderacion, v_fk_recuperar
      FROM academico_test.TACTIVIDAD_RECUPERACION r
      JOIN academico_test.TLISTA_VALOR lv_d ON lv_d.PK_LISTA_VALOR = r.FK_TLV_DESTINO_RECUPERACION
      JOIN academico_test.TLISTA_VALOR lv_a ON lv_a.PK_LISTA_VALOR = r.FK_TLV_TIPO_APLICACION_RECUPERACION
      JOIN academico_test.TLISTA_VALOR lv_c ON lv_c.PK_LISTA_VALOR = r.FK_TLV_TIPO_CALCULO_RECUPERACION
     WHERE r.FK_TACTIVIDAD = v_pk_tactividad AND r.ACTIVE = TRUE;

    IF v_destino IS NULL THEN
        RETURN jsonb_build_object('aplicada', FALSE, 'motivo', 'SIN_CONFIGURACION');
    END IF;

    SELECT n.CALIFICACION INTO v_nota_recup
      FROM academico_test.TACTIVIDAD_NOTA n
     WHERE n.FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante AND n.ACTIVE = TRUE;

    IF v_nota_recup IS NULL THEN
        RETURN jsonb_build_object('aplicada', FALSE, 'motivo', 'SIN_NOTA_DE_RECUPERACION');
    END IF;

    v_fk_tgrado := academico_test.fn_actividad_grado_resolver(v_pk_tactividad);
    IF v_fk_tgrado IS NOT NULL AND v_fk_tasignatura IS NOT NULL THEN
        v_pk_criterio := academico_test.fn_asignatura_criterio_evaluacion_vigente(v_fk_tasignatura, v_fk_tgrado);
    END IF;
    IF v_pk_criterio IS NOT NULL THEN
        v_politica := academico_test.fn_criterio_evaluacion_desempeno_sin_calificar(v_pk_criterio);
        v_piso     := academico_test.fn_criterio_evaluacion_porcentaje_inicial(v_pk_criterio);
        v_tope     := academico_test.fn_criterio_evaluacion_porcentaje_maximo_recuperacion(v_pk_criterio);
    END IF;

    IF v_destino = 'ACTIVIDAD' THEN
        SELECT ae.PK_TACTIVIDAD_ESTUDIANTE INTO v_pk_ae_orig
          FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
         WHERE ae.FK_TACTIVIDAD = v_fk_recuperar
           AND ae.FK_TMATRICULA = v_fk_tmatricula
           AND ae.ACTIVE = TRUE;
        IF v_pk_ae_orig IS NULL THEN
            RETURN jsonb_build_object('aplicada', FALSE, 'motivo', 'DESTINO_NO_ASIGNADO');
        END IF;
        IF academico_test.fn_actividad_refuerzo_vigente(v_fk_recuperar, v_fk_tmatricula, p_pk_tactividad_excluir)
           IS DISTINCT FROM p_pk_tactividad_estudiante THEN
            RETURN jsonb_build_object('aplicada', FALSE, 'motivo', 'REFUERZO_POSTERIOR_VIGENTE');
        END IF;

        v_pk_destino := academico_test.fn_actividad_nota_get_or_create(p_pk_usuario_solicitante, v_pk_ae_orig);
        SELECT n.CALIFICACION INTO v_base
          FROM academico_test.TACTIVIDAD_NOTA n WHERE n.PK_TACTIVIDAD_NOTA = v_pk_destino;
    ELSE
        IF academico_test.fn_criterio_evaluacion_nota_final_editable(v_pk_criterio) = FALSE THEN
            RETURN jsonb_build_object('aplicada', FALSE, 'motivo', 'NOTA_FINAL_NO_EDITABLE');
        END IF;

        v_fk_periodo_eval := academico_test.fn_actividad_periodo_evaluacion(v_pk_tactividad, v_fk_tmatricula);
        IF v_fk_periodo_eval IS NULL OR v_fk_tasignatura IS NULL THEN
            RETURN jsonb_build_object('aplicada', FALSE, 'motivo', 'SIN_PERIODO_DE_EVALUACION');
        END IF;

        SELECT sn.PK_TASIGNATURA_NOTA, sn.CALIFICACION
          INTO v_pk_destino, v_base
          FROM academico_test.TASIGNATURA_NOTA sn
         WHERE sn.FK_TMATRICULA          = v_fk_tmatricula
           AND sn.FK_TPERIODO_EVALUACION = v_fk_periodo_eval
           AND sn.FK_TASIGNATURA         = v_fk_tasignatura
           AND sn.ACTIVE = TRUE;

        IF v_base IS NULL THEN
            v_base := academico_test.fn_recuperacion_definitiva_periodo(
                          v_fk_tmatricula, v_fk_tasignatura, v_fk_periodo_eval);
        END IF;
    END IF;

    v_definitiva := academico_test.fn_recuperacion_combinar(
                        v_base, v_nota_recup, v_aplicacion, v_calculo, v_ponderacion, v_politica, v_piso);
    IF v_definitiva IS NULL THEN
        RETURN jsonb_build_object('aplicada', FALSE, 'motivo', 'SIN_POLITICA_SIN_CALIFICAR');
    END IF;

    -- La combinación puede quedar sobre el tope sin que el docente haya
    -- digitado nada fuera de él (base alta): aquí se recorta, no se rechaza
    -- (Regla 31 rechaza lo digitado, en fn_actividad_nota_ajustar_por_criterio).
    v_definitiva := academico_test.fn_actividad_nota_ajustar_por_criterio(
                        v_pk_tactividad, LEAST(v_definitiva, COALESCE(v_tope, v_definitiva)));
    v_definitiva := academico_test.fn_criterio_evaluacion_nota_redondear(v_pk_criterio, v_definitiva);

    IF v_destino = 'ACTIVIDAD' THEN
        UPDATE academico_test.TACTIVIDAD_NOTA
           SET RECUPERACION = v_nota_recup,
               DEFINITIVA   = v_definitiva,
               MODIFIED_BY  = v_usuario,
               MODIFIED_AT  = CURRENT_TIMESTAMP
         WHERE PK_TACTIVIDAD_NOTA = v_pk_destino;
    ELSIF v_pk_destino IS NULL THEN
        INSERT INTO academico_test.TASIGNATURA_NOTA (
            FK_TMATRICULA, FK_TPERIODO_EVALUACION, FK_TASIGNATURA,
            CALIFICACION, RECUPERACION, DEFINITIVA, CREATED_BY, CREATED_AT, ACTIVE
        ) VALUES (
            v_fk_tmatricula, v_fk_periodo_eval, v_fk_tasignatura,
            v_base, v_nota_recup, v_definitiva, v_usuario, CURRENT_TIMESTAMP, TRUE
        )
        ON CONFLICT (FK_TMATRICULA, FK_TPERIODO_EVALUACION, FK_TASIGNATURA)
            WHERE ACTIVE = TRUE
        DO UPDATE SET RECUPERACION = EXCLUDED.RECUPERACION,
                      DEFINITIVA   = EXCLUDED.DEFINITIVA,
                      MODIFIED_BY  = v_usuario,
                      MODIFIED_AT  = CURRENT_TIMESTAMP
        RETURNING PK_TASIGNATURA_NOTA INTO v_pk_destino;
    ELSE
        UPDATE academico_test.TASIGNATURA_NOTA
           SET RECUPERACION = v_nota_recup,
               DEFINITIVA   = v_definitiva,
               MODIFIED_BY  = v_usuario,
               MODIFIED_AT  = CURRENT_TIMESTAMP
         WHERE PK_TASIGNATURA_NOTA = v_pk_destino;
    END IF;

    RETURN jsonb_build_object(
        'aplicada',          TRUE,
        'destino',           v_destino,
        'tipo_aplicacion',   v_aplicacion,
        'tipo_calculo',      v_calculo,
        'pk_destino',        v_pk_destino,
        'nota_base',         v_base,
        'nota_recuperacion', v_nota_recup,
        'definitiva',        v_definitiva
    );
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_recuperacion_consolidar_interno(BIGINT, BIGINT, BIGINT)
    IS 'INTERNO: aplica la nota de UNA asignación de recuperación sobre su destino (ACTIVIDAD: la nota del mismo estudiante en la original; NOTA_FINAL: TASIGNATURA_NOTA del periodo), sin decidir aprobación. La base es siempre CALIFICACION, nunca DEFINITIVA (idempotente). La definitiva se recorta al tope, pasa por el piso y se redondea con la Regla 30. Devuelve {aplicada, motivo|detalle}. La usan fn_actividad_recuperacion_consolidar y la aprobación de una solicitud de recuperación.';

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_recuperacion_consolidar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad_estudiante BIGINT,
    p_pk_tactividad_excluir    BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk_tactividad   BIGINT;
    v_fk_tmatricula   BIGINT;
    v_es_recuperacion CHAR(1);
    v_pk_ae_rec       BIGINT;
    v_tipo            VARCHAR;
    v_nota_recup      NUMERIC;
    v_pk_solicitud    BIGINT;
BEGIN
    SELECT ae.FK_TACTIVIDAD, ae.FK_TMATRICULA, a.ES_RECUPERACION
      INTO v_pk_tactividad, v_fk_tmatricula, v_es_recuperacion
      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
      JOIN academico_test.TACTIVIDAD a ON a.PK_TACTIVIDAD = ae.FK_TACTIVIDAD
     WHERE ae.PK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante;

    IF v_es_recuperacion IS DISTINCT FROM 'S' THEN
        -- Recalificar la original rehace la consolidación del Refuerzo que manda
        -- (Regla 67; profundidad 1, Regla 64).
        v_pk_ae_rec := academico_test.fn_actividad_refuerzo_vigente(
                           v_pk_tactividad, v_fk_tmatricula, p_pk_tactividad_excluir);
        IF v_pk_ae_rec IS NULL THEN
            RETURN jsonb_build_object('aplicada', FALSE, 'motivo', 'NO_ES_RECUPERACION');
        END IF;
        RETURN academico_test.fn_actividad_recuperacion_consolidar(
                   p_pk_usuario_solicitante, v_pk_ae_rec, p_pk_tactividad_excluir)
               || jsonb_build_object('reaplicada_desde_original', TRUE);
    END IF;

    v_tipo := academico_test.fn_recuperacion_tipo_aprobacion(p_pk_tactividad_estudiante);
    SELECT n.CALIFICACION INTO v_nota_recup
      FROM academico_test.TACTIVIDAD_NOTA n
     WHERE n.FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante AND n.ACTIVE = TRUE;

    IF v_tipo IS NULL OR v_nota_recup IS NULL
       OR academico_test.fn_recuperacion_aprobada_vigente(p_pk_tactividad_estudiante, v_tipo, v_nota_recup) THEN
        RETURN academico_test.fn_actividad_recuperacion_consolidar_interno(
                   p_pk_usuario_solicitante, p_pk_tactividad_estudiante, p_pk_tactividad_excluir);
    END IF;

    -- Regla 70: queda pendiente y el destino conserva su valor.
    SELECT academico_test.fn_solicitud_aprobacion_crear_interno(
               p_pk_usuario_solicitante, v_tipo, 'TACTIVIDAD_ESTUDIANTE', p_pk_tactividad_estudiante,
               m.FK_TGRUPO, a.FK_TASIGNATURA,
               academico_test.fn_actividad_periodo_evaluacion(
                   CASE WHEN v_tipo = 'RECUPERACION_REFUERZO' THEN r.FK_TACTIVIDAD_RECUPERAR ELSE a.PK_TACTIVIDAD END,
                   v_fk_tmatricula),
               a.PK_TACTIVIDAD,
               academico_test.fn_solicitud_valor_vigente_recuperacion(p_pk_tactividad_estudiante, v_tipo),
               jsonb_build_object('notaRecuperacion', v_nota_recup, 'excluir', p_pk_tactividad_excluir))
      INTO v_pk_solicitud
      FROM academico_test.TACTIVIDAD a
      JOIN academico_test.TMATRICULA m ON m.PK_TMATRICULA = v_fk_tmatricula
      JOIN academico_test.TACTIVIDAD_RECUPERACION r ON r.FK_TACTIVIDAD = a.PK_TACTIVIDAD AND r.ACTIVE = TRUE
     WHERE a.PK_TACTIVIDAD = v_pk_tactividad;

    RETURN jsonb_build_object('aplicada', FALSE, 'motivo', 'PENDIENTE_APROBACION',
                              'tipo', v_tipo, 'pk_solicitud', v_pk_solicitud);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_recuperacion_consolidar(BIGINT, BIGINT, BIGINT)
    IS 'INTERNO: tras cada calificación decide si la recuperación se aplica (fn_actividad_recuperacion_consolidar_interno) o queda pendiente de aprobación (Regla 69: Habilitación siempre; Refuerzo si el periodo de la original ya no admite refuerzos). Una recuperación ya APROBADA con esa misma nota se reconsolida sin pedir otra vez. Si la actividad calificada es la ORIGINAL de un Refuerzo, reenvía al Refuerzo que manda (Regla 67). Si exige aprobación abre la solicitud con el valor vigente del destino (fn_solicitud_valor_vigente_recuperacion) y no toca la nota (Regla 70). Devuelve el JSONB del núcleo o {aplicada:false, motivo:PENDIENTE_APROBACION, tipo, pk_solicitud}. Sin gate: la llaman por nombre los núcleos de calificación tras guardar una nota.';

-- ---------------------------------------------------------------------------
-- Asistencia: la corrección como solicitud (Regla 75)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_correccion_solicitar_interno(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tasistencia         BIGINT,
    p_tipo_asistencia_valor  NUMERIC,
    p_observacion            VARCHAR,
    p_fk_soporte_archivo     BIGINT,
    p_limpiar_archivo        BOOLEAN,
    p_limpiar_observacion    BOOLEAN
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_solicitud_aprobacion_crear_interno(
               p_pk_usuario_solicitante, 'CORRECCION_ASISTENCIA', 'TASISTENCIA', a.PK_TASISTENCIA,
               m.FK_TGRUPO, a.FK_TASIGNATURA,
               academico_test.fn_asistencia_periodo_eval(m.FK_TGRUPO, a.FECHA), a.FK_TACTIVIDAD,
               jsonb_build_object('tipoAsistencia', lv.VALOR, 'observacion', a.OBSERVACION,
                                  'soporteArchivo', a.FK_SOPORTE_ARCHIVO, 'fecha', a.FECHA),
               jsonb_build_object('tipoAsistencia', p_tipo_asistencia_valor, 'observacion', p_observacion,
                                  'soporteArchivo', p_fk_soporte_archivo,
                                  'limpiarArchivo', COALESCE(p_limpiar_archivo, FALSE),
                                  'limpiarObservacion', COALESCE(p_limpiar_observacion, FALSE)))
      FROM academico_test.TASISTENCIA a
      JOIN academico_test.TMATRICULA m ON m.PK_TMATRICULA = a.FK_TMATRICULA
      LEFT JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = a.FK_TLV_TIPO_ASISTENCIA
     WHERE a.PK_TASISTENCIA = p_pk_tasistencia;
    RETURN p_pk_tasistencia;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_correccion_solicitar_interno(BIGINT, BIGINT, NUMERIC, VARCHAR, BIGINT, BOOLEAN, BOOLEAN)
    IS 'INTERNO: guarda como solicitud CORRECCION_ASISTENCIA la edición de un registro cuyo periodo de evaluación ya no es calificable (Regla 75); el registro no cambia hasta aprobarla. Devuelve el PK del registro, como fn_asistencia_editar. La usa fn_asistencia_editar.';

-- ---------------------------------------------------------------------------
-- Regla 71: el informe emitido queda desactualizado al aprobar
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_informe_desactualizado_marcar_interno(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tsolicitud          BIGINT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO academico_test.TINFORME_DESACTUALIZADO (
        FK_TGRUPO, FK_TPERIODO_EVALUACION, FK_TASIGNATURA, FK_TSOLICITUD_APROBACION, CREATED_BY)
    SELECT s.FK_TGRUPO, s.FK_TPERIODO_EVALUACION, s.FK_TASIGNATURA, s.PK_TSOLICITUD_APROBACION,
           p_pk_usuario_solicitante::VARCHAR
      FROM academico_test.TSOLICITUD_APROBACION s
     WHERE s.PK_TSOLICITUD_APROBACION = p_pk_tsolicitud
       AND s.FK_TPERIODO_EVALUACION IS NOT NULL
       AND EXISTS (SELECT 1 FROM academico_test.TINFORME_GUARDADO g
                    WHERE g.FK_TGRUPO = s.FK_TGRUPO AND g.FK_TPERIODO_EVALUACION = s.FK_TPERIODO_EVALUACION
                      AND g.ACTIVE = TRUE
                      AND (g.FK_TASIGNATURA IS NULL OR s.FK_TASIGNATURA IS NULL OR g.FK_TASIGNATURA = s.FK_TASIGNATURA))
       AND NOT EXISTS (SELECT 1 FROM academico_test.TINFORME_DESACTUALIZADO d
                        WHERE d.FK_TSOLICITUD_APROBACION = s.PK_TSOLICITUD_APROBACION AND d.ACTIVE = TRUE);
    RETURN FOUND;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_informe_desactualizado_marcar_interno(BIGINT, BIGINT)
    IS 'INTERNO: Regla 71. Marca el informe del grupo y periodo de la solicitud como desactualizado, solo si ya se había emitido (TINFORME_GUARDADO). TRUE si lo marcó. La usa fn_solicitud_aprobacion_aprobar_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_tinforme_guardado_limpiar_desactualizado()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    -- Reemitir el informe del grupo limpia todo; la planilla de una
    -- asignatura, solo lo de esa asignatura.
    UPDATE academico_test.TINFORME_DESACTUALIZADO
       SET ACTIVE = FALSE, MODIFIED_BY = NEW.CREATED_BY, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TGRUPO = NEW.FK_TGRUPO
       AND FK_TPERIODO_EVALUACION = NEW.FK_TPERIODO_EVALUACION
       AND ACTIVE = TRUE
       AND (NEW.FK_TASIGNATURA IS NULL OR FK_TASIGNATURA = NEW.FK_TASIGNATURA);
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_tinforme_guardado_limpiar_desactualizado ON academico_test.TINFORME_GUARDADO;
CREATE TRIGGER trg_tinforme_guardado_limpiar_desactualizado
    AFTER INSERT ON academico_test.TINFORME_GUARDADO
    FOR EACH ROW EXECUTE FUNCTION academico_test.fn_tinforme_guardado_limpiar_desactualizado();

CREATE OR REPLACE FUNCTION academico_test.fn_informe_desactualizado_interno(
    p_fk_tgrupo              BIGINT,
    p_fk_tperiodo_evaluacion BIGINT
)
RETURNS JSONB
LANGUAGE sql
STABLE
AS $$
    SELECT jsonb_build_object(
               'desactualizado', COUNT(*) > 0,
               'mensaje', CASE WHEN COUNT(*) > 0 THEN
                   'Este informe fue emitido antes de que se aprobara una actividad de Recuperación; los valores mostrados pueden no reflejar la Nota Final o el resultado más reciente del estudiante.' END,
               'cambios', COALESCE(jsonb_agg(jsonb_build_object(
                   'pkSolicitud', s.PK_TSOLICITUD_APROBACION,
                   'tipo', lv.VALOR,
                   'asignatura', asig.NOMBRE,
                   'fechaAprobacion', s.FECHA_RESOLUCION) ORDER BY s.FECHA_RESOLUCION)
                   FILTER (WHERE d.PK_TINFORME_DESACTUALIZADO IS NOT NULL), '[]'::jsonb))
      FROM academico_test.TINFORME_DESACTUALIZADO d
      JOIN academico_test.TSOLICITUD_APROBACION s ON s.PK_TSOLICITUD_APROBACION = d.FK_TSOLICITUD_APROBACION
      JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = s.FK_TLV_TIPO
      LEFT JOIN academico_test.TASIGNATURA asig ON asig.PK_TASIGNATURA = d.FK_TASIGNATURA
     WHERE d.FK_TGRUPO = p_fk_tgrupo
       AND d.FK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion
       AND d.ACTIVE = TRUE;
$$;

COMMENT ON FUNCTION academico_test.fn_informe_desactualizado_interno(BIGINT, BIGINT)
    IS 'INTERNO: {desactualizado, mensaje (texto estático de la Regla 71), cambios[]} del informe de un grupo y periodo. La usa fn_informe_desactualizado; las pantallas y exportaciones de informes pueden llamarla igual.';

-- ---------------------------------------------------------------------------
-- Resolver: aprobar y rechazar
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_solicitud_aprobacion_aprobar_interno(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tsolicitud          BIGINT,
    p_motivo                 VARCHAR DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_s         RECORD;
    v_tipo      VARCHAR := academico_test.fn_solicitud_aprobacion_tipo(p_pk_tsolicitud);
    v_p         JSONB;
    v_resultado JSONB;
BEGIN
    SELECT * INTO v_s FROM academico_test.TSOLICITUD_APROBACION
     WHERE PK_TSOLICITUD_APROBACION = p_pk_tsolicitud FOR UPDATE;
    v_p := v_s.VALOR_PROPUESTO;

    -- Se marca APROBADA antes de aplicar: así la reconsolidación de la
    -- recuperación la reconoce como vigente y no abre otra solicitud.
    UPDATE academico_test.TSOLICITUD_APROBACION
       SET FK_TLV_ESTADO = academico_test.fn_tlv_solicitud_estado_pk('APROBADA'),
           FK_TUSUARIO_APROBADOR = p_pk_usuario_solicitante,
           FECHA_RESOLUCION = CURRENT_TIMESTAMP,
           MOTIVO_RESOLUCION = NULLIF(TRIM(p_motivo), ''),
           MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TSOLICITUD_APROBACION = p_pk_tsolicitud;

    IF v_tipo IN ('RECUPERACION_HABILITACION', 'RECUPERACION_REFUERZO') THEN
        v_resultado := academico_test.fn_actividad_recuperacion_consolidar_interno(
                           p_pk_usuario_solicitante, v_s.FK_OBJETO, (v_p->>'excluir')::BIGINT);
    ELSIF v_tipo = 'CORRECCION_RESULTADO' THEN
        v_resultado := jsonb_build_object('aplicada', TRUE, 'porcentaje',
                           academico_test.fn_actividad_nota_aplicar_interno(
                               p_pk_usuario_solicitante, v_s.FK_OBJETO, (v_p->>'porcentaje')::NUMERIC));
    ELSE
        PERFORM academico_test.fn_asistencia_editar_interno(
            v_s.FK_OBJETO, v_s.FK_TGRUPO, (v_p->>'tipoAsistencia')::NUMERIC, v_p->>'observacion',
            (v_p->>'soporteArchivo')::BIGINT, (v_p->>'limpiarArchivo')::BOOLEAN,
            (v_p->>'limpiarObservacion')::BOOLEAN, p_pk_usuario_solicitante);
        v_resultado := jsonb_build_object('aplicada', TRUE, 'pk_tasistencia', v_s.FK_OBJETO);
    END IF;

    RETURN jsonb_build_object('pkSolicitud', p_pk_tsolicitud, 'estado', 'APROBADA', 'tipo', v_tipo,
                              'resultado', v_resultado,
                              'informeDesactualizado',
                              academico_test.fn_informe_desactualizado_marcar_interno(p_pk_usuario_solicitante, p_pk_tsolicitud));
END;
$$;

COMMENT ON FUNCTION academico_test.fn_solicitud_aprobacion_aprobar_interno(BIGINT, BIGINT, VARCHAR)
    IS 'INTERNO: aprueba una solicitud PENDIENTE (el llamador ya validó estado y permisos) y aplica el valor propuesto con el núcleo de siempre: consolidación de la recuperación, fn_actividad_nota_aplicar_interno o fn_asistencia_editar_interno. Marca el informe emitido como desactualizado (Regla 71). La usa fn_solicitud_aprobacion_aprobar.';

CREATE OR REPLACE FUNCTION academico_test.fn_solicitud_aprobacion_rechazar_interno(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tsolicitud          BIGINT,
    p_motivo                 VARCHAR
)
RETURNS JSONB
LANGUAGE sql
AS $$
    UPDATE academico_test.TSOLICITUD_APROBACION
       SET FK_TLV_ESTADO = academico_test.fn_tlv_solicitud_estado_pk('RECHAZADA'),
           FK_TUSUARIO_APROBADOR = p_pk_usuario_solicitante,
           FECHA_RESOLUCION = CURRENT_TIMESTAMP,
           MOTIVO_RESOLUCION = TRIM(p_motivo),
           MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TSOLICITUD_APROBACION = p_pk_tsolicitud
    RETURNING jsonb_build_object('pkSolicitud', PK_TSOLICITUD_APROBACION, 'estado', 'RECHAZADA',
                                 'valorVigente', VALOR_ANTERIOR);
$$;

COMMENT ON FUNCTION academico_test.fn_solicitud_aprobacion_rechazar_interno(BIGINT, BIGINT, VARCHAR)
    IS 'INTERNO: rechaza una solicitud PENDIENTE; el valor vigente sigue siendo el anterior (Regla 70), así que no se toca ningún dato. La usa fn_solicitud_aprobacion_rechazar.';

CREATE OR REPLACE FUNCTION academico_test.fn_solicitud_aprobacion_listar_interno(
    p_estado    VARCHAR DEFAULT 'PENDIENTE',
    p_tipo      VARCHAR DEFAULT NULL,
    p_fk_tgrupo BIGINT  DEFAULT NULL
)
RETURNS TABLE (
    pk_tsolicitud_aprobacion BIGINT,
    tipo                     VARCHAR,
    tipo_nombre              VARCHAR,
    estado                   VARCHAR,
    tabla_objeto             VARCHAR,
    fk_objeto                BIGINT,
    fk_tgrupo                BIGINT,
    grupo                    VARCHAR,
    fk_tasignatura           BIGINT,
    asignatura               VARCHAR,
    fk_tperiodo_evaluacion   BIGINT,
    periodo_evaluacion       VARCHAR,
    fk_tactividad            BIGINT,
    actividad                VARCHAR,
    estudiante               VARCHAR,
    valor_anterior           JSONB,
    valor_propuesto          JSONB,
    solicitante              VARCHAR,
    fecha_solicitud          TIMESTAMP,
    motivo                   VARCHAR,
    aprobador                VARCHAR,
    fecha_resolucion         TIMESTAMP,
    motivo_resolucion        VARCHAR
)
LANGUAGE sql
STABLE
AS $$
    SELECT s.PK_TSOLICITUD_APROBACION, lt.VALOR, lt.NOMBRE, le.VALOR, s.TABLA_OBJETO, s.FK_OBJETO,
           s.FK_TGRUPO, g.NOMBRE, s.FK_TASIGNATURA, asig.NOMBRE, s.FK_TPERIODO_EVALUACION, pe.NOMBRE,
           s.FK_TACTIVIDAD,
           CASE WHEN s.FK_TACTIVIDAD IS NOT NULL THEN academico_test.fn_actividad_etiqueta(s.FK_TACTIVIDAD) END,
           academico_test.fn_actividad_estudiante_nombre(COALESCE(ae.FK_TMATRICULA, asis.FK_TMATRICULA)),
           s.VALOR_ANTERIOR, s.VALOR_PROPUESTO,
           NULLIF(TRIM(CONCAT_WS(' ', us.PRIMER_NOMBRE, us.PRIMER_APELLIDO)), '')::VARCHAR,
           s.FECHA_SOLICITUD, s.MOTIVO,
           NULLIF(TRIM(CONCAT_WS(' ', ua.PRIMER_NOMBRE, ua.PRIMER_APELLIDO)), '')::VARCHAR,
           s.FECHA_RESOLUCION, s.MOTIVO_RESOLUCION
      FROM academico_test.TSOLICITUD_APROBACION s
      JOIN academico_test.TLISTA_VALOR lt ON lt.PK_LISTA_VALOR = s.FK_TLV_TIPO
      JOIN academico_test.TLISTA_VALOR le ON le.PK_LISTA_VALOR = s.FK_TLV_ESTADO
      JOIN academico_test.TGRUPO g ON g.PK_TGRUPO = s.FK_TGRUPO
      LEFT JOIN academico_test.TASIGNATURA asig ON asig.PK_TASIGNATURA = s.FK_TASIGNATURA
      LEFT JOIN academico_test.TPERIODO_EVALUACION pe ON pe.PK_TPERIODO_EVALUACION = s.FK_TPERIODO_EVALUACION
      LEFT JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
             ON s.TABLA_OBJETO = 'TACTIVIDAD_ESTUDIANTE' AND ae.PK_TACTIVIDAD_ESTUDIANTE = s.FK_OBJETO
      LEFT JOIN academico_test.TASISTENCIA asis
             ON s.TABLA_OBJETO = 'TASISTENCIA' AND asis.PK_TASISTENCIA = s.FK_OBJETO
      LEFT JOIN academico_test.TUSUARIO us ON us.PK_TUSUARIO = s.FK_TUSUARIO_SOLICITANTE
      LEFT JOIN academico_test.TUSUARIO ua ON ua.PK_TUSUARIO = s.FK_TUSUARIO_APROBADOR
     WHERE s.ACTIVE = TRUE
       AND (p_estado IS NULL OR le.VALOR = upper(TRIM(p_estado)))
       AND (p_tipo IS NULL OR lt.VALOR = upper(TRIM(p_tipo)))
       AND (p_fk_tgrupo IS NULL OR s.FK_TGRUPO = p_fk_tgrupo)
     ORDER BY s.FECHA_SOLICITUD, s.PK_TSOLICITUD_APROBACION;
$$;

COMMENT ON FUNCTION academico_test.fn_solicitud_aprobacion_listar_interno(VARCHAR, VARCHAR, BIGINT)
    IS 'INTERNO: solicitudes de aprobación con sus etiquetas legibles, por estado (PENDIENTE por defecto; NULL = todas), tipo y grupo, de la más antigua a la más reciente. Sin alcance: el wrapper fn_solicitud_aprobacion_listar lo filtra con fn_solicitud_aprobacion_puede_aprobar.';
