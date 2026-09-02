# Matrícula: edición y movimientos de grupo

Qué endpoint usar para cada cosa, en qué orden llamarlos y por qué las reglas
son las que son. Cubre el módulo de cobertura académica: crear, editar, mover de
grupo y cambiar de estado.

---

## Los endpoints

| Método | Ruta | `id_query` | Qué hace |
|---|---|---|---|
| `POST` | `/cobertura-academica/matricula` | 215 | Matrícula directa |
| `GET` | `/cobertura-academica/matricula/:ID` | 216 | Ficha completa |
| `PATCH` | `/cobertura-academica/matricula/:ID` | 294 | **Editar la ficha** |
| `PUT` | `/cobertura-academica/matricula/:ID` | 226 | Baja lógica individual |
| `POST` | `/cobertura-academica/matricula/bulk-delete` | 227 | Baja lógica masiva |
| `PUT` | `/cobertura-academica/matricula/:ID/retirar` | 245 | Cursando → Retirado |
| `PUT` | `/cobertura-academica/matricula/:ID/reingresar` | 248 | Retirado → Cursando |
| `PUT` | `/cobertura-academica/matricula/:ID/reactivar` | 252 | Estado cerrado → Cursando |
| `PUT` | `/cobertura-academica/matricula/promover` | 263 | **Promoción en lote** |
| `PUT` | `/cobertura-academica/matricula/reubicar` | 264 | **Reubicación en lote** |
| `PUT` | `/cobertura-academica/matricula/corregir` | 298 | **Corrección en lote** |
| `PATCH` | `/usuarios/:ID` | 295 | **Datos de la persona** |

`PATCH` para editar (convención del sistema: establecimientos 87, sedes 90,
funcionarios 119, referentes 232). `PUT` para las acciones, porque el catálogo
sólo admite GET/POST/PUT/PATCH y `DELETE` está prohibido por
`ck_query_http_method`.

---

## Los tres movimientos de grupo

Los tres reciben una **lista**. Para un solo estudiante se manda una lista de un
elemento; no hay endpoints individuales.

| | promover | reubicar | corregir |
|---|---|---|---|
| Destino | grado superior, **misma sede** | otra sede, **o grado inferior misma sede** | cualquiera de los anteriores |
| ¿Matrícula nueva? | sí | sí | **no**: mueve la existente |
| Estado de la anterior | Promovido | Reubicado | **no cambia** |
| Motivo | **obligatorio** | **obligatorio** | no se pide |
| Soporte (archivo) | **obligatorio** | **obligatorio** | no se pide |
| Registro | `TMATRICULA_PROMOCION` | `TTRASLADO_ESTUDIANTE` + `TTRASLADO_MATRICULA` | ninguno |
| Estado de origen | sólo Cursando | sólo Cursando | sólo Cursando |

**Corregir es la alternativa a las otras dos.** En la pantalla, el usuario elige
el destino y después decide si el movimiento es una novedad académica
(promoción / reubicación) o simplemente el arreglo de algo mal capturado
(corrección). Por eso corregir acepta exactamente los mismos destinos: si
aceptara menos, dejaría de ser una alternativa.

### Cuerpo

```jsonc
// promover y reubicar -- multipart, porque el soporte es un archivo
{
  "ids": [1001, 1002, 1003],
  "grupoDestino": 11402,
  "motivo": "Promoción de fin de año",
  "soporte": <archivo>          // FILE:matricula, obligatorio
}

// corregir -- JSON normal
{ "ids": [1001], "grupoDestino": 11402 }
```

El soporte llega como multipart: el file-service lo sube a S3 y sustituye el
binario por el `PK_TARCHIVO` antes de ejecutar la query. Es el mismo mecanismo
de los documentos del alta.

### Respuesta

```jsonc
{
  "mensaje": "Matricula actualizada",
  "tipoCambio": "promover",
  "procesadas": 3,
  "estadoAplicado": { "id": 51976, "nombre": "Promovido" },
  "estadoNuevas":   { "id": 257,   "nombre": "Cursando" },
  "motivo": "Promoción de fin de año",
  "soporte": 490654,
  "destino": { "fkTgrupo": 11402, "grupo": "01", "fkTgrado": 3688,
               "grado": "CUARTO", "fkTsede": 1373, "fkTperiodoAcademico": 1747 },
  "matriculas": [{
    "pkTmatriculaAnterior": 1001,
    "pkTmatriculaNueva": 2001,          // null en corregir
    "estudiante": { "pkTestudiante": 188870, "documento": "1002003004",
                    "nombre": "MARIA JOSE PEREZ GOMEZ" },
    "anterior": { "fkTgrado": 3679, "grado": "TERCERO", "fkTgrupo": 11340, "grupo": "01" },
    "nuevo":    { "fkTgrado": 3688, "grado": "CUARTO",  "fkTgrupo": 11359, "grupo": "01" },
    "estadoAnterior": { "id": 257, "nombre": "Cursando" }
  }]
}
```

---

## Orden de las llamadas

**Editar primero, mover después.**

Promover y reubicar **copian** la ficha (socioeconómico y enlaces a documentos)
a la matrícula nueva. Si se edita antes, la copia nace ya corregida y las dos
quedan consistentes. Si se mueve primero y se edita la nueva, la anterior se
queda con los datos viejos — y es la anterior la que sostiene el historial
académico, así que quedarían dos versiones divergentes del mismo estudiante.

```
Un estudiante, con cambios en la ficha y promoción:
  1. PATCH /usuarios/:ID                      (si cambian nombres, documento, etc.)
  2. PATCH /cobertura-academica/matricula/:ID (resto de la ficha)
  3. PUT   /cobertura-academica/matricula/promover   { ids: [esa], ... }

Un lote sin cambios de ficha:
  1. PUT   /cobertura-academica/matricula/promover   { ids: [...], ... }
```

En corrección da igual el orden: no hay copia, la fila es la misma.

---

## Reglas y por qué

### Período académico

Los tres movimientos usan la misma regla: el período del grupo destino **no
puede haber terminado**, y **no puede haber empezado antes** que el de la
matrícula. Pueden apuntar al mismo período —bajar de grado a mitad de año— o a
uno posterior, que es el caso normal de la promoción de fin de año.

Consecuencia práctica: **el período del año siguiente tiene que existir antes de
poder promover.**

Ninguna acción del módulo funciona si el período de la matrícula ya terminó
(`fn_matricula_validar_periodo_vigente`). El corte es `FECHA_FIN`, no `ACTIVE`:
de los 361 períodos activos, 349 ya tienen `FECHA_FIN` pasada, así que `ACTIVE`
significa "el registro sigue vigente", no "el período está en curso".

### "Grado inferior"

Se compara `TGRADO.CODIGO` como entero, pero **sólo dentro de la escalera
regular** (−3 Párvulo a 13 Normal Superior). Los códigos 14–18 (educación
especial), 21–26 (ciclos de adultos) y 99 (aceleración del aprendizaje) son
**modalidades, no escalones**: decir que "Ciclo 3 Adultos" (23) es superior a
"Quinto" (5) no significa nada. Si alguno de los dos grados está fuera de la
escalera, no se bloquea.

### Todo o nada

Los tres validan el lote completo antes de tocar la primera matrícula.
Cualquier rechazo aborta la operación entera. Dejar medio curso movido es peor
que no hacer nada: el usuario no sabría cuáles pasaron sin revisar una por una.

Es distinto del `bulk-delete` (227), que sí procesa cada una por separado.

### Permisos

Rector, secretaria o jefe de sistema del establecimiento. **El super-admin no
puede ejecutar ninguna acción del módulo de matrícula**, deliberadamente, para
no habilitarlo a mover datos académicos de instituciones que no administra.

En reubicar se exige permiso sobre el establecimiento **de origen y el de
destino**, que pueden ser distintos.

---

## Editar la ficha

`PATCH /cobertura-academica/matricula/:ID` guarda todo en **una sola
transacción**. El formulario es grande y hacer una petición por tabla dejaría la
ficha a medio guardar si una fallara.

### Banderas

El cuerpo lleva banderas que dicen qué se guarda:

```jsonc
{
  "actualizarMatricula": true,
  "actualizarEstudiante": true,
  "actualizarAcudiente": false,
  "actualizarSocioeconomico": true,
  "pkTpadre": 70157,              // obligatorio si actualizarAcudiente
  "tocarDocumentoDeIdentidad": true,
  "documentoDeIdentidadDelEstudiante": <archivo>   // null => borrado lógico
}
```

Sin las banderas no se podría distinguir "esta sección no se envió" de "no
cambió nada", que es justo lo que permite editar una parte del formulario sin
mandar el resto.

### NULL no borra

`NULL` significa **"no lo toques"**, con `COALESCE(p_campo, columna)` y
`NULLIF(TRIM(...))` en los textos: ni `NULL` ni la cadena vacía pisan un valor
existente. Es el patrón de las otras seis funciones de actualización del sistema
(`fn_est_actualizar`, `fn_fun_actualizar`, `fn_sed_actualizar`,
`fn_grado_actualizar`, `fn_grupo_actualizar`, `fn_periodo_actualizar`).

**Por esta vía no se puede vaciar un campo que ya tiene valor.** Si el negocio
lo pide, se resuelve con una lista explícita de campos a limpiar, no cambiando
el significado del `NULL`.

### Qué NO edita

- **Grupo y estado.** Tienen sus propios endpoints con sus reglas; editar la
  ficha no puede saltárselas.
- **Identidad y contacto de la persona.** Van por `PATCH /usuarios/:ID`, porque
  `TUSUARIO` es una persona, no una matrícula: la misma persona puede ser
  estudiante en una ficha y acudiente en otra.
- **Cuenta y contraseña.** Son credenciales, tienen su propio flujo.

Lo que **sí** viaja por el PATCH de matrícula es el subconjunto de `TUSUARIO`
que el formulario de matrícula pregunta —municipios, dirección de residencia,
estrato, sisbén—, igual que en el alta.

### Documentos

`TMATRICULA_ARCHIVO` guarda **enlaces**, no archivos. Al reemplazar un
documento, el enlace viejo queda `ACTIVE = FALSE` y se crea uno nuevo; el objeto
en S3 **no se toca**, porque ese mismo `PK_TARCHIVO` puede estar referenciado
por otra matrícula (al promover se copia el enlace, no el archivo). El GET
filtra por `ACTIVE`, así que el usuario sólo ve el vigente.

Para "Otros documentos relevantes", que admiten N, se opera por
`pkTmatriculaArchivo` en vez de por tipo:

```jsonc
"otrosDocumentosRelevantes": [
  { "pkTmatriculaArchivo": 12, "fkTarchivo": null },  // borrar ese
  { "fkTarchivo": 987 }                               // agregar uno
]
```

---

## Deuda conocida

- **`TMATRICULA_PROMOCION` tiene ocho `justificacion_*` heredados en `NOT NULL`**
  que pertenecen al formulario de promoción *anticipada*, no a este flujo. Se
  llenan con cadena vacía para poder insertar; el motivo real va en
  `JUSTIFICACION`. Cuando se relajen esos `NOT NULL`, se borran esas ocho
  cadenas de `fn_matricula_mover_lote`.
- **Traslado de calificaciones** al promover o reubicar: pendiente de definir,
  fuera de alcance.
- **Asignaturas de la matrícula** (`TMATRICULA_ASIGNATURA`, hoy vacía): fuera de
  alcance.
- **Aprobar / reprobar** según el criterio de promoción: pendiente. El criterio
  ya existe y está poblado (`TCRITERIO_PROMOCION`, 737 filas), pero las tablas
  de definitivas están vacías y hay decisiones de negocio sin cerrar.
