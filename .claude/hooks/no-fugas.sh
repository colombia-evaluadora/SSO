#!/usr/bin/env bash
# PreToolUse (Bash|PowerShell): impide publicar IPs/hosts de servidores en
# mensajes de commit y descripciones de PR. La deteccion vive en no_fugas.py.
set -uo pipefail
exec python "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/no_fugas.py"
