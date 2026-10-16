# Contrato del asistente (ai-control-service) para el front

Base: `/api/ai/agente` (el gateway quita `/api`). Todas las rutas exigen el JWT del usuario en
`Authorization: Bearer …`. Lo que el agente lee o propone escribir pasa por el query-service con ese mismo
token, así que el asistente nunca puede hacer más que la persona desde la pantalla.

## Endpoints

| Método | Ruta | Cuerpo | Respuesta |
|---|---|---|---|
| POST | `/conversaciones` | — | `201 {conversationId}` |
| GET | `/conversaciones?page=0&size=20` | — | conversaciones propias, recientes primero (máx. 50) |
| GET | `/conversaciones/{id}` | — | conversación con sus mensajes (ver [Historial](#historial-get-conversacionesid)) |
| PUT | `/conversaciones/{id}/archivar` | — | `204` (no hay borrado) |
| POST | `/conversaciones/{id}/mensajes` | `{texto, contextoUi?}` | `Respuesta` |
| POST | `/conversaciones/{id}/mensajes/stream` | `{texto, contextoUi?}` | eventos SSE (ver abajo) |
| POST | `/conversaciones/{id}/cancelar` | — | `{cancelado: boolean}` (ver [Cancelar](#cancelar-un-turno)) |
| POST | `/acciones/{id}/confirmar` | — | `Respuesta` con el resultado |
| POST | `/acciones/{id}/cancelar` | — | `Respuesta` |
| GET | `/sugerencias?ruta=` | — | sugerencias de la pantalla y `capacidades` (ver [Sugerencias](#sugerencias-get-sugerenciasruta)) |

Una conversación o acción de otra persona responde `404`, igual que una que no existe.

**Permiso de menú `ASISTENTE`.** Menú sin pantalla (`visible = 'N'`, sin URL) sembrado para los mismos roles
que pueden llamar a `/ai/agente/**` (todo rol `CEVAL-*` con algún menú activo). El front lo lee con
`useMenuPermission("ASISTENTE")`: `puedeVer` muestra el asistente; `puedeCrear`/`puedeEditar` indican que
puede preparar escrituras (siempre con confirmación). `puedeEliminar` es siempre `false`. Se puede quitar o
recortar por rol desde la pantalla de roles y menús. El backend sigue validando cada herramienta por su
propio menú: este código es solo para la UI.

Los nombres de personas viajan al proveedor del modelo como seudónimos (`Persona_7`) y el front los recibe
ya con el nombre real. El historial se guarda con seudónimos: `GET /conversaciones/{id}` los traduce mientras
la conversación siga viva (24 h desde el último mensaje); después pueden aparecer como `Persona_N`.

## `contextoUi`: lo que la pantalla le cuenta al asistente

Opcional en cada mensaje. Es **dato**, nunca autoriza nada: el backend lo valida todo.

```json
{
  "ruta": "/app/establecimiento-educativo/funcionarios/crear",
  "filtros": ["sede", "estado"],
  "parametros": {"sede": "12", "jornada": "MANANA", "pestana": "datos"},
  "formulario": {
    "codigo": "funcionario.crear",
    "entidad": "",
    "campos": [
      {"nombre": "nombres", "etiqueta": "Nombres", "tipo": "text", "obligatorio": true, "valor": ""},
      {"nombre": "cargo", "etiqueta": "Cargo", "tipo": "select", "obligatorio": true,
       "opciones": [{"valor": "DOCENTE", "etiqueta": "Docente"}]}
    ]
  }
}
```

- `formulario` o `formularios: [...]` (máx. 5). `codigo` tiene que coincidir con el registro del backend
  (`funcionario.crear`, `funcionario.editar`, `planeador.actividad`, `planeador.unidad`); un formulario sin
  registrar no se rellena.
- `entidad`: id del registro que se edita; vacío en altas. En los formularios del Planeador el backend lo
  usa para pedir la configuración de campos con el token del usuario.
- `tipo`: `text|textarea|email|tel|number|date|checkbox|select|radio|autocomplete` (uno desconocido cuenta
  como texto). Las fechas van en `AAAA-MM-DD`.
- `filtros`: nombres de filtro que admite el listado abierto; `APLICAR_FILTROS` solo usa estos.
- `ruta`: hasta 1000 caracteres (antes 200), con su query (`?actividad=42&dia=2026-10-16`); se recorta si
  pasa.
- `parametros`: objeto plano clave → valor con lo que identifica la pantalla (ids de la URL, filtros
  aplicados, pestaña…). Claves `[A-Za-z][A-Za-z0-9_.-]{0,59}`, valores escalares (texto, número, booleano;
  se reciben como texto de hasta 200 caracteres), máx. 30. Lo que no cumple se ignora sin error. Es dato
  para el modelo, igual que el resto del contexto.
- Todo el `contextoUi` serializado sigue limitado a 20 000 caracteres (`400` si pasa).
- Lo mejor es que el componente de formulario genere esta definición. Si una pantalla la escribe a mano,
  se desfasa.

## `Respuesta`

```json
{ "tipo": "RESPUESTA|PREGUNTA|CONFIRMACION|UI|DATOS|BLOQUEADO|SIN_PERMISO",
  "texto": "…",
  "faltantes": [{"campo": "numeroDocumento", "pregunta": "¿Cuál es el documento?", "opciones": []}],
  "accionPendiente": {"id": "uuid", "resumen": "…", "expira": "2026-10-13T15:10:00", "estado": "PENDIENTE"},
  "acciones": [ … acciones de UI … ],
  "datos": {"columnas": ["estado", "total"], "filas": [{"estado": "PENDIENTE", "total": 3}]} }
```

Los campos que no aplican al `tipo` no vienen.

| tipo | Qué hacer en el front |
|---|---|
| `RESPUESTA` | Mostrar `texto`. |
| `PREGUNTA` | Mostrar `texto` y cada `faltantes[].pregunta` (con `opciones` como botones si vienen). La respuesta va en el siguiente mensaje. |
| `CONFIRMACION` | Mostrar `accionPendiente.resumen` con **Confirmar / Cancelar**, que llaman a `/acciones/{id}/confirmar` o `/cancelar`. Un "sí" escrito en el chat no ejecuta nada. Caduca en `expira` (10 min). |
| `UI` | Mostrar `texto` y aplicar `acciones` en orden. |
| `DATOS` | Mostrar `texto` y la tabla `datos` (se puede graficar). Sin documentos, correos ni teléfonos: el backend los quita. |
| `BLOQUEADO` | Mostrar `texto`; el mensaje se rechazó por seguridad. |
| `SIN_PERMISO` | Mostrar `texto`; la persona no puede hacer eso desde el asistente. |

## Acciones de UI (`acciones[]`)

Conjunto cerrado; cada una lleva su tipo en `op`. **No existe enviar**: el envío lo hace siempre la persona
con el botón del formulario, con sus validaciones y permisos normales.

| op | Campos | Efecto |
|---|---|---|
| `NAVEGAR` | `pantalla`, `url`, `params` | Ir a `url` (viene del registro de menús, no del modelo). |
| `RELLENAR` | `formulario`, `valores{campo: valor}` | Asignar cada valor al campo **en el modelo del formulario**. |
| `LIMPIAR_CAMPO` | `formulario`, `campo` | Vaciar el campo. |
| `RESALTAR` | `formulario`, `campo` | Señalar el campo (p. ej. obligatorio que falta). |
| `ABRIR_PESTANA` | `pestana` | Abrir la pestaña con ese nombre. |
| `APLICAR_FILTROS` | `filtros{nombre: valor}` | Aplicar filtros del listado abierto. |

El backend ya validó cada acción: la pantalla está entre los menús del usuario, el formulario está registrado
y abierto, cada campo existe en la definición enviada, cada valor de una lista está entre sus opciones, y en
los formularios del Planeador no se tocan secciones que la base oculta. Aun así el front **solo debe aceptar
`op` conocidas y códigos de formulario de su propio registro**, y asignar valores como valor del campo, nunca
como HTML ni selector CSS.

## Streaming (`/mensajes/stream`)

Mismo cuerpo que `/mensajes`. Responde `text/event-stream` con:

- `event: estado` → `{"estado": "VALIDADO|INTENCION|PERMISO_OK|RECOLECTANDO|…"}` mientras avanza. Sirve para
  mostrar "Analizando…"; nunca trae texto del modelo ni su razonamiento.
- `event: herramienta` → una por cada inicio y fin de herramienta (nuevo):
  ```json
  {"id": "h1", "herramienta": "sedes_listar", "etiqueta": "Consultando sedes", "fase": "INICIO"}
  {"id": "h1", "herramienta": "sedes_listar", "etiqueta": "Consultando sedes", "fase": "FIN", "ok": true}
  ```
  `id` une el `INICIO` con su `FIN` dentro del turno; `ok` solo viene en `FIN`. Nunca lleva argumentos ni
  resultados (ni documentos, ni nombres, ni ids de registros). Mostrar `etiqueta` tal cual; `herramienta` es
  el código del catálogo (estable, sirve para iconos). Un `FIN` con `ok: false` no es un error del turno: el
  modelo suele reintentar o explicar; el resultado final llega en `respuesta`.
- `event: respuesta` → la misma `Respuesta` del endpoint síncrono. Cierra el flujo.
- `event: error` → `{"status": 429, "mensaje": "…"}` con el estado HTTP que habría tenido. Cierra el flujo.

El front debe ignorar eventos que no conozca (pueden aparecer otros en el futuro).

**Texto parcial: no se emite.** El texto del modelo no se transmite por fragmentos aunque el proveedor lo
permita: antes de llegar a la persona pasa entero por la salida segura (quita documentos, correos y
teléfonos), por la revisión de afirmaciones (que puede devolvérselo al modelo para rehacerlo) y por la
traducción de seudónimos (`Persona_7` → nombre real, que no se puede hacer sobre un fragmento cortado). El
texto llega completo en `respuesta`; mientras tanto, `estado` y `herramienta` dan el progreso.

Los errores previos al turno (sin sesión, texto vacío o demasiado largo) responden como un HTTP normal.

## Cancelar un turno

`POST /conversaciones/{id}/cancelar` corta el turno en curso de esa conversación, sea síncrono o por
streaming, y **libera en el acto** el turno del usuario (puede escribir otra vez sin esperar el `409`).

- Responde `200 {"cancelado": true}` si había un turno en marcha en esa conversación, `{"cancelado": false}`
  si no (ya terminó, o el turno en curso es de otra conversación). `404` si la conversación no es tuya.
- Si el turno estaba esperando al modelo, se interrumpe esa llamada; si estaba entre pasos, se corta antes
  del siguiente. Lo que ya se hizo no se deshace, pero un turno nunca escribe: las escrituras solo ocurren al
  confirmar una acción.
- El turno cortado termina con `Respuesta` `{"tipo": "RESPUESTA", "texto": "Cancelaste la petición."}`, que
  queda en el historial. Por streaming llega como `event: respuesta` (si la conexión sigue abierta); el
  síncrono responde con esa misma `Respuesta`.
- **Cerrar la conexión del streaming también cancela** el turno (el servidor lo detecta al fallar un envío o
  al cerrarse el flujo). No hace falta llamar a `/cancelar` si se aborta el `fetch`, aunque llamarlo es lo
  más rápido y seguro para liberar el turno.

## Historial (`GET /conversaciones/{id}`)

```json
{ "conversacion": {"id": "uuid", "titulo": "…", "estado": "ACTIVA", "ultimoMensajeAt": "…", "createdAt": "…"},
  "mensajes": [
    {"id": 1, "secuencia": 1, "rol": "USER", "texto": "cambia el cargo de Ana", "createdAt": "…"},
    {"id": 2, "secuencia": 2, "rol": "ASSISTANT", "texto": "…", "tipoRespuesta": "CONFIRMACION", "createdAt": "…",
     "respuesta": { "tipo": "CONFIRMACION", "texto": "…",
                    "accionPendiente": {"id": "uuid", "resumen": "…", "expira": "…", "estado": "PENDIENTE"} }}
  ] }
```

- Cada mensaje `ASSISTANT` trae `respuesta` (nuevo): la misma `Respuesta` del endpoint de mensajes, con
  `faltantes`, `accionPendiente`, `acciones` y `datos` según el tipo, para volver a pintar la conversación
  igual que en vivo. Los campos de siempre (`texto`, `tipoRespuesta`) siguen viniendo.
- `accionPendiente.estado` es el **estado actual**: `PENDIENTE` (vigente: mostrar Confirmar / Cancelar, que
  funcionan igual que en vivo), `EJECUTADA`, `FALLIDA`, `DESCARTADA` o `EXPIRADA` (mostrar el resumen sin
  botones). Una `PENDIENTE` vencida se informa ya como `EXPIRADA`.
- Mensajes guardados antes de este cambio traen una `respuesta` reducida (`tipo`, `texto` y `acciones` si las
  hubo): sin `faltantes`, `datos` ni `accionPendiente`.
- `respuesta` pasa por la misma traducción de seudónimos que `texto` (24 h de vida).
- En la respuesta en vivo, `accionPendiente.estado` siempre es `PENDIENTE`.

## Sugerencias (`GET /sugerencias?ruta=`)

`ruta` es la ruta actual del front (con o sin query, máx. 1000 caracteres). Responde:

```json
{ "pantalla": {"codigo": "planeador", "nombre": "Planeador", "menu": "PLANEADOR", "url": "/app/planeador/actividades"},
  "sugerencias": [
    {"texto": "¿Qué actividades tengo esta semana?", "tipo": "CONSULTA"},
    {"texto": "Crea una actividad evaluativa para mi grupo", "tipo": "ACCION"},
    {"texto": "¿Qué puedo hacer desde el asistente?", "tipo": "AYUDA"}
  ],
  "capacidades": {"consultar": true, "proponerAcciones": true, "estadisticas": true, "navegar": true,
                  "rellenarFormularios": true, "modulos": ["Funcionarios", "Planeador"]} }
```

- `pantalla`: la pantalla del registro cuya URL es el prefijo más largo de `ruta`; no viene si ninguna
  coincide (entonces solo hay sugerencias generales).
- `sugerencias` (máx. 6): primero las de la pantalla, después las generales. Están filtradas con el mismo
  criterio que un turno: menús del usuario, roles y solo lectura. `ACCION` solo aparece si puede preparar
  escrituras en ese menú; `CONSULTA` si tiene alguna lectura de ese menú; `NAVEGACION` si ve alguna pantalla;
  `AYUDA` siempre. El `texto` está listo para enviarse como mensaje tal cual.
- `capacidades`: resumen para la bienvenida del asistente. `modulos` son los nombres de las pantallas donde
  tiene herramientas de datos.
- Es ayuda de UX: no autoriza nada. Pedir algo fuera de las sugerencias sigue funcionando igual.


## Errores

`{"mensaje": "…"}` con: `400` mensaje no válido, `403` sesión sin identidad, `404` conversación o acción
que no existe o no es tuya, `409` conversación archivada o acción ya resuelta o alterada, `410` acción
caducada, `429` demasiados mensajes por minuto (con `Retry-After`), `503`/`504` proveedor de IA no
disponible o lento.
