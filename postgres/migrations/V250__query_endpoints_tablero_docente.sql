-- ===========================================================================
-- V250 — Planeador educativo: tablero de estados del DOCENTE (las 4 tarjetas
-- "Pendientes por evaluar / En evaluacion vigentes / Finalizadas / Vencidas")
-- y su "Ver detalles" filtrado por estado, mas el arreglo del filtro
-- Grado->Grupo->Asignatura del docente (CU-86e311xxp).
--
-- Este archivo NO crea las funciones de negocio: fn_funcionario_actual,
-- fn_actividad_resumen_estados_docente y fn_actividad_listar_docente se
-- editaron in-place en V224 (mismo criterio ya usado en esta rama para
-- V113/V123/V185), junto con el nuevo parametro p_fk_tfuncionario de
-- fn_actividad_listar / fn_actividad_resumen_estados. Aqui solo se
-- registran los endpoints y se corrige el gate de V242.
--
-- -------------------------------------------------------------------------
-- (1) FIX DE V242 — por que /planeador/docentes/grupos devolvia SIEMPRE
--     vacio para un docente real.
--
-- fn_docente_grupos_listar / fn_docente_grado_asignatura_listar (V242)
-- exigen fn_periodo_usuario_puede_ver(usuario, periodo). Ese helper (del
-- sistema de capability+scope, otra rama) resuelve el alcance territorial
-- asi:
--     fn_periodo_usuario_global   -> TSEDE_USUARIO.FK_TROL IN (1,2,3)
--     fn_periodo_usuario_sedes    -> TSEDE_USUARIO.FK_TROL IN (11)   [COORDINADOR]
-- Un DOCENTE (FK_TROL=14) no esta en ninguno de los dos, asi que el gate
-- devuelve FALSE para CUALQUIER docente, en cualquier periodo, aunque este
-- correctamente asignado a la sede de ese periodo -- verificado contra un
-- docente real con TDOCENTE_ASIGNATURA vigente: el endpoint respondia 200
-- con lista vacia.
--
-- El arreglo NO es tocar ese helper (pertenece a otra rama y a otro
-- dominio): es reconocer que estas dos funciones YA traen el alcance mas
-- estricto posible en su propio WHERE -- filtran por
-- TDOCENTE_ASIGNATURA.FK_TFUNCIONARIO = p_fk_tfuncionario, es decir "solo
-- las asignaciones de ESE docente". Cuando el funcionario consultado ES el
-- usuario autenticado (auto-consulta, que es exactamente como las invoca
-- el endpoint), pedir ademas alcance territorial es redundante: nadie ve
-- nada que no sea suyo. Se agrega esa alternativa al gate:
--
--     fn_periodo_usuario_puede_ver(...)            -- admin/coordinador
--  OR p_fk_tfuncionario = fn_funcionario_actual(...)  -- el docente, sobre si mismo
--
-- Con un p_fk_tfuncionario AJENO (un administrativo consultando a otro
-- docente) el gate territorial sigue aplicando igual que antes -- no se
-- abre ningun camino nuevo.
--
-- -------------------------------------------------------------------------
-- (2) ENDPOINTS del tablero del docente. Mismas convenciones que
--     V245-V248 (microservice eval-col, p_pk_usuario_solicitante siempre
--     desde :CONTEXT.USER_ID, execution_mode SELECT, role_query para
--     CEVAL-SUPER_ADMINISTRADOR + CEVAL-DOCENTE -- este ultimo ya agregado
--     en V249 para el resto de /planeador/%).
--
--     El FK_TFUNCIONARIO NO se expone como parametro: lo resuelve la propia
--     funcion con fn_funcionario_actual a partir del token (a diferencia de
--     V248, que lo resuelve en el SQL del endpoint). Asi el cliente no
--     puede pedir el tablero de otro docente.
--
-- Depende de: V224 (funciones del tablero, editadas in-place), V242
-- (funciones del filtro docente), V245-V248 (endpoints /planeador/...),
-- V249 (CEVAL-DOCENTE en role_query).
-- ===========================================================================

SET search_path TO academico_test, public;

-- ===========================================================================
-- (1) FIX del gate de V242 — auto-consulta del docente sobre sus propias
--     asignaciones. Ver cabecera.
-- ===========================================================================
CREATE OR REPLACE FUNCTION academico_test.fn_docente_grupos_listar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_periodo             BIGINT,
    p_fk_tfuncionario        BIGINT
)
RETURNS TABLE (
    grupo_id                BIGINT,
    grupo_codigo             VARCHAR,
    grupo_nombre             VARCHAR,
    capacidad                NUMERIC,
    jornada_id               BIGINT,
    jornada_valor            VARCHAR,
    jornada_nombre           VARCHAR,
    modelo_pedagogico_id     BIGINT,
    modelo_pedagogico_valor  VARCHAR,
    modelo_pedagogico_nombre VARCHAR,
    grado_id                 BIGINT,
    grado_codigo             VARCHAR,
    grado_nombre             VARCHAR,
    nivel_ensenanza_id       BIGINT,
    nivel_ensenanza_nombre   VARCHAR
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    RETURN QUERY
    SELECT DISTINCT
           gr.PK_TGRUPO, gr.CODIGO, gr.NOMBRE,
           gr.CAPACIDAD,
           jor.PK_LISTA_VALOR, jor.VALOR, jor.NOMBRE,
           mp.PK_LISTA_VALOR, mp.VALOR, mp.NOMBRE,
           g.PK_TGRADO, g.CODIGO, g.NOMBRE,
           ne.PK_NIVEL_ENSENANZA, ne.NOMBRE
      FROM academico_test.TDOCENTE_ASIGNATURA da
      JOIN academico_test.TGRUPO gr           ON gr.PK_TGRUPO = da.FK_TGRUPO AND gr.ACTIVE = TRUE
      JOIN academico_test.TGRADO g            ON g.PK_TGRADO = gr.FK_TGRADO AND g.ACTIVE = TRUE
      JOIN academico_test.TNIVEL_ENSENANZA ne ON ne.PK_NIVEL_ENSENANZA = g.FK_TNIVEL_ENSENANZA
      JOIN academico_test.TLISTA_VALOR jor    ON jor.PK_LISTA_VALOR = gr.FK_TLV_JORNADA
      JOIN academico_test.TLISTA_VALOR mp     ON mp.PK_LISTA_VALOR = gr.FK_TLV_MODELO_PEDAGOGICO
     WHERE da.FK_TFUNCIONARIO = p_fk_tfuncionario
       AND da.FK_TPERIODO_ACADEMICO = p_fk_periodo
       AND da.ACTIVE = TRUE
       -- V250: el alcance territorial (admin/coordinador) O la auto-consulta
       -- del propio docente sobre sus asignaciones -- ver cabecera.
       AND ( academico_test.fn_periodo_usuario_puede_ver(p_pk_usuario_solicitante, p_fk_periodo)
             OR p_fk_tfuncionario = academico_test.fn_funcionario_actual(p_pk_usuario_solicitante) )
     ORDER BY g.NOMBRE, gr.NOMBRE;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_docente_grupos_listar(BIGINT, BIGINT, BIGINT) IS
'Grupos (con grado y nivel de ensenanza) donde un docente dicta al menos una asignatura en el periodo dado. Filtro de la pantalla Planilla de calificacion (V239) para el rol docente. p_fk_tfuncionario debe venir ya resuelto por el llamador. V250: el gate de alcance acepta fn_periodo_usuario_puede_ver (admin/coordinador) O que el funcionario consultado sea el propio usuario autenticado (fn_funcionario_actual) -- sin esa alternativa NINGUN docente veia sus grupos, porque fn_periodo_usuario_sedes solo reconoce FK_TROL=11 (COORDINADOR) y el global FK_TROL IN (1,2,3). Consultar a OTRO docente sigue exigiendo el alcance territorial. V242/V250.';

CREATE OR REPLACE FUNCTION academico_test.fn_docente_grado_asignatura_listar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_periodo             BIGINT,
    p_fk_tfuncionario        BIGINT
)
RETURNS TABLE (
    grado_id       BIGINT,
    grado_codigo    VARCHAR,
    grado_nombre    VARCHAR,
    asignatura_id   BIGINT,
    asignatura_codigo VARCHAR,
    asignatura_nombre VARCHAR
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER'
    );

    RETURN QUERY
    SELECT DISTINCT
           g.PK_TGRADO, g.CODIGO, g.NOMBRE,
           s.PK_TASIGNATURA, s.CODIGO, s.NOMBRE
      FROM academico_test.TDOCENTE_ASIGNATURA da
      JOIN academico_test.TGRUPO gr       ON gr.PK_TGRUPO = da.FK_TGRUPO AND gr.ACTIVE = TRUE
      JOIN academico_test.TGRADO g        ON g.PK_TGRADO = gr.FK_TGRADO AND g.ACTIVE = TRUE
      JOIN academico_test.TASIGNATURA s   ON s.PK_TASIGNATURA = da.FK_TASIGNATURA AND s.ACTIVE = TRUE
     WHERE da.FK_TFUNCIONARIO = p_fk_tfuncionario
       AND da.FK_TPERIODO_ACADEMICO = p_fk_periodo
       AND da.ACTIVE = TRUE
       AND ( academico_test.fn_periodo_usuario_puede_ver(p_pk_usuario_solicitante, p_fk_periodo)
             OR p_fk_tfuncionario = academico_test.fn_funcionario_actual(p_pk_usuario_solicitante) )
     ORDER BY g.NOMBRE, s.NOMBRE;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_docente_grado_asignatura_listar(BIGINT, BIGINT, BIGINT) IS
'Pares (grado, asignatura) distintos que un docente dicta en el periodo dado, sin repetir por tener la misma asignatura en varios grupos del mismo grado. Filtro de la pantalla Planilla de calificacion (V239) para el rol docente. p_fk_tfuncionario debe venir ya resuelto por el llamador. V250: mismo gate de auto-consulta que fn_docente_grupos_listar (ver su COMMENT). V242/V250.';

-- ===========================================================================
-- (2) ENDPOINTS
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 2.1 GET /planeador/actividades/tablero — las 4 tarjetas del docente.
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_actividad_resumen_estados_docente(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.ASIGNATURA AS BIGINT),
    CAST(:QUERY.GRUPO AS BIGINT),
    CAST(:QUERY.UNIDAD AS BIGINT),
    CAST(:QUERY.FECHA_DESDE AS DATE),
    CAST(:QUERY.FECHA_HASTA AS DATE),
    COALESCE(CAST(:QUERY.DIAS_GRACIA AS INT), 2)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades/tablero', 'SELECT', 'GET',
    '{"QUERY.ASIGNATURA": "BIGINT", "QUERY.GRUPO": "BIGINT", "QUERY.UNIDAD": "BIGINT", "QUERY.FECHA_DESDE": "DATE", "QUERY.FECHA_HASTA": "DATE", "QUERY.DIAS_GRACIA": "INT"}'::jsonb,
    'V250 -- tarjetas del tablero "mis actividades" del DOCENTE autenticado (fn_actividad_resumen_estados_docente, V224/V250): pendientes_por_evaluar, en_evaluacion, finalizadas, vencidas, programadas, sin_programar y total, en una sola pasada. El docente se resuelve del token (fn_funcionario_actual sobre :CONTEXT.USER_ID) y NO es un parametro -- nadie puede pedir el tablero de otro docente por esta ruta. Solo cuenta actividades que el usuario DICTA (TDOCENTE_ASIGNATURA por grupo+asignatura), no las que aparecen en unidades de las que es autor. Filtros opcionales ?asignatura=, ?grupo=, ?unidad=, ?fechaDesde=, ?fechaHasta= y ?diasGracia= (default 2, umbral de "Vencida"). Si el usuario autenticado no es un docente activo devuelve todos los contadores en 0 (no es error). Para el "Ver detalles" de cada tarjeta usar GET /planeador/actividades/mias?estados=... . Gate VER sobre PLANEADOR.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2.2 GET /planeador/actividades/mias — "Ver detalles" de una tarjeta.
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    gen_random_uuid()::text,
    'SELECT * FROM academico_test.fn_actividad_listar_docente(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.SEARCH AS VARCHAR),
    CAST(:QUERY.ASIGNATURA AS BIGINT),
    CAST(:QUERY.GRUPO AS BIGINT),
    CAST(:QUERY.UNIDAD AS BIGINT),
    CAST(:QUERY.ESTADOS AS VARCHAR[]),
    COALESCE(CAST(:QUERY.DIAS_GRACIA AS INT), 2),
    COALESCE(CAST(:QUERY.ORDEN_POR AS VARCHAR), ''fecha_inicio''),
    COALESCE(CAST(:QUERY.ORDEN_ASC AS BOOLEAN), TRUE),
    COALESCE(CAST(:QUERY.SIZE AS INT), 20),
    COALESCE(CAST(:QUERY.OFFSET AS INT), 0)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades/mias', 'SELECT', 'GET',
    '{"QUERY.SEARCH": "VARCHAR", "QUERY.ASIGNATURA": "BIGINT", "QUERY.GRUPO": "BIGINT", "QUERY.UNIDAD": "BIGINT", "QUERY.ESTADOS": "TEXT[]", "QUERY.DIAS_GRACIA": "INT", "QUERY.ORDEN_POR": "VARCHAR", "QUERY.ORDEN_ASC": "BOOLEAN"}'::jsonb,
    'V250 -- "Ver detalles" de una tarjeta del tablero: pagina de las actividades del DOCENTE autenticado (fn_actividad_listar_docente, V224/V250), con las mismas columnas, orden y paginacion que GET /planeador/actividades. El docente se resuelve del token y NO es un parametro (nadie lista las actividades de otro docente por esta ruta); si el usuario no es un docente activo devuelve 0 filas. ?estados= es el filtro que viene de la tarjeta pulsada: array del estado DERIVADO (fn_actividad_estado) en {PENDIENTE_POR_EVALUAR, EN_EVALUACION, FINALIZADA, VENCIDA, PROGRAMADA, SIN_PROGRAMAR}; sin el, lista todas las del docente. ?diasGracia= (default 2) define el umbral de VENCIDA, igual que en el tablero. Filtros opcionales ?search=, ?asignatura=, ?grupo=, ?unidad=; orden ?ordenPor= (whitelist fecha_inicio|fecha_cierre|fecha_creacion|titulo|ponderacion) / ?ordenAsc=. IMPORTANTE: mandar ?size= y ?offset= SIEMPRE explicitos (bug conocido del motor query-service con los system-bound de paginacion). total_count via COUNT(*) OVER(). Gate VER sobre PLANEADOR.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2.3 role_query — mismos roles que el resto de /planeador/% (V245-V249).
-- ---------------------------------------------------------------------------
INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR', 'CEVAL-DOCENTE')
 WHERE m.serviceid = 'eval-col'
   AND q.path_template IN ('/planeador/actividades/tablero', '/planeador/actividades/mias')
ON CONFLICT DO NOTHING;
