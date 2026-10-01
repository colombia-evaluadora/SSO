-- ===========================================================================
-- V349 - Endpoint GET del historial de informes (fila public.query + roles).
-- La funcion fn_informe_historial_listar vive en V491; su COMMENT en V491.1.
-- ===========================================================================


INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action, style)
SELECT
    'eval-col-informes-historial-listar-001',
    'SELECT * FROM academico_test.fn_informe_historial_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.GRUPOS AS BIGINT[]),
    CAST(:BODY.PERIODOS AS BIGINT[]),
    CAST(:BODY.ANIO AS INTEGER),
    CAST(:BODY.LIMITE AS INTEGER)
);',
    'postgres', false, false,
    m.id_microservice,
    '/informes/historial', 'SELECT', 'POST',
    '{"BODY.GRUPOS": "BIGINT[]", "BODY.PERIODOS": "BIGINT[]", "BODY.ANIO": "INTEGER", "BODY.LIMITE": "INTEGER"}'::jsonb,
    NULL,
    'Historial de guardados del modulo de informes: una fila por guardado, de mas reciente a mas antiguo, con FECHA aparte del MOMENTO para agrupar por dia en el front. Trae grupo, asignatura (NULL = informe completo; con valor = una sola asignatura desde la planilla), periodo, quien lo hizo, cuantos estudiantes y el detalle en JSONB con nombre, documento y promedio de cada uno. El conteo es POR ESTUDIANTE: un estudiante guardado es un cambio, asi que guardar un curso de 30 son 30 cambios. Solo aparecen los dias con movimiento, porque solo se registran guardados que escribieron algo -- volver a pulsar guardar sin cambios no deja entrada. El promedio del detalle es el del momento del guardado y no se recalcula: el historial dice que paso ese dia. Todos los parametros son OPCIONALES: sin nada devuelve el ano lectivo en curso dentro del alcance del usuario, que es lo que hace la pantalla al abrirse; GRUPOS, PERIODOS y ANIO solo acotan, y LIMITE tope por defecto 100 porque el modal es una lista con scroll, no una tabla paginada. No devuelve flecha de subida o bajada: un guardado abarca varios estudiantes y a unos les puede subir la nota y a otros bajarsela.',
    'informes-historial-listar', 'DEFAULT'
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
        'CEVAL-DIRECTOR_GRUPO',
        'CEVAL-DOCENTE',
        'CEVAL-JEFE_AREA',
        'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL',
        'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO',
        'CEVAL-PSICO_ORIENTADOR',
        'CEVAL-RECTOR',
        'CEVAL-SUPER_ADMINISTRADOR',
        'SSO-ADMIN')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/informes/historial'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;
