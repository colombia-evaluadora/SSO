# notification-service

Multichannel notification consumer: SMS / email / push. Reads from RabbitMQ,
persists to Postgres with idempotency, routes to one of N providers per
channel with circuit breakers and failover.

```
┌──────────────┐    ┌────────────────────────────────┐    ┌────────────┐
│  producers   │    │      notifications (topic)     │    │  providers │
│  (sso-admin) │───▶│  sms ──▶ notif.sms            │───▶│  Twilio    │
│              │    │  email ─▶ notif.email         │    │  SMTP-Brevo│
│              │    │  push ─▶ notif.push  (TTL 5m) │    │  FCM       │
└──────────────┘    └────────────────────────────────┘    │  + fakes   │
                                                          └────────────┘
                              │
                              ▼
                       ┌────────────────┐
                       │ notification_log│ + provider_config (Postgres)
                       └────────────────┘
```

## Quick reference

| What                | Where                                       |
|---------------------|---------------------------------------------|
| Entry point         | `NotificationServiceApplication.java`       |
| Config              | `src/main/resources/application.yml`        |
| Domain records      | `domain/`                                   |
| Consumers (queues)  | `consumer/NotificationConsumers.java`       |
| Processor (5 steps) | `service/NotificationProcessor.java`        |
| Orchestrators       | `sender/{Sms,Email,Push}Sender.java`        |
| Providers           | `provider/{sms,email,push,fake}/*.java`     |
| Registry / selector | `provider/ProviderRegistry.java`            |
| Resilience4j        | `config/Resilience4jConfig.java`            |
| Templates           | `src/main/resources/templates/{email,sms,push}/` |
| Flyway              | `src/main/resources/db/migration/V1__init.sql` |
| Provider actuator   | `web/ProvidersEndpoint.java`                |

## Versions

This module pins no extra dependency versions; everything
inherits from the parent BOM (`com.co.eurekatic:sso-parent`):
Spring Boot 4.0.7, Spring Cloud 2025.1.2, JDK 25,
PostgreSQL JDBC 42.7.4, Flyway 11.14.1 (split into
`flyway-core` + `flyway-database-postgresql`), Resilience4j
2.2.0 (programmatic only — no starter), Twilio 10.9.2,
Firebase Admin 9.9.0, Testcontainers 1.21.4.

## Running locally

The service runs against the same Postgres + Rabbit stack
the rest of the project uses. Start it via:

```bash
docker compose up -d postgres rabbitmq eurekaserver notification-service
```

Once it's up:

```bash
# health
curl -fsS http://localhost:8085/actuator/health

# live provider roster
curl -s http://localhost:8085/actuator/providers | jq

# reload provider_config without restart
curl -X POST http://localhost:8085/actuator/providers/refresh
```

Without env vars set for any real provider, every channel's
roster collapses to the matching fake (`fake-sms` /
`fake-email` / `fake-push`), and delivery just logs at INFO.

## Publishing a test message

The simplest way is via the RabbitMQ HTTP API (management
plugin is on `:15672`):

```bash
curl -u guest:guest -X POST \
  http://localhost:15672/api/exchanges/%2F/notifications/publish \
  -H 'Content-Type: application/json' \
  -d '{
    "properties": {"content_type":"application/json"},
    "routing_key": "email",
    "payload": "{\"notificationId\":\"11111111-1111-1111-1111-111111111111\",\"channel\":\"EMAIL\",\"recipient\":{\"userId\":\"u-1\",\"address\":\"ada@example.com\"},\"templateId\":\"welcome\",\"payload\":{\"displayName\":\"Ada\",\"loginLink\":\"https://app.example.com/login\",\"notificationId\":\"11111111-1111-1111-1111-111111111111\"},\"metadata\":{\"source\":\"manual\",\"correlationId\":\"abc-123\",\"timestamp\":\"2026-07-07T12:00:00Z\"}}",
    "payload_encoding": "string"
  }'
```

Confirm in Postgres:

```bash
docker exec -it sso-postgres psql -U sso -d sso \
  -c "SELECT notification_id, channel, status, provider FROM notification_log ORDER BY created_at DESC LIMIT 5;"
```

## Provider configuration

Each row in `provider_config` carries:

| Column      | Meaning                                                              |
|-------------|----------------------------------------------------------------------|
| channel     | `SMS` / `EMAIL` / `PUSH`                                             |
| provider_key| The Spring bean name; orchestrator key + circuit-breaker key        |
| impl        | `SMTP` / `RESEND` / `EMAILJS` / `TWILIO` / `VONAGE` / `FCM` / `FAKE` |
| enabled     | Boolean — registry skips `false` rows                                |
| priority    | Ascending. Lower wins for `PRIORITY` policy                          |
| weight      | Used by `WEIGHTED` policy                                            |
| policy      | `PRIORITY` or `WEIGHTED`                                             |
| settings    | `jsonb` — provider-specific (e.g. SMTP host/port/credentials_env)    |

`settings` keys always carry the env-var **names** (with
the suffix `_env`), never the secrets themselves — credentials
stay in the environment.

### Required env vars per provider

| Provider     | Env vars                                                                          |
|--------------|-----------------------------------------------------------------------------------|
| twilio       | `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_FROM_NUMBER`                   |
| vonage       | (stub) — see `provider/sms/VonageSmsProvider.java`                                |
| smtp-brevo   | `SMTP_BREVO_USER`, `SMTP_BREVO_PASS`                                              |
| smtp-gmail   | `SMTP_GMAIL_USER`, `SMTP_GMAIL_PASS`                                              |
| resend       | `RESEND_API_KEY`                                                                  |
| emailjs      | `EMAILJS_SERVICE_ID`, `EMAILJS_PUBLIC_KEY`, `EMAILJS_PRIVATE_KEY`                 |
| fcm          | `GOOGLE_APPLICATION_CREDENTIALS` (path to a service-account JSON key file)        |

If any required env var is missing at startup, the row is
excluded from the active roster with a single WARN — no
exception, no crash. This is what makes "scaffold and
fill in credentials later" a viable workflow.

### Enabling a provider without restart

```sql
UPDATE provider_config SET enabled = TRUE WHERE provider_key = 'twilio';
```

```bash
curl -X POST http://localhost:8085/actuator/providers/refresh
```

## RabbitMQ topology

Declared by `config/RabbitTopologyConfig.java`. Default
names match the spec; the contract with producers (e.g.
sso-admin) is pinned.

| Object                | Name                  | Notes                              |
|-----------------------|-----------------------|------------------------------------|
| Topic exchange        | `notifications`       | Routing keys: `sms` / `email` / `push` |
| Direct exchange (DLX) | `notifications.dlx`   | Routing keys: `<channel>.dlq`      |
| Queue                 | `notif.sms`           | DLX → `notifications.dlx`          |
| Queue                 | `notif.email`         | DLX → `notifications.dlx`          |
| Queue                 | `notif.push`          | DLX + `x-message-ttl = 300_000` (5 min) |
| Queue (DLQ)           | `notif.sms.dlq`       |                                    |
| Queue (DLQ)           | `notif.email.dlq`     |                                    |
| Queue (DLQ)           | `notif.push.dlq`      |                                    |

Listener concurrency: SMS 2-5, EMAIL 3-10, PUSH 5-20.
Retries: 4 attempts, exponential 2s × 3, no requeue after
exhaustion (`default-requeue-rejected: false`).

## Circuit breakers

`config/Resilience4jConfig.java` builds the
`CircuitBreakerRegistry` programmatically (no starter).
Defaults bound to `notif.circuit-breaker.*`:

| Setting                          | Default |
|----------------------------------|---------|
| sliding-window-type              | COUNT_BASED |
| sliding-window-size              | 10      |
| minimum-number-of-calls          | 5       |
| failure-rate-threshold           | 50%     |
| slow-call-rate-threshold         | 100%    |
| slow-call-duration-threshold-ms  | 5000    |
| wait-duration-in-open-state-ms   | 30000   |
| permitted-number-of-calls-in-half-open-state | 3 |
| automatic-transition-from-open-to-half-open-enabled | true |

Per-provider breakers are keyed `<channel>:<providerKey>`
(e.g. `email:smtp-brevo`).

## Templates

Email uses Thymeleaf — `.html` files under
`templates/email/`. SMS / push use plain `.txt` files under
`templates/sms/` and `templates/push/` with `{{var}}`
substitution (no Thymeleaf needed).

Seeded templates:

- `email/welcome.html`
- `email/password-reset.html`
- `sms/password-reset.txt`
- `push/password-reset.txt`

Add a new template by dropping the file in the right
directory and referencing it from the message's
`templateId`. Missing templates → `TemplateNotFoundException`
→ straight to DLQ (no retry).

## Tests

| Suite                | Type                | Coverage                                    |
|----------------------|---------------------|---------------------------------------------|
| `NotificationProcessorTest` | Unit (Mockito) | 5-step pipeline, all error paths             |
| `ProviderSelectorTest`      | Unit (pure)    | PRIORITY / WEIGHTED ordering                 |
| `NotificationServiceIntegrationTest` | Testcontainers (Postgres + Rabbit) | 6 end-to-end scenarios |

### Unit tests

```bash
mvn -pl notification-service -am test \
    -Dtest='NotificationProcessorTest,ProviderSelectorTest'
```

### Integration tests

Requires Docker. Testcontainers will spin up a Postgres
16 + RabbitMQ 3.13 pair as side-cars.

```bash
mvn -pl notification-service -am verify \
    -Dtest='NotificationServiceIntegrationTest'
```

The integration suite covers:

1. **Happy path** — publish email, log → `SENT` with
   `provider = fake-email`.
2. **Idempotency** — same `notificationId` twice → first
   row goes `SENT`, second becomes `DUPLICATE`.
3. **All providers fail** — only `failing-fake` enabled,
   retry budget exhausted → log `FAILED`.
4. **Invalid payload** — missing `templateId` → DLQ,
   no log row created.
5. **Failover** — `failing-fake` (priority 1) throws,
   `fake-email` (priority 2) succeeds → log `SENT` with
   `provider = fake-email`.
6. **Refresh without restart** — first publish goes
   `FAILED`, then `UPDATE provider_config` + refresh +
   republish → `SENT`.

> **Colima note**: Testcontainers 1.21.x has a known
> incompatibility with Colima's docker socket path
> (`/Users/<user>/.colima/default/docker.sock`). On Colima
> the `ContainerLaunchException` you see is "mkdir …
> operation not supported" — the test code is fine, the
> socket path isn't. Workarounds:
>
> - Run against Docker Desktop, or
> - Set `TESTCONTAINERS_HOST_OVERRIDE=unix:///.../docker.sock`
>   **and** symlink `/var/run/docker.sock` to the colima
>   socket (`sudo ln -sf ~/.colima/default/docker.sock
>   /var/run/docker.sock`), or
> - Skip the integration suite (`-Dtest=!NotificationServiceIntegrationTest`).

## Health & metrics

| Endpoint                        | Notes                                  |
|---------------------------------|----------------------------------------|
| `GET /actuator/health`          | Liveness + readiness                   |
| `GET /actuator/info`            | App metadata                           |
| `GET /actuator/prometheus`      | Scrape target (Micrometer)             |
| `GET /actuator/providers`       | Live provider roster + breaker state   |
| `POST /actuator/providers/refresh` | Reload `provider_config` from DB    |

## Project conventions honoured

- **Single flat `application.yml`** — no profiles (dev/prod
  split is by env vars only).
- **Resilience4j programmatic** — no `resilience4j-spring-boot4`
  starter (doesn't exist on Maven Central).
- **Hikari 5/3/5s**, `ddl-auto: validate`, `open-in-view: false`,
  no Hibernate dialect (auto-detected) — matches sso-admin,
  auth-center, etc.
- **Multi-stage Dockerfile** — `maven:3.9-eclipse-temurin-25`
  build, `eclipse-temurin:25-jre-jammy` runtime, non-root
  user. Same shape as the rest of the project's Dockerfiles.
- **Eureka `prefer-ip-address: true`** — required in Spring
  Cloud Netflix 5.0.2.
- **All 8 modules now expose Prometheus** — `notification-service`
  was the first, then propagated.