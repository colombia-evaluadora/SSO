-- fn_periodo_anos_lectivos_listar — años lectivos con al menos un periodo
-- académico activo, dentro del alcance del usuario (mismo criterio de scope
-- que fn_periodo_listar: global / establecimiento / sede). Alimenta el
-- combobox "Año lectivo" del filtro de periodos académicos con datos reales
-- en vez de un rango calculado en el front.
--
-- Recreada acá con numero de version nuevo (la V127 original de la rama
-- feature se elimino por colision con dev). Incluye los dos fixes que se le
-- hicieron en su momento:
--   1. `:CONTEXT.USER_ID::BIGINT` -- SSO manda todos los inputs como string,
--      sin el cast fn_get_academico_usuario_id(BIGINT) fallaba.
--   2. El alcance se precalcula en CTEs MATERIALIZED: el `OR` de la condicion
--      de scope le impedia al planner convertir los `IN (SELECT ...)` en un
--      semi-join, y Postgres re-ejecutaba fn_periodo_usuario_establecimientos/
--      _sedes (cada una un JOIN sobre TSEDE_USUARIO x TSEDE) por cada fila del
--      join principal.
DROP FUNCTION IF EXISTS academico_test.fn_periodo_anos_lectivos_listar(BIGINT);
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_anos_lectivos_listar(
    p_pk_usuario BIGINT DEFAULT NULL
)
RETURNS TABLE (id BIGINT, name VARCHAR)
LANGUAGE sql STABLE AS $$
    WITH es_global AS MATERIALIZED (
        SELECT academico_test.fn_periodo_usuario_global(p_pk_usuario) AS valor
    ),
    establecimientos AS MATERIALIZED (
        SELECT establecimiento_id
          FROM academico_test.fn_periodo_usuario_establecimientos(p_pk_usuario)
    ),
    sedes AS MATERIALIZED (
        SELECT sede_id FROM academico_test.fn_periodo_usuario_sedes(p_pk_usuario)
    )
    -- `TANO_LECTIVO` es único por (establecimiento, nombre): el mismo año
    -- "2026" existe como una fila distinta por cada establecimiento. El
    -- filtro solo necesita el nombre, así que se agrupa por NOMBRE (un id
    -- representativo por año, no uno por establecimiento).
    SELECT MIN(al.PK_ANO_LECTIVO), al.NOMBRE
      FROM academico_test.TANO_LECTIVO al
      JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.FK_TANO_LECTIVO = al.PK_ANO_LECTIVO
      JOIN academico_test.TSEDE s               ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE al.ACTIVE = TRUE
       AND pa.ACTIVE = TRUE
       AND ( (SELECT valor FROM es_global)
             OR s.FK_TESTABLECIMIENTO IN (SELECT establecimiento_id FROM establecimientos)
             OR pa.FK_TSEDE IN (SELECT sede_id FROM sedes) )
     GROUP BY al.NOMBRE
     ORDER BY al.NOMBRE DESC;
$$;