-- ===========================================================================
-- V429 - La biblioteca de recursos tambien sirve al CREAR una actividad.
--
--   fn_actividad_materiales_reutilizables_listar  (gana ancla por grupo y
--                                                  filtro por establecimiento)
--   GET /planeador/materiales-reutilizables       (ruta sin :ID)
--
--
-- EL PROBLEMA
--   La biblioteca -- los archivos ya subidos en OTRAS actividades, para
--   reusarlos sin volver a cargarlos -- solo se podia consultar desde una
--   actividad que YA existiera. No por la consulta, sino por el gate:
--
--       fn_planeador_assert_alcance(usuario, 'VER', NULL, NULL, NULL,
--                                   p_pk_tactividad)
--
--   ese gate resuelve el alcance territorial A PARTIR de la actividad. Sin
--   actividad no hay sede que mirar y responde 42501 -- probado con un
--   docente real; solo el super admin pasaba, por su bypass de nivel 0.
--
--   Y al crear una actividad no hay id todavia: los materiales se guardan
--   despues, cuando la actividad ya existe. Con lo cual la pantalla donde la
--   biblioteca es MAS util -- el alta, cuando el docente esta armando la
--   actividad -- era justo donde no se podia usar.
--
--
-- EL ANCLA ALTERNATIVA: EL GRUPO
--   En el alta el formulario ya tiene grupo y asignatura elegidos antes de
--   llegar a la seccion de Recursos, y fn_planeador_assert_alcance acepta el
--   grupo como ancla -- es lo mismo que hace fn_actividad_configuracion_
--   contexto para pintar el formulario sin actividad todavia.
--
--   Queda entonces: con actividad, se ancla en la actividad (como hoy); sin
--   actividad, en el grupo; sin ninguna de las dos, 22023 pidiendo una. NO se
--   deja pasar sin ancla: sin un punto donde resolver el alcance, el gate no
--   verifica nada y la biblioteca se convierte en "todos los archivos del
--   sistema".
--
--
-- DE PASO SE CIERRA UNA FUGA
--   La consulta NO filtraba los resultados por establecimiento. El gate
--   miraba la actividad que se pasaba, pero el SELECT recorria
--   TACTIVIDAD_MATERIAL entero: un docente de un colegio, pasando una
--   actividad suya, recibia los archivos de CUALQUIER otro colegio.
--
--   Hoy no se nota porque no hay un solo material con archivo en la base
--   (medido: 4 materiales activos, 0 con FK_TARCHIVO), asi que la consulta
--   siempre devuelve vacio. En cuanto empiecen a subirse archivos, se
--   notaria -- y habilitar el ancla por grupo sin arreglar esto lo abriria
--   mas, porque el alta no acota a ninguna actividad.
--
--   Ahora los resultados se limitan al establecimiento del ancla. No se
--   acota al propio docente: una biblioteca institucional tiene sentido
--   justamente para reusar lo que subio un colega del mismo colegio, y quien
--   quiera solo lo suyo ya tiene el filtro p_fk_tfuncionario.
--
--   Las actividades sin grupo (huerfanas) quedan fuera: sin grupo no hay
--   establecimiento que comparar, y ante la duda no se muestran.
--
--
-- LA RUTA NUEVA NO REEMPLAZA A LA VIEJA
--   GET /planeador/actividades/:ID/materiales-reutilizables sigue existiendo
--   y funcionando igual. Se agrega GET /planeador/materiales-reutilizables,
--   que recibe ACTIVIDAD y GRUPO como query string opcionales, para que el
--   front tenga UN solo camino: manda la actividad cuando la hay y el grupo
--   cuando todavia no.
--
-- Idempotente: CREATE OR REPLACE (misma firma mas un parametro con DEFAULT,
-- que no crea sobrecarga) e INSERT ... ON CONFLICT DO NOTHING.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 1. La funcion: ancla por grupo y resultados acotados al establecimiento.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_materiales_reutilizables_listar(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT  DEFAULT NULL,
    p_fk_tasignatura         BIGINT  DEFAULT NULL,
    p_fk_tfuncionario        BIGINT  DEFAULT NULL,
    p_search                 VARCHAR DEFAULT NULL,
    p_pagina                 INTEGER DEFAULT 1,
    p_tamano_pagina          INTEGER DEFAULT 20,
    -- V429 -- el ancla del alta. Va al final y con DEFAULT para no romper a
    -- quien ya llama por posicion.
    p_fk_tgrupo              BIGINT  DEFAULT NULL
)
RETURNS TABLE(
    fk_tarchivo             BIGINT,
    nombre_archivo          VARCHAR,
    peso                    BIGINT,
    pk_tactividad_origen    BIGINT,
    titulo_actividad_origen VARCHAR,
    fk_tlv_tipo_recurso     BIGINT,
    tipo_recurso            VARCHAR,
    descripcion             VARCHAR,
    total_count             BIGINT
)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_limite INT;
    v_offset INT;
    v_grupo  BIGINT;
    v_ee     BIGINT;
BEGIN
    -- V429 -- El ancla: la actividad si la hay, el grupo si no. Sin ninguna
    -- de las dos no hay donde resolver el alcance, y dejar pasar convertiria
    -- la biblioteca en "todos los archivos del sistema".
    IF p_pk_tactividad IS NULL AND p_fk_tgrupo IS NULL THEN
        RAISE EXCEPTION 'Indique la actividad o el grupo para consultar la biblioteca de recursos'
            USING ERRCODE = '22023',
                  HINT    = 'Al editar se manda la actividad; al crear, el grupo que ya eligio el formulario';
    END IF;

    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER',
        CASE WHEN p_pk_tactividad IS NULL THEN p_fk_tgrupo END,
        NULL, NULL, p_pk_tactividad
    );

    -- El establecimiento al que se acotan los resultados sale del mismo
    -- ancla: el grupo de la actividad, o el grupo suelto del alta.
    v_grupo := COALESCE(
        p_fk_tgrupo,
        (SELECT a.FK_TGRUPO FROM academico_test.TACTIVIDAD a
          WHERE a.PK_TACTIVIDAD = p_pk_tactividad)
    );
    v_ee := academico_test.fn_grupo_establecimiento(v_grupo);

    v_limite := GREATEST(COALESCE(p_tamano_pagina, 20), 1);
    v_offset := (GREATEST(COALESCE(p_pagina, 1), 1) - 1) * v_limite;

    RETURN QUERY
    SELECT t.PK_TARCHIVO,
           t.NOMBRE,
           t.PESO,
           a.PK_TACTIVIDAD,
           a.TITULO,
           m.FK_TLV_TIPO_RECURSO,
           lv.NOMBRE,
           m.DESCRIPCION,
           COUNT(*) OVER()
      FROM academico_test.TACTIVIDAD_MATERIAL m
      JOIN academico_test.TACTIVIDAD a  ON a.PK_TACTIVIDAD = m.FK_TACTIVIDAD AND a.ACTIVE = TRUE
      JOIN academico_test.TARCHIVO t    ON t.PK_TARCHIVO = m.FK_TARCHIVO AND t.ACTIVE = TRUE
      LEFT JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = m.FK_TLV_TIPO_RECURSO
      LEFT JOIN academico_test.TUNIDAD u ON u.PK_TUNIDAD = a.FK_TUNIDAD
     WHERE m.ACTIVE = TRUE
       AND m.FK_TARCHIVO IS NOT NULL
       AND (p_pk_tactividad IS NULL OR a.PK_TACTIVIDAD <> p_pk_tactividad)
       AND (p_fk_tasignatura  IS NULL OR a.FK_TASIGNATURA = p_fk_tasignatura)
       AND (p_fk_tfuncionario IS NULL OR u.FK_TFUNCIONARIO = p_fk_tfuncionario)
       -- V429 -- mismo establecimiento que el ancla. Una actividad sin grupo
       -- no tiene establecimiento que comparar y queda fuera: ante la duda,
       -- no se muestra.
       AND (v_ee IS NULL
            OR academico_test.fn_grupo_establecimiento(a.FK_TGRUPO) = v_ee)
       AND (p_search IS NULL OR TRIM(p_search) = ''
            OR t.NOMBRE ILIKE '%' || TRIM(p_search) || '%'
            OR a.TITULO ILIKE '%' || TRIM(p_search) || '%')
     ORDER BY t.NOMBRE, a.TITULO
     LIMIT v_limite
    OFFSET v_offset;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_actividad_materiales_reutilizables_listar(BIGINT, BIGINT, BIGINT, BIGINT, VARCHAR, INTEGER, INTEGER, BIGINT)
    IS 'La "biblioteca de recursos": archivos ya subidos en OTRAS actividades, para reusarlos sin volver a cargarlos. Solo trae materiales CON archivo -- un enlace no se reutiliza, se copia. V429 le agrega el ancla por GRUPO: antes el alcance se resolvia unicamente desde la actividad y por eso respondia 42501 cuando no habia ninguna, que es justo el caso del ALTA, donde la biblioteca es mas util; ahora con actividad se ancla en la actividad, sin ella en el grupo, y sin ninguna de las dos levanta 22023 en vez de dejar pasar sin verificar nada. V429 tambien acota los RESULTADOS al establecimiento del ancla: antes el gate miraba la actividad que se pasaba pero el SELECT recorria TACTIVIDAD_MATERIAL entero, asi que un docente recibia los archivos de cualquier otro colegio -- no se notaba porque no hay ningun material con archivo en la base todavia. No se acota al propio docente a proposito: una biblioteca institucional sirve para reusar lo que subio un colega del mismo colegio, y quien quiera solo lo suyo tiene p_fk_tfuncionario. Las actividades sin grupo quedan fuera: sin grupo no hay establecimiento que comparar.';


-- ---------------------------------------------------------------------------
-- 2. La ruta sin :ID, para el alta.
--
--    La de siempre (/planeador/actividades/:ID/materiales-reutilizables) se
--    deja intacta. Esta recibe ACTIVIDAD y GRUPO por query string, asi el
--    front tiene UN solo camino: manda la actividad cuando la hay y el grupo
--    cuando todavia no existe.
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action, style)
SELECT
    'eval-col-materiales-reutilizables-001',
    'SELECT * FROM academico_test.fn_actividad_materiales_reutilizables_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.ACTIVIDAD AS BIGINT),
    CAST(:QUERY.ASIGNATURA AS BIGINT),
    CAST(:QUERY.FUNCIONARIO AS BIGINT),
    CAST(:QUERY.SEARCH AS VARCHAR),
    COALESCE(CAST(:QUERY.PAGINA AS INT), 1),
    COALESCE(CAST(:QUERY.SIZE AS INT), 20),
    CAST(:QUERY.GRUPO AS BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/planeador/materiales-reutilizables', 'SELECT', 'GET',
    '{"QUERY.ACTIVIDAD": "BIGINT", "QUERY.GRUPO": "BIGINT", "QUERY.ASIGNATURA": "BIGINT", "QUERY.FUNCIONARIO": "BIGINT", "QUERY.SEARCH": "VARCHAR", "QUERY.PAGINA": "INT", "QUERY.SIZE": "INT"}'::jsonb,
    NULL,
    'Biblioteca de recursos: los archivos subidos en otras actividades, para reusarlos. Misma funcion que GET /planeador/actividades/:ID/materiales-reutilizables, pero con la actividad como parametro OPCIONAL de query string, para poder consultarla mientras se CREA una actividad (cuando todavia no hay id). En ese caso se manda GRUPO, que es lo que el formulario ya tiene elegido y lo que permite resolver el alcance del usuario. Hay que mandar ACTIVIDAD o GRUPO: sin ninguno responde 22023. Los resultados se limitan al establecimiento de ese ancla. Solo trae materiales CON archivo. Pagina con PAGINA (1-based) y SIZE, y busca por nombre de archivo o titulo de la actividad de origen.',
    'materiales-reutilizables', 'DEFAULT'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;


-- ---------------------------------------------------------------------------
-- 3. Roles: los mismos de la ruta hermana, que es la misma consulta.
-- ---------------------------------------------------------------------------
INSERT INTO public.role_query (query_id, role_id)
SELECT nuevo.id_query, rq.role_id
  FROM public.query nuevo
  JOIN public.query hermano
    ON hermano.microservice_id = nuevo.microservice_id
   AND hermano.path_template   = '/planeador/actividades/:ID/materiales-reutilizables'
   AND hermano.http_method     = 'GET'
  JOIN public.role_query rq ON rq.query_id = hermano.id_query
 WHERE nuevo.uuid = 'eval-col-materiales-reutilizables-001'
ON CONFLICT DO NOTHING;
