#!/usr/bin/env bash
#
# setup-environment-secrets.sh — puebla los secretos de un GitHub
# Environment (`test` o `production`) para el pipeline de despliegue.
#
# ─── Por qué existe ──────────────────────────────────────────────────
#
# Hasta ahora los secretos vivían a nivel de repositorio con nombres
# atados a un entorno concreto (TEST_SSH_HOST, TEST_ENV_FILE…), así que
# no servían para un segundo destino: había que inventar PROD_* y
# duplicar la lógica del workflow. Con secretos por environment, los
# NOMBRES son los mismos y lo que cambia es el VALOR, de modo que un
# único workflow reutilizable sirve para los dos.
#
# ─── Lo que crea ─────────────────────────────────────────────────────
#
#   SSH_TARGET   usuario@host del servidor (fusiona los antiguos
#                TEST_SSH_USER y TEST_SSH_HOST, que el workflow ya
#                concatenaba en cada uso)
#   SSH_KEY      clave privada OpenSSH SOLO para deploy
#   ENV_FILE     contenido completo de /opt/sso/.env
#
# Esos TRES son todo lo que el pipeline necesita. No hay secretos de
# repositorio; lo único que se lee además es el GITHUB_TOKEN que GitHub
# inyecta solo en cada run.
#
#   - GHCR_PULL_USER / GHCR_PULL_TOKEN no se crean: el `docker login` del
#     servidor usa ese GITHUB_TOKEN efímero, así que no queda ninguna
#     credencial de larga vida en la máquina.
#
#   - SMTP_ZEPTOMAIL_USER / SMTP_ZEPTOMAIL_PASS tampoco: van DENTRO del
#     .env, y por tanto dentro de ENV_FILE. Rotar el token es editar la
#     línea en el servidor y volver a correr este script con
#     --from-server.
#
# ─── Uso ─────────────────────────────────────────────────────────────
#
#   # test: toma el .env del servidor que YA está corriendo
#   ./scripts/setup-environment-secrets.sh test \
#       --ssh-target deploy@172.233.184.248 \
#       --from-server root@172.233.184.248
#
#   # production: parte de una plantilla local que tú has preparado
#   ./scripts/setup-environment-secrets.sh production \
#       --ssh-target deploy@2.25.181.178 \
#       --env-file ./produccion.env \
#       --ssh-key ~/.ssh/sso_deploy_prod
#
# Ningún valor se imprime por pantalla: todo viaja por STDIN hacia
# `gh secret set`, que es la única forma de que no acabe en el historial
# del shell ni en la lista de procesos.
#
set -euo pipefail

REPO="${REPO:-colombia-evaluadora/SSO}"

ENTORNO="${1:-}"
shift || true

SSH_TARGET=""
SSH_KEY_PATH=""
ENV_FILE_PATH=""
DESDE_SERVIDOR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ssh-target)   SSH_TARGET="$2"; shift 2 ;;
        --ssh-key)      SSH_KEY_PATH="$2"; shift 2 ;;
        --env-file)     ENV_FILE_PATH="$2"; shift 2 ;;
        --from-server)  DESDE_SERVIDOR="$2"; shift 2 ;;
        *) echo "Opción desconocida: $1" >&2; exit 2 ;;
    esac
done

if [[ "$ENTORNO" != "test" && "$ENTORNO" != "production" ]]; then
    echo "Uso: $0 <test|production> --ssh-target usuario@host [opciones]" >&2
    echo "     --from-server root@host   lee /opt/sso/.env de ese servidor" >&2
    echo "     --env-file RUTA           usa un fichero local como ENV_FILE" >&2
    echo "     --ssh-key RUTA            clave privada de deploy" >&2
    exit 2
fi

command -v gh >/dev/null || { echo "Falta el CLI 'gh'." >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "'gh' no está autenticado." >&2; exit 1; }

# El environment tiene que existir antes de colgarle secretos, pero se
# crea SOLO si falta. Un `PUT` a ciegas sobre uno que ya existe puede
# llevarse por delante sus reglas de protección (revisores obligatorios,
# política de rama) según qué mande el cuerpo, y este script no es quien
# debe tocar eso: su trabajo son los secretos.
if ! gh api "repos/$REPO/environments/$ENTORNO" >/dev/null 2>&1; then
    echo "El entorno '$ENTORNO' no existe; creándolo SIN reglas de protección."
    echo "Configura revisores y política de rama en Settings -> Environments."
    gh api -X PUT "repos/$REPO/environments/$ENTORNO" >/dev/null
fi

echo "Entorno: $ENTORNO  (repo $REPO)"

# ─── SSH_TARGET ──────────────────────────────────────────────────────
if [[ -n "$SSH_TARGET" ]]; then
    if [[ "$SSH_TARGET" != *@* ]]; then
        echo "--ssh-target debe tener la forma usuario@host" >&2; exit 2
    fi
    printf '%s' "$SSH_TARGET" | gh secret set SSH_TARGET --env "$ENTORNO" --repo "$REPO"
    echo "  SSH_TARGET  ok  ($SSH_TARGET)"
fi

# ─── SSH_KEY ─────────────────────────────────────────────────────────
if [[ -n "$SSH_KEY_PATH" ]]; then
    [[ -f "$SSH_KEY_PATH" ]] || { echo "No existe $SSH_KEY_PATH" >&2; exit 1; }
    # Una clave pública aquí dejaría el deploy fallando con un error
    # críptico de autenticación media hora después. Mejor cortar ya.
    if ! grep -q 'PRIVATE KEY' "$SSH_KEY_PATH"; then
        echo "$SSH_KEY_PATH no parece una clave PRIVADA OpenSSH" >&2; exit 1
    fi
    gh secret set SSH_KEY --env "$ENTORNO" --repo "$REPO" < "$SSH_KEY_PATH"
    echo "  SSH_KEY     ok  (desde $SSH_KEY_PATH)"
fi

# ─── ENV_FILE ────────────────────────────────────────────────────────
if [[ -n "$DESDE_SERVIDOR" && -n "$ENV_FILE_PATH" ]]; then
    echo "--from-server y --env-file son excluyentes" >&2; exit 2
fi

verificar_env() {
    # Lee el .env por STDIN, comprueba que no le faltan claves respecto a
    # .env.example y lo reemite. Sin esto, el fallo típico es el que ya
    # ocurrió: el servidor arrancó sin SSO_EMAIL_APP_NAME y compose lo
    # dejó en blanco sin que nadie se enterara hasta ver un correo.
    local tmp; tmp="$(mktemp)"
    cat > "$tmp"
    if [[ -f .env.example ]]; then
        local faltan
        faltan="$(comm -23 \
            <(grep -oE '^[A-Z_0-9]+=' .env.example | tr -d '=' | sort -u) \
            <(grep -oE '^[A-Z_0-9]+=' "$tmp"       | tr -d '=' | sort -u) || true)"
        if [[ -n "$faltan" ]]; then
            echo "  AVISO: faltan claves que .env.example sí documenta:" >&2
            echo "$faltan" | sed 's/^/    - /' >&2
            echo "  (no se aborta: puede ser intencionado, pero revísalo)" >&2
        fi
    fi
    cat "$tmp"
    rm -f "$tmp"
}

if [[ -n "$DESDE_SERVIDOR" ]]; then
    ssh -o BatchMode=yes "$DESDE_SERVIDOR" 'cat /opt/sso/.env' \
        | verificar_env \
        | gh secret set ENV_FILE --env "$ENTORNO" --repo "$REPO"
    echo "  ENV_FILE    ok  (leído de $DESDE_SERVIDOR:/opt/sso/.env)"
elif [[ -n "$ENV_FILE_PATH" ]]; then
    [[ -f "$ENV_FILE_PATH" ]] || { echo "No existe $ENV_FILE_PATH" >&2; exit 1; }
    verificar_env < "$ENV_FILE_PATH" \
        | gh secret set ENV_FILE --env "$ENTORNO" --repo "$REPO"
    echo "  ENV_FILE    ok  (desde $ENV_FILE_PATH)"
fi

echo
echo "Secretos en el entorno '$ENTORNO':"
gh api "repos/$REPO/environments/$ENTORNO/secrets" \
    -q '.secrets[]? | "  - " + .name + "  (actualizado " + .updated_at + ")"'
