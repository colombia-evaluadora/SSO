# Subir archivos a un query — flujo completo

Cómo pasarle una foto (o cualquier binario) a un endpoint de `query-service`
para que la procese bien, de punta a punta: qué manda el cliente, qué hace
`file-service` en el medio, y qué le llega finalmente al SQL.

No hay endpoint separado para "subir archivos" — es el mismo
`POST /files/<microservicio>/<ruta>` de siempre. Lo nuevo es **declarar, en
el catálogo, qué campo del cuerpo es un archivo** (tipo `FILE` en
`param_types`), configurable desde `/admin/query-catalog`. Sin esa
declaración, `file-service` sigue aceptando cualquier campo binario tal
como lo hacía antes (comportamiento legacy, sin romper nada existente).

---

## 1. El viaje de la petición

```
Cliente                file-service              api-gateway         query-service-<svc>
  │                          │                         │                     │
  │ POST /api/files/eval-col/prueba-file-ui             │                     │
  │ multipart: foto=<jpg>, nombre="Juan"                │                     │
  ├─────────────────────────>│                         │                     │
  │                          │ 1. Verifica JWT (firma)  │                     │
  │                          │ 2. role_endpoint: ¿puede subir? │              │
  │                          │ 3. resolverDestino: ¿existe la ruta? │         │
  │                          │ 4. ¿"foto" está declarado FILE?     │         │
  │                          │ 5. Sube a S3, reserva TARCHIVO(inactive) │     │
  │                          │ 6. foto=<jpg>  →  foto: 17 (pk_tarchivo) │     │
  │                          │                         │                     │
  │                          │ POST /api/eval-col/prueba-file-ui           │
  │                          │ JSON: {"nombre":"Juan","foto":17}           │
  │                          │ Authorization: <mismo JWT del cliente>      │
  │                          ├────────────────────────>│                     │
  │                          │                         │ enruta /eval-col/** │
  │                          │                         ├────────────────────>│
  │                          │                         │  7. QueryPathRegistry resuelve
  │                          │                         │     path_template → uuid
  │                          │                         │  8. ParamBinder: BODY.FOTO
  │                          │                         │     (declarado FILE) → BIGINT
  │                          │                         │  9. Ejecuta el SQL
  │                          │                         │<────────────────────┤
  │                          │<────────────────────────┤   200 {"rows":[...]}│
  │                          │ 10. 2xx → archivos.activar([17])            │
  │<─────────────────────────┤                         │                     │
  │   200 (la respuesta del query, tal cual)            │                     │
```

## 2. Ejemplo real

```bash
curl -X POST "https://<host>/api/files/eval-col/prueba-file-ui" \
  -H "Authorization: Bearer $TOKEN" \
  -F "nombre=Juan Pérez" \
  -F "foto=@foto.jpg;type=image/jpeg"
```

Con el catálogo configurado como en la sección 4, la respuesta es la del
propio query:

```json
{ "rows": [{ "archivo_id": 17 }] }
```

**El nombre del campo multipart tiene que ser exactamente el que aparece
después de `BODY.` en `param_types`.** Si el catálogo declaró
`"BODY.FOTO": "FILE"`, el campo se llama `foto` (minúscula: la mayúscula
del catálogo es la forma canónica del placeholder, no el nombre literal
que manda el cliente — ver `ParamNamespace.canonicalKeyFor`). `usuario.foto`
en el multipart (con punto, para anidar) mapea a `BODY.USUARIO.FOTO`.

## 3. Los cinco chequeos de `file-service` — en orden, cada uno más caro

Antes de que exista un endpoint dedicado a esto, cualquier cliente
autenticado podía apuntar `file-service` a **cualquier** ruta inventada:
subía bytes reales a S3 y reservaba una fila en `TARCHIVO` aunque el
reenvío terminara en 404. Estos chequeos cierran eso — ver
[`ReenvioController.reenviar`](../file-service/src/main/java/com/co/eurekatic/files/ReenvioController.java).

| # | Qué valida | Falla con | Se ejecuta en |
|---|---|---|---|
| 1 | JWT verificado de verdad (firma + expiración, no sólo decodificado) | `401` | `ReenvioController.principalDe` |
| 2 | El rol del caller tiene binding `role_endpoint` para `POST`/`PUT /files/**` | `403` | `FileDestinationAccessService.puedeSubir` |
| 3 | El destino (`/eval-col/prueba-file-ui`) existe como `endpoint` REST estático **o** `query.path_template` | `404` | `FileDestinationAccessService.resolverDestino` |
| 4 | Si esa query declaró `param_types`: cada campo binario del multipart mapea a un placeholder `BODY.*` tipado `FILE` | `400` — *"El campo 'X' no está declarado como archivo para esta ruta"* | `ReenvioController.reenviar` |
| 5 | Todo placeholder `FILE!` (obligatorio) llegó con archivo | `400` — *"Falta el archivo obligatorio 'BODY.X'"* | `ReenvioController.reenviar` |

Sólo si las cinco pasan se llama a `TransformadorMultipart.transformar(...)`
— ahí recién se sube a S3 y se reserva la fila.

**Importante:** el chequeo 4 sólo aplica si la query tiene `param_types`
no vacío. Una query sin tipar (legacy, o un destino de `endpoint` que no
tiene esa columna) sigue aceptando cualquier campo binario, exactamente
como antes de que existiera el tipo `FILE` — no rompe nada existente al
desplegarse.

## 4. Configurar el campo-archivo — desde `/admin/query-catalog`

1. **+ Nuevo query** (o editar uno existente).
2. Elegir el **microservicio** (`kind=QUERY`, p. ej. `eval-col`).
3. Escribir el **SQL** usando el placeholder donde va el id del archivo:
   ```sql
   INSERT INTO academico_test.tfuncionario_foto (fk_funcionario, fk_tarchivo)
   VALUES (:PARAM.ID::bigint, :BODY.FOTO::bigint)
   ```
4. En **"Tipos de parámetros"** (se auto-detectan del SQL), asignar el
   tipo **`FILE`** al placeholder del archivo. Al elegirlo aparece un
   campo de texto **"Clasificación (opcional)"** — ver sección 5.
   Marcar **"Obligatorio"** si la operación no tiene sentido sin él
   (`FILE!`, o `FILE:perfilUsuario!` con clasificación).
5. Completar **Método HTTP** y **Path template** (`/funcionario/:ID/foto`
   en este ejemplo).
6. **Roles** (después de guardar): igual que cualquier query — sin esto,
   la query es inalcanzable salvo que sea `publicEnd`.

`FILE` se comporta como `BIGINT` para todo lo que le importa al bind SQL
— el cast, el tipo JDBC, la validación de tipo en runtime. La única
diferencia real es que `file-service` lo usa para decidir qué campos del
multipart acepta como archivo para esa ruta puntual.

## 5. Clasificación — retrocompatibilidad con el formato histórico de clave

Sin clasificación, `file-service` arma la clave S3 como
`<pk_tarchivo>/<nombre-original>` (p. ej. `18/foto.jpg`) — el formato
que ya usaba antes de que existiera este campo. Las filas **migradas**
de antes de este sistema, en cambio, casi todas siguen un layout
distinto: `<algo>/<clasificación>/<id>.<extensión>` (ejemplo real de
`TARCHIVO`: `ACADEMICO_VALLEDUPAR/perfilUsuario/141906.jpeg`), con
`TARCHIVO.etiqueta` poblada (`perfilUsuario`, `escudo`,
`firmaMecanica`, ...).

Declarar `FILE:perfilUsuario` en vez de `FILE` (mismo campo de texto
que aparece junto al dropdown al elegir tipo `FILE`) hace que
file-service imite ESE layout para las filas nuevas:

```
GET /sso-admin/query/param-types  →  param_types: {"BODY.FOTO": "FILE:perfilUsuario"}

POST /api/files/eval-col/funcionario/42/foto  (multipart, campo "foto")
  → clave S3:        perfilUsuario/18.jpg     (<clasificación>/<pk>.<extensión>)
  → TARCHIVO.etiqueta: perfilUsuario           (antes quedaba NULL en toda fila nueva)
```

Reglas:

- **Sin extensión reconocible** en el nombre del archivo (el campo no
  trae punto), se cae al formato genérico `<pk>/<nombre>` — no tiene
  sentido armar `<clasificación>/<pk>.` con un punto colgando.
- La clasificación es **case-sensitive tal cual se escribe**
  (`perfilUsuario`, no `PERFILUSUARIO`) — se vuelve un segmento de
  ruta S3 literal, así que respeta el vocabulario histórico camelCase.
  Formato exigido: empieza con letra, luego letras/dígitos/`_`
  (`ParamTypes.isValidFileClassification`) — sin espacios ni `/`.
- Sólo aplica a destinos `query` (con `param_types`). Un destino
  `endpoint` (REST estático) no tiene dónde declarar esto — sigue
  usando el formato genérico siempre.

## 6. Qué tiene que estar configurado ANTES de que esto funcione

| Requisito | Dónde se configura | Si falta |
|---|---|---|
| Rol del usuario con binding `role_endpoint` a `POST`/`PUT /files/**` | `/admin/endpoints` → **Editar** la fila `POST /files/**` → pestaña **Roles** | `403` en el paso 2 |
| El query con `path_template` + microservicio correcto | `/admin/query-catalog` | `404` en el paso 3 |
| El campo declarado `FILE` en `param_types` (si se quiere restringir) | `/admin/query-catalog` → "Tipos de parámetros" | Sin declarar = permisivo (no rompe, pero tampoco valida) |
| Rol del usuario con binding `role_query` a esa query (si no es `publicEnd`) | `/admin/query-catalog` → modal "Roles" | `403` en el paso 9 (lo devuelve query-service, no file-service) |

## 7. Límites actuales

- **No hay `FILE[]`** — un campo con varios archivos (`TransformadorMultipart`
  ya soporta "un binario → id suelto, varios → lista de ids") no tiene
  todavía forma de declararse en `param_types`. Se agrega el día que haga
  falta, mismo patrón que los demás tipos array.
- **Los destinos `endpoint` (REST estático, no `query-service`) no tienen
  `param_types`** — esa tabla no tiene esa columna. Un destino como
  `auth-center POST /register/funcionario` sigue aceptando cualquier
  campo binario sin restricción por nombre.
- `TARCHIVO` no guarda mimetype; si el consumidor final necesita el
  content-type exacto al servir la imagen de vuelta (`GET /files/view/{id}`),
  puede pasarlo explícito con `?mimeType=image/jpeg` — ver
  [`DownloadController`](../file-service/src/main/java/com/co/eurekatic/files/DownloadController.java).
