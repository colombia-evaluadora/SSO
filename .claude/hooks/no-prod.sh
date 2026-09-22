#!/usr/bin/env bash
# PreToolUse (Bash|PowerShell): impide escribir en la base de un servidor real.
# La deteccion vive en no_prod.py; esto solo la invoca.
set -uo pipefail
exec python "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/no_prod.py"
