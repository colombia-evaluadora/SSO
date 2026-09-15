# Reglas — Observabilidad (`observability/`)

Alloy, Grafana, Loki, Mimir y Tempo. Complementan el `CLAUDE.md` raíz.

## Skills y agentes

| Trabajo | Usar |
|---|---|
| Cambiar servicios, redes, volúmenes o el orden de arranque | agente `docker-compose-steward` |
| Variables de entorno de telemetría en los servicios Java | skills `java-spring-boot` / `spring-cloud-basics` |
| Consultas o esquemas de ClickHouse (auditoría) | skill `clickhouse-best-practices` |

## Restricciones

- **La exportación OTLP está apagada por defecto y así se queda.** Encenderla es
  una decisión explícita por entorno, nunca el valor por defecto de un servicio
  nuevo: con OTLP activo y sin colector, cada servicio llena los logs de errores
  de conexión.
- **Los `MANAGEMENT_*` tienen que llegar a los servicios provisionados
  dinámicamente.** Los `query-service-<serviceid>` no los hereda del compose: los
  propaga el `provisioner`. Configurar la telemetría solo en el `docker-compose`
  deja fuera justo a los que más ruido hacen.
- **Nada de valores quemados.** Endpoints, puertos, muestreos y credenciales van
  por variable de entorno / `.env`, con su entrada en `.env.example`. Antes de
  añadir una, comprueba que no esté ya duplicada con otro nombre.
- **Un cambio de telemetría no se da por bueno sin mirar el ruido que genera.**
  El criterio no es "exporta", es "exporta y no inunda". Ruido ya identificado y
  pendiente: `MailHealthIndicator`, refrescos periódicos de configuración y doble
  ingesta en Loki.
- **Los nombres de propiedad cambian entre versiones de Spring Boot.** Verifica
  contra la versión que usa el repo (Boot 4.x) en lugar de copiar de ejemplos de
  Boot 2/3: una propiedad mal escrita no falla, simplemente se ignora en silencio.
- **Antes de tocar un servicio del stack**, revisa `depends_on`, healthchecks y
  quién escribe en quién. Grafana sin su datasource arranca igual y falla al
  consultarse, que es mucho más difícil de diagnosticar.

## Al cerrar

Di qué señal cambió (logs / métricas / trazas), qué servicios la emiten ahora y
cuáles no, y cómo se verifica en Grafana. Un cambio de observabilidad que no se
puede comprobar mirando un panel no está terminado.
