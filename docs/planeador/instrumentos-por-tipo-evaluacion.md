# Planeador — qué instrumento de evaluación se ofrece, según el referente

Cómo el **tipo de evaluación** del referente curricular decide qué instrumentos
puede usar una actividad, con especial atención a la **escala de valoración**,
que tiene dos variantes y se apaga por variante, no entera. Entradas y salidas
de cada endpoint del flujo.

Estado: `dev` + V453 (rama `fix/planeador-escala-por-variante`).

---

## 1. La regla

El referente curricular tiene un `TIPO_EVALUACION` (`TLISTA_VALOR`, categoría
`TIPO_EVALUACION`): `CUALITATIVA`, `CUANTITATIVA` o `CUANTITATIVA_CUALITATIVA`.
Los instrumentos son `INSTRUMENTO_EVALUACION`: `RUBRICA`, `LISTA_COTEJO`,
`ESCALA_VALORACION`, `OTRO`. Y la escala tiene su propio catálogo de variantes,
`TIPO_ESCALA`: `CUALITATIVA` y `NUMERICA`.

| Tipo de evaluación del referente | Rúbrica | Lista de cotejo | Escala de valoración | Otro |
|---|---|---|---|---|
| `CUALITATIVA` | sí | sí | **solo variante `CUALITATIVA`** | sí |
| `CUANTITATIVA` | no | no | **solo variante `NUMERICA`** | sí |
| `CUANTITATIVA_CUALITATIVA` | sí | sí | las dos variantes | sí |
| sin referente / sin tipo | sí | sí | las dos variantes | sí |

**Lo que corrige V453.** La configuración excluía `ESCALA_VALORACION` entera
para un referente `CUALITATIVA`, mientras que el endpoint de definir la escala
(V226) aceptaba la variante cualitativa y solo rechazaba la numérica. El
formulario no ofrecía algo que el back sí guardaba. Ahora la escala se ofrece
siempre que el instrumento aplique y cada instrumento trae `variantes` con las
de `TIPO_ESCALA` que ese referente admite. La regla vive en dos funciones que
dicen lo mismo:

- `fn_instrumento_permitido_por_tipo_evaluacion(instrumento, tipo)` — si el
  instrumento aplica.
- `fn_escala_variantes_permitidas(tipo)` — qué variantes de escala aplican. Es
  la misma condición que `fn_actividad_escala_definir` hace cumplir al guardar.

`OTRO` siempre aplica porque es un instrumento personalizado: su método de
valoración (`TACTIVIDAD_OTRO.FK_TLV_METODO_VALORACION`, V240) puede reutilizar
cualquiera de los otros tres, y ahí sí se le aplica la misma regla.

---

## 2. De dónde sale el tipo de evaluación

```
actividad ──► unidad ──► referente ──► TIPO_EVALUACION
   │ (sin unidad)
   └──► grupo ──► grado ──► nivel  ┐
        asignatura ──► área        ┴──► fn_unidad_referente_aplicable ──► referente ──► TIPO_EVALUACION
```

Con unidad, manda el referente de la unidad. Sin unidad, se deriva de (grado,
asignatura) con la regla de preferencia de V451. Sin referente no hay tipo y
se ofrecen todos los instrumentos — pero la actividad será formativa y no se
califica con nota (ver §5).

---

## 3. Consultar qué se puede usar

Las tres configuraciones devuelven el **mismo** bloque `evaluacion`; solo cambia
desde dónde se resuelve el referente.

| Momento | Endpoint | Entra |
|---|---|---|
| Sin unidad, antes de crear | `GET /planeador/actividades/configuracion` | `GRUPO`, `ASIGNATURA`, `UNIDAD` (opc.), `ES_EVALUATIVA` |
| Con unidad, antes de crear | `GET /planeador/unidades/:ID/configuracion-actividad` | `ID` = PK_TUNIDAD, `ES_EVALUATIVA` |
| Actividad ya creada | `GET /planeador/actividades/:ID/configuracion` | `ID` = PK_TACTIVIDAD |

Salida (bloque `campos_disponibles.evaluacion`):

```jsonc
"evaluacion": {
  "visible": true, "requerido": true,
  "motivo": "El referente curricular de la unidad es EVALUATIVO: la actividad requiere instrumento de evaluacion",
  "tipoEvaluacion": "CUALITATIVA",
  "instrumentosPermitidos": [
    {"pk": 247, "valor": "ESCALA_VALORACION", "etiqueta": "Escala de valoración", "nombre": "Escala de valoración",
     "variantes": [{"pk": 278, "valor": "CUALITATIVA", "nombre": "Cualitativa"}]},
    {"pk": 270, "valor": "LISTA_COTEJO", "etiqueta": "Lista de cotejo", "nombre": "Lista de cotejo", "variantes": []},
    {"pk": 269, "valor": "OTRO", "etiqueta": "Otro (personalizado)", "nombre": "Otro (personalizado)", "variantes": []},
    {"pk": 262, "valor": "RUBRICA", "etiqueta": "Rúbrica", "nombre": "Rúbrica", "variantes": []}
  ]
}
```

- `variantes` solo trae contenido en `ESCALA_VALORACION`; en el resto es `[]`.
- `visible=false` cuando el referente es FORMATIVO, no hay referente, o
  `ES_EVALUATIVA=N`. Entonces `instrumentosPermitidos` es `[]`.
- **Los `pk` no son estables entre entornos.** El front decide por `valor` y
  manda el `pk` que recibió de este mismo servidor. Es la causa más común de
  409 al crear ("instrumento no pertenece a la categoría").

Existe además `fn_actividad_instrumentos_permitidos` (V214.2), que aplica la
misma regla pero devuelve solo `{pk, valor, etiqueta}`, sin `variantes`. **No
tiene ruta en `public.query`**: ningún endpoint la expone hoy, así que el
front debe leer siempre el bloque de configuración.

---

## 4. Crear la actividad y definir el instrumento

### `POST /planeador/actividades`

| Entrada | Regla |
|---|---|
| `FK_TLV_INSTRUMENTO_EVALUACION` | Debe estar en `instrumentosPermitidos`; si no, 409 |
| `ES_EVALUATIVA` | Con `N` no se acepta instrumento ni recuperación |
| `FK_TUNIDAD` | **`RUBRICA` exige unidad** (los criterios de rúbrica son de la unidad) |

### `PUT /planeador/actividades/:ID/instrumento`

`DEFINICION` es JSONB y **debe viajar serializado como string** (como objeto
anidado el binder lo ignora). Su forma depende del instrumento:

| Instrumento | `DEFINICION` | Regla que se valida |
|---|---|---|
| `RUBRICA` | `[{nombre, descripcion, niveles:[{etiqueta, descripcion, ponderacion}]}]` | — |
| `LISTA_COTEJO` | `[{descripcion, ponderacion}]` | — |
| `ESCALA_VALORACION` | `{tipoEscala, criteriosGenerales, …}` + según variante | **`tipoEscala` ∈ `variantes`**. Con referente CUALITATIVA la NUMERICA da 22023 *"No se puede definir una escala NUMERICA…"*; con CUANTITATIVA la CUALITATIVA da el simétrico |
| ↳ variante `NUMERICA` | `…, valorMin, valorMax, interpretacionRangos` | `valorMin < valorMax` |
| ↳ variante `CUALITATIVA` | `…, niveles:[{etiqueta, descripcion, ponderacion}]` | al menos un nivel |
| `OTRO` | `{tipoEvidencia, metodoValoracion, definicion}` | `definicion` reutiliza la forma del método elegido, con la misma regla |

Salida: `instrumento_aplicado` (el VALOR). Lectura: `GET /planeador/actividades/:ID/instrumento`
→ `{instrumento, instrumento_nombre, definicion}` con los `pk` de criterios,
niveles o ítems ya asignados, que son los que piden los payloads de calificar.

---

## 5. Calificar según el instrumento

`PUT /planeador/actividades/estudiantes/:ID/calificar` (`:ID` = **`PK_TACTIVIDAD_ESTUDIANTE`**),
`CALIFICACION` serializado:

| Instrumento | Payload | Nota resultante |
|---|---|---|
| `RUBRICA` | `{"niveles":[{"pkCriterio","pkNivel"}]}` (set completo) | promedio de las ponderaciones de los niveles elegidos |
| `LISTA_COTEJO` | `{"itemsMarcados":[pk,…]}` | suma de ponderaciones de los ítems marcados |
| `ESCALA_VALORACION` (NUMERICA) | `{"valorNumerico": n}` | `n` reescalado a 0-100 entre `valorMin` y `valorMax` |
| `ESCALA_VALORACION` (CUALITATIVA) | `{"pkNivel": pk}` | ponderación del nivel **normalizada**: `nivel / máx(ponderaciones) × 100` |
| `OTRO` | `{"porcentaje": n}` o el payload del método configurado | directo / el del método |

Los bulk `PUT /planeador/actividades/:ID/calificar-bulk/{rubrica,cotejo,escala}`
aplican una columna a varios estudiantes; `escala` acepta `PK_NIVEL` **o**
`VALOR_NUMERICO` según la variante.

Restricciones que aplican siempre, sea cual sea el instrumento:

- Sin asistencia registrada para (matrícula, asignatura, **fecha exacta**) →
  22023. `BODY.FECHA` por defecto es hoy; en la planilla usar `fechaAsistencia`.
- Referente **FORMATIVO** → `calificar` rechaza; se usa `observar`. Y al revés:
  con referente EVALUATIVO, `observar` rechaza.
- Actividad **sin unidad** en contexto sin referente evaluativo → ni calificar
  ni observar aplican (callejón sin salida documentado en el mapa de
  configuración).

---

## 6. Verificación

Corrida local (V453 aplicada), instrumentos y variantes por tipo de evaluación:

```
CUALITATIVA              → ESCALA_VALORACION(CUALITATIVA)  LISTA_COTEJO  OTRO  RUBRICA
CUANTITATIVA             → ESCALA_VALORACION(NUMERICA)     OTRO
CUANTITATIVA_CUALITATIVA → ESCALA_VALORACION(CUALITATIVA,NUMERICA)  LISTA_COTEJO  OTRO  RUBRICA
sin tipo                 → ESCALA_VALORACION(CUALITATIVA,NUMERICA)  LISTA_COTEJO  OTRO  RUBRICA
```

Y el ciclo completo con una unidad de referente CUALITATIVA: crear la actividad
con `ESCALA_VALORACION` **acepta** (antes, 409 por instrumento no permitido);
definirla `NUMERICA` **rechaza** con el mensaje de V226; definirla `CUALITATIVA`
**acepta**; la configuración de esa unidad ofrece la escala con
`variantes: [CUALITATIVA]`.

## 7. Dónde vive cada pieza

| Función | Migración dueña |
|---|---|
| `fn_instrumento_permitido_por_tipo_evaluacion` | **V453** (antes V214.2) |
| `fn_escala_variantes_permitidas` | **V453** (nueva) |
| `fn_actividad_instrumentos_campos_disponibles` | **V453** (antes V440) |
| `fn_actividad_escala_definir` | V226 — no cambia; ya tenía la regla por variante |
| `fn_actividad_instrumentos_permitidos` (sin ruta) | V214.2 — hereda el cambio por llamar a la primera |
