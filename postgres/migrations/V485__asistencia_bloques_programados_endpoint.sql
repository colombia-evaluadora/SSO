-- ===========================================================================
-- V485 -- expone los bloques reales de una sesion (grupo+asignatura+fecha).
-- Que hace: fn_asistencia_bloques_programados envuelve
--   fn_asistencia_sesiones_programadas (V457, resuelve la sede sola via
--   fn_grupo_periodo/fn_periodo_sede) y GET /asistencias/sesion/bloques la
--   expone. Sin esto, quien registra asistencia sin saber el bloque de
--   THORARIO (Planeador, que no maneja horario) tenia que mandar BLOQUE=NULL
--   -- una toma "suelta" que fn_asistencia_calendario nunca empareja con la
--   clase programada real.
-- Depende de: V220 (fn_asistencia_puede_ver, la usa fn_asistencia_sesiones_
--   programadas por dentro), V457 (la funcion que envuelve), V29/V40
--   (fn_periodo_sede/fn_grupo_periodo).
-- ===========================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_bloques_programados(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tgrupo              BIGINT,
    p_fk_tasignatura         BIGINT,
    p_fecha                  DATE
)
RETURNS TABLE(bloque NUMERIC)
LANGUAGE sql
STABLE
AS $function$
    SELECT DISTINCT sp.bloque
      FROM academico_test.fn_asistencia_sesiones_programadas(
               p_pk_usuario_solicitante,
               academico_test.fn_periodo_sede(academico_test.fn_grupo_periodo(p_fk_tgrupo)),
               p_fecha, p_fecha,
               p_fk_tgrupo, p_fk_tasignatura, NULL)
           sp
     ORDER BY sp.bloque;
$function$;

COMMENT ON FUNCTION academico_test.fn_asistencia_bloques_programados(BIGINT, BIGINT, BIGINT, DATE)
    IS 'Bloque(s) reales de THORARIO para un grupo+asignatura en una fecha puntual -- envoltorio de fn_asistencia_sesiones_programadas (mismo gate y mismas reglas de fecha registrable) filtrado a un solo dia. Lo usa quien no maneja horario (Planeador) para saber CADA bloque contra el que registrar asistencia, en vez de mandar BLOQUE=NULL y que fn_asistencia_calendario nunca lo empareje con la clase programada. Puede devolver mas de una fila (asignatura con varios bloques ese dia).';

INSERT INTO public.query (uuid, query, type, public_end, captcha, microservice_id,
                          path_template, execution_mode, http_method, param_types, detail)
SELECT
    'asis-sesion-bloques',
    $q$SELECT * FROM academico_test.fn_asistencia_bloques_programados(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.GRUPO AS BIGINT),
    CAST(:QUERY.ASIGNATURA AS BIGINT),
    CAST(:QUERY.FECHA AS DATE)
);$q$,
    'postgres', false, false, m.id_microservice,
    '/asistencias/sesion/bloques', 'SELECT', 'GET',
    '{
       "QUERY.GRUPO":      "BIGINT!",
       "QUERY.ASIGNATURA": "BIGINT!",
       "QUERY.FECHA":      "VARCHAR!"
     }'::jsonb,
    'V485 -- bloques reales de THORARIO para GRUPO+ASIGNATURA en FECHA, para registrar asistencia contra la clase programada real en vez de una toma suelta sin bloque. Puede devolver varias filas.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (uuid) DO UPDATE
   SET query = EXCLUDED.query, param_types = EXCLUDED.param_types,
       path_template = EXCLUDED.path_template, http_method = EXCLUDED.http_method,
       execution_mode = EXCLUDED.execution_mode, microservice_id = EXCLUDED.microservice_id,
       detail = EXCLUDED.detail;

-- Mismo criterio que V221, bloque 6: super admin + roles con el menu
-- ASISTENCIAS concedido (DOCENTE/RECTOR del dump base).
INSERT INTO public.role_query (role_id, query_id)
SELECT pr.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id AND m.serviceid = 'eval-col'
 CROSS JOIN LATERAL (
       SELECT 'CEVAL-SUPER_ADMINISTRADOR'::text AS rname
       UNION
       SELECT 'CEVAL-' || tr.codigo
         FROM academico_test.trol_menu rm
         JOIN academico_test.tmenu tm ON tm.pk_tmenu = rm.fk_tmenu
          AND tm.codigo = 'ASISTENCIAS' AND tm.active = TRUE
         JOIN academico_test.trol tr  ON tr.pk_trol = rm.fk_trol AND tr.active = TRUE
        WHERE rm.active = TRUE
 ) src
  JOIN public.role pr ON pr.name = src.rname
 WHERE q.uuid = 'asis-sesion-bloques'
   AND NOT EXISTS (
       SELECT 1 FROM public.role_query rq
        WHERE rq.query_id = q.id_query AND rq.role_id = pr.id_role
   );
