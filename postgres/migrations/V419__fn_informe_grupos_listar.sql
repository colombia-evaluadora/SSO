-- ===========================================================================
-- V419 - Endpoint GET de grupos de informes (fila public.query + roles).
-- La funcion fn_informe_grupos_listar vive en V490; su COMMENT en V491.1.
-- ===========================================================================


INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action, style)
SELECT
    'eval-col-informes-grupos-periodo-001',
    'SELECT * FROM academico_test.fn_informe_grupos_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FK_TSEDE AS BIGINT),
    CAST(:BODY.ANIO AS INTEGER),
    CAST(:BODY.FK_TLV_JORNADA AS BIGINT),
    CAST(:BODY.SEARCH AS VARCHAR)
);',
    'postgres', false, false,
    m.id_microservice,
    '/informes/grupos-periodo', 'SELECT', 'POST',
    '{"BODY.FK_TSEDE": "BIGINT", "BODY.ANIO": "INTEGER", "BODY.FK_TLV_JORNADA": "BIGINT", "BODY.SEARCH": "VARCHAR"}'::jsonb,
    NULL,
    'Los grupos del periodo academico que resuelven la sede, el año y la jornada elegidos en los tres selects de la pantalla. Reemplaza el uso que la vista de informes hacia de GET /planeador/docentes/grupos, que exigia permiso de PLANEADOR y ademas solo devolvia los grupos donde el docente dicta -- con lo cual un rector o una secretaria no veian ninguno. Aqui no se filtra por quien dicta: eso lo decide el permiso INFORMES/VER con alcance de sede y jornada. Cada fila trae la etiqueta ya armada ("Quinto A"), el conteo de matriculas activas, el director de grupo si lo hay y la jornada del propio grupo, que en los años viejos no coincide con la del periodo academico. SEARCH filtra por nombre y codigo de grupo, nombre de grado y la etiqueta compuesta. Responde 42501 si el usuario no alcanza esa sede y jornada, y P0002 si no hay periodo academico para esa combinacion.',
    'informes-grupos-periodo', 'DEFAULT'
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
   AND q.http_method   = 'POST'
   AND q.path_template = '/informes/grupos-periodo'
ON CONFLICT DO NOTHING;
