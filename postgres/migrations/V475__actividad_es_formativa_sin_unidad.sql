-- ===========================================================================
-- V475 - El referente decide si la actividad lleva nota, tambien sin unidad
-- (desde V218 una actividad puede nacer sin TUNIDAD; V243 devolvia FALSE).
-- fn_actividad_contexto_evaluativo: unica definicion de "este (grupo,
-- asignatura, unidad) admite nota"; con unidad manda la unidad, sin ella el
-- referente se deriva del (grado, asignatura) con fn_unidad_referente_aplicable.
-- fn_actividad_es_formativa delega en ella (misma firma: arregla a la vez a
-- sus llamadores de V441/V450/V454/V461/V463/V469).
-- El detail de /planeador/actividades/configuracion se construye en orden
-- V459 (texto) -> V460 (REPLACE) -> V475 (append): se re-aplican juntas.
-- Depende de: V243 (funciones), V451 (derivacion), V218 (columnas), V460.
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

-- Delega en fn_actividad_contexto_evaluativo: tiene que crearse despues.
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

COMMENT ON FUNCTION academico_test.fn_actividad_es_formativa(BIGINT)
    IS 'TRUE si una actividad debe tratarse como FORMATIVA (preescolar/"Proyecto Pedagogico"): el referente curricular que le aplica tiene un enfoque pedagogico que NO es EVALUATIVO. Dos caminos, en este orden: (1) con TACTIVIDAD.FK_TUNIDAD, el referente de la unidad (fn_unidad_referente_evaluativo, V214.2); (2) SIN unidad -- posible desde V218 --, el referente se DERIVA del (grado del grupo, asignatura) con fn_unidad_referente_aplicable (V451), la misma regla que usa fn_actividad_configuracion_contexto (V459) para apagar la seccion de evaluacion en ese mismo formulario. Hasta V474 el caso (2) respondia FALSE fijo (decision de V243, tomada cuando no habia de donde derivar el referente): una actividad de Transicion sin unidad se dejaba calificar con nota y rechazaba la observacion, contradiciendo a la configuracion que la pinto como formativa. Sigue devolviendo FALSE si la actividad no existe, esta inactiva, o no hay referente activo para ese (grado, asignatura) -- no bloquear el flujo normal. La usan fn_actividad_nota_calificar (rechaza 22023 si es formativa), fn_actividad_observar_grupal/_estudiante y los soportes individuales (exigen que SI lo sea), la planilla y el detalle de actividad. V243/V475.';

-- Los detail de V450 anunciaban la decision vieja como contrato del endpoint.
UPDATE public.query q
   SET detail = q.detail || ' V475 -- Correccion del parrafo anterior: una actividad SIN unidad ya NO devuelve FALSE por defecto. Su referente se deriva del grado del grupo y la asignatura (fn_unidad_referente_aplicable), asi que una actividad de Preescolar sin unidad responde es_formativa = true, como corresponde a su referente y como ya la pintaba GET /planeador/actividades/configuracion. Solo queda FALSE si no hay ningun referente activo para ese (grado, asignatura).'
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   IN ('/planeador/actividades/:ID', '/planeador/actividades/:ID/pantalla-edicion')
   AND q.http_method     = 'GET'
   AND q.detail NOT LIKE '%V475 --%';

-- Las filas de configuracion anuncian esFormativo / esSumativoSugerido.
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
