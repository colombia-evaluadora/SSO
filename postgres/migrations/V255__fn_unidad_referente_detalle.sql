-- ===========================================================================
-- V255 — Planeador: el referente curricular de UNA unidad y los enunciados
-- que ESA unidad relaciono (TUNIDAD_ENUNCIADO), con sus evidencias.
--
-- Es lectura de lo relacionado, NO un catalogo: para OFRECER enunciados que
-- marcar se usa GET /planeador/referente-curricular (V278), que devuelve el
-- arbol completo del referente sin unidad.
--
-- Las evidencias salen todas las hijas del enunciado relacionado: no existe
-- relacion "evidencia marcada por la unidad" -- TACTIVIDAD_EVIDENCIA es por
-- ACTIVIDAD, no por unidad.
--
-- No delega en fn_refenunc_listar (V213): esa gatea sobre el menu
-- REFERENTES_CURRICULARES, que hoy solo tiene el super admin, y el docente
-- recibiria 42501 sobre su propia unidad.
--
-- Depende de: V214.1 (TUNIDAD_ENUNCIADO, jerarquia de TREFERENTE_ENUNCIADO),
-- V212 (TREFERENTE_CURRICULAR), V216 (menu PLANEADOR).
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
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', NULL, NULL, p_pk_tunidad
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
           -- Solo los enunciados que ESTA unidad relaciono (INNER JOIN), con
           -- el PK de la RELACION, que es lo que pide el PATCH de quitar.
           -- relacionadoConUnidad queda fijo en true: se conserva la clave
           -- para no romper el contrato del front.
           COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                          'pk',                   en.PK_REFERENTE_ENUNCIADO,
                          'texto',                en.TEXTO,
                          'relacionadoConUnidad', TRUE,
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
                 FROM academico_test.TUNIDAD_ENUNCIADO ue
                 JOIN academico_test.TREFERENTE_ENUNCIADO en
                        ON en.PK_REFERENTE_ENUNCIADO = ue.FK_REFERENTE_ENUNCIADO
                WHERE ue.FK_TUNIDAD = u.PK_TUNIDAD
                  AND ue.ACTIVE = TRUE
                  AND en.FK_REFERENTE_CURRICULAR = rc.PK_REFERENTE_CURRICULAR
                  AND en.FK_PADRE IS NULL          -- nivel 1
                  AND en.ACTIVE = TRUE
           ), '[]'::jsonb)
      FROM academico_test.TUNIDAD u
      LEFT JOIN academico_test.TGRADO g            ON g.PK_TGRADO = u.FK_TGRADO
      LEFT JOIN academico_test.TNIVEL_ENSENANZA ne ON ne.PK_NIVEL_ENSENANZA = g.FK_TNIVEL_ENSENANZA
      -- ACTIVE (borrado logico) Y ESTADO (estado de negocio que edita el
      -- usuario): un referente marcado Inactivo no debe pintar la unidad.
      LEFT JOIN academico_test.TREFERENTE_CURRICULAR rc
             ON rc.PK_REFERENTE_CURRICULAR = u.FK_REFERENTE_CURRICULAR
            AND rc.ACTIVE = TRUE
            AND rc.ESTADO = 'A'
      LEFT JOIN academico_test.TLISTA_VALOR enf ON enf.PK_LISTA_VALOR = rc.FK_TLV_ENFOQUE_PEDAGOGICO
      LEFT JOIN academico_test.TLISTA_VALOR tev ON tev.PK_LISTA_VALOR = rc.FK_TLV_TIPO_EVALUACION
     WHERE u.PK_TUNIDAD = p_pk_tunidad;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_referente_detalle(BIGINT, BIGINT)
    IS 'Referente curricular de UNA unidad y SOLO los enunciados (nivel 1) que esa unidad relaciono en TUNIDAD_ENUNCIADO, con las evidencias (nivel 2) de esos enunciados. NO es un catalogo: no devuelve los enunciados no relacionados, asi que NO sirve para OFRECER casillas que marcar -- para eso esta GET /planeador/referente-curricular?grado=&asignatura= (fn_refcurr_por_grado_asignatura, V278), que da el arbol completo del referente sin unidad; esta funcion es la vista de lectura de lo ya relacionado. Devuelve el recorrido unidad -> grado -> nivel de ensenanza -> referente, mas: nivel_1_etiqueta / nivel_2_etiqueta (como llama ESE referente a sus niveles -- "Enunciado"/"Evidencia" o "Proposito"/"Evidencia" -- la UI debe rotular con esto, no con literales), enfoque y es_evaluativo + tipo_evaluacion (las dos reglas que deciden que secciones e instrumentos se habilitan en la actividad, V214.2), y por cada enunciado relacionado: relacionadoConUnidad (siempre true; la clave se conserva para no romper el contrato del front) y pkTunidadEnunciado (el PK de la RELACION, que es lo que pide el PATCH de quitar, no el del enunciado) con sus evidencias anidadas. Las evidencias son todas las hijas activas del enunciado: no existe relacion "evidencia marcada por la unidad" -- TACTIVIDAD_EVIDENCIA es por ACTIVIDAD. NO delega en fn_refenunc_listar/fn_refenunc_evidencias_listar (V213) a proposito: esas gatean sobre el menu REFERENTES_CURRICULARES, que hoy solo tiene el super admin, y un docente recibiria 42501 sobre su propia unidad. Gate VER sobre PLANEADOR. P0002 si la unidad no existe. Si la unidad no tiene referente activo o no relaciono ninguno, enunciados viene []. V255.';

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
    'V255 -- los enunciados del referente curricular que ESTA unidad relaciono, con sus evidencias. :ID = PK_TUNIDAD. Es LECTURA de lo relacionado, NO un catalogo: solo vienen los enunciados presentes en TUNIDAD_ENUNCIADO. Para OFRECER enunciados que marcar en el formulario usa GET /planeador/referente-curricular?grado=&asignatura= (V278), que devuelve el arbol completo del referente. El referente NO se elige a mano: se deriva del GRADO de la unidad -> nivel de ensenanza -> referente de ese nivel, y este endpoint hace ese recorrido en una sola llamada. Devuelve: el contexto (unidad, grado, nivel_ensenanza), el referente (nombre, descripcion), enfoque_valor + es_evaluativo y tipo_evaluacion_valor -- las dos reglas que deciden que secciones e instrumentos se habilitan en la actividad (ver GET /planeador/actividades/:ID/configuracion) --, nivel_1_etiqueta y nivel_2_etiqueta (como llama ESE referente a sus niveles: "Enunciado"/"Evidencia" en primaria, "Proposito"/"Evidencia" en preescolar -- rotula con esto, no con literales), y enunciados: [{pk, texto, relacionadoConUnidad, pkTunidadEnunciado, evidencias:[{pk, texto}]}]. relacionadoConUnidad viene siempre true (la clave se conserva para no romper el contrato) y pkTunidadEnunciado es el PK que pide PATCH /planeador/unidades/enunciados/:ID para quitar la relacion (es el de la RELACION, no el del enunciado). Las evidencias son todas las hijas activas del enunciado: no hay relacion evidencia<->unidad, TACTIVIDAD_EVIDENCIA es por ACTIVIDAD. Si la unidad no tiene referente activo o no relaciono ningun enunciado, enunciados viene []. Gate VER sobre PLANEADOR; 404 (P0002) si la unidad no existe.'
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

-- La fila ya existe en los entornos donde V255 corrio: el INSERT de arriba es
-- ON CONFLICT DO NOTHING y no la actualiza (patron de V253/V279).
UPDATE public.query q
   SET detail = 'V255 -- los enunciados del referente curricular que ESTA unidad relaciono, con sus evidencias. :ID = PK_TUNIDAD. Es LECTURA de lo relacionado, NO un catalogo: solo vienen los enunciados presentes en TUNIDAD_ENUNCIADO. Para OFRECER enunciados que marcar en el formulario usa GET /planeador/referente-curricular?grado=&asignatura= (V278), que devuelve el arbol completo del referente. El referente NO se elige a mano: se deriva del GRADO de la unidad -> nivel de ensenanza -> referente de ese nivel, y este endpoint hace ese recorrido en una sola llamada. Devuelve: el contexto (unidad, grado, nivel_ensenanza), el referente (nombre, descripcion), enfoque_valor + es_evaluativo y tipo_evaluacion_valor -- las dos reglas que deciden que secciones e instrumentos se habilitan en la actividad (ver GET /planeador/actividades/:ID/configuracion) --, nivel_1_etiqueta y nivel_2_etiqueta (como llama ESE referente a sus niveles: "Enunciado"/"Evidencia" en primaria, "Proposito"/"Evidencia" en preescolar -- rotula con esto, no con literales), y enunciados: [{pk, texto, relacionadoConUnidad, pkTunidadEnunciado, evidencias:[{pk, texto}]}]. relacionadoConUnidad viene siempre true (la clave se conserva para no romper el contrato) y pkTunidadEnunciado es el PK que pide PATCH /planeador/unidades/enunciados/:ID para quitar la relacion (es el de la RELACION, no el del enunciado). Las evidencias son todas las hijas activas del enunciado: no hay relacion evidencia<->unidad, TACTIVIDAD_EVIDENCIA es por ACTIVIDAD. Si la unidad no tiene referente activo o no relaciono ningun enunciado, enunciados viene []. Gate VER sobre PLANEADOR; 404 (P0002) si la unidad no existe.'
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/unidades/:ID/referente'
   AND q.http_method     = 'GET';
