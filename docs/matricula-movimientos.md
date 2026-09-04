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
| `POST` | `/cobertura-academica/matricula/promover` | 263 | **Promoción en lote** |
| `POST` | `/cobertura-academica/matricula/reubicar` | 264 | **Reubicación en lote** |
| `POST` | `/cobertura-academica/matricula/corregir` | 298 | **Corrección en lote** |
| `PATCH` | `/usuarios/:ID` | 295 | **Datos de la persona** |

Y uno que **no está en el catálogo**, porque vive en auth-center:

| Método | Ruta | Qué hace |
|---|---|---|
| `POST` | `/register/usuario` | Da de alta una persona, **o la devuelve si ya existe** |

Se usa para resolver al acudiente antes de sustituirlo en una matrícula: el
front pide la persona por sus datos y recibe su `PK_TUSUARIO`, sin tener que
comprobar antes si estaba registrada. Comparte `fn_usu_crear` con
`POST /register/funcionario`.

`PATCH` para editar (convención del sistema: establecimientos 87, sedes 90,
funcionarios 119, referentes 232). `PUT` para las acciones sobre **una**
matrícula (retirar, reingresar, reactivar, baja), porque el catálogo sólo admite
GET/POST/PUT/PATCH y `DELETE` está prohibido por `ck_query_http_method`.

**`POST` para las acciones de lote** (promover, reubicar, corregir,
bulk-delete). Dos razones: promover y reubicar **crean** matrículas nuevas, y
sobre todo el **file-service no procesa multipart en `PUT`** — en todo el
catálogo, los endpoints con campos `FILE` son `POST` o `PATCH`, sin una sola
excepción. Declarar el soporte en un `PUT` daba:

> El campo 'SOPORTE' no está declarado como archivo para esta ruta.

corregir también es `POST` aunque no lleve archivo: son tres acciones hermanas
de la misma pantalla y tenerlas en verbos distintos sólo complica al front.

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
// promover y reubicar -- multipart, porque el soporte es un archivo.
// OJO: las claves van en UPPER_SNAKE, no en camelCase (ver mas abajo).
{
  "IDS": [1001, 1002, 1003],
  "GRUPO_DESTINO": 11402,
  "MOTIVO": "Promoción de fin de año",
  "SOPORTE": <archivo>          // FILE:matricula, obligatorio
}

// corregir -- JSON normal
{ "IDS": [1001], "GRUPO_DESTINO": 11402 }
```

El soporte llega como multipart: el file-service lo sube a S3 y sustituye el
binario por el `PK_TARCHIVO` antes de ejecutar la query. Es el mismo mecanismo
de los documentos del alta.

### Respuesta

Las claves de la **respuesta** sí van en `camelCase` — las arma
`jsonb_build_object` en la función. Sólo las del **cuerpo de la petición** van en
`UPPER_SNAKE`.

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

## Las claves del cuerpo van en `UPPER_SNAKE`

El motor de queries busca cada placeholder por su **nombre exacto**, tal como está
declarado en `param_types` del catálogo. **No convierte `camelCase` a
`snake_case`**: sólo pasa a mayúsculas lo que recibe.

```jsonc
// correcto
{ "ALUMNOS_MADRE_CABEZA_DE_FAMILIA": "S", "ACTUALIZAR_MATRICULA": true }

// incorrecto -- el motor busca BODY.ALUMNOSMADRECABEZADEFAMILIA y no lo encuentra
{ "alumnosMadreCabezaDeFamilia": "S", "actualizarMatricula": true }
```

Mandar `camelCase` produce este error, que es **engañoso**:

> El query q-mtb2d9k4-cobmatedi1 tiene placeholders sin tipo declarado:
> [BODY.ACTUALIZARMATRICULA, BODY.ALUMNOSMADRECABEZADEFAMILIA, ...].
> Edita la fila en el catálogo y asigna un tipo a cada uno.

**No hay nada que arreglar en el catálogo.** Esos nombres salen de las claves que
envió el cliente, no del texto de la query. Dos señales para reconocerlo:

- los nombres aparecen **sin guiones bajos**, que es justo lo que queda al pasar
  `camelCase` a mayúsculas sin insertar separadores;
- la lista puede incluir campos que la query **no menciona** (por ejemplo
  `GENERODELACUDIENTE`), lo que sería imposible si viniera del catálogo.

Para verificarlo sin adivinar, comparar los placeholders del texto contra las
claves declaradas:

```sql
SELECT jsonb_object_keys(param_types) FROM public.query
 WHERE uuid = 'q-mtb2d9k4-cobmatedi1';
```

Es la misma convención del POST de alta (215). La colección
`docs/postman/matricula-editar-movimientos.postman_collection.json` trae los
cinco requests con las claves ya escritas, generada desde el catálogo.

### Listas: `IDS` depende del transporte

**En JSON** (`corregir`, `bulk-delete`) la lista va como array y el tipo es
`BIGINT[]`, que es la convención de los veinte endpoints de lista del catálogo:

```sql
CAST(:BODY.IDS AS BIGINT[])        "BODY.IDS": "BIGINT[]"
```
```jsonc
{ "IDS": [1001, 1002, 1003], "GRUPO_DESTINO": 11402 }
```

**En multipart** (`promover`, `reubicar`, que llevan el soporte) **no existen
los tipos: todo llega como cadena.** Y `CAST(texto AS BIGINT[])` sólo acepta la
sintaxis de array de Postgres:

| valor de `IDS` | `CAST AS BIGINT[]` |
|---|---|
| `{1001}` | ✓ |
| `[1001]` — lo que serializa un array de JS | **error 22P02** *malformed array literal* |
| `1001` | **error 22P02** |

Por eso esos dos declaran `"BODY.IDS": "TEXT"` y parsean el valor a mano.
**Aceptan cualquiera de estas formas**, así que el cliente no tiene que
adivinar:

```
[1001,1002]     {1001,1002}     1001,1002     1001     [1001, 1002]
```

En el campo del formulario se manda simplemente `[1001,1002]`. La asimetría con
los de JSON no es arbitraria: multipart no tiene tipos y JSON sí. Y pasar los de
JSON a `TEXT` sería peor — el motor tendría que serializar el array, y si lo
aplanara quedaría sólo el primer elemento, perdiendo el resto en silencio.

**Cuidado con `BODY_RAW`.** El motor valida la clave entrante contra
`BODY.<NOMBRE>`; `BODY_RAW.<NOMBRE>` sólo sirve para que el *texto de la query*
reciba el JSON sin aplanar. Declarar únicamente `BODY_RAW.X` deja la clave
entrante sin tipo y el motor aborta antes de ejecutar:

> El query q-mtb2d9k4-cobmatcor1 tiene placeholders sin tipo declarado: [BODY.IDS].

Los seis endpoints del catálogo que usan `BODY_RAW` y funcionan declaran
**las dos claves** (`/areas/:ID/asignaturas`, `/escalas`, `/horarios`,
`/menus/order`, `/roles/:ROLEID/menus`, `/asistencias/registrar`). Regla
práctica:

| el campo es… | cómo se declara |
|---|---|
| lista de números | sólo `BODY.X` con `BIGINT[]` |
| lista de objetos, u objeto | `BODY.X` **y** `BODY_RAW.X`, ambos `JSONB` |

`OTROS_DOCUMENTOS_RELEVANTES` es del segundo caso —lleva
`{pkTmatriculaArchivo, fkTarchivo}`— así que conserva las dos declaraciones.

### Multipart cuando hay archivos

| endpoint | ruta | modo |
|---|---|---|
| `PATCH` matrícula (294) | `/api/files/eval-col/...` | formdata (4 archivos) |
| `PATCH` usuarios (295) | `/api/files/eval-col/...` | formdata (foto) |
| `POST` promover (263) | `/api/files/eval-col/...` | formdata (soporte) |
| `POST` reubicar (264) | `/api/files/eval-col/...` | formdata (soporte) |
| `POST` corregir (298) | `/api/eval-col/...` | JSON |

**El método importa: los archivos sólo funcionan en `POST` y `PATCH`.** Y la
clasificación se declara **sin sufijo** — `FILE:matricula`, no
`FILE:matricula!`. La obligatoriedad del soporte y del motivo la valida la
función con un `22023`, que es donde no se puede saltar.

Los que llevan campos `FILE:` pasan por el file-service, que sube el archivo a
S3 y sustituye el binario por el `PK_TARCHIVO` antes de ejecutar la query.

### Campos que el editar de matrícula NO recibe

`TMATRICULA_CAMPO` tiene 65 campos activos, pero algunos no pertenecen a la
matrícula sino a la **persona**, y van por `PATCH /usuarios/:ID`:

| campo del formulario | dónde vive | endpoint |
|---|---|---|
| Género del estudiante / del acudiente | `TUSUARIO.FK_TLV_GENERO` | `PATCH /usuarios/:ID`, clave `GENERO` |
| Nombres, apellidos, documento, fecha de nacimiento | `TUSUARIO` | `PATCH /usuarios/:ID` |

Ambos géneros están además marcados `EDITABLE = 'N'` en `TMATRICULA_CAMPO`, así
que en principio no deberían llegar al editar.

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
puede haber terminado**. Puede ser el mismo período de la matrícula —bajar de
grado a mitad de año—, uno posterior —la promoción de fin de año, el caso
normal— o incluso uno que empezó antes.

Consecuencia práctica: **el período del año siguiente tiene que existir antes de
poder promover.**

> Hubo además una comparación de fechas de inicio, que exigía que el período
> destino no hubiera empezado antes que el de la matrícula. Se quitó: en la
> práctica es normal que dos períodos vigentes arranquen con días o semanas de
> diferencia, y esa comparación rebotaba movimientos legítimos por un desfase
> de calendario que no dice nada del año lectivo. Con que ninguno de los dos
> períodos haya terminado alcanza.

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
  "ACTUALIZAR_MATRICULA": true,
  "ACTUALIZAR_ESTUDIANTE": true,
  "ACTUALIZAR_ACUDIENTE": false,
  "ACTUALIZAR_SOCIOECONOMICO": true,
  "PK_USUARIO_ACUDIENTE": 166663,  // quién debe quedar como acudiente — mándalo siempre
  "PARENTESCO": 703,               // obligatorio si el acudiente cambia
  "PK_TPADRE": 70157,              // opcional: cuál editar si el estudiante tiene varios
  "TOCAR_DOCUMENTO_DE_IDENTIDAD": true,
  "DOCUMENTO_DE_IDENTIDAD_DEL_ESTUDIANTE": <archivo>   // null => borrado lógico
}
```

Sin las banderas no se podría distinguir "esta sección no se envió" de "no
cambió nada", que es justo lo que permite editar una parte del formulario sin
mandar el resto.

El acudiente es la excepción: no lo decide una bandera sino una **key**, porque
hay tres cosas que pueden pasarle y una bandera sólo distingue dos. Ver la
sección siguiente.

### El acudiente: sustituirlo o editarlo

**Cómo se conecta.** `TMATRICULA.FK_TPADRE` es el vínculo matrícula ↔ acudiente.
Un estudiante puede tener varios acudientes en `TNUCLEO_FAMILIAR` —que es la
**relación familiar**, con sus datos— y **cada matrícula señala a uno**.
Sustituir el acudiente es repuntar ese campo; el núcleo familiar del anterior
sobrevive, porque el vínculo familiar sigue siendo real.

Medido sobre los datos: de las matrículas activas, **32.070** tienen
`FK_TPADRE` relleno y **31.293** coinciden con una fila `ACTIVE` de
`TNUCLEO_FAMILIAR` del mismo par (padre, estudiante). En estudiantes con dos o
tres vínculos, apunta a uno de ellos. No es una columna muerta: es el
discriminador.

**Los tres casos**, y los distingue `PK_USUARIO_ACUDIENTE` — el `PK_TUSUARIO` de
quien debe quedar como acudiente de esa matrícula. Mándala **siempre**:

| Qué mandas | Qué pasa | `acudiente.accion` |
|---|---|---|
| la misma key, `ACTUALIZAR_ACUDIENTE: false` | nada | `sin cambio` |
| la misma key, `ACTUALIZAR_ACUDIENTE: true` + campos | se editan sus datos en sitio | `datos actualizados` |
| **otra** key + `PARENTESCO` | se sustituye | `sustituido` |
| no la mandas | el acudiente no se toca | `sin cambio` |

Para sustituir, el front resuelve primero la persona con
`POST /register/usuario` (auth-center, fuera del catálogo), que **la devuelve si
ya existe** en vez de duplicarla —un docente, un padre con otro hijo
matriculado—, y manda esa key.

**`PARENTESCO` es obligatorio al sustituir.** `TNUCLEO_FAMILIAR.FK_TLV_PARENTESCO`
es `NOT NULL` y no se puede deducir: si entra un acudiente nuevo hay que decir
qué relación tiene con el alumno. Si falta, la respuesta es `23502`.

Los demás campos del acudiente cambian de papel según el caso: al **sustituir**
alimentan la **creación** de los registros del nuevo; al **editar**, la
actualización del que ya está. Nunca modifican los datos del anterior.

**Qué le pasa al que sale.** Nada, salvo el acceso:

- **Sigue en el núcleo familiar** del estudiante. La fila queda `ACTIVE`.
- Conserva su `TPADRE` y su `TUSUARIO`.
- Pierde el permiso de acudiente **en esa sede**, y sólo si ya no es acudiente
  de ninguna otra matrícula activa allí.

Ese último criterio va por `TMATRICULA.FK_TPADRE`, no por `TNUCLEO_FAMILIAR`, y
ahí está la diferencia con `fn_padre_soft_delete`, que sí mira el núcleo: esa
función deshace la relación entera, así que el vínculo familiar es la base
correcta. En una sustitución el vínculo **sobrevive a propósito**, así que
preguntarle a él daría siempre "aún le queda un estudiante aquí" —justo el que
acabamos de quitarle— y el permiso nunca se retiraría. Es un error que estuvo
escrito y que sólo salió al probar la rama.

**La respuesta** dice qué pasó, sin que el front tenga que inferirlo:

```jsonc
{
  "pkTpadre": 2991,
  "acudiente": {
    "accion": "sustituido",
    "pkTpadreAnterior": 65124,
    "permisosRetiradosAlAnterior": 1
  },
  "actualizado": { "acudiente": true }
}
```

**En la lectura.** El `GET` sigue devolviendo **todos** los acudientes del
estudiante con su vínculo —la lista no se filtra— y marca cuál es el de la
matrícula. Cuando `FK_TPADRE` apunta a alguien sin fila de núcleo (hay 777 así
en los datos heredados) se muestra a esa persona con el parentesco vacío, en vez
de sustituirla por otra: es más honesto que mentir sobre quién es.

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
"OTROS_DOCUMENTOS_RELEVANTES": [
  { "pkTmatriculaArchivo": 12, "fkTarchivo": null },  // borrar ese
  { "fkTarchivo": 987 }                               // agregar uno
]
```

---

## Deuda conocida

- **`fn_matricula_listar` divergió del repo.** La que corría en el servidor no
  era la de V200: había una revisión aplicada a mano que nunca se escribió al
  archivo, y traía un comentario dando por muerta la columna `FK_TPADRE` —de ahí
  el bug de los 2.037 acudientes equivocados—. La corrección va en **V239**
  partiendo de la versión **viva**, para no perder ese trabajo ni subirlo al
  repo sin que su autor lo revise. Cuando escriba V200, V239 sigue siendo la
  última palabra por número de versión. Pendiente: que lo haga.
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
