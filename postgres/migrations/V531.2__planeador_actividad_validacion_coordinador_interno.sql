-- V531.2 - Validación de la ACTIVIDAD por el Coordinador, capa 2 de 4: núcleos
-- sin permisos. Escribir la decisión (reemplaza la vigente) y leer el estado.
-- Depende de: V531.1 (columnas).

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validacion_coordinador_estado_interno(p_pk_tactividad BIGINT)
RETURNS JSONB
LANGUAGE sql
STABLE
AS $$
    SELECT jsonb_build_object(
               'pkActividad',        a.PK_TACTIVIDAD,
               'requiereValidacion', a.REQUIERE_VALIDACION_COORDINADOR = 'S',
               'estado',             CASE WHEN a.REQUIERE_VALIDACION_COORDINADOR IS DISTINCT FROM 'S' THEN 'NO_REQUIERE'
                                          ELSE COALESCE(a.ESTADO_VALIDACION_COORDINADOR, 'PENDIENTE') END,
               'observacion',        a.OBSERVACION_VALIDACION_COORDINADOR,
               'validadoPor',        NULLIF(TRIM(CONCAT_WS(' ', u.PRIMER_NOMBRE, u.PRIMER_APELLIDO)), ''),
               'fechaValidacion',    a.FECHA_VALIDACION_COORDINADOR)
      FROM academico_test.TACTIVIDAD a
      LEFT JOIN academico_test.TUSUARIO u ON u.PK_TUSUARIO = a.FK_TUSUARIO_VALIDACION_COORDINADOR
     WHERE a.PK_TACTIVIDAD = p_pk_tactividad;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_validacion_coordinador_estado_interno(BIGINT)
    IS 'INTERNO: estado de validación de la actividad {pkActividad, requiereValidacion, estado (NO_REQUIERE|PENDIENTE|APROBADA|DECLINADA), observacion, validadoPor, fechaValidacion}. La usan fn_actividad_validacion_coordinador_consultar y _resolver_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validacion_coordinador_resolver_interno(
    p_pk_usuario    BIGINT,
    p_pk_tactividad BIGINT,
    p_decision      VARCHAR,
    p_observacion   VARCHAR
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE academico_test.TACTIVIDAD
       SET ESTADO_VALIDACION_COORDINADOR      = upper(TRIM(p_decision)),
           OBSERVACION_VALIDACION_COORDINADOR = NULLIF(TRIM(p_observacion), ''),
           FK_TUSUARIO_VALIDACION_COORDINADOR = p_pk_usuario,
           FECHA_VALIDACION_COORDINADOR       = CURRENT_TIMESTAMP,
           MODIFIED_BY                        = p_pk_usuario::VARCHAR,
           MODIFIED_AT                        = CURRENT_TIMESTAMP
     WHERE PK_TACTIVIDAD = p_pk_tactividad;

    RETURN academico_test.fn_actividad_validacion_coordinador_estado_interno(p_pk_tactividad);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_validacion_coordinador_resolver_interno(BIGINT, BIGINT, VARCHAR, VARCHAR)
    IS 'INTERNO: guarda la decisión (APROBADA/DECLINADA) y la observación del Coordinador, reemplazando la vigente; devuelve el estado. Sin validaciones ni gate: los aplica fn_actividad_validacion_coordinador_resolver.';
