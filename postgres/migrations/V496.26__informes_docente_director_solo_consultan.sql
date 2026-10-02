-- ===========================================================================
-- V496.26 - Docente y Director de Grupo solo consultan Informes (Regla 76).
--
--   fn_informe_assert_puede_escribir  42501 si el usuario solo tiene roles
--                                     de grupo (fn_usuario_solo_sus_grupos)
--   role_query / role_endpoint        sin CEVAL-DOCENTE ni
--                                     CEVAL-DIRECTOR_GRUPO en las escrituras
--
-- Las 7 escrituras lo llaman tras su gate EDITAR/ELIMINAR (V490, V496.24).
-- No depende de la casilla SOLO_LECTURA: fn_usuario_permisos_menu (V303)
-- concede editar si CUALQUIER rol del usuario lo concede.
-- Depende de: V489 (fn_usuario_solo_sus_grupos), V342-V496.24 (endpoints).
-- ===========================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_informe_assert_puede_escribir(
    p_pk_usuario_solicitante BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $function$
BEGIN
    IF academico_test.fn_usuario_solo_sus_grupos(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario solo puede consultar los informes'
            USING ERRCODE = '42501',
                  HINT    = 'Docente y Director de Grupo consultan los informes de sus grupos; guardarlos corresponde al coordinador o al rector';
    END IF;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_assert_puede_escribir(BIGINT)
    IS 'Gate de escritura de Informes (Regla 76): 42501 cuando el usuario solo tiene roles que dan acceso por grupo (DOCENTE, DIRECTOR_GRUPO; ver fn_usuario_solo_sus_grupos y fn_rol_alcance_sede, V489). Se llama DESPUES de fn_assert_permiso_seccion EDITAR/ELIMINAR en las 7 escrituras de informes, y no depende de TROL_MENU.SOLO_LECTURA. Un usuario sin TSEDE_USUARIO activo (super admin) pasa. V496.26.';

-- Endpoints de escritura: el gateway deja de aceptarlos para estos roles.
DELETE FROM public.role_query rq
 USING public.query q, public.microservice m, public.role r
 WHERE rq.query_id        = q.id_query
   AND rq.role_id         = r.id_role
   AND q.microservice_id  = m.id_microservice
   AND m.serviceid        = 'eval-col'
   AND q.http_method      = 'POST'
   AND q.path_template IN ('/informes/guardar',
                           '/informes/planilla/guardar',
                           '/informes/final/guardar',
                           '/informes/observacion/guardar',
                           '/informes/observacion/eliminar',
                           '/informes/observacion/final/guardar',
                           '/informes/observacion/final/eliminar')
   AND r.name IN ('CEVAL-DOCENTE', 'CEVAL-DIRECTOR_GRUPO');

-- V487 copio a los endpoints de IA los roles de los dos guardar de observacion.
DELETE FROM public.role_endpoint re
 USING public.endpoint e, public.role r
 WHERE re.endpoint_id = e.id_endpoint
   AND re.role_id     = r.id_role
   AND e.method       = 'POST'
   AND e.path IN ('/ai/observaciones/periodo', '/ai/observaciones/anio')
   AND r.name IN ('CEVAL-DOCENTE', 'CEVAL-DIRECTOR_GRUPO');
