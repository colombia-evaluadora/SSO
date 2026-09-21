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

## Cuántas líneas sobran

La pestaña **Líneas** reparte las 127k líneas del corpus en *sin efecto* /
*vigentes* / *sin encadenar*, con el desglose por archivo. Cada sentencia
reclama su tramo desde el `;` anterior (así que arrastra su comentario de
cabecera, que es lo que de verdad se borraría) y el tramo sólo cuenta como
sin efecto si **ninguna** de sus escrituras sigue viva: en un bloque `DO`
que toca varios objetos, basta uno vigente para conservarlo.

Ese número **no es una lista de borrado**: borrar una migración ya aplicada
rompe el checksum de Flyway en el servidor. Es lo que colapsaría en un squash
y lo que no hace falta leer al depurar.

## Presupuesto de comentarios

La pestaña **Líneas y comentarios** mide también el presupuesto de CLAUDE.md
(cabecera de ≤12 líneas, ≤20% de comentario) con el **mismo criterio que
`scripts/migration-lint.py`**: líneas que empiezan con `--`, y fuera de
presupuesto sólo si pasa el 20% *y* tiene más de 20 líneas de comentario. Así
el informe y el linter no pueden contradecirse. La escala es de tres niveles
—dentro / 20-40% / >40%— porque con un solo umbral quedaban 249 de 384
archivos en rojo y el color dejaba de avisar.

## Autoría

La pestaña **Autoría** dice de quién es cada migración —quien hizo el **primer**
commit que la creó— y quién la tocó después, en orden, con `+`/`−` líneas por
commit. Distingue tres aportes que no conviene mezclar: **crear**, **editar la
de otro** (lo que obliga a `flyway repair` donde ya se había aplicado) y
**volver sobre la propia**. Al elegir una persona se ven sus aportes: qué creó,
en qué estado quedó (veredictos), qué objetos, su % de comentario, su actividad
por mes y la lista de lo que editó de otros. El selector de la pestaña
Migraciones filtra por persona.

Las identidades se unifican con `.mailmap`, en la raíz del repo: las mismas
cinco personas firmaron con ocho pares nombre/correo distintos, y sin eso
«Jorge Sanchez» y «Jorge Luis Sanchez» cuentan como dos. Ese fichero también
arregla `git shortlog` y `git blame`.

Límite del dato: sale de `git log` sobre la rama actual. Una rama integrada con
*squash* deja un solo commit, así que quien lo firmó figura como autor aunque el
trabajo fuese de otro, y un rebase reescribe las fechas.

## Cómo se navega

- Cada migración trae un **mapa del archivo**: una franja por tramo de líneas,
  coloreada por estado (vigente / sin efecto / comentario / sin encadenar). Es
  lo que deja ver de un golpe que media migración ya no hace nada.
- Barras de presupuesto (líneas, sin efecto, comentarios, cabecera) y los
  objetos escritos **agrupados por tipo**, con el recuento vivo/muerto.
- Dependencias en los dos sentidos, con el número de objetos de cada arista:
  *usa objetos creados en* (si esa migración cambia una firma, esta hay que
  revisarla) y *sus objetos los usa* (las que romperían si esta cambia).
- Las cabeceras de la tabla ordenan; `/` enfoca el buscador y `Esc` lo limpia.
- El hash guarda la selección (`#migraciones/51`,
  `#objetos/function:academico_test.fn_fun_actualizar`), así que un enlace abre
  la página ya posicionada.

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
