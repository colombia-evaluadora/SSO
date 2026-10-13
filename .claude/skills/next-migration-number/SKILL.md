---
name: next-migration-number
description: >-
  Decide qué fichero de postgres/migrations/ tocar: la migración dueña de hoy
  (editar) o un V<n> nuevo junto a su categoría, libre en todas las ramas y
  PRs. deps.py da la ficha de una función, endpoint o tabla (dueña, contrato,
  quién la llama, impacto, cadena hasta el gate) y de una migración (de qué
  depende, qué la usa, qué está muerto). Usar siempre antes de crear o editar
  una migración, y para averiguar qué define hoy un objeto o a quién afecta.
---

# next-migration-number

La pregunta no es "¿qué número toca?" sino "¿qué archivo toco?". Casi todo lo
que se pide ya existe en alguna migración, y un `V<n>` nuevo que reescribe una
función con dueña deja dos verdades en el historial. Primero la dueña; solo si
no hay, número.

## 1. ¿Quién lo define hoy y a quién afecta?

```bash
python .claude/skills/next-migration-number/deps.py fn_actividad_listar      # funcion
python .claude/skills/next-migration-number/deps.py /planeador/actividades   # endpoint(s) de esa ruta
python .claude/skills/next-migration-number/deps.py tactividad               # tabla
python .claude/skills/next-migration-number/deps.py --version 224            # una migracion
python .claude/skills/next-migration-number/deps.py --reutilizable planeador # que reutilizar, por capa
```

El nombre se resuelve exacto (corto, con esquema o la ruta); sin exacto, busca
como subcadena y resume por tipo con lo más llamado primero (`--todo` da todas
las fichas, `--historial` el historial completo y la cadena profunda). Lee el
modelo cacheado y el grafo de llamadas **vivo**: solo cuenta lo que hace la
definición vigente de cada objeto.

| Ficha | Qué mirar |
|---|---|
| **EDITAR V\<n\> \<fichero\>** | la dueña de hoy; no te guíes por la migración más antigua que "suena" al tema |
| **contrato** | el `COMMENT ON FUNCTION` vigente (ruta, gate, qué devuelve) |
| **lo llaman / IMPACTO** | endpoints, funciones, triggers y Java que la usan; los endpoints que la ejecutan aunque sea indirectamente son lo que hay que volver a probar |
| **llama a / tablas** | con su capa (gate, interno, validación…) |
| **cadena / gate** (endpoint) | wrapper → núcleo → validaciones; `! SIN GATE` si ninguna es gate ni filtro de alcance |
| **FIRMA CAMBIO** | cambió de aridad: editar obliga a `DROP FUNCTION IF EXISTS` de la vieja |
| **firmas exactas** | `! N SOBRECARGAS VIVAS` = una llamada que encaje en varias da 42725 |
| **ORDEN** | migraciones que la ejecutan o validan al migrar: una que la redefina no puede ir antes |
| `--version`: **DEPENDE DE / LA USAN** | **FUERA DE ORDEN** = solo funciona por enlace tardío de PL/pgSQL |

Etiquetas de `--version` (sección PRECISION, por firma exacta), las que deciden
si un fichero se puede editar o recortar:

- **MUERTA** — se puede quitar. **VIVA POR FIRMA** — sobrecarga viva aunque el
  historial diga "muerta" (V116→V130): no se quita.
- **MUERTA PERO NECESARIA** — algo la ejecuta antes al migrar en base limpia: se
  conserva con un CREATE condicionado a `to_regprocedure(...) IS NULL`.
- **DROP PELIGROSO** — re-aplicar el fichero borraría la vigente de otra migración.
- **ALTER POSTERIOR** / COMMENT por OID — escrituras que el modelo no ve;
  re-aplicar el CREATE las deshace.
- **BACKFILL**, **VERIFICACION**, **SEMILLA NECESARIA**, **PARCHE 'PISADO'**,
  **REVIERTE** — lo que el deploy repetiría al re-ejecutar el fichero.

## 2. Editar o crear

| Situación | Qué hacer |
|---|---|
| El objeto tiene dueña y el cambio es "así debió escribirse" | Editar la dueña (CLAUDE.md), dejando limpio lo `MUERTA` del fichero (`rules/migraciones.md` § deja limpio lo que tocas) |
| La dueña ya está desplegada | Igual se edita: el deploy hace `repair` y re-aplica. Calcula el set con `python scripts/migration-reapply-set.py <n>` (skill `reaplicando-migraciones`) y dilo en el reporte |
| El objeto no existe, o es funcionalidad nueva que convive con la vieja | `V<n>` nuevo, una migración por capa (`rules/migraciones.md` § por capas) |
| Hay que colarse antes de una migración existente | Out-of-order en un hueco, confirmando antes con `/server-status` que no está en `flyway_schema_history` |

## 3. El número (solo para una migración nueva)

```bash
python scripts/migration-analysis hueco --categoria planeador
python scripts/migration-analysis hueco --objeto fn_actividad_listar --objeto fn_unidad_crear
python scripts/migration-analysis hueco --panorama     # maximo por rama y PR, colisiones
```

Una sola herramienta, contra el árbol local, **todas** las ramas de `origin` y
las PRs abiertas, decimales incluidos:

- **piso:** la dueña de cada `--objeto` que la migración redefine o usa; por
  debajo, la pisa la posterior;
- **recomendado:** el primer decimal libre detrás del bloque de la categoría
  (`V553.2`), que deja la funcionalidad contigua y casi nunca choca;
- **`!! MISMA VERSION CON FICHEROS DISTINTOS`:** dos ramas o PRs usan el mismo
  número; Flyway rechaza el despliegue en cuanto se fusiona la segunda (V523).
  Renumerar una antes de fusionar;
- los huecos enteros bajo el techo **no son libres**: casi siempre son una rama
  borrada o algo ya aplicado en un servidor.

## 4. Antes de escribir: dónde está cada regla y qué la comprueba sola

Las reglas viven en un solo sitio; el hook `post_edit` corre el linter en cada
edición y el CI repite orden + lint + re-aplicación. No hace falta repasarlas
aquí, pero sí decidirlas antes de escribir:

| Decisión | Regla | Se comprueba solo |
|---|---|---|
| Capa (DDL, utilidades, validaciones, `_interno`, wrapper, endpoint) | `rules/migraciones.md` § por capas | revisor |
| Gate en el wrapper con la acción exacta y alcance; núcleo `_interno` sin permisos | CLAUDE.md, `rules/migraciones.md`, `definiendo-permisos` | lint `GATE-EN-LINEA`, `WRAPPER-GORDO`, `GATE-TILDES`; pestaña Calidad (endpoints sin gate) |
| Una validación por regla, reutilizada en todo el CRUD | `rules/migraciones.md` § validaciones | revisor |
| Qué bloquea o se arrastra al borrar; orden de errores | `rules/migraciones.md` § antes de borrar | lint `BORRADO-SIN-GUARDA` |
| Forma de un listado | `optimizando-consultas` § 3 | lint `LISTADO-PLAN-GENERICO` |
| Firma, idempotencia, auditoría de tablas nuevas, catálogos por texto | CLAUDE.md § invariantes | lint `FIRMA-SIN-DROP`, `QUERY-ON-CONFLICT`, `TABLA-SIN-CDC`, `PK-CATALOGO`; CI re-aplica sobre base limpia |
| Endpoint: `param_types` completo, restricciones, roles | `new-query-endpoint` | lint `BIND-SIN-TIPO` |
| Comentarios | `rules/migraciones.md` § comentarios | lint `CABECERA`/`COMENTARIOS` (error en nuevas), `COMMENT-LARGO` |

Dos cosas que no comprueba nadie:

- **Nombre y esquema:** `fn_<dominio>_<accion>` en singular del dominio, y el
  esquema explícito (`academico_test`, `public`, `pigse`).
- **Guarda de resultado:** si la migración depende de que exista una fila previa
  (la hermana que clona, un menú, un microservicio), un `DO $$ … RAISE EXCEPTION`
  que reviente la migración en vez de dejar un 404 silencioso.

Cabecera (≤ 12 líneas):

```sql
-- V407 -- fn_x + GET /ruta
-- Qué hace: una o dos frases.
-- Por qué aquí: la decisión que no se deduce leyendo el SQL.
-- Depende de: V224 (fn_actividad_listar), V29 (gate).
```

## 5. Al cerrar

El linter ya corrió en cada edición y el informe HTML se regeneró solo
(`.claude/hooks/informe_fondo.py`). Queda:

1. `python scripts/migration-analysis orden <fichero>` — que nada posterior
   pise lo que escribiste (el CI lo repite, pero tarde).
2. Si editaste una migración desplegada: el set de `migration-reapply-set.py`.
3. Reportar: número y por qué ese, ficheros editados frente a creados, qué
   reutilizaste y qué no con su motivo, el impacto de `deps.py` de lo que
   cambió de contrato, y los avisos del lint que no aplican con su razón.
