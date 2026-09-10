-- ===========================================================================
-- V281 — Planeador: las PESTANAS de unidad que le corresponden a un docente,
-- una por referente curricular de los niveles educativos que dicta
-- (CU-86e311xxp).
--
-- EL PROBLEMA: la pestana del Planeador dice "Unidad tematica" fijo, pero ese
-- rotulo no es fijo -- lo define el referente curricular del nivel educativo,
-- en su campo INSTRUMENTO ("Unidad tematica" en Basica Primaria, "Proyecto
-- pedagogico" en Preescolar, "Valores"...), con INSTRUMENTO_INFO_ADICIONAL
-- como descripcion larga ("Incluye planes de area, rubricas, informes de
-- logro...").
--
-- Y un docente no tiene UNA pestana: tiene las que le salgan de los niveles
-- que dicta.
--
--   * Un docente solo de Preescolar -> UNA pestana, "Proyecto pedagogico".
--   * Un docente con grados de Primaria y Secundaria -> DOS (o mas), una por
--     referente: "Unidad tematica", "Valores"...
--
-- Ya existia fn_unidad_etiqueta_por_grado (V216), pero resuelve UN grado y
-- devuelve UN texto: el front tendria que llamarla una vez por cada grado que
-- dicta el docente y deduplicar los referentes a mano. Esta funcion hace ese
-- recorrido completo del lado del servidor y devuelve la lista ya agrupada.
--
-- -------------------------------------------------------------------------
-- DE DONDE SALEN LOS NIVELES DEL DOCENTE
--
--     TDOCENTE_ASIGNATURA (FK_TFUNCIONARIO, FK_TGRUPO, FK_TASIGNATURA)
--       -> TGRUPO -> TGRADO -> FK_TNIVEL_ENSENANZA
--
-- Es el mismo vinculo real docente<->asignatura<->grupo que usan V242 y el
-- filtro p_fk_tfuncionario de fn_actividad_listar (V250): NO se usa
-- TUNIDAD.FK_TFUNCIONARIO, que es el AUTOR de una unidad y puede ser otro
-- docente o el coordinador que la armo.
--
-- El docente se resuelve del token con fn_funcionario_actual (V224) y NO es
-- un parametro: nadie consulta las pestanas de otro docente por esta ruta, y
-- el cliente no tiene de donde sacar un PK_TFUNCIONARIO (el claim "fid" del
-- JWT es un id de sesion, no el funcionario). Guard explicito: si el usuario
-- no es un docente activo, 0 filas -- nunca "todas las pestanas del universo".
--
-- -------------------------------------------------------------------------
-- COMO SE AGRUPA
--
-- Por cada par (grado, asignatura) que dicta se deriva su referente con
-- fn_unidad_referente_aplicable (V216) -- la UNICA definicion de la regla,
-- la misma que usan fn_unidad_crear y GET /planeador/referente-curricular, asi
-- que la pestana y lo que se ofrece dentro de ella no pueden discrepar.
-- Despues se agrupa por referente: si dos niveles comparten referente (pasa,
-- la relacion es N:N -- p.ej. el referente 25 cubre Primaria y Secundaria) es
-- UNA sola pestana, no dos con el mismo nombre.
--
-- NIVELES SIN REFERENTE: no se omiten. Se devuelven con
-- pk_referente_curricular NULL e instrumento 'Unidad tematica' -- el rotulo
-- historico, el mismo fallback de fn_unidad_etiqueta_por_grado. Omitirlos
-- dejaria al docente sin pestana para grados que si dicta; el front necesita
-- la pestana igual, aunque dentro no haya arbol de enunciados que marcar.
-- Esos casos se agrupan por NIVEL (no por referente, que es NULL).
--
-- Cada fila trae los grados y asignaturas que caen bajo esa pestana, para que
-- el front pueda filtrar el contenido al cambiar de pestana sin volver a
-- preguntar; y las banderas del referente (es_evaluativo, tipo_evaluacion,
-- nivel_1_etiqueta / nivel_2_etiqueta) para no tener que pedir el detalle solo
-- para saber como pintarla.
--
-- Depende de: V46 (TDOCENTE_ASIGNATURA), V212 (TREFERENTE_CURRICULAR y sus
-- puentes, rama CU-86e311xqh), V216 (fn_unidad_referente_aplicable, menu
-- PLANEADOR), V224 (fn_funcionario_actual).
-- ===========================================================================

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_docente_unidad_tabs_listar(
    p_pk_usuario_solicitante BIGINT
)
RETURNS TABLE (
    -- Lo que rotula la pestana. instrumento nunca viene NULL: cae a
    -- 'Unidad tematica' cuando el nivel no tiene referente cargado.
    instrumento                 VARCHAR,
    instrumento_info_adicional  VARCHAR,
    pk_referente_curricular     BIGINT,
    referente_nombre            VARCHAR,
    -- Como pintar el contenido de la pestana, sin pedir el detalle aparte.
    enfoque_valor               VARCHAR,
    es_evaluativo               BOOLEAN,
    tipo_evaluacion_valor       VARCHAR,
    nivel_1_etiqueta            VARCHAR,
    nivel_2_etiqueta            VARCHAR,
    -- Que niveles / grados / asignaturas caen bajo esta pestana. Un referente
    -- puede cubrir varios niveles (la relacion es N:N), de ahi el arreglo.
    niveles                     JSONB,
    grados                      JSONB,
    asignaturas                 JSONB,
    total_grados                BIGINT,
    total_count                 BIGINT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_fk_tfuncionario BIGINT;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    v_fk_tfuncionario := academico_test.fn_funcionario_actual(p_pk_usuario_solicitante);

    -- Guard explicito, mismo criterio que fn_actividad_listar_docente (V250):
    -- si no es docente activo, 0 filas. Sin esto habria que decidir que
    -- significa "sin funcionario", y la unica respuesta segura es "nada".
    IF v_fk_tfuncionario IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH asignaciones AS (
        -- Los pares (grado, asignatura) que el docente REALMENTE dicta, ya
        -- deduplicados: un mismo grado+asignatura puede venir por varios
        -- grupos (dos cursos del mismo grado) y eso no multiplica pestanas.
        SELECT DISTINCT
               gr.PK_TGRADO           AS pk_tgrado,
               gr.NOMBRE              AS grado_nombre,
               gr.FK_TNIVEL_ENSENANZA AS pk_nivel,
               asig.PK_TASIGNATURA    AS pk_tasignatura,
               asig.NOMBRE            AS asignatura_nombre
          FROM academico_test.TDOCENTE_ASIGNATURA da
          JOIN academico_test.TGRUPO g       ON g.PK_TGRUPO = da.FK_TGRUPO
                                            AND g.ACTIVE = TRUE
          JOIN academico_test.TGRADO gr      ON gr.PK_TGRADO = g.FK_TGRADO
                                            AND gr.ACTIVE = TRUE
          JOIN academico_test.TASIGNATURA asig ON asig.PK_TASIGNATURA = da.FK_TASIGNATURA
                                            AND asig.ACTIVE = TRUE
         WHERE da.FK_TFUNCIONARIO = v_fk_tfuncionario
           AND da.ACTIVE = TRUE
    ), con_referente AS (
        -- El referente de cada par, con la regla unica de V216.
        SELECT a.*,
               academico_test.fn_unidad_referente_aplicable(
                   a.pk_tgrado, a.pk_tasignatura) AS pk_referente
          FROM asignaciones a
    ), agrupado AS (
        -- La CLAVE de agrupacion: el referente cuando lo hay, y el nivel
        -- cuando no. Dos niveles que comparten referente son UNA pestana; dos
        -- niveles sin referente son pestanas distintas (una por nivel), no una
        -- sola "Unidad tematica" que las mezcle.
        SELECT COALESCE('R' || cr.pk_referente::TEXT, 'N' || cr.pk_nivel::TEXT) AS clave,
               MIN(cr.pk_referente)                                            AS pk_referente,
               jsonb_agg(DISTINCT jsonb_build_object(
                   'pk', cr.pk_tgrado, 'nombre', cr.grado_nombre))             AS grados,
               jsonb_agg(DISTINCT jsonb_build_object(
                   'pk', cr.pk_tasignatura, 'nombre', cr.asignatura_nombre))   AS asignaturas,
               jsonb_agg(DISTINCT jsonb_build_object(
                   'pk', cr.pk_nivel, 'nombre', ne.NOMBRE))                    AS niveles,
               COUNT(DISTINCT cr.pk_tgrado)::BIGINT                            AS total_grados
          FROM con_referente cr
          LEFT JOIN academico_test.TNIVEL_ENSENANZA ne
                 ON ne.PK_NIVEL_ENSENANZA = cr.pk_nivel
         GROUP BY COALESCE('R' || cr.pk_referente::TEXT, 'N' || cr.pk_nivel::TEXT)
    )
    SELECT COALESCE(NULLIF(TRIM(rc.INSTRUMENTO), ''), 'Unidad tematica')::VARCHAR,
           rc.INSTRUMENTO_INFO_ADICIONAL,
           rc.PK_REFERENTE_CURRICULAR,
           rc.NOMBRE,
           enf.VALOR,
           (enf.VALOR = 'EVALUATIVO'),
           tev.VALOR,
           rc.NIVEL_1_ETIQUETA,
           rc.NIVEL_2_ETIQUETA,
           ag.niveles,
           ag.grados,
           ag.asignaturas,
           ag.total_grados,
           COUNT(*) OVER()
      FROM agrupado ag
      LEFT JOIN academico_test.TREFERENTE_CURRICULAR rc
             ON rc.PK_REFERENTE_CURRICULAR = ag.pk_referente
      LEFT JOIN academico_test.TLISTA_VALOR enf ON enf.PK_LISTA_VALOR = rc.FK_TLV_ENFOQUE_PEDAGOGICO
      LEFT JOIN academico_test.TLISTA_VALOR tev ON tev.PK_LISTA_VALOR = rc.FK_TLV_TIPO_EVALUACION
     -- Las pestanas con referente primero (son las utiles); dentro, por
     -- rotulo, para que el orden sea estable entre llamadas.
     ORDER BY (ag.pk_referente IS NULL),
              COALESCE(NULLIF(TRIM(rc.INSTRUMENTO), ''), 'Unidad tematica'),
              ag.clave;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_docente_unidad_tabs_listar(BIGINT)
    IS 'Las PESTANAS de unidad que le corresponden al docente autenticado: una por referente curricular de los niveles educativos que dicta. El rotulo de la pestana NO es fijo ("Unidad tematica"): lo define TREFERENTE_CURRICULAR.INSTRUMENTO del nivel ("Proyecto pedagogico" en Preescolar, "Unidad tematica" en Primaria, "Valores"...), con INSTRUMENTO_INFO_ADICIONAL como descripcion larga. Un docente solo de Preescolar recibe UNA fila; uno con grados de varios niveles recibe la lista. Los niveles del docente salen de TDOCENTE_ASIGNATURA -> TGRUPO -> TGRADO -> FK_TNIVEL_ENSENANZA (el vinculo real que dicta, igual que V242/V250 -- NO TUNIDAD.FK_TFUNCIONARIO, que es el AUTOR de la unidad y puede ser otro). El docente se resuelve del token con fn_funcionario_actual y no es parametro; si el usuario no es docente activo devuelve 0 filas (nunca el universo). Por cada par (grado, asignatura) que dicta se deriva el referente con fn_unidad_referente_aplicable -- UNICA definicion de la regla, la misma de fn_unidad_crear y de GET /planeador/referente-curricular, para que la pestana y lo que se ofrece dentro no discrepen -- y luego se agrupa por referente: si dos niveles comparten referente (la relacion es N:N) es UNA pestana, no dos con el mismo nombre. Los niveles SIN referente aplicable NO se omiten: vienen con pk_referente_curricular NULL e instrumento ''Unidad tematica'' (el fallback historico) y se agrupan por nivel -- omitirlos dejaria al docente sin pestana para grados que si dicta. Cada fila trae niveles/grados/asignaturas que caen bajo la pestana (para filtrar el contenido al cambiar de pestana sin volver a preguntar) y las banderas del referente (es_evaluativo, tipo_evaluacion_valor, nivel_1_etiqueta, nivel_2_etiqueta) para no pedir el detalle solo para saber como pintarla. Orden estable: primero las que tienen referente, luego por rotulo. Gate VER sobre PLANEADOR. V281.';

-- ===========================================================================
-- ENDPOINT — GET /planeador/unidades/tabs
--
-- Sin parametros: todo sale del token. Cuelga de /planeador/unidades/ porque
-- son las pestanas de ESA pantalla; no se llama /mis-tabs para no inventar un
-- prefijo nuevo cuando el resto del modulo ya usa /planeador/<recurso>/...
-- ===========================================================================
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_docente_unidad_tabs_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/unidades/tabs', 'SELECT', 'GET',
    '{}'::jsonb,
    'V281 -- las PESTANAS de unidad del docente autenticado, una por referente curricular de los niveles educativos que dicta. El rotulo de la pestana NO es fijo: sale de instrumento (TREFERENTE_CURRICULAR.INSTRUMENTO del referente del nivel -- "Proyecto pedagogico" en Preescolar, "Unidad tematica" en Primaria, "Valores"...) y instrumento_info_adicional es su descripcion larga. Un docente que solo dicta Preescolar recibe UNA fila; uno con grados de varios niveles recibe la lista completa. Sin parametros: el docente se resuelve del token (no se pueden consultar las pestanas de otro), y si el usuario no es un docente activo devuelve 0 filas. Cada fila trae, ademas del rotulo: pk_referente_curricular y referente_nombre; enfoque_valor + es_evaluativo y tipo_evaluacion_valor (que secciones e instrumentos se habilitan dentro); nivel_1_etiqueta / nivel_2_etiqueta (como llama ESE referente a sus niveles -- rotular con esto); y niveles / grados / asignaturas: [{pk,nombre}] con lo que cae bajo esa pestana, para filtrar el contenido al cambiar de pestana sin volver a preguntar. Si dos niveles comparten referente es UNA sola pestana (la relacion referente<->nivel es N:N). Los niveles cuyo grado aun no tiene referente cargado NO se omiten: vienen con pk_referente_curricular null e instrumento "Unidad tematica" -- hay que pintar la pestana igual, aunque dentro no haya arbol de enunciados. Orden estable: primero las pestanas con referente, luego por rotulo. Gate VER sobre PLANEADOR.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR', 'CEVAL-DOCENTE')
 WHERE m.serviceid = 'eval-col'
   AND q.path_template = '/planeador/unidades/tabs'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;
