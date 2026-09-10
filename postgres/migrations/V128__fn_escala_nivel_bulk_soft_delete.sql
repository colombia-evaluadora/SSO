-- ===========================================================================
-- V128 - drift de funcion: academico_test.fn_escala_nivel_bulk_soft_delete.
--
-- QUE ES ESTO
--   La funcion existe y esta en uso en el servidor de test (la invoca
--   POST /escalas/bulk-delete, registrado mas abajo), pero NO esta definida en
--   ninguna migracion de ninguna rama de origin: se aplico a mano contra la
--   base. Sobre un entorno limpio el endpoint existiria y fallaria en tiempo
--   de ejecucion con 42883 (undefined function).
--
--   El cuerpo de aqui es el volcado literal de pg_get_functiondef contra el
--   servidor, sin reescribir: el objetivo es versionar lo que YA corre, no
--   cambiarlo. Cualquier mejora va en una migracion posterior.
--
-- QUE HACE
--   Borrado logico masivo de niveles de escala de valoracion dentro de un
--   periodo academico. Un unico gate de escritura al principio
--   (fn_periodo_gate_escritura, V40) y luego delega elemento a elemento en
--   fn_escala_nivel_soft_delete (V42/V105) capturando el error de cada uno,
--   asi que devuelve una fila por id con {eliminado, error_code,
--   error_mensaje} en vez de abortar el lote entero. Mismo patron que los
--   otros bulk-delete del modulo (V105/V106/V107).
--
-- NUMERACION
--   Hueco libre V128, verificado contra TODAS las ramas de origin. Va por
--   encima de V105 (que define fn_escala_valoracion_bulk_delete, su hermana) y
--   de V42 (fn_escala_nivel_soft_delete, a la que delega), y por debajo de
--   V129, que registra el resto del drift del catalogo.
-- ===========================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_escala_nivel_bulk_soft_delete(p_academic_period_id bigint, p_teaching_level_ids bigint[], p_pk_usuario_solicitante bigint)
 RETURNS TABLE(id bigint, eliminado boolean, error_code text, error_mensaje text)
 LANGUAGE plpgsql
AS $function$
DECLARE v_id BIGINT; v_state TEXT; v_msg TEXT;
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, academico_test.fn_periodo_establecimiento(p_academic_period_id));
    IF p_teaching_level_ids IS NULL THEN RETURN; END IF;
    FOREACH v_id IN ARRAY p_teaching_level_ids LOOP
        BEGIN
            PERFORM academico_test.fn_escala_nivel_soft_delete(
                p_academic_period_id, v_id, p_pk_usuario_solicitante);
            id := v_id; eliminado := TRUE; error_code := NULL; error_mensaje := NULL;
            RETURN NEXT;
        EXCEPTION WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
            id := v_id; eliminado := FALSE; error_code := v_state; error_mensaje := v_msg;
            RETURN NEXT;
        END;
    END LOOP;
    RETURN;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_escala_nivel_bulk_soft_delete(BIGINT, BIGINT[], BIGINT)
    IS 'Borrado logico masivo de niveles de escala de valoracion de un periodo academico. Un solo gate de escritura (fn_periodo_gate_escritura) y luego delega por elemento en fn_escala_nivel_soft_delete capturando la excepcion de cada uno: devuelve una fila por id con eliminado/error_code/error_mensaje en vez de abortar el lote. Versionada en V128 a partir del volcado del servidor de test, donde se habia aplicado a mano.';

-- ---------------------------------------------------------------------------
-- POST /escalas/bulk-delete: el endpoint que la invoca, tambien ausente de
-- toda migracion.
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-msp2s4x0-kdbqdoyv',
    'SELECT * FROM academico_test.fn_escala_nivel_bulk_soft_delete(
    CAST(:BODY.PERIODO_ACADEMICO_ID AS BIGINT),
    CAST(:BODY.IDS AS BIGINT[]),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/escalas/bulk-delete', 'SELECT', 'POST',
    '{"BODY.IDS": "BIGINT[]", "BODY.PERIODO_ACADEMICO_ID": "BIGINT"}'::jsonb,
    NULL,
    NULL,
    NULL, NULL,
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-COORDINADOR', 'CEVAL-DIRECTOR_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-RECTOR', 'CEVAL-SUPER_ADMINISTRADOR', 'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/escalas/bulk-delete'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;
