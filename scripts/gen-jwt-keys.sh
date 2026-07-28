#!/usr/bin/env bash
#
# Genera el par de claves RSA que firma y verifica los JWT del SSO.
#
#   ./scripts/gen-jwt-keys.sh            # escribe en ./secrets/
#   ./scripts/gen-jwt-keys.sh --env      # además imprime las líneas para .env
#
# La privada la consume SOLO auth-center (JWT_PRIVATE_KEY); la pública
# va a api-gateway, sso-admin y query-service (JWT_PUBLIC_KEY). Ese
# reparto es el motivo de pasar de HS256 a RS256: un verificador
# comprometido ya no puede emitir tokens.
#
# 2048 bits es el mínimo que exige jjwt para RS256 y lo que recomienda
# NIST SP 800-57 para material vigente más allá de 2030.

set -euo pipefail

OUT_DIR="${JWT_KEY_DIR:-secrets}"
PRIVATE_PEM="$OUT_DIR/jwt-private.pem"
PUBLIC_PEM="$OUT_DIR/jwt-public.pem"

if ! command -v openssl >/dev/null 2>&1; then
    echo "ERROR: se necesita openssl en el PATH." >&2
    exit 1
fi

mkdir -p "$OUT_DIR"

if [[ -f "$PRIVATE_PEM" ]]; then
    echo "ERROR: $PRIVATE_PEM ya existe." >&2
    echo "Rotar la clave invalida todos los access token vigentes: los usuarios" >&2
    echo "tendrán que volver a autenticarse. Si es lo que quieres, bórrala a mano" >&2
    echo "y vuelve a ejecutar este script." >&2
    exit 1
fi

# -topk8 -nocrypt produce PKCS#8 sin passphrase, que es el formato que
# lee KeyFactory("RSA") + PKCS8EncodedKeySpec en JwtTokenService. El
# formato por defecto de `openssl genrsa` es PKCS#1 y Java no lo parsea.
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
    -out "$PRIVATE_PEM" 2>/dev/null
openssl rsa -in "$PRIVATE_PEM" -pubout -out "$PUBLIC_PEM" 2>/dev/null

chmod 600 "$PRIVATE_PEM"
chmod 644 "$PUBLIC_PEM"

echo "Par de claves generado:"
echo "  privada (solo auth-center): $PRIVATE_PEM"
echo "  pública  (resto):           $PUBLIC_PEM"

if [[ "${1:-}" == "--env" ]]; then
    # docker-compose no admite valores multilínea en .env, así que el PEM
    # viaja con los saltos escapados como \n. JwtTokenService.decodePem
    # borra todo el whitespace antes de decodificar, de modo que ambas
    # formas —fichero montado o env var de una línea— funcionan igual.
    echo
    echo "# ---- pega esto en tu .env (NO lo subas al repositorio) ----"
    printf 'JWT_PRIVATE_KEY="%s"\n' "$(awk '{printf "%s\\n", $0}' "$PRIVATE_PEM")"
    printf 'JWT_PUBLIC_KEY="%s"\n' "$(awk '{printf "%s\\n", $0}' "$PUBLIC_PEM")"
fi
