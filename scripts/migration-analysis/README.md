# Análisis de migraciones

Genera un informe HTML interactivo sobre `postgres/migrations/`: qué migraciones
quedaron obsoletas, qué objeto reescribió a cuál, qué firmas de función
cambiaron y quién se quedó llamándolas con la firma vieja, y cuál es el próximo
número de versión realmente libre.

Un solo CLI, con subcomandos:

```bash
python scripts/migration-analysis lint --all           # invariantes (antes scripts/migration-lint.py)
python scripts/migration-analysis orden --base origin/dev  # orden de versiones (antes migration-orden.py)
python scripts/migration-analysis oraculo             # verifica el modelo contra un Postgres real
```

Sin subcomando genera el informe:

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

Las filas de `public.query` se resuelven **por columna**: una escritura muere
solo cuando las posteriores han reescrito todas las columnas que dejó. Un
`UPDATE` que solo cambia `query` no mata un `param_types` o un `detail`
anterior, y un `INSERT … ON CONFLICT DO NOTHING` sobre una fila que ya existe
es un no-op: no mata nada (V93 sobre las filas de V67). Los
`WITH … AS (VALUES …) INSERT INTO public.query` crean las filas de sus tuplas.

Veredictos: `obsoleta` (ninguna escritura sobrevive), `residual` (una sola viva
contra tres o más muertas), `parcial`, `viva`, `solo-binds` (únicamente ata
permisos o siembra datos — eso no se reescribe) y `sin-cambios` (documental).

Una migración obsoleta se puede borrar del repo: el deploy hace `flyway repair`
y la marca como borrada. Antes hay que confirmar por firma exacta que nada la
necesita al migrar (ver "Qué se puede recortar").

## Arquitectura

| Fichero | Qué hace |
|---|---|
| `sqlscan.py` | Parte el SQL en sentencias respetando literales, `$$ … $$` y comentarios; enmascara lo que no se ejecuta al migrar (`mask_inert`) y da la firma de identidad de una función. |
| `nucleo.py` | Tipos compartidos (`Write`, `Migration`), orden de versiones (`vkey`, `vnum`) y rutas del repo. |
| `extraccion.py` | `LectorMigracion` lee un archivo; el DDL lo emiten los `EXTRACTORES_DDL` (una clase por familia: funciones, relaciones, ALTER TABLE, índices…) y el DML del catálogo se despacha por tabla destino (`_DML`). `Registro` resuelve esquemas como Postgres. |
| `consultas.py` | Filas de `public.query`: qué fila toca una sentencia, qué columnas escribe y a qué filas ata un bind. |
| `grafo.py` | `build_graph` y un `Resolutor` por tipo de objeto (`Generico`, `Funcion`, `FilaQuery`, `Acumulativo`, `SinIdentidad`): status de cada escritura y `estado` final. Binds de `role_query`, líneas y veredicto. |
| `usos.py` | Quién usa qué: llamadas SQL y Java, referencias a tablas, firmas cambiadas, huérfanas y llamadas a funciones borradas. |
| `historia.py` | Autoría y números libres en todas las ramas (git). |
| `poda.py` | Recorte por firma exacta con `precision.py`. |
| `categories.py` | Taxonomía funcional y **la única** agregación por categoría. |
| `analyze_migrations.py` | `construir()` orquesta lo anterior sin escribir nada; el CLI lo envuelve. |
| `modelo.py` | Punto único de acceso al modelo, con caché por huella de las migraciones y de estos módulos. |
| `oraculo.py` + `catalogo.sql` | Verifica el modelo contra un Postgres real con todo el historial aplicado (ver Precisión). |
| `render.py` + `render_categories.py` | Solo pintan el modelo: no recalculan ninguna cifra. |

**Extender**: un tipo de DDL nuevo es una subclase de `ExtractorDDL` en
`EXTRACTORES_DDL` (o una fila de `SIMPLE_DDL` si es un objeto con nombre
propio); un objeto con reglas de vida propias, una subclase de `Resolutor`
registrada en `RESOLUTORES`; una tabla del catálogo con reglas propias, un
método en `LectorMigracion._DML`. Tras cualquier cambio: el modelo debe salir
idéntico salvo lo que se quiso cambiar, y `oraculo.py` sin discrepancias.

El flujo es uno: `construir()` → `apply_precision()` (corrige el mapa de
líneas de cada migración) → `categorize()` (agrega esos mismos mapas por
categoría) → JSON / HTML / consumidores. Una cifra se calcula en un solo sitio.

**Todos los consumidores leen por `modelo.cargar()`**: `deps.py`, `precision`,
`lint.py` (y su hook), `orden.py`, `migration-reapply-set.py`,
`generar-mapa.py` (y el hook Stop) y `limpiando-migraciones/propuesta.py`.
El modelo se cachea en `%TEMP%/sso-migrations-model.json` con la huella de
todas las migraciones y del código del analizador (incluido `precision.py`):
si cambia un `.sql` o una regla se reconstruye solo, y nadie necesita
`--refresh` ni correr el analizador dos veces. Generar el informe completo
también deja ese caché al día.

El HTML solo se escribe cuando se pide: sin argumentos, o con `--out`. Con
`--json` a secas no se toca `docs/auditoria/`. (Antes, cada consumidor llamaba
al CLI con `--no-git --json` y de paso pisaba el informe con una versión sin
el techo de las ramas de `origin`.)

### Añadir una cifra por categoría

Se añade en `categories.categorize()` (o en `lineas()` si sale del mapa de
líneas) y se pinta en `render_categories.py`. Nada más: `render.compact` pasa
las definiciones tal cual, y `docs/MAPA.md` usa la misma asignación.

## Por elemento

La pestaña **Objetos** responde, para cada elemento, qué migraciones lo
reescribieron (con línea y quién mató a cada escritura) y quién lo usa: cada
llamada a función o referencia a tabla/vista se atribuye al elemento que la
contiene (la función que se define, la fila de `public.query` que se inserta)
y se separa entre "sus mismas migraciones" y "otras". Una sentencia suelta
(un `UPDATE` sin definir nada) se atribuye a la migración. El JSON lo expone
como `uses`: `{from, to, v, line, file, kind: call|ref|java}`.

## Cuántas líneas sobran

La pestaña **Líneas** reparte las líneas del corpus en *recortables* /
*se conservan* / *vigentes* / *sin encadenar*, con el desglose por archivo. Cada sentencia
reclama su tramo desde el `;` anterior (así que arrastra su comentario de
cabecera, que es lo que de verdad se borraría) y el tramo sólo cuenta como
sin efecto si **ninguna** de sus escrituras sigue viva: en un bloque `DO`
que toca varios objetos, basta uno vigente para conservarlo.

## Qué se puede recortar

El modelo empareja funciones por nombre y aridad, así que "sin efecto" engaña
en los dos sentidos. Si existe `.claude/skills/next-migration-number/precision.py`,
`apply_precision()` relee cada migración por **firma exacta** y contexto de uso
(`version_findings`, lo mismo que imprime `deps.py --version <n>`) y:

- pasa a *se conservan* (`n` en el mapa del archivo) las sentencias sin efecto
  que hacen falta: sobrecarga viva por firma, función que una migración
  intermedia llama, valida (`LANGUAGE sql`), comenta o altera al migrar,
  semilla que otra usa antes, CREATE ya condicionado (`solo_si_falta`);
- da a cada migración un veredicto de recorte (`recorte` en el JSON):
  `recortable`, `con-ajuste` (algo que re-aplicado borra o revierte lo de una
  posterior: DROP de la vigente, filas o índices que otra reescribe, un ALTER
  que hay que copiar al CREATE, COMMENT por OID, o una función necesaria al
  migrar), `revisar-backfill` (recalcula datos reales al re-aplicarse) o `nada`;
- guarda los avisos en `findings` y el detalle de cada migración los muestra.

Recortar un fichero ya aplicado cambia su checksum: el deploy hace `repair` y
lo re-ejecuta entero, así que lo que queda tiene que poder correr otra vez sin
revertir nada. El procedimiento, con banco de pruebas, es la skill
`limpiando-migraciones`. Sin `precision.py` el informe usa la cuenta del modelo
y lo marca como `sin-precision`.

## Presupuesto de comentarios

La pestaña **Líneas y comentarios** mide también el presupuesto de CLAUDE.md
(cabecera de ≤12 líneas, ≤20% de comentario) con el **mismo criterio que
`scripts/migration-analysis/lint.py`**: líneas que empiezan con `--`, y fuera de
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

## Categorías funcionales

La pestaña **Categorías** reparte objetos y migraciones entre las áreas del
producto (permisos, menús, establecimiento, sedes, funcionarios, periodos,
PIGSE, matrícula, prematrícula, planeador, planilla, asistencias, referentes,
auditoría, observaciones, informes, calificación con instrumentos, más
estructura académica y plataforma SSO). Las reglas están en `categories.py`
(una regex por categoría; el orden decide cuando un nombre casa con varias):

- un **objeto** se clasifica por su nombre o el path de su fila de
  `public.query`; si no dice nada, hereda de lo que usa y, si no, de la
  migración que lo creó;
- una **migración** toma la categoría de su nombre de archivo (la que aparece
  primero) o, si no casa, la de la mayoría de sus líneas; figura en «también la
  tocan» de las categorías que ocupan ≥15% de sus sentencias.

Por categoría se ve su **mapa de líneas** —la suma de los mapas de sus
archivos, con los mismos estados (vigente / recortable / se conserva /
comentario / sin encadenar) y colores—, líneas y % del corpus, recortables, % de comentario,
objetos vivos/muertos por tipo, veredictos, quién creó y quién aportó
(commits, +/−), actividad por mes, firmas cambiadas, objetos más usados y qué
usa de otras categorías o quién la usa. El grafo tiene dos niveles: burbujas por
categoría con aristas de uso, y la categoría abierta con sus migraciones →
objetos → categorías externas. `#categorias/<id>` abre una directamente, y la
pestaña Migraciones filtra por categoría. El JSON lo expone como `categories`;
`docs/MAPA.md` agrupa por estas mismas categorías y
`deps.py --reutilizable <id-categoría>` lista lo vivo de una.

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

### Qué texto se lee

Un grep sobre migraciones confunde lo que se **menciona** con lo que se
**ejecuta**. El extractor solo busca DDL en el texto que corre al migrar
(`sqlscan.mask_inert`: misma longitud, literales y cuerpos `$$` en blanco):

- el **cuerpo de una función** corre cuando se la llama, no al crearla: un
  `CREATE TEMP TABLE` o un `DROP TABLE` dentro de él no es DDL de la migración;
- un **bloque `DO`** sí corre: se lee su cuerpo sin comentarios (también los
  internos: `-- DROP INDEX falla` en V146 era un índice fantasma) y el SQL de
  cada `EXECUTE '...'` / `EXECUTE format($f$...$f$)`;
- un **literal** (mensajes, `detail`, el SQL de una fila de `public.query`) no
  es DDL; las comparaciones `col = '...'` del catálogo se buscan solo a nivel
  superior y el valor se lee del original en la misma posición.

### Cómo se nombra un objeto

- **Esquema como en Postgres**: un `Registro` lleva lo que existe hasta cada
  migración y el `search_path` de cada archivo (Flyway lo restaura al terminar
  cada una). Un nombre sin esquema se resuelve al primer esquema del path donde
  ya existe; un índice vive en el esquema de su tabla. Antes `tarchivo` y
  `academico_test.tarchivo` eran dos cadenas y la primera parecía muerta.
- **Funciones por firma de identidad** (tipos de entrada, sin `OUT` ni
  `DEFAULT`): `f(int)` y `f(int, text)` son dos objetos. Un `CREATE` reescribe
  solo su firma; un `DROP FUNCTION f(firma)` sin recreación la borra.
- **Orden real dentro de una sentencia** (`Write.pos`): en un `DO` con
  `DROP INDEX` y luego `CREATE INDEX`, el vivo es el segundo.
- **`public.query`**: la identidad real es la ruta (servicio, path, método). Un
  `INSERT ... ON CONFLICT` sobre una ruta existente no crea el uuid que trae.
  `(path = a AND method = 'POST') OR (path = b AND method = 'PUT')` se empareja
  por ruta, sin producto cartesiano.

### Estado de cada objeto

`model["estado"][clave]` dice si el objeto **existe** al final del historial,
qué migración lo **define hoy** (`duena`), dónde se **borró** (`borrada_en`) y,
para funciones, lo mismo **por firma**. Un `DROP` que borra de verdad es código
vigente pero el objeto no existe: los consumidores (`deps.py`, el mapa) leen
`estado` en vez de inferirlo de los status.

`model["llamadas_rotas"]` lista llamadas a funciones que ya no existen desde la
definición vigente de algo que sí existe: un error en tiempo de ejecución.

### Binds

Un `INSERT INTO role_query` vale mientras viva su fila de `public.query` (FK
`ON DELETE CASCADE`): si la fila se borra después —aunque se vuelva a crear con
otro id— el bind está muerto; si no existía al atar, fue un no-op. La fila
destino sale del `WHERE` o de las tuplas `VALUES`, leyendo qué columna es ruta,
verbo o servicio del propio `JOIN` (`q.path_template = d.ruta`). Los binds por
patrón (`LIKE '/planeador/%'`) no se pueden nombrar y se tratan como persistentes.

### Verificación contra una base real

```bash
python scripts/migration-analysis/oraculo.py            # ~2 min
python scripts/migration-analysis/oraculo.py --mantener # y luego --reusar
```

Levanta un Postgres 16 desechable en local, aplica todo el historial con Flyway
(como el job de CI), lee el catálogo (`catalogo.sql`) y lo compara con
`estado`: funciones por firma y su migración dueña (por cuerpo idéntico a
`prosrc`), tablas, vistas, índices, secuencias, triggers, columnas,
constraints, tipos, filas de `public.query` y binds. Sale con 1 si hay
discrepancias. Correrlo tras tocar un extractor o el grafo.

Lo que **no puede** ver por definición sale como informativo: los triggers
`trg_audit_ctx` que un `DO` crea con `format('%I')` sobre cada tabla, y los
binds de roles `CEVAL-*` que llegan por el dump base (en una base limpia el
`INSERT ... SELECT` no inserta).

### Límites que quedan

- **DDL dinámico** con objetivo en tiempo de ejecución: cuenta como escritura
  persistente, no se encadena.
- **Ramas de un `DO`** (`IF ... THEN DROP ... ELSE ...`): se toma el orden
  textual; no se evalúan condiciones.
- **Llamadas sin esquema** se resuelven por nombre si existe en un solo
  esquema. Las "llamadas fuera de la firma viva" son candidatas: el conteo de
  argumentos es textual. Cada fila trae `archivo:línea`.
