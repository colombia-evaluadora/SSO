-- ===========================================================================
-- V426 - Subir UN archivo de "Materiales de apoyo" de una actividad.
--
--   fn_actividad_material_archivo_registrar
--   POST /planeador/actividades/:ID/materiales/archivo
--
--
-- EL HUECO QUE TAPA
--   Un material de actividad se guarda con PUT /planeador/actividades/:ID/
--   materiales, y fn_actividad_material_reemplazar exige que cada elemento
--   traiga EXACTAMENTE UNO de `url` o `fkTarchivo`. Los de tipo URL y unidad
--   virtual cumplen con `url`. Los de tipo ARCHIVO necesitan un `fkTarchivo`,
--   y hasta ahora NO habia forma de conseguirlo: no existia ningun endpoint
--   que subiera el binario de un material y devolviera su PK_TARCHIVO.
--
--   El front venia mandando ese PUT como multipart con las partes
--   `archivo_<i>` y un `archivoIndex` dentro del JSON. Eso nunca funciono:
--   `archivoIndex` no lo lee nadie, file-service no esta en el camino de
--   /eval-col/** (solo intercepta /files/**) y query-service no procesa
--   multipart. Resultado medido: de los materiales guardados en el servidor,
--   TODOS tienen FK_TARCHIVO en NULL. Nunca se guardo un archivo por ahi.
--
--
-- POR QUE UN ARCHIVO POR PETICION
--   Porque el catalogo no puede declarar otra cosa. file-service solo acepta
--   como archivo los campos que `param_types` declare con el tipo FILE, y
--   `FILE[]` no existe: lo dice el propio ParamTypes de common ("un campo con
--   varios ficheros no tiene aun forma de declararse en el catalogo").
--   Agregarlo es tocar common, que esta fuera de alcance.
--
--   Con un archivo por peticion no hace falta nada de eso, y ademas es el
--   patron que este sistema ya usa dos veces:
--
--     POST /asistencias/soporte                        (V221)
--     POST /cobertura-academica/matricula/:ID/documentos (V201)
--
--   Los dos son "paso 1": suben un binario y devuelven su PK_TARCHIVO para
--   que el paso 2 lo enlace. Este es el mismo flujo, con el mismo nombre de
--   campo que el de matricula (ARCHIVO).
--
--
-- ESTA FUNCION NO ESCRIBE EL MATERIAL
--   Solo valida y devuelve el id. El material lo sigue enlazando el PUT de
--   siempre, que es de REEMPLAZO TOTAL: si esta funcion insertara la fila,
--   el PUT posterior -- que manda la lista completa -- la borraria salvo que
--   el front la reenviara igual. Dos escrituras para el mismo dato, y la
--   segunda pisando a la primera. Mejor una sola dueña de la lista.
--
--   Consecuencia practica: un archivo subido y nunca enlazado queda en S3 sin
--   referencia. Es lo mismo que ya pasa con el soporte de asistencia y con el
--   documento de matricula, y el costo de evitarlo (un endpoint transaccional
--   que suba Y enlace, incompatible con el reemplazo total) es mayor.
--
--
-- LA CLASIFICACION ES `actividad`
--   Es la que el sistema ya usa para los archivos de actividades: 364.961
--   filas historicas con esa etiqueta (ver docs/archivos/
--   subida-archivos-a-queries.md). Se declara sin el tercer componente
--   -- `FILE:actividad`, no `FILE:actividad:idEstablecimiento` --, igual que
--   `FILE:matricula` en el endpoint hermano: el establecimiento en la clave
--   S3 es opcional y pedirlo obligaria al front a mandarlo o a depender de
--   que el usuario tenga un solo establecimiento.
--
--
-- EL GATE ES MAS ESTRICTO QUE EL DEL PUT
--   fn_actividad_material_reemplazar no tiene gate propio: se apoya solo en
--   los roles del endpoint. Aca si se llama a fn_planeador_assert_alcance con
--   la actividad, que es el mismo gate de fn_actividad_actualizar (capability
--   PLANEADOR/EDITAR mas alcance territorial). Subir un archivo contra una
--   actividad que no podes editar deberia ser 42501 y no un id utilizable.
--
-- Idempotente: CREATE OR REPLACE, e INSERT ... ON CONFLICT DO NOTHING para el
-- endpoint y los roles.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 1. Validar y devolver el id del archivo recien subido.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_material_archivo_registrar(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT,
    p_fk_tarchivo            BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $function$
DECLARE
    v_activa BOOLEAN;
BEGIN
    IF p_fk_tarchivo IS NULL THEN
        -- file-service reemplaza el campo declarado FILE por el PK del
        -- archivo que acaba de registrar. Un NULL aca significa que la
        -- peticion no llevo archivo, o que no paso por file-service.
        RAISE EXCEPTION 'No llego ningun archivo: la peticion debe ir como multipart a /files/eval-col/planeador/actividades/<id>/materiales/archivo con el campo ARCHIVO'
            USING ERRCODE = '22023';
    END IF;

    SELECT a.ACTIVE
      INTO v_activa
      FROM academico_test.TACTIVIDAD a
     WHERE a.PK_TACTIVIDAD = p_pk_tactividad;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe la actividad %', p_pk_tactividad
            USING ERRCODE = 'P0002';
    END IF;

    IF v_activa IS NOT TRUE THEN
        RAISE EXCEPTION 'La actividad % ya no esta disponible', p_pk_tactividad
            USING ERRCODE = '22023';
    END IF;

    -- Mismo gate que fn_actividad_actualizar: capability PLANEADOR/EDITAR y
    -- alcance territorial resuelto desde la propia actividad.
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'EDITAR', NULL, NULL, NULL, p_pk_tactividad);

    -- El archivo ya existe: lo creo file-service antes de llamar aca. Se
    -- verifica igual, porque este parametro es un BIGINT como cualquier otro
    -- y nada impide que llegue uno inventado si alguien arma la peticion a
    -- mano contra el query-service.
    --
    -- SIN "AND ACTIVE = TRUE" a proposito, a diferencia de otros chequeos de
    -- FK de este archivo: file-service SIEMPRE crea la fila de TARCHIVO con
    -- ACTIVE = FALSE (ArchivoRepository, "Reserva la fila ANTES de subir a
    -- S3") y recien la activa DESPUES de recibir un 2xx de ESTA MISMA
    -- llamada (ReenvioController#reenviar, "Solo ahora se sabe que la
    -- operacion completa salio bien"). Exigir ACTIVE = TRUE aca es una
    -- condicion que nunca se puede cumplir -- el archivo esta, por diseno,
    -- siempre inactivo en el momento exacto en que esta funcion corre.
    -- Confirmado en produccion: toda subida de un material tipo Archivo
    -- fallaba con "El archivo % no existe o esta inactivo". Mismo criterio
    -- que ya usan las funciones hermanas de este mismo patron "subir y
    -- devolver el id" (fn_matricula_archivo_crear, V201; el soporte de
    -- asistencia, V221), que no chequean ACTIVE en este paso.
    IF NOT EXISTS (SELECT 1 FROM academico_test.TARCHIVO t
                    WHERE t.PK_TARCHIVO = p_fk_tarchivo) THEN
        RAISE EXCEPTION 'El archivo % no existe', p_fk_tarchivo
            USING ERRCODE = '23503';
    END IF;

    RETURN p_fk_tarchivo;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_actividad_material_archivo_registrar(BIGINT, BIGINT, BIGINT)
    IS 'Paso 1 de "subir un material de tipo Archivo": valida y devuelve el PK_TARCHIVO que file-service acaba de registrar, para que el front lo mande como fkTarchivo en PUT /planeador/actividades/:ID/materiales (paso 2). NO escribe TACTIVIDAD_MATERIAL a proposito: esa lista es de reemplazo total y si aca se insertara la fila, el PUT siguiente la borraria salvo que el front la reenviara -- dos escrituras del mismo dato, la segunda pisando a la primera. Existe porque fn_actividad_material_reemplazar exige url O fkTarchivo y no habia ninguna forma de obtener un fkTarchivo: medido, TODOS los materiales guardados tienen FK_TARCHIVO en NULL. Un archivo por peticion porque el catalogo no puede declarar FILE[] (ver ParamTypes en common), igual que POST /asistencias/soporte y POST /cobertura-academica/matricula/:ID/documentos. El gate es fn_planeador_assert_alcance con la actividad -- el mismo de fn_actividad_actualizar --, mas estricto que el del PUT, que no tiene gate propio. V426.';


-- ---------------------------------------------------------------------------
-- 2. El endpoint. Se llama SIEMPRE a traves de file-service:
--
--       POST /api/files/eval-col/planeador/actividades/<id>/materiales/archivo
--       multipart/form-data, campo ARCHIVO
--
--    file-service sube el binario, lo registra en TARCHIVO con la
--    clasificacion declarada, reemplaza :BODY.ARCHIVO por el PK resultante y
--    recien ahi reenvia la peticion a este query.
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action, style)
SELECT
    'eval-col-actividad-material-archivo-001',
    'SELECT academico_test.fn_actividad_material_archivo_registrar(
    p_pk_usuario_solicitante => public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    p_pk_tactividad          => CAST(:PARAM.ID AS BIGINT),
    p_fk_tarchivo            => CAST(:BODY.ARCHIVO AS BIGINT)
) AS fk_tarchivo;',
    'postgres', false, false,
    m.id_microservice,
    '/planeador/actividades/:ID/materiales/archivo', 'SELECT', 'POST',
    '{"PARAM.ID": "BIGINT", "BODY.ARCHIVO": "FILE:actividad"}'::jsonb,
    NULL,
    'V426 -- paso 1 del flujo de materiales de apoyo: sube UN archivo (multipart, campo ARCHIVO) a POST /files/eval-col/planeador/actividades/<id>/materiales/archivo y devuelve su fk_tarchivo, que luego se manda como MATERIALES[i].fkTarchivo en PUT /planeador/actividades/<id>/materiales (paso 2). Un archivo por peticion porque el catalogo no puede declarar un campo multi-archivo (no hay FILE[]), mismo patron que POST /asistencias/soporte y POST /cobertura-academica/matricula/:ID/documentos. No enlaza el material: la lista es de reemplazo total y la escribe el PUT. Responde 42501 si el usuario no puede editar esa actividad, 404 si no existe y 409 si el archivo no quedo registrado.',
    'actividad-material-archivo', 'DEFAULT'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;


-- ---------------------------------------------------------------------------
-- 3. Roles: los MISMOS que ya pueden reemplazar la lista de materiales.
--
--    Se copian de la fila hermana en vez de escribirlos, para que no se
--    desincronicen el dia que alguien agregue un rol al PUT: quien puede
--    guardar materiales es exactamente quien puede subirlos.
-- ---------------------------------------------------------------------------
INSERT INTO public.role_query (query_id, role_id)
SELECT nuevo.id_query, rq.role_id
  FROM public.query nuevo
  JOIN public.query hermano
    ON hermano.microservice_id = nuevo.microservice_id
   AND hermano.path_template   = '/planeador/actividades/:ID/materiales'
   AND hermano.http_method     = 'PUT'
  JOIN public.role_query rq ON rq.query_id = hermano.id_query
 WHERE nuevo.uuid = 'eval-col-actividad-material-archivo-001'
ON CONFLICT DO NOTHING;
