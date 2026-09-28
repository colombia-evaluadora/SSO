-- V511 -- fn_planeador_rotulo_actividad + GET /planeador/rotulo-actividad  [CU-86e3ffvx9]
-- Que hace: dado ?grado= (y ?asignatura= opcional) dice como se llama la
--   actividad bajo el referente que le corresponde (Rotulo de Ejecucion,
--   Regla 13), sin traer el referente completo de /planeador/referente-curricular.
-- Por que aqui: numero nuevo para no reaplicar V422, cuya reejecucion revertiria
--   funciones de actividad reescritas despues. El referente sale de
--   fn_unidad_referente_aplicable, la unica definicion de la regla.
-- Depende de: V212/V214.3 (ROTULO_EJECUCION), V451 (fn_unidad_referente_aplicable),
--   V277 (fn_planeador_assert_alcance), V29 (gate).

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_planeador_rotulo_actividad_interno(
    p_fk_tgrado       BIGINT,
    p_fk_tasignatura  BIGINT DEFAULT NULL,
    p_anio            INT    DEFAULT NULL
)
RETURNS TABLE (
    fk_tgrado                BIGINT,
    pk_referente_curricular  BIGINT,
    rotulo_ejecucion         VARCHAR
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_pk_referente  BIGINT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM academico_test.TGRADO g WHERE g.PK_TGRADO = p_fk_tgrado) THEN
        RAISE EXCEPTION 'No se encontro el grado solicitado' USING ERRCODE = 'P0002';
    END IF;
    -- Mandar una asignatura que no existe es un error del cliente, no "sin filtro".
    IF p_fk_tasignatura IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TASIGNATURA a WHERE a.PK_TASIGNATURA = p_fk_tasignatura
    ) THEN
        RAISE EXCEPTION 'No se encontro la asignatura solicitada' USING ERRCODE = 'P0002';
    END IF;

    v_pk_referente := academico_test.fn_unidad_referente_aplicable(p_fk_tgrado, p_fk_tasignatura, p_anio);

    -- Sin referente aplicable no hay rotulo configurado: "Actividad" es el
    -- valor por defecto de la columna, asi el front siempre tiene que pintar.
    RETURN QUERY
    SELECT p_fk_tgrado,
           v_pk_referente,
           COALESCE((SELECT rc.ROTULO_EJECUCION FROM academico_test.TREFERENTE_CURRICULAR rc
                      WHERE rc.PK_REFERENTE_CURRICULAR = v_pk_referente), 'Actividad')::VARCHAR;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_planeador_rotulo_actividad_interno(BIGINT, BIGINT, INT)
    IS 'INTERNO: Rotulo de Ejecucion del referente que le corresponde a un grado + asignatura (fn_unidad_referente_aplicable). Una fila siempre: pk_referente_curricular NULL y rotulo "Actividad" si ningun referente aplica. P0002 si el grado o la asignatura informada no existen. Lo usa fn_planeador_rotulo_actividad.';

CREATE OR REPLACE FUNCTION academico_test.fn_planeador_rotulo_actividad(
    p_pk_usuario_solicitante  BIGINT,
    p_fk_tgrado               BIGINT,
    p_fk_tasignatura          BIGINT DEFAULT NULL,
    p_anio                    INT    DEFAULT NULL
)
RETURNS TABLE (
    fk_tgrado                BIGINT,
    pk_referente_curricular  BIGINT,
    rotulo_ejecucion         VARCHAR
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(p_pk_usuario_solicitante, 'PLANEADOR', 'VER');
    -- El grado es el ancla del alcance: sin el, el gate no acota nada. Corre
    -- antes que la existencia para no revelar que grados existen (403, no 404).
    PERFORM academico_test.fn_planeador_assert_alcance(p_pk_usuario_solicitante, 'VER', NULL, p_fk_tgrado);

    RETURN QUERY
    SELECT * FROM academico_test.fn_planeador_rotulo_actividad_interno(p_fk_tgrado, p_fk_tasignatura, p_anio);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_planeador_rotulo_actividad(BIGINT, BIGINT, BIGINT, INT)
    IS 'GET /planeador/rotulo-actividad?grado=&asignatura=&anio=: como se llama la actividad (Rotulo de Ejecucion) para ese grado. Gate VER sobre PLANEADOR + alcance territorial por el grado; logica en fn_planeador_rotulo_actividad_interno.';

INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id,
                           path_template, execution_mode, http_method, param_types, detail)
SELECT
    'planeador-rotulo-actividad',
    $q$SELECT * FROM academico_test.fn_planeador_rotulo_actividad(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.GRADO AS BIGINT),
    CAST(:QUERY.ASIGNATURA AS BIGINT),
    CAST(:QUERY.ANIO AS INT)
);$q$,
    'postgres', false, false, m.id_microservice,
    '/planeador/rotulo-actividad', 'SELECT', 'GET',
    '{"QUERY.GRADO": "BIGINT", "QUERY.ASIGNATURA": "BIGINT", "QUERY.ANIO": "INT"}'::jsonb,
    'Como se llama la actividad para un ?grado= (obligatorio) y ?asignatura= (opcional): el Rotulo de Ejecucion del referente curricular que le corresponde, resuelto con la misma regla que la unidad (grado -> nivel -> referente activo y vigente, preferido el acotado al area). Devuelve UNA fila {fk_tgrado, pk_referente_curricular, rotulo_ejecucion}; si ningun referente aplica, pk_referente_curricular es NULL y rotulo_ejecucion "Actividad". ?anio= por defecto el anio en curso. Gate VER sobre PLANEADOR + alcance por el grado: un grado fuera de alcance o inexistente da 403; un grado alcanzable o una asignatura que no existen dan 404'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (uuid) DO UPDATE
   SET query = EXCLUDED.query, param_types = EXCLUDED.param_types,
       path_template = EXCLUDED.path_template, http_method = EXCLUDED.http_method,
       execution_mode = EXCLUDED.execution_mode, microservice_id = EXCLUDED.microservice_id,
       detail = EXCLUDED.detail;

-- Mismos roles que GET /planeador/referente-curricular, copiados de su
-- role_query: quien ve la unidad de un grado ve tambien el rotulo de su actividad.
INSERT INTO public.role_query (role_id, query_id)
SELECT DISTINCT rq.role_id, nq.id_query
  FROM public.query oq
  JOIN public.microservice m ON m.id_microservice = oq.microservice_id AND m.serviceid = 'eval-col'
  JOIN public.role_query rq ON rq.query_id = oq.id_query
  JOIN public.query nq ON nq.uuid = 'planeador-rotulo-actividad'
 WHERE oq.path_template = '/planeador/referente-curricular'
   AND oq.http_method = 'GET'
   AND NOT EXISTS (SELECT 1 FROM public.role_query x
                    WHERE x.role_id = rq.role_id AND x.query_id = nq.id_query);

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.query WHERE uuid = 'planeador-rotulo-actividad') THEN
        RAISE EXCEPTION 'No se registro GET /planeador/rotulo-actividad (falta el microservicio eval-col)';
    END IF;
END $$;
