#!/usr/bin/env bash
# Siguiente numero de migracion Flyway libre, mirando TODAS las ramas de origin
# y las PRs abiertas, decimales incluidos (V496.27 tambien ocupa su numero).
# Uso: bash .claude/skills/next-migration-number/scan.sh
set -euo pipefail

MIGRATIONS_DIR="postgres/migrations"
FILE_RE='V[0-9]+(\.[0-9]+)*__[^/]*\.sql$'

echo "== git fetch --all --prune --quiet =="
git fetch --all --prune --quiet

# Inventario "origen<TAB>version<TAB>fichero" de cada rama y del arbol local.
inventario=$(mktemp)
trap 'rm -f "$inventario"' EXIT

listar() {  # $1 = etiqueta del origen; lee nombres de fichero por stdin
  grep -oE "$FILE_RE" | awk -v o="$1" '{v=$0; sub(/^V/, "", v); sub(/__.*/, "", v); print o "\t" v "\t" $0}'
}

while read -r ref; do
  [ -z "$ref" ] && continue
  git ls-tree -r --name-only "$ref" -- "$MIGRATIONS_DIR" 2>/dev/null \
    | listar "${ref#refs/remotes/}" >> "$inventario" || true
done < <(git for-each-ref --format='%(refname)' refs/remotes/origin)
ls "$MIGRATIONS_DIR" 2>/dev/null | listar "(local)" >> "$inventario" || true

# Maximo por origen: la version mas alta, decimales incluidos.
max_global=0
while IFS=$'\t' read -r origen top; do
  printf '  %-45s V%s\n' "$origen" "$top"
  entero=${top%%.*}
  [ "$entero" -gt "$max_global" ] && max_global=$entero
done < <(sort -t$'\t' -k1,1 -k2,2V "$inventario" | awk -F'\t' '{top[$1]=$2} END {for (o in top) print o "\t" top[o]}' | sort)

echo
echo "V<n> maximo global : V${max_global}"
echo "Siguiente libre    : V$((max_global + 1))   <- techo; para una migracion nueva"
echo "                     mejor un decimal junto a su categoria (ver abajo)"

# Huecos: enteros por debajo del techo que ninguna rama usa (ni como V<n>.x).
holes=$(cut -f2 "$inventario" | cut -d. -f1 | sort -un \
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

# Decimales de otras ramas que el arbol local no tiene: ocupan su numero aunque
# aqui no se vean, y son justo los que chocan con un V<n>.x nuevo.
echo
echo "== decimales en otras ramas que no estan en el arbol local =="
pendientes=$(awk -F'\t' '
  $1 == "(local)" { loc[$2] = 1; next }
  $2 ~ /\./      { if (!($2 in rem)) rem[$2] = $1 }
  END { for (v in rem) if (!(v in loc)) print v "\t" rem[v] }' "$inventario" | sort -V)
if [ -n "$pendientes" ]; then
  echo "$pendientes" | awk -F'\t' '{printf "  V%-12s %s\n", $1, $2}'
else
  echo "  ninguno"
fi

# Misma version con ficheros distintos en ramas distintas: Flyway rechaza el
# despliegue en cuanto se fusiona la segunda (V523).
colisiones=$(awk -F'\t' '{k = $2 SUBSEP $3; if (!(k in visto)) { visto[k] = 1; n[$2]++; f[$2] = f[$2] " " $3 } }
  END { for (v in n) if (n[v] > 1) print "  V" v ":" f[v] }' "$inventario" | sort -V)
if [ -n "$colisiones" ]; then
  echo
  echo "!! misma version con ficheros distintos (colision al fusionar):"
  echo "$colisiones"
fi

# PRs abiertas: pueden tener migraciones que aun no estan en origin/*.
if command -v gh >/dev/null 2>&1; then
  echo
  echo "== migraciones en PRs abiertas =="
  gh pr list --state open --json number,headRefName --jq '.[] | "\(.number) \(.headRefName)"' 2>/dev/null \
  | while read -r num branch; do
      files=$(gh pr diff "$num" --name-only 2>/dev/null | grep -oE "$FILE_RE" | tr '\n' ' ' || true)
      [ -n "${files// /}" ] && printf '  PR #%-5s %-35s %s\n' "$num" "$branch" "$files"
    done
else
  echo
  echo "OJO: sin 'gh' no se revisaron las PRs abiertas -> gh pr list"
fi

echo
echo "Numero para una migracion NUEVA junto a su categoria (piso por dependencias):"
echo "  python scripts/migration-analysis hueco --categoria <id> [--objeto fn_x ...]"
echo "Antes de fijar el numero: ¿el cambio pertenece a una migracion que ya existe?"
echo "  python .claude/skills/next-migration-number/deps.py <fn_o_ruta>"
