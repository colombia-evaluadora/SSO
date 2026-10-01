-- ===========================================================================
-- V525 — fn_planeador_actividad_tabs_listar + GET /planeador/actividades/tabs
-- Que hace: las PESTANAS de "Actividades", una por Rotulo de Ejecucion (Regla
--   13) entre los pares (grado, asignatura) que el usuario dicta o administra.
-- Por que aqui: fn_docente_unidad_tabs_listar (V407) agrupa por GRADO (via
--   referente); el rotulo de ejecucion se resuelve por GRADO+ASIGNATURA
--   (fn_unidad_referente_aplicable, V451) -- dos asignaturas de un mismo
--   grado pueden resolver a rotulos distintos. Agrupar por grado solo podia
--   mezclar en una pestana actividades de rotulos diferentes.
-- Depende de: V451 (fn_unidad_referente_aplicable), V407 (mismas dos ramas
--   docente/territorial), V511 (misma regla de rotulo), V29 (gate).
-- ===========================================================================

SET search_path TO academico_test, public;

-- ---------------------------------------------------------------------------
-- 1. Plural del rotulo, resuelto en servidor (evita pluralizar con JS).
-- ---------------------------------------------------------------------------
ALTER TABLE academico_test.TREFERENTE_CURRICULAR
    ADD COLUMN IF NOT EXISTS ROTULO_EJECUCION_PLURAL VARCHAR;

COMMENT ON COLUMN academico_test.TREFERENTE_CURRICULAR.ROTULO_EJECUCION_PLURAL IS
    'Plural de ROTULO_EJECUCION ("Experiencias de aprendizaje" para
     "Experiencia de aprendizaje"), para las pestañas/botones de Actividades
     sin pluralizar con JS. NULL = fn_planeador_rotulo_pluralizar da un
     fallback best-effort.';

UPDATE academico_test.TREFERENTE_CURRICULAR
   SET ROTULO_EJECUCION_PLURAL = 'Actividades'
 WHERE ROTULO_EJECUCION = 'Actividad' AND ROTULO_EJECUCION_PLURAL IS NULL;

UPDATE academico_test.TREFERENTE_CURRICULAR
   SET ROTULO_EJECUCION_PLURAL = 'Experiencias de aprendizaje'
 WHERE ROTULO_EJECUCION = 'Experiencia de aprendizaje' AND ROTULO_EJECUCION_PLURAL IS NULL;

CREATE OR REPLACE FUNCTION academico_test.fn_planeador_rotulo_pluralizar(
    p_rotulo VARCHAR
)
RETURNS VARCHAR
LANGUAGE sql
IMMUTABLE
AS $$
    -- Una palabra: heuristica minima (vocal -> +s, consonante -> +es). Con
    -- espacio (rotulo compuesto): se devuelve TAL CUAL antes que arriesgar
    -- una forma compuesta rota -- la forma correcta se configura en
    -- ROTULO_EJECUCION_PLURAL.
    SELECT CASE
             WHEN p_rotulo IS NULL THEN NULL
             WHEN position(' ' IN trim(p_rotulo)) > 0 THEN p_rotulo
             WHEN right(trim(p_rotulo), 1) IN ('a','e','i','o','u','á','é','í','ó','ú')
               THEN p_rotulo || 's'
             ELSE p_rotulo || 'es'
           END;
$$;

COMMENT ON FUNCTION academico_test.fn_planeador_rotulo_pluralizar(VARCHAR) IS
    'INTERNO: fallback best-effort de plural cuando ROTULO_EJECUCION_PLURAL
     no esta configurado. Una palabra: heuristica simple. Mas de una palabra:
     devuelve el rotulo sin cambios. Preferir siempre la columna configurada.';

-- ---------------------------------------------------------------------------
-- 2. Nucleo sin gate: agrupa por el TEXTO del rotulo resuelto por par
--    (grado, asignatura) -- no por referente, dos referentes distintos
--    pueden compartir el mismo texto de rotulo y deben caer en la misma
--    pestana. grado_asignatura_pares es la fuente para filtrar sin fuga.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_planeador_actividad_tabs_listar_interno(
    p_sedes_lectura    BIGINT[],
    p_alcance_total    BOOLEAN,
    p_solo_propias     BOOLEAN,
    p_fk_tfuncionario  BIGINT
)
RETURNS TABLE (
    rotulo_ejecucion         VARCHAR,
    rotulo_ejecucion_plural  VARCHAR,
    pk_referente_curricular  BIGINT,
    grados                   JSONB,
    asignaturas              JSONB,
    grado_asignatura_pares   JSONB,
    total_grados             BIGINT,
    total_count              BIGINT
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_fk_tfuncionario IS NULL
       AND NOT p_alcance_total
       AND array_length(p_sedes_lectura, 1) IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH pares AS (
        -- Rama 1: lo que el docente REALMENTE dicta (grado, asignatura).
        SELECT DISTINCT
               gr.PK_TGRADO        AS pk_tgrado,
               gr.NOMBRE           AS grado_nombre,
               asig.PK_TASIGNATURA AS pk_tasignatura,
               asig.NOMBRE         AS asignatura_nombre
          FROM academico_test.TDOCENTE_ASIGNATURA da
          JOIN academico_test.TGRUPO g        ON g.PK_TGRUPO = da.FK_TGRUPO AND g.ACTIVE = TRUE
          JOIN academico_test.TGRADO gr       ON gr.PK_TGRADO = g.FK_TGRADO AND gr.ACTIVE = TRUE
          JOIN academico_test.TASIGNATURA asig ON asig.PK_TASIGNATURA = da.FK_TASIGNATURA AND asig.ACTIVE = TRUE
         WHERE p_fk_tfuncionario IS NOT NULL
           AND da.FK_TFUNCIONARIO = p_fk_tfuncionario
           AND da.ACTIVE = TRUE

        UNION

        -- Rama 2: alcance territorial (rector/coordinador/...), sin
        -- asignatura puntual -- mismo criterio que V407.
        SELECT DISTINCT
               gr.PK_TGRADO, gr.NOMBRE, NULL::BIGINT, NULL::VARCHAR
          FROM academico_test.TGRADO gr
          JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.PK_TPERIODO_ACADEMICO = gr.FK_TPERIODO_ACADEMICO
          JOIN academico_test.TSEDE s               ON s.PK_TSEDE = pa.FK_TSEDE AND s.ACTIVE = TRUE
         WHERE gr.ACTIVE = TRUE
           AND NOT p_solo_propias
           AND (p_alcance_total OR pa.FK_TSEDE = ANY(p_sedes_lectura))
    ), con_rotulo AS (
        SELECT p.*,
               academico_test.fn_unidad_referente_aplicable(p.pk_tgrado, p.pk_tasignatura) AS pk_referente
          FROM pares p
    ), con_label AS (
        SELECT cr.*,
               COALESCE((SELECT rc.ROTULO_EJECUCION FROM academico_test.TREFERENTE_CURRICULAR rc
                          WHERE rc.PK_REFERENTE_CURRICULAR = cr.pk_referente), 'Actividad')::VARCHAR AS rotulo,
               COALESCE(
                   (SELECT rc2.ROTULO_EJECUCION_PLURAL FROM academico_test.TREFERENTE_CURRICULAR rc2
                     WHERE rc2.PK_REFERENTE_CURRICULAR = cr.pk_referente),
                   academico_test.fn_planeador_rotulo_pluralizar(
                       COALESCE((SELECT rc3.ROTULO_EJECUCION FROM academico_test.TREFERENTE_CURRICULAR rc3
                                  WHERE rc3.PK_REFERENTE_CURRICULAR = cr.pk_referente), 'Actividad'))
               )::VARCHAR AS rotulo_plural
          FROM con_rotulo cr
    ), agrupado AS (
        SELECT cl.rotulo,
               MIN(cl.rotulo_plural)                                         AS rotulo_plural,
               MIN(cl.pk_referente)                                          AS pk_referente,
               jsonb_agg(DISTINCT jsonb_build_object(
                   'pk', cl.pk_tgrado, 'nombre', cl.grado_nombre))           AS grados,
               jsonb_agg(DISTINCT jsonb_build_object(
                   'pk', cl.pk_tasignatura, 'nombre', cl.asignatura_nombre)) AS asignaturas,
               jsonb_agg(DISTINCT jsonb_build_object(
                   'grado', cl.pk_tgrado, 'asignatura', cl.pk_tasignatura))  AS pares,
               COUNT(DISTINCT cl.pk_tgrado)::BIGINT                          AS total_grados
          FROM con_label cl
         GROUP BY cl.rotulo
    )
    -- MIN(varchar) resuelve a `text`: RETURN QUERY exige tipo exacto contra
    -- RETURNS TABLE, así que hace falta el cast explícito acá, no alcanza
    -- con el de con_label.
    SELECT ag.rotulo::VARCHAR,
           ag.rotulo_plural::VARCHAR,
           ag.pk_referente,
           ag.grados,
           ag.asignaturas,
           ag.pares,
           ag.total_grados,
           COUNT(*) OVER()
      FROM agrupado ag
     ORDER BY (ag.rotulo = 'Actividad') DESC, ag.rotulo;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_planeador_actividad_tabs_listar_interno(BIGINT[], BOOLEAN, BOOLEAN, BIGINT) IS
    'INTERNO: pestañas de Actividades sin gate, recibe el alcance ya resuelto
     (mismo shape que fn_planeador_listado_alcance, V481). Agrupa por el
     TEXTO del rotulo_ejecucion resuelto POR PAR grado+asignatura
     (fn_unidad_referente_aplicable, V451) -- no por referente ni por grado
     solo. grado_asignatura_pares trae los pares reales de cada pestaña:
     filtrar por grados/asignaturas sueltos puede filtrar de más (un grado
     puede caer en dos pestañas si sus asignaturas resuelven distinto). Lo
     usa fn_planeador_actividad_tabs_listar.';

-- ---------------------------------------------------------------------------
-- 3. Wrapper: gate + alcance + delegar.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_planeador_actividad_tabs_listar(
    p_pk_usuario_solicitante BIGINT
)
RETURNS TABLE (
    rotulo_ejecucion         VARCHAR,
    rotulo_ejecucion_plural  VARCHAR,
    pk_referente_curricular  BIGINT,
    grados                   JSONB,
    asignaturas              JSONB,
    grado_asignatura_pares   JSONB,
    total_grados             BIGINT,
    total_count              BIGINT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_alc RECORD;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    SELECT * INTO v_alc FROM academico_test.fn_planeador_listado_alcance(p_pk_usuario_solicitante);

    RETURN QUERY
    SELECT * FROM academico_test.fn_planeador_actividad_tabs_listar_interno(
        v_alc.sedes_lectura, v_alc.alcance_total, v_alc.solo_propias, v_alc.fk_tfuncionario
    );
END;
$$;

COMMENT ON FUNCTION academico_test.fn_planeador_actividad_tabs_listar(BIGINT) IS
    'GET /planeador/actividades/tabs: las pestañas de Actividades del usuario
     autenticado, una por Rotulo de Ejecucion. Gate VER sobre PLANEADOR;
     alcance via fn_planeador_listado_alcance (V481, la misma que usan los
     listados de actividades y unidades); lógica en
     fn_planeador_actividad_tabs_listar_interno.';

-- ---------------------------------------------------------------------------
-- 4. GET /planeador/actividades/tabs
-- ---------------------------------------------------------------------------
INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id,
                           path_template, execution_mode, http_method, param_types, detail)
SELECT
    'planeador-actividad-tabs',
    $q$SELECT * FROM academico_test.fn_planeador_actividad_tabs_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);$q$,
    'postgres', false, false, m.id_microservice,
    '/planeador/actividades/tabs', 'SELECT', 'GET', '{}'::jsonb,
    'Las PESTANAS del listado de Actividades, una por Rotulo de Ejecucion (Regla 13) -- mismo mecanismo que GET /planeador/unidades/tabs pero agrupando por rotulo_ejecucion resuelto por PAR grado+asignatura (fn_unidad_referente_aplicable) en vez de por referente a nivel grado. Sin parametros: el usuario se resuelve del token. Cada fila trae rotulo_ejecucion/rotulo_ejecucion_plural (ya pluralizado en el servidor, no concatenar "s" en el cliente), pk_referente_curricular (informativo, el primero del grupo), grados/asignaturas ([{pk,nombre}]) y grado_asignatura_pares ([{grado,asignatura}], la fuente correcta para filtrar/acotar: dos asignaturas de un mismo grado pueden caer en pestañas distintas). 0 filas si el usuario no tiene ningun alcance. Gate VER sobre PLANEADOR.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (uuid) DO UPDATE
   SET query = EXCLUDED.query, param_types = EXCLUDED.param_types,
       path_template = EXCLUDED.path_template, http_method = EXCLUDED.http_method,
       execution_mode = EXCLUDED.execution_mode, microservice_id = EXCLUDED.microservice_id,
       detail = EXCLUDED.detail;

-- Mismos once roles que ya leen /planeador/unidades* y /planeador/actividades*.
INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id AND m.serviceid = 'eval-col'
  JOIN public.role r ON r.name IN (
        'CEVAL-SUPER_ADMINISTRADOR', 'CEVAL-RECTOR', 'CEVAL-COORDINADOR', 'CEVAL-DOCENTE',
        'CEVAL-DIRECTOR_GRUPO', 'CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO',
        'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-JEFE_AREA_CALIDAD', 'CEVAL-JEFE_AREA_COBERTURA',
        'CEVAL-JEFE_AREA_PLANEACION')
 WHERE q.uuid = 'planeador-actividad-tabs'
ON CONFLICT DO NOTHING;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.query WHERE uuid = 'planeador-actividad-tabs') THEN
        RAISE EXCEPTION 'No se registro GET /planeador/actividades/tabs (falta el microservicio eval-col)';
    END IF;
END $$;
