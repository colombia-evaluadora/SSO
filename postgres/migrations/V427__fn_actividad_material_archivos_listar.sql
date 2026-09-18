-- ===========================================================================
-- V427 - Los nombres de los archivos de los materiales de una actividad.
--
--   fn_actividad_material_archivos_listar
--   GET /planeador/actividades/:ID/materiales/archivos
--
--
-- PARA QUE
--   El detalle de la actividad (fn_actividad_buscar_por_pk) devuelve cada
--   material con su `fkTarchivo`, pero NO con el nombre del archivo. Sin
--   nombre no hay extension, y sin extension el front no puede saber si lo
--   que hay del otro lado es un PDF, una foto, un audio o un video -- ni
--   siquiera puede rotular la fila con algo distinto de "Archivo 490848".
--
--   Esta funcion cierra ese hueco: dado el id de la actividad, devuelve una
--   fila por material-con-archivo, con el nombre y la extension ya resuelta.
--
--
-- POR QUE UN ENDPOINT NUEVO Y NO DOS CLAVES MAS EN EL DETALLE
--   Lo natural seria agregar 'nombre' al jsonb_build_object de los materiales
--   dentro de fn_actividad_buscar_por_pk. Se descarto por una razon concreta,
--   no por prolijidad:
--
--   Esa funcion la define V224 y NADIE mas. Para tocarla hay dos caminos y
--   los dos son peores que este:
--
--     * Editar V224 -- es lo que el equipo hace con las migraciones del
--       planeador (ver el orden de re-aplicacion en
--       docs/planeador/mapa-flujo-crear-actividad.md), pero obliga a
--       re-ejecutar TODO el set en orden, y re-aplicar V224 sola resucita la
--       version vieja de fn_actividad_calendario que redefine V251.
--     * Copiarla entera en una migracion nueva -- congela en V427 una copia
--       de 333 lineas de la version de hoy. La proxima vez que alguien edite
--       V224, su cambio se pierde en silencio, porque la migracion posterior
--       gana. Es exactamente el problema que ese documento describe.
--
--   Medido ademas: la version VIVA en el servidor de test esta atrasada
--   respecto de V224 (no trae `evidencias` ni `criterios`), asi que generar
--   la copia desde el servidor habria publicado una regresion.
--
--   Una funcion aditiva no tiene ninguno de esos problemas. El costo es una
--   llamada mas al abrir la pantalla de edicion, sobre una lista que en la
--   practica tiene cero o un par de filas.
--
--
-- LA EXTENSION SE RESUELVE ACA
--   TARCHIVO.NOMBRE conserva la extension en 446.098 de las 480.002 filas
--   activas. Las que no -- historicas migradas, con nombres como
--   "guia2compsocioemo10" -- la tienen igual en URLS3, que es la clave del
--   objeto y siempre termina en el sufijo real. Se prueba el nombre primero y
--   se cae a la clave, para que el front reciba SIEMPRE el mismo dato y no
--   tenga que conocer esa historia.
--
--   URLS3 no viaja: es una ruta interna del bucket y no le sirve a nadie del
--   otro lado. Lo que viaja es la extension ya extraida.
--
-- Idempotente: CREATE OR REPLACE, e INSERT ... ON CONFLICT DO NOTHING.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 1. Un registro por material con archivo.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_material_archivos_listar(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT
)
RETURNS TABLE(
    pk_tactividad_material BIGINT,
    fk_tarchivo            BIGINT,
    nombre                 VARCHAR,
    extension              VARCHAR,
    peso                   BIGINT
)
LANGUAGE plpgsql
STABLE
AS $function$
BEGIN
    -- Mismo gate de LECTURA que el detalle de la actividad, resuelto desde la
    -- propia actividad: quien puede abrirla puede ver los nombres de sus
    -- archivos.
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', NULL, NULL, NULL, p_pk_tactividad);

    RETURN QUERY
    SELECT m.PK_TACTIVIDAD_MATERIAL,
           t.PK_TARCHIVO,
           t.NOMBRE,
           -- Primero el nombre; si no trae sufijo, la clave S3. En minuscula
           -- y sin el punto, para que el consumidor no tenga que normalizar.
           LOWER(COALESCE(
               SUBSTRING(t.NOMBRE FROM '\.([A-Za-z0-9]{2,5})$'),
               SUBSTRING(t.URLS3  FROM '\.([A-Za-z0-9]{2,5})$')
           ))::VARCHAR,
           t.PESO
      FROM academico_test.TACTIVIDAD_MATERIAL m
      JOIN academico_test.TARCHIVO t
        ON t.PK_TARCHIVO = m.FK_TARCHIVO
       AND t.ACTIVE = TRUE
     WHERE m.FK_TACTIVIDAD = p_pk_tactividad
       AND m.ACTIVE = TRUE
       AND m.FK_TARCHIVO IS NOT NULL
     ORDER BY m.ORDEN, m.PK_TACTIVIDAD_MATERIAL;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_actividad_material_archivos_listar(BIGINT, BIGINT)
    IS 'Nombre y extension de los archivos de los materiales de apoyo de una actividad. Existe porque el detalle (fn_actividad_buscar_por_pk) devuelve el fkTarchivo de cada material pero no su nombre, y sin nombre no hay extension: el front no puede saber si el archivo es un PDF, una foto, un audio o un video, ni rotular la fila con otra cosa que el id. Se hizo aditivo en vez de agregar la clave al detalle porque esa funcion solo la define V224 y las dos formas de tocarla son peores -- editarla obliga a re-ejecutar el set de re-aplicacion del planeador entero (y re-aplicar V224 sola resucita la version vieja de fn_actividad_calendario que redefine V251), y copiarla en una migracion nueva congela 333 lineas que la proxima edicion de V224 perderia en silencio. La extension sale del NOMBRE y, si ese no trae sufijo -- pasa en las filas historicas migradas, 33.904 de 480.002 --, de URLS3, que siempre lo tiene; URLS3 no se devuelve porque es una ruta interna del bucket. Gate: el mismo de lectura del detalle, resuelto desde la actividad. V427.';


-- ---------------------------------------------------------------------------
-- 2. El endpoint. GET porque solo lee y no recibe arreglos.
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action, style)
SELECT
    'eval-col-actividad-material-archivos-001',
    'SELECT * FROM academico_test.fn_actividad_material_archivos_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/planeador/actividades/:ID/materiales/archivos', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    NULL,
    'Nombre y extension de los archivos de los materiales de apoyo de una actividad, una fila por material-con-archivo. Complementa al detalle (GET /planeador/actividades/:ID), que devuelve el fkTarchivo de cada material pero no su nombre: sin extension el front no puede decidir si previsualiza un PDF, una imagen, un audio o un video, ni rotular la fila con algo mas util que el id. La extension viene ya resuelta y en minuscula, sin punto. Para VER el archivo hace falta ademas acunar un token: POST /files/view-token/<fk_tarchivo>.',
    'actividad-material-archivos', 'DEFAULT'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;


-- ---------------------------------------------------------------------------
-- 3. Roles: los del DETALLE de la actividad, no los del guardado de
--    materiales. Esto es lectura y acompaña a abrir la actividad; quien puede
--    abrirla tiene que poder leer los nombres, aunque no pueda editarla.
-- ---------------------------------------------------------------------------
INSERT INTO public.role_query (query_id, role_id)
SELECT nuevo.id_query, rq.role_id
  FROM public.query nuevo
  JOIN public.query hermano
    ON hermano.microservice_id = nuevo.microservice_id
   AND hermano.path_template   = '/planeador/actividades/:ID'
   AND hermano.http_method     = 'GET'
  JOIN public.role_query rq ON rq.query_id = hermano.id_query
 WHERE nuevo.uuid = 'eval-col-actividad-material-archivos-001'
ON CONFLICT DO NOTHING;
