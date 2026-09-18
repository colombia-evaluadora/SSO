# Planeador — cómo se determina la configuración de una actividad

Entradas y salidas de los endpoints que deciden qué se pinta y qué se acepta al
crear, editar y consultar una actividad, y cómo se encadenan en los dos casos:
**con unidad** y **sin unidad**.

Estado leído de `dev` tras #324 (Flyway ≥ V450). El endpoint de configuración
*por contexto* (`GET /planeador/actividades/configuracion`, V422) vive en la
PR #319 y aún no está en `dev`; se menciona donde aplica.

---

## 1. La cadena de derivación

Todo cuelga de **quién decide el referente curricular**, porque de él salen
tres cosas: si hay sección de evaluación, qué instrumentos se ofrecen y si la
actividad se califica con nota o con observación.

```
grupo ──► grado ──► nivel de enseñanza ──┐
                                          ├──► referente ──► enfoque (EVALUATIVO | FORMATIVO)
asignatura ──► área (TAREA_ASIGNATURA) ──┘                └──► tipo de evaluación ──► instrumentos
```

Hay **una sola función** que hace ese recorrido: `fn_unidad_referente_aplicable(grado, asignatura, año)`.
La usan `fn_unidad_crear` (cuando el cliente no manda referente), V280 (reparación),
`fn_docente_unidad_tabs_listar` (V407) y, en #319, `fn_actividad_configuracion_contexto`.

**Con unidad**, el referente ya está fijado en `TUNIDAD.FK_REFERENTE_CURRICULAR`
y nadie lo vuelve a derivar: la unidad es la fuente de verdad.
**Sin unidad**, se deriva de (grado, asignatura) con esa función.

### El fallo que corrige V451

La regla de V216 trataba las áreas del referente como **exclusión**: un
referente acotado a áreas que no incluyeran el área de la asignatura quedaba
fuera. Como un nivel puede tener varios referentes y el de Preescolar (24)
tiene dos áreas declaradas, `(Jardin I, SEGUIMIENTOS1)` devolvía **NULL** y
las unidades nuevas de Preescolar nacían sin referente — sin etiquetas, sin
árbol de enunciados, sin sección de evaluación.

La regla nueva (V451) usa las áreas como **preferencia**, con tres niveles:

| Prioridad | Referente activo (`ESTADO='A'` y `ACTIVE=true`), del mismo nivel, vigente… |
|---|---|
| 1 | …que **lista el área de la asignatura** |
| 2 | …**sin áreas** (aplica a todas) |
| 3 | …cualquier otro |

Dentro de cada nivel gana el de **vigencia más reciente**. Se devuelve NULL
solo si no hay ninguno activo para ese nivel.

> "Activo" significa las dos cosas a la vez: `ESTADO` es el estado de negocio
> que edita el usuario en el catálogo; `ACTIVE` es el borrado lógico. En test
> hay referentes con uno sin el otro.

---

## 2. Configuración ANTES de crear

### Con unidad — `GET /planeador/unidades/:ID/configuracion-actividad`

| | |
|---|---|
| **Función** | `fn_unidad_configuracion_actividad(usuario, pk_tunidad, es_sumativo='S')` — V282, cuerpo en V458 |
| **Entra** | `ID` = PK_TUNIDAD, `ES_SUMATIVO` = `S`/`N` (lo que el usuario acaba de marcar; sin enviarlo, `S`) |
| **Sale** | `{pkTunidad, unidad, nivelEnsenanza, esSumativoConsultado, campos_disponibles:{criterio, evaluacion, ponderacion, recuperacion}}` |
| **De dónde sale cada bloque** | `criterio` ← nivel del grado de la unidad (Preescolar apaga) · `evaluacion` ← `fn_unidad_referente_evaluativo` + `fn_unidad_referente_tipo_evaluacion` · `ponderacion` ← `fn_unidad_calculo_definitiva_modo` · `recuperacion` ← evaluativo **y** `ES_SUMATIVO≠N`. Con `N` **solo** se apagan `recuperacion` y `ponderacion`; `evaluacion` sale del referente igual que con `S` (V458) |

### Sin unidad — hoy en `dev` **no hay endpoint**

El formulario de nueva actividad sin unidad no puede pintarse desde el back
hasta que #319 aporte `GET /planeador/actividades/configuracion?GRUPO=&ASIGNATURA=&UNIDAD=`
(`fn_actividad_configuracion_contexto`). Ese endpoint deriva el referente con
`fn_unidad_referente_aplicable`, por lo que **V451 lo corrige de rebote**.

Mientras tanto, lo único consultable sin unidad es el catálogo de referentes:
`GET /planeador/referente-curricular?GRADO=&ASIGNATURA=` (V278), que devuelve
el conjunto ordenado por especificidad. **Ojo**: V278 conserva la regla de
exclusión por área en su CTE `candidatos`; V451 no la toca para no pisar la
edición in-place que #319 hace de V278 (V451 correría después y la revertiría).
Queda como seguimiento alinearla cuando #319 esté en `dev`.

---

## 3. Crear — `POST /planeador/actividades`

`fn_actividad_crear` (V224). Lo que decide la configuración:

| Entrada | Efecto |
|---|---|
| `FK_TGRUPO` + `FK_TASIGNATURA` | Contexto. Obligatorios para el gate de alcance y para derivar grado/nivel |
| `FK_TUNIDAD` | Opcional. **Si viene, el referente es el de la unidad**; si no, la actividad queda sin referente y `fn_actividad_es_formativa` devuelve FALSE |
| `ES_EVALUATIVA` | `S`/`N`. Con `N` se apagan instrumento, ponderación y recuperación |
| `FK_TLV_INSTRUMENTO_EVALUACION` | Debe estar en `instrumentosPermitidos` del referente. **RÚBRICA exige unidad** |
| `RECUPERACION` (JSONB) | Solo con referente evaluativo y `ES_EVALUATIVA='S'`. **Debe viajar serializado como string**: como objeto anidado el binder lo ignora en silencio |

### El callejón sin salida de la actividad sin unidad

Una actividad **sin `FK_TUNIDAD`** en un contexto sin referente evaluativo no
se puede evaluar por ninguna vía:

- `PUT .../observar` → *"tiene referente EVALUATIVO (o no tiene unidad): use calificar"*
- `PUT .../calificar` → *"no tiene un instrumento de evaluación válido"*

Y el mensaje de `observar` desorienta: la causa es "no tiene unidad". V451 no
cambia esto (es comportamiento de V243); queda anotado.

---

## 4. Consultar el detalle

### `GET /planeador/actividades/:ID` — `fn_actividad_buscar_por_pk` (V224)

Devuelve la fila completa más cinco JSONB ya resueltos:

| Clave | Contenido |
|---|---|
| `campos_disponibles` | `fn_actividad_campos_disponibles(usuario, pk)` — los cuatro bloques, **por actividad** (V214.2, cuerpo en V440) |
| `unidad_configuracion` | `fn_actividad_unidad_configuracion(usuario, pk)` — snapshot de la unidad: referente, objetivos, contenidos, rúbrica |
| `recuperacion` | Con nombres resueltos y `actividadRecuperarTitulo`; `null` si no es de recuperación |
| `materiales`, `adaptaciones` | Listas |
| `evidencias`, `criterios` | Solo en #319 |

Para una actividad **sin unidad**, `unidad_configuracion` viene `{tieneUnidad:false}`
y `campos_disponibles.evaluacion.motivo` dice *"La actividad no tiene unidad relacionada"*.

### `GET /planeador/actividades/:ID/pantalla-edicion` — `fn_actividad_pantalla_edicion` (V353)

El mismo contenido compuesto en un solo JSONB para la pantalla:
`{actividad:{…,banderas:{esEvaluativa, esRecuperacion,…}}, camposDisponibles, unidadConfiguracion, recuperacion, instrumento, materiales, adaptaciones}`.

### `GET /planeador/actividades/:ID/configuracion`

`fn_actividad_campos_disponibles` + `fn_actividad_unidad_configuracion` sueltos.
Es la versión *post-creación* del §2.

---

## 5. Cómo se combinan en el formulario

```
1. El usuario elige GRUPO y ASIGNATURA
2. (opcional) elige UNIDAD  ──► GET /unidades/:ID/configuracion-actividad?ES_SUMATIVO=
                                └─ sin unidad: en dev no hay nada; en #319, GET /actividades/configuracion
3. La respuesta dice qué pintar: evaluacion.instrumentosPermitidos, recuperacion.catalogos, criterio, ponderacion
4. POST /actividades con los pk que salieron de (3)  ──► nunca pk copiados de otro entorno
5. GET /actividades/:ID  ó  /pantalla-edicion  ──► el detalle ya trae campos_disponibles recalculados
```

La invariante que sostiene todo: **los PK de `TLISTA_VALOR` no son estables
entre entornos**. Todo pk que el front mande debe haber salido de una respuesta
de configuración del mismo servidor (`instrumentosPermitidos[].pk`,
`recuperacion.catalogos.*[].pk`), decidiendo por `valor`.

---

## 6. Qué cambia V451, y qué no

| | |
|---|---|
| **Cambia** | `fn_unidad_referente_aplicable`: áreas como preferencia (3 niveles) en vez de exclusión. Misma firma, `CREATE OR REPLACE` sin `DROP` |
| **Se beneficia sin tocarlo** | `fn_unidad_crear` (unidades nuevas de Preescolar ya nacen con el 24), V280, `fn_docente_unidad_tabs_listar`, y en #319 `fn_actividad_configuracion_contexto` |
| **No cambia** | El catálogo V278 (para no pisar #319), el mensaje de `observar` sin unidad (V243), y la regla de que el referente de una actividad **con** unidad es el de la unidad |
