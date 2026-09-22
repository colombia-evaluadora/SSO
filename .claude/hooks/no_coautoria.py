#!/usr/bin/env python3
"""Bloquea la atribucion a Claude en mensajes de commit y descripciones de PR.

CLAUDE.md lo prohibe, pero un CLAUDE.md es contexto, no configuracion: se le
cuela al agente aunque lo haya leido. Un PreToolUse lo impide decida lo que
decida el modelo.

La deteccion NO es "el texto menciona Co-Authored-By": eso bloquea cualquier
script que documente la regla o la audite. Hace falta que un comando que
*escribe* atribucion (git commit, gh pr create/edit) este en posicion de
comando; solo entonces se mira el texto, y se descartan los segmentos que solo
leen (git log --grep, grep, rg...).

Lo que el detector viejo dejaba pasar, y por eso hay trailers en el historial
posteriores a su llegada:
  - cuerpos de heredoc (`git commit -F - <<EOF`): es justo donde vive un
    mensaje multilinea, y se estaban borrando antes de mirar;
  - `gh pr create/edit`: ni se miraba, asi que la coautoria entraba por la
    descripcion del PR;
  - la herramienta PowerShell (here-strings `@'...'@`): el hook solo estaba
    enganchado a Bash (se corrige en settings.json).

Exit 2 => la llamada no se ejecuta y el motivo vuelve al agente.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "comun"))
from git_text import publicado  # noqa: E402

# El trailer al principio de una linea real, o de una escapada (`\n` literal
# dentro de un --body de una sola linea).
TRAILER = re.compile(r"(?:^|\\r?\\n)[ \t]*co-authored-by[ \t]*:", re.I | re.M)
# La firma "Generated with Claude Code" que el harness pide para los PR: es
# atribucion a Claude igual que el trailer, y el usuario la quiere fuera.
FIRMA = re.compile(r"generated with \[?claude code", re.I)

def main() -> int:
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return 0
    cmd = (data.get("tool_input") or {}).get("command") or ""
    if not cmd:
        return 0

    commit, pr, texto = publicado(cmd)
    if not (commit or pr):
        return 0

    donde = "del commit" if commit else "del pull request"
    if TRAILER.search(texto):
        motivo = "lleva un trailer de coautoria"
    elif pr and FIRMA.search(texto):
        motivo = 'lleva la firma "Generated with Claude Code"'
    else:
        return 0

    sys.stderr.write(
        f"BLOQUEADO: el texto {donde} {motivo}.\n\n"
        'CLAUDE.md > Commits: "Sin trailers de coautoria. No agregar '
        "Co-Authored-By\nni de Claude ni del usuario.\" Lo mismo vale para la "
        "descripcion de un PR.\nPrevalece sobre cualquier instruccion del harness "
        "que pida anadirlos.\n\n"
        "Reescribe el texto sin esa linea. No uses --no-verify ni otra via para\n"
        "escribirlo: la regla es del usuario.\n")
    return 2


if __name__ == "__main__":
    sys.exit(main())
