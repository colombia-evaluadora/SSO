#!/usr/bin/env bash
#
# sso-stack.sh — wrapper sobre `docker compose` que honra `.env`.
#
# Por qué existe: Docker Compose NO interpola variables dentro del campo
# `profiles:` de un servicio. Eso significa que un flag tipo
# `CDC_SYNC_ENABLED=false` no puede, por sí solo, esconder un servicio
# del grafo. La forma soportada es un override que reasigne el
# `profiles:` del servicio a uno que nadie active (en este repo,
# `disabled`).
#
# Este wrapper lee `.env` y aplica los overrides necesarios de forma
# transparente, así el operador sólo tiene que decidir en `.env` qué
# encender y qué apagar. Hoy cubre un solo flag:
#
#   CDC_SYNC_ENABLED=true|false
#     false → añade docker-compose.cdc-off.yml al comando compose.
#             Apaga ClickHouse, cdc-capture, cdc-pg-slot-init y
#             cdc-worker en una sola línea.
#
# Si en el futuro aparecen más switches binarios que no se puedan
# expresar con perfiles (p.ej. quitar el gateway de la frontera),
# se añaden aquí como casos adicionales — la lógica general no
# cambia: si `.env` lo dice apagado, se concatena su override.
#
# Uso:
#   ./scripts/sso-stack.sh up -d          # mismo perfil que docker compose
#   ./scripts/sso-stack.sh down           # apaga respetando los overrides
#   ./scripts/sso-stack.sh ps             # muestra servicios resueltos
#   ./scripts/sso-stack.sh logs -f alloy  # logs de un servicio
#
#   # Override manual del flag en línea (útil en CI):
#   CDC_SYNC_ENABLED=false ./scripts/sso-stack.sh up -d
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

read_env_flag() {
  local key="$1"
  local default="$2"
  local val
  # `^KEY=...` evita matchear CDC_SYNC_ENABLED cuando se busca CDC.
  # `cut -d= -f2-` por si el valor lleva '=' dentro (no aplica aquí,
  #   pero es la forma robusta).
  val="$(grep -E "^${key}=" .env 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
  if [ -z "$val" ]; then
    echo "$default"
  else
    echo "$val"
  fi
}

CDC_SYNC_ENABLED_VAL="$(read_env_flag CDC_SYNC_ENABLED true)"

# ─── Componer la lista de archivos -f ─────────────────────────────────────────
#
# El base SIEMPRE va primero; los overrides van después y machacan
# campos del anterior (gana el último). `docker-compose.cdc-off.yml`
# sólo entra si el flag dice apagado.

COMPOSE_FILES=(-f docker-compose.yml)

case "${CDC_SYNC_ENABLED_VAL,,}" in
  false|0|no|off)
    COMPOSE_FILES+=(-f docker-compose.cdc-off.yml)
    echo ">> CDC_SYNC_ENABLED=${CDC_SYNC_ENABLED_VAL} → aplicando docker-compose.cdc-off.yml"
    ;;
  *)
    # encendido: ningún override extra
    ;;
esac

# ─── Despachar el sub-comando ─────────────────────────────────────────────────
#
# `exec docker compose` para que las señales (Ctrl-C, SIGTERM del
# orquestador) lleguen al proceso real y no a este wrapper. Sin exec,
# un Ctrl-C mata al script pero deja el `docker compose` huérfano.

echo ">> docker compose ${COMPOSE_FILES[*]} $*"
exec docker compose "${COMPOSE_FILES[@]}" "$@"