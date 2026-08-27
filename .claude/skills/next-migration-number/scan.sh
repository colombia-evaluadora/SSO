#!/usr/bin/env bash
# Siguiente número de migración Flyway libre, mirando TODAS las ramas de origin.
# Uso: bash .claude/skills/next-migration-number/scan.sh
set -euo pipefail

MIGRATIONS_DIR="postgres/migrations"

echo "== git fetch --all --prune --quiet =="
git fetch --all --prune --quiet

max_global=0

# Recorre cada rama remota y saca el V<n> más alto de postgres/migrations/.
while read -r ref; do
  [ -z "$ref" ] && continue
  nums=$(git ls-tree -r --name-only "$ref" -- "$MIGRATIONS_DIR" 2>/dev/null \
    | grep -oE '/V[0-9]+' | grep -oE '[0-9]+' | sort -n || true)
  [ -z "$nums" ] && continue
  top=$(echo "$nums" | tail -1)
  printf '  %-45s V%s\n' "${ref#refs/remotes/}" "$top"
  [ "$top" -gt "$max_global" ] && max_global=$top
done < <(git for-each-ref --format='%(refname)' refs/remotes/origin)

# Incluye también el working tree local por si hay migraciones sin commitear.
local_top=$(ls "$MIGRATIONS_DIR" 2>/dev/null | grep -oE '^V[0-9]+' \
  | grep -oE '[0-9]+' | sort -n | tail -1 || echo 0)
printf '  %-45s V%s\n' "(working tree local)" "$local_top"
[ "${local_top:-0}" -gt "$max_global" ] && max_global=$local_top

echo
echo "V<n> máximo global : V${max_global}"
echo "Siguiente libre    : V$((max_global + 1))"
echo
echo "OJO: revisa PRs abiertas que aún no estén en origin/*  ->  gh pr list"
