#!/usr/bin/env bash
# =============================================================================
# promote-test-to-main.sh — Asistente para promover los commits acumulados
# en la rama `test` a `main`. Ver CONTRIBUTING.md §3.5.
#
# Modo de uso recomendado: crea una PR `test → main` con el cuerpo
# prellenado, para que el cambio pase por code review + CI. Sólo en
# emergencias se hace el atajo (--ff-only) de merge directo.
#
# Uso:
#   ./scripts/promote-test-to-main.sh               # flujo PR (recomendado)
#   ./scripts/promote-test-to-main.sh --emergency   # fast-forward directo
#
# Requisitos: gh autenticado (scope `repo`), git, red a github.com.
# =============================================================================
set -euo pipefail

EMERGENCY=0
[[ "${1:-}" == "--emergency" ]] && EMERGENCY=1

REPO="djromerom/sso_postgres"
TEST="test"
MAIN="main"

echo "→ Sincronizando refs locales..."
git fetch origin "$TEST" "$MAIN"

echo
echo "→ Commits a promover (en 'test' pero no en 'main'):"
git log --oneline "origin/${MAIN}..origin/${TEST}"
COMMIT_COUNT=$(git rev-list --count "origin/${MAIN}..origin/${TEST}")
echo
echo "Total: ${COMMIT_COUNT} commits."

if [[ "$COMMIT_COUNT" -eq 0 ]]; then
  echo
  echo "✓ Nada para promover — 'test' ya está al día con 'main'."
  exit 0
fi

if [[ "$EMERGENCY" -eq 1 ]]; then
  echo
  echo "⚠ Modo EMERGENCY: fast-forward directo a main. Se salta code review."
  echo "  Sólo para cuando la PR de promoción se rechaza persistentemente"
  echo "  o hay una incidencia P0 que no puede esperar. Verifica:"
  echo "    - 'test' está verde en CI."
  echo "    - staging env (si existe) pasó el smoke suite."
  echo
  read -r -p "Confirmar fast-forward '${MAIN}' → '${TEST}' ahora? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "Cancelado."; exit 1; }

  echo
  echo "→ Fast-forwarding ${MAIN} a ${TEST}..."
  git checkout "$MAIN"
  git merge --ff-only "origin/${TEST}"
  git push origin "$MAIN"

  echo
  echo "✓ Listo. Tag el release con Semantic Versioning."
  echo "  Próximo paso:"
  echo "    git tag -a vX.Y.Z -m 'vX.Y.Z: <one-liner>' && git push origin vX.Y.Z"
else
  echo
  echo "→ Modo PR (recomendado): abro una PR 'test → main' y te devuelvo la URL."
  echo "  Verificá que los commits de arriba son los que querés promover antes"
  echo "  de aprobar en GitHub."
  echo

  gh pr create \
    --repo "$REPO" \
    --base "$MAIN" \
    --head "$TEST" \
    --title "chore(release): promote test → main" \
    --body "Promoción procedural de los ${COMMIT_COUNT} commits acumulados en \`test\` desde la última promoción. Esta PR no tiene código propio — el contenido está en los commits listados arriba.

## Checklist de release

- [ ] \`test\` verde en CI (los 8 checks)
- [ ] staging env (si existe) pasó el smoke suite
- [ ] Se leyó \`git log origin/main..origin/test --oneline\` y los commits son los esperados
- [ ] No hay migraciones Flyway pendientes en el rango a promover (ver §4 de CONTRIBUTING)
- [ ] Tag SemVer preparado (Ver §5) — version bump en \`.env.example\` y docker manifests

## Después del merge

1. \`git tag -a vX.Y.Z\` desde el merge commit
2. \`git push origin vX.Y.Z\`
3. \`gh release create vX.Y.Z --notes-from-tag\`

Si esta PR se cierra sin mergear, se aborta el release y los
commits siguen en \`test\` para la próxima ventana."

  echo
  echo "✓ PR creada. Andá a GitHub para revisarla y aprobarla."
fi
