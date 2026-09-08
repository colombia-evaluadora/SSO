-- ===========================================================================
-- V255 — Planeador educativo: el referente curricular de una unidad, con sus
-- enunciados y evidencias, para pintar dinamicamente la unidad y la actividad
-- (CU-86e311xxp).
--
-- QUE FALTABA: el Planeador ya sabe RELACIONAR una unidad con enunciados
-- (POST /planeador/unidades/:ID/enunciados, V136/V245) y una actividad con
-- evidencias (POST /planeador/actividades/:ID/evidencias), pero no habia
-- forma de LEER el arbol contra el que se marcan esas casillas: que referente
-- le toca a la unidad, que enunciados tiene, que evidencias cuelgan de cada
-- uno, y cuales estan ya relacionados. El front tenia que adivinarlo.
--
-- El referente NO se elige a mano en la actividad: se deriva del GRADO de la
-- unidad -> TGRADO.FK_TNIVEL_ENSENANZA -> el referente de ese nivel de
-- ensenanza. Esta funcion hace ese recorrido y devuelve el arbol completo en
-- una sola llamada.
--
-- -------------------------------------------------------------------------
-- POR QUE NO SE DELEGA EN fn_refenunc_listar / fn_refenunc_evidencias_listar
--
-- Existen (V213, rama CU-86e311xqh, ya aplicadas en el servidor) y seria lo
-- natural para no duplicar la lectura. No se usan a proposito: gatean sobre
-- fn_assert_permiso_seccion(usuario, 'REFERENTES_CURRICULARES', 'VER'), y ese
-- menu -- segun la propia cabecera de V213 -- "en la practica hoy significa
-- solo SUPER_ADMIN porque este seed NO concede el menu a ningun otro rol".
-- Invocarlas desde aqui haria que un DOCENTE recibiera 42501 justo en la
-- pantalla donde tiene que marcar evidencias de SU unidad.
--
-- Tampoco se le concede al docente el menu REFERENTES_CURRICULARES: eso le
-- abriria el catalogo GLOBAL entero (incluido su CRUD), cuando lo que
-- necesita es leer UN referente concreto, el que ya cuelga de una unidad que
-- el puede ver.
--
-- Asi que la lectura se hace aqui, sobre las mismas tablas
-- (TREFERENTE_CURRICULAR / TREFERENTE_ENUNCIADO, con FK_PADRE separando
-- nivel 1 = enunciado y nivel 2 = evidencia -- ver V136), pero con el gate
-- del Planeador y ACOTADA a la unidad: el docente nunca ve mas referente que
-- el de la unidad que consulta. Es una lectura derivada, no una puerta al
-- catalogo.
--
-- -------------------------------------------------------------------------
-- LO QUE HACE UTIL LA RESPUESTA (no es solo volcar el arbol):
--
--   * nivel_1_etiqueta / nivel_2_etiqueta -- el referente decide COMO se
--     llaman sus niveles ("Enunciado"/"Evidencia" en Primaria,
--     "Proposito"/"Evidencia" en Preescolar). La UI debe rotular con esto,
--     no con literales.
--   * enfoque (EVALUATIVO / FORMATIVO) y tipo_evaluacion -- las dos reglas
--     que deciden que secciones se habilitan en la actividad (V137): sin
--     referente evaluativo no hay seccion de evaluacion, y el tipo filtra
--     que instrumentos aplican.
--   * relacionado_con_unidad + pk_tunidad_enunciado por enunciado -- para
--     pre-marcar las casillas Y para poder desmarcarlas: el PATCH de quitar
--     (V245) pide el PK de la RELACION, no el del enunciado.
--   * evidencias anidadas por enunciado -- la actividad solo puede marcar
--     evidencias de enunciados que la unidad ya relaciono (regla de V136),
--     asi que el front necesita el arbol, no dos listas sueltas.
--
-- Depende de: V136 (TUNIDAD_ENUNCIADO, jerarquia de TREFERENTE_ENUNCIADO),
-- V212 (TREFERENTE_CURRICULAR y su catalogo, rama CU-86e311xqh),
-- V216 (menu PLANEADOR + fn_assert_permiso_seccion).
-- ===========================================================================

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_referente_detalle(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tunidad             BIGINT
)
RETURNS TABLE (
    pk_tunidad               BIGINT,
    unidad_nombre            VARCHAR,
    fk_tgrado                BIGINT,
    grado                    VARCHAR,
    fk_tnivel_ensenanza      BIGINT,
    nivel_ensenanza          VARCHAR,
    pk_referente_curricular  BIGINT,
    referente_nombre         VARCHAR,
    referente_descripcion    VARCHAR,
    enfoque_valor            VARCHAR,
    enfoque_nombre           VARCHAR,
    es_evaluativo            BOOLEAN,
    tipo_evaluacion_valor    VARCHAR,
    tipo_evaluacion_nombre   VARCHAR,
    nivel_1_etiqueta         VARCHAR,
    nivel_2_etiqueta         VARCHAR,
    enunciados               JSONB
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    IF NOT EXISTS (SELECT 1 FROM academico_test.TUNIDAD u
                    WHERE u.PK_TUNIDAD = p_pk_tunidad) THEN
        RAISE EXCEPTION 'No se encontro la unidad solicitada' USING ERRCODE = 'P0002';
    END IF;

    RETURN QUERY
    SELECT u.PK_TUNIDAD,
           u.NOMBRE,
           u.FK_TGRADO,
           g.NOMBRE,
           g.FK_TNIVEL_ENSENANZA,
           ne.NOMBRE,
           rc.PK_REFERENTE_CURRICULAR,
           rc.NOMBRE,
           rc.DESCRIPCION,
           enf.VALOR,
           enf.NOMBRE,
           (enf.VALOR = 'EVALUATIVO'),
           tev.VALOR,
           tev.NOMBRE,
           rc.NIVEL_1_ETIQUETA,
           rc.NIVEL_2_ETIQUETA,
           -- Arbol nivel 1 -> nivel 2. Se marca cuales enunciados ya estan
           -- relacionados con ESTA unidad y con que PK de relacion, que es lo
           -- que pide el PATCH de quitar (no el PK del enunciado).
           COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                          'pk',                   en.PK_REFERENTE_ENUNCIADO,
                          'texto',                en.TEXTO,
                          'relacionadoConUnidad', (ue.PK_TUNIDAD_ENUNCIADO IS NOT NULL),
                          'pkTunidadEnunciado',   ue.PK_TUNIDAD_ENUNCIADO,
                          'evidencias', COALESCE((
                              SELECT jsonb_agg(jsonb_build_object(
                                         'pk',    ev.PK_REFERENTE_ENUNCIADO,
                                         'texto', ev.TEXTO)
                                         ORDER BY ev.PK_REFERENTE_ENUNCIADO)
                                FROM academico_test.TREFERENTE_ENUNCIADO ev
                               WHERE ev.FK_PADRE = en.PK_REFERENTE_ENUNCIADO
                                 AND ev.ACTIVE = TRUE
                          ), '[]'::jsonb))
                          ORDER BY en.PK_REFERENTE_ENUNCIADO)
                 FROM academico_test.TREFERENTE_ENUNCIADO en
                 LEFT JOIN academico_test.TUNIDAD_ENUNCIADO ue
                        ON ue.FK_REFERENTE_ENUNCIADO = en.PK_REFERENTE_ENUNCIADO
                       AND ue.FK_TUNIDAD = u.PK_TUNIDAD
                       AND ue.ACTIVE = TRUE
                WHERE en.FK_REFERENTE_CURRICULAR = rc.PK_REFERENTE_CURRICULAR
                  AND en.FK_PADRE IS NULL          -- nivel 1
                  AND en.ACTIVE = TRUE
           ), '[]'::jsonb)
      FROM academico_test.TUNIDAD u
      LEFT JOIN academico_test.TGRADO g            ON g.PK_TGRADO = u.FK_TGRADO
      LEFT JOIN academico_test.TNIVEL_ENSENANZA ne ON ne.PK_NIVEL_ENSENANZA = g.FK_TNIVEL_ENSENANZA
      LEFT JOIN academico_test.TREFERENTE_CURRICULAR rc
             ON rc.PK_REFERENTE_CURRICULAR = u.FK_REFERENTE_CURRICULAR
            AND rc.ACTIVE = TRUE
      LEFT JOIN academico_test.TLISTA_VALOR enf ON enf.PK_LISTA_VALOR = rc.FK_TLV_ENFOQUE_PEDAGOGICO
      LEFT JOIN academico_test.TLISTA_VALOR tev ON tev.PK_LISTA_VALOR = rc.FK_TLV_TIPO_EVALUACION
     WHERE u.PK_TUNIDAD = p_pk_tunidad;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_referente_detalle(BIGINT, BIGINT)
    IS 'Referente curricular de UNA unidad con su arbol de enunciados (nivel 1) y evidencias (nivel 2), para pintar dinamicamente la unidad y la actividad. Devuelve el recorrido completo unidad -> grado -> nivel de ensenanza -> referente, mas: nivel_1_etiqueta / nivel_2_etiqueta (como llama ESE referente a sus niveles -- "Enunciado"/"Evidencia" o "Proposito"/"Evidencia" -- la UI debe rotular con esto, no con literales), enfoque y es_evaluativo + tipo_evaluacion (las dos reglas que deciden que secciones e instrumentos se habilitan en la actividad, V137), y por cada enunciado: relacionadoConUnidad y pkTunidadEnunciado (el PK de la RELACION, que es lo que pide el PATCH de quitar, no el del enunciado) con sus evidencias anidadas. NO delega en fn_refenunc_listar/fn_refenunc_evidencias_listar (V213) a proposito: esas gatean sobre el menu REFERENTES_CURRICULARES, que hoy solo tiene el super admin, y un docente recibiria 42501 justo donde debe marcar evidencias de su propia unidad; aqui la lectura va con el gate del Planeador y ACOTADA a la unidad consultada -- lectura derivada, no una puerta al catalogo global. Gate VER sobre PLANEADOR. P0002 si la unidad no existe. Si la unidad no tiene referente, las columnas del referente vienen NULL y enunciados como []. V255.';

-- ===========================================================================
-- ENDPOINT — GET /planeador/unidades/:ID/referente
-- ===========================================================================
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_unidad_referente_detalle(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/unidades/:ID/referente', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    'V255 -- el referente curricular que le toca a una unidad, con su arbol de enunciados y evidencias. :ID = PK_TUNIDAD. Es la fuente para pintar dinamicamente la unidad y la actividad: el referente NO se elige a mano, se deriva del GRADO de la unidad -> nivel de ensenanza -> referente de ese nivel, y este endpoint hace ese recorrido en una sola llamada. Devuelve: el contexto (unidad, grado, nivel_ensenanza), el referente (nombre, descripcion), enfoque_valor + es_evaluativo y tipo_evaluacion_valor -- las dos reglas que deciden que secciones e instrumentos se habilitan en la actividad (ver GET /planeador/actividades/:ID/configuracion) --, nivel_1_etiqueta y nivel_2_etiqueta (como llama ESE referente a sus niveles: "Enunciado"/"Evidencia" en primaria, "Proposito"/"Evidencia" en preescolar -- rotula con esto, no con literales), y enunciados: [{pk, texto, relacionadoConUnidad, pkTunidadEnunciado, evidencias:[{pk, texto}]}]. relacionadoConUnidad pre-marca las casillas ya vinculadas y pkTunidadEnunciado es el PK que pide PATCH /planeador/unidades/enunciados/:ID para quitarlas (es el de la RELACION, no el del enunciado). Las evidencias vienen anidadas porque una actividad solo puede marcar evidencias de enunciados que la unidad ya relaciono. Si la unidad no tiene referente, esas columnas vienen NULL y enunciados en []. Gate VER sobre PLANEADOR; 404 (P0002) si la unidad no existe.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR', 'CEVAL-DOCENTE')
 WHERE m.serviceid = 'eval-col'
   AND q.path_template = '/planeador/unidades/:ID/referente'
ON CONFLICT DO NOTHING;
