# Planeador: endpoints de unidades, actividades y referente curricular

Guía para el front. Describe qué se envía y qué se recibe en los endpoints de
**unidades temáticas**, **actividades**, **referente curricular** y
**configuración** del Planeador. Para instrumento/calificación/materiales ver
`docs/planeador/calificacion-y-materiales-endpoints.md`. Corresponde al estado
de la rama `feat/planeador-correcciones-reglas-gestion-academica`.

## Convenciones comunes

- **Base:** todas las rutas cuelgan del gateway en `/api/eval-col`. Por ejemplo,
  `POST /api/eval-col/planeador/unidades`.
- **Autenticación:** `Authorization: Bearer <token>`. El usuario **nunca** se
  envía en el body: la base lo deriva del token.
- **Nombres de campo:**
  - los del body y de la query van en **MAYÚSCULAS** tal como aparecen aquí
    (`BODY.NOMBRE` → `"NOMBRE"`, `QUERY.GRUPO` → `?grupo=`);
  - dentro de un JSON anidado las claves van en **camelCase**.
- **Respuesta:** las filas que devuelve la función. Cada columna es una clave del
  objeto. Un endpoint que devuelve un solo valor responde una fila con una
  columna (por ejemplo `pk_tunidad`).

| HTTP | Cuándo |
|---|---|
| 400 (22023) | El dato no cumple una regla de negocio (unidad/actividad eliminada, enfoque incompatible, falta un campo obligatorio, etc.). |
| 403 (42501) | Sin permiso/alcance sobre la sede, grado o grupo, o un docente toca una actividad/unidad que no creó (Regla 25). |
| 404 (P0002) | No existe la actividad/unidad/criterio/enunciado. |
| 409 (23503 / 23505) | Referencia inactiva, nombre repetido, o la actividad ya tiene resultados/es una recuperación activa (Regla 37/38). |

**Roles (ojo, incompletos en el dump de producción — completados contra
`postgres/migrations`):**

- **Lectura (GET):** `CEVAL-DOCENTE` y `CEVAL-SUPER_ADMINISTRADOR` desde el
  origen; V284 añadió `CEVAL-RECTOR` y `CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO`,
  pero **solo** sobre 19 rutas puntuales (las que no tienen `:ID` de escritura):
  `/planeador/actividades`, `/planeador/actividades/:ID`,
  `/planeador/actividades/:ID/calificaciones`,
  `/planeador/actividades/:ID/configuracion`,
  `/planeador/actividades/:ID/instrumento`,
  `/planeador/actividades/:ID/materiales-reutilizables`,
  `/planeador/actividades/calendario`,
  `/planeador/actividades/estudiantes/:ID/nota`,
  `/planeador/actividades/huerfanas`, `/planeador/actividades/mias`,
  `/planeador/actividades/stats`, `/planeador/actividades/tablero`,
  `/planeador/asignaturas/:ID/ponderacion-disponible`,
  `/planeador/docentes/grado-asignatura`, `/planeador/docentes/grupos`,
  `/planeador/periodos-evaluacion`, `/planeador/planilla/calificaciones`,
  `/planeador/planilla/columnas`, `/planeador/referente-curricular`. El resto
  de los GET del dominio (unidades, export-all, etc.) sigue sin esos dos roles
  salvo que una migración posterior lo haya ampliado.
- **Escritura (POST/PUT/PATCH):** intencionalmente **no** se tocó en V284;
  queda en `CEVAL-DOCENTE` y `CEVAL-SUPER_ADMINISTRADOR`.
- El gate real de negocio no es el rol sino la **capability `PLANEADOR`**
  (`VER`/`CREAR`/`EDITAR`/`ELIMINAR`, `fn_assert_permiso_seccion`) más el
  alcance territorial (sede/grado/grupo) y, en escritura, ser el **docente
  propietario** del recurso (Regla 25).

---

## Índice

1. [Actividades — listado, tablero y calendario](#1-actividades--listado-tablero-y-calendario)
2. [Actividades — CRUD y detalle](#2-actividades--crud-y-detalle)
3. [Actividades — configuración de formulario](#3-actividades--configuración-de-formulario)
4. [Actividades — estudiantes, criterios y evidencias](#4-actividades--estudiantes-criterios-y-evidencias)
5. [Actividades — export/import e informe PDF/Excel](#5-actividades--exportimport-e-informe-pdfexcel)
6. [Unidades — CRUD y detalle](#6-unidades--crud-y-detalle)
7. [Unidades — actividades vinculadas](#7-unidades--actividades-vinculadas)
8. [Unidades — rúbrica (criterios/niveles)](#8-unidades--rúbrica-criteriosniveles)
9. [Unidades — objetivos, contenidos y enunciados](#9-unidades--objetivos-contenidos-y-enunciados)
10. [Referente curricular](#10-referente-curricular)
11. [Contexto del docente (grupos, pestañas, periodos)](#11-contexto-del-docente-grupos-pestañas-periodos)
12. [Cambios de esta rama](#12-cambios-de-esta-rama)

---

## 1. Actividades — listado, tablero y calendario

### 1.1 `GET /planeador/actividades`

Página general de actividades (`fn_actividad_listar`).

| Query | Tipo | Significado |
|---|---|---|
| `search` | VARCHAR | Buscador único: título, descripción (trigram), nivel de enseñanza de la unidad o nombre del instrumento. |
| `asignatura`, `grupo`, `unidad`, `tipoActividad`→`TIPO_ACTIVIDAD`, `instrumento` | BIGINT | Filtros indexados. |
| `fechaDesde`/`fechaHasta` → `FECHA_DESDE`/`FECHA_HASTA` (o `desde`/`hasta`) | DATE | Ventana de fechas. |
| `estados` | VARCHAR (CSV) | Array del estado derivado: `FINALIZADA`, `VENCIDA`, `PENDIENTE_POR_EVALUAR`, `PROGRAMADA`, `EN_EVALUACION`, `SIN_PROGRAMAR`. |
| `diasGracia` | INT, default 2 | Umbral para considerar `VENCIDA`. |
| `incluirInactivas` | BOOLEAN, default false | Incluye actividades inactivas. |
| `ordenPor` | VARCHAR, default `fecha_inicio` | Whitelist: `fecha_inicio\|fecha_cierre\|fecha_creacion\|titulo\|ponderacion`. |
| `ordenAsc` | BOOLEAN, default true | |
| `size`/`offset` | INT, default 20/0 | Paginación. |
| `dia` | DATE | Ver "paginado por día activo" abajo. |

**Paginado por día activo (`?dia=`):** deja solo las actividades **vigentes**
ese día — la ventana `[fechaInicio, fechaCierre]` **cubre** el día (no que
empiece o cierre ese día), así una actividad de tres días aparece en los tres.
Una actividad sin fechas no sale en esta vista. La respuesta trae `dia`,
`dia_anterior` y `dia_siguiente`: el día ocupado más cercano a cada lado bajo
los mismos filtros, saltando los días vacíos; `null` cuando no hay más días
por ese lado (para deshabilitar la flecha). Sin `?dia=` esas tres columnas
vienen `null`.

**Salida:** nombres resueltos (asignatura, área, unidad, grupo, tipo,
instrumento), estado derivado, progreso de evaluación (asignados/evaluados/%),
`total_count` (window function). Gate VER sobre PLANEADOR.

### 1.2 `GET /planeador/actividades/mias`

"Ver detalles" de una tarjeta del tablero: página de actividades del **docente
autenticado** (no es parámetro; si el usuario no es docente activo, 0 filas).
Mismos filtros/columnas/paginado-por-día que 1.1. **Importante:** mandar
`size`/`offset` siempre explícitos (bug conocido del motor de query-service con
los parámetros de paginación system-bound).

### 1.3 `GET /planeador/actividades/tablero`

Contadores del tablero "mis actividades" del docente autenticado:
`pendientes_por_evaluar`, `en_evaluacion`, `finalizadas`, `vencidas`,
`programadas`, `sin_programar`, `total`. Solo cuenta actividades que el usuario
**dicta** (no las de unidades de las que es autor). Si no es docente activo,
todos los contadores en 0 (no es error). Filtros opcionales
`asignatura`/`grupo`/`unidad`/`fechaDesde`/`fechaHasta`/`diasGracia`.

### 1.4 `GET /planeador/actividades/stats`

Igual función que 1.3 (reutiliza `fn_actividad_resumen_estados_docente`), con
**dos nomenclaturas** en la respuesta: alias del tipo `ActividadStatus` del
front (`pending`/`in_progress`/`completed`/`cancelled`) y los nombres reales
(`pendientes_por_evaluar`/`en_evaluacion`/`finalizadas`/`vencidas`). `cancelled`
es alias de `vencidas` (nada se cancela en el Planeador).

### 1.5 `GET /planeador/actividades/calendario`

Grilla mensual del calendario del docente autenticado.

| Query | Obligatorio | Significado |
|---|---|---|
| `fechaDesde`, `fechaHasta` | **Sí** | 400 (22023) si falta alguno o `hasta < desde`. Acotan por **solapamiento** con `[fecha_inicio, fecha_cierre]`. |
| `asignatura`, `grupo`, `unidad` | No | Filtros. |
| `diasGracia` | No, default 2 | |

**Sin paginación** — no debe pedirse `size`/`offset` aquí (un mes nunca es
volumen grande). Columnas clave: `fecha` (día de anclaje ya resuelto),
`fecha_inicio`, `fecha_cierre`, `estado` (derivado) y `etiqueta` (texto de la
celda: "601 · Debate" — grado/grupo + título; **nunca** la asignatura, que va
en el detalle lateral). El docente sale del token, no es parámetro.

---

## 2. Actividades — CRUD y detalle

### 2.1 `POST /planeador/actividades`

Crea una actividad (`fn_actividad_crear`).

**Obligatorios:** `TITULO` (máx. 150), `FK_TASIGNATURA`, `FK_TLV_TIPO_ACTIVIDAD`,
`FK_TLV_JERARQUIA`.

**Reglas de negocio:**
- Con `FK_TUNIDAD`, la unidad debe ser de la misma asignatura y del grado del
  grupo.
- Ponderar exige `PONDERACION`; Sumatoria exige `NOTA_MAXIMA` (Regla 24).
- `EVIDENCIAS` debe marcar al menos una evidencia de los enunciados de la
  unidad cuando la unidad las tiene (Regla 43). Sin unidad no se admiten
  evidencias ni criterios.
- Sin `FK_TMATRICULAS` se asigna todo el grupo; con grupo debe quedar al menos
  un estudiante.
- `ES_EVALUATIVA` por defecto la decide el **referente** (ver §3 y Regla 19).
- `RECUPERACION` `{destino, tipoAplicacion, tipoCalculo?, valorPonderacion?,
  fkActividadRecuperar?}`: la actividad a recuperar debe ser sumativa, no ser
  recuperación, ser de la misma asignatura y tener resultados (Regla 64).
- La actividad sin grupo ni unidad se crea con solo el permiso CREAR.

**Respuesta:** `pk_tactividad` (bigint).

### 2.2 `GET /planeador/actividades/:ID`

Detalle completo (`fn_actividad_buscar_por_pk`). `:ID` = `pk_tactividad`.
SETOF 0 o 1 fila (incluye inactivas).

| Columna destacada | Significado |
|---|---|
| `estado` | Estado DERIVADO (`?diasGracia=`, default 2). |
| `materiales`, `adaptaciones` | JSONB. |
| `recuperacion` | Config de recuperación o `null`. |
| `campos_disponibles` | Secciones dinámicas del formulario (ver §3). |
| `unidad_configuracion` | Snapshot de la unidad: objetivos, contenidos, referente curricular, rúbrica, enunciados/evidencias. |
| `estudiantes` | `[{pkTactividadEstudiante, pkTmatricula, fkTestudiante, estudiante, calificacion, calificable, observacion}]` — los asignados activos, con el pk que piden calificar/observar/adaptar. |
| `es_formativa` | `true` = la actividad se registra con **observación**, no con nota. Se deriva del referente aplicable a la actividad (grado+asignatura si no tiene unidad, V475/V479); **solo** queda `false` si no hay ningún referente activo para ese (grado, asignatura). No se puede deducir en el cliente de `fk_tlv_instrumento_evaluacion IS NULL` (una evaluativa sin instrumento definido también llega así) ni confundir con `es_evaluativa` (flag manual con `DEFAULT S`). |

Gate VER sobre PLANEADOR.

### 2.3 `PATCH /planeador/actividades/:ID`

Borrado lógico en cascada (`fn_actividad_eliminar`): la suelta de su unidad y
recalcula la Sumatoria.

**Respuesta:** `fn_actividad_eliminar` (el PK) y, si la unidad pondera,
`porcentaje_libre` y `aviso` ("...quedará un X% libre en la unidad. Ajuste los
pesos restantes..."); **no redistribuye** (Regla 38a).

No se elimina si tiene resultados, asistencias o una recuperación activa que la
recupera (409, 23503; Regla 38).

### 2.4 `PUT /planeador/actividades/:ID`

Actualización parcial (`fn_actividad_actualizar`). Lo ausente conserva su
valor; `MATERIALES`/`ADAPTACIONES`/`FK_TMATRICULAS`/`EVIDENCIAS`/`CRITERIOS`
`NULL` = no tocar, arreglo = reemplazo.

- Cambiar `FK_TUNIDAD` mueve la actividad: suelta evidencias/criterios de la
  unidad anterior y exige marcar las nuevas (Regla 36).
- `DESVINCULAR_UNIDAD=true` la deja sin unidad (Regla 39).
- Cambiar `FK_TGRUPO` reasigna todo el grupo si no llegan estudiantes (Regla 35).
- `QUITAR_RECUPERACION=true` deja de ser recuperación.
- El alcance se comprueba **donde está** la actividad y **adonde se mueve**.

**Errores:** 404 si no existe; 400 (22023) si ya fue eliminada o el dato no
cumple una regla; 403 (42501) sin permiso o si un docente toca una actividad
que **no creó** (Regla 25); 409 (23503) si ya tiene resultados o es la
original de una recuperación (Regla 37).

### 2.5 `GET /planeador/actividades/:ID/pantalla-edicion`

DTO compuesto para la pantalla de edición (reemplaza GET `:ID` + GET
`:ID/instrumento`). Agrega:

| Clave | Significado |
|---|---|
| `evidencias` | `[{pk, fkReferenteEnunciado, texto, fkPadre, textoPadre}]` para pre-marcar al reabrir. |
| `criterios` | `[{pk, fkTcriterioUnidad, descripcion, codigo, orden}]` ya relacionados. |
| `estudiantes` | Igual que en 2.2. |
| `esFormativa` | Igual regla que 2.2 (V475). |

---

## 3. Actividades — configuración de formulario

### 3.1 `GET /planeador/actividades/:ID/configuracion`

"Visualización construida por endpoint": qué secciones del formulario mostrar
para **esta actividad puntual**, con el motivo de cada decisión
(`fn_actividad_campos_disponibles` + `fn_actividad_unidad_configuracion`).

`campos_disponibles`:

| Sección | Reglas |
|---|---|
| `criterio` | Oculto solo en Preescolar; opcional en el resto. |
| `evaluacion` | Visible/requerido solo si la unidad (o el referente aplicable) es EVALUATIVO; `instrumentosPermitidos` filtrado por el `TIPO_EVALUACION` del referente. Desde V479 **no** se apaga por falta de unidad: se deriva del referente aplicable a (grado, asignatura). En Preescolar sigue apagada. |
| `ponderacion` | Oculto sin unidad o si `ES_EVALUATIVA=N`; el modo (`PORCENTAJE` sobre `PONDERACION`, o `PUNTAJE` autocalculado sobre `NOTA_MAXIMA`) lo decide el método de cálculo de la unidad. |

**V476** — `campos_disponibles` gana:

| Clave | Significado |
|---|---|
| `esFormativo` | boolean — lo que dicta el referente (no su visibilidad). |
| `esSumativoSugerido` | `S`/`N` — lo que el formulario debe traer marcado en "Es sumativa", y lo que `fn_actividad_crear` guarda si no se envía `ES_EVALUATIVA`. Antes de V475 el front tenía que deducirlo de `evaluacion.visible`, y en una actividad sin unidad ni eso funcionaba. |

`unidad_configuracion`: snapshot completo de la unidad o `{"tieneUnidad":false}`.

404 (P0002) si la actividad no existe. Gate VER sobre PLANEADOR (ambas funciones).

### 3.2 `GET /planeador/actividades/configuracion`

Qué pintar en el formulario a partir de los dos filtros de pantalla: `?grupo=`
y `?asignatura=` (**obligatorios**), con `?unidad=` opcional.

- Con unidad: manda la unidad (referente y método de cálculo).
- Sin unidad: el referente se deriva del grado + asignatura
  (`fn_unidad_referente_aplicable`).
- `origenConfiguracion` dice cuál camino se usó (`CONTEXTO` o `UNIDAD`).

**Respuesta:** contexto resuelto (grupo, grado, nivelEnsenanza, asignatura,
referente), `programacion` (límites de fechas, semanaCronograma,
duracionEstimada, intensidadHoraria del periodo/horario) y
`campos_disponibles` con la **misma forma** que `:ID/configuracion` y
`GET /planeador/unidades/:ID/configuracion-actividad`:
`criterio {visible, requerido, motivo}`,
`evaluacion {visible, requerido, motivo, tipoEvaluacion, instrumentosPermitidos}`,
`ponderacion {visible, requerido, modo, campo?, autocalculado?, motivo}`,
`recuperacion {visible, requerido, motivo, catalogos, reglas}`.

| Query | Default | Efecto |
|---|---|---|
| `esSumativo`→`ES_SUMATIVO` | `S` | Es lo que el usuario **acaba de marcar** en el formulario. Con `N` **solo** se apagan `recuperacion` y `ponderacion` (una recuperación debe ser sumativa; la escritura la rechaza). `evaluacion` sigue saliendo del referente igual con `S` o `N`. |
| `recuperar`→`RECUPERAR` | `N` | `S` llena `recuperacion.actividadesRecuperables` (sumativas del grupo/asignatura aún recuperables). |
| `actividadRecuperar`→`ACTIVIDAD_RECUPERAR` | — | Devuelve `recuperacion.origen` con el contexto heredado/inhabilitado (grado, grupo, asignatura, unidad, tituloBase) y los estudiantes asignados con `notaPrevia`, todos `seleccionado=true` para que el docente desmarque los que no necesita. 404/400 si el origen no existe, no es sumativa, ya es recuperación o es de otra asignatura. |

**V476** — la respuesta también gana `esFormativo` (boolean) y
`esSumativoSugerido` (`S`/`N`), junto a `esSumativoConsultado`: los dos
primeros son lo que **el referente dicta**. Con referente Formativo (y en
Preescolar, siempre) `esSumativoSugerido = N`. Enviar `ES_EVALUATIVA=S` contra
un referente Formativo se rechaza con 400 (22023), tenga o no unidad la
actividad. En instrumentosPermitidos, la entrada `OTRO` trae `campos`
(`tipoEvidencia`, `metodoValoracion`, `definicion`, `requiereArchivo`,
`requiereTexto`); los demás instrumentos traen `campos = null`. **El front
decide por VALOR**, no por pk (no son estables entre entornos). En Preescolar
`evaluacion` y `recuperacion` vienen `visible=false`.

El árbol de enunciados/evidencias **no** viene aquí: usar §10.1.

Gate VER sobre PLANEADOR + alcance por el grupo; 404 si grupo/asignatura/unidad
no existen.

---

## 4. Actividades — estudiantes, criterios y evidencias

### 4.1 `PUT /planeador/actividades/:ID/estudiantes`

Fija los estudiantes de la actividad con **semántica de reemplazo**
(`fn_actividad_estudiantes_set_detalle`).

| Body | Tipo | Significado |
|---|---|---|
| `FK_TMATRICULAS` | BIGINT[] | Matrículas activas del grupo de la actividad. |
| `ASIGNAR_TODO_EL_GRUPO` | BOOLEAN | `true` asigna a todo el grupo. |

Debe quedar al menos un estudiante; quien sale, sale también de sus
adaptaciones.

**Respuesta:**

| Columna | Significado |
|---|---|
| `total_asignados` | Total tras el reemplazo. |
| `afectados_adaptacion` | `[{pkTmatricula, estudiante, adaptaciones:[{pkTactividadAdaptacion, tipoAdaptacion}]}]` — los que **salieron** de alguna adaptación (Regla 46). |
| `avisos_piar` | `[{pkTmatricula, fkTestudiante, estudiante, discapacidad}]` — estudiantes del grupo con discapacidad registrada que **no** quedaron en la actividad; informativo (Regla 48). |

Mismos errores 404/400/403/409 que §2.4 (Reglas 25/37).

### 4.2 `GET /planeador/actividades/estudiantes-grupo`

Padrón de matrículas activas del grupo (`?grupo=`), para el checklist de
"Estudiantes" al crear/editar una actividad.

### 4.3 `GET /planeador/estudiantes`

Estudiantes matriculados activos de un `?grupo=` (obligatorio), para asignar
una actividad. `?asignatura=` **no** recorta la lista (todos los matriculados
cursan la asignatura); solo valida que exista. Con `?actividad=`, cada fila
trae `asignado` (true/false) y `pk_tactividad_estudiante` (el pk que piden las
adaptaciones); sin `?actividad=`, `asignado` viene `false` en todas (catálogo
de candidatos para `POST /planeador/actividades`). La actividad debe ser del
mismo grupo (22023 si no). `size=NULL` devuelve sin paginar.

### 4.4 `POST /planeador/actividades/:ID/criterios` / `PATCH .../criterios/:ID`

Asocia/retira un criterio de la rúbrica de la **unidad** a la actividad
(`fn_actividad_criterio_relacionar` / `fn_actividad_criterio_quitar`).
`BODY.FK_TCRITERIO_UNIDAD` debe ser un criterio activo de la rúbrica de la
misma unidad. Respuesta: `pk_tactividad_criterio_unidad` / `eliminado` (bool).

### 4.5 `POST /planeador/actividades/:ID/evidencias` / `PATCH .../evidencias/:ID`

Marca/desmarca una evidencia (`fn_actividad_evidencia_relacionar` /
`fn_actividad_evidencia_quitar`). `BODY.FK_REFERENTE_ENUNCIADO`: evidencia
(segundo nivel) de un enunciado seleccionado en la unidad de la actividad, del
referente de la unidad y de su grado (**Regla 12**). La actividad sin unidad
no admite evidencias. Al quitar, se exige que quede al menos una marcada
(**Regla 43**).

---

## 5. Actividades — export/import e informe PDF/Excel

### 5.1 `POST /planeador/actividades/exportar`

Exporta actividades al formato JSON de intercambio. Filtros combinables:
`IDS`, `PK_TUNIDAD`, `FK_TASIGNATURA`, `FK_TGRUPO` — al menos uno. Cada
actividad incluye `unidad_meta`, el instrumento (rúbrica/cotejo/escala/otro) y
`_identificadores` con las PKs para reimportar sin resolver nombres.

### 5.2 `POST /planeador/actividades/importar`

Importa desde el formato de 5.1.

| Body | Significado |
|---|---|
| `ACTIVIDADES` | JSONB con el arreglo exportado. |
| `FK_TASIGNATURA`, `FK_TGRUPO`, `FK_TGRADO`, `FK_TFUNCIONARIO`, `FK_REFERENTE_CURRICULAR`, `FK_TLV_CALCULO_DEFINITIVA` | Destino por defecto si una fila no trae `_identificadores`. |
| `SOLO_VALIDAR` | default `true`: no escribe nada, devuelve el informe fila por fila con etiquetas sin catálogo y reglas incumplidas. `false`: aplica **todo o nada** — si alguna fila tiene errores, no se escribe ninguna. |

El destino sale de `_identificadores` de cada fila si viene; si no, de los
`FK_` del cuerpo. Nunca se resuelve por nombre.

### 5.3 `GET /planeador/actividades/huerfanas`

Actividades sin unidad (`FK_TUNIDAD IS NULL`, activas) para la pantalla de
vinculación posterior. No proyecta `PONDERACION` (siempre `NULL` en una
huérfana). Para vincular, usar §7.3.

### 5.4 `POST /planeador/actividades/export-all`

Actividades **sin paginar** para el reporte PDF/Excel (reporting-service,
clave `planeador-actividades`). Misma función/filtros/gate que §1.1, con los
binds bajo `BODY.FILTERS.*` + `FILTERS.IDS` (seleccionados) y
`SORTING.ID`/`SORTING.DESC`. No es el JSON de intercambio de 5.1.

---

## 6. Unidades — CRUD y detalle

### 6.1 `GET /planeador/unidades`

Página de unidades (`fn_unidad_listar`).

| Columna | Significado |
|---|---|
| `estado` | Derivado, agregando el de sus actividades: una sola VENCIDA marca la unidad VENCIDA; si no hay vencidas pero sí alguna PENDIENTE_POR_EVALUAR, esa; si todas finalizadas, FINALIZADA; si no, EN_EVALUACION (incluida la unidad sin actividades, reconocida por `total_actividades = 0`). |

Mismo mecanismo de paginado-por-día-activo (`?dia=`) que §1.1, aplicado a
unidades con alguna actividad activa vigente ese día. Filtros `search`,
`asignatura`, `grado`, `funcionario`, `incluirInactivos` (default false);
orden whitelist `nombre|asignatura|grado`.

### 6.2 `POST /planeador/unidades`

Crea una unidad temática (`fn_unidad_crear`).

**Obligatorios:** `NOMBRE`, `FK_TASIGNATURA`, `FK_TGRADO` y
`FK_TLV_CALCULO_DEFINITIVA` **salvo** que el referente del grado sea de
enfoque Formativo (**Regla 19**).

**Opcionales:**

| Body | Tipo | Significado |
|---|---|---|
| `FK_TFUNCIONARIO` | BIGINT | Se deriva del usuario si no llega. |
| `DESCRIPCION`, `FK_REFERENTE_CURRICULAR` | | El referente debe cubrir el nivel y el grado (**Regla 12**). |
| `OBJETIVOS`, `CONTENIDOS` | TEXT[] | Ningún elemento vacío. |
| `CONTENIDOS_TITULOS` | TEXT[] | **Nuevo (§4):** si llega, un título no vacío de máx. 200 caracteres por contenido, en la **misma posición** que `CONTENIDOS`. Si no llega, los contenidos quedan sin título (como antes). |
| `ENUNCIADOS` | BIGINT[] | |
| `PONDERACION` | NUMERIC | |

**Respuesta:** `pk_tunidad` (bigint). Gate: alcance CREAR sobre el grado.

### 6.3 `GET /planeador/unidades/:ID`

Detalle (`fn_unidad_buscar_por_pk`): escalares + nombres resueltos,
`Inicio`/`Fin` DERIVADOS (MIN/MAX de fechas de actividades activas),
`objetivos`/`contenidos` como JSONB ordenados, `campos_disponibles`
(dependencia referente→rúbrica) y `active`. SETOF 0 o 1 fila (incluye
inactivas).

### 6.4 `PATCH /planeador/unidades/:ID`

Baja lógica (`fn_unidad_eliminar`): la unidad, su rúbrica (niveles, criterios),
objetivos, contenidos y enunciados.

**Regla 27 (cesión):** se rechaza (409, 23503) si **otros docentes** tienen
actividades o criterios propios en ella — en ese caso se **cede** la unidad en
vez de eliminarla (ver 6.5); las actividades del dueño se desvinculan y siguen
vivas. Gate: alcance ELIMINAR + propietario.

### 6.5 `PUT /planeador/unidades/:ID`

Actualización parcial (`fn_unidad_actualizar`). Campo ausente/`NULL` = no
tocar; `OBJETIVOS`/`CONTENIDOS` son reemplazo completo.

| Body | Significado |
|---|---|
| `CONTENIDOS_TITULOS` | Acompaña a `CONTENIDOS` (§4): si llega, un título no vacío de máx. 200 por contenido; si no, se guardan sin título. |
| `LIMPIAR_REFERENTE` / `LIMPIAR_PONDERACION` | Fuerzan `NULL` el referente/la ponderación. |
| `FK_TFUNCIONARIO` | Cambiarlo **cede** la unidad: el nuevo dueño debe tener actividades o criterios propios en ella, o dictar la asignatura en su grado (**Regla 27**). |

**Respuesta:** `fn_unidad_actualizar` (el `pk_tunidad`) y `actividades_afectadas`
`[{pk, titulo}]` — las actividades cuyo peso o puntaje se **convirtió** por un
cambio de criterio de cálculo, `[]` si no cambió (**Regla 28**: si la unidad
tiene docentes colaboradores, además se notifican y la pestaña Actividades
queda en solo lectura mientras dura el recálculo). Gate: alcance EDITAR +
propietario de la unidad.

---

## 7. Unidades — actividades vinculadas

### 7.1 `GET /planeador/unidades/:ID/actividades`

Actividades vinculadas a la unidad, con su `ponderacion` (%, columna visible
en la pantalla; distinta de `influencia`, que se devuelve por compatibilidad).
Filtros `search`, `grupo`, `incluirInactivas`; orden whitelist
`actividad|tipo|instrumento|grupo|porcentaje`.

**Regla 25c:** a un **docente de aula** solo le lista las actividades que él
**creó**; director de grupo o directivos (rector, coordinación) ven todas.

### 7.2 `GET /planeador/unidades/:ID/actividades-disponibles`

Candidatas a vincularse a la unidad (modal "Vincular actividad"). Candidata =
activa, sin unidad, misma asignatura que la unidad, mismo grado vía el grupo
(sin grupo también es candidata). Devuelve `porcentaje_disponible` =
`fn_unidad_ponderacion_disponible(unidad, grupo de esa fila)`.

### 7.3 `PUT /planeador/unidades/:ID/actividades/:ACTIVIDADID`

Vincula una actividad a una unidad y fija su `PONDERACION` (%) dentro de ella.

| Body | Significado |
|---|---|
| `PONDERACION` | `NULL` = no cambiar el peso actual; se rechaza (22023) si la unidad calcula por Promediar o Sumatoria (en Sumatoria el % se autocalcula desde `NOTA_MAXIMA`). |
| `PERMITIR_MOVER_DE_UNIDAD` | default `false`, **obligatorio en `true`** si la actividad ya estaba vinculada a **otra** unidad (evita mover de unidad en silencio). Vincular una huérfana no lo requiere. |

Valida la regla del 100% por (unidad, grupo). Gate EDITAR sobre PLANEADOR.

### 7.4 `PATCH /planeador/unidades/actividades/:ACTIVIDADID`

Desvincula una actividad de su unidad: `FK_TUNIDAD` y `PONDERACION` quedan en
`NULL`. Si la unidad de origen calculaba por Sumatoria, recalcula el % de las
actividades que quedan en ese (unidad, grupo). **Respuesta:**
`fn_unidad_actividad_desvincular` (PK) y, si la unidad pondera,
`porcentaje_libre` y `aviso`; **no redistribuye** (**Regla 39**). Gate EDITAR
+ autor de la actividad (Regla 25c).

### 7.5 `PUT /planeador/unidades/actividades/:ACTIVIDADID/ponderacion`

Edición inline del peso (%) de una actividad ya vinculada. `BODY.PONDERACION`
obligatorio, 0–100; se rechaza (22023) si la unidad Promedia, calcula por
Sumatoria, o la actividad no está vinculada a ninguna unidad. Gate EDITAR +
autor de la actividad (Regla 25c).

---

## 8. Unidades — rúbrica (criterios/niveles)

### 8.1 `GET /planeador/unidades/:ID/criterios`

Criterios de la rúbrica (`TCRITERIO_UNIDAD`), con sus niveles agregados en
JSONB ordenado por valoración de la escala:
`[{pk, fkTescalaValoracion, valoracion, orden, indicador, recomendacion, tarea}]`.
`?incluirInactivos=` (default false).

### 8.2 `GET /planeador/unidades/:ID/valoraciones`

Valoraciones (bandas Bajo/Básico/Alto/Superior) de la escala que aplica a la
unidad — el select que falta para poder agregar un criterio. Se deriva de la
unidad (asignatura + grado → criterio de evaluación vigente → escala; si no
hay, por el nivel de enseñanza del grado). Trae orden, código/nombre/gráficas,
límites crudos en % (`limite_inferior`/`limite_superior`) y ya convertidos al
formato de calificación del colegio (`nota_minima`/`nota_maxima`, `null` si el
formato no es numérico).

### 8.3 `POST /planeador/unidades/:ID/criterios`

Agrega un criterio a la rúbrica.

| Body | Significado |
|---|---|
| `NIVELES` | `[{"fkTescalaValoracion":N, "indicador":"..", "recomendacion":"?", "tarea":"?"}]` — obligatorio **exactamente** un elemento por cada valoración activa de la escala aplicable (8.2). |
| `PUBLICO` | `S`/`N`, default `S`. |
| `DESCRIPTOR_PROM` | `S`/`N`, default `N`. |

22023 si no hay escala aplicable o el payload no calza exacto con las
valoraciones.

### 8.4 `PUT /planeador/unidades/criterios/:ID`

Actualización parcial de un criterio (`:ID` = `pk_tcriterio_unidad`). Campos
ausentes/`NULL` preservan; `LIMPIAR_CODIGO=true` fuerza `CODIGO` a `NULL`.
`NIVELES` (opcional) actualiza **solo** los textos de niveles **ya
existentes** de ese criterio (no crea niveles nuevos).

### 8.5 `PATCH /planeador/unidades/criterios/:ID`

Soft delete (`active=false`) del criterio y sus niveles. No renumera el orden
de los restantes. 404 si no existe; 22023 si ya está inactivo.

---

## 9. Unidades — objetivos, contenidos y enunciados

### 9.1 `GET /planeador/unidades/:ID/objetivos`

Objetivos activos (`TUNIDAD_OBJETIVO`), ordenados por `orden`.

### 9.2 `GET /planeador/unidades/:ID/contenidos`

Contenidos/componentes activos (`TUNIDAD_CONTENIDO`), ordenados por `orden`.

| Columna | Significado |
|---|---|
| `pk_tunidad_contenido`, `orden`, `descripcion` | Como antes. |
| `titulo` | **Nuevo (§4):** título de sección; `NULL` si el contenido no tiene título. Es la **última columna** de la fila. |

### 9.3 `POST /planeador/unidades/:ID/enunciados`

Relaciona (o reactiva) un enunciado de nivel 1 del referente curricular con la
unidad. Valida que el enunciado sea nivel 1 (`FK_PADRE IS NULL`) y comparta el
mismo nivel de enseñanza que la unidad. 23503 si la unidad o el enunciado no
existen/no están activos; 22023 si el enunciado es una evidencia (nivel 2) o
el nivel de enseñanza no coincide.

### 9.4 `PATCH /planeador/unidades/enunciados/:ID`

Borrado lógico de la relación unidad↔enunciado (`:ID` = `pk_tunidad_enunciado`,
**no** el pk del enunciado). Arrastra la desactivación de las
`TACTIVIDAD_EVIDENCIA` de esa unidad cuyo enunciado padre era este.

---

## 10. Referente curricular

### 10.1 `GET /planeador/referente-curricular`

El referente curricular que corresponde a un `?grado=` (obligatorio) y
`?asignatura=` (opcional), con todos sus datos, para pintar unidad y actividad
**antes** de crear la unidad (con unidad ya creada usar 10.2). El referente
**no se elige a mano**: se deriva de grado → nivel de enseñanza → referente(s)
de ese nivel.

Devuelve un **arreglo ordenado por prioridad** (la misma regla con que
`fn_unidad_referente_aplicable` decide el referente de una unidad nueva):
especificidad 0 = lista el área de la asignatura pedida, 1 = sin áreas (aplica
a todas), 2 = acotado a otras áreas — las áreas **no excluyen**, un referente
acotado a otras áreas sigue saliendo al final. Solo referentes activos con
`ESTADO = Activo`. `?anio=` (default año en curso) descarta los fuera de
vigencia.

Cada referente trae `enfoque_valor` + `es_evaluativo`, `tipo_evaluacion`,
`nivel_1_etiqueta`/`nivel_2_etiqueta` (rotular con esto, no con literales), y
`enunciados:[{pk, texto, fkReferenteCurricularArea, area, evidencias:[{pk,
texto}]}]` acotados al área pedida.

Gate VER sobre PLANEADOR + alcance territorial por el grado; **un grado
inexistente responde 403, no 404** (el gate corre antes que la existencia, a
propósito — **Regla 5/59**: un referente inactivo conserva sus datos
históricos, por eso el gate de alcance manda sobre la existencia). 404 para la
asignatura que no existe.

### 10.2 `GET /planeador/unidades/:ID/referente`

Los enunciados que **esta unidad relacionó**, con sus evidencias — es
**lectura** de lo relacionado (`TUNIDAD_ENUNCIADO`), no un catálogo; para
ofrecer enunciados que marcar, usar 10.1. Trae el contexto, el referente
(`enfoque_valor` + `es_evaluativo`, `tipo_evaluacion_valor`),
`nivel_1_etiqueta`/`nivel_2_etiqueta`, y `enunciados:[{pk, texto,
relacionadoConUnidad, pkTunidadEnunciado, evidencias:[{pk, texto}]}]`.
`relacionadoConUnidad` siempre `true`; `pkTunidadEnunciado` es el pk que pide
`PATCH /planeador/unidades/enunciados/:ID` (9.4). Si la unidad no tiene
referente activo o no relacionó enunciados, `enunciados: []`.

### 10.3 `GET /planeador/rotulo-actividad`

Cómo se llama la actividad para un `?grado=`(obligatorio)/`?asignatura=`
(opcional): el **Rótulo de Ejecución** del referente, resuelto con la misma
regla de 10.1. Si ningún referente aplica, `pk_referente_curricular` es `NULL`
y `rotulo_ejecucion` es `"Actividad"`.

---

## 11. Contexto del docente (grupos, pestañas, periodos)

### 11.1 `GET /planeador/docentes/grupos`

Paso 1-2 del filtro en cascada Grado→Grupo→Asignatura para "Planilla de
calificación", del docente autenticado (no es parámetro). `?periodo=` opcional
(si no llega, se deduce del periodo vigente del docente). Devuelve
`grupo_etiqueta` ("<grado> <grupo>") lista para pintar — `CODIGO` viene `NULL`
y `NOMBRE` es `"01"` en todos los grupos, así que sin ella el selector no los
distingue. Si el usuario no es funcionario activo (o no dicta nada ese
periodo), 200 con lista vacía, no error.

### 11.2 `GET /planeador/docentes/grado-asignatura`

Pares (grado, asignatura) distintos que el docente dicta en el periodo, sin
repetir por tener la misma asignatura en varios grupos del mismo grado.
`?periodo=` opcional. `?referente=` opcional: el pk del referente curricular
de la pestaña de unidad desde la que se abre (ver 11.3); deja solo los pares
cuyo referente aplicable es ese.

### 11.3 `GET /planeador/unidades/tabs`

Las **pestañas** de unidad del docente autenticado, una por referente
curricular de los niveles que dicta. El rótulo no es fijo: sale de
`instrumento` del referente del nivel ("Proyecto pedagógico" en Preescolar,
"Unidad temática" en Primaria...). Un docente que solo dicta Preescolar recibe
una fila. Si el usuario no es docente activo, 0 filas. Cada fila trae
`enfoque_valor`+`es_evaluativo`, `tipo_evaluacion_valor`,
`nivel_1_etiqueta`/`nivel_2_etiqueta`, y `niveles`/`grados`/`asignaturas`
(`[{pk,nombre}]`) para filtrar sin volver a preguntar. Si dos niveles
comparten referente es **una sola** pestaña. Los niveles cuyo grado aún no
tiene referente cargado **no se omiten**: vienen con `pk_referente_curricular
null` e `instrumento "Unidad temática"` — pintar la pestaña igual.

### 11.4 `GET /planeador/periodos-evaluacion`

Los cortes de evaluación (`TPERIODO_EVALUACION`) visibles para los roles con
acceso al Planeador. Devuelve los activos sin filtrar por estado: cada fila
trae `fk_tlv_estado`+`estado_valor`+`estado_nombre` (Calificable / No
calificable / Habilitados para algunas asignaturas / En Recuperaciones) para
que el cliente decida; **en ese catálogo no existe un estado llamado
"activo"**. `?estado=` acota a uno. `?periodo=` opcional (se deduce del
docente autenticado). Trae además `vigente_hoy` (derivado: hoy cae dentro del
corte, para preseleccionar).

### 11.5 `GET /planeador/sedes/opciones`

Gemelo de `GET /establecimientos/sedes/opciones` para el Planeador. Gate VER
sobre el **grupo de menú** al que cuelga PLANEADOR (Gestión Académica,
resuelto por estructura) en vez de `SEDES_EDUCATIVAS`. 42501 si el usuario no
tiene la capability — **Regla del código de menú sin tildes**: el gate
compara contra el código real `GESTION_ACADEMICA`, nunca contra una variante
con tildes.

### 11.6 `GET /planeador/asignaturas/:ID/ponderacion-disponible`

Porcentaje **libre** para repartir entre las **unidades** de una (asignatura,
grado): `100 - ponderación intra-asignatura ya asignada`. `:ID` =
`pk_tasignatura`, `?grado=` obligatorio. Análogo, un nivel arriba, de
`GET /planeador/unidades/:ID/ponderacion-disponible` (reparte el peso de las
**actividades** dentro de una unidad). Acotado a `>= 0`.

---

## 12. Cambios de esta rama

Resumen de lo que cambia respecto a la versión previa de estos endpoints
(rama `feat/planeador-correcciones-reglas-gestion-academica`):

| Qué | Dónde | Detalle |
|---|---|---|
| `CONTENIDOS_TITULOS` opcional | `POST`/`PUT /planeador/unidades[/:ID]` | Títulos de sección por contenido, en la misma posición que `CONTENIDOS`; si no llega, sin título (**§4**). |
| `titulo` en contenidos | `GET /planeador/unidades/:ID/contenidos` | Última columna; `NULL` si el contenido no tiene título. |
| `actividades_afectadas` | `PUT /planeador/unidades/:ID` | Actividades cuyo peso/puntaje se convirtió al cambiar el criterio de cálculo (**Regla 28**). |
| Cesión de unidad | `PUT /planeador/unidades/:ID`, `PATCH /planeador/unidades/:ID` | Cambiar `FK_TFUNCIONARIO` exige que el nuevo dueño tenga actividades/criterios propios o dicte la asignatura en su grado; eliminar se rechaza si hay docentes colaboradores (ceder en vez de eliminar) (**Regla 27**). |
| Visibilidad de actividades por rol | `GET /planeador/unidades/:ID/actividades` | Un docente de aula puro solo ve las que **él creó**; director de grupo y directivos ven todas (**Regla 25c**). |
| Validaciones Regla 12 / 19 | `POST /planeador/actividades/:ID/evidencias`, `POST`/`PUT /planeador/unidades` | Evidencia debe ser del referente y grado de la unidad (12); `FK_TLV_CALCULO_DEFINITIVA` solo se exime con referente Formativo (19). |
| `afectados_adaptacion` / `avisos_piar` | `PUT /planeador/actividades/:ID/estudiantes` | Estudiantes que salieron de adaptaciones (**Regla 46**) y estudiantes con discapacidad que quedaron fuera (**Regla 48**), informativos. |
| Recuperación — candidatos y roster | `GET /planeador/actividades/configuracion`, `GET /planeador/unidades/:ID/configuracion-actividad` | `?recuperar=S` lista `actividadesRecuperables`; `?actividadRecuperar=` devuelve `recuperacion.origen` con el roster completo y `notaPrevia`, preseleccionado (**Reglas 63/65**). |
| Herencia del Refuerzo | `GET .../configuracion`, `POST /planeador/actividades` | Al elegir la actividad base, el contexto (grado/grupo/asignatura/unidad/título/"¿es sumativa?") se hereda y bloquea (**Regla 66**). |
| Referente inactivo | `GET /planeador/referente-curricular` | Gate de alcance corre antes que la existencia (403 sobre 404 en grado fuera de alcance); un referente inactivo conserva su histórico (**Reglas 5/59**). |
