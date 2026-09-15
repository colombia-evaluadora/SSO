#!/usr/bin/env bash
# PreToolUse (Bash): impide commitear con trailers de coautoria.
# La deteccion vive en no_coautoria.py; esto solo la invoca.
set -uo pipefail
exec python "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/no_coautoria.py"
