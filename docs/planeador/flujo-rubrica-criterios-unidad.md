# Planeador — flujo de la rúbrica de una unidad (referente → escala → criterios)

Documenta, endpoint por endpoint, qué entra y qué sale en el flujo de la pestaña
**Rúbricas → Criterios de la unidad**, y los dos defectos que hacían que la
pantalla no llegara a usar `POST /planeador/unidades/:ID/criterios`. Corregidos
en **V455**. Todo fue reproducido y validado contra el Postgres local a través
del gateway (`/api/eval-col/...`).

Base: `/api/eval-col`. Todas las rutas requieren `Authorization: Bearer <jwt>`;
el usuario se resuelve con `fn_get_academico_usuario_id(:CONTEXT.USER_ID)`.
Roles con acceso: `CEVAL-SUPER_ADMINISTRADOR`, `CEVAL-DOCENTE` (más los roles
con el menú `PLANEADOR`, V284/V305). El gate de base es `fn_planeador_assert_alcance`
(capability VER / EDITAR / ELIMINAR sobre `PLANEADOR` + alcance territorial).

## Diagnóstico

Con la unidad de la captura (`fk_referente_curricular: null` en `GET /planeador/unidades/11`)
la pantalla pintaba el referente pero la sección de rúbrica decía
`"La unidad no tiene referente curricular asignado"` y el POST de criterio nunca
prosperaba. Son **dos** defectos independientes:

| # | Síntoma | Causa | Dónde |
|---|---|---|---|
| 1 | El front muestra el referente (`GET /planeador/referente-curricular?GRADO=`) pero `campos_disponibles.rubrica.visible=false` y `GET /unidades/:ID/referente` devuelve todo `NULL`. | El referente se **guarda** en `TUNIDAD.FK_REFERENTE_CURRICULAR` al crear la unidad (V216) y se re-deriva solo en `PUT /unidades/:ID` (V216) o en la reparación puntual de V280. Si el referente del nivel se carga/activa **después** de crear la unidad (o la regla vieja de derivación devolvía NULL, V451), la FK queda NULL para siempre: `GET /referente-curricular` deriva en vivo y sí lo ve; los lectores de la unidad (`fn_unidad_referente_evaluativo`, `fn_unidad_campos_disponibles`, `fn_unidad_referente_detalle`, instrumentos) leen la FK guardada y no. | `fn_unidad_referente_aplicable` (V216/V451) vs. lectores de `TUNIDAD.FK_REFERENTE_CURRICULAR` |
| 2 | `GET /unidades/:ID/valoraciones` devuelve las 4 bandas, pero `POST /unidades/:ID/criterios` responde 400 `"El periodo academico del grado de la unidad no tiene una escala definida en sus criterios de evaluacion"`. | Dos reglas distintas para "qué escala aplica a la unidad": el GET (V227) resuelve criterio vigente de (asignatura, grado) → `TCRITERIO_EVALUACION.FK_TESCALA` con **fallback a `TNIVEL_ESCALA`**; el POST (V216) solo miraba `TGRADO.FK_TPERIODO_ACADEMICO → TCRITERIO_EVALUACION.FK_TESCALA`. Con la opción **"Cada nivel tendrá su escala"** (`FK_TESCALA` NULL + una fila por nivel en `TNIVEL_ESCALA`, que es como lo guarda el módulo de escalas, V42) el GET lista y el POST rechaza. | `fn_unidad_valoraciones_listar` (V227) vs. `fn_unidad_criterio_agregar` (V216) |

Lo que **no** era el problema: los permisos (`role_query` tiene DOCENTE y SUPER_ADMIN
en las 6 rutas), el `param_types` de las filas de `public.query`, y el gate.

## Corrección (V455)

1. **`fn_unidad_escala_aplicable(pk_tunidad)`** — única definición de la escala de
   una unidad: criterio de evaluación vigente de (asignatura, grado) [V239] →
   criterio del periodo académico del grado → `TNIVEL_ESCALA` (nivel del grado,
   periodo del grado). `fn_unidad_valoraciones_listar` y `fn_unidad_criterio_agregar`
   la comparten: lo que el GET lista es exactamente lo que el POST acepta.
2. **`fn_unidad_referente_reparar()`** — la reparación de V280 como función
   idempotente, ejecutada una vez en la migración y dejada como trigger por
   sentencia (`AFTER INSERT OR UPDATE`) sobre `TREFERENTE_CURRICULAR` y
   `TREFERENTE_CURRICULAR_NIVEL`: dar de alta, activar o vincular a un nivel un
   referente re-apunta las unidades activas cuyo referente es NULL, ya no está
   vigente o no aplica a su nivel. Salta las unidades con actividades
   instrumentadas cuyo referente aún existe (mismo guard de `fn_unidad_actualizar`).

Las firmas y las filas de `public.query` no cambian; el front no tiene que tocar nada.

## Orden de llamadas de la pantalla

```
GET /planeador/unidades/:ID                       → campos_disponibles.rubrica.visible
GET /planeador/unidades/:ID/referente             → cabecera del referente + enunciados marcados
GET /planeador/referente-curricular?GRADO=&ASIGNATURA=   (catálogo, para ofrecer enunciados)
GET /planeador/unidades/:ID/valoraciones          → columnas BAJO/BÁSICO/ALTO/SUPERIOR (pk_tescala_valoracion)
GET /planeador/unidades/:ID/criterios             → tabla de criterios
POST /planeador/unidades/:ID/criterios            → "Agregar criterio" (un indicador por valoración)
PUT /planeador/unidades/criterios/:ID             → editar textos / niveles
PATCH /planeador/unidades/criterios/:ID           → eliminar (soft delete)
```

---

## 1. `GET /planeador/unidades/:ID` — detalle (fn_unidad_buscar_por_pk, V216)

**Entrada:** `PARAM.ID` = PK_TUNIDAD. Gate VER.

**Salida** (campos relevantes al flujo):

```json
{"rows":[{
  "pk_tunidad": 970001,
  "fk_tgrado": 990501, "grado": "G1 MANANA",
  "fk_tasignatura": 970001, "asignatura": "ANALISIS",
  "fk_referente_curricular": 980001,
  "referente_curricular": "DBA Preescolar",
  "referente_vigente": true,
  "campos_disponibles": {
    "rubrica":    {"visible": true,  "requerido": false, "motivo": "El referente curricular de la unidad es EVALUATIVO"},
    "enunciados": {"visible": true,  "requerido": false, "motivo": "La unidad tiene referente curricular; puede relacionar enunciados (TUNIDAD_ENUNCIADO)"}
  }
}]}
```

`campos_disponibles.rubrica.visible` = la unidad tiene referente **vigente**
(`ACTIVE` y `ESTADO='A'`) con enfoque `EVALUATIVO`. Motivos posibles:
`"La unidad no tiene referente curricular asignado"` (FK NULL → tras V455 solo
si el grado no tiene ningún referente aplicable), `"El referente curricular de
la unidad es FORMATIVO, no EVALUATIVO"`, o el de arriba.

Errores: 404 `P0002` unidad inexistente; 403 `42501` sin capability/alcance.

## 2. `GET /planeador/unidades/:ID/referente` — (fn_unidad_referente_detalle, V255)

**Entrada:** `PARAM.ID` = PK_TUNIDAD. Gate VER.

**Salida:** una fila siempre (los campos del referente en NULL si la unidad no
tiene uno vigente):

```json
{"rows":[{
  "pk_tunidad": 970001, "unidad_nombre": "Centenas",
  "fk_tgrado": 990501, "grado": "G1 MANANA",
  "fk_tnivel_ensenanza": 990001, "nivel_ensenanza": "Preescolar",
  "pk_referente_curricular": 980001, "referente_nombre": "DBA Preescolar", "referente_descripcion": "...",
  "enfoque_valor": "EVALUATIVO", "enfoque_nombre": "Evaluativo", "es_evaluativo": true,
  "tipo_evaluacion_valor": "CUANTITATIVA_CUALITATIVA", "tipo_evaluacion_nombre": "Cuantitativa y cualitativa",
  "nivel_1_etiqueta": "Enunciado", "nivel_2_etiqueta": "Evidencia",
  "enunciados": [ {"pk": 1, "texto": "...", "relacionadoConUnidad": true, "pkTunidadEnunciado": 5,
                   "evidencias": [{"pk": 9, "texto": "..."}]} ]
}]}
```

Solo trae los enunciados que **esta unidad marcó** (`TUNIDAD_ENUNCIADO`); para el
árbol completo está el endpoint 3. Rotular con `nivel_1_etiqueta`/`nivel_2_etiqueta`.

## 3. `GET /planeador/referente-curricular?GRADO=&ASIGNATURA=&ANIO=` — (fn_refcurr_por_grado_asignatura, V278)

**Entrada:** `QUERY.GRADO` (BIGINT, obligatorio), `QUERY.ASIGNATURA` (opcional,
desempata por área), `QUERY.ANIO` (default año en curso). Gate VER + alcance por grado.

**Salida:** el/los referentes que **aplican** al nivel del grado según
`fn_unidad_referente_aplicable` (misma regla que usa `POST /planeador/unidades`
para rellenar la FK), con `especificidad`, `niveles`, `areas` y el árbol completo
`enunciados[{pk,texto,evidencias[]}]`. Esta ruta **deriva en vivo**: es la que
seguía mostrando el referente cuando la unidad tenía la FK en NULL.

## 4. `GET /planeador/unidades/:ID/valoraciones` — (fn_unidad_valoraciones_listar, V227 → V455)

**Entrada:** `PARAM.ID` = PK_TUNIDAD. Gate VER.

**Salida:** una fila por banda de la escala que aplica a la unidad
(`fn_unidad_escala_aplicable`), sin paginar:

```json
{"rows":[
 {"pk_tescala_valoracion": 980001, "fk_tescala": 980001, "escala_nombre": "Escala Preescolar",
  "orden": 1, "valoracion_codigo": "BAJO", "valoracion_nombre": "Bajo",
  "valoracion_simbolo": null, "valoracion_carita": null,
  "limite_inferior": 0.0, "limite_superior": 59.0,
  "nota_minima": null, "nota_maxima": null, "formato_valor": null, "es_numerico": null},
 {"pk_tescala_valoracion": 980002, "...": "Basico"},
 {"pk_tescala_valoracion": 980003, "...": "Alto"},
 {"pk_tescala_valoracion": 980004, "...": "Superior"}
]}
```

`pk_tescala_valoracion` es lo que el POST pide como `fkTescalaValoracion`.
`nota_minima/nota_maxima` vienen convertidas al formato del colegio solo en
formatos numéricos (CINCO/DIEZ/CIEN). `rows: []` si no hay escala por ningún
camino — en ese caso el POST también fallará con 22023.

## 5. `GET /planeador/unidades/:ID/criterios?INCLUIR_INACTIVOS=` — (fn_unidad_criterio_listar, V222)

**Entrada:** `PARAM.ID` = PK_TUNIDAD; `QUERY.INCLUIR_INACTIVOS` (default false). Gate VER.

**Salida:** criterios ordenados por `orden`, cada uno con sus niveles ordenados
por la valoración de la escala:

```json
{"rows":[{
  "pk_tcriterio_unidad": 1, "orden": 1,
  "descripcion": "Reconoce numeros hasta 100",
  "publico": "S", "codigo": null, "descriptor_prom": "N",
  "niveles": [
    {"pk": 1, "orden": 1, "fkTescalaValoracion": 980001, "valoracion": "Bajo",     "indicador": "No los reconoce",     "recomendacion": null, "tarea": null},
    {"pk": 2, "orden": 2, "fkTescalaValoracion": 980002, "valoracion": "Basico",   "indicador": "Reconoce algunos",    "recomendacion": null, "tarea": null},
    {"pk": 3, "orden": 3, "fkTescalaValoracion": 980003, "valoracion": "Alto",     "indicador": "Reconoce la mayoria", "recomendacion": null, "tarea": null},
    {"pk": 4, "orden": 4, "fkTescalaValoracion": 980004, "valoracion": "Superior", "indicador": "Los reconoce todos",  "recomendacion": null, "tarea": null}
  ],
  "active": true
}]}
```

`rows: []` mientras la unidad no tenga criterios (es lo que pinta "Esta unidad no
tiene criterios definidos"). La rúbrica (`TRUBRICA_UNIDAD`) no se crea hasta el
primer POST.

## 6. `POST /planeador/unidades/:ID/criterios` — (fn_unidad_criterio_agregar, V216 → V455)

**Entrada:** `PARAM.ID` = PK_TUNIDAD. Gate EDITAR.

```json
{
  "DESCRIPCION": "Cuenta de 10 en 10",
  "NIVELES": [
    {"fkTescalaValoracion": 980001, "indicador": "No cuenta"},
    {"fkTescalaValoracion": 980002, "indicador": "Cuenta hasta 30", "recomendacion": "...", "tarea": "..."},
    {"fkTescalaValoracion": 980003, "indicador": "Cuenta hasta 70"},
    {"fkTescalaValoracion": 980004, "indicador": "Cuenta hasta 100"}
  ],
  "PUBLICO": "S",
  "CODIGO": "C01",
  "DESCRIPTOR_PROM": "N"
}
```

| Campo | Tipo | Regla |
|---|---|---|
| `DESCRIPCION` | VARCHAR(4000) | obligatorio, no vacío |
| `NIVELES` | JSONB array | **exactamente** un elemento por cada valoración activa de la escala de la unidad (los `pk_tescala_valoracion` del endpoint 4); `indicador` obligatorio; `recomendacion`/`tarea` opcionales |
| `PUBLICO` | 'S' \| 'N' | default 'S' |
| `CODIGO` | VARCHAR(6) | opcional |
| `DESCRIPTOR_PROM` | 'S' \| 'N' | default 'N' |

**Salida:** `{"rows":[{"fn_unidad_criterio_agregar": 2}]}` — PK_TCRITERIO_UNIDAD.
Crea la rúbrica de la unidad si no existía (`fn_unidad_rubrica_asegurar`, V222)
y asigna `ORDEN = MAX+1`.

**Errores** (el gateway los traduce a HTTP 400 con `code: INVALID_VALUE`, 404/409 según SQLSTATE):

| SQLSTATE | Mensaje | Cuándo |
|---|---|---|
| `P0002` | No se encontro la unidad tematica solicitada | ID inexistente |
| `22023` | La unidad esta inactiva; no se le pueden agregar criterios | unidad borrada |
| `22023` | El texto del criterio es obligatorio | DESCRIPCION vacía |
| `22023` | La unidad no tiene una escala de valoracion aplicable: ... | ningún camino da escala (antes de V455: "El periodo academico del grado de la unidad no tiene una escala definida...", también cuando SÍ había escala por nivel) |
| `22023` | Debe enviar exactamente un indicador por cada valoracion activa de la escala (esperados: 4, recibidos: 1) | faltan/sobran niveles |
| `22023` | El payload de niveles tiene valoraciones repetidas | `fkTescalaValoracion` duplicado |
| `22023` | Cada nivel del criterio requiere un indicador no vacio | `indicador` vacío |
| `23503` | Un nivel referencia una valoracion (fkTescalaValoracion) que no pertenece a la escala de evaluacion de la unidad | pk de otra escala |

## 7. `PUT /planeador/unidades/criterios/:ID` — (fn_unidad_criterio_actualizar, V222)

**Entrada:** `PARAM.ID` = PK_TCRITERIO_UNIDAD. Gate EDITAR. PATCH parcial: todo
campo ausente/NULL se conserva.

```json
{
  "DESCRIPCION": "Cuenta de 10 en 10 hasta 100",
  "PUBLICO": "N",
  "CODIGO": "C01", "LIMPIAR_CODIGO": false,
  "DESCRIPTOR_PROM": "S",
  "NIVELES": [ {"fkTescalaValoracion": 980004, "indicador": "Cuenta hasta 100 sin ayuda", "recomendacion": "", "tarea": null} ]
}
```

`NIVELES` solo actualiza niveles **ya existentes** del criterio (no crea ni
borra): campos ausentes/NULL se preservan, `""` vacía `recomendacion`/`tarea`.

**Salida:** `{"rows":[{"fn_unidad_criterio_actualizar": 2}]}`.
Errores: `P0002` criterio inexistente; `22023` criterio inactivo / texto vacío /
`fkTescalaValoracion` que no es un nivel de ese criterio.

## 8. `PATCH /planeador/unidades/criterios/:ID` — (fn_unidad_criterio_eliminar, V222)

**Entrada:** `PARAM.ID` = PK_TCRITERIO_UNIDAD, sin body. Gate ELIMINAR.

**Salida:** `{"rows":[{"fn_unidad_criterio_eliminar": 2}]}`. Soft delete del
criterio y sus niveles; no renumera `ORDEN`. Errores: `P0002` inexistente,
`22023` ya inactivo.

---

## Cómo se resuelve cada cosa (para no volver a divergir)

| Pregunta | Función única | Quién la usa |
|---|---|---|
| ¿Qué referente le corresponde a (grado, asignatura)? | `fn_unidad_referente_aplicable` (V216/V451) | `fn_unidad_crear`, `fn_unidad_actualizar`, `fn_refcurr_por_grado_asignatura` (endpoint 3), `fn_unidad_referente_reparar` (V455) |
| ¿Qué referente tiene la unidad? | `TUNIDAD.FK_REFERENTE_CURRICULAR` (guardado; V455 lo mantiene al día por trigger) | `fn_unidad_referente_evaluativo`, `fn_unidad_referente_tipo_evaluacion`, `fn_unidad_campos_disponibles`, `fn_unidad_referente_detalle`, instrumentos de actividad |
| ¿Qué escala aplica a la unidad? | `fn_unidad_escala_aplicable` (V455) | `fn_unidad_valoraciones_listar` (endpoint 4), `fn_unidad_criterio_agregar` (endpoint 6) |

## Validación local realizada

Fixture: referente EVALUATIVO para el nivel Preescolar, criterio de evaluación del
periodo con `FK_TESCALA` NULL y escala del nivel en `TNIVEL_ESCALA` (4 bandas);
3 unidades preexistentes con `FK_REFERENTE_CURRICULAR` NULL.

- Antes de V455: endpoint 1 → `rubrica.visible=false` "no tiene referente"; endpoint 2 → todo NULL; endpoint 3 → sí devuelve el referente; endpoint 4 → 4 bandas; endpoint 6 → 22023 "no tiene una escala definida".
- Después de V455: la migración re-apuntó las 3 unidades (`3 unidades re-apuntadas`); endpoints 1 y 2 devuelven el referente y `rubrica.visible=true`; 6 → 200 (pk 2); 6 con 1 nivel → 400 "esperados: 4, recibidos: 1"; 5 lista el criterio con sus 4 niveles; 7 → 200; 8 → 200.
- Trigger: unidad creada en un grado cuyo nivel aún no tiene referente (FK NULL) → al insertar el referente + su fila de nivel, la unidad queda apuntándolo (`modified_by = tr_refcurr_reparar_unidades`) y `rubrica.visible=true`; un UPDATE cosmético del referente no la toca.
- Re-aplicar V455 es no-op (`0 unidades re-apuntadas`).
