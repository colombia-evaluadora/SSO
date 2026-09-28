-- ===========================================================================
-- V441 — Planilla de calificacion: indices del LATERAL por celda, el DROP que
-- deja a V454 cambiar el RETURNS TABLE del header y el detail de las filas de
-- V248. Las funciones vigentes estan en V454 (header) y V469 (cuerpo).
-- ===========================================================================

SET search_path TO academico_test, public;

CREATE INDEX IF NOT EXISTS idx_tasistencia_mat_asig_fecha
    ON academico_test.TASISTENCIA (FK_TMATRICULA, FK_TASIGNATURA, FECHA)
 WHERE ACTIVE = TRUE AND FK_TASIGNATURA IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_tasistencia_mat_act_fecha
    ON academico_test.TASISTENCIA (FK_TMATRICULA, FK_TACTIVIDAD, FECHA)
 WHERE ACTIVE = TRUE AND FK_TACTIVIDAD IS NOT NULL;

-- Solo si aun tiene el retorno de V239: re-aplicar no tumba la de V454.
DO $$
DECLARE
    v_fn regprocedure := to_regprocedure(
        'academico_test.fn_planilla_columnas_listar(bigint,bigint,bigint,bigint,date,date,varchar)');
BEGIN
    IF v_fn IS NOT NULL
       AND pg_get_function_result(v_fn) NOT LIKE '%metodo_valoracion%' THEN
        DROP FUNCTION academico_test.fn_planilla_columnas_listar(
            BIGINT, BIGINT, BIGINT, BIGINT, DATE, DATE, VARCHAR);
    END IF;
END $$;

-- Las filas de V248 nacieron con ON CONFLICT DO NOTHING: UPDATE aparte.
UPDATE public.query q
   SET detail = q.detail || ' V441 -- El HEADER agrega es_formativa (true = la actividad cuelga de una unidad FORMATIVA: el cliente abre el popover de OBSERVACION, no el de nota; ES_EVALUATIVA es otro concepto, un flag manual de la actividad con DEFAULT S) y metodo_valoracion (solo cuando instrumento = OTRO: el metodo de valoracion configurado en TACTIVIDAD_OTRO, NULL si no es OTRO o no tiene metodo).'
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/planilla/columnas'
   AND q.http_method     = 'GET'
   AND q.detail NOT LIKE '%V441 --%';

UPDATE public.query q
   SET detail = q.detail || ' V441 -- Cada celda agrega esFormativa, fechaAsistencia, tieneAsistencia y evidencias. fechaAsistencia es la fecha, dentro de la ventana [fecha_inicio, fecha_cierre] de la actividad (extremo NULL = abierto), en la que ESE estudiante tiene una asistencia ACTIVA que el gate de calificacion aceptaria: llave por asignatura para las actividades normales y por actividad para las formativas, excluyendo la inasistencia injustificada (TIPO_ASISTENCIA VALOR=2). Desempate: la mas reciente <= hoy y, si no hay ninguna pasada, la primera futura de la ventana. El cliente debe mandar esa fecha en BODY.FECHA al calificar; tieneAsistencia=false (fechaAsistencia NULL) significa que la celda no es calificable todavia y debe pintarse deshabilitada, porque cualquier intento devolveria 22023. evidencias son los adjuntos de la observacion (TACTIVIDAD_SOPORTE) con la misma forma que GET del detalle de nota: [{pk, fkTarchivo, nombre, fecha}], siempre [] en celdas no formativas.'
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/planilla/calificaciones'
   AND q.http_method     = 'GET'
   AND q.detail NOT LIKE '%V441 --%';
