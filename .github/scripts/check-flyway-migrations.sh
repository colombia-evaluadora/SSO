#!/usr/bin/env bash
# =============================================================================
# check-flyway-migrations.sh — gate de CI para postgres/migrations/.
#
# Corre dos validaciones sobre las migraciones NUEVAS o MODIFICADAS en esta
# rama respecto a la rama destino (dev en un PR, o el tip previo en un push):
#
#   1. Choque de versión: si el V<n> de una migración nueva ya existe en la
#      rama destino apuntando a OTRO archivo (mismo número, distinto título),
#      falla. Flyway aplica por número de versión, así que dos archivos con
#      el mismo V<n> y contenido distinto es una colisión real: cualquiera
#      que ya haya corrido el V<n> de destino en su entorno no puede aplicar
#      el V<n> de esta rama sin intervención manual, y en producción es
#      directamente un migrate roto.
#
#   2. Idempotencia: cada migración nueva se aplica dos veces seguidas contra
#      la misma base (una vez vía `flyway migrate` como parte del historial
#      completo, otra vez ejecutando el .sql directo con psql). Si la segunda
#      ejecución falla, la migración no es idempotente — típicamente un
#      CREATE TABLE/INDEX sin IF NOT EXISTS, o un INSERT sin ON CONFLICT.
#      Esto importa porque el flujo de recuperación de deploy-test.yml
#      (`flyway repair` + `migrate -outOfOrder=true`) reaplica migraciones
#      tras un checksum mismatch, y una migración no idempotente deja el
#      servidor en un estado peor que el fallo original.
#
# Uso: check-flyway-migrations.sh <base-ref> <pg-host> <pg-port> <pg-user> <pg-pass> <pg-db>
# =============================================================================
set -euo pipefail

BASE_REF="$1"
PGHOST="$2"
PGPORT="$3"
PGUSER="$4"
PGPASSWORD="$5"
PGDATABASE="$6"
export PGPASSWORD

MIGRATIONS_DIR="postgres/migrations"

echo "=== Migraciones nuevas/modificadas respecto a $BASE_REF ==="
CHANGED_FILES=$(git diff --name-only --diff-filter=ACMR "$BASE_REF"...HEAD -- "$MIGRATIONS_DIR" | grep -E "^${MIGRATIONS_DIR}/V[0-9]+(\.[0-9]+)*__.*\.sql\$" || true)

if [ -z "$CHANGED_FILES" ]; then
  echo "Ninguna migración nueva o modificada en esta rama. Nada que validar."
  exit 0
fi

echo "$CHANGED_FILES" | sed 's/^/  /'

# ───────── 1. Choque de versión contra la rama destino ─────────
echo ""
echo "=== Chequeo de colisión de versión vs $BASE_REF ==="
fail=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  base_name=$(basename "$f")
  ver=$(echo "$base_name" | grep -oE '^V[0-9]+(\.[0-9]+)*')
  # Todos los archivos de migración que YA existen en la rama destino con
  # ese mismo V<n>, sea cual sea su título.
  existing_same_version=$(git ls-tree -r --name-only "$BASE_REF" -- "$MIGRATIONS_DIR" \
    | grep -E "^${MIGRATIONS_DIR}/${ver}__" || true)
  if [ -n "$existing_same_version" ] && [ "$existing_same_version" != "$f" ]; then
    echo "::error file=$f::Colisión de versión ${ver}: la rama destino ($BASE_REF) ya tiene '$existing_same_version' con ese mismo número. Renombra tu migración al siguiente V<n> libre."
    fail=1
  fi
done <<< "$CHANGED_FILES"

if [ "$fail" -ne 0 ]; then
  echo ""
  echo "::error::Hay colisiones de versión sin resolver. No se puede mergear hasta renombrar los V<n> en conflicto."
  exit 1
fi
echo "Sin colisiones de versión."

# ───────── 2. Idempotencia ─────────
#
# `flyway migrate` sobre el historial COMPLETO ya deja la base al día
# (incluye las migraciones nuevas de esta rama, aplicadas una vez). Para
# probar idempotencia, cada migración nueva se re-ejecuta directo con psql
# contra esa misma base: si el archivo es idempotente, la segunda corrida
# también sale limpia.
echo ""
echo "=== Chequeo de idempotencia (aplicación duplicada) ==="
idempotency_fail=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  echo "--- Re-aplicando $f ---"
  if ! psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" \
       -v ON_ERROR_STOP=1 -f "$f" > /tmp/idempotency-output.log 2>&1; then
    echo "::error file=$f::La migración NO es idempotente: falló al re-ejecutarse una segunda vez sobre el mismo esquema. Usa IF NOT EXISTS / IF EXISTS / ON CONFLICT / CREATE OR REPLACE según corresponda."
    cat /tmp/idempotency-output.log
    idempotency_fail=1
  else
    echo "OK: $f es idempotente."
  fi
done <<< "$CHANGED_FILES"

if [ "$idempotency_fail" -ne 0 ]; then
  echo ""
  echo "::error::Hay migraciones no idempotentes. Corrígelas antes de mergear."
  exit 1
fi

echo ""
echo "Todas las migraciones nuevas pasaron el chequeo de versión e idempotencia."
