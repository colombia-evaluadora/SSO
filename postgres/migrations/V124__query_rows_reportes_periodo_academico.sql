-- =============================================================================
-- V124 — endpoints de reporte para periodos academicos y periodos de
--        evaluacion.
--
-- Mismo patron que V67 (establecimientos, sedes, funcionarios): una fila por
-- dominio que llama a la MISMA funcion del listado, sin paginar y con los
-- mismos filtros.
--
-- Diferencia con V67, y por eso estas dos no necesitan tocar ninguna funcion:
-- fn_periodo_listar y fn_periodo_eval_listar YA soportan "sin limite". Su SQL
-- dice
--
--     LIMIT NULLIF($n, 0)
--
-- asi que un page_size NULL (o 0) deja el LIMIT en NULL, que en PostgreSQL es
-- "sin clausula". No hizo falta el equivalente de V66 — el problema del tope
-- clavado era de fn_est_listar / fn_sed_listar / fn_usu_empleados_listar, no
-- de estas.
--
-- Los binds van bajo BODY.FILTERS.* aunque el listado los reciba planos
-- (BODY.FK_SEDE). Es para que TODOS los reportes compartan el mismo contrato
-- —POST /reportes/{clave} con { format, filters, sorting }— y el
-- reporting-service no tenga que saber la forma del cuerpo de cada dominio.
-- El front manda el mismo objeto que ya arma para el listado, solo que
-- anidado: la conversion sigue siendo una sola, compartida.
--
-- BODY.FILTERS.IDS: el filtro de "exportar seleccionados", igual que en V69.
-- El recorte va en un WHERE por fuera, DESPUES de que la funcion aplico su
-- propio gate de autorizacion, asi que mandar el id de una fila que el usuario
-- no puede ver no la revela.
--
-- Areas y asignaturas queda fuera a proposito: esa pantalla COMPONE dos
-- llamadas (POST /areas/query + el GET de asignaturas), asi que su reporte no
-- sale de una sola fila query — necesita un SQL propio que haga ese join del
-- lado del servidor, que es una decision de contenido, no de plomeria.
--
-- Idempotente: no inserta si el uuid ya existe; los role_query usan
-- ON CONFLICT DO NOTHING.
-- =============================================================================

SELECT setval(
    pg_get_serial_sequence('public.query', 'id_query'),
    (SELECT COALESCE(MAX(id_query), 1) FROM public.query),
    TRUE
);

WITH nuevos (uuid, path_template, path_listado, detail, sql) AS (
    VALUES
    (
        'eval-col-periodos-academicos-reporte-001',
        '/periodos-academicos/reporte',
        '/periodos-academicos/query',
        'Periodos academicos sin paginar para reporte. Mismos filtros y mismo gate que el listado.',
        $sql$SELECT * FROM academico_test.fn_periodo_listar(
    CAST(:BODY.FILTERS.FK_SEDE AS BIGINT),
    CAST(:BODY.FILTERS.NOMBRE_SEDE AS TEXT),
    CAST(:BODY.FILTERS.ANO AS TEXT),
    CAST(:BODY.FILTERS.FK_ESTADO AS BIGINT),
    CAST(:BODY.FILTERS.FECHA_DESDE AS DATE),
    CAST(:BODY.FILTERS.FECHA_HASTA AS DATE),
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    NULL::INTEGER, NULL::INTEGER,
    CAST(:BODY.SORTING.ID AS TEXT),
    CAST(:BODY.SORTING.DESC AS TEXT)
) t
WHERE CAST(:BODY.FILTERS.IDS AS BIGINT[]) IS NULL
   OR t.id = ANY(CAST(:BODY.FILTERS.IDS AS BIGINT[]));$sql$
    ),
    (
        'eval-col-periodos-evaluacion-reporte-001',
        '/periodo-evaluacion/reporte',
        '/periodo-evaluacion/query',
        'Periodos de evaluacion sin paginar para reporte. Mismos filtros y mismo gate que el listado.',
        $sql$SELECT * FROM academico_test.fn_periodo_eval_listar(
    CAST(:BODY.FILTERS.FK_PERIODO AS BIGINT),
    CAST(:BODY.FILTERS.FILTRO AS TEXT),
    NULL::INTEGER, NULL::INTEGER,
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.SORTING.ID AS TEXT),
    CAST(:BODY.SORTING.DESC AS TEXT)
) t
WHERE CAST(:BODY.FILTERS.IDS AS BIGINT[]) IS NULL
   OR t.id = ANY(CAST(:BODY.FILTERS.IDS AS BIGINT[]));$sql$
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
    -- Los tipos se derivan del listado renombrando cada bind a BODY.FILTERS.*,
    -- se quitan los de paginacion y se suman SORTING e IDS. Derivarlos en vez
    -- de escribirlos evita que el reporte quede con un juego de tipos viejo si
    -- manana alguien agrega un filtro al listado.
    (
        SELECT COALESCE(jsonb_object_agg(
                   'BODY.FILTERS.' || substring(clave FROM 6), valor), '{}'::JSONB)
          FROM jsonb_each_text(listado.param_types) AS e(clave, valor)
         WHERE clave LIKE 'BODY.%'
           AND clave NOT IN ('BODY.PAGEINDEX', 'BODY.PAGESIZE',
                             'BODY.PAGE_INDEX', 'BODY.PAGE_SIZE',
                             'BODY.SORT_BY', 'BODY.SORT_DIR')
    )
    || '{"BODY.SORTING.ID": "TEXT", "BODY.SORTING.DESC": "TEXT", "BODY.FILTERS.IDS": "BIGINT[]"}'::JSONB,
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
        ('eval-col-periodos-academicos-reporte-001', '/periodos-academicos/query'),
        ('eval-col-periodos-evaluacion-reporte-001', '/periodo-evaluacion/query')
       ) AS m (uuid_reporte, path_listado)
  JOIN public.query reporte ON reporte.uuid = m.uuid_reporte
  JOIN public.query listado ON listado.path_template = m.path_listado
                           AND listado.http_method   = 'POST'
  JOIN public.role_query rq ON rq.query_id = listado.id_query
ON CONFLICT (query_id, role_id) DO NOTHING;
