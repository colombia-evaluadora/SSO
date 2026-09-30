-- V422 - Estudiantes candidatos de un grupo (fn_planeador_estudiantes_candidatos_listar
-- y GET /planeador/estudiantes) y el catálogo de referentes por grado y
-- asignatura (fn_refcurr_por_grado_asignatura). PUT :ID/estudiantes y
-- GET /planeador/actividades/configuracion los define hoy V496.4; la
-- programación vive en V460 y la configuración del formulario en V496.

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_planeador_estudiantes_candidatos_listar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tgrupo              BIGINT,
    p_fk_tasignatura         BIGINT DEFAULT NULL,
    p_pk_tactividad          BIGINT DEFAULT NULL,
    p_search                 VARCHAR DEFAULT NULL,
    p_limite                 INT DEFAULT NULL,
    p_offset                 INT DEFAULT 0
)
RETURNS TABLE (
    pk_tmatricula            BIGINT,
    fk_testudiante           BIGINT,
    estudiante               VARCHAR,
    fk_tgrupo                BIGINT,
    grupo                    VARCHAR,
    fk_tgrado                BIGINT,
    grado                    VARCHAR,
    asignado                 BOOLEAN,
    pk_tactividad_estudiante BIGINT,
    total_count              BIGINT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_search VARCHAR := NULLIF(TRIM(COALESCE(p_search, '')), '');
BEGIN
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', p_fk_tgrupo, NULL, NULL, p_pk_tactividad
    );

    IF p_fk_tgrupo IS NULL THEN
        RAISE EXCEPTION 'Se requiere el grupo para listar sus estudiantes'
            USING ERRCODE = '22023';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM academico_test.TGRUPO
                    WHERE PK_TGRUPO = p_fk_tgrupo AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'No se encontro el grupo solicitado' USING ERRCODE = 'P0002';
    END IF;

    IF p_fk_tasignatura IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM academico_test.TASIGNATURA
                        WHERE PK_TASIGNATURA = p_fk_tasignatura AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'No se encontro la asignatura solicitada' USING ERRCODE = 'P0002';
    END IF;

    -- La actividad, si se pasa, tiene que ser la del mismo grupo: si no, la
    -- marca "asignado" seria de otra actividad y el front la creeria buena.
    IF p_pk_tactividad IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM academico_test.TACTIVIDAD a
                        WHERE a.PK_TACTIVIDAD = p_pk_tactividad
                          AND (a.FK_TGRUPO IS NULL OR a.FK_TGRUPO = p_fk_tgrupo)) THEN
        RAISE EXCEPTION 'La actividad indicada no existe o no pertenece a ese grupo'
            USING ERRCODE = '22023';
    END IF;

    RETURN QUERY
    WITH base AS (
        SELECT m.PK_TMATRICULA,
               m.FK_TESTUDIANTE,
               NULLIF(TRIM(CONCAT_WS(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE,
                                          u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO)), '')::VARCHAR AS nombre,
               gr.PK_TGRUPO,
               gr.NOMBRE AS grupo_nombre,
               gr.FK_TGRADO,
               gd.NOMBRE AS grado_nombre,
               ae.PK_TACTIVIDAD_ESTUDIANTE
          FROM academico_test.TMATRICULA m
          JOIN academico_test.TGRUPO gr      ON gr.PK_TGRUPO = m.FK_TGRUPO
          LEFT JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
          JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
          JOIN academico_test.TUSUARIO u     ON u.PK_TUSUARIO = es.FK_TUSUARIO
          LEFT JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
                 ON ae.FK_TMATRICULA = m.PK_TMATRICULA
                AND ae.FK_TACTIVIDAD = p_pk_tactividad
                AND ae.ACTIVE = TRUE
         WHERE m.FK_TGRUPO = p_fk_tgrupo
           AND m.ACTIVE = TRUE
    )
    SELECT b.PK_TMATRICULA,
           b.FK_TESTUDIANTE,
           b.nombre,
           b.PK_TGRUPO,
           b.grupo_nombre,
           b.FK_TGRADO,
           b.grado_nombre,
           (b.PK_TACTIVIDAD_ESTUDIANTE IS NOT NULL),
           b.PK_TACTIVIDAD_ESTUDIANTE,
           COUNT(*) OVER()
      FROM base b
     WHERE v_search IS NULL OR b.nombre ILIKE '%' || v_search || '%'
     ORDER BY b.nombre, b.PK_TMATRICULA
     LIMIT p_limite OFFSET GREATEST(COALESCE(p_offset, 0), 0);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_planeador_estudiantes_candidatos_listar(BIGINT, BIGINT, BIGINT, BIGINT, VARCHAR, INT, INT)
    IS 'Los estudiantes matriculados ACTIVOS de un grupo, para escoger a quien se le asigna una actividad del Planeador. La ASIGNATURA no recorta la lista -- en el modelo todos los matriculados en el grupo cursan la asignatura --: se valida su existencia para que un contexto incoherente falle claro, no para filtrar. Con p_pk_tactividad cada fila trae asignado (BOOLEAN) y pk_tactividad_estudiante, que es el PK que piden las adaptaciones (TACTIVIDAD_ADAPTACION_ESTUDIANTE cuelga de TACTIVIDAD_ESTUDIANTE, no de la matricula) y la calificacion por estudiante; sin actividad, asignado viene FALSE en todas. La actividad debe ser del mismo grupo o se rechaza con 22023: si no, la marca seria de otra actividad y el front la creeria buena. p_limite NULL = sin paginar. total_count via COUNT(*) OVER() sobre el filtro de busqueda. Gate VER sobre PLANEADOR + alcance territorial por el grupo (V277). V422.';

CREATE OR REPLACE FUNCTION academico_test.fn_refcurr_por_grado_asignatura(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tgrado              BIGINT,
    p_fk_tasignatura         BIGINT DEFAULT NULL,
    p_anio                   INT    DEFAULT NULL
)
RETURNS TABLE (
    fk_tgrado                  BIGINT,
    grado                      VARCHAR,
    fk_tnivel_ensenanza        BIGINT,
    nivel_ensenanza            VARCHAR,
    fk_tasignatura             BIGINT,
    asignatura                 VARCHAR,
    fk_tarea_asignatura        BIGINT,
    area_asignatura            VARCHAR,
    pk_referente_curricular    BIGINT,
    referente_nombre           VARCHAR,
    referente_descripcion      VARCHAR,
    enfoque_valor              VARCHAR,
    enfoque_nombre             VARCHAR,
    es_evaluativo              BOOLEAN,
    tipo_evaluacion_valor      VARCHAR,
    tipo_evaluacion_nombre     VARCHAR,
    nivel_1_etiqueta           VARCHAR,
    nivel_2_etiqueta           VARCHAR,
    instrumento                VARCHAR,
    instrumento_info_adicional VARCHAR,
    normatividad               VARCHAR,
    anio_vigencia_desde        INTEGER,
    anio_vigencia_hasta        INTEGER,
    aplica_a_area              BOOLEAN,
    especificidad              INT,
    niveles                    JSONB,
    areas                      JSONB,
    enunciados                 JSONB,
    total_count                BIGINT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_fk_tnivel_ensenanza BIGINT;
    v_fk_tarea_asignatura BIGINT;
    v_anio                INT := COALESCE(p_anio, EXTRACT(YEAR FROM CURRENT_DATE)::INT);
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    -- Alcance territorial por el grado consultado (V277). Se pasa el grado
    -- como ancla: sin objetivo el gate no acota nada (ver la cabecera de
    -- V277), y este endpoint seria un sondeo libre del universo de grados.
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', NULL, p_fk_tgrado
    );

    SELECT g.FK_TNIVEL_ENSENANZA
      INTO v_fk_tnivel_ensenanza
      FROM academico_test.TGRADO g
     WHERE g.PK_TGRADO = p_fk_tgrado;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el grado solicitado' USING ERRCODE = 'P0002';
    END IF;

    -- El area de la asignatura contra el catalogo nacional. Se valida la
    -- existencia de la asignatura solo si viene informada: mandarla es
    -- opcional, pero mandar una que no existe es un error del cliente, no
    -- "sin filtro" (que devolveria de mas, callado).
    IF p_fk_tasignatura IS NOT NULL THEN
        SELECT COALESCE(asig.FK_TAREA_ASIGNATURA, ta.FK_TAREA_ASIGNATURA)
          INTO v_fk_tarea_asignatura
          FROM academico_test.TASIGNATURA asig
          LEFT JOIN academico_test.TAREA ta ON ta.PK_TAREA = asig.FK_TAREA
         WHERE asig.PK_TASIGNATURA = p_fk_tasignatura;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'No se encontro la asignatura solicitada' USING ERRCODE = 'P0002';
        END IF;
    END IF;

    RETURN QUERY
    WITH candidatos AS (
        SELECT rc.PK_REFERENTE_CURRICULAR AS pk,
               ar.tiene_areas             AS acotado_por_area,
               -- Prioridad (misma regla que fn_unidad_referente_aplicable):
               -- 0 lista el area pedida, 1 sin areas (aplica a todas), 2 el resto.
               CASE WHEN v_fk_tarea_asignatura IS NOT NULL AND ar.lista_el_area THEN 0
                    WHEN NOT ar.tiene_areas THEN 1
                    ELSE 2 END             AS prioridad
          FROM academico_test.TREFERENTE_CURRICULAR rc
          JOIN academico_test.TREFERENTE_CURRICULAR_NIVEL rcn
                ON rcn.FK_REFERENTE_CURRICULAR = rc.PK_REFERENTE_CURRICULAR
               AND rcn.FK_TNIVEL_ENSENANZA = v_fk_tnivel_ensenanza
               AND rcn.ACTIVE = TRUE
          CROSS JOIN LATERAL (
              SELECT EXISTS (SELECT 1 FROM academico_test.TREFERENTE_CURRICULAR_AREA a
                              WHERE a.FK_REFERENTE_CURRICULAR = rc.PK_REFERENTE_CURRICULAR
                                AND a.ACTIVE = TRUE) AS tiene_areas,
                     EXISTS (SELECT 1 FROM academico_test.TREFERENTE_CURRICULAR_AREA a
                              WHERE a.FK_REFERENTE_CURRICULAR = rc.PK_REFERENTE_CURRICULAR
                                AND a.FK_TAREA_ASIGNATURA = v_fk_tarea_asignatura
                                AND a.ACTIVE = TRUE) AS lista_el_area
          ) ar
         WHERE rc.ACTIVE = TRUE            -- borrado logico
           AND rc.ESTADO = 'A'             -- estado de negocio
           AND rc.ANIO_VIGENCIA_DESDE <= v_anio
           AND (rc.ANIO_VIGENCIA_HASTA IS NULL OR rc.ANIO_VIGENCIA_HASTA >= v_anio)
    )
    SELECT p_fk_tgrado,
           g.NOMBRE,
           g.FK_TNIVEL_ENSENANZA,
           ne.NOMBRE,
           p_fk_tasignatura,
           asig.NOMBRE,
           v_fk_tarea_asignatura,
           taa.NOMBRE,
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
           rc.INSTRUMENTO,
           rc.INSTRUMENTO_INFO_ADICIONAL,
           rc.NORMATIVIDAD,
           rc.ANIO_VIGENCIA_DESDE,
           rc.ANIO_VIGENCIA_HASTA,
           c.acotado_por_area,
           c.prioridad,
           -- Todos los niveles que cubre el referente, no solo el consultado:
           -- el front los muestra en el detalle ("aplica a Primaria y Basica").
           COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                          'pk',     ne2.PK_NIVEL_ENSENANZA,
                          'nombre', ne2.NOMBRE)
                          ORDER BY ne2.NOMBRE)
                 FROM academico_test.TREFERENTE_CURRICULAR_NIVEL rcn2
                 JOIN academico_test.TNIVEL_ENSENANZA ne2
                       ON ne2.PK_NIVEL_ENSENANZA = rcn2.FK_TNIVEL_ENSENANZA
                WHERE rcn2.FK_REFERENTE_CURRICULAR = rc.PK_REFERENTE_CURRICULAR
                  AND rcn2.ACTIVE = TRUE
           ), '[]'::jsonb),
           -- Areas a las que esta acotado. [] significa "todas" (leer
           -- aplica_a_area, que es lo que permite distinguirlo).
           COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                          'pk',     taa2.PK_TAREA_ASIGNATURA,
                          'nombre', taa2.NOMBRE)
                          ORDER BY taa2.NOMBRE)
                 FROM academico_test.TREFERENTE_CURRICULAR_AREA rca4
                 JOIN academico_test.TAREA_ASIGNATURA taa2
                       ON taa2.PK_TAREA_ASIGNATURA = rca4.FK_TAREA_ASIGNATURA
                WHERE rca4.FK_REFERENTE_CURRICULAR = rc.PK_REFERENTE_CURRICULAR
                  AND rca4.ACTIVE = TRUE
           ), '[]'::jsonb),
           -- Arbol nivel 1 (enunciado) -> nivel 2 (evidencia), la jerarquia
           -- por FK_PADRE de V214.1. Acotado al area de la asignatura pedida:
           -- FK_REFERENTE_CURRICULAR_AREA NULL = el enunciado no esta amarrado
           -- a ninguna area y aplica siempre (V212). La evidencia hereda el
           -- area de su padre (CHK_TREFENUNC_AREA_SOLO_NIVEL1), por eso solo
           -- se filtra el nivel 1.
           COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                          'pk',    en.PK_REFERENTE_ENUNCIADO,
                          'texto', en.TEXTO,
                          'fkReferenteCurricularArea', en.FK_REFERENTE_CURRICULAR_AREA,
                          'area',  taa5.NOMBRE,
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
                 LEFT JOIN academico_test.TREFERENTE_CURRICULAR_AREA rca5
                        ON rca5.PK_REFERENTE_CURRICULAR_AREA = en.FK_REFERENTE_CURRICULAR_AREA
                       AND rca5.ACTIVE = TRUE
                 LEFT JOIN academico_test.TAREA_ASIGNATURA taa5
                        ON taa5.PK_TAREA_ASIGNATURA = rca5.FK_TAREA_ASIGNATURA
                WHERE en.FK_REFERENTE_CURRICULAR = rc.PK_REFERENTE_CURRICULAR
                  AND en.FK_PADRE IS NULL
                  AND en.ACTIVE = TRUE
                  AND (v_fk_tarea_asignatura IS NULL
                       OR en.FK_REFERENTE_CURRICULAR_AREA IS NULL
                       OR rca5.FK_TAREA_ASIGNATURA = v_fk_tarea_asignatura)
           ), '[]'::jsonb),
           COUNT(*) OVER()
      FROM candidatos c
      JOIN academico_test.TREFERENTE_CURRICULAR rc  ON rc.PK_REFERENTE_CURRICULAR = c.pk
      JOIN academico_test.TGRADO g                  ON g.PK_TGRADO = p_fk_tgrado
      LEFT JOIN academico_test.TNIVEL_ENSENANZA ne  ON ne.PK_NIVEL_ENSENANZA = g.FK_TNIVEL_ENSENANZA
      LEFT JOIN academico_test.TASIGNATURA asig     ON asig.PK_TASIGNATURA = p_fk_tasignatura
      LEFT JOIN academico_test.TAREA_ASIGNATURA taa ON taa.PK_TAREA_ASIGNATURA = v_fk_tarea_asignatura
      LEFT JOIN academico_test.TLISTA_VALOR enf     ON enf.PK_LISTA_VALOR = rc.FK_TLV_ENFOQUE_PEDAGOGICO
      LEFT JOIN academico_test.TLISTA_VALOR tev     ON tev.PK_LISTA_VALOR = rc.FK_TLV_TIPO_EVALUACION
     ORDER BY c.prioridad,
              rc.ANIO_VIGENCIA_DESDE DESC,
              rc.PK_REFERENTE_CURRICULAR;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_refcurr_por_grado_asignatura(BIGINT, BIGINT, BIGINT, INT)
    IS 'El/los referentes curriculares que aplican a un GRADO + ASIGNATURA, con el arbol completo, para pintar la unidad y la actividad ANTES de que exista la unidad. Recorrido: TGRADO -> FK_TNIVEL_ENSENANZA -> TREFERENTE_CURRICULAR_NIVEL (N:N) -> referente. Devuelve un CONJUNTO ordenado por PRIORIDAD, la MISMA regla con la que fn_unidad_referente_aplicable decide el referente de una unidad nueva: especificidad 0 = lista el area de la asignatura pedida, 1 = sin areas (aplica a todas, V212), 2 = acotado a otras areas; dentro de cada nivel, la vigencia mas reciente. Las areas son preferencia y NO exclusion: antes un referente acotado a otras areas quedaba fuera y el catalogo podia no listar el referente que la derivacion asignaba a la unidad. El area de la asignatura se resuelve con COALESCE(TASIGNATURA.FK_TAREA_ASIGNATURA, TAREA.FK_TAREA_ASIGNATURA). Sin asignatura no hay nivel 0 y el universal va primero. Exige ACTIVE = true Y ESTADO = A (independientes). Descarta los referentes fuera de la vigencia de p_anio. Los enunciados de nivel 1 vienen acotados al area pedida (FK_REFERENTE_CURRICULAR_AREA NULL = sale siempre; la evidencia hereda el area del padre). Gate VER sobre PLANEADOR + alcance territorial por el grado; un grado inexistente responde 403 y no 404, a proposito. P0002 para la asignatura informada que no existe.';

UPDATE public.query q
   SET detail = 'V278/V422 -- el referente curricular que le corresponde a un ?grado= (obligatorio) y ?asignatura= (opcional), con TODOS sus datos, para pintar la unidad y la actividad ANTES de crear la unidad (con unidad ya creada, usar GET /planeador/unidades/:ID/referente). El referente NO se elige a mano: se deriva del grado -> nivel de ensenanza -> referente(s) de ese nivel. Devuelve un ARREGLO ordenado por PRIORIDAD, la misma regla con la que fn_unidad_referente_aplicable decide el referente de una unidad nueva: especificidad 0 = lista el area de la ?asignatura=, 1 = sin areas (aplica a todas), 2 = acotado a otras areas; dentro de cada nivel la vigencia mas reciente. Las areas NO excluyen: un referente acotado a otras areas sigue saliendo, al final, para que el catalogo y la derivacion nunca discrepen (antes se excluia y el catalogo podia no listar el referente que la unidad recibia). Solo referentes ACTIVE con ESTADO = Activo (son independientes). ?anio= (default: anio en curso) descarta los fuera de vigencia. Por cada referente: nombre, descripcion, enfoque_valor + es_evaluativo, tipo_evaluacion, nivel_1_etiqueta y nivel_2_etiqueta (rotula con esto, no con literales), instrumento, normatividad, vigencia, niveles, areas ([] = todas), aplica_a_area, especificidad, y enunciados:[{pk, texto, fkReferenteCurricularArea, area, evidencias:[{pk, texto}]}] acotados al area pedida (un enunciado sin area sale siempre). total_count via COUNT(*) OVER(). Gate VER sobre PLANEADOR + alcance territorial por el grado; un grado inexistente responde 403 y no 404 (el gate corre antes que la existencia, a proposito). 404 (P0002) para la ?asignatura= que no existe.'
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/referente-curricular'
   AND q.http_method     = 'GET'
   AND q.detail IS DISTINCT FROM 'V278/V422 -- el referente curricular que le corresponde a un ?grado= (obligatorio) y ?asignatura= (opcional), con TODOS sus datos, para pintar la unidad y la actividad ANTES de crear la unidad (con unidad ya creada, usar GET /planeador/unidades/:ID/referente). El referente NO se elige a mano: se deriva del grado -> nivel de ensenanza -> referente(s) de ese nivel. Devuelve un ARREGLO ordenado por PRIORIDAD, la misma regla con la que fn_unidad_referente_aplicable decide el referente de una unidad nueva: especificidad 0 = lista el area de la ?asignatura=, 1 = sin areas (aplica a todas), 2 = acotado a otras areas; dentro de cada nivel la vigencia mas reciente. Las areas NO excluyen: un referente acotado a otras areas sigue saliendo, al final, para que el catalogo y la derivacion nunca discrepen (antes se excluia y el catalogo podia no listar el referente que la unidad recibia). Solo referentes ACTIVE con ESTADO = Activo (son independientes). ?anio= (default: anio en curso) descarta los fuera de vigencia. Por cada referente: nombre, descripcion, enfoque_valor + es_evaluativo, tipo_evaluacion, nivel_1_etiqueta y nivel_2_etiqueta (rotula con esto, no con literales), instrumento, normatividad, vigencia, niveles, areas ([] = todas), aplica_a_area, especificidad, y enunciados:[{pk, texto, fkReferenteCurricularArea, area, evidencias:[{pk, texto}]}] acotados al area pedida (un enunciado sin area sale siempre). total_count via COUNT(*) OVER(). Gate VER sobre PLANEADOR + alcance territorial por el grado; un grado inexistente responde 403 y no 404 (el gate corre antes que la existencia, a proposito). 404 (P0002) para la ?asignatura= que no existe.';

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    'eval-col-planeador-estudiantes-001',
    'SELECT * FROM academico_test.fn_planeador_estudiantes_candidatos_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.GRUPO AS BIGINT),
    CAST(:QUERY.ASIGNATURA AS BIGINT),
    CAST(:QUERY.ACTIVIDAD AS BIGINT),
    CAST(:QUERY.SEARCH AS VARCHAR),
    CAST(:QUERY.SIZE AS INT),
    COALESCE(CAST(:QUERY.OFFSET AS INT), 0)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/estudiantes', 'SELECT', 'GET',
    '{"QUERY.GRUPO": "BIGINT", "QUERY.ASIGNATURA": "BIGINT", "QUERY.ACTIVIDAD": "BIGINT", "QUERY.SEARCH": "VARCHAR", "QUERY.SIZE": "INT", "QUERY.OFFSET": "INT"}'::jsonb,
    'V422 -- los estudiantes matriculados activos de un ?grupo= (obligatorio), para escoger a quien se le asigna una actividad del Planeador. ?asignatura= NO recorta la lista: en el modelo todos los matriculados en el grupo cursan la asignatura, y solo se valida que exista para que un contexto incoherente falle claro. Con ?actividad= cada fila trae asignado (true/false) y pk_tactividad_estudiante, que es el PK que piden las adaptaciones (TACTIVIDAD_ADAPTACION_ESTUDIANTE cuelga de TACTIVIDAD_ESTUDIANTE, no de la matricula), la nota por estudiante y la observacion; sin ?actividad= asignado viene false en todas y sirve como catalogo de candidatos para POST /planeador/actividades (BODY.FK_TMATRICULAS). La actividad tiene que ser del mismo grupo o responde 22023. Devuelve pk_tmatricula, fk_testudiante, estudiante, grupo, grado, asignado, pk_tactividad_estudiante y total_count. ?search= filtra por nombre; ?size= NULL devuelve sin paginar. Gate VER sobre PLANEADOR + alcance territorial por el grupo; 404 (P0002) si el grupo o la asignatura no existen.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET query = EXCLUDED.query, param_types = EXCLUDED.param_types, detail = EXCLUDED.detail;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR', 'CEVAL-DOCENTE')
 WHERE m.serviceid = 'eval-col'
   AND q.path_template = '/planeador/estudiantes'
ON CONFLICT DO NOTHING;
