-- ===========================================================================
-- V417 - informes cascada sede ano jornada
-- Recortada: las funciones de informes que V535-V541 reescriben en capas
-- se quitaron de aqui y viven alli. Queda lo que sigue vivo y lo que una
-- base limpia necesita al migrar (CREATE solo si la funcion no existe).
-- ===========================================================================


CREATE OR REPLACE FUNCTION academico_test.fn_anio_lectivo_numero(
    p_nombre VARCHAR
)
RETURNS INTEGER
LANGUAGE sql
IMMUTABLE
AS $function$
    SELECT CASE WHEN p_nombre ~ '^[0-9]{4}$' THEN p_nombre::INTEGER END;
$function$;

COMMENT ON FUNCTION academico_test.fn_anio_lectivo_numero(VARCHAR)
    IS 'TANO_LECTIVO.NOMBRE como numero, o NULL si no es un año de cuatro digitos. Existe porque escribir el guard y el cast como dos condiciones de la misma calificacion ("NOMBRE ~ ... AND NOMBRE::INTEGER = x") no garantiza el orden de evaluacion: el planificador puede hacer el cast primero y una sola fila sucia tumba la consulta con 22P02, cosa que ya paso en este esquema. Dentro de un CASE el orden si esta garantizado y la fila sucia sale como NULL, que en cualquier comparacion es simplemente una fila que no entra. IMMUTABLE para que se pueda usar en indices y el planificador la pliegue. V417.';

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action, style)
SELECT
    'eval-col-informes-sedes-listar-001',
    'SELECT * FROM academico_test.fn_informe_sedes_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/informes/sedes', 'SELECT', 'POST',
    '{}'::jsonb,
    NULL,
    'Primer select de la pantalla de informes: las sedes que el usuario alcanza y que tienen algun periodo academico activo del año en curso o anterior. No recibe parametros -- el alcance sale de quien pregunta, no del cuerpo, para que no se pueda pedir una sede ajena y descubrirla por la respuesta vacia. Devuelve tambien el establecimiento, porque quien alcanza varios necesita distinguir sedes de nombre parecido.',
    'informes-sedes-listar', 'DEFAULT'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action, style)
SELECT
    'eval-col-informes-anos-listar-001',
    'SELECT * FROM academico_test.fn_informe_anos_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FK_TSEDE AS BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/informes/anos', 'SELECT', 'POST',
    '{"BODY.FK_TSEDE": "BIGINT"}'::jsonb,
    NULL,
    'Segundo select de la pantalla de informes: los años lectivos con periodos academicos activos en esa sede, del año en curso hacia atras. Los años futuros no se ofrecen aunque existan periodos creados (hay para 2027, 2028 y 2029): son configuracion adelantada, no años sobre los que pedir informes. FK_TSEDE acota y nunca amplia -- una sede fuera del alcance devuelve lista vacia. Sin FK_TSEDE devuelve los años de todo el alcance, util si el front quiere precargar.',
    'informes-anos-listar', 'DEFAULT'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action, style)
SELECT
    'eval-col-informes-jornadas-listar-001',
    'SELECT * FROM academico_test.fn_informe_jornadas_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FK_TSEDE AS BIGINT),
    CAST(:BODY.ANIO AS INTEGER)
);',
    'postgres', false, false,
    m.id_microservice,
    '/informes/jornadas', 'SELECT', 'POST',
    '{"BODY.FK_TSEDE": "BIGINT", "BODY.ANIO": "INTEGER"}'::jsonb,
    NULL,
    'Tercer select de la pantalla de informes: las jornadas con periodo academico activo en esa sede y ese año. Devuelve una fila por PERIODO ACADEMICO, no una por jornada distinta: hoy la tripleta (sede, año, jornada) identifica un solo periodo entre las sedes activas, pero ningun indice lo garantiza y en el historico paso 24 veces, asi que ese caso se ve en pantalla en vez de resolverse en silencio. Cada fila trae FK_TPERIODO_ACADEMICO, por si el front prefiere mandar esa PK directamente en vez de la tripleta. Sin ANIO se toma el año en curso.',
    'informes-jornadas-listar', 'DEFAULT'
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
 WHERE m.serviceid   = 'eval-col'
   AND q.http_method = 'POST'
   AND q.path_template IN ('/informes/sedes',
                           '/informes/anos',
                           '/informes/jornadas')
ON CONFLICT DO NOTHING;
