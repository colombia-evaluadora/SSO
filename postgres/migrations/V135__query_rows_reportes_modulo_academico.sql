-- ===========================================================================
-- V135 - Filas public.query de los reportes del modulo academico y sus roles.
-- Las funciones viven en V187 (grado/grupo), V188 (area/asignatura) y V190 (asignacion).
-- ===========================================================================


SET search_path TO academico_test, public;

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, detail, path_template, execution_mode, http_method, microservice_id, param_types)
VALUES (
    'q-mt9244pe-lfglm5gw',
    $sql$SELECT * FROM academico_test.fn_area_subject_reporte_listar(
      CAST(:BODY.FILTERS.FK_PERIODO AS BIGINT),
      CAST(:BODY.FILTERS.FK_AREA AS BIGINT[]),
      CAST(:BODY.FILTERS.FK_ASIGNATURA AS BIGINT[]),
      CAST(:BODY.FILTERS.FK_ESPECIALIDAD AS BIGINT[]),
      CAST(:BODY.FILTERS.INCLUIR_INACTIVOS AS BOOLEAN),
      public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
      NULL::INTEGER, NULL::INTEGER
  ) t
WHERE CAST(:BODY.FILTERS.IDS AS BIGINT[]) IS NULL
   OR t.area_id = ANY(CAST(:BODY.FILTERS.IDS AS BIGINT[]));$sql$,
    'postgres', false, false,
    'V135 — areas/reporte: una fila por (area, asignatura, enfasis). Replica fn_periodo_areas_asignaturas_listar pero con salida fila-plana para el reporte. inactivos excluidos por defecto (param INCLUIR_INACTIVOS=false). WHERE por ids (V69) sobre area_id.',
    '/areas/reporte', 'SELECT', 'POST',
    (SELECT id_microservice FROM public.microservice WHERE serviceid = 'eval-col'),
    '{"BODY.FILTERS.FK_PERIODO": "BIGINT", "BODY.FILTERS.FK_AREA": "BIGINT[]", "BODY.FILTERS.FK_ASIGNATURA": "BIGINT[]", "BODY.FILTERS.FK_ESPECIALIDAD": "BIGINT[]", "BODY.FILTERS.INCLUIR_INACTIVOS": "BOOLEAN", "BODY.FILTERS.IDS": "BIGINT[]"}'
)
ON CONFLICT (uuid) DO NOTHING;

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, detail, path_template, execution_mode, http_method, microservice_id, param_types)
VALUES (
    'q-mt922y68-ywxkdbfi',
    $sql$SELECT * FROM academico_test.fn_escala_listar(
      CAST(:BODY.FILTERS.FK_PERIODO AS BIGINT),
      NULL::TEXT,
      public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
      CAST(:BODY.FILTERS.FK_NIVEL AS BIGINT),
      NULL::TEXT, NULL::TEXT,
      CAST(:BODY.FILTERS.TIPO AS TEXT)
  ) t
WHERE CAST(:BODY.FILTERS.IDS AS BIGINT[]) IS NULL
   OR t.id = ANY(CAST(:BODY.FILTERS.IDS AS BIGINT[]));$sql$,
    'postgres', false, false,
    'V135 — escalas/reporte: reusa fn_escala_listar (V42/V97) con FK_PERIODO/FK_NIVEL/TIPO, page_size NULL. WHERE por ids (V69) sobre t.id (alias de la escala_de_valoracion en la salida).',
    '/escalas/reporte', 'SELECT', 'POST',
    (SELECT id_microservice FROM public.microservice WHERE serviceid = 'eval-col'),
    '{"BODY.FILTERS.FK_PERIODO": "BIGINT", "BODY.FILTERS.FK_NIVEL": "BIGINT", "BODY.FILTERS.TIPO": "TEXT", "BODY.FILTERS.IDS": "BIGINT[]"}'
)
ON CONFLICT (uuid) DO NOTHING;

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, detail, path_template, execution_mode, http_method, microservice_id, param_types)
VALUES (
    'q-mt925c80-zy0mfug8',
    $sql$SELECT * FROM academico_test.fn_plan_reporte_listar(
      CAST(:BODY.FILTERS.FK_PERIODO AS BIGINT),
      CAST(:BODY.FILTERS.FK_GRADO AS BIGINT[]),
      CAST(:BODY.FILTERS.FK_ASIGNATURA AS BIGINT[]),
      CAST(:BODY.FILTERS.FK_ESPECIALIDAD AS BIGINT[]),
      public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
      NULL::INTEGER, NULL::INTEGER
  ) t
WHERE CAST(:BODY.FILTERS.IDS AS BIGINT[]) IS NULL
   OR t.id = ANY(CAST(:BODY.FILTERS.IDS AS BIGINT[]));$sql$,
    'postgres', false, false,
    'V135 — plan-estudio/reporte: una fila por (grado, asignatura, plan). Reusa fn_plan_reporte_listar (V136) con FK_PERIODO/FK_GRADO[]/FK_ASIGNATURA[]/FK_ESPECIALIDAD[]. page_size NULL. WHERE por ids (V69) sobre t.id (= PK_TASIGNATURA_PLAN).',
    '/plan-estudio/reporte', 'SELECT', 'POST',
    (SELECT id_microservice FROM public.microservice WHERE serviceid = 'eval-col'),
    '{"BODY.FILTERS.FK_PERIODO": "BIGINT", "BODY.FILTERS.FK_GRADO": "BIGINT[]", "BODY.FILTERS.FK_ASIGNATURA": "BIGINT[]", "BODY.FILTERS.FK_ESPECIALIDAD": "BIGINT[]", "BODY.FILTERS.IDS": "BIGINT[]"}'
)
ON CONFLICT (uuid) DO NOTHING;

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, detail, path_template, execution_mode, http_method, microservice_id, param_types)
VALUES (
    'q-mt9263nn-nagskpcd',
    $sql$SELECT * FROM academico_test.fn_grado_grupo_reporte_listar(
      CAST(:BODY.FILTERS.FK_PERIODO AS BIGINT),
      CAST(:BODY.FILTERS.FK_GRADO AS BIGINT[]),
      public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
      NULL::INTEGER, NULL::INTEGER
  ) t
WHERE (CAST(:BODY.FILTERS.IDS AS BIGINT[]) IS NULL
       OR t.grado_id = ANY(CAST(:BODY.FILTERS.IDS AS BIGINT[])))
  AND (CAST(:BODY.FILTERS.GRUPO_IDS AS BIGINT[]) IS NULL
       OR t.grupo_id = ANY(CAST(:BODY.FILTERS.GRUPO_IDS AS BIGINT[])));$sql$,
    'postgres', false, false,
    'V135 — grados/reporte: una fila por (grado, grupo) con director, jornada y plan. fn_grado_grupo_reporte_listar (V135) usa LEFT JOIN contra TGRUPO, de modo que grados sin grupos cargados aparecen igual. WHERE por ids (V69) sobre grado_id (la pantalla tilda GRADOS, no grupos — filtrar por grado deja "una fila por grupo" sin perder filas del grado tildado).',
    '/grados/reporte', 'SELECT', 'POST',
    (SELECT id_microservice FROM public.microservice WHERE serviceid = 'eval-col'),
    '{"BODY.FILTERS.FK_PERIODO": "BIGINT", "BODY.FILTERS.FK_GRADO": "BIGINT[]", "BODY.FILTERS.IDS": "BIGINT[]", "BODY.FILTERS.GRUPO_IDS": "BIGINT[]"}'
)
ON CONFLICT (uuid) DO NOTHING;

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, detail, path_template, execution_mode, http_method, microservice_id, param_types)
VALUES (
    'q-mt91xbrs-geg8uo0r',
    $sql$SELECT * FROM academico_test.fn_asignacion_reporte_listar(
      CAST(:BODY.FILTERS.FK_PERIODO AS BIGINT),
      CAST(:BODY.FILTERS.FK_FUNCIONARIO AS BIGINT[]),
      CAST(:BODY.FILTERS.FK_GRADO AS BIGINT[]),
      CAST(:BODY.FILTERS.FK_ASIGNATURA AS BIGINT[]),
      CAST(:BODY.FILTERS.FK_JORNADA AS BIGINT[]),
      CAST(:BODY.FILTERS.ESTADO AS TEXT),
      public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
      NULL::INTEGER, NULL::INTEGER
  ) t
WHERE CAST(:BODY.FILTERS.IDS AS BIGINT[]) IS NULL
   OR t.docente_id = ANY(CAST(:BODY.FILTERS.IDS AS BIGINT[]));$sql$,
    'postgres', false, false,
    'V135 — asignaciones/reporte: una fila por asignacion docente-grado-grupo-asignatura-jornada. LEFT JOIN TSEDE_USUARIO filtra solo docentes con sede activa (rol Docente=14). WHERE por ids (V69) sobre docente_id.',
    '/asignaciones/reporte', 'SELECT', 'POST',
    (SELECT id_microservice FROM public.microservice WHERE serviceid = 'eval-col'),
    '{"BODY.FILTERS.FK_PERIODO": "BIGINT", "BODY.FILTERS.FK_FUNCIONARIO": "BIGINT[]", "BODY.FILTERS.FK_GRADO": "BIGINT[]", "BODY.FILTERS.FK_ASIGNATURA": "BIGINT[]", "BODY.FILTERS.FK_JORNADA": "BIGINT[]", "BODY.FILTERS.ESTADO": "TEXT", "BODY.FILTERS.IDS": "BIGINT[]"}'
)
ON CONFLICT (uuid) DO NOTHING;

UPDATE public.query SET
    query = $sql$SELECT * FROM academico_test.fn_area_subject_reporte_listar(
      CAST(:BODY.FILTERS.FK_PERIODO AS BIGINT),
      CAST(:BODY.FILTERS.FK_AREA AS BIGINT[]),
      CAST(:BODY.FILTERS.FK_ASIGNATURA AS BIGINT[]),
      CAST(:BODY.FILTERS.FK_ESPECIALIDAD AS BIGINT[]),
      CAST(:BODY.FILTERS.INCLUIR_INACTIVOS AS BOOLEAN),
      public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
      NULL::INTEGER, NULL::INTEGER
  ) t
WHERE CAST(:BODY.FILTERS.IDS AS BIGINT[]) IS NULL
   OR t.area_id = ANY(CAST(:BODY.FILTERS.IDS AS BIGINT[]))$sql$,
    param_types = param_types || '{"BODY.FILTERS.IDS": "BIGINT[]"}'::JSONB
 WHERE uuid = 'q-mt9244pe-lfglm5gw';

UPDATE public.query SET
    query = $sql$SELECT * FROM academico_test.fn_escala_listar(
      CAST(:BODY.FILTERS.FK_PERIODO AS BIGINT),
      NULL::TEXT,
      public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
      CAST(:BODY.FILTERS.FK_NIVEL AS BIGINT),
      NULL::TEXT, NULL::TEXT,
      CAST(:BODY.FILTERS.TIPO AS TEXT)
  ) t
WHERE CAST(:BODY.FILTERS.IDS AS BIGINT[]) IS NULL
   OR t.id = ANY(CAST(:BODY.FILTERS.IDS AS BIGINT[]))$sql$,
    param_types = param_types || '{"BODY.FILTERS.IDS": "BIGINT[]"}'::JSONB
 WHERE uuid = 'q-mt922y68-ywxkdbfi';

UPDATE public.query SET
    query = $sql$SELECT * FROM academico_test.fn_plan_reporte_listar(
      CAST(:BODY.FILTERS.FK_PERIODO AS BIGINT),
      CAST(:BODY.FILTERS.FK_GRADO AS BIGINT[]),
      CAST(:BODY.FILTERS.FK_ASIGNATURA AS BIGINT[]),
      CAST(:BODY.FILTERS.FK_ESPECIALIDAD AS BIGINT[]),
      public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
      NULL::INTEGER, NULL::INTEGER
  ) t
WHERE CAST(:BODY.FILTERS.IDS AS BIGINT[]) IS NULL
   OR t.id = ANY(CAST(:BODY.FILTERS.IDS AS BIGINT[]))$sql$,
    param_types = param_types || '{"BODY.FILTERS.IDS": "BIGINT[]"}'::JSONB
 WHERE uuid = 'q-mt925c80-zy0mfug8';

UPDATE public.query SET
    query = $sql$SELECT * FROM academico_test.fn_grado_grupo_reporte_listar(
      CAST(:BODY.FILTERS.FK_PERIODO AS BIGINT),
      CAST(:BODY.FILTERS.FK_GRADO AS BIGINT[]),
      public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
      NULL::INTEGER, NULL::INTEGER
  ) t
WHERE (CAST(:BODY.FILTERS.IDS AS BIGINT[]) IS NULL
       OR t.grado_id = ANY(CAST(:BODY.FILTERS.IDS AS BIGINT[])))
  AND (CAST(:BODY.FILTERS.GRUPO_IDS AS BIGINT[]) IS NULL
       OR t.grupo_id = ANY(CAST(:BODY.FILTERS.GRUPO_IDS AS BIGINT[])))$sql$,
    param_types = param_types || '{"BODY.FILTERS.IDS": "BIGINT[]", "BODY.FILTERS.GRUPO_IDS": "BIGINT[]"}'::JSONB
 WHERE uuid = 'q-mt9263nn-nagskpcd';

UPDATE public.query SET
    query = $sql$SELECT * FROM academico_test.fn_asignacion_reporte_listar(
      CAST(:BODY.FILTERS.FK_PERIODO AS BIGINT),
      CAST(:BODY.FILTERS.FK_FUNCIONARIO AS BIGINT[]),
      CAST(:BODY.FILTERS.FK_GRADO AS BIGINT[]),
      CAST(:BODY.FILTERS.FK_ASIGNATURA AS BIGINT[]),
      CAST(:BODY.FILTERS.FK_JORNADA AS BIGINT[]),
      CAST(:BODY.FILTERS.ESTADO AS TEXT),
      public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
      NULL::INTEGER, NULL::INTEGER
  ) t
WHERE CAST(:BODY.FILTERS.IDS AS BIGINT[]) IS NULL
   OR t.docente_id = ANY(CAST(:BODY.FILTERS.IDS AS BIGINT[]))$sql$,
    param_types = param_types || '{"BODY.FILTERS.IDS": "BIGINT[]"}'::JSONB
 WHERE uuid = 'q-mt91xbrs-geg8uo0r';

INSERT INTO public.role_query (query_id, role_id)
SELECT reporte.id_query, rq.role_id
  FROM public.query reporte
  JOIN (VALUES
        ('q-mt9244pe-lfglm5gw', '/areas/query'),
        ('q-mt922y68-ywxkdbfi', '/escalas/query'),
        ('q-mt925c80-zy0mfug8', '/plan-asignaturas-disponibles/query'),
        ('q-mt9263nn-nagskpcd', '/grados/query'),
        ('q-mt91xbrs-geg8uo0r', '/asignaciones/query')
       ) AS m (uuid_reporte, path_listado)
    ON reporte.uuid = m.uuid_reporte
  JOIN public.query listado
    ON listado.path_template = m.path_listado
   AND listado.http_method   = 'POST'
  JOIN public.role_query rq ON rq.query_id = listado.id_query
ON CONFLICT (query_id, role_id) DO NOTHING;
