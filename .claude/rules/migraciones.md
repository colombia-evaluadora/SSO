---
paths:
  - "postgres/**"
  - "scripts/migration-analysis/**"
---

# Reglas — Postgres y migraciones (`postgres/`)

Complementan los invariantes de `CLAUDE.md`, que no se repiten aquí. El linter
(`migration-analysis lint`) corre en cada edición de un `.sql`: sus reglas no se
silencian; si una no aplica, se dice por qué en la respuesta.

## Qué archivo tocar

Primero la dueña, después el número (skill `next-migration-number`):
`deps.py <fn|ruta|tabla>` dice quién lo define hoy; si tiene dueña, **se edita**.
Un `V<n>` nuevo solo si el objeto no existe o convive con el viejo, numerado con
`migration-analysis hueco --categoria <id>` en un decimal junto al bloque del
dominio (`V496.1`), no en el techo global.

**Reutilizar antes de escribir:** `deps.py --reutilizable <dominio>`, repetido con
cada término cercano. En el plan, cada función nueva dice qué existente descartó
y por qué; si una sirve a medias, se extiende su dueña.

### Funcionalidad nueva: migraciones por capas

Una migración por capa, cada una llamando solo a números menores (así una base
limpia aplica). Capa vacía no se crea; dos capas no se mezclan en un fichero.

| # | Capa | Qué lleva | Qué no lleva |
|---|---|---|---|
| 0 | **DDL** | tablas, constraints, índices, `fn_audit_declarar` de cada tabla nueva | funciones de negocio |
| 1 | **Utilidades** | helpers puros: catálogo por texto, normalizar, calcular (`IMMUTABLE`/`STABLE`) | gate, escrituras, `RAISE` de negocio |
| 2 | **Validaciones** | una `fn_<dominio>_validar_<regla>` por regla y una que las compone por caso | usuario solicitante, escrituras |
| 3 | **Núcleos `_interno`** | crear/actualizar/eliminar que validan y escriben; `_listar_interno` según `optimizando-consultas` § 3 | gate, permisos |
| 4 | **Wrappers CRUD** | existencia (P0002) → gate con la **acción exacta** + alcance → `fn_audit_declarar` si escribe → delegar | lógica, SQL de negocio |
| 5 | **Endpoints** | `public.query` con `param_types` completo, `query_param_constraint`, `role_query` con roles de los menús reales (`new-query-endpoint`) | SQL que no sea llamar al wrapper |

### Al editar una migración, deja limpio lo que tocas

El deploy re-aplica **el fichero entero**: lo muerto que lleve revierte a quien
lo reescribió después (V29 en #311 deshizo V294/V295/V298/V302). En el mismo
commit, según la sección PRECISION de `deps.py --version <n>`:

- lo **`MUERTA`** (un `CREATE` que una posterior reescribe entero, sus
  comentarios) se quita;
- `VIVA POR FIRMA`, `MUERTA PERO NECESARIA`, `DROP PELIGROSO`, backfills y
  semillas no: van por `limpiando-migraciones`. Ante la duda, no se quita;
- cabecera y `COMMENT ON` se recortan a su presupuesto;
- lo quitado se nombra en el commit y en el set de `reaplicando-migraciones`.

## Wrapper y núcleo

- **El gate solo en el wrapper** (`fn_assert_permiso_seccion`,
  `fn_*_gate_escritura`, `fn_planeador_assert_alcance`), y delegar. El núcleo
  `_interno` (no `_core` ni `_impl`; precedente V159) no recibe el usuario salvo
  para auditoría: si lo necesita para decidir qué devuelve, es alcance y se le
  pasa ya resuelto.
- **Permisos y alcance son dos cosas.** Omitir establecimiento/sede/jornada en
  el gate no es "sin restricción", es no comprobarla. En un listado el alcance
  se filtra con la booleana (`fn_*_puede_ver`, `fn_planeador_alcanza`), nunca
  reimplementándolo en el `WHERE`. Niveles, gates existentes y roles:
  `definiendo-permisos`.
- **Reportes y exportaciones llaman al núcleo de la pantalla**, sin función
  propia: una `fn_*_reporte_listar` aparte diverge en cuanto se toca la otra
  (V186-V190).
- **Refactor incremental:** si editas una función con el gate en línea, pártela
  en wrapper + núcleo en esa misma migración. Sin refactor masivo.
- **`COMMENT ON FUNCTION` es contrato, ≤ 600 caracteres:** el wrapper empieza por
  la ruta HTTP, el núcleo por `INTERNO:`; después qué devuelve, gate, errores y
  quién lo reutiliza.

### Las validaciones también se componen

Una regla por función, `fn_<dominio>_validar_<regla>(...) RETURNS VOID` que lanza
o no hace nada, invocada con `PERFORM` desde todo el CRUD (precedente V162:
`fn_matricula_validar_cupo` y hermanas; V205 cambió el cupo editando una sola
función). Si al nombrarla sale una "y", son dos. Toma los ids que necesita, no
el usuario solicitante.

### Listados

La forma de un listado (filtrar antes de agregar, agregados por fila con
`LATERAL`, paginación y total, trigram, `plan_cache_mode` con filtros opcionales)
está en `optimizando-consultas`; antes de indexar, `migration-analysis tabla <t>`.

### Antes de borrar, mira qué cuelga

Un borrado lógico no rompe nada: deja lo que cuelga vivo e inalcanzable (V354:
168 sedes dadas de baja con 58 945 matrículas activas colgando).

- Antes de un `_eliminar`, recorre las relaciones hacia abajo (`deps.py`, FK de
  la tabla) y decide **explícitamente** qué bloquea y qué se arrastra.
- Lo que bloquea se rechaza con **23503** (el gateway da 409). *Terminado* bloquea
  (es historial); *dado de baja*, no.
- **El orden de errores es contrato:** existencia (P0002) → estado (22023) →
  gate (42501) → dependencias (23503). A quien no tiene permiso no se le cuenta
  qué cuelga.

### Comentarios: los justos, y solo de negocio

Cabecera ≤ 12 líneas y ≤ 20% de comentario (error en una migración nueva). El
criterio es **qué no se deduce del SQL**: una regla de negocio, una trampa de
PostgreSQL que parece un error (`GREATEST(NULL,1)` vale 1), una guarda cuya
ausencia no se notaría o por qué importa un orden. Repetir la línea siguiente,
narrar la investigación o contar qué pasó en el servidor va al commit o al PR:
en el `.sql` miente en cuanto alguien lo edita.

## Restricciones propias

- **Un número anterior al de la dueña de hoy no vale:** se pierde en una base
  limpia y revierte a la posterior en un servidor (`orden` lo bloquea en CI).
- **Los huecos enteros no son libres** (rama borrada o ya aplicado en un
  servidor). Usarlo es out-of-order, confirmado antes con `/server-status`.
- **Idempotencia:** `IF NOT EXISTS`, `DROP ... IF EXISTS`, `DELETE` por `uuid`
  antes del `INSERT`; todo fichero debe poder re-aplicarse.
- **Mensajes de error con nombre legible**, no solo el PK.
- **Sin auto-referencias** al propio `V<n>` en el cuerpo: la función sobrevive a
  su migración.
- **Una regla del linter que nace o cambia congela su deuda en el mismo PR**
  (`lint --all --baseline-regla <CODIGO>`); si no, los errores viejos se mezclan
  con los nuevos (#562, #590).

### Donde chocan las guías genéricas (`plpgsql`, Flyway)

- *"Never modify applied migrations"*: aquí se edita la dueña y el deploy
  re-aplica.
- `CREATE INDEX CONCURRENTLY` falla dentro de la transacción de Flyway: `CREATE
  INDEX IF NOT EXISTS`.
- No hay migraciones undo (`U<n>__`, Flyway Teams).
- Los UNIQUE son índices parciales `WHERE active = true`: el `ON CONFLICT` repite
  su `WHERE`.

## Al cerrar

```bash
python scripts/migration-analysis lint --all       # sin errores nuevos
python scripts/migration-analysis orden <fichero>  # nada posterior pisa lo escrito
python scripts/migration-analysis mapa             # si cambiaron funciones o endpoints
```

El informe HTML (pestaña **Calidad**: impacto, endpoints sin gate, capas) y la
poda del baseline se regeneran solos tras cada edición; `mapa --check` lo
comprueba el hook Stop. El CI (`check-flyway-migrations.sh`) aplica el
historial sobre una base limpia y re-aplica lo nuevo.
