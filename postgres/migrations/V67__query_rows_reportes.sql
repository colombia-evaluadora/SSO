-- =============================================================================
-- V67 — endpoints de reporte: el mismo listado, sin paginar.
--
-- Una fila en public.query por dominio reportable. Cada una apunta a la MISMA
-- funcion que alimenta la pantalla, con los MISMOS binds de filtros, pero:
--
--   * llama a fn_X_listar (la que devuelve filas) en vez de
--     fn_X_listar_paginado (la que devuelve el sobre con total/page_count):
--     un reporte no necesita metadatos de paginacion, necesita filas.
--   * pasa NULL::INTEGER en p_page_index y p_page_size, que desde V66
--     significa "sin limite".
--   * no declara BODY.PAGEINDEX / BODY.PAGESIZE en param_types, asi que el
--     front no puede paginar un reporte ni por accidente.
--
-- Los filtros mantienen exactamente los mismos nombres de bind que el listado
-- (BODY.FILTERS.*). Un filtro que el front no manda llega NULL y la funcion ya
-- lo ignora: sin filtros, el reporte sale completo. Esa es la semantica pedida
-- y no hay que programarla, ya esta en las funciones.
--
-- microservice_id y param_types NO se escriben a mano: se derivan de la fila
-- de listado correspondiente (quitandole los dos binds de paginacion). Asi, si
-- manana alguien agrega un filtro al listado y actualiza param_types, no queda
-- una fila de reporte con un juego de tipos viejo — y si el listado se movio de
-- microservicio, el reporte lo sigue.
--
-- Autorizacion: se copian los role_query del listado. La regla queda "quien
-- puede ver el listado puede exportarlo", sin inventar un permiso nuevo ni
-- abrir el reporte a roles que no ven los datos.
--
-- Idempotente: los INSERT se saltan si el uuid ya existe, y los role_query
-- usan ON CONFLICT DO NOTHING.
-- =============================================================================

-- La secuencia de public.query quedo atras de los ids sembrados a mano por las
-- migraciones de endpoints, asi que el primer INSERT que confiara en el DEFAULT
-- moria con "duplicate key ... (id_query)". No es un problema de esta migracion
-- —cualquier alta de endpoint chocaba igual—, pero hay que resolverlo antes de
-- insertar. setval con is_called = true deja el proximo nextval en MAX+1.
SELECT setval(
    pg_get_serial_sequence('public.query', 'id_query'),
    (SELECT COALESCE(MAX(id_query), 1) FROM public.query),
    TRUE
);

-- Los tres reportes: uuid nuevo, ruta nueva, ruta del listado del que hereda
-- (microservice_id, param_types y roles), y el SQL sin paginar.
WITH nuevos (uuid, path_template, path_listado, detail, sql) AS (
    VALUES
    (
        'eval-col-funcionarios-reporte-001',
        '/establecimientos/funcionarios/reporte',
        '/establecimientos/funcionarios/query',
        'Funcionarios sin paginar para reporte. Mismos filtros y mismo gate que el listado (super-admin ve todos; rector/secretaria solo los de su EE).',
        $sql$SELECT * FROM academico_test.fn_usu_empleados_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FILTERS.SEARCH AS VARCHAR),
    CAST(:BODY.FILTERS.ROLES AS BIGINT[]),
    CAST(:BODY.FILTERS.WORKSCHEDULES AS BIGINT[]),
    CAST(:BODY.FILTERS.STATUSES AS VARCHAR[]),
    CAST(:BODY.FILTERS.CAMPUSID AS BIGINT),
    CAST(:BODY.SORTING.ID AS VARCHAR),
    CAST(:BODY.SORTING.DESC AS BOOLEAN),
    NULL::INTEGER, NULL::INTEGER
);$sql$
    ),
    (
        'eval-col-establecimientos-reporte-001',
        '/establecimientos/reporte',
        '/establecimientos/query',
        'Establecimientos sin paginar para reporte. Mismos filtros y mismo gate que el listado.',
        $sql$SELECT * FROM academico_test.fn_est_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FILTERS.SEARCH AS VARCHAR),
    CAST(:BODY.FILTERS.DEPARTMENT AS BIGINT[]),
    CAST(:BODY.FILTERS.MUNICIPALITY AS BIGINT[]),
    CAST(:BODY.FILTERS.STATUS AS BIGINT[]),
    CAST(:BODY.SORTING.ID AS VARCHAR),
    CAST(:BODY.SORTING.DESC AS BOOLEAN),
    NULL::INTEGER, NULL::INTEGER
);$sql$
    ),
    (
        'eval-col-sedes-reporte-001',
        '/establecimientos/sedes/reporte',
        '/establecimientos/sedes/query',
        'Sedes sin paginar para reporte. Mismos filtros y mismo gate que el listado.',
        $sql$SELECT * FROM academico_test.fn_sed_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FILTERS.SEARCH AS VARCHAR),
    CAST(:BODY.FILTERS.ZONES AS BIGINT[]),
    CAST(:BODY.SORTING.ID AS VARCHAR),
    CAST(:BODY.SORTING.DESC AS BOOLEAN),
    NULL::INTEGER, NULL::INTEGER
);$sql$
    )
)
INSERT INTO public.query (
    uuid, query, type, execution_mode, http_method, path_template,
    public_end, captcha, microservice_id, param_types, detail
)
SELECT
    n.uuid,
    n.sql,
    listado.type,
    'SELECT',
    'POST',
    n.path_template,
    FALSE,
    FALSE,
    listado.microservice_id,
    -- Mismos tipos de bind que el listado, menos los dos de paginacion.
    listado.param_types - 'BODY.PAGEINDEX' - 'BODY.PAGESIZE',
    n.detail
  FROM nuevos n
  JOIN public.query listado
    ON listado.path_template = n.path_listado
   AND listado.http_method   = 'POST'
 WHERE NOT EXISTS (
     SELECT 1 FROM public.query existente WHERE existente.uuid = n.uuid
 );

-- "Quien ve el listado puede exportarlo": se copian los roles tal cual.
INSERT INTO public.role_query (query_id, role_id)
SELECT reporte.id_query, rq.role_id
  FROM (VALUES
        ('eval-col-funcionarios-reporte-001',     '/establecimientos/funcionarios/query'),
        ('eval-col-establecimientos-reporte-001', '/establecimientos/query'),
        ('eval-col-sedes-reporte-001',            '/establecimientos/sedes/query')
       ) AS m (uuid_reporte, path_listado)
  JOIN public.query reporte ON reporte.uuid = m.uuid_reporte
  JOIN public.query listado ON listado.path_template = m.path_listado
                           AND listado.http_method   = 'POST'
  JOIN public.role_query rq ON rq.query_id = listado.id_query
ON CONFLICT (query_id, role_id) DO NOTHING;
