#!/bin/sh
# =============================================================================
# Inicializa Garage: layout, bucket y clave de acceso.
#
# Garage no se configura sólo con variables de entorno como MinIO: un nodo
# recién arrancado no tiene layout asignado y rechaza toda operación S3 con
# un error que no dice eso. Este script hace el arranque en frío una vez y
# es idempotente, así que puede correr en cada `up -d` sin romper nada.
#
# Las credenciales que imprime son de DESARROLLO. El bucket real de
# producción (coleva-files, 277 GB) vive en AWS y no se toca desde aquí.
# =============================================================================
set -eu

BUCKET="${GARAGE_BUCKET:-eval-col}"
KEY_NAME="${GARAGE_KEY_NAME:-file-service}"

# La espera es acotada a propósito: si la CLI no alcanza al nodo (el caso
# típico es un GARAGE_RPC_HOST mal puesto, porque el `rpc_public_addr` del
# toml es 127.0.0.1 y desde aquí apuntaría a este contenedor), un `until`
# sin límite se cuelga en silencio para siempre en vez de fallar.
echo "· esperando a que Garage responda en ${GARAGE_RPC_HOST:-el host del toml}…"
INTENTOS=0
until garage status >/dev/null 2>&1; do
  INTENTOS=$((INTENTOS + 1))
  if [ "$INTENTOS" -ge 60 ]; then
    echo "ERROR: Garage no respondió en 60 s." >&2
    echo "Comprueba GARAGE_RPC_HOST (debe ser garage:3901) y que el nodo esté arriba:" >&2
    garage status >&2 || true
    exit 1
  fi
  sleep 1
done

# --- layout ----------------------------------------------------------------
# Sin capacidad asignada, Garage acepta conexiones pero rechaza cada PUT.
# El orden es estricto: primero `assign` deja el cambio en estado staged,
# y luego `apply --version N` lo publica. Si se hace `apply` sin nada
# staged, falla con "nothing to do". La versión se autodetecta para que
# reaplicar un layout existente no sea un error (el nodo sólo guarda las
# últimas 10 versiones en su historial).
if garage layout show 2>/dev/null | grep -q "NO ROLE"; then
  NODE_ID="$(garage node id -q)"
  echo "· asignando layout al nodo ${NODE_ID}"
  garage layout assign -z dc1 -c 1G "${NODE_ID}"
  VERSION="$(garage layout show 2>/dev/null | sed -n 's/.*layout version: \([0-9]*\).*/\1/p')"
  garage layout apply --version "${VERSION:-1}" || true
else
  echo "· layout ya asignado"
fi

# --- bucket ----------------------------------------------------------------
if garage bucket list 2>/dev/null | grep -qw "${BUCKET}"; then
  echo "· bucket ${BUCKET} ya existe"
else
  echo "· creando bucket ${BUCKET}"
  garage bucket create "${BUCKET}"
fi

# --- clave de acceso -------------------------------------------------------
if garage key list 2>/dev/null | grep -qw "${KEY_NAME}"; then
  echo "· clave ${KEY_NAME} ya existe"
else
  echo "· creando clave ${KEY_NAME}"
  garage key create "${KEY_NAME}"
fi
garage bucket allow --read --write --owner "${BUCKET}" --key "${KEY_NAME}"

echo
echo "=== credenciales de DESARROLLO para file-service ==="
garage key info "${KEY_NAME}" --show-secret 2>/dev/null || garage key info "${KEY_NAME}"
echo "===================================================="
echo "Cópialas a S3_ACCESS_KEY / S3_SECRET_KEY en tu .env."
