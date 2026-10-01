# Planeador: endpoints de observación (formativa) y evidencias

> **Este documento sustituye a** `docs/planeador/observacion-formativa-evidencias-favorita.md`
> para el estado de la rama `feat/planeador-correcciones-reglas-gestion-academica`.
> El contrato de rutas y claves no cambió, pero sí las reglas: `MOMENTO` y
> `ENLACE` nuevos en la observación, la asistencia de la actividad bloquea
> observar sin asistencia o en No asistido, el gate de
> propiedad (Regla 54) ahora es explícito en wrapper, y el límite de evidencias
> se valida con una función propia (Regla 61). Ver "Qué cambió" más abajo.

Guía para el front. Describe los endpoints que registran la **observación**
de un estudiante en una actividad **formativa** (referente formativo, p. ej.
preescolar: se evalúa con observación narrativa, no con nota — Regla 52), sus
**evidencias** (archivos o enlace) y la **evidencia favorita**.

## Convenciones comunes

- **Base:** todas las rutas cuelgan del gateway en `/api/eval-col`. Por ejemplo,
  `PUT /api/eval-col/planeador/actividades/estudiantes/123/observar`.
- **Autenticación:** `Authorization: Bearer <token>`. El usuario **nunca** se
  envía en el body: la base lo deriva del token.
- **Nombres de campo:** los del body y de la query van en **MAYÚSCULAS** tal
  como aparecen aquí (`BODY.OBSERVACION` → `"OBSERVACION"`).
- **Tres identificadores distintos, por ruta:**
  - `/actividades/:ID/...` → `:ID` = `pk_tactividad`.
  - `/actividades/estudiantes/:ID/...` → `:ID` = `pk_tactividad_estudiante`
    (sale de `GET /planeador/actividades/:ID` como
    `estudiantes[].pkTactividadEstudiante`, **no** es la matrícula).
  - `/actividades/estudiantes/soportes/:ID/...` → `:ID` = `pk_tactividad_soporte`
    (sale del `GET`/`POST` de `.../soportes`, **no** es el `PK_TARCHIVO`).
- **Respuesta:** las filas que devuelve la función. Un endpoint que devuelve un
  solo valor responde una fila con una columna.
- **Errores:** el cuerpo trae un mensaje listo para mostrar al usuario. Nombra
  la actividad o el estudiante, nunca un id.

| HTTP | SQLSTATE | Cuándo |
|---|---|---|
| 400 | `22023` | La actividad no es formativa; su referente curricular está inactivo (Regla 59); sin texto **y** sin evidencias; `OBSERVACION` pasa de 1000 caracteres; más de 3 evidencias; evidencia con `ENLACE` **y** archivos a la vez; `MOMENTO` no reconocido; formato de archivo no admitido. |
| 403 | `42501` | Sin permiso `VER`/`EDITAR` sobre `PLANEADOR`, fuera de alcance, o un **docente de aula** observa/gestiona soportes de una actividad que **no creó** (Regla 54). Coordinación, rectoría y super admin sí pasan. |
| 404 | `P0002` | No existe la actividad, la asignación actividad-estudiante, o el soporte (o ya fue retirado). |
| 409 | `23503` | Algún `PK_TARCHIVO` enviado no existe. |

## Qué cambió en esta rama

- **`BODY.MOMENTO`** (nuevo, opcional): `INICIO`, `PROCESO` o `CIERRE` —
  catálogo `MOMENTO_REGISTRO`. Ausente o `NULL` = no toca el momento ya
  guardado.
- **`BODY.ENLACE`** (nuevo, opcional): enlace `http://` o `https://` como
  evidencia alternativa a los archivos. No se puede enviar junto con
  `EVIDENCIAS` si ambos quedan con contenido (Regla 61: archivos **o** enlace,
  nunca los dos).
- **`BODY.OBSERVACION` tiene tope de 1000 caracteres** (antes sin límite
  explícito).
- **Evidencias:** hasta 3 archivos `pdf`/`doc`/`docx`/`jpg`/`jpeg`/`png` de
  máximo 10 MB cada uno, **o** un enlace — nunca ambos (Regla 61).
- **Asistencia de la actividad** (Reglas 62/73): cuenta la de la **fecha fin** si ya llegó y se tomó; si no, la del **primer día**
  de la actividad, no `FECHA`. Sin asistencia (ni en la Vista ni marcada en el
  Planeador), en No asistido o en No presentó **no se observa** (400). Al
  observar, la asistencia de la actividad queda congelada.
- **Regla 54 explícita:** solo el docente que **creó** la actividad puede
  observar o gestionar sus soportes; un docente de aula que no la creó recibe
  403. Coordinación, rectoría y super admin no tienen esa restricción.
- **`observar-grupal` solo alcanza a Pendientes sin observación:** se omiten
  los estudiantes que ya tienen un resultado (observación o un estado como
  *No asistido*), están ausentes o no tienen asistencia. La clave de salida
  sigue siendo `estudiantes_observados`.
- **Favorito auditado:** marcar/desmarcar la evidencia favorita queda
  registrado en la auditoría igual que el resto de escrituras del módulo.

---

## 1. Observar

### 1.1 `PUT /planeador/actividades/estudiantes/:ID/observar` — un estudiante

`:ID` = `pk_tactividad_estudiante`. Gate `EDITAR` sobre `PLANEADOR` + alcance +
Regla 54. Función: `fn_actividad_observar_estudiante` (wrapper) →
`fn_actividad_observar_estudiante_interno`.

**Uso:** registrar o editar la observación narrativa de un estudiante en una
actividad formativa. Marca el resultado como `Calificado`.

**Entrada:**

| Campo | Tipo | Oblig. | Notas |
|---|---|---|---|
| `OBSERVACION` | texto | no | Hasta 1000 caracteres. Vacía o ausente es válida si queda con evidencia o enlace. Enviarla vacía al editar **borra** el texto anterior. |
| `MOMENTO` | varchar | no | `INICIO`, `PROCESO` o `CIERRE`. Ausente/`NULL` = no toca el momento guardado. |
| `EVIDENCIAS` | bigint[] | no | `PK_TARCHIVO`, hasta 3. **Reemplazo completo**: ausente/`NULL` = conserva los archivos actuales; `[]` = los quita todos. |
| `ENLACE` | varchar | no | `http://` o `https://`. Alternativo a `EVIDENCIAS`, nunca junto con archivos vivos. |
| `FECHA` | date | no | Por defecto hoy. Fecha de las evidencias; la asistencia que vale es la de la fecha fin o, si aún no, la del primer día. |

Regla: tras aplicar el cambio, la observación debe quedar con texto **o** al
menos una evidencia (archivo o enlace) activa; si no, 400.

**Salida:** `void` — el éxito es el 200.

**Errores propios:** 400 si la actividad no es formativa, su referente está
inactivo, se excede algún límite de la Regla 61, o queda sin texto y sin
evidencia; 403 (42501) sin alcance o si el docente no creó la actividad
(Regla 54); 404 si la asignación no existe.

### 1.2 `POST /planeador/actividades/:ID/observar-grupal` — grupal

`:ID` = `pk_tactividad`. Gate `EDITAR` sobre `PLANEADOR` + alcance + Regla 54.
Función: `fn_actividad_observar_grupal` (wrapper) →
`fn_actividad_observar_grupal_interno`.

**Uso:** aplicar la **misma** observación a todos los estudiantes de la
actividad que siguen **Pendientes y sin observación**. Los que ya tienen un
resultado (observación propia o un estado como *No asistido*), los ausentes y
los que no tienen asistencia se omiten sin error.

**Entrada:** mismos campos y límites que 1.1 (`OBSERVACION`, `MOMENTO`,
`EVIDENCIAS`, `ENLACE`, `FECHA`) — los mismos archivos/enlace se adjuntan a
cada estudiante alcanzado.

**Salida:** `{ "estudiantes_observados": <int> }` — cuántos estudiantes quedaron
observados con esta llamada (puede ser `0`).

**Errores propios:** 400 (`22023`) si la actividad no es formativa, su
referente está inactivo, se excede un límite de evidencia o no trae texto,
evidencia ni enlace; 403 (`42501`) sin alcance o si el docente no creó la
actividad (Regla 54); 404 (`P0002`) si la actividad no existe.

---

## 2. Evidencias (soportes)

### 2.1 `GET /planeador/actividades/estudiantes/:ID/soportes` — listar

`:ID` = `pk_tactividad_estudiante`. Gate `VER` sobre `PLANEADOR` + alcance +
Regla 54. Sin body. Función: `fn_actividad_observacion_soportes_listar` →
`..._interno`.

**Uso:** archivos de evidencia adjuntos a la observación de un estudiante. Es
la misma lista que la columna `evidencias` de
`GET /planeador/actividades/estudiantes/:ID/nota` (contrato de calificación),
como recurso propio.

**Salida:** una fila por adjunto activo:

| Columna | Tipo | Notas |
|---|---|---|
| `pk_tactividad_soporte` | bigint | `:ID` para quitar o marcar favorita |
| `fk_tarchivo` | bigint | `PK_TARCHIVO` |
| `nombre` | varchar | Nombre del archivo |
| `urls3` | varchar | Clave interna S3 (no es URL navegable) |
| `peso` | bigint | Bytes |
| `etiqueta` | varchar | |
| `fecha` | date | Fecha del soporte |
| `created_at` | timestamp | |
| `es_favorito` | boolean | `true` en a lo sumo una fila |

**Errores propios:** 404 si la asignación actividad-estudiante no existe.

### 2.2 `POST /planeador/actividades/estudiantes/:ID/soportes` — agregar una

`:ID` = `pk_tactividad_estudiante`. Gate `EDITAR` sobre `PLANEADOR` + alcance +
Regla 54 (y para la vía multipart, además el binding `role_endpoint`
`POST /files/**`). Función: `fn_actividad_observacion_soporte_agregar` →
`..._interno`.

**Uso:** adjuntar **un** archivo a la observación sin tocar los demás —a
diferencia de `EVIDENCIAS` del `PUT observar`, que reemplaza el set completo.
Sirve para armar la observación de a un archivo por vez.

**Entrada:**

| Campo | Tipo | Oblig. | Notas |
|---|---|---|---|
| `FK_TARCHIVO` | archivo o bigint | sí | Dos formas: (1) multipart a `POST /api/files/eval-col/planeador/actividades/estudiantes/:ID/soportes` con el binario en el campo `FK_TARCHIVO`, que file-service sube y reenvía como JSON; (2) JSON directo con un `PK_TARCHIVO` ya existente. Carpeta S3: `actividad/<pk>.<ext>`. |
| `FECHA` | date | no | Por defecto hoy. |

**Salida:** `{ "pk_tactividad_soporte": <bigint> }`. Idempotente: si el archivo
ya estaba adjunto, devuelve el mismo pk. La evidencia nueva nace **sin**
favorita.

**Errores propios:** 400 (`22023`) si la actividad no es formativa, su
referente está inactivo o se excede la Regla 61 (hasta 3 archivos
pdf/doc/docx/jpg/jpeg/png de 10 MB, o un enlace); 409 (`23503`) si el archivo no
existe; 404 (`P0002`) si la asignación no existe.

### 2.3 `PUT /planeador/actividades/estudiantes/soportes/:ID` — quitar una

`:ID` = `pk_tactividad_soporte`. Gate `EDITAR` sobre `PLANEADOR` + alcance +
Regla 54. Es `PUT` y no `DELETE` porque el catálogo no admite `DELETE`.
Función: `fn_actividad_observacion_soporte_quitar` → `..._interno`.

**Entrada:** `{ "FECHA": "..." }` — opcional, se conserva por contrato y ya no
se usa.

**Salida:** `{ "pk_tactividad_soporte": <bigint> }`. Baja lógica; el binario no
se borra del file-service. Si era la favorita, queda desmarcada.

**Errores propios:** 400 si la actividad no es formativa o su referente está
inactivo; 404 (`P0002`) si el soporte no existe o ya fue retirado.

### 2.4 `PUT /planeador/actividades/estudiantes/soportes/:ID/favorito` — marcar favorita

`:ID` = `pk_tactividad_soporte`. Gate `EDITAR` sobre `PLANEADOR` + alcance +
Regla 54. No exige asistencia: no toca la observación, solo cuál evidencia se
destaca. Función: `fn_actividad_observacion_soporte_favorito` → `..._interno`.

**Entrada:**

| Campo | Tipo | Oblig. | Notas |
|---|---|---|---|
| `ES_FAVORITO` | boolean | no | Por defecto `true`. `true` marca esta evidencia y **desmarca la anterior** (a lo sumo una por estudiante-actividad); `false` la desmarca. |

**Salida:** `{ "pk_tactividad_soporte": <bigint> }`.

**Errores propios:** 404 si el soporte no existe o ya fue retirado; 400 si la
actividad no es formativa.

Esta escritura queda auditada (nuevo respecto a la versión anterior del
documento).

---

## 3. Dónde se lee después

- El boletín de preescolar incluye las observaciones sin texto (solo
  evidencia) y pone la favorita primero.
- `GET /planeador/actividades/estudiantes/:ID/nota` (ver
  `docs/planeador/calificacion-y-materiales-endpoints.md`, sección 3.2) trae
  `evidencias` con el mismo detalle que 2.1, para precargar el popover.
- `POST /informes/evidencias` (pantalla "Seguimiento individual") trae una fila
  por evidencia, con o sin texto en la observación, incluyendo `es_favorito`.
