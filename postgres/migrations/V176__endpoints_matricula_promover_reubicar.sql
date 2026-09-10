-- =============================================================================
-- V176 -- Registra en el catalogo `query` los dos endpoints de movimiento en
-- lote de matriculas (ver V175):
--
--   PUT /cobertura-academica/matricula/promover  -> fn_matricula_promover_lote
--   PUT /cobertura-academica/matricula/reubicar  -> fn_matricula_reubicar_lote
--
-- POR QUE PUT: mismo criterio que el resto del modulo -- no crean un recurso
-- direccionable nuevo por si mismas, cambian el estado de recursos existentes.
-- Ademas el CHECK ck_query_http_method del catalogo solo admite
-- GET/POST/PUT/PATCH.
--
-- SOBRE LA RUTA LITERAL vs /:ID -- estas dos rutas tienen la misma longitud y
-- el mismo metodo que PUT /cobertura-academica/matricula/:ID (id_query 226),
-- con un literal donde la otra tiene un parametro. No es un caso nuevo: el
-- catalogo ya tiene nueve pares asi resueltos, entre ellos
-- PUT /grados/:ID vs PUT /grados/eliminacion-masiva y
-- PUT /establecimientos/sedes/:ID vs PUT /establecimientos/sedes/bulk-delete.
-- Se sigue esa convencion en vez de inventar un prefijo /lote/.
--
-- CUERPO de ambas, identico:
--
--     { "ids": [1001, 1002, 1003], "grupoDestino": 11402 }
--
-- :BODY_RAW.IDS llega como JSONB (array de numeros) y se convierte a BIGINT[]
-- con jsonb_array_elements_text -- mismo patron BODY_RAW + CAST del
-- bulk-delete (V169). No se usa :BODY.IDS porque el motor aplanaria el array.
--
-- A DIFERENCIA del bulk-delete, estas dos son TODO O NADA: validan el lote
-- completo antes de tocar la primera matricula y cualquier rechazo aborta la
-- operacion entera. Mover medio curso y dejar la otra mitad en el grupo viejo
-- es un estado peor que no haber hecho nada -- el usuario no sabria cuales
-- pasaron sin revisar una por una.
--
-- Sin fila en role_query responden 403 -- los permisos por rol se configuran
-- aparte, en la plataforma.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Promover (misma sede, siguiente grupo)
-- ---------------------------------------------------------------------------
INSERT INTO public.query (
    uuid, query, type, public_end, captcha, microservice_id,
    path_template, execution_mode, http_method, param_types, detail
)
SELECT
    'q-mtb2d9k4-cobmatpro1',
    'SELECT academico_test.fn_matricula_promover_lote(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    ARRAY(SELECT jsonb_array_elements_text(CAST(:BODY_RAW.IDS AS JSONB))::BIGINT),
    CAST(:BODY.GRUPO_DESTINO AS BIGINT)
) AS resultado;',
    'postgres', false, false,
    m.id_microservice,
    '/cobertura-academica/matricula/promover', 'SELECT', 'PUT',
    '{"BODY_RAW.IDS": "JSONB", "BODY.GRUPO_DESTINO": "BIGINT"}'::jsonb,
    'V176 -- promocion en lote: por cada matricula crea una nueva en el grupo destino en estado Cursando (copiando socioeconomico y archivos, encadenada por FK_TMATRICULA_ANTERIOR) y deja la anterior en Promovido. Origen Cursando o Aprobado; el grupo destino debe ser de la MISMA sede. Todo o nada. Solo rector/secretaria/jefe de sistema; el super-admin NO puede ejecutarlo'
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

-- ---------------------------------------------------------------------------
-- 2. Reubicar (otra sede)
--
-- No recibe la sede destino: el grupo destino ya la determina
-- (grupo -> grado -> periodo -> sede). Recibirla suelta permitiria que llegue
-- una sede que no corresponde al grupo enviado.
-- ---------------------------------------------------------------------------
INSERT INTO public.query (
    uuid, query, type, public_end, captcha, microservice_id,
    path_template, execution_mode, http_method, param_types, detail
)
SELECT
    'q-mtb2d9k4-cobmatreu1',
    'SELECT academico_test.fn_matricula_reubicar_lote(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    ARRAY(SELECT jsonb_array_elements_text(CAST(:BODY_RAW.IDS AS JSONB))::BIGINT),
    CAST(:BODY.GRUPO_DESTINO AS BIGINT)
) AS resultado;',
    'postgres', false, false,
    m.id_microservice,
    '/cobertura-academica/matricula/reubicar', 'SELECT', 'PUT',
    '{"BODY_RAW.IDS": "JSONB", "BODY.GRUPO_DESTINO": "BIGINT"}'::jsonb,
    'V176 -- reubicacion en lote: por cada matricula crea una nueva en el grupo destino de OTRA sede en estado Cursando (copiando socioeconomico y archivos, encadenada por FK_TMATRICULA_ANTERIOR) y deja la anterior en Reubicado. Origen Cursando, Aprobado o Reprobado; el grupo destino debe ser de una sede DISTINTA. Todo o nada. Se exige permiso sobre el establecimiento de origen y el de destino; el super-admin NO puede ejecutarlo'
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
