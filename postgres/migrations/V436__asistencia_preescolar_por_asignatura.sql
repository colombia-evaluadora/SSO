-- ===========================================================================
-- V436 - Asistencia de preescolar por asignatura: fn_asistencia_grupo_es_
-- formativo, el filtro de busqueda de seguimiento y su restriccion.
-- fn_asistencia_listar_seguimiento vive hoy en V438.
-- ===========================================================================


CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_grupo_es_formativo(
    p_fk_tgrupo BIGINT
)
RETURNS BOOLEAN
LANGUAGE sql STABLE PARALLEL SAFE AS $$
    -- p_fk_tgrupo se ignora a proposito: la firma se conserva para no tocar
    -- a los llamadores mientras el modo por actividad siga en pie.
    SELECT FALSE;
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_grupo_es_formativo(BIGINT)
    IS 'Devuelve FALSE siempre: ningun grupo toma asistencia por ACTIVIDAD. Preescolar pasa a la sesion por asignatura + bloque de horario (THORARIO), igual que el resto de niveles. Antes discriminaba por TNIVEL_ENSENANZA.CODIGO = ''1''. El modo formativo NO se elimino -- siguen en pie la columna TASISTENCIA.FK_TACTIVIDAD, CK_TASISTENCIA_CONTEXTO, los parametros p_fk_tactividad de fn_asistencia_registrar_bulk / fn_asistencia_estudiantes_sesion / fn_asistencia_listar_seguimiento y la rama formativa de fn_asistencia_calendario: quedan inalcanzables mientras esta funcion devuelva FALSE. Para revertir, reponer el cuerpo de V220 (el SELECT sobre TGRUPO -> TGRADO -> TNIVEL_ENSENANZA).';

UPDATE public.query
   SET query = replace(
           query,
           '    p_search          => CAST(:BODY.FILTERS.SEARCH AS TEXT),',
           '    p_search          => CAST(:BODY.FILTERS.SEARCH AS TEXT),' || chr(10) ||
           '    p_jornada         => CAST(:BODY.FILTERS.JORNADA AS TEXT),' || chr(10) ||
           '    p_grado           => CAST(:BODY.FILTERS.GRADO AS TEXT),'),
       param_types = param_types || '{"BODY.FILTERS.JORNADA": "VARCHAR",
                                      "BODY.FILTERS.GRADO":   "VARCHAR"}'::JSONB
 WHERE uuid IN ('asis-seguimiento', 'eval-col-asistencias-seguimiento-export-all-001')
   AND query LIKE '%p_search          => CAST(:BODY.FILTERS.SEARCH AS TEXT),%'
   AND query NOT LIKE '%p_jornada%';

INSERT INTO public.query_param_constraint
       (query_id, param_key, only_positive, allow_decimals, max_digits,
        numeric_text, min_length, max_length, min_value, max_value)
SELECT q.id_query, c.param_key, NULL::boolean, NULL::boolean, NULL::integer,
       FALSE, NULL::integer, c.max_length, NULL::numeric, NULL::numeric
  FROM public.query q
  CROSS JOIN (VALUES
      ('BODY.FILTERS.JORNADA', 60),
      ('BODY.FILTERS.GRADO',   60)
  ) AS c(param_key, max_length)
 WHERE q.uuid IN ('asis-seguimiento', 'eval-col-asistencias-seguimiento-export-all-001')
ON CONFLICT (query_id, param_key) DO UPDATE
   SET max_length = EXCLUDED.max_length,
       numeric_text = EXCLUDED.numeric_text;
