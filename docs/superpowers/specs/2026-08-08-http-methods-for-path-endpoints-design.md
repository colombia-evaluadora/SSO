# Métodos HTTP en los endpoints por ruta

**Fecha**: 2026-08-08
**Estado**: aprobado, pendiente de plan de implementación
**Alcance**: tanda 2 de 2. La tanda 1 (namespaces y sintaxis `:VARIABLE`) está desplegada — ver `2026-08-07-query-param-namespaces-design.md`.

---

## Problema

Todo endpoint por ruta es hoy un `POST` que lee. `QueryPathController` es un único `@PostMapping("/**")`, y el registro de rutas es un `Map<pathTemplate, uuid>` que sólo apunta a filas de `QUERY`.

Eso deja dos cosas fuera:

**No se puede leer con `GET`.** Una consulta idempotente y sin cuerpo tiene que enviarse como POST, lo que impide cachearla, enlazarla o abrirla en un navegador.

**No se puede escribir por ruta.** Las escrituras existen (`POST /write` con un uuid en el cuerpo) pero viven fuera del esquema de rutas: no tienen `PATH_TEMPLATE`. Un consumidor que quiera crear o actualizar tiene que conocer un uuid, no una URL.

---

## El límite que este diseño NO cruza

Conviene dejarlo escrito porque es la restricción que ordena todo lo demás.

Hay dos caminos, separados a propósito:

- **Lectura** (`/query` y los endpoints por ruta). Ejecuta el SQL que el autor escribió en el catálogo, pero antes pasa por `rejectIfMutating`: si el SQL modifica algo, se rechaza. SQL libre, sólo lectura.
- **Escritura** (`POST /write`). **No ejecuta SQL del catálogo.** Construye el `INSERT`/`UPDATE` a partir de una tabla y unas columnas declaradas en `WriteDefinition`. `WriteType` es un enum de dos valores: `INSERT` y `UPDATE`. No hay `DELETE` ni DDL.

La garantía que sale de ahí — **nunca se ejecuta SQL de modificación escrito a mano contra la base** — es la que este diseño mantiene intacta. Por eso `DELETE` queda fuera: soportarlo obligaría a ampliar el camino de escritura o a relajar `rejectIfMutating`, y lo segundo desmonta la garantía entera. `GET`/`POST`/`PUT` encajan con lo que ya existe sin tocarla.

---

## Decisiones tomadas

| # | Decisión | Alternativas descartadas |
|---|---|---|
| 1 | Verbos soportados: `GET`, `POST`, `PUT`. `DELETE` no | Soportar DELETE — requeriría tocar el límite lectura/escritura |
| 2 | Lo que decide si un `POST` lee o crea es **la fila**, no el verbo | Que POST signifique sólo "crear" (REST estricto) — rompería todos los endpoints POST-que-leen actuales, y sus consumidores no los controlamos |
| 3 | `writeType` se deriva del método cuando la fila tiene ruta: `POST`→`INSERT`, `PUT`→`UPDATE` | Pedirlo y validar que concuerde — es el patrón que quitamos en la tanda 1: pedir un dato deducible y reñir si no acierta |
| 4 | Las variables de ruta alimentan `keyColumns`; el cuerpo alimenta `columns` | Que todo venga del cuerpo — dejaría la ruta como decoración y permitiría que cuerpo y URL se contradijeran |
| 5 | La unicidad de `(microservicio, ruta, método)` se comprueba en sso-admin | Índice único en BD — imposible: la restricción abarca dos tablas |

---

## Diseño

### A. El registro pasa a tener método y tipo de fila

Clave actual: `pathTemplate → uuid`. Nueva: `(método, pathTemplate) → (tipo, uuid)`, donde el tipo es `QUERY` o `WRITE`.

Eso es lo que hace que la decisión 2 funcione sin ambigüedad en tiempo de petición: `POST /establecimiento/:NOMBRE` apunta a una fila `QUERY` y lee; `POST /establecimiento` apunta a una fila `WRITE` e inserta. Como sólo puede existir una fila por combinación, el dispatcher no tiene nada que adivinar — mira el tipo y despacha.

Qué verbo puede apuntar a qué:

| Verbo | Tipo de fila | Efecto | Cuerpo |
|---|---|---|---|
| `GET` | `QUERY` | lee | no lleva |
| `POST` | `QUERY` | lee | opcional |
| `POST` | `WRITE` (`INSERT`) | crea | obligatorio |
| `PUT` | `WRITE` (`UPDATE`) | actualiza | obligatorio |

Un `GET` que apunte a una fila `WRITE` se rechaza al guardar, no en tiempo de petición.

### B. Esquema

`QUERY` gana `HTTP_METHOD VARCHAR(10) NOT NULL DEFAULT 'POST'`. El default preserva exactamente el comportamiento actual: toda fila existente sigue siendo un POST que lee, sin migración de datos.

`WRITE_DEFINITION` gana `PATH_TEMPLATE VARCHAR(500)` y `HTTP_METHOD VARCHAR(10)`, ambos nulables. Nulo = sólo accesible por el `POST /write` legacy, igual que hoy.

El índice único actual de `QUERY` pasa a `(MICROSERVICE_ID, PATH_TEMPLATE, HTTP_METHOD)`, y `WRITE_DEFINITION` gana el suyo equivalente. **Ninguno de los dos impide que una query y una escritura reclamen la misma combinación** — eso lo comprueba `QueryAdminService` / `WriteAdminService` consultando la otra tabla antes de guardar.

Es una garantía más débil que la de hoy: entre la comprobación y el commit hay una ventana en la que dos inserciones concurrentes podrían colar un duplicado cruzado. Se acepta porque el escenario requiere dos admins guardando la misma ruta con el mismo método en el mismo instante, y porque la alternativa —fusionar las dos tablas— es un cambio mucho mayor por un riesgo mucho menor. El síntoma, si ocurriera, sería que una de las dos filas gana el matching de forma no determinista; queda anotado como riesgo conocido.

### C. Cómo se alimenta una escritura por ruta

`WriteService` recibe hoy un mapa `columns` (columna→valor) y, para `UPDATE`, necesita además las `keyColumns`. Con ruta:

- **Las variables de la ruta alimentan las `keyColumns`.**
- **El cuerpo alimenta las `columns`.**

```
PUT /establecimiento/:ID     con body { "nombre": "X", "direccion": "Y" }

  keyColumns = id        <- de :PARAM.ID
  columns    = nombre, direccion   <- del cuerpo

  → UPDATE establecimiento SET nombre = :nombre, direccion = :direccion
    WHERE id = :id
```

Esto da una validación fuerte **al guardar**, no en producción: las variables de la plantilla deben cubrir **exactamente** las `keyColumns` de la fila. Una plantilla `/establecimiento/:ID` sobre una fila cuya key es `(id, anio)` se rechaza con un mensaje que dice qué falta. Sin esa regla, el fallo aparecería en la primera petición real como un `UPDATE` sin `WHERE` completo — o peor, como un `WHERE` que casa más filas de las que debía.

Para `POST`/`INSERT` no hay `keyColumns`, así que la plantilla no debe declarar variables: `POST /establecimiento` sí, `POST /establecimiento/:ID` no. También se comprueba al guardar.

Los nombres de las variables de ruta siguen la gramática de la tanda 1 (`:MAYÚSCULA` ASCII) y se mapean a la columna en minúscula: `:ID` → columna `id`. El mapeo es explícito y no depende de la caja porque los nombres de columna en el catálogo ya se declaran en minúscula.

### D. `GET` no lleva cuerpo

Un `GET` no puede aportar `:BODY.*`. En vez de dejar que el autor lo descubra con un bind sin valor en la primera petición, se comprueba al guardar: si la fila es `GET` y su SQL menciona `:BODY.`, se rechaza.

Es la misma idea que la derivación de la tanda 1 — mover el error del runtime al momento de guardar, donde hay un humano mirando.

### E. Dispatcher

`QueryPathController` pasa de un `@PostMapping("/**")` a tres mappings (`GET`, `POST`, `PUT`) que delegan en un único método con el verbo como parámetro. El verbo entra en la consulta al registro; el tipo de fila que devuelve decide si se llama a `QueryService` o a `WriteService`.

El `@GetMapping("/**")` no se traga los endpoints de actuator: Spring resuelve primero el handler mapping de actuator, que tiene mayor precedencia que el de controllers. Conviene un test que lo fije, porque es el tipo de cosa que un cambio de versión rompe en silencio.

### F. Gateway

No cambia. Las rutas del catálogo se registran con un predicado `Path`, sin `Method`, así que los tres verbos pasan igual. El PR #14 dejó ese camino funcionando y no hay motivo para tocarlo.

---

## Pruebas

1. `GET` por ruta devuelve filas y no acepta cuerpo.
2. `POST` sobre fila `QUERY` sigue leyendo — regresión del comportamiento actual, que es lo que la decisión 2 protege.
3. `POST` sobre fila `WRITE` inserta y devuelve `rowsAffected`.
4. `PUT` actualiza usando la variable de ruta como clave.
5. `DELETE` sobre una ruta registrada responde 405, no 404: la ruta existe, el método no se admite. Un 404 haría pensar que la URL está mal.
6. Rechazo al guardar: `GET` con SQL que usa `:BODY.`; plantilla cuyas variables no cubren las `keyColumns`; `INSERT` con variables en la plantilla; `GET` apuntando a una fila `WRITE`; ruta+método ya reclamados por la otra tabla.
7. Actuator sigue respondiendo con el `@GetMapping("/**")` registrado.

---

## Cambios con ruptura

Ninguno. `HTTP_METHOD` entra con default `POST` en `QUERY`, y nulable en `WRITE_DEFINITION`. Todo lo que funciona hoy sigue funcionando igual.

---

## Fuera de alcance

- `DELETE` — ver el límite arriba.
- `PATCH` — no aporta nada que `PUT` no cubra mientras el camino de escritura sólo sepa hacer INSERT y UPDATE sobre columnas declaradas.
- Fusionar `QUERY` y `WRITE_DEFINITION` en una sola tabla, que resolvería la unicidad en BD. Es un cambio grande para un riesgo pequeño; queda anotado por si la carrera llegara a doler.
