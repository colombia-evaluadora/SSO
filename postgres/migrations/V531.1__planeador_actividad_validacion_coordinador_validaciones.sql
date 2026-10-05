-- V531.1 - Validación de la ACTIVIDAD por el Coordinador, capa 1 de 4: columnas
-- de estado en TACTIVIDAD y validaciones. Si REQUIERE_VALIDACION_COORDINADOR = S
-- el Coordinador de la sede la aprueba o la declina (con observación). No es la
-- aprobación de cambios de nota/asistencia (TSOLICITUD_APROBACION, V496.18):
-- aquí se valida la planeación, una sola decisión vigente por actividad.
-- ESTADO NULL = pendiente. Editar la actividad no reinicia la decisión.
-- Depende de: V22 (TACTIVIDAD), V496.1 (fn_actividad_etiqueta).

SET search_path TO academico_test, public;

ALTER TABLE academico_test.TACTIVIDAD
    ADD COLUMN IF NOT EXISTS ESTADO_VALIDACION_COORDINADOR      VARCHAR(20),
    ADD COLUMN IF NOT EXISTS OBSERVACION_VALIDACION_COORDINADOR VARCHAR(1000),
    ADD COLUMN IF NOT EXISTS FK_TUSUARIO_VALIDACION_COORDINADOR BIGINT,
    ADD COLUMN IF NOT EXISTS FECHA_VALIDACION_COORDINADOR       TIMESTAMP;

ALTER TABLE academico_test.TACTIVIDAD DROP CONSTRAINT IF EXISTS CK_TACTIVIDAD_ESTADO_VALIDACION;
ALTER TABLE academico_test.TACTIVIDAD ADD CONSTRAINT CK_TACTIVIDAD_ESTADO_VALIDACION
    CHECK (ESTADO_VALIDACION_COORDINADOR IS NULL
           OR ESTADO_VALIDACION_COORDINADOR IN ('APROBADA', 'DECLINADA'));

ALTER TABLE academico_test.TACTIVIDAD DROP CONSTRAINT IF EXISTS FK_TACTIVIDAD_USUARIO_VALIDACION;
ALTER TABLE academico_test.TACTIVIDAD ADD CONSTRAINT FK_TACTIVIDAD_USUARIO_VALIDACION
    FOREIGN KEY (FK_TUSUARIO_VALIDACION_COORDINADOR) REFERENCES academico_test.TUSUARIO (PK_TUSUARIO);

COMMENT ON COLUMN academico_test.TACTIVIDAD.ESTADO_VALIDACION_COORDINADOR
    IS 'Decisión del Coordinador sobre la planeación: NULL (pendiente), APROBADA o DECLINADA. Solo aplica con REQUIERE_VALIDACION_COORDINADOR = S.';
COMMENT ON COLUMN academico_test.TACTIVIDAD.OBSERVACION_VALIDACION_COORDINADOR
    IS 'Observación del Coordinador al validar; obligatoria al declinar (≤ 1000).';
COMMENT ON COLUMN academico_test.TACTIVIDAD.FK_TUSUARIO_VALIDACION_COORDINADOR
    IS 'Usuario que tomó la decisión vigente de validación.';
COMMENT ON COLUMN academico_test.TACTIVIDAD.FECHA_VALIDACION_COORDINADOR
    IS 'Momento de la decisión vigente de validación.';

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validacion_validar_requerida(p_pk_tactividad BIGINT)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM academico_test.TACTIVIDAD
                    WHERE PK_TACTIVIDAD = p_pk_tactividad
                      AND REQUIERE_VALIDACION_COORDINADOR = 'S') THEN
        RAISE EXCEPTION '% no requiere validación del coordinador',
            academico_test.fn_actividad_etiqueta(p_pk_tactividad)
            USING ERRCODE = '22023';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_validacion_validar_requerida(BIGINT)
    IS '22023 si la actividad no tiene REQUIERE_VALIDACION_COORDINADOR = S. La usa fn_actividad_validacion_coordinador_resolver.';

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validacion_validar_decision(
    p_decision    VARCHAR,
    p_observacion VARCHAR
)
RETURNS VOID
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF upper(TRIM(COALESCE(p_decision, ''))) NOT IN ('APROBADA', 'DECLINADA') THEN
        RAISE EXCEPTION 'La decisión debe ser APROBADA o DECLINADA'
            USING ERRCODE = '22023';
    END IF;
    IF upper(TRIM(p_decision)) = 'DECLINADA' AND NULLIF(TRIM(p_observacion), '') IS NULL THEN
        RAISE EXCEPTION 'Escriba la observación con el motivo para declinar la actividad'
            USING ERRCODE = '22023';
    END IF;
    IF char_length(TRIM(p_observacion)) > 1000 THEN
        RAISE EXCEPTION 'La observación admite hasta 1000 caracteres (tiene %)', char_length(TRIM(p_observacion))
            USING ERRCODE = '22023';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_validacion_validar_decision(VARCHAR, VARCHAR)
    IS '22023 si la decisión no es APROBADA/DECLINADA, si se declina sin observación o si la observación pasa de 1000 caracteres. La usa fn_actividad_validacion_coordinador_resolver.';
