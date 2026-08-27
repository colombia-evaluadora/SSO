#!/bin/bash
# ===========================================================================
# rabbitmq entrypoint — renders the cdc user/password from .env into
# /etc/rabbitmq/definitions.json BEFORE the original rabbitmq entrypoint
# boots the broker. Without this, the CDC user is hardcoded to
# "cdc"/"demopass" and changing .env had no effect.
#
# Substitution strategy: envsubst (from gettext-base) is the canonical
# tool, but it isn't always installed in minimal container images.
# Fall back to sed with `${VAR}` matching — rabbitmq's base image
# (debian-slim) ships sed but may not ship gettext.
#
# CDC_AMQP_USER / CDC_AMQP_PASSWORD are the ONLY vars templated here.
# The exchange/queue/binding names (cdc.events, cdc.worker, etc.) are
# CDC-internal and stay literal.
# ===========================================================================
set -eu
# Note: pipefail was dropped — rabbitmq's base image invokes the script
# in a way that disables the bash extension, and our substitutions
# are sequential anyway (no pipelines to mask failures in).

TEMPLATE="/etc/rabbitmq/definitions.json.template"
OUTPUT="/etc/rabbitmq/definitions.json"

if [ ! -f "$TEMPLATE" ]; then
    echo "[entrypoint] $TEMPLATE not found — skipping substitution" >&2
    exec /usr/local/bin/docker-entrypoint.sh "$@"
fi

# Default-empty values: if CDC_AMQP_USER is unset, refuse to render
# instead of silently writing garbage (e.g. an empty-string user).
: "${CDC_AMQP_USER:?CDC_AMQP_USER must be set in .env when cdc-sync profile is enabled}"
: "${CDC_AMQP_PASSWORD:?CDC_AMQP_PASSWORD must be set in .env when cdc-sync profile is enabled}"
# Same guard for the SSO_MQ user — declared in definitions.json
# alongside the CDC user so the broker has the right credentials
# across fresh and replayed boots (definitions.json REPLACES the
# user list, so RABBITMQ_DEFAULT_USER alone is not enough).
: "${RABBITMQ_USER:?RABBITMQ_USER must be set in .env}"
: "${RABBITMQ_PASS:?RABBITMQ_PASS must be set in .env}"

if command -v envsubst >/dev/null 2>&1; then
    envsubst < "$TEMPLATE" > "$OUTPUT"
else
    # sed fallback — escapes every shell metacharacter in the value
    # (|, &) so a password like 'foo&bar' doesn't break the BRE.
    _cdc_u=$(printf '%s' "$CDC_AMQP_USER"     | sed -e 's/[&|]/\\&/g')
    _cdc_p=$(printf '%s' "$CDC_AMQP_PASSWORD" | sed -e 's/[&|]/\\&/g')
    _sso_u=$(printf '%s' "$RABBITMQ_USER"      | sed -e 's/[&|]/\\&/g')
    _sso_p=$(printf '%s' "$RABBITMQ_PASS"      | sed -e 's/[&|]/\\&/g')
    sed -e "s|\${CDC_AMQP_USER}|$_cdc_u|g" \
        -e "s|\${CDC_AMQP_PASSWORD}|$_cdc_p|g" \
        -e "s|\${RABBITMQ_USER}|$_sso_u|g" \
        -e "s|\${RABBITMQ_PASS}|$_sso_p|g" \
        "$TEMPLATE" > "$OUTPUT"
    unset _cdc_u _cdc_p _sso_u _sso_p
fi

# Tighten permissions — the file contains the broker's plain-text
# password and the cdc user can auth against the management API.
# Mode 644 (not 600) because RabbitMQ runs as the unprivileged
# `rabbitmq` user and needs to read the file. The container has no
# other unprivileged users so 644 doesn't broaden the exposure
# beyond "anyone inside this container".
chmod 644 "$OUTPUT"
echo "[entrypoint] rendered $OUTPUT from .env (user=${CDC_AMQP_USER})"

# Hand off to the original rabbitmq entrypoint.
# `$@` is whatever the container was started with (typically
# `rabbitmq-server`); pos args are preserved.
exec /usr/local/bin/docker-entrypoint.sh "$@"
