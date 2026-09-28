-- ===========================================================================
-- V476 - El referente decide si la actividad lleva nota, tambien sin unidad.
--
-- fn_actividad_contexto_evaluativo: unica definicion de "este (grupo,
-- asignatura, unidad) admite nota"; fn_actividad_es_formativa (V475) pasa a
-- delegar en ella. Las filas de public.query de configuracion anuncian las
-- claves esFormativo / esSumativoSugerido.
-- Depende de: V460 (contexto), V475 (fn_actividad_es_formativa), V451.
-- ===========================================================================

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_contexto_evaluativo(
    p_fk_tgrupo      BIGINT,
    p_fk_tasignatura BIGINT,
    p_fk_tunidad     BIGINT
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    SELECT CASE
        -- Con unidad manda la unidad: ya eligio referente.
        WHEN p_fk_tunidad IS NOT NULL
            THEN academico_test.fn_unidad_referente_evaluativo(p_fk_tunidad)
        -- Sin unidad, el referente se deriva del (grado del grupo, asignatura),
        -- igual que en fn_actividad_configuracion_contexto.
        ELSE COALESCE((
            SELECT lv.VALOR = 'EVALUATIVO'
              FROM academico_test.TGRUPO g
              JOIN academico_test.TREFERENTE_CURRICULAR rc
                ON rc.PK_REFERENTE_CURRICULAR =
                   academico_test.fn_unidad_referente_aplicable(
                       g.FK_TGRADO, p_fk_tasignatura, NULL)
              JOIN academico_test.TLISTA_VALOR lv
                ON lv.PK_LISTA_VALOR = rc.FK_TLV_ENFOQUE_PEDAGOGICO
             WHERE g.PK_TGRUPO = p_fk_tgrupo), TRUE)
    END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_contexto_evaluativo(BIGINT, BIGINT, BIGINT)
    IS 'TRUE si el contexto de una actividad admite EVALUACION CON NOTA, segun el referente curricular que le aplica. Con p_fk_tunidad manda la unidad (fn_unidad_referente_evaluativo, V214.2); sin ella el referente se DERIVA del (grado del grupo, asignatura) con fn_unidad_referente_aplicable (V451) -- la misma regla que fn_actividad_configuracion_contexto usa para pintar el formulario, ahora tambien disponible para la escritura, que antes solo sabia decidir con unidad. Es el gemelo "antes de que la actividad exista" de fn_actividad_es_formativa (V475), que delega en ella. Devuelve TRUE cuando no hay de donde decidir (sin grupo, o sin referente activo para ese grado y asignatura): el default historico es la actividad con nota, y no se bloquea un alta por falta de catalogo. Sin gate: helper de lectura invocado desde funciones que ya gatearon. V476.';

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_es_formativa(
    p_pk_tactividad BIGINT
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(
        (SELECT NOT academico_test.fn_actividad_contexto_evaluativo(
                        a.FK_TGRUPO, a.FK_TASIGNATURA, a.FK_TUNIDAD)
           FROM academico_test.TACTIVIDAD a
          WHERE a.PK_TACTIVIDAD = p_pk_tactividad
            AND a.ACTIVE = TRUE),
        FALSE
    );
$$;

UPDATE public.query q
   SET detail = q.detail || ' V476 -- campos_disponibles gana esFormativo (boolean) y esSumativoSugerido (S|N): el VALOR que le corresponde al referente de la actividad, no su visibilidad. Es lo que el formulario debe traer marcado en "Es sumativa" y lo que fn_actividad_crear guarda cuando no se le manda es_evaluativa; hasta V475 el front tenia que deducirlo de evaluacion.visible y, en una actividad SIN unidad, ni siquiera eso funcionaba.'
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/actividades/:ID/configuracion'
   AND q.http_method     = 'GET'
   AND q.detail NOT LIKE '%V476 --%';

UPDATE public.query q
   SET detail = q.detail || ' V476 -- La respuesta gana esFormativo (boolean) y esSumativoSugerido (S|N) al lado de esSumativoConsultado: el primero es lo que el usuario pregunto, estos dos son lo que el referente DICTA. Con referente Formativo (y en Preescolar, formativo por definicion) esSumativoSugerido = N: es lo que el front debe traer marcado y lo que POST /planeador/actividades guarda si no envia es_evaluativa. Enviar es_evaluativa = S contra un referente Formativo se rechaza con 422 (22023), venga o no la actividad con unidad.'
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/actividades/configuracion'
   AND q.http_method     = 'GET'
   AND q.detail NOT LIKE '%V476 --%';
