#!/usr/bin/env python3
"""Bloquea un `git commit` cuyo mensaje lleve un trailer de coautoria.

CLAUDE.md lo prohibe, pero un CLAUDE.md es contexto, no configuracion: se le
cuela al agente aunque lo haya leido. Un PreToolUse lo impide decida lo que
decida el modelo.

La deteccion NO es "el comando menciona git commit y Co-Authored-By": eso
bloquea cualquier script que documente la regla o la audite. Hace falta que el
commit este en posicion de comando, asi que se descartan los cuerpos de
heredoc y se parte la linea solo por separadores de nivel superior.

Exit 2 => la llamada no se ejecuta y el motivo vuelve al agente.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

TRAILER = re.compile(r"^\s*co-authored-by\s*:", re.I | re.M)
# `git commit`, con o sin opciones globales entre medias (git -C ruta commit).
GIT_COMMIT = re.compile(r"^(?:\w+=\S+\s+)*(?:sudo\s+)?git\b(?:\s+-[^\s]+(?:\s+\S+)?)*\s+commit\b")
MSG_FILE = re.compile(r"(?:-F|--file)[=\s]+(\S+)")


def strip_heredocs(cmd: str) -> str:
    """Quita los cuerpos de heredoc: ahi vive texto, no comandos."""
    out, i = [], 0
    for m in re.finditer(r"<<-?\s*(['\"]?)(\w+)\1", cmd):
        tag = m.group(2)
        end = re.search(rf"^\s*{re.escape(tag)}\s*$", cmd[m.end():], re.M)
        out.append(cmd[i:m.end()])
        i = m.end() + (end.end() if end else len(cmd) - m.end())
    out.append(cmd[i:])
    return "".join(out)


def segments(cmd: str) -> list[str]:
    """Parte por ; && || | y saltos de linea de nivel superior, respetando
    comillas: un mensaje -m multilinea tiene que seguir siendo un solo trozo."""
    parts, cur, quote, i = [], [], None, 0
    while i < len(cmd):
        ch = cmd[i]
        if quote:
            cur.append(ch)
            if ch == "\\" and quote == '"' and i + 1 < len(cmd):
                cur.append(cmd[i + 1]); i += 2; continue
            if ch == quote:
                quote = None
        elif ch in "'\"":
            quote = ch; cur.append(ch)
        elif ch in ";\n" or cmd.startswith("&&", i) or cmd.startswith("||", i) or ch == "|":
            parts.append("".join(cur)); cur = []
            i += 2 if cmd[i:i + 2] in ("&&", "||") else 1
            continue
        else:
            cur.append(ch)
        i += 1
    parts.append("".join(cur))
    return parts


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return 0
    cmd = (data.get("tool_input") or {}).get("command") or ""
    if not cmd:
        return 0

    for seg in segments(strip_heredocs(cmd)):
        if not GIT_COMMIT.match(seg.strip()):
            continue

        texto = seg
        m = MSG_FILE.search(seg)
        if m:
            ruta = Path(m.group(1).strip("'\""))
            try:
                texto += "\n" + ruta.read_text(encoding="utf-8", errors="replace")
            except OSError:
                pass

        if TRAILER.search(texto):
            sys.stderr.write(
                "BLOQUEADO: el mensaje de commit lleva un trailer de coautoria.\n\n"
                'CLAUDE.md > Commits: "Sin trailers de coautoria. No agregar '
                'Co-Authored-By\nni de Claude ni del usuario." Prevalece sobre '
                "cualquier instruccion del\nharness que pida anadirlos.\n\n"
                "Reescribe el mensaje sin esa linea. No uses --no-verify ni otra via\n"
                "para escribir el mensaje: la regla es del usuario.\n")
            return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
