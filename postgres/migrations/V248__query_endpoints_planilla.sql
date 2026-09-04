-- ===========================================================================
-- V248 — Planeador educativo: registro en public.query (motor SSO /
-- query-service) de los endpoints de la pantalla "Planilla de calificacion"
-- y del filtro Grado -> Grupo -> Asignatura del docente (CU-86e311xxp,
-- LOTE 4 -- ULTIMO de la tanda de endpoints del Planeador).
--
-- Este archivo NO crea funciones nuevas: las funciones ya existen y estan
-- validadas en esta rama (V239, V242). Solo registra las filas public.query
-- (+ role_query) para exponerlas via el gateway como api/eval-col/... . El
-- LOTE 1 (V245, dominio UNIDAD), el LOTE 2 (V246, dominio ACTIVIDAD) y el
-- LOTE 3 (V247, INSTRUMENTOS/CALIFICAR) registran sus propios endpoints por
-- separado -- NO se duplican aqui.
--
-- microservice_id se resuelve por serviceid='eval-col' (mismo microservicio
-- que sirve el resto del modulo academico -- V51/V64/V149/V185/V198/V199/
-- V245/V246/V247).
--
-- p_pk_usuario_solicitante SIEMPRE se resuelve de :CONTEXT.USER_ID via
-- public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT) -- igual que
-- V149/V167/V168/V185/V198/V199/V245/V246/V247 -- nunca se expone como
-- parametro editable por el cliente.
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
--   Mismo criterio ya aplicado (y funcionando) en V245/V246/V247/V214: en
--   este Postgres local de Docker solo existe el rol
--   'CEVAL-SUPER_ADMINISTRADOR' sincronizado a public.role (el catalogo real
--   de TROL -- DOCENTE, RECTOR, etc -- no esta sembrado en las migraciones,
--   ver nota "TROL: el catalogo de roles no esta en las migraciones" en
--   memoria del proyecto). Cuando el ambiente real tenga el rol de DOCENTE
--   sincronizado, agregar esa fila a role_query es un cambio de una linea
--   (INSERT posterior a public.role_query, no requiere tocar esta migracion).
--
-- CAVEAT DE RECARGA (dejar constancia, igual que V149/V167/V185/V198/V199/
-- V245/V246/V247): las filas nuevas en public.query dan 404 por el gateway
-- hasta que el contenedor query-service-eval-col se reinicia. No aplica a
-- esta validacion SQL (fuera de alcance segun el enunciado de la tarea; otro
-- agente esta corriendo pruebas end-to-end reales por separado sobre los
-- lotes anteriores -- no se reinicia el contenedor desde aqui).
--
-- CONVENCIONES DE PARAMETROS (V32/V49, igual que V245/V246/V247):
--   :PARAM.<VAR>   -> variable de la ruta (path_template ...:VAR...).
--   :QUERY.<VAR>   -> filtro por query-string (?var=...); QUERY.SIZE/
--                     QUERY.OFFSET son system-bound (paginacion), el resto
--                     de nombres de QUERY.* SI necesita entrada en
--                     param_types.
--   :BODY.<VAR>    -> campo del body JSON.
--   :CONTEXT.*     -> system-bound (JWT verificado), nunca en param_types.
--
-- execution_mode = 'SELECT' en TODAS las filas: este lote es 100% de
-- lectura (GET) -- mismo patron que V64/V149/V185/V198/V199/V245/V246/V247.
--
-- -------------------------------------------------------------------------
-- FUNCIONES PUBLICAS DE V239 REVISADAS (grep completo de
-- "CREATE OR REPLACE FUNCTION" en V239) Y DECISION SOBRE CUALES SE EXPONEN:
--
--   fn_unidad_ponderacion_intra_asignatura_asignada  -> NO se expone: helper
--       interno (STABLE, sin gate propio), solo lo consumen el trigger y las
--       dos funciones de abajo.
--   fn_tunidad_ponderacion_asignatura_check          -> trigger, no aplica.
--   fn_asignatura_grado_ponderacion_disponible       -> SI se expone (punto
--       5). Tiene gate VER propio y devuelve un dato consumible directamente
--       ("Disponible para asignar: X%" al capturar TUNIDAD.PONDERACION desde
--       el formulario de unidad, fn_unidad_crear/_actualizar de V216). Es el
--       analogo, un nivel arriba, de fn_unidad_ponderacion_disponible (V223),
--       YA EXPUESTO por V245 punto 18 como
--       GET /planeador/unidades/:ID/ponderacion-disponible. Por cronologia de
--       archivo (V239 < V245) podria pensarse que le tocaba a V245, pero V245
--       fue escrita sin conocer este helper nuevo (su cabecera solo declara
--       dependencia de V216/V222/V136/V223/V244) y por eso quedo sin exponer.
--       Se cierra aqui, en el ULTIMO lote de la tanda, para no dejar un
--       endpoint gateado huerfano. Aunque conceptualmente es del formulario de
--       UNIDAD (no de la pantalla Planilla), es la unica funcion publica de
--       V239 fuera de las 3 propias de Planilla, y el enunciado de esta tarea
--       pide expresamente revisar el archivo completo y no asumir que son
--       solo las 3 esperadas.
--   fn_planilla_grupo_asignatura_assert   -> NO se expone: RETURNS VOID, sin
--       gate, solo valida (la usan internamente las 2 funciones de la
--       planilla, que devuelven su mismo error si el filtro es invalido).
--   fn_planilla_actividades_universo      -> NO se expone: helper interno sin
--       gate (documentado explicitamente en su propio comentario: "No gatea
--       permisos, helper interno"); es la fuente de columnas/orden que
--       consumen fn_planilla_columnas_listar y fn_planilla_calificaciones_listar,
--       exponerlo aparte duplicaria el header sin las columnas resueltas que
--       si trae fn_planilla_columnas_listar.
--   fn_asignatura_plan_vigente_por_grado / fn_asignatura_plan_vigente
--       -> NO se exponen: RETURNS BIGINT (solo un PK interno de
--       TASIGNATURA_PLAN), sin gate, sin utilidad para un cliente HTTP.
--   fn_asignatura_criterio_evaluacion_vigente,
--   fn_criterio_evaluacion_porcentaje_inicial,
--   fn_criterio_evaluacion_porcentaje_maximo_recuperacion,
--   fn_asignatura_plan_elemento_calculo,
--   fn_asignatura_plan_calculo_definitiva_modo
--       -> NO se exponen: los 5 son accesores/resoluciones internas (LANGUAGE
--       sql, sin gate), consumidos por V227 (fn_actividad_nota_ajustar_por_criterio)
--       y por fn_planilla_definitiva_proyectada. No son pantalla, son
--       configuracion interna del motor de calculo.
--
-- DECISION SOBRE fn_planilla_definitiva_proyectada (columna "DEFINIT
-- PROY.") — NO SE EXPONE STANDALONE.
--
-- Confirmado leyendo V239 completo: fn_planilla_calificaciones_listar YA
-- invoca fn_planilla_definitiva_proyectada por cada fila de estudiante (LEFT
-- JOIN LATERAL "def") y la devuelve embebida como la columna
-- definitiva_proyectada del listado paginado (ver el punto 2 de este
-- archivo). Ademas fn_planilla_definitiva_proyectada NO tiene gate propio
-- (STABLE, sin PERFORM fn_assert_permiso_seccion): esta escrita para ser
-- invocada desde dentro de otra funcion que YA valido el permiso, no para
-- exponerse ella sola por el gateway (habria que envolverla en un gate
-- nuevo, redundante con el que ya hace el listado). Exponer una ruta aparte
-- solo repetiria, por estudiante, el mismo numero que el listado ya trae por
-- fila -- cero informacion adicional, una llamada N+1 extra en el cliente
-- (una por estudiante en vez de una por pagina) y un endpoint sin el gate
-- real. Si en el futuro la pantalla necesita un popover de detalle de "como
-- se compuso la definitiva proyectada" (desglose por actividad/unidad, no
-- solo el numero final), seria una funcion NUEVA de desglose, no la misma
-- fn_planilla_definitiva_proyectada de hoy (que retorna un solo NUMERIC).
--
-- -------------------------------------------------------------------------
-- p_fk_tfuncionario NULL-SAFE — fn_docente_grupos_listar /
-- fn_docente_grado_asignatura_listar (V242).
--
-- Confirmado leyendo V242 completo: ambas funciones filtran con
-- "da.FK_TFUNCIONARIO = p_fk_tfuncionario" (comparacion de igualdad estandar,
-- sin IS NOT DISTINCT FROM). Si el usuario autenticado NO es funcionario
-- activo, la subconsulta de resolucion (ver mas abajo) da NULL, y en SQL
-- estandar "cualquier_valor = NULL" evalua a NULL (nunca TRUE): el WHERE
-- descarta todas las filas sin lanzar error. Ambas funciones SOPORTAN
-- p_fk_tfuncionario NULL sin romper -- devuelven vacio (0 filas), no 500 ni
-- excepcion. No se toco nada de V242 (fuera de alcance segun el enunciado:
-- "confirma que soportan p_fk_tfuncionario NULL sin romper; si no lo
-- soportan, avisame, no lo arregles tu sin confirmar" -- si lo soportan, no
-- hay nada que avisar como bloqueante).
--
-- El query-service resuelve p_fk_tfuncionario ANTES de llamar a la funcion,
-- con el MISMO patron documentado en la rama de Asistencias
-- (CU-86e32gvpp, cross-branch):
--   (SELECT f.PK_TFUNCIONARIO
--      FROM academico_test.TFUNCIONARIO f
--     WHERE f.FK_TUSUARIO = public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
--       AND f.ACTIVE = TRUE)
-- Si el usuario autenticado no es funcionario (o el que es esta inactivo),
-- la subconsulta da NULL y, por lo explicado arriba, el endpoint responde
-- 200 con una lista vacia -- comportamiento correcto para un rol
-- administrativo que consulte este filtro sin ser docente, o para cualquier
-- llamada desde un usuario no-funcionario.
--
-- -------------------------------------------------------------------------
-- NOMENCLATURA DE RUTAS (decision de este lote):
--   * GET /planeador/planilla/columnas         (fn_planilla_columnas_listar,
--     el HEADER de la planilla; filtros por query-string, NO por PK de ruta:
--     no existe un recurso "planilla" con PK propio, es siempre una
--     combinacion grupo+asignatura+[grado]+[fechas]+[search]).
--   * GET /planeador/planilla/calificaciones   (fn_planilla_calificaciones_listar,
--     el CUERPO paginado de la planilla; mismos filtros + busqueda de
--     estudiante + paginacion QUERY.SIZE/QUERY.OFFSET).
--   * GET /planeador/docentes/grupos           (fn_docente_grupos_listar,
--     paso 1-2 del filtro en cascada para el docente autenticado: grupos con
--     su grado, donde dicta al menos una asignatura en el periodo).
--   * GET /planeador/docentes/grado-asignatura (fn_docente_grado_asignatura_listar,
--     paso 3 del filtro: pares grado-asignatura distintos del docente en el
--     periodo).
--   * GET /planeador/asignaturas/:ID/ponderacion-disponible
--     (fn_asignatura_grado_ponderacion_disponible, :ID = PK_TASIGNATURA,
--     ?grado= obligatorio -- ver DECISION arriba sobre por que se expone en
--     este lote y no en V245).
--
-- Depende de (orden de version de Flyway): V239 (planilla, TUNIDAD.PONDERACION
-- + helpers de calculo), V242 (filtro docente, TDOCENTE_ASIGNATURA de V46).
-- ===========================================================================


-- ===========================================================================
-- 1. GET /planeador/planilla/columnas —
--    fn_planilla_columnas_listar (V239; HEADER de la planilla).
-- ===========================================================================
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_planilla_columnas_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.GRUPO AS BIGINT),
    CAST(:QUERY.ASIGNATURA AS BIGINT),
    CAST(:QUERY.GRADO AS BIGINT),
    CAST(:QUERY.FECHA_DESDE AS DATE),
    CAST(:QUERY.FECHA_HASTA AS DATE),
    CAST(:QUERY.SEARCH AS VARCHAR)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/planilla/columnas', 'SELECT', 'GET',
    '{"QUERY.GRUPO": "BIGINT", "QUERY.ASIGNATURA": "BIGINT", "QUERY.GRADO": "BIGINT", "QUERY.FECHA_DESDE": "DATE", "QUERY.FECHA_HASTA": "DATE", "QUERY.SEARCH": "VARCHAR"}'::jsonb,
    'V248 -- HEADER de la pantalla "Planilla de calificacion": una fila por actividad-columna del (grupo, asignatura) pedido, en el MISMO orden (orden_columna) que las celdas de GET /planeador/planilla/calificaciones (ambas comparten fn_planilla_actividades_universo, V239, no pueden desalinearse) (fn_planilla_columnas_listar, V239). ?grupo= y ?asignatura= OBLIGATORIOS (22023 si falta alguno -- la pantalla no muestra nada hasta tener el filtro completo); ?grado= opcional, si viene debe ser el grado de ese grupo (23503 con el nombre del grupo en el mensaje); ?fechaDesde/?fechaHasta acotan las columnas por ventana de fechas (misma semantica de solapamiento que fn_actividad_listar, V224); ?search filtra por titulo+descripcion de la actividad. Cada fila trae: orden_columna, pk_tactividad, titulo, fk_tunidad + unidad (nombre -- con esto el cliente arma el sub-header del toggle "Ver por: Unidad" agrupando columnas contiguas, sin otra consulta), fk_tlv_instrumento_evaluacion + instrumento (VALOR) + instrumento_nombre (para saber que popover de calificacion abrir, y consultar despues GET /planeador/actividades/:ID/instrumento de V247), ponderacion, nota_maxima, es_evaluativa, fecha_inicio, fecha_cierre, estudiantes_asignados y estudiantes_calificados (progreso acotado a ESTE grupo). Sin paginacion (son las columnas visibles de una tabla). Gate VER sobre PLANEADOR. 404 (P0002) si el grupo o la asignatura no existen; 22023 si falta grupo o asignatura; 23503 si el grado no corresponde al grupo.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/planilla/columnas'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;


-- ===========================================================================
-- 2. GET /planeador/planilla/calificaciones —
--    fn_planilla_calificaciones_listar (V239; CUERPO paginado de la
--    planilla, con la definitiva proyectada embebida por fila -- ver
--    DECISION en la cabecera sobre por que fn_planilla_definitiva_proyectada
--    NO se expone aparte).
-- ===========================================================================
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_planilla_calificaciones_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.GRUPO AS BIGINT),
    CAST(:QUERY.ASIGNATURA AS BIGINT),
    CAST(:QUERY.GRADO AS BIGINT),
    CAST(:QUERY.FECHA_DESDE AS DATE),
    CAST(:QUERY.FECHA_HASTA AS DATE),
    CAST(:QUERY.SEARCH_ACTIVIDAD AS VARCHAR),
    CAST(:QUERY.SEARCH_ESTUDIANTE AS VARCHAR),
    COALESCE(CAST(:QUERY.SIZE AS INT), 50),
    COALESCE(CAST(:QUERY.OFFSET AS INT), 0)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/planilla/calificaciones', 'SELECT', 'GET',
    '{"QUERY.GRUPO": "BIGINT", "QUERY.ASIGNATURA": "BIGINT", "QUERY.GRADO": "BIGINT", "QUERY.FECHA_DESDE": "DATE", "QUERY.FECHA_HASTA": "DATE", "QUERY.SEARCH_ACTIVIDAD": "VARCHAR", "QUERY.SEARCH_ESTUDIANTE": "VARCHAR"}'::jsonb,
    'V248 -- CUERPO paginado de la pantalla "Planilla de calificacion": una fila por estudiante ACTIVO matriculado en el grupo, con sus celdas por actividad y la definitiva proyectada (fn_planilla_calificaciones_listar, V239). ?grupo= y ?asignatura= OBLIGATORIOS (22023 si falta alguno); ?grado= opcional (23503 si no corresponde al grupo); ?fechaDesde/?fechaHasta/?searchActividad acotan las COLUMNAS igual que GET /planeador/planilla/columnas (mismo universo, fn_planilla_actividades_universo); ?searchEstudiante filtra las FILAS por nombre. Paginacion por estudiante via QUERY.SIZE (default 50) / QUERY.OFFSET (default 0), total_count por fila. Cada fila trae: pk_tmatricula, pk_testudiante, nombre_estudiante, definitiva_proyectada (regla del motor legacy configurada en TASIGNATURA_PLAN -- plano por actividades o por unidad, ver cabecera de V239 y sus limitaciones documentadas sobre grados multi-plan y TUNIDAD.PONDERACION incompleta; YA VIENE CALCULADA por fila, no se expone endpoint aparte para pedirla por estudiante), definitiva_registrada + tendencia (SUBE/BAJA/IGUAL/NULL -- la flecha de la pantalla; tendencia SIEMPRE NULL hoy porque ninguna funcion del repo consolida TUNIDAD_NOTA, el cliente no debe pintar flecha mientras sea NULL), y celdas (JSONB ordenado por ordenColumna: [{ordenColumna, pkTactividad, pkTunidad, pkTactividadEstudiante, estado, calificacion, recuperacion, definitiva, nota, calificable, observacion}], con estado en NO_ASIGNADA (icono prohibido, pkTactividadEstudiante NULL -> no se puede abrir el popover) | NO_CALIFICABLE | SIN_CALIFICAR | CALIFICADA). El toggle "Ver por: Actividad | Unidad" no cambia esta consulta: se agrupa en el cliente por pkTunidad. Gate VER sobre PLANEADOR. 404 (P0002) si el grupo o la asignatura no existen; 22023 si falta grupo o asignatura; 23503 si el grado no corresponde al grupo.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR')
 WHERE m.serviceid    = 'eval-col'
   AND q.path_template = '/planeador/planilla/calificaciones'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;


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
    (SELECT f.PK_TFUNCIONARIO
       FROM academico_test.TFUNCIONARIO f
      WHERE f.FK_TUSUARIO = public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
        AND f.ACTIVE = TRUE)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/docentes/grupos', 'SELECT', 'GET',
    '{"QUERY.PERIODO": "BIGINT"}'::jsonb,
    'V248 -- paso 1-2 del filtro en cascada Grado -> Grupo -> Asignatura de la pantalla "Planilla de calificacion" (V239) para el DOCENTE autenticado: grupos (con su grado y nivel de ensenanza) donde el docente dicta al menos una asignatura en el periodo pedido (fn_docente_grupos_listar, V242). ?periodo= obligatorio (PK_TPERIODO_ACADEMICO). p_fk_tfuncionario se resuelve del token AQUI (TFUNCIONARIO.FK_TUSUARIO = usuario autenticado, ACTIVE=TRUE), nunca lo envia el cliente -- mismo patron que la rama de Asistencias (CU-86e32gvpp). Si el usuario autenticado no es funcionario activo (o no dicta nada en ese periodo), responde 200 con lista vacia, no error (confirmado NULL-safe leyendo V242). Cada fila trae grupo_id/codigo/nombre/capacidad, jornada (id/valor/nombre), modelo_pedagogico (id/valor/nombre), grado (id/codigo/nombre) y nivel_ensenanza (id/nombre). Sin paginar (universo de un docente en un periodo). Gate VER sobre PLANEADOR + fn_periodo_usuario_puede_ver. NO usar TGRUPO.FK_TFUNCIONARIO (ese es el director de grupo, no el docente de la asignatura).'
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
    (SELECT f.PK_TFUNCIONARIO
       FROM academico_test.TFUNCIONARIO f
      WHERE f.FK_TUSUARIO = public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT)
        AND f.ACTIVE = TRUE)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/docentes/grado-asignatura', 'SELECT', 'GET',
    '{"QUERY.PERIODO": "BIGINT"}'::jsonb,
    'V248 -- paso 3 del filtro en cascada Grado -> Grupo -> Asignatura de la pantalla "Planilla de calificacion" (V239) para el DOCENTE autenticado: pares (grado, asignatura) DISTINTOS que dicta en el periodo pedido, sin repetir por tener la misma asignatura en varios grupos del mismo grado (fn_docente_grado_asignatura_listar, V242). ?periodo= obligatorio. p_fk_tfuncionario se resuelve del token igual que en GET /planeador/docentes/grupos (punto 3) -- NULL-safe: usuario no-funcionario responde 200 con lista vacia. Cada fila trae grado (id/codigo/nombre) y asignatura (id/codigo/nombre). Sin paginar. Gate VER sobre PLANEADOR + fn_periodo_usuario_puede_ver.'
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
