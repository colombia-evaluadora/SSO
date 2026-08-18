# Mensajes de error PL/pgSQL: análisis y depuración antes de cruzar el cable

Fecha: 2026-08-18
Alcance: cómo nacen los mensajes de error en las funciones PL/pgSQL de `postgres/migrations/`, qué información de esquema llegaba al cliente a través de `query-service`, `auth-center` y `file-service`, y qué se cambió para evitarlo.

---

## 1. Las cuatro familias de mensaje

Se relevaron las **296 sentencias `RAISE EXCEPTION` distintas** en `postgres/migrations/*.sql`. Se agrupan según qué tan publicable es su texto:

### A. Mensajes de negocio con nombres de tabla incrustados
La mayoría de las funciones nuevas redacta en español natural, pero las heredadas del esquema legado insertan el nombre físico de la tabla o de la FK en el propio texto:

```sql
RAISE EXCEPTION 'No existe TESTABLECIMIENTO con PK_ESTABLECIMIENTO = %', p_pk_establecimiento
RAISE EXCEPTION 'FK_TLV_ZONA (%) no existe o no esta activa en TLISTA_VALOR', ...
RAISE EXCEPTION 'archivo (%) no existe o no esta activo en TARCHIVO', p_fk_tarchivo
```

Tokens que aparecían crudos en respuestas HTTP: `TESTABLECIMIENTO`, `TSEDE`, `TSEDE_USUARIO`, `TFUNCIONARIO`, `TARCHIVO`, `TMUNICIPIO`, `TLISTA_VALOR`, `TUSUARIO`, `TROL`, `TMENU`, `TPLAN`, `TDISCAPACIDAD`, `TPROPIEDAD_JURIDICA`, más cualquier `FK_*`/`PK_*`. Es la firma del modelo relacional.

### B. Mensajes con prefijo del nombre de la función
Todo el grupo de roles y menús (`fn_add_trol`, `fn_associate_menus_to_rol`, `fn_create_parent_menu_with_submenus`, `fn_assert_superadmin`, …) usa `RAISE EXCEPTION 'fn_xxx: detalle'`. Sirve para grepear logs; no para publicar el nombre del procedimiento almacenado.

### C. Errores nativos del motor
Violaciones de `UNIQUE`, `NOT NULL` o `FOREIGN KEY`. Aquí el mensaje **no lo escribe nadie del equipo**: lo arma Postgres con nombre de constraint, tabla, columna y —en `unique_violation`— los valores que colisionaron:

```
ERROR: duplicate key value violates unique constraint "ux_tusuario_correo_electronico"
  Detail: Key (correo_electronico)=(juan.perez@colegio.edu.co) already exists.
```

La categoría más grave: no sólo revela estructura, revela **un dato personal de un tercero** en el cuerpo de la respuesta.

### D. Errores de sintaxis u objeto inexistente
`42601`, `42703`, `42P01`. Bugs de quien escribió una fila del catálogo o una migración. El mensaje nombra tablas y columnas reales.

---

## 2. La pieza que faltaba: los campos ya venían separados

El driver `org.postgresql` expone `PSQLException.getServerErrorMessage()`, que devuelve un `ServerErrorMessage` con **MESSAGE, DETAIL, HINT, TABLE, COLUMN, CONSTRAINT y SCHEMA por separado**.

No había un solo uso en el repositorio. Todo el código llamaba a `SQLException.getMessage()`, que entrega esos campos **ya concatenados** — por eso era imposible separar lo publicable del diagnóstico interno: el DETAIL con el valor real viajaba pegado al mensaje.

---

## 3. Estado previo por servicio

**`query-service`** — `PostgresErrorMapper` ya mapeaba SQLState → status correctamente, pero su "depuración" se limitaba a recortar a 500 caracteres y enmascarar URLs `jdbc:`. Los nombres de tabla de las categorías A/B pasaban intactos; el `Detail` de la C, también; y la rama genérica `42xxx` devolvía el mensaje crudo del motor con un 500.

**`auth-center`** — fallaba en las dos direcciones a la vez:
- Para `23xxx` reenviaba `sql.getMessage()` completo al campo `message` de la respuesta. Un registro con correo duplicado devolvía el correo del otro funcionario.
- Para `P0001`/`P0002`/`42501` no había handler: Spring no los envuelve en `DataIntegrityViolationException`, así que caían en la caza-todo y se perdían por completo tras un `"Ocurrió un error inesperado"` con 500 — justo los mensajes que el autor de la función sí quiso comunicar.

**`file-service`** — no filtraba esquema por los endpoints de reenvío (delega por HTTP), pero sí ejecuta SQL directo sobre `tarchivo` desde `ArchivoRepository`, y todo lo que no fuera multipart demasiado grande o subida fallida caía en un 500 genérico.

---

## 4. Lo implementado

### `common` — `SqlErrorSanitizer` + `SqlErrorKind`

`common/src/main/java/com/co/eurekatic/common/error/`. Sin dependencias de framework web, para que lo consuman los tres servicios y cada uno decida su propio status.

Dos decisiones sostienen el resto:

**1. Se leen los campos estructurados.** Si la excepción es una `PSQLException`, el texto público sale de `ServerErrorMessage.getMessage()` — sólo MESSAGE. Sin driver PG a mano (H2 en tests, envoltorios), se corta en el primer salto de línea, que es donde el servidor arranca `Detail:` y `Hint:`.

**2. El SQLState no basta para decidir si el mensaje es reenviable.** Éste fue el hallazgo que cambió el diseño respecto de la propuesta inicial: las funciones del esquema levantan `RAISE EXCEPTION ... USING ERRCODE = '23503'` (y `23505`, `23502`, `22023`) con texto de negocio escrito a mano, **indistinguible por código** de la violación que emite el motor. Descartar todo `23xxx` habría tirado cientos de mensajes buenos.

El discriminador es que el motor puebla `constraint`/`table` en la respuesta y `RAISE EXCEPTION` no:

| Origen | `constraint`/`table` | Qué se publica |
|---|---|---|
| Motor | poblados | Texto genérico por `SqlErrorKind` |
| `RAISE EXCEPTION` del autor | nulos | Su mensaje, con los identificadores redactados |

La redacción sustituye, en este orden: prefijo `fn_xxx:`, esquema calificado (`academico_test.`), columnas `FK_*`/`PK_*` → término de negocio, nombres de tabla del diccionario → término de negocio, y una red de seguridad `T[A-Z]{4,}` → `registro` para tablas que aún no estén en el diccionario.

Cubierto por `SqlErrorSanitizerTest` (16 casos), con fixtures copiados literalmente de las migraciones y de la salida real del motor.

### Integración en los tres servicios

- **`query-service`** — `PostgresErrorMapper` delega en el sanitizador. **Los status HTTP no cambian** (`23xxx`→409, `22xxx`→400, `P0001`→400, `P0002`→404, `42501`→403): lo que cambia es el texto, no el contrato que ya consume el admin-ui. El mensaje sin depurar sigue existiendo en el log del servidor, que es donde el operador necesita el nombre real de la constraint.
- **`auth-center`** — `handleDataIntegrity` se reemplaza por `handleDataAccess` sobre `DataAccessException`, que cubre también los `RAISE EXCEPTION` que antes se perdían, más un handler para `SQLException` suelta. Se conservan los status que ya publicaba (`23503`/`22023`→422, `23502`→400, `23505`→409) y los códigos (`DUPLICATE`, `FK_NOT_FOUND`, `VALIDATION_REQUIRED`, …) para no romper clientes; `P0002` pasa a 404 y `P0001` a 400, que antes eran 500.
- **`file-service`** — mismo sanitizador para los fallos de `tarchivo`, más ramas nuevas para multipart mal formado (400 en vez de 500), parámetro faltante (400), destino que no responde (504) y destino que responde mal (502).

---

## 5. Convención para las funciones nuevas

`RAISE EXCEPTION` admite separar el mensaje del detalle técnico:

```sql
RAISE EXCEPTION 'No existe la sede indicada'
    USING ERRCODE = 'P0002',
          DETAIL  = 'TSEDE.PK_TSEDE = ' || p_pk_sede;
```

Así el MESSAGE queda limpio **por construcción** —sin depender del diccionario de reemplazo— y el DETAIL queda disponible sólo para el log del operador.

No hace falta reescribir las 296 sentencias existentes: el sanitizador cubre la brecha. La convención aplica a funciones nuevas, y las existentes se pueden migrar cuando se toquen por otro motivo.

---

## 6. Qué queda fuera

- El diccionario de tablas cubre los nombres legados que aparecen hoy en los mensajes. Una tabla nueva `T*` cae en la red de seguridad como `registro`; si conviene un término mejor, se agrega una entrada en `SqlErrorSanitizer.TABLE_TERMS`.
- `PostgresErrorMappingIntegrationTest` sigue `@Disabled`: asume semántica de SQLState que H2 no reproduce. Necesita Testcontainers con un Postgres real para ser significativo; la lógica de depuración sí está cubierta por los tests unitarios de `common`.
