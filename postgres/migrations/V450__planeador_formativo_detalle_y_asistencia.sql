-- V450 - Asistencia de una actividad: la de su fecha fin (FECHA_CIERRE) en
-- cuanto llega y se toma; antes, la de su primer día. Agrega los bloques de
-- la asignatura (en formativas, de cualquier asignatura); la Vista
-- Asistencias predomina sobre la tomada en el Planeador.
-- Solo lectura. También es_formativa en GET /planeador/actividades/:ID.
-- Depende de: V137 (fn_asistencia_tipo_pk), V139 (TASISTENCIA.ORIGEN), V243.

DROP FUNCTION IF EXISTS academico_test.fn_actividad_asistencia_valida(BIGINT, BIGINT, DATE);

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_fecha_asistencia(p_pk_tactividad BIGINT)
RETURNS DATE
LANGUAGE sql
STABLE
AS $$
    SELECT CASE WHEN a.FECHA_CIERRE IS NOT NULL AND a.FECHA_CIERRE <= CURRENT_DATE THEN a.FECHA_CIERRE
                ELSE COALESCE(a.FECHA_INICIO, a.FECHA_CREACION) END
      FROM academico_test.TACTIVIDAD a
     WHERE a.PK_TACTIVIDAD = p_pk_tactividad;
$$;

-- Primer día de la actividad: vale mientras la fecha fin no tenga asistencia.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_fecha_inicio_asistencia(p_pk_tactividad BIGINT)
RETURNS DATE
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(a.FECHA_INICIO, a.FECHA_CREACION)
      FROM academico_test.TACTIVIDAD a
     WHERE a.PK_TACTIVIDAD = p_pk_tactividad;
$$;

-- Ausente = todos los bloques del día son No asistió (2, o 3 histórico); un
-- bloque en Asistió o Llegó tarde lo hace presente. Justificada = algún bloque
-- trae excusa (archivo, o 3/6 históricos): una excusa cubre todo el día.
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_asistencia_dia(
    p_fk_tmatricula BIGINT,
    p_pk_tactividad BIGINT
)
RETURNS TABLE (fecha DATE, tipo_valor VARCHAR, fk_tlv_tipo_asistencia BIGINT, ausente BOOLEAN,
               justificada BOOLEAN, origen VARCHAR, pk_tasistencia BIGINT, fk_soporte_archivo BIGINT,
               observacion VARCHAR)
LANGUAGE sql
STABLE
AS $$
    WITH base AS (
        SELECT a.FK_TASIGNATURA,
               academico_test.fn_actividad_fecha_asistencia(a.PK_TACTIVIDAD) AS fin,
               academico_test.fn_actividad_fecha_inicio_asistencia(a.PK_TACTIVIDAD) AS inicio,
               academico_test.fn_actividad_es_formativa(a.PK_TACTIVIDAD) AS formativa
          FROM academico_test.TACTIVIDAD a
         WHERE a.PK_TACTIVIDAD = p_pk_tactividad
    ), candidatas AS (
        SELECT s.*, lv.VALOR AS valor
          FROM base
          JOIN academico_test.TASISTENCIA s
            ON s.FK_TMATRICULA = p_fk_tmatricula AND s.FECHA IN (base.fin, base.inicio) AND s.ACTIVE = TRUE
           AND (base.formativa OR s.FK_TASIGNATURA = base.FK_TASIGNATURA)
          JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = s.FK_TLV_TIPO_ASISTENCIA
    ), act AS (
        -- La fecha fin manda si ya se tomó; si no, sigue el primer día.
        SELECT base.FK_TASIGNATURA, base.formativa,
               CASE WHEN EXISTS (SELECT 1 FROM candidatas c WHERE c.FECHA = base.fin)
                    THEN base.fin ELSE base.inicio END AS fecha
          FROM base
    ), filas AS (
        SELECT c.* FROM candidatas c JOIN act ON c.FECHA = act.fecha
    ), vigentes AS (
        -- La de la Vista predomina; la del Planeador vale solo si la Vista no se tomó.
        SELECT f.* FROM filas f
         WHERE f.ORIGEN = 'ASISTENCIA'
            OR NOT EXISTS (SELECT 1 FROM filas x WHERE x.ORIGEN = 'ASISTENCIA')
    ), agg AS (
        SELECT COUNT(*) AS n,
               BOOL_AND(v.valor IN ('2', '3')) AS ausente,
               BOOL_OR(v.valor IN ('5', '6')) AS tarde,
               BOOL_OR(v.FK_SOPORTE_ARCHIVO IS NOT NULL OR v.valor IN ('3', '6')) AS justificada,
               BOOL_OR(v.ORIGEN = 'ASISTENCIA') AS de_vista,
               MAX(v.PK_TASISTENCIA) AS pk,
               MAX(v.FK_SOPORTE_ARCHIVO) AS soporte,
               (ARRAY_AGG(v.OBSERVACION ORDER BY v.PK_TASISTENCIA DESC)
                  FILTER (WHERE NULLIF(TRIM(v.OBSERVACION), '') IS NOT NULL))[1] AS observacion
          FROM vigentes v
    )
    SELECT act.fecha,
           t.valor::VARCHAR,
           academico_test.fn_asistencia_tipo_pk(t.valor::NUMERIC),
           agg.ausente,
           COALESCE(agg.justificada, FALSE),
           (CASE WHEN agg.de_vista THEN 'ASISTENCIA' ELSE 'PLANEADOR' END)::VARCHAR,
           agg.pk, agg.soporte, agg.observacion::VARCHAR
      FROM act CROSS JOIN agg
     CROSS JOIN LATERAL (SELECT CASE WHEN agg.ausente THEN '2' WHEN agg.tarde THEN '5' ELSE '1' END AS valor) t
     WHERE agg.n > 0;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_fecha_asistencia(BIGINT)
    IS 'Fecha a la que se escribe la asistencia de la actividad: su fecha fin (FECHA_CIERRE) si ya llegó; si no, su primer día (FECHA_INICIO; sin ella, FECHA_CREACION). Ambas son días con clase porque la actividad no se crea fuera del horario.';
COMMENT ON FUNCTION academico_test.fn_actividad_fecha_inicio_asistencia(BIGINT)
    IS 'Primer día de la actividad (FECHA_INICIO; sin ella, FECHA_CREACION): su asistencia vale mientras la fecha fin no tenga asistencia tomada. La usan fn_actividad_asistencia_dia y la sincronización con la Vista.';
COMMENT ON FUNCTION academico_test.fn_actividad_asistencia_dia(BIGINT, BIGINT)
    IS 'Asistencia tomada (TASISTENCIA) del estudiante en la fecha fin de la actividad si ya llegó y tiene asistencia, o si no en su primer día, agregada por bloques: de la asignatura de la actividad, o de cualquiera si es formativa. Filas de la Vista (ORIGEN ASISTENCIA) predominan sobre la del Planeador. tipo_valor normalizado a 1/2/5; ausente si todos los bloques son No asistió; justificada si algún bloque trae archivo (o 3/6 históricos). Sin filas no devuelve nada. No mira la copia congelada de TACTIVIDAD_NOTA: eso es fn_actividad_asistencia_estudiante (V496.5).';

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_asistencia_fecha_resolver(
    p_fk_tmatricula BIGINT,
    p_pk_tactividad BIGINT
)
RETURNS DATE
LANGUAGE sql
STABLE
AS $$
    SELECT d.fecha FROM academico_test.fn_actividad_asistencia_dia(p_fk_tmatricula, p_pk_tactividad) d;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_asistencia_fecha_resolver(BIGINT, BIGINT)
    IS 'Primer día de la actividad (fn_actividad_fecha_asistencia) si ese día se tomó asistencia al estudiante (Vista o Planeador); NULL si no. Lo leen la planilla (fechaAsistencia/tieneAsistencia) y la tabla de calificaciones (fecha_asistencia). La asistencia ya no bloquea por sí sola: bloquea el estado de resultado (V496.5).';

-- Reglas 62/73: la asistencia ya no bloquea observar; la existencia de la
-- asignación la resuelve fn_actividad_estudiante_actividad (V227).
DROP FUNCTION IF EXISTS academico_test.fn_actividad_nota_asistencia_assert_preescolar(BIGINT, DATE);

UPDATE public.query q
   SET detail = q.detail || ' V450 -- La asistencia de una actividad es la de su primer dia (FECHA_INICIO), agregando los bloques de la asignatura (en FORMATIVAS, de cualquier asignatura); la de la Vista Asistencias predomina sobre la tomada en el Planeador. fechaAsistencia/tieneAsistencia (fn_actividad_asistencia_fecha_resolver): ese primer dia si ya se tomo asistencia, NULL si no. Cada fila agrega es_formativa (TRUE = se registra con OBSERVACION, no con nota). OJO: la columna `fecha` sigue siendo el ECO de ?fecha= (default hoy).'
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   IN ('/planeador/planilla/calificaciones', '/planeador/actividades/:ID/calificaciones')
   AND q.http_method     = 'GET'
   AND q.detail NOT LIKE '%V450 --%';

UPDATE public.query q
   SET query = 'SELECT d.*,
       academico_test.fn_actividad_es_formativa(d.pk_tactividad) AS es_formativa
  FROM academico_test.fn_actividad_buscar_por_pk(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    COALESCE(CAST(:QUERY.DIAS_GRACIA AS INT), 2)
) d;',
       detail = q.detail || ' V450 -- Agrega es_formativa (fn_actividad_es_formativa, V243): TRUE = la actividad cuelga de una unidad con referente NO evaluativo (preescolar / "Proyecto Pedagogico") y se registra con OBSERVACION, no con nota -- fn_actividad_nota_calificar la rechaza con 22023. Es la MISMA columna que ya devuelve GET /planeador/planilla/columnas. NO se puede deducir en el cliente: una actividad evaluativa sin instrumento definido tambien llega con fk_tlv_instrumento_evaluacion NULL, y es_evaluativa es otro concepto (flag manual con DEFAULT S). Una actividad SIN unidad devuelve FALSE por decision explicita de V243.'
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/actividades/:ID'
   AND q.http_method     = 'GET'
   AND q.detail NOT LIKE '%V450 --%';
