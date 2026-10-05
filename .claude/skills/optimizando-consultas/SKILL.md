---
name: optimizando-consultas
description: >-
  Escribe o revisa una consulta, un listado o un indice del esquema de SSO
  partiendo de lo que la tabla ya tiene: indices vivos y su definicion real
  (casi todo UNIQUE es parcial WHERE active = true), FKs sin indice, quien la
  usa. Patrones de este repo para listados paginados, agregados por fila,
  busqueda ILIKE con trigram y EXPLAIN contra el Postgres local. Usar antes de
  crear un indice, al escribir un fn_*_listar o un endpoint de consulta, o
  cuando un listado o un endpoint responde lento.
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

## 3. Indice nuevo: reglas

- **Buscar antes** con `tabla`: un indice cuyas primeras columnas ya cubren el
  filtro sirve; dos indices con el mismo prefijo solo pagan escritura.
- **Parcial si el filtro siempre esta**: `WHERE active = true` reduce tamano y
  escritura, y es como estan hechos los demas.
- **Orden de columnas**: primero igualdad, luego rango u `ORDER BY`.
- **Nunca `CONCURRENTLY` en una migracion**: Flyway corre cada migracion en una
  transaccion y `CREATE INDEX CONCURRENTLY` falla ahi ("cannot run inside a
  transaction block"). La skill generica `flyway-migrations` lo sugiere; aqui
  no aplica.
- **Idempotente**: `CREATE INDEX IF NOT EXISTS`, nombre `idx_<tabla>_<que>`.
- **Va en la migracion de la funcionalidad** que lo necesita (capa de
  validaciones o la de la tabla), no en una suelta.

## 4. Medir, no suponer

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
