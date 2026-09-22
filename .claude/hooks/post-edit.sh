#!/usr/bin/env bash
# PostToolUse (Write|Edit): codificacion + lint de invariantes del fichero tocado.
#
# Solo actua sobre postgres/migrations/*.sql. Devuelve el hallazgo por stderr
# con exit 2 cuando hay ERRORES, que es como el harness se lo hace llegar al
# agente para que corrija antes de seguir. Los avisos salen por stdout y no
# interrumpen.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
payload="$(cat)"

file=$(printf '%s' "$payload" | python -c "
import json,sys
try:
    d = json.load(sys.stdin)
except ValueError:
    sys.exit()
ti = d.get('tool_input') or {}
print(ti.get('file_path') or ti.get('notebook_path') or '')
" 2>/dev/null)

[ -n "$file" ] && [ -f "$file" ] || exit 0

# 1. Codificacion. En esta maquina el locale es cp1252 y un fichero guardado
#    con el locale equivocado llega a produccion con el texto roto: un
#    RAISE EXCEPTION mal codificado nadie lo ve hasta que revienta.
case "$file" in
  *.sql|*.md|*.json|*.java|*.yml|*.yaml)
    if LC_ALL=C grep -qP 'Ã[-¿]|Ã¢â¬' "$file" 2>/dev/null; then
      echo "Codificacion rota en $(basename "$file"): hay secuencias tipo 'Ã©' / 'â€“'." >&2
      echo "El fichero se guardo como cp1252 en vez de UTF-8. Reescribelo en UTF-8." >&2
      exit 2
    fi ;;
esac

# 2. YAML con claves duplicadas. PyYAML se queda con la ultima y no avisa, asi
#    que un merge que concatena dos bloques hermanos pasa la revision y tumba
#    el servicio en el arranque (paso con el application.yml de reporting).
case "$file" in
  *.yml|*.yaml)
    if ! out=$(python "$REPO/.claude/hooks/yaml_estricto.py" "$file" 2>&1); then
      echo "YAML con clave duplicada en $(basename "$file"):" >&2
      echo "$out" >&2
      echo "PyYAML se queda con la ultima definicion sin avisar; en el servidor" >&2
      echo "el servicio no arranca. Une los bloques en uno solo." >&2
      exit 2
    fi ;;
esac

# 2. Invariantes de migracion.
case "$file" in
  *postgres/migrations/*.sql) ;;
  *) exit 0 ;;
esac

out=$(python "$REPO/scripts/migration-lint.py" "$file" --quiet-ok 2>&1)
code=$?

[ -z "$out" ] && exit 0

if [ $code -ne 0 ]; then
  echo "migration-lint encontro invariantes rotas en $(basename "$file"):" >&2
  echo "$out" >&2
  echo "" >&2
  echo "Corrigelas antes de continuar. Si en este caso concreto la regla no" >&2
  echo "aplica, dilo explicitamente y sigue; no la silencies en el script." >&2
  exit 2
fi

echo "$out"
exit 0
