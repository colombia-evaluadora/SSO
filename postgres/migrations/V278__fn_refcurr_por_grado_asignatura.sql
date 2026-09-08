-- ===========================================================================
-- V278 — Planeador educativo: el referente curricular que le corresponde a un
-- GRADO + ASIGNATURA, con su arbol completo (CU-86e311xxp).
--
-- QUE FALTABA: V255 ya resuelve el referente de una unidad YA CREADA
-- (GET /planeador/unidades/:ID/referente). Pero al ARMAR la unidad -- o al
-- pintar la actividad antes de tener unidad -- el front solo tiene en la mano
-- el grado y la asignatura que el docente acaba de escoger, y no habia forma
-- de preguntar "para esta combinacion, que referente aplica y que trae
-- dentro". Sin eso no se pueden rotular los niveles, ni decidir si hay
-- seccion de evaluacion, ni ofrecer los enunciados/evidencias a marcar.
--
-- EL RECORRIDO (el mismo que documenta V255, pero desde el grado en vez de
-- desde la unidad):
--
--     TGRADO -> FK_TNIVEL_ENSENANZA -> TREFERENTE_CURRICULAR_NIVEL -> referente
--
-- La relacion referente <-> nivel es N:N (TREFERENTE_CURRICULAR_NIVEL, V212 de
-- la rama CU-86e311xqh): un mismo referente puede cubrir varios niveles, y un
-- nivel puede tener varios referentes. Por eso esta funcion devuelve un
-- CONJUNTO ordenado por especificidad, no una fila unica -- forzar "uno solo"
-- seria inventar un criterio de negocio que el modelo no tiene.
--
-- -------------------------------------------------------------------------
-- COMO ENTRA LA ASIGNATURA (y por que es un filtro y no una llave)
--
-- El referente se acota a areas por TREFERENTE_CURRICULAR_AREA (N:N contra
-- TAREA_ASIGNATURA, el catalogo nacional). La semantica la fija V212:
-- "sin filas" NO significa "no aplica a ninguna area", significa "aplica a
-- TODAS" (a diferencia de la puente de niveles, donde el set nunca puede
-- quedar vacio). Asi que:
--
--   * referente sin filas de area  -> aplica siempre (universal)
--   * referente con filas de area  -> aplica solo si una de ellas es el area
--                                     de la asignatura pedida
--
-- Y el area de la asignatura contra el catalogo nacional se resuelve con
-- COALESCE(TASIGNATURA.FK_TAREA_ASIGNATURA, TAREA.FK_TAREA_ASIGNATURA): la
-- primera es NULLABLE en V22 y muchas asignaturas la traen vacia, en cuyo
-- caso el enganche real esta en su TAREA (donde FK_TAREA_ASIGNATURA es NOT
-- NULL). Sin ese COALESCE, filtrar por asignatura dejaria fuera referentes
-- correctos en la mayoria de las filas sembradas.
--
-- Si no se manda asignatura, no se filtra por area: se devuelven todos los
-- referentes del nivel. Es el caso "el docente todavia no escogio asignatura".
--
-- ORDEN DE SALIDA (= orden de preferencia para el front): primero los
-- referentes ACOTADOS al area de la asignatura pedida (mas especificos),
-- despues los universales, y dentro de cada grupo el de vigencia mas
-- reciente. aplica_a_area y especificidad van en la salida para que el front
-- pueda mostrar el criterio en vez de confiar a ciegas en el orden.
--
-- VIGENCIA: se descartan los referentes cuyo rango
-- [ANIO_VIGENCIA_DESDE, ANIO_VIGENCIA_HASTA] no cubre p_anio (por defecto el
-- anio en curso). ANIO_VIGENCIA_HASTA NULL = vigente indefinidamente.
--
-- -------------------------------------------------------------------------
-- GATE: el del Planeador, igual que V255 y por la misma razon -- NO se delega
-- en fn_refenunc_listar / fn_refcurr_listar (V213), que gatean sobre el menu
-- REFERENTES_CURRICULARES (hoy solo super admin) y le devolverian 42501 a un
-- docente justo en la pantalla donde arma su unidad. Aqui la lectura va con
-- el gate del Planeador y ACOTADA al grado consultado, cuyo alcance
-- territorial se verifica con fn_planeador_assert_alcance (V277): un docente
-- de nivel 3 no puede sondear grados de sedes que no le corresponden.
--
-- Depende de: V22 (TGRADO/TASIGNATURA/TAREA/TAREA_ASIGNATURA), V136
-- (jerarquia de TREFERENTE_ENUNCIADO), V212 (TREFERENTE_CURRICULAR y sus dos
-- puentes, rama CU-86e311xqh), V216 (menu PLANEADOR), V277 (alcance).
-- ===========================================================================

SET search_path TO academico_test, public;

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
               -- Esta el referente acotado a areas? Si no lo esta, es universal.
               EXISTS (SELECT 1
                         FROM academico_test.TREFERENTE_CURRICULAR_AREA rca
                        WHERE rca.FK_REFERENTE_CURRICULAR = rc.PK_REFERENTE_CURRICULAR
                          AND rca.ACTIVE = TRUE) AS acotado_por_area
          FROM academico_test.TREFERENTE_CURRICULAR rc
          JOIN academico_test.TREFERENTE_CURRICULAR_NIVEL rcn
                ON rcn.FK_REFERENTE_CURRICULAR = rc.PK_REFERENTE_CURRICULAR
               AND rcn.FK_TNIVEL_ENSENANZA = v_fk_tnivel_ensenanza
               AND rcn.ACTIVE = TRUE
         WHERE rc.ACTIVE = TRUE
           AND rc.ANIO_VIGENCIA_DESDE <= v_anio
           AND (rc.ANIO_VIGENCIA_HASTA IS NULL OR rc.ANIO_VIGENCIA_HASTA >= v_anio)
           -- Filtro por area: solo cuando se pidio asignatura. "Sin filas de
           -- area" = aplica a todas (V212), asi que el universal nunca se cae.
           AND (v_fk_tarea_asignatura IS NULL
                OR NOT EXISTS (SELECT 1
                                 FROM academico_test.TREFERENTE_CURRICULAR_AREA rca2
                                WHERE rca2.FK_REFERENTE_CURRICULAR = rc.PK_REFERENTE_CURRICULAR
                                  AND rca2.ACTIVE = TRUE)
                OR EXISTS (SELECT 1
                             FROM academico_test.TREFERENTE_CURRICULAR_AREA rca3
                            WHERE rca3.FK_REFERENTE_CURRICULAR = rc.PK_REFERENTE_CURRICULAR
                              AND rca3.FK_TAREA_ASIGNATURA = v_fk_tarea_asignatura
                              AND rca3.ACTIVE = TRUE))
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
           -- 0 = acotado al area pedida (mas especifico), 1 = universal.
           CASE WHEN c.acotado_por_area THEN 0 ELSE 1 END,
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
           -- por FK_PADRE de V136. Mismo shape que V255 MENOS
           -- relacionadoConUnidad/pkTunidadEnunciado: aqui todavia no hay
           -- unidad contra la que marcar, es el catalogo a ofrecer.
           COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                          'pk',    en.PK_REFERENTE_ENUNCIADO,
                          'texto', en.TEXTO,
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
                WHERE en.FK_REFERENTE_CURRICULAR = rc.PK_REFERENTE_CURRICULAR
                  AND en.FK_PADRE IS NULL
                  AND en.ACTIVE = TRUE
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
     ORDER BY CASE WHEN c.acotado_por_area THEN 0 ELSE 1 END,
              rc.ANIO_VIGENCIA_DESDE DESC,
              rc.PK_REFERENTE_CURRICULAR;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_refcurr_por_grado_asignatura(BIGINT, BIGINT, BIGINT, INT)
    IS 'El/los referentes curriculares que aplican a un GRADO + ASIGNATURA, con el arbol completo, para pintar la unidad y la actividad ANTES de que exista la unidad (V255 hace lo mismo pero partiendo de una unidad ya creada). Recorrido: TGRADO -> FK_TNIVEL_ENSENANZA -> TREFERENTE_CURRICULAR_NIVEL (N:N, V212) -> referente. Devuelve un CONJUNTO ordenado por especificidad, no una fila: la relacion es N:N y forzar "uno solo" seria inventar un criterio que el modelo no tiene. La asignatura es un FILTRO por area (TREFERENTE_CURRICULAR_AREA contra TAREA_ASIGNATURA) con la semantica de V212 -- un referente SIN filas de area aplica a TODAS, no a ninguna --, y el area de la asignatura se resuelve con COALESCE(TASIGNATURA.FK_TAREA_ASIGNATURA, TAREA.FK_TAREA_ASIGNATURA) porque la primera es nullable en V22 y viene vacia en la mayoria de las filas sembradas. Sin asignatura no se filtra por area. Se descartan los referentes cuya vigencia no cubre p_anio (default: anio en curso; ANIO_VIGENCIA_HASTA NULL = indefinida). Orden = preferencia: primero los acotados al area pedida, luego los universales, y dentro de cada grupo la vigencia mas reciente; aplica_a_area y especificidad van en la salida para que el front muestre el criterio en vez de confiar a ciegas en el orden. Trae enfoque + es_evaluativo y tipo_evaluacion (las dos reglas que deciden que secciones e instrumentos se habilitan, V137), nivel_1_etiqueta / nivel_2_etiqueta (como llama ESE referente a sus niveles -- rotula con esto, no con literales), instrumento / normatividad, niveles y areas del referente, y enunciados: [{pk, texto, evidencias:[{pk, texto}]}]. NO delega en fn_refcurr_listar/fn_refenunc_listar (V213) a proposito: gatean sobre el menu REFERENTES_CURRICULARES, hoy solo super admin. Gate VER sobre PLANEADOR + alcance territorial por el grado (V277). P0002 si el grado o la asignatura informada no existen. V278.';

-- ===========================================================================
-- ENDPOINT — GET /planeador/referente-curricular?grado=&asignatura=&anio=
--
-- Query-string y no path params: los dos valores son una SELECCION del
-- formulario (los combos de grado y asignatura), no la identidad de un
-- recurso; y asignatura es opcional -- con path params habria que registrar
-- dos rutas para el mismo lookup.
-- ===========================================================================
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_refcurr_por_grado_asignatura(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.GRADO AS BIGINT),
    CAST(:QUERY.ASIGNATURA AS BIGINT),
    CAST(:QUERY.ANIO AS INT)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/referente-curricular', 'SELECT', 'GET',
    '{"QUERY.GRADO": "BIGINT", "QUERY.ASIGNATURA": "BIGINT", "QUERY.ANIO": "INT"}'::jsonb,
    'V278 -- el referente curricular que le corresponde a un ?grado= (obligatorio) y ?asignatura= (opcional), con TODOS sus datos, para pintar la unidad y la actividad ANTES de crear la unidad (con unidad ya creada, usar GET /planeador/unidades/:ID/referente, V255). El referente NO se elige a mano: se deriva del grado -> nivel de ensenanza -> referente(s) de ese nivel, y este endpoint hace el recorrido en una sola llamada. Devuelve un ARREGLO ordenado por preferencia (la relacion referente<->nivel es N:N, puede haber varios): primero los acotados al area de la asignatura pedida, luego los universales, y dentro de cada grupo la vigencia mas reciente -- lee aplica_a_area y especificidad para mostrar el criterio en vez de asumir la primera fila a ciegas. ?asignatura= filtra por AREA (TREFERENTE_CURRICULAR_AREA): un referente sin areas declaradas aplica a TODAS, no a ninguna. ?anio= (default: anio en curso) descarta los referentes fuera de vigencia. Por cada referente: nombre, descripcion, enfoque_valor + es_evaluativo, tipo_evaluacion_valor + nombre (las dos reglas que deciden que secciones e instrumentos se habilitan en la actividad, ver GET /planeador/actividades/:ID/configuracion), nivel_1_etiqueta y nivel_2_etiqueta (como llama ESE referente a sus niveles: "Enunciado"/"Evidencia" en primaria, "Proposito"/"Evidencia" en preescolar -- rotula con esto, no con literales), instrumento, instrumento_info_adicional, normatividad, vigencia, niveles:[{pk,nombre}], areas:[{pk,nombre}] ([] = todas) y enunciados:[{pk, texto, evidencias:[{pk, texto}]}] con el arbol de enunciados y evidencias. total_count via COUNT(*) OVER(). Gate VER sobre PLANEADOR + alcance territorial por el grado; 404 (P0002) si el grado o la asignatura no existen.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR', 'CEVAL-DOCENTE')
 WHERE m.serviceid = 'eval-col'
   AND q.path_template = '/planeador/referente-curricular'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;
