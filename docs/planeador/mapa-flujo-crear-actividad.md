# Planeador — mapa del flujo de crear y calificar una actividad

Entradas y salidas de cada endpoint, en el orden en que la pantalla los llama.
Al final, el orden correcto para re-aplicar las migraciones de esta rama.

Ruta real a través del gateway: `api/eval-col/<path>`.
Gate común: menú `PLANEADOR` (`fn_assert_permiso_seccion`) + alcance territorial
(`fn_planeador_assert_alcance`, V277).

Estado leído del Postgres local `sso-postgres` con la rama
`feat/planeador-actividad-configuracion-evidencias` aplicada.

---

## Paso 0 — Los dos filtros de los que cuelga todo

La pantalla arranca con **grupo** y **asignatura**. De ahí salen el grado, el
nivel de enseñanza y el referente; no se eligen a mano.

| Endpoint | Entra | Sale |
|---|---|---|
| `GET /planeador/docentes/grupos` | `PERIODO` | Los grupos que dicta el docente |
| `GET /planeador/docentes/grado-asignatura` | `PERIODO` | Sus pares grado↔asignatura |

## Paso 1 — Los selects del formulario

### Estudiantes a asignar

| | |
|---|---|
| **Endpoint** | `GET /planeador/estudiantes` |
| **Entra** | `GRUPO` (obligatorio), `ASIGNATURA`, `ACTIVIDAD`, `SEARCH`, `SIZE`, `OFFSET` |
| **Sale** | `pk_tmatricula`, `fk_testudiante`, `estudiante`, `fk_tgrupo`, `grupo`, `fk_tgrado`, `grado`, `asignado`, `pk_tactividad_estudiante`, `total_count` |
| **Función** | `fn_planeador_estudiantes_candidatos_listar` (V422) |

- `ASIGNATURA` **no recorta** la lista: todos los matriculados del grupo cursan
  la asignatura. Se valida para que un contexto incoherente falle claro.
- Con `ACTIVIDAD` cada fila trae `asignado` y **`pk_tactividad_estudiante`**, que
  es el PK que piden después las adaptaciones, la nota y la observación — todas
  cuelgan de `TACTIVIDAD_ESTUDIANTE`, no de la matrícula.
- La actividad debe ser del mismo grupo o responde 22023.

### Unidades

| Endpoint | Entra | Sale |
|---|---|---|
| `GET /planeador/unidades` | `ASIGNATURA`, `GRADO`, `FUNCIONARIO`, `SEARCH`, `DIA`, `SIZE`, `OFFSET`, … | Listado + `referente_curricular`, `referente_vigente`, `total_actividades`, `estado`, `total_count` |
| `GET /planeador/unidades/:ID` | `ID` | Fila única + `objetivos`, `contenidos`, `campos_disponibles` (JSONB) |
| `POST /planeador/unidades` | `NOMBRE`, `FK_TASIGNATURA`, `FK_TGRADO`, `FK_TLV_CALCULO_DEFINITIVA`, `OBJETIVOS[]`, `CONTENIDOS[]`, `ENUNCIADOS[]`, `PONDERACION`, … | `BIGINT` (PK) |

### Referente curricular

| | Catálogo (para marcar) | Lo ya relacionado |
|---|---|---|
| **Endpoint** | `GET /planeador/referente-curricular` | `GET /planeador/unidades/:ID/referente` |
| **Entra** | `GRADO` (obligatorio), `ASIGNATURA`, `ANIO` | `ID` = PK_TUNIDAD |
| **Sale** | Arreglo de referentes ordenado por **prioridad** (0 lista el área, 1 sin áreas, 2 otras áreas — las áreas son preferencia, no exclusión, igual que la derivación), cada uno con `enunciados:[{pk, texto, fkReferenteCurricularArea, area, evidencias:[…]}]` | Contexto + referente + etiquetas + `enunciados` **solo los relacionados** |
| **Función** | `fn_refcurr_por_grado_asignatura` (V278) | `fn_unidad_referente_detalle` (V255) |

> **Cambio de contrato de esta rama.** V255 ya **no** devuelve el catálogo
> completo: solo los enunciados que la unidad relacionó (`TUNIDAD_ENUNCIADO`).
> Para *ofrecer* enunciados que marcar hay que usar V278. `relacionadoConUnidad`
> se conserva, siempre `true`.
> V278 filtra ahora los enunciados por `FK_REFERENTE_CURRICULAR_AREA`: un
> referente multi-área ya no devuelve los enunciados de otra área.

Relacionar/quitar: `POST /planeador/unidades/:ID/enunciados` (devuelve
`PK_TUNIDAD_ENUNCIADO`) y `PATCH /planeador/unidades/enunciados/:ID`, que pide
el PK de la **relación**, no el del enunciado.

## Paso 2 — Configuración dinámica del formulario

| | Sin unidad todavía | Con unidad | Con la actividad ya creada |
|---|---|---|---|
| **Endpoint** | `GET /planeador/actividades/configuracion` | `GET /planeador/unidades/:ID/configuracion-actividad` | `GET /planeador/actividades/:ID/configuracion` |
| **Entra** | `GRUPO`, `ASIGNATURA`, `UNIDAD` (opcional), `ES_EVALUATIVA` | `ID`, `ES_EVALUATIVA` | `ID` |
| **Función** | `fn_actividad_configuracion_contexto` (V422, cuerpo en V440) | `fn_unidad_configuracion_actividad` (V282, cuerpo en V440) | `fn_actividad_campos_disponibles` (V214.2, cuerpo en V440) |

Las tres devuelven el **mismo** `campos_disponibles` desde V440:

```jsonc
"campos_disponibles": {
  "criterio":     {"visible":…, "requerido":false, "motivo":"…"},
  "evaluacion":   {"visible":…, "requerido":…, "motivo":"…", "tipoEvaluacion":"…",
                   "instrumentosPermitidos":[{"pk":…,"valor":"RUBRICA","etiqueta":"Rúbrica","nombre":"Rúbrica"}]},
  "ponderacion":  {"visible":…, "requerido":…, "modo":"PORCENTAJE|PUNTAJE", "campo":"PONDERACION|NOTA_MAXIMA",
                   "autocalculado":…, "motivo":"…"},
  "recuperacion": {"visible":…, "requerido":false, "motivo":"…",
                   "catalogos":{"destino":[…],"tipoAplicacion":[…],"tipoCalculo":[…]},
                   "reglas":{…}}
}
```

- `instrumentosPermitidos` emite **`etiqueta` y `nombre`** con el mismo texto y un
  único orden alfabético. Antes cambiaba de clave y de orden según el endpoint.
- `recuperacion` depende de **dos** gates: referente `EVALUATIVO` **y**
  `ES_EVALUATIVA <> 'N'`. Los catálogos van como `{pk, valor, nombre}` y el front
  debe decidir por **`valor`**: los PK de `TLISTA_VALOR` no son estables entre
  entornos.

Solo el endpoint por contexto (V422) devuelve además **`programacion`**, los
topes de esa sección del formulario:

```jsonc
"programacion": {
  "periodoAcademico":  {"pk":…,"nombre":…,"fechaInicio":…,"fechaFin":…,"semanas":19},
  "intensidadHoraria": {"bloquesPorSemana":4,"diasHabiles":[{"valor":2,"nombre":"Lunes"},…]},
  "fechaInicio":       {"min":…,"max":…,"diasHabiles":[2,4,6],"motivo":"…"},
  "fechaCierre":       {"min":…,"max":…,"diasHabiles":[2,4,6],"motivo":"…"},
  "semanaCronograma":  {"min":1,"max":19,"motivo":"…"},
  "duracionEstimada":  {"min":1,"max":76,"unidad":"BLOQUES","motivo":"…"}
}
```

La ventana la fija el periodo académico del grado y los días hábiles el horario
de ese (grupo, asignatura). **Cuando falta el dato base no se inventa tope**:
viene `null` con su `motivo`. Estos límites **se validan también al escribir**
(`fn_actividad_programacion_assert`), así que un cliente que los ignore recibe
22023.

## Paso 3 — Crear la actividad

| | |
|---|---|
| **Endpoint** | `POST /planeador/actividades` → `fn_actividad_crear` (V224) |
| **Sale** | `BIGINT` = `PK_TACTIVIDAD` |

Entradas agrupadas por sección de la pantalla:

| Sección | Campos |
|---|---|
| Identificación | `TITULO`, `DESCRIPCION`, `FK_TASIGNATURA`, `FK_TGRUPO`, `FK_TUNIDAD`, `FK_TLV_TIPO_ACTIVIDAD`, `FK_TLV_JERARQUIA` |
| Programación | `FECHA_INICIO`, `FECHA_CIERRE`, `DURACION_ESTIMADA`, `SEMANA_CRONOGRAMA`, `FK_TLV_MODALIDAD` |
| Evaluación | `ES_EVALUATIVA`, `FK_TLV_INSTRUMENTO_EVALUACION`, `DESCRIPCION_INSTRUMENTO`, `FK_TLV_TIPO_EVIDENCIA`, `FK_TLV_METODO_VALORACION`, `FK_TLV_TIPO_CALCULO`, `PONDERACION`, `INFLUENCIA`, `NOTA_MAXIMA` |
| Estudiantes | `FK_TMATRICULAS[]`, `ASIGNAR_TODO_EL_GRUPO` |
| Relaciones | `EVIDENCIAS[]` (PK de `TREFERENTE_ENUNCIADO`), `CRITERIOS[]` (PK de `TCRITERIO_UNIDAD`) |
| Otros | `MATERIALES` (JSONB), `ADAPTACIONES` (JSONB), `RECUPERACION` (JSONB), `MATERIAL_REQUERIDO`, `OBSERVACIONES_DOCENTE`, `REQUIERE_*`, `GENERA_EVIDENCIAS` |

`RECUPERACION` es `{destino, fkActividadRecuperar, tipoAplicacion, tipoCalculo,
valorPonderacion}`: `fkActividadRecuperar` obligatorio sii `destino=ACTIVIDAD`;
`valorPonderacion` obligatorio y 0..100 sii `tipoCalculo=PONDERADO`.

## Paso 4 — Instrumento

| | Leer | Definir |
|---|---|---|
| **Endpoint** | `GET /planeador/actividades/:ID/instrumento` | `PUT /planeador/actividades/:ID/instrumento` |
| **Entra** | `ID` | `ID`, `DEFINICION` (JSONB) |
| **Sale** | `instrumento`, `instrumento_nombre`, `definicion` | `VARCHAR` = instrumento aplicado |

`definicion` cambia de forma según el instrumento:

| Instrumento | Forma |
|---|---|
| `RUBRICA` | `[{pk, orden, nombre, descripcion, niveles:[{pk, etiqueta, descripcion, ponderacion}]}]` (niveles por ponderación DESC) |
| `LISTA_COTEJO` | `[{pk, orden, descripcion, ponderacion}]` |
| `ESCALA_VALORACION` | `{tipoEscala, criteriosGenerales, valorMin, valorMax, interpretacionRangos, niveles:[…]}` |
| `OTRO` | `{pk, tipoEvidencia, metodoValoracion, definicion}` — `definicion` reutiliza una de las tres formas anteriores |

## Paso 5 — Listar actividades

| Endpoint | Entra | Sale |
|---|---|---|
| `GET /planeador/actividades` | `SEARCH`, `ASIGNATURA`, `GRUPO`, `UNIDAD`, `TIPO_ACTIVIDAD`, `INSTRUMENTO`, `FECHA_DESDE/HASTA`, `ESTADOS`, `DIA`, `DIAS_GRACIA`, `INCLUIR_INACTIVAS`, `ORDEN_POR/ASC`, `SIZE`, `OFFSET` | 34 columnas: identificación, `estado` derivado, `es_evaluativa`, **`es_recuperacion`**, `estudiantes_asignados/evaluados`, `porcentaje_evaluado`, `dia/dia_anterior/dia_siguiente`, `total_count` |
| `GET /planeador/actividades/mias` | igual, sin los de tipo/instrumento | igual, acotado al docente |

`es_recuperacion` es nuevo en esta rama: antes había que abrir el detalle.

### Detalle

`GET /planeador/actividades/:ID` → `fn_actividad_buscar_por_pk`: 53 columnas,
incluidas `materiales`, `adaptaciones`, `recuperacion`, **`evidencias`**,
**`criterios`**, **`estudiantes`**, `campos_disponibles` y `unidad_configuracion`
(la unidad completa: referente, objetivos, contenidos, rúbrica y enunciados con
sus evidencias). Es decir, **todo lo que la actividad tiene relacionado en una
sola llamada**. `estudiantes` = `[{pkTactividadEstudiante, pkTmatricula,
fkTestudiante, estudiante, calificacion, calificable, observacion}]`.

`GET /planeador/actividades/:ID/pantalla-edicion` devuelve el mismo contenido ya
compuesto como un solo JSONB, con `esRecuperacion`, `recuperacion`, `evidencias`
y `criterios`.

> `evidencias` y `criterios` son nuevos. Antes se podían escribir pero **no
> leer**, así que al reabrir una actividad no se podían pre-marcar ni obtener
> los PK que piden los PATCH para quitarlos.

## Paso 6 — Calificar

### Individual

| | |
|---|---|
| **Endpoint** | `PUT /planeador/actividades/estudiantes/:ID/calificar` |
| **`:ID`** | **`PK_TACTIVIDAD_ESTUDIANTE`**, no la matrícula |
| **Entra** | `CALIFICACION` (JSONB), `FECHA` |
| **Sale** | `NUMERIC` = % 0-100 |

`CALIFICACION` según el instrumento:

| Instrumento | Payload |
|---|---|
| `RUBRICA` | `{"niveles":[{"pkCriterio":…,"pkNivel":…}]}` — set completo, reemplazo total |
| `LISTA_COTEJO` | `{"itemsMarcados":[pk,…]}` |
| `ESCALA_VALORACION` | `{"pkNivel":…}` o `{"valorNumerico":…}` |
| `OTRO` | `{"porcentaje":…}`, o el payload del método equivalente si tiene uno configurado |

### Bulk

`PUT /planeador/actividades/:ID/calificar-bulk/{rubrica,cotejo,escala}` — el flujo
real de la pantalla: una columna aplicada a varios marcados.

| Variante | Entra | Sale |
|---|---|---|
| `rubrica` | `PK_CRITERIO`, `PK_NIVEL`, `ESTUDIANTES[]`, `FECHA` | por estudiante: `criterios_totales`, `criterios_cubiertos`, `calificacion`, `calificacion_actualizada` |
| `cotejo` | `PK_ITEM`, `CUMPLIDO`, `ESTUDIANTES[]`, `FECHA` | por estudiante: `items_totales`, `items_cumplidos`, `calificacion` |
| `escala` | `PK_NIVEL` o `VALOR_NUMERICO`, `ESTUDIANTES[]`, `FECHA` | por estudiante: `calificacion` |

El bulk de rúbrica hace upsert **solo de ese criterio**; la versión individual
exige el set completo y reemplaza todo.

### Leer la nota

`GET /planeador/actividades/estudiantes/:ID/nota` → `instrumento`, `calificacion`
(% 0-100, **sin homologar**), `calificable`, `observacion`, `detalle` (por
instrumento) y **`evidencias`**.

Las bandas visuales (Bajo/Básico/Alto/Superior) salen aparte de
`GET /planeador/unidades/:ID/valoraciones`.

### Tres trampas del calificar

1. **Sin asistencia no se califica.** `fn_actividad_nota_asistencia_assert` exige
   una fila activa de `TASISTENCIA` para (matrícula, asignatura, **fecha exacta**)
   o 22023; la inasistencia injustificada también bloquea, la justificada no.
2. **Las actividades de referente FORMATIVO se rechazan** con 22023: van por
   observación.
3. `BODY.FECHA` por defecto es **hoy**, y es la que se cruza con la asistencia.

## Paso 7 — Editar la actividad

`PUT /planeador/actividades/:ID` → `fn_actividad_actualizar`. Acepta todo lo del
alta **más** `DESVINCULAR_UNIDAD` y `QUITAR_RECUPERACION`, y desde esta rama
`EVIDENCIAS[]` y `CRITERIOS[]` con semántica de reemplazo (antes solo el POST).

Endpoints sueltos, que siguen valiendo para cambios puntuales:

| Acción | Endpoint | Devuelve |
|---|---|---|
| Fijar estudiantes | `PUT /planeador/actividades/:ID/estudiantes` (`FK_TMATRICULAS[]`, `ASIGNAR_TODO_EL_GRUPO`) | total asignados |
| Relacionar evidencia | `POST /planeador/actividades/:ID/evidencias` | `PK_TACTIVIDAD_EVIDENCIA` |
| Quitar evidencia | `PATCH /planeador/actividades/evidencias/:ID` | `BOOLEAN` |
| Relacionar criterio | `POST /planeador/actividades/:ID/criterios` | `PK_TACTIVIDAD_CRITERIO_UNIDAD` |
| Quitar criterio | `PATCH /planeador/actividades/criterios/:ID` | `BOOLEAN` |
| Materiales / adaptaciones | `PUT .../materiales`, `PUT .../adaptaciones` | nº de filas (reemplazo total) |
| Borrar | `PATCH /planeador/actividades/:ID` | `BIGINT` (borrado lógico) |

> Quitar un estudiante desactiva su `TACTIVIDAD_ESTUDIANTE`, y con él las
> adaptaciones, la nota y las evidencias que colgaban de esa fila.

## Paso 8 — Observaciones (Preescolar / referente FORMATIVO)

No hay nota numérica: hay texto y, desde esta rama, **imágenes**.

| | Individual | Grupal |
|---|---|---|
| **Endpoint** | `PUT /planeador/actividades/estudiantes/:ID/observar` | `POST /planeador/actividades/:ID/observar-grupal` |
| **`:ID`** | `PK_TACTIVIDAD_ESTUDIANTE` | `PK_TACTIVIDAD` |
| **Entra** | `OBSERVACION`, `FECHA`, `EVIDENCIAS[]` | `OBSERVACION`, `FECHA`, `EVIDENCIAS[]` |
| **Sale** | `void` | `INT` = estudiantes observados |

- El texto va a `TACTIVIDAD_NOTA.OBSERVACION` con `CALIFICACION=NULL` y
  `CALIFICABLE='N'`. Hay **una sola observación viva** por estudiante-actividad:
  la individual pisa a la grupal.
- `EVIDENCIAS[]` son `PK_TARCHIVO`; el binario se sube **antes** por el
  file-service (`POST /api/files/**`). Se guardan en `TACTIVIDAD_SOPORTE`, que es
  N:1 y por eso admite varias imágenes. Semántica de reemplazo: omitir no toca,
  array vacío quita.
- En la grupal, las evidencias se adjuntan a **cada** observado.
- Se leen en `GET /planeador/actividades/estudiantes/:ID/nota` → `evidencias`.
- La grupal **omite** (no falla) a quien no tenga asistencia válida ese día.

> `TASISTENCIA.FK_SOPORTE_ARCHIVO`, que aparece en el listado de calificaciones,
> es el soporte de la **excusa de inasistencia**, no una evidencia de la
> observación.

## Paso 9 — Planilla de calificación

| Endpoint | Entra | Sale |
|---|---|---|
| `GET /planeador/planilla/columnas` | `GRUPO`, `ASIGNATURA`, `GRADO`, `FECHA_DESDE/HASTA`, `SEARCH` | Una fila por actividad-columna: `orden_columna`, `titulo`, `unidad`, `instrumento`, `instrumento_nombre`, **`metodo_valoracion`**, `ponderacion`, `nota_maxima`, `es_evaluativa`, **`es_formativa`**, fechas, asignados/calificados |
| `GET /planeador/planilla/calificaciones` | ídem + `SEARCH_ESTUDIANTE`, `SIZE`, `OFFSET` | Una fila por estudiante: `nombre_estudiante`, `definitiva_proyectada`, `definitiva_registrada`, `tendencia`, `celdas` (JSONB), `total_count` |

Cada celda:

```jsonc
{"ordenColumna":…, "pkTactividad":…, "pkTunidad":…, "pkTactividadEstudiante":…,
 "esFormativa":…, "estado":"SIN_CALIFICAR|NO_CALIFICABLE|NO_ASIGNADA|…",
 "calificacion":…, "recuperacion":…, "definitiva":…, "nota":…, "calificable":…,
 "observacion":…, "fechaAsistencia":"2026-08-27", "tieneAsistencia":true,
 "evidencias":[{"pk":…,"fkTarchivo":…,"nombre":…,"fecha":…}]}
```

- **`fechaAsistencia` es la que hay que mandar en `BODY.FECHA` al calificar.** Es
  la fecha, dentro de la ventana de la actividad, en que ese estudiante tiene
  asistencia que el gate va a aceptar — resuelta por la llave correcta
  (`FK_TACTIVIDAD` si es formativa, `FK_TASIGNATURA` si no) y excluyendo la
  inasistencia injustificada. Sin esto, calificar desde la planilla daba 22023
  casi siempre, porque el endpoint cae a `CURRENT_DATE`.
- `tieneAsistencia = false` → celda gris: no se puede calificar hasta registrar
  asistencia. Es una foto del momento de la lectura.
- `es_formativa` / `esFormativa` dicen si abrir el popover de **observación** en
  vez del de nota. No confundir con `es_evaluativa`, que es un flag manual de
  `TACTIVIDAD` con default `'S'`.
- `definitiva_registrada` y `tendencia` **son siempre NULL** hoy: nada consolida
  `TUNIDAD_NOTA`. No pintes flecha mientras `tendencia` sea NULL.

---

# Orden de re-aplicación de las migraciones

Re-aplicar solo el fichero editado **no basta**: si define una función que una
migración posterior reescribió, re-ejecutarlo resucita la versión vieja. Ya pasó
en el servidor de test (V29 revirtió V294/V295/V298/V302).

Calculado con `python scripts/migration-reapply-set.py V214.2 V224 V241 V243
V246 V255 V278 V282 V353 V422 V440 V441`:

```
V214.2__planeador_campos_dinamicos_configuracion.sql
V224__fn_actividad_crud.sql
V241__fn_actividad_nota_calificar_otro_estructurado.sql
V243__planeador_preescolar_observar.sql
V246__query_endpoints_actividad.sql
V251__query_endpoint_calendario_docente.sql          <- ARRASTRADA
V255__fn_unidad_referente_detalle.sql
V278__fn_refcurr_por_grado_asignatura.sql
V282__fn_unidad_configuracion_actividad.sql
V353__fn_actividad_pantalla_edicion.sql
V422__planeador_estudiantes_y_configuracion_contexto.sql
V440__campos_disponibles_actividad_unificado.sql
V441__planilla_asistencia_formativa.sql
```

Dos entradas no son obvias y son justo las que rompen si se omiten:

- **V251 no se editó**, pero redefine `fn_actividad_calendario`, que V224 también
  define. Re-aplicar V224 sin V251 deja viva la versión vieja del calendario.
- **V440 no se editó**, pero redefine `fn_actividad_campos_disponibles` y
  `fn_unidad_configuracion_actividad`. Re-aplicar V214.2 o V282 sin V440 revierte
  la unificación.

Y una dependencia que la herramienta **no** detecta, porque es una llamada y no
una redefinición:

> **V224 y V422 tienen que ir en el mismo despliegue.** `fn_actividad_crear` y
> `fn_actividad_actualizar` (V224) llaman a `fn_actividad_programacion_assert`,
> que define V422. Si el set se parte, crear o editar una actividad responde
> **42883**. El orden entre ambas da igual: PL/pgSQL resuelve el cuerpo en
> ejecución, y ninguna migración las invoca en tiempo de migración.

Procedimiento en el servidor: `flyway repair` para los checksums cambiados y
después re-ejecutar ese set **en el orden de arriba**.
