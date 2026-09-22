---
name: next-migration-number
description: >-
  Decide el archivo de migración Flyway a tocar: si el cambio pertenece a una
  migración que ya existe (editar) o necesita un V<n> nuevo, calculado contra
  TODAS las ramas de origin. Incluye el análisis de dependencias entre
  migraciones y el checklist de qué debe definir una migración, incluida la
  separación wrapper con gate / núcleo `_interno` reutilizable. Usar siempre
  antes de crear o editar cualquier fichero de postgres/migrations/, y para
  averiguar qué migración define hoy una función o un endpoint.
---

# next-migration-number

La pregunta no es "¿qué número toca?" sino "¿qué archivo toco?". En este repo
casi todo lo que se pide ya existe en alguna migración anterior, y crear un
`V<n>` nuevo para reescribir una función que ya tiene dueño deja dos verdades
en el historial. El orden importa: primero se busca el dueño, y solo si no hay
se pide número.

## Paso 1 — ¿quién define esto hoy?

```bash
python .claude/skills/next-migration-number/deps.py fn_actividad_listar
python .claude/skills/next-migration-number/deps.py /planeador/actividades
python .claude/skills/next-migration-number/deps.py --version 224
```

Lee el modelo de `scripts/migration-analysis/analyze_migrations.py` (cacheado
en temp; `--refresh` lo recalcula tras editar migraciones). Por cada objeto
imprime:

- **DEFINIDO HOY POR V\<n\>** — la última escritura viva. Ese es el archivo a
  editar si el cambio pertenece a ese objeto.
- **historial** — quién lo creó, quién lo reescribió y qué quedó muerto. Si ves
  varias versiones "muerta por", ese texto ya no describe el estado real: no te
  guíes por la migración más antigua aunque sea la que "suena" al tema.
- **FIRMA CAMBIÓ** — la función cambió de aridad. Editar in-place obliga a
  `DROP FUNCTION IF EXISTS` con la firma vieja antes del `CREATE`; sin eso
  PostgreSQL deja las dos sobrecargas vivas y las llamadas sin tipos explícitos
  se vuelven ambiguas.
- **MIGRACIONES QUE LO USAN** — los llamadores. Cambiar contrato sin revisarlos
  es la causa habitual de que un endpoint responda 500 tras el deploy.
- Con `--version`, además **DEPENDE DE**: las migraciones que tienen que haberse
  aplicado antes. Es lo que decide si puedes numerar out-of-order o no.

## Paso 2 — editar vs. crear

| Situación | Qué hacer |
|---|---|
| El objeto ya tiene dueño y el cambio es "así debió escribirse desde el principio" | **Editar ese archivo.** Es la regla de `CLAUDE.md`. |
| Editar rompería el checksum de un servidor que ya la aplicó | Sigue siendo válido editar: `deploy-test.yml` hace `flyway repair` y reaplica el SQL cambiado. Dilo en el reporte para que nadie se sorprenda. |
| El objeto no existe, o existe pero el cambio es funcionalidad nueva que convive con la vieja | `V<n>` nuevo. |
| Necesitas colarte ANTES de una migración existente | Out-of-order sobre un hueco, y solo confirmando con `/server-status` que ese número no está en `flyway_schema_history`. |

## Paso 3 — el número

```bash
bash .claude/skills/next-migration-number/scan.sh
```

Imprime el máximo por rama de `origin`, el máximo global, el siguiente libre,
los huecos y las migraciones que viven en PRs abiertas todavía no mergeadas.

El techo se calcula contra **todas** las ramas porque dos ramas que numeran a
la vez no chocan hasta que se mergea la segunda, y entonces Flyway rechaza el
despliegue entero (historial: V53, V59, V66, V123, V136-V145).

**Los huecos no son números libres.** Casi siempre son una rama borrada o una
migración ya aplicada en un servidor. Reutilizar uno es una decisión explícita
de orden, no una forma de "aprovechar espacio".

## Qué define una migración

Antes de escribir, ten decidido cada punto; la mayoría de las migraciones que
hubo que corregir fallaron por uno de estos, no por SQL malo:

- **Objeto y alcance** — qué se crea/cambia y en qué esquema
  (`academico_test`, `public`, `pigse`). Nombre de función en singular del
  dominio: `fn_<dominio>_<accion>`.
- **Firma completa** si es función: tipos, orden, cuáles son opcionales. Cambiar
  aridad ⇒ `DROP FUNCTION IF EXISTS` de la firma vieja primero.
- **Gate de permisos** — qué menú y qué capability se exigen
  (`fn_assert_permiso_seccion`), y si aplica alcance territorial (V277). Un
  endpoint sin gate explícito es un bug de seguridad, no una omisión.
  Los CODIGO de menú van **sin tildes** y se comparan exactos (ver V396).
- **Qué parte es núcleo reutilizable** — el gate va en un wrapper delgado que
  delega en una función `_interno` **sin permisos**, para que un trigger, otro
  endpoint o un reporte puedan llamarla. Antes de escribir el núcleo, busca con
  `deps.py` si ya existe uno que sirva. Detalle en `.claude/rules/migraciones.md`
  § Anatomía de una función de endpoint; precedente vivo:
  `fn_matricula_config_crear_interno` (V159), reutilizado desde un trigger y
  desde V180/V181/V182.
- **Idempotencia** — `IF NOT EXISTS`, `DROP ... IF EXISTS`, borrar por `uuid`
  antes de insertar. `INSERT ... ON CONFLICT DO NOTHING` **no** actualiza una
  fila existente: si editas una migración que sembró datos, hace falta un
  `UPDATE` aparte (V253/V279).
- **CDC** — toda tabla nueva nace sin auditoría; hay que declararla
  explícitamente (V26/V276).
- **Guarda de resultado** — si la migración depende de que exista una fila
  previa, un `DO $$ ... RAISE EXCEPTION`. Es preferible que reviente la
  migración a que el endpoint responda 404 en silencio.
- **Sin auto-referencias** al propio `V<n>` dentro del cuerpo de una función.

## Comentarios: presupuesto

El repo llegó a cabeceras de 60 líneas de prosa que narran la investigación
(por qué se probó otra cosa, qué dijo el usuario, qué pasó en producción). Eso
envejece mal: cuando la migración se edita, la narración queda mintiendo, y el
lector siguiente no puede distinguir la parte vigente de la histórica.

Objetivo: **cabecera de ≤ 12 líneas y ≤ 20% de líneas de comentario** en el
archivo. Para medirlo:

```bash
f=postgres/migrations/V407__x.sql; echo "$((100*$(grep -c '^\s*--' $f)/$(wc -l <$f)))%"
```

La cabecera responde tres cosas y para:

```sql
-- V407 -- fn_x + GET /ruta
-- Qué hace: una o dos frases.
-- Por qué aquí: la decisión que no se deduce leyendo el SQL.
-- Depende de: V224 (fn_actividad_listar), V29 (gate).
```

Lo que **sí** vale un comentario en el cuerpo: una trampa de PostgreSQL que
parece un error de tipeo (`GREATEST(NULL, 1) = 1`, `count(DISTINCT) OVER`), o
una guarda cuya ausencia no se notaría. Lo que **no**: repetir en prosa lo que
la línea siguiente ya dice, ni el registro de las alternativas descartadas —
eso va en el mensaje de commit o en la descripción del PR, que es donde se
busca la historia.

## Al cerrar

1. `python scripts/migration-analysis/analyze_migrations.py` (o
   `/migration-analysis`) para confirmar que no dejaste llamadores con la firma
   vieja ni colisión de número.
2. Valida contra el Postgres **local** (`sso-postgres`), nunca contra un
   servidor; el hook `no-prod.sh` bloquea lo segundo.
3. Reporta: número asignado y por qué ese y no otro, archivos editados vs.
   creados, dependencias detectadas y cualquier drift contra el servidor.
