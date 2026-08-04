# cdc-sync (consolidated into SSO)

Sub-proyecto Maven que replica **PostgreSQL → ClickHouse (audit) + Oracle (mirror legacy)** vía Debezium + RabbitMQ.

Esta carpeta antes vivía en `db-migrations/cdc-sync/` (repositorio hermano). Como parte de la unificación de stacks, el código fuente de `cdc-common`, `cdc-capture` y `cdc-worker` se consolidó bajo este árbol; las migraciones V22..V26 viven en `postgres/migrations/` (top-level) y se aplican por el `flyway` principal; los init scripts de ClickHouse y las definitions de RabbitMQ están en `docker/clickhouse/` y `docker/rabbitmq/` (top-level).

## Estructura

```
cdc-sync/
├── pom.xml                # parent Maven (Spring Boot 3.3.5 / Java 25)
├── cdc-common/            # DTOs, transformadores, ColumnTypeRegistry
├── cdc-capture/           # Debezium embedded engine → AMQP
└── cdc-worker/            # AMQP consumer → ClickHouse + Oracle

postgres/migrations/                # mismas migraciones que el flyway principal
├── V1..V19__*.sql                  # SSO schema (groups/microservice/...)
├── V22__academic-schema.sql        # academic_test schema + 147 tables
├── V23__schema.sql                 # schema-level DDL supplement
├── V24__publication.sql            # cdc_pub publication
├── V25__replica-identity.sql       # REPLICA IDENTITY FULL on all tables
└── V26__context-emitter.sql        # trg_audit_ctx trigger

docker/
├── rabbitmq/              # definitions.json + rabbitmq.conf (cdc user + cdc.events)
└── clickhouse/            # audit_log schema + typed JSON projection
```

## Servicios compartidos con SSO

Los servicios CDC **ya no levantan su propio Postgres / RabbitMQ / Flyway**. Reusan los servicios del SSO:

| Servicio CDC | Usa |
|--------------|-----|
| `cdc-capture` | `postgres` (con WAL logical, profile `local-only`), `rabbitmq` (user `cdc` via `definitions.json`), `flyway` (V22..V26) |
| `cdc-worker` | `rabbitmq` (cola `cdc.events`), `cdc-clickhouse` (audit) |
| `cdc-clickhouse` | (sólo `clickhouse-server` con su init SQL) |

El `postgres` ya viene configurado con `wal_level=logical` (debezium/postgres:16-alpine para soportar CDC). El `rabbitmq` monta `docker/rabbitmq/definitions.json` vía `rabbitmq.conf`, declarando el usuario `cdc` y el exchange `cdc.events`. El `flyway` aplica V1..V19 + V22..V26 en una sola corrida.

## Por qué NO es un módulo del parent SSO

El parent del SSO (`com.co.eurekatic:sso-parent`) corre **Spring Boot 4.0.7 / Java 25**. Los módulos CDC fueron validados sobre **Spring Boot 3.3.5 / Java 25** (ver `cdc-sync/pom.xml`). Mezclarlos en un mismo reactor Maven forzaría una actualización mayor de Debezium + ojdbc11 + clickhouse-jdbc, lo que está fuera del scope de la unificación.

Decisión: el sub-proyecto `cdc-sync/` mantiene su propio root pom (Spring Boot 3.3.5). En CI se compila por separado:

```bash
cd cdc-sync
mvn -pl cdc-common,cdc-capture,cdc-worker -am package -DskipTests
```

## Configuración en docker-compose

Levantar con:

```bash
docker compose --profile local-only --profile cdc-sync up -d
```

Servicios:

| Servicio | Puerto | Imagen / build |
|----------|--------|----------------|
| `postgres` (shared) | ${POSTGRES_PORT:-5432} | `debezium/postgres:16-alpine` (WAL logical) |
| `rabbitmq` (shared) | ${RABBITMQ_PORT:-5672} / 15672 | `rabbitmq:3.13.7-management` |
| `flyway` (shared) | (one-shot) | `flyway/flyway:11-alpine` — V1..V26 |
| `cdc-clickhouse` | ${CDC_CLICKHOUSE_HTTP_PORT:-58123} / ${CDC_CLICKHOUSE_NATIVE_PORT:-59000} | `clickhouse/clickhouse-server:24.8-alpine` |
| `cdc-capture` | ${CDC_CAPTURE_PORT:-58081} | build `./cdc-sync/cdc-capture/Dockerfile` |
| `cdc-worker` | ${CDC_WORKER_PORT:-58082} | build `./cdc-sync/cdc-worker/Dockerfile` |

**Schema bootstrap**: `postgres` arranca vacío. `flyway` aplica V1..V19 + V22..V26. `cdc-capture` depende de `flyway` como `service_completed_successfully` antes de iniciar Debezium.

## Environment variables

| Variable | Default | Descripción |
|----------|---------|-------------|
| `POSTGRES_DB` | (from .env) | DB local (default `sso`, hospeda ambos schemas) |
| `POSTGRES_USER` | (from .env) | Usuario local |
| `POSTGRES_PASSWORD` | (from .env) | Password local |
| `FLYWAY_URL` | `${DB_URL}/${DB_NAME}` | Override a `jdbc:postgresql://postgres:5432/${POSTGRES_DB}` para CDC |
| `RABBITMQ_USER` | (from .env) | Usuario SSO broker |
| `RABBITMQ_PASS` | (from .env) | Password SSO broker |
| `CDC_AMQP_USER` | `cdc` | Usuario CDC (declarado en `docker/rabbitmq/definitions.json`) |
| `CDC_AMQP_PASSWORD` | `demopass` | Password CDC |
| `CDC_CLICKHOUSE_USER` | `default` | Usuario ClickHouse |
| `CDC_CLICKHOUSE_PASSWORD` | `demopass` | Password ClickHouse |
| `CDC_CLICKHOUSE_DB` | `auditoria` | DB ClickHouse |
| `CDC_DEST_CLICKHOUSE` | `true` | Toggle destino audit |
| `CDC_DEST_ORACLE` | `true` | Toggle destino mirror Oracle |
| `CDC_WORKER_CONCURRENCY_MIN` | `1` | Concurrency scope |
| `CDC_WORKER_CONCURRENCY_MAX` | `1` | Concurrency scope |
| `CDC_CAPTURE_PORT` | `58081` | Actuator port |
| `CDC_WORKER_PORT` | `58082` | Actuator port |
| `CDC_OFFSETS_DIR` | `/var/cdc-capture/offsets` | Directorio del slot offset |

## Volúmenes

- `sso-postgres-data` — datos del PG source (compartido con SSO)
- `sso-rabbitmq-data` — mnesia del broker (compartido con SSO)
- `cdc-sync-clickhouse-data` — datos del audit
- `cdc-sync-cdc-capture-offsets` — offsets.dat del slot

## Oracle

El servicio `cdc-oracle` NO está incluido en este compose. Su Dockerfile vive en un repositorio hermano (`oracle-db/`). Para activarlo, añadir el bloque de `cdc-oracle` desde el `docker-compose.yml` original de `db-migrations/cdc-sync` y ajustar la `build.context` a la ruta correcta.

## Troubleshooting

(ver `/db-migrations/cdc-sync/README.md` original — la operativa es idéntica, sólo cambia la ruta del repo.)
