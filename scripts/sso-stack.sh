#!/usr/bin/env bash
#
# sso-stack.sh — wrapper sobre `docker compose` que honra `.env`.
#
# Por qué existe: Docker Compose NO interpola variables dentro del campo
# `profiles:` de un servicio. Eso significa que flags tipo
# `CDC_SYNC_ENABLED=false` o `SSO_TELEMETRY_ENABLED=false` no pueden,
# por sí solos, esconder servicios del grafo. La forma soportada es:
#
#   · un override que reasigne el `profiles:` del servicio a uno que
#     nadie active (en este repo, `disabled` — docker-compose.cdc-off.yml).
#   · filtrar perfiles de la lista `COMPOSE_PROFILES` antes de
#     exportarla al environment del comando compose.
#
# Este wrapper lee `.env`, aplica los overrides necesarios y exporta
# `COMPOSE_PROFILES` ya filtrada, así el operador sólo tiene que
# decidir en `.env` qué encender y qué apagar. Cubre dos flags:
#
#   CDC_SYNC_ENABLED=true|false
#     false → añade docker-compose.cdc-off.yml al comando compose.
#             Apaga ClickHouse, cdc-capture, cdc-pg-slot-init y
#             cdc-worker en una sola línea.
#
#   SSO_TELEMETRY_ENABLED=true|false
#     false → quita `observability` del COMPOSE_PROFILES que se le pasa
#             a compose. Apaga Alloy/Tempo/Mimir/Loki/Grafana en una
#             sola línea (los cinco contenedores que gastan ~883 MB sin
#             recibir nada si los exporters ya están apagados).
#             Los exporters OTLP de los nueve servicios Spring también
#             leen este flag directamente desde su `environment:`.
#
# Si en el futuro aparecen más switches binarios, se añaden aquí como
# casos adicionales — la lógica general no cambia: si `.env` lo dice
# apagado, se concatena su override o se filtra su perfil.
#
# Uso:
#   ./scripts/sso-stack.sh up -d          # mismo perfil que docker compose
#   ./scripts/sso-stack.sh down           # apaga respetando los overrides
#   ./scripts/sso-stack.sh ps             # muestra servicios resueltos
#   ./scripts/sso-stack.sh logs -f alloy  # logs de un servicio
#
#   # Override manual del flag en línea (útil en CI):
#   CDC_SYNC_ENABLED=false ./scripts/sso-stack.sh up -d
#   SSO_TELEMETRY_ENABLED=false ./scripts/sso-stack.sh up -d
#
# Pre-requisito: estar en la raíz del repo (donde vive docker-compose.yml).
# El wrapper hace `cd` ahí automáticamente.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# ─── Resolver flags desde .env ────────────────────────────────────────────────
#
# No usamos `docker compose --env-file` porque queremos el MISMO .env
# que `docker compose` ya carga solo (raíz del repo). Pero como no
# queremos `source`ear un .env arbitrario del usuario en nuestro shell
# (cambia PATH, PWD, etc.), leemos sólo las claves que nos interesan
# con grep + cut. Si la línea está comentada o ausente, usamos el
# default "encendido" — coherente con cómo se interpreta el resto del
# docker-compose.yml (los `${VAR:-default}` también caen al default).
#
# Los overrides en línea (`KEY=val ./scripts/sso-stack.sh ...`) tienen
# precedencia sobre .env: si la variable ya está en el environment, la
# usamos directamente sin releer el fichero.

read_env_flag() {
  local key="$1"
  local default="$2"
  # Override en línea gana sobre .env
  local val="${!key:-}"
  if [ -z "$val" ]; then
    val="$(grep -E "^${key}=" .env 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
  fi
  if [ -z "$val" ]; then
    echo "$default"
  else
    echo "$val"
  fi
}

is_truthy() {
  # Aceptamos las mismas variantes que la convención docker compose:
  # true/1/yes/on → encendido; false/0/no/off → apagado; cualquier
  # otra cosa (incluido vacío) cae al default "encendido".
  case "${1,,}" in
    false|0|no|off|"") return 1 ;;
    *) return 0 ;;
  esac
}

CDC_SYNC_ENABLED_VAL="$(read_env_flag CDC_SYNC_ENABLED true)"
SSO_TELEMETRY_ENABLED_VAL="$(read_env_flag SSO_TELEMETRY_ENABLED true)"

# ─── Componer la lista de archivos -f ─────────────────────────────────────────
#
# El base SIEMPRE va primero; los overrides van después y machacan
# campos del anterior (gana el último). `docker-compose.cdc-off.yml`
# sólo entra si CDC_SYNC_ENABLED dice apagado.

COMPOSE_FILES=(-f docker-compose.yml)

if ! is_truthy "$CDC_SYNC_ENABLED_VAL"; then
  COMPOSE_FILES+=(-f docker-compose.cdc-off.yml)
  echo ">> CDC_SYNC_ENABLED=${CDC_SYNC_ENABLED_VAL} → aplicando docker-compose.cdc-off.yml"
fi

# ─── Filtrar COMPOSE_PROFILES si telemetría está apagada ──────────────────────
#
# Si SSO_TELEMETRY_ENABLED=false, quitamos `observability` de la lista
# de perfiles que se exporta al environment de compose. Sin esto, los
# cinco contenedores del stack LGTM (Alloy/Tempo/Mimir/Loki/Grafana)
# siguen arrancando y gastando ~883 MB sin que nadie les empuje datos.
#
# El filtrado opera sobre tres fuentes en orden de precedencia:
#   1. `COMPOSE_PROFILES` ya exportada en el shell del operador.
#   2. La línea `COMPOSE_PROFILES=` del `.env` del repo.
#   3. Default `local-only,cdc-sync` (lo razonable para dev/test).
#
# Hacemos caso al orden porque refleja la intención: si el operador
# pasó `COMPOSE_PROFILES=local-only` en línea, no vamos a meterle
# cdc-sync "porque sí".

DEFAULT_PROFILES="local-only,cdc-sync"

if [ -n "${COMPOSE_PROFILES:-}" ]; then
  PROFILES_RAW="$COMPOSE_PROFILES"
elif grep -qE "^COMPOSE_PROFILES=" .env 2>/dev/null; then
  PROFILES_RAW="$(grep -E "^COMPOSE_PROFILES=" .env | tail -n1 | cut -d= -f2-)"
else
  PROFILES_RAW="$DEFAULT_PROFILES"
fi

if ! is_truthy "$SSO_TELEMETRY_ENABLED_VAL"; then
  # Filtro: conservamos todos los perfiles de la lista salvo
  # `observability`. `,` se usa como separador; el IFS de read nos
  # ayuda a tokenizar limpiamente sin tirar de awk/sed.
  FILTERED=""
  IFS=',' read -ra PARTS <<< "$PROFILES_RAW"
  for p in "${PARTS[@]}"; do
    p="$(echo "$p" | xargs)"  # trim espacios
    [ -z "$p" ] && continue
    if [ "$p" = "observability" ]; then
      continue
    fi
    if [ -z "$FILTERED" ]; then
      FILTERED="$p"
    else
      FILTERED="${FILTERED},${p}"
    fi
  done
  if [ "$FILTERED" != "$PROFILES_RAW" ]; then
    echo ">> SSO_TELEMETRY_ENABLED=${SSO_TELEMETRY_ENABLED_VAL} → quitando 'observability' de COMPOSE_PROFILES"
    echo "   antes:  COMPOSE_PROFILES=${PROFILES_RAW}"
    echo "   ahora:  COMPOSE_PROFILES=${FILTERED}"
    export COMPOSE_PROFILES="$FILTERED"
  fi
fi

# ─── Despachar el sub-comando ─────────────────────────────────────────────────
#
# `exec docker compose` para que las señales (Ctrl-C, SIGTERM del
# orquestador) lleguen al proceso real y no a este wrapper. Sin exec,
# un Ctrl-C mata al script pero deja el `docker compose` huérfano.

echo ">> docker compose ${COMPOSE_FILES[*]} $*"
exec docker compose "${COMPOSE_FILES[@]}" "$@"