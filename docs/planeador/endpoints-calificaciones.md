# Calificaciones: escalas, planilla, informes y aprobaciones

Guía para el front. Cubre los endpoints de **escalas de valoración**,
**planilla de calificación**, **informes de grupo** y el nuevo flujo de
**estados de resultado / aprobación del Coordinador**. No repite lo ya
documentado en
[`calificacion-y-materiales-endpoints.md`](./calificacion-y-materiales-endpoints.md)
sobre instrumento de evaluación, calificar (individual y en bloque) y
`resultado_instrumento`: ese documento sigue siendo la referencia para esas
piezas, aquí solo se citan los cambios que introduce esta rama.

## Convenciones comunes

- **Base:** todas las rutas cuelgan del gateway en `/api/eval-col`. Por
  ejemplo, `PUT /api/eval-col/planeador/actividades/estudiantes/123/estado-resultado`.
- **Autenticación:** `Authorization: Bearer <token>`. El usuario nunca se
  envía en el body: la base lo deriva del token.
- **Nombres de campo:** los del body y la query van en **MAYÚSCULAS**
  (`BODY.ESTADO` → `"ESTADO"`, `QUERY.GRUPO` → `?grupo=`); dentro de un JSON
  anidado (`SCALES`, `FILTERS`...) las claves van en **camelCase**.
- **Respuesta:** las filas que devuelve la función; cada columna es una clave
  del objeto. Un endpoint que devuelve un solo valor responde una fila con una
  columna.
- **Porcentajes:** toda nota se guarda como porcentaje 0–100; la nota en el
  formato del colegio va aparte en `*_homologada` / `valoracion`.

| HTTP | Cuándo |
|---|---|
| 400 (22023) | El dato no cumple una regla: falta un parámetro obligatorio, estado inválido, actividad eliminada o formativa, motivo muy largo, periodo fuera del periodo académico del grupo. |
| 403 (42501) | Sin permiso sobre la sede/jornada, sin alcance de Coordinador sobre el grupo, o un docente toca una actividad que no creó (Regla 54). |
| 404 (P0002) | No existe la actividad, la asignación, el grupo, la asignatura, el periodo o la solicitud de aprobación. |
| 409 (23503) | El grado enviado no es el del grupo, o una referencia no existe. |

---

## 1. Estado de resultado (nuevo)

La asistencia de la actividad es la de su **fecha fin** (`FECHA_CIERRE`) en cuanto llega y se toma; hasta entonces, la de su **primer día** (`FECHA_INICIO`),
juntando todos los bloques del día. La tomada en la Vista Asistencias se
refleja sola en el estado (Regla 73) y es la que muestra el Planeador. Un
cambio desde el Planeador (`PUT .../estudiantes/:ID/asistencia`) **vale solo
para esa actividad** y no toca la asistencia tomada. Si ese día no se tomó la
Vista, la asistencia **oficial** del día (una fila por bloque) se calcula con
las marcas de todas las actividades del día: presente si asistió en alguna,
tarde si solo llegó tarde, ausente si faltó en todas. La Vista la reemplaza.

**Sin asistencia, No asistido o No presentó no se califica ni se observa**
(400). Al registrar el resultado, la asistencia de la actividad queda
**congelada** (`asistencia_editable = false`).

`ESTADO_RESULTADO` (catálogo `TLISTA_VALOR`), valores:

| Valor | Significado |
|---|---|
| `PENDIENTE` | Aún sin resolver. Estado por defecto. |
| `CALIFICADO` | Se fija **automáticamente** al calificar u observar; no se marca a mano. |
| `NO_PRESENTO` | El estudiante no entregó / no se presentó a la actividad. |
| `NO_ASISTIO_JUSTIFICADA` | Faltó y hay archivo de excusa en algún bloque del día. Sale de la asistencia; no se marca a mano. |
| `NO_ASISTIO_NO_JUSTIFICADA` | Faltó sin excusa. Sale de la asistencia; no se marca a mano. |

A mano solo se marca `NO_PRESENTO` o `PENDIENTE`. `NO_PRESENTO` exige que no
haya nota (400): primero se quita la nota. `PENDIENTE` borra la nota (Regla 62).

### 1.1 `PUT /planeador/actividades/estudiantes/:ID/estado-resultado`

Marca el estado de **un** estudiante. `:ID` = `pk_tactividad_estudiante`.

**Body:** `{ "ESTADO": "NO_PRESENTO" }`

**Respuesta:** `{ "estado_resultado": "NO_PRESENTO" }` (el valor guardado).

**Roles:** `CEVAL-SUPER_ADMINISTRADOR`, `CEVAL-DOCENTE`.

**Errores:** 404 si la asignación no existe; 400 si la actividad fue
eliminada, su referente está inactivo, el estado no es válido (`CALIFICADO` o
`NO_ASISTIO_*`), el estudiante está No asistido, o se marca `NO_PRESENTO` con
nota; 403 sin alcance o si un docente toca una actividad que no creó.

### 1.3 `PUT /planeador/actividades/estudiantes/:ID/asistencia`

Asistencia de **un** estudiante en la actividad, marcada desde la tabla de
calificaciones. `:ID` = `pk_tactividad_estudiante`.

**Body:** `{ "TIPO_ASISTENCIA": 2 }` (1 Asistió, 2 No asistió, 5 Llegó tarde).

**Respuesta:** `{ "estado_resultado": "..." }`.

- Nunca cambia la asistencia de la Vista: el cambio queda en **esta
  actividad**.
- Si ese día no se tomó la Vista, la asistencia **oficial** en `TASISTENCIA`
  (`ORIGEN = PLANEADOR`, una fila por bloque) se recalcula con las marcas de
  todas las actividades del día: presente si asistió en alguna, tarde si solo
  llegó tarde, ausente si faltó en todas. Las actividades del día sin marca
  propia ni resultado toman su estado.
- Si después se guarda la Vista, esa pasa a ser la oficial. Las actividades
  con marca propia del Planeador **conservan su marca** (es la asistencia de
  esa actividad); las demás toman la de la Vista.
- No asistió → `NO_ASISTIO_JUSTIFICADA` si la Vista trae excusa ese día, si no
  `NO_ASISTIO_NO_JUSTIFICADA`. Asistió o Llegó tarde devuelven a `PENDIENTE`.
- No asistió marcado aquí queda **No justificada** hasta que se suba la excusa
  en la Vista Asistencias; entonces pasa a Justificada sin perder el cambio.
- Con nota no se puede cambiar (y tampoco marcar No presentó).

**Errores:** 400 si ya tiene nota u observación (congelada), la actividad aún no
empieza o fue eliminada; 400 (23503) si el tipo no es 1, 2 o 5; 403 sin alcance
o Regla 54.

### 1.2 `PUT /planeador/actividades/:ID/estado-resultado-bulk`

Mismo estado para **varios** estudiantes de la actividad `:ID` = `pk_tactividad`.

**Body:** `{ "ESTADO": "NO_PRESENTO", "ESTUDIANTES": [501, 502] }`
(`ESTUDIANTES` = `pk_tactividad_estudiante[]`; `ESTADO` = `NO_PRESENTO` o `PENDIENTE`).

| Columna | Significado |
|---|---|
| `pk_tactividad_estudiante` | Estudiante. |
| `estado_resultado` | Estado guardado para ese estudiante. |

**Roles:** `CEVAL-SUPER_ADMINISTRADOR`, `CEVAL-DOCENTE`.

**Errores:** igual que 1.1, por lote (si un estudiante no es de la actividad,
se rechaza).

---

## 2. Calificaciones: columnas nuevas (Regla 58)

`GET /planeador/actividades/:ID/calificaciones` (tabla "Calificaciones:
\<actividad>") y `GET /planeador/actividades/estudiantes/:ID/nota` (detalle de
un estudiante) agregan, al final de la fila, estas columnas respecto a la
versión documentada en `calificacion-y-materiales-endpoints.md`:

| Columna | Significado |
|---|---|
| `estado_resultado` | Ver la tabla de valores arriba. El No asistido que sale de la asistencia ya viene reflejado aquí; el front no lo infiere. |
| `tipo_asistencia_valor`, `asistencia_justificada`, `origen_asistencia`, `asistencia_editable` | Asistencia de la actividad: código 1/2/5, si hay excusa, `ASISTENCIA` (Vista) o `PLANEADOR`, y si todavía se puede cambiar (`false` con resultado). |
| `momento` | Momento del registro narrativo (observación), solo relevante en formativas. |
| `evidencia_enlace` | Enlace de evidencia de la observación, si se registró uno. |
| `resultados_completos` | **Regla 58.** `true` solo si **ningún** estudiante de la actividad quedó en `PENDIENTE`; es el mismo valor en todas las filas de la respuesta (se usa para pintar el indicador "completo" de la actividad, no por estudiante). |

Las demás columnas (`instrumento`, `calificacion`, `nota_homologada`,
`valoracion`, `resultado_instrumento`, etc.) no cambiaron: ver la sección 3
de `calificacion-y-materiales-endpoints.md`.

---

## 3. Calificar: `solicitudes_pendientes` (Reglas 55/69/70)

Los endpoints de calificar (individual y los tres de bloque: rúbrica, cotejo,
escala) ahora **nunca fallan** cuando el cambio exige aprobación del
Coordinador — lo aplican o abren una solicitud, pero siempre responden 200.
Cada respuesta agrega la columna:

| Columna | Significado |
|---|---|
| `solicitudes_pendientes` | Arreglo de `pk` de solicitudes de aprobación abiertas por esta llamada. **Vacío `[]`** = el cambio se aplicó directo. **Con elementos** = el cambio quedó pendiente de que un Coordinador lo apruebe o rechace (sección 4); la nota/estado mostrados en la respuesta son el valor **anterior**, no el propuesto. |

Qué dispara una solicitud en vez de aplicar directo (Reglas 55/69/75):
recuperación (Habilitación o Refuerzo) y corrección de un resultado o de una
asistencia ya existentes, cuando el usuario no tiene el nivel para aplicarlo
directo. El front debe mostrar un aviso ("queda pendiente de aprobación")
cuando `solicitudes_pendientes` no esté vacío, en vez de asumir que la nota ya
quedó guardada.

Afecta: `PUT .../estudiantes/:ID/calificar`, los tres `calificar-bulk/*`, y
`PATCH /asistencias/:ID` (fuera del alcance de este documento, documentado en
el de asistencias).

---

## 4. Aprobaciones del Coordinador (nuevo)

Quien resuelve: Coordinador (de las sedes donde lo es) o super administrador
(todas). **Roles:** `CEVAL-COORDINADOR`, `CEVAL-SUPER_ADMINISTRADOR`.

### 4.1 `GET /aprobaciones/pendientes`

Lista las solicitudes que el usuario puede resolver.

**Query:** `?tipo=` (`RECUPERACION_HABILITACION`, `RECUPERACION_REFUERZO`,
`CORRECCION_RESULTADO` o `CORRECCION_ASISTENCIA`), `?grupo=` (`pk_tgrupo`),
`?estado=` (`PENDIENTE` por defecto, `APROBADA` o `RECHAZADA`). Todos
opcionales.

| Columna | Significado |
|---|---|
| `pk_tsolicitud_aprobacion` | Id de la solicitud, el `:ID` de aprobar/rechazar. |
| `tipo`, `tipo_nombre` | Código y nombre del tipo de solicitud. |
| `estado` | `PENDIENTE` / `APROBADA` / `RECHAZADA`. |
| `tabla_objeto`, `fk_objeto` | Qué fila originó la solicitud. |
| `fk_tgrupo`, `grupo`, `fk_tasignatura`, `asignatura`, `fk_tperiodo_evaluacion`, `periodo_evaluacion`, `fk_tactividad`, `actividad` | Contexto para mostrar en la lista. |
| `estudiante` | Estudiante afectado. |
| `valor_anterior`, `valor_propuesto` | JSON con el valor antes/después del cambio. |
| `solicitante`, `fecha_solicitud`, `motivo` | Quién la abrió, cuándo y por qué. |
| `aprobador`, `fecha_resolucion`, `motivo_resolucion` | Solo si ya se resolvió. |

**Errores:** 403 si el usuario no es Coordinador en ninguna sede (y no es
super admin).

### 4.2 `POST /aprobaciones/:ID/aprobar`

Aprueba la solicitud `:ID` y **aplica el cambio**: la recuperación se
consolida, o la corrección de resultado/asistencia se escribe.

**Body:** `{ "MOTIVO": "..." }` (opcional, máximo 1000 caracteres).

**Respuesta:** `{ "pkSolicitud": ..., "estado": "APROBADA", "tipo": "...", "resultado": ..., "informeDesactualizado": true|false }`.

`informeDesactualizado` (Regla 71): `true` si el informe del grupo y periodo
afectados ya se había emitido antes de esta aprobación — ver sección 5.

**Errores:** 404 si no existe; 400 si ya fue resuelta o el motivo supera 1000
caracteres; 403 si el usuario no es Coordinador de la sede del grupo (ni super
admin).

### 4.3 `POST /aprobaciones/:ID/rechazar`

Rechaza la solicitud `:ID`. El valor vigente **no cambia** (Regla 70).

**Body:** `{ "MOTIVO": "..." }` (**obligatorio**, máximo 1000 caracteres).

**Respuesta:** `{ "pkSolicitud": ..., "estado": "RECHAZADA", "valorVigente": ... }`.

**Errores:** 404 si no existe; 400 si ya fue resuelta o falta el motivo; 403
si el usuario no es Coordinador de la sede del grupo.

---

## 5. Informe desactualizado (Regla 71, nuevo)

### 5.1 `GET /informes/desactualizado`

Advierte cuando una aprobación cambió un valor **después** de que el informe
del grupo ya se había emitido/guardado.

**Query:** `?grupo=` (`pk_tgrupo`), `?periodo=` (`pk_tperiodo_evaluacion`).

**Respuesta:** `{ "desactualizado": true|false, "mensaje": "...", "cambios": [...] }`.
La marca se limpia automáticamente al volver a guardar el informe.

**Roles:** los mismos que `POST /informes/grupo` (hereda sus `role_query`).

**Errores:** 404 si el grupo no existe; 403 sin alcance sobre el grupo.

---

## 6. Planilla de calificación (grupo + asignatura + periodo)

Pantalla distinta de `/planeador/planilla/*` (planilla del docente, sin
periodo de evaluación): esta acota por **periodo de evaluación**, usa la
misma proyección que detecta cambios
(`fn_asignatura_definitiva_proyectada_periodo`) y su línea base es
`TASIGNATURA_NOTA` — donde el módulo consolida de verdad. **Roles:**
`CEVAL-SUPER_ADMINISTRADOR`.

### 6.1 `POST /informes/planilla`

Una fila por estudiante del grupo con su definitiva del periodo (guardada y
proyectada, en porcentaje y homologadas) y las actividades del periodo
embebidas.

**Body:** `{ "FK_TGRUPO": ..., "FK_TASIGNATURA": ..., "FK_TPERIODO_EVALUACION": ..., "SEARCH": "..." }` (`SEARCH` opcional).

| Columna | Significado |
|---|---|
| `fk_tmatricula`, `fk_testudiante`, `estudiante`, `documento` | Identificación del estudiante. |
| `definitiva_guardada`, `definitiva_proyectada` | Porcentaje 0–100. |
| `definitiva_guardada_homologada`, `definitiva_proyectada_homologada` | En el formato del colegio. |
| `estado_nota`, `es_numerico`, `nota_maxima`, `formato_valor`, `valoracion_nombre`, `aprobada` | Metadatos para pintar la celda. |
| `actividades` | `JSONB`: una celda por actividad con `orden`, `titulo`, `estado` (`CALIFICADA` / `PENDIENTE` / `NO_ASIGNADA` / `NO_CALIFICABLE`), `porcentaje`, nota homologada y `pkTactividadEstudiante` (para el popover). |
| `total_count` | Total para paginar (sin paginación real: todas las filas la repiten). |

**Importante:** todas las filas traen las mismas columnas de `actividades` en
el mismo orden, incluidas las `NO_ASIGNADA`: el header se arma con cualquier
fila sin riesgo de desalinearse del cuerpo. `SEARCH` filtra dos dimensiones a
la vez (nombre de estudiante y título de actividad) dejando intacta la
dimensión sin coincidencias.

**Errores:** 404 si no existe el grupo, la asignatura o el periodo; 400 si
falta grupo o asignatura, o si el periodo no es del periodo académico del
grupo; 409 si el grado enviado no es el del grupo.

### 6.2 `POST /informes/planilla/guardar`

Congela la definitiva de **una** asignatura desde la planilla ("Aprobar y
actualizar consolidado").

**Body:** `{ "FK_TGRUPO": ..., "FK_TASIGNATURA": ..., "FK_TPERIODO_EVALUACION": ..., "MATRICULAS": [...] }`
(`MATRICULAS` vacío o ausente = todos los estudiantes del grupo).

| Columna | Significado |
|---|---|
| `fk_tmatricula`, `estudiante` | Estudiante. |
| `resultado` | `guardada` / `actualizada` (con `nota_anterior`) / `sin_cambio` / `sin_proyeccion`. |
| `nota_anterior`, `nota_guardada` | Antes/después, en porcentaje. |
| `promedio_periodo`, `aprobadas`, `reprobadas` | Ya **recalculados** para refrescar la pantalla sin volver a pedir el listado. |

Convive con `POST /informes/guardar` (congela **todas** las asignaturas): no
se pisan — `TASIGNATURA_NOTA` es por (matrícula, periodo, asignatura) — y los
dos recalculan las mismas métricas, así que el orden no importa; ambos son
idempotentes. En `sin_proyeccion` (sin actividad evaluativa calificada en el
periodo) lo ya guardado **no se borra**.

**Errores:** 404 si no existe grupo, asignatura o periodo; 400 si el periodo
no es del periodo académico del grupo; 409 si el grado no es el del grupo.

### 6.3 `POST /informes/planillas-pendientes`

Alerta roja: planillas sin **nada** registrado. Una fila por (grupo,
asignatura, periodo) ya **terminado** (`FECHA_FIN < hoy`) con el docente
asignado, cuántos estudiantes tiene el grupo y cuántas actividades existen (0
= ni siquiera se armaron). Cuenta como calificado cualquier nota **u
observación** (preescolar).

**Body:** `{ "GRUPOS": [...], "PERIODOS": [...] }` (`PERIODOS` opcional).

| Columna | Significado |
|---|---|
| `fk_tgrupo`, `grupo_nombre`, `fk_tasignatura`, `asignatura_nombre` | Contexto. |
| `fk_tfuncionario`, `fk_tusuario_docente`, `docente`, `docentes_asignados` | Responsable(s). |
| `fk_tperiodo_evaluacion`, `periodo_nombre`, `periodo_abreviacion`, `periodo_fin` | Periodo. |
| `estudiantes`, `actividades` | Conteos. |

Misma firma que la alerta naranja (planillas incompletas, documentada aparte)
para que el front las trate igual.

---

## 7. Informe final: nota del año (Regla 79)

### 7.1 `POST /informes/final/guardar`

Consolida la nota del **año** de un grupo en `TASIGNATURA_DEFINITIVA`. Cada
periodo vale su nota guardada o, si no la tiene, la proyectada, y se pesa con
`PORCENTAJE` cuando el criterio final del grado es por porcentaje y los
periodos suman 100 (si no, equitativo); un periodo sin ningún valor no cuenta
como cero, sale del promedio. **Nada la recalcula sola**: solo cambia al
volver a llamar este endpoint — la fila "Final" de `POST /informes/grupo` lee
lo guardado aquí y, si no existe, la calcula al vuelo para mostrarla (sin
escribir).

**Body:** `{ "FK_TGRUPO": ..., "FK_TMATRICULAS": [...] }` (`FK_TMATRICULAS`
opcional: vacío o ausente = todo el grupo).

| Columna | Significado |
|---|---|
| `fk_tmatricula`, `estudiante` | Estudiante. |
| `guardadas`, `actualizadas`, `sin_nota`, `sin_cambio` | Conteo de asignaturas por resultado. |
| `detalle` | `JSONB`: `[{asignatura, resultado, nota, anterior}]` por asignatura. |

**Roles:** los mismos que `POST /informes/guardar` (hereda sus `role_query`).

**Errores:** 404 si el grupo no existe. Gate `EDITAR` sobre `INFORMES` con
alcance (establecimiento, sede, jornada) del grupo, y recorte por grupo propio.

---

## 8. Escalas de valoración

Administración de las escalas de calificación del colegio (no confundir con
el instrumento `ESCALA_VALORACION` de una actividad puntual, documentado en
`calificacion-y-materiales-endpoints.md`). **Roles:**
`CEVAL-AUXILIAR_ADMINISTRATIVO`, `CEVAL-COORDINADOR`,
`CEVAL-DIRECTOR_ENTE_TERRITORIAL`, `CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL`,
`CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO`, `CEVAL-RECTOR`,
`CEVAL-SUPER_ADMINISTRADOR`, `SSO-ADMIN` (`CEVAL-DOCENTE` se agrega solo en
8.3, de solo lectura).

### 8.1 `POST /escalas`

Crea o actualiza en bloque niveles de escala.

**Body:** `{ "ACADEMIC_PERIOD_ID": ..., "TEACHING_LEVEL_IDS": [...], "SCALES": [...] }`
(`SCALES` va en `BODY_RAW`, JSON crudo con la estructura de niveles).

**Respuesta:** `{ "cantidad": N }`, el número de niveles guardados.

### 8.2 `PUT /escalas/:ID`

Elimina (soft-delete) un nivel de escala.

**Respuesta:** `{ "id_eliminado": ... }`.

### 8.3 `POST /escalas/:PERIODO_ACADEMICO_ID`

Lista los niveles de escala del periodo académico `:PERIODO_ACADEMICO_ID`
(obligatorio).

**Body:** `{ "FILTRO": "...", "TEACHING_LEVEL_ID": ... }` (ambos opcionales).

| Columna | Significado |
|---|---|
| `id`, `nombre`, `abreviacion` | La escala. |
| `tipo`, `tipo_name` | `NUMERICA` / `CUALITATIVA`. |
| `iconografia` | Ícono asociado. |
| `teaching_level_id`, `teaching_level_name` | Nivel de enseñanza. |
| `nota_minima`, `nota_maxima`, `nota_equivalente` | Rango y equivalencia del nivel. |
| `escala_id` | La escala a la que pertenece el nivel. |

### 8.4 `POST /escalas/bulk-delete`

Elimina (soft-delete) varios niveles por `pk`, acotado al periodo académico.

**Body:** `{ "PERIODO_ACADEMICO_ID": ..., "IDS": [...] }`.

| Columna | Significado |
|---|---|
| `id` | Nivel. |
| `eliminado` | `true`/`false`. |
| `error_code`, `error_mensaje` | Si falló ese nivel puntual. |

### 8.5 `POST /escalas/reporte`

Variante de 8.3 para exportar/reportar, filtrando por una lista de `id`
concreta además de nivel/tipo/periodo.

**Body:** `{ "FILTERS": { "IDS": [...], "TIPO": "...", "FK_NIVEL": ..., "FK_PERIODO": ... } }`.
Misma forma de respuesta que 8.3. `IDS` nulo = todas las que cumplan los demás
filtros.

### 8.6 `POST /escalas/valoraciones/bulk-delete`

Elimina (soft-delete) niveles de **valoración** cualitativa por `pk`, sin
acotar a un periodo.

**Body:** `{ "IDS": [...] }`. Misma forma de respuesta que 8.4.

### 8.7 `PUT /periodos/:PERIODO_ID/niveles/:NIVEL_ID/escala`

Elimina (soft-delete) la asociación de un nivel de enseñanza con un periodo
académico.

**Respuesta:** una fila (ver `fn_escala_nivel_soft_delete`); devuelve el `id`
afectado.

---

## 9. Redondeo, tope de recuperación y escala multi-criterio (reglas existentes, sin endpoint propio)

Documentadas aquí porque afectan lo que estos endpoints devuelven y validan:

- **Regla 30 — redondeo institucional:** toda nota homologada a la escala del
  colegio se redondea a **1 decimal** sobre el rango de esa escala (por
  ejemplo, 4.3 sobre 5), nunca sobre el porcentaje crudo.
- **Regla 31 — tope de recuperación:** si la actividad es una recuperación y
  la nota calculada supera el tope institucional, el endpoint de calificar
  **rechaza con 400**; no recorta el valor en silencio.
- **Regla 56 — escala con varios criterios:** la nota final de una escala con
  `criteriosGenerales` es `Σ obtenido / Σ máximo` de todos los criterios, no
  el promedio simple de sus porcentajes individuales.
- **Regla 40 — escala-precarga:** `GET /planeador/actividades/escala-precarga`
  (documentado en `calificacion-y-materiales-endpoints.md`, sección de
  instrumento) resuelve la escala vigente para proponer valores iniciales al
  construir el instrumento; el docente puede editarlo todo después.
