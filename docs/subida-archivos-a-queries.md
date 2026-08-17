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
  → clave S3:        ACADEMICO_VALLEDUPAR/perfilUsuario/18.jpg
                      (<sitio>/<clasificación>/<pk>.<extensión> — el
                      prefijo <sitio> viene de FILES_SITE_CODE, ver
                      TransformadorMultipart.claveDe; vacío por
                      defecto = sin ese segmento)
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

## 6. Catálogo de clasificaciones + relación con un establecimiento

Se revisó `TARCHIVO.etiqueta` completa en el servidor de producción
para ver qué clasificaciones existen de verdad y con qué forma de
clave S3. El catálogo resultante (expuesto en
`GET /sso-admin/query/param-types` como `knownFileClassifications` —
sugerido para el dropdown del admin-ui, **no** una lista cerrada:
cualquier valor con forma válida sigue siendo aceptado):

| Clasificación | Filas (histórico) | Layout histórico | ¿Lleva establecimiento? |
|---|---:|---|---|
| `perfilUsuario` | 19 607 | `<sitio>/perfilUsuario/<id>.ext` | No |
| `actividad` | 364 961 | `<sitio>/<establecimiento.codigo>/actividad/<id>.ext` | Sí |
| `recursoCompartido` | 331 | `<sitio>/<establecimiento.codigo>/recursoCompartido/<uuid>.ext` | Sí |
| `matricula` | 96 | `<sitio>/<establecimiento.codigo>/matricula/<idLegado>/<uuid>.ext` | Sí |
| `candidato` | 36 | `<sitio>/<establecimiento.codigo>/candidato/<uuid>.ext` | Sí |
| `escudo` | 28 | `<sitio>/<establecimiento.codigo>/escudo/<pk_establecimiento>.ext` | Sí |

Deliberadamente afuera del catálogo:

- **`firmaMecanica`** — `TARCHIVO.urls3` siempre vacío en las filas
  migradas con esa etiqueta; no hay objeto S3 real detrás.
- **`informeFinal`, `certificacion`, `informePeriodo`** — reportes PDF
  con una carpeta más de profundidad
  (`.../informePeriodo/PA<año>/<periodo>/<id>.pdf`, y con DOS formas
  históricas distintas para `informePeriodo` según la fecha de
  migración) que este esquema de un solo segmento adicional no modela.
  Probablemente generados por un proceso batch aparte, no por una
  subida de usuario vía `FILE:clasificación`.

**El id final nunca es reproducible para clasificaciones establishment-scoped
salvo `escudo`.** Se comprobó contra la BD real: el número que aparece
al final de la clave histórica (p. ej. `.../actividad/220537.pdf`, o
el subdirectorio de `matricula`) es un id del sistema origen de la
migración — no existe como `pk_tarchivo`, `pk_tmatricula` ni ningún
otro PK de este esquema. Una fila **nueva** subida por este sistema
usa su propio `pk_tarchivo` ahí, igual que ya hacía `perfilUsuario` —
sólo el establecimiento y la clasificación imitan el layout histórico,
no el id final. La excepción es `escudo`: el id histórico SÍ es
`pk_establecimiento` (comprobado: `.../escudo/752.jpeg` con
`pk_establecimiento = 752`), pero una fila nueva usa igual su propio
`pk_tarchivo` — reproducir el pk del establecimiento exigiría que la
clasificación conociera esa relación 1:1, que este esquema genérico no
modela.

### Declarar el campo de establecimiento

Un tercer componente, después de la clasificación, nombra OTRO campo
de **texto** del mismo multipart que trae el código de establecimiento
(`testablecimiento.codigo` — el código DANE, no el `pk_establecimiento`
interno). `file-service` lo valida contra esa tabla ANTES de tocar S3:

```
param_types: {
  "BODY.FOTO":              "FILE:actividad:idEstablecimiento",
  "BODY.IDESTABLECIMIENTO": "TEXT!"
}

POST /api/files/eval-col/actividad  (multipart)
  foto              = <jpg>
  idEstablecimiento = 120001003751

  → GET testablecimiento WHERE codigo = '120001003751'  (existe → OK)
  → clave S3: ACADEMICO_VALLEDUPAR/120001003751/actividad/21.jpg
              (<sitio>/<código>/<clasificación>/<pk>.<extensión>)
```

Reglas:

- El nombre que sigue al segundo `:` es el **nombre literal del campo
  multipart** (`idEstablecimiento`), no una clave canónica `BODY.*` —
  `file-service` lo busca tal cual entre los campos de texto de la
  misma petición (ver `ReenvioController`). Mismo patrón de
  identificador que la clasificación: empieza con letra, luego
  letras/dígitos/`_`.
- Un código que no exista en `testablecimiento.codigo` (o que el campo
  ni siquiera llegue) responde `400` **antes** de subir nada a S3 —
  sin este chequeo, cualquier texto que mandara el cliente terminaría
  siendo una "carpeta" nueva en el bucket sin relación real con ningún
  establecimiento.
- El campo de establecimiento sólo tiene efecto si HAY clasificación
  (`FILE:actividad:idEstablecimiento`, no `FILE::idEstablecimiento`) —
  sin clasificación no hay carpeta que anteceda.
- Es opcional incluso en una clasificación de las que históricamente sí
  llevan establecimiento: declarar sólo `FILE:actividad` (sin el
  tercer componente) sigue siendo válido, sólo que la clave nueva no
  llevará ese segmento — es decisión de quien configura el catálogo,
  no algo que el sistema fuerce por el nombre de la clasificación.

### Respaldo: derivarlo del usuario cuando no lo manda (`tsede_usuario`)

Un usuario vinculado a un solo establecimiento (un profesor típico, por
ejemplo) no debería tener que elegirlo ni mandarlo — su cliente puede
simplemente omitir el campo. Si `idEstablecimiento` no llega (o llega
vacío), `file-service` intenta derivarlo de las relaciones de rol/sede
del propio usuario autenticado ANTES de rechazar:

```
tusuario (cuenta == email del JWT, case-insensitive)
  → tsede_usuario (activo, tlv_estado = ACTIVO)
    → tsede (activo)
      → testablecimiento.codigo
```

Ver `FileDestinationAccessService#establecimientoDelUsuario`. Sólo
resuelve si da con **exactamente un** establecimiento distinto:

- Varias filas de `tsede_usuario` para la MISMA sede (distintos roles o
  jornadas) siguen contando como una sola — `SELECT DISTINCT` sobre el
  código.
- **Ambiguo** (el usuario está vinculado a 2+ establecimientos
  distintos, o a ninguno) → sigue exigiendo el campo explícito, con un
  mensaje que lo dice: *"no se pudo derivar automáticamente de tu
  usuario porque estás vinculado a varios establecimientos (o a
  ninguno) — mándalo explícito"*.
- Un valor explícito no vacío **siempre gana** — nunca se intenta
  derivar si el cliente sí mandó algo (aunque sea inválido: ese caso
  responde con el mensaje de código inválido de siempre, no con el de
  ambigüedad).

Esto no cambia nada del lado del catálogo: la declaración sigue siendo
`FILE:actividad:idEstablecimiento`, el mismo campo que un
administrador con varios establecimientos SÍ necesita mandar para
elegir uno. El respaldo sólo cubre el caso en que el cliente ni
siquiera lo manda.

## 7. `GET /files/public/**` — activos globales sin JWT ni token que expire

`GET /files/view/{id}` (sección 6 del doc de visualización inline)
resuelve el caso "`<img src>` autenticado" con un token de vida corta
(5 minutos). No sirve para un dato de CATÁLOGO
(`tlista_valor.valor`, por ejemplo) que se guarda una vez y se
renderiza indefinidamente después — habría que re-mintar el token en
cada carga. Este endpoint no pide nada:

```
GET /api/files/public/<clave-s3-completa>
```

La clave va tal cual está en `TARCHIVO.urls3`:

```
GET /api/files/public/ACADEMICO_VALLEDUPAR/graficaCarita/489905.png
```

Dos puertas, ambas obligatorias, antes de tocar S3 — ninguna es un
JWT:

1. La **clasificación** de la clave (el segmento inmediatamente antes
   del nombre de archivo — `graficaCarita` arriba) tiene que estar en
   `ParamTypes.PUBLIC_FILE_CLASSIFICATIONS` (hoy: `graficaCarita`,
   `graficaSimbolo` — íconos de calificación, activos globales de UI,
   nunca datos por-usuario ni por-establecimiento). Cualquier otra
   clasificación responde `404`, exista o no el objeto — este
   endpoint nunca es la puerta para `actividad`, `matricula`,
   `perfilUsuario`, etc.
2. Tiene que existir una fila **activa** en `TARCHIVO` con `urls3`
   EXACTAMENTE igual a la clave pedida (`ArchivoRepository#buscarActivoPorClave`)
   — evita servir un objeto huérfano que ya no está en el catálogo.

Agregar una clasificación a `PUBLIC_FILE_CLASSIFICATIONS` la hace
pública de inmediato para TODO objeto que la use, presente y futuro
— nunca agregar ahí una de
`ParamTypes.ESTABLISHMENT_SCOPED_FILE_CLASSIFICATIONS` ni ninguna con
datos reales de un usuario o establecimiento.

El `api-gateway` deja pasar `/api/files/public/**` sin exigir Bearer
(`GatewaySecurityConfig`) — sin eso, un `<img>` sin `Authorization` se
quedaría en `401` antes de llegar siquiera a `file-service` a mirar
si la clasificación es pública.

## 8. Qué tiene que estar configurado ANTES de que esto funcione

| Requisito | Dónde se configura | Si falta |
|---|---|---|
| Rol del usuario con binding `role_endpoint` a `POST`/`PUT /files/**` | `/admin/endpoints` → **Editar** la fila `POST /files/**` → pestaña **Roles** | `403` en el paso 2 |
| El query con `path_template` + microservicio correcto | `/admin/query-catalog` | `404` en el paso 3 |
| El campo declarado `FILE` en `param_types` (si se quiere restringir) | `/admin/query-catalog` → "Tipos de parámetros" | Sin declarar = permisivo (no rompe, pero tampoco valida) |
| Rol del usuario con binding `role_query` a esa query (si no es `publicEnd`) | `/admin/query-catalog` → modal "Roles" | `403` en el paso 9 (lo devuelve query-service, no file-service) |

## 9. Límites actuales

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
- **Un solo segmento de establecimiento, sin más profundidad** — las
  clasificaciones de reporte (`informeFinal`, `certificacion`,
  `informePeriodo`) necesitan además año/periodo y no están cubiertas
  (ver sección 6). No hay tampoco forma de reproducir el id final
  histórico salvo para `escudo` (pk_establecimiento) — toda fila
  nueva usa su propio `pk_tarchivo`.
