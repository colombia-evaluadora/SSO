#!/usr/bin/env bash
#
# sso-stack.sh — wrapper sobre `docker compose` que honra `.env`.
#
# Por qué existe: Docker Compose NO interpola variables dentro del campo
# `profiles:` de un servicio. Eso significa que flags tipo
# `CDC_SYNC_ENABLED=false` o `SSO_TELEMETRY_ENABLED=false` no pueden,
# por sí solos, esconder servicios del grafo. La forma soportada es
# filtrar perfiles de la lista `COMPOSE_PROFILES` antes de exportarla
# al environment del comando compose: si un servicio sólo tiene
# `profiles: ["cdc-sync"]`, quitar `cdc-sync` del environment hace
# que el servicio quede fuera del grafo.
#
# Este wrapper lee `.env`, filtra `COMPOSE_PROFILES` en consecuencia y
# se la pasa a compose. Cubre dos flags:
#
#   CDC_SYNC_ENABLED=true|false
#     false → quita `cdc-sync` del COMPOSE_PROFILES. Apaga ClickHouse,
#             cdc-capture, cdc-pg-slot-init y cdc-worker en una
#             sola línea.
#
#   SSO_TELEMETRY_ENABLED=true|false
#     false → quita `observability` del COMPOSE_PROFILES. Apaga
#             Alloy/Tempo/Mimir/Loki/Grafana en una sola línea (los
#             cinco contenedores que gastan ~883 MB sin recibir nada
#             si los exporters ya están apagados).
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
    val="$(grep -E "^${key}=" .env 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '\r' || true)"
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
# campos del anterior (gana el último). El override `cdc-off.yml`
# ya no se concatena por aquí — el apagado de CDC se hace filtrando
# `cdc-sync` de COMPOSE_PROFILES más abajo, que es la vía robusta
# (el override mezclaba listas de perfiles en vez de reemplazarlas,
# dejando los CDC seleccionables bajo ambos perfiles).

COMPOSE_FILES=(-f docker-compose.yml)

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
  PROFILES_RAW="$(grep -E "^COMPOSE_PROFILES=" .env | tail -n1 | cut -d= -f2- | tr -d '\r')"
else
  PROFILES_RAW="$DEFAULT_PROFILES"
fi

# ─── Filtrar COMPOSE_PROFILES según los flags ────────────────────────────────
#
# Algunos flags se materializan quitando el perfil del CDC de la lista
# activa; otros (telemetría) lo mismo con `observability`. La lógica
# general: si `.env` lo dice apagado, ese perfil no se queda.
#
# Razón del enfoque: originalmente usábamos un override (-f
# docker-compose.cdc-off.yml) que movía los servicios CDC a un perfil
# `disabled`. Pero Docker Compose V2 mezcla listas de override (no
# las reemplaza atómicamente), y la config efectiva quedaba con
# `profiles: ["cdc-sync", "disabled"]` — ambos perfiles a la vez, así
# que los CDC seguían siendo seleccionables. Filtrar el `-f` extra es
# más simple, más robusto y consistente con cómo apagamos
# `observability`.

FILTER_OUT=""
if ! is_truthy "$SSO_TELEMETRY_ENABLED_VAL"; then
  FILTER_OUT="${FILTER_OUT} observability"
fi
if ! is_truthy "$CDC_SYNC_ENABLED_VAL"; then
  FILTER_OUT="${FILTER_OUT} cdc-sync"
fi

if [ -n "$FILTER_OUT" ]; then
  FILTERED=""
  IFS=',' read -ra PARTS <<< "$PROFILES_RAW"
  for p in "${PARTS[@]}"; do
    p="$(echo "$p" | xargs)"  # trim espacios
    [ -z "$p" ] && continue
    # Espacio-delimitado en FILTER_OUT: ¿está $p en la lista a quitar?
    skip=0
    for f in $FILTER_OUT; do
      if [ "$p" = "$f" ]; then skip=1; break; fi
    done
    [ "$skip" = "1" ] && continue
    if [ -z "$FILTERED" ]; then
      FILTERED="$p"
    else
      FILTERED="${FILTERED},${p}"
    fi
  done
  if [ "$FILTERED" != "$PROFILES_RAW" ]; then
    echo ">> Filtro COMPOSE_PROFILES (apagado: ${FILTER_OUT# })"
    echo "   antes:  COMPOSE_PROFILES=${PROFILES_RAW}"
    echo "   ahora:  COMPOSE_PROFILES=${FILTERED}"
    export COMPOSE_PROFILES="$FILTERED"
  fi
fi

# ─── Bajar contenedores huérfanos cuando un perfil se apaga ───────────────────
#
# `docker compose up -d` sólo recrea/levanta servicios del grafo activo
# — los que estaban bajo un perfil que se acaba de quitar (p. ej.
# `cdc-sync` cuando CDC_SYNC_ENABLED=false) ya no salen en el grafo,
# pero sus contenedores siguen corriendo. Si no los paramos, el flag
# "no apagó" nada en la práctica: el operador sigue viendo CDC UP y
# la memoria no se libera.
#
# Solución: si vamos a hacer `up` (no `down`, no `ps`, no `logs`) y
# hay al menos un perfil en `FILTER_OUT`, preguntamos al grafo cuáles
# servicios están bajo ese perfil — con el override de perfiles
# resuelto por la flag — y bajamos selectivamente los que están
# corriendo. Sólo `up` lo dispara: cualquier otro subcomando pasa
# intacto.
#
# OJO: usamos `docker compose config --services` después de aplicar
# el mismo filtro de COMPOSE_PROFILES, así sabemos qué servicios
# caen DENTRO del grafo activo. Para saber cuáles sacar, en cambio,
# vemos qué servicios tenían `cdc-sync` u `observability` en su
# perfil ORIGINAL — para eso parseamos docker-compose.yml directamente
# con un grep (no nos hace falta `yq`; la regex es estable).

if [ "${1:-}" = "up" ] && [ -n "$FILTER_OUT" ]; then
  # Servicios que matchean los perfiles que se acaban de apagar.
  # Parseamos docker-compose.yml: nombres de servicio son líneas
  # que empiezan con 2 espacios + letra + `:` y fin de línea.
  # Capturamos qué profiles tiene cada uno.
  HUErfanos=""

  PROFILES_BY_SERVICE="$(awk '
    # Cabecera de servicio: dos espacios, nombre, ":" y fin de línea.
    # Si veníamos acumulando profiles de otro servicio, los volcamos.
    /^  [a-zA-Z0-9_.-]+:$/ {
      if (svc != "" && svc != "services") printf "%s %s\n", svc, prof
      svc=$1; sub(/:$/,"",svc); prof=""; next
    }
    # Top-level (services:, name:, etc.) → olvidamos el svc pendiente
    # y volcamos si había algo.
    /^[^ ]/ || /^ [^ ]/ {
      if (svc != "" && svc != "services") printf "%s %s\n", svc, prof
      svc=""; prof=""; next
    }
    # profiles: [a, b] — capturar todo lo que está dentro del corchete
    # en una sola pasada (no asumimos que cierre en la misma línea).
    /profiles:[[:space:]]*\[/ {
      s = $0
      while (match(s, /\[[^\]]*\]/)) {
        arr = substr(s, RSTART+1, RLENGTH-2)
        gsub(/[ \t]+/, "", arr)
        if (prof == "") prof = arr; else prof = prof "," arr
        s = substr(s, RSTART+RLENGTH)
      }
      next
    }
    END { if (svc != "" && svc != "services") printf "%s %s\n", svc, prof }
  ' docker-compose.yml)"

  # Validación: parser sano. Si la salida está vacía o no tiene
  # comas, no bajamos nada (defensivo).
  if [ -z "$PROFILES_BY_SERVICE" ]; then
    echo ">> Aviso: parser no extrajo profiles de docker-compose.yml; saltando bajada de huérfanos."
    PROFILES_BY_SERVICE=""
  fi

  for f in $FILTER_OUT; do
    matches="$(printf '%s\n' "$PROFILES_BY_SERVICE" | awk -v p="$f" '{
      # Limpiamos comillas y separamos por comas/espacios.
      gsub(/"/, "", $0)
      n = split($0, parts, /[, ]+/)
      for (i=2; i<=n; i++) {
        if (parts[i] == p) { print $1; next }
      }
    }')"
    for m in $matches; do
      # El nombre del contenedor puede llevar el prefijo del proyecto
      # (`sso-…`) o no, dependiendo de si `docker-compose.yml` define
      # `container_name:` o no. Probamos los dos.
      PROJECT_PREFIX="${COMPOSE_PROJECT_NAME:-sso}"
      if docker ps --format '{{.Names}}' | grep -qxE "^(${PROJECT_PREFIX}-)?${m}\$"; then
        HUErfanos="${HUErfanos} ${m}"
      fi
    done
  done

  # Quita duplicados y espacios extra.
  HUErfanos="$(echo "$HUErfanos" | tr ' ' '\n' | sort -u | sed '/^$/d' | tr '\n' ' ' | sed 's/ $//')"

  if [ -n "$HUErfanos" ]; then
    echo ">> Bajando contenedores huérfanos (perfiles apagados:${FILTER_OUT#,}):"
    for s in $HUErfanos; do
      echo "     - $s"
    done
    # `docker compose stop` + `rm` es seguro: stop manda SIGTERM,
    # espera 10s, pasa a SIGKILL. rm quita el contenedor pero deja
    # los volúmenes y la imagen (eso es lo que queremos — los datos
    # de ClickHouse se conservan por si el operador reactiva CDC).
    docker compose "${COMPOSE_FILES[@]}" stop $HUErfanos 2>&1 || true
    docker compose "${COMPOSE_FILES[@]}" rm -f $HUErfanos 2>&1 || true
  fi
fi

# ─── Despachar el sub-comando ─────────────────────────────────────────────────
#
# `exec docker compose` para que las señales (Ctrl-C, SIGTERM del
# orquestador) lleguen al proceso real y no a este wrapper. Sin exec,
# un Ctrl-C mata al script pero deja el `docker compose` huérfano.

echo ">> docker compose ${COMPOSE_FILES[*]} $*"
exec docker compose "${COMPOSE_FILES[@]}" "$@"