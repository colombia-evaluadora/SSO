# Planeador: endpoints de materiales y adaptaciones reutilizables (biblioteca)

Guía para el front. Describe los endpoints de **materiales de apoyo** y
**adaptaciones curriculares** de las actividades del Planeador, y las dos
bibliotecas que permiten reutilizar un archivo o un enlace ya subido en otra
actividad en lugar de volver a cargarlo. Corresponde al estado de la rama
`feat/planeador-correcciones-reglas-gestion-academica`.

## Convenciones comunes

- **Base:** todas las rutas cuelgan del gateway en `/api/eval-col`. Por ejemplo,
  `PUT /api/eval-col/planeador/actividades/123/materiales`.
- **Autenticación:** `Authorization: Bearer <token>`. El usuario **nunca** se
  envía en el body: la base lo deriva del token.
- **Nombres de campo:**
  - los del body y de la query van en **MAYÚSCULAS** tal como aparecen aquí
    (`BODY.MATERIALES` → `"MATERIALES"`, `QUERY.SEARCH` → `?search=`);
  - dentro de un JSON anidado (`MATERIALES`, `ADAPTACIONES`) las claves van en
    **camelCase** (`tipoRecurso`, `nombrePlantilla`...).
- **Respuesta:** las filas que devuelve la función. Cada columna es una clave
  del objeto. Los endpoints que devuelven un solo valor responden una fila con
  una columna (por ejemplo `cantidad`).
- **Errores:** el cuerpo trae un mensaje listo para mostrar al usuario. Nombra
  la actividad o el material; nunca un id.

| HTTP | Cuándo |
|---|---|
| 400 (22023) | El dato no cumple una regla: array mal formado, enlace de un sitio no admitido, formato o tamaño de archivo no admitido, falta `especificacionTipo` con tipo "Otro", más de 10/3 archivos, actividad ya eliminada. |
| 403 (42501) | Sin permiso sobre PLANEADOR, o un docente de aula toca una actividad que **no creó** (Regla 25). |
| 404 (P0002) | No existe la actividad. |
| 409 (23503) | La actividad ya tiene resultados registrados o es la original de una recuperación (Regla 37); o un `fkTarchivo` referenciado no existe. |

- **`:ID` de actividad = `pk_tactividad`** en todas las rutas de esta página.
- **Gate:** escritura (`PUT`/`POST`) exige EDITAR sobre PLANEADOR; lectura
  (`GET`) exige VER. Un docente de aula solo opera sobre las actividades que
  él creó (Regla 25); coordinación, rectoría y super admin, todas las de su
  alcance (igual que en el resto de `/planeador/actividades/:ID/*`).

---

## 1. Materiales de apoyo

### 1.1 `PUT /planeador/actividades/:ID/materiales`

Reemplaza la lista completa de materiales de apoyo de la actividad `:ID`
(`fn_actividad_material_reemplazar`). `[]` = sin materiales.

**Body:**

```json
{ "MATERIALES": [
  { "tipoRecurso": 254, "url": "https://www.youtube.com/watch?v=abc", "descripcion": "Video introductorio" },
  { "tipoRecurso": 261, "fkTarchivo": 9876, "descripcion": "Guía en PDF" }
] }
```

| Campo | Significado |
|---|---|
| `tipoRecurso` | pk de `TIPO_RECURSO` (`GET /select/TIPO_RECURSO`): `URL` (URL - Sitio web), `REPOSITORIO` (Unidad virtual - repositorio) o `ARCHIVO` (Archivo en PC). |
| `url` | Solo para URL y REPOSITORIO. `http://` o `https://`. |
| `fkTarchivo` | Solo para ARCHIVO. El pk devuelto por la subida (1.2) o elegido en la biblioteca de materiales (3). |
| `descripcion` | Nombre del material (opcional). |

Exactamente uno de `url`/`fkTarchivo` por elemento; **máximo 10 materiales**
(Regla 82).

Reglas por tipo (Regla 82):

- **URL - Sitio web:** el dominio, o un subdominio suyo, debe estar en el
  catálogo `DOMINIO_MATERIAL_URL` (Wikipedia, YouTube/youtu.be, Google
  Classroom, Moodle, MoodleCloud, Khan Academy, Colombia Aprende,
  MinEducación).
- **Unidad virtual - repositorio:** catálogo `DOMINIO_MATERIAL_REPOSITORIO`
  (Google Drive, Google Docs, Dropbox, OneDrive/1drv.ms, Mega, SharePoint).
  Ambas listas son configurables por catálogo (`TLISTA_VALOR`).
- **Archivo en PC:** formatos PDF, DOC, DOCX, XLS, XLSX, PPT, PPTX, JPG, JPEG,
  PNG, GIF, MP3, MP4, WEBM y TXT; máximo **20 MB**.
- Un tipo no admite la forma del otro (archivo con enlace, o enlace con
  archivo) → 400.

**Respuesta:** `{ "cantidad": 2 }`, el número de materiales que quedaron.

**Errores:** 404 si no existe; 400 si ya fue eliminada o el dato no cumple una
regla; 403 sin permiso o Regla 25; 409 si ya tiene resultados o es la original
de una recuperación (Regla 37).

**Roles:** `CEVAL-SUPER_ADMINISTRADOR` y `CEVAL-DOCENTE` (gate EDITAR sobre
PLANEADOR; también heredan el permiso los demás roles con menú de escritura
del Planeador).

### 1.2 `POST /planeador/actividades/:ID/materiales/archivo`

Paso 1 de un material tipo archivo: `multipart/form-data` con el campo
**`ARCHIVO`**. Lo guarda file-service (`fn_actividad_material_archivo_registrar`).

**Respuesta:** `{ "fk_tarchivo": 9876 }`, el valor que se envía como
`fkTarchivo` en 1.1. Si nunca se usa en un `PUT :ID/materiales`, no queda
asociado a la actividad.

**Errores:** los mismos cuatro de 1.1 (404/400/403/409), porque valida la
actividad antes de aceptar el archivo.

### 1.3 `GET /planeador/actividades/:ID/materiales/archivos`

Nombre y extensión de los archivos de los materiales de apoyo, una fila por
material con archivo. El detalle de la actividad trae el `fkTarchivo` pero no
el nombre ni la extensión; sin eso el front no puede decidir si previsualiza
un PDF, una imagen, un audio o un video.

| Columna | Significado |
|---|---|
| `pk_tactividad_material` | Material de la actividad. |
| `fk_tarchivo` | Archivo. |
| `nombre` | Nombre original del archivo. |
| `extension` | En minúsculas, sin punto (`pdf`, `png`, `mp4`...). |
| `peso` | Tamaño en bytes. |

Para **ver** el archivo hace falta además acuñar un token:
`POST /files/view-token/<fk_tarchivo>`.

---

## 2. Adaptaciones curriculares

Las adaptaciones (Bloque 6) permiten dejar una **versión modificada del
instrumento** para uno o varios estudiantes de la actividad: archivo, enlace o
una referencia a la biblioteca propia.

### 2.1 `PUT /planeador/actividades/:ID/adaptaciones`

Reemplaza las adaptaciones de la actividad `:ID`
(`fn_actividad_adaptacion_reemplazar`). `[]` = sin adaptaciones.

**Body:** `{ "ADAPTACIONES": [ { ... } ] }`, cada elemento:

| Campo | Significado |
|---|---|
| `tipoAdaptacion` | pk de `TIPO_ADAPTACION`. |
| `especificacionTipo` | Texto libre, máx. 150. **Obligatorio** cuando `tipoAdaptacion` es "Otro". |
| `descripcion` | Máx. 500 (obligatorio). |
| `usaVersionModificada` | `"S"`/`"N"` (default `N`). |
| `formatoAdaptacion` | Si `usaVersionModificada = "S"`: `ARCHIVO`, `ENLACE` o `BIBLIOTECA`. |
| `archivos` | **Nuevo.** `[fkTarchivo, ...]`, hasta **3**. Formatos PDF, DOC, DOCX, JPG, JPEG o PNG, máximo **10 MB** cada uno. Se usa con `formatoAdaptacion = ARCHIVO` o `BIBLIOTECA`. |
| `fkTarchivo` | Contrato anterior (un solo archivo). Se **suma** a `archivos`, sin duplicar; sigue aceptándose. |
| `url` | Si `formatoAdaptacion = ENLACE`: enlace http(s). |
| `nombrePlantilla` | **Nuevo.** Máx. 100. Nombre con el que la versión modificada queda disponible en `GET /planeador/adaptaciones-reutilizables`, la biblioteca del propio docente. |
| `aplicaA` | `TODO_EL_GRUPO` o `ESTUDIANTES_SELECCIONADOS`. |
| `estudiantes` | Si `ESTUDIANTES_SELECCIONADOS`: `pk_tmatricula` de la actividad (deben estar ya asignados; Regla 47). |

`BIBLIOTECA` referencia el archivo o enlace elegido en
`GET /planeador/adaptaciones-reutilizables` (sección 4): se reutiliza el mismo
`fkTarchivo`/`url`, no se duplica.

Con `formatoAdaptacion` en `ARCHIVO` o `BIBLIOTECA` se exige al menos un
archivo entre `fkTarchivo` y `archivos` (hasta 3 en total, sin repetidos).

**Respuesta:** `{ "cantidad": 2 }`, el número de adaptaciones que quedaron.

**Errores:** 404 si no existe; 400 si ya fue eliminada, falta
`especificacionTipo` con tipo "Otro", hay más de 3 archivos, el formato o
tamaño del archivo no es admitido, o algún estudiante no está asignado a la
actividad; 403 sin permiso o Regla 25; 409 si ya tiene resultados o es la
original de una recuperación (Regla 37).

**Roles:** `CEVAL-SUPER_ADMINISTRADOR` y `CEVAL-DOCENTE`.

### 2.2 `POST /planeador/actividades/:ID/adaptaciones/archivo`

Paso 1 de una versión modificada tipo archivo: `multipart/form-data` con el
campo **`ARCHIVO`**. Lo guarda file-service
(`fn_actividad_adaptacion_archivo_registrar`).

**Respuesta:** `{ "fk_tarchivo": 9876 }`, uno de los valores que se envían
dentro de `archivos` (o como `fkTarchivo`) en 2.1.

**Errores:** los mismos de 2.1.

---

## 3. Biblioteca de recursos: materiales reutilizables

Archivos que ya se subieron como material (sección 1) en **otras**
actividades del mismo establecimiento, para reusarlos sin volver a cargarlos.
Solo trae materiales **con archivo**: un enlace no se reutiliza, se copia.
Muestra lo de todos los docentes del colegio; para ver solo lo propio se
filtra por `?funcionario=`.

Hay dos rutas con la misma respuesta:

| Ruta | Cuándo usarla |
|---|---|
| `GET /planeador/actividades/:ID/materiales-reutilizables` | Al **editar** una actividad (`:ID` = la actividad; sus propios materiales se excluyen). |
| `GET /planeador/materiales-reutilizables?actividad=` o `?grupo=` | Al **crear**, cuando aún no hay actividad: se envía el `grupo` ya elegido. |

**Inputs (query):**

| Parámetro | Tipo | Significado |
|---|---|---|
| `actividad` | BIGINT | Solo en la ruta sin `:ID`. Alternativa a `grupo`. |
| `grupo` | BIGINT | Solo en la ruta sin `:ID`. Una de las dos (`actividad`/`grupo`) es obligatoria; sin ninguna responde 400 (22023). |
| `asignatura` | BIGINT | Solo materiales de actividades de esa asignatura. |
| `funcionario` | BIGINT | Solo los de unidades de ese docente (pk del funcionario). |
| `search` | VARCHAR | Busca en el nombre del archivo y el título de la actividad de origen. |
| `pagina` | INT | Página, desde 1 (default 1). |
| `size` | INT | Tamaño de página (default 20). |

**Outputs** (una fila por archivo; una fila más por cada actividad de origen
distinta si el archivo se reutilizó más de una vez):

| Columna | Significado |
|---|---|
| `fk_tarchivo` | El archivo. **Es lo que se envía como `fkTarchivo`** (con `tipoRecurso = ARCHIVO`) en `PUT :ID/materiales`. |
| `nombre_archivo` | Nombre del archivo. |
| `peso` | Tamaño en bytes. |
| `pk_tactividad_origen`, `titulo_actividad_origen` | Actividad donde se subió. |
| `fk_tlv_tipo_recurso`, `tipo_recurso` | Tipo - Fuente con que se registró. |
| `descripcion` | Nombre que le dio el docente al material. |
| `total_count` | Total de resultados, para el paginador (se repite en cada fila, via `COUNT(*) OVER()`). |

Orden: nombre del archivo y luego título de la actividad de origen.

**Roles:** `CEVAL-SUPER_ADMINISTRADOR` y `CEVAL-DOCENTE` (gate VER sobre
PLANEADOR).

---

## 4. Biblioteca de adaptaciones: `GET /planeador/adaptaciones-reutilizables`

Igual idea que la sección 3, pero para las versiones modificadas del
instrumento (adaptaciones curriculares). Es la opción **Biblioteca** del
Bloque 6 (`formatoAdaptacion = BIBLIOTECA`).

### Cambios de esta rama

- **Alcance propio (Regla 50):** antes mostraba lo de todo el establecimiento;
  ahora devuelve **solo las adaptaciones del propio docente solicitante** (las
  que él registró como versión modificada en otras actividades).
- **Incluye las de solo enlace:** antes solo traía adaptaciones con archivo;
  ahora también aparecen las que se guardaron como `url` sin archivo.
- **Filtro nuevo:** `?tipoAdaptacion=` (pk de `TIPO_ADAPTACION`), para acotar
  por el tipo que el docente ya eligió en el formulario.
- **Columnas nuevas:** `url`, `nombre_plantilla`, `pk_tactividad_adaptacion`,
  `archivos` (ver tabla de outputs).

### Inputs (query)

| Parámetro | Tipo | Significado |
|---|---|---|
| `actividad` | BIGINT | Al **editar** una actividad existente. |
| `grupo` | BIGINT | Al **crear**, cuando aún no hay actividad. |
| | | Una de las dos (`actividad`/`grupo`) es **obligatoria**; sin ninguna responde 400 (22023) — determina el alcance de permisos. |
| `asignatura` | BIGINT | Solo adaptaciones de actividades de esa asignatura. |
| `funcionario` | BIGINT | Solo las de unidades de ese docente. |
| `tipoAdaptacion` | BIGINT | **Nuevo.** Filtra por `fk_tlv_tipo_adaptacion`. |
| `search` | VARCHAR | Busca en nombre de plantilla, nombre de archivo, enlace y título de la actividad de origen. |
| `pagina` | INT | Página, desde 1 (default 1). |
| `size` | INT | Tamaño de página (default 20). |

### Outputs

Una fila por recurso (archivo o enlace); al elegirlo se **referencia**, no se
duplica.

| Columna | Significado |
|---|---|
| `fk_tarchivo`, `nombre_archivo`, `peso` | El archivo principal (contrato anterior, un solo archivo). |
| `url` | **Nuevo.** El enlace, si la adaptación se guardó como `formatoAdaptacion = ENLACE`. |
| `nombre_plantilla` | **Nuevo.** El `nombrePlantilla` con el que el docente la guardó. |
| `pk_tactividad_adaptacion` | **Nuevo.** La fila de adaptación de origen. |
| `archivos` | **Nuevo.** `jsonb`: `[{fkTarchivo, nombre, peso}]`, todos los archivos de la adaptación (contrato nuevo, hasta 3). |
| `pk_tactividad_origen`, `titulo_actividad_origen` | Actividad donde se registró. |
| `fk_tlv_tipo_adaptacion`, `tipo_adaptacion` | Tipo de adaptación con que se cargó. |
| `descripcion` | Descripción de la adaptación original. |
| `total_count` | Total para paginar. |

Para reutilizarla: `PUT :ID/adaptaciones` con `formatoAdaptacion = BIBLIOTECA`
y el mismo `fkTarchivo`/`archivos`/`url` que trajo esta fila.

**Roles:** `CEVAL-SUPER_ADMINISTRADOR` y `CEVAL-DOCENTE` (gate VER sobre
PLANEADOR).

---

## Resumen de rutas

| Método | Ruta | Qué hace |
|---|---|---|
| PUT | `/planeador/actividades/:ID/materiales` | Reemplaza los materiales de apoyo. |
| POST | `/planeador/actividades/:ID/materiales/archivo` | Sube el archivo de un material (paso 1). |
| GET | `/planeador/actividades/:ID/materiales/archivos` | Nombre/extensión de los archivos ya guardados. |
| PUT | `/planeador/actividades/:ID/adaptaciones` | Reemplaza las adaptaciones curriculares. |
| POST | `/planeador/actividades/:ID/adaptaciones/archivo` | Sube el archivo de una adaptación (paso 1). |
| GET | `/planeador/actividades/:ID/materiales-reutilizables` | Biblioteca de materiales, editando una actividad existente. |
| GET | `/planeador/materiales-reutilizables` | Biblioteca de materiales, creando una actividad (`?grupo=`/`?actividad=`). |
| GET | `/planeador/adaptaciones-reutilizables` | Biblioteca de adaptaciones del propio docente (`?grupo=`/`?actividad=`). |
