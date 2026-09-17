-- ===========================================================================
-- V282 — Planeador: la configuracion de la actividad ANTES de crearla, a
-- partir de la unidad escogida (CU-86e311xxp).
-- Nota: los bloques criterio/evaluacion/ponderacion los construye V440.
--
-- EL HUECO DEL FLUJO. El flujo de creacion es:
--
--   grado -> asignatura -> referente (autocompletado) -> enunciados de la
--   unidad -> [crear unidad] -> nueva actividad: se escoge la unidad y el
--   formulario se autocompleta con lo que aporta el referente de esa unidad
--
-- El ultimo paso ya estaba resuelto... pero solo DESPUES de crear la
-- actividad: GET /planeador/actividades/:ID/configuracion (V214.2) devuelve
-- campos_disponibles + el arbol de enunciados/evidencias de la unidad, y pide
-- un PK_TACTIVIDAD. En el formulario de creacion la actividad todavia no
-- existe, asi que no habia forma de saber que secciones pintar ni que
-- instrumentos ofrecer hasta despues de guardar -- justo al reves de lo que
-- necesita la pantalla.
--
-- Lo que SI se podia pedir antes de crear:
--   * el CATALOGO de enunciados y evidencias que se pueden marcar ->
--     GET /planeador/referente-curricular?grado=&asignatura= (V278). OJO: NO
--     sirve GET /planeador/unidades/:ID/referente, que desde V255 devuelve
--     solo los enunciados que la unidad YA relaciono, no el arbol completo;
--   * los campos de la UNIDAD -> GET /planeador/unidades/:ID (campos_disponibles).
-- Lo que faltaba es lo de la ACTIVIDAD: criterio / evaluacion (con sus
-- instrumentosPermitidos) / ponderacion.
--
-- ESTA FUNCION EXIGE UNA UNIDAD. Para la actividad que todavia no pertenece a
-- ninguna, usar fn_actividad_configuracion_contexto (V422), que resuelve lo
-- mismo desde (grupo, asignatura) y ademas devuelve los limites de la seccion
-- Programacion.
--
-- -------------------------------------------------------------------------
-- POR QUE SE PUEDE RESOLVER SIN LA ACTIVIDAD
--
-- Mirando fn_actividad_campos_disponibles (V214.2), sus tres respuestas se
-- derivan de la UNIDAD, no de la actividad:
--   * criterio  -> nivel de ensenanza del grado de la unidad
--   * evaluacion-> referente de la unidad (EVALUATIVO) y su TIPO_EVALUACION
--   * ponderacion-> metodo de calculo de la unidad (V73/V223)
-- El unico dato propio de la actividad es ES_EVALUATIVA, y en el formulario de
-- creacion lo esta eligiendo el usuario en ese momento: aqui entra como
-- parametro (p_es_evaluativa, por defecto 'S').
--
-- Asi que esta funcion NO reimplementa las reglas: compone los helpers que ya
-- existen y que ya son por unidad -- fn_unidad_referente_evaluativo,
-- fn_unidad_referente_tipo_evaluacion,
-- fn_instrumento_permitido_por_tipo_evaluacion (V214.2) y
-- fn_unidad_calculo_definitiva_modo (V223). Los motivos y la forma del JSON se
-- mantienen iguales a los de la version por actividad para que el front pueda
-- usar el mismo codigo de render antes y despues de crear.
--
-- Depende de: V214.2 (los helpers y la forma del JSON), V223
-- (fn_unidad_calculo_definitiva_modo), V216 (menu PLANEADOR, alcance).
-- ===========================================================================

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_configuracion_actividad(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tunidad             BIGINT,
    -- Lo unico que no sale de la unidad: si la actividad que se esta creando
    -- va a ser evaluativa. Es lo que el usuario acaba de marcar en el
    -- formulario. 'S' por defecto, igual que el default de TACTIVIDAD.
    p_es_evaluativa          VARCHAR DEFAULT 'S'
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_nombre_unidad   VARCHAR;
    v_nivel_nombre    VARCHAR;
    v_es_evaluativa   VARCHAR := UPPER(TRIM(COALESCE(p_es_evaluativa, 'S')));
    v_evaluativo      BOOLEAN;
    v_tipo            VARCHAR;
    v_modo            VARCHAR;
    v_es_preescolar   BOOLEAN;
    v_instrumentos    JSONB;
    v_ponderacion     JSONB;
BEGIN
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', NULL, NULL, p_pk_tunidad
    );

    SELECT u.NOMBRE, ne.NOMBRE
      INTO v_nombre_unidad, v_nivel_nombre
      FROM academico_test.TUNIDAD u
      JOIN academico_test.TGRADO g            ON g.PK_TGRADO = u.FK_TGRADO
      LEFT JOIN academico_test.TNIVEL_ENSENANZA ne
             ON ne.PK_NIVEL_ENSENANZA = g.FK_TNIVEL_ENSENANZA
     WHERE u.PK_TUNIDAD = p_pk_tunidad
       AND u.ACTIVE = TRUE;

    IF v_nombre_unidad IS NULL THEN
        RAISE EXCEPTION 'No se encontro la unidad solicitada' USING ERRCODE = 'P0002';
    END IF;

    -- Mismo criterio que V214.2 para Preescolar (por NOMBRE del nivel, no por
    -- PK: los pks de TNIVEL_ENSENANZA no son estables entre bases).
    v_es_preescolar := COALESCE(v_nivel_nombre ILIKE 'preescolar%', FALSE);

    v_evaluativo := academico_test.fn_unidad_referente_evaluativo(p_pk_tunidad);
    v_tipo       := academico_test.fn_unidad_referente_tipo_evaluacion(p_pk_tunidad);
    v_modo       := academico_test.fn_unidad_calculo_definitiva_modo(p_pk_tunidad);

    -- Instrumentos que aplican al TIPO_EVALUACION del referente de la unidad.
    -- Se filtran con el mismo helper que usa la version por actividad, asi que
    -- la lista no puede discrepar de la que se vera despues de crear.
    v_instrumentos := CASE
        WHEN NOT COALESCE(v_evaluativo, FALSE) OR v_es_evaluativa = 'N'
            THEN '[]'::jsonb
        ELSE COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'pk',     lv.PK_LISTA_VALOR,
                       'valor',  lv.VALOR,
                       'nombre', lv.NOMBRE)
                       ORDER BY lv.PK_LISTA_VALOR)
              FROM academico_test.TLISTA_VALOR lv
             WHERE lv.CATEGORIA = 'INSTRUMENTO_EVALUACION'
               AND lv.ACTIVE = TRUE
               AND academico_test.fn_instrumento_permitido_por_tipo_evaluacion(lv.VALOR, v_tipo)
        ), '[]'::jsonb)
    END;

    -- ponderacion: manda el metodo de calculo de la unidad (V223). Misma
    -- cascada y mismos textos que fn_actividad_campos_disponibles.
    v_ponderacion := CASE
        WHEN v_es_evaluativa = 'N' THEN jsonb_build_object(
            'visible', FALSE, 'requerido', FALSE, 'modo', NULL,
            'motivo', 'La actividad no es evaluativa; la ponderacion no aplica')
        WHEN v_modo = 'PONDERAR' THEN jsonb_build_object(
            'visible', TRUE, 'requerido', TRUE, 'modo', 'PORCENTAJE',
            'campo', 'PONDERACION',
            'motivo', 'la unidad pondera sus actividades')
        WHEN v_modo = 'SUMATORIA' THEN jsonb_build_object(
            'visible', TRUE, 'requerido', TRUE, 'modo', 'PUNTAJE',
            'campo', 'NOTA_MAXIMA', 'autocalculado', TRUE,
            'motivo', 'la unidad suma puntajes; el % lo calcula el sistema')
        WHEN v_modo = 'PROMEDIAR' THEN jsonb_build_object(
            'visible', FALSE, 'requerido', FALSE, 'modo', NULL,
            'motivo', 'la unidad promedia, la ponderacion no aplica')
        ELSE jsonb_build_object(
            'visible', FALSE, 'requerido', FALSE, 'modo', NULL,
            'motivo', 'la unidad aun no tiene metodo de calculo elegido')
    END;

    RETURN jsonb_build_object(
        'pkTunidad', p_pk_tunidad,
        'unidad',    v_nombre_unidad,
        'nivelEnsenanza', v_nivel_nombre,
        'esEvaluativaConsultada', v_es_evaluativa,
        'campos_disponibles', jsonb_build_object(
            'criterio', jsonb_build_object(
                'visible',   NOT v_es_preescolar,
                'requerido', FALSE,
                'motivo',    CASE
                    WHEN v_es_preescolar
                        THEN 'El grado de la unidad pertenece al nivel Preescolar: la relacion con criterios de rubrica no aplica'
                    ELSE 'Opcional: la actividad puede relacionarse con criterios de la rubrica de la unidad'
                END),
            'evaluacion', jsonb_build_object(
                'visible',   COALESCE(v_evaluativo, FALSE) AND v_es_evaluativa <> 'N',
                'requerido', COALESCE(v_evaluativo, FALSE) AND v_es_evaluativa <> 'N',
                'motivo',    CASE
                    WHEN v_es_evaluativa = 'N'
                        THEN 'La actividad se creara como NO evaluativa; no hay seccion de evaluacion'
                    WHEN NOT COALESCE(v_evaluativo, FALSE)
                        THEN 'El referente curricular de la unidad no es EVALUATIVO (o la unidad no tiene referente)'
                    ELSE 'El referente curricular de la unidad es EVALUATIVO: la actividad requiere instrumento de evaluacion'
                END,
                'tipoEvaluacion', v_tipo,
                'instrumentosPermitidos', v_instrumentos),
            'ponderacion', v_ponderacion,
            'recuperacion', academico_test.fn_actividad_recuperacion_campos_disponibles(
                                COALESCE(v_evaluativo, FALSE), v_es_evaluativa))
    );
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_configuracion_actividad(BIGINT, BIGINT, VARCHAR)
    IS 'La configuracion del formulario de NUEVA ACTIVIDAD a partir de la unidad escogida, es decir ANTES de que la actividad exista. Cubre el hueco del flujo: GET /planeador/actividades/:ID/configuracion (V214.2) responde lo mismo pero exige un PK_TACTIVIDAD, y en el formulario de creacion la actividad todavia no esta creada -- no habia forma de saber que secciones pintar ni que instrumentos ofrecer hasta despues de guardar. Se puede resolver sin la actividad porque las tres respuestas de fn_actividad_campos_disponibles se derivan de la UNIDAD (criterio: nivel de ensenanza de su grado; evaluacion: referente EVALUATIVO y su TIPO_EVALUACION; ponderacion: metodo de calculo de la unidad); el unico dato propio de la actividad es ES_EVALUATIVA, que en el formulario lo esta eligiendo el usuario y aqui entra como p_es_evaluativa (default ''S''). NO reimplementa las reglas: compone los helpers que ya existen y ya son por unidad -- fn_unidad_referente_evaluativo, fn_unidad_referente_tipo_evaluacion, fn_instrumento_permitido_por_tipo_evaluacion (V214.2) y fn_unidad_calculo_definitiva_modo (V223) --, y conserva la forma del JSON y los textos de motivo de la version por actividad para que el front use el mismo codigo de render antes y despues de crear. Preescolar se detecta por NOMBRE del nivel (ILIKE ''preescolar%''), no por PK, igual que V214.2: los pks de TNIVEL_ENSENANZA no son estables entre bases. El ARBOL de enunciados y evidencias no se duplica aqui: el CATALOGO a ofrecer esta en GET /planeador/referente-curricular (V278) y los que la unidad YA relaciono en GET /planeador/unidades/:ID/referente (V255, que desde su ultima version devuelve SOLO los relacionados, no el arbol completo). Para una actividad sin unidad, la configuracion equivalente la da fn_actividad_configuracion_contexto (V422). Gate VER sobre PLANEADOR + alcance por la unidad. P0002 si la unidad no existe o esta inactiva. V282.';

-- ===========================================================================
-- ENDPOINT — GET /planeador/unidades/:ID/configuracion-actividad?ES_EVALUATIVA=
-- ===========================================================================
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT academico_test.fn_unidad_configuracion_actividad(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    COALESCE(CAST(:QUERY.ES_EVALUATIVA AS VARCHAR), ''S'')
) AS configuracion;',
    'postgres', false, false,
    m.id_microservice, '/planeador/unidades/:ID/configuracion-actividad', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT", "QUERY.ES_EVALUATIVA": "VARCHAR"}'::jsonb,
    'V282 -- que pintar en el formulario de NUEVA ACTIVIDAD para la unidad escogida, ANTES de crearla. :ID = PK_TUNIDAD. Es el paso que faltaba del flujo: GET /planeador/actividades/:ID/configuracion devuelve lo mismo pero pide el PK de una actividad que en el formulario de creacion todavia no existe. Devuelve campos_disponibles con la MISMA forma y los mismos textos de motivo que la version por actividad, para reutilizar el codigo de render: criterio {visible, requerido, motivo} (visible=false solo en Preescolar), evaluacion {visible, requerido, motivo, tipoEvaluacion, instrumentosPermitidos:[{pk,valor,nombre}]} (segun el referente de la unidad y su TIPO_EVALUACION) y ponderacion {visible, requerido, modo, campo?, autocalculado?, motivo} (segun el metodo de calculo de la unidad: Ponderar -> PORCENTAJE sobre PONDERACION; Sumatoria -> PUNTAJE sobre NOTA_MAXIMA y autocalculado; Promediar o sin metodo -> no visible). ?ES_EVALUATIVA=S|N (default S) es lo unico que no sale de la unidad: lo que el usuario acaba de marcar en el formulario; con N la seccion de evaluacion y la ponderacion se apagan. El ARBOL de enunciados y evidencias NO viene aqui para no duplicarlo: el CATALOGO a ofrecer se pide a GET /planeador/referente-curricular?grado=&asignatura= (V278) y los que la unidad YA relaciono a GET /planeador/unidades/:ID/referente (que desde su ultima version devuelve SOLO los relacionados). Si la actividad aun no tiene unidad, usar GET /planeador/actividades/configuracion?grupo=&asignatura= (V422), que ademas trae los limites de la seccion Programacion. Gate VER sobre PLANEADOR + alcance por la unidad; 404 (P0002) si la unidad no existe o esta inactiva.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR', 'CEVAL-DOCENTE')
 WHERE m.serviceid = 'eval-col'
   AND q.path_template = '/planeador/unidades/:ID/configuracion-actividad'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

-- El INSERT de arriba es ON CONFLICT DO NOTHING: en las bases donde la fila ya
-- existe no habria actualizado el detail. Se reconcilia aparte (V253/V279).
UPDATE public.query q
   SET detail = 'V282 -- que pintar en el formulario de NUEVA ACTIVIDAD para la unidad escogida, ANTES de crearla. :ID = PK_TUNIDAD. Es el paso que faltaba del flujo: GET /planeador/actividades/:ID/configuracion devuelve lo mismo pero pide el PK de una actividad que en el formulario de creacion todavia no existe. Devuelve campos_disponibles con la MISMA forma y los mismos textos de motivo que la version por actividad, para reutilizar el codigo de render: criterio {visible, requerido, motivo} (visible=false solo en Preescolar), evaluacion {visible, requerido, motivo, tipoEvaluacion, instrumentosPermitidos:[{pk,valor,nombre}]} (segun el referente de la unidad y su TIPO_EVALUACION) y ponderacion {visible, requerido, modo, campo?, autocalculado?, motivo} (segun el metodo de calculo de la unidad: Ponderar -> PORCENTAJE sobre PONDERACION; Sumatoria -> PUNTAJE sobre NOTA_MAXIMA y autocalculado; Promediar o sin metodo -> no visible). ?ES_EVALUATIVA=S|N (default S) es lo unico que no sale de la unidad: lo que el usuario acaba de marcar en el formulario; con N la seccion de evaluacion y la ponderacion se apagan. El ARBOL de enunciados y evidencias NO viene aqui para no duplicarlo: el CATALOGO a ofrecer se pide a GET /planeador/referente-curricular?grado=&asignatura= (V278) y los que la unidad YA relaciono a GET /planeador/unidades/:ID/referente (que desde su ultima version devuelve SOLO los relacionados). Si la actividad aun no tiene unidad, usar GET /planeador/actividades/configuracion?grupo=&asignatura= (V422), que ademas trae los limites de la seccion Programacion. Gate VER sobre PLANEADOR + alcance por la unidad; 404 (P0002) si la unidad no existe o esta inactiva.'
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/unidades/:ID/configuracion-actividad'
   AND q.http_method     = 'GET'
   AND q.detail IS DISTINCT FROM 'V282 -- que pintar en el formulario de NUEVA ACTIVIDAD para la unidad escogida, ANTES de crearla. :ID = PK_TUNIDAD. Es el paso que faltaba del flujo: GET /planeador/actividades/:ID/configuracion devuelve lo mismo pero pide el PK de una actividad que en el formulario de creacion todavia no existe. Devuelve campos_disponibles con la MISMA forma y los mismos textos de motivo que la version por actividad, para reutilizar el codigo de render: criterio {visible, requerido, motivo} (visible=false solo en Preescolar), evaluacion {visible, requerido, motivo, tipoEvaluacion, instrumentosPermitidos:[{pk,valor,nombre}]} (segun el referente de la unidad y su TIPO_EVALUACION) y ponderacion {visible, requerido, modo, campo?, autocalculado?, motivo} (segun el metodo de calculo de la unidad: Ponderar -> PORCENTAJE sobre PONDERACION; Sumatoria -> PUNTAJE sobre NOTA_MAXIMA y autocalculado; Promediar o sin metodo -> no visible). ?ES_EVALUATIVA=S|N (default S) es lo unico que no sale de la unidad: lo que el usuario acaba de marcar en el formulario; con N la seccion de evaluacion y la ponderacion se apagan. El ARBOL de enunciados y evidencias NO viene aqui para no duplicarlo: el CATALOGO a ofrecer se pide a GET /planeador/referente-curricular?grado=&asignatura= (V278) y los que la unidad YA relaciono a GET /planeador/unidades/:ID/referente (que desde su ultima version devuelve SOLO los relacionados). Si la actividad aun no tiene unidad, usar GET /planeador/actividades/configuracion?grupo=&asignatura= (V422), que ademas trae los limites de la seccion Programacion. Gate VER sobre PLANEADOR + alcance por la unidad; 404 (P0002) si la unidad no existe o esta inactiva.';
