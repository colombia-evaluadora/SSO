# Contrato del asistente (ai-control-service) para el front

Base: `/api/ai/agente` (el gateway quita `/api`). Todas las rutas exigen el JWT del usuario en
`Authorization: Bearer …`. Lo que el agente lee o propone escribir pasa por el query-service con ese mismo
token, así que el asistente nunca puede hacer más que la persona desde la pantalla.

## Endpoints

| Método | Ruta | Cuerpo | Respuesta |
|---|---|---|---|
| POST | `/conversaciones` | — | `201 {conversationId}` |
| GET | `/conversaciones?page=0&size=20` | — | conversaciones propias, recientes primero (máx. 50) |
| GET | `/conversaciones/{id}` | — | conversación con sus mensajes |
| PUT | `/conversaciones/{id}/archivar` | — | `204` (no hay borrado) |
| POST | `/conversaciones/{id}/mensajes` | `{texto, contextoUi?}` | `Respuesta` |
| POST | `/conversaciones/{id}/mensajes/stream` | `{texto, contextoUi?}` | eventos SSE (ver abajo) |
| POST | `/acciones/{id}/confirmar` | — | `Respuesta` con el resultado |
| POST | `/acciones/{id}/cancelar` | — | `Respuesta` |

Una conversación o acción de otra persona responde `404`, igual que una que no existe.

Los nombres de personas viajan al proveedor del modelo como seudónimos (`Persona_7`) y el front los recibe
ya con el nombre real. El historial se guarda con seudónimos: `GET /conversaciones/{id}` los traduce mientras
la conversación siga viva (24 h desde el último mensaje); después pueden aparecer como `Persona_N`.

## `contextoUi`: lo que la pantalla le cuenta al asistente

Opcional en cada mensaje. Es **dato**, nunca autoriza nada: el backend lo valida todo.

```json
{
  "ruta": "/app/establecimiento-educativo/funcionarios/crear",
  "filtros": ["sede", "estado"],
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
- Lo mejor es que el componente de formulario genere esta definición. Si una pantalla la escribe a mano,
  se desfasa.

## `Respuesta`

```json
{ "tipo": "RESPUESTA|PREGUNTA|CONFIRMACION|UI|DATOS|BLOQUEADO|SIN_PERMISO",
  "texto": "…",
  "faltantes": [{"campo": "numeroDocumento", "pregunta": "¿Cuál es el documento?", "opciones": []}],
  "accionPendiente": {"id": "uuid", "resumen": "…", "expira": "2026-10-13T15:10:00"},
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
- `event: respuesta` → la misma `Respuesta` del endpoint síncrono. Cierra el flujo.
- `event: error` → `{"status": 429, "mensaje": "…"}` con el estado HTTP que habría tenido. Cierra el flujo.

Los errores previos al turno (sin sesión, texto vacío o demasiado largo) responden como un HTTP normal.

## Errores

`{"mensaje": "…"}` con: `400` mensaje no válido, `403` sesión sin identidad, `404` conversación o acción
que no existe o no es tuya, `409` conversación archivada o acción ya resuelta o alterada, `410` acción
caducada, `429` demasiados mensajes por minuto (con `Retry-After`), `503`/`504` proveedor de IA no
disponible o lento.
