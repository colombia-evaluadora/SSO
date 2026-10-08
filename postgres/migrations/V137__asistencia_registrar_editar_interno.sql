-- ===========================================================================
-- V137 -- Nucleos _interno de escritura de asistencia, sin gate ni reglas
-- de negocio (las corre el wrapper de V138 antes de llamarlos). Cuerpo
-- identico al que tenian V220/V464 (ambas eliminadas: su contenido quedo
-- consolidado en V136-V141). Incluye fn_asistencia_periodo_eval y
-- fn_asistencia_tipo_pk, que vivian solo en V220. Al escribir sugiere No
-- asistido en las actividades del dia aun Pendientes (Regla 73, V496.6).
-- Solo escribe tipos 1/2/5 y marca ORIGEN ASISTENCIA (la Vista predomina). En
-- periodo no calificable registrar abre solicitudes (Regla 75, V496.19).
-- Depende de: TASISTENCIA/TMATRICULA/TARCHIVO/TGRUPO/TGRADO/
-- TPERIODO_EVALUACION/TLISTA_VALOR (V22), fn_periodo_sede/fn_grupo_periodo (V40).
-- ===========================================================================

SET search_path TO academico_test, public;

-- Definiciones sin cambios respecto a la V220 original (eliminada).
CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_periodo_eval(
    p_fk_tgrupo BIGINT,
    p_fecha     DATE
)
RETURNS BIGINT
LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT pe.PK_TPERIODO_EVALUACION
      FROM academico_test.TGRUPO gr
      JOIN academico_test.TGRADO g ON g.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_EVALUACION pe
        ON pe.FK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
       AND pe.ACTIVE = TRUE
       AND p_fecha BETWEEN pe.FECHA_INICIO AND pe.FECHA_FIN
     WHERE gr.PK_TGRUPO = p_fk_tgrupo AND gr.ACTIVE = TRUE
     ORDER BY pe.FECHA_INICIO DESC
     LIMIT 1;
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_periodo_eval(BIGINT, DATE)
    IS 'PK_TPERIODO_EVALUACION de una sesion: periodo de evaluacion activo del periodo academico del grado del grupo cuyo rango contiene la fecha. NULL si no hay. Copia identica de V220, redefinida aqui (V137) para trazabilidad -- la usa fn_asistencia_registrar_bulk_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_tipo_pk(
    p_valor NUMERIC
)
RETURNS BIGINT
LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT lv.PK_LISTA_VALOR
      FROM academico_test.TLISTA_VALOR lv
     WHERE lv.CATEGORIA = 'TIPO_ASISTENCIA'
       AND lv.VALOR = p_valor::TEXT
       AND lv.ACTIVE = TRUE
     LIMIT 1;
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_tipo_pk(NUMERIC)
    IS 'PK_LISTA_VALOR del TIPO_ASISTENCIA con ese VALOR (1,2,3,5,6). Resuelve por (CATEGORIA, VALOR): los pk no son estables entre ambientes. NULL si el valor no existe o esta inactivo. Copia identica de V220, redefinida aqui (V137) para trazabilidad -- la usa fn_asistencia_registrar_bulk_interno / fn_asistencia_editar_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_registrar_bulk_interno(
    p_fk_tgrupo              BIGINT,
    p_fk_tasignatura         BIGINT,
    p_fecha                  DATE,
    p_bloque                 NUMERIC,
    p_registros              JSONB,
    p_marcar_todos_valor     NUMERIC,
    p_fk_tactividad          BIGINT,
    p_pk_usuario_solicitante BIGINT
)
RETURNS INTEGER
LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    v_afectados  INTEGER := 0;
    v_fk_periodo BIGINT;
    v_entrada    JSONB;
    v_invalido   TEXT;
    v_fk_tsede   BIGINT;
BEGIN
    IF (p_registros IS NULL OR jsonb_array_length(COALESCE(p_registros, '[]'::jsonb)) = 0)
       AND p_marcar_todos_valor IS NULL THEN
        RAISE EXCEPTION 'debe enviar p_registros o p_marcar_todos_valor' USING ERRCODE = '22023';
    END IF;

    v_fk_periodo := academico_test.fn_asistencia_periodo_eval(p_fk_tgrupo, p_fecha);
    IF v_fk_periodo IS NULL THEN
        RAISE EXCEPTION 'No hay un periodo de evaluación activo para el grupo % que incluya la fecha %.',
            (SELECT format('%s del grado %s', gr.NOMBRE, g.NOMBRE)
               FROM academico_test.TGRUPO gr
               JOIN academico_test.TGRADO g ON g.PK_TGRADO = gr.FK_TGRADO
              WHERE gr.PK_TGRUPO = p_fk_tgrupo), to_char(p_fecha, 'DD/MM/YYYY') USING ERRCODE = '22023';
    END IF;

    -- TARCHIVO.FK_TSEDE es la sede propietaria del archivo (V22): sin esto,
    -- un archivo ACTIVE de cualquier sede pasaba como soporte.
    v_fk_tsede := academico_test.fn_periodo_sede(academico_test.fn_grupo_periodo(p_fk_tgrupo));

    IF p_registros IS NOT NULL AND jsonb_array_length(p_registros) > 0 THEN
        v_entrada := p_registros;
    ELSE
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
                   'fkMatricula',    m.PK_TMATRICULA,
                   'tipoAsistencia', p_marcar_todos_valor)), '[]'::jsonb)
          INTO v_entrada
          FROM academico_test.TMATRICULA m
         WHERE m.FK_TGRUPO = p_fk_tgrupo AND m.ACTIVE = TRUE;
    END IF;

    SELECT motivo INTO v_invalido
      FROM (
        SELECT CASE
                 WHEN e.fk_matricula IS NULL
                   THEN 'fkMatricula es obligatorio en cada registro'
                 WHEN NOT EXISTS (SELECT 1 FROM academico_test.TMATRICULA m
                                   WHERE m.PK_TMATRICULA = e.fk_matricula
                                     AND m.ACTIVE = TRUE
                                     AND m.FK_TGRUPO = p_fk_tgrupo)
                   THEN format('la matricula %s no existe, no esta activa o no pertenece al grupo %s',
                               e.fk_matricula, p_fk_tgrupo)
                 WHEN e.valor_tipo IS NULL
                   THEN 'falta tipoAsistencia en algun registro y no se envio p_marcar_todos_valor'
                 WHEN e.valor_tipo NOT IN (1, 2, 5) OR academico_test.fn_asistencia_tipo_pk(e.valor_tipo) IS NULL
                   THEN format('tipoAsistencia %s invalido (validos: 1 Asistio, 2 No asistio, 5 Llego tarde; la excusa va como fkArchivo)',
                               e.valor_tipo)
                 WHEN e.fk_archivo IS NOT NULL
                      AND NOT EXISTS (SELECT 1 FROM academico_test.TARCHIVO ar
                                       WHERE ar.PK_TARCHIVO = e.fk_archivo AND ar.ACTIVE = TRUE
                                         AND (ar.FK_TSEDE IS NULL OR ar.FK_TSEDE = v_fk_tsede))
                   THEN format('el archivo de soporte %s no existe, no esta activo, o no pertenece a la sede del grupo',
                               e.fk_archivo)
                 ELSE NULL
               END AS motivo
          FROM jsonb_array_elements(v_entrada) r
          CROSS JOIN LATERAL (
              SELECT (r->>'fkMatricula')::BIGINT                             AS fk_matricula,
                     COALESCE((r->>'tipoAsistencia')::NUMERIC,
                              p_marcar_todos_valor)                          AS valor_tipo,
                     NULLIF(r->>'fkArchivo', '')::BIGINT                     AS fk_archivo
          ) e
      ) v
     WHERE v.motivo IS NOT NULL
     LIMIT 1;

    IF v_invalido IS NOT NULL THEN
        RAISE EXCEPTION '%', v_invalido USING ERRCODE = '23503';
    END IF;

    -- Regla 75: en un periodo no calificable no se escribe; corregir y capturar
    -- tarde quedan como solicitudes del Coordinador.
    IF COALESCE(academico_test.fn_asistencia_fecha_requiere_aprobacion(p_fk_tgrupo, p_fecha), FALSE) THEN
        PERFORM academico_test.fn_asistencia_registrar_solicitar_interno(
            p_pk_usuario_solicitante, p_fk_tgrupo, p_fk_tasignatura, p_fk_tactividad, p_fecha, p_bloque,
            v_fk_periodo, v_entrada, p_marcar_todos_valor);
        RETURN 0;
    END IF;

    WITH entrada AS (
        SELECT (r->>'fkMatricula')::BIGINT                                   AS fk_matricula,
               academico_test.fn_asistencia_tipo_pk(
                   COALESCE((r->>'tipoAsistencia')::NUMERIC,
                            p_marcar_todos_valor))                           AS fk_tlv_tipo,
               NULLIF(TRIM(r->>'observacion'), '')                           AS observacion,
               NULLIF(r->>'fkArchivo', '')::BIGINT                           AS fk_archivo
          FROM jsonb_array_elements(v_entrada) r
    ), up AS (
        INSERT INTO academico_test.TASISTENCIA (
            FECHA, FK_TLV_TIPO_ASISTENCIA, FK_TASIGNATURA, FK_TACTIVIDAD,
            FK_TPERIODO_EVALUACION,
            FK_TMATRICULA, OBSERVACION, FK_SOPORTE_ARCHIVO, BLOQUE, ORIGEN,
            CREATED_BY, CREATED_AT, ACTIVE
        )
        SELECT p_fecha, e.fk_tlv_tipo, p_fk_tasignatura, p_fk_tactividad,
               v_fk_periodo,
               e.fk_matricula, e.observacion, e.fk_archivo, p_bloque, 'ASISTENCIA',
               p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
          FROM entrada e
        -- Target = UQ_TASISTENCIA_SESION (V220): debe coincidir EXACTAMENTE
        -- con la lista del indice, COALESCE incluido.
        ON CONFLICT (FK_TMATRICULA,
                     COALESCE(FK_TASIGNATURA, 0),
                     COALESCE(FK_TACTIVIDAD, 0),
                     FECHA,
                     COALESCE(BLOQUE, 0))
                 WHERE ACTIVE = true
        DO UPDATE SET
            FK_TLV_TIPO_ASISTENCIA = EXCLUDED.FK_TLV_TIPO_ASISTENCIA,
            FK_TPERIODO_EVALUACION = EXCLUDED.FK_TPERIODO_EVALUACION,
            OBSERVACION            = EXCLUDED.OBSERVACION,
            FK_SOPORTE_ARCHIVO     = EXCLUDED.FK_SOPORTE_ARCHIVO,
            ORIGEN                 = 'ASISTENCIA',
            MODIFIED_BY            = p_pk_usuario_solicitante::VARCHAR,
            MODIFIED_AT            = CURRENT_TIMESTAMP
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_afectados FROM up;

    -- La Vista predomina: la fila que el Planeador tomo ese dia deja de contar.
    UPDATE academico_test.TASISTENCIA s
       SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE s.ORIGEN = 'PLANEADOR' AND s.ACTIVE = TRUE
       AND s.FECHA = p_fecha AND s.FK_TASIGNATURA IS NOT DISTINCT FROM p_fk_tasignatura
       AND s.FK_TMATRICULA IN (SELECT (r->>'fkMatricula')::BIGINT FROM jsonb_array_elements(v_entrada) r);

    PERFORM academico_test.fn_actividad_resultado_desde_asistencia_interno(
        p_pk_usuario_solicitante, p_fk_tgrupo, p_fk_tasignatura, p_fecha,
        ARRAY(SELECT (r->>'fkMatricula')::BIGINT FROM jsonb_array_elements(v_entrada) r));

    RETURN v_afectados;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_registrar_bulk_interno(BIGINT, BIGINT, DATE, NUMERIC, JSONB, NUMERIC, BIGINT, BIGINT)
    IS 'INTERNO: nucleo de fn_asistencia_registrar_bulk, sin gate ni reglas de negocio. Resuelve periodo de evaluacion y sede del grupo, normaliza p_registros (o "Marcar todo"), valida la forma de cada fila; si el periodo de evaluacion no es calificable no escribe y delega en fn_asistencia_registrar_solicitar_interno (Regla 75: devuelve 0, las solicitudes salen por fn_solicitud_aprobacion_creadas); si no, hace el upsert por UQ_TASISTENCIA_SESION con ORIGEN ASISTENCIA, retira la fila del Planeador de ese dia (la Vista predomina) y sincroniza el estado de resultado de las actividades del dia (fn_actividad_resultado_desde_asistencia_interno, Regla 73). p_pk_usuario_solicitante solo para CREATED_BY/MODIFIED_BY.';

CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_editar_interno(
    p_pk_tasistencia         BIGINT,
    p_fk_tgrupo              BIGINT,
    p_tipo_asistencia_valor  NUMERIC,
    p_observacion            VARCHAR,
    p_fk_soporte_archivo     BIGINT,
    p_limpiar_archivo        BOOLEAN,
    p_limpiar_observacion    BOOLEAN,
    p_pk_usuario_solicitante BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    v_fk_tlv_tipo BIGINT;
    v_s           RECORD;
BEGIN
    IF p_tipo_asistencia_valor IS NOT NULL THEN
        v_fk_tlv_tipo := academico_test.fn_asistencia_validar_tipo(p_tipo_asistencia_valor);
    END IF;

    IF p_fk_soporte_archivo IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TARCHIVO ar
         WHERE ar.PK_TARCHIVO = p_fk_soporte_archivo AND ar.ACTIVE = TRUE
           AND (ar.FK_TSEDE IS NULL
                OR ar.FK_TSEDE = academico_test.fn_periodo_sede(academico_test.fn_grupo_periodo(p_fk_tgrupo)))
    ) THEN
        RAISE EXCEPTION 'archivo (%) no existe, no esta activo, o no pertenece a la sede del grupo',
            p_fk_soporte_archivo
            USING ERRCODE = '23503';
    END IF;

    UPDATE academico_test.TASISTENCIA SET
        FK_TLV_TIPO_ASISTENCIA = COALESCE(v_fk_tlv_tipo, FK_TLV_TIPO_ASISTENCIA),
        OBSERVACION = CASE WHEN p_limpiar_observacion THEN NULL
                           ELSE COALESCE(NULLIF(TRIM(p_observacion), ''), OBSERVACION) END,
        FK_SOPORTE_ARCHIVO = CASE WHEN p_limpiar_archivo THEN NULL
                                  ELSE COALESCE(p_fk_soporte_archivo, FK_SOPORTE_ARCHIVO) END,
        -- Corregirla desde Seguimiento la vuelve asistencia de la Vista.
        ORIGEN = 'ASISTENCIA',
        MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
        MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TASISTENCIA = p_pk_tasistencia AND ACTIVE = TRUE
    RETURNING FK_TASIGNATURA, FECHA, FK_TMATRICULA INTO v_s;

    IF FOUND THEN
        PERFORM academico_test.fn_actividad_resultado_desde_asistencia_interno(
            p_pk_usuario_solicitante, p_fk_tgrupo, v_s.FK_TASIGNATURA, v_s.FECHA, ARRAY[v_s.FK_TMATRICULA]);
    END IF;

    RETURN p_pk_tasistencia;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_editar_interno(BIGINT, BIGINT, NUMERIC, VARCHAR, BIGINT, BOOLEAN, BOOLEAN, BIGINT)
    IS 'INTERNO: nucleo de fn_asistencia_editar, sin gate. Valida tipoAsistencia y el soporte, aplica el UPDATE parcial y sincroniza el estado de resultado del estudiante (Regla 73). p_pk_usuario_solicitante solo para MODIFIED_BY.';
