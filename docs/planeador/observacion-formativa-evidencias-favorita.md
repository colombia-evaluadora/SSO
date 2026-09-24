# Observación formativa — solo evidencias y evidencia favorita

Contrato de los endpoints que registran la observación de un estudiante en una
actividad **formativa** (referente formativo, p. ej. preescolar: observación en
vez de nota), sus evidencias (archivos) y la evidencia favorita.
Estado tras la rama `fix/planeador-observacion-solo-evidencias-favorita`
(V461, V463, V468 y V490 editadas).

Todos van por el gateway con prefijo `/api/eval-col` y `Authorization: Bearer <token>`.

## Qué cambió

- **El texto de la observación es opcional.** Se puede guardar una observación
  que solo tenga archivos y, al editarla después, agregarle el texto o dejarla
  vacía. Solo se rechaza si queda **sin texto y sin ninguna evidencia**.
- **Evidencia favorita:** una de las evidencias de la observación se puede marcar
  como favorita (`es_favorito`). Hay como máximo una por estudiante y actividad.
- El boletín de preescolar incluye las fotos de las observaciones sin texto y
  pone la favorita primero.

## Flujo

```
1. (opcional) subir cada archivo por file-service  ──► PK_TARCHIVO
2. PUT  /planeador/actividades/estudiantes/:ID/observar   { OBSERVACION?, EVIDENCIAS? }
     o POST /planeador/actividades/estudiantes/:ID/soportes  (un archivo a la vez)
3. GET  /planeador/actividades/estudiantes/:ID/soportes   ──► pk_tactividad_soporte, es_favorito
4. PUT  /planeador/actividades/estudiantes/soportes/:ID/favorito   { ES_FAVORITO }
```

## Convenciones

- Claves del body **exactamente en MAYÚSCULAS**.
- `:ID` cambia según la ruta. Hay que fijarse bien en cuál es:
  - `/actividades/:ID/...` → `PK_TACTIVIDAD`
  - `/actividades/estudiantes/:ID/...` → `PK_TACTIVIDAD_ESTUDIANTE`
    (sale de `GET /planeador/actividades/:ID` como `estudiantes[].pkTactividadEstudiante`)
  - `/actividades/estudiantes/soportes/:ID/...` → `PK_TACTIVIDAD_SOPORTE`
    (**no** es el `PK_TARCHIVO`)
- `EVIDENCIAS` (arrays de `PK_TARCHIVO`): ausente o `null` = no tocar;
  cualquier array (incluido `[]`) = **reemplazo completo**.
- `FECHA` opcional (por defecto hoy): el estudiante debe tener asistencia válida
  ese día en la actividad (no inasistencia injustificada).

### Errores

| SQLSTATE | HTTP | Cuándo |
|---|---|---|
| `22023` | 400 | La actividad no es formativa; sin texto **y** sin evidencias; sin asistencia válida en `FECHA` |
| `P0002` | 404 | La asignación actividad-estudiante, la actividad o el soporte no existe (o el soporte ya se retiró) |
| `42501` | 403 | Sin permiso `EDITAR`/`VER` sobre `PLANEADOR` o fuera de su alcance |
| `23503` | 409 | Algún `PK_TARCHIVO` no existe |

---

## `PUT /planeador/actividades/estudiantes/:ID/observar` — observación individual

`:ID` = `PK_TACTIVIDAD_ESTUDIANTE`. Gate `EDITAR` sobre `PLANEADOR`.

### Entrada

| Campo | Tipo | Oblig. | Notas |
|---|---|---|---|
| `OBSERVACION` | texto | no | Vacío o ausente guarda la observación **sin texto** (`NULL`). Enviarlo vacío al editar **borra** el texto anterior |
| `EVIDENCIAS` | bigint[] | no | `PK_TARCHIVO`. Reemplazo completo; ausente = conserva los archivos actuales |
| `FECHA` | date | no | Por defecto hoy |

Regla: después de aplicar el cambio, la observación debe tener texto **o** al
menos una evidencia activa. Si `EVIDENCIAS` no viene, cuentan los archivos que ya
tenía.

```json
// Crear solo con archivos
{ "EVIDENCIAS": [9001, 9002] }

// Editar después: agregar texto, conservando los archivos
{ "OBSERVACION": "Participó con entusiasmo en la actividad." }

// Editar: quitar el texto, conservando los archivos
{ "OBSERVACION": "" }

// Rechazado (400): sin texto y quitando todos los archivos
{ "OBSERVACION": "", "EVIDENCIAS": [] }
```

### Salida

```json
{ "rows": [ { "fn_actividad_observar_estudiante": null } ] }
```

La función no devuelve valor (`VOID`): el éxito es el 200.

---

## `POST /planeador/actividades/:ID/observar-grupal` — observación grupal

`:ID` = `PK_TACTIVIDAD`. Gate `EDITAR` sobre `PLANEADOR`.

### Entrada

| Campo | Tipo | Oblig. | Notas |
|---|---|---|---|
| `OBSERVACION` | texto | no* | *Obligatorio si `EVIDENCIAS` viene vacío o ausente |
| `EVIDENCIAS` | bigint[] | no* | Los mismos archivos se adjuntan a cada estudiante observado |
| `FECHA` | date | no | Por defecto hoy |

- **No sobrescribe:** se salta a los estudiantes que ya tienen observación, es
  decir texto no vacío **o** evidencias activas.
- También se salta a quien no tiene asistencia válida en `FECHA`. Ninguna de las
  dos omisiones da error.

```json
{ "EVIDENCIAS": [9001] }
```

### Salida

```json
{ "rows": [ { "fn_actividad_observar_grupal": 18 } ] }
```

Cantidad de estudiantes efectivamente observados (puede ser `0`).

---

## `GET /planeador/actividades/estudiantes/:ID/soportes` — listar evidencias

`:ID` = `PK_TACTIVIDAD_ESTUDIANTE`. Gate `VER` sobre `PLANEADOR`. Sin body.

### Salida

Una fila por evidencia activa, ordenadas por `pk_tactividad_soporte`:

| Columna | Tipo | Notas |
|---|---|---|
| `pk_tactividad_soporte` | bigint | `:ID` para quitar o marcar favorita |
| `fk_tarchivo` | bigint | `PK_TARCHIVO` |
| `nombre` | texto | Nombre del archivo |
| `urls3` | texto | Clave interna S3 (no es una URL navegable) |
| `peso` | bigint | Bytes |
| `etiqueta` | texto | |
| `fecha` | date | Fecha de carga |
| `created_at` | timestamp | |
| `es_favorito` | boolean | **Nuevo.** `true` en a lo sumo una fila |

```json
{ "rows": [
  { "pk_tactividad_soporte": 501, "fk_tarchivo": 9001, "nombre": "foto1.jpg",
    "urls3": "actividad/9001.jpg", "peso": 204800, "etiqueta": null,
    "fecha": "2026-09-24", "created_at": "2026-09-24T10:12:00", "es_favorito": true },
  { "pk_tactividad_soporte": 502, "fk_tarchivo": 9002, "nombre": "foto2.jpg",
    "urls3": "actividad/9002.jpg", "peso": 180224, "etiqueta": null,
    "fecha": "2026-09-24", "created_at": "2026-09-24T10:12:05", "es_favorito": false }
] }
```

---

## `POST /planeador/actividades/estudiantes/:ID/soportes` — agregar una evidencia

`:ID` = `PK_TACTIVIDAD_ESTUDIANTE`. Gate `EDITAR`. Sin cambios de contrato; sirve
para armar una observación de solo archivos de a uno por vez.

### Entrada

| Campo | Tipo | Oblig. | Notas |
|---|---|---|---|
| `FK_TARCHIVO` | archivo o bigint | sí | Multipart por `/api/files/eval-col/planeador/actividades/estudiantes/:ID/soportes` (campo `FK_TARCHIVO` con el binario), o JSON directo con un `PK_TARCHIVO` existente |
| `FECHA` | date | no | Por defecto hoy |

### Salida

```json
{ "rows": [ { "pk_tactividad_soporte": 503 } ] }
```

Idempotente: si el archivo ya estaba adjunto devuelve el mismo pk. La evidencia
nueva nace **sin** favorita.

---

## `PUT /planeador/actividades/estudiantes/soportes/:ID` — quitar una evidencia

`:ID` = `PK_TACTIVIDAD_SOPORTE`. Gate `EDITAR`. Body opcional `{ "FECHA": "..." }`.

Salida: `{ "rows": [ { "pk_tactividad_soporte": 501 } ] }`.

**Nuevo:** si era la favorita, queda desmarcada; la observación se queda sin favorita.

---

## `PUT /planeador/actividades/estudiantes/soportes/:ID/favorito` — marcar favorita (nuevo)

`:ID` = `PK_TACTIVIDAD_SOPORTE`. Gate `EDITAR` sobre `PLANEADOR` + alcance.
No exige asistencia: no cambia la observación, solo cuál evidencia se destaca.

### Entrada

| Campo | Tipo | Oblig. | Notas |
|---|---|---|---|
| `ES_FAVORITO` | boolean | no | Por defecto `true`. `true` marca esta y **desmarca la anterior**; `false` la desmarca |

```json
{ "ES_FAVORITO": true }
```

### Salida

```json
{ "rows": [ { "pk_tactividad_soporte": 502 } ] }
```

Errores propios: `404` si el soporte no existe o ya fue retirado; `400` si la
actividad no es formativa.

---

## Lectura en Informes

### `POST /informes/evidencias` — evidencias del seguimiento individual

Gate `VER` sobre `INFORMES`. Alimenta la sección **EVIDENCIAS** de la pantalla
"Seguimiento individual".

#### Entrada

| Campo | Tipo | Oblig. | Notas |
|---|---|---|---|
| `FK_TMATRICULA` | bigint | sí | |
| `FK_TPERIODO_EVALUACION` | bigint | no | Ausente = todo el año (fila Final) |

#### Salida

Una fila por evidencia, **con o sin texto** en la observación:
`pk_tactividad_soporte`, `fk_tarchivo`, `nombre`, `urls3`, `peso`, `etiqueta`,
`fecha`, `fk_tperiodo_evaluacion`, `periodo_nombre`, `fk_tactividad`,
`actividad_titulo`, `observacion` y **`es_favorito`** (nuevo, al final).

### Boletín de preescolar

Sin cambios de contrato. Las seis ranuras de evidencia ahora:

1. incluyen fotos de observaciones **sin texto**;
2. ordenan **primero las favoritas** y después las más recientes.
