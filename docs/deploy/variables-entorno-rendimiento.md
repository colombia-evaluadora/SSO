# Variables de entorno de rendimiento y resiliencia

Variables que introduce o cambia la rama `perf/auditoria-rendimiento`. Todas tienen un valor por defecto pensado para producción: **un `.env` que no defina ninguna sigue funcionando**. Este documento sirve para decidir cuáles ajustar en cada servidor y con qué criterio.

## Antes de tocar el `.env`

- **El compose solo pasa a cada contenedor las variables que lista en su `environment:`.** No usa `env_file`, así que una variable que no aparece en el bloque del servicio no tiene efecto aunque esté en el `.env`. La columna **`.env`** de cada tabla lo indica:
  - **sí**: basta con definirla en el `.env`.
  - **servicio**: hay que añadirla primero al `environment:` de ese servicio en `docker-compose.yml`.
- **No declares una variable vacía** (`QUERY_TIMEOUT_SECONDS=`). Algunas se pasan como `${VAR:-}`, y Spring recibiría una cadena vacía en lugar de usar su default. Si no quieres cambiar el valor, comenta la línea.
- **Los query-service aprovisionados** (`query-service-eval-col`, `query-service-pigse`, …) no son servicios del compose. Reciben las variables `QUERY_*` marcadas como **provisioner** en las tablas a través del servicio `provisioner`. El cambio solo se aplica cuando el provisioner vuelve a crear el contenedor.

## Timeouts: tienen que respetar este orden

Cada capa corta un poco después que la de abajo, para que el error lo dé la que sabe por qué: la consulta antes que el cliente HTTP, el cliente HTTP antes que el gateway.

```
consulta de pantalla      QUERY_TIMEOUT_SECONDS           15 s
operación larga           QUERY_REPORT_TIMEOUT_SECONDS    170 s   < 180 s de lectura de reporting (REPORTING_REQUEST_TIMEOUT)
red de seguridad en BD    QUERY_DS_STATEMENT_TIMEOUT_MS   185 s   > operación larga
gateway (global)          GATEWAY_RESPONSE_TIMEOUT        180 s   > operación larga
gateway (reportes)        GATEWAY_REPORTING_RESPONSE_TIMEOUT_MS  300 s  > consulta + render del PDF/Excel
```

Si subes una, revisa las de encima.

---

## query-service

| Variable | Default | `.env` | Qué controla | Cuándo cambiarla |
|---|---|---|---|---|
| `QUERY_TIMEOUT_SECONDS` | `15` | sí · provisioner | Tiempo máximo de una consulta de pantalla. Pasado ese tiempo se cancela y responde 504. | Si un listado legítimo tarda más de 15 s: primero revisa su SQL (índices, `pg_stat_statements`). Súbelo solo como medida temporal. |
| `QUERY_REPORT_TIMEOUT_SECONDS` | `170` | sí · provisioner | Tiempo de las operaciones largas: reportes (cabecera de reporting-service) y rutas que casen con `QUERY_LONG_PATH_PATTERN`. | Si una exportación de 50 000 filas no termina. Mantenlo por debajo de 180 s (ver el orden de timeouts). |
| `QUERY_LONG_PATH_PATTERN` | `(?i).*(export\|exportar\|importar\|reporte\|boletin\|bulk\|masivo\|masiva\|lote).*` | sí · provisioner | Expresión regular sobre el `path_template` de la fila que da el timeout largo, sin necesidad de cabecera. | Cuando un endpoint nuevo de operaciones en lote no siga esa nomenclatura. Vacía (comentada no, **vacía**) desactiva el perfil por ruta. |
| `QUERY_MAX_ROWS` | `50001` | sí · provisioner | Tope de filas por consulta. Protege el heap de un `SELECT` sin `LIMIT`. Al alcanzarlo se registra un aviso. | Debe ser mayor que `REPORTING_MAX_ROWS` (50 000), para que reporting detecte el exceso y responda 422. |
| `QUERY_FETCH_SIZE` | `500` | servicio | Filas que el driver trae de Postgres por viaje. | Rara vez. |
| `QUERY_BULKHEAD_MAX_CONCURRENT` | `8` (antes `20`) | sí · provisioner | Consultas simultáneas por dialecto. Nunca supera el pool de Hikari de la instancia: se acota solo. | Súbelo junto con el pool (`QUERY_DS_POOL_SIZE` / `poolSize` del microservicio). |
| `QUERY_BULKHEAD_MAX_WAIT` | `200ms` | sí · provisioner | Espera por un permiso antes de responder 503. Absorbe ráfagas cortas. `0` responde 503 al instante. | Si ves 503 por ráfagas, súbelo a 300-500 ms. No pases de 1 s: retiene hilos. |
| `QUERY_RATE_LIMIT_RPS` | `100` | sí · provisioner | Peticiones por segundo por usuario. Ahora aplica también a la ruta por plantilla. | Si un usuario legítimo recibe 429. Las pruebas de carga con un solo usuario lo necesitan alto. |
| `QUERY_RATE_LIMIT_IDLE_EXPIRY` | `10m` | servicio | Tiempo tras el cual se olvida el limitador de un usuario inactivo. | Rara vez. |
| `QUERY_RATE_LIMIT_MAX_PRINCIPALS` | `100000` | servicio | Usuarios con limitador en memoria a la vez. | Rara vez. |
| `QUERY_CATALOG_CACHE_TTL_SECONDS` | `60` | sí · provisioner | Tiempo que query-service guarda la definición y autorización de un endpoint por usuario, antes de volver a preguntar a sso-admin. **Es también lo que tarda en notarse un cambio de roles.** | Bájalo si los cambios de permisos tienen que verse antes. Un cambio en el catálogo invalida la caché al momento. |
| `QUERY_CATALOG_CACHE_ENABLED` | `true` | servicio | Interruptor de esa caché. | `false` solo para diagnosticar: devuelve una llamada HTTP a sso-admin por petición. |
| `QUERY_CATALOG_CACHE_MAX` | `50000` | servicio | Entradas máximas de esa caché. | Rara vez. |
| `QUERY_DS_CONNECTION_TIMEOUT_MS` | `2000` | sí · provisioner | Espera máxima por una conexión del pool antes de fallar. Antes eran 30 s en las instancias aprovisionadas. | Rara vez: la espera la absorbe el bulkhead. |
| `QUERY_DS_STATEMENT_TIMEOUT_MS` | `185000` | sí · provisioner | `statement_timeout` de Postgres para las conexiones de query-service. Es la red de seguridad del lado servidor. | Mantenlo por encima de `QUERY_REPORT_TIMEOUT_SECONDS`. |
| `QUERY_DS_MINIMUM_IDLE` | `min(4, pool)` | servicio | Conexiones abiertas en reposo. | Bájalo si Postgres (Neon) va justo de conexiones. |
| `QUERY_DS_MAX_LIFETIME_MS` | `1500000` | servicio | Vida máxima de una conexión. Debe ser menor que el límite que imponga el pooler o Neon. | Si el pooler corta conexiones antes de 25 min. |
| `QUERY_DS_KEEPALIVE_TIME_MS` | `120000` | servicio | Cada cuánto se comprueban las conexiones inactivas. | Rara vez. |
| `QUERY_DS_LEAK_DETECTION_MS` | `20000` | servicio | Avisa en el log si una conexión no se devuelve en ese tiempo. | Rara vez. |

## api-gateway

| Variable | Default | `.env` | Qué controla | Cuándo cambiarla |
|---|---|---|---|---|
| `GATEWAY_RESPONSE_TIMEOUT` | `180s` | sí | Timeout global hacia los servicios. Las rutas de query-service lo heredan, porque salen del catálogo sin timeout propio. | Mantenlo por encima de `QUERY_REPORT_TIMEOUT_SECONDS`. |
| `GATEWAY_REPORTING_RESPONSE_TIMEOUT_MS` | `300000` | sí | Timeout de `/api/reportes/**`: consulta más render. | Si un reporte grande corta en el gateway (504) con reporting todavía trabajando. |
| `GATEWAY_AI_RESPONSE_TIMEOUT_MS` | `125000` | sí | Timeout de la ruta de ai-control-service. | Mantenlo por encima de `AI_TIMEOUT`. |
| `GATEWAY_FILE_RESPONSE_TIMEOUT_MS` | `300000` | sí | Timeout de file-service (subidas y descargas grandes). | Si fallan subidas grandes. |
| `GATEWAY_CONNECT_TIMEOUT_MS` | `2000` | servicio | Tiempo para abrir la conexión TCP con un servicio. | Rara vez. |
| `GATEWAY_POOL_MAX_IDLE_TIME` | `30s` | servicio | Tiempo que se reutiliza una conexión inactiva. Evita usar conexiones que el servicio ya cerró. | Rara vez. |
| `GATEWAY_ACTUATOR_EXPOSURE` | `health,info` | servicio | Endpoints de Actuator expuestos en el puerto público. | No añadas `gateway` ni `prometheus`: quedarían accesibles desde fuera. |

## auth-center

| Variable | Default | `.env` | Qué controla | Cuándo cambiarla |
|---|---|---|---|---|
| `AUTH_CENTER_JAVA_OPTS` | `-Xmx512m -XX:G1PeriodicGCInterval=15000 -Xss512k -XX:ReservedCodeCacheSize=64m -XX:MaxDirectMemorySize=64m` | sí | Opciones de la JVM. El contenedor ya no tiene límite de memoria, así que **el tope real es este `-Xmx`**. Sin él, la JVM tomaba el 75 % de la RAM del host. | Sube `-Xmx` (p. ej. a `768m`) si el heap se queda corto en picos de login. |
| `AUTH_CENTER_MALLOC_ARENA_MAX` | `2` | sí | Arenas de memoria de glibc. Con el valor por defecto de glibc, cada hilo puede crear la suya e inflar la RAM fuera del heap. | Rara vez. |
| `SSO_LOGIN_MAX_CONCURRENT` | `0` | sí | Logins que hashean a la vez. `0` = 2 por núcleo, sin pasar de la mitad del heap entre 7 MiB por hash. Los que excedan reciben 429 con `Retry-After`. | Fíjalo si el servidor comparte CPU con muchos servicios y los logins la acaparan. |
| `SSO_LOGIN_ACQUIRE_TIMEOUT_MS` | `200` | sí | Espera por un permiso de login antes del 429. | Rara vez. |
| `SSO_ADMIN_CLIENT_CONNECT_TIMEOUT` | `2s` | servicio | Conexión de auth-center a sso-admin. | Rara vez. |
| `SSO_ADMIN_CLIENT_READ_TIMEOUT` | `5s` | servicio | Lectura de auth-center a sso-admin (antes no tenía límite). | Rara vez. |

## sso-admin

| Variable | Default | `.env` | Qué controla | Cuándo cambiarla |
|---|---|---|---|---|
| `SSO_ADMIN_VIRTUAL_THREADS` | `true` | sí | Hilos virtuales en Tomcat. La espera del alta de microservicios (hasta 45 s) ya no ocupa un hilo de plataforma. | `false` solo si aparece un problema atribuible a los hilos virtuales. |
| `SSO_ADMIN_HTTP_CONNECT_TIMEOUT` | `2s` | servicio | Conexión de sso-admin a auth-center, a query-service y al provisioner. | Rara vez. |
| `SSO_ADMIN_HTTP_READ_TIMEOUT` | `5s` | servicio | Lectura en esas mismas llamadas (antes no tenía límite). | Rara vez. |
| `SSO_ADMIN_PROVISIONER_READ_TIMEOUT` | `60s` | servicio | Lectura de la llamada al provisioner al crear un microservicio. | Si el alta de un query-service falla por timeout con el contenedor arrancando bien. |
| `SSO_ADMIN_EUREKA_READY_TIMEOUT` | `45s` | servicio | Espera a que la instancia nueva aparezca en Eureka. | Si el alta falla porque la instancia tarda más en registrarse. |
| `SSO_ADMIN_EUREKA_POLL_INTERVAL` | `1s` | servicio | Cada cuánto se consulta Eureka durante esa espera. | Rara vez. |

## reporting-service

| Variable | Default | `.env` | Qué controla | Cuándo cambiarla |
|---|---|---|---|---|
| `REPORTING_MAX_CONCURRENT_EXPORTS` | `4` | sí | Exportaciones simultáneas. Las que excedan reciben 429 con `Retry-After: 5`. Protege los 512 MiB del contenedor. | Súbelo solo si subes también la memoria del contenedor. |
| `REPORTING_EXPORT_ACQUIRE_TIMEOUT_MS` | `2000` | servicio | Espera por un hueco de exportación antes del 429. | Rara vez. |
| `REPORTING_TEMPLATE_CACHE_MAX` | `200` | servicio | Plantillas Jasper compiladas en memoria. | Rara vez. |

## notification-service y file-service

| Variable | Default | `.env` | Qué controla |
|---|---|---|---|
| `NOTIFICATION_HTTP_CONNECT_TIMEOUT` | `3s` | servicio | Conexión con los proveedores HTTP de correo (Resend, EmailJS). |
| `NOTIFICATION_HTTP_READ_TIMEOUT` | `10s` | servicio | Lectura con esos proveedores (antes no tenía límite). |
| `FILES_HTTP_CONNECT_TIMEOUT` | `2s` | servicio | Conexión del reenvío de archivos. |
| `FILES_HTTP_READ_TIMEOUT` | `10s` | servicio | Lectura del reenvío de archivos. |

## cdc-sync

| Variable | Default | `.env` | Qué controla | Cuándo cambiarla |
|---|---|---|---|---|
| `CDC_LOG_LEVEL` | `INFO` | sí | Nivel de log de `com.example.cdc` en capture y worker. Antes estaba en DEBUG. | `DEBUG` solo para diagnosticar: puede volcar datos de los cambios. |
| `CDC_WORKER_PREFETCH` | `10` | sí | Mensajes que el worker retiene sin confirmar (antes 100). | Súbelo solo si subes también la concurrencia del worker. |
| `CDC_PUBLISH_CONFIRM_TIMEOUT_MS` | `10000` | servicio | Espera de la confirmación de RabbitMQ antes de dar un lote por publicado. Si vence, el lote se reintenta. | Si hay timeouts de confirmación con RabbitMQ sano. |
| `CDC_HEALTH_SHOW_DETAILS` | `never` | servicio | Detalle del endpoint de salud. | No pongas `always` en servidores. |
| `CDC_HEALTH_HEARTBEAT_MS` | `15000` | servicio | Cada cuánto cdc-capture actualiza su fichero de latido. El healthcheck lo da por caído si no se actualiza en 1 min. | Rara vez. |
| `CDC_HEALTH_FILE` | `/tmp/cdc-health` | **no tocar** | Ruta del fichero de latido. El healthcheck del compose usa esta ruta fija. | No la cambies sin cambiar también el healthcheck. |

## Provisioner (query-service aprovisionados)

| Variable | Default | `.env` | Qué controla | Cuándo cambiarla |
|---|---|---|---|---|
| `PROVISIONER_QUERY_MEM_LIMIT` | `768m` | sí | Límite de memoria de cada query-service que crea el provisioner. Antes no tenía. | Súbelo si una instancia se reinicia por memoria (exit 137). |
| `PROVISIONER_QUERY_MEM_RESERVATION` | `256m` | sí | Reserva blanda de esas instancias. | Rara vez. |
| `PROVISIONER_QUERY_CPUS` | vacío (sin límite) | sí | Núcleos máximos por instancia (p. ej. `1.5`). | Si una instancia acapara la CPU del servidor. |

## Infraestructura y plataforma

| Variable | Default | `.env` | Qué controla | Cuándo cambiarla |
|---|---|---|---|---|
| `JAVA_STOP_GRACE_PERIOD` | `40s` | sí | Tiempo que Docker espera antes de matar un servicio Java al pararlo. Antes eran 10 s, menos que los 30 s del apagado ordenado de Spring. | Súbelo si las peticiones largas se cortan en los despliegues. |
| `DOCKER_LOG_MAX_SIZE` | `20m` | sí | Tamaño máximo de cada fichero de log de un contenedor. | Si los logs necesitan más historia en el host. |
| `DOCKER_LOG_MAX_FILE` | `5` | sí | Ficheros de log rotados por contenedor. | Igual que el anterior. |
| `REDIS_MAXMEMORY` | `200mb` | sí | Memoria máxima de Redis antes de expulsar claves. | Si Redis expulsa claves con frecuencia. Mantenlo por debajo de su `mem_limit` (256m). |
| `REDIS_MAXMEMORY_POLICY` | `volatile-lru` | sí | Qué claves expulsa Redis al llegar al tope. Solo las que tienen TTL, nunca las permanentes. | Rara vez. |
| `EUREKA_RENEWAL_THRESHOLD` | `0.85` (antes `0.33`) | sí | Umbral de autoprotección de Eureka. | Rara vez. |
| `EUREKA_EVICTION_INTERVAL_MS` | `30000` (antes `1000`) | sí | Cada cuánto Eureka expulsa instancias que no renuevan. | Rara vez. |
| `GRAFANA_ANONYMOUS_ENABLED` | `false` | sí | Acceso anónimo a Grafana. Antes estaba activo y con rol Admin. | Actívalo solo en local. |
| `GRAFANA_ANONYMOUS_ROLE` | `Viewer` | sí | Rol del acceso anónimo, si se activa. | No uses `Admin`. |

---

## Variables que ya existían y cambian de comportamiento

| Variable | Antes | Ahora | Qué revisar en cada servidor |
|---|---|---|---|
| `BIND_IP` | por defecto `0.0.0.0` | por defecto `127.0.0.1` | Los puertos internos (Postgres local, Eureka, auth-center, sso-admin, Grafana, ClickHouse, cdc) solo se publican en el propio host. Si algo los consulta desde fuera del servidor, define `BIND_IP=0.0.0.0` a conciencia. El gateway sigue público. |
| `REDIS_PASSWORD` | se pasaba a los clientes, pero Redis no la exigía | si está definida, Redis la exige (`requirepass`) | Si el `.env` tiene un valor, Redis pasa a pedir contraseña: comprueba que todos los servicios la reciben (ya están conectados en el compose). |
| `OTEL_TRACING_SAMPLE_RATE` | no llegaba a los contenedores; se trazaba el 100 % | se pasa a todos los servicios Spring, default `0.1` | Súbelo a `1.0` solo para diagnosticar. |
| `AI_TIMEOUT` | `60s` | `120s` | Mantenlo por debajo de `GATEWAY_AI_RESPONSE_TIMEOUT_MS`. |
| `QUERY_BULKHEAD_MAX_CONCURRENT` (`.env.example`) | `20` | `8` | Si el `.env` del servidor copió el `20` del ejemplo, el bulkhead ya se acota solo al pool, pero conviene actualizarlo. |
| `JWT_PRIVATE_KEY` / `JWT_PUBLIC_KEY` (`.env.example`) | traía un par de claves | vacías, se generan con `./scripts/gen-jwt-keys.sh --env` | Comprueba que **ningún servidor** use el par que estaba en el ejemplo. Si alguno lo usa, rota las claves. |

## Bloque sugerido para el `.env` de un servidor

No hace falta definir nada: los defaults ya son los recomendados. Este bloque solo deja visibles, comentadas, las variables que más probablemente se ajusten:

```dotenv
# --- Rendimiento y resiliencia (ver docs/deploy/variables-entorno-rendimiento.md) ---
# BIND_IP=127.0.0.1
# OTEL_TRACING_SAMPLE_RATE=0.1
# JAVA_STOP_GRACE_PERIOD=40s

# query-service (estáticos y aprovisionados)
# QUERY_TIMEOUT_SECONDS=15
# QUERY_REPORT_TIMEOUT_SECONDS=170
# QUERY_BULKHEAD_MAX_CONCURRENT=8
# QUERY_BULKHEAD_MAX_WAIT=200ms
# QUERY_CATALOG_CACHE_TTL_SECONDS=60

# gateway
# GATEWAY_RESPONSE_TIMEOUT=180s
# GATEWAY_REPORTING_RESPONSE_TIMEOUT_MS=300000

# auth-center
# AUTH_CENTER_JAVA_OPTS=-Xmx512m -XX:G1PeriodicGCInterval=15000 -Xss512k -XX:ReservedCodeCacheSize=64m -XX:MaxDirectMemorySize=64m
# SSO_LOGIN_MAX_CONCURRENT=0

# reporting
# REPORTING_MAX_CONCURRENT_EXPORTS=4

# provisioner
# PROVISIONER_QUERY_MEM_LIMIT=768m

# redis
# REDIS_MAXMEMORY=200mb
```
