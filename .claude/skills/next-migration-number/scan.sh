#!/usr/bin/env bash
# Siguiente numero de migracion Flyway libre, mirando TODAS las ramas de origin
# y las PRs abiertas. Uso: bash .claude/skills/next-migration-number/scan.sh
set -euo pipefail

MIGRATIONS_DIR="postgres/migrations"

echo "== git fetch --all --prune --quiet =="
git fetch --all --prune --quiet

max_global=0
all_nums=""

# V<n> mas alto de postgres/migrations/ en cada rama remota.
while read -r ref; do
  [ -z "$ref" ] && continue
  nums=$(git ls-tree -r --name-only "$ref" -- "$MIGRATIONS_DIR" 2>/dev/null \
    | grep -oE '/V[0-9]+' | grep -oE '[0-9]+' | sort -n || true)
  [ -z "$nums" ] && continue
  top=$(echo "$nums" | tail -1)
  all_nums="$all_nums$nums"$'\n'
  printf '  %-45s V%s\n' "${ref#refs/remotes/}" "$top"
  [ "$top" -gt "$max_global" ] && max_global=$top
done < <(git for-each-ref --format='%(refname)' refs/remotes/origin)

# Working tree local, por si hay migraciones sin commitear.
local_nums=$(ls "$MIGRATIONS_DIR" 2>/dev/null | grep -oE '^V[0-9]+' \
  | grep -oE '[0-9]+' | sort -n || true)
local_top=$(echo "$local_nums" | tail -1)
all_nums="$all_nums$local_nums"$'\n'
printf '  %-45s V%s\n' "(working tree local)" "${local_top:-0}"
[ "${local_top:-0}" -gt "$max_global" ] && max_global=$local_top

echo
echo "V<n> maximo global : V${max_global}"
echo "Siguiente libre    : V$((max_global + 1))   <- usa este"

# Huecos: numeros por debajo del techo que ninguna rama usa.
holes=$(echo "$all_nums" | grep -E '^[0-9]+$' \
  | awk -v top="$max_global" '{u[$1+0]=1} END {for (i=1;i<=top;i++) if (!(i in u)) printf "%s ", i}')
if [ -n "${holes// /}" ]; then
  echo
  echo "Huecos por debajo del techo (NO son libres por defecto):"
  echo "  $holes"
  echo "  Un hueco casi siempre viene de una rama borrada o de una migracion ya"
  echo "  aplicada en un servidor. Solo se reutiliza out-of-order deliberadamente"
  echo "  (para colarse antes de una migracion existente) y confirmando primero"
  echo "  con /server-status que ese V<n> no esta en flyway_schema_history."
fi

# PRs abiertas: pueden tener migraciones que aun no estan en origin/*.
if command -v gh >/dev/null 2>&1; then
  echo
  echo "== migraciones en PRs abiertas =="
  gh pr list --state open --json number,headRefName --jq '.[] | "\(.number) \(.headRefName)"' 2>/dev/null \
  | while read -r num branch; do
      files=$(gh pr diff "$num" --name-only 2>/dev/null | grep -oE 'V[0-9]+[0-9.]*__[^/]*' | tr '\n' ' ' || true)
      [ -n "${files// /}" ] && printf '  PR #%-5s %-35s %s\n' "$num" "$branch" "$files"
    done
else
  echo
  echo "OJO: sin 'gh' no se revisaron las PRs abiertas -> gh pr list"
fi

echo
echo "Antes de fijar el numero: ¿el cambio pertenece a una migracion que ya existe?"
echo "  python .claude/skills/next-migration-number/deps.py <fn_o_ruta>"
