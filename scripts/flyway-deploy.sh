#!/usr/bin/env bash
#
# flyway-deploy.sh — fase de migraciones de un deploy. Corre ANTES de recrear
# los servicios: si algo falla, sale con 1 y el stack sigue con la versión
# anterior (código viejo contra esquema viejo), nunca con código nuevo contra
# un esquema a medias.
#
# Orden, y por qué:
#
#   1. Detecta las migraciones YA APLICADAS cuyo contenido cambió, por dos
#      vías que se suman:
#        a) REAPPLY_CANDIDATES, que calcula deploy.yml con `git diff` entre el
#           último commit cuyas migraciones quedaron aplicadas en este
#           servidor y el que se despliega (o el `reapply_since` del release);
#        b) el checksum de flyway_schema_history (`flyway validate`).
#      La (b) sola no basta: un `flyway repair` previo ya realineó los
#      checksums y la migración editada deja de verse como cambiada aunque
#      su SQL nuevo nunca se haya ejecutado (release v1.1.57).
#   2. Las expande con scripts/migration-reapply-set.py: re-ejecutar un V<n>
#      viejo pisa lo que una migración posterior redefinió, así que esas
#      posteriores se re-ejecutan detrás.
#   3. Re-ejecuta todo ese SQL, en orden de versión y en UNA transacción
#      (si una falla no queda nada a medias), ANTES de aplicar las pendientes:
#      una migración nueva puede usar lo que la edición añadió (V540 llama a
#      fn_grado_escala_aplicable, que se agregó dentro de V428).
#   4. `flyway repair` solo si la validación (sin contar pendientes) falla:
#      checksums editados o ficheros borrados del repo.
#   5. `flyway migrate -outOfOrder=true` y `flyway validate`.
#
# Variables de entorno:
#   MIGRATIONS_DIR      directorio con los V<n>__*.sql (el mismo que ve flyway).
#   FLYWAY_CMD          prefijo que ejecuta flyway; se le añaden los argumentos.
#   PSQL_CMD            prefijo que ejecuta psql contra la MISMA base que flyway
#                       y lee el SQL de stdin.
#   REAPPLY_CANDIDATES  basenames (o V<n>) separados por espacio. Opcional.
#   HISTORY_TABLE       default public.flyway_schema_history.
#
# Lo usan deploy.yml (en el servidor) y el job flyway-upgrade de ci.yml (que
# simula la subida desde el último release), con los mismos pasos.
set -euo pipefail

: "${MIGRATIONS_DIR:?falta MIGRATIONS_DIR}"
: "${FLYWAY_CMD:?falta FLYWAY_CMD}"
: "${PSQL_CMD:?falta PSQL_CMD}"
REAPPLY_CANDIDATES="${REAPPLY_CANDIDATES:-}"
HISTORY_TABLE="${HISTORY_TABLE:-public.flyway_schema_history}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

fw()   { eval "$FLYWAY_CMD" '"$@"'; }
psqlq() { eval "$PSQL_CMD" -v ON_ERROR_STOP=1 -X '"$@"'; }

# 'V214.3__x.sql' | 'V214.3' | '214.3' -> '214.3'
version_of() { local b="${1##*/}"; b="${b%%__*}"; echo "${b#V}"; }

# Basename del fichero de una versión ('' si no existe en el repo).
file_of() { local f; for f in "$MIGRATIONS_DIR"/V"$1"__*.sql; do [ -e "$f" ] && { basename "$f"; return 0; }; done; return 0; }

# Ordena basenames por VERSION (sort -V sobre el número, no sobre el nombre:
# sobre el nombre V214.3__ quedaría antes que V214__).
sort_by_version() { awk -F'__' 'NF{print $1"\t"$0}' | sort -V -u -k1,1 | cut -f2; }

# Versiones con checksum distinto en el historial. JSON con jq si lo hay; si
# no, el texto de `flyway validate` (el servidor no garantiza jq).
checksum_mismatches() {
  if command -v jq >/dev/null 2>&1; then
    fw validate -outOfOrder=true -outputType=json 2>/dev/null \
      | jq -r '(.invalidMigrations // [])[]
               | select(.errorDetails.errorCode == "CHECKSUM_MISMATCH")
               | .version' 2>/dev/null || true
  else
    fw validate -outOfOrder=true 2>&1 \
      | grep -iE 'checksum mismatch for migration version' \
      | grep -oE '[0-9]+(\.[0-9]+)*' || true
  fi
}

echo "=== [1/5] migraciones aplicadas con contenido cambiado ==="
CHECKSUM_FILES="$(checksum_mismatches | sort -V -u)"
echo "Por checksum de flyway: $(echo $CHECKSUM_FILES)"
echo "Por diff de git (deploy.yml): ${REAPPLY_CANDIDATES:-<ninguna>}"

TABLE_EXISTS="$(psqlq -At -c "SELECT to_regclass('$HISTORY_TABLE') IS NOT NULL")"
APPLIED=""
if [ "$TABLE_EXISTS" = "t" ]; then
  APPLIED="$(psqlq -At -c "SELECT version FROM $HISTORY_TABLE WHERE success AND version IS NOT NULL")"
else
  # Base vacía (arranque desde cero): no hay nada aplicado que re-ejecutar.
  # Se comprueba contra flyway para no confundir esto con un PSQL_CMD que
  # apunta a otra base, que saltaría la re-aplicación en silencio.
  # A una variable y no en tubería: con pipefail, el `grep -q` que corta
  # antes de tiempo hace fallar a flyway por SIGPIPE y el `if` mentiría.
  INFO_JSON="$(fw info -outputType=json 2>/dev/null || true)"
  if printf '%s' "$INFO_JSON" | grep -E '"schemaVersion"[[:space:]]*:[[:space:]]*"' >/dev/null; then
    echo "::error::flyway ve migraciones aplicadas pero psql no encuentra $HISTORY_TABLE: PSQL_CMD no apunta a la base de flyway."
    exit 1
  fi
  echo "Base sin historial de flyway: nada que re-aplicar."
fi
is_applied() { printf '%s\n' "$APPLIED" | grep -xF -- "$1" >/dev/null; }

REQUESTED=""
for tok in $REAPPLY_CANDIDATES $CHECKSUM_FILES; do
  v="$(version_of "$tok")"
  f="$(file_of "$v")"
  if [ -z "$f" ]; then
    echo "::warning::V$v no está en $MIGRATIONS_DIR; se omite"
    continue
  fi
  is_applied "$v" && REQUESTED="$REQUESTED $f"
done

REAPPLY=""
if [ -n "${REQUESTED// /}" ]; then
  echo "=== [2/5] expandiendo con las posteriores que redefinen lo mismo ==="
  if command -v python3 >/dev/null 2>&1 && [ -f "$SCRIPT_DIR/migration-reapply-set.py" ]; then
    EXPANDED="$(python3 "$SCRIPT_DIR/migration-reapply-set.py" $REQUESTED)"
  else
    echo "::warning::sin python3: se re-aplican solo las cambiadas, sin las posteriores que redefinen sus objetos"
    EXPANDED="$(printf '%s\n' $REQUESTED)"
  fi
  for f in $EXPANDED; do
    is_applied "$(version_of "$f")" && REAPPLY="$REAPPLY $f"
  done
  REAPPLY="$(printf '%s\n' $REAPPLY | sort_by_version | tr '\n' ' ')"
fi

if [ -n "${REAPPLY// /}" ]; then
  echo "=== [3/5] re-aplicando (una transacción, antes de las pendientes) ==="
  echo "$REAPPLY" | tr ' ' '\n' | sed '/^$/d; s/^/  /'
  # RESET ALL entre ficheros: cada migración arranca con la sesión limpia,
  # como cuando flyway o un psql por fichero la corren. El ';' suelto cierra
  # una última sentencia sin punto y coma, que flyway acepta.
  {
    echo "BEGIN;"
    for f in $REAPPLY; do
      printf '\\echo -> %s\n' "$f"
      cat "$MIGRATIONS_DIR/$f"
      printf '\n;\nRESET ALL;\n'
    done
    echo "COMMIT;"
  } | psqlq -q -f - || {
    echo "::error::falló la re-aplicación; la transacción se deshizo y la base quedó como estaba"
    exit 1
  }
else
  echo "=== [3/5] nada que re-aplicar ==="
fi

echo "=== [4/5] repair (solo si la validación sin pendientes falla) ==="
if fw validate -outOfOrder=true '-ignoreMigrationPatterns=*:pending,*:future' >/dev/null 2>&1; then
  echo "historial consistente: sin repair"
else
  fw repair
fi

echo "=== [5/5] migrate + validate ==="
fw -outOfOrder=true migrate
fw validate -outOfOrder=true
echo "flyway OK: el esquema coincide con $MIGRATIONS_DIR"
