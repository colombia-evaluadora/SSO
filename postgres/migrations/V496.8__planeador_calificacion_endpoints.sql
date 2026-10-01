-- V496.8 - Calificación y resultados de actividades: endpoints (4 de 4).
-- Define en un solo sitio las filas de calificar (individual y en bloque), la
-- nota de un estudiante, el listado de calificaciones, el estado de resultado
-- (individual y en bloque), la asistencia marcada desde el Planeador y la
-- observación formativa (individual y grupal).
-- Upsert que conserva el id y con él sus role_query. Roles: DOCENTE y
-- SUPER_ADMINISTRADOR. Los INSERT originales siguen en V246 y V247.
-- Depende de: V496.7 (wrappers), V463 (observar), V246/V247 (filas).

SET search_path TO academico_test, public;

-- GET /planeador/actividades/:ID/calificaciones
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT '5cda6361-6ade-4bb8-8907-8677b0ff25d5', m.id_microservice, '/planeador/actividades/:ID/calificaciones', 'GET', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL,
       '{"PARAM.ID": "BIGINT", "QUERY.FECHA": "DATE", "QUERY.SEARCH": "VARCHAR"}'::jsonb,
       'Tabla "Calificaciones: <actividad>" de la actividad :ID (fn_actividad_estudiantes_calificaciones_listar): un renglón por estudiante asignado con la asistencia de la actividad (la de su primer día, fecha_asistencia, agregando todos los bloques; la de la Vista Asistencias predomina sobre la marcada en el Planeador y queda congelada al registrar el resultado): pk_tasistencia, tipo_asistencia, tipo_asistencia_valor (1 Asistió, 2 No asistió, 5 Llegó tarde), asistencia_justificada (hay excusa), origen_asistencia (ASISTENCIA o PLANEADOR) y asistencia_editable (FALSE si ya hay resultado). Además nota en % y homologada, es_formativa, resultado_instrumento, estado_resultado (CALIFICADO, PENDIENTE, NO_PRESENTO, NO_ASISTIO_JUSTIFICADA, NO_ASISTIO_NO_JUSTIFICADA; No asistido sale de la asistencia y no se puede calificar ni observar), momento y evidencia_enlace del registro narrativo, y resultados_completos (Regla 58: ningún estudiante Pendiente; igual en todas las filas). ?fecha= solo se devuelve como eco en `fecha`. ?search= filtra por nombre. Errores: 404 (P0002); 400 (22023) si fue eliminada; 403 (42501) sin alcance o si un docente consulta una actividad que no creó (Regla 54).',
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
       'Marca un elemento de la lista de cotejo como Cumple (S) o No cumple (N) para varios estudiantes de la actividad :ID (fn_actividad_nota_calificar_cotejo_bulk). BODY.PK_ITEM, BODY.CUMPLIDO, BODY.ESTUDIANTES, BODY.FECHA. Recalcula la nota en la misma pasada (un elemento sin marcar cuenta como No cumple). Errores: 404 (P0002) si la actividad o la asignación no existe; 400 (22023) si la actividad fue eliminada, es formativa, no tiene instrumento, el estudiante no es de la actividad, está No asistido o No presentó, o el valor no cumple el instrumento; 403 (42501) sin alcance o si un docente califica una actividad que no creó (Regla 54).',
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
       'Califica con la escala de valoración a varios estudiantes de la actividad :ID (fn_actividad_nota_calificar_escala_bulk). BODY.CRITERIOS [{criterioIndex,pkNivel|valorNumerico}] uno por criterio, o BODY.PK_NIVEL / BODY.VALOR_NUMERICO suelto, que con varios criterios se aplica a cada uno; BODY.ESTUDIANTES y BODY.FECHA. Devuelve {pk_tactividad_estudiante, calificacion}. Errores: 404 (P0002) si la actividad o la asignación no existe; 400 (22023) si la actividad fue eliminada, es formativa, no tiene instrumento, el estudiante no es de la actividad, está No asistido o No presentó, o el valor no cumple el instrumento; 403 (42501) sin alcance o si un docente califica una actividad que no creó (Regla 54).',
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
       'Aplica un nivel de un criterio de la rúbrica a varios estudiantes de la actividad :ID (fn_actividad_nota_calificar_rubrica_bulk). BODY.PK_CRITERIO, BODY.PK_NIVEL, BODY.ESTUDIANTES (PK_TACTIVIDAD_ESTUDIANTE[]), BODY.FECHA. Los demás criterios ya capturados no se tocan; la nota se guarda cuando el estudiante completa todos (calificacion_actualizada). Errores: 404 (P0002) si la actividad o la asignación no existe; 400 (22023) si la actividad fue eliminada, es formativa, no tiene instrumento, el estudiante no es de la actividad, está No asistido o No presentó, o el valor no cumple el instrumento; 403 (42501) sin alcance o si un docente califica una actividad que no creó (Regla 54).',
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
       'Califica a UN estudiante (:ID = PK_TACTIVIDAD_ESTUDIANTE) con el instrumento de su actividad (fn_actividad_nota_calificar). BODY.CALIFICACION según el instrumento (Otro con método se califica como su método): rúbrica {niveles:[{pkCriterio,pkNivel}]} con todos los criterios; lista de cotejo {itemsMarcados:[pk]}; escala {pkNivel} o {valorNumerico}, o {criterios:[{criterioIndex,pkNivel|valorNumerico}]} uno por criterio; Otro sin método {porcentaje} 0-100. BODY.FECHA (por defecto hoy) se conserva por contrato. Un estudiante No asistido o No presentó no se califica (22023): primero se cambia su asistencia en el Planeador o se quita el No presentó. Calificar marca el resultado como Calificado y congela la asistencia de la actividad. La rúbrica suma los puntajes elegidos sobre la suma de los máximos de cada criterio (Regla 42); la nota pasa por piso y tope institucionales y, si la actividad es una recuperación, se consolida en su destino. Devuelve el % guardado (0-100). Errores: 404 (P0002) si la actividad o la asignación no existe; 400 (22023) si la actividad fue eliminada, es formativa, no tiene instrumento, el estudiante no es de la actividad, está No asistido o No presentó, o el valor no cumple el instrumento; 403 (42501) sin alcance o si un docente califica una actividad que no creó (Regla 54).',
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

-- PUT /planeador/actividades/estudiantes/:ID/estado-resultado
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT 'bde92bfe-a6b4-41e3-b554-7fdc80f95a50', m.id_microservice, '/planeador/actividades/estudiantes/:ID/estado-resultado', 'PUT', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL,
       '{"PARAM.ID": "BIGINT", "BODY.ESTADO": "VARCHAR"}'::jsonb,
       'Marca el estado del resultado de UN estudiante (:ID = PK_TACTIVIDAD_ESTUDIANTE, fn_actividad_resultado_estado_set; Regla 62). BODY.ESTADO = PENDIENTE o NO_PRESENTO. PENDIENTE borra la nota del estudiante (los estados son excluyentes); NO_PRESENTO exige que no tenga nota ni esté No asistido. Calificado no se marca: lo fija calificar u observar; No asistido (Justificada o No justificada) tampoco: sale de la asistencia (PUT /planeador/actividades/estudiantes/:ID/asistencia) y su excusa. Devuelve el estado guardado. Errores: 404 (P0002) si la asignación no existe; 400 (22023) si la actividad fue eliminada, su referente está inactivo, el estado no es válido, el estudiante está No asistido o se marca No presentó con nota; 403 (42501) sin alcance o si un docente toca una actividad que no creó (Regla 54).',
       $q$SELECT academico_test.fn_actividad_resultado_estado_set(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.ESTADO AS VARCHAR)
) AS estado_resultado;$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- PUT /planeador/actividades/estudiantes/:ID/asistencia
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT '9c58dbaf-8de0-442b-a047-ccc681f89715', m.id_microservice, '/planeador/actividades/estudiantes/:ID/asistencia', 'PUT', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL,
       '{"PARAM.ID": "BIGINT", "BODY.TIPO_ASISTENCIA": "NUMERIC"}'::jsonb,
       'Asistencia de UN estudiante en la actividad, marcada desde la tabla de calificaciones del Planeador (:ID = PK_TACTIVIDAD_ESTUDIANTE, fn_actividad_asistencia_planeador_set; Regla 73). BODY.TIPO_ASISTENCIA = 1 Asistió, 2 No asistió o 5 Llegó tarde. Vale para el primer día de la actividad y nunca cambia la asistencia de la Vista Asistencias; si la Vista no se tomó ese día, queda como asistencia oficial (ORIGEN PLANEADOR) hasta que la Vista la tome. No asistió deja el resultado en NO_ASISTIO_JUSTIFICADA si la Vista trae excusa ese día y en NO_ASISTIO_NO_JUSTIFICADA si no (el docente no lo elige); Asistió o Llegó tarde devuelven a Pendiente un No asistido. Devuelve el estado_resultado que queda. Errores: 404 (P0002) si la asignación no existe; 400 (22023) si la actividad fue eliminada, su referente está inactivo, el estudiante ya tiene nota u observación (la asistencia queda congelada) o no hay periodo de evaluación en esa fecha; 400 (23503) si el tipo no es 1, 2 o 5; 403 (42501) sin alcance o si un docente toca una actividad que no creó (Regla 54).',
       $q$SELECT academico_test.fn_actividad_asistencia_planeador_set(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.TIPO_ASISTENCIA AS NUMERIC)
) AS estado_resultado;$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- PUT /planeador/actividades/:ID/estado-resultado-bulk
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT '50ad02d2-139c-440f-923d-fb9416262200', m.id_microservice, '/planeador/actividades/:ID/estado-resultado-bulk', 'PUT', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL,
       '{"PARAM.ID": "BIGINT", "BODY.ESTADO": "VARCHAR", "BODY.ESTUDIANTES": "BIGINT[]"}'::jsonb,
       'Marca el mismo estado de resultado a varios estudiantes de la actividad :ID (fn_actividad_resultado_estado_set_bulk). BODY.ESTADO como en el endpoint individual; BODY.ESTUDIANTES = PK_TACTIVIDAD_ESTUDIANTE[]. Devuelve {pk_tactividad_estudiante, estado_resultado}. Errores: 404 (P0002); 400 (22023) si la actividad fue eliminada, su referente está inactivo, el estado no es válido o un estudiante no es de la actividad; 403 (42501) sin alcance o si un docente toca una actividad que no creó (Regla 54).',
       $q$SELECT * FROM academico_test.fn_actividad_resultado_estado_set_bulk(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.ESTADO AS VARCHAR),
    CAST(:BODY.ESTUDIANTES AS BIGINT[])
);$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- PUT /planeador/actividades/estudiantes/:ID/observar (fila de V246: solo contrato)
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT gen_random_uuid()::text, m.id_microservice, '/planeador/actividades/estudiantes/:ID/observar', 'PUT', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL,
       '{"PARAM.ID": "BIGINT", "BODY.OBSERVACION": "VARCHAR", "BODY.FECHA": "DATE", "BODY.EVIDENCIAS": "BIGINT[]", "BODY.MOMENTO": "VARCHAR", "BODY.ENLACE": "VARCHAR"}'::jsonb,
       'Observación de UN estudiante (:ID = PK_TACTIVIDAD_ESTUDIANTE) en una actividad formativa (fn_actividad_observar_estudiante). BODY.OBSERVACION hasta 1000 caracteres (vacía vale si queda con evidencia o enlace); BODY.MOMENTO = INICIO, PROCESO o CIERRE; BODY.EVIDENCIAS = hasta 3 PK_TARCHIVO pdf/doc/docx/jpg/png de máximo 10 MB, con semántica de reemplazo, o BODY.ENLACE http(s), no los dos (Regla 61). Omitir MOMENTO, EVIDENCIAS o ENLACE no los toca; vacío los quita. Un estudiante No asistido o No presentó no se observa (22023). Marca el resultado como Calificado y congela la asistencia de la actividad. Errores: 404 (P0002); 400 (22023) si la actividad no es formativa, su referente está inactivo o se excede un límite; 403 (42501) sin alcance o si un docente observa una actividad que no creó (Regla 54).',
       $q$SELECT academico_test.fn_actividad_observar_estudiante(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.OBSERVACION AS TEXT),
    COALESCE(CAST(:BODY.FECHA AS DATE), CURRENT_DATE),
    CAST(:BODY.EVIDENCIAS AS BIGINT[]),
    CAST(:BODY.MOMENTO AS VARCHAR),
    CAST(:BODY.ENLACE AS VARCHAR)
);$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- POST /planeador/actividades/:ID/observar-grupal
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT gen_random_uuid()::text, m.id_microservice, '/planeador/actividades/:ID/observar-grupal', 'POST', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL,
       '{"PARAM.ID": "BIGINT", "BODY.OBSERVACION": "VARCHAR", "BODY.FECHA": "DATE", "BODY.EVIDENCIAS": "BIGINT[]", "BODY.MOMENTO": "VARCHAR", "BODY.ENLACE": "VARCHAR"}'::jsonb,
       'La misma observación para los estudiantes de la actividad formativa :ID que siguen Pendientes y sin observación (fn_actividad_observar_grupal); los que ya tienen resultado (observación o un estado como No asistido) se omiten. Mismos campos y límites que la individual (BODY.OBSERVACION ≤1000, BODY.MOMENTO, BODY.EVIDENCIAS hasta 3 o BODY.ENLACE). Devuelve estudiantes_observados: cuántos observó. Errores: 404 (P0002); 400 (22023) si la actividad no es formativa, su referente está inactivo, se excede un límite o no trae texto, evidencia ni enlace; 403 (42501) sin alcance o si un docente observa una actividad que no creó (Regla 54).',
       $q$SELECT academico_test.fn_actividad_observar_grupal(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.OBSERVACION AS TEXT),
    COALESCE(CAST(:BODY.FECHA AS DATE), CURRENT_DATE),
    CAST(:BODY.EVIDENCIAS AS BIGINT[]),
    CAST(:BODY.MOMENTO AS VARCHAR),
    CAST(:BODY.ENLACE AS VARCHAR)
) AS estudiantes_observados;$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

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
        ('GET', '/planeador/actividades/estudiantes/:ID/nota'),
        ('PUT', '/planeador/actividades/estudiantes/:ID/estado-resultado'),
        ('PUT', '/planeador/actividades/estudiantes/:ID/asistencia'),
        ('PUT', '/planeador/actividades/:ID/estado-resultado-bulk'))
ON CONFLICT DO NOTHING;

-- Calificar suma solicitudes_pendientes (Reglas 55/69): la escritura no falla
-- cuando exige aprobación, devuelve qué solicitud abrió. Va aquí y no en V496.21
-- porque el deploy re-ejecuta esta migración después de las nuevas y el upsert
-- de arriba pisaría el envoltorio. MATERIALIZED garantiza que la escritura ya
-- corrió cuando se lee la lista; el guard por prefijo lo hace idempotente.
UPDATE public.query q
   SET query = 'WITH w AS MATERIALIZED (' || regexp_replace(q.query, ';\s*$', '')
               || E')\nSELECT w.*, academico_test.fn_solicitud_aprobacion_creadas() AS solicitudes_pendientes FROM w;',
       detail = q.detail || ' Si el cambio exige aprobación del Coordinador (Reglas 55, 69, 75) no se aplica todavía: solicitudes_pendientes trae el PK de la solicitud abierta (vacío = se aplicó).'
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id AND m.serviceid = 'eval-col'
   AND q.query NOT LIKE 'WITH w AS MATERIALIZED (%'
   AND (q.http_method, q.path_template) IN (
        ('PUT', '/planeador/actividades/estudiantes/:ID/calificar'),
        ('PUT', '/planeador/actividades/:ID/calificar-bulk/cotejo'),
        ('PUT', '/planeador/actividades/:ID/calificar-bulk/escala'),
        ('PUT', '/planeador/actividades/:ID/calificar-bulk/rubrica'));
