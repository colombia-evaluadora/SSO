# Análisis de migraciones

Genera un informe HTML interactivo sobre `postgres/migrations/`: qué migraciones
quedaron obsoletas, qué objeto reescribió a cuál, qué firmas de función
cambiaron y quién se quedó llamándolas con la firma vieja, y cuál es el próximo
número de versión realmente libre.

```bash
python scripts/migration-analysis/analyze_migrations.py            # -> docs/auditoria/migraciones-analisis.html
python scripts/migration-analysis/analyze_migrations.py --open     # y lo abre
python scripts/migration-analysis/analyze_migrations.py --from 355 --to 394
python scripts/migration-analysis/analyze_migrations.py --no-git --json modelo.json
```

Solo stdlib (Python 3.10+). `git` es opcional: sin él no se puede calcular el
techo de versión de **todas** las ramas de `origin` y el informe lo dice.

## Qué considera "obsoleta"

Cada sentencia se atribuye a un objeto (`function:pigse.fn_sed_listar`,
`query:uuid:pigse-sedes-crear`, `table:pigse.tsede`, `role:PIGSE-RECTOR`…) y se
ordenan por versión. Tipos reconocidos: funciones, filas de `public.query`,
tablas, columnas, constraints con nombre, índices, triggers, vistas,
dominios/tipos, esquemas, secuencias, extensiones, publicaciones CDC, roles,
rutas del menú y endpoints; los bindings de permisos, los seeds de datos, el
DDL dinámico, los objetos `TEMP` de una migración y los `UPDATE` masivos de
`public.query` por patrón se cuentan pero no se encadenan. La pestaña **Tipos de cambio** del informe muestra esa cobertura
con números. Sobre cada objeto conviven dos cadenas:

| | qué la mata |
|---|---|
| **identidad** — el objeto existe (`INSERT`, `CREATE TABLE`, `CREATE INDEX`) | un `DELETE`/`DROP` posterior, o un alta nueva del mismo objeto |
| **cuerpo** — lo que el objeto dice hoy (`CREATE OR REPLACE FUNCTION`, `UPDATE … SET query =`) | cualquier reescritura completa posterior |

Un **parche** (`replace()`, `regexp_replace`, `ALTER TABLE`, cambiar solo
`param_types`/`icon`/`menuorder`) deriva del estado anterior: no lo mata, lo
modifica, y muere junto con él.

Veredictos: `obsoleta` (ninguna escritura sobrevive), `residual` (una sola viva
contra tres o más muertas), `parcial`, `viva`, `solo-binds` (únicamente ata
permisos o siembra datos — eso no se reescribe) y `sin-cambios` (documental).

Una migración obsoleta **no se puede borrar** del repo: rompería el checksum de
Flyway en los servidores que ya la aplicaron. Lo que da el informe es saber qué
texto ya no describe el estado actual al depurar, y qué colapsaría en un squash.

## Los tres ficheros

| Fichero | Qué hace |
|---|---|
| `sqlscan.py` | Parte el SQL en sentencias respetando literales, `$$ … $$` y comentarios. Todo lo demás depende de esto: un grep a secas matchea dentro de cuerpos de función y de comentarios. |
| `analyze_migrations.py` | Extractores, grafo de reescritura, firmas, llamadores, slots, dependencias. |
| `render.py` | Emite el HTML (CSS y JS propios, datos embebidos, sin CDN). |

## Por elemento

La pestaña **Objetos** responde, para cada elemento, qué migraciones lo
reescribieron (con línea y quién mató a cada escritura) y quién lo usa: cada
llamada a función o referencia a tabla/vista se atribuye al elemento que la
contiene (la función que se define, la fila de `public.query` que se inserta)
y se separa entre "sus mismas migraciones" y "otras". Una sentencia suelta
(un `UPDATE` sin definir nada) se atribuye a la migración. El JSON lo expone
como `uses`: `{from, to, v, line, file, kind: call|ref|java}`.

## Precisión

El informe muestra su propia cobertura: cuántas sentencias no logró clasificar.
Nada se descarta en silencio. Puntos donde es deliberadamente conservador:

- **DDL dinámico** (`EXECUTE format('CREATE TRIGGER … ON %I.%I')`): no se puede
  saber estáticamente sobre qué tablas actúa, así que cuenta como escritura
  real y persistente en vez de encadenarse con otras.
- **Sobrecargas**: si una migración define el mismo nombre con distinta aridad,
  no se chequea el número de argumentos de sus llamadas.
- **Llamadas sin esquema** (`fn_x(...)` con `search_path`): se resuelven por
  nombre cuando existe en un solo esquema; si está en `academico_test` y en
  `pigse`, cuenta como uso pero no se verifica su firma.
- **Binds** (`role_query`, `role_route`…): se cuentan pero no se encadenan — no
  hay forma fiable de identificar la fila concreta desde el SQL.

Las "llamadas fuera de la firma viva" son **candidatas**: el conteo de
argumentos es textual. Cada fila trae `archivo:línea` para verificar en un clic.
