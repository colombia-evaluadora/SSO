# Crear y editar unidad / actividad — enunciados y evidencias

Contrato de los endpoints que crean y editan unidades y actividades del
Planeador, y de los que asignan o quitan enunciados (a la unidad) y evidencias
(a la actividad). Estado tras **V492**.

Todos van por el gateway con prefijo `/api/eval-col` y `Authorization: Bearer <token>`.

## Flujo

```
referente curricular (según grado + asignatura)
 ├─ enunciado (nivel 1)  ──►  unidad      (TUNIDAD_ENUNCIADO)
 │   └─ evidencia (nivel 2) ─►  actividad (TACTIVIDAD_EVIDENCIA)
```

1. Crear la unidad, con `ENUNCIADOS` en el body o sin ellos.
2. Asignar enunciados: en el mismo POST, en el PUT de la unidad o uno a uno con
   `POST /planeador/unidades/:ID/enunciados`.
3. Crear la actividad con `FK_TUNIDAD`, con `EVIDENCIAS` en el body o sin ellas.
4. Asignar evidencias: en el mismo POST, en el PUT de la actividad o una a una
   con `POST /planeador/actividades/:ID/evidencias`.

**Crear sin enunciados o sin evidencias no da error.** La única regla de mínimo
que queda se aplica al **quitar** (ver [Reglas de mínimo](#reglas-de-mínimo)).

## Convenciones

- Las claves del body van **exactamente en MAYÚSCULAS** (`FK_TUNIDAD`, no `fkTunidad`).
  Una clave que la query no usa se ignora sin error.
- Arrays como arrays JSON: `"ENUNCIADOS": [101, 102]`.
- `S`/`N` para los campos `bool_sn`; `true`/`false` para los `BOOLEAN`.
- **PUT = PATCH parcial:** un campo ausente o `null` conserva su valor actual.
- **Listas en PUT** (`ENUNCIADOS`, `EVIDENCIAS`, `CRITERIOS`, `OBJETIVOS`,
  `CONTENIDOS`, `MATERIALES`, `ADAPTACIONES`, `FK_TMATRICULAS`): ausente o `null`
  = no tocar; cualquier array (incluido `[]`) = **reemplazo completo**. Se
  desactivan las que no vienen y se relacionan o reactivan las que sí.

### Respuesta de éxito

HTTP 200, siempre una fila:

```json
{ "rows": [ { "<columna>": 1234 } ] }
```

El nombre de la columna depende del endpoint (ver cada uno).

### Errores

La función SQL lanza un SQLSTATE; query-service lo traduce así:

| SQLSTATE | HTTP | Cuándo |
|---|---|---|
| `22023` | 400 | Regla de negocio o valor inválido (incluidas las de enunciados y evidencias) |
| `P0002` | 404 | La unidad o actividad `:ID` no existe |
| `42501` | 403 | Sin permiso sobre `PLANEADOR` o fuera de su alcance (sede/jornada) |
| `23503` | 409 | Una FK no existe o está inactiva; la relación a quitar ya está inactiva |
| `23505` | 409 | Duplicado (nombre de unidad o título de actividad) |

El cuerpo trae `code` y `message`; `message` es el texto que redacta la función.

---

## Unidad

### `POST /planeador/unidades` — crear

Gate `CREAR`. Respuesta: `{ "rows": [ { "fn_unidad_crear": <PK_TUNIDAD> } ] }`.

| Campo | Tipo | Oblig. | Notas |
|---|---|---|---|
| `NOMBRE` | texto | sí | Único por (asignatura, grado) entre unidades activas |
| `FK_TASIGNATURA` | bigint | sí | |
| `FK_TGRADO` | bigint | sí | |
| `FK_TLV_CALCULO_DEFINITIVA` | bigint | sí | Catálogo `CALCULO_DEFINITIVA` |
| `FK_TFUNCIONARIO` | bigint | no | Si no viene, se toma el funcionario del usuario autenticado |
| `DESCRIPCION` | texto | no | |
| `FK_REFERENTE_CURRICULAR` | bigint | no | Si no viene, **se deriva** del grado + asignatura. Si viene, tiene que aplicar al nivel del grado |
| `OBJETIVOS` | texto[] | no | Orden = posición; se ignoran los vacíos |
| `CONTENIDOS` | texto[] | no | Igual que `OBJETIVOS` |
| `ENUNCIADOS` | bigint[] | no | PKs de `TREFERENTE_ENUNCIADO` **nivel 1** del referente de la unidad |
| `PONDERACION` | numeric | no | 0..100; regla del 100 % por (asignatura, grado); se rechaza si el plan no la admite |

```json
{
  "NOMBRE": "Fracciones",
  "FK_TASIGNATURA": 10, "FK_TGRADO": 6, "FK_TLV_CALCULO_DEFINITIVA": 55,
  "OBJETIVOS": ["Reconocer fracciones"],
  "ENUNCIADOS": [101, 102]
}
```

### `PUT /planeador/unidades/:ID` — editar

Gate `EDITAR`. `:ID` = `PK_TUNIDAD`. Respuesta:
`{ "rows": [ { "fn_unidad_actualizar": <PK_TUNIDAD> } ] }`.

Acepta los mismos campos que el POST (todos opcionales), más:

| Campo | Tipo | Notas |
|---|---|---|
| `ENUNCIADOS` | bigint[] | **Nuevo en V492.** Reemplazo completo. Si se quita un enunciado, se desactivan también las evidencias de las actividades de la unidad que colgaban de él |
| `LIMPIAR_REFERENTE` | boolean | `true` pone el referente en NULL |
| `LIMPIAR_PONDERACION` | boolean | `true` pone la ponderación en NULL |

Si cambia el grado y el referente actual deja de aplicar, el referente se
re-deriva. Si la unidad deja de ser evaluativa y alguna actividad ya tiene
instrumento, responde 400.

```json
{ "ENUNCIADOS": [101, 103] }
```

### `POST /planeador/unidades/:ID/enunciados` — asignar un enunciado

Gate `EDITAR`. Body: `{ "FK_REFERENTE_ENUNCIADO": 101 }`. Respuesta:
`{ "rows": [ { "fn_unidad_enunciado_relacionar": <PK_TUNIDAD_ENUNCIADO> } ] }`.
Es idempotente: si la relación existía inactiva, la reactiva.

Da 400 si el PK es una evidencia (nivel 2) o si es de otro referente distinto
al de la unidad.

### `PATCH /planeador/unidades/enunciados/:ID` — quitar un enunciado

Gate `EDITAR`. `:ID` = `PK_TUNIDAD_ENUNCIADO`. Sin body. Respuesta:
`{ "rows": [ { "fn_unidad_enunciado_quitar": true } ] }`. Desactiva también las
evidencias de las actividades de la unidad que colgaban de ese enunciado.

---

## Actividad

### `POST /planeador/actividades` — crear

Gate `CREAR`. Respuesta: `{ "rows": [ { "fn_actividad_crear": <PK_TACTIVIDAD> } ] }`.

| Campo | Tipo | Oblig. | Notas |
|---|---|---|---|
| `TITULO` | texto | sí | |
| `FK_TASIGNATURA` | bigint | sí | |
| `FK_TLV_TIPO_ACTIVIDAD` | bigint | sí | Catálogo `TIPO_ACTIVIDAD` |
| `FK_TLV_JERARQUIA` | bigint | sí | Catálogo `TIPO_JERARQUIA_ACTIVIDAD` (Actividad / Criterio) |
| `FK_TUNIDAD` | bigint | no | Necesaria para poder asignar evidencias y criterios |
| `EVIDENCIAS` | bigint[] | no | PKs de `TREFERENTE_ENUNCIADO` **nivel 2** cuyo enunciado padre ya esté asignado a la unidad |
| `CRITERIOS` | bigint[] | no | PKs de `TCRITERIO_UNIDAD` de la rúbrica de la unidad |
| `FK_TGRUPO` | bigint | no | |
| `PONDERACION` | numeric | no | % dentro de la unidad; 400 si no es evaluativa o el método de la unidad no la admite |
| `FECHA_INICIO`, `FECHA_CIERRE` | fecha | no | `YYYY-MM-DD` |
| `DURACION_ESTIMADA` | numeric | no | |
| `SEMANA_CRONOGRAMA` | texto | no | |
| `FK_TLV_MODALIDAD` | bigint | no | |
| `MATERIAL_REQUERIDO` | texto | no | |
| `ES_EVALUATIVA` | `S`/`N` | no | Por defecto `S` |
| `FK_TLV_INSTRUMENTO_EVALUACION` | bigint | no | Solo si el referente que aplica es evaluativo |
| `DESCRIPCION_INSTRUMENTO` | texto | no | |
| `FK_TLV_TIPO_EVIDENCIA` | bigint | no | Catálogo `TIPO_EVIDENCIA` |
| `FK_TLV_METODO_VALORACION` | bigint | no | |
| `FK_TLV_TIPO_CALCULO` | bigint | no | |
| `INFLUENCIA` | numeric | no | |
| `NOTA_MAXIMA` | numeric | no | Puntaje si la unidad calcula por sumatoria |
| `REQUIERE_ARCHIVO`, `REQUIERE_TEXTO`, `GENERA_EVIDENCIAS`, `REQUIERE_VALIDACION_COORDINADOR` | `S`/`N` | no | Por defecto `N` |
| `OBSERVACIONES_DOCENTE` | texto | no | |
| `MATERIALES`, `ADAPTACIONES` | JSON array | no | Formato de `PUT .../materiales` y `PUT .../adaptaciones` |
| `FK_TMATRICULAS` | bigint[] | no | Estudiantes asignados |
| `ASIGNAR_TODO_EL_GRUPO` | boolean | no | Si no viene ni esto ni `FK_TMATRICULAS`, no se asigna a nadie |
| `RECUPERACION` | JSON | no | `{destino, fkActividadRecuperar?, tipoAplicacion, tipoCalculo, valorPonderacion?}`; exige `ES_EVALUATIVA=S` |

```json
{
  "TITULO": "Taller de fracciones",
  "FK_TASIGNATURA": 10, "FK_TLV_TIPO_ACTIVIDAD": 70, "FK_TLV_JERARQUIA": 80,
  "FK_TUNIDAD": 500,
  "EVIDENCIAS": [201]
}
```

### `PUT /planeador/actividades/:ID` — editar

Gate `EDITAR`. `:ID` = `PK_TACTIVIDAD`. Respuesta:
`{ "rows": [ { "fn_actividad_actualizar": <PK_TACTIVIDAD> } ] }`.

Acepta los mismos campos que el POST salvo `FK_TLV_JERARQUIA` (todos
opcionales), más:

| Campo | Tipo | Notas |
|---|---|---|
| `EVIDENCIAS` | bigint[] | Reemplazo completo |
| `CRITERIOS` | bigint[] | Reemplazo completo |
| `DESVINCULAR_UNIDAD` | boolean | `true` suelta la unidad; excluyente con `FK_TUNIDAD` / `PONDERACION` |
| `QUITAR_RECUPERACION` | boolean | Excluyente con `RECUPERACION` |

`ES_EVALUATIVA` y las banderas `S`/`N` no tienen valor por defecto en el PUT:
si no vienen, se conservan.

### `POST /planeador/actividades/:ID/evidencias` — asignar una evidencia

Gate `EDITAR`. Body: `{ "FK_REFERENTE_ENUNCIADO": 201 }`. Respuesta:
`{ "rows": [ { "pk_tactividad_evidencia": <PK_TACTIVIDAD_EVIDENCIA> } ] }`.
Es idempotente.

Da 400 si la actividad no tiene unidad, si el PK es un enunciado (nivel 1) o si
el enunciado padre no está asignado a la unidad de la actividad.

### `PATCH /planeador/actividades/evidencias/:ID` — quitar una evidencia

Gate `EDITAR`. `:ID` = `PK_TACTIVIDAD_EVIDENCIA`. Sin body. Respuesta:
`{ "rows": [ { "eliminado": true } ] }`.

---

## Reglas de mínimo

Se validan **solo al quitar** (V483, reducida en V492), al final de la
operación:

| Operación | Falla (400) cuando |
|---|---|
| Quitar un enunciado de una unidad (PATCH suelto o `ENUNCIADOS` en el PUT) | La unidad se queda sin enunciados y su referente sí tiene |
| Quitar una evidencia de una actividad (PATCH suelto o `EVIDENCIAS` en el PUT) | La actividad se queda sin evidencias y los enunciados de su unidad sí tienen |
| Quitar un enunciado del que cuelgan las únicas evidencias de una actividad | Igual que la anterior: la cascada deja a la actividad sin evidencias |

Reemplazar la lista entera por otra no vacía no falla, porque se evalúa el
estado final.

Los mensajes usan los nombres que da el referente a cada nivel:

- `Proyecto pedagógico "Mi huerta": debe tener al menos 1 propósito de su referente curricular`
- `La actividad "Taller" debe tener al menos 1 imprescindible de cualquier propósito de su proyecto pedagógico`

El nombre de la unidad sale de `TREFERENTE_CURRICULAR.INSTRUMENTO`, el del nivel
1 de `NIVEL_1_ETIQUETA` y el del nivel 2 de `NIVEL_2_ETIQUETA`. Si alguno está
vacío se usa "Unidad tematica", "enunciado" o "evidencia".

## De dónde sacar los PKs

- Enunciados y evidencias disponibles para un grado y asignatura:
  `GET /planeador/referente-curricular` (árbol del referente, nivel 1 → nivel 2).
- Evidencias ya asignadas a una actividad, con el `PK_TACTIVIDAD_EVIDENCIA` que
  pide el PATCH de quitar: `GET /planeador/actividades/:ID` (columna `evidencias`).
- Enunciados de una unidad: ningún GET devuelve hoy el `PK_TUNIDAD_ENUNCIADO`
  (solo lo devuelve el POST que lo crea). Para quitar enunciados, usar
  `ENUNCIADOS` en el PUT de la unidad, que trabaja con los PKs del enunciado.
