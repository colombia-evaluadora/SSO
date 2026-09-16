# Informes y consolidación de calificaciones

Guía del módulo para el front: qué endpoint sirve cada parte de la pantalla, qué
se manda, qué vuelve y **por qué** funciona así.

Son **11 endpoints**, todos `POST` y todos bajo `/api/eval-col/informes/...`.

```
POST /informes/periodos               los checkboxes de periodo
POST /informes/grupo                  la tabla principal
POST /informes/guardar                consolidar el informe completo
POST /informes/planillas-pendientes   alerta ROJA
POST /informes/cambios-pendientes     alerta NARANJA
POST /informes/historial              el modal de historial
POST /informes/planilla               la planilla de una asignatura
POST /informes/planilla/guardar       consolidar una sola asignatura
POST /informes/observacion/generar    redactar con IA (no persiste)
POST /informes/observacion/guardar    persistir lo que el docente aceptó
POST /informes/observacion/eliminar   quitar el resumen guardado
```

---

## Índice

1. [Por qué todos son POST](#1-por-qué-todos-son-post)
2. [Los dos ejes que gobiernan la respuesta](#2-los-dos-ejes-que-gobiernan-la-respuesta)
3. [Las tres notas: guardada, proyectada y requerida](#3-las-tres-notas)
4. [Permisos y errores](#4-permisos-y-errores)
5. [Referencia de cada endpoint](#5-referencia-de-cada-endpoint)
6. [Lo que todavía no existe](#6-lo-que-todavía-no-existe)

---

## 1. Por qué todos son POST

Cuatro reciben arreglos (`GRUPOS`, `PERIODOS`, `MATRICULAS`). **En este esquema
no hay un solo endpoint `GET` que pase un arreglo** — se revisó: `param_types`
con `[]` aparece únicamente en `POST` y `PUT`, siempre por body.

Los que no llevan arreglos van `POST` igual, por coherencia: los 11 endpoints de
una misma pantalla se consumen del mismo modo y no hay que recordar cuál es la
excepción. El `execution_mode` sigue siendo `SELECT`, así que los de lectura no
escriben nada.

### Los arreglos llevan NÚMEROS, no strings

```json
{ "GRUPOS": [11474] }      ← bien
{ "GRUPOS": ["11474"] }    ← 400
```

El binder valida **cada elemento** del arreglo. Con los escalares (`FK_TGRUPO`,
`FK_TMATRICULA`…) sí tolera un string que parsee como número, pero **nunca la
cadena vacía**: si un campo opcional no aplica, **quitá la clave** en vez de
mandar `""`.

`NULL` o arreglo vacío en un filtro significa **"todos"**, no "ninguno".

---

## 2. Los dos ejes que gobiernan la respuesta

Esta es la parte que más confunde, y es lo único que hay que entender bien.
`/informes/grupo` devuelve **una fila por (estudiante, periodo)** y cada fila
trae dos columnas que dicen cómo leerla. **Son independientes.**

### `formato` — ¿califica con números?

Sale del **criterio de evaluación** por `(asignatura, grado)`:

| Formato configurado | `formato` |
|---|---|
| `CIEN` · `CINCO` · `DIEZ` | `"numerico"` |
| `LITERAL` · `SIMBOLO` · `CARITA` | `"cualitativo"` |
| **sin criterio configurado** | `"cualitativo"` |

Las dimensiones de preescolar no tienen criterio → salen cualitativas. Esa es la
vía normal.

### `modo_periodo` — ¿qué significan los números de este periodo?

```
¿hay alguna nota (guardada o proyectada) en el periodo?
├─ SÍ  →  "real"        las notas son lo que el estudiante SACÓ
└─ NO  →  ¿el docente dejó observaciones?
          ├─ SÍ  →  "real" + formato "cualitativo"    ← preescolar
          └─ NO  →  ¿alguna asignatura es numérica?
                    ├─ SÍ  →  "requerido"   las notas son lo que NECESITA
                    └─ NO  →  "real" + "cualitativo"
```

### La tabla de decisión del front

| `formato` | `modo_periodo` | Qué renderizar |
|---|---|---|
| `cualitativo` | `real` | **Preescolar.** La columna OBSERVACIÓN. Ignorar promedio, puesto, aprobadas |
| `numerico` | `real` | La tabla normal: negro/gris, promedio, puesto, flechas |
| `numerico` | `requerido` | Las notas que **faltan**. Sin puesto. `promedio_proyectado` = el mínimo |

> **Nunca decidas mirando si `asignaturas` viene vacío.** En preescolar viene con
> filas, todas en `null`. La decisión se toma con `formato`.

### Por qué un solo endpoint y no dos

Porque los grupos **mixtos** existen: dimensiones y asignaturas numéricas
conviviendo. Con dos endpoints el front tendría que saber de antemano a cuál
llamar, y para el mixto no habría respuesta correcta. Así pregunta una vez y
cada fila se describe a sí misma.

---

## 3. Las tres notas

| Nota | De dónde sale | Qué significa |
|---|---|---|
| **guardada** | `TASIGNATURA_NOTA.DEFINITIVA` | lo consolidado — el **negro** |
| **proyectada** | recalculada desde las actividades | lo que daría hoy — el **gris** |
| **requerida** | despeje contra el mínimo del año | lo que le **falta sacar** |

### `estado_nota`, por asignatura

| Valor | Significa |
|---|---|
| `sin_nota` | no hay ninguna de las dos |
| `proyectada` | hay proyección y nunca se consolidó → **gris** |
| `guardada` | consolidada y la proyección coincide → **negro** |
| `cambio_propuesto` | consolidada y la proyección **difiere** → negro + gris |
| `requerido` | la nota que hace falta (solo en `modo_periodo: "requerido"`) |

`cambio_propuesto` con `nota_propuesta: null` significa **"la propuesta es que ya
no hay nota"**: el docente dio de baja las actividades que la sustentaban.

### Las flechas las dibuja el front

Se mandan las **dos notas ya homologadas** a la escala del colegio y el front
compara. No se manda una columna `tendencia` a propósito: sería duplicar un dato
derivado, y calcularla sobre porcentajes daría flecha cuando dos porcentajes
distintos redondean a la misma nota. **Comparando lo que se dibuja, la flecha
aparece solo si el número cambia a la vista.**

### La nota requerida

Cuando un periodo no tiene ninguna calificación, en vez de devolver todo en
`null` se calcula **cuánto necesita el estudiante ahí para no perder la
asignatura en el año**:

```
S = Σ(nota × peso)  de los periodos CON nota
W = Σ(peso)         de TODOS los periodos del año
E = Σ(peso)         de los periodos VACÍOS

requerido = (mínimo × W − S) / E
```

- El mínimo sale de `TCRITERIO_PROMOCION.DESEMPENHO_MINIMO`.
- La forma de combinar periodos sale de `TCRITERIO_EVALUACION.FK_TLV_CRITERIO_FINAL`
  (`1` equitativo, `2` por el % de cada periodo).
- **Cae a equitativo** si ese criterio no está configurado o si los porcentajes
  no suman 100. Ponderar con pesos rotos da un número que *parece* preciso y no
  lo es — y acá ese número le dice a un estudiante cuánto tiene que sacar.
- Si faltan varios periodos, se responde cuánto sacar en **cada uno** asumiendo
  lo mismo en todos.

Dos banderas acompañan cada valor:

| Bandera | Significa |
|---|---|
| `ya_asegurado: true` | el valor salió ≤ 0 — **no necesita nada**, ya le alcanza |
| `alcanzable: false` | supera el máximo — **ya perdió**, pase lo que pase |

El valor se devuelve **aunque supere 100**: necesitar 130 sobre 100 *es* la
información, y recortarlo la escondería.

---

## 4. Permisos y errores

Todos los endpoints validan contra el menú **`INFORMES`**:

| Acción | Endpoints |
|---|---|
| `VER` | periodos, grupo, planilla, las dos alertas, historial, observacion/generar |
| `EDITAR` | guardar, planilla/guardar, observacion/guardar |
| `ELIMINAR` | observacion/eliminar |

Además del permiso, cuenta el **alcance**: nivel 0 pasa, nivel 1 (territoriales)
llega a todos los EE, nivel 2 a los suyos, nivel 3 (docentes) a su **sede y
jornada**.

### Códigos

| SQLSTATE | HTTP | Cuándo |
|---|---|---|
| `P0002` | 404 | grupo, asignatura, periodo o matrícula que no existe |
| `22023` | 400 | periodo de otro año lectivo; arreglo de grupos vacío; observación vacía |
| `42501` | 403 | sin permiso o fuera de alcance |
| `23503` | 409 | el grado enviado no es el del grupo |

**En las dos alertas, un grupo fuera de alcance hace fallar la llamada entera**
con 403 — no se devuelve el resto en silencio. La alerta afirma hablar de "los
grupos seleccionados", y una respuesta incompleta que se ve completa es peor que
un error.

---

## 5. Referencia de cada endpoint

### `POST /informes/periodos`

Los checkboxes de periodo. **Todos los parámetros son opcionales.**

```json
{ "ANIO": 2026, "FK_TESTABLECIMIENTO": null, "FK_TSEDE": null }
```

Sin nada devuelve el **año en curso** dentro del alcance del usuario, que es lo
que hace la pantalla al abrirse.

`ANIO` es un **número**, no una FK, porque `TANO_LECTIVO` es por establecimiento
y "el año lectivo 2026" no existe como registro único: 2025 tiene 47 filas para
47 EE. `FK_TESTABLECIMIENTO` y `FK_TSEDE` solo **acotan**, nunca amplían.

Devuelve `termino` y `en_curso` ya calculados. `termino` es exactamente la
condición que usa la alerta roja, así que **no la reimplementes** con otro
criterio.

La sede y la jornada viajan porque dos periodos pueden llamarse igual en sedes
distintas del mismo EE.

---

### `POST /informes/grupo`

La tabla principal. **Una fila por (estudiante, periodo).**

```json
{ "FK_TGRUPO": 11474, "PERIODOS": [622, 627], "SEARCH": null }
```

`PERIODOS` vacío o ausente = todos los del periodo académico del grupo.
`SEARCH` filtra por nombre y documento, **después** de calcular el puesto —
buscar a alguien no cambia su posición. **Sin paginación**: se muestra el grupo
entero, y paginar rompería el puesto.

Columnas clave:

| Campo | |
|---|---|
| `modo_periodo`, `formato`, `es_cualitativo` | cómo leer la fila — [sección 2](#2-los-dos-ejes-que-gobiernan-la-respuesta) |
| `consolidado` | si el periodo ya se congeló |
| `promedio_guardado` / `promedio_proyectado` | negro / gris, a nivel estudiante |
| `puesto` | `RANK()` dentro del periodo. Empatados comparten puesto. `null` si no tiene promedio |
| `asignaturas` | **JSONB con las columnas MAT/LEN/CN…** |
| `observacion`, `observacion_estado`, `observacion_desactualizada` | el lado cualitativo |
| `tiene_cambios_propuestos` | para marcar la fila |

**`asignaturas` viene embebido** para que el front no necesite `1 + N` peticiones
para pintar una tabla:

```json
[{ "asignatura": 4190, "nombre": "MATEMATICAS", "abreviacion": "MAT",
   "area": "MATEMATICAS", "orden": 1,
   "nota": 2.5, "nota_propuesta": 2.3,
   "estado": "cambio_propuesto", "es_numerico": true,
   "valoracion": "alto", "simbolo": null, "aprobada": true }]
```

En `modo_periodo: "requerido"` las entradas cambian de forma:

```json
[{ "asignatura": 4190, "nombre": "MATEMATICAS",
   "nota": 34.6, "porcentaje": 34.58,
   "estado": "requerido", "ya_asegurado": false, "alcanzable": true }]
```

Y en modo requerido: `puesto` viene `null`, `promedio_proyectado` trae el
**mínimo del grado**, y `consolidado`/`promedio_guardado`/`aprobadas`/`reprobadas`
vienen vacíos o en cero.

---

### `POST /informes/guardar`

Congela el informe **completo** — todas las asignaturas del estudiante.

```json
{ "FK_TGRUPO": 11474, "FK_TPERIODO_EVALUACION": 622, "MATRICULAS": null }
```

`MATRICULAS` vacío o ausente = todo el grupo. **Un solo periodo por llamada**, a
diferencia de los de lectura: guardar es un acto puntual, y aceptar un arreglo
invitaría a consolidar varios de un clic sin ver qué se congela.

Devuelve **un informe por estudiante**, no un contador:

| `resultado` en `detalle` | |
|---|---|
| `guardada` | primera vez |
| `actualizada` | había otra — trae `anterior` |
| `sin_cambio` | ya estaba igual; **no se toca la fila**, para no borrar el `MODIFIED_AT` |
| `sin_proyeccion` | no hay actividad evaluativa calificada |

**Volver a llamarlo es seguro**: lo que no cambió sale `sin_cambio` y no se
escribe.

> **Preescolar no usa este endpoint.** Allí todo sale `sin_proyeccion` porque las
> observaciones se guardan con `CALIFICABLE='N'` y no promedian. Lo que se
> consolida es el resumen de la IA.

---

### `POST /informes/planillas-pendientes` — alerta **roja**

Planillas sin **nada** registrado.

```json
{ "GRUPOS": [11474, 11473], "PERIODOS": [622] }
```

`GRUPOS` es **obligatorio** y admite varios. Una fila por
`(grupo, asignatura, periodo)`.

**Solo considera periodos que YA TERMINARON** (`FECHA_FIN < hoy`). Un periodo en
curso no puede tener planillas pendientes: el docente está dentro de su plazo, y
marcarlo llenaría la alerta de rojo el primer día de cada periodo.

**Cuenta como calificado cualquier nota *u observación***, para que los docentes
de preescolar —que dejan comentarios, no números— no salgan como morosos.

`actividades: 0` significa que el docente **ni siquiera armó** las actividades;
mayor que 0, que las armó y no las calificó.

---

### `POST /informes/cambios-pendientes` — alerta **naranja**

Docentes que cambiaron notas **después** de consolidar. Mismo body que la roja.

Una fila por `(grupo, asignatura, periodo)` — **el periodo va en el grano** porque
el botón "Ir" lleva a la planilla y la planilla carga las actividades *de ese
periodo*.

- `SUM(estudiantes_afectados)` → el contador del botón
- `COUNT(DISTINCT fk_tgrupo)` → el encabezado del panel
- `fk_tfuncionario` + `fk_tgrupo` + `fk_tasignatura` → la ruta del botón "Ir"

El docente sale de `TDOCENTE_ASIGNATURA` (el asignado a esa asignatura en ese
grupo). `docentes_asignados > 1` avisa que la planilla se comparte — hay 397
combinaciones con más de un docente.

**Solo cuentan las asignaturas ya consolidadas.** Si el periodo nunca se guardó
no hay nada que "aprobar": la nota simplemente aún no se congeló.

---

### `POST /informes/historial`

El modal. **Todos los parámetros opcionales**; sin nada devuelve el año en curso.

```json
{ "GRUPOS": null, "PERIODOS": null, "ANIO": null, "LIMITE": 100 }
```

Una fila por **guardado**, de más reciente a más antiguo. `fecha` viene aparte de
`momento` para que el front agrupe por día ("Hoy", "Ayer", "07/08/2026") sin
recalcularlo.

**El conteo es por estudiante**: un estudiante guardado es un cambio. Guardar un
curso de 30 son 30 cambios, no 360 — contar cada calificación daría números
inutilizables.

`fk_tasignatura: null` = se guardó el **informe completo**; con valor = una sola
asignatura desde la planilla.

`detalle` trae la lista que se despliega:

```json
[{ "matricula": 223117, "estudiante": "JORGITO SANCHEZ",
   "documento": "131312131", "promedio": 77.71, "asignaturas": 2 }]
```

> El `promedio` es **el del momento del guardado** y no se recalcula. Si después
> alguien vuelve a consolidar, la entrada vieja sigue mostrando lo que mostró
> entonces. Esa es la diferencia entre un historial y un listado.

**Solo aparecen los días con movimiento**: volver a pulsar guardar sin cambios no
deja entrada.

---

### `POST /informes/planilla`

La planilla a la que llevan las dos alertas.

```json
{ "FK_TGRUPO": 11474, "FK_TASIGNATURA": 4190,
  "FK_TPERIODO_EVALUACION": 622, "SEARCH": null }
```

Una fila por estudiante con su definitiva del periodo —guardada y proyectada,
ambas también homologadas— y las actividades embebidas:

```json
[{ "orden": 1, "pkTactividad": 23, "titulo": "Taller de fracciones",
   "pkTactividadEstudiante": 4, "estado": "CALIFICADA",
   "porcentaje": 75, "nota": 3.0, "valoracion": "basico",
   "observacion": null, "esEvaluativa": true, "ponderacion": 35,
   "notaMaxima": 100, "instrumento": "RUBRICA",
   "fechaInicio": "2026-09-10", "fechaCierre": "2026-09-15" }]
```

`estado` por celda: `CALIFICADA` · `PENDIENTE` · `NO_ASIGNADA` · `NO_CALIFICABLE`.
`pkTactividadEstudiante` es la llave que el popover necesita para precargar y
guardar; viene `null` cuando la celda no aplica.

**Todas las filas traen las mismas columnas en el mismo orden**, incluidas las
`NO_ASIGNADA`, así que el header se arma con las celdas de cualquier fila y no
puede desalinearse del cuerpo.

#### El buscador: un texto, dos dimensiones

```
sin buscar        1 fila,  8 columnas
"JORG"  (alumno)  1 fila,  8 columnas   ← filtra filas, conserva columnas
"Taller" (activ.) 1 fila,  1 columna    ← conserva filas, filtra columnas
"zzz"   (nada)    0 filas, 0 columnas
```

La dimensión donde **nada coincidió se deja intacta**. Filtrar ambas siempre
vaciaría la tabla al escribir un nombre, porque ninguna actividad se llama como
un alumno.

> **No es** `/planeador/planilla/*`, que sirve a la planilla del docente y no se
> toca. Esta acota por periodo de evaluación, usa la misma proyección que
> detecta los cambios, y toma su línea base de `TASIGNATURA_NOTA`.

---

### `POST /informes/planilla/guardar`

Congela **una sola asignatura** — el botón "Aprobar y actualizar consolidado".

```json
{ "FK_TGRUPO": 11474, "FK_TASIGNATURA": 4190,
  "FK_TPERIODO_EVALUACION": 622, "MATRICULAS": [223117] }
```

Devuelve por estudiante el `resultado` (`guardada` · `actualizada` con
`nota_anterior` · `sin_cambio` · `sin_proyeccion`) **y además** el
`promedio_periodo`, `aprobadas` y `reprobadas` **ya recalculados**, para
refrescar la cabecera sin volver a pedir el listado.

**Convive con `/informes/guardar` sin pisarse**: `TASIGNATURA_NOTA` es por
`(matrícula, periodo, asignatura)`, y ambos terminan en el mismo recálculo de
métricas, así que el promedio del periodo queda coherente sin importar el orden.
Los dos son idempotentes.

En `sin_proyeccion` **lo ya guardado no se borra**: quitar un consolidado por una
ausencia no es decisión de un botón de guardar.

---

### Los tres de la observación (preescolar)

**Son tres actos distintos**, y esa separación es lo que sostiene el modelo de
estados.

#### `POST /informes/observacion/generar` — **no escribe**

```json
{ "FK_TMATRICULA": 222759, "FK_TPERIODO_EVALUACION": 622 }
```

Devuelve `observacion_ia` (el texto) y `observaciones_origen` (cuántas resumió).
Se puede llamar las veces que haga falta sin dejar rastro.

> ⚠️ **La IA está simulada.** Hoy concatena las observaciones que el docente dejó
> por actividad, en orden cronológico y prefijadas con el título. **El contrato
> ya es el definitivo**: cuando llegue el modelo, ni la ruta ni el body cambian.

#### `POST /informes/observacion/guardar` — acá nace la fila

```json
{ "FK_TMATRICULA": 222759, "FK_TPERIODO_EVALUACION": 622,
  "OBSERVACION": "lo que quedó en pantalla",
  "OBSERVACION_IA": "el borrador tal como lo recibiste",
  "OBSERVACIONES_ORIGEN": 3 }
```

El estado **se deduce comparando** los dos textos: iguales → `APROBADA`,
distintos → `MODIFICADA`. No se manda por parámetro para que no pueda
contradecir al texto.

> 🔴 **El front debe reenviar `OBSERVACION_IA` tal como la recibió.** Si no la
> manda, la función asume que se guardó tal cual y marca `APROBADA` — no puede
> distinguir "guardé sin editar" de "edité y se me olvidó mandar el original".

`OBSERVACIONES_ORIGEN` también se reenvía: comparándolo contra cuántas
observaciones hay hoy, el listado calcula `observacion_desactualizada` — el
equivalente cualitativo de `cambio_propuesto`.

**Guardar reemplaza**: el índice único es total sobre `(matrícula, periodo)`, así
que regenerar y volver a guardar pisa la versión anterior.

#### `POST /informes/observacion/eliminar`

```json
{ "FK_TMATRICULA": 222759, "FK_TPERIODO_EVALUACION": 622 }
```

**Borrado físico**, no baja lógica: el índice único es total, así que una fila
inactiva seguiría ocupando el lugar e impediría guardar una nueva. Y no hay nada
que conservar — el resumen se regenera desde las observaciones, que son el dato
original.

Después de eliminar, `/informes/grupo` vuelve a traer `observacion` y
`observacion_estado` en `null`, igual que antes de generar por primera vez.
Llamarlo dos veces responde **404**.

---

## 6. Lo que todavía no existe

Para que nadie lo busque:

| Falta | Nota |
|---|---|
| **Rechazar un cambio propuesto** | `cambio_propuesto` se *deriva* comparando, así que no hay dónde anotar "rechazado". Hoy la única forma de apagar la alerta es aceptar el valor. Requiere **estado nuevo**, no solo un endpoint |
| **Generar boletines (PDF)** | no hay endpoint ni clave de reporte |
| **Exportar la grilla** | ídem |
| **Botón de IA masivo** | `generar` recibe **una** matrícula; el masivo son N llamadas |
| **Tooltip "nota anterior / motivo"** | `planilla/guardar` devuelve `nota_anterior`, pero la celda del listado no expone el valor previo ni el motivo |
| **El periodo "4 / Final"** | no hay definitiva anual: `TASIGNATURA_DEFINITIVA` y `TAREA_DEFINITIVA` siguen sin escritores |

Y de `TCRITERIO_PROMOCION` **solo se usa `DESEMPENHO_MINIMO`**. `NODO_CURRICULAR`,
`APROBACION_PROMEDIO`, `MINIMO_INASISTENCIAS`, `CANTIDAD_NIVELAR`,
`MAX_ASIG_PROMEDIO` y `DESEMPENHO_MINIMO_GENERAL` no los lee nadie: toda la
lógica de nivelación, aprobación por promedio y reprobación por inasistencia
está sin implementar. Eso es alcance pendiente, no un defecto — pero es lo que
separa "consolidar periodos" de "promover estudiantes".
