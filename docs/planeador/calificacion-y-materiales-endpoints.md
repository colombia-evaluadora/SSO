# Planeador: endpoints de calificación y de materiales reutilizables

Guía para el front. Describe qué se envía y qué se recibe en cada endpoint de
**instrumento de evaluación**, **calificación** y **materiales / biblioteca de
recursos** de las actividades del Planeador, y qué significa cada campo.
Corresponde al estado de la rama `refactor/planeador-actividades-calificacion-capas`
(PR #515).

## Convenciones comunes

- **Base:** todas las rutas cuelgan del gateway en `/api/eval-col`. Por ejemplo,
  `PUT /api/eval-col/planeador/actividades/estudiantes/123/calificar`.
- **Autenticación:** `Authorization: Bearer <token>`. El usuario **nunca** se
  envía en el body: la base lo deriva del token.
- **Nombres de campo:**
  - los del body y de la query van en **MAYÚSCULAS** tal como aparecen aquí
    (`BODY.FECHA` → `"FECHA"`, `QUERY.SEARCH` → `?search=`);
  - dentro de un JSON anidado (`CALIFICACION`, `DEFINICION`, `MATERIALES`) las
    claves van en **camelCase** (`pkCriterio`, `tipoRecurso`...).
- **Respuesta:** las filas que devuelve la función. Cada columna es una clave del
  objeto. Los endpoints que devuelven un solo valor responden una fila con una
  columna (por ejemplo `calificacion`).
- **Porcentajes:** toda nota se guarda como **porcentaje 0–100**. La nota en el
  formato del colegio (1–5, 1–10, literal…) viene aparte, en `nota_homologada`
  y `valoracion`.
- **Errores:** el cuerpo trae un mensaje listo para mostrar al usuario. Nombra la
  actividad, el estudiante o el criterio; nunca un id.

| HTTP | Cuándo |
|---|---|
| 400 | El dato no cumple una regla. Por ejemplo: falta un criterio, valor fuera de rango, actividad formativa, sin asistencia ese día, enlace de un sitio no admitido. |
| 403 | Sin permiso sobre la sede o jornada, o un docente toca una actividad que **no creó** (Reglas 25 y 54). |
| 404 | No existe la actividad o la asignación actividad‑estudiante. |
| 409 | La actividad ya tiene resultados o es la original de un Refuerzo y no se puede modificar (Regla 37), o una referencia (catálogo, archivo) no existe. |

- **Dos identificadores distintos:**
  - `:ID` de actividad = `pk_tactividad`;
  - `:ID` de un estudiante en una actividad = `pk_tactividad_estudiante`, la
    asignación. Sale de `GET :ID/calificaciones` o del detalle de la actividad.
    **No** es la matrícula.
- **Quién puede ver y calificar resultados (Regla 54):** un docente de aula solo
  sus propias actividades. Coordinación, rectoría y super admin, todas las de su
  alcance.

---

## 1. Instrumento de evaluación

Una actividad tiene **un** instrumento (`fk_tlv_instrumento_evaluacion`, elegido en
el formulario de la actividad): `RUBRICA`, `LISTA_COTEJO`, `ESCALA_VALORACION` u
`OTRO`. Estos endpoints configuran y leen **su estructura**.

### 1.1 `PUT /planeador/actividades/:ID/instrumento`

Define la estructura del instrumento que la actividad ya tiene elegido. Hace un
**reemplazo completo**: lo anterior se descarta. Se bloquea con 409 si la
actividad ya tiene resultados (Regla 37).

**Body:** `{ "DEFINICION": <json según el instrumento> }`

**Rúbrica** — arreglo de criterios:

```json
[
  { "nombre": "Contenido", "descripcion": "opcional",
    "niveles": [
      { "etiqueta": "Alto", "descripcion": "Completo y correcto", "ponderacion": 50 },
      { "etiqueta": "Bajo", "descripcion": "Incompleto",          "ponderacion": 25 }
    ] },
  { "nombre": "Ortografía",
    "niveles": [
      { "etiqueta": "Alto", "descripcion": "Sin errores", "ponderacion": 20 },
      { "etiqueta": "Bajo", "descripcion": "Con errores", "ponderacion": 10 }
    ] }
]
```

| Campo | Significado |
|---|---|
| `nombre` | Nombre del criterio (obligatorio). |
| `niveles[].etiqueta` | Rótulo corto del nivel ("Alto"). Opcional. |
| `niveles[].descripcion` | Descripción o juicio de valor del nivel (obligatorio). |
| `niveles[].ponderacion` | **Puntaje del nivel**, 0–100 (obligatorio). No se puede repetir dentro de un criterio y al menos uno debe ser mayor que 0. |

El **puntaje del criterio** no se envía: es el de su nivel más alto (en el ejemplo,
50 y 20) y hace de peso del criterio (Regla 42).

**Lista de cotejo** — arreglo de elementos:

```json
[ { "descripcion": "Incluye portada", "ponderacion": 50 },
  { "descripcion": "Contiene bibliografía", "ponderacion": 30 },
  { "descripcion": "Mantiene el orden" } ]
```

`ponderacion` es el **puntaje del elemento** (0–100, opcional). Sin puntaje pesa 1.
El **total posible** es la suma de puntajes (en el ejemplo, 81) y no se envía.

**Escala de valoración** — objeto:

```json
{ "tipoEscala": 279, "valorMin": 0, "valorMax": 5,
  "criteriosGenerales": "Contenido,Forma", "interpretacionRangos": "0-2 Bajo, 3-4 Bueno, 5 Excelente" }
```

| Campo | Significado |
|---|---|
| `tipoEscala` | pk de `TIPO_ESCALA`: `NUMERICA` o `CUALITATIVA` (catálogo `GET /select/TIPO_ESCALA`). |
| `valorMin`, `valorMax` | Solo en **numérica**: rango que se podrá digitar al calificar (`min < max`). |
| `niveles` | Solo en **cualitativa**: `[{etiqueta, descripcion, ponderacion}]`, como los niveles de la rúbrica. |
| `criteriosGenerales` | Nombres de los criterios separados por coma. Cada uno se califica aparte con los mismos niveles o el mismo rango. Vacío = un solo criterio. |
| `interpretacionRangos` | Texto libre de referencia; no afecta el cálculo. |

El tipo de evaluación del referente decide qué variante se admite. Con referente
**cuantitativo**, solo escala numérica; con **cualitativo**, rúbrica, lista de
cotejo o escala cualitativa.

**Otro (personalizado)** — objeto:

```json
{ "tipoEvidencia": 343, "metodoValoracion": 270,
  "requiereArchivo": true, "requiereTexto": false,
  "definicion": [ { "descripcion": "Entrega completa", "ponderacion": 100 } ] }
```

| Campo | Significado |
|---|---|
| `tipoEvidencia` | pk de `TIPO_EVIDENCIA_OTRO`: Archivo, Enlace, Observación directa o Registro en campo. |
| `metodoValoracion` | pk de `INSTRUMENTO_EVALUACION`: rúbrica, lista de cotejo o escala. **Nunca** Otro. |
| `definicion` | La estructura del método elegido, con el mismo formato de su sección. |
| `requiereArchivo`, `requiereTexto` | Casillas de entrega (booleano o `"S"`/`"N"`). **Regla 41:** con evidencia *Archivo* queda siempre marcada `requiereArchivo`; con las demás, `requiereTexto`. Lo que se envíe para esa casilla se ignora; la otra es libre (ausente = sin cambio). |

**Respuesta:** `{ "instrumento_aplicado": "RUBRICA" | "LISTA_COTEJO" | "ESCALA_VALORACION" | "OTRO" }`.

### 1.2 `GET /planeador/actividades/:ID/instrumento`

Lee la estructura para pintar el formulario o las columnas de la planilla.

| Columna | Significado |
|---|---|
| `instrumento` | Código del instrumento (`RUBRICA`…). |
| `instrumento_nombre` | Nombre para mostrar. |
| `definicion` | La estructura, con los **pk** que se usan al calificar (ver abajo). |

Forma de `definicion` según el instrumento:

- **Rúbrica:** `[{ pk, orden, nombre, descripcion, niveles: [{ pk, etiqueta, descripcion, ponderacion }] }]`.
  - `pk` del criterio → `pkCriterio`; `pk` del nivel → `pkNivel`.
  - Los niveles vienen del mayor al menor puntaje.
- **Lista de cotejo:** `[{ pk, orden, descripcion, ponderacion }]`. El `pk` del
  elemento → `pkItem` / `itemsMarcados`.
- **Escala:** `{ pk, tipoEscala, tipoEscalaNombre, tipoEscalaValor, criteriosGenerales, valorMin, valorMax, interpretacionRangos, niveles: [{ pk, orden, etiqueta, descripcion, ponderacion }] }`.
  - `criteriosGenerales` partido por coma da los criterios; su posición (desde 0)
    es el `criterioIndex`.
- **Otro:** `{ pk, tipoEvidencia, tipoEvidenciaNombre, requiereArchivo, requiereTexto, metodoValoracion, metodoValoracionNombre, metodoValoracionValor, definicion }`,
  donde `definicion` tiene la forma del método.

---

## 2. Calificar

Requisitos para poder calificar a un estudiante (errores 400 si no se cumplen):

- La actividad existe, no está eliminada, tiene instrumento configurado y **no es
  formativa**. Las formativas (preescolar) se registran con observación, no con
  nota (Regla 52).
- El estudiante está asignado a la actividad.
- El estudiante tiene **asistencia** registrada en la asignatura ese día (`FECHA`,
  por defecto hoy) y no es una inasistencia injustificada. Una justificada sí deja
  calificar. Para saber qué fecha usar, mire `fecha_asistencia` en
  `GET :ID/calificaciones`.

La nota pasa por el **piso** y el **tope** institucionales. El tope solo aplica si
la actividad es una recuperación. Si la actividad es un Refuerzo, la nota se
consolida en la actividad original (ver sección 4).

### 2.1 `PUT /planeador/actividades/estudiantes/:ID/calificar`

Califica a **un** estudiante. `:ID` = `pk_tactividad_estudiante`.

**Body:** `{ "CALIFICACION": <json>, "FECHA": "2026-09-30" }` (`FECHA` es opcional; por defecto hoy).

`CALIFICACION` según el instrumento de la actividad (un Otro con método se califica
como su método):

| Instrumento | `CALIFICACION` | Reglas |
|---|---|---|
| Rúbrica | `{ "niveles": [ { "pkCriterio": 11, "pkNivel": 31 }, { "pkCriterio": 12, "pkNivel": 34 } ] }` | Un nivel por **cada** criterio, sin repetir. |
| Lista de cotejo | `{ "itemsMarcados": [21, 23] }` | Los `pkItem` que **cumplen**; los que no vienen quedan como "No cumple". `[]` = ninguno. |
| Escala, un solo valor | `{ "pkNivel": 41 }` (cualitativa) o `{ "valorNumerico": 4 }` (numérica) | Exactamente uno de los dos. Con varios criterios, el valor se aplica a cada uno. |
| Escala, por criterio | `{ "criterios": [ { "criterioIndex": 0, "valorNumerico": 4 }, { "criterioIndex": 1, "valorNumerico": 5 } ] }` | Un elemento por **cada** criterio. Cada uno lleva `pkNivel` o `valorNumerico`, dentro de `valorMin`–`valorMax`. |
| Otro sin método | `{ "porcentaje": 85 }` | 0–100. |

**Respuesta:** `{ "calificacion": 85.71 }`, el porcentaje 0–100 ya guardado.

Cómo se calcula (Regla 42):

- **Rúbrica:** suma de los puntajes elegidos ÷ suma del nivel más alto de cada criterio × 100. Ejemplo: 50 + 10 de 50 + 20 = 60/70 = **85,71**.
- **Lista de cotejo:** suma de los puntajes cumplidos ÷ total posible × 100.
- **Escala:** por criterio, `puntaje del nivel ÷ nivel más alto` o `valor ÷ valorMax`; la nota es el promedio de los criterios.
- **Otro sin método:** el porcentaje enviado.

### 2.2 Calificación en bloque (la planilla, una columna para varios estudiantes)

Comunes a los tres: `:ID` = `pk_tactividad`; `ESTUDIANTES` = arreglo de
`pk_tactividad_estudiante` (al menos uno, todos de esa actividad); `FECHA` opcional.
Si **un** estudiante no cumple (por ejemplo, no tiene asistencia), la llamada entera
se rechaza con 400 y el nombre de ese estudiante; no se guarda ninguno.

**`PUT /planeador/actividades/:ID/calificar-bulk/rubrica`**

Body: `{ "PK_CRITERIO": 11, "PK_NIVEL": 31, "ESTUDIANTES": [501, 502], "FECHA": "..." }`.
Aplica ese nivel de ese criterio. Los demás criterios ya marcados no se tocan.

| Columna | Significado |
|---|---|
| `pk_tactividad_estudiante` | Estudiante. |
| `criterios_totales` | Cuántos criterios tiene la rúbrica. |
| `criterios_cubiertos` | Cuántos tiene ya marcados ese estudiante. |
| `calificacion` | Porcentaje 0–100 si ya completó todos los criterios; `null` si aún faltan. |
| `calificacion_actualizada` | `true` si con esta llamada quedó nota; `false` = se guardó el criterio pero aún faltan otros (no es error). |

**`PUT /planeador/actividades/:ID/calificar-bulk/cotejo`**

Body: `{ "PK_ITEM": 21, "CUMPLIDO": "S" | "N", "ESTUDIANTES": [...], "FECHA": "..." }`.
Marca un elemento. La nota se recalcula en la misma llamada, porque un elemento sin
marcar cuenta como No cumple.

| Columna | Significado |
|---|---|
| `pk_tactividad_estudiante` | Estudiante. |
| `items_totales` | Elementos de la lista. |
| `items_cumplidos` | Elementos marcados como Cumple para ese estudiante. |
| `calificacion` | Porcentaje 0–100 resultante. |

**`PUT /planeador/actividades/:ID/calificar-bulk/escala`**

Body, una de dos formas:

- `{ "CRITERIOS": [ { "criterioIndex": 0, "pkNivel": 41 }, ... ], "ESTUDIANTES": [...] }`,
  un valor por criterio, igual para todos;
- `{ "PK_NIVEL": 41 }` o `{ "VALOR_NUMERICO": 4 }` suelto. Con varios criterios
  se aplica a cada uno.

No se mezclan `CRITERIOS` con un valor suelto.

| Columna | Significado |
|---|---|
| `pk_tactividad_estudiante` | Estudiante. |
| `calificacion` | Porcentaje 0–100 resultante. |

---

## 3. Leer resultados

### 3.1 `GET /planeador/actividades/:ID/calificaciones`

La tabla "Calificaciones: \<actividad>". `:ID` = `pk_tactividad`.
Parámetros: `?fecha=` (día de asistencia a mostrar; por defecto hoy) y `?search=`
(filtra por nombre del estudiante). Una fila por estudiante asignado.

| Columna | Significado |
|---|---|
| `pk_tactividad_estudiante` | Id del estudiante **en esta actividad**: el que se usa para calificar y para leer su nota. |
| `pk_tmatricula` | Matrícula del estudiante. |
| `nombre_estudiante` | Nombre completo. |
| `instrumento` | Código del instrumento de la actividad. |
| `fecha` | Eco de `?fecha=`. **No** usarlo como `FECHA` al calificar. |
| `pk_tasistencia`, `fk_tlv_tipo_asistencia`, `tipo_asistencia`, `asistencia_observacion`, `fk_soporte_archivo` | La asistencia de ese día, si hay: tipo (asistió, no asistió, justificada…), observación y soporte de la excusa. |
| `calificacion` | Nota en porcentaje 0–100; `null` = sin calificar. |
| `calificable` | `S`/`N`. |
| `nota_observacion` | Observación de la nota (el registro narrativo en formativas). |
| `es_formativa` | `true` = la actividad se registra con **observación**, no con nota: mostrar la vista narrativa. |
| `fecha_asistencia` | Día en que ese estudiante **sí** tiene una asistencia válida. Es la fecha a enviar como `FECHA` al calificar u observar. `null` = todavía no se le puede calificar. |
| `nota_homologada` | La nota en la escala del colegio (por ejemplo, 4.3 sobre 5). `null` si el formato no es numérico. |
| `valoracion` | Desempeño de la escala institucional (Bajo, Básico, Alto, Superior…). |
| `formato_valor` | Formato de calificación del colegio (`CINCO`, `DIEZ`, `CIEN`, `LITERAL`…). |
| `resultado_instrumento` | Lo que se marcó en el instrumento, ya con textos (ver 3.3). |

### 3.2 `GET /planeador/actividades/estudiantes/:ID/nota`

Detalle de un estudiante, para precargar el popover de calificación.
`:ID` = `pk_tactividad_estudiante`.

| Columna | Significado |
|---|---|
| `instrumento` | Código del instrumento. |
| `calificacion`, `calificable`, `observacion` | Nota (0–100), bandera y observación. |
| `detalle` | Lo capturado, **por pk**, para volver a marcar el formulario. Rúbrica: `[{pkCriterio, pkNivel, ponderacion}]`. Lista de cotejo: `[{pkItem, cumplido: "S"/"N"}]`. Escala: `[{criterioIndex, pkNivel, valor, ponderacion}]`, o `{pkNivel, valor, ponderacion}` si se calificó con un solo valor. Otro sin método: `null`. |
| `evidencias` | Archivos adjuntos a la observación: `[{pk, fkTarchivo, nombre, fecha}]`. |
| `nota_homologada`, `valoracion`, `formato_valor` | Igual que en 3.1. |
| `resultado_instrumento` | Ver 3.3. |

### 3.3 `resultado_instrumento`

Resumen listo para pintar lo que se marcó, **en puntos del propio instrumento**.
`null` = aún no hay captura.

| Clave | Significado |
|---|---|
| `tipo` | `RUBRICA`, `LISTA_COTEJO`, `ESCALA_CUALITATIVA`, `ESCALA_NUMERICA` u `OTRO`. |
| `resumen` | Texto para la celda o el chip. |
| `valor` / `base` | Puntos obtenidos / puntos posibles del instrumento completo. |
| `porcentaje` | La nota guardada (0–100). |
| `detalle` | Desglose (ver cada tipo). |

- **Rúbrica:**
  - `resumen`: "Contenido: Alto (50 / 50) · Ortografía: Bajo (10 / 20)"; `valor` 60, `base` 70.
  - `detalle`: `[{pkCriterio, criterio, pkNivel, nivel, ponderacion, valor, base}]`, donde `valor` es el puntaje elegido y `base` el nivel más alto del criterio.
- **Lista de cotejo:**
  - `resumen`: "50 / 81 (1/3 elementos)"; `valor`/`base` en puntos; `cumplidos` y `total` en número de elementos.
  - `detalle`: `[{pkItem, item, puntaje, cumplido: true/false}]`.
- **Escala:**
  - `resumen` por criterio: "Contenido: 3 / 5 · Forma: 3 / 5" (cualitativa: "Contenido: Alto (4 / 5)").
  - `valor`/`base` = suma de criterios; también trae `pkNivel`, `nivel`, `valorMin`, `valorMax`.
  - `detalle`: `[{criterioIndex, criterio, pkNivel, nivel, valor, base}]`.
- **Otro sin método:** `resumen` "85 %", `valor` = porcentaje, `base` 100.

> Cambio respecto a la versión anterior: en rúbrica y lista de cotejo, `valor`/`base`
> ahora son **puntos**. Antes la rúbrica mostraba "2 / 4" para 50 de 50, y en la
> lista de cotejo eran el número de elementos (esos siguen en `cumplidos`/`total`).

---

## 4. Recuperación (Refuerzo) y la nota que se muestra

- Una actividad puede tener **varios Refuerzos** (Regla 67). Para cada estudiante
  manda la nota del Refuerzo **más reciente que ya tenga nota**.
- Esa nota se escribe en la actividad original como `recuperacion` y `definitiva`.
- `nota_homologada` y `valoracion` se calculan sobre `definitiva` si existe; si
  no, sobre `calificacion`.
- Si se retira un Refuerzo, vuelve a mandar el anterior.
- La actividad original de un Refuerzo queda bloqueada para edición (Regla 37),
  pero se puede seguir calificando.

---

## 5. Materiales de apoyo

### 5.1 `PUT /planeador/actividades/:ID/materiales`

Reemplaza la lista completa de materiales de apoyo. `[]` = sin materiales. Máximo
10. Se bloquea con 409 si la actividad tiene resultados.

**Body:**

```json
{ "MATERIALES": [
  { "tipoRecurso": 254, "url": "https://www.youtube.com/watch?v=abc", "descripcion": "Video introductorio" },
  { "tipoRecurso": 300, "url": "https://drive.google.com/file/d/xyz", "descripcion": "Carpeta del curso" },
  { "tipoRecurso": 261, "fkTarchivo": 9876, "descripcion": "Guía en PDF" }
] }
```

| Campo | Significado |
|---|---|
| `tipoRecurso` | pk de `TIPO_RECURSO` (`GET /select/TIPO_RECURSO`): `URL` (URL - Sitio web), `REPOSITORIO` (Unidad virtual - repositorio) o `ARCHIVO` (Archivo en PC). |
| `descripcion` | Nombre del material, máximo 100 caracteres. |
| `url` | Solo para URL y REPOSITORIO. `http://` o `https://`. |
| `fkTarchivo` | Solo para ARCHIVO. El pk que devolvió la subida (5.2) o uno elegido de la biblioteca (5.4). |

Reglas por tipo (Regla 82):

- **URL - Sitio web:** el dominio, o un subdominio suyo, debe estar en el catálogo
  `DOMINIO_MATERIAL_URL`. Hoy: Wikipedia, YouTube (y youtu.be), Google Classroom,
  Moodle, MoodleCloud, Khan Academy, Colombia Aprende, MinEducación.
- **Unidad virtual - repositorio:** catálogo `DOMINIO_MATERIAL_REPOSITORIO`. Hoy:
  Google Drive, Google Docs, Dropbox, OneDrive (y 1drv.ms), Mega, SharePoint.
- **Listas:** son configurables. El LMS del colegio se agrega como un valor más
  del catálogo; el front puede leerlas con `GET /select/DOMINIO_MATERIAL_URL` y
  validar antes de enviar.
- **Archivo en PC:** formatos PDF, DOC, DOCX, XLS, XLSX, PPT, PPTX, JPG, JPEG, PNG,
  GIF, MP3, MP4, WEBM y TXT; máximo **20 MB**.
- **Un tipo no admite la forma del otro:** un material tipo archivo con enlace, o
  uno tipo enlace con archivo, da 400.
- **Enlaces al renderizar:** abrirlos con `target="_blank" rel="noopener noreferrer"`.

**Respuesta:** `{ "cantidad": 3 }`, el número de materiales que quedaron.

### 5.2 `POST /planeador/actividades/:ID/materiales/archivo`

Paso 1 de un material tipo archivo. `multipart/form-data` con el campo **`ARCHIVO`**.
El archivo lo guarda file-service.

**Respuesta:** `{ "fk_tarchivo": 9876 }`. Ese valor se envía como `fkTarchivo` en 5.1.
Si nunca se usa en un `PUT :ID/materiales`, no queda asociado a la actividad.

### 5.3 `GET /planeador/actividades/:ID/materiales/archivos`

Nombre y extensión de los archivos de los materiales de la actividad. Sirve para
pintar el ícono (PDF, imagen, audio, video) y el nombre. El detalle de la actividad
solo trae el `fkTarchivo`.

| Columna | Significado |
|---|---|
| `pk_tactividad_material` | Material de la actividad. |
| `fk_tarchivo` | Archivo. |
| `nombre` | Nombre original del archivo. |
| `extension` | Extensión en minúsculas (`pdf`, `png`, `mp4`…). |
| `peso` | Tamaño en bytes. |

### 5.4 Biblioteca de recursos: materiales reutilizables

Archivos que ya se subieron como material en **otras** actividades del mismo
establecimiento, para reusarlos sin volver a cargarlos. Solo trae materiales con
**archivo**: un enlace no se reutiliza, se copia. Muestra lo de todos los docentes
del colegio; para ver solo lo propio se filtra por `?funcionario=`.

Hay dos rutas con la misma respuesta:

| Ruta | Cuándo usarla |
|---|---|
| `GET /planeador/actividades/:ID/materiales-reutilizables` | Al **editar** una actividad (`:ID` = la actividad; sus propios materiales se excluyen). |
| `GET /planeador/materiales-reutilizables?actividad=` o `?grupo=` | Al **crear**, cuando aún no hay actividad: se envía el `grupo` ya elegido. Una de las dos es obligatoria (400 si no llega ninguna). |

Parámetros de filtro (todos opcionales):

| Parámetro | Significado |
|---|---|
| `asignatura` | Solo materiales de actividades de esa asignatura. |
| `funcionario` | Solo los de unidades de ese docente (pk del funcionario). |
| `search` | Busca en el nombre del archivo y el título de la actividad de origen. |
| `pagina` | Página, desde 1. Por defecto 1. |
| `size` | Tamaño de página. Por defecto 20. |

| Columna | Significado |
|---|---|
| `fk_tarchivo` | El archivo. **Es lo que se envía como `fkTarchivo`** (con `tipoRecurso` = ARCHIVO) en `PUT :ID/materiales` para reutilizarlo. |
| `nombre_archivo` | Nombre del archivo. |
| `peso` | Tamaño en bytes. |
| `pk_tactividad_origen`, `titulo_actividad_origen` | Actividad donde se subió. |
| `fk_tlv_tipo_recurso`, `tipo_recurso` | Tipo - Fuente con que se registró. |
| `descripcion` | Nombre que le dio el docente al material. |
| `total_count` | Total de resultados, para el paginador (se repite en cada fila). |

Orden: nombre del archivo y luego título de la actividad.

### 5.5 Biblioteca de adaptaciones: `GET /planeador/adaptaciones-reutilizables`

Igual que 5.4, pero para las versiones modificadas del instrumento (tipo archivo)
de las adaptaciones curriculares. Es la opción **Biblioteca** del Bloque 6. Mismos
parámetros: `actividad` o `grupo` (uno obligatorio), `asignatura`, `funcionario`,
`search`, `pagina`, `size`.

| Columna | Significado |
|---|---|
| `fk_tarchivo`, `nombre_archivo`, `peso` | El archivo. `fk_tarchivo` se envía como `fkTarchivo` de la adaptación, con formato `BIBLIOTECA`, en `PUT :ID/adaptaciones`. |
| `pk_tactividad_origen`, `titulo_actividad_origen` | Actividad de origen. |
| `fk_tlv_tipo_adaptacion`, `tipo_adaptacion` | Tipo de adaptación con que se cargó. Sirve para filtrar por el tipo ya elegido, como pide el documento de diseño. |
| `descripcion` | Descripción de la adaptación original. |
| `total_count` | Total para paginar. |
