#!/usr/bin/env bash
# Banco de pruebas de un recorte de migraciones: dos Postgres 16 desechables.
#   A = historial de la rama base (git archive), B = arbol de trabajo.
#
#   banco.sh arranque [ref]        levanta A y B y migra (ref por defecto origin/dev)
#   banco.sh comparar              huella de esquema, permisos y datos: A vs B
#   banco.sh deploy V51 V59 ...    simula el deploy sobre A (repair + outOfOrder +
#                                  re-aplicar los editados dos veces + validate) y compara
#   banco.sh limpiar               borra los contenedores
#
# Destino host.docker.internal: es el que acepta el hook no_prod. Nunca un servidor.
# Variables: BANCO_DIR, BANCO_PORT_A (55431), BANCO_PORT_B (55432).
set -uo pipefail

# Rutas nativas antes de desactivar la conversion de MSYS (Git Bash en Windows):
# `pwd -W` da C:/..., que entienden git y docker; en Linux/macOS basta `pwd`.
HERE="$(cd "$(dirname "$0")" && { pwd -W 2>/dev/null || pwd; })"
REPO="$(git -C "$HERE" rev-parse --show-toplevel)"
export MSYS_NO_PATHCONV=1
WORK="${BANCO_DIR:-${TMPDIR:-/tmp}/sso-banco}"
PA="${BANCO_PORT_A:-55431}"
PB="${BANCO_PORT_B:-55432}"
IMG_PG="postgres:16-alpine"
IMG_FLY="flyway/flyway:11-alpine"

winpath() { command -v cygpath >/dev/null 2>&1 && cygpath -w "$1" || echo "$1"; }

fly() { # puerto dir args...
  local port=$1 dir; dir="$(winpath "$2")"; shift 2
  docker run --rm -v "$dir:/flyway/sql:ro" "$IMG_FLY" \
    -url="jdbc:postgresql://host.docker.internal:$port/t" -user=t -password=t -connectRetries=10 "$@" 2>&1 \
    | grep -E "Successfully|ERROR|Location|Line  |not resolved|checksum mismatch|up to date" | grep -v "^WARNING"
}

psql_in() { docker exec -i "sso-banco-$1" psql -q -U t -d t "${@:2}"; }

arrancar_pg() { # nombre puerto
  docker rm -f "sso-banco-$1" >/dev/null 2>&1
  docker run -d --name "sso-banco-$1" -e POSTGRES_USER=t -e POSTGRES_PASSWORD=t -e POSTGRES_DB=t \
    -p "$2:5432" "$IMG_PG" >/dev/null
  until docker exec "sso-banco-$1" pg_isready -U t -d t >/dev/null 2>&1; do sleep 1; done
}

huella() { # A|B -> $WORK/<X>.{h,b,d}
  psql_in "$1" < "$HERE/huella.sql" | grep -v pg_temp > "$WORK/$1.h"
  psql_in "$1" < "$HERE/binds.sql" > "$WORK/$1.b"
  psql_in "$1" < "$HERE/datos.sql" > "$WORK/$1.d"
}

comparar() {
  huella A; huella B
  local rc=0
  for k in h:esquema b:permisos d:datos; do
    local ext=${k%%:*} nom=${k##*:}
    if diff "$WORK/A.$ext" "$WORK/B.$ext" > "$WORK/diff.$ext"; then
      echo "  $nom: IGUAL ($(wc -l < "$WORK/A.$ext") lineas)"
    else
      echo "  $nom: DIFERENTE -> $WORK/diff.$ext"; head -8 "$WORK/diff.$ext" | cut -c1-200; rc=1
    fi
  done
  return $rc
}

case "${1:-}" in
  arranque)
    ref="${2:-origin/dev}"
    rm -rf "$WORK"; mkdir -p "$WORK/old" "$WORK/new"
    git -C "$REPO" archive "$ref" postgres/migrations | tar -x -C "$WORK/old"
    cp "$REPO"/postgres/migrations/*.sql "$WORK/new/"
    arrancar_pg A "$PA"; arrancar_pg B "$PB"
    echo "== A ($ref)";  fly "$PA" "$WORK/old/postgres/migrations" migrate
    echo "== B (arbol)"; fly "$PB" "$WORK/new" migrate
    ;;
  comparar)
    comparar ;;
  deploy)
    shift; [ $# -gt 0 ] || { echo "uso: banco.sh deploy V<n> ..."; exit 2; }
    cp "$REPO"/postgres/migrations/*.sql "$WORK/new/"
    # en orden de version, como hace el deploy
    vers=$(for v in "$@"; do echo "${v#V}"; done | sort -V)
    files=()
    for v in $vers; do
      f=$(ls "$WORK/new/V${v}__"*.sql 2>/dev/null) || { echo "no existe V$v"; exit 2; }
      files+=("$f")
    done
    echo "== A migrate (se espera fallo)"; fly "$PA" "$WORK/new" migrate
    echo "== A repair";                    fly "$PA" "$WORK/new" repair
    echo "== A migrate -outOfOrder";       fly "$PA" "$WORK/new" -outOfOrder=true migrate
    for pasada in 1 2; do
      for f in "${files[@]}"; do
        echo "== re-aplica ($pasada) $(basename "$f")"
        psql_in A -v ON_ERROR_STOP=1 < "$f" 2>&1 | grep -E "ERROR|FATAL" && { echo "FALLO al re-aplicar"; exit 1; }
      done
    done
    echo "== A validate"; fly "$PA" "$WORK/new" -outOfOrder=true validate
    echo "== A desplegada vs B limpia"; comparar
    ;;
  limpiar)
    docker rm -f sso-banco-A sso-banco-B >/dev/null 2>&1; echo "contenedores borrados" ;;
  *)
    sed -n '2,12p' "$0"; exit 2 ;;
esac
