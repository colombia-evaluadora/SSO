---
paths:
  - "postgres/tests/**"
---

# Reglas — suites SQL (`postgres/tests/`)

Son la forma de verificar una función PL/pgSQL sin levantar el back: un `.sql`
que se corre contra el Postgres local y dice solo si algo se rompió. Existen
porque casi todos los bugs del repo se detectaron leyendo, no probando, y eso
se nota en cuántos llegaron a producción.

**La carpeta es local: está en `.gitignore` y no viaja.** Son batería de trabajo
—fixtures, semillas y teardown contra el contenedor—, no parte del esquema que
se despliega. Esta regla viaja igual, para que una suite escrita en cualquier
máquina tenga la misma forma; no cuentes con encontrar las de otro.

## Forma de un caso

Un fichero por tema, dentro de la carpeta del dominio (`planeador/`,
`asistencias/`, ...). La estructura que ya usan todos:

```sql
-- Qué verifica y de qué migración es. Se corre contra el Postgres local:
--   docker exec -i sso-postgres psql -U <user> -d <db> -X < este.sql
-- Cualquier fila con "<<< FALLA" es una regresion de <fn_...>.
SET search_path TO academico_test, public;

WITH casos(caso, ..., esperado) AS (VALUES
 ('descripcion en castellano del caso', ..., 'ESPERADO'),
 ...
)
SELECT caso, esperado, fn_bajo_prueba(...) AS obtenido,
       CASE WHEN fn_bajo_prueba(...) = esperado THEN 'ok' ELSE '<<< FALLA' END
  FROM casos;
```

- **El veredicto va en una columna, no en la cabeza de quien lee.** `ok` /
  `<<< FALLA`, para que un `grep FALLA` baste y la suite sirva en CI.
- **El nombre del caso dice la regla, no los datos:** `'rojo: cerro hace 3
  dias, sin calificar'`, no `'caso 7'`. Cuando falle dentro de seis meses, esa
  frase es todo el contexto que va a haber.
- **Fechas fijas, nunca `now()`.** Las funciones que dependen de hoy reciben la
  fecha como parámetro para que el caso siga valiendo mañana.
- **Sin efectos:** `SELECT` sobre `VALUES`. Si el caso necesita filas, se crean
  en una transacción con `ROLLBACK` al final.

## Cuándo se escribe una

- Al corregir un bug de una función: primero el caso que lo reproduce.
- Al escribir un núcleo `_interno` (ver `.claude/rules/migraciones.md`): es lo
  que hace la lógica verificable sin pasar por el gate de permisos.
- Al descubrir una trampa de PostgreSQL de las que no dan error
  (`GREATEST(NULL,1)=1`, `count(DISTINCT) OVER`, `ON CONFLICT` que no
  actualiza): el caso vale más que el comentario.

## Correrlas

```bash
for f in postgres/tests/<dominio>/*.sql; do
  echo "== $f"; docker exec -i sso-postgres psql -U <user> -d <db> -X < "$f"
done | grep -E "^==|FALLA"
```

Contra el contenedor `sso-postgres`, nunca contra un servidor: el hook
`no_prod.py` bloquea lo segundo.

## Un caso que falla a propósito

Si una suite documenta un hueco todavía sin arreglar, el caso se queda y se
marca en su nombre (`XFAIL: ...`) con la razón. Borrarlo pierde el hallazgo;
dejarlo mudo hace que la suite mienta.
