#!/usr/bin/env bash
#
# clickhouse-migrate.sh — Flyway para ClickHouse.
#
# Por qué existe: Flyway (postgres/migrations/) sólo migra sso-postgres.
# Los cambios de esquema de `auditoria.*` (ClickHouse, el mirror que
# alimenta /audits/*) siempre se aplicaron A MANO por ambiente — V377
# documentó ese ALTER como manual, se aplicó en dev/test y se olvidó en
# producción: /audits/stats y /audits/query devolvieron 500 ahí durante
# días sin que ningún pipeline lo hubiera podido atrapar. Este script
# cierra ese hueco: mismo principio que Flyway (versionar, trackear lo ya
# aplicado, fallar fuerte ante drift), pero contra ClickHouse.
#
# Convención de archivos, igual que postgres/migrations/:
#   docker/clickhouse/migrations/V<N>__descripcion.sql
#
# Cada archivo debe ser SQL de ClickHouse idempotente (`ADD COLUMN IF NOT
# EXISTS`, `CREATE TABLE IF NOT EXISTS`, etc.) — igual que el resto de este
# repo, para que re-correrlo nunca sea destructivo por accidente.
#
# Tracking: tabla auditoria.schema_migrations (versión, descripción,
# checksum md5 del archivo, cuándo se aplicó). Antes de aplicar una
# migración YA registrada, se compara su checksum contra el del archivo en
# disco — si difieren, el script FALLA (exit 1) en vez de re-aplicar en
# silencio: un V<n> que cambió después de aplicado es una señal de que algo
# se escribió mal, no algo para pasar por alto (mismo espíritu que el
# checksum mismatch de Flyway, sin el auto-repair — acá no hace falta:
# nunca se edita un V<n> ya aplicado, se agrega uno nuevo).
#
# Uso (desde la raíz del repo, en el servidor -- deploy.yml lo invoca así):
#   ./scripts/clickhouse-migrate.sh
#
# Variables de entorno (mismos nombres que docker-compose.yml usa para el
# propio contenedor, así que ya están en el .env de cada servidor):
#   CDC_CLICKHOUSE_USER       default: default
#   CDC_CLICKHOUSE_PASSWORD   default: demopass
#   CDC_CLICKHOUSE_DB         default: auditoria
#   CLICKHOUSE_CONTAINER      default: cdc-clickhouse
#
# Si el contenedor no está corriendo (CDC_SYNC_ENABLED=false apaga
# ClickHouse en ese ambiente, ver sso-stack.sh), el script lo nota y
# termina en 0 -- no hay nada que migrar sin ClickHouse levantado, y no
# es motivo para tumbar el deploy del resto del stack.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

MIGRATIONS_DIR="docker/clickhouse/migrations"
CONTAINER="${CLICKHOUSE_CONTAINER:-cdc-clickhouse}"

# Mismo criterio que _envval() en deploy.yml: leer del .env sin `source`
# (los valores pueden traer caracteres que rompan el shell).
_envval() {
  sed -n "s/^$1=//p" .env 2>/dev/null | tail -1 | tr -d '\r'
}

CH_USER="${CDC_CLICKHOUSE_USER:-$(_envval CDC_CLICKHOUSE_USER)}"
CH_USER="${CH_USER:-default}"
CH_PASSWORD="${CDC_CLICKHOUSE_PASSWORD:-$(_envval CDC_CLICKHOUSE_PASSWORD)}"
CH_PASSWORD="${CH_PASSWORD:-demopass}"
CH_DB="${CDC_CLICKHOUSE_DB:-$(_envval CDC_CLICKHOUSE_DB)}"
CH_DB="${CH_DB:-auditoria}"

if ! docker inspect -f '{{.State.Running}}' "$CONTAINER" >/dev/null 2>&1; then
  echo "clickhouse-migrate: '$CONTAINER' no está corriendo en este ambiente (CDC_SYNC_ENABLED=false?) -- nada que migrar."
  exit 0
fi

ch_client() {
  docker exec -i "$CONTAINER" clickhouse-client \
    --user "$CH_USER" --password "$CH_PASSWORD" --database "$CH_DB" "$@"
}

echo "=== clickhouse-migrate: asegurando auditoria.schema_migrations ==="
ch_client --query "
CREATE TABLE IF NOT EXISTS ${CH_DB}.schema_migrations
(
    version     String,
    description String,
    checksum    String,
    applied_at  DateTime64(3, 'UTC') DEFAULT now64(3)
)
ENGINE = ReplacingMergeTree
ORDER BY version
"

if [ ! -d "$MIGRATIONS_DIR" ] || [ -z "$(ls -A "$MIGRATIONS_DIR" 2>/dev/null)" ]; then
  echo "clickhouse-migrate: $MIGRATIONS_DIR vacío o no existe -- nada que migrar."
  exit 0
fi

# Orden por VERSION numérica, no lexicográfico -- mismo motivo que
# `sort -V` en deploy.yml (V10 tiene que ir después de V9, no antes).
mapfile -t FILES < <(find "$MIGRATIONS_DIR" -maxdepth 1 -type f -name 'V*__*.sql' -printf '%f\n' | sort -V)

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "clickhouse-migrate: sin archivos V<n>__*.sql en $MIGRATIONS_DIR -- nada que migrar."
  exit 0
fi

FAILED=0
for fname in "${FILES[@]}"; do
  version="$(printf '%s' "$fname" | sed -E 's/^V([0-9]+(\.[0-9]+)*)__.*/\1/')"
  description="$(printf '%s' "$fname" | sed -E 's/^V[0-9]+(\.[0-9]+)*__(.*)\.sql$/\2/')"
  filepath="$MIGRATIONS_DIR/$fname"
  checksum="$(md5sum "$filepath" | cut -d' ' -f1)"

  # FINAL: fuerza el merge de ReplacingMergeTree en la lectura -- sin esto
  # una versión insertada hace un instante podría no verse todavía si
  # quedaron dos partes sin compactar.
  existing_checksum="$(ch_client --query "
    SELECT checksum FROM ${CH_DB}.schema_migrations FINAL WHERE version = '${version}' LIMIT 1
  ")"

  if [ -n "$existing_checksum" ]; then
    if [ "$existing_checksum" = "$checksum" ]; then
      echo "V${version} (${description}): ya aplicada, sin cambios -- omitida."
      continue
    fi
    echo "::error::clickhouse-migrate: V${version} (${fname}) ya está aplicada con OTRO checksum. Un V<n> aplicado no debe editarse -- agrega una migración nueva en su lugar. Checksum registrado=${existing_checksum} archivo=${checksum}"
    FAILED=1
    continue
  fi

  echo "=== aplicando V${version}: ${description} ==="
  # `--queries-file` sería una ruta DENTRO del contenedor (no existe ahí);
  # por stdin sí funciona -- `docker exec -i` la reenvía y clickhouse-client
  # separa multiquery por `;` automáticamente al leer de stdin.
  if ch_client < "$filepath"; then
    ch_client --query "
      INSERT INTO ${CH_DB}.schema_migrations (version, description, checksum)
      VALUES ('${version}', '${description}', '${checksum}')
    "
    echo "V${version} (${description}): aplicada OK."
  else
    echo "::error::clickhouse-migrate: V${version} (${fname}) falló -- no se registra como aplicada."
    FAILED=1
  fi
done

if [ "$FAILED" -ne 0 ]; then
  echo "::error::clickhouse-migrate: una o más migraciones fallaron o tienen drift -- revisar arriba."
  exit 1
fi

echo "=== clickhouse-migrate: todas las migraciones de $MIGRATIONS_DIR están aplicadas ==="
