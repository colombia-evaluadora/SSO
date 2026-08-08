# Métodos HTTP en los endpoints por ruta

**Fecha**: 2026-08-08
**Estado**: aprobado, pendiente de plan de implementación
**Alcance**: tanda 2 de 2. La tanda 1 (namespaces y sintaxis `:VARIABLE`) está desplegada — ver `2026-08-07-query-param-namespaces-design.md`.

---

## Problema

Todo endpoint por ruta es hoy un `POST`. `QueryPathController` es un único `@PostMapping("/**")` y el registro de rutas es un `Map<pathTemplate, uuid>`, sin noción de método.

Eso impide dos cosas:

**Leer con `GET`.** Una consulta idempotente y sin cuerpo tiene que enviarse como POST, así que no se puede cachear, enlazar ni abrir en un navegador.

**Expresar la intención en la URL.** Crear y actualizar se ven exactamente igual que leer desde fuera: todo es POST a una ruta. El consumidor no puede deducir qué hace un endpoint sin leer el catálogo.

---

## El malentendido que este spec corrigió

La primera versión de este documento diseñaba un aparato considerable para las escrituras: `PATH_TEMPLATE` en `WRITE_DEFINITION`, las variables de ruta alimentando `keyColumns`, `writeType` derivado del método, y unicidad cruzada entre dos tablas.

**Todo eso sobraba**, y conviene dejar escrito por qué para que nadie lo reintroduzca.

Partía de asumir que una escritura por ruta tendría que ir por `WriteService` (tabla + columnas declaradas), porque el camino de lectura rechaza SQL mutante. Pero el guardia es más estrecho de lo que parece:

```java
if ("SELECT".equals(mode) || "FUNCTION".equals(mode)) {
    rejectIfMutating(def.query());     // ← sólo en este brazo
} else if (!"PROCEDURE".equals(mode)) {
    throw ... "Unknown executionMode"
}

static void rejectIfMutating(String sql) {
    String first = ... primer keyword ...
    if (!first.equals("SELECT") && !first.equals("WITH")) { throw 400; }
}
```

Dos consecuencias:

1. **El modo `PROCEDURE` no pasa por el guardia.** Un `CALL paquete.actualizar_x(...)` se ejecuta verbatim, y el procedimiento hace lo que tenga que hacer.
2. **El guardia sólo mira el primer keyword.** Una función invocada como `SELECT * FROM paquete.func(...)` lo atraviesa sin problema, module lo que module.

O sea que el guardia bloquea únicamente un `UPDATE`/`INSERT`/`DELETE` escrito literalmente a pelo en el campo SQL. **Paquetes, procedimientos y funciones —que es como se consume esta base— ya funcionan hoy.**

Y la propiedad de seguridad resultante es mejor que cualquier alternativa que se barajó: **el DBA decide qué hace cada paquete; el autor del catálogo sólo puede invocarlo.** No hace falta relajar el guardia ni construir un segundo camino de escritura. La superficie de lo que un admin del catálogo puede ejecutar contra la base sigue siendo la que el DBA haya publicado.

---

## Decisiones tomadas

| # | Decisión | Alternativas descartadas |
|---|---|---|
| 1 | Verbos soportados: `GET`, `POST`, `PUT`. `DELETE` no | Soportarlo — ver abajo |
| 2 | Los tres verbos despachan al mismo camino. Lo que la fila hace lo decide su SQL | Enrutar las escrituras por `WriteService` — innecesario: los procedimientos ya pasan |
| 3 | El campo SQL acepta `INSERT`/`UPDATE` directo, en filas atadas a `POST` o `PUT` | Obligar a paquetes o a filas tabla+columnas — decisión del dueño del sistema, tomada el 2026-08-08 |
| 4 | El permiso se ata al **modo derivado**, no al método | Relajar `rejectIfMutating` para POST/PUT — con default `POST`, dejaría sin guardia a todas las filas existentes de golpe |
| 5 | `HTTP_METHOD` entra con default `POST` | Migrar filas — innecesario, el default preserva el comportamiento actual |

### Cómo se concede el permiso de escribir sin desproteger lo existente

Relajar `rejectIfMutating` "cuando el método es POST o PUT" parece lo directo, y es una trampa: `HTTP_METHOD` entra con default `POST`, así que **todas las filas que existen hoy pasarían a admitir SQL mutante en el mismo despliegue**. Un cambio de configuración se convertiría en una ampliación silenciosa de privilegios sobre 5 filas que nadie tocó.

En su lugar se extiende la derivación de modo de la tanda 1, que ya lee el primer keyword:

| Primer keyword | Modo derivado | ¿Pasa por `rejectIfMutating`? |
|---|---|---|
| `SELECT` / `WITH` | `SELECT` | sí — igual que hoy |
| `CALL` | `PROCEDURE` | no — igual que hoy |
| `INSERT` / `UPDATE` | `DML` (nuevo) | no, y **exige** método `POST` o `PUT` |
| cualquier otro | — | rechazado al guardar |

Con esto, una fila `SELECT` sigue tan protegida como hoy y el permiso alcanza únicamente a las filas donde el autor escribió DML deliberadamente. `rejectIfMutating` no se relaja: sigue aplicándose íntegro en su brazo.

El último renglón mantiene el DDL fuera del sistema. `DELETE`, `DROP`, `ALTER`, `TRUNCATE` y `GRANT` se rechazan al guardar, que es la misma línea que ya traza `WriteService` (su enum sólo admite `INSERT` y `UPDATE`, nunca DDL).

**Por qué `DELETE` sigue fuera.** No por un impedimento técnico —un `CALL paquete.borrar_x(...)` funcionaría igual que cualquier otro procedimiento— sino porque es lo que se decidió: mantener el verbo fuera evita que la URL sugiera un borrado directo sobre tablas. Si más adelante hace falta, el trabajo es añadirlo a la lista de verbos válidos y nada más.

---

## Diseño

### A. El registro pasa a tener método

Clave actual: `pathTemplate → uuid`. Nueva: `(método, pathTemplate) → uuid`.

Eso permite que `GET /establecimiento/:NOMBRE` y `PUT /establecimiento/:ID` sean filas distintas, y que la misma ruta sirva propósitos distintos según el verbo.

`QueryPathRegistry.match` recibe el verbo además de la ruta. `matchTemplate` no cambia — la gramática y la decodificación son las mismas.

### B. Esquema

`QUERY` gana:

```sql
HTTP_METHOD VARCHAR(10) NOT NULL DEFAULT 'POST'
```

El default preserva exactamente el comportamiento actual: toda fila existente sigue siendo un POST, sin migrar datos y sin cambios con ruptura.

El índice único pasa de `(MICROSERVICE_ID, PATH_TEMPLATE)` a `(MICROSERVICE_ID, PATH_TEMPLATE, HTTP_METHOD)`, que es lo que permite tener la misma ruta con dos verbos.

Valores admitidos: `GET`, `POST`, `PUT`. Se valida al guardar; la BD lleva un `CHECK` como última línea.

### C. Dispatcher

`QueryPathController` pasa de un `@PostMapping("/**")` a tres mappings que delegan en un único método privado con el verbo como parámetro:

```java
@GetMapping("/**")  → dispatch(request, "GET",  queryParams, null)
@PostMapping("/**") → dispatch(request, "POST", queryParams, body)
@PutMapping("/**")  → dispatch(request, "PUT",  queryParams, body)
```

`GET` no recibe cuerpo, así que no aporta `:BODY.*`. El resto del flujo es idéntico: se resuelve la fila, se arman los parámetros con sus namespaces y se ejecuta.

Una ruta registrada a la que se llama con un verbo que no tiene fila responde **405**, no 404: la URL existe, lo que no se admite es el método. Un 404 haría pensar que la ruta está mal escrita.

`DELETE` no tiene mapping, así que Spring responde 405 por sí solo.

El `@GetMapping("/**")` no se traga los endpoints de actuator: su handler mapping tiene mayor precedencia que el de los controllers. Conviene un test que lo fije, porque es de las cosas que un cambio de versión rompe en silencio.

### D. Ejecución de una fila `DML`

Una fila `SELECT` o `PROCEDURE` se ejecuta con `jdbc.query(...)` y devuelve filas. Una fila `DML` no devuelve filas: se ejecuta con `jdbc.update(...)` y la respuesta es

```json
{ "rowsAffected": 1 }
```

`INSERT … RETURNING` queda fuera de alcance: `update()` ejecuta la sentencia pero descarta las filas devueltas. Detectar `RETURNING` a base de buscar la palabra en el texto sería una heurística que falla en cuanto aparezca dentro de un literal de cadena, y prefiero una regla predecible a una que acierta el 95% de las veces. Quien necesite recuperar la fila insertada tiene dos caminos que ya funcionan: una función del paquete invocada con `SELECT`, o un procedimiento con OUT params.

### E. Validación al guardar

- El método debe ser `GET`, `POST` o `PUT`.
- El primer keyword del SQL debe ser `SELECT`, `WITH`, `CALL`, `INSERT` o `UPDATE`. Cualquier otro —`DELETE`, `DROP`, `ALTER`, `TRUNCATE`, `GRANT`…— se rechaza con un mensaje que dice qué se admite.
- Una fila `DML` atada a `GET` se rechaza: un GET no debe modificar nada, y además no lleva cuerpo del que sacar los valores.
- Un `GET` cuyo SQL mencione `:BODY.` se rechaza: ese bind nunca tendría valor. Mismo criterio que la derivación de la tanda 1 — mover el error al momento de guardar, donde hay un humano mirando, en vez de a la primera petición real.
- La unicidad `(microservicio, ruta, método)` la sigue garantizando el índice de BD, igual que hoy.

### E. Formulario

Un desplegable con `GET`, `POST`, `PUT`, por defecto `POST`. Junto al campo de plantilla, porque solo tiene sentido cuando hay ruta.

### F. Gateway

No cambia. Las rutas del catálogo se registran con un predicado `Path` sin `Method`, así que los tres verbos pasan igual.

---

## Pruebas

1. `GET` por ruta devuelve filas.
2. `POST` sobre una fila existente sigue leyendo — regresión de lo que hay hoy en producción.
3. `PUT` sobre una fila con `CALL paquete.proc(...)` ejecuta el procedimiento.
4. La misma ruta con dos verbos resuelve a filas distintas.
5. Verbo sin fila registrada para esa ruta → 405.
6. `DELETE` → 405.
7. Rechazo al guardar: método inválido; `GET` con `:BODY.` en el SQL.
8. Actuator sigue respondiendo con el `@GetMapping("/**")` registrado.

---

## Cambios con ruptura

Ninguno. `HTTP_METHOD` entra con default `POST`.

---

## Fuera de alcance

- `DELETE` y `PATCH` — se pueden añadir después con solo ampliar la lista de verbos válidos, si hace falta.
- Tocar `rejectIfMutating` o el camino de `WriteService`. Ninguno de los dos hace falta para esto.
