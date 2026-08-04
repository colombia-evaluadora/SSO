# docker/rabbitmq/ — shared RabbitMQ broker config

These three files plus `docker-compose.yml` define the SSO broker config.
The broker is shared between two consumers:

- **SSO apps** (`sso-admin`, `notification-service`) — auth as the
  default user (set via `RABBITMQ_DEFAULT_USER` env var, normally
  `SSO_MQ`). They create their own exchanges/queues programmatically.

- **CDC apps** (`cdc-capture`, `cdc-worker`) — auth as the CDC user
  declared in `definitions.json.template`. They produce/consume on
  `cdc.events` / `cdc.worker`.

## Files

### `rabbitmq.conf`
One line:
```
load_definitions = /etc/rabbitmq/definitions.json
```
Tells the broker to load entity definitions (users, vhosts, exchanges,
queues, bindings) from the JSON file at boot. Without this line the
broker reads `definitions.json` but never applies it.

### `definitions.json.template`
Template for the broker's definitions.json. The two CDC-templated
placeholders are:

| Placeholder | Source (.env) | Description |
|-------------|---------------|-------------|
| `${CDC_AMQP_USER}` | `CDC_AMQP_USER` | Username of the CDC AMQP account |
| `${CDC_AMQP_PASSWORD}` | `CDC_AMQP_PASSWORD` | Password of the CDC AMQP account |

**Source of truth**: `.env`. To rotate the CDC user, edit
`CDC_AMQP_USER` / `CDC_AMQP_PASSWORD` in `.env` and restart the
rabbitmq container:

```bash
docker compose restart rabbitmq
```

The entrypoint renders the template into `definitions.json` and the
broker applies the new user on boot. **Do not edit
`definitions.json.template` to change the user/password** — anyone
who pulls the repo would see the value in git history.

### `entrypoint.sh`
Renders `definitions.json.template` → `/etc/rabbitmq/definitions.json`
on container start, then `exec`s the original rabbitmq
`docker-entrypoint.sh`. The rendered file is `chmod 600` because it
contains the CDC password in plain text.

Uses `envsubst` if available, falls back to `sed` with metachar
escaping if not. Fails loudly on empty `${CDC_AMQP_USER}` /
`${CDC_AMQP_PASSWORD}` (`: ${VAR:?...}`) so a missing/typo'd env
var surfaces a clear error instead of silently creating a broker
with no CDC user.

## CDC user tag

The CDC user is tagged `management` (not `administrator`). This grants:

- ✅ AMQP auth + publish + consume (full pipeline functionality)
- ✅ Read-only access to the management UI/API (queues, exchanges,
  bindings, connections, channels — viewable)
- ❌ Cannot create/delete users, vhosts, policies
- ❌ Cannot close connections, force-close channels, reset stats

The full administrator account is the broker's default user
(`RABBITMQ_DEFAULT_USER`), which the SSO apps use. The CDC service
doesn't need admin powers — only the SSO apps need to declare
exchanges/queues programmatically.

## Validation

```bash
# Verify the template is valid JSON (after envsubst, on a running container)
docker compose exec rabbitmq cat /etc/rabbitmq/definitions.json | jq .

# Verify the CDC user exists with the right tag
docker compose exec rabbitmq rabbitmqctl list_users
# Expected: cdc [...], management
```

## Troubleshooting

**Container restarts on every boot**: the entrypoint renders the file
in-memory only; the rendered file is in `/etc/rabbitmq/` which is NOT
in the `rabbitmq-data` named volume. Only the broker's mnesia dir
(messages, exchanges, queues, users) persists across `docker compose
restart`. If you change the CDC user/password in `.env` and
`docker compose restart rabbitmq`, the new user is applied.

**Auth fails for the CDC user after rotating**:
- check `.env` has matching `CDC_AMQP_USER` and `CDC_AMQP_PASSWORD`
- `docker compose exec rabbitmq rabbitmqctl list_users` to confirm
  the new user was created
- `docker compose logs rabbitmq` to see broker rejection messages
