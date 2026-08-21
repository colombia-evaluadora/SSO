-- =============================================================================
-- V69 — filtro opcional por ids en los reportes ("exportar seleccionados").
--
-- El front tiene dos botones de exportacion por listado:
--   * exportar TODO lo que pasa el filtro  -> ya resuelto en V67
--   * exportar SOLO las filas tildadas     -> esto
--
-- El segundo manda { ids: number[], format }. Se resuelve como un filtro mas,
-- no como un endpoint aparte: la misma fila query, la misma funcion PL/pgSQL,
-- el mismo gate de autorizacion. "Exportar seleccionados" pasa a ser
-- "exportar con el filtro ids", y el reporting-service no se entera — para el
-- sigue siendo un filtro que viaja en el body.
--
-- Por que un WHERE por fuera y no un parametro nuevo en fn_X_listar:
--
--   * Agregar un parametro NO es un CREATE OR REPLACE: cambia la firma, o sea
--     que crea una SOBRECARGA. Con dos funciones del mismo nombre —una de 10
--     parametros y otra de 11 con default— las llamadas de 10 argumentos
--     quedan ambiguas y PG las rechaza. Habria que DROP + CREATE de las tres
--     funciones y de los tres wrappers _paginado que las llaman.
--   * El WHERE de afuera no toca ninguna funcion: solo cambia el texto de
--     estas tres filas de public.query.
--
-- El costo es real y conviene tenerlo presente: la funcion materializa todas
-- las filas que pasan los demas filtros y recien despues se recortan por id.
-- Para "exportar 5 seleccionados" eso significa calcular el listado completo.
-- Es aceptable porque el conjunto ya esta acotado por los permisos del usuario
-- y porque exportar no es una operacion interactiva; si algun dia pesa, el
-- arreglo es el parametro en la funcion, con el DROP + CREATE que implica.
--
-- Semantica del filtro:
--   * ids ausente (NULL)  -> no filtra; el reporte sale como hasta ahora
--   * ids = '{}'          -> cero filas (nadie tildado = nada que exportar)
--   * ids = '{1,2,3}'     -> solo esas, y solo si el usuario podia verlas:
--                            el gate de la funcion ya corrio antes del WHERE,
--                            asi que mandar un id ajeno no lo revela.
--
-- El bind :BODY.FILTERS.IDS aparece DOS VECES en cada SQL. Es correcto: el
-- binder arma un MapSqlParameterSource y Spring expande cada aparicion del
-- nombre con el mismo valor.
--
-- Idempotente: son UPDATE sobre filas identificadas por uuid.
-- =============================================================================

-- ─── Funcionarios ───
UPDATE public.query
   SET query = $sql$SELECT * FROM academico_test.fn_usu_empleados_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FILTERS.SEARCH AS VARCHAR),
    CAST(:BODY.FILTERS.ROLES AS BIGINT[]),
    CAST(:BODY.FILTERS.WORKSCHEDULES AS BIGINT[]),
    CAST(:BODY.FILTERS.STATUSES AS VARCHAR[]),
    CAST(:BODY.FILTERS.CAMPUSID AS BIGINT),
    CAST(:BODY.SORTING.ID AS VARCHAR),
    CAST(:BODY.SORTING.DESC AS BOOLEAN),
    NULL::INTEGER, NULL::INTEGER
) t
WHERE CAST(:BODY.FILTERS.IDS AS BIGINT[]) IS NULL
   OR t.pk_empleado = ANY(CAST(:BODY.FILTERS.IDS AS BIGINT[]));$sql$,
       param_types = param_types || '{"BODY.FILTERS.IDS": "BIGINT[]"}'::JSONB
 WHERE uuid = 'eval-col-funcionarios-reporte-001';

-- ─── Establecimientos ───
UPDATE public.query
   SET query = $sql$SELECT * FROM academico_test.fn_est_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FILTERS.SEARCH AS VARCHAR),
    CAST(:BODY.FILTERS.DEPARTMENT AS BIGINT[]),
    CAST(:BODY.FILTERS.MUNICIPALITY AS BIGINT[]),
    CAST(:BODY.FILTERS.STATUS AS BIGINT[]),
    CAST(:BODY.SORTING.ID AS VARCHAR),
    CAST(:BODY.SORTING.DESC AS BOOLEAN),
    NULL::INTEGER, NULL::INTEGER
) t
WHERE CAST(:BODY.FILTERS.IDS AS BIGINT[]) IS NULL
   OR t.pk_establecimiento = ANY(CAST(:BODY.FILTERS.IDS AS BIGINT[]));$sql$,
       param_types = param_types || '{"BODY.FILTERS.IDS": "BIGINT[]"}'::JSONB
 WHERE uuid = 'eval-col-establecimientos-reporte-001';

-- ─── Sedes ───
UPDATE public.query
   SET query = $sql$SELECT * FROM academico_test.fn_sed_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FILTERS.SEARCH AS VARCHAR),
    CAST(:BODY.FILTERS.ZONES AS BIGINT[]),
    CAST(:BODY.SORTING.ID AS VARCHAR),
    CAST(:BODY.SORTING.DESC AS BOOLEAN),
    NULL::INTEGER, NULL::INTEGER
) t
WHERE CAST(:BODY.FILTERS.IDS AS BIGINT[]) IS NULL
   OR t.pk_sede = ANY(CAST(:BODY.FILTERS.IDS AS BIGINT[]));$sql$,
       param_types = param_types || '{"BODY.FILTERS.IDS": "BIGINT[]"}'::JSONB
 WHERE uuid = 'eval-col-sedes-reporte-001';
