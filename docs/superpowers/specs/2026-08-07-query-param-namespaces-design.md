# Namespaces de parámetros y sintaxis `:VARIABLE` en path templates

**Fecha**: 2026-08-07
**Estado**: aprobado, pendiente de plan de implementación
**Alcance**: tanda 1 de 2. Los métodos HTTP (GET/PUT/DELETE) van en una tanda posterior.

---

## Problema

La definición de una query en el catálogo tiene hoy cuatro problemas distintos que se manifiestan en el mismo sitio.

**1. Los parámetros viven en un espacio plano.** Las variables de ruta (`{nombre}`), los query params, el body aplanado (`body.x.y`) y los valores inyectados del JWT (`caller_user_id`, `caller_email`, `caller_roles`, `caller_roles_array`) más `limit`/`offset` acaban todos en el mismo `Map`. Mirando una SQL no se sabe de dónde sale cada valor, ni cuál controla el que llama y cuál el sistema. Peor: pueden pisarse. Una plantilla `/algo/{limit}` machaca el `:limit` del sistema sin avisar.

**2. Los query params pisan a las variables de ruta.** En `QueryPathController` el orden es `params.putAll(match.pathVars())` y después `params.putAll(queryParams)`. Una ruta declarada puede ser secuestrada desde el query string. Se descubrió por accidente durante la sesión de depuración del 2026-08-07.

**3. Las variables de ruta no se decodifican.** `QueryPathController` lee la ruta de `HandlerMapping.PATH_WITHIN_HANDLER_MAPPING_ATTRIBUTE`, que bajo el `PathPatternParser` de Spring 6 devuelve la ruta **cruda**. El valor llega percent-encoded a la SQL.

Confirmado empíricamente contra el host de test:

| petición | resultado |
|---|---|
| `/establecimiento/PRUEBA2025` | devuelve la fila |
| `/establecimiento/PRUEBA%32%30%32%35` (mismo valor, dígitos codificados) | `{"rows":[]}` |
| `/establecimiento/PRUDENCIA%20DAZA` | `{"rows":[]}` |
| `?nombre=PRUDENCIA%20DAZA` (query param) | devuelve la fila |

El agravante: como la SQL usa `LIKE`, el `%` del encoding actúa además como comodín, así que `PRUDENCIA%20DAZA` se interpreta como `PRUDENCIA`+cualquier cosa+`20DAZA`. El fallo es silencioso — 200 con lista vacía, nunca un error. De las 47 filas de `testablecimiento`, solo `PRUEBA2025` (la única sin espacios ni acentos) es alcanzable por ruta.

**4. El formulario pide datos que el sistema ya sabe o puede deducir.**

- **"Modo de ejecución"**: `SELECT` y `FUNCTION` son indistinguibles en el código. `QueryService` los trata con el mismo `if` (`"SELECT".equals(mode) || "FUNCTION".equals(mode)`, líneas 158 y 242) y la validación al guardar exige a ambos que la SQL empiece por `SELECT`. `FUNCTION` no cambia ni cómo se valida ni cómo se ejecuta. El único modo con comportamiento propio es `PROCEDURE`, y se deduce del primer keyword — de hecho `validateExecutionModePrefix` ya comprueba esa correspondencia en vez de derivarla.
- **"Tipo"**: la ayuda del formulario dice *"Etiqueta opcional (QUERY, CHART, …)"* y **es falsa**. `QUERY.TYPE` se usa en runtime como clave de dialecto para elegir el `NamedParameterJdbcTemplate` (`JdbcTemplateRegistry.resolve`) y como clave de bulkhead (`resilience.bulkheadFor`). Escribir "CHART" produce un 502 *"El dialecto 'chart' no está configurado"* la primera vez que se invoca la query. Además el dato es redundante: el microservicio dueño ya declara su `dialect`.

---

## Decisiones tomadas

| # | Decisión | Alternativas descartadas |
|---|---|---|
| 1 | Los nombres de variable van en MAYÚSCULA, tanto en la ruta como en la SQL | Case-insensitive en el binder; inyectar ambas cajas. Ambas dejan la regla en decorativa y añaden una norma oculta |
| 2 | La caja del **valor** no se toca: la maneja la SQL del autor (`UPPER()`, `ILIKE`) | Forzar mayúscula en el framework — corrompería emails, códigos, UUIDs |
| 3 | Corte limpio: solo `:MAYÚSCULA`, con migración de los datos existentes | Aceptar ambas sintaxis (perpetúa la ambigüedad); corte sin migrar (rompe en silencio) |
| 4 | Cuatro namespaces: `PARAM`, `QUERY`, `BODY`, `CONTEXT`. Sin excepciones | Path desnudo (`:NOMBRE`) — se descartó por coherencia, aun a costa de la alineación literal URL↔SQL |
| 5 | Se elimina la reescritura automática de SQL; el `LIMIT` lo escribe el autor | Mantener la concatenación leyendo query params — el SQL ejecutado seguiría sin ser el que se ve |
| 6 | Métodos HTTP fuera de alcance | Meterlo todo junto — arrastra una decisión de seguridad sobre el límite lectura/escritura |

---

## Diseño

### A. Namespaces de parámetros

Cuatro orígenes, cuatro prefijos obligatorios, todos en MAYÚSCULA:

| Prefijo | Origen | Ejemplo | Lo controla |
|---|---|---|---|
| `:PARAM.*` | variables de la ruta | `:PARAM.NOMBRE` | quien llama |
| `:QUERY.*` | query string | `:QUERY.SIZE` | quien llama |
| `:BODY.*` | cuerpo JSON, anidado con puntos | `:BODY.FILTROS.ZONA` | quien llama |
| `:CONTEXT.*` | derivado del JWT | `:CONTEXT.USER_ID` | el sistema |

Renombrado del contexto:

| Antes | Después |
|---|---|
| `caller_user_id` | `CONTEXT.USER_ID` |
| `caller_email` | `CONTEXT.EMAIL` |
| `caller_roles` (CSV) | `CONTEXT.ROLES` |
| `caller_roles_array` (array PG) | `CONTEXT.ROLES_ARRAY` |

**Por qué namespaces y no solo mayúsculas.** Las colisiones pasan de "improbables porque acordamos una convención" a **estructuralmente imposibles**: `PARAM` y `QUERY` no pueden pisarse porque no comparten espacio de nombres. Eso elimina el problema 2 sin necesidad de decidir una precedencia. Y de un vistazo se distingue lo que el llamante controla (`PARAM`/`QUERY`/`BODY`) de lo que no (`CONTEXT`) — que es exactamente la distinción que importa para razonar sobre seguridad.

**Normalización de claves.** Las claves de `QUERY` y `BODY` las envía el llamante, así que el nombre del binding se deriva pasando la clave a mayúscula: `?estado=activo` → `:QUERY.ESTADO`; `{"filtros":{"zona":1}}` → `:BODY.FILTROS.ZONA`. Si dos claves solo se diferencian por la caja (`?estado=a&ESTADO=b`), se responde **400 explícito**. Nunca una pisa a la otra en silencio.

Este es el mismo criterio de la decisión 2 aplicado a nombres en vez de valores: se normaliza el **nombre** (que es identificador) y jamás el **valor** (que es dato).

**Sin reescritura de SQL.** Desaparece la concatenación de `" LIMIT :limit"` / `" OFFSET :offset"` de `QueryService`. La paginación la escribe el autor con `:QUERY.*`. Los campos `limit`/`offset` del DTO `QueryRequest` dejan de inyectar parámetros.

Verificado: ningún cliente los usa hoy — ni el admin-ui ni ningún consumidor conocido. Solo existen como campos del record.

**El endpoint legacy `POST /query` no se namespacea.** Ese camino recibe un mapa `params` explícito en el body y lo pasa tal cual al binder; sus nombres los elige quien llama en cada invocación, no hay un "origen" que prefijar. Las filas que hoy se invocan así (`:categoria` en la query 8, `:sede` en la query 10) siguen funcionando sin tocar nada.

Lo único que sí les cambia es `CONTEXT.*`: la inyección desde el JWT es común a los dos caminos, así que una SQL legacy que usara `:caller_user_id` habría que migrarla. Ninguna lo hace hoy.

Consecuencia a aceptar: una misma SQL invocada por los dos caminos necesita que los nombres coincidan. Si una query tiene `PATH_TEMPLATE` y además se llama por `/query`, el llamante legacy debe mandar `params: { "PARAM.NOMBRE": "x" }`. Es una arista rara y aceptable — el camino legacy existe para compatibilidad, no para uso nuevo.

### B. Sintaxis de ruta y matching

Plantilla: `/establecimiento/:NOMBRE`. Variable = `:` seguido de `[A-Z][A-Z0-9_]*`.

Se rechaza al guardar, con mensaje que explique el porqué:
- la sintaxis vieja `{}`
- minúsculas en el nombre de variable
- `**` (ya existía)
- una plantilla sin `microserviceId` (ya existía)
- duplicado dentro del mismo microservicio (ya existía)

**Matcher**: se sustituye `AntPathMatcher` por `PathPatternParser` en `QueryPathRegistry`. El registry traduce `:NOMBRE` → `{NOMBRE}` al cargar en memoria; es un único punto de traducción, invisible desde fuera. `matchAndExtract` devuelve las variables **ya decodificadas**, que es lo que resuelve el problema 3 de raíz en vez de con un paso manual que alguien pueda olvidar.

Se decodifica la variable extraída, **no la ruta completa antes de matchear**: si se decodificara antes, un `%2F` dentro de un valor inyectaría segmentos de ruta y podría hacer casar una plantilla que no corresponde.

`PathPatternParser` es además la API que usa el propio Spring MVC; `AntPathMatcher` está en retirada para matching de peticiones (el mismo cambio ya obligó a tocar `JsonLoginFilter` en la migración a Spring Security 7).

### C. Simplificación del formulario

**"Modo de ejecución"** se elimina como campo editable. Se deriva al guardar del primer keyword de la SQL, ignorando espacios y comentarios `--` iniciales (misma lógica que ya usa `validateExecutionModePrefix`):

- `CALL` → `PROCEDURE`
- `SELECT` / `WITH` → `SELECT`
- cualquier otra cosa → error al guardar

La columna `EXECUTION_MODE` **se mantiene en BD** con el valor derivado, de modo que `query-service` no cambia. `FUNCTION` se retira como opción: no aporta comportamiento y sí confusión. Las filas existentes con `FUNCTION` se migran a `SELECT` (equivalente exacto).

**"Tipo"** se elimina como campo editable. Al guardar, `type = microservicio.dialect`. Las queries sin microservicio conservan el comportamiento actual (`null` → `postgres` en `JdbcTemplateRegistry.resolve`).

Ambos se muestran en la UI como texto derivado no editable ("Modo: SELECT · Dialecto: postgres"), para que siga siendo visible qué se guardó sin poder equivocarse.

### D. Migración

Una migración Flyway que, para cada fila con `PATH_TEMPLATE` no nulo:

1. Reescribe la plantilla: `{nombre}` → `:NOMBRE`.
2. Reescribe en su SQL **únicamente** los binds cuyo nombre corresponde a una variable de esa plantilla: `:nombre` → `:PARAM.NOMBRE`.
3. Normaliza `EXECUTION_MODE = 'FUNCTION'` → `'SELECT'`.
4. Rellena `TYPE` desde el `dialect` del microservicio cuando esté vacío.

Y para todas las filas, con o sin plantilla: `:caller_user_id`→`:CONTEXT.USER_ID`, `:caller_email`→`:CONTEXT.EMAIL`, `:caller_roles_array`→`:CONTEXT.ROLES_ARRAY`, `:caller_roles`→`:CONTEXT.ROLES` (el orden importa: `ROLES_ARRAY` antes que `ROLES`, o el prefijo común corrompe el nombre largo).

**Estado verificado del catálogo el 2026-08-07** (5 filas): usan `:nombre`, `:categoria`, `:sede`; ninguna usa `:caller_*`, `:limit`, `:offset` ni `:body.*`. Solo la fila 5 (`0cc92e1e-…`) tiene `PATH_TEMPLATE`. El coste real de la migración hoy es una fila. Ese es el argumento para hacerlo ahora.

**Riesgo asumido**: la reescritura de binds es textual y podría tocar un `:nombre` que apareciese dentro de un literal de cadena en la SQL. Ninguna de las filas actuales tiene ese caso. Si el catálogo creciera antes de aplicar esto, hay que revisar a mano.

---

## Pruebas

Obligatorias, porque cubren huecos reales:

1. **Bindear un parámetro con punto en una SQL real.** El esquema entero descansa en que `:CONTEXT.USER_ID` se parsea como un solo nombre. Es cierto — el parser de Spring no trata `.` como separador — pero **la suite actual nunca lo comprueba**. El único test que roza el tema lo admite en su comentario: *"even though our query doesn't use that placeholder, the flatten works"*. Deja de ser suposición.
2. **Valor de ruta con espacios y con acentos**, como regresión del problema 3.
3. **Rechazo al guardar** de `{}`, de minúsculas y de `**`.
4. **400 por colisión de caja** en query params y en claves de body.
5. **Derivación del modo** (`CALL`→PROCEDURE, `SELECT`/`WITH`→SELECT, otro→error) y **herencia del dialecto**.
6. **`%2F` codificado dentro de un valor** no inyecta segmentos de ruta.

---

## Cambios con ruptura

- Toda SQL que use `:caller_*`, `:limit`, `:offset` o `:body.*` deja de funcionar sin migrar.
- Toda `PATH_TEMPLATE` con `{}` deja de resolver.
- Los clientes que envíen `limit`/`offset` en el body de `/query` dejan de paginar (nadie lo hace hoy).
- `FUNCTION` desaparece como modo seleccionable.

---

## Fuera de alcance

- **Métodos HTTP** — tanda 2. Requiere que la clave del registro pase de `path` a `(método, path)` y el índice único a `(microservice_id, path_template, http_method)`.

  **Decidido el 2026-08-07, pendiente de diseñar en detalle:**

  | Verbo | Puede apuntar a | Efecto |
  |---|---|---|
  | `GET` | fila con SQL | lee, sin cuerpo |
  | `POST` | fila con SQL **o** fila de escritura | lee o inserta |
  | `PUT` | fila de escritura | actualiza |
  | `DELETE` | — | **no se soporta** |

  Lo que decide si un `POST` lee o crea **no es el verbo, es la fila**: una fila con SQL lee, una con tabla+columnas escribe. Como sólo puede haber una fila por `(método, ruta)`, no hay ambigüedad que resolver en tiempo de petición.

  **Por qué DELETE queda fuera.** Los endpoints por ruta van hoy al camino de **lectura**, que rechaza SQL mutante (`rejectIfMutating`). El camino de **escritura** (`POST /write`) no ejecuta SQL del catálogo: genera `INSERT`/`UPDATE` a partir de una tabla y columnas declaradas, y `DELETE`/DDL están prohibidos por diseño. Un `DELETE /x/:ID` no podría borrar nada sin una de dos cosas: ampliar el camino de escritura para que sepa borrar, o relajar `rejectIfMutating` — y lo segundo desmontaría la garantía de que nunca se ejecuta SQL de modificación escrito a mano contra la base. Al dejar DELETE fuera, esa garantía se mantiene intacta y GET/POST/PUT encajan con lo que ya existe.
- Cambiar la semántica de `LIKE` o añadir búsqueda insensible a mayúsculas por defecto — queda en manos de cada autor (decisión 2).

---

## Nota de verificación

El diseño se apoya en comprobaciones hechas contra el host de test el 2026-08-07 (encoding de rutas, contenido del catálogo, comportamiento de `TYPE` y de los modos de ejecución). La máquina de desarrollo donde se redactó **no tiene Maven ni Docker**, así que la implementación no podrá compilarse ni probarse en local: la validación será CI más verificación contra el servidor, igual que los PRs #11 y #12 de esa misma fecha.
