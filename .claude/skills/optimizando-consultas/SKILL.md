---
name: optimizando-consultas
description: >-
  Escribe o revisa una consulta, un listado o un indice del esquema de SSO
  partiendo de lo que la tabla ya tiene: indices vivos y su definicion real
  (casi todo UNIQUE es parcial WHERE active = true), FKs sin indice, quien la
  usa. Plantilla del nucleo de listado (STABLE, filtros opcionales y plan
  cacheado, paginacion OFFSET/keyset, total con count OVER, DISTINCT ON,
  ROW_NUMBER/RANK, FILTER), agregados por fila, busqueda ILIKE con trigram y
  EXPLAIN contra el Postgres local. Usar antes de crear un indice, al escribir
  un fn_*_listar / _listar_interno o un endpoint de consulta, o cuando un
  listado o un endpoint responde lento.
---

# Optimizando consultas

El planner no adivina: usa los indices que existen y las estadisticas que
tiene. Antes de escribir un indice o un `WHERE`, se mira la tabla.

## 1. Que tiene la tabla hoy

```bash
python scripts/migration-analysis tabla tactividad_nota          # indices, constraints, triggers, columnas
python scripts/migration-analysis tabla tactividad_nota --usos   # funciones y filas de public.query que la leen
```

Da cada indice vivo con su definicion real y avisa de las columnas `fk_*`
anadidas despues sin indice que las encabece. Lo que hay que saber del esquema:

- **Los UNIQUE son parciales.** V65/V71 convirtieron las 84 constraints UNIQUE
  de `academico_test` en `CREATE UNIQUE INDEX ... WHERE active = true`. Una
  consulta que no filtra por `active = true` no puede usarlos, y un
  `ON CONFLICT (cols)` necesita repetir el mismo `WHERE` del indice.
- **Cada tabla tiene `idx_<tabla>_active (pk) WHERE ACTIVE = true`** desde V22:
  el filtro de borrado logico ya esta indexado; no se duplica.
- **Las FKs de CREATE TABLE (V22) suelen tener su `idx_<tabla>_N`.** Las
  anadidas despues con `ALTER TABLE ADD COLUMN fk_*` muchas veces no: `tabla`
  las marca.
- **Catalogos por texto** (`TLISTA_VALOR.VALOR`): el pk cambia entre bases, asi
  que el `JOIN` va por `fk_tlista + valor`, no por un pk literal.

## 2. Patrones de este repo

| Caso | Hacer | Precedente |
|---|---|---|
| Agregado por fila en un listado | subconsulta correlacionada en el `SELECT` o `LEFT JOIN LATERAL ... LIMIT 1`: solo se evalua para las filas que sobreviven al `LIMIT` | V112: 11,5 s → 83 ms |
| CTE con `GROUP BY` que no menciona ningun parametro de filtro | es la señal de que se materializa entero: mover el filtro dentro o pasar a LATERAL | V112 |
| Busqueda libre sobre varias columnas | **una** expresion (`lower(a || ' ' || b)`) con indice GIN `gin_trgm_ops` sobre **esa misma** expresion; el planner solo usa el indice si la consulta la repite exacta | pg_trgm desde V112 |
| Alcance en un listado | la variante booleana (`fn_*_puede_ver`, `fn_planeador_alcanza`) en el `WHERE`, nunca reimplementar permisos en SQL | V277 (ver `definiendo-permisos`) |
| Listado "sin paginar" para exportar | `p_page_size NULL`; `GREATEST(NULL, 1)` vale 1, no NULL | V401 |
| Recorrer dependientes antes de borrar | indice que encabece la FK del hijo; si no, cada borrado recorre la tabla hija | V354 |

## 3. Plantilla de un `_listar_interno`

El nucleo de lectura recibe el alcance ya resuelto por el wrapper y aplica esto,
en este orden:

1. **`STABLE`**, nunca el `VOLATILE` por defecto: una funcion `VOLATILE` no
   puede ir en la condicion de un index scan y el planner la evalua por fila.
   `IMMUTABLE` solo si no lee tablas (la cachea como constante).
2. **Filtros opcionales y plan cacheado.** `(p_x IS NULL OR col = p_x)` es el
   patron del repo y esta bien con plan *custom* (el planner pliega el
   `NULL IS NULL` y el filtro activo usa su indice). PL/pgSQL cachea el plan y,
   tras unas llamadas, puede quedarse con el *generico*, que no puede elegir
   indice por filtro: si las primeras llamadas venian sin filtros, las
   selectivas siguen con el Seq Scan. Con 3+ filtros opcionales:
   `SET plan_cache_mode = force_custom_plan` en el `CREATE FUNCTION` (linter:
   `LISTADO-PLAN-GENERICO`). Si los filtros cambian la forma de la consulta
   (joins que solo hacen falta con un filtro), `RETURN QUERY EXECUTE format(...)
   USING ...` arma solo el `WHERE` que aplica (ya hay 12 en el repo).
3. **Alcance en el `WHERE`** con la booleana (`fn_*_puede_ver`,
   `fn_planeador_alcanza`) o con los arrays que resolvio el wrapper
   (`= ANY(p_sedes)`), nunca reimplementando permisos.
4. **Filtrar antes de agregar** (V112). El agregado por fila va en subconsulta
   correlacionada o `LATERAL ... LIMIT 1`, que solo corre para la pagina.
5. **Paginacion.** `OFFSET` sirve para la pantalla (paginas cortas y numeradas),
   pero lee y descarta todo lo anterior: una exportacion o un recorrido completo
   va sin paginar (`p_page_size NULL`, V401) o por keyset
   (`WHERE (orden, pk) > (p_ultimo_orden, p_ultimo_pk) ORDER BY orden, pk`) con
   un indice que cubra `(orden, pk)`. El `ORDER BY` siempre termina en el pk, o
   dos paginas repiten o pierden filas.
6. **Total.** `count(*) OVER ()` cuenta el conjunto filtrado **entero** antes
   del `LIMIT`: cada pagina paga el total. Solo si la pantalla muestra el total;
   si solo necesita "hay mas", pide `LIMIT n + 1`.
7. **Ventanas y agregados de una pasada:**
   - ultimo/primero por grupo: `DISTINCT ON (grupo) ... ORDER BY grupo, fecha DESC`
     o `ROW_NUMBER() OVER (PARTITION BY ...)`, no una subconsulta `MAX` por fila;
   - varios conteos condicionales: `count(*) FILTER (WHERE estado = 'X')` en un
     solo `GROUP BY`, no un `SELECT` por estado;
   - puestos y rankings: `RANK() OVER (... ORDER BY nota DESC NULLS LAST)`
     (sin `NULLS LAST`, los NULL quedan primeros: informes V330-V347);
   - `count(DISTINCT x) OVER (...)` no existe en PostgreSQL: se agrega antes.
8. **Columnas explicitas**, nunca `SELECT *` dentro del nucleo: un `RETURNS
   TABLE` con `SELECT *` se rompe en cuanto la tabla gana una columna.

Fuentes: [volatilidad](https://www.postgresql.org/docs/current/xfunc-volatility.html),
[plan_cache_mode](https://postgresqlco.nf/en/doc/param/plan_cache_mode/),
[OFFSET vs keyset](https://blog.jooq.org/faster-sql-pagination-with-keysets-continued/).

## 4. Indice nuevo: reglas

- **Buscar antes** con `tabla`: un indice cuyas primeras columnas ya cubren el
  filtro sirve; dos indices con el mismo prefijo solo pagan escritura.
- **Parcial si el filtro siempre esta**: `WHERE active = true` reduce tamano y
  escritura, y es como estan hechos los demas.
- **Orden de columnas**: primero igualdad, luego rango u `ORDER BY`.
- **Nunca `CONCURRENTLY` en una migracion**: Flyway corre cada migracion en una
  transaccion y `CREATE INDEX CONCURRENTLY` falla ahi ("cannot run inside a
  transaction block"). Las guias genericas de Flyway lo sugieren; aqui
  no aplica.
- **Idempotente**: `CREATE INDEX IF NOT EXISTS`, nombre `idx_<tabla>_<que>`.
- **Va en la migracion de la funcionalidad** que lo necesita (capa de
  validaciones o la de la tabla), no en una suelta.

## 5. Medir, no suponer

Solo si el usuario pide probar, y solo contra el Postgres local
(`sso-postgres`; ver `probando-en-contenedores-locales`):

```sql
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM academico_test.fn_actividad_listar(...);
```

- `Seq Scan` sobre una tabla grande con filtro selectivo → falta indice o el
  `WHERE` no casa con el indice (funcion sobre la columna, falta `active = true`).
- `rows=` estimado muy lejos del real → `ANALYZE <tabla>` antes de concluir.
- Una funcion `plpgsql` esconde su plan: probar su `SELECT` interior suelto, con
  los parametros sustituidos.

La base local tiene que tener datos para que el plan signifique algo; con
tablas vacias todo es `Seq Scan` y no dice nada.
