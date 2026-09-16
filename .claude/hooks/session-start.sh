#!/usr/bin/env bash
# SessionStart: contexto minimo para no arrancar a ciegas.
#
# Barato a proposito: NO hace git fetch (eso es scan.sh, que tarda). Solo dice
# en que rama estas, cual es el techo LOCAL de migraciones y si hay migraciones
# sin commitear, que es lo que cambia la primera decision de casi toda sesion.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO" || exit 0

branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')
top=$(ls postgres/migrations 2>/dev/null | grep -oE '^V[0-9]+' | grep -oE '[0-9]+' \
      | sort -n | tail -1)
pending=$(git status --porcelain -- postgres/migrations 2>/dev/null | wc -l | tr -d ' ')

echo "SSO | rama: $branch | techo local de migraciones: V${top:-?}"
[ "${pending:-0}" -gt 0 ] && \
  echo "  ${pending} migracion(es) sin commitear en el working tree."
echo "  Numero libre real (todas las ramas): bash .claude/skills/next-migration-number/scan.sh"
echo "  Quien define un objeto hoy:          python .claude/skills/next-migration-number/deps.py <fn|ruta>"
exit 0
