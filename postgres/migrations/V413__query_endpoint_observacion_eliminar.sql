-- ===========================================================================
-- V413 - Endpoint que faltaba: borrar el resumen de seguimiento de la IA.
--
--   POST /informes/observacion/eliminar
--       -> fn_estudiante_periodo_observacion_eliminar (V332)
--
-- POR QUE FALTABA
--   La funcion existe desde V332, pero V343 solo registro generar y guardar.
--   La pantalla ofrece quitar el resumen y hoy esa accion responde 404: no hay
--   ruta. Es la unica de las tres que quedo sin exponer.
--
-- POR QUE POST Y NO DELETE
--   Por coherencia con los otros diez endpoints del modulo, que son todos POST
--   -- cuatro reciben arreglos y en este esquema ningun GET pasa uno. Ademas
--   la clave no es un identificador en la ruta sino un PAR (matricula,
--   periodo), y meter dos identificadores en el path daria una ruta que no se
--   parece a ninguna otra del modulo.
--
--   execution_mode sigue siendo SELECT, como en el resto del esquema: la
--   funcion se invoca con SELECT aunque escriba.
--
-- EL BORRADO ES FISICO, Y ESO IMPORTA PARA EL FRONT
--   No es baja logica. Dos razones, ambas en el comentario de la funcion: el
--   indice unico de TESTUDIANTE_PERIODO_OBSERVACION es TOTAL sobre (matricula,
--   periodo), asi que una fila inactiva seguiria ocupando el lugar e impediria
--   guardar un resumen nuevo; y no hay nada que conservar, porque el resumen
--   se puede volver a generar desde las TACTIVIDAD_NOTA.OBSERVACION, que son
--   el dato original.
--
--   Consecuencia practica: despues de eliminar, el listado del grupo vuelve a
--   traer OBSERVACION y OBSERVACION_ESTADO en NULL, exactamente como antes de
--   generar por primera vez.
--
-- QUIEN PUEDE
--   El reparto estrecho, el mismo de /informes/guardar y
--   /informes/observacion/guardar. El gate de la funcion es INFORMES/ELIMINAR,
--   que es mas exigente que el EDITAR de guardar: rehacer un resumen es
--   corregir, borrarlo es deshacer.
--
-- Idempotente: ON CONFLICT DO NOTHING.
-- ===========================================================================


INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action, style)
SELECT
    'eval-col-informes-observacion-eliminar-001',
    'SELECT academico_test.fn_estudiante_periodo_observacion_eliminar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FK_TMATRICULA AS BIGINT),
    CAST(:BODY.FK_TPERIODO_EVALUACION AS BIGINT)
) AS pk_testudiante_periodo_observacion;',
    'postgres', false, false,
    m.id_microservice,
    '/informes/observacion/eliminar', 'SELECT', 'POST',
    '{"BODY.FK_TMATRICULA": "BIGINT", "BODY.FK_TPERIODO_EVALUACION": "BIGINT"}'::jsonb,
    NULL,
    'Quita el resumen de seguimiento guardado de un estudiante en un periodo. Devuelve el PK de la fila eliminada. EL BORRADO ES FISICO, no baja logica: el indice unico de TESTUDIANTE_PERIODO_OBSERVACION es total sobre (matricula, periodo), de modo que una fila inactiva seguiria ocupando el lugar e impediria guardar un resumen nuevo; y no hay nada que conservar, porque el resumen se puede volver a generar desde las TACTIVIDAD_NOTA.OBSERVACION, que son el dato original. Despues de eliminar, /informes/grupo vuelve a traer OBSERVACION y OBSERVACION_ESTADO en NULL, igual que antes de generar por primera vez. Es POST y no DELETE por coherencia con los demas endpoints del modulo y porque la clave es un PAR (matricula, periodo), no un identificador de ruta. Errores: 404 si no hay resumen guardado para ese estudiante en ese periodo; 403 si el usuario no alcanza el grupo. Gate: INFORMES/ELIMINAR -- mas exigente que el EDITAR de guardar, porque rehacer un resumen es corregir y borrarlo es deshacer.',
    'informes-observacion-eliminar', 'DEFAULT'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;


INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN (
        'CEVAL-AUXILIAR_ADMINISTRATIVO',
        'CEVAL-COORDINADOR',
        'CEVAL-DOCENTE',
        'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL',
        'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO',
        'CEVAL-RECTOR',
        'CEVAL-SUPER_ADMINISTRADOR',
        'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/informes/observacion/eliminar'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;
