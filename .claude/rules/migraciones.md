---
paths:
  - "postgres/**"
  - "scripts/migration-lint.py"
  - "scripts/migration-analysis/**"
---

# Reglas — Postgres y migraciones (`postgres/`)

Aplican a todo `postgres/migrations/`. Complementan el `CLAUDE.md` raíz.

## Orden de trabajo

No se empieza escribiendo SQL. Se empieza averiguando **qué archivo tocar**:

```bash
python .claude/skills/next-migration-number/deps.py <fn|ruta>   # quién lo define hoy
python .claude/skills/next-migration-number/deps.py --version N # de qué depende
bash .claude/skills/next-migration-number/scan.sh               # número libre real
```

Si el objeto ya tiene dueña, **se edita esa migración**; solo se crea un `V<n>`
nuevo cuando el objeto no existe o la funcionalidad convive con la vieja.
`docs/MAPA.md` da el índice dominio → función → migración.

## Skills y agentes

| Trabajo | Usar |
|---|---|
| Crear/editar/revisar una migración | agente `flyway-migration-author` |
| Funciones, triggers, PL/pgSQL | skill `plpgsql` |
| SQL, índices, constraints, performance | skill `postgresql` |
| Versionado y patrones Flyway | skill `flyway-migrations` |
| SQL portado desde Oracle | skill `reviewing-oracle-to-postgres-migration` |
| Endpoint de `query-service` | `/new-query-endpoint` + agente `query-service-endpoint-builder` |
| Saber qué quedó obsoleto tras editar | agente `migration-analysis-reporter` |
| El servidor no se comporta como el repo | agente `server-drift-detector` |

## Anatomía de una función de endpoint

Una función de endpoint es un **wrapper delgado**: valida permisos y delega. La
lógica vive en un **núcleo sin gate**, que otro endpoint, un trigger, un reporte
o una exportación pueden reutilizar sin volver a pedir permisos.

```sql
-- wrapper: el único que sabe de permisos
CREATE OR REPLACE FUNCTION fn_matricula_config_crear(p_pk_usuario BIGINT, ...)
...
  PERFORM academico_test.fn_assert_permiso_seccion(p_pk_usuario, 'MATRICULA', 'CREAR', ...);
  RETURN academico_test.fn_matricula_config_crear_interno(...);
```

- **El gate va solo en el wrapper**: una llamada a `fn_assert_permiso_seccion` /
  `fn_*_gate_escritura` / `fn_planeador_assert_alcance` al principio, y delegar.
- **El núcleo no recibe `p_pk_usuario_solicitante`** salvo para auditoría. Si lo
  necesita para decidir *qué* devuelve, eso es scope: se resuelve en el wrapper
  y se le pasa ya resuelto como filtro.
- **Nombre del núcleo: sufijo `_interno`** (precedente vivo:
  `fn_matricula_config_crear_interno`, V159). No `_core` ni `_impl`.
- **`COMMENT ON FUNCTION`:** el wrapper empieza por la ruta HTTP; el núcleo
  empieza por `INTERNO:` y nombra quién lo reutiliza.
- **Antes de escribir un núcleo, busca uno que sirva** con `deps.py`. Reutilizar
  es el objetivo, no un efecto secundario.
- **Reportes y exportaciones no crean función propia:** llaman al mismo núcleo
  que la pantalla. Una `fn_*_reporte_listar` aparte diverge de su `fn_*_listar`
  en cuanto una de las dos se toca (pasó con V186-V190).
- **Refactor incremental:** si ya vas a editar una función que lleva el gate en
  línea, pártela en wrapper + núcleo **en esa misma migración**. No hay refactor
  masivo de las funciones existentes.

Por qué: cuando el gate va dentro de la lógica, la lógica no se puede reutilizar.
La cabecera de `V130__listar_sin_paginar_para_reportes.sql` lo dice — se descartó
crear funciones de reporte porque "duplicaría el WHERE y el gate de autorización
de cada listado", y hubo que meter `p_page_size NULL` a la función existente.

### Las validaciones también se componen

El CRUD de un dominio repite las mismas comprobaciones en `_crear`, `_actualizar`
y `_eliminar`. Escritas en línea, corregir una regla es encontrar sus N copias y
acertar con todas.

Cada regla de negocio va en su propio `fn_<dominio>_validar_<regla>(...)` que
**lanza o no hace nada** (`RETURNS VOID`), y el CRUD la invoca con `PERFORM`.
Precedente vivo: `fn_matricula_validar_cupo`, `_validar_estudiante_disponible`,
`_validar_periodo_vigente`, `_validar_plazo_matricula` (V162). Que funciona se
demostró en V205: cambiar el cupo para que contara por estado fue **editar una
función**, no perseguir llamadores.

- Una regla por función, con nombre que diga la regla. Si al nombrarla te sale
  una "y", son dos.
- Toman los ids que necesitan, no el usuario solicitante: eso es el gate.
- El orden de las comprobaciones es contrato, no gusto — ver más abajo.
- Antes de escribir una, `deps.py` dice si ya existe.

### Permisos y alcance son dos cosas

El gate responde *¿puede hacer esto?*; el alcance, *¿sobre qué filas?*. Pasar
solo el primero deja a un rector escribiendo en otro establecimiento.

- `fn_assert_permiso_seccion(usuario, menu, accion, establecimiento, sede,
  jornada)` — los tres últimos son el alcance. **Omitirlos no es "sin
  restricción": es no comprobarla.** Si la fila cuelga de una sede, se pasa la
  sede.
- El nivel sale de `CATEGORIA_ROL` (V29/V120): `0` super admin (bypass),
  `1` territorial, `2` establecimiento, `3` sede+jornada, `4` estudiantes y
  familia. Se resuelve por el **texto** de `TLISTA_VALOR.VALOR`, y un rol sin
  categoría o con un valor desconocido cae a `4` — fail-closed.
- Un usuario multi-rol vale por su nivel **más alto**
  (`fn_usuario_categoria_rol_nivel` = `MIN`).
- En un listado el alcance no se pregunta, se **filtra**: la variante booleana
  (`fn_*_puede_ver`, `fn_planeador_alcanza`) va en el `WHERE`. Nunca se
  reimplementa el modelo de permisos en el `WHERE`: la booleana envuelve al
  assert y captura el 42501, para que las dos formas no puedan divergir (V277).
- Escribir permisos en el JWT no es escribirlos en la base. Son dos fuentes
  distintas y al desincronizarse la UI muestra el botón y la base responde
  42501.

### Filtrar antes de agregar

Un agregado que no depende de la página se calcula entero aunque salgan diez
filas. `fn_usu_empleados_listar` agregaba sedes y estados sobre los **126 704**
usuarios de `TSEDE_USUARIO` y después unía por `LEFT JOIN` con los ≤1 599 que
podían aparecer: un `LEFT JOIN` contra un subquery con `GROUP BY` no deja al
planner empujar el filtro hacia dentro. **11,5 s para 100 filas**, y el tiempo
era el mismo con o sin filtros. V112 lo dejó en 83 ms.

- El agregado por fila va como **subconsulta correlacionada en el `SELECT`** o
  `LEFT JOIN LATERAL ... LIMIT 1`: Postgres solo lo evalúa para las filas que
  sobreviven al `ORDER BY`/`LIMIT`.
- Un CTE con `GROUP BY` que no menciona ningún parámetro de filtro es la señal:
  se va a materializar entero.
- `ILIKE '%x%'` sobre varias columnas no usa índice. Se unifica en **una**
  expresión y se indexa **esa misma** expresión con GIN trigram — el planner
  solo usa un índice de expresión si la consulta repite la expresión exacta.
- Antes de dar por buena una consulta de listado, `EXPLAIN ANALYZE` contra el
  Postgres local con datos, no a ojo.

### Antes de borrar, mira qué cuelga

Un borrado lógico no rompe nada: deja la información viva y **inalcanzable**.
Dar de baja una sede no miraba nada de lo que colgaba de ella; en el servidor de
test 168 sedes arrastraron 256 periodos académicos, 1 170 grados, 3 632 grupos y
**58 945 matrículas activas** colgando de sedes que ya no existían (V354). No es
que el borrado las rompiera: es que nadie preguntó.

- Antes de escribir un `_eliminar` / `_soft_delete`, recorre la cadena de
  relaciones hacia abajo (`deps.py`, `docs/MAPA.md`, las FK de la tabla) y
  decide **explícitamente** qué bloquea y qué se arrastra.
- Lo que bloquea se rechaza con **23503**, que es el código que el esquema ya usa
  para "tiene dependientes" (`fn_matricula_eliminar` V163/V166, referente
  curricular V213, actividad con notas V224, `fn_periodo_soft_delete` V37). El
  gateway lo traduce a 409.
- Distingue *terminado* de *dado de baja*: un periodo cerrado sigue siendo
  historial y bloquea; uno que alguien ya retiró, no.
- **El orden de los errores es contrato:** existencia (P0002) → estado (22023) →
  gate (42501) → dependencias (23503). El guard de dependencias va **después**
  del gate: a quien no tiene permiso sobre la sede no se le cuenta cuánto
  historial tiene.

### Comentarios: los justos, y solo de negocio

Presupuesto: cabecera ≤ 12 líneas y ≤ 20% de líneas de comentario. Pero el
límite no es el criterio; el criterio es **qué no se deduce leyendo el SQL**.

Un comentario se gana su sitio cuando explica:

- una **regla de negocio** que el código no puede decir por qué es así ("un
  periodo TERMINADO sigue siendo historial y bloquea; uno dado de baja no");
- una **trampa de PostgreSQL** que parece un error de tipeo (`GREATEST(NULL,1)`
  vale 1, `count(DISTINCT) OVER` no existe, `ON CONFLICT DO NOTHING` no
  actualiza);
- una **guarda cuya ausencia no se notaría**, o por qué el orden de dos
  comprobaciones importa.

No lo vale: repetir en prosa la línea siguiente, narrar la investigación, listar
las alternativas descartadas, ni contar qué pasó en el servidor. Eso va al
mensaje de commit o a la descripción del PR, que es donde se busca la historia;
dentro del `.sql` queda mintiendo en cuanto alguien edite la función.

## Restricciones

- **Numeración contra TODAS las ramas de `origin`.** Dos ramas que numeran a la
  vez no chocan hasta que se mergea la segunda, y ahí Flyway rechaza el
  despliegue entero (V53, V59, V66, V123, V136-V145).
- **Los huecos no son números libres.** Casi siempre son una rama borrada o una
  migración ya aplicada en un servidor. Reutilizar uno es una decisión explícita
  de orden (out-of-order), confirmada antes con `/server-status`.
- **Idempotencia obligatoria:** `IF NOT EXISTS`, `DROP ... IF EXISTS`, `DELETE`
  por `uuid` antes del `INSERT`. Toda migración debe poder reaplicarse.
- **Cambiar la aridad de una función exige `DROP FUNCTION IF EXISTS`** de la
  firma vieja, o quedan dos sobrecargas vivas.
- **Gate de permisos explícito** en todo endpoint, con su menú, su capability y
  su alcance (ver arriba). Los CODIGO de menú van **sin tildes** y se comparan
  exactos.
- **Catálogos por texto, nunca por pk.** Los `pk_tlista_valor` difieren entre el
  servidor de test y un Postgres limpio, y el catálogo de `TROL` no está en las
  migraciones: llega por el dump base.
- **Tabla nueva ⇒ declarar auditoría** (V26/V276).
- **Mensajes de error con nombre legible**, no solo el PK.
- **Sin auto-referencias** al propio `V<n>` dentro del cuerpo de una función: la
  función sobrevive a su migración.
- **Comentarios:** cabecera ≤ 12 líneas y ≤ 20% del archivo, y solo de lo que no
  se deduce del SQL (ver arriba).

## Validación

- **Siempre contra el Postgres local** (contenedor `sso-postgres`), **nunca**
  contra un servidor. El servidor es para diagnosticar, no para probar, y lo que
  se aplica ahí no tiene deshacer: el hook `no-prod.sh` bloquea los comandos que
  escriben en su base (los hosts están en `.claude/hooks/hosts-prod.txt`). Leer
  —`SELECT`, `\df`, `flyway info`, `pg_dump`— sigue permitido.
- `.github/scripts/check-flyway-migrations.sh` corre el historial completo sobre
  un Postgres limpio y luego reaplica lo nuevo, que es la prueba de idempotencia.

## Al cerrar

```bash
python scripts/migration-lint.py --all        # sin errores nuevos
python scripts/migration-analysis/analyze_migrations.py
python scripts/generar-mapa.py                # si cambiaron funciones o endpoints
```

El lint corre además como hook al editar cualquier `.sql` de este directorio.
Sus reglas no se silencian: si una no aplica en un caso concreto, se dice por
qué en la respuesta.
