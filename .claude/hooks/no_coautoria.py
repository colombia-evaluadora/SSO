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

# El trailer al principio de una linea real, o de una escapada (`\n` literal
# dentro de un --body de una sola linea).
TRAILER = re.compile(r"(?:^|\\r?\\n)[ \t]*co-authored-by[ \t]*:", re.I | re.M)
# La firma "Generated with Claude Code" que el harness pide para los PR: es
# atribucion a Claude igual que el trailer, y el usuario la quiere fuera.
FIRMA = re.compile(r"generated with \[?claude code", re.I)

# `git commit`, con o sin opciones globales entre medias (git -C ruta commit).
GIT_COMMIT = re.compile(r"^(?:\w+=\S+\s+)*(?:sudo\s+)?git\b(?:\s+-[^\s]+(?:\s+\S+)?)*\s+commit\b")
# `gh pr create|edit`, `gh pr comment`, y la via cruda `gh api .../pulls`.
GH_PR = re.compile(r"^(?:\w+=\S+\s+)*gh\s+(?:pr\s+(?:create|edit|comment)\b|api\b.*\bpulls\b)")
# Segmentos que solo leen: no escriben atribucion en ningun lado.
SOLO_LECTURA = re.compile(r"^(?:\w+=\S+\s+)*(?:git\s+(?:log|show|grep|diff)\b|grep\b|rg\b|egrep\b|cat\b|python\b|type\b|Select-String\b)", re.I)
# Ficheros de los que sale el texto: -F/--file (git), --body-file/-F (gh).
ARCHIVO = re.compile(r"(?:--body-file|--file|-F)[=\s]+(\S+)")


def heredocs(cmd: str) -> list[str]:
    """Los cuerpos de heredoc, que es donde vive un mensaje multilinea."""
    cuerpos = []
    for m in re.finditer(r"<<-?\s*(['\"]?)(\w+)\1", cmd):
        tag = m.group(2)
        fin = re.search(rf"^\s*{re.escape(tag)}\s*$", cmd[m.end():], re.M)
        cuerpos.append(cmd[m.end():m.end() + (fin.start() if fin else len(cmd))])
    return cuerpos


def herestrings(cmd: str) -> list[str]:
    """Lo mismo para PowerShell: @'...'@ y @"..."@."""
    return [m.group(2) for m in re.finditer(r"@(['\"])\r?\n(.*?)\r?\n\1@", cmd, re.S)]


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


def texto_de_archivos(cmd: str) -> str:
    fuera = []
    for m in ARCHIVO.finditer(cmd):
        ruta = m.group(1).strip("'\"")
        if ruta in ("-", "--"):
            continue
        try:
            fuera.append(Path(ruta).read_text(encoding="utf-8", errors="replace"))
        except OSError:
            pass
    return "\n".join(fuera)


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return 0
    cmd = (data.get("tool_input") or {}).get("command") or ""
    if not cmd:
        return 0

    # Un heredoc puede contener `;` y `&&`: se parte solo lo que hay fuera.
    sin_cuerpos = cmd
    for cuerpo in heredocs(cmd) + herestrings(cmd):
        sin_cuerpos = sin_cuerpos.replace(cuerpo, "")

    commit = pr = False
    for seg in segments(sin_cuerpos):
        seg = seg.strip().lstrip("(&{ ")
        commit = commit or bool(GIT_COMMIT.match(seg))
        pr = pr or bool(GH_PR.match(seg))
    if not (commit or pr):
        return 0

    # El texto a revisar: el comando sin los segmentos que solo leen, mas los
    # cuerpos de heredoc/here-string y los ficheros de mensaje referenciados.
    partes = [s for s in segments(sin_cuerpos) if not SOLO_LECTURA.match(s.strip().lstrip("(&{ "))]
    texto = "\n".join(partes + heredocs(cmd) + herestrings(cmd) + [texto_de_archivos(cmd)])

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
