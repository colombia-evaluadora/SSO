# Planeador — contrato de salida: configuración y detalle de actividad

Qué devuelve cada endpoint del formulario de actividad y cómo interpretar
cada caso: `ES_SUMATIVO`, la ponderación según el método de la unidad, los
instrumentos de evaluación con sus variantes, y cómo llega el instrumento ya
definido en el detalle.

Estado: `dev` (V458) + V459/V460 (rama `feat/planeador-recuperacion-dinamica`).

Regla que aplica a **todo** este documento: los `pk` de catálogo
(`TLISTA_VALOR`) **no son estables entre entornos**. El front decide por
`valor` y reenvía el `pk` que recibió de ese mismo servidor.

---

## 1. Los endpoints

| Momento | Endpoint | Entra | Función |
|---|---|---|---|
| Antes de crear, sin unidad (o con ella) | `GET /planeador/actividades/configuracion` | `GRUPO`, `ASIGNATURA` (obligatorios), `UNIDAD`, `ES_SUMATIVO`, `RECUPERAR`, `ACTIVIDAD_RECUPERAR` (opcionales) | `fn_actividad_configuracion_contexto` |
| Antes de crear, con unidad | `GET /planeador/unidades/:ID/configuracion-actividad` | `:ID` = PK_TUNIDAD, `ES_SUMATIVO` (opcional) | `fn_unidad_configuracion_actividad` |
| Actividad ya creada | `GET /planeador/actividades/:ID/configuracion` | `:ID` = PK_TACTIVIDAD | `fn_actividad_campos_disponibles` |
| Detalle plano | `GET /planeador/actividades/:ID` | `:ID` = PK_TACTIVIDAD | `fn_actividad_buscar_por_pk` |
| Detalle para la pantalla de edición | `GET /planeador/actividades/:ID/pantalla-edicion` | `:ID` = PK_TACTIVIDAD | `fn_actividad_pantalla_edicion` |
| Solo el instrumento | `GET /planeador/actividades/:ID/instrumento` | `:ID` = PK_TACTIVIDAD | `fn_actividad_instrumento_obtener` |

Los query params van **en mayúsculas y con el nombre declarado**
(`?ES_SUMATIVO=N`). Un `?esSumativo=` se ignora en silencio y se responde
como si no se hubiera enviado.

Las tres configuraciones devuelven el **mismo** bloque `campos_disponibles`
(mismas claves, mismos textos de `motivo`). Solo cambia de dónde sale el
referente: de (grado, asignatura) sin unidad, de la unidad cuando la hay, o de
la actividad cuando ya existe.

---

## 2. `GET /planeador/actividades/configuracion` — forma completa

```jsonc
{
  "fkTgrupo": 990201,        "grupo": "A",
  "fkTgrado": 990501,        "grado": "G1 MANANA",
  "nivelEnsenanza": "Preescolar",
  "fkTasignatura": 970001,   "asignatura": "SEGUIMIENTO Y VALORACION",
  "pkTunidad": 970001,                       // null si no se envió UNIDAD
  "origenConfiguracion": "UNIDAD",           // "CONTEXTO" | "UNIDAD"
  "referente": {"pk": 980001, "nombre": "DBA Preescolar"},   // null si no hay referente aplicable
  "esSumativoConsultado": "S",               // lo que se interpretó de ES_SUMATIVO
  "programacion": { … },                     // §2.1
  "campos_disponibles": {                    // §3
    "criterio":     { … },
    "evaluacion":   { … },
    "ponderacion":  { … },
    "recuperacion": { … }
  }
}
```

`GET /planeador/unidades/:ID/configuracion-actividad` devuelve
`{pkTunidad, unidad, nivelEnsenanza, esSumativoConsultado, campos_disponibles}`
(sin `programacion` ni contexto de grupo). `GET /planeador/actividades/:ID/configuracion`
devuelve **solo** `campos_disponibles`.

### 2.1 `programacion` — límites de la sección Programación

Los límites que la pantalla debe usar como `min`/`max` en vez de dejar los
campos libres. Salen del **periodo académico del grado** y del **horario del
docente con ese grupo** (`THORARIO` del grupo + asignatura). Cuando falta el
dato base no se inventa un tope: el valor viene `null` y `motivo` dice por qué.

```jsonc
"programacion": {
  "periodoAcademico": {"pk": 990501, "nombre": "…", "fechaInicio": "2026-01-01", "fechaFin": "2026-12-01", "semanas": 48},  // null sin periodo
  "intensidadHoraria": {
    "bloquesPorSemana": 3, "minutosPorBloque": 51.67, "minutosPorSemana": 155.00,
    "diasHabiles": [{"valor": 2, "nombre": "Lunes"}, {"valor": 4, "nombre": "Miércoles"}],
    "horario": [                                   // días y HORAS en que el docente dicta la asignatura al grupo
      {"valor": 2, "nombre": "Lunes", "bloques": [{"numero": 0, "horaInicio": "07:00:00", "horaFin": "07:50:00", "minutos": 50.00},
                                                   {"numero": 1, "horaInicio": "07:50:00", "horaFin": "08:40:00", "minutos": 50.00}]},
      {"valor": 4, "nombre": "Miércoles", "bloques": [{"numero": 0, "horaInicio": "07:00:00", "horaFin": "07:55:00", "minutos": 55.00}]}
    ],
    "motivo": "…"},
  "fechaInicio":      {"min": "2026-01-05", "max": "2026-11-30", "diasHabiles": [2, 4], "motivo": "…"},
  "fechaCierre":      {"min": "2026-01-05", "max": "2026-11-30", "diasHabiles": [2, 4], "motivo": "…"},
  "semanaCronograma": {"min": 1, "max": 48, "motivo": "…"},
  "duracionEstimada": {"min": 1, "max": 7440.00, "unidad": "MINUTOS", "paso": 51.67, "motivo": "…"}
}
```

**La duración se expresa y se valida en MINUTOS** (V460; antes bloques):
`max = semanas × minutosPorSemana`, donde los minutos de cada bloque salen de
`HORA_INICIO/HORA_FIN` del horario o, si faltan, del bloque del periodo
académico. `paso` es el promedio de minutos por bloque, útil como incremento
del control.

| Caso | Efecto |
|---|---|
| Grado sin periodo académico | `periodoAcademico: null`; `fechaInicio/fechaCierre.min/max: null`; `semanaCronograma.max: null`; `duracionEstimada.max: null` |
| Periodo pero sin horario para la asignatura | Fechas acotadas solo por el periodo, `diasHabiles: []`, `horario: []`, `bloquesPorSemana: 0`, `duracionEstimada.max: null`; el back **no** exige día con clase |
| Horario con algún bloque sin horas (y periodo sin `BLOQUES_POR_DEFECTO`) | `minutosPorSemana: null`, `duracionEstimada.max: null`; los días sí se validan |
| Periodo y horario completo | Fechas acotadas al primer y último día con clase; `diasHabiles` = valores de `DIA_SEMANA` (**Domingo = 1**, Lunes = 2…); `duracionEstimada.max` en minutos |

Qué valida el back al crear/actualizar (`fn_actividad_programacion_assert`, 22023):

- `FECHA_INICIO` **y** `FECHA_CIERRE` dentro del periodo y, si hay horario, **ambas** en un día con clase (`diasHabiles`). Las horas no se validan porque las fechas de `TACTIVIDAD` son `DATE`; el front las habilita con `horario`.
- `DURACION_ESTIMADA`: nunca negativa (también hay `CHECK` en la tabla), mínimo 1 minuto, máximo `duracionEstimada.max` cuando existe.
- `SEMANA_CRONOGRAMA`: texto; cada número que contenga entre 1 y `semanas`; se rechaza cualquier número negativo (`"-3"`).

---

## 3. `campos_disponibles`

Todos los bloques comparten `{visible, requerido, motivo}`. `visible=false`
significa **no pintar la sección**; `motivo` es un texto listo para tooltip.

### 3.1 `criterio`

```jsonc
"criterio": {"visible": true, "requerido": false, "motivo": "Opcional: la actividad puede relacionarse con criterios de la rubrica de la unidad"}
```

| Caso | `visible` | `motivo` |
|---|---|---|
| Sin unidad | `false` | "Los criterios pertenecen a la rubrica de una unidad; la actividad aun no tiene unidad" |
| Nivel Preescolar (con o sin unidad) | `false` | "El grado … pertenece al nivel Preescolar: la relacion con criterios de rubrica no aplica" |
| Con unidad, otro nivel | `true` | Opcional (nunca `requerido`) |

### 3.2 `evaluacion`

```jsonc
"evaluacion": {
  "visible": true, "requerido": true,
  "motivo": "El referente curricular de la unidad es EVALUATIVO: la actividad requiere instrumento de evaluacion",
  "tipoEvaluacion": "CUANTITATIVA_CUALITATIVA",      // CUALITATIVA | CUANTITATIVA | CUANTITATIVA_CUALITATIVA | null
  "instrumentosPermitidos": [ … ]                    // §4
}
```

| Caso | `visible` / `requerido` | `instrumentosPermitidos` |
|---|---|---|
| Referente **EVALUATIVO** | `true` / `true` | los que admite `tipoEvaluacion` (§4) |
| **Nivel Preescolar** (Prejardín, Jardín, Transición) | `false` / `false` — "El nivel Preescolar se rige por un referente formativo: no hay evaluacion con nota ni recuperacion" | `[]` (aunque el referente diga EVALUATIVO) |
| Referente FORMATIVO | `false` / `false` | `[]` |
| Sin referente (ni de unidad ni aplicable a grado+asignatura) | `false` / `false` | `[]` |
| `ES_SUMATIVO=N` | **no cambia nada aquí** (desde V458) | igual que con `S` |

En el endpoint por actividad ya creada, el `motivo` cuando no tiene unidad es
"La actividad no tiene unidad relacionada" y `visible=false`.

### 3.3 `ponderacion` — depende del **método de cálculo de la unidad**

La ponderación **solo existe con unidad**, y es el método de cálculo de esa
unidad (`TUNIDAD.FK_TLV_CALCULO_DEFINITIVA`) el que decide qué campo se
captura. Los casos, en orden de evaluación:

| Caso | Salida |
|---|---|
| `ES_SUMATIVO=N` (o la actividad ya creada es `esEvaluativa=false`) | `{"visible": false, "requerido": false, "modo": null, "valor": 0, "motivo": "La actividad no es sumativa: pesa 0 frente a la unidad; no enviar PONDERACION ni NOTA_MAXIMA"}` |
| Sin unidad | `{"visible": false, "requerido": false, "modo": null, "motivo": "La actividad aun no pertenece a una unidad; la ponderacion la define el metodo de calculo de la unidad"}` |
| Unidad **PONDERAR** | `{"visible": true, "requerido": true, "modo": "PORCENTAJE", "campo": "PONDERACION", "autocalculado": false, "motivo": "la unidad pondera sus actividades"}` |
| Unidad **SUMATORIA** | `{"visible": true, "requerido": true, "modo": "PUNTAJE", "campo": "NOTA_MAXIMA", "autocalculado": true, "motivo": "la unidad suma puntajes; el % lo calcula el sistema"}` |
| Unidad **PROMEDIAR** | `{"visible": false, "requerido": false, "modo": null, "motivo": "la unidad promedia, la ponderacion no aplica"}` |
| Unidad sin método elegido | `{"visible": false, "requerido": false, "modo": null, "motivo": "la unidad aun no tiene metodo de calculo elegido"}` |

Qué enviar en el `POST /planeador/actividades` según `modo`:

- `PORCENTAJE` → `PONDERACION` (0–100). La suma por (unidad, grupo) no puede
  pasar de 100 (trigger de V223 → 409/22023).
- `PUNTAJE` → `NOTA_MAXIMA` (puntaje máximo). **No** enviar `PONDERACION`: el
  sistema la recalcula para todas las actividades de esa (unidad, grupo).
- `visible=false` → no enviar ni `PONDERACION` ni `NOTA_MAXIMA`. Con
  `ES_SUMATIVO=N` el back **rechaza** `PONDERACION` (22023): la actividad pesa
  cero y `valor: 0` lo dice explícitamente.

### 3.4 `recuperacion`

```jsonc
"recuperacion": {
  "visible": true, "requerido": false,
  "motivo": "Opcional: la actividad puede registrarse como recuperacion de otra actividad o de la nota final",
  "recuperarConsultado": "N",                 // lo que se interpretó de ?RECUPERAR=
  "catalogos": {
    "destino":        [{"pk": 260, "valor": "ACTIVIDAD",  "nombre": "Recuperar una actividad"}, {"pk": 263, "valor": "NOTA_FINAL", "nombre": "Recuperar la nota final"}],
    "tipoAplicacion": [{"pk": 256, "valor": "COMPUTAR",   "nombre": "Computar con la nota anterior"}, {"pk": 271, "valor": "REEMPLAZAR", "nombre": "Reemplazar la nota anterior"}],
    "tipoCalculo":    [{"pk": 268, "valor": "PONDERADO",  "nombre": "Ponderado"}, {"pk": 265, "valor": "PROMEDIADO", "nombre": "Promediado"}]
  },
  "reglas": {
    "actividadRecuperarRequeridaSi": "destino = ACTIVIDAD",
    "actividadRecuperableSi":        "ES_EVALUATIVA = S y ES_RECUPERACION = N y sin otra recuperacion activa",
    "tipoCalculoRequeridoSi":        "tipoAplicacion = COMPUTAR",
    "tipoCalculoOcultoSi":           "tipoAplicacion = REEMPLAZAR",
    "valorPonderacionRequeridoSi":   "tipoAplicacion = COMPUTAR y tipoCalculo = PONDERADO",
    "valorPonderacionRango":         {"min": 0, "max": 100},
    "estudiantesPorDefecto":         "los asignados a la actividad origen; se envian en FK_TMATRICULAS los que quedan marcados"
  },
  "actividadesRecuperables": null,            // §3.4.2
  "origen": null                              // §3.4.3
}
```

#### 3.4.1 Cuándo se muestra

| Caso | `visible` | `motivo` |
|---|---|---|
| Referente EVALUATIVO, `ES_SUMATIVO` ≠ `N`, nivel ≠ Preescolar | `true` | Opcional |
| Nivel Preescolar | `false` | "El nivel Preescolar se rige por un referente formativo: no hay nota que recuperar" |
| `ES_SUMATIVO=N` | `false` | "La actividad se creara como NO sumativa; una actividad de recuperacion debe ser sumativa" |
| Referente no EVALUATIVO / sin referente | `false` | "El referente curricular no es EVALUATIVO: no hay nota que recuperar" |

Los catálogos y las reglas vienen siempre, aunque `visible=false`.

#### 3.4.2 `?RECUPERAR=S` — "¿Qué desea recuperar?"

Cuando el docente marca la casilla, el front vuelve a pedir la configuración con
`RECUPERAR=S` y recibe en `actividadesRecuperables` **solo** las actividades
que se pueden recuperar en ese contexto: sumativas (`ES_EVALUATIVA=S`), que no
son a su vez recuperación, activas, sin otra recuperación activa apuntándoles,
de la misma asignatura y del mismo grupo (o sin grupo pero de una unidad del
mismo grado). Orden: fecha de inicio descendente.

```jsonc
"actividadesRecuperables": [
  {"pk": 970001, "titulo": "Quiz de centenas", "fkTgrupo": 990201, "fkTunidad": 970001, "unidad": "Centenas",
   "fechaInicio": "2026-08-26", "fechaCierre": "2026-08-31", "estudiantesAsignados": 25}
]
```

Sin `RECUPERAR=S` (o con la sección no visible) viene `null`. `[]` significa
que no hay nada recuperable.

#### 3.4.3 `?ACTIVIDAD_RECUPERAR=<pk>` — herencia y estudiantes

Al elegir la actividad del selector, el front pide de nuevo la configuración
con `ACTIVIDAD_RECUPERAR=<pk>` y recibe `origen`:

```jsonc
"origen": {
  "pkActividad": 970001,
  "tituloBase": "Quiz de centenas",
  "tituloSugerido": "Recuperacion - Quiz de centenas",
  "fkTgrado": 990501, "grado": "G1 MANANA",
  "fkTgrupo": 990201, "grupo": "A",
  "fkTasignatura": 970001, "asignatura": "SEGUIMIENTO Y VALORACION",
  "fkTunidad": 970001, "unidad": "Centenas",
  "camposHeredados": ["FK_TGRUPO", "FK_TASIGNATURA", "FK_TUNIDAD"],   // el formulario los completa e inhabilita
  "estudiantes": [
    {"pkTmatricula": 990301, "pkTactividadEstudiante": 12, "fkTestudiante": 990401,
     "estudiante": "Ana Pérez", "notaPrevia": 62.50, "seleccionado": true}
  ]
}
```

- `estudiantes` son **todos** los asignados a la actividad origen, con
  `seleccionado: true`. El docente desmarca los que no la necesitan y el POST
  lleva en `FK_TMATRICULAS` los `pkTmatricula` que quedaron marcados.
- `notaPrevia` es `COALESCE(DEFINITIVA, CALIFICACION)` de esa actividad; `null`
  si aún no tiene nota.
- Errores: 404 (P0002) si la actividad no existe o está inactiva; 422 (22023)
  si no es sumativa, si ya es una recuperación o si es de otra asignatura.

`GET /planeador/actividades/:ID/configuracion` de una actividad que **ya es**
recuperación devuelve `origen` con su actividad recuperada y
`actividadesRecuperables` (sin ella misma), para repintar el selector al editar.

#### 3.4.4 "¿Cómo se aplicará la nota?" — qué enviar en `RECUPERACION`

El body `RECUPERACION` del POST/PATCH (serializado como string):

| `tipoAplicacion` | `tipoCalculo` | `valorPonderacion` | Resultado al calificar |
|---|---|---|---|
| `REEMPLAZAR` | **no enviar** (se ignora; el back guarda PROMEDIADO por la columna NOT NULL) | **no enviar** (22023 si viene) | la nota de la recuperación sustituye a la anterior |
| `COMPUTAR` + `PROMEDIADO` | obligatorio | no enviar | promedio simple de las dos |
| `COMPUTAR` + `PONDERADO` | obligatorio | obligatorio 0–100 (peso de **la recuperación**; el resto va a la nota anterior) | `rec × p/100 + anterior × (100−p)/100` |

`destino = ACTIVIDAD` exige `fkActividadRecuperar` (el `pk` elegido en §3.4.2);
`destino = NOTA_FINAL` lo prohíbe. Sin nota previa en `COMPUTAR` manda la
política institucional (`FK_TLV_DESEMPENO_SIN_CALIF`).

#### 3.4.5 Nota previa y tendencia en planillas e informes

El back **no** manda una columna "tendencia" por celda (decisión documentada en
V344/V450: sería un dato derivado y sobre porcentajes daría flecha cuando dos
valores redondean igual). Lo que sí manda, por celda de
`GET /planeador/planilla/calificaciones`:

```jsonc
{"calificacion": 62.50, "recuperacion": 80.00, "definitiva": 80.00, "nota": 80.00, …}
```

- `calificacion` = nota previa (gris/opaca); `definitiva` = la nota tras la
  recuperación (resaltada); `recuperacion` = lo que sacó en la recuperación.
- Flecha: verde arriba si `definitiva > calificacion`, roja abajo si
  `definitiva < calificacion`, ninguna si `definitiva` es `null` (no hubo
  recuperación aplicada).
- En informes, `fn_informe_estudiante_asignaturas` y `fn_informe_planilla_listar`
  traen `NOTA_GUARDADA` y `NOTA_PROYECTADA` con el mismo criterio.

### 3.5 Resumen de `ES_SUMATIVO`

| `ES_SUMATIVO` | `criterio` | `evaluacion` | `ponderacion` | `recuperacion` |
|---|---|---|---|---|
| no enviado / `S` | según nivel y unidad | según referente | según método de la unidad | según referente |
| `N` | según nivel y unidad | **igual que con S** | `visible=false`, `valor: 0` | `visible=false` |
| cualquiera, nivel **Preescolar** | `visible=false` | `visible=false` | según método de la unidad | `visible=false` |

En el `POST /planeador/actividades` el flag sigue llamándose `ES_EVALUATIVA`
(`S`/`N`, default `S`): es la columna `TACTIVIDAD.ES_EVALUATIVA`. Solo cambió
el nombre del query param de la configuración.

---

## 4. `instrumentosPermitidos` — instrumentos, variantes y el bloque de OTRO

Cada entrada:

```jsonc
{"pk": 262, "valor": "RUBRICA", "etiqueta": "Rúbrica", "nombre": "Rúbrica", "variantes": [], "campos": null}
```

`etiqueta` y `nombre` llevan el mismo texto (compatibilidad). El orden es
alfabético por nombre.

### 4.1 Qué instrumento aparece según `tipoEvaluacion`

| `tipoEvaluacion` del referente | `RUBRICA` | `LISTA_COTEJO` | `ESCALA_VALORACION` | `OTRO` |
|---|---|---|---|---|
| `CUALITATIVA` | sí | sí | sí, `variantes: [CUALITATIVA]` | sí |
| `CUANTITATIVA` | no | no | sí, `variantes: [NUMERICA]` | sí |
| `CUANTITATIVA_CUALITATIVA` | sí | sí | sí, `variantes: [CUALITATIVA, NUMERICA]` | sí |
| `null` (referente sin tipo) | sí | sí | sí, las dos variantes | sí |

### 4.2 `variantes` — solo en `ESCALA_VALORACION`

```jsonc
"variantes": [{"pk": 278, "valor": "CUALITATIVA", "nombre": "Cualitativa"}, {"pk": 279, "valor": "NUMERICA", "nombre": "Numérica"}]
```

Son los `TIPO_ESCALA` que el referente admite. Al definir la escala
(`PUT /planeador/actividades/:ID/instrumento`), `tipoEscala` debe ser uno de
estos `pk`; otra variante da 22023. En el resto de instrumentos `variantes: []`.

### 4.3 `campos` — solo en `OTRO` (personalizado)

`OTRO` no tiene estructura propia: se califica **con uno de los otros tres
instrumentos** (`metodoValoracion`) y además declara qué evidencia espera.
`campos` describe todo lo que pide:

```jsonc
"campos": {
  "tipoEvidencia": {
    "requerido": true,
    "catalogo": [
      {"pk": 343, "valor": "ARCHIVO", "nombre": "Archivo"},
      {"pk": 342, "valor": "ENLACE", "nombre": "Enlace"},
      {"pk": 340, "valor": "OBSERVACION_DIRECTA", "nombre": "Observación directa"},
      {"pk": 341, "valor": "REGISTRO_CAMPO", "nombre": "Registro en campo"}
    ],
    "motivo": "Tipo de evidencia esperada del instrumento personalizado"
  },
  "metodoValoracion": {
    "requerido": true,
    "catalogo": [                                   // los MISMOS instrumentos de §4.1, sin OTRO
      {"pk": 247, "valor": "ESCALA_VALORACION", "nombre": "Escala de valoración", "variantes": [ … ]},
      {"pk": 270, "valor": "LISTA_COTEJO", "nombre": "Lista de cotejo", "variantes": []},
      {"pk": 262, "valor": "RUBRICA", "nombre": "Rúbrica", "variantes": []}
    ],
    "motivo": "Instrumento con el que se califica el personalizado; se ofrecen los que admite el tipo de evaluacion del referente"
  },
  "definicion": {
    "requerido": true,
    "formaPorMetodo": {
      "RUBRICA":           "[{nombre, descripcion?, niveles:[{etiqueta?, descripcion, ponderacion}]}]",
      "LISTA_COTEJO":      "[{descripcion, ponderacion?}]",
      "ESCALA_VALORACION": "{tipoEscala, criteriosGenerales?, interpretacionRangos?, valorMin?, valorMax?, niveles?}"
    },
    "motivo": "Misma forma que el metodoValoracion elegido; se envia en PUT /planeador/actividades/:ID/instrumento como {tipoEvidencia, metodoValoracion, definicion}"
  },
  "descripcionInstrumento": {"requerido": false, "campo": "DESCRIPCION_INSTRUMENTO", "maxLength": 4000, "motivo": "…"},
  "requiereArchivo":        {"requerido": false, "campo": "REQUIERE_ARCHIVO", "valores": ["S", "N"], "default": "N", "motivo": "…"},
  "requiereTexto":          {"requerido": false, "campo": "REQUIERE_TEXTO",   "valores": ["S", "N"], "default": "N", "motivo": "…"}
}
```

- `metodoValoracion.catalogo` sigue la **misma tabla de §4.1**: con referente
  `CUANTITATIVA` solo aparece `ESCALA_VALORACION` con `variantes: [NUMERICA]`.
  Elegir un método fuera de esta lista da 22023 al definir.
- `descripcionInstrumento`, `requiereArchivo` y `requiereTexto` van en el
  `POST`/`PATCH` de la actividad (son columnas de `TACTIVIDAD`), no en el `PUT`
  del instrumento.
- Dónde se guarda cada cosa: `tipoEvidencia` y `metodoValoracion` en
  `TACTIVIDAD_OTRO`; `definicion` en las tablas del método elegido
  (rúbrica / cotejo / escala), igual que si el instrumento fuera ese.

### 4.4 Flujo de escritura del instrumento

1. `POST /planeador/actividades` con `FK_TLV_INSTRUMENTO_EVALUACION` = un `pk`
   de `instrumentosPermitidos`. **`RUBRICA` exige `FK_TUNIDAD`**.
2. `PUT /planeador/actividades/:ID/instrumento` con `DEFINICION` **serializado
   como string**:

| Instrumento | `DEFINICION` |
|---|---|
| `RUBRICA` | `[{nombre, descripcion?, niveles:[{etiqueta?, descripcion, ponderacion}]}]` — ponderación de nivel obligatoria (0–100), sin repetir dentro del criterio |
| `LISTA_COTEJO` | `[{descripcion, ponderacion?}]` — ponderación opcional (`null` = peso 1) |
| `ESCALA_VALORACION` variante `NUMERICA` | `{tipoEscala, valorMin, valorMax, criteriosGenerales?, interpretacionRangos?}` con `valorMin < valorMax` |
| `ESCALA_VALORACION` variante `CUALITATIVA` | `{tipoEscala, niveles:[{etiqueta?, descripcion, ponderacion}], criteriosGenerales?}` — al menos un nivel |
| `OTRO` | `{tipoEvidencia, metodoValoracion, definicion}` — `definicion` con la forma del método |

---

## 5. Detalle de la actividad — cómo llega el instrumento

### 5.1 `GET /planeador/actividades/:ID` (plano, snake_case)

Trae solo el **tipo** elegido, no la definición:

```jsonc
{
  "fk_tlv_instrumento_evaluacion": 262,      // null si no eligió instrumento
  "instrumento_evaluacion": "Rúbrica",       // NOMBRE del catálogo; null si no eligió
  "descripcion_instrumento": null,
  "es_evaluativa": "S",                      // el flag "sumativa" persistido
  "ponderacion": 20.00, "nota_maxima": null, "influencia": null,
  …
}
```

Para saber el `valor` (`RUBRICA`, `OTRO`…) cruzar `fk_tlv_instrumento_evaluacion`
contra `instrumentosPermitidos` de la configuración **del mismo servidor**, o
usar `pantalla-edicion` / `:ID/instrumento`, que ya lo traen.

### 5.2 `GET /planeador/actividades/:ID/pantalla-edicion` (DTO camelCase)

```jsonc
{
  "actividad": {
    "id": 970001, "titulo": "…", "descripcion": "…", "estado": "VENCIDA",
    "unidad": {"id": 970001, "nombre": "Centenas"},          // null sin unidad
    "grupo": {…} | null, "grado": {…}, "asignatura": {…},
    "tipoActividad": {"id", "nombre"}, "jerarquia": {…}, "modalidad": {…} | null,
    "fechas": {"inicio", "cierre", "calificado", "publicacion"},
    "ponderacion": 20.00, "notaMaxima": null, "influencia": null,
    "descripcionInstrumento": null,
    "tipoEvidencia": null, "metodoValoracion": null, "tipoCalculo": null,   // catálogos genéricos de TACTIVIDAD, NO los de OTRO
    "banderas": {"esEvaluativa": true, "esRecuperacion": false, "requiereArchivo": false, "requiereTexto": false, "generaEvidencias": false, "requiereValidacionCoordinador": false},
    "estudiantes": {"asignados": 0, "evaluados": 0}, …
  },
  "materiales": [ … ], "adaptaciones": [ … ], "evidencias": [ … ], "criterios": [ … ], "estudiantes": [ … ],
  "recuperacion": null | {…},
  "instrumento": null | {"tipo": {"valor", "nombre"}, "definicion": …},   // §5.3
  "camposDisponibles": { … },        // el mismo bloque de §3, ya calculado para esta actividad
  "unidadConfiguracion": {"tieneUnidad", "pkTunidad", "nombre", "descripcion", "objetivos", "contenidos", "enunciados", "rubrica", "referenteCurricular"}
}
```

`banderas.esEvaluativa` es el flag "sumativa" de la actividad; con `false`,
`camposDisponibles.ponderacion` y `.recuperacion` vienen apagados (§3.3, §3.4).

### 5.3 `instrumento` — todos los casos

| Estado de la actividad | `instrumento` |
|---|---|
| No eligió instrumento (`FK_TLV_INSTRUMENTO_EVALUACION` null) | `null` |
| Eligió `RUBRICA` / `LISTA_COTEJO`, aún sin definir | `{"tipo": {"valor": "RUBRICA", "nombre": "Rúbrica"}, "definicion": []}` |
| Eligió `ESCALA_VALORACION` / `OTRO`, aún sin definir | `{"tipo": {…}, "definicion": null}` |
| Definido | `{"tipo": {…}, "definicion": <según el tipo, abajo>}` |

`GET /planeador/actividades/:ID/instrumento` devuelve lo mismo pero plano:
`{instrumento, instrumento_nombre, definicion}`.

**`definicion` por tipo** (los `pk` son los que piden los payloads de calificar):

```jsonc
// RUBRICA — niveles ordenados por ponderación DESC
[{"pk": 16, "orden": 1, "nombre": "C1", "descripcion": null,
  "niveles": [{"pk": 28, "etiqueta": "Alto", "descripcion": "d", "ponderacion": 100.00},
              {"pk": 29, "etiqueta": "Bajo", "descripcion": "d", "ponderacion": 50.00}]}]

// LISTA_COTEJO
[{"pk": 26, "orden": 1, "descripcion": "item 1", "ponderacion": 60.00},
 {"pk": 27, "orden": 2, "descripcion": "item 2", "ponderacion": null}]

// ESCALA_VALORACION — variante NUMERICA
{"pk": 14, "tipoEscala": 279, "tipoEscalaValor": "NUMERICA", "tipoEscalaNombre": "Numérica",
 "valorMin": 1.00, "valorMax": 5.00, "criteriosGenerales": null, "interpretacionRangos": null, "niveles": []}

// ESCALA_VALORACION — variante CUALITATIVA
{"pk": 15, "tipoEscala": 278, "tipoEscalaValor": "CUALITATIVA", "tipoEscalaNombre": "Cualitativa",
 "valorMin": null, "valorMax": null, "criteriosGenerales": "…", "interpretacionRangos": null,
 "niveles": [{"pk": 31, "orden": 1, "etiqueta": "Alto", "descripcion": "…", "ponderacion": 100.00}, …]}

// OTRO — envuelve la definición del método elegido
{"pk": 9,
 "tipoEvidencia": 342, "tipoEvidenciaNombre": "Enlace",
 "metodoValoracion": 247, "metodoValoracionValor": "ESCALA_VALORACION", "metodoValoracionNombre": "Escala de valoración",
 "definicion": { …la misma forma de RUBRICA / LISTA_COTEJO / ESCALA_VALORACION según metodoValoracionValor… }}
```

Para OTRO, el front pinta y califica según `definicion.metodoValoracionValor`,
exactamente como lo haría con ese instrumento.

### 5.4 Cómo calificar según lo que llegó

`PUT /planeador/actividades/estudiantes/:ID/calificar` (`:ID` = `pkTactividadEstudiante`), `CALIFICACION` serializado:

| `instrumento.tipo.valor` (o `metodoValoracionValor` en OTRO) | Payload |
|---|---|
| `RUBRICA` | `{"niveles": [{"pkCriterio", "pkNivel"}]}` — set completo |
| `LISTA_COTEJO` | `{"itemsMarcados": [pk, …]}` |
| `ESCALA_VALORACION` `NUMERICA` | `{"valorNumerico": n}` |
| `ESCALA_VALORACION` `CUALITATIVA` | `{"pkNivel": pk}` |
| `OTRO` sin método configurado | `{"porcentaje": n}` |

---

## 6. Dónde vive cada pieza

| Pieza | Migración |
|---|---|
| `fn_actividad_configuracion_contexto` (cuerpo) | V460 (antes V459) |
| `fn_unidad_configuracion_actividad`, `fn_actividad_campos_disponibles` (cuerpos) | V459 (antes V458) |
| `fn_actividad_instrumentos_campos_disponibles` (`variantes` + `campos`), `fn_actividad_otro_campos_disponibles` | V458 |
| `fn_actividad_ponderacion_campos_disponibles`, `fn_actividad_recuperacion_campos_disponibles`, `fn_actividad_criterio_campos_disponibles` | V458 / V459 / V440 |
| `fn_instrumento_permitido_por_tipo_evaluacion`, `fn_escala_variantes_permitidas` | V453 |
| `fn_actividad_programacion_limites`, `fn_actividad_programacion_assert` (minutos, días de inicio y cierre, sin negativos) | V460 (antes V422) |
| `fn_actividad_pantalla_edicion`, `fn_actividad_buscar_por_pk` | V452 |
| `fn_actividad_instrumento_obtener` / `_definir`, `TACTIVIDAD_OTRO` | V226 / V240 |
| `fn_actividad_recuperacion_configurar` (writer: REEMPLAZAR sin tipoCálculo, origen sumativa) | V459 (antes V224) |
| `fn_recuperacion_combinar`, `fn_actividad_recuperacion_aplicar` | V408 |
