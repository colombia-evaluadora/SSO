-- =============================================================================
-- V131 — las filas `query` de ClickHouse declaran su tipo de ClickHouse en vez
--        de VARCHAR, para que el rewriter de Postgres no les meta un cast.
--
-- SINTOMA
--   POST /api/audit-ch/audit-tables/query -> 500. En el log del contenedor:
--
--     Code: 70. DB::Exception: Cannot convert NULL to a non-nullable type ...
--       WHERE coalesce(CAST(NULL, 'varchar'), '') = '' ...   (CANNOT_CONVERT_TYPE)
--
--   Se dispara en cuanto un filtro llega vacio, que es el caso normal: abrir la
--   pantalla de auditoria sin filtrar nada.
--
-- CAUSA
--   `SqlRewriter.rewrite` (common/.../query/SqlRewriter.java) reescribe cada
--   placeholder con tipo declarado como
--
--     cast(:BODY.FILTERS.NAME as varchar)
--
--   Ese rewrite es deliberadamente de PostgreSQL —existe para que el cast se
--   aplique donde `search_path` resuelve los DOMAIN types de academico_test—
--   pero se aplica SIN mirar el dialecto. En ClickHouse `varchar` es alias de
--   String, que NO es nullable: castear NULL ahi es un error duro, no un NULL.
--   En Postgres el mismo SQL funciona porque todo tipo admite NULL.
--
-- POR QUE ESTE ARREGLO Y NO "QUITAR LOS TIPOS"
--   Vaciar `param_types` NO sirve: `QueryService` exige que TODO placeholder
--   controlado por el cliente (namespace PARAM./BODY.) tenga tipo declarado, y
--   sin el responde 400 "tiene placeholders sin tipo declarado". Ademas es el
--   tipo declarado lo que hace que un filtro OMITIDO se bindee como NULL en vez
--   de dejar el placeholder sin valor (ver ParamTypes.parseDeclaration).
--
--   La pieza que se puede mover sin tocar codigo es el NOMBRE del tipo: el
--   rewriter solo inserta el cast si el tipo esta en `ParamTypes.PG_CAST_NAME`,
--   y si no esta deja el placeholder intacto. `Nullable(String)` —el nombre
--   real del tipo en ClickHouse— no esta en ese mapa, asi que:
--     * el guard de "placeholder sin tipo" queda satisfecho (mira la clave),
--     * el rewriter no mete cast,
--     * el binder pasa el valor (o NULL) como parametro JDBC normal,
--     * y la fila queda documentando el tipo que de verdad tiene su columna.
--
--   EFECTO COLATERAL A SABER: el formulario de sso-admin valida contra el set
--   curado de tipos PG (`CURATED_PG_TYPES` en el front), asi que si alguien
--   abre una de estas filas en la UI, el selector de tipo va a marcar
--   `Nullable(String)` como desconocido. Es cosmetico —el runtime no valida
--   contra CURATED— pero conviene saberlo antes de editar estas filas a mano.
--
--   El arreglo estructural es que `SqlRewriter` mire el dialecto (ya disponible
--   como QUERY_DS_DIALECT) y no reescriba cuando no es PostgreSQL. Toca
--   `common`, obliga a reconstruir la imagen de query-service y a recrear TODAS
--   las instancias, no solo la de auditoria; esta migracion desbloquea la
--   pantalla sin ese radio de impacto.
--
-- ALCANCE
--   Solo filas cuyo microservicio tiene dialect = 'clickhouse'. Las de Postgres
--   conservan sus tipos: alli el cast es el comportamiento querido.
--
-- Idempotente: reemplaza cada valor 'VARCHAR' por 'Nullable(String)' clave a
-- clave, asi que correrla dos veces deja el mismo JSON.
-- =============================================================================

UPDATE public.query q
   SET param_types = (
           SELECT jsonb_object_agg(
                      e.clave,
                      CASE WHEN upper(e.valor) = 'VARCHAR' THEN 'Nullable(String)'
                           ELSE e.valor END)
             FROM jsonb_each_text(q.param_types) AS e(clave, valor)
       )
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND lower(m.dialect) = 'clickhouse'
   AND q.param_types IS NOT NULL
   AND q.param_types <> '{}'::JSONB
   AND EXISTS (
       SELECT 1 FROM jsonb_each_text(q.param_types) AS e(clave, valor)
        WHERE upper(e.valor) = 'VARCHAR'
   );
