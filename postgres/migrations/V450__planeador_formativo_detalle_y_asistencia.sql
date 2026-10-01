-- V450 - Asistencia por actividad en Preescolar: helpers de fecha y validez de
-- la asistencia (solo lectura: ya no bloquea observar), y es_formativa en
-- GET /planeador/actividades/:ID. La fila de pantalla-edicion la define V496.4.


CREATE OR REPLACE FUNCTION academico_test.fn_actividad_asistencia_valida(
    p_fk_tmatricula BIGINT,
    p_pk_tactividad BIGINT,
    p_fecha         DATE
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1
          FROM academico_test.TASISTENCIA s
          JOIN academico_test.TACTIVIDAD a ON a.PK_TACTIVIDAD = p_pk_tactividad
         WHERE s.FK_TMATRICULA = p_fk_tmatricula
           AND s.FECHA         = p_fecha
           AND s.ACTIVE = TRUE
           AND s.FK_TLV_TIPO_ASISTENCIA IS DISTINCT FROM academico_test.fn_asistencia_tipo_pk(2)
           AND CASE
                 WHEN academico_test.fn_actividad_es_formativa(p_pk_tactividad) THEN TRUE
                 ELSE s.FK_TASIGNATURA = a.FK_TASIGNATURA
               END
    );
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_asistencia_valida(BIGINT, BIGINT, DATE)
    IS 'TRUE si el estudiante (por matricula) tiene, en p_fecha, una asistencia ACTIVA que habilita calificar u observar la actividad: alguna fila que NO sea inasistencia injustificada (TIPO_ASISTENCIA VALOR=2) y que ademas pertenezca al contexto correcto -- en una actividad FORMATIVA cualquier sesion del dia cuenta (la jornada de preescolar es continua y desde V436 la asistencia ya no se escribe por FK_TACTIVIDAD), en el resto tiene que ser la asignatura de la actividad. Con varios bloques alcanza UNA fila valida. Es la UNICA definicion de la regla: la usan, a traves de fn_actividad_asistencia_fecha_resolver, las lecturas de la planilla y de la tabla de calificaciones (la asistencia ya no bloquea calificar ni observar, Reglas 62/73). V450.';

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_asistencia_fecha_resolver(
    p_fk_tmatricula BIGINT,
    p_pk_tactividad BIGINT
)
RETURNS DATE
LANGUAGE sql
STABLE
AS $$
    SELECT s.FECHA
      FROM academico_test.TASISTENCIA s
      JOIN academico_test.TACTIVIDAD a ON a.PK_TACTIVIDAD = p_pk_tactividad
     WHERE s.FK_TMATRICULA = p_fk_tmatricula
       AND s.ACTIVE = TRUE
       AND s.FECHA <= CURRENT_DATE
       AND (a.FECHA_INICIO IS NULL OR s.FECHA >= a.FECHA_INICIO)
       AND (a.FECHA_CIERRE IS NULL OR s.FECHA <= a.FECHA_CIERRE)
       AND academico_test.fn_actividad_asistencia_valida(p_fk_tmatricula, p_pk_tactividad, s.FECHA)
     ORDER BY s.FECHA DESC
     LIMIT 1;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_asistencia_fecha_resolver(BIGINT, BIGINT)
    IS 'La fecha que hay que mandar en BODY.FECHA para calificar u observar a ESE estudiante en ESA actividad: la mas reciente, dentro de la ventana [FECHA_INICIO, FECHA_CIERRE] de la actividad (extremo NULL = abierto), que fn_actividad_asistencia_valida acepta -- solo fechas <= hoy; sin ninguna, NULL. NULL = no hay ninguna pasada o de hoy que habilite, o sea que la celda no es calificable/observable todavia y cualquier intento devolveria 22023. Ya NO cae a una fecha futura de la ventana (bug: la pantalla de marcar mostraba "sin asistencia" para hoy y el gate igual dejaba guardar via esa fecha futura). Definida EN TERMINOS del predicado para que la lectura y el gate no puedan desincronizarse. V450.';

-- Reglas 62/73: la asistencia ya no bloquea observar; la existencia de la
-- asignación la resuelve fn_actividad_estudiante_actividad (V227).
DROP FUNCTION IF EXISTS academico_test.fn_actividad_nota_asistencia_assert_preescolar(BIGINT, DATE);

UPDATE public.query q
   SET detail = q.detail || ' V450 -- En las actividades FORMATIVAS, la asistencia que habilita observar ya no tiene que ser una fila con FK_TACTIVIDAD (V436 dejo de escribirlas): basta con que ESE dia se le haya tomado asistencia al estudiante en cualquier sesion y que no sea inasistencia injustificada. fechaAsistencia/tieneAsistencia se calculan con esa misma regla, compartida con el gate (fn_actividad_asistencia_valida / _fecha_resolver). Cada fila agrega ademas es_formativa (TRUE = se registra con OBSERVACION, no con nota) y fecha_asistencia (la fecha en la que ESE estudiante tiene una asistencia que el gate aceptaria; NULL = no se puede calificar ni observar todavia). OJO: la columna `fecha` sigue siendo el ECO de ?fecha= (default hoy) y NO sirve para BODY.FECHA: para eso va fecha_asistencia.'
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
