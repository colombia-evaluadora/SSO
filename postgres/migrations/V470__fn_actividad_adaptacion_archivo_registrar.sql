-- ===========================================================================
-- V470 - Subir UN archivo de "Adaptaciones curriculares" de una actividad.
--
--   fn_actividad_adaptacion_archivo_registrar
--   POST /planeador/actividades/:ID/adaptaciones/archivo
--
--
-- EL HUECO QUE TAPA
--   PUT /planeador/actividades/:ID/adaptaciones (fn_actividad_adaptaciones_
--   reemplazar, V224) exige, con usaVersionModificada = 'S' y formatoAdaptacion
--   = ARCHIVO o BIBLIOTECA, un fkTarchivo -- y hasta ahora no habia forma de
--   conseguirlo: ningun endpoint subia el binario de una plantilla de
--   adaptacion y devolvia su PK_TARCHIVO. El front ni siquiera capturaba el
--   archivo elegido (el <input type="file"> guardaba el nombre falso del
--   navegador, no el binario) -- confirmado: se guarda "en vivo" junto con
--   este endpoint.
--
--
-- MISMO PATRON QUE fn_actividad_material_archivo_registrar (V426)
--   Un archivo por peticion, "paso 1" que solo valida y devuelve el id --
--   PUT /adaptaciones sigue siendo el UNICO que escribe TACTIVIDAD_ADAPTACION
--   (reemplazo completo: si esta funcion insertara algo, el PUT posterior lo
--   borraria salvo que el front lo reenviara). Mismo gate
--   (fn_planeador_assert_alcance, capability PLANEADOR/EDITAR + alcance
--   territorial) y la MISMA razon para no exigir ACTIVE = TRUE sobre
--   TARCHIVO: file-service siempre crea la fila con active = false y recien
--   la activa DESPUES de recibir 2xx de esta misma llamada -- exigirlo aca
--   es una condicion que nunca se puede cumplir (bug real, corregido en
--   V426 tras confirmarse en produccion; se evita reintroducirlo aca).
--
--   La clasificacion es `actividad` -- misma que materiales/soporte de
--   evidencias de esta misma actividad, no una nueva.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 1. Validar y devolver el id del archivo recien subido.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_adaptacion_archivo_registrar(
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
        RAISE EXCEPTION 'No llego ningun archivo: la peticion debe ir como multipart a /files/eval-col/planeador/actividades/<id>/adaptaciones/archivo con el campo ARCHIVO'
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

    -- SIN "AND ACTIVE = TRUE" a proposito -- ver V426 para el porque (file-
    -- service activa la fila DESPUES de que ESTA MISMA llamada responda 2xx,
    -- asi que exigirlo aca es una condicion que nunca se puede cumplir).
    IF NOT EXISTS (SELECT 1 FROM academico_test.TARCHIVO t
                    WHERE t.PK_TARCHIVO = p_fk_tarchivo) THEN
        RAISE EXCEPTION 'El archivo % no existe', p_fk_tarchivo
            USING ERRCODE = '23503';
    END IF;

    RETURN p_fk_tarchivo;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_actividad_adaptacion_archivo_registrar(BIGINT, BIGINT, BIGINT)
    IS 'Paso 1 de "subir el archivo de una adaptacion curricular" (formatoAdaptacion = ARCHIVO o BIBLIOTECA): valida y devuelve el PK_TARCHIVO que file-service acaba de registrar, para que el front lo mande como fkTarchivo en el elemento correspondiente de PUT /planeador/actividades/:ID/adaptaciones (paso 2, fn_actividad_adaptaciones_reemplazar). NO escribe TACTIVIDAD_ADAPTACION a proposito: esa lista es de reemplazo total y la sigue escribiendo unicamente el PUT. Mismo patron y mismo motivo que fn_actividad_material_archivo_registrar (V426): un archivo por peticion (no existe FILE[] en el catalogo), gate fn_planeador_assert_alcance, y sin exigir TARCHIVO.ACTIVE = TRUE (file-service la activa recien despues del 2xx de esta llamada). V470.';


-- ---------------------------------------------------------------------------
-- 2. El endpoint. Se llama SIEMPRE a traves de file-service:
--
--       POST /api/files/eval-col/planeador/actividades/<id>/adaptaciones/archivo
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
    'eval-col-actividad-adaptacion-archivo-001',
    'SELECT academico_test.fn_actividad_adaptacion_archivo_registrar(
    p_pk_usuario_solicitante => public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    p_pk_tactividad          => CAST(:PARAM.ID AS BIGINT),
    p_fk_tarchivo            => CAST(:BODY.ARCHIVO AS BIGINT)
) AS fk_tarchivo;',
    'postgres', false, false,
    m.id_microservice,
    '/planeador/actividades/:ID/adaptaciones/archivo', 'SELECT', 'POST',
    '{"PARAM.ID": "BIGINT", "BODY.ARCHIVO": "FILE:actividad"}'::jsonb,
    NULL,
    'V470 -- paso 1 del flujo de adaptaciones curriculares (formatoAdaptacion = ARCHIVO o BIBLIOTECA): sube UN archivo (multipart, campo ARCHIVO) a POST /files/eval-col/planeador/actividades/<id>/adaptaciones/archivo y devuelve su fk_tarchivo, que luego se manda como el fkTarchivo del elemento correspondiente en PUT /planeador/actividades/<id>/adaptaciones (paso 2). Mismo patron que /materiales/archivo (V426): un archivo por peticion, no enlaza nada (la lista la escribe el PUT, reemplazo total). Responde 42501 si el usuario no puede editar esa actividad, 404 si no existe y 409 si el archivo no quedo registrado.',
    'actividad-adaptacion-archivo', 'DEFAULT'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;


-- ---------------------------------------------------------------------------
-- 3. Roles: los MISMOS que ya pueden reemplazar la lista de adaptaciones.
--
--    Se copian de la fila hermana en vez de escribirlos, para que no se
--    desincronicen el dia que alguien agregue un rol al PUT: quien puede
--    guardar adaptaciones es exactamente quien puede subirles un archivo.
-- ---------------------------------------------------------------------------
INSERT INTO public.role_query (query_id, role_id)
SELECT nuevo.id_query, rq.role_id
  FROM public.query nuevo
  JOIN public.query hermano
    ON hermano.microservice_id = nuevo.microservice_id
   AND hermano.path_template   = '/planeador/actividades/:ID/adaptaciones'
   AND hermano.http_method     = 'PUT'
  JOIN public.role_query rq ON rq.query_id = hermano.id_query
 WHERE nuevo.uuid = 'eval-col-actividad-adaptacion-archivo-001'
ON CONFLICT DO NOTHING;
