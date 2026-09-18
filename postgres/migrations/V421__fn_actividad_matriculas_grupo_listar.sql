-- ===========================================================================
-- V421 -- fn_actividad_matriculas_grupo_listar + GET /planeador/actividades/
--         estudiantes-grupo.
-- Que hace: lista las matriculas activas de un grupo (id, nombre, documento)
--   para que el form de Actividad pueda ofrecer un checklist de estudiantes
--   puntuales en vez de asignar siempre "todo el grupo".
-- Por que aqui: fn_actividad_crear/_actualizar (V224) YA aceptan
--   FK_TMATRICULAS (array) o ASIGNAR_TODO_EL_GRUPO -- lo unico que faltaba
--   era de donde sacar la lista para armar ese array; no hay ningun otro
--   endpoint que devuelva el padron de un grupo sin pedir tambien una fecha
--   de asistencia (fn_asistencia_estudiantes_sesion, V220ish).
-- Depende de: V224 (TACTIVIDAD/fn_actividad_crear), V277 (fn_planeador_
--   assert_alcance), V22 (TMATRICULA/TESTUDIANTE).
-- ===========================================================================

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_matriculas_grupo_listar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tgrupo              BIGINT
)
RETURNS TABLE (
    fk_tmatricula  BIGINT,
    fk_testudiante BIGINT,
    estudiante     VARCHAR,
    documento      VARCHAR
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_fk_tgrupo IS NULL THEN
        RAISE EXCEPTION 'El grupo (FK_TGRUPO) es obligatorio' USING ERRCODE = '23502';
    END IF;

    -- Mismo gate de alcance que el resto del Planeador: un docente puro solo
    -- ve esto si el grupo es suyo (via fn_usuario_es_docente_puro dentro de
    -- fn_planeador_assert_alcance); rector/coordinador/admin, por alcance
    -- territorial de la sede del grupo.
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', p_fk_tgrupo, NULL, NULL, NULL
    );

    IF NOT EXISTS (SELECT 1 FROM academico_test.TGRUPO WHERE PK_TGRUPO = p_fk_tgrupo AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'El grupo (%) no existe o no esta activo', p_fk_tgrupo USING ERRCODE = '23503';
    END IF;

    RETURN QUERY
    SELECT
        m.PK_TMATRICULA,
        es.PK_TESTUDIANTE,
        NULLIF(TRIM(regexp_replace(
            concat_ws(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE, u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO),
            '\s+', ' ', 'g')), '')::VARCHAR,
        u.IDENTIFICACION
      FROM academico_test.TMATRICULA m
      JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE AND es.ACTIVE = TRUE
      JOIN academico_test.TUSUARIO u     ON u.PK_TUSUARIO = es.FK_TUSUARIO
     WHERE m.FK_TGRUPO = p_fk_tgrupo
       AND m.ACTIVE = TRUE
     ORDER BY u.PRIMER_APELLIDO, u.PRIMER_NOMBRE;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_matriculas_grupo_listar(BIGINT, BIGINT)
    IS 'Padron de matriculas activas de un grupo (pk_tmatricula, pk_testudiante, nombre completo, documento) -- para el checklist de "Estudiantes" del form de Actividad, que arma el array FK_TMATRICULAS que fn_actividad_crear/_actualizar (V224) ya aceptan. Gate VER sobre PLANEADOR + alcance territorial del grupo (fn_planeador_assert_alcance, V277). V421.';

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_actividad_matriculas_grupo_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.GRUPO AS BIGINT)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades/estudiantes-grupo', 'SELECT', 'GET',
    '{"QUERY.GRUPO": "BIGINT"}'::jsonb,
    'V421 -- padron de matriculas activas del grupo (?grupo=), para el checklist de "Estudiantes" al crear/editar una actividad. Ver fn_actividad_matriculas_grupo_listar. Gate VER sobre PLANEADOR.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

-- Mismos roles que ya pueden CREAR una actividad (POST /planeador/actividades)
-- -- sin hardcodear nombres de rol (ver V305: un nombre que no matchea deja
-- el INSERT como no-op silencioso).
INSERT INTO public.role_query (role_id, query_id)
SELECT rq.role_id, q_new.id_query
  FROM public.role_query rq
  JOIN public.query q_old ON q_old.id_query = rq.query_id
  JOIN public.query q_new ON q_new.microservice_id = q_old.microservice_id
                          AND q_new.path_template = '/planeador/actividades/estudiantes-grupo'
                          AND q_new.http_method = 'GET'
  JOIN public.microservice m ON m.id_microservice = q_old.microservice_id
 WHERE m.serviceid = 'eval-col'
   AND q_old.path_template = '/planeador/actividades'
   AND q_old.http_method = 'POST'
ON CONFLICT DO NOTHING;
