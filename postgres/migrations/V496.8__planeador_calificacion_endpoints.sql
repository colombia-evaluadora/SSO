-- V496.8 - Calificación de actividades: endpoints (4 de 4).
-- Define en un solo sitio las filas de calificar (individual y en bloque), la
-- nota de un estudiante y el listado de calificaciones, con upsert que
-- conserva el id y con él sus role_query. Las consultas no cambian; el detail
-- describe el contrato vigente (Reglas 42 y 54). Roles: DOCENTE y
-- SUPER_ADMINISTRADOR, los que ya tenían. Los INSERT originales siguen en V247.
-- Depende de: V496.7 (wrappers), V247 (filas).

SET search_path TO academico_test, public;

-- GET /planeador/actividades/:ID/calificaciones
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT '5cda6361-6ade-4bb8-8907-8677b0ff25d5', m.id_microservice, '/planeador/actividades/:ID/calificaciones', 'GET', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL,
       '{"PARAM.ID": "BIGINT", "QUERY.FECHA": "DATE", "QUERY.SEARCH": "VARCHAR"}'::jsonb,
       'Tabla "Calificaciones: <actividad>" de la actividad :ID (fn_actividad_estudiantes_calificaciones_listar): un renglón por estudiante asignado con su asistencia de ?fecha= (por defecto hoy), fecha_asistencia (el día que habilita calificar u observar), nota en % y homologada, es_formativa (se registra con observación) y resultado_instrumento. ?search= filtra por nombre. Errores: 404 (P0002); 400 (22023) si fue eliminada; 403 (42501) sin alcance o si un docente consulta una actividad que no creó (Regla 54).',
       $q$SELECT * FROM academico_test.fn_actividad_estudiantes_calificaciones_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    COALESCE(CAST(:QUERY.FECHA AS DATE), CURRENT_DATE),
    CAST(:QUERY.SEARCH AS VARCHAR)
);$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- PUT /planeador/actividades/:ID/calificar-bulk/cotejo
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT '14678565-ec76-49f2-b339-3d0feec788cd', m.id_microservice, '/planeador/actividades/:ID/calificar-bulk/cotejo', 'PUT', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL,
       '{"PARAM.ID": "BIGINT", "BODY.FECHA": "DATE", "BODY.PK_ITEM": "BIGINT", "BODY.CUMPLIDO": "VARCHAR", "BODY.ESTUDIANTES": "BIGINT[]"}'::jsonb,
       'Marca un elemento de la lista de cotejo como Cumple (S) o No cumple (N) para varios estudiantes de la actividad :ID (fn_actividad_nota_calificar_cotejo_bulk). BODY.PK_ITEM, BODY.CUMPLIDO, BODY.ESTUDIANTES, BODY.FECHA. Recalcula la nota en la misma pasada (un elemento sin marcar cuenta como No cumple). Errores: 404 (P0002) si la actividad o la asignación no existe; 400 (22023) si la actividad fue eliminada, es formativa, no tiene instrumento, el estudiante no es de la actividad, no tiene asistencia válida ese día o el valor no cumple el instrumento; 403 (42501) sin alcance o si un docente califica una actividad que no creó (Regla 54).',
       $q$SELECT * FROM academico_test.fn_actividad_nota_calificar_cotejo_bulk(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.PK_ITEM AS BIGINT),
    CAST(:BODY.CUMPLIDO AS CHAR(1)),
    CAST(:BODY.ESTUDIANTES AS BIGINT[]),
    COALESCE(CAST(:BODY.FECHA AS DATE), CURRENT_DATE)
);$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- PUT /planeador/actividades/:ID/calificar-bulk/escala
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT '217f8ddb-9838-4bb6-a44b-dc415741e964', m.id_microservice, '/planeador/actividades/:ID/calificar-bulk/escala', 'PUT', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL,
       '{"PARAM.ID": "BIGINT", "BODY.FECHA": "DATE", "BODY.PK_NIVEL": "BIGINT", "BODY.CRITERIOS": "JSONB", "BODY.ESTUDIANTES": "BIGINT[]", "BODY.VALOR_NUMERICO": "NUMERIC"}'::jsonb,
       'Califica con la escala de valoración a varios estudiantes de la actividad :ID (fn_actividad_nota_calificar_escala_bulk). BODY.CRITERIOS [{criterioIndex,pkNivel|valorNumerico}] uno por criterio, o BODY.PK_NIVEL / BODY.VALOR_NUMERICO suelto, que con varios criterios se aplica a cada uno; BODY.ESTUDIANTES y BODY.FECHA. Devuelve {pk_tactividad_estudiante, calificacion}. Errores: 404 (P0002) si la actividad o la asignación no existe; 400 (22023) si la actividad fue eliminada, es formativa, no tiene instrumento, el estudiante no es de la actividad, no tiene asistencia válida ese día o el valor no cumple el instrumento; 403 (42501) sin alcance o si un docente califica una actividad que no creó (Regla 54).',
       $q$SELECT * FROM academico_test.fn_actividad_nota_calificar_escala_bulk(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.PK_NIVEL AS BIGINT),
    CAST(:BODY.VALOR_NUMERICO AS NUMERIC),
    CAST(:BODY.CRITERIOS AS JSONB),
    CAST(:BODY.ESTUDIANTES AS BIGINT[]),
    COALESCE(CAST(:BODY.FECHA AS DATE), CURRENT_DATE)
);$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- PUT /planeador/actividades/:ID/calificar-bulk/rubrica
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT 'bdb9d1a9-249c-4b04-a393-bfbcb18373fb', m.id_microservice, '/planeador/actividades/:ID/calificar-bulk/rubrica', 'PUT', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL,
       '{"PARAM.ID": "BIGINT", "BODY.FECHA": "DATE", "BODY.PK_NIVEL": "BIGINT", "BODY.ESTUDIANTES": "BIGINT[]", "BODY.PK_CRITERIO": "BIGINT"}'::jsonb,
       'Aplica un nivel de un criterio de la rúbrica a varios estudiantes de la actividad :ID (fn_actividad_nota_calificar_rubrica_bulk). BODY.PK_CRITERIO, BODY.PK_NIVEL, BODY.ESTUDIANTES (PK_TACTIVIDAD_ESTUDIANTE[]), BODY.FECHA. Los demás criterios ya capturados no se tocan; la nota se guarda cuando el estudiante completa todos (calificacion_actualizada). Errores: 404 (P0002) si la actividad o la asignación no existe; 400 (22023) si la actividad fue eliminada, es formativa, no tiene instrumento, el estudiante no es de la actividad, no tiene asistencia válida ese día o el valor no cumple el instrumento; 403 (42501) sin alcance o si un docente califica una actividad que no creó (Regla 54).',
       $q$SELECT * FROM academico_test.fn_actividad_nota_calificar_rubrica_bulk(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.PK_CRITERIO AS BIGINT),
    CAST(:BODY.PK_NIVEL AS BIGINT),
    CAST(:BODY.ESTUDIANTES AS BIGINT[]),
    COALESCE(CAST(:BODY.FECHA AS DATE), CURRENT_DATE)
);$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- PUT /planeador/actividades/estudiantes/:ID/calificar
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT '895b10f1-e766-4a7a-a1e2-46cc70862650', m.id_microservice, '/planeador/actividades/estudiantes/:ID/calificar', 'PUT', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL,
       '{"PARAM.ID": "BIGINT", "BODY.FECHA": "DATE", "BODY.CALIFICACION": "JSONB"}'::jsonb,
       'Califica a UN estudiante (:ID = PK_TACTIVIDAD_ESTUDIANTE) con el instrumento de su actividad (fn_actividad_nota_calificar). BODY.CALIFICACION según el instrumento (Otro con método se califica como su método): rúbrica {niveles:[{pkCriterio,pkNivel}]} con todos los criterios; lista de cotejo {itemsMarcados:[pk]}; escala {pkNivel} o {valorNumerico}, o {criterios:[{criterioIndex,pkNivel|valorNumerico}]} uno por criterio; Otro sin método {porcentaje} 0-100. BODY.FECHA (por defecto hoy) es el día con asistencia que habilita calificar. La rúbrica suma los puntajes elegidos sobre la suma de los máximos de cada criterio (Regla 42); la nota pasa por piso y tope institucionales y, si la actividad es una recuperación, se consolida en su destino. Devuelve el % guardado (0-100). Errores: 404 (P0002) si la actividad o la asignación no existe; 400 (22023) si la actividad fue eliminada, es formativa, no tiene instrumento, el estudiante no es de la actividad, no tiene asistencia válida ese día o el valor no cumple el instrumento; 403 (42501) sin alcance o si un docente califica una actividad que no creó (Regla 54).',
       $q$SELECT academico_test.fn_actividad_nota_calificar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.CALIFICACION AS JSONB),
    COALESCE(CAST(:BODY.FECHA AS DATE), CURRENT_DATE)
) AS calificacion;$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- GET /planeador/actividades/estudiantes/:ID/nota
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT '3b4cc230-9748-4d9b-9deb-bb92a4c25c93', m.id_microservice, '/planeador/actividades/estudiantes/:ID/nota', 'GET', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL,
       '{"PARAM.ID": "BIGINT"}'::jsonb,
       'Detalle de la nota de UN estudiante (:ID = PK_TACTIVIDAD_ESTUDIANTE, fn_actividad_nota_obtener): instrumento, calificacion (%), calificable, observacion, detalle (captura por pk), evidencias (soportes de la observación), nota_homologada/valoracion/formato_valor en el formato del colegio y resultado_instrumento con etiquetas. Errores: 404 (P0002) si no existe; 403 (42501) sin alcance o si un docente consulta una actividad que no creó (Regla 54).',
       $q$SELECT * FROM academico_test.fn_actividad_nota_obtener(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
);$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- Roles: el docente califica sus actividades; el super admin administra.
INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id AND m.serviceid = 'eval-col'
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR', 'CEVAL-DOCENTE')
 WHERE (q.http_method, q.path_template) IN (
        ('GET', '/planeador/actividades/:ID/calificaciones'),
        ('PUT', '/planeador/actividades/:ID/calificar-bulk/cotejo'),
        ('PUT', '/planeador/actividades/:ID/calificar-bulk/escala'),
        ('PUT', '/planeador/actividades/:ID/calificar-bulk/rubrica'),
        ('PUT', '/planeador/actividades/estudiantes/:ID/calificar'),
        ('GET', '/planeador/actividades/estudiantes/:ID/nota'))
ON CONFLICT DO NOTHING;
