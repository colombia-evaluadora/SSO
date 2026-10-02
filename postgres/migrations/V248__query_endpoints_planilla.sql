-- ===========================================================================
-- V248 — Planeador: endpoints del filtro Grado -> Grupo -> Asignatura del
-- docente y del peso disponible de unidad, con su role_query de super admin.
--   GET /planeador/docentes/grupos                    (fn_docente_grupos_listar)
--   GET /planeador/docentes/grado-asignatura          (fn_docente_grado_asignatura_listar)
--   GET /planeador/asignaturas/:ID/ponderacion-disponible
--                                                     (fn_asignatura_grado_ponderacion_disponible)
-- Los de la planilla de calificación viven en V469.5. El docente sale del
-- token (fn_get_academico_usuario_id); el gate real lo hace cada función.
-- Depende de: V239 (peso de unidad), V242 (filtro docente).
-- ===========================================================================

SET search_path TO academico_test, public;

-- ===========================================================================
-- 3. GET /planeador/docentes/grupos —
--    fn_docente_grupos_listar (V242; paso 1-2 del filtro en cascada
--    Grado -> Grupo -> Asignatura para el DOCENTE autenticado).
--
--    p_fk_tfuncionario se resuelve AQUI, en el query-service, con el mismo
--    patron de la rama de Asistencias (CU-86e32gvpp): NUNCA se recibe del
--    cliente. Si el usuario autenticado no es funcionario activo, la
--    subconsulta da NULL y la funcion devuelve vacio (ver DECISION en la
--    cabecera de esta migracion -- confirmado NULL-safe).
-- ===========================================================================
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_docente_grupos_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.PERIODO AS BIGINT),
    NULL
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/docentes/grupos', 'SELECT', 'GET',
    '{"QUERY.PERIODO": "BIGINT"}'::jsonb,
    'V248 -- paso 1-2 del filtro en cascada Grado -> Grupo -> Asignatura de la pantalla "Planilla de calificacion" (V239) para el DOCENTE autenticado: grupos (con su grado y nivel de ensenanza) donde el docente dicta al menos una asignatura en el periodo pedido (fn_docente_grupos_listar, V242). ?periodo= es OPCIONAL: si no se envia, la funcion lo deduce de las propias asignaciones del docente (fn_docente_periodo_vigente, V250 -- el vigente por fechas o, si ninguno lo esta, el mas reciente), asi el front no necesita conocer el PK_TPERIODO_ACADEMICO para pintar la pantalla. El docente tampoco se envia: la funcion lo resuelve del token (fn_funcionario_actual). Si el usuario autenticado no es funcionario activo (o no dicta nada en ese periodo), responde 200 con lista vacia, no error (confirmado NULL-safe leyendo V242). Cada fila trae grupo_id/codigo/nombre, grupo_etiqueta ("<grado> <grupo>", lista para pintar: CODIGO viene NULL y NOMBRE es "01" en todos los grupos, asi que sin ella el selector no los distingue), capacidad, jornada (id/valor/nombre), modelo_pedagogico (id/valor/nombre), grado (id/codigo/nombre) y nivel_ensenanza (id/nombre). Sin paginar (universo de un docente en un periodo). Gate VER sobre PLANEADOR + fn_periodo_usuario_puede_ver. NO usar TGRUPO.FK_TFUNCIONARIO (ese es el director de grupo, no el docente de la asignatura).'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/docentes/grupos'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;


-- ===========================================================================
-- 4. GET /planeador/docentes/grado-asignatura —
--    fn_docente_grado_asignatura_listar (V242; paso 3 del filtro en cascada,
--    pares Grado-Asignatura del DOCENTE autenticado). Mismo patron de
--    resolucion de p_fk_tfuncionario que el punto 3.
-- ===========================================================================
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_docente_grado_asignatura_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.PERIODO AS BIGINT),
    NULL
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/docentes/grado-asignatura', 'SELECT', 'GET',
    '{"QUERY.PERIODO": "BIGINT"}'::jsonb,
    'V248 -- paso 3 del filtro en cascada Grado -> Grupo -> Asignatura de la pantalla "Planilla de calificacion" (V239) para el DOCENTE autenticado: pares (grado, asignatura) DISTINTOS que dicta en el periodo pedido, sin repetir por tener la misma asignatura en varios grupos del mismo grado (fn_docente_grado_asignatura_listar, V242). ?periodo= es OPCIONAL (se deduce igual que en GET /planeador/docentes/grupos, punto 3); el docente sale del token. NULL-safe: un usuario no-funcionario responde 200 con lista vacia. Cada fila trae grado (id/codigo/nombre) y asignatura (id/codigo/nombre). Sin paginar. Gate VER sobre PLANEADOR + fn_periodo_usuario_puede_ver.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/docentes/grado-asignatura'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;


-- ===========================================================================
-- 5. GET /planeador/asignaturas/:ID/ponderacion-disponible —
--    fn_asignatura_grado_ponderacion_disponible (V239; "Disponible para
--    asignar: X%" del peso de una UNIDAD dentro de su asignatura+grado --
--    ver DECISION en la cabecera sobre por que se expone en este lote).
-- ===========================================================================
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT academico_test.fn_asignatura_grado_ponderacion_disponible(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:QUERY.GRADO AS BIGINT)
) AS ponderacion_disponible;',
    'postgres', false, false,
    m.id_microservice, '/planeador/asignaturas/:ID/ponderacion-disponible', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT", "QUERY.GRADO": "BIGINT"}'::jsonb,
    'V248 -- porcentaje LIBRE para repartir entre las UNIDADES de una (asignatura, grado): 100 - fn_unidad_ponderacion_intra_asignatura_asignada(asignatura, grado) (fn_asignatura_grado_ponderacion_disponible, V239). :ID = PK_TASIGNATURA, ?grado= obligatorio (PK_TGRADO). Alimenta el "Disponible para asignar: X%" del campo TUNIDAD.PONDERACION en el formulario de unidad (fn_unidad_crear/fn_unidad_actualizar, V216) -- analogo, un nivel arriba, de GET /planeador/unidades/:ID/ponderacion-disponible (V245 punto 18, que reparte el peso de las ACTIVIDADES dentro de UNA unidad; este reparte el peso de las UNIDADES dentro de una asignatura+grado). Acotado a >= 0. Gate VER sobre PLANEADOR. 404 (P0002) si la asignatura o el grado no existen/no estan activos.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/asignaturas/:ID/ponderacion-disponible'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

-- ===========================================================================
-- Sincronizacion de la fila de grupos del docente (?periodo= opcional; la de
-- grado-asignatura la reescribe V497).
--
-- Los INSERT de arriba llevan ON CONFLICT DO NOTHING, asi que en un ambiente
-- donde ya estaban registradas NO actualizarian su SQL, y seguirian exigiendo
-- el periodo y resolviendo el funcionario por fuera. Estos UPDATE dejan esas
-- filas iguales a las de un ambiente nuevo -- es lo que hace re-aplicable el
-- archivo.
-- ===========================================================================
UPDATE public.query q
   SET query = 'SELECT * FROM academico_test.fn_docente_grupos_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.PERIODO AS BIGINT),
    NULL
);'
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/docentes/grupos'
   AND q.http_method     = 'GET';
