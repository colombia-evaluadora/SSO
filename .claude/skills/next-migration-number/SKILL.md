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
python .claude/skills/next-migration-number/deps.py fn_actividad_listar      # funcion
python .claude/skills/next-migration-number/deps.py /planeador/actividades   # endpoint(s) de esa ruta
python .claude/skills/next-migration-number/deps.py tactividad               # tabla
python .claude/skills/next-migration-number/deps.py --version 224            # una migracion
```

El nombre se resuelve **exacto** primero (corto o con esquema, o la ruta), así
que basta con el nombre tal cual. Si no hay exacto busca como subcadena y, con
muchas coincidencias, las resume por tipo con lo más llamado primero
(`--todo` da la ficha de todas; `--historial`, historial completo y cadena
profunda).

Y antes de escribir cualquier función, el inventario de lo reutilizable del
dominio (validaciones, gates, núcleos `_interno`, wrappers, con dueña y
parámetros):

```bash
python .claude/skills/next-migration-number/deps.py --reutilizable planeador
```

Lee el modelo cacheado (`modelo.cargar()`, se recalcula solo cuando cambia un
`.sql`) y el grafo de llamadas **vivo** de `analisis/calidad.py`: solo cuentan
las llamadas que hace la definición vigente de cada objeto. Cada ficha empieza
por lo que decide el siguiente paso:

- **EDITAR V\<n\> \<fichero\>** — la dueña de hoy. Si el historial tiene varias
  "muerta por", ese texto ya no describe el estado real: no te guíes por la
  migración más antigua aunque sea la que "suena" al tema.
- **contrato** — el `COMMENT ON FUNCTION` vigente (ruta, gate, qué devuelve).
- **lo llaman** — por nombre: endpoints (`METHOD /ruta`), funciones con su
  dueña, triggers, Java. **IMPACTO**: los endpoints que la ejecutan aunque sea
  indirectamente; es lo que hay que volver a probar.
- **llama a** (con su capa: gate, interno, validación…) y **tablas** que toca.
- En un endpoint, la **cadena** wrapper → núcleo → validaciones y si pasa por un
  **gate** (`! SIN GATE` si no). Una fila que una migración clona como hermana
  (`INSERT … SELECT`) se avisa: el analizador no distingue la copiada de la
  creada.
- En una tabla, columnas añadidas después, índices, triggers, quién la lee o
  escribe por capa y cuántos endpoints llegan a ella.
- **FIRMA CAMBIO** — cambió de aridad: editar in-place obliga a
  `DROP FUNCTION IF EXISTS` de la firma vieja, o quedan dos sobrecargas.
- **ORDEN** — migraciones que la ejecutan o validan al migrar: una que la
  redefina no puede ir antes que esas.
- Con `--version`: qué escribe (vivo / ya reescrito) resumido por tipo,
  **DEPENDE DE** / **LA USAN**, marcadas **FUERA DE ORDEN** cuando solo
  funcionan por enlace tardío de PL/pgSQL, y el comando del set de re-aplicación.

El modelo agrupa funciones por nombre y número de parámetros, y no distingue
cómo se usan. `precision.py` relee los `.sql` y corrige eso:

- **firmas exactas** / **VIVA POR FIRMA** — una posterior con otros tipos o
  más parámetros crea otra sobrecarga y la vieja sigue viva, aunque el
  historial diga "muerta" (V116→V130, V257→V360). No se puede quitar.
  `! N SOBRECARGAS VIVAS` = una llamada que encaje en varias da 42725.
- Contexto de uso: `migracion` (DO, backfill, SQL suelto, trigger) y
  `sql-body` (LANGUAGE sql, se valida al crearse) atan el orden (línea
  **ORDEN**); `plpgsql` y `texto` (filas de public.query) no.
- **MUERTA PERO NECESARIA** — reescrita después, pero algo la ejecuta antes en
  una base limpia (también en el propio fichero). Se conserva con un CREATE
  condicionado a `to_regprocedure(...) IS NULL`.
- **DROP PELIGROSO** — el fichero borra una firma que hoy define otra
  migración: el deploy, al re-aplicarlo, la borraría.
- **ALTER POSTERIOR** / COMMENT dinámico — escrituras que el modelo no ve
  (`ALTER FUNCTION ... ROWS`, COMMENT por OID); re-aplicar el CREATE las deshace.
- **BACKFILL**, **VERIFICACION**, **SEMILLA NECESARIA**, **PARCHE 'PISADO'** —
  lo que hay que revisar antes de editar un fichero que el deploy re-ejecutará.

## Paso 2 — editar vs. crear

| Situación | Qué hacer |
|---|---|
| El objeto ya tiene dueño y el cambio es "así debió escribirse desde el principio" | **Editar ese archivo.** Es la regla de `CLAUDE.md`. |
| Editar rompería el checksum de un servidor que ya la aplicó | Sigue siendo válido editar: `deploy-test.yml` hace `flyway repair` y reaplica el SQL cambiado. Dilo en el reporte para que nadie se sorprenda. |
| El objeto no existe, o existe pero el cambio es funcionalidad nueva que convive con la vieja | `V<n>` nuevo. |
| Necesitas colarte ANTES de una migración existente | Out-of-order sobre un hueco, y solo confirmando con `/server-status` que ese número no está en `flyway_schema_history`. |

## Paso 3 — el número

Para una migración **nueva**, el número se elige junto a su categoría, no al
final de todo:

```bash
python scripts/migration-analysis hueco --categoria planeador
python scripts/migration-analysis hueco --objeto fn_actividad_listar --objeto fn_unidad_crear
```

- **Piso:** cada `--objeto` que la migración redefine o usa fija un mínimo, la
  migración que lo define hoy. Por debajo, la pisa la posterior (`orden`).
- **Recomendado:** el primer decimal libre detrás de la última migración de la
  categoría que supera el piso (`V531.1`). Así la funcionalidad queda contigua y
  dos PRs casi nunca chocan en el mismo número.
- **Libre de verdad:** se mira el árbol local, todas las ramas de `origin` y
  las PRs abiertas, **decimales incluidos**.
- Los huecos enteros cercanos salen aparte: solo out-of-order deliberado.
- Sin categoría clara o sin hueco junto a ella: el siguiente al techo.

`scan.sh` da el panorama: máximo por rama (decimales incluidos), huecos,
decimales de otras ramas que el árbol local no tiene, versiones que dos ramas
usan con ficheros distintos (colisión al fusionar) y migraciones de PRs abiertas:

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
- **Alcance, no solo permiso** — qué establecimiento / sede / jornada acota la
  operación. `fn_assert_permiso_seccion` los recibe como parámetros: omitirlos
  no es "sin restricción", es no comprobarlos. El nivel del rol sale de
  `CATEGORIA_ROL` (0 super admin … 4 estudiantes, fail-closed a 4).
- **Qué validaciones comparte con el resto del CRUD** — cada regla en su
  `fn_<dominio>_validar_<regla>` reutilizable (familia `fn_matricula_validar_*`,
  V162), no repetida en `_crear`, `_actualizar` y `_eliminar`.
- **Qué cuelga de lo que se borra** — antes de un `_eliminar` / `_soft_delete`,
  recorrer las relaciones y decidir qué bloquea (23503 → 409) y qué se arrastra.
  Un borrado lógico sin esa pregunta deja la información viva e inalcanzable
  (V354: 58 945 matrículas). Orden: existencia → estado → gate → dependencias.
- **En qué capa va** — DDL, utilidades, validaciones, `_interno`, wrapper CRUD o
  endpoint (`.claude/rules/migraciones.md` § migraciones por capas). Una
  migración, una capa.
- **Forma de la consulta si es un listado** — la plantilla de
  `optimizando-consultas` § 3: `STABLE`, filtrar antes de agregar (V112:
  11,5 s → 83 ms), `plan_cache_mode` con filtros opcionales, paginación y total.
- **Qué queda muerto en el fichero que editas** — `deps.py --version <n>`; lo
  `MUERTA` sale en el mismo commit (§ deja limpio lo que tocas).
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

Cabecera ≤ 12 líneas, ≤ 20% de comentario y `COMMENT ON` ≤ 600 caracteres; el
linter lo mide y en una migración nueva es **error**. El criterio (qué se gana
un comentario y qué va al commit) está en `.claude/rules/migraciones.md`
§ Comentarios. La cabecera responde tres cosas y para:

```sql
-- V407 -- fn_x + GET /ruta
-- Qué hace: una o dos frases.
-- Por qué aquí: la decisión que no se deduce leyendo el SQL.
-- Depende de: V224 (fn_actividad_listar), V29 (gate).
```

## Al cerrar

1. `python scripts/migration-analysis informe` (o
   `/migration-analysis`) para confirmar que no dejaste llamadores con la firma
   vieja ni colisión de número.
2. Si el usuario pide probarla, contra el Postgres **local**
   (`sso-postgres`); nunca contra un servidor, que el hook `no_prod.py`
   bloquea. Sin esa petición, no se prueba: basta con el linter.
3. Reporta: número asignado y por qué ese y no otro, archivos editados vs.
   creados, dependencias detectadas y cualquier drift contra el servidor.
