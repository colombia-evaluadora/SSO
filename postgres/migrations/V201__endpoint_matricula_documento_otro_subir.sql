-- =============================================================================
-- V201 -- Subida de UN documento de "Otros documentos relevantes", en su propio
-- endpoint.
--
--   POST /cobertura-academica/matricula/:ID/documentos  ->  fn_matricula_documento_otro_agregar
--
-- Numero bajo a proposito, en un hueco libre del rango (201-211 estaban sin
-- usar y sin registrar en flyway_schema_history): va DESPUES de V165, que crea
-- fn_matricula_archivo_crear y siembra el tipo '06', y ANTES de las migraciones
-- altas del modulo, para poder referenciarlo desde ellas. El compose corre
-- `migrate -outOfOrder=true`, asi que intercalar un numero por debajo del
-- maximo ya aplicado no rompe el arranque.
--
-- -----------------------------------------------------------------------------
-- Por que hace falta un endpoint aparte
-- -----------------------------------------------------------------------------
-- "Otros documentos relevantes" (TLISTA_VALOR ARCHIVO_MATRICULA, VALOR '06') es
-- el unico documento de la ficha que admite N archivos. Los otros cuatro son
-- 1-a-1 y viajan bien como un campo FILE cada uno.
--
-- Un campo con VARIOS archivos hoy no se puede declarar en el catalogo. El
-- transformador de file-service SI los soporta -- sube todas las partes que
-- comparten nombre de campo y sustituye "un id suelto si hay uno, una lista si
-- hay varios" (TransformadorMultipart.transformar) -- pero param_types no tiene
-- el tipo FILE[] para describirlo. Esta escrito como limitacion conocida en
-- docs/subida-archivos-a-queries.md, seccion 10.
--
-- El intento previo fue declarar el mismo campo dos veces, FILE para que
-- file-service lo acepte y JSONB por BODY_RAW para leer la lista. No puede
-- funcionar: ParamBinder.buildStrict valida TODAS las claves del cuerpo contra
-- TODO param_types, sin mirar que placeholders usa el SQL, y el cuerpo produce
-- las dos claves (flatten deja BODY.X, putRaw deja BODY_RAW.X) apuntando al
-- MISMO valor. Con esos dos tipos declarados no hay valor que satisfaga ambos:
--
--   1 archivo   -> el valor es un Long. BODY.X (FILE, que la guardia trata como
--                  BIGINT) pasa; BODY_RAW.X (JSONB) lo rechaza, porque JSONB
--                  solo admite objeto, array o string ya serializado.
--   2+ archivos -> el valor es una List. BODY_RAW.X (JSONB) pasa; BODY.X (FILE)
--                  la rechaza por no ser un entero.
--
-- Es decir: el unico caso que hoy pasa por el alta es NO mandar ninguno. Cuadra
-- con los datos -- TARCHIVO solo tiene 96 filas con etiqueta 'matricula', todas
-- migradas: por este camino nunca se subio nada.
--
-- Asi que se parte en dos operaciones, que es lo que el catalogo si sabe
-- expresar: un endpoint que sube UN archivo, y el front lo llama en bucle. Un
-- archivo por peticion es la unica forma de subir varios sin tocar `common/`.
--
-- -----------------------------------------------------------------------------
-- Por que exige la matricula y no devuelve un fkTarchivo "libre"
-- -----------------------------------------------------------------------------
-- La alternativa era un endpoint de "solo subir" que devolviera el pk_tarchivo
-- para que el front lo mandara despues. Se descarto: file-service reserva la
-- fila de TARCHIVO inactiva y la ACTIVA cuando el destino responde 2xx (paso 10
-- del flujo). Un endpoint que solo devuelve el id deja el archivo activo y sin
-- dueño en cuanto responde; si el usuario abandona el formulario, queda una
-- fila y un objeto en S3 que nada referencia y nadie va a limpiar.
--
-- Enlazando en la misma peticion, la fila nace con dueño. El coste es el orden
-- de las llamadas en el alta: primero se crea la matricula (que ya no recibe
-- este campo) y con el pk que devuelve se suben los documentos en bucle. En el
-- editar no hay coste, porque la matricula ya existe.
--
-- Que NO hace este endpoint: quitar ni reemplazar. Eso sigue siendo del PATCH
-- de la ficha, con OTROS_DOCUMENTOS_RELEVANTES, y esta bien que sea asi --
-- desde el front tiene mas sentido mandar los identificadores de lo que se
-- quita que volver a subir lo que se conserva.
--
-- Idempotente: CREATE OR REPLACE, y el INSERT del catalogo con ON CONFLICT.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- fn_matricula_documento_otro_agregar
-- -----------------------------------------------------------------------------
-- Enlaza UN archivo ya subido a la matricula como "Otros documentos
-- relevantes". El tipo se resuelve aca por VALOR '06' y no se recibe por
-- parametro: el front no tiene por que conocer un PK de TLISTA_VALOR que
-- ademas difiere por ambiente.
--
-- El gate y el INSERT se delegan en fn_matricula_archivo_crear (V165), que ya
-- resuelve el EE de la matricula y valida el permiso. Aqui no se repite esa
-- regla: dos copias de un gate divergen.
--
-- Devuelve el enlace creado y cuantos documentos de este tipo quedan, para que
-- el front pueda mostrar el avance del bucle sin volver a pedir la ficha.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_matricula_documento_otro_agregar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tmatricula          BIGINT,
    p_fk_tarchivo            BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
AS $function$
DECLARE
    v_tipo   BIGINT;
    v_nuevo  BIGINT;
    v_total  BIGINT;
BEGIN
    IF p_fk_tarchivo IS NULL THEN
        RAISE EXCEPTION 'No llego ningun archivo'
            USING ERRCODE = '22023',
                  HINT    = 'El campo ARCHIVO del multipart tiene que traer el fichero. '
                         || 'Se sube uno por peticion';
    END IF;

    SELECT PK_LISTA_VALOR INTO v_tipo
      FROM academico_test.TLISTA_VALOR
     WHERE CATEGORIA = 'ARCHIVO_MATRICULA' AND VALOR = '06' AND ACTIVE = TRUE;

    IF v_tipo IS NULL THEN
        RAISE EXCEPTION 'El catalogo ARCHIVO_MATRICULA no tiene el tipo "Otros Documentos Relevantes"'
            USING ERRCODE = '23503',
                  HINT    = 'Lo siembra V165; revise que la fila con VALOR = ''06'' este activa';
    END IF;

    -- Gate + INSERT. Si la matricula no existe o el usuario no puede, levanta
    -- desde ahi con el mensaje que ya usa el resto del modulo.
    v_nuevo := academico_test.fn_matricula_archivo_crear(
        p_pk_usuario_solicitante := p_pk_usuario_solicitante,
        p_fk_tmatricula          := p_fk_tmatricula,
        p_fk_tarchivo            := p_fk_tarchivo,
        p_fk_tlv_tipo_archivo    := v_tipo
    );

    SELECT COUNT(*) INTO v_total
      FROM academico_test.TMATRICULA_ARCHIVO
     WHERE FK_TMATRICULA = p_fk_tmatricula
       AND FK_TLV_TIPO_ARCHIVO = v_tipo
       AND ACTIVE = TRUE;

    RETURN jsonb_build_object(
        'pkTmatriculaArchivo', v_nuevo,
        'pkTmatricula',        p_fk_tmatricula,
        'fkTarchivo',          p_fk_tarchivo,
        'tipo',                'otros',
        'totalOtrosDocumentos', v_total
    );
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_matricula_documento_otro_agregar(BIGINT, BIGINT, BIGINT)
    IS 'Enlaza UN archivo ya subido a una matricula como "Otros documentos relevantes" (ARCHIVO_MATRICULA VALOR ''06''), resolviendo el tipo por VALOR. Existe porque ese es el unico documento de la ficha que admite N archivos y param_types no tiene tipo FILE[] para declarar un campo multi-archivo, asi que se sube uno por peticion y el front itera. Exige la matricula a proposito: file-service activa la fila de TARCHIVO al recibir 2xx, y un endpoint que solo devolviera el id dejaria archivos activos sin dueño si el usuario abandona el formulario. Delega gate e INSERT en fn_matricula_archivo_crear. No quita ni reemplaza: eso es del PATCH de la ficha. V201.';


-- -----------------------------------------------------------------------------
-- El endpoint
-- -----------------------------------------------------------------------------
-- ARCHIVO se declara FILE:matricula, igual clasificacion que los otros cuatro
-- documentos de la ficha (una clasificacion es la carpeta de S3, no el tipo de
-- negocio -- ver V165).
--
-- POST y no PUT: es una accion que AGREGA un elemento a una coleccion, no la
-- reemplaza. Repetirla con el mismo archivo crea otro enlace, que es el
-- comportamiento correcto de un POST y ademas lo que se quiere aqui -- el mismo
-- fichero puede subirse dos veces por error del usuario y eso lo resuelve el
-- front quitando uno, no la base rechazandolo.
--
-- Nota sobre arranque limpio: como todo el registro de endpoints de este modulo
-- (V167, V168, V179...), la fila sale de public.microservice WHERE serviceid =
-- 'eval-col', que NINGUNA migracion siembra -- es dato de plataforma. En una BD
-- recien creada el SELECT no devuelve filas y el INSERT no inserta nada, sin
-- error. Es el comportamiento que ya tiene el modulo entero, no algo propio de
-- esta migracion.
-- -----------------------------------------------------------------------------
INSERT INTO public.query (
    uuid, query, type, public_end, captcha, microservice_id,
    path_template, execution_mode, http_method, param_types, detail
)
SELECT
    'q-mtb2d9k4-cobmatdoc1',
    'SELECT academico_test.fn_matricula_documento_otro_agregar(
    p_pk_usuario_solicitante => public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    p_fk_tmatricula => CAST(:PARAM.ID AS BIGINT),
    p_fk_tarchivo => CAST(:BODY.ARCHIVO AS BIGINT)
) AS documento',
    'postgres', false, false,
    m.id_microservice,
    '/cobertura-academica/matricula/:ID/documentos', 'SELECT', 'POST',
    '{"PARAM.ID": "BIGINT",
      "BODY.ARCHIVO": "FILE:matricula"}'::jsonb,
    'V201 -- sube UN documento de "Otros documentos relevantes" y lo enlaza a la matricula. Un archivo por peticion: es el unico documento de la ficha que admite varios y el catalogo no tiene tipo FILE[] para declarar un campo multi-archivo (ver docs/subida-archivos-a-queries.md, seccion 10), asi que el front llama este endpoint en bucle. En el alta se llama DESPUES de crear la matricula, con el pk que esta devuelve. Para quitar o reemplazar documentos se usa OTROS_DOCUMENTOS_RELEVANTES del PATCH de la ficha.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (uuid) DO UPDATE
   SET query = EXCLUDED.query,
       param_types = EXCLUDED.param_types,
       path_template = EXCLUDED.path_template,
       http_method = EXCLUDED.http_method,
       execution_mode = EXCLUDED.execution_mode,
       microservice_id = EXCLUDED.microservice_id,
       detail = EXCLUDED.detail;


-- -----------------------------------------------------------------------------
-- Se saca OTROS_DOCUMENTOS_RELEVANTES del alta
-- -----------------------------------------------------------------------------
-- V167 queda corregido en su propio texto para que una BD nueva no lo declare
-- nunca. Esto es para los servidores donde la version vieja YA se aplico: sin
-- este UPDATE la fila sigue con el par FILE + JSONB insatisfacible, y cualquier
-- alta que mande el campo responde 400.
--
-- Se quita el argumento del texto de la query y las dos claves de param_types.
-- p_fk_tarchivo_otros sigue existiendo en fn_matricula_directa_crear con
-- DEFAULT NULL: no se toca la funcion, simplemente el endpoint deja de pasarlo.
-- Un dia que exista FILE[] se vuelve a enchufar ahi sin cambiar la firma.
-- -----------------------------------------------------------------------------
UPDATE public.query
   SET query = REPLACE(
           query,
           ',
        p_fk_tarchivo_otros => CAST(:BODY_RAW.OTROS_DOCUMENTOS_RELEVANTES AS JSONB)',
           ''),
       param_types = (param_types
                      - 'BODY.OTROS_DOCUMENTOS_RELEVANTES')
                      - 'BODY_RAW.OTROS_DOCUMENTOS_RELEVANTES'
 WHERE uuid = 'q-mtb2d9k4-cobmatd1'
   AND (param_types ? 'BODY.OTROS_DOCUMENTOS_RELEVANTES'
        OR param_types ? 'BODY_RAW.OTROS_DOCUMENTOS_RELEVANTES');
