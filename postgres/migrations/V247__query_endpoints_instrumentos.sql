-- ===========================================================================
-- V247 — Planeador educativo: registro en public.query (motor SSO /
-- query-service) de los endpoints de INSTRUMENTOS DE EVALUACION DINAMICOS
-- (CU-86e311xxp, LOTE 3 de la tanda de endpoints del Planeador).
--
-- Este archivo NO crea funciones nuevas: las funciones ya existen y estan
-- validadas en esta rama (V226, V240, V227, editada en V241/V243). Solo
-- registra las filas public.query (+ role_query) para exponerlas via el
-- gateway como api/eval-col/... . El LOTE 1 (V245, dominio UNIDAD) y el
-- LOTE 2 (V246, dominio ACTIVIDAD) registran sus propios endpoints por
-- separado -- NO se duplican aqui, y aqui no se expone nada de CRUD de
-- unidad/actividad ni de fn_actividad_observar_* (ya cubierto en V246).
--
-- microservice_id se resuelve por serviceid='eval-col' (mismo microservicio
-- que sirve el resto del modulo academico -- V51/V64/V149/V185/V198/V199/
-- V245/V246).
--
-- p_pk_usuario_solicitante SIEMPRE se resuelve de :CONTEXT.USER_ID via
-- public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT) -- igual que
-- V149/V167/V168/V185/V198/V199/V245/V246 -- nunca se expone como parametro
-- editable por el cliente.
--
-- AUTORIZACION
--   El gate real (capability CREAR/VER/EDITAR/ELIMINAR sobre la seccion
--   PLANEADOR, TROL_MENU + TUSUARIO_ROL_PERMISO) lo hace cada funcion via
--   fn_assert_permiso_seccion (V29/V185/V213/V216). role_query aqui NO
--   sustituye ese gate, solo decide que ROLES DE public.role pueden llamar
--   al endpoint por el gateway -- role_query NO tiene bypass de admin (a
--   diferencia de otras rutas, aqui no hay atajo para SSO-ADMIN/ADMIN salvo
--   que el rol este explicitamente listado).
--
--   Mismo criterio ya aplicado (y funcionando) en V245/V246/V214: en este
--   Postgres local de Docker solo existe el rol 'CEVAL-SUPER_ADMINISTRADOR'
--   sincronizado a public.role (el catalogo real de TROL -- DOCENTE, RECTOR,
--   etc -- no esta sembrado en las migraciones, ver nota "TROL: el catalogo
--   de roles no esta en las migraciones" en memoria del proyecto). Cuando el
--   ambiente real tenga el rol de DOCENTE sincronizado, agregar esa fila a
--   role_query es un cambio de una linea (INSERT posterior a
--   public.role_query, no requiere tocar esta migracion).
--
-- CAVEAT DE RECARGA (dejar constancia, igual que V149/V167/V185/V198/V199/
-- V245/V246): las filas nuevas en public.query dan 404 por el gateway hasta
-- que el contenedor query-service-eval-col se reinicia. No aplica a esta
-- validacion SQL (fuera de alcance segun el enunciado de la tarea).
--
-- CONVENCIONES DE PARAMETROS (V32/V49, igual que V245/V246):
--   :PARAM.<VAR>   -> variable de la ruta (path_template ...:VAR...).
--   :QUERY.<VAR>   -> filtro por query-string (?var=...); QUERY.SIZE/
--                     QUERY.OFFSET son system-bound (paginacion), el resto
--                     de nombres de QUERY.* SI necesita entrada en
--                     param_types.
--   :BODY.<VAR>    -> campo del body JSON.
--   :CONTEXT.*     -> system-bound (JWT verificado), nunca en param_types.
--
-- execution_mode = 'SELECT' en TODAS las filas (incluidas las de escritura):
--   "SELECT * FROM fn_x(...)" sigue siendo una sentencia SELECT aunque fn_x
--   escriba por dentro -- mismo patron que V64/V149/V185/V198/V199/V245/V246.
--
-- DELETE -> PATCH: el CHECK ck_query_http_method de public.query solo admite
-- {GET,POST,PUT,PATCH} -- no existe DELETE en este catalogo. No aplica a
-- este lote (no hay borrado real en el dominio de instrumentos/calificar,
-- solo definir/calificar, que son PUT).
--
-- -------------------------------------------------------------------------
-- DECISION 1 — SOLO se expone la FACHADA fn_actividad_instrumento_definir /
-- _obtener (V226), NO las 3 funciones especificas de rubrica/cotejo/escala
-- por separado (fn_actividad_rubrica_definir / _cotejo_definir /
-- _escala_definir).
--
-- La fachada YA hace todo el trabajo de despacho leyendo
-- TACTIVIDAD.FK_TLV_INSTRUMENTO_EVALUACION y llamando internamente a la
-- funcion correcta segun ese valor (confirmado leyendo V226 completo).
-- Exponer las 3 especificas ademas de la fachada crearia 3 rutas
-- redundantes que hacen exactamente lo mismo que la generica, con el
-- riesgo adicional de que el cliente le pase a la ruta especifica una
-- definicion que no calza con el instrumento real de la actividad (caso
-- que la fachada evita por diseño: siempre resuelve ella misma el
-- instrumento antes de despachar). Una sola ruta generica
-- PUT /planeador/actividades/:ID/instrumento (body = la definicion en el
-- formato que exija el instrumento vigente de esa actividad) es
-- suficiente y mas simple para el front, que de todas formas ya conoce el
-- instrumento vigente por GET /planeador/actividades/:ID/configuracion
-- (V246, campos_disponibles.evaluacion.instrumentosPermitidos) o por el
-- detalle de la actividad (V246, punto 4).
--
-- DECISION 2 — fn_actividad_otro_definir (V240) NO se expone standalone.
--
-- Confirmado leyendo V240 completo: la fachada fn_actividad_instrumento_definir
-- YA fue editada en V240 (CREATE OR REPLACE) para que su rama 'OTRO' delegue
-- exactamente en fn_actividad_otro_definir, pasandole tal cual el
-- p_definicion recibido (que para el caso OTRO es el objeto
-- {tipoEvidencia, metodoValoracion, definicion}). Por lo tanto exponer
-- PUT /planeador/actividades/:ID/instrumento (fachada) YA cubre por
-- completo configurar el instrumento OTRO -- una ruta aparte para
-- fn_actividad_otro_definir seria una tercera forma de llegar al mismo
-- efecto que la fachada, sin aportar nada que el cliente no pueda hacer ya
-- con ella.
--
-- -------------------------------------------------------------------------
-- NOMENCLATURA DE RUTAS (decision de este lote):
--   * /planeador/actividades/:ID/instrumento                (PUT define,
--     GET obtiene -- :ID = PK_TACTIVIDAD; fachada unica, ver Decision 1/2)
--   * /planeador/actividades/estudiantes/:ID/calificar      (PUT, :ID =
--     PK_TACTIVIDAD_ESTUDIANTE, no PK_TACTIVIDAD -- mismo criterio de
--     desambiguacion que /planeador/actividades/estudiantes/:ID/observar
--     de V246 punto 13 y /planeador/unidades/criterios/:ID de V245)
--   * /planeador/actividades/:ID/calificar-bulk/rubrica      (PUT, :ID =
--     PK_TACTIVIDAD; un criterio+nivel aplicado a N estudiantes)
--   * /planeador/actividades/:ID/calificar-bulk/cotejo       (PUT, idem,
--     un item marcado S/N para N estudiantes)
--   * /planeador/actividades/:ID/calificar-bulk/escala       (PUT, idem,
--     un nivel de escala CUALITATIVA para N estudiantes; la escala NUMERICA
--     no admite bulk -- la propia funcion SQL no lo permite, ver V227)
--     Un segmento /calificar-bulk/<instrumento> por cada bulk (en vez de
--     una fachada unica) porque, a diferencia de fn_actividad_instrumento_
--     definir/fn_actividad_nota_calificar, estas 3 funciones NO tienen una
--     fachada de despacho en el SQL (documentado explicitamente en la
--     cabecera de V227/V241: "SI exponlas aparte porque no tienen fachada
--     unica de despacho") -- construir una fachada de query-service (varias
--     filas public.query con el mismo path resuelta por instrumento) no es
--     el patron de este catalogo (1 fila = 1 funcion SQL), asi que se
--     diferencian por el ultimo segmento del path.
--   * /planeador/actividades/estudiantes/:ID/nota            (GET, :ID =
--     PK_TACTIVIDAD_ESTUDIANTE, detalle de un estudiante)
--   * /planeador/actividades/:ID/calificaciones              (GET, :ID =
--     PK_TACTIVIDAD, tabla completa de la pantalla "Calificaciones: <actividad>")
--
-- Depende de (orden de version de Flyway): V226 (definicion de instrumentos
-- + fachada), V240 (instrumento OTRO), V227 (motor de calculo de notas,
-- editado en V241 -- OTRO estructurado -- y V243 -- rechazo de actividades
-- FORMATIVAS).
-- ===========================================================================


-- ===========================================================================
-- 1. PUT /planeador/actividades/:ID/instrumento —
--    fn_actividad_instrumento_definir (V226, editada en V240; fachada de
--    despacho segun el instrumento vigente de la actividad).
-- ===========================================================================
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT academico_test.fn_actividad_instrumento_definir(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.DEFINICION AS JSONB)
) AS instrumento_aplicado;',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades/:ID/instrumento', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT", "BODY.DEFINICION": "JSONB"}'::jsonb,
    'V247 -- define (reemplazo completo) el instrumento de evaluacion vigente de una actividad: fachada que lee TACTIVIDAD.FK_TLV_INSTRUMENTO_EVALUACION y despacha internamente a fn_actividad_rubrica_definir / _cotejo_definir / _escala_definir / _otro_definir (fn_actividad_instrumento_definir, V226, editada en V240). :ID = PK_TACTIVIDAD. BODY.DEFINICION cambia de forma segun el instrumento vigente de la actividad (consultar antes con GET /planeador/actividades/:ID/configuracion, campos_disponibles.evaluacion.instrumentosPermitidos, o el detalle de la actividad): si es RUBRICA, un array [{nombre, descripcion?, niveles:[{etiqueta?, descripcion, ponderacion}]}]; si es LISTA_COTEJO, un array [{descripcion, ponderacion?}]; si es ESCALA_VALORACION, un objeto {tipoEscala, criteriosGenerales?, interpretacionRangos?, valorMin/valorMax (solo NUMERICA), niveles (solo CUALITATIVA)}; si es OTRO, un objeto {tipoEvidencia, metodoValoracion, definicion} donde metodoValoracion en {RUBRICA,LISTA_COTEJO,ESCALA_VALORACION} y definicion reutiliza el mismo formato del metodo elegido (fn_actividad_otro_definir, V240). SOLO se expone esta ruta generica: las 3 funciones especificas de rubrica/cotejo/escala y fn_actividad_otro_definir NO se registran aparte porque la fachada ya hace todo su trabajo de despacho (decision documentada en la cabecera de esta migracion). Retorna el VALOR del instrumento aplicado. Gate EDITAR sobre PLANEADOR (dentro de la funcion destino). 404 (P0002) si la actividad no existe; 22023 si el instrumento de la actividad no coincide con el esperado o el payload no cumple el formato exigido por ese instrumento.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/actividades/:ID/instrumento'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;


-- ===========================================================================
-- 2. GET /planeador/actividades/:ID/instrumento —
--    fn_actividad_instrumento_obtener (V226, editada en V240; lectura del
--    instrumento definido).
-- ===========================================================================
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_actividad_instrumento_obtener(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades/:ID/instrumento', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    'V247 -- lee el instrumento de evaluacion definido para una actividad (fn_actividad_instrumento_obtener, V226, editada en V240). :ID = PK_TACTIVIDAD. Retorna {instrumento (VALOR de TLISTA_VALOR), instrumento_nombre, definicion (JSONB)}: RUBRICA -> [{pk,orden,nombre,descripcion,niveles:[{pk,etiqueta,descripcion,ponderacion}]}] (niveles ordenados por ponderacion DESC); LISTA_COTEJO -> [{pk,orden,descripcion,ponderacion}]; ESCALA_VALORACION -> {pk,tipoEscala,tipoEscalaNombre,tipoEscalaValor,criteriosGenerales,valorMin,valorMax,interpretacionRangos,niveles:[...]}; OTRO -> {pk,tipoEvidencia,tipoEvidenciaNombre,metodoValoracion,metodoValoracionNombre,metodoValoracionValor,definicion} (definicion reutiliza el mismo formato de RUBRICA/LISTA_COTEJO/ESCALA_VALORACION segun el metodo elegido); sin instrumento definido -> definicion NULL. Gate VER sobre PLANEADOR.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/actividades/:ID/instrumento'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;


-- ===========================================================================
-- 3. PUT /planeador/actividades/estudiantes/:ID/calificar —
--    fn_actividad_nota_calificar (V227, editada en V241/V243; fachada de
--    calificacion individual con nota numerica). :ID = PK_TACTIVIDAD_ESTUDIANTE.
-- ===========================================================================
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT academico_test.fn_actividad_nota_calificar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.CALIFICACION AS JSONB),
    COALESCE(CAST(:BODY.FECHA AS DATE), CURRENT_DATE)
) AS calificacion;',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades/estudiantes/:ID/calificar', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT", "BODY.CALIFICACION": "JSONB", "BODY.FECHA": "DATE"}'::jsonb,
    'V247 -- califica con nota numerica a UN estudiante de una actividad, segun su instrumento vigente (fn_actividad_nota_calificar, V227, editada en V241 -- OTRO estructurado -- y V243 -- rechazo de FORMATIVAS). :ID = PK_TACTIVIDAD_ESTUDIANTE (NO PK_TACTIVIDAD). BODY.CALIFICACION cambia de forma segun el instrumento: RUBRICA -> {niveles:[{pkCriterio,pkNivel}]} (debe cubrir TODOS los criterios activos, ni de mas ni de menos); LISTA_COTEJO -> {itemsMarcados:[pk,...]} (PKs de TACTIVIDAD_COTEJO_ITEM cumplidos); ESCALA_VALORACION -> {pkNivel} (CUALITATIVA) o {valorNumerico} (NUMERICA), exactamente uno segun el tipo de la escala; OTRO -> {porcentaje} si no tiene metodo de valoracion configurado (V240), o el mismo payload del metodo equivalente si si lo tiene. BODY.FECHA opcional (default hoy): el "dia de clase" contra el que se valida asistencia (bloquea si no hay asistencia registrada esa fecha o es una inasistencia injustificada) y, si aplica, el tope de recuperacion / piso institucional (TCRITERIO_EVALUACION). Guarda el % (0-100) en TACTIVIDAD_NOTA.CALIFICACION. RECHAZA (22023) de entrada cualquier actividad de referente FORMATIVO (preescolar) -- usar PUT .../observar / POST .../observar-grupal (V246) en ese caso. Gate EDITAR sobre PLANEADOR. 404 (P0002) si la asignacion actividad-estudiante no existe; 22023 si falta asistencia, el payload no calza con el instrumento, o (RUBRICA) faltan/sobran criterios.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/actividades/estudiantes/:ID/calificar'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;


-- ===========================================================================
-- 4. PUT /planeador/actividades/:ID/calificar-bulk/rubrica —
--    fn_actividad_nota_calificar_rubrica_bulk (V227; un criterio+nivel
--    aplicado a N estudiantes -- flujo real de la Planilla). :ID = PK_TACTIVIDAD.
-- ===========================================================================
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_actividad_nota_calificar_rubrica_bulk(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.PK_CRITERIO AS BIGINT),
    CAST(:BODY.PK_NIVEL AS BIGINT),
    CAST(:BODY.ESTUDIANTES AS BIGINT[]),
    COALESCE(CAST(:BODY.FECHA AS DATE), CURRENT_DATE)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades/:ID/calificar-bulk/rubrica', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT", "BODY.PK_CRITERIO": "BIGINT", "BODY.PK_NIVEL": "BIGINT", "BODY.ESTUDIANTES": "BIGINT[]", "BODY.FECHA": "DATE"}'::jsonb,
    'V247 -- calificacion BULK por rubrica: aplica UN criterio + UN nivel de desempeno a VARIOS estudiantes de la misma actividad de una sola pasada (fn_actividad_nota_calificar_rubrica_bulk, V227) -- el flujo real de la pantalla "Planilla" cuando el docente elige la columna "Criterio: Nivel" y la aplica a los estudiantes marcados. :ID = PK_TACTIVIDAD. BODY.PK_CRITERIO/PK_NIVEL deben pertenecer a la rubrica de esta actividad; BODY.ESTUDIANTES (obligatorio, >=1) = PKs de TACTIVIDAD_ESTUDIANTE, cada uno debe pertenecer a esta actividad y tener asistencia valida en BODY.FECHA (default hoy). Hace upsert de UNA sola fila por estudiante (la de ese criterio): NO toca los demas criterios ya capturados (a diferencia de PUT .../calificar, que exige el set completo). Devuelve una fila por estudiante {pk_tactividad_estudiante, criterios_totales, criterios_cubiertos, calificacion, calificacion_actualizada}: calificacion_actualizada=true significa que ese estudiante ya cubrio todos los criterios y se guardo/recalculo la nota (TACTIVIDAD_NOTA.CALIFICACION); false es informativo (faltan criterios), no un error. Gate EDITAR sobre PLANEADOR. 22023 si la actividad no tiene instrumento RUBRICA, el criterio/nivel no pertenecen a esta rubrica, o algun estudiante no pertenece a la actividad o no tiene asistencia valida esa fecha.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/actividades/:ID/calificar-bulk/rubrica'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;


-- ===========================================================================
-- 5. PUT /planeador/actividades/:ID/calificar-bulk/cotejo —
--    fn_actividad_nota_calificar_cotejo_bulk (V227; un item marcado S/N para
--    N estudiantes). :ID = PK_TACTIVIDAD.
-- ===========================================================================
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_actividad_nota_calificar_cotejo_bulk(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.PK_ITEM AS BIGINT),
    CAST(:BODY.CUMPLIDO AS CHAR(1)),
    CAST(:BODY.ESTUDIANTES AS BIGINT[]),
    COALESCE(CAST(:BODY.FECHA AS DATE), CURRENT_DATE)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades/:ID/calificar-bulk/cotejo', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT", "BODY.PK_ITEM": "BIGINT", "BODY.CUMPLIDO": "VARCHAR", "BODY.ESTUDIANTES": "BIGINT[]", "BODY.FECHA": "DATE"}'::jsonb,
    'V247 -- calificacion BULK por lista de cotejo: marca UN item como cumplido (BODY.CUMPLIDO=''S'') o no cumplido (''N'') para VARIOS estudiantes de la misma actividad de una sola pasada (fn_actividad_nota_calificar_cotejo_bulk, V227) -- el flujo real de la pantalla cuando el docente recorre la lista item por item. :ID = PK_TACTIVIDAD. BODY.PK_ITEM debe pertenecer a la lista de cotejo de esta actividad; BODY.CUMPLIDO obligatorio, en {S,N}; BODY.ESTUDIANTES (obligatorio, >=1) = PKs de TACTIVIDAD_ESTUDIANTE, cada uno debe pertenecer a esta actividad y tener asistencia valida en BODY.FECHA (default hoy). Hace upsert de UNA sola fila por estudiante (la de ese item): NO toca los demas items ya capturados. A diferencia del bulk de rubrica, SIEMPRE recalcula y guarda TACTIVIDAD_NOTA.CALIFICACION en la misma pasada (un item sin captura cuenta como no cumplido por diseño, no hay "incompleto"). Devuelve una fila por estudiante {pk_tactividad_estudiante, items_totales, items_cumplidos, calificacion}. Gate EDITAR sobre PLANEADOR. 22023 si la actividad no tiene instrumento LISTA_COTEJO, el item no pertenece a esta lista, CUMPLIDO invalido, o algun estudiante no pertenece a la actividad o no tiene asistencia valida esa fecha.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/actividades/:ID/calificar-bulk/cotejo'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;


-- ===========================================================================
-- 6. PUT /planeador/actividades/:ID/calificar-bulk/escala —
--    fn_actividad_nota_calificar_escala_bulk (V227; un nivel de escala
--    CUALITATIVA para N estudiantes; la NUMERICA no admite bulk).
--    :ID = PK_TACTIVIDAD.
-- ===========================================================================
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_actividad_nota_calificar_escala_bulk(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.PK_NIVEL AS BIGINT),
    CAST(:BODY.ESTUDIANTES AS BIGINT[]),
    COALESCE(CAST(:BODY.FECHA AS DATE), CURRENT_DATE)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades/:ID/calificar-bulk/escala', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT", "BODY.PK_NIVEL": "BIGINT", "BODY.ESTUDIANTES": "BIGINT[]", "BODY.FECHA": "DATE"}'::jsonb,
    'V247 -- calificacion BULK por escala de valoracion: aplica UN nivel de la escala CUALITATIVA a VARIOS estudiantes de la misma actividad de una sola pasada (fn_actividad_nota_calificar_escala_bulk, V227). Solo aplica a escala CUALITATIVA -- la escala NUMERICA (valor digitado por estudiante) no admite bulk, se califica individual via PUT .../calificar. :ID = PK_TACTIVIDAD. BODY.PK_NIVEL debe pertenecer a la escala CUALITATIVA de esta actividad; BODY.ESTUDIANTES (obligatorio, >=1) = PKs de TACTIVIDAD_ESTUDIANTE, cada uno debe pertenecer a esta actividad y tener asistencia valida en BODY.FECHA (default hoy). Devuelve una fila por estudiante {pk_tactividad_estudiante, calificacion}. Gate EDITAR sobre PLANEADOR. 22023 si la actividad no tiene instrumento ESCALA_VALORACION, la escala es NUMERICA, el nivel no pertenece a ella, o algun estudiante no pertenece a la actividad o no tiene asistencia valida esa fecha.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/actividades/:ID/calificar-bulk/escala'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;


-- ===========================================================================
-- 7. GET /planeador/actividades/estudiantes/:ID/nota —
--    fn_actividad_nota_obtener (V227, editada en V241; detalle de UN
--    estudiante). :ID = PK_TACTIVIDAD_ESTUDIANTE.
-- ===========================================================================
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_actividad_nota_obtener(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades/estudiantes/:ID/nota', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    'V247 -- detalle de la calificacion de UN estudiante en una actividad (fn_actividad_nota_obtener, V227, editada en V241 -- OTRO estructurado). :ID = PK_TACTIVIDAD_ESTUDIANTE (NO PK_TACTIVIDAD). Retorna {instrumento, calificacion (% 0-100 o NULL si aun no hay nota), calificable (S/N), observacion (texto libre de fn_actividad_observar_*, V246, o NULL), detalle (JSONB con la captura cruda segun instrumento: RUBRICA -> [{pkCriterio,pkNivel,ponderacion}]; LISTA_COTEJO -> [{pkItem,cumplido}]; ESCALA_VALORACION -> {pkNivel,valor,ponderacion}; OTRO con metodo configurado -> el mismo formato del metodo equivalente)}. Distinta de GET /planeador/actividades/:ID/calificaciones (V247, punto 8), que es la TABLA completa de todos los estudiantes de la actividad. Gate VER sobre PLANEADOR. 404 (P0002) si la asignacion actividad-estudiante no existe.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/actividades/estudiantes/:ID/nota'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;


-- ===========================================================================
-- 8. GET /planeador/actividades/:ID/calificaciones —
--    fn_actividad_estudiantes_calificaciones_listar (V227; tabla completa
--    de la pantalla "Calificaciones: <actividad>"). :ID = PK_TACTIVIDAD.
-- ===========================================================================
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_actividad_estudiantes_calificaciones_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    COALESCE(CAST(:QUERY.FECHA AS DATE), CURRENT_DATE),
    CAST(:QUERY.SEARCH AS VARCHAR)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades/:ID/calificaciones', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT", "QUERY.FECHA": "DATE", "QUERY.SEARCH": "VARCHAR"}'::jsonb,
    'V247 -- tabla completa de la pantalla "Calificaciones: <actividad>": una fila por cada estudiante ACTIVO asignado a la actividad, con su asistencia de ?fecha= (default hoy) y su nota (fn_actividad_estudiantes_calificaciones_listar, V227). :ID = PK_TACTIVIDAD. Cada fila = {pk_tactividad_estudiante, pk_tmatricula, nombre_estudiante, instrumento (repetido por fila, evita una segunda consulta), fecha, pk_tasistencia, fk_tlv_tipo_asistencia, tipo_asistencia, asistencia_observacion, fk_soporte_archivo (todos NULL si no hay asistencia registrada esa fecha -- no es un error), calificacion, calificable, nota_observacion}. ?search= filtra por nombre (ILIKE simple). Sin paginacion (universo acotado a una actividad, normalmente un grupo). Ordena por nombre. Distinta de GET /planeador/actividades/estudiantes/:ID/nota (V247, punto 7), que es el detalle de captura completo de UN estudiante. Gate VER sobre PLANEADOR. 404 (P0002) si la actividad no existe.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/actividades/:ID/calificaciones'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;
