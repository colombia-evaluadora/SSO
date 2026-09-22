# Informes y consolidación de calificaciones

Guía del módulo para el front: qué endpoint sirve cada parte de la pantalla, qué
se manda, qué vuelve y **por qué** funciona así.

Son **15 endpoints**, todos `POST` y todos bajo `/api/eval-col/informes/...`.

```
POST /informes/sedes                  select 1 -- la sede
POST /informes/anos                   select 2 -- el año
POST /informes/jornadas               select 3 -- la jornada
POST /informes/grupos-periodo         los grupos de esa combinación
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

> El **boletín de preescolar** —el PDF con el fondo institucional y las fotos de
> evidencia— es otro endpoint y tiene su propia guía:
> [`boletin-preescolar.md`](boletin-preescolar.md).

---

## Índice

0. [La cascada: sede → año → jornada](#0-la-cascada-sede--año--jornada) ← **empezá por acá**
1. [Por qué todos son POST](#1-por-qué-todos-son-post)
2. [Los dos ejes que gobiernan la respuesta](#2-los-dos-ejes-que-gobiernan-la-respuesta)
3. [Las tres notas: guardada, proyectada y requerida](#3-las-tres-notas)
4. [Permisos y errores](#4-permisos-y-errores)
5. [Referencia de cada endpoint](#5-referencia-de-cada-endpoint)
6. [Lo que todavía no existe](#6-lo-que-todavía-no-existe)

---

## 0. La cascada: sede → año → jornada

Todo lo demás cuelga de acá, así que va primero.

```
POST /informes/sedes    {}                                   -> elige SEDE
POST /informes/anos     {FK_TSEDE}                           -> elige AÑO
POST /informes/jornadas {FK_TSEDE, ANIO}                     -> elige JORNADA
      │
      ├── POST /informes/periodos       {FK_TSEDE, ANIO, FK_TLV_JORNADA}
      └── POST /informes/grupos-periodo {FK_TSEDE, ANIO, FK_TLV_JORNADA}
                                              │
                                              └── POST /informes/grupo {FK_TGRUPO, PERIODOS}
```

Esos tres valores resuelven **un periodo académico**, y de ese periodo salen los
periodos de evaluación y los grupos. No hace falta mandar el
`FK_TPERIODO_ACADEMICO`: el backend lo resuelve con la terna.

### Qué cambió respecto de la versión anterior

| | antes | ahora |
|---|---|---|
| `/informes/periodos` | cuerpo opcional; devolvía **todo el año de todas las sedes y jornadas** del alcance | `FK_TSEDE` y `FK_TLV_JORNADA` **obligatorios**; devuelve solo los del periodo académico resuelto |
| lista de grupos | `GET /planeador/docentes/grupos` | `POST /informes/grupos-periodo` |

Las dos son **rupturas de contrato**: la pantalla no carga con `{}` y la lista de
grupos cambia de ruta y de forma.

Lo de los grupos no era solo cosmético. `/planeador/docentes/grupos` exige permiso
del menú **PLANEADOR** (quien tenía `INFORMES` y no `PLANEADOR` no podía abrir la
pantalla) y además solo devuelve los grupos **donde el docente dicta** — un rector,
una secretaria o un coordinador no veían ninguno. El endpoint nuevo no filtra por
quién dicta: qué grupos ve cada quien lo decide el permiso `INFORMES/VER` con su
alcance.

### Por qué hacía falta

`/informes/periodos` devolvía los periodos de evaluación de todo el año dentro del
alcance del usuario. Medido en test, alguien con alcance total recibía **8 periodos
de 5 sedes de 3 establecimientos con solo 4 nombres distintos**: media lista eran
"Primer periodo" repetidos, indistinguibles salvo por la sede que venía en la fila.

### Detalles que te van a morder

- **El `FK_TPERIODO_ACADEMICO` viene gratis.** `/informes/jornadas` devuelve una
  fila **por periodo académico**, no por jornada distinta, y cada fila trae su PK.
  Hoy la terna resuelve siempre uno solo, pero ningún índice lo garantiza (el único
  `UNIQUE` es `(año, sede, NOMBRE)` y no incluye la jornada) y en el histórico
  aparecieron 24 casos, varios de colegios por ciclos: `"2015"` y `"2015BH CICLO VI"`,
  misma sede y jornada. Si alguna vez te llegan dos filas con la **misma** jornada,
  mostralas las dos con su `periodo_nombre` y avisanos: los endpoints de abajo
  reciben la terna, no la PK, así que hoy se quedarían con el periodo de fecha más
  reciente. Pasarles la PK es un cambio chico, pero hay que hacerlo.
- **El año es un número** (`2026`), no una FK. `TANO_LECTIVO` es por establecimiento:
  "el año lectivo 2026" no existe como registro único — 2025 tiene 47 filas.
- **Solo el año en curso y los anteriores.** Hay periodos ya creados para 2027-2029
  y no se ofrecen: es configuración adelantada.
- **La jornada del grupo no es la del periodo académico.** De 5.339 grupos activos,
  5.277 difieren, porque en los años viejos el periodo se creaba como "Completa" y la
  jornada real vivía en el grupo. Por eso `grupos-periodo` **no** filtra por la
  jornada del grupo — te la devuelve como columna para que agrupes o rotules.
- **Elegir una sede ajena es `403`, no una lista vacía.** Desde que la sede y la
  jornada viajan en el cuerpo, el permiso se valida antes de leer.

---

## 1. Por qué todos son POST

Cuatro reciben arreglos (`GRUPOS`, `PERIODOS`, `MATRICULAS`). **En este esquema
no hay un solo endpoint `GET` que pase un arreglo** — se revisó: `param_types`
con `[]` aparece únicamente en `POST` y `PUT`, siempre por body.

Los que no llevan arreglos van `POST` igual, por coherencia: los 15 endpoints de
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
| `numerico` | `final` | La nota del **año**. Se pide con `-1` en `PERIODOS` — [abajo](#la-fila-final) |
| `cualitativo` | `final` | La misma fila, vacía: no se promedian observaciones |

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
| `VER` | sedes, anos, jornadas, grupos-periodo, periodos, grupo, planilla, las dos alertas, historial, observacion/generar |
| `EDITAR` | guardar, planilla/guardar, observacion/guardar |
| `ELIMINAR` | observacion/eliminar |

Además del permiso, cuenta el **alcance**: nivel 0 pasa, nivel 1 (territoriales)
llega a todos los EE, nivel 2 a los suyos, nivel 3 (docentes) a su **sede y
jornada**.

Los tres selects de la cascada aplican **ese mismo alcance** al armar sus listas,
así que un rol de nivel 3 ve su sede y una sola jornada en vez de opciones que
después le responderían 403. Medido: niveles 0 y 1 ven 36 sedes, un nivel 2 ve 4
y un nivel 3 ve 1.

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

> **Sobre los ejemplos.** El motor de queries del SSO envuelve **todo** resultado
> de lectura en `{ "rows": [...] }`, así que eso es lo que llega por HTTP aunque
> acá se muestre a veces solo la fila. Los ejemplos de respuesta salen de
> llamadas reales al servidor de test; los tres que no se pudieron ejecutar están
> marcados como **FORMA** — hoy ningún dato de test los produce (ninguna
> actividad calificada cae dentro de un periodo de evaluación, así que no hay
> informes guardados, ni cambios posteriores a un guardado, ni observaciones
> resumibles). Los nombres de columna de esos tres salen del `RETURNS TABLE` de
> la función, que es la fuente de verdad.
>
> Ojo con un detalle que muerde: la abreviación del periodo se llama
> **`abreviacion`** en `/informes/periodos` y **`periodo_abreviacion`** en
> `/informes/grupo`, `/informes/historial` y las dos alertas.

### `POST /informes/sedes`

Primer select. **Sin cuerpo** (`{}`).

No recibe parámetros a propósito: el alcance sale de quien pregunta, no del body.
Si se pudiera pedir un establecimiento, se podría sondear cuáles existen mirando
cuál devuelve vacío.

Devuelve solo sedes **activas, de un EE activo y con al menos un periodo académico**
del año en curso o anterior — una sede sin periodos no da informes y ofrecerla solo
lleva a un segundo select vacío. Cada fila trae el establecimiento, porque quien
alcanza varios necesita distinguir sedes de nombre parecido.

```json
{ "fk_tsede": 1671, "sede_nombre": "colegio chino",
  "fk_testablecimiento": 890, "establecimiento_nombre": "colegio chino" }
```

---

### `POST /informes/anos`

Segundo select.

```json
{ "FK_TSEDE": 1671 }
```

Devuelve `{ "anio": 2026, "es_actual": true }`, de mayor a menor. `es_actual` está
para que preselecciones sin volver a calcular la fecha.

**Solo el año en curso y anteriores.** `FK_TSEDE` acota y nunca amplía; sin él
devuelve los años de todo el alcance.

---

### `POST /informes/jornadas`

Tercer select.

```json
{ "FK_TSEDE": 1671, "ANIO": 2026 }
```

Sin `ANIO` toma el año en curso.

```json
{ "fk_tlv_jornada": 51900, "jornada_nombre": "Completa",
  "fk_tperiodo_academico": 1780, "periodo_nombre": "2026 - C",
  "fecha_inicio": "2026-09-02", "fecha_fin": "2026-12-12", "en_curso": true }
```

Una fila **por periodo académico**. Mostrá `jornada_nombre`; guardate
`fk_tperiodo_academico` por si algún día llegan dos filas con la misma jornada
(ver [sección 0](#0-la-cascada-sede--año--jornada)).

---

### `POST /informes/grupos-periodo`

Los grupos del periodo académico que resuelve la terna. Reemplaza a
`GET /planeador/docentes/grupos`.

```json
{ "FK_TSEDE": 1671, "ANIO": 2026, "FK_TLV_JORNADA": 51900, "SEARCH": null }
```

```json
{ "grupo_id": 11484, "grupo_codigo": null, "grupo_nombre": "01",
  "grupo_etiqueta": "-201", "capacidad": 1, "estudiantes": 1,
  "jornada_id": 51900, "jornada_nombre": "Completa",
  "grado_id": 3749, "grado_codigo": "-2", "grado_nombre": "Pre-Jardin",
  "nivel_ensenanza_id": 1, "nivel_ensenanza_nombre": "Preescolar",
  "director_id": 3587743, "director_nombre": "ALEJANDRO TORO",
  "fk_tperiodo_academico": 1780 }
```

- `grupo_etiqueta` viene armada con la misma convención del planeador, para que las
  dos pantallas rotulen igual. **Los códigos negativos de preescolar son correctos**:
  grado `-1` + grupo `01` → `-101`, no es un signo perdido.
- `estudiantes` son las matrículas activas. Un grupo en cero no tiene informe que
  mostrar, y verlo antes de abrirlo ahorra el viaje.
- `SEARCH` filtra por nombre y código de grupo, nombre de grado y la etiqueta
  compuesta — quien escribe "quinto a" lo encuentra aunque ese texto no exista
  entero en ninguna columna.
- **No filtra por quién dicta.** Eso lo decide el permiso.

---

### `POST /informes/periodos`

Los checkboxes de periodo, del periodo académico que resuelve la terna.

```json
{ "FK_TSEDE": 1671, "ANIO": 2026, "FK_TLV_JORNADA": 51900 }
```

> **Cambió el contrato.** Antes aceptaba `{}` y devolvía todo el año de todas las
> sedes del alcance. Ahora `FK_TSEDE` y `FK_TLV_JORNADA` son **obligatorios**; sin
> `ANIO` se toma el año en curso.

`ANIO` es un **número**, no una FK, porque `TANO_LECTIVO` es por establecimiento y
"el año lectivo 2026" no existe como registro único: 2025 tiene 47 filas para 47 EE.

Devuelve `termino` y `en_curso` ya calculados. `termino` es exactamente la
condición que usa la alerta roja, así que **no la reimplementes** con otro
criterio. `calificable` viene resuelto del catálogo.

Errores propios: `403` si no alcanzás esa sede y jornada, `404` (`P0002`) si no hay
periodo académico para esa combinación — un error explícito en vez de una lista
vacía que se confunde con "no hay nada configurado".

La sede, la jornada y el establecimiento siguen viajando en cada fila aunque ahora
sean siempre los mismos: así podés rotular la pestaña sin arrastrar lo que eligió
el usuario.

**Respuesta** (real, 2 de 2 filas)

```json
{
  "rows": [
    {
      "fk_tperiodo_evaluacion": 625,
      "codigo": "01",
      "nombre": "Primer periodo",
      "abreviacion": "P1",
      "fecha_inicio": "2026-09-02",
      "fecha_fin": "2026-09-10",
      "porcentaje": 1,
      "estado": "NO Calificable",
      "calificable": false,
      "termino": true,
      "en_curso": false,
      "fk_tperiodo_academico": 1780,
      "periodo_academico": "2026 - C",
      "fk_tsede": 1671,
      "sede_nombre": "colegio chino",
      "fk_tlv_jornada": 51900,
      "jornada": "Completa",
      "fk_testablecimiento": 890,
      "anio": 2026
    },
    {
      "fk_tperiodo_evaluacion": 626,
      "codigo": "P2",
      "nombre": "Segundo periodo",
      "abreviacion": "P2",
      "fecha_inicio": "2026-09-12",
      "fecha_fin": "2026-09-27",
      "porcentaje": 1,
      "estado": "NO Calificable",
      "calificable": false,
      "termino": false,
      "en_curso": true,
      "fk_tperiodo_academico": 1780,
      "periodo_academico": "2026 - C",
      "fk_tsede": 1671,
      "sede_nombre": "colegio chino",
      "fk_tlv_jornada": 51900,
      "jornada": "Completa",
      "fk_testablecimiento": 890,
      "anio": 2026
    }
  ]
}
```

---

### `POST /informes/grupo`

La tabla principal. **Una fila por (estudiante, periodo).**

`FK_TGRUPO` sale de [`/informes/grupos-periodo`](#post-informesgrupos-periodo) y
`PERIODOS` de [`/informes/periodos`](#post-informesperiodos). Este endpoint **no
cambió**: recibe el grupo directo y de él deduce el periodo académico, así que no
hay ambigüedad que resolver acá.

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
| `evidencias` | cuántas imágenes adjuntas tiene la fila. En el Final, las del año. Las imágenes se piden aparte |

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

#### La fila Final

El Final **es un id más de `PERIODOS`**: el `-1`, el mismo centinela con el
que la fila viaja de vuelta. No hay bandera aparte.

| `PERIODOS` | qué devuelve |
|---|---|
| `null` o `[]` | todos los períodos reales, **sin** Final |
| `[622, 627]` | esos dos, sin Final |
| `[622, -1]` | ese período **y** el Final |
| `[-1]` | **solo** el Final |

La última fila es la que motivó el cambio: con una bandera aparte era
imposible, porque un arreglo vacío significa *todos*, así que no había forma
de decir «ninguno». Con el `-1` sale sin ningún caso especial — no coincide
con ningún período real, así que el filtro se queda vacío solo.

Cada estudiante recibe entonces **una fila más** con la nota del año, que no
sale de ninguna tabla: se calcula al responder.

```json
{ "fk_tperiodo_evaluacion": -1, "periodo_nombre": "Final",
  "periodo_abreviacion": "FIN", "modo_periodo": "final",
  "consolidado": false, "promedio_guardado": 71.25, "puesto": 3 }
```

`-1` es un **centinela, no un PK**: no lo uses para pedir nada. Sirve como
clave de React y para distinguir la fila; lo que la identifica de verdad es
`modo_periodo: "final"`. Sus asignaturas llegan con `estado: "final"`, que es
un estado nuevo — píntalo como una nota normal, **no** en gris: no es una
proyección.

Tres cosas que sorprenden si no se saben:

1. **Se calcula sobre TODOS los periodos del año, no sobre `PERIODOS`.** El
   filtro de periodos es de vista. Un final que cambia según lo que esté
   desmarcado no es un final.
2. **Un periodo sin nota guardada vale cero**, y el divisor es el total de
   periodos del año. Consecuencia real: a mitad de año casi todo el mundo
   pierde. El Final no es una proyección de cómo va a terminar.
3. **El promedio general es el promedio de las asignaturas de esa misma
   fila**, no el de los promedios de cada periodo.

El puesto se recalcula sobre ese promedio.

`observacion` tiene **el mismo ciclo que en un período** —se genera, se revisa
y se guarda— pero contra otra tabla y otros endpoints. La fila arranca en
`null` hasta que alguien la guarde, y después llega con su
`observacion_estado` (`APROBADA` / `MODIFICADA`) y su
`observacion_desactualizada`, igual que los períodos.

Dos diferencias que importan:

- El **borrador** lo devuelve `/informes/observacion/final`, y encadena los
  resúmenes de período **ya consolidados** — no las observaciones por
  actividad, que son la materia prima de esos resúmenes.
- Lo que lo deja **desactualizado** es que se consolide un **período nuevo**,
  no que el docente escriba una observación más. Por eso el contador se llama
  `PERIODOS_ORIGEN` y vive en una tabla aparte, `TESTUDIANTE_ANIO_OBSERVACION`,
  cuya llave es solo la matrícula.

En un grupo **cualitativo** la fila llega sin asignaturas, sin promedio y sin
puesto —no se promedian observaciones—, pero **con** su observación y sus
evidencias del año.

**Respuesta** (real — una fila en `modo_periodo: "requerido"`, que es justo el caso que más cuesta leer)

```json
{
  "rows": [
    {
      "fk_tmatricula": 223117,
      "estudiante": "JORGITO SANCHEZ",
      "documento": "131312131",
      "fk_tperiodo_evaluacion": 622,
      "periodo_nombre": "Primer periodo",
      "periodo_abreviacion": "P1",
      "periodo_inicio": "2026-09-01",
      "modo_periodo": "requerido",
      "formato": "numerico",
      "es_cualitativo": false,
      "consolidado": false,
      "promedio_guardado": null,
      "promedio_proyectado": 25,
      "puesto": null,
      "asignaturas_total": 1,
      "aprobadas": 0,
      "reprobadas": 0,
      "sin_definir": 1,
      "tiene_cambios_propuestos": false,
      "asignaturas": [
        {
          "area": "MATEMATICAS",
          "nota": 25,
          "orden": 1,
          "estado": "requerido",
          "nombre": "MATEMATICAS",
          "alcanzable": true,
          "asignatura": 4190,
          "porcentaje": 25,
          "abreviacion": null,
          "es_numerico": true,
          "ya_asegurado": false
        }
      ],
      "observacion": null,
      "observacion_estado": null,
      "observacion_desactualizada": null,
      "total_count": 1
    }
  ]
}
```

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

**Respuesta** (real, 2 de 2 filas)

```json
{
  "rows": [
    {
      "fk_tgrupo": 11474,
      "grupo_nombre": "01",
      "fk_tasignatura": 4191,
      "asignatura_nombre": "MATEMATICA FINANCIERA",
      "fk_tfuncionario": 3587701,
      "fk_tusuario_docente": 197422,
      "docente": "SANDRO TORRES",
      "docentes_asignados": 1,
      "fk_tperiodo_evaluacion": 622,
      "periodo_nombre": "Primer periodo",
      "periodo_abreviacion": "P1",
      "periodo_fin": "2026-09-13",
      "estudiantes": 1,
      "actividades": 0
    },
    {
      "fk_tgrupo": 11474,
      "grupo_nombre": "01",
      "fk_tasignatura": 4190,
      "asignatura_nombre": "MATEMATICAS",
      "fk_tfuncionario": 3587701,
      "fk_tusuario_docente": 197422,
      "docente": "SANDRO TORRES",
      "docentes_asignados": 1,
      "fk_tperiodo_evaluacion": 622,
      "periodo_nombre": "Primer periodo",
      "periodo_abreviacion": "P1",
      "periodo_fin": "2026-09-13",
      "estudiantes": 1,
      "actividades": 1
    }
  ]
}
```

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

**Respuesta** — **FORMA**, ningún dato de test produce hoy esta alerta

```json
{
  "rows": [
    {
      "fk_tgrupo": 11474,
      "grupo_nombre": "01",
      "fk_tasignatura": 4190,
      "asignatura_nombre": "MATEMATICAS",
      "fk_tperiodo_evaluacion": 622,
      "periodo_nombre": "Primer periodo",
      "periodo_abreviacion": "P1",
      "fk_tfuncionario": 3587743,
      "fk_tusuario_docente": 197049,
      "docente": "ALEJANDRO TORO",
      "docentes_asignados": 1,
      "estudiantes_afectados": 3,
      "ultimo_cambio": "2026-09-16T09:12:44"
    }
  ]
}
```

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

**Respuesta** — **FORMA**, `TINFORME_GUARDADO` está vacía en test

```json
{
  "rows": [
    {
      "pk_tinforme_guardado": 41,
      "fecha": "2026-09-15",
      "momento": "2026-09-15T16:42:08",
      "fk_tgrupo": 11474,
      "grupo_nombre": "01",
      "fk_tasignatura": null,
      "asignatura_nombre": null,
      "origen": "informe",
      "fk_tperiodo_evaluacion": 622,
      "periodo_nombre": "Primer periodo",
      "periodo_abreviacion": "P1",
      "fk_tusuario": 197798,
      "guardado_por": "ANA MARIA TORRES",
      "estudiantes": 27,
      "detalle": [
        {
          "fk_tmatricula": 223117,
          "estudiante": "JORGITO SANCHEZ",
          "guardadas": 5,
          "actualizadas": 0
        }
      ]
    }
  ]
}
```

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

### Los tres de la fila Final (preescolar)

Los mismos tres pasos que los del período —generar, guardar, eliminar— pero
contra `TESTUDIANTE_ANIO_OBSERVACION`, cuya llave es **solo la matrícula**: la
matrícula ya pertenece a un grupo, a un grado y por lo tanto a un año.

> **Por qué una tabla aparte y no la de períodos con el período en `null`.**
> Funcionaría (PG16 tiene `UNIQUE NULLS NOT DISTINCT`), pero
> `OBSERVACIONES_ORIGEN` pasaría a contar **dos cosas distintas** según la
> fila: en un período, las observaciones por actividad; en el año, los períodos
> consolidados. Misma columna, dos fórmulas. Acá se llama `PERIODOS_ORIGEN` y
> cuenta períodos.

#### `POST /informes/observacion/final` — **no escribe**

Genera el **borrador** del comentario del año: los resúmenes de período **ya**
**consolidados**, encadenados en orden y prefijados con el nombre de cada
período.

```json
{ "FK_TMATRICULA": 223199 }
```

```json
{ "rows": [{ "observacion_ia": "Primer periodo: … Segundo periodo: …",
             "periodos_origen": 2 }] }
```

**No es** `/informes/observacion/generar`. Aquel concatena las observaciones
que el docente dejó **por actividad** dentro de un período: materia prima. Este
encadena los resúmenes que ya salieron de ahí.

Hoy es una concatenación; cuando exista el modelo cambia lo que devuelve esta
función y **nada más**, porque el contrato ya es el definitivo. Devuelve siempre
una fila; con `null` y `0` si el estudiante no tiene ningún resumen de período
guardado.

#### `POST /informes/observacion/final/guardar`

```json
{ "FK_TMATRICULA": 223199, "OBSERVACION": "…",
  "OBSERVACION_IA": "…", "PERIODOS_ORIGEN": 2 }
```

Reemplaza. El **estado no se pide**: sale de comparar `OBSERVACION` contra
`OBSERVACION_IA` —iguales `APROBADA`, distintos `MODIFICADA`—, así que reenviá
el borrador tal como llegó. Si **no** lo reenviás pero ya había fila, se conserva
el borrador guardado en vez de asumir que el texto nuevo es el de la IA; sin eso,
editar quedaría como `APROBADA` sin cambios. Lo mismo con `PERIODOS_ORIGEN`: si
no lo mandás se cuenta al guardar, para que la marca de desactualizado no quede
mintiendo. Gate `INFORMES/EDITAR`.

#### `POST /informes/observacion/final/eliminar`

```json
{ "FK_TMATRICULA": 223199 }
```

Borrado **físico**, por el mismo motivo que el del período: el índice único es
total sobre la matrícula y una fila inactiva impediría guardar una nueva.
Después, la fila Final vuelve a traer `observacion` en `null`. Gate
`INFORMES/ELIMINAR`. Llamarlo dos veces responde **404**.

---

### `POST /informes/evidencias` — las fotos de preescolar

Las imágenes adjuntas a las observaciones de un estudiante en un período.

```json
{ "FK_TMATRICULA": 223199, "FK_TPERIODO_EVALUACION": 626 }
```

`FK_TPERIODO_EVALUACION` **nulo o ausente = todo el año**, que es lo que
necesita la fila Final.

Una fila por adjunto: `pk_tactividad_soporte`, `fk_tarchivo`, `nombre`, `urls3`,
`peso`, `etiqueta`, `fecha`, el período en que cae, la actividad de la que sale
y su observación. Para mostrarla, `fk_tarchivo` va a
`POST /files/view-token/{id}`, como cualquier otro archivo.

> **Por qué no se reusa `GET /planeador/actividades/estudiantes/:ID/soportes`.**
> Lee la misma tabla y devuelve las mismas filas, pero su gate es
> `PLANEADOR/VER` —quien mira informes puede no tener planeador, y se comería un
> 403 en una pantalla donde sí puede ver— y su llave es
> `PK_TACTIVIDAD_ESTUDIANTE`, o sea **por actividad**: serían N llamadas y habría
> que saber de antemano qué actividades hay.

Cuántas hay ya viene en la columna `evidencias` de `/informes/grupo`, así que no
hace falta llamar a este endpoint solo para decidir si se dibuja la sección.

---

### Las dos descargas: el BOLETÍN y el DESCARGAR

Las dos pasan por `reporting-service` (`POST /reportes/<clave>`), no por estos
endpoints directamente. La diferencia entre ellas es toda la gracia:

| | clave | qué imprime |
|---|---|---|
| **Generar boletines** | `informes` | **solo lo consolidado** |
| **Descargar** | `informes-tabla` | **la tabla tal cual**, con la búsqueda aplicada |

Un boletín no puede imprimir una proyección ni una nota requerida: fuera del
sistema se leen como calificaciones reales. Un volcado que esconde la mitad de
la tabla no sirve para revisar, así que el otro trae todo y lo identifica en la
columna `estado` (`Guardada`, `Proyectada (sin consolidar)`,
`Requerida para aprobar el año`, `Final (promedio del año)`, `Sin nota`) más una
columna `consolidado`.

Filtros del boletín (`BODY.FILTERS`): `FK_TGRUPO`, `PERIODOS`, `SEARCH`,
y `MATRICULAS` — un boletín es de un estudiante; vacío o ausente sigue siendo
el grupo entero. El descargar toma los mismos menos `MATRICULAS`. En ambos, el
Final se pide igual que en el listado: `-1` dentro de `PERIODOS`.

En ambos, `evidencias` trae **la cuenta** de imágenes, no las imágenes:
`reporting-service` arma una tabla de texto desde su `application.yml`, y una
imagen por fila es código Java nuevo en un servicio compartido.

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
