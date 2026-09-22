#!/usr/bin/env bash
# Envoltorio del hook; la logica vive en cierre_limpio.py.
set -uo pipefail
exec python "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cierre_limpio.py"
