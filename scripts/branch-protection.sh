#!/usr/bin/env bash
# =============================================================================
# branch-protection.sh — Aplica (o reaplica) la branch protection sobre `main`
# Y `test` en djromerom/sso_postgres, dejando el repositorio con las reglas
# descritas en CONTRIBUTING.md §1 y §3.3.
#
# Lo dispara el **maintainer** manualmente, no un PR. Por seguridad este
# script se queda commiteado y se ejecuta después de mergear la PR de
# infraestructura que trae el workflow `ci.yml`:
#
#   1. Fusionar la PR de infraestructura que trae el workflow `ci.yml`
#      (PR #4 en este repo).
#   2. Asegurarse de que ambas ramas (`main` y `test`) existen en el
#      remote. Si `test` no existe, crearla:
#        git branch test origin/main && git push -u origin test
#   3. Ejecutar este script:
#
#        gh auth login --scopes repo,workflow   # una sola vez
#        ./scripts/branch-protection.sh
#
#   4. La próxima PR contra `main` o `test` ya estará sujeta a los checks
#      listados en `required_status_checks.contexts`.
#
# Idempotente: `gh api -X PUT` reemplaza la configuración existente. Se
# puede correr de nuevo para actualizar la lista de checks cuando entren
# checks nuevos (p.ej. cuando se añada `admin-ui-e2e`).
#
# Requisitos: `gh` ≥ 2.40 autenticado con scope `repo`.
# =============================================================================
set -euo pipefail

REPO="djromerom/sso_postgres"

# El mismo payload se aplica a main y a test (mismas reglas: misma
# rigurosidad en integración que en release; la única diferencia entre
# ambas vive en la regla de origen de PRs, NO en la protección).
#
# Nota sobre "restrictions" en repos personales (no-org):
# - La API exige que el field esté presente. Para un repo personal
#   (no-org) lo correcto es `"restrictions": null` ("no aplica
#   restricciones de usuarios/teams"). Un objeto vacío `{}` se
#   rechaza con 422 ("teams, users weren't supplied") y un objeto
#   con arrays vacíos es ambiguo según la versión de la API.
# - "dismissal_restrictions" se omite por completo: solo tiene
#   sentido si `restrictions` apunta a usuarios/teams concretos.
#   Si el repo migra a una organización y se quiere limitar quién
#   puede pushear, reemplazar `null` por
#   `{"users": ["..."], "teams": ["..."]}` y volver a añadir
#   `dismissal_restrictions` con los mismos identifiers.
PAYLOAD=$(cat <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "contexts": [
      "maven-common",
      "maven-auth-center",
      "maven-sso-admin",
      "maven-api-gateway",
      "admin-ui-typecheck",
      "admin-ui-test",
      "admin-ui-lint",
      "admin-ui-build"
    ]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": false,
    "required_approving_review_count": 1,
    "require_last_push_approval": false
  },
  "restrictions": null,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "block_creations": false,
  "required_conversation_resolution": true,
  "lock_branch": false,
  "allow_fork_syncing": false
}
JSON
)

# Aplica el payload a una rama; imprime resumen si la operación fue
# exitosa. No aborta el run si una rama falla (idempotencia: ya
# protegida o no existente).
apply_protection() {
  local branch="$1"
  echo
  echo "──── ${REPO}:${branch} ────"
  echo "→ Aplicando protection..."
  if ! printf '%s' "${PAYLOAD}" | gh api \
      -X PUT \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "/repos/${REPO}/branches/${branch}/protection" \
      --input - >/dev/null; then
    echo "⚠ Falló la protección de '${branch}' (probablemente la rama no existe en el remote todavía). Saltando."
    return 1
  fi
  echo "→ Verificando la configuración aplicada..."
  gh api "/repos/${REPO}/branches/${branch}/protection" \
    | jq '{
      required_status_checks: (.required_status_checks.contexts),
      required_approving_review_count: .required_pull_request_reviews.required_approving_review_count,
      dismiss_stale_reviews: .required_pull_request_reviews.dismiss_stale_reviews,
      required_linear_history: .required_linear_history,
      allow_force_pushes: .allow_force_pushes,
      allow_deletions: .allow_deletions,
      enforce_admins: .enforce_admins,
      required_conversation_resolution: .required_conversation_resolution
    }'
}

apply_protection "main"
apply_protection "test"

echo
echo "✓ Listo. Próximas PRs contra 'main' o 'test' requieren los checks listados y 1 review."
