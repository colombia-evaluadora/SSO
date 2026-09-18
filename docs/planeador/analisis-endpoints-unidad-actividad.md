# Planeador — análisis de endpoints de Unidad y Actividad

Qué recibe y qué devuelve cada endpoint del Planeador que toca **unidades** y
**actividades**, y dónde el contrato no cuadra con lo que la pantalla necesita.

Fuente: filas de `public.query` (`serviceid = eval-col`) y firmas reales de
`pg_proc` leídas del Postgres local `sso-postgres` (Flyway V403). Ruta real a
través del gateway: `api/eval-col/<path>`.

---

## 1. El problema reportado: el referente de una unidad lista *todos* los enunciados

`GET /planeador/unidades/:ID/referente` → `fn_unidad_referente_detalle` (V255).

La columna `enunciados` **no** contiene los enunciados que la unidad relacionó.
Contiene **todo el árbol del referente curricular**, con una marca por enunciado:

```jsonc
"enunciados": [
  { "pk": 31, "texto": "...", "relacionadoConUnidad": true,  "pkTunidadEnunciado": 88,
    "evidencias": [ { "pk": 45, "texto": "..." } ] },
  { "pk": 32, "texto": "...", "relacionadoConUnidad": false, "pkTunidadEnunciado": null,
    "evidencias": [ ... ] }
]
```

Esto **es deliberado** y está documentado en la cabecera de V255: el endpoint
es la fuente para *pintar el formulario de marcado* — necesita el catálogo
completo para ofrecer casillas, `relacionadoConUnidad` para pre-marcarlas y
`pkTunidadEnunciado` para poder desmarcarlas (`PATCH
/planeador/unidades/enunciados/:ID` pide el PK de la **relación**, no el del
enunciado).

Consecuencias reales, aun siendo intencional:

- **No existe un endpoint de solo-lectura de lo relacionado.** Si la pantalla
  es de *consulta* (ver la unidad, no editarla), el front tiene que filtrar
  `relacionadoConUnidad === true` por su cuenta. No hay parámetro
  (`?SOLO_RELACIONADOS=true`) ni endpoint hermano que lo haga en la base.
- **El filtro es asimétrico.** `relacionadoConUnidad` solo marca el **nivel 1**
  (enunciado). Las `evidencias` anidadas vienen **siempre completas**, sin marca
  y sin recorte: incluso bajo un enunciado no relacionado. Una pantalla que
  recorra el árbol para mostrar evidencias muestra evidencias de enunciados que
  la unidad nunca marcó.

### 1.1 Bug real: el árbol no filtra por área (`FK_REFERENTE_CURRICULAR_AREA`)

`TREFERENTE_ENUNCIADO` tiene `FK_REFERENTE_CURRICULAR_AREA` (V212/V214.3) —
un enunciado de nivel 1 puede estar acotado a un área del catálogo nacional
(`chk_trefenunc_area_solo_nivel1` lo restringe a nivel 1). **Ninguna función
del Planeador la lee**:

```
$ grep -rl FK_REFERENTE_CURRICULAR_AREA postgres/migrations/
V212__referente_curricular_schema.sql
V213__referente_curricular_crud.sql
V214.3__referente_curricular_nombre_asignatura.sql
```

Ni V255 ni V278 aparecen. Las dos construyen el árbol con:

```sql
WHERE en.FK_REFERENTE_CURRICULAR = rc.PK_REFERENTE_CURRICULAR
  AND en.FK_PADRE IS NULL
  AND en.ACTIVE = TRUE
```

Es decir, **todos** los enunciados del referente, sean del área de la unidad o no.

Es una incoherencia dentro de la propia V278: allí el *referente* sí se filtra
por área (`TREFERENTE_CURRICULAR_AREA` contra
`COALESCE(TASIGNATURA.FK_TAREA_ASIGNATURA, TAREA.FK_TAREA_ASIGNATURA)`), pero
sus *enunciados* no. Un referente de nivel acotado por áreas devuelve a una
unidad de Matemáticas los enunciados de Ciencias.

Esto explica el síntoma reportado incluso en pantallas que **sí** filtran por
`relacionadoConUnidad`: sobran enunciados que no pertenecen ni al área de la
unidad.

> No se pudo reproducir con datos: el Postgres local no trae catálogo de
> referentes (`treferente_enunciado` = 0 filas; llega por el dump base). La
> conclusión es estática, sobre el SQL de V255/V278 y el DDL de V212.

### 1.2 Lo que sí funciona

`POST /planeador/unidades` (`fn_unidad_crear`, V216) acepta `BODY.ENUNCIADOS
BIGINT[]` y los persiste vía `fn_unidad_enunciado_relacionar` (valida nivel 1 y
mismo nivel de enseñanza; aborta el CREATE si alguno no cumple). La relación
queda en `TUNIDAD_ENUNCIADO` con unicidad parcial
`u_tunidad_enunciado_1 (fk_tunidad, fk_referente_enunciado) WHERE active`. La
escritura no es el problema.

---

## 2. Bug real: lo que se marca en la actividad no se puede volver a leer

`TACTIVIDAD_EVIDENCIA` y `TACTIVIDAD_CRITERIO_UNIDAD` tienen escritores y ningún lector.

| Tabla | Escriben | Leen |
|---|---|---|
| `TACTIVIDAD_EVIDENCIA` | `fn_actividad_crear` (`p_evidencias`), `fn_actividad_evidencia_relacionar`, `fn_actividad_evidencia_quitar` | — |
| `TACTIVIDAD_CRITERIO_UNIDAD` | `fn_actividad_crear` (`p_criterios`), `fn_actividad_criterio_relacionar`, `fn_actividad_criterio_quitar` | — |

Verificado sobre `pg_proc`: ninguna función de lectura del esquema las menciona.
En concreto:

- `fn_actividad_buscar_por_pk` (`GET /planeador/actividades/:ID`) devuelve 50
  columnas — `materiales`, `adaptaciones`, `recuperacion`, `campos_disponibles`,
  `unidad_configuracion` — y **ni evidencias ni criterios**.
- `fn_actividad_pantalla_edicion` (`GET /planeador/actividades/:ID/pantalla-edicion`,
  V353), que es literalmente "la pantalla de edición", tampoco los trae.
- `fn_unidad_configuracion_actividad` (V282) declara explícitamente que el árbol
  no va allí y remite a `GET /planeador/unidades/:ID/referente` — que, como no
  conoce la actividad, tampoco puede decir qué evidencias marcó **esta**.

Resultado: al reabrir una actividad **no hay forma de pre-marcar sus evidencias
ni sus criterios**, ni de obtener los `PK_TACTIVIDAD_EVIDENCIA` /
`PK_TACTIVIDAD_CRITERIO_UNIDAD` que exigen los `PATCH .../evidencias/:ID` y
`PATCH .../criterios/:ID` para quitarlos. Esos PKs solo se conocen en la
respuesta del POST que los creó.

Además, `PUT /planeador/actividades/:ID` (`fn_actividad_actualizar`) **no acepta**
`EVIDENCIAS` ni `CRITERIOS` (sí los acepta el `POST` de creación): editar esa
parte obliga a ir uno a uno por los endpoints sueltos.

---

## 3. Catálogo de endpoints — UNIDAD

Todos con gate `VER/CREAR/EDITAR` sobre el menú `PLANEADOR`
(`fn_assert_permiso_seccion`) + alcance territorial `fn_planeador_assert_alcance`
(V277). Roles en el Postgres local: `CEVAL-SUPER_ADMINISTRADOR`, `CEVAL-DOCENTE`
(V249/V284/V305 añaden más en el servidor).

| Método | Ruta | Función | Devuelve |
|---|---|---|---|
| GET | `/planeador/unidades` | `fn_unidad_listar` | Listado paginado: `pk_tunidad, nombre, descripcion, asignatura, area, grado, docente, calculo_definitiva, fk_referente_curricular, referente_curricular, referente_vigente, total_actividades, total_objetivos, total_contenidos, fecha_inicio, fecha_fin, estado, active, dia, dia_anterior, dia_siguiente, total_count` |
| GET | `/planeador/unidades/:ID` | `fn_unidad_buscar_por_pk` | Fila única + `objetivos JSONB`, `contenidos JSONB`, `campos_disponibles JSONB`, `referente_vigente`. **No trae enunciados.** |
| POST | `/planeador/unidades` | `fn_unidad_crear` | `BIGINT` (PK). Acepta `OBJETIVOS[]`, `CONTENIDOS[]`, `ENUNCIADOS BIGINT[]`, `PONDERACION` |
| PUT | `/planeador/unidades/:ID` | `fn_unidad_actualizar` | `BIGINT`. Acepta `LIMPIAR_REFERENTE`, `LIMPIAR_PONDERACION`. **No acepta `ENUNCIADOS`** — solo los endpoints sueltos |
| PATCH | `/planeador/unidades/:ID` | `fn_unidad_eliminar` | `BIGINT` (borrado lógico) |
| GET | `/planeador/unidades/:ID/referente` | `fn_unidad_referente_detalle` | Ver §1. Contexto + referente + etiquetas + `enunciados JSONB` (árbol **completo**) |
| POST | `/planeador/unidades/:ID/enunciados` | `fn_unidad_enunciado_relacionar` | `BIGINT` = `PK_TUNIDAD_ENUNCIADO` |
| PATCH | `/planeador/unidades/enunciados/:ID` | `fn_unidad_enunciado_quitar` | `BOOLEAN`. `:ID` = PK de la **relación** |
| GET | `/planeador/unidades/:ID/objetivos` | `fn_unidad_objetivos_listar` | `pk_tunidad_objetivo, orden, descripcion` |
| GET | `/planeador/unidades/:ID/contenidos` | `fn_unidad_contenidos_listar` | `pk_tunidad_contenido, orden, descripcion` |
| GET | `/planeador/unidades/:ID/criterios` | `fn_unidad_criterio_listar` | `pk_tcriterio_unidad, orden, descripcion, publico, codigo, descriptor_prom, niveles JSONB, active` |
| POST / PUT / PATCH | `/planeador/unidades/:ID/criterios`, `/planeador/unidades/criterios/:ID` | `fn_unidad_criterio_agregar` / `_actualizar` / `_eliminar` | `BIGINT` |
| GET | `/planeador/unidades/:ID/valoraciones` | `fn_unidad_valoraciones_listar` | Escala: `valoracion_codigo/nombre/simbolo/carita`, `limite_inferior/superior`, `nota_minima/maxima`, `formato_valor`, `es_numerico` |
| GET | `/planeador/unidades/:ID/actividades` | `fn_unidad_actividades_listar` | Actividades vinculadas, paginado + `total_count` |
| GET | `/planeador/unidades/:ID/actividades-disponibles` | `fn_actividad_disponibles_listar` | Actividades sin unidad que se pueden enganchar + `porcentaje_disponible` |
| PUT | `/planeador/unidades/:ID/actividades/:ACTIVIDADID` | `fn_unidad_actividad_vincular` | `BIGINT`. `PERMITIR_MOVER_DE_UNIDAD` |
| PATCH | `/planeador/unidades/actividades/:ACTIVIDADID` | `fn_unidad_actividad_desvincular` | `BIGINT` |
| PUT | `/planeador/unidades/actividades/:ACTIVIDADID/ponderacion` | `fn_unidad_actividad_ponderacion_set` | `BIGINT` |
| GET | `/planeador/unidades/:ID/ponderacion-disponible` | `fn_unidad_ponderacion_disponible` | `NUMERIC` (% libre) |
| GET | `/planeador/unidades/:ID/configuracion-actividad` | `fn_unidad_configuracion_actividad` | `JSONB` `campos_disponibles` para el form de **nueva** actividad. `?ES_EVALUATIVA=S\|N` |
| GET | `/planeador/unidades/tabs` | `fn_docente_unidad_tabs_listar` | Pestañas del docente: instrumento, referente, etiquetas, `niveles/grados/asignaturas JSONB` |
| POST | `/planeador/unidades/export-all` | `fn_unidad_listar` | Mismo listado, contrato `FILTERS`/`SORTING` para el reporting |

## 4. Catálogo de endpoints — ACTIVIDAD

| Método | Ruta | Función | Devuelve |
|---|---|---|---|
| GET | `/planeador/actividades` | `fn_actividad_listar` | Listado paginado (33 columnas) + `estado`, `estudiantes_asignados/evaluados`, `porcentaje_evaluado`, `dia/dia_anterior/dia_siguiente`, `total_count` |
| GET | `/planeador/actividades/mias` | `fn_actividad_listar_docente` | Igual pero acotado al docente autenticado |
| GET | `/planeador/actividades/:ID` | `fn_actividad_buscar_por_pk` | 50 columnas + `materiales`, `adaptaciones`, `recuperacion`, `campos_disponibles`, `unidad_configuracion`. **Sin evidencias ni criterios** (§2) |
| GET | `/planeador/actividades/:ID/pantalla-edicion` | `fn_actividad_pantalla_edicion` | `JSONB` completo de la pantalla. **Sin evidencias ni criterios** (§2) |
| GET | `/planeador/actividades/:ID/configuracion` | `fn_actividad_campos_disponibles` + `fn_actividad_unidad_configuracion` | `JSONB` — qué secciones e instrumentos se habilitan |
| POST | `/planeador/actividades` | `fn_actividad_crear` | `BIGINT`. Acepta `EVIDENCIAS[]` y `CRITERIOS[]` |
| PUT | `/planeador/actividades/:ID` | `fn_actividad_actualizar` | `BIGINT`. **No acepta `EVIDENCIAS`/`CRITERIOS`** |
| PATCH | `/planeador/actividades/:ID` | `fn_actividad_eliminar` | `BIGINT` |
| POST | `/planeador/actividades/:ID/evidencias` | `fn_actividad_evidencia_relacionar` | `BIGINT` = `PK_TACTIVIDAD_EVIDENCIA` |
| PATCH | `/planeador/actividades/evidencias/:ID` | `fn_actividad_evidencia_quitar` | `BOOLEAN` |
| POST | `/planeador/actividades/:ID/criterios` | `fn_actividad_criterio_relacionar` | `BIGINT` |
| PATCH | `/planeador/actividades/criterios/:ID` | `fn_actividad_criterio_quitar` | `BOOLEAN` |
| GET / PUT | `/planeador/actividades/:ID/instrumento` | `fn_actividad_instrumento_obtener` / `_definir` | `instrumento, instrumento_nombre, definicion JSONB` / `VARCHAR` |
| PUT | `/planeador/actividades/:ID/materiales` | `fn_actividad_material_reemplazar` | `INT` (reemplazo total) |
| GET | `/planeador/actividades/:ID/materiales-reutilizables` | `fn_actividad_materiales_reutilizables_listar` | Archivos de otras actividades + `total_count` |
| PUT | `/planeador/actividades/:ID/adaptaciones` | `fn_actividad_adaptacion_reemplazar` | `INT` (reemplazo total) |
| GET | `/planeador/actividades/:ID/calificaciones` | `fn_actividad_estudiantes_calificaciones_listar` | Por estudiante: asistencia + `calificacion`, `calificable`, `nota_observacion` |
| PUT | `/planeador/actividades/estudiantes/:ID/calificar` | `fn_actividad_nota_calificar` | `NUMERIC` |
| GET | `/planeador/actividades/estudiantes/:ID/nota` | `fn_actividad_nota_obtener` | `instrumento, calificacion, calificable, observacion, detalle JSONB` |
| PUT | `/planeador/actividades/:ID/calificar-bulk/{cotejo,escala,rubrica}` | `fn_actividad_nota_calificar_*_bulk` | Por estudiante: totales/cubiertos + `calificacion` |
| PUT / POST | `.../estudiantes/:ID/observar`, `.../:ID/observar-grupal` | `fn_actividad_observar_estudiante` / `_grupal` | `void` / `INT` |
| GET | `/planeador/actividades/calendario` | `fn_actividad_calendario_docente` | Una fila por día/actividad |
| GET | `/planeador/actividades/stats` y `/planeador/actividades/tablero` | `fn_actividad_resumen_estados_docente` | `pendientes_por_evaluar, en_evaluacion, finalizadas, vencidas, total`. **Dos rutas, la misma función y los mismos parámetros** |
| GET | `/planeador/actividades/huerfanas` | `fn_actividad_huerfanas_listar` | Actividades sin unidad + `total_count` |
| POST | `/planeador/actividades/exportar` · `export-all` · `importar` | `fn_actividad_exportar` / `fn_actividad_listar` / `fn_actividad_importar` | `JSONB` |

---

## 5. Resumen de hallazgos

| # | Hallazgo | Severidad | Dónde |
|---|---|---|---|
| 1 | `GET /unidades/:ID/referente` devuelve el catálogo completo; solo hay marca en nivel 1, y **ninguna** en las evidencias | Diseño (documentado), pero el filtrado recae en el front | V255 |
| 2 | El árbol de enunciados **no filtra por `FK_REFERENTE_CURRICULAR_AREA`**, mientras el referente sí se filtra por área | **Bug** — devuelve enunciados de otras áreas | V255 y V278 |
| 3 | `TACTIVIDAD_EVIDENCIA` / `TACTIVIDAD_CRITERIO_UNIDAD` no tienen lector: imposible pre-marcar ni obtener el PK para quitar | **Bug funcional** | V214.1 / V224 / V353 |
| 4 | `PUT /actividades/:ID` no acepta `EVIDENCIAS`/`CRITERIOS` aunque el `POST` sí | Inconsistencia de contrato | V224 |
| 5 | `/actividades/stats` y `/actividades/tablero` son el mismo endpoint duplicado | Ruido | V250 |

### Arreglos propuestos

1. **(2)** Añadir el filtro por área en el árbol de V255 y V278, con la misma
   semántica de V212 — *sin `FK_REFERENTE_CURRICULAR_AREA` = aplica a todas*:
   ```sql
   AND (en.FK_REFERENTE_CURRICULAR_AREA IS NULL
        OR en.FK_REFERENTE_CURRICULAR_AREA = v_fk_tarea_asignatura)
   ```
   En V255 el área sale de la asignatura de la unidad
   (`COALESCE(TASIGNATURA.FK_TAREA_ASIGNATURA, TAREA.FK_TAREA_ASIGNATURA)`),
   igual que ya hace V278.
2. **(1)** Parámetro `?SOLO_RELACIONADOS=true` en `GET /unidades/:ID/referente`
   que recorte el árbol a las `TUNIDAD_ENUNCIADO` activas, y marca
   `relacionadoConUnidad` también en las evidencias (contra
   `TACTIVIDAD_EVIDENCIA` cuando se pase actividad).
3. **(3)** `fn_actividad_evidencias_listar` / `fn_actividad_criterios_listar`, o
   —mejor— dos columnas `evidencias JSONB` y `criterios JSONB` en
   `fn_actividad_pantalla_edicion`, que es donde el front ya va a buscar todo.
4. **(4)** `p_evidencias` / `p_criterios` en `fn_actividad_actualizar` con
   semántica de reemplazo, igual que `p_materiales` / `p_adaptaciones`.

Los cuatro son ediciones **in-place** de V255/V278/V224/V353, salvo (3) si se
hace como función nueva, que necesitaría un `V<n>` libre — comprobar con
`bash .claude/skills/next-migration-number/scan.sh` (techo local: V413).
