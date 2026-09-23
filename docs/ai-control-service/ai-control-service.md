# ai-control-service

Endpoints de IA del ecosistema. Hoy tiene uno por cada resumen de observaciones de preescolar. Los dos reemplazan la concatenación que hacían `fn_estudiante_periodo_observacion_generar` (V332) y `fn_estudiante_final_observacion` (V435) por un informe redactado por un modelo de lenguaje, y lo guardan.

| | |
|---|---|
| Puerto | 8088 (sin publicar; se entra por el gateway) |
| Ruta en el gateway | `/api/ai/**` → `lb://ai-control-service`, `StripPrefix=1` |
| Stack | Spring Boot 4.1, Spring AI 2.0.1 (`spring-ai-starter-model-openai`), Resilience4j, Redis |
| Base de datos | Ninguna. Lee y guarda por query-service con el JWT del usuario |

## Flujo de `POST /api/ai/observaciones/periodo`

1. **Fuentes.** Llama a `POST /informes/observacion/fuentes` (V486), que usa el gate `INFORMES/VER`. Devuelve una fila por observación del docente, el primer nombre del estudiante y el estado del resumen ya guardado.
2. **Guarda contra sobrescritura.** Si el texto guardado está `MODIFICADA` y el cuerpo no trae `SOBRESCRIBIR=true`, responde **409** sin llamar al modelo.
3. **Anonimiza.** El nombre del estudiante se reemplaza por `[ESTUDIANTE]`, también dentro de las observaciones. Al proveedor no le llega ningún identificador.
4. **Cache.** La clave es el SHA-256 de las fuentes, el modelo, la calibración y `AI_PROMPT_VERSION`. Si las observaciones no cambiaron, se reutiliza el texto sin llamar al proveedor.
5. **Modelo.** El prompt de sistema está en `prompts/system-periodo.st` y la salida es estructurada (`ResumenEstructurado`). `ResumenRenderer` la convierte en texto plano. Si el JSON viene mal formado, se reintenta una vez; si vuelve a fallar, responde 502.
6. **Guarda.** Llama a `POST /informes/observacion/guardar` (gate `INFORMES/EDITAR`) con `OBSERVACION = OBSERVACION_IA` y `OBSERVACIONES_ORIGEN`. El texto nace `APROBADA` y pasa a `MODIFICADA` cuando el docente lo edita.

`/anio` sigue el mismo flujo con `/informes/observacion/final/fuentes` y `/final/guardar`. Parte de los resúmenes de periodo ya guardados (`PERIODOS_ORIGEN`).

## Errores

| Status | Cuándo |
|---|---|
| 400 / 403 / 404 | Los devuelve query-service: sin observaciones o periodo de otro año; sin permiso o fuera de alcance; matrícula inexistente |
| 409 | El texto guardado fue modificado por el docente y no se envió `SOBRESCRIBIR` |
| 429 | Se agotó el cupo por minuto (`AI_RATE_LIMIT_PER_MIN`) o la concurrencia (`AI_MAX_CONCURRENT`). Trae `Retry-After` |
| 502 | El proveedor devolvió un error, o el modelo no produjo un JSON válido en 2 intentos |
| 503 | Circuito abierto: el proveedor viene fallando y no se le llama durante `AI_CIRCUIT_OPEN_WAIT` |

## Configuración

Todas las variables están en `.env.example`, sección `ai-control-service`. Las del proveedor pasan a `spring.ai.openai.*`:

| Variable | Default | Nota |
|---|---|---|
| `AI_BASE_URL` | `https://integrate.api.nvidia.com/v1` | El SDK de Spring AI 2 necesita el `/v1`, aunque la doc de Spring AI sobre NVIDIA lo omite |
| `AI_API_KEY` | vacía | `nvapi-...`, en build.nvidia.com → abrir el modelo → *Get API Key* |
| `AI_MODEL` | `nvidia/nemotron-3.5-lightning-30b-a3b` | Id `publisher/modelo` del catálogo de build.nvidia.com. Ver *Elección del modelo* |
| `AI_MAX_TOKENS` | 1500 | NVIDIA lo exige |
| `AI_TEMPERATURE` / `AI_TOP_P` | 0.6 / 0.95 | NVIDIA recomienda 1.0 / 0.95; se baja la temperatura para que el tono y el JSON salgan estables entre estudiantes |
| `AI_EXTRA_BODY_JSON` | `{"chat_template_kwargs":{"enable_thinking":false}}` | Va como JSON para que los booleanos lleguen como booleanos. Poner `{}` con modelos que no lo entiendan |
| `AI_TIMEOUT` / `AI_MAX_RETRIES` | 60s / 1 | Los aplica el SDK de OpenAI. `spring.ai.retry.*` ya no afecta a este starter |
| `AI_PROMPT_VERSION` | v1 | Subirla al editar un prompt invalida la cache |
| `AI_CACHE_TTL` | 7d | `0s` la desactiva |

## Elección del modelo

La elección se hizo sobre el catálogo *preview* de build.nvidia.com (endpoints gratuitos) en septiembre de 2026. Kimi K2.5 ya no está en esa lista. La tarea es corta y no necesita razonar: consolidar entre 5 y 40 observaciones en unas 250 palabras de español formal, con salida JSON. Por eso pesa más la velocidad que la capacidad bruta.

| Modelo | Activos | Por qué sí o no |
|---|---|---|
| **`nvidia/nemotron-3.5-lightning-30b-a3b`** (elegido) | 3B de 30B | El más rápido de los generalistas: NVIDIA declara hasta 4x la velocidad de salida de modelos de su tamaño. Español soportado oficialmente y salida estructurada soportada. Su razonamiento viene **encendido** y se apaga con `enable_thinking: false` |
| `deepseek-ai/deepseek-v4.1-flash` | 8B prefill, 16B decode, de 552B | Más conocimiento y mejor redacción previsible, pero varias veces más cómputo por token. La ficha no documenta cómo apagar el razonamiento, solo cómo graduarlo (`reasoning_effort` de 1 a 100). Es la alternativa si la redacción de Nemotron no convence |
| `google/gemma-4-31b-it` | 31B denso | Muy buen multilingüe, pero denso (más lento) y su ficha dice que la salida estructurada **no** está soportada |
| `glm-5-3-flash` | 18B de 320B | Multimodal; más pesado que Nemotron sin ventaja para texto corto |
| `gpt-oss-20b` | MoE pequeño | Orientado a razonamiento matemático; el español no es su fuerte |

Para cambiar a DeepSeek: `AI_MODEL=deepseek-ai/deepseek-v4.1-flash` y `AI_EXTRA_BODY_JSON={}`, o `{"reasoning_effort":1}` si el endpoint lo acepta. No hace falta tocar `AI_PROMPT_VERSION`: la clave de cache ya incluye el modelo y su calibración.

**Cambiar de proveedor:** cualquier API compatible con OpenAI (vLLM, Ollama, OpenRouter, OpenAI) funciona cambiando solo `AI_BASE_URL`, `AI_API_KEY` y `AI_MODEL`. Si el modelo no entiende el `chat_template_kwargs`, poner `AI_EXTRA_BODY_JSON={}`.

## Privacidad

Las observaciones son de menores y el proveedor es externo.

- Al modelo no se le envía ningún nombre ni identificador (`Anonimizador`).
- `spring.ai.chat.observations.log-prompt` y `log-completion` están apagados.
- Los logs del servicio no escriben el contenido de las respuestas.
- La cache guarda el texto con el marcador, nunca con el nombre.

## Pruebas

- `mvn -pl ai-control-service -am verify`: los tests unitarios, más `ObservacionEndpointTest`, que levanta el contexto completo contra un `HttpServer` local que imita a NVIDIA y a query-service. No gasta cuota ni necesita secretos.
- Colección Postman [observaciones-ia.postman_collection.json](observaciones-ia.postman_collection.json): cubre el flujo completo contra el entorno (generar, 409 tras editar, `SOBRESCRIBIR`, año, y limpieza al final).
