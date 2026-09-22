-- ===========================================================================
-- V475 — fn_actividad_es_formativa deja de responder FALSE cuando la
-- actividad no tiene unidad: desde V218 una actividad puede nacer sin
-- TUNIDAD (Preescolar/Transicion), y V243 devolvia FALSE ahi porque en su
-- momento no habia con que resolver el referente. Si lo hay: la actividad
-- guarda FK_TGRUPO -> TGRADO y FK_TASIGNATURA, que es justo la entrada de
-- fn_unidad_referente_aplicable (V451). Sin esto, una actividad formativa
-- sin unidad acepta nota (fn_actividad_nota_calificar) y rechaza la
-- observacion (fn_actividad_observar_*), al reves de lo que dice su
-- referente y de lo que pinta fn_actividad_configuracion_contexto (V459).
-- Misma firma: arregla a la vez sus llamadores de V441/V450/V454/V461/
-- V463/V469. Depende de: V243 (funcion), V451 (derivacion), V218 (columnas).
-- ===========================================================================
SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_es_formativa(
    p_pk_tactividad BIGINT
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(
        (SELECT CASE
                    -- Con unidad manda la unidad: mismo helper de siempre.
                    WHEN a.FK_TUNIDAD IS NOT NULL
                        THEN NOT academico_test.fn_unidad_referente_evaluativo(a.FK_TUNIDAD)
                    -- Sin unidad, el referente se deriva del (grado, asignatura)
                    -- igual que en fn_actividad_configuracion_contexto: una
                    -- unica definicion de la regla, la de V451.
                    ELSE (
                        SELECT lv.VALOR <> 'EVALUATIVO'
                          FROM academico_test.TREFERENTE_CURRICULAR rc
                          JOIN academico_test.TLISTA_VALOR lv
                            ON lv.PK_LISTA_VALOR = rc.FK_TLV_ENFOQUE_PEDAGOGICO
                         WHERE rc.PK_REFERENTE_CURRICULAR =
                               academico_test.fn_unidad_referente_aplicable(
                                   g.FK_TGRADO, a.FK_TASIGNATURA, NULL)
                    )
                END
           FROM academico_test.TACTIVIDAD a
           LEFT JOIN academico_test.TGRUPO g ON g.PK_TGRUPO = a.FK_TGRUPO
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
