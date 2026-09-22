#!/usr/bin/env bash
# Envoltorio del hook; la logica vive en fallo_conocido.py.
set -uo pipefail
exec python "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fallo_conocido.py"
