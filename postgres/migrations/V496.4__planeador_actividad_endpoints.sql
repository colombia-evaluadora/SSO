-- V496.4 — Planeador, actividad: endpoints de escritura (4 de 4).
--
-- Qué hace: define en un solo sitio las 13 filas de escritura de
-- /planeador/actividades* (upsert que conserva el id y con él los role_query
-- de cada servidor) y sus roles: DOCENTE y SUPER_ADMINISTRADOR, los que ya
-- tenían. Las consultas no cambian; el detail describe el contrato vigente.
-- También las dos lecturas del formulario (pantalla-edicion y configuracion),
-- tal cual estaban, para que re-aplicar V452 no les pise el detail.
-- Las filas de archivo y pantalla-edicion nacen aquí; las demás, en V246/V247,
-- que se conservan porque otras migraciones copian de ellas sus roles.
-- Depende de: V496.3 (funciones), V246/V247 (filas).

SET search_path TO academico_test, public;

-- POST /planeador/actividades
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT '119385c4-6ce3-476a-be75-fa81a2995f06', m.id_microservice, '/planeador/actividades', 'POST', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL,
       '{"BODY.TITULO": "VARCHAR", "BODY.CRITERIOS": "BIGINT[]", "BODY.FK_TGRUPO": "BIGINT", "BODY.EVIDENCIAS": "BIGINT[]", "BODY.FK_TUNIDAD": "BIGINT", "BODY.INFLUENCIA": "NUMERIC", "BODY.MATERIALES": "JSONB", "BODY.DESCRIPCION": "VARCHAR", "BODY.NOTA_MAXIMA": "NUMERIC", "BODY.PONDERACION": "NUMERIC", "BODY.ADAPTACIONES": "JSONB", "BODY.FECHA_CIERRE": "DATE", "BODY.FECHA_INICIO": "DATE", "BODY.RECUPERACION": "JSONB", "BODY.ES_EVALUATIVA": "VARCHAR", "BODY.FK_TASIGNATURA": "BIGINT", "BODY.FK_TMATRICULAS": "BIGINT[]", "BODY.REQUIERE_TEXTO": "VARCHAR", "BODY.FK_TLV_JERARQUIA": "BIGINT", "BODY.FK_TLV_MODALIDAD": "BIGINT", "BODY.REQUIERE_ARCHIVO": "VARCHAR", "BODY.DURACION_ESTIMADA": "NUMERIC", "BODY.GENERA_EVIDENCIAS": "VARCHAR", "BODY.SEMANA_CRONOGRAMA": "VARCHAR", "BODY.MATERIAL_REQUERIDO": "VARCHAR", "BODY.FK_TLV_TIPO_CALCULO": "BIGINT", "BODY.ASIGNAR_TODO_EL_GRUPO": "BOOLEAN", "BODY.FK_TLV_TIPO_ACTIVIDAD": "BIGINT", "BODY.FK_TLV_TIPO_EVIDENCIA": "BIGINT", "BODY.OBSERVACIONES_DOCENTE": "VARCHAR", "BODY.DESCRIPCION_INSTRUMENTO": "VARCHAR", "BODY.FK_TLV_METODO_VALORACION": "BIGINT", "BODY.FK_TLV_INSTRUMENTO_EVALUACION": "BIGINT", "BODY.REQUIERE_VALIDACION_COORDINADOR": "VARCHAR"}'::jsonb,
       'Crea una actividad del Planeador (fn_actividad_crear). Obligatorios: TITULO (máx. 150), FK_TASIGNATURA, FK_TLV_TIPO_ACTIVIDAD, FK_TLV_JERARQUIA. Con FK_TUNIDAD la unidad debe ser de la misma asignatura y del grado del grupo; Ponderar exige PONDERACION y Sumatoria NOTA_MAXIMA (Regla 24), y EVIDENCIAS debe marcar al menos una evidencia de los enunciados de la unidad cuando la unidad las tiene (Regla 43). Sin unidad no se admiten evidencias ni criterios. Sin FK_TMATRICULAS se asigna todo el grupo; con grupo debe quedar al menos un estudiante. ES_EVALUATIVA por defecto la decide el referente. RECUPERACION {destino, tipoAplicacion, tipoCalculo?, valorPonderacion?, fkActividadRecuperar?}: la actividad a recuperar debe ser sumativa, no ser recuperación, ser de la misma asignatura y tener resultados (Regla 64). La actividad sin grupo ni unidad se crea con solo el permiso CREAR. Devuelve el PK_TACTIVIDAD. Errores: 422 (22023) regla del formulario, 409 (23503/23505) referencia inactiva o nombre repetido, 403 (42501) sin alcance.',
       $q$SELECT * FROM academico_test.fn_actividad_crear(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.TITULO AS VARCHAR),
    CAST(:BODY.FK_TASIGNATURA AS BIGINT),
    CAST(:BODY.FK_TLV_TIPO_ACTIVIDAD AS BIGINT),
    CAST(:BODY.FK_TLV_JERARQUIA AS BIGINT),
    CAST(:BODY.DESCRIPCION AS VARCHAR),
    CAST(:BODY.FK_TGRUPO AS BIGINT),
    CAST(:BODY.FK_TUNIDAD AS BIGINT),
    CAST(:BODY.PONDERACION AS NUMERIC),
    CAST(:BODY.FECHA_INICIO AS DATE),
    CAST(:BODY.FECHA_CIERRE AS DATE),
    CAST(:BODY.DURACION_ESTIMADA AS NUMERIC),
    CAST(:BODY.SEMANA_CRONOGRAMA AS VARCHAR),
    CAST(:BODY.FK_TLV_MODALIDAD AS BIGINT),
    CAST(:BODY.MATERIAL_REQUERIDO AS VARCHAR),
    COALESCE(CAST(:BODY.ES_EVALUATIVA AS academico_test.bool_sn), 'S'),
    CAST(:BODY.FK_TLV_INSTRUMENTO_EVALUACION AS BIGINT),
    CAST(:BODY.DESCRIPCION_INSTRUMENTO AS VARCHAR),
    CAST(:BODY.FK_TLV_TIPO_EVIDENCIA AS BIGINT),
    CAST(:BODY.FK_TLV_METODO_VALORACION AS BIGINT),
    CAST(:BODY.FK_TLV_TIPO_CALCULO AS BIGINT),
    CAST(:BODY.INFLUENCIA AS NUMERIC),
    CAST(:BODY.NOTA_MAXIMA AS NUMERIC),
    COALESCE(CAST(:BODY.REQUIERE_ARCHIVO AS academico_test.bool_sn), 'N'),
    COALESCE(CAST(:BODY.REQUIERE_TEXTO AS academico_test.bool_sn), 'N'),
    COALESCE(CAST(:BODY.GENERA_EVIDENCIAS AS academico_test.bool_sn), 'N'),
    COALESCE(CAST(:BODY.REQUIERE_VALIDACION_COORDINADOR AS academico_test.bool_sn), 'N'),
    CAST(:BODY.OBSERVACIONES_DOCENTE AS VARCHAR),
    CAST(:BODY.MATERIALES AS JSONB),
    CAST(:BODY.ADAPTACIONES AS JSONB),
    CAST(:BODY.FK_TMATRICULAS AS BIGINT[]),
    COALESCE(CAST(:BODY.ASIGNAR_TODO_EL_GRUPO AS BOOLEAN), FALSE),
    CAST(:BODY.RECUPERACION AS JSONB),
    CAST(:BODY.EVIDENCIAS AS BIGINT[]),
    CAST(:BODY.CRITERIOS AS BIGINT[])
);$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- PATCH /planeador/actividades/:ID
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT '29eb7594-ede8-467c-bd0b-ab2e98bb988f', m.id_microservice, '/planeador/actividades/:ID', 'PATCH', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL,
       '{"PARAM.ID": "BIGINT"}'::jsonb,
       'Elimina (borrado lógico en cascada) la actividad :ID (fn_actividad_eliminar): la suelta de su unidad y recalcula la Sumatoria. No se elimina si tiene resultados, asistencias o una recuperación activa que la recupera (409, 23503; Regla 38). Errores: 404 (P0002), 422 (22023) si ya fue eliminada, 403 (42501) sin permiso o si no es del docente.',
       $q$SELECT * FROM academico_test.fn_actividad_eliminar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
);$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- PUT /planeador/actividades/:ID
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT '747ddda2-9b22-4baf-bd6d-23d378aa3685', m.id_microservice, '/planeador/actividades/:ID', 'PUT', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL,
       '{"PARAM.ID": "BIGINT", "BODY.TITULO": "VARCHAR", "BODY.CRITERIOS": "BIGINT[]", "BODY.FK_TGRUPO": "BIGINT", "BODY.EVIDENCIAS": "BIGINT[]", "BODY.FK_TUNIDAD": "BIGINT", "BODY.INFLUENCIA": "NUMERIC", "BODY.MATERIALES": "JSONB", "BODY.DESCRIPCION": "VARCHAR", "BODY.NOTA_MAXIMA": "NUMERIC", "BODY.PONDERACION": "NUMERIC", "BODY.ADAPTACIONES": "JSONB", "BODY.FECHA_CIERRE": "DATE", "BODY.FECHA_INICIO": "DATE", "BODY.RECUPERACION": "JSONB", "BODY.ES_EVALUATIVA": "VARCHAR", "BODY.FK_TASIGNATURA": "BIGINT", "BODY.FK_TMATRICULAS": "BIGINT[]", "BODY.REQUIERE_TEXTO": "VARCHAR", "BODY.FK_TLV_MODALIDAD": "BIGINT", "BODY.REQUIERE_ARCHIVO": "VARCHAR", "BODY.DURACION_ESTIMADA": "NUMERIC", "BODY.GENERA_EVIDENCIAS": "VARCHAR", "BODY.SEMANA_CRONOGRAMA": "VARCHAR", "BODY.DESVINCULAR_UNIDAD": "BOOLEAN", "BODY.MATERIAL_REQUERIDO": "VARCHAR", "BODY.FK_TLV_TIPO_CALCULO": "BIGINT", "BODY.QUITAR_RECUPERACION": "BOOLEAN", "BODY.ASIGNAR_TODO_EL_GRUPO": "BOOLEAN", "BODY.FK_TLV_TIPO_ACTIVIDAD": "BIGINT", "BODY.FK_TLV_TIPO_EVIDENCIA": "BIGINT", "BODY.OBSERVACIONES_DOCENTE": "VARCHAR", "BODY.DESCRIPCION_INSTRUMENTO": "VARCHAR", "BODY.FK_TLV_METODO_VALORACION": "BIGINT", "BODY.FK_TLV_INSTRUMENTO_EVALUACION": "BIGINT", "BODY.REQUIERE_VALIDACION_COORDINADOR": "VARCHAR"}'::jsonb,
       'Actualización parcial de la actividad :ID (fn_actividad_actualizar): lo ausente conserva su valor; MATERIALES/ADAPTACIONES/FK_TMATRICULAS/EVIDENCIAS/CRITERIOS NULL = no tocar, arreglo = reemplazo. Cambiar FK_TUNIDAD mueve la actividad (suelta las evidencias y criterios de la unidad anterior y exige marcar las nuevas, Regla 36); DESVINCULAR_UNIDAD=true la deja sin unidad (Regla 39). Cambiar FK_TGRUPO reasigna todo el grupo si no llegan estudiantes (Regla 35). QUITAR_RECUPERACION=true deja de ser recuperación. El alcance se comprueba donde está la actividad y adonde se mueve. Errores: 404 (P0002) si no existe; 422 (22023) si ya fue eliminada o el dato no cumple una regla; 403 (42501) sin permiso o si un docente toca una actividad que no creó (Regla 25); 409 (23503) si ya tiene resultados registrados o es la original de una recuperación (Regla 37).',
       $q$SELECT * FROM academico_test.fn_actividad_actualizar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.TITULO AS VARCHAR),
    CAST(:BODY.DESCRIPCION AS VARCHAR),
    CAST(:BODY.FK_TASIGNATURA AS BIGINT),
    CAST(:BODY.FK_TGRUPO AS BIGINT),
    CAST(:BODY.FK_TUNIDAD AS BIGINT),
    CAST(:BODY.PONDERACION AS NUMERIC),
    COALESCE(CAST(:BODY.DESVINCULAR_UNIDAD AS BOOLEAN), FALSE),
    CAST(:BODY.FK_TLV_TIPO_ACTIVIDAD AS BIGINT),
    CAST(:BODY.FECHA_INICIO AS DATE),
    CAST(:BODY.FECHA_CIERRE AS DATE),
    CAST(:BODY.DURACION_ESTIMADA AS NUMERIC),
    CAST(:BODY.SEMANA_CRONOGRAMA AS VARCHAR),
    CAST(:BODY.FK_TLV_MODALIDAD AS BIGINT),
    CAST(:BODY.MATERIAL_REQUERIDO AS VARCHAR),
    CAST(:BODY.ES_EVALUATIVA AS academico_test.bool_sn),
    CAST(:BODY.FK_TLV_INSTRUMENTO_EVALUACION AS BIGINT),
    CAST(:BODY.DESCRIPCION_INSTRUMENTO AS VARCHAR),
    CAST(:BODY.FK_TLV_TIPO_EVIDENCIA AS BIGINT),
    CAST(:BODY.FK_TLV_METODO_VALORACION AS BIGINT),
    CAST(:BODY.FK_TLV_TIPO_CALCULO AS BIGINT),
    CAST(:BODY.INFLUENCIA AS NUMERIC),
    CAST(:BODY.NOTA_MAXIMA AS NUMERIC),
    CAST(:BODY.REQUIERE_ARCHIVO AS academico_test.bool_sn),
    CAST(:BODY.REQUIERE_TEXTO AS academico_test.bool_sn),
    CAST(:BODY.GENERA_EVIDENCIAS AS academico_test.bool_sn),
    CAST(:BODY.REQUIERE_VALIDACION_COORDINADOR AS academico_test.bool_sn),
    CAST(:BODY.OBSERVACIONES_DOCENTE AS VARCHAR),
    CAST(:BODY.MATERIALES AS JSONB),
    CAST(:BODY.ADAPTACIONES AS JSONB),
    CAST(:BODY.FK_TMATRICULAS AS BIGINT[]),
    COALESCE(CAST(:BODY.ASIGNAR_TODO_EL_GRUPO AS BOOLEAN), FALSE),
    CAST(:BODY.RECUPERACION AS JSONB),
    COALESCE(CAST(:BODY.QUITAR_RECUPERACION AS BOOLEAN), FALSE),
    CAST(:BODY.EVIDENCIAS AS BIGINT[]),
    CAST(:BODY.CRITERIOS AS BIGINT[])
);$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- PUT /planeador/actividades/:ID/adaptaciones
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT '90edaeb1-71ca-45aa-9b12-91bb8400c8ff', m.id_microservice, '/planeador/actividades/:ID/adaptaciones', 'PUT', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL,
       '{"PARAM.ID": "BIGINT", "BODY.ADAPTACIONES": "JSONB"}'::jsonb,
       'Reemplaza las adaptaciones curriculares de la actividad :ID (fn_actividad_adaptacion_reemplazar, Bloque 6). BODY.ADAPTACIONES = [{tipoAdaptacion, descripcion (máx. 500), usaVersionModificada S/N, formatoAdaptacion?, fkTarchivo?, url?, aplicaA?, estudiantes?}]: los estudiantes deben ser de la actividad (Regla 47). Arreglo vacío = sin adaptaciones. Errores: 404 (P0002) si no existe; 422 (22023) si ya fue eliminada o el dato no cumple una regla; 403 (42501) sin permiso o si un docente toca una actividad que no creó (Regla 25); 409 (23503) si ya tiene resultados registrados o es la original de una recuperación (Regla 37).',
       $q$SELECT academico_test.fn_actividad_adaptacion_reemplazar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.ADAPTACIONES AS JSONB)
) AS cantidad;$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- POST /planeador/actividades/:ID/adaptaciones/archivo
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT 'eval-col-actividad-adaptacion-archivo-001', m.id_microservice, '/planeador/actividades/:ID/adaptaciones/archivo', 'POST', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', 'actividad-adaptacion-archivo', 'DEFAULT',
       '{"PARAM.ID": "BIGINT", "BODY.ARCHIVO": "FILE:actividad"}'::jsonb,
       'Paso 1 de una versión modificada del instrumento tipo archivo: multipart con el campo ARCHIVO por file-service; devuelve el fk_tarchivo que se envía como fkTarchivo en PUT :ID/adaptaciones (fn_actividad_adaptacion_archivo_registrar). Errores: 404 (P0002) si no existe; 422 (22023) si ya fue eliminada o el dato no cumple una regla; 403 (42501) sin permiso o si un docente toca una actividad que no creó (Regla 25); 409 (23503) si ya tiene resultados registrados o es la original de una recuperación (Regla 37).',
       $q$SELECT academico_test.fn_actividad_adaptacion_archivo_registrar(
    p_pk_usuario_solicitante => public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    p_pk_tactividad          => CAST(:PARAM.ID AS BIGINT),
    p_fk_tarchivo            => CAST(:BODY.ARCHIVO AS BIGINT)
) AS fk_tarchivo;$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- POST /planeador/actividades/:ID/criterios
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT '93f9facf-1207-49de-a8f8-588d8ffe3be3', m.id_microservice, '/planeador/actividades/:ID/criterios', 'POST', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL,
       '{"PARAM.ID": "BIGINT", "BODY.FK_TCRITERIO_UNIDAD": "BIGINT"}'::jsonb,
       'Asocia a la actividad :ID un criterio de la rúbrica de su unidad (fn_actividad_criterio_relacionar). BODY.FK_TCRITERIO_UNIDAD debe ser un criterio activo de la rúbrica de la misma unidad. Devuelve PK_TACTIVIDAD_CRITERIO_UNIDAD. Errores: 404 (P0002) si no existe; 422 (22023) si ya fue eliminada o el dato no cumple una regla; 403 (42501) sin permiso o si un docente toca una actividad que no creó (Regla 25); 409 (23503) si ya tiene resultados registrados o es la original de una recuperación (Regla 37).',
       $q$SELECT academico_test.fn_actividad_criterio_relacionar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.FK_TCRITERIO_UNIDAD AS BIGINT)
) AS pk_tactividad_criterio_unidad;$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- PUT /planeador/actividades/:ID/estudiantes
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT 'eval-col-planeador-actividad-estudiantes-set-001', m.id_microservice, '/planeador/actividades/:ID/estudiantes', 'PUT', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL,
       '{"PARAM.ID": "BIGINT", "BODY.FK_TMATRICULAS": "BIGINT[]", "BODY.ASIGNAR_TODO_EL_GRUPO": "BOOLEAN"}'::jsonb,
       'Fija los estudiantes de la actividad :ID con semántica de reemplazo (fn_actividad_estudiantes_set). BODY.FK_TMATRICULAS: matrículas activas del grupo de la actividad; BODY.ASIGNAR_TODO_EL_GRUPO=true asigna a todo el grupo. Debe quedar al menos un estudiante; quien sale, sale también de sus adaptaciones. Devuelve el total asignado. Errores: 404 (P0002) si no existe; 422 (22023) si ya fue eliminada o el dato no cumple una regla; 403 (42501) sin permiso o si un docente toca una actividad que no creó (Regla 25); 409 (23503) si ya tiene resultados registrados o es la original de una recuperación (Regla 37).',
       $q$SELECT academico_test.fn_actividad_estudiantes_set(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.FK_TMATRICULAS AS BIGINT[]),
    COALESCE(CAST(:BODY.ASIGNAR_TODO_EL_GRUPO AS BOOLEAN), FALSE)
) AS total_asignados;$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- POST /planeador/actividades/:ID/evidencias
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT '743909b1-11b6-418a-abf8-43370a30a9d5', m.id_microservice, '/planeador/actividades/:ID/evidencias', 'POST', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL,
       '{"PARAM.ID": "BIGINT", "BODY.FK_REFERENTE_ENUNCIADO": "BIGINT"}'::jsonb,
       'Marca una evidencia en la actividad :ID (fn_actividad_evidencia_relacionar). BODY.FK_REFERENTE_ENUNCIADO: evidencia (segundo nivel) de un enunciado seleccionado en la unidad de la actividad, del referente de la unidad y de su grado (Regla 12). La actividad sin unidad no admite evidencias. Devuelve PK_TACTIVIDAD_EVIDENCIA. Errores: 404 (P0002) si no existe; 422 (22023) si ya fue eliminada o el dato no cumple una regla; 403 (42501) sin permiso o si un docente toca una actividad que no creó (Regla 25); 409 (23503) si ya tiene resultados registrados o es la original de una recuperación (Regla 37).',
       $q$SELECT academico_test.fn_actividad_evidencia_relacionar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.FK_REFERENTE_ENUNCIADO AS BIGINT)
) AS pk_tactividad_evidencia;$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- PUT /planeador/actividades/:ID/instrumento
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT '7e62d759-8a6d-4749-bd46-548e5a4d018c', m.id_microservice, '/planeador/actividades/:ID/instrumento', 'PUT', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL,
       '{"PARAM.ID": "BIGINT", "BODY.DEFINICION": "JSONB"}'::jsonb,
       'Define (reemplazo completo) el instrumento de evaluación de la actividad :ID según el que tenga elegido (fn_actividad_instrumento_definir): BODY.DEFINICION es el arreglo de criterios (rúbrica), de ítems (lista de cotejo), el objeto de la escala, o {tipoEvidencia, metodoValoracion, definicion} para Otro. Errores: 404 (P0002) si no existe; 422 (22023) si ya fue eliminada o el dato no cumple una regla; 403 (42501) sin permiso o si un docente toca una actividad que no creó (Regla 25); 409 (23503) si ya tiene resultados registrados o es la original de una recuperación (Regla 37).',
       $q$SELECT academico_test.fn_actividad_instrumento_definir(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.DEFINICION AS JSONB)
) AS instrumento_aplicado;$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- PUT /planeador/actividades/:ID/materiales
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT 'f0120e99-16c9-424d-9625-871c9b955739', m.id_microservice, '/planeador/actividades/:ID/materiales', 'PUT', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL,
       '{"PARAM.ID": "BIGINT", "BODY.MATERIALES": "JSONB"}'::jsonb,
       'Reemplaza los materiales de apoyo de la actividad :ID (fn_actividad_material_reemplazar). BODY.MATERIALES = [{tipoRecurso, url | fkTarchivo, descripcion?}], máximo 10 (Regla 82); el enlace debe ser http(s) y el archivo el devuelto por POST :ID/materiales/archivo. Arreglo vacío = sin materiales. Errores: 404 (P0002) si no existe; 422 (22023) si ya fue eliminada o el dato no cumple una regla; 403 (42501) sin permiso o si un docente toca una actividad que no creó (Regla 25); 409 (23503) si ya tiene resultados registrados o es la original de una recuperación (Regla 37).',
       $q$SELECT academico_test.fn_actividad_material_reemplazar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.MATERIALES AS JSONB)
) AS cantidad;$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- POST /planeador/actividades/:ID/materiales/archivo
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT 'eval-col-actividad-material-archivo-001', m.id_microservice, '/planeador/actividades/:ID/materiales/archivo', 'POST', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', 'actividad-material-archivo', 'DEFAULT',
       '{"PARAM.ID": "BIGINT", "BODY.ARCHIVO": "FILE:actividad"}'::jsonb,
       'Paso 1 de un material tipo archivo: multipart con el campo ARCHIVO por file-service; devuelve el fk_tarchivo que se envía como fkTarchivo en PUT :ID/materiales (fn_actividad_material_archivo_registrar). Errores: 404 (P0002) si no existe; 422 (22023) si ya fue eliminada o el dato no cumple una regla; 403 (42501) sin permiso o si un docente toca una actividad que no creó (Regla 25); 409 (23503) si ya tiene resultados registrados o es la original de una recuperación (Regla 37).',
       $q$SELECT academico_test.fn_actividad_material_archivo_registrar(
    p_pk_usuario_solicitante => public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    p_pk_tactividad          => CAST(:PARAM.ID AS BIGINT),
    p_fk_tarchivo            => CAST(:BODY.ARCHIVO AS BIGINT)
) AS fk_tarchivo;$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- PATCH /planeador/actividades/criterios/:ID
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT '617d3c6e-c89f-463f-b88b-113c1347e217', m.id_microservice, '/planeador/actividades/criterios/:ID', 'PATCH', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL,
       '{"PARAM.ID": "BIGINT"}'::jsonb,
       'Retira el criterio :ID (PK_TACTIVIDAD_CRITERIO_UNIDAD) de su actividad (fn_actividad_criterio_quitar). Errores: 404 (P0002) si no existe; 422 (22023) si ya fue eliminada o el dato no cumple una regla; 403 (42501) sin permiso o si un docente toca una actividad que no creó (Regla 25); 409 (23503) si ya tiene resultados registrados o es la original de una recuperación (Regla 37).',
       $q$SELECT academico_test.fn_actividad_criterio_quitar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
) AS eliminado;$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- PATCH /planeador/actividades/evidencias/:ID
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT 'bdf2337d-3b7f-403c-a0c5-626f0398f92b', m.id_microservice, '/planeador/actividades/evidencias/:ID', 'PATCH', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL,
       '{"PARAM.ID": "BIGINT"}'::jsonb,
       'Desmarca la evidencia :ID (PK_TACTIVIDAD_EVIDENCIA) de su actividad (fn_actividad_evidencia_quitar). Al confirmar se exige que quede al menos una (Regla 43). Errores: 404 (P0002) si no existe; 422 (22023) si ya fue eliminada o el dato no cumple una regla; 403 (42501) sin permiso o si un docente toca una actividad que no creó (Regla 25); 409 (23503) si ya tiene resultados registrados o es la original de una recuperación (Regla 37).',
       $q$SELECT academico_test.fn_actividad_evidencia_quitar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
) AS eliminado;$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- GET /planeador/actividades/:ID/pantalla-edicion
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT 'q-planeador-actividad-pantalla-edicion', m.id_microservice, '/planeador/actividades/:ID/pantalla-edicion', 'GET', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL,
       '{"PARAM.ID": "BIGINT", "QUERY.DIAS_GRACIA": "INTEGER"}'::jsonb,
       'V353 -- DTO compuesto para PlaneadorEditarActividadPage: actividad + instrumento en una sola llamada, ya en camelCase y anidado por concepto. Reemplaza, PARA ESA PANTALLA, la cadena GET .../:ID + GET .../:ID/instrumento. Incluye ademas evidencias (TACTIVIDAD_EVIDENCIA: [{pk, fkReferenteEnunciado, texto, fkPadre, textoPadre}]) y criterios (TACTIVIDAD_CRITERIO_UNIDAD: [{pk, fkTcriterioUnidad, descripcion, codigo, orden}]) ya relacionados, para poder pre-marcarlos al reabrir la actividad y para conocer el pk que exigen PATCH /planeador/actividades/evidencias/:ID y PATCH /planeador/actividades/criterios/:ID. Y estudiantes ([{pkTactividadEstudiante, pkTmatricula, fkTestudiante, estudiante, calificacion, calificable, observacion}]): los asignados, con el pk de la asignacion que piden calificar, observar y las adaptaciones. V475 -- Correccion del parrafo anterior: una actividad SIN unidad ya NO devuelve FALSE por defecto. Su referente se deriva del grado del grupo y la asignatura (fn_unidad_referente_aplicable), asi que una actividad de Preescolar sin unidad responde es_formativa = true, como corresponde a su referente y como ya la pintaba GET /planeador/actividades/configuracion. Solo queda FALSE si no hay ningun referente activo para ese (grado, asignatura).',
       $q$SELECT t.p || jsonb_build_object(
           'esFormativa',
           academico_test.fn_actividad_es_formativa((t.p->'actividad'->>'id')::BIGINT)
       ) AS pantalla
  FROM (SELECT academico_test.fn_actividad_pantalla_edicion(
            public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
            CAST(:PARAM.ID AS BIGINT),
            COALESCE(CAST(:QUERY.DIAS_GRACIA AS INT), 2)
        ) AS p) t$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- GET /planeador/actividades/configuracion
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT 'eval-col-planeador-actividad-configuracion-001', m.id_microservice, '/planeador/actividades/configuracion', 'GET', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL,
       '{"QUERY.GRUPO": "BIGINT", "QUERY.UNIDAD": "BIGINT", "QUERY.RECUPERAR": "VARCHAR", "QUERY.ASIGNATURA": "BIGINT", "QUERY.ES_SUMATIVO": "VARCHAR", "QUERY.ACTIVIDAD_RECUPERAR": "BIGINT"}'::jsonb,
       'Que pintar en el formulario de actividad a partir de los DOS filtros de la pantalla: ?grupo= y ?asignatura= (obligatorios), con ?unidad= OPCIONAL. Con unidad manda la unidad (referente y metodo de calculo); sin unidad el referente se deriva del grado + asignatura (fn_unidad_referente_aplicable). origenConfiguracion dice cual camino se uso (CONTEXTO o UNIDAD). Devuelve el contexto resuelto (grupo, grado, nivelEnsenanza, asignatura, referente {pk, nombre}), programacion (limites de fechaInicio/fechaCierre, semanaCronograma, duracionEstimada e intensidadHoraria a partir del periodo academico del grado y del horario) y campos_disponibles con la MISMA forma que GET /planeador/unidades/:ID/configuracion-actividad y GET /planeador/actividades/:ID/configuracion: criterio {visible, requerido, motivo}, evaluacion {visible, requerido, motivo, tipoEvaluacion, instrumentosPermitidos:[{pk, valor, nombre, variantes, campos}]}, ponderacion {visible, requerido, modo, campo?, autocalculado?, motivo} y recuperacion {visible, requerido, motivo, catalogos, reglas}. ?ES_SUMATIVO=S|N (default S: si no se envia, se responde la configuracion de una actividad sumativa) es lo que el usuario acaba de marcar en el formulario; con N SOLO se apagan recuperacion (una recuperacion debe ser sumativa) y ponderacion (la escritura la rechaza); la seccion de evaluacion y sus instrumentosPermitidos salen del referente igual que con S. En instrumentosPermitidos la entrada OTRO trae `campos`: tipoEvidencia {catalogo TIPO_EVIDENCIA_OTRO}, metodoValoracion {catalogo: los demas instrumentos que admite el tipo de evaluacion del referente, con variantes de escala}, definicion {formaPorMetodo}, descripcionInstrumento, requiereArchivo y requiereTexto; los demas instrumentos traen campos = null. El front decide por VALOR: los pk no son estables entre entornos. Recuperacion: ?RECUPERAR=S (la casilla "es una recuperacion") hace que recuperacion.actividadesRecuperables liste las actividades sumativas del (grupo, asignatura) que aun se pueden recuperar (ES_EVALUATIVA = S, no son recuperacion, sin otra recuperacion activa) -- el selector "Que desea recuperar"; ?ACTIVIDAD_RECUPERAR=<PK_TACTIVIDAD> devuelve recuperacion.origen con el contexto que el formulario hereda e inhabilita (grado, grupo, asignatura, unidad, tituloBase) y los estudiantes asignados a esa actividad con su notaPrevia, todos seleccionado=true para que el docente desmarque los que no la necesitan y envie los restantes en BODY.FK_TMATRICULAS del POST; 404/422 si la origen no existe, no es sumativa, ya es recuperacion o es de otra asignatura. recuperacion.reglas dice que tipoCalculo se oculta con REEMPLAZAR y se exige con COMPUTAR. En nivel Preescolar (formativo por definicion) evaluacion y recuperacion vienen visible=false. El arbol de enunciados y evidencias NO viene aqui: GET /planeador/referente-curricular?grado=&asignatura=. Gate VER sobre PLANEADOR + alcance por el grupo; 404 (P0002) si el grupo, la asignatura o la unidad no existen. V476 -- La respuesta gana esFormativo (boolean) y esSumativoSugerido (S|N) al lado de esSumativoConsultado: el primero es lo que el usuario pregunto, estos dos son lo que el referente DICTA. Con referente Formativo (y en Preescolar, formativo por definicion) esSumativoSugerido = N: es lo que el front debe traer marcado y lo que POST /planeador/actividades guarda si no envia es_evaluativa. Enviar es_evaluativa = S contra un referente Formativo se rechaza con 422 (22023), venga o no la actividad con unidad.',
       $q$SELECT academico_test.fn_actividad_configuracion_contexto(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.GRUPO AS BIGINT),
    CAST(:QUERY.ASIGNATURA AS BIGINT),
    CAST(:QUERY.UNIDAD AS BIGINT),
    COALESCE(CAST(:QUERY.ES_SUMATIVO AS VARCHAR), 'S'),
    COALESCE(CAST(:QUERY.RECUPERAR AS VARCHAR), 'N'),
    CAST(:QUERY.ACTIVIDAD_RECUPERAR AS BIGINT)
) AS configuracion;$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- Roles: el docente planea sus actividades; el super admin administra.
-- configuracion va aquí porque V422 ya no crea la fila.
INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id AND m.serviceid = 'eval-col'
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR', 'CEVAL-DOCENTE')
 WHERE (q.http_method, q.path_template) IN (
        ('POST', '/planeador/actividades'),
        ('PATCH', '/planeador/actividades/:ID'),
        ('PUT', '/planeador/actividades/:ID'),
        ('PUT', '/planeador/actividades/:ID/adaptaciones'),
        ('POST', '/planeador/actividades/:ID/adaptaciones/archivo'),
        ('POST', '/planeador/actividades/:ID/criterios'),
        ('PUT', '/planeador/actividades/:ID/estudiantes'),
        ('POST', '/planeador/actividades/:ID/evidencias'),
        ('PUT', '/planeador/actividades/:ID/instrumento'),
        ('PUT', '/planeador/actividades/:ID/materiales'),
        ('POST', '/planeador/actividades/:ID/materiales/archivo'),
        ('PATCH', '/planeador/actividades/criterios/:ID'),
        ('PATCH', '/planeador/actividades/evidencias/:ID'),
        ('GET', '/planeador/actividades/configuracion'))
ON CONFLICT DO NOTHING;

-- La pantalla de edición la ve quien ve el detalle de la actividad.
INSERT INTO public.role_query (role_id, query_id)
SELECT rq.role_id, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id AND m.serviceid = 'eval-col'
  JOIN public.query d ON d.microservice_id = q.microservice_id
                     AND d.path_template = '/planeador/actividades/:ID' AND d.http_method = 'GET'
  JOIN public.role_query rq ON rq.query_id = d.id_query
 WHERE q.path_template = '/planeador/actividades/:ID/pantalla-edicion' AND q.http_method = 'GET'
ON CONFLICT DO NOTHING;
