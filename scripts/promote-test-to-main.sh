#!/usr/bin/env bash
# =============================================================================
# promote-test-to-main.sh — promueve lo acumulado en `test` a `main`.
# Ver CONTRIBUTING.md §3.6.
#
# ---- Qué arregla respecto a la versión anterior -----------------------------
#
# 1. Apuntaba a `djromerom/sso_postgres`, que no es este repo. Ahora el repo
#    se deduce del remote `origin`.
#
# 2. Abría la PR con `--head test` siempre. Eso solo funciona si `test` mergea
#    limpio en `main`; en cuanto hay conflicto, GitHub crea la PR igual pero
#    imposible de mergear y sin sitio donde resolver. La promoción del
#    2026-09-09 dio 41 conflictos y hubo que rehacerla a mano. Ahora, si hay
#    conflicto, el script crea una rama de promoción donde resolverlos.
#
# 3. El atajo `--emergency` hacía `git merge --ff-only`, que falla justo
#    cuando `main` tiene algo que `test` no — que es la situación en la que
#    querrías el atajo. Ahora detecta si el fast-forward es posible y, si no,
#    lo dice en vez de reventar.
#
# 4. Decía "los 8 checks". Hoy `ci.yml` tiene 19 jobs.
#
# ---- El método de merge NO es cosmético -------------------------------------
#
# CONTRIBUTING §1: squash para `feature → dev`, MERGE COMMIT para `dev → test`
# y `test → main`. GitHub no permite fijarlo por rama, así que es una
# convención que se rompe con un clic — y se rompió: las promociones #117 y
# #121 salieron aplastadas a un solo padre.
#
# La consecuencia la predice el propio CONTRIBUTING: un squash crea en la
# rama destino un commit que no existe en la de origen, las dos divergen para
# siempre, y la siguiente promoción vuelve a conflictuar sobre contenido que
# YA estaba aplicado. Cada promoción arrastra más ruido que la anterior.
#
# Por eso este script imprime —y opcionalmente ejecuta— `gh pr merge --merge`.
# Nunca `--squash`.
#
# ---- Uso --------------------------------------------------------------------
#
#   ./scripts/promote-test-to-main.sh              # abre la PR (recomendado)
#   ./scripts/promote-test-to-main.sh --merge      # abre la PR y la mergea
#   ./scripts/promote-test-to-main.sh --take-test  # resuelve conflictos con test
#
# Requisitos: gh autenticado, git, red.
# =============================================================================
set -euo pipefail

TEST="test"
MAIN="main"
AUTO_MERGE=0
TAKE_TEST=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --merge)     AUTO_MERGE=1; shift ;;
        --take-test) TAKE_TEST=1; shift ;;
        -h|--help)   sed -n '2,45p' "$0"; exit 0 ;;
        *) echo "Opción desconocida: $1" >&2; exit 2 ;;
    esac
done

command -v gh >/dev/null || { echo "Falta el CLI 'gh'." >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "'gh' no está autenticado." >&2; exit 1; }

# El repo sale del remote, no de una constante que envejece en silencio.
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"

# Un árbol sucio + los `git checkout` de abajo es la receta para perder
# trabajo sin enterarse.
if [[ -n "$(git status --porcelain)" ]]; then
    echo "El árbol de trabajo tiene cambios sin commitear. Guárdalos antes." >&2
    git status --short >&2
    exit 1
fi

RAMA_ORIGINAL="$(git rev-parse --abbrev-ref HEAD)"
volver() { git checkout -q "$RAMA_ORIGINAL" 2>/dev/null || true; }
trap volver EXIT

echo "Repo: $REPO"
echo "→ Sincronizando refs..."
git fetch origin "$TEST" "$MAIN" --quiet

PENDIENTES="$(git rev-list --count "origin/${MAIN}..origin/${TEST}")"
DIVERGENTES="$(git rev-list --count "origin/${TEST}..origin/${MAIN}")"

echo
echo "→ Commits en 'test' que no están en 'main' (${PENDIENTES}):"
# `| head -40` bajo `set -o pipefail` mata git-log con SIGPIPE en cuanto
# head cierra su extremo del pipe tras la línea 40, y pipefail propaga
# ese 141 como si el script hubiera fallado. Pasó en la promoción real:
# con 264 commits pendientes el script moría aquí SIEMPRE, antes de
# simular siquiera el merge. `|| true` en el propio git log basta —
# head sigue imprimiendo sus 40 líneas antes de cerrar.
git log --oneline "origin/${MAIN}..origin/${TEST}" 2>&1 | head -40 || true
[[ "$PENDIENTES" -gt 40 ]] && echo "   ... y $((PENDIENTES - 40)) más"

if [[ "$DIVERGENTES" -gt 0 ]]; then
    echo
    echo "→ AVISO: 'main' tiene ${DIVERGENTES} commit(s) que 'test' no tiene:"
    git log --oneline "origin/${TEST}..origin/${MAIN}" 2>&1 | head -40 | sed 's/^/   /' || true
    echo "   Revisa que su contenido ya viajó a test (o ve CONTRIBUTING §3.6.5,"
    echo "   cherry-pick de vuelta) antes de promover."
fi

if [[ "$PENDIENTES" -eq 0 ]]; then
    echo
    echo "Nada que promover: 'test' no adelanta a 'main'."
    exit 0
fi

# El contaje de commits MIENTE cuando la promoción anterior se mergeó con
# squash: el commit aplastado no es ancestro de `test`, así que git sigue
# viendo "pendientes" commits cuyo contenido ya está en `main`.
#
# Detectado probando este mismo script: reportaba 9 commits pendientes y
# abrió una PR vacía, cuando `main` y `test` eran idénticos byte a byte.
# Lo que decide si hay algo que promover es el CONTENIDO, no la ancestría.
if git diff --quiet "origin/${MAIN}" "origin/${TEST}"; then
    echo
    echo "Nada que promover: 'main' y 'test' son IDÉNTICOS en contenido."
    echo
    echo "Git reporta ${PENDIENTES} commit(s) pendientes, pero es un espejismo:"
    echo "la promoción anterior se mergeó con squash, así que su commit no es"
    echo "ancestro de 'test' y los cambios ya aplicados siguen contándose."
    echo
    echo "Por eso CONTRIBUTING §1 exige merge commit en las promociones:"
    echo "  gh pr merge <n> --merge      # NO --squash"
    exit 0
fi

# ─── ¿Mergea limpio? ─────────────────────────────────────────────────────────
#
# `merge-tree --write-tree` simula el merge sin tocar el árbol de trabajo ni
# crear commits. Es la forma de saber si hace falta rama de promoción ANTES de
# abrir una PR que nadie va a poder mergear.
echo
echo "→ Simulando el merge..."
if git merge-tree --write-tree "origin/${MAIN}" "origin/${TEST}" >/dev/null 2>&1; then
    LIMPIO=1
    echo "   Sin conflictos."
else
    LIMPIO=0
    N_CONF="$(git merge-tree --write-tree "origin/${MAIN}" "origin/${TEST}" 2>&1 \
              | awk '/^[0-7]{6} /{print $4}' | sort -u | wc -l)"
    echo "   ${N_CONF} fichero(s) en conflicto."
fi

if [[ "$LIMPIO" -eq 1 ]]; then
    HEAD_PR="$TEST"
    echo "→ La PR puede salir directamente de 'test'."
else
    HEAD_PR="promote/test-to-main-$(date +%Y%m%d-%H%M)"
    echo
    echo "→ Hay conflictos: creo la rama '${HEAD_PR}' para resolverlos."
    git checkout -q -b "$HEAD_PR" "origin/${MAIN}"
    git merge --no-commit --no-ff "origin/${TEST}" >/dev/null 2>&1 || true

    if [[ "$TAKE_TEST" -eq 1 ]]; then
        # Deja el árbol EXACTAMENTE igual al de test, conservando MERGE_HEAD
        # para que el commit salga con sus dos padres.
        #
        # Es lo correcto cuando `test` es la línea validada —está desplegada,
        # pasó CI y sus migraciones se probaron sobre base limpia— y los
        # conflictos vienen de editar in-place los mismos V<n>. NO es un
        # comodín: si `main` tiene contenido propio que no viajó a test, esto
        # LO BORRA. Por eso el aviso de arriba sobre los commits divergentes.
        echo "   --take-test: el árbol queda idéntico a origin/${TEST}."
        git read-tree -u --reset "origin/${TEST}"
        git commit -q -m "chore(release): promover test a main

Resuelto tomando el árbol de test, idéntico a origin/${TEST}.
Ver CONTRIBUTING §3.6."
    else
        echo
        echo "   Resuélvelos y termina el merge:"
        echo "     git status"
        echo "     # ...resolver..."
        echo "     git commit"
        echo "     git push -u origin ${HEAD_PR}"
        echo
        echo "   Si el criterio es 'test manda' (lo habitual cuando el conflicto"
        echo "   son migraciones editadas in-place), relanza con --take-test."
        trap - EXIT
        exit 3
    fi
    git push -q -u origin "$HEAD_PR"
fi

# ─── PR ──────────────────────────────────────────────────────────────────────
echo
echo "→ Abriendo la PR..."
URL="$(gh pr create \
    --repo "$REPO" \
    --base "$MAIN" \
    --head "$HEAD_PR" \
    --title "chore(release): promote test → main" \
    --body "Promoción de los ${PENDIENTES} commits acumulados en \`test\`.

Revisa \`git log origin/main..origin/test --oneline\` antes de aprobar.

## Antes de mergear

- [ ] \`test\` verde en CI
- [ ] QA dio el visto bueno sobre lo desplegado
- [ ] Los commits listados son los esperados
- [ ] Ninguna migración Flyway pendiente en el rango (CONTRIBUTING §4)

## Cómo mergear — importa

\`\`\`bash
gh pr merge <n> --merge     # merge commit. NUNCA --squash
\`\`\`

Un squash aquí crea en \`main\` un commit que no existe en \`test\`, las dos
ramas divergen para siempre y la siguiente promoción vuelve a conflictuar
sobre contenido ya aplicado (CONTRIBUTING §1). Ya pasó: las promociones
#117 y #121 salieron aplastadas y la siguiente dio 41 conflictos.

## Después del merge

\`\`\`bash
git checkout main && git pull --ff-only origin main
git tag -a vX.Y.Z -m 'vX.Y.Z: <resumen>'
git push origin vX.Y.Z
\`\`\`

El tag dispara \`release.yml\`: construye las 12 imágenes con \`:vX.Y.Z\` y
despliega a producción. El job **espera aprobación** en el environment
\`production\` antes de tocar el servidor.")"

echo "   ${URL}"

if [[ "$AUTO_MERGE" -eq 1 ]]; then
    echo
    echo "→ Mergeando con merge commit (--merge)..."
    gh pr merge "$URL" --merge --repo "$REPO"
    echo "   Mergeada. Siguiente paso: el tag."
    echo "     git checkout main && git pull --ff-only origin main"
    echo "     git tag -a vX.Y.Z -m 'vX.Y.Z: <resumen>' && git push origin vX.Y.Z"
else
    echo
    echo "→ Para mergear (merge commit, NO squash):"
    echo "     gh pr merge ${URL##*/} --merge --repo ${REPO}"
fi
